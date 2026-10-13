#!/usr/bin/env bash
# Fails if story 1.2/1.3 evidence (or harness sources) contain a usable credential:
# JWTs, Supabase keys, harness-generated passwords, link/OTP token values,
# hex link tokens, or any secret-bearing JSON key whose value is not redacted.
# Usage: bash tools/auth-harness/scan-evidence.sh [--personal-data] [paths...]
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE=_bmad-output/initiative-church-app/epic-platform-baseline
EVIDENCE_DIRS=("$BASE/evidence-1.2" "$BASE/evidence-1.3")
personal_data=false
paths=()
# Flags may come in any position; an unknown flag or a missing path is an error (exit 2), never
# a "clean" report (review 3.8-3.10, finding 13).
for arg in "$@"; do
  case "$arg" in
    --personal-data) personal_data=true ;;
    --) ;;
    -*) echo "scan-evidence: unknown option: $arg" >&2; exit 2 ;;
    *) paths+=("$arg") ;;
  esac
done
if [ ${#paths[@]} -eq 0 ]; then
  [ "$personal_data" = true ] && { echo "scan-evidence: --personal-data needs at least one path" >&2; exit 2; }
  paths=("${EVIDENCE_DIRS[@]}" tools/auth-harness)
fi
for path in "${paths[@]}"; do
  if [ ! -e "$path" ]; then
    echo "scan-evidence: no such path: $path" >&2
    exit 2
  fi
done

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
  # FCM registration tokens (<instance id>:APA91...) and the synthetic test device tokens (story 3.5)
  '[A-Za-z0-9_-]{20,}:APA91[A-Za-z0-9_-]*'
  '\bfcm-[A-Za-z0-9]{20,}'
  # GoTrue email-link tokens (56 hex) and token hashes
  '\b[0-9a-f]{56}\b'
  # Secret-bearing JSON keys with a non-empty, unredacted string value
  '"(access_token|refresh_token|provider_token|provider_refresh_token|token|token_hash|otp|auth_code|password|new_password|nonce|apikey|authorization|confirmation_token|recovery_token|email_change_token_new|email_change_token_current|phone_change_token|reauthentication_token|grant|grant_secret|grant_digest|operator|operator_token)"\s*:\s*"(?!\[redacted\]")[^"]+"'
)

fail=0
# Story 3.10 owner evidence must not contain personal identifiers. This is an
# opt-in check because the broader harness and runbooks intentionally include
# synthetic UUIDs, phones and example addresses.
if [ "$personal_data" = true ]; then
  allowed_words='(?:A|An|And|Android|Apple|Admin|Access|Account|Acceptance|All|Api|Apns|Browser|Build|Cells|Check|Checks|Chrome|Client|Clients|Cloud|Core|Count|Counts|Debug|Delivery|Design|Device|Devices|Direct|Contact|Edge|Evidence|Failed|Fake|Fcm|Firebase|Firefox|Flutter|Function|Functions|Gate|Google|Health|Hosted|In|Inbox|Ios|Item|Lifecycle|Local|Linux|Macos|Member|Members|Messaging|Mobile|Not|Notes|Notification|Notifications|Of|On|Out|Owner|Pass|Passed|Platform|Production|Push|Recorded|Redacted|Release|Reminder|Reminders|Result|Results|Review|Run|Safari|Scheduler|Settings|Sign|Signed|Snooze|Source|Staff|Staging|Status|Step|Story|Suite|Suites|Supabase|Synthetic|Test|Tests|The|This|To|Unavailable|Web|Windows|Witness|Worker)'
  personal_patterns=(
    # Canonical UUIDs (member/account/source/job/item/device identifiers).
    '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
    # E.164, also written with spaces, dots, dashes or brackets (+260 97 123 4567, +44 (0)7700 900800),
    # and common North American phone formats.
    '\+[1-9](?:[ .()-]{0,2}[0-9]){7,16}\b'
    '\b[2-9][0-9]{2}[-. ][2-9][0-9]{2}[-. ][0-9]{4}\b'
    '\([2-9][0-9]{2}\)[ .-]?[2-9][0-9]{2}[ .-][0-9]{4}\b'
    # Any ordinary number written in a labeled phone field.
    '(?i)\b(phone|telephone|mobile|cell)([ _-]+(number|no))?\s*[:=]\s*\+?[0-9][0-9 ()-]{5,}[0-9]'
    # Email addresses, including owner and member addresses.
    '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
    # Unlabeled names: two adjacent capitalized words unless both are known product, platform or
    # report vocabulary. A heuristic: add a word here only when it is not a personal name.
    "\\b(?:(?!${allowed_words}\\b)[A-Z][a-z'’-]+[ ][A-Z][a-z'’-]+|[A-Z][a-z'’-]+[ ](?!${allowed_words}\\b)[A-Z][a-z'’-]+)\\b"
    # Names in explicitly labeled identity fields.
    '(?i)\b(member|account|source|job|item|device|witness|recipient)([ _-]+(full[ _-]+)?name)?\s*[:=]\s*[A-Z][[:alpha:]’'"'"'-]+[[:space:]]+[A-Z][[:alpha:]’'"'"'-]+'
  )
  patterns+=("${personal_patterns[@]}")
fi

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
