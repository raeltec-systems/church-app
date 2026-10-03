#!/usr/bin/env bash
# Command foundation (story 1.4) through the real Data API (PostgREST + Auth) of the running
# local stack: duplicates, changed-payload replay, stale revisions, simultaneous writes,
# rolled-back failures, malformed envelopes, revoked fixture authority (including a revocation
# racing an in-flight command) and denied direct access.
# Usage: npm run db:smoke   (expects `npm run db:start`; needs curl, jq and psql; SYNTHETIC users and data only)
set -euo pipefail

eval "$(npx supabase status -o env 2>/dev/null | grep -E '^(API_URL|PUBLISHABLE_KEY|SECRET_KEY|SERVICE_ROLE_KEY|DB_URL)=')"
: "${API_URL:?}" "${PUBLISHABLE_KEY:?}" "${SECRET_KEY:?}" "${SERVICE_ROLE_KEY:?}" "${DB_URL:?}"
RPC="$API_URL/rest/v1/rpc/fixture_counter_command"
fail=0
WORK=$(mktemp -d)
USERS=()

ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }
expect() { # name expected actual
  if [[ "$3" == "$2" ]]; then ok "$1 ($3)"; else bad "$1: expected $2, got $3"; fi
}

die() { echo "SETUP FAILED - $1" >&2; exit 1; }

pg() { # psql against the local database: host psql, or the db container as fallback
  if command -v psql >/dev/null 2>&1; then
    psql "$DB_URL" -X -qtA -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i -e PGAPPNAME="${PGAPPNAME:-psql}" \
      "$(docker ps --filter name=supabase_db_ --format '{{.Names}}' | head -1)" \
      psql -U postgres -X -qtA -v ON_ERROR_STOP=1 "$@"
  fi
}
sql() { pg -c "$1"; }

uuid() { cat /proc/sys/kernel/random/uuid; }

