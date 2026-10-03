#!/usr/bin/env bash
# Shared wire-contract fixtures (story 1.5) against the SQL authority, app.contract_check, in the
# running local database. The Dart and TypeScript client mappings run the same files.
# Usage: npm run db:smoke   (expects `npm run db:start`; needs jq and psql or docker)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/packages/contracts/fixtures/v1"

source "$ROOT/supabase/tests/lib/local_stack.sh"
require_local_stack DB_URL

fail=0
total=0
for file in "$FIXTURES"/*.json; do
  # One query per file: every case with its expected and actual result.
  cases=$(jq -c '[.kind as $k
                  | (.valid[] | {kind: $k, name, value, expected: {valid: true, field_errors: {}}}),
                    (.invalid[] | {kind: $k, name, value, expected: {valid: false, field_errors}})]' "$file")
  results=$(pg -v cases="$cases" <<'SQL'
select coalesce(jsonb_agg(jsonb_build_object(
         'name', c ->> 'name',
         'ok', app.contract_check(c ->> 'kind', c -> 'value') = c -> 'expected',
         'actual', app.contract_check(c ->> 'kind', c -> 'value'))), '[]'::jsonb)
  from jsonb_array_elements(:'cases'::jsonb) c;
SQL
)
  kind=$(jq -r .kind "$file")
  count=$(jq length <<<"$results")
  total=$((total + count))
  bad=$(jq -c '.[] | select(.ok | not)' <<<"$results")
  if [[ -z "$bad" ]]; then
    echo "ok   - $kind: $count fixture cases match app.contract_check"
  else
    while IFS= read -r line; do echo "FAIL - $kind: $line"; done <<<"$bad"
    fail=1
  fi
done

echo "# $total fixture cases checked against SQL"

# The command envelope fixtures through the real api entry point (api.fixture_counter_command)
# as an authenticated synthetic actor with no grant, in a rolled-back transaction. The kernel
# may add only its per-command codes (command unsupported, expected_revision required /
# must_be_null); everything else must equal the fixture, and a valid envelope must get past
# validation (here: forbidden, since the actor holds no grant).
cases=$(jq -c '[(.valid[] | {name, value, expected: {}}),
                (.invalid[] | {name, value, expected: .field_errors})]' "$FIXTURES/command_request.json")
results=$(pg -v cases="$cases" <<'SQL'
begin;
create temp table cases as select c from jsonb_array_elements(:'cases'::jsonb) c;
grant select on cases to authenticated;
set local role authenticated;
set local request.jwt.claims = '{"sub": "f0000000-0000-4000-8000-0000000000f5", "role": "authenticated"}';
select coalesce(jsonb_agg(jsonb_build_object('name', c ->> 'name', 'expected', c -> 'expected',
         'response', api.fixture_counter_command(c -> 'value'))), '[]'::jsonb)
  from cases;
rollback;
SQL
)
bad=$(jq -c '.[]
  | .actual = (if .response.code == "validation_failed"
               then (.response.field_errors
                     | with_entries(select(([.key, .value] == ["command", "unsupported"]
                                            or [.key, .value] == ["expected_revision", "required"]
                                            or [.key, .value] == ["expected_revision", "must_be_null"]) | not)))
               else {} end)
  | select(.actual != .expected)
  | {name, expected, response}' <<<"$results")
count=$(jq length <<<"$results")
if [[ -z "$bad" ]]; then
  echo "ok   - command_request: $count fixture envelopes agree with api.fixture_counter_command"
else
  while IFS= read -r line; do echo "FAIL - api envelope: $line"; done <<<"$bad"
  fail=1
fi
exit "$fail"
