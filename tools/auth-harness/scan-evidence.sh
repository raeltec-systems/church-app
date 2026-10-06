#!/usr/bin/env bash
# Fails if story 1.2/1.3 evidence (or harness sources) contain a usable credential:
# JWTs, Supabase keys, harness-generated passwords, link/OTP token values,
# hex link tokens, or any secret-bearing JSON key whose value is not redacted.
# Usage: bash tools/auth-harness/scan-evidence.sh [paths...]
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE=_bmad-output/initiative-church-app/epic-platform-baseline
EVIDENCE_DIRS=("$BASE/evidence-1.2" "$BASE/evidence-1.3")
paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=("${EVIDENCE_DIRS[@]}" tools/auth-harness)

patterns=(
  # JWT (header.payload.signature)
  'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{10,}'
  # Supabase publishable/secret keys
  'sb_(secret|publishable)_[A-Za-z0-9_-]{8,}'
  # Harness-generated passwords ('Hx!' + 24 base64url chars)
  'Hx![A-Za-z0-9_-]{16,}'
  # Story 1.3 member-held grant secrets and harness operator tokens
  'hg_[A-Za-z0-9_-]{20,}'
  'ho_[A-Za-z0-9_-]{20,}'
  # Undisclosed random password set by force-revoke reconciliation
  'Rv![A-Za-z0-9]{16,}'
  # Token values in URLs/fragments that are not redacted
  '[?&#](access_token|refresh_token|token|token_hash|code|provider_token)=(?!\[redacted\])[^&#\s"]+'
  # GoTrue email-link tokens (56 hex) and token hashes
  '\b[0-9a-f]{56}\b'
  # Secret-bearing JSON keys with a non-empty, unredacted string value
  '"(access_token|refresh_token|provider_token|provider_refresh_token|token|token_hash|otp|auth_code|password|new_password|nonce|apikey|authorization|confirmation_token|recovery_token|email_change_token_new|email_change_token_current|phone_change_token|reauthentication_token|grant|grant_secret|grant_digest|operator|operator_token)"\s*:\s*"(?!\[redacted\]")[^"]+"'
)

fail=0
for p in "${patterns[@]}"; do
  # Scenario lines that send deliberately invalid dummy values carry the marker
  # `# scan-evidence:allow` (a comment run-script.mjs strips); only those are skipped.
  if grep -rPn --exclude=scan-evidence.sh --exclude='*.test.mjs' --exclude='*.sql' -- "$p" "${paths[@]}" \
      | grep -vP '^[^:]*/scenarios/[^:]*:[0-9]+:.*# scan-evidence:allow'; then
    echo "scan-evidence: forbidden pattern found: $p" >&2
    fail=1
  fi
done
# Evidence masks owner-inbox addresses as …+bicauth-<tag>@gmail.com and scenario
# files use <inbox>+bicauth-<tag>@gmail.com; the full local part may appear only
# in harness code/usage docs, never in evidence or scenarios.
for EVIDENCE in "${EVIDENCE_DIRS[@]}" tools/auth-harness/scenarios; do
  if [ -d "$EVIDENCE" ] && grep -rPn -- '[A-Za-z0-9._-]+\+bicauth-[A-Za-z0-9-]*@' "$EVIDENCE"; then
    echo "scan-evidence: unmasked owner-inbox address in evidence" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "scan-evidence: clean (${paths[*]})"
exit "$fail"
