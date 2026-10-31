# Epic 6 acceptance reconciliation — 30 October 2026

**Engineering evidence and owner preparation are updated. Epic 6 acceptance is still open.**
The feature work on main has backend, shared-client and staff/mobile implementations, but
neither automated results nor this document establish that the owner has witnessed the
required ministry workflows. Staging also has a confirmed migration-history blocker.

This work began from fresh main `c96cd562b2650c37f5d3d879cb12891419700139`, tree
`6f7a62d931683c680cbb0bafb3fa52e12b912621`, on
`acceptance/epic-6-reconcile-epic-7-plan`. The review is
[draft PR #7](https://github.com/raeltec-systems/church-app/pull/7). Commits and pushes are
authorized. No production deployment, merge, policy approval, content publication,
notification send, migration repair or acceptance completion was performed.

## What changed and why

The old handoff and promotion documents mixed pre-merge instructions, superseded audio
scope, older staging observations and a partial migration inventory. They now distinguish
dated evidence from current state and link to the runnable owner procedure. The inventory
covers all **101** tracked migrations, including cross-epic fixes. The old pending `_rows`
instructions are replaced with fresh read-only verification and a separately reviewable
history-repair proposal.

The [owner walkthrough](../../../docs/runbooks/content-owner-walkthrough.md) provides a
coherent fictional set of people, roles, sermons, events and giving data, then tests useful
outcomes from normal navigation. It includes permissions, independent role combinations,
failed/uncertain requests, stale sessions, cross-client persistence, offline relaunch,
external handoffs and real concurrent sessions. Its cases are **authored only** until
someone executes them and records actual evidence. Written procedures do not count as a pilot.

The current app READMEs now point to that procedure. The original story 1.7 shell/browser
smoke documentation is labelled historical because its signed-out tracer navigation no
longer describes the app. The Cells owner-contract document assigns attendance to Epic 7
and recaps to Epic 8, matching the initiative.

The approved design primitives, runtime sources, backend migrations, dependency locks and
public APIs are unchanged by this reconciliation. Source review did not establish a new
required backend fix that can safely be substituted for the open acceptance work. Known
functional limitations are explicit below; none is disguised as a missing test or silently
accepted. Historical resolved findings F1, F3, F8, C1 and C2 are not reopened merely because
their original report remains in the repository.

## Acceptance state and sequencing

| Work | Current evidence/state | Remaining boundary |
| --- | --- | --- |
| 6.1–6.14, 6.18, 6.19 and F1–F3 implementation | Merged main; plans report built; current automated evidence below | Demonstrate applicable integrated member/leader outcomes; resolve or explicitly accept listed limitations. |
| 6.16 refactor sweep | Already built; owner permitted it before the pilot | No repeat cleanup or absorption of missing behavior. |
| 6.15 runbooks and synthetic owner pilot | Plan is **in-progress**; docs, fixtures, evidence and device procedures prepared | Owner/device pilot, outcome evidence and unresolved policy/source checks. |
| 6.17 integrated verification and promotion | Remains **planned**, with this release preparation available | 6.15, exact candidate/target evidence, prior Cells promotion 5.12, required gates, explicit owner release approval and post-deployment verification. |
| Epic 7 | Separate **unapproved inception proposal** | Review the complete proposed set and its owner decisions before canonical tickets or implementation. |

The Epic 6 ticket file now reflects the recorded exception: 6.16 precedes 6.15; 6.15
depends on it; 6.17 depends on both and 5.12. Stable IDs and human checkpoints are preserved.
No story is marked built/done by preparing this package. Epic 7 planning does not imply
Epic 6 acceptance or introduce a whole-Epic-6 implementation dependency.

## Fresh checks this environment supports

The full [validation ledger](evidence-reconciliation-2026-10-30/validation-ledger.md) and
[machine-readable records](evidence-reconciliation-2026-10-30/validation-ledger.json)
provide commands, working directories, full commit IDs, toolchains, UTC times, actual
exits, final markers and complete logs. Runtime source and configuration match the
inspected main; documentation changes are identified separately.

| Check family | Complete result |
| --- | --- |
| Policy / TypeScript contracts / offline harness and Function units | 56 / 267 / 410 passed |
| Dart contracts on VM and Chrome | 284 / 283 passed |
| Design system / full client core / mobile | 20 / 1,169 / 115 passed |
| Staff / staff framework trial | 63 / 35 passed |
| Alternate-timezone duties / follow-ups | 224 / 37 passed under `America/New_York` |
| Dependencies and analysis | Existing locks enforced; all six package/app analyses clean |
| Build and repository checks | Both web builds complete; environment, migration policy, import boundary, secret and evidence checks passed |
| Bundle scan | 91 generated files clean; builds were not deployed |
| Current staff browser smoke | 17/17 at desktop and 390 px, with screenshots; signed-out UI only, zero backend requests |

Counts overlap across subsets and platforms and must not be summed into accepted
workflows. An interrupted first core/build attempt lacked final success markers despite
an exit 0; it remains marked incomplete. The full core suite and staff build were rerun
successfully with reduced concurrency/sequential execution. Original logs are preserved,
with deterministic gzip and SHA-256 metadata for the large core log. A Cupertino font
warning remains recorded; no missing-icon defect was demonstrated.

[Hosted main CI run 40733936249](https://github.com/raeltec-systems/church-app/actions/runs/40733936249)
passed all four jobs, including database/restore work unavailable in this workspace.
Its policy log explicitly **skipped staging drift because the access token was absent**.
This is historical evidence for that exact source commit. PR CI is additional
candidate-specific evidence; neither run is a witnessed app/device pilot or target parity.

The branch checkpoint `c655dac95766011a22e3f6eb6cff674af2396b13` also produced fresh hosted
database evidence: **72 pgTAP files / 5,841 tests**, Data API smoke and the isolated
database/object restore steps all succeeded. At capture, GitHub still labelled the overall
run and two jobs in progress despite successful listed steps, so the
[checkpoint summary](evidence-reconciliation-2026-10-30/hosted-checkpoint-ci-summary.json)
does not claim a completed green run. Inspect the PR's exact final head and workflow status
before any release decision; its staging drift step still skips without the management token.

The [actual staff browser smoke](evidence-reconciliation-2026-10-30/staff-signed-out-browser/README.md)
exercised landing, keyboard navigation, local empty-field errors and recovery, password
visibility, help/recovery entry, Back, reload and a 390 px layout. Seventeen checks passed;
root also inspected the landing and desktop/narrow sign-in images. There were no page
errors, staging API requests or mutation attempts. This is meaningful current UI evidence;
it does not verify sign-in, authenticated permissions, recovery delivery or native devices.

## Fresh staging observations and release blocker

At **19:48:59 UTC / 21:48:59 Africa/Lusaka on 30 October**, connected read-only inspection
of `bic-kafue-platform-test` / `tmurpotfluignacfueki` found:

| Observation | Result and implication |
| --- | --- |
| Migration history | **99/101**, with exactly `20261027140200` and `20261027182300` absent; no unexpected versions. |
| Installed purge helpers | Both real bodies match repository after CRLF normalization; neither missing-rows stub remains. |
| Helper access | Invoker functions, empty search path; `anon`, `authenticated`, `service_role` cannot execute them. |
| Boundary guards | Zero violations and zero unowned objects at this observation. |
| Edge metadata | `content-assets` ACTIVE v4; `notifications-worker` ACTIVE v10; metadata does not prove deployed source-byte equality. |
| Required drift check | Actual repository checker against captured history **failed, exit 1**, identifying the two missing versions. |

Evidence: [staging-read-only.json](evidence-reconciliation-2026-10-30/staging-read-only.json),
[captured history](evidence-reconciliation-2026-10-30/staging-migration-history.json),
[drift output](evidence-reconciliation-2026-10-30/staging-drift-check.log).
**Matching bodies do not mean synchronized migration history.** Do not replay either SQL
file or assert zero drift. The [concrete history-repair proposal](../../../docs/runbooks/content-staging-history-reconciliation.md)
requires owner approval, fresh full-effect comparison and successful after-checks. No repair
was performed. Production has not been inspected.

At **19:59:33 UTC**, a separate signed-out HTTP probe passed **15/15 read checks**, using
only the staging publishable key. Events/banners returned valid public projections;
giving, sermon, announcement and Sunday-list empty states were valid; unknown records
returned null. WEB exposed 66 books, 1,189 chapter references and offline clearance;
Genesis 1, John 5 and Revelation 22 returned chapter/verse shapes. The evidence retains
counts and schema observations, never keys, record IDs or text. This proves those reads
at that time, not all verses, permissions for signed-in users, video playback or the UI.
See [staging-public-reads.json](evidence-reconciliation-2026-10-30/staging-public-reads.json)
and the adjacent reproducible probe.

## Useful workflows and the evidence still needed

| Person and useful result | Present implementation/evidence | Remaining realistic proof |
| --- | --- | --- |
| Guest discovers content through Home/search and reads Bible/hymns | Public adapters, screens, fixtures and fresh signed-out reads; bundled hymn book | Normal navigation with meaningful content, display/download rights refusal, offline cold restart and reconnect recovery. |
| Media prepares, publishes, replaces and withdraws content | Revisioned commands, role checks, rights/assets and staff screens; regression coverage | Two editors, stale save, failed upload/sync, withdrawn cache, actual church-owned/third-party rights cases. |
| Member saves favourites and reads Sunday hymns | Member-only favourites and current Sunday publication paths | Cross-session/server persistence, scoped worship editor, guest/Pending denial, printed-source review for hymns 25/29/30. |
| Member attends an event | Capacity RSVP, own response, calendar export and lifecycle release | Two real clients racing the last place, cancel/retry/restart, multi-day calendar import and attendee-name privacy. |
| Member/leader sees own work | Own duties/My cell overlays, event review flags and preaching draft integration | Cross-client current-role denials, event mismatch approval, no silent duty reschedule, actual blocked sermon-send session. |
| Admin publishes verified giving instructions | Two-person validation and 14-day independent Admin tenure; safe external handoff | SAMPLE-only local proof, real destination/provider checks by owner, recent/self-verifier denial, unsafe hiding and device handoff without a false payment claim. |
| Member receives an optional announcement | Generic source-based notification implementation | Explicitly authorized isolated recipient/provider/device check; no notification was sent by this run. |

The [walkthrough](../../../docs/runbooks/content-owner-walkthrough.md) supplies exact
roles, setup, actions, expected outcomes, failures/recovery and evidence for each row.
Use the result template for actual results. A screenshot of a successful screen without
the linked persistence/permission result is insufficient for the corresponding journey.

## Unfinished capability and known behavior requiring disposition

These are statements about implemented behavior, **not environmental test limitations**.
They remain visible for owner acceptance; this reconciliation neither broadens permissions
nor silently treats an agent's prior deferral as an owner decision.

| Known behavior | User consequence | Required disposition |
| --- | --- | --- |
| An event organiser must hold Media, Pastor or Admin; a ministry leader without an editor role is unsupported | That leader cannot manage the attendee-name view solely as an organiser | Decide whether existing editor-only organiser scope meets the intended workflow; a broader role needs an explicit permission design/build. |
| RSVP cancellation is unavailable while RSVP is disabled | A member cannot cancel via that control in that state | Review against the approved event operating policy; if cancellation must remain available, record/build the change before acceptance. |
| Event linking is on an existing duty date's editor, not the new-series form | Leader creates the series/date, then links it | Demonstrate the actual two-step path; decide whether the additional creation-form path is required. |
| Special-assignment staff screens have no Send to Media action; the assignee can send from mobile | A staff-only special-assignment handoff is absent | Explicit scope/permission disposition is needed; a Pastor title alone is not authority in the existing topic owner contract. Do not add a button that the server must refuse. |
| A sent sermon draft is a snapshot; another send returns that draft | Later topic changes require Media editing/review | Demonstrate this wording and decide whether snapshot behavior is acceptable; automatic refresh is not implemented. |
| Favourites are server-backed but not stored for offline use | The bundled hymn text remains available offline; favourite state does not gain an offline persistence promise | Keep the distinction visible in the pilot. |
| Failed staff refresh replaces the list with an error | Staff retries; last-good list preservation is absent | Existing cross-staff behavior, not a new claim of missing backend persistence; record usability outcome. |

The separately recorded **owner-accepted residual** is public asset cleanup after process
death or a persistent take-back failure: already-public bytes can remain until a later
authorized sync; there is no autonomous public sweep. Preserve that decision and test
the supported retry path. Do not turn it into a universal cleanup guarantee or claim all
the other rows above are owner-accepted.

## Unverified, blocked and owner-controlled work

The following implementations/tests have not been freshly exercised in this workspace:

- **Fresh local database and actual integrations:** no Docker/Podman engine or PostgreSQL
  runtime. Full pgTAP, Data API smoke, isolated restore, real G1/G2 and actual sermon lock
  contention were not run here. Historical [G1 13/13](evidence-release/content-event-rsvp-e2e.jsonl)
  and [G2 6/6](evidence-release/content-retention-e2e.jsonl) remain valid evidence for their
  recorded source, not fresh runs. The existing sermon stale-read injection is not two sessions.
- **Physical Android/iOS and browser/accessibility pilot:** no attached phones, emulator,
  Xcode or printed book. Playback/unavailable video, offline relaunch, dialler/USSD,
  calendar import, assistive technology and approved push require the listed devices.
- **Owner policy/source/provider decisions:** Q3 real giving verification, any affected
  third-party Q5 uses and the printed hymn questions require actual decisions/evidence.
  Church-owned content follows the already approved exemption; this run approves nothing.
- **Release operations:** history repair, broader target parity, preceding production
  migration/promotions, backup/recovery evidence, candidate approval and promotion remain open.

Exact commands and safe local cleanup are in
[local-validation.md](evidence-reconciliation-2026-10-30/local-validation.md). The owner
walkthrough provides device URL mapping, fictional account setup, permissions and manual
concurrency instructions. Run local database commands only against a disposable stack;
the sample fixtures and local grant-age adjustment must never be applied to hosted data.

## Evidence required before acceptance or promotion

Record each missing case with full candidate SHA, environment/target, UTC and church-local
date, actor role, setup, command or UI steps, expected versus actual outcome and a sanitized
artifact. Classify it as `authored only`, `run-passed`, `run-failed`, `skipped` or `blocked`;
classify known implementation omissions separately. Include failures and recovery, not
only successful screenshots.

Before any release decision: resolve the history blocker; verify the complete candidate
migration set and affected functions on the intended target; complete applicable local
integration/device/permission evidence; obtain owner dispositions on the above limitations;
confirm 5.12 and required policy gates; record an explicit release approval. Only the
approved promotion workflow may then run. Record actual post-deployment verification before
proposing closure of 6.17 or Epic 6. This document makes no release-ready or completion claim.
