# Story 3.10: closing acceptance and promotion

This evidence folder separates repository-verifiable checks from owner-witnessed hosted checks.
No staging or production deployment, device check, owner approval or production promotion is
claimed by the implementation session.

## Repository checks

Record command and result for the offline policy tests, environment checks, migration policy,
secret scan, notification E2E helper tests and Flutter checks. Raw scenario outputs belong in
`local/` only after passing `bash tools/auth-harness/scan-evidence.sh`.

| Check | Result | Evidence |
|---|---|---|
| Offline workflow and hosted SQL tests | Pass, 51 tests | `npm run ci:policy-test` |
| Environment policy | Pass | `npm run env:check` |
| Migration policy | Pass, 34 migrations checked | `npm run ci:migrations -- --base origin/main` |
| Repository secret scan | Pass, 1,434 files | `npm run ci:secrets` |
| Notification scenario helper and function tests | Pass, 107 tests | `node --test tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs` |
| Flutter analyze, tests and clean client builds | Not run | Flutter SDK is not installed in this environment |

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
