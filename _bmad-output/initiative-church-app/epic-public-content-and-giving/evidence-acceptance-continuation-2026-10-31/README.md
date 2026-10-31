# Epic 6 acceptance continuation ? 31 October 2026

## Outcome and scope

This continuation materially advances 6.15 and 6.17, but **does not complete either human-in-the-loop story**. Canonical 6.15 remains `in-progress`; 6.17 remains `planned`, dependent on 6.15, 6.16 and 5.12. These states are intentional. The owner has not yet supplied the witnessed staging/device walkthrough or production-promotion decision required by the tickets.

No application screen, design token, business rule, SQL migration or dependency lock changed. No production or hosted staging mutation, merge, real notification, payment, content publication or owner acceptance occurred. Synthetic content was created and removed only in the disposable local test project.

## Exact source checkpoints

| SHA | Change |
| --- | --- |
| `a0c842c48fe96f19e3b52a5a77fd85af2ea58215` | Starting acceptance branch; migration-history metadata closure already recorded. |
| `7e8b556177029adce3184ff0fe52355ce291261b` | Bind local test SQL, API and Edge cleanup to the exact configured project. |
| `ed73982483c45b67894f8fb0722d8ea0df4d60a5` | Add actual PostgreSQL sermon-lock contention scenarios. Initial reassignment fixture failed. |
| `c3b633ddc23bf65776cb52d978b2b6654cb930e8` | Correct the fixture to the existing single-duty `member_id` reassignment contract. All four actual races passed. |
| `8ed2387e67564469c4e6ddb04773f752e3c5e1a7` | Make the existing full deletion test launch the pinned CLI on Windows; use a unique owned restore container, not a shared fixed name. |

Subsequent evidence/runbook edits are documentation only. Read their exact-head CI separately; do not relabel a preceding checkpoint's run as a later-head pass.

## What was proved

| Check | Executed result | Boundary |
| --- | --- | --- |
| Full local database suite | **72 files / 5,841 tests passed** on `7e8b556` | Fresh replay in the isolated local project, not current hosted schema parity. |
| G1 real RSVP/Storage integration | **13/13 passed** on `7e8b556` | Real Auth, HTTP, capacity races and Storage. First race: one winner/four Full; second: one winner/three Full. No normal-UI or device claim. |
| G2 scheduled private-asset cleanup | **6/6 passed** on `7e8b556` | Real scheduler/worker/Storage, with old unreferenced files removed and recent/referenced files retained. No announcement delivery. |
| Sermon-from-duty integration and actual lock contention | **13/13 passed** on `c3b633d`, including four new actual races | Independent transactions and actual PostgreSQL advisory-lock waiters; no function replacement or injected stale-read substitute. |
| Dart VM contracts | Initial **283/284**, then **284/284 passed** after restoring committed LF working-tree bytes | Original failed log preserved by hash; no fixture-content change. Retry head `8ed2387`. |
| Dart browser contracts | **283/283 passed** | Chrome compiler/browser model, not mobile OS behavior. |
| Design-system, client-core, mobile, staff, staff-trial tests | **20 / 1,169 / 115 / 63 / 35 passed** | Widget/unit suites. Not signed-in cross-client acceptance. |
| Locked dependencies and analysis | All six package/app dependency and analysis steps passed | Original Flutter ledger has 19 steps, 18 passed and one failed VM test; the separate VM retry resolves only that failure. |
| Actual local staff web build | Passed, configured for the isolated backend with the client publishable key only | No fake authentication. No Android/iOS release-binary or signing claim. |
| Signed-out real staff browser | Landing view rendered; no page errors | Not a signed-in journey; no owner or native-device acceptance. |

The G1/G2 JSONL records and the shell ledger carry different reported clock times. They are retained as returned, not merged into an invented precise chronology or duration. Their test results, target, commands and source checkpoints are separately recorded.

The full identity-deletion rehearsal and final CI observations are recorded in [final-observations.md](final-observations.md), including failed attempts. A passing deletion worker fixture would not by itself prove every populated Content store and every normal-UI journey in one combined scenario.

## Actual sermon race evidence

`sermon-lock-retry.jsonl` records:

- **DL11:** old assignee waits, the manager reassigns through the real HTTP command, one waiter remains blocked after commit, old sender receives `not_found`, new assignee creates exactly one private draft.
- **DL12:** cancellation commits during the wait; old sender and subsequent manager request receive `not_found`; no draft is created.
- **DL13:** deputy scope is revoked while the send waits; the stale token is refused and the current assignee can create one private draft.
- **DL14:** two authorised HTTP requests are actually waiting on the same lock; after release they return the same draft, with exactly one `created=true` and one `created=false`.

The existing publishing/privacy cases also pass. Cleanup reports zero fixture users, members, departments and sermons. These observations close the **local backend contention evidence gap**, not the separate normal-UI multi-session demonstration or deployed-target parity.

