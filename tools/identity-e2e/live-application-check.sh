#!/usr/bin/env bash
# Story 2.4: drives the REAL client adapters (packages/client_core/tool/live_application_check.dart)
# against the LOCAL stack: phone sign-up through SupabaseAccountAuthGateway (no email, no SMS),
# the safe cell chooser and the applicant's own request through SupabaseMembershipRepository,
# submit and correct through SupabaseCommandGateway, the access reads still denied, and a
# duplicate username refused. Seeds the SYNTHETIC cells, then removes everything it created.
# Needs `node tools/auth-harness/local-phone-auth.mjs on`. SYNTHETIC +1 202 555 0183 only.
#
# Usage: bash tools/identity-e2e/live-application-check.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[[ -n "${FLUTTER_ROOT:-}" ]] && export PATH="$FLUTTER_ROOT/bin:$PATH"
command -v dart >/dev/null || { echo "dart not found: put the Flutter SDK's bin on PATH or set FLUTTER_ROOT" >&2; exit 2; }
cd "$ROOT"
source supabase/tests/lib/local_stack.sh
require_local_stack API_URL PUBLISHABLE_KEY DB_URL
[[ "$API_URL" == "http://127.0.0.1:54321" ]] || die "LOCAL only"
[[ "$(curl -s "$API_URL/auth/v1/settings" -H "apikey: $PUBLISHABLE_KEY" | jq -r .external.phone)" == true ]] \
  || die "the local phone provider is off: run node tools/auth-harness/local-phone-auth.mjs on"
PHONE="+12025550183"
OURS="u.phone = '${PHONE#+}'"
ENV_FILE=$(mktemp)
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD
MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-apply-2.4')" >/dev/null
CELLS=$(sql "select count(*) from app.cells_cells where is_synthetic")

cleanup() {
  sql "delete from app.identity_application_events e using app.identity_membership_applications a, auth.users u
        where e.application_id = a.application_id and a.auth_user_id = u.id and $OURS;
       delete from app.identity_membership_applications a using auth.users u where a.auth_user_id = u.id and $OURS;
       delete from app.cmd_receipts r using auth.users u where r.actor_id = u.id and $OURS;
       delete from auth.users u where $OURS;" >/dev/null
  if [[ "$CELLS" == 0 ]]; then
    sql "delete from app.cells_signup_options where is_synthetic; delete from app.cells_cells where is_synthetic;" >/dev/null
  fi
  sql "delete from app.platform_environment where set_by = 'live-apply-2.4';
       delete from app.platform_environment_history where set_by = 'live-apply-2.4';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

[[ "$(sql "select count(*) from auth.users u where $OURS")" == 0 ]] || die "a user with $PHONE already exists"
sql "select app.cells_seed_synthetic_cells('live-apply-2.4')" >/dev/null
echo "== adapters: phone sign-up, chooser, submit/correct, access still denied, duplicate refused"
cd packages/client_core
dart run tool/live_application_check.dart "$ENV_FILE" "$PHONE"
