#!/usr/bin/env bash
# Identity live access (story 2.1) through the real Data API (PostgREST + Auth) of the running
# local stack: the allowlisted read api.identity_my_member_summary for a seeded synthetic member,
# an unlinked account, a signed-out client, a revoked session, and direct table queries.
# Story 2.2 adds native alternate routes with the CLI's default config: token refresh keeps
# access; magic-link and recovery sessions (Auth Admin generate_link redeemed at native /verify,
# so no email is sent) are denied; a direct Auth email change puts the account in review.
#
# The local CLI forces the phone provider off (evidence-1.2/local-cli-phone-gate.txt), so CI signs
# in through the verified-email alias of a phone account (AD-20: same account, same predicate).
# Phone sign-in itself is exercised by tools/identity-e2e with `node tools/auth-harness/local-phone-auth.mjs on`.
# Story 2.3 adds: the grant command and grant reads refuse signed-out and unlinked callers.
# Story 2.4 adds: the application command and applicant reads (signed-out and unlinked callers).
# Usage: npm run db:smoke   (needs curl, jq and psql; SYNTHETIC users and data only)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/local_stack.sh"
require_local_stack API_URL PUBLISHABLE_KEY SECRET_KEY SERVICE_ROLE_KEY DB_URL
RPC="$API_URL/rest/v1/rpc/identity_my_member_summary"
fail=0
WORK=$(mktemp -d)
USERS=()
MARKED=0

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }
expect() { # name expected actual [body]
  if [[ "$3" == "$2" ]]; then ok "$1 ($3)"; else bad "$1: expected $2, got $3 ${4:-}"; fi
}

