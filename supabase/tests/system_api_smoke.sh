#!/usr/bin/env bash
# Bounded system route (story 1.9, AD-19) through the real Data API of the running local stack:
# valid, replayed and conflicting probes; missing, malformed, unknown and wrong-environment
# credentials; a real user session JWT; a forged JWT; forged actor fields and headers; a
# non-allowlisted command; the audit table not exposed; then the content-free audit rows.
# The credential is minted at run time into a temp dir and never printed; SYNTHETIC data only.
# Usage: npm run db:smoke   (expects `npm run db:start`; needs node, curl, jq and psql)
# Optional: SYSTEM_SMOKE_EVIDENCE_DIR=<dir> saves the matrix and audit rows there.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/supabase/tests/lib/local_stack.sh"
require_local_stack API_URL PUBLISHABLE_KEY SECRET_KEY SERVICE_ROLE_KEY DB_URL
WORK=$(mktemp -d)
chmod 700 "$WORK"
USER_ID=""
PRINCIPAL_ID=""
CREDENTIAL_ID=""
MARKED=0
fail=0

cleanup() {
  [[ -n "$CREDENTIAL_ID" ]] && sql "select app.sys_revoke_credential('$CREDENTIAL_ID', 'israel');" >/dev/null || true
  [[ -n "$PRINCIPAL_ID" ]] && sql "select app.sys_disable_principal('$PRINCIPAL_ID', 'israel');" >/dev/null || true
  [[ -n "$USER_ID" ]] && synthetic_user_delete "$USER_ID"
  if [[ "$MARKED" == 1 ]]; then
    # Restore the unmarked state this script found (local stack only).
    sql "delete from app.platform_environment where set_by = 'system-api-smoke';
         delete from app.platform_environment_history where set_by = 'system-api-smoke';" >/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Environment marker: the route is bound to it. Mark local only if unmarked.
current=$(sql "select coalesce((select environment from app.platform_environment), '')")
if [[ -z "$current" ]]; then
  sql "select app.platform_set_environment('local', 'system-api-smoke');" >/dev/null
  MARKED=1
elif [[ "$current" != local ]]; then
  die "local database is marked '$current'"
fi
START=$(sql "select now()")

# Mint (token stays in $WORK, 0600) and register only the digest, as the restricted operator.
export OPS_STATE_DIR="$WORK/ops-state"
digest=$(node "$ROOT/tools/ops/system-credential.mjs" mint --env local | jq -r .digest)
node "$ROOT/tools/ops/system-credential.mjs" mint --env staging >/dev/null   # wrong-environment token, unregistered
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "mint failed"
PRINCIPAL_ID=$(sql "select app.sys_create_principal('smoke-$(uuid | cut -c1-8)', 'synthetic_probe', 'israel');")
CREDENTIAL_ID=$(sql "select app.sys_register_credential('$PRINCIPAL_ID', '$digest', 'system api smoke', interval '10 minutes', 'israel') ->> 'credential_id';")

# A real synthetic user session.
email="system-smoke-$(uuid)@example.test"; password="Smoke-$(uuid)"
USER_ID=$(synthetic_user_create "$email" "$password")
[[ "$USER_ID" =~ ^[0-9a-f-]{36}$ ]] || die "could not create a synthetic user"
SYSTEM_MATRIX_USER_JWT=$(synthetic_user_token "$email" "$password")
[[ -n "$SYSTEM_MATRIX_USER_JWT" && "$SYSTEM_MATRIX_USER_JWT" != null ]] || die "could not sign in"
export SYSTEM_MATRIX_USER_JWT SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY" SUPABASE_API_URL="$API_URL"

if node "$ROOT/tools/ops/system-credential.mjs" matrix --env local --require-user-jwt --out "$WORK/matrix.jsonl" >/dev/null; then
  echo "ok   - system route HTTP matrix ($(grep -c '"pass":true' "$WORK/matrix.jsonl") cases)"
else
  echo "FAIL - system route HTTP matrix:"; grep -v '"pass":true' "$WORK/matrix.jsonl" || true; fail=1
fi

# Audit: every call recorded, content-free, attributed only to the credential's principal.
audit=$(sql "select json_agg(json_build_object('outcome', outcome, 'reason', reason, 'code', code,
               'caller_role', caller_role, 'command', command, 'principal_is_smoke', system_principal_id = '$PRINCIPAL_ID',
               'has_request_id', request_id is not null, 'initiating_member_id', initiating_member_id) order by id)
             from app.sys_audit where occurred_at >= '$START'")
calls=$(grep -c '"http_status"' "$WORK/matrix.jsonl")
rows=$(jq length <<<"$audit")
# The forged-JWT and audit-table requests are refused by PostgREST before any SQL runs.
if [[ "$rows" == $((calls - 2)) ]]; then echo "ok   - one audit row per call that reached the route ($rows)"; else echo "FAIL - audit rows $rows for $calls calls"; fail=1; fi
succ=$(jq '[.[] | select(.outcome == "succeeded")] | length' <<<"$audit")
if [[ "$succ" == 2 ]]; then echo "ok   - only the valid and forged-header probes succeeded"; else echo "FAIL - $succ successes"; fail=1; fi
if jq -e 'all(.[]; .initiating_member_id == null and (.principal_is_smoke != false))' <<<"$audit" >/dev/null; then
  echo "ok   - no forged principal or member in the audit"
else echo "FAIL - forged attribution in audit"; fail=1; fi
if jq -e '[.[] | select(.reason == "user_session_rejected" and .caller_role == "authenticated")] | length == 1' <<<"$audit" >/dev/null; then
  echo "ok   - the user session was refused and audited as authenticated"
else echo "FAIL - user session audit"; fail=1; fi

if [[ -n "${SYSTEM_SMOKE_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$SYSTEM_SMOKE_EVIDENCE_DIR"
  cp "$WORK/matrix.jsonl" "$SYSTEM_SMOKE_EVIDENCE_DIR/local-matrix.jsonl"
  jq . <<<"$audit" > "$SYSTEM_SMOKE_EVIDENCE_DIR/local-audit.json"
  sql "select app.ops_health_snapshot(interval '10 minutes')" | jq . > "$SYSTEM_SMOKE_EVIDENCE_DIR/local-health-snapshot.json"
fi
exit $fail
