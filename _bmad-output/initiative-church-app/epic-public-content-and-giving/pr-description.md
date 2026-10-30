# Epics 4–6: implementation history and Epic 6 acceptance status

## Current reconciliation — 30 October 2026

The implementation from `story/5.8-meetings-held` was merged into `main` as **`c96cd562b2650c37f5d3d879cb12891419700139`** on 28 October 2026. PR #6 is merged; the former integration branch and that main commit have the same tree. The earlier “not merged”, “no PR” and “hosted CI not run” statements below describe earlier snapshots and do not govern current work.

[Hosted CI run 40733936249](https://github.com/raeltec-systems/church-app/actions/runs/40733936249) succeeded for that exact main commit: policy, database, offline harness/function tests and Flutter jobs. The policy log explicitly reports that **staging migration-history drift was skipped because `SUPABASE_ACCESS_TOKEN` was unset**. A green run establishes neither current staging parity nor physical-device acceptance. See [the inspected CI summary](evidence-reconciliation-2026-10-30/hosted-main-ci-summary.json). Separately, the connected read-only staging inspection below supplies fresh, bounded environment evidence.

The current branch is `acceptance/epic-6-reconcile-epic-7-plan`. Stories 6.1–6.14, 6.16, 6.18, 6.19 and the three named follow-ups have built plans and are merged. **Story 6.15’s owner pilot and Story 6.17’s integrated acceptance/promotion remain open.** No production deployment, gate approval or owner acceptance is established by this reconciliation. The 27 October owner decision replaced background audio with YouTube/public Facebook video and livestream links; audio is not a remaining feature gap.

Use the [acceptance reconciliation](acceptance-reconciliation-2026-10-30.md) for current findings, the [owner walkthrough](../../../docs/runbooks/content-owner-walkthrough.md) for normal-app steps and evidence, and the [promotion runbook](../../../docs/runbooks/production-promotion-content.md) for the owner-controlled release procedure. The [migration manifest](evidence-reconciliation-2026-10-30/migration-manifest.json) lists and hashes all 101 tracked migrations at the verified main commit; it is not a remote migration-history report.

### Fresh read-only staging observation

At **30 October 2026, 21:48:59 Africa/Lusaka (19:48:59 UTC)** the connected Supabase metadata/SELECT inspection confirmed `bic-kafue-platform-test` (`tmurpotfluignacfueki`). [The recorded observation](evidence-reconciliation-2026-10-30/staging-read-only.json) found:

- **99 of 101 expected migration versions recorded**, with no unexpected versions. Exactly `20261027140200` (RSVP rows) and `20261027182300` (hymn-favourites rows) are absent from migration history. **Migration-history drift is not zero.**
- Both real purge bodies are present, neither contains the missing-rows stub, and each body matches the repository after CRLF normalization. Their `anon`, `authenticated` and `service_role` execute permissions are false; both are invoker functions with an empty `search_path`.
- Boundary violations and unowned objects are both **0** at this observation.
- `content-assets` is **ACTIVE v4** and `notifications-worker` is **ACTIVE v10** according to function metadata.

This resolves whether the two purge bodies and the reported Edge versions are present. It does not establish whole-schema/function-byte parity, execution of the deletion workflows, actual Storage behavior or device acceptance. The migration-history discrepancy needs a separately reviewed, owner-authorized remediation; do not replay either rows file or repair history automatically.

### Evidence still required

- A witnessed integrated mobile/staff pilot, including device playback, dialler/manual fallback, native calendar import, restart/offline recovery and the full current-role matrix.
- Actual two-session sermon-from-duty lock contention. The existing stale-first-read regression proves the recheck logic, not a concurrent transaction waiting on the lock.
- Resolve the observed staging migration-history discrepancy through a separately reviewed, owner-authorized operation. The two purge bodies match the repository and current Edge versions are observed above; broader function/schema/source parity and the affected lifecycle/Storage workflow checks still need evidence. Never replay rows or repair history automatically.
- Explicit owner approval and the required production evidence for promotion. Q3/Q5 remain owner decisions or visibly fail-closed release conditions.

The sections below preserve dated implementation and review evidence. Counts, staging observations and deployment statements apply to their recorded snapshots, not automatically to the present environment or a new candidate head.

## Follow-up review fixes (2026-10-28 follow-up report, HOLD at `970e8e0`)

Each finding was reproduced with a failing test committed **before** its fix. The tests then pass after the fix.

| Finding | Reproduced on `970e8e0` | Fix | After |
|---|---|---|---|
| F1 public object survives a post-upload refusal | `post-upload-refusal.test.mjs`: 10 of 17 failed (401, 403, 503, timeout), with output in `evidence-followup-f1/before-fix.txt` | Every plan read goes through one wrapper. Once a call has stored public objects, a refused or failed read deletes exactly the paths that call stored, using server Storage authority, before answering. Retried up to 3 times; otherwise the object is listed for the next authorized sync. A timeout becomes a 503. `content-assets` is staging v4. | 17 of 17 pass. All function tests pass. `content-banners.mjs` passes 16 of 16. |
| F3 stale catalog write undoes a withdrawal (sermons and events) | `apps/mobile/test/offline/public_content_ordering_test.dart`, with the real file adapter, a blocked queue and a gated repository: both cases failed | `forgetSermon`/`forgetEvent` invalidate in-flight reads before their first await. A cache `readGeneration` tombstone also stops any save from a read started before a removal from bringing the removed row back. Giving removals get the same treatment. | passes, including a cold adapter |
| F8 moved meetings miss venue notices | `cells_meeting_reminders_test.sql`: 6 of 70 failed (combined edit; nominal vs effective start; replay/dedup) | Migration `20261028150927` replaces `cells_set_schedule`: moved meetings revised by the generator get their notice at that revision, and the window uses the effective start. Staging hash matches. | 70 of 70 pass |
| C1 giving detail waits for its logo | failing widget test, which never left loading | `reconcileGivingMethod` is now only the awaited safety step (text, plus keep or drop the logo). The download runs in the background via `saveGivingLogo` and attaches only if nothing changed meanwhile. | passes |
| C2 oversized same-revision banner never repaired | adapter test failed, leaving a 5 MiB + 1 file | Every rejected image file is replaced, for banners and giving logos. | passes; no repeat download |

**Accepted residual (owner, 2026-10-28):** process death between a public upload and its take-back, or persistent take-back failure, can leave the object until the next authorized sync. A server-side sweep would need an extra command granted to the `content_asset_retention` principal, and the owner chose not to add it now. It is documented in `docs/runbooks/content.md`.

**Not independently re-verified:** the sermon-from-duty lock recheck is tested by injecting a stale first read, not by real two-session contention.

## Historical verification at `cfc2e6f` (local, 2026-10-28)

All checks ran on the merged head `cfc2e6fe46f284f9707cf26881607aa527f4e658`, using `tools/ci/run-local-ci.sh`, which runs every `ci.yml` step. The tree of the pushed head differs only in this file, the new script and the release evidence.

| Check | Result |
|---|---|
| Migrations (base `origin/main`), secrets, env configs, function imports | **passed** |
| TypeScript contract fixtures | **passed** |
| pgTAP on a fresh reset | **passed**: 72 files, 5,841 tests |
| Data API smoke | **passed** |
| Evidence scans (every `scan-evidence.sh` step) | **passed** |
| Flutter analyze and test: design_system, client_core, mobile, staff, staff web trial | **passed** (client_core 1,169, mobile 115, staff 63, design_system 20, staff web trial 35) |
| client_core duties and follow-ups with `TZ=America/New_York` | **passed** (224 and 37 tests), but Windows ignores `TZ`, so this did not prove time-zone independence; CI on Linux does |
| Staff web and trial web builds; bundle secret scan | **passed** |
| Dart contracts in Chrome | **passed**, 283 tests |
| Policy tool tests | **failed on Windows** (CRLF checkout and the 0600 file mode). **Passed on a clean Linux clone:** 56 of 56 (Node 22.23.4) |
| Harness, function and shared-module tests | **failed on Windows** (CRLF `pipefail\r` and a `/C:/` bash path). **Passed on a clean Linux clone:** 410 of 410 |
| Dart contracts test (VM) | **failed on Windows** (the generated fixture expected LF and got CRLF). **Passed on a clean Linux clone:** Dart 3.13.5, 284 of 284, analyze clean |
| Restore rehearsal | **unrun in this Windows session**: `spawnSync('npx')` did not resolve. Later hosted-main CI succeeded; see the current reconciliation above. |
| Staging migration-history drift | **unrun in this session**; later hosted-main policy logs explicitly confirm the credential-dependent check was skipped. Later connected read-only inspection found the two-version history discrepancy described above; zero drift is not established. |
| **G1** concurrent last-seat RSVP (`content-event-rsvp.mjs`) | **passed**, exit 0, 13 of 13. C21: round 1 had 1 going and 4 full, and round 2 the same. Evidence in `evidence-release/content-event-rsvp-e2e.jsonl` |
| **G2** scheduler, worker and Storage retention (`content-retention.mjs`) | **passed**, exit 0, 6 of 6. Evidence in `evidence-release/content-retention-e2e.jsonl`; the evidence scan is clean |
| Hosted GitHub CI | **not run at this historical checkpoint**; superseded by the successful exact-main run linked above. |

Historical follow-up checklist, reconciled on 30 October:

1. PR #6 was opened and merged; hosted-main CI succeeded, including the Linux restore/TZ jobs described in the handoff.
2. F1, F3 and F8 have the later reproductions, fixes and regression evidence recorded above. Preserve those checks; do not reopen them from the old HOLD list alone.
3. Owner device acceptance, current environment verification and production approval remain open (entries 15 and 17).

## Earlier review fixes (2026-10-28 first review)

The fixes from the first review are summarised below. F1 and F3 were completed by the follow-up fixes above.

| Finding | Fix |
|---|---|
| F1 stale asset sync | `content-assets` rechecks the plan before each upload and carries out pending removals. There is a race test against the real handler. Deployed to staging (v3). |
| F2 Bible import preflight | Busy guard and account epoch are taken before the first await; stale continuations are rejected. |
| F3 withdrawn sermon offline | A null detail removes the sermon from the saved catalog directly. |
| F4 banner images | Unchanged permitted revisions are reused; withdrawn or revoked ones are dropped before downloads. |
| F5 calendar overlays | Personal overlays render whatever the public read returns. |
| F6 historical roster | `record_roster` is membership at the meeting's start, for leader and assistant only. |
| F7 special duty due date | `due_on` is a material change: re-acceptance, notice, overlap and revision history. |
| F8 venue-only changes | Future meetings using the schedule venue are revised and send a deduplicated notice. |
| Sermon-from-duty race | Authority is re-read after the advisory lock (`20261028123554`). |
| Section 8 items | Manifest crash recovery and corrupt-manifest policy; display no longer waits on images; search query identity; picker reconciliation; special duty form reopen after a conflict. |
| G1/G2 | CI has no Edge runtime or phone sign-in, so the runbook has a release-gate section with the RSVP last-seat and retention commands. |

Owner decisions taken with the fixes (2026-10-28):
- Cell leaders get the same coverage features as departments (contact attempts, coverage queue, alerts, outcomes), so the epic 5 coverage requirement now holds as written.
- A saved calendar event opens offline.

Also fixed: the banner E2E cleanup, which 6.11's organiser rows blocked (now 16/16).

## Epic 6 entries (plans in `_bmad-output/initiative-church-app/epic-public-content-and-giving/`)

| Entry | What | Staging migration |
|---|---|---|
| 6.1 | Events on staff web, guest Calendar | yes |
| 6.2 | Home banners, rights registry, public asset path | yes |
| 6.3 | Verified giving methods, Give tab (two-Admin check) | yes |
| 6.4 | Offline public content cache | yes |
| 6.5 | Dialler hand-off, offline giving, unsafe flag | yes |
| 6.6 | Bible reader (KJV/WEB staging) | yes |
| 6.7 | Built-in BICC Tonga hymn book (199 hymns, 67 choruses), converter in `tools/hymn-book/` | none |
| 6.8 | Hymn favourites, Hymns for this Sunday, `worship_leader` scope | `20261027182223` + `_rows` |
| 6.9 | Sermons with YouTube player and safe notes | `20261027083618` |
| 6.10 | Facebook video/livestream links for sermons (background audio descoped) | `20261027191003` |
| 6.11 | Event posters, Add to calendar, RSVP within capacity | `20261027140149` + `_rows` |
| 6.12 | Duties linked to published events, review flags | `20261027192013` |
| 6.13 | Pinned announcements with optional push | yes |
| 6.14 | Home completion, top-bar search | `20261028072741` |
| 6.16 | Refactor sweep (client only) | none |
| 6.18 | Sermon drafts from preaching duties | `20261028071717` |
| 6.19 | Calendar overlays for own duties and cell meetings | `20261028064546` |
| F1-F3 | Giving Admin tenure, church-owned images skip Q5, upload retention | yes |

The original story plans record review deferral to the epic PR under the owner’s 27 October process decision. Those fields are historical; the later first/follow-up reviews above and the merged PR supply subsequent evidence. Unresolved behavior notes and owner-only checks remain visible in their plans.

## Areas to look at hardest

- **Privacy:** RSVP names visible only to organisers and Admin (6.11); hymn favourites private to the member (6.8).
- **Concurrency:** the RSVP capacity race (6.11).
- **Authority:** the content authorizer and replay registry, replaced in 6.8 to make it registry-driven.
- **Contract boundaries:**
  - Duties `event_ref` validation through `app.contract_check_source` (6.12)
  - Cells `api.cells_my_meetings()` (6.19)
  - the `duties_owner_topic` seam (6.18)
- **Server-side validation:** sermon notes sanitising and the Facebook/YouTube allowlists (6.9, 6.10).
- **Deletion:** the `_rows` deletion files (6.8, 6.11), already hand-applied on staging.

## Earlier integration-branch verification (historical, before the follow-up results above)

- pgTAP: 72 files, 5,764 tests pass. One known load-sensitive timing case, `duties_owner_decisions_test` 32, passes when run alone.
- Flutter tests: client_core 1,148, mobile 96, staff 63, design_system 19. `flutter analyze` is clean.
- `node tools/ci/check-migrations.mjs` passes.
- The 28 October integration report recorded staging (`tmurpotfluignacfueki`) as having every migration, with function hashes matching its fresh local reset and boundary/unowned checks at 0. This is a historical observation. The fresh 30 October connected read found both purge bodies present but their two versions absent from history; see the current reconciliation above.
- That report recorded production as untouched. Entry 6.17 remains owner-controlled; this reconciliation neither deploys nor establishes current production state.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
