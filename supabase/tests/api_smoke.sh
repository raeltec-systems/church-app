#!/usr/bin/env bash
# HTTP permission evidence through the Data API (PostgREST) of the running local stack.
# pgTAP cannot see which schemas PostgREST exposes, so these checks go over HTTP.
# Usage: npm run db:smoke   (expects `npm run db:start` to have run)
set -euo pipefail

eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|PUBLISHABLE_KEY)=')"
: "${API_URL:?supabase status did not report API_URL}"
: "${PUBLISHABLE_KEY:?supabase status did not report PUBLISHABLE_KEY}"
REST="$API_URL/rest/v1/platform_status"
fail=0

check() { # name expected_status actual_status body
  if [[ "$3" == "$2" ]]; then echo "ok   - $1 ($3)"; else echo "FAIL - $1: expected $2, got $3: $4"; fail=1; fi
}

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

call() { # method profile_header [data] [query]
  local method=$1 profile=$2 data=${3:-} query=${4:-}
  local args=(-s -o "$BODY" -w '%{http_code}' -X "$method" -H "apikey: $PUBLISHABLE_KEY" -H "$profile")
  if [[ -n "$data" ]]; then args+=(-H 'Content-Type: application/json' -d "$data"); fi
  curl "${args[@]}" "$REST$query"
}

code=$(call GET "Accept-Profile: api")
body=$(cat "$BODY")
check "anon reads api.platform_status" 200 "$code" "$body"
if ! grep -q '"is_synthetic":true' <<<"$body"; then echo "FAIL - row is not labelled synthetic: $body"; fail=1; fi

code=$(call GET "Accept-Profile: app")
check "app schema is not exposed (PGRST106)" 406 "$code" "$(cat "$BODY")"

code=$(call GET "Accept-Profile: public")
check "public schema is not exposed" 406 "$code" "$(cat "$BODY")"

code=$(call POST "Content-Profile: api" '{"status":"x","message":"y"}')
check "anon INSERT through api is denied" 401 "$code" "$(cat "$BODY")"

code=$(call PATCH "Content-Profile: api" '{"status":"x"}' '?status=not.is.null')
check "anon UPDATE through api is denied" 401 "$code" "$(cat "$BODY")"

code=$(call DELETE "Content-Profile: api" '' '?status=not.is.null')
check "anon DELETE through api is denied" 401 "$code" "$(cat "$BODY")"

exit $fail
