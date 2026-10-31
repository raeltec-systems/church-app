# Admin onboarding / Users & access: partial implementation evidence

Observed 31 October 2026. **Status: in progress, not a completed onboarding or management feature.**
Final tested source: `5d8a3444b2d3e8a29f1304d35f90dbbdda5cf5a4`. Branch: `feature/admin-onboarding-user-management`. Draft PR #8 is stacked on the acceptance branch, not merged into it or main.

## Useful client work delivered in source

The staff landing page now reaches an owner-invitation setup screen. The client has real composition/HTTP adapter wiring, strict response decoding, bounded no-redirect POSTs, private in-memory state, notice acknowledgement, new/existing-account forms and status-only recovery after uncertain submissions or reload. It does not auto-sign in or pretend an unavailable server granted Admin.

The **Users & access** entry opens the existing server-backed membership and access workflows in one workspace. Its selected-person panel retains real target-specific grant/hold/deactivate/unlink commands. Existing routes remain compatible; current-role denials and observed revocation clear controls and private cached state. No existing permission rule, schema migration, design token or dependency lock changed.

**The new commissioning endpoint is NOT implemented.** The installation invite issuance/revocation and privileged backend, all-status/role-filtered directory, profile/contact edits, activity viewer and full selected-person cross-queue continuation remain unfinished. See [continuation.md](continuation.md) and [client-protocol.md](client-protocol.md). These are not renamed as manual-test limitations. The hosted Vercel site and distributed APK remain the older candidate.

## Executed verification

| Check | Result | Source / evidence boundary |
| --- | --- | --- |
| Final core analysis and full tests | Clean; **1,218 passed** | Exact `5d8a344`; `final-client-ledger.json`, two final-core logs. |
| Final staff analysis and full tests | Clean; **68 passed** | Exact `5d8a344`; includes five new normal-router widget journeys. |
| New onboarding / workspace tests | **49 passed** | Included in core count, not additional accepted workflows; fake HTTP/ports. |
| Final staff web build | Passed | Exact `5d8a344`, unconfigured client compile, not deployed. |
| Final Android debug build | Passed | Exact `5d8a344`, no real backend/push defines, not installed/distributed; not release signing. |
| Mobile / design / trial suites | **115 / 20 / 35 passed** | Earlier recorded heads in `client-check-ledger.json`; relevant source subtrees unchanged, see `unchanged-suite-trees.json`. Shared-core final regression is separately executed above. |
| Dart VM / Chrome contracts | **284 / 283 passed** | Correct `dart test` / `dart test -p chrome` reruns at `5d8a344`. |
| TypeScript contracts | **267 passed** | Recorded final-source supporting command. |
| Linux offline / POSIX policy | **436 / 56 passed**, zero skips | Network-disabled Docker, repository read-only, source `71363c1`; no database touched. |
| Environment/import/migration/secret checks | Passed | Environment separation retained; **101 unchanged migrations**, zero new. No current hosted drift claim. |
| Web bundle secret scan | Passed | Final rebuilt outputs: **92 files clean**; see `final-bundle-scan.json`. |

Final ledger records start/end SHA and source-stability checks for every final command. Earlier runs are not relabelled as final-head evidence. Test counts overlap. The first staff run included a newly authored test file before its commit; its initial source label is not a clean-tree artifact attestation. It is superseded by the clean-source final rerun. The earlier Android build overlapped a later label-only source change; use the final stable-source build instead.

## Retained failures and corrections

- Early analysis found a misspelled recovery-screen class and missing braces; corrected, then final analysis clean.
- Initial workspace tests exposed a 27px overflow at 390px/200% text and a never-resolved fake roster. Removed the duplicate sticky header and supplied the intended fake response; assertions retained. `new-clients-third.log` remains failed; `new-clients-fourth.log` passed 49/49.
- The initial staff keyboard test expected **Members** as the first People destination. The new destination is **Users & access**. Updated the exact destination/focus assertion and retained the old Members route check; final 68/68 passed.
- The broad runner incorrectly invoked Flutter for the pure-Dart contract package. Both failures remain. Correct repository commands (`dart pub get --enforce-lockfile`, `dart analyze --fatal-infos`, `dart test`, `dart test -p chrome`) all exited zero; no test or fixture was weakened.
- Android/web toolchain warnings remain in their build logs. Build success does not resolve production signing, device playback, push or screen-reader acceptance.

## Visual inspection

The four screenshots are **actual widget renders with synthetic test responses and bundled design fonts**, not browser, hosted backend or physical-device evidence. Desktop table/selected-person panel retains the approved navy sidebar, light canvas and role/status styling. At 390px and 200% text the setup fields/actions remain usable; shorter setup labels remove the truncation found in the earlier render. Screenshots may show a scrolled viewport and test debug ribbon. No design-system token or font asset changed.

- [Setup desktop](screenshots/setup-desktop.png)
- [Setup narrow / large text](screenshots/setup-narrow-large-text.png)
- [Selected-person workspace](screenshots/users-selected-person.png)
- [Workspace narrow / large text](screenshots/users-narrow-large-text.png)

## CI observation

Run **41197732871**, head `5d8a3444b2d3e8a29f1304d35f90dbbdda5cf5a4`, was **completed / success** at this capture. All four jobs completed successfully: offline harness/functions, policy, database/API/isolated restore, and Flutter analyses/tests/builds. Full metadata is in `ci-5d8a344-observation.json`. These results belong to this code SHA, not a later evidence-only commit. The credential-dependent staging-drift step can skip internally. Its green job is not evidence of current hosted parity. No new onboarding backend test exists to be passed by this CI.

## Integrity and boundaries

`artifact-manifest.json` preserves original log hashes and exact published-byte hashes. Only encoding/line endings/trailing whitespace were normalized for Git; outcomes and original failed attempts remain. No credential, real-member fixture or invitation secret was created for these tests.

BMAD approval is recorded; the plan remains `in-progress`. No independent reviewer, first real Admin creation, hosted mutation, merge, deployment, notification send, policy activation or acceptance completion is claimed. The user-directed manual migration-file preparation is explained in `continuation.md`; no SQL is ready for hosted application yet.
