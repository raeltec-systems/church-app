# Admin onboarding: real backend integration checkpoint

Date: 31 October 2026. Status: **in progress; not accepted or deployed**.

## Source and authority

Israel copied and pushed the seven backend source drafts at `6c54f99d68d3147d7e97b50c476265d603fc9e36`. That checkpoint succeeded; it did not apply hosted SQL. Terminal access was available again in this continuation.

The runtime correction and final database/HTTP source is `1a449aca8c6bdf8367421efa5292d35224b71526`. This evidence commit also carries two tooling-only changes: CRLF-aware parsing in the existing recovery scenario test, and additional content-free error diagnostics in the new HTTP rehearsal. Neither changes the app, runtime SQL, authentication authority or design system. Their exact normalized source hashes appear in `offline-windows-rerun.json`.

Saved intermediate checkpoints: `d799fb32674e90bbc56790313fa78405babe5417` fixes exact test inventories/fixtures; `9585c24043e5c0696e99ecfd151fe095a3aa4a4d` adds the real HTTP runner, completion tests and Edge configuration; `1a449ac` fixes the existing-account refusal defect. No historical migration was edited: both new migrations are unmerged feature drafts, not hosted migrations.

## Actual verified outcomes

| Check | Source and result | Evidence |
| --- | --- | --- |
| Full isolated PostgreSQL suite | `1a449ac`: **5,937 passed across 76 files** | `database-1a449ac.log`, `local-ledger-node24.json` |
| Real new-account commissioning | `1a449ac`: **22/22 passed**, actual Edge/GoTrue/PostgREST/SQL, closed public signup | `new-account-node24.jsonl` |
| Real existing-account commissioning | `1a449ac`: **25/25 passed**, existing account/password retained | `existing-account-node24.jsonl` |
| Full GitHub CI | `1a449ac`: **all four jobs succeeded**, run **41209198724** | `ci-1a449ac.json` |
| Linux CI offline suites | `1a449ac`: **489/489**, zero skips, Node **22.23.4** | `ci-offline-summary.log` |
| Windows offline suites after CRLF correction | Runtime parent `1a449ac` plus the two hash-recorded tooling changes: **489/489**, zero skips, Node **22.16.0** | `offline-windows-crlf-fixed.log`, `offline-windows-rerun.json` |
| New onboarding/target-guard unit tests | `1a449ac`: **53/53**, included in the 489, not additional user journeys | `new-offline-suites-node22.log` |
| TypeScript contracts | Node22.16 with explicit type stripping: **267/267** | `ts-node22-explicit-strip.log` |
| Additional Node22 real new-account run | `1a449ac` runtime plus safe-error-diagnostics-only runner change: **22/22** | `http-node22-diagnostic.jsonl` |

The first local full suite and the two clean `1a449ac` HTTP runs used the machine's global Node **24.22.0** to drive the pinned Supabase **2.119.0** CLI. CI uses Node22. Node22.16 was subsequently run from a separately downloaded, official-checksum-verified temporary binary, without changing global Node. The ledgers preserve this distinction instead of presenting all executions as one toolchain. PostgreSQL tests are run by the same pinned CLI/local stack.

Both HTTP scenarios use the same request ID for their two concurrent submissions. They prove duplicate-request concurrency, not every distinct-request or conflicting-payload race. The response may be pending or completed, but the final status and database must show exactly one account/member/link/Admin. The new-account run observed completed plus pending; the existing-account run observed completed plus completed with one grant.

The tests then use ordinary phone/password sign-in and current-authority APIs to create an accountless member, correct a name and labelled contact, replay once, reject a stale edit, read safe activity, deactivate/filter the member, reject guests/non-Admins and deny a held Admin. Contact correction does not alter Auth credentials. Public setup replies do not return a session. Existing-account setup revokes earlier sessions and never resets the password. Service-log/public-response scans found none of the run's invitation, digest, password or server-key values.

These are **real backend HTTP journeys, not a witnessed browser or phone UI pilot**. No new management UI was implemented in this continuation. The existing Vercel site and published APK remain unchanged.

## Defect reproduced and corrected

An existing account with a valid fresh password session could become ineligible after its invitation, for example through an unverified recovery-email change. SQL correctly refused the grant, but left the invitation in `provisioning` and incorrectly demanded provider reconciliation even though this path never makes an external account-creation call. A fresh retry stayed pending indefinitely.

