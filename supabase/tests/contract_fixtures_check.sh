#!/usr/bin/env bash
# Shared wire-contract fixtures (story 1.5) against the SQL authority, app.contract_check, in the
# running local database. The Dart and TypeScript client mappings run the same files.
# Usage: npm run db:smoke   (expects `npm run db:start`; needs jq and psql or docker)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/packages/contracts/fixtures/v1"

eval "$(npx supabase status -o env 2>/dev/null | grep -E '^DB_URL=')"
: "${DB_URL:?}"

pg() { # psql against the local database: host psql, or the db container as fallback
  if command -v psql >/dev/null 2>&1; then
    psql "$DB_URL" -X -qtA -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "$(docker ps --filter name=supabase_db_ --format '{{.Names}}' | head -1)" \
      psql -U postgres -X -qtA -v ON_ERROR_STOP=1 "$@"
  fi
}

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
exit "$fail"
