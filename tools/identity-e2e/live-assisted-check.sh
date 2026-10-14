#!/usr/bin/env bash
# Story 2.9: drives the REAL client adapters (packages/client_core/tool/live_assisted_recovery_check.dart)
# against the LOCAL stack and the Edge Function identity-assisted-recovery served here with a
# fresh system credential (purpose identity_assisted_recovery; only its digest is registered; the
# token lives in a 0600 temp file for the run). The member's phone asks for help, a staff-web
# Admin opens a case and issues the setup for the code, the phone sets a private password once,
# and a fresh password sign-in is required. Creates the Admin (+44 7700 900459, bootstrapped) and
# the member (+44 7700 900458), then removes everything (the run's credential is revoked and its
# principal disabled; content-free system audit rows stay). LOCAL only; needs
# `node tools/auth-harness/local-phone-auth.mjs on`, the edge-runtime image and an empty Admin
# roster (fresh `npx supabase db reset`). Prints outcomes only.
#
# Usage: bash tools/identity-e2e/live-assisted-check.sh
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
ADMIN_PHONE="+447700900459"
PHONE="+447700900458"
OURS="u.phone in ('${ADMIN_PHONE#+}', '${PHONE#+}')"
TMP=$(mktemp -d)
chmod 700 "$TMP"
printf 'API_URL=%s\nPUBLISHABLE_KEY=%s\n' "$API_URL" "$PUBLISHABLE_KEY" > "$TMP/client.env"
LIVE_CHECK_PASSWORD="Synthetic-$(node -e "process.stdout.write(require('crypto').randomBytes(9).toString('base64url'))")"
export LIVE_CHECK_PASSWORD

[[ "$(sql "select app.identity_usable_admin_count()")" == 0 ]] || die "a usable Admin already exists; reset the local database first"
[[ "$(sql "select count(*) from auth.users u where $OURS")" == 0 ]] || die "a user with these numbers already exists"
MARK=$(sql "select coalesce((select environment from app.platform_environment), '')")
[[ -z "$MARK" ]] && sql "select app.platform_set_environment('local', 'live-assisted-2.9')" >/dev/null

RUN=$(node -e "process.stdout.write(require('crypto').randomBytes(4).toString('hex'))")
CREDENTIAL=$(node -e "process.stdout.write('sysc_local_' + require('crypto').randomBytes(32).toString('base64url'))")
DIGEST=$(printf '%s' "$CREDENTIAL" | sha256sum | cut -d' ' -f1)
PRINCIPAL=$(sql "select app.sys_create_principal('identity-assisted-live-$RUN', 'identity_assisted_recovery', 'israel')")
CRED_ID=$(sql "select app.sys_register_credential('$PRINCIPAL', '$DIGEST', 'assisted live $RUN', interval '1 hour', 'israel') ->> 'credential_id'")
( umask 077; printf 'IDENTITY_RECOVERY_SYSTEM_CREDENTIAL=%s\n' "$CREDENTIAL" > "$TMP/functions.env" )
unset CREDENTIAL
setsid npx supabase functions serve --env-file "$TMP/functions.env" > "$TMP/serve.log" 2>&1 &
SERVE_PID=$!

cleanup() {
  kill -INT -- "-$SERVE_PID" 2>/dev/null || true
  sleep 2
  docker rm -f supabase_edge_runtime_church-app >/dev/null 2>&1 || true
  sql "select app.sys_revoke_credential('$CRED_ID', 'israel'); select app.sys_disable_principal('$PRINCIPAL', 'israel');" >/dev/null
  sql "create temp table gone_users as select u.id from auth.users u where $OURS;
       create temp table gone as select m.member_id from app.identity_members m where m.display_name like 'SYNTHETIC 2.9 Live%';
       delete from app.identity_recovery_audit a using gone g where a.member_id = g.member_id or a.actor_member_id = g.member_id;
       delete from app.identity_recovery_operations x using gone g where x.member_id = g.member_id;
       delete from app.identity_recovery_grants x using gone g where x.member_id = g.member_id;
       delete from app.identity_recovery_cases x using gone g where x.member_id = g.member_id;
       delete from app.identity_recovery_requests r where r.claimed_phone in ('$ADMIN_PHONE', '$PHONE');
       delete from app.identity_recovery_audit a where a.member_id is null and a.system_principal_id = '$PRINCIPAL';
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
       delete from app.platform_environment where set_by = 'live-assisted-2.9';
       delete from app.platform_environment_history where set_by = 'live-assisted-2.9';" >/dev/null
  echo "synthetic users left: $(sql "select count(*) from auth.users u where $OURS")"
  rm -rf "$TMP"
}
trap cleanup EXIT

for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/identity-assisted-recovery" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d '{}' || true)
  [[ "$code" == 400 ]] && break
  sleep 1
done
[[ "$code" == 400 ]] || die "the Edge Function did not start (is the edge-runtime image present?)"

create() { # phone -> user id
  curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$1\",\"phone_confirm\":true,\"password\":\"$LIVE_CHECK_PASSWORD\"}" | jq -r .id
}
UA=$(create "$ADMIN_PHONE")
MA=$(sql "select app.identity_seed_synthetic_link('$UA', 'SYNTHETIC 2.9 Live Admin', 'live-assisted-2.9')")
sql "select app.identity_bootstrap_admin('$MA', 'israel')" >/dev/null
UM=$(create "$PHONE")
LIVE_CHECK_MEMBER_ID=$(sql "select app.identity_seed_synthetic_link('$UM', 'SYNTHETIC 2.9 Live Member', 'live-assisted-2.9')")
export LIVE_CHECK_MEMBER_ID
echo "== adapters: help on the phone, an Admin case and setup, a private password, fresh sign-in"
cd packages/client_core
dart run tool/live_assisted_recovery_check.dart "$TMP/client.env" "$ADMIN_PHONE" "$PHONE"
