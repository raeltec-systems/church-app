# Story 3.10: closing acceptance and promotion

This evidence folder separates repository-verifiable checks from owner-witnessed hosted checks.
No staging or production deployment, device check, owner approval or production promotion is
claimed by the implementation session.

## Repository checks

Record command and result for the offline policy tests, environment checks, migration policy,
secret scan, notification E2E helper tests and Flutter checks. Raw scenario outputs belong in
`local/` only after passing `bash tools/auth-harness/scan-evidence.sh`.
Story 3.10 release evidence also uses `--personal-data` to reject identifiers and contact details.

| Check | Result | Evidence |
|---|---|---|
| Offline workflow and hosted SQL tests | Pass, 51 tests | `npm run ci:policy-test` |
| Environment policy | Pass | `npm run env:check` |
| Migration policy | Pass, 34 migrations checked | `npm run ci:migrations -- --base origin/main` |
| Repository secret scan | Pass, 1,437 files | `npm run ci:secrets` |
| Notification scenario helper and function tests | Pass, 107 tests | `node --test tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs` |
| Client Core analyze and tests | Pass, 427 tests | Flutter 3.47.6 |
| Mobile analyze and tests | Pass, 44 tests | Flutter 3.47.6 |
| Mobile Android debug APK | Not run | Android SDK is not installed; mobile has no web target |
| Staff analyze and tests | Pass, 31 tests | Flutter 3.47.6 |
| Clean staff web release build | Pass | Flutter 3.47.6; built from a clean package directory |
| Local Supabase reset and live E2E | Blocked | Startup fails in the Realtime migration with a Postgres connection-pool timeout; no staging/production run was attempted |

## Owner-witnessed staging checks

Use the sequence in `docs/runbooks/notifications.md`, Story 3.10. Keep this table redacted: record
status, coarse time, platform/build version and fixed counts or outcome codes only. Do not add
member, account, source, job, item or device identifiers; names, numbers, URLs, keys, credentials,
message content or screenshots with personal values.

| Check | Result | Witness class | Notes |
|---|---|---|---|
| Staging mobile clean build | Not witnessed | — | Owner action required |
| Staging staff clean web build | Not witnessed | — | Owner action required |
| A/B isolation and signed-out behavior | Not witnessed | — | Owner action required |
| Reminder lifecycle, duplicate rerun and independent rerun | Not witnessed | — | Owner action required |
| Closed-app scheduler delivery and retry recovery | Not witnessed | — | Owner action required |
| Health projection: fresh, failed, recovered, redacted | Not witnessed | — | Owner action required |
| Real-device push checks | Unavailable | — | Requires owner Firebase/APNs and device setup |

## Production gates

Production project and project ref, protected environment, Q2 church-time, `ops_system_access` and
Q12 approvals, worker credential and Edge secrets, Firebase/APNs credentials, Q12 lateness
tolerance and witness record remain pending owner action. Scheduler, push, outbound sending and
alerting are required to remain disabled until separately approved.
This story does not attest production promotion or activation.