## Execution isolation and safety fix

The original workstation checkout had substantial unrelated uncommitted deletions and a running `church-app` stack. It was not reset, switched or edited. Work was done in a separate worktree on the existing acceptance branch.

Investigation found that the old HTTP helpers used the selected CLI project, while SQL could select `supabase_db_church-app` or simply the first database container. That made a second project unsafe. The correction checks the local Docker transport, configured project, exact container name, Supabase project label, network, mapped API/database ports and immutable container ID. Missing/mismatched targets fail closed. Legacy default-origin guards were not relaxed to permit hosted targets.

Temporary local config: project `church-content-acceptance-20261031`, API **55421**, database **55422**, shadow **55420**, Studio **55423**, mail **55424**, analytics **55427**, pooler **55429**, inspector **8183**. These edits were not committed to `supabase/config.toml`; original and temporary hashes are in `config-delta.json`. The mail service must be present for the full deletion runner's actual email-change/one-time-token fixture. All mail is captured locally, never sent through an external provider.

The new target helper has **23 pure tests**; the focused target plus deletion-helper run passed **25/25**. The initial broader target/harness run and all safe original log hashes are listed in `artifact-manifest.json`.

## Reproduce the engineering checks

Use the repository's pinned **Node 22**, **Flutter 3.47.6 / Dart 3.13.5**, locked **Supabase CLI 2.119.0**, a clean disposable local stack, Docker Linux, and Chrome. Do not run resets or these synthetic fixture runners against staging or the user's shared local stack. The helpers expect the project/ports in the current `supabase/config.toml`; configure a unique local project first if another stack exists. Keep every local port change consistent.

```bash
npm ci
node node_modules/supabase/dist/supabase.js start
node node_modules/supabase/dist/supabase.js test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-event-rsvp.mjs --evidence <private-output>/rsvp.jsonl
node tools/identity-e2e/content-retention.mjs --evidence <private-output>/retention.jsonl
node tools/identity-e2e/content-sermon-duty-drafts.mjs --contention --evidence <private-output>/sermon-lock.jsonl
node tools/identity-e2e/deletion.mjs --evidence <private-output>/deletion.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

Replace `<private-output>` with an actual private directory. Always turn the local phone switch off after an interruption. Deletion requires its own clean fixture state and a fresh private recovery-journal directory; preserve the append-only journal when analysing a run, and never reuse real contacts. Run these before creating persistent owner pilot accounts.

For each Flutter package, the exact commands and exits are in `flutter-ledger.jsonl`; tests used `--concurrency=2`. The corrected Dart VM rerun is separate. Actual Linux non-Lusaka timezone checks belong to the exact-head CI, not a Windows `TZ` approximation.

## Failures retained, not hidden

Read `failures-and-limits.json`. The Windows offline retry is **433/436**, with three scanner tests unable to launch their `/C:/...` Bash path. The Windows policy retry is **55/56**, with the POSIX 0600 file-mode assertion unsupported by the observed Windows mode representation. These suites are not labelled passed. No test was disabled or made less strict. The evidence publication scan itself was run with the installed Git Bash executable and correct relative script path; that does not rewrite the failed unit-test launch observations.

The first sermon reassignment fixture failure, deletion `npx` launch failure, mail-disabled deletion failure, later retries and the Dart line-ending failure retain separate evidence. The blocked signed-in browser command was not retried through another route. No credentials, local keys, passwords, session state or raw SQL output are included in this package. Raw private logs remain on the workstation with their hashes; this is not a backup of secret-bearing local CLI output.

## Owner and release gates still open

The [owner closeout checklist](../../../../docs/runbooks/content-acceptance-closeout.md) points to the existing 19-step normal-app walkthrough and records the remaining decisions. Outstanding: signed-in role matrix and persistence/recovery, witnessed Android/iOS playback and dialler return, offline cold restart, explicitly authorised push, hymn 25/29/30 printed-source review, disposition of known product limitations, broader current staging schema/Function/build parity, predecessor production verification, independent review and explicit promotion approval.

BMAD quick review was rendered and its current continuation diff and commit claims staged outside the repository. Step 1's confirmation checkpoint was not passed; no independent lenses ran for this continuation. Historical quick-review metadata in the 6.15 plan does not cover these new changes. No independent reviewer is claimed.

**6.15 is not done. 6.17 is not done.** Tests are evidence toward acceptance, not a substitute for the owner-observed outcomes or the required controlled production promotion.

## Subsequent resumed checkpoint

See [resumed-validation.md](resumed-validation.md) for the passing 436/436 native Windows and Linux offline reruns, 56/56 Linux policy tests, 267/267 TypeScript contracts, immutable migration verification and corrected publication hashes. The historical failed Windows runs above remain separate. Fresh read-only staging Edge metadata is retained in `staging-edge-metadata-observation.json`; full deployed parity is not claimed.
