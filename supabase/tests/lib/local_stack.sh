# Shared helpers for the `npm run db:smoke` scripts (story 1.11 refactor sweep). Source it from a
# script under supabase/tests/; it only defines functions and touches nothing until called.
# LOCAL stack only, SYNTHETIC users and data only.

die() { echo "SETUP FAILED - $1" >&2; exit 1; }

# Loads the named variables (API_URL, PUBLISHABLE_KEY, SECRET_KEY, SERVICE_ROLE_KEY, DB_URL, ...)
# from `supabase status` of the running local stack and aborts if any is missing.
require_local_stack() {
  local pattern
  pattern="^($(IFS='|'; echo "$*"))="
  eval "$(npx supabase status -o env 2>/dev/null | grep -E "$pattern")"
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || { echo "supabase status did not report $v (is the local stack running?)" >&2; exit 1; }
  done
}

# psql against the local database: host psql, or the db container as fallback.
pg() {
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

# Prints the id of a new confirmed email/password user (admin API), or nothing on failure.
synthetic_user_create() { # email password
  curl -s -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"email_confirm\":true}" | jq -r .id
}

# Prints a password-grant access token for the user ("null" or nothing on failure).
synthetic_user_token() { # email password
  curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r .access_token
}

# Deletes a user through the admin API; never fails (used in cleanup traps).
synthetic_user_delete() { # id
  curl -s -o /dev/null -X DELETE "$API_URL/auth/v1/admin/users/$1" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
}