cleanup() {
  for id in "${USERS[@]:-}"; do
    [[ -z "$id" ]] && continue
    sql "delete from app.cmd_receipts where actor_id = '$id';
         delete from app.fixture_counters where created_by = '$id';
         delete from app.fixture_command_grants where actor_id = '$id';" >/dev/null || true
    curl -s -o /dev/null -X DELETE "$API_URL/auth/v1/admin/users/$id" \
      -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Creates a fresh synthetic email/password user in this shell (not a subshell), registers it for
# cleanup as soon as it exists, and sets ACTOR_ID and ACTOR_TOKEN. Any failure aborts the run.
new_actor() {
  local email="fixture-$(uuid)@example.test" password="Fixture-$(uuid)"
  ACTOR_ID=$(curl -s -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\",\"email_confirm\":true}" | jq -r .id) \
    || die "admin user creation request failed"
  [[ "$ACTOR_ID" =~ ^[0-9a-f-]{36}$ ]] || die "could not create a synthetic user"
  USERS+=("$ACTOR_ID")
  ACTOR_TOKEN=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" | jq -r .access_token) \
    || die "password sign-in request failed"
  [[ -n "$ACTOR_TOKEN" && "$ACTOR_TOKEN" != null ]] || die "could not sign in the synthetic user"
}

raw_call() { # out_file token body -> http code
  local out=$1 token=$2 auth=()
  [[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")
  curl -s -o "$out" -w '%{http_code}' -X POST "$RPC" \
    -H "apikey: $PUBLISHABLE_KEY" "${auth[@]}" \
    -H 'Content-Profile: api' -H 'Content-Type: application/json' -d "$3"
}
call() { # out_file token command request_id expected_revision(json) payload(json) -> http code
  raw_call "$1" "$2" \
    "{\"version\":1,\"command\":\"$3\",\"request_id\":\"$4\",\"expected_revision\":$5,\"payload\":$6}"
}

# Hold the counter row lock for a few seconds so the next requests really arrive together.
hold_lock() { # counter_id seconds
  PGAPPNAME=fixture_lock_holder pg \
    -c 'begin' -c "select 1 from app.fixture_counters where id = '$1' for update" \
    -c "select pg_sleep($2)" -c 'commit' >/dev/null &
  HOLDER=$!
  for _ in $(seq 1 50); do
    [[ "$(sql "select count(*) from pg_stat_activity
                where application_name = 'fixture_lock_holder' and wait_event = 'PgSleep'")" == 1 ]] && return 0
    sleep 0.1
  done
  bad "lock holder did not start"; return 1
}
max_lock_waiters() { # polls until the holder ends; prints the most requests seen waiting on locks
  local max=0 n
  while kill -0 "$HOLDER" 2>/dev/null; do
    n=$(sql "select count(*) from pg_stat_activity
              where wait_event_type = 'Lock' and application_name <> 'fixture_lock_holder'")
    (( n > max )) && max=$n
    sleep 0.1
  done
  echo "$max"
}

new_actor; A=$ACTOR_ID; A_TOKEN=$ACTOR_TOKEN
new_actor; B=$ACTOR_ID; B_TOKEN=$ACTOR_TOKEN

# Denied access ---------------------------------------------------------------------------------
code=$(call "$WORK/anon" "" fixture_counter.create "$(uuid)" null '{"intent_key":"anon"}')
expect "anon cannot execute the command RPC" 401 "$code"
code=$(call "$WORK/nogrant" "$A_TOKEN" fixture_counter.create "$(uuid)" null '{"intent_key":"k"}')
expect "actor without fixture authority is forbidden" forbidden "$(jq -r .code "$WORK/nogrant")"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/fixture_counters" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $A_TOKEN" -H 'Content-Profile: app' \
  -H 'Content-Type: application/json' -d '{"intent_key":"direct"}')
expect "direct table insert into app is not reachable (PGRST106)" 406 "$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/cmd_execute" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $A_TOKEN" -H 'Content-Profile: app' \
  -H 'Content-Type: application/json' -d '{}')
expect "the app kernel is not reachable over HTTP" 406 "$code"

sql "insert into app.fixture_command_grants (actor_id, command) values
       ('$A', 'fixture_counter.create'), ('$A', 'fixture_counter.increment'),
       ('$B', 'fixture_counter.create'), ('$B', 'fixture_counter.increment')" >/dev/null

# Create ----------------------------------------------------------------------------------------
REQ_CREATE=$(uuid)
call "$WORK/create" "$A_TOKEN" fixture_counter.create "$REQ_CREATE" null '{"intent_key":"smoke"}' >/dev/null
COUNTER=$(jq -r .data.id "$WORK/create")
expect "create returns revision 1" 1 "$(jq -r .revision "$WORK/create")"
call "$WORK/create_changed" "$A_TOKEN" fixture_counter.create "$REQ_CREATE" null '{"intent_key":"other"}' >/dev/null
expect "changed-payload replay conflicts" conflict "$(jq -r .code "$WORK/create_changed")"

# Simultaneous duplicates: 5 identical requests queue behind the held row lock ------------------
REQ_DUP=$(uuid)
hold_lock "$COUNTER" 3
for i in 1 2 3 4 5; do
  call "$WORK/dup$i" "$A_TOKEN" fixture_counter.increment "$REQ_DUP" 1 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >"$WORK/dup$i.code" &
done
waiters=$(max_lock_waiters); wait
(( waiters >= 2 )) && ok "duplicates were in flight together ($waiters waiting on locks)" \
  || bad "duplicates did not overlap (max $waiters waiting)"
distinct=$(for i in 1 2 3 4 5; do jq -cS . "$WORK/dup$i"; done | sort -u | wc -l)
expect "all 5 duplicates return one identical result" 1 "$distinct"
expect "duplicate result is the first increment" 2 "$(jq -r .revision "$WORK/dup1")"
expect "duplicates applied once" "1|2" "$(sql "select value || '|' || revision from app.fixture_counters where id = '$COUNTER'")"
expect "one receipt for the duplicated request" 1 "$(sql "select count(*) from app.cmd_receipts where request_id = '$REQ_DUP'")"

# Simultaneous distinct writers at the same revision --------------------------------------------
hold_lock "$COUNTER" 3
for i in 1 2 3 4 5 6 7 8; do
  call "$WORK/race$i" "$A_TOKEN" fixture_counter.increment "$(uuid)" 2 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null &
done
waiters=$(max_lock_waiters); wait
(( waiters >= 2 )) && ok "writers were in flight together ($waiters waiting on locks)" \
  || bad "writers did not overlap (max $waiters waiting)"
wins=$(for i in $(seq 1 8); do jq -r '.revision // empty' "$WORK/race$i"; done | wc -l)
conflicts=$(for i in $(seq 1 8); do jq -r 'select(.code == "conflict" and .current_revision == 3) | .code' "$WORK/race$i"; done | wc -l)
expect "exactly one simultaneous writer wins" 1 "$wins"
expect "the other 7 get conflict with current_revision 3" 7 "$conflicts"
expect "counter advanced exactly once" "2|3" "$(sql "select value || '|' || revision from app.fixture_counters where id = '$COUNTER'")"

# Stale revision and rolled-back failure ---------------------------------------------------------
call "$WORK/stale" "$A_TOKEN" fixture_counter.increment "$(uuid)" 1 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null
expect "stale revision conflicts" "conflict|3" "$(jq -r '.code + "|" + (.current_revision|tostring)' "$WORK/stale")"
REQ_FAIL=$(uuid)
call "$WORK/fail" "$A_TOKEN" fixture_counter.increment "$REQ_FAIL" 3 "{\"counter_id\":\"$COUNTER\",\"by\":1000}" >/dev/null
expect "failing write returns validation_failed" validation_failed "$(jq -r .code "$WORK/fail")"
if grep -qiE 'violat|constraint|sql|fixture_counters' "$WORK/fail"; then bad "error leaks SQL detail: $(cat "$WORK/fail")"; else ok "error carries no SQL detail"; fi
expect "failed write rolled back the aggregate" "2|3" "$(sql "select value || '|' || revision from app.fixture_counters where id = '$COUNTER'")"
expect "failed write committed no receipt" 0 "$(sql "select count(*) from app.cmd_receipts where request_id = '$REQ_FAIL'")"

# Scope ----------------------------------------------------------------------------------------
call "$WORK/scope" "$B_TOKEN" fixture_counter.increment "$(uuid)" 3 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null
expect "another actor's counter is not_found" not_found "$(jq -r .code "$WORK/scope")"

# Malformed or missing envelope fields come back as contract envelopes, not raw errors ----------
envelope_case() { # name body field expected_reason
  local code
  code=$(raw_call "$WORK/env" "$A_TOKEN" "$2")
  expect "$1" "200|validation_failed|$4" \
    "$code|$(jq -r --arg f "$3" '.code + "|" + (.field_errors[$f] // "")' "$WORK/env")"
}
envelope_case "malformed request_id is a validation_failed envelope" \
  "{\"version\":1,\"command\":\"fixture_counter.create\",\"request_id\":\"not-a-uuid\",\"payload\":{\"intent_key\":\"e1\"}}" \
  request_id invalid
envelope_case "omitted request_id is a validation_failed envelope" \
  "{\"version\":1,\"command\":\"fixture_counter.create\",\"payload\":{\"intent_key\":\"e2\"}}" \
  request_id required
envelope_case "malformed expected_revision is a validation_failed envelope" \
  "{\"version\":1,\"command\":\"fixture_counter.increment\",\"request_id\":\"$(uuid)\",\"expected_revision\":\"abc\",\"payload\":{\"counter_id\":\"$COUNTER\",\"by\":1}}" \
  expected_revision invalid
envelope_case "omitted version is a validation_failed envelope" \
  "{\"command\":\"fixture_counter.create\",\"request_id\":\"$(uuid)\",\"payload\":{\"intent_key\":\"e3\"}}" \
  version required
expect "malformed envelopes changed nothing" "2|3" "$(sql "select value || '|' || revision from app.fixture_counters where id = '$COUNTER'")"

# Concurrent revocation waits for an in-flight command holding the grant row FOR SHARE ----------
hold_lock "$COUNTER" 4
call "$WORK/inflight" "$A_TOKEN" fixture_counter.increment "$(uuid)" 3 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null &
CMD_PID=$!
for _ in $(seq 1 50); do
  [[ "$(sql "select count(*) from pg_stat_activity
              where wait_event_type = 'Lock' and application_name <> 'fixture_lock_holder'")" -ge 1 ]] && break
  sleep 0.1
done
PGAPPNAME=fixture_revoker pg -c "update app.fixture_command_grants set revoked_at = now()
  where actor_id = '$A' and command = 'fixture_counter.increment'" >/dev/null &
REV_PID=$!
revoker_waited=0
while kill -0 "$HOLDER" 2>/dev/null; do
  [[ "$(sql "select count(*) from pg_stat_activity
              where application_name = 'fixture_revoker' and wait_event_type = 'Lock'")" == 1 ]] && revoker_waited=1
  sleep 0.1
done
wait "$CMD_PID" "$REV_PID" "$HOLDER"
expect "revocation waited on the in-flight command's grant lock" 1 "$revoker_waited"
expect "the command authorised before the revocation completed" 4 "$(jq -r .revision "$WORK/inflight")"
expect "the revocation committed afterwards" 1 "$(sql "select count(*) from app.fixture_command_grants
  where actor_id = '$A' and command = 'fixture_counter.increment' and revoked_at is not null")"

# Revoked authority ----------------------------------------------------------------------------
call "$WORK/revoked_replay" "$A_TOKEN" fixture_counter.increment "$REQ_DUP" 1 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null
expect "revoked authority blocks receipt replay" forbidden "$(jq -r .code "$WORK/revoked_replay")"
call "$WORK/revoked_new" "$A_TOKEN" fixture_counter.increment "$(uuid)" 4 "{\"counter_id\":\"$COUNTER\",\"by\":1}" >/dev/null
expect "revoked authority blocks new writes" forbidden "$(jq -r .code "$WORK/revoked_new")"
expect "nothing changed after revocation" "3|4" "$(sql "select value || '|' || revision from app.fixture_counters where id = '$COUNTER'")"

exit $fail
