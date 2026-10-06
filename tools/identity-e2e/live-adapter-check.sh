#!/usr/bin/env bash
# Story 2.2: drives the REAL client adapters (packages/client_core/tool/live_identity_check.dart)
# against the LOCAL stack: sign-up (unlinked), restricted-operator SYNTHETIC link, then the
# `session` mode (token refresh, reopen from the stored session JSON, revocation from another
# device, sign-out). Preconditions: local stack running and
#   node tools/auth-harness/local-phone-auth.mjs on
# LOCAL only (the Dart tool refuses any other API URL); fictional numbers only; prints outcomes,
# never tokens or passwords. Cleans up the synthetic user, link and member it created.
#
# Usage: bash tools/identity-e2e/live-adapter-check.sh [+12025550181]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PHONE=${1:-+12025550181}
case "$PHONE" in +120255501[0-9][0-9]|+447700900[0-9][0-9][0-9]) ;; *) echo "not a reserved fictional number" >&2; exit 2;; esac
DIGITS=${PHONE#+}
[[ -n "${FLUTTER_ROOT:-}" ]] && export PATH="$FLUTTER_ROOT/bin:$PATH"
command -v dart >/dev/null || { echo "dart not found: put the Flutter SDK's bin on PATH or set FLUTTER_ROOT" >&2; exit 2; }
cd "$ROOT"
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
npx supabase status -o env 2>/dev/null | grep -E "^(API_URL|PUBLISHABLE_KEY)=" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD
cd packages/client_core
echo "== signup (unlinked)"
dart run tool/live_identity_check.dart "$ENV_FILE" signup "$PHONE" not_linked
echo "== operator seeds a SYNTHETIC link (database marked local for the run)"
MARK=$(docker exec supabase_db_church-app psql -U postgres -qtAX -c "select coalesce((select environment from app.platform_environment), '')")
if [ -z "$MARK" ]; then docker exec supabase_db_church-app psql -U postgres -qtAX -c "select app.platform_set_environment('local', 'live-check-2.2')" >/dev/null; fi
docker exec supabase_db_church-app psql -U postgres -qtAX -c "select app.identity_seed_synthetic_link((select id from auth.users where phone='$DIGITS'), 'SYNTHETIC 2.2 Adapter Member', 'live-check 2.2') is not null"
echo "== session (refresh, reopen, revoke elsewhere, sign-out)"
set +e
dart run tool/live_identity_check.dart "$ENV_FILE" session "$PHONE" granted
RC=$?
set -e
echo "== cleanup"
docker exec supabase_db_church-app psql -U postgres -qtAX -c "
  delete from app.identity_binding_history h using app.identity_account_links l, auth.users u where h.link_id = l.link_id and l.auth_user_id = u.id and u.phone = '$DIGITS';
  delete from app.identity_credential_events e using app.identity_account_links l, auth.users u where e.link_id = l.link_id and l.auth_user_id = u.id and u.phone = '$DIGITS';
  with gone as (delete from app.identity_account_links l using auth.users u where l.auth_user_id = u.id and u.phone = '$DIGITS' returning l.member_id)
  delete from app.identity_members m using gone where m.member_id = gone.member_id;
  delete from auth.users where phone = '$DIGITS';
  delete from app.platform_environment where set_by = 'live-check-2.2';
  delete from app.platform_environment_history where set_by = 'live-check-2.2';
  select 'synthetic users left: ' || count(*) from auth.users where phone = '$DIGITS';"
exit $RC
