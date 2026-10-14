#!/usr/bin/env bash
# Story 2.5: drives the REAL client adapters (packages/client_core/tool/live_review_check.dart)
# against the LOCAL stack: a staff-web Admin (phone sign-in) reads the review queue through
# SupabaseReviewRepository, records an accountless SYNTHETIC member and links a new applicant's
# account to it through SupabaseCommandGateway; the applicant's pre-approval session is refused
# and a fresh sign-in reaches the same member id. Creates the Admin (+1 202 555 0189, linked by
# the restricted operator and bootstrapped) and the applicant (+1 202 555 0188, phone sign-up,
# no email), then removes everything it created.
# LOCAL only; needs `node tools/auth-harness/local-phone-auth.mjs on` and an empty Admin roster
# (fresh `npx supabase db reset`). Prints outcomes only.
#
# Usage: bash tools/identity-e2e/live-review-check.sh
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
ADMIN_PHONE="+12025550189"
PHONE="+12025550188"
OURS="u.phone in ('${ADMIN_PHONE#+}', '${PHONE#+}')"
ENV_FILE=$(mktemp)
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD

[[ "$(sql "select app.identity_usable_admin_count()")" == 0 ]] || die "a usable Admin already exists; reset the local database first"
[[ "$(sql "select count(*) from auth.users u where $OURS")" == 0 ]] || die "a user with these numbers already exists"
MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-review-2.5')" >/dev/null

cleanup() {
  sql "create temp table gone_users as select u.id from auth.users u where $OURS;
       create temp table gone as select m.member_id from app.identity_members m where m.display_name like 'SYNTHETIC 2.5 Live%';
       delete from app.identity_membership_audit a using gone g where a.member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_member_provenance p using gone g where p.member_id = g.member_id;
       delete from app.identity_application_events e using app.identity_membership_applications a
        where e.application_id = a.application_id and a.auth_user_id in (select id from gone_users);
       delete from app.identity_membership_applications a where a.auth_user_id in (select id from gone_users);
       delete from app.identity_access_audit a using gone g where a.target_member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_grants x using gone g where x.member_id = g.member_id;
       delete from app.identity_grant_sets x using gone g where x.member_id = g.member_id;
       delete from app.identity_binding_history h using app.identity_account_links l, gone g where h.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_credential_events e using app.identity_account_links l, gone g where e.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_account_links x using gone g where x.member_id = g.member_id;
       delete from app.identity_members x using gone g where x.member_id = g.member_id;
       delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
       delete from auth.users u where u.id in (select id from gone_users);
       delete from app.platform_environment where set_by = 'live-review-2.5';
       delete from app.platform_environment_history where set_by = 'live-review-2.5';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

UA=$(curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"phone\":\"$ADMIN_PHONE\",\"phone_confirm\":true,\"password\":\"$LIVE_CHECK_PASSWORD\"}" | jq -r .id)
MA=$(sql "select app.identity_seed_synthetic_link('$UA', 'SYNTHETIC 2.5 Live Admin', 'live-review-2.5')")
sql "select app.identity_bootstrap_admin('$MA', 'israel')" >/dev/null
echo "== adapters: staff-web Admin review queue, accountless record, link; applicant re-signs in"
cd packages/client_core
dart run tool/live_review_check.dart "$ENV_FILE" "$ADMIN_PHONE" "$PHONE"