`admin_onboarding_existing_test.sql` reproduced **8 failures out of 15 checks** before the correction. The corrected path clears the temporary request/proof correlation and submitted name, records `completion_refused`, restores the invitation to `issued`, and still returns refusal. Only a deliberate retry with fresh valid proof can complete it. It does not relax account eligibility or reopen an already commissioned installation. The uncertain **new-account** provider fence is unchanged.

The three focused commissioning suites subsequently passed **81/81**; the clean full suite at `1a449ac` includes them. Evidence: `existing-refusal-before-fix.log`, `existing-refusal-after-fix.log`, `database-1a449ac.log`.

## Original failures remain visible

- The first CI/local run at `6c54f99` applied the migrations but failed four test files. The onboarding test had omitted its transaction-scoped local marker; the database correctly defaulted to production. Three older exact inventories lacked the intended new checked APIs/system command or assumed only one non-retaining command. The correction adds only exact expected entries, asserts the production default first, and leaves runtime permissions unchanged. The four affected files then passed **324** checks. Evidence: `original-6c54f99-db-failure.log`, `integration-fixtures-rerun.log`.
- One earlier clean-checkout existing-account run at `9585c24` aborted after fixture issuance; only three checks including cleanup completed. Its apparent `3/3` was not a completed journey. A later Node22 run also aborted at the start of actual HTTP work. Both are retained as **incomplete/failed**. The underlying transient failure was not reproduced or conclusively diagnosed. The runner now records a failed scenario with phase and safe error codes; subsequent complete Node24 and Node22 runs passed. Evidence: `incomplete-existing-run-9585c24.log`, `http-new-node22.log`, and the complete rerun files.
- Windows initially passed **488/489** offline tests. An existing scenario test split on LF and attempted to strip comments before removing the CR; a comment-only line became a fake `#` command. Splitting CRLF correctly fixes the parser without changing any permitted-command/account/secret assertion. The full rerun passed **489/489**. The original failure is preserved in `offline-windows-node22.log`.
- Node22.16's first plain TypeScript invocation did not support the file extension under that invocation. The explicit `--experimental-strip-types` rerun passed all 267; CI's Node22.23.4 passed its normal repository command. Both results are retained.

## Isolation, cleanup and evidence handling

Dedicated project: `church-admin-backend-20261031`, API 56421, DB 56422; separate disposable worktree. The owner's shared `church-app` project was not reset or stopped. Every complete HTTP scenario asserts empty Auth/member stores after its own local reset, removes its captured Edge container and deletes its temporary credential file. The phone switch is restored separately. `cleanup-observation.json` records the final dedicated-stack stop and shared database observation.

`isolated-config.toml` is the test-only config: public signup disabled, separate ports/project, no real credentials. The actual SQL/Edge source is from the feature branch. Supabase start/status output and environment-secret files are **not** included. Captured text is normalized to UTF-8/LF with trailing whitespace trimmed; `artifact-manifest.json` records raw and published hashes. Logs with an incomplete execution are not relabelled after a successful rerun.

The credential-dependent staging-drift CI step can skip internally. These new migrations remain **unpromoted**; this checkpoint makes no new hosted-history parity claim and does not repeat the earlier 101-migration history repair.

## Unfinished implementation

1. Complete secure operator CLI and controlled recovery/cleanup when new-account provider creation remains uncertain with no account visible. Expired/unclaimed/orphan cleanup also remains unfinished. Current reissue stays deliberately fenced; direct table edits are not an approved workaround.
2. Normal staff UI for the new all-status/role-filtered directory, profile/contact correction, administrative activity and selected-person continuity through recovery/lifecycle queues. The current Users & access workspace still opens the earlier screens.

## Unverified/review work

Authenticated browser/device onboarding and management walkthroughs; full distinct-request/provider-fault/expiry matrix; complete new-enrollment deletion/restore coverage; independent security review; owner acceptance and candidate-specific rollout. Historical restore regression success is not proof of every new enrollment recovery scenario.

The approved BMAD plan remains **in-progress**, with its matrix audit open. Epic 6 acceptance/release and Epic 7 implementation status are unchanged. No hosted SQL, real user account, policy approval, notification, merge or deployment occurred.

Repeat commands and precautions: [verification runbook](../../../docs/runbooks/admin-onboarding-verification.md).
