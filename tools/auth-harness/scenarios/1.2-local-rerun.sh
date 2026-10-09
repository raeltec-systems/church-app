#!/usr/bin/env bash
# Story 1.2 LOCAL rerun (local Supabase CLI stack only; evidence lines are
# labelled harness_target: LOCAL and go to evidence-1.2/local-harness-log.jsonl).
#
# Preconditions (see evidence-1.2/README.md, "LOCAL run"):
#   - local stack running; harness probe applied to the local DB:
#       docker exec -i supabase_db_church-app psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
#         < tools/auth-harness/sql/001_trusted_session_probe.sql
#     then the same for sql/local/10_local_api_probe_wrappers.sql (local PostgREST
#     exposes only `api`); `supabase db reset` removes both afterwards.
#   - for hosted parity of the email rows, [auth.email] enable_confirmations = true
#     for the duration of the run (restore afterwards).
#   - SUPABASE_PUBLISHABLE_KEY = the local stack's publishable key (`supabase status`).
# Phone rows stop at the provider gate: Supabase CLI 2.119.0 forces
# GOTRUE_EXTERNAL_PHONE_ENABLED=false unless an SMS provider is enabled.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export HARNESS_TARGET=local SUPABASE_URL=http://127.0.0.1:54321
: "${SUPABASE_PUBLISHABLE_KEY:?local publishable key required}"
H="node tools/auth-harness/run.mjs"
LINK="node tools/auth-harness/local-mailpit-link.mjs"
DB="docker exec -i supabase_db_church-app psql -U postgres -d postgres -X -A -t -q"
P=+12025550191
E=${HARNESS_INBOX_LOCAL:?set HARNESS_INBOX_LOCAL}+bicauth-l1@gmail.com
eval "$($H init)"
trap '$H cleanup >/dev/null' EXIT
sessions() { $DB -v ident="$1" < tools/auth-harness/sql/local/observe_local_account_sessions.sql \
  | $H attach --source sql/local/observe_local_account_sessions.sql --via local-psql --step "$2"; }
mail() { sleep 2; $LINK "$E" --subject "$1" --after "$2"; }

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$H info --step L00-provider-info
# Phone track: provider forced off by the CLI (no SMS provider enabled).
$H signup lp1 --phone $P --step L10-phone-signup-cli-forced-provider-off || true
$H login lp1-a --account lp1 --phone $P --step L11-phone-login-cli-forced-provider-off || true
$H otp --phone $P --create-user --step L12-phone-otp-create-user-provider-off || true
$H verify-otp lp1-otp --phone $P --step L13-phone-verify-guess-provider-off || true
$DB < tools/auth-harness/sql/local/observe_local_sms_state.sql \
  | $H attach --source sql/local/observe_local_sms_state.sql --via local-psql --step L14-sms-state-after-phone-attempts

# Email track: legacy steps 22/23 re-captured, then every session probed and
# refreshed after the password change and after the recovery reset.
T=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$H signup l1 --email $E --step L20-email-signup
$H login l1-pre --account l1 --email $E --step L21-login-before-confirm || true
mail "confirm" "$T" | $H verify-link l1-signup --step L22-verify-signup-link
$H probe l1-signup --step L23-probe-signup-link-session
$H refresh l1-signup --as l1-signup-r --step L24-refresh-signup-link-session
$H probe l1-signup-r --step L24b-probe-refreshed-signup-link-session
$H login l1-a --account l1 --email $E --step L30-password-login-A
$H login l1-b --account l1 --email $E --step L31-password-login-B
$H login l1-x --account l1 --email $E --wrong --step L32-wrong-password
$H login l1-y --account l1u --email ${HARNESS_INBOX_LOCAL:?set HARNESS_INBOX_LOCAL}+bicauth-l1-unknown@gmail.com --wrong --step L33-unknown-account
$H probe l1-a --step L34-probe-A
T=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$H otp --email $E --step L40-magic-link-request
mail "sign-in" "$T" | $H verify-link l1-ml --step L41-verify-magic-link
$H probe l1-ml --step L42-probe-magic-link-session
sessions "$E" L50-sessions-before-password-change

$H set-password l1-b --account l1 --step L60-password-change-from-B
for s in l1-a l1-signup-r l1-ml l1-b; do $H probe $s --step L61-probe-after-change-$s || true; done
for s in l1-a l1-signup-r l1-ml l1-b; do $H refresh $s --as $s-r2 --step L62-refresh-after-change-$s || true; done
$H login l1-old --account l1@previous --email $E --step L63-old-password-refused || true
sessions "$E" L64-sessions-after-password-change

$H login l1-c --account l1 --email $E --step L70-password-login-C
$H login l1-d --account l1 --email $E --step L71-password-login-D
T=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$H recover --email $E --step L72-recover-known
$H recover --email ${HARNESS_INBOX_LOCAL:?set HARNESS_INBOX_LOCAL}+bicauth-l1-unknown@gmail.com --step L73-recover-unknown
mail "reset" "$T" | $H verify-link l1-rec --step L74-verify-recovery-link
$H probe l1-rec --step L75-probe-recovery-session
$H set-password l1-rec --account l1 --step L76-set-password-from-recovery
for s in l1-rec l1-c l1-d l1-b-r2; do $H probe $s --step L77-probe-after-reset-$s || true; done
for s in l1-rec l1-c l1-d l1-b-r2; do $H refresh $s --as $s-r3 --step L78-refresh-after-reset-$s || true; done
$H login l1-e --account l1 --email $E --step L79-fresh-login-after-reset
$H probe l1-e --step L79b-probe-fresh-login
sessions "$E" L80-sessions-after-reset
$DB < tools/auth-harness/sql/observe_probe_grants.sql \
  | $H attach --source sql/observe_probe_grants.sql --via local-psql --step L90-local-probe-grants
docker logs --since "$START" supabase_auth_church-app 2>&1 | node tools/auth-harness/local-auth-logs.mjs \
  | $H attach --source sql/local/observe_local_auth_logs.txt --via local-docker-logs --window "$START/now" --step L91-local-auth-logs
