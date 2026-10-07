#!/usr/bin/env bash
# Story 2.8: drives the REAL client adapters (packages/client_core/tool/live_credentials_check.dart)
# against the LOCAL stack: a member asks for a new phone username (password re-check, credential
# command), a staff-web Admin approves it from the credential queue (applied to Auth server-side,
# no SMS), then places a lost-device hold (every session revoked, the help screen's own read
# answers review) and releases it after an identity check. Creates the Admin (+44 7700 900359,
# linked by the restricted operator and bootstrapped) and the member (+44 7700 900358, linked; new
# number +44 7700 900357), then removes everything. LOCAL only; needs
# `node tools/auth-harness/local-phone-auth.mjs on` and an empty Admin roster (fresh
# `npx supabase db reset`). Prints outcomes only.
#
# Usage: bash tools/identity-e2e/live-credentials-check.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[[ -n "${FLUTTER_ROOT:-}" ]] && export PATH="$FLUTTER_ROOT/bin:$PATH"
command -v dart >/dev/null || { echo "dart not found: put the Flutter SDK's bin on PATH or set FLUTTER_ROOT" >&2; exit 2; }
cd "$ROOT"
source supabase/tests/lib/local_stack.sh
require_local_stack API_URL PUBLISHABLE_KEY SECRET_KEY SERVICE_ROLE_KEY DB_URL
[[ "$API_URL" == "http://127.0.0.1:54321" ]] || die "LOCAL only"
[[ "$(curl -s "$API_URL/auth/v1/settings" -H "apikey: $PUBLISHABLE_KEY" | jq -r .external.phone)" == true ]] \
  || die "the local phone provider is off: run node tools/auth-harness/local-phone-auth.mjs on"
ADMIN_PHONE="+447700900359"
PHONE="+447700900358"
NEW_PHONE="+447700900357"
OURS="u.phone in ('${ADMIN_PHONE#+}', '${PHONE#+}', '${NEW_PHONE#+}')"
ENV_FILE=$(mktemp)
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD

[[ "$(sql "select app.identity_usable_admin_count()")" == 0 ]] || die "a usable Admin already exists; reset the local database first"
[[ "$(sql "select count(*) from auth.users u where $OURS")" == 0 ]] || die "a user with these numbers already exists"
MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-credentials-2.8')" >/dev/null

cleanup() {
  sql "create temp table gone_users as select u.id from auth.users u where $OURS;
       create temp table gone as select m.member_id from app.identity_members m where m.display_name like 'SYNTHETIC 2.8 Live%';
       delete from app.identity_credential_review_audit a using gone g where a.member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_credential_changes c using gone g where c.member_id = g.member_id;
       delete from app.identity_holds h using gone g where h.member_id = g.member_id;
       delete from app.identity_access_audit a using gone g where a.target_member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_grants x using gone g where x.member_id = g.member_id;
       delete from app.identity_grant_sets x using gone g where x.member_id = g.member_id;
       delete from app.identity_binding_history h using app.identity_account_links l, gone g where h.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_credential_events e using app.identity_account_links l, gone g where e.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_account_links x using gone g where x.member_id = g.member_id;
       delete from app.identity_members x using gone g where x.member_id = g.member_id;
       delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
       delete from auth.flow_state f where f.user_id in (select id from gone_users);
       delete from auth.users u where u.id in (select id from gone_users);
       delete from app.platform_environment where set_by = 'live-credentials-2.8';
       delete from app.platform_environment_history where set_by = 'live-credentials-2.8';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

create() { # phone -> user id
  curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$1\",\"phone_confirm\":true,\"password\":\"$LIVE_CHECK_PASSWORD\"}" | jq -r .id
}
UA=$(create "$ADMIN_PHONE")
MA=$(sql "select app.identity_seed_synthetic_link('$UA', 'SYNTHETIC 2.8 Live Admin', 'live-credentials-2.8')")
sql "select app.identity_bootstrap_admin('$MA', 'israel')" >/dev/null
UM=$(create "$PHONE")
sql "select app.identity_seed_synthetic_link('$UM', 'SYNTHETIC 2.8 Live Member', 'live-credentials-2.8')" >/dev/null
echo "== adapters: a reviewed username change, a lost-device hold and its release"
cd packages/client_core
dart run tool/live_credentials_check.dart "$ENV_FILE" "$ADMIN_PHONE" "$PHONE" "$NEW_PHONE"
