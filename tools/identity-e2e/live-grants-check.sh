#!/usr/bin/env bash
# Story 2.3: drives the REAL client adapters (packages/client_core/tool/live_grants_check.dart)
# against the LOCAL stack: a staff-web Admin client grants and revokes Pastor through
# SupabaseCommandGateway, and an already signed-in member client sees each change at its next
# SupabaseGrantsRepository read with the same token. Creates two SYNTHETIC phone accounts
# (+1 202 555 0157/0158) with verified @example.test aliases, links them as the restricted
# operator, bootstraps the Admin, then removes everything it created.
# LOCAL only; needs an empty Admin roster (fresh `npx supabase db reset`). Prints outcomes only.
#
# Usage: bash tools/identity-e2e/live-grants-check.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[[ -n "${FLUTTER_ROOT:-}" ]] && export PATH="$FLUTTER_ROOT/bin:$PATH"
command -v dart >/dev/null || { echo "dart not found: put the Flutter SDK's bin on PATH or set FLUTTER_ROOT" >&2; exit 2; }
cd "$ROOT"
source supabase/tests/lib/local_stack.sh
require_local_stack API_URL PUBLISHABLE_KEY SECRET_KEY SERVICE_ROLE_KEY DB_URL
[[ "$API_URL" == "http://127.0.0.1:54321" ]] || die "LOCAL only"
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD
TAG=$(uuid | cut -c1-8)
ADMIN_EMAIL="synthetic-2-3-live-admin-$TAG@example.test"
MEMBER_EMAIL="synthetic-2-3-live-member-$TAG@example.test"
OURS="u.email like 'synthetic-2-3-live-%@example.test'"

[[ "$(sql "select app.identity_usable_admin_count()")" == 0 ]] || die "a usable Admin already exists; reset the local database first"
MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-grants-2.3')" >/dev/null

cleanup() {
  sql "create temp table gone as select l.member_id from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where $OURS;
       delete from app.identity_access_audit a using gone g where a.target_member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_grants x using gone g where x.member_id = g.member_id;
       delete from app.identity_grant_sets x using gone g where x.member_id = g.member_id;
       delete from app.identity_binding_history h using app.identity_account_links l, gone g where h.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_credential_events e using app.identity_account_links l, gone g where e.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_account_links x using gone g where x.member_id = g.member_id;
       delete from app.identity_members x using gone g where x.member_id = g.member_id;
       delete from app.cmd_receipts r using auth.users u where r.actor_id = u.id and $OURS;
       delete from auth.users u where $OURS;
       delete from app.platform_environment where set_by = 'live-grants-2.3';
       delete from app.platform_environment_history where set_by = 'live-grants-2.3';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

new_user() { # phone email -> id
  curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$1\",\"phone_confirm\":true,\"email\":\"$2\",\"email_confirm\":true,\"password\":\"$LIVE_CHECK_PASSWORD\"}" | jq -r .id
}
UA=$(new_user "+12025550157" "$ADMIN_EMAIL"); UM=$(new_user "+12025550158" "$MEMBER_EMAIL")
MA=$(sql "select app.identity_seed_synthetic_link('$UA', 'SYNTHETIC 2.3 Live Admin', 'live-grants-2.3')")
sql "select app.identity_seed_synthetic_link('$UM', 'SYNTHETIC 2.3 Live Member', 'live-grants-2.3')" >/dev/null
sql "select app.identity_bootstrap_admin('$MA', 'israel')" >/dev/null
echo "== adapters: staff-web Admin grants/revokes; member session reads"
cd packages/client_core
dart run tool/live_grants_check.dart "$ENV_FILE" "$ADMIN_EMAIL" "$MEMBER_EMAIL"
