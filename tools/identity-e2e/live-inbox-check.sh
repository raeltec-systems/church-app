#!/usr/bin/env bash
# Story 3.1: drives the REAL client adapters (packages/client_core/tool/live_inbox_check.dart)
# against the LOCAL stack: member A runs the synthetic source command through
# SupabaseCommandGateway, the real worker script (tools/notifications/worker.mjs) runs once
# through the system route with a local `notifications_worker` credential, and A's mobile and
# staff web clients (SupabaseInboxRepository) read the same single item while member B and a
# signed-out client see nothing. Creates two SYNTHETIC phone accounts (+44 7700 900820/900821)
# with verified @example.test aliases, links them as the restricted operator, then removes
# everything it created (the credential is revoked and its principal disabled).
# LOCAL only. Prints outcomes only.
#
# Usage: bash tools/identity-e2e/live-inbox-check.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[[ -n "${FLUTTER_ROOT:-}" ]] && export PATH="$FLUTTER_ROOT/bin:$PATH"
command -v dart >/dev/null || { echo "dart not found: put the Flutter SDK's bin on PATH or set FLUTTER_ROOT" >&2; exit 2; }
cd "$ROOT"
source supabase/tests/lib/local_stack.sh
require_local_stack API_URL PUBLISHABLE_KEY SECRET_KEY SERVICE_ROLE_KEY DB_URL
[[ "$API_URL" == "http://127.0.0.1:54321" ]] || die "LOCAL only"
ENV_FILE=$(mktemp)
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$ENV_FILE"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD
NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL="sysc_local_$(node -e "process.stdout.write(require('crypto').randomBytes(32).toString('base64url'))")"
export NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL
TAG=$(uuid | cut -c1-8)
A_EMAIL="synthetic-3-1-live-a-$TAG@example.test"
B_EMAIL="synthetic-3-1-live-b-$TAG@example.test"
OURS="u.email like 'synthetic-3-1-live-%@example.test'"

MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-inbox-3.1')" >/dev/null
PRINCIPAL=$(sql "select app.sys_create_principal('notifications-worker-live-$TAG', 'notifications_worker', 'israel')")
DIGEST=$(printf '%s' "$NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL" | sha256sum | cut -d' ' -f1)
CRED_ID=$(sql "select app.sys_register_credential('$PRINCIPAL', '$DIGEST', 'live inbox $TAG', interval '1 hour', 'israel') ->> 'credential_id'")

cleanup() {
  sql "create temp table gone as select l.member_id from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where $OURS;
       delete from app.notifications_inbox_items x using gone g where x.recipient_member_id = g.member_id;
       delete from app.notifications_jobs x using gone g where x.recipient_member_id = g.member_id;
       delete from app.fixture_reminder_sources x using gone g where x.member_id = g.member_id;
       delete from app.identity_access_audit a using gone g where a.target_member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_grants x using gone g where x.member_id = g.member_id;
       delete from app.identity_grant_sets x using gone g where x.member_id = g.member_id;
       delete from app.identity_binding_history h using app.identity_account_links l, gone g where h.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_credential_events e using app.identity_account_links l, gone g where e.link_id = l.link_id and l.member_id = g.member_id;
       delete from app.identity_account_links x using gone g where x.member_id = g.member_id;
       delete from app.identity_members x using gone g where x.member_id = g.member_id;
       delete from app.cmd_receipts r using auth.users u where r.actor_id = u.id and $OURS;
       delete from auth.users u where $OURS;
       select app.sys_revoke_credential('$CRED_ID', 'israel');
       select app.sys_disable_principal('$PRINCIPAL', 'israel');
       delete from app.platform_environment where set_by = 'live-inbox-3.1';
       delete from app.platform_environment_history where set_by = 'live-inbox-3.1';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

new_user() { # phone email -> id
  curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$1\",\"phone_confirm\":true,\"email\":\"$2\",\"email_confirm\":true,\"password\":\"$LIVE_CHECK_PASSWORD\"}" | jq -r .id
}
UA=$(new_user "+447700900820" "$A_EMAIL"); UB=$(new_user "+447700900821" "$B_EMAIL")
sql "select app.identity_seed_synthetic_link('$UA', 'SYNTHETIC 3.1 Live Member A', 'live-inbox-3.1')" >/dev/null
sql "select app.identity_seed_synthetic_link('$UB', 'SYNTHETIC 3.1 Live Member B', 'live-inbox-3.1')" >/dev/null
echo "== adapters: source command, worker, mobile and staff web inbox reads"
cd packages/client_core
dart run tool/live_inbox_check.dart "$ENV_FILE" "$A_EMAIL" "$B_EMAIL"