cleanup() {
  for id in "${USERS[@]:-}"; do
    [[ -z "$id" ]] && continue
    sql "delete from app.identity_application_events e using app.identity_membership_applications a
          where e.application_id = a.application_id and a.auth_user_id = '$id';
         delete from app.identity_membership_applications where auth_user_id = '$id';
         delete from app.cmd_receipts where actor_id = '$id';" >/dev/null || true
    sql "delete from app.identity_binding_history h using app.identity_account_links l
          where h.link_id = l.link_id and l.auth_user_id = '$id';
         delete from app.identity_credential_events e using app.identity_account_links l
          where e.link_id = l.link_id and l.auth_user_id = '$id';
         delete from app.identity_grants g using app.identity_account_links l
          where g.member_id = l.member_id and l.auth_user_id = '$id';
         delete from app.identity_grant_sets s using app.identity_account_links l
          where s.member_id = l.member_id and l.auth_user_id = '$id';
         with gone as (delete from app.identity_account_links where auth_user_id = '$id' returning member_id)
         delete from app.identity_members m using gone where m.member_id = gone.member_id;" >/dev/null || true
    synthetic_user_delete "$id"
  done
  if [[ "$MARKED" == 1 ]]; then
    sql "delete from app.platform_environment where set_by = 'identity-api-smoke';
         delete from app.platform_environment_history where set_by = 'identity-api-smoke';" >/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

current=$(sql "select coalesce((select environment from app.platform_environment), '')")
if [[ -z "$current" ]]; then
  sql "select app.platform_set_environment('local', 'identity-api-smoke');" >/dev/null
  MARKED=1
elif [[ "$current" != local ]]; then
  die "local database is marked '$current'"
fi

# Synthetic phone account (fictional NANP range) with a verified synthetic email alias.
new_user() { # phone email password -> sets USER_ID
  USER_ID=$(curl -s -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$1\",\"phone_confirm\":true,\"email\":\"$2\",\"email_confirm\":true,\"password\":\"$3\"}" | jq -r .id)
  [[ "$USER_ID" =~ ^[0-9a-f-]{36}$ ]] || die "could not create a synthetic user"
  USERS+=("$USER_ID")
}
sign_in() { # email password -> prints the session JSON
  curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}"
}
read_summary() { # token -> http code; body in $WORK/out
  local auth=()
  [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
  curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$RPC" -H "apikey: $PUBLISHABLE_KEY" "${auth[@]}" \
    -H 'Content-Profile: api' -H 'Content-Type: application/json' -d '{}'
}

PW1="Synthetic-$(uuid)"; PW2="Synthetic-$(uuid)"
new_user "+12025550161" "identity-smoke-1-$(uuid | cut -c1-8)@example.test" "$PW1"; U1=$USER_ID
E1=$(sql "select email from auth.users where id = '$U1'")
new_user "+12025550162" "identity-smoke-2-$(uuid | cut -c1-8)@example.test" "$PW2"; U2=$USER_ID
E2=$(sql "select email from auth.users where id = '$U2'")
sql "select app.identity_seed_synthetic_link('$U1', 'SYNTHETIC Smoke Member', 'identity-api-smoke');" >/dev/null

S1=$(sign_in "$E1" "$PW1"); T1=$(jq -r .access_token <<<"$S1"); R1=$(jq -r .refresh_token <<<"$S1")
T2=$(sign_in "$E2" "$PW2" | jq -r .access_token)
[[ -n "$T1" && "$T1" != null && -n "$T2" && "$T2" != null ]] || die "synthetic sign-in failed"

code=$(read_summary "$T1"); body=$(cat "$WORK/out")
expect "linked synthetic member reads own summary" 200 "$code" "$body"
[[ "$(jq -r .display_name <<<"$body")" == "SYNTHETIC Smoke Member" && "$(jq -r .phone_username <<<"$body")" == "+12025550161" ]] \
  && ok "summary is the caller's own record" || bad "unexpected summary: $body"

code=$(read_summary "$T2"); body=$(cat "$WORK/out")
expect "unlinked account is forbidden" 403 "$code" "$body"
[[ "$(jq -r .message <<<"$body"):$(jq -r .details <<<"$body")" == "forbidden:not_linked" ]] \
  && ok "unlinked denial is generic (forbidden/not_linked)" || bad "unlinked body: $body"

code=$(read_summary ""); expect "signed-out client is refused" 401 "$code" "$(cat "$WORK/out")"

code=$(curl -s -o "$WORK/out" -w '%{http_code}' "$API_URL/rest/v1/identity_members" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $T1" -H 'Accept-Profile: app')
expect "direct query of the app schema is refused (not exposed)" 406 "$code" "$(cat "$WORK/out")"
for rel in identity_members identity_account_links identity_holds; do
  code=$(curl -s -o "$WORK/out" -w '%{http_code}' "$API_URL/rest/v1/$rel" \
    -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $T1" -H 'Accept-Profile: api')
  expect "no api relation named $rel" 404 "$code" "$(cat "$WORK/out")"
done

# Sign-out (scope local) deletes the session row: the still-unexpired JWT is denied.
curl -s -o /dev/null -X POST "$API_URL/auth/v1/logout?scope=local" -H "apikey: $PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $T1"
code=$(read_summary "$T1"); body=$(cat "$WORK/out")
expect "revoked session's unexpired JWT is refused" 401 "$code" "$body"
[[ "$(jq -r .details <<<"$body")" == "untrusted_session" ]] && ok "revoked session reason" || bad "revoked body: $body"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/token?grant_type=refresh_token" \
  -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d "{\"refresh_token\":\"$R1\"}")
expect "revoked session cannot refresh" 400 "$code"

# Story 2.2: alternate native Auth routes on the same linked account.
admin() { # method path json -> body
  curl -s -X "$1" "$API_URL/auth/v1$2" -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' -d "$3"
}
verify_hash() { # type token_hash -> access token
  curl -s -X POST "$API_URL/auth/v1/verify" -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"type\":\"$1\",\"token_hash\":\"$2\"}" | jq -r .access_token
}
S3=$(sign_in "$E1" "$PW1"); R3=$(jq -r .refresh_token <<<"$S3")
T3=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=refresh_token" -H "apikey: $PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' -d "{\"refresh_token\":\"$R3\"}" | jq -r .access_token)
code=$(read_summary "$T3"); expect "a refreshed password session keeps access" 200 "$code" "$(cat "$WORK/out")"
for type in magiclink recovery; do
  H=$(admin POST /admin/generate_link "{\"type\":\"$type\",\"email\":\"$E1\"}" | jq -r .hashed_token)
  TL=$(verify_hash "$type" "$H")
  [[ -n "$TL" && "$TL" != null ]] || bad "$type link did not produce a session"
  code=$(read_summary "$TL"); body=$(cat "$WORK/out")
  [[ "$code:$(jq -r .details <<<"$body")" == "401:untrusted_session" ]] \
    && ok "$type session (otp AMR) is denied (401 untrusted_session)" || bad "$type session: $code $body"
done
admin PUT "/admin/users/$U1" "{\"email\":\"changed-$E1\",\"email_confirm\":true}" >/dev/null
code=$(read_summary "$T3"); body=$(cat "$WORK/out")
[[ "$code:$(jq -r .details <<<"$body")" == "403:review_required" ]] \
  && ok "a direct Auth email change puts the account in review (403 review_required)" || bad "after email change: $code $body"
T4=$(sign_in "changed-$E1" "$PW1" | jq -r .access_token)
code=$(read_summary "$T4"); body=$(cat "$WORK/out")
[[ "$code:$(jq -r .details <<<"$body")" == "403:review_required" ]] \
  && ok "a fresh sign-in with the changed email is still in review" || bad "fresh sign-in after change: $code $body"
kinds=$(sql "select string_agg(array_to_string(e.kinds, '+'), ',' order by e.event_id) from app.identity_credential_events e
              join app.identity_account_links l using (link_id) where l.auth_user_id = '$U1'")
[[ "$kinds" == *email* ]] && ok "the change is recorded by kind ($kinds)" || bad "credential events: '$kinds'"

# Story 2.3: the grant command and grant reads need a session (no EXECUTE for anon).
for call in 'identity_my_access|{}' 'identity_grant_command|{}' 'identity_admin_member_grants|{}' \
            "fixture_scoped_read|{\"scope_kind\":\"fixture_care\",\"scope_id\":\"$(uuid)\"}"; do
  fn=${call%%|*}
  code=$(curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/$fn" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Profile: api' -H 'Content-Type: application/json' -d "${call#*|}")
  expect "signed-out client cannot call $fn" 401 "$code" "$(cat "$WORK/out")"
done
T5=$(sign_in "$E2" "$PW2" | jq -r .access_token)
code=$(curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/identity_my_access" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $T5" -H 'Content-Profile: api' \
  -H 'Content-Type: application/json' -d '{}')
expect "an unlinked account reads no access" 403 "$code" "$(cat "$WORK/out")"
GRANT_BODY="{\"version\":1,\"command\":\"identity.grant_role\",\"request_id\":\"$(uuid)\",\"expected_revision\":1,\"payload\":{\"member_id\":\"$(uuid)\",\"role\":\"admin\"}}"
code=$(curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/identity_grant_command" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $T5" -H 'Content-Profile: api' \
  -H 'Content-Type: application/json' -d "$GRANT_BODY")
[[ "$code:$(jq -r .code "$WORK/out")" == "200:forbidden" ]] \
  && ok "an unlinked account cannot grant roles (forbidden envelope)" || bad "grant as unlinked: $code $(cat "$WORK/out")"

# Story 2.4: the application command and applicant reads need a session; an unlinked account
# reads only its own (empty) application and the safe chooser; applying grants no access.
for fn in identity_application_command identity_my_application cells_signup_options; do
  code=$(curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/$fn" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Profile: api' -H 'Content-Type: application/json' -d '{}')
  expect "signed-out client cannot call $fn" 401 "$code" "$(cat "$WORK/out")"
done
api_call() { # fn body
  curl -s -o "$WORK/out" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/$1" \
    -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $T5" -H 'Content-Profile: api' \
    -H 'Content-Type: application/json' -d "$2"
}
code=$(api_call identity_my_application '{}')
[[ "$code:$(jq -c '[.application, .privacy_notice.draft]' "$WORK/out")" == '200:[null,true]' ]] \
  && ok "an unlinked account reads its own (empty) application and the draft notice" \
  || bad "my_application as unlinked: $code $(cat "$WORK/out")"
code=$(api_call cells_signup_options '{}')
[[ "$code:$(jq -c '[(.options | type), ([.options[] | keys[]] | unique - ["broad_area","cell_id","label","revision"])]' "$WORK/out")" == '200:["array",[]]' ]] \
  && ok "the cell chooser returns only label, broad area, id and revision" \
  || bad "cells_signup_options: $code $(cat "$WORK/out")"
APPLY_BODY="{\"version\":1,\"command\":\"identity.submit_application\",\"request_id\":\"$(uuid)\",\"expected_revision\":null,\"payload\":{\"full_name\":\"SYNTHETIC Smoke\",\"cell_choice\":{\"choice\":\"not_sure\"},\"privacy_notice_version\":\"draft-2026-10-07\"}}"
code=$(api_call identity_application_command "$APPLY_BODY")
[[ "$code:$(jq -c '[.data.church_status, .data.cell_status, .revision]' "$WORK/out")" == '200:["awaiting_approval","follow_up",1]' ]] \
  && ok "an unlinked phone account applies (awaiting approval, cell follow-up)" || bad "apply: $code $(cat "$WORK/out")"
code=$(api_call identity_my_access '{}')
[[ "$code:$(jq -r .details "$WORK/out")" == "403:not_linked" ]] \
  && ok "applying grants nothing: still no member access (403 not_linked)" || bad "access after applying: $code $(cat "$WORK/out")"

# No SMS configuration exists on this stack.
sms=$(curl -s "$API_URL/auth/v1/settings" -H "apikey: $PUBLISHABLE_KEY" | jq -r '.sms_provider // ""')
[[ -z "$sms" ]] && ok "no SMS provider configured" || bad "sms_provider is '$sms'"

exit $fail
