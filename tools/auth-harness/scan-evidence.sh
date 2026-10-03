#!/usr/bin/env bash
# Fails if story 1.2 evidence (or harness sources) contain a usable credential:
# JWTs, Supabase keys, harness-generated passwords, link/OTP token values,
# hex link tokens, or any secret-bearing JSON key whose value is not redacted.
# Usage: bash tools/auth-harness/scan-evidence.sh [paths...]
set -euo pipefail
cd "$(dirname "$0")/../.."
EVIDENCE=_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2
paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=("$EVIDENCE" tools/auth-harness)

patterns=(
  # JWT (header.payload.signature)
  'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{10,}'
  # Supabase publishable/secret keys
  'sb_(secret|publishable)_[A-Za-z0-9_-]{8,}'
  # Harness-generated passwords ('Hx!' + 24 base64url chars)
  'Hx![A-Za-z0-9_-]{16,}'
  # Token values in URLs/fragments that are not redacted
  '[?&#](access_token|refresh_token|token|token_hash|code|provider_token)=(?!\[redacted\])[^&#\s"]+'
  # GoTrue email-link tokens (56 hex) and token hashes
  '\b[0-9a-f]{56}\b'
  # Secret-bearing JSON keys with a non-empty, unredacted string value
  '"(access_token|refresh_token|provider_token|provider_refresh_token|token|token_hash|otp|auth_code|password|new_password|nonce|apikey|authorization|confirmation_token|recovery_token|email_change_token_new|email_change_token_current|phone_change_token|reauthentication_token)"\s*:\s*"(?!\[redacted\]")[^"]+"'
)

fail=0
for p in "${patterns[@]}"; do
  if grep -rPn --exclude=scan-evidence.sh --exclude='*.test.mjs' --exclude='*.sql' -- "$p" "${paths[@]}"; then
    echo "scan-evidence: forbidden pattern found: $p" >&2
    fail=1
  fi
done
# Evidence masks owner-inbox addresses as …+bicauth-<tag>@gmail.com; the full
# local part may appear only in harness usage docs, never in evidence.
if [ -d "$EVIDENCE" ] && grep -rPn -- '[A-Za-z0-9._-]+\+bicauth-[A-Za-z0-9-]*@' "$EVIDENCE"; then
  echo "scan-evidence: unmasked owner-inbox address in evidence" >&2
  fail=1
fi
[ "$fail" -eq 0 ] && echo "scan-evidence: clean (${paths[*]})"
exit "$fail"
