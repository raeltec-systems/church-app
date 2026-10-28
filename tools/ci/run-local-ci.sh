#!/usr/bin/env bash
# Runs the steps of .github/workflows/ci.yml locally, in workflow order, and records
# each step as PASS, FAIL or UNRUN (a tool the step needs is missing). It never stops
# at a failure, so one run shows every result. Usage, from the repository root:
#   bash tools/ci/run-local-ci.sh <results-file> [--base <git-ref>]
# The db job resets the local Supabase stack: hold the shared local-database lock.
set -u
out="${1:?usage: run-local-ci.sh <results-file> [--base <ref>]}"
base=""
if [ "${2:-}" = "--base" ]; then base="${3:?--base needs a ref}"; fi
root="$(pwd)"
logdir="$(dirname "$out")/ci-logs"
mkdir -p "$logdir"
: > "$out"
echo "head $(git rev-parse HEAD)" >> "$out"
n=0

step() { # step <name> <dir> <command...>
  local name="$1" dir="$2"; shift 2
  n=$((n + 1))
  local log="$logdir/$(printf '%02d' "$n").log"
  (cd "$root/$dir" && "$@") > "$log" 2>&1
  local code=$?
  local verdict=PASS
  [ $code -ne 0 ] && verdict="FAIL(exit $code)"
  printf '%s\t%s\t%s\n' "$verdict" "$name" "$log" >> "$out"
}
unrun() { n=$((n + 1)); printf 'UNRUN\t%s\t%s\n' "$1" "$2" >> "$out"; }

# policy
step "policy tool tests" . npm run ci:policy-test
step "environment configs" . npm run env:check
if [ -n "$base" ]; then
  step "migrations (base $base)" . npm run ci:migrations -- --base "$base"
else
  step "migrations" . npm run ci:migrations
fi
step "no secrets in tracked files" . npm run ci:secrets
step "edge function imports" . npm run ci:function-imports
unrun "staging migration-history drift" "needs SUPABASE_ACCESS_TOKEN (CI skips it too)"

# db
step "contract fixtures (TypeScript)" . npm run contracts:test
step "local stack start" . npx supabase start -x studio,imgproxy,mailpit,edge-runtime,logflare,vector,supavisor,realtime,postgres-meta
step "local reset (fresh database)" . npx supabase db reset --local
step "pgTAP" . npm run db:test
step "Data API smoke" . npm run db:smoke
step "restore rehearsal" . npm run recovery:rehearse

# harness and evidence scans
step "harness, function and shared-module tests" . bash -c 'node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs tools/hymn-book/*.test.mjs'
step "evidence scans (every scan-evidence.sh step in ci.yml)" . bash -c "grep -E '^\s+run: bash tools/auth-harness/scan-evidence.sh' .github/workflows/ci.yml | sed -E 's/^\s+run: //' | while read -r cmd; do echo \"== \$cmd\"; eval \"\$cmd\" || exit 1; done"

# flutter
step "contracts pub get" packages/contracts/dart dart pub get --enforce-lockfile
step "contracts analyze" packages/contracts/dart dart analyze --fatal-infos
step "contracts test" packages/contracts/dart dart test
if command -v chrome >/dev/null 2>&1 || [ -x "/c/Program Files/Google/Chrome/Application/chrome.exe" ]; then
  step "contracts test in Chrome" packages/contracts/dart dart test -p chrome
else
  unrun "contracts test in Chrome" "no Chrome on this host"
fi
for pkg in packages/design_system packages/client_core apps/mobile apps/staff trials/staff_web; do
  step "$pkg pub get" "$pkg" flutter pub get --enforce-lockfile
  step "$pkg analyze" "$pkg" flutter analyze
  step "$pkg test" "$pkg" flutter test
done
step "client_core duties in America/New_York" packages/client_core env TZ=America/New_York flutter test test/duties
step "client_core follow-ups in America/New_York" packages/client_core env TZ=America/New_York flutter test test/followups
step "staff build web" apps/staff flutter build web --no-web-resources-cdn
step "staff web trial build web" trials/staff_web flutter build web
step "web bundles carry no secret" . node tools/ci/scan-secrets.mjs --bundle apps/staff/build/web trials/staff_web/build/web
git -C "$root" checkout -- apps/mobile/linux/flutter 2>/dev/null
echo "done" >> "$out"
