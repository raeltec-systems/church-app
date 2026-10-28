# Epics 4-6: duties, cells and public church content and giving

`main` was last updated at PR #3, so this branch (`story/5.8-meetings-held`) carries epic 4 (duties), epic 5 (cells and meetings) and epic 6 (public content and giving). Epics 4 and 5 were reviewed story by story when they were built. **Epic 6 has not been reviewed** (owner decision 2026-10-27: the build agent only builds, and this PR is the review). Please focus the review on epic 6.

## Status for the reviewer

**This PR is not approved yet.** Nothing here is merged to `main` or deployed to production. Production also still needs the owner's approval of the Q3 and Q5 gates, which is separate from the technical checks below.

## Follow-up review fixes (2026-10-28 follow-up report, HOLD at `970e8e0`)

Each finding was reproduced with a failing test committed **before** its fix. The tests then pass after the fix.

| Finding | Reproduced on `970e8e0` | Fix | After |
|---|---|---|---|
| F1 public object survives a post-upload refusal | `post-upload-refusal.test.mjs`: 10 of 17 failed (401, 403, 503, timeout), with output in `evidence-followup-f1/before-fix.txt` | Every plan read goes through one wrapper. Once a call has stored public objects, a refused or failed read deletes exactly the paths that call stored, using server Storage authority, before answering. Retried up to 3 times; otherwise the object is listed for the next authorized sync. A timeout becomes a 503. `content-assets` is staging v4. | 17 of 17 pass. All function tests pass. `content-banners.mjs` passes 16 of 16. |
| F3 stale catalog write undoes a withdrawal (sermons and events) | `apps/mobile/test/offline/public_content_ordering_test.dart`, with the real file adapter, a blocked queue and a gated repository: both cases failed | `forgetSermon`/`forgetEvent` invalidate in-flight reads before their first await. A cache `readGeneration` tombstone also stops any save from a read started before a removal from bringing the removed row back. Giving removals get the same treatment. | passes, including a cold adapter |
| F8 moved meetings miss venue notices | `cells_meeting_reminders_test.sql`: 6 of 70 failed (combined edit; nominal vs effective start; replay/dedup) | Migration `20261028150927` replaces `cells_set_schedule`: moved meetings revised by the generator get their notice at that revision, and the window uses the effective start. Staging hash matches. | 70 of 70 pass |
| C1 giving detail waits for its logo | failing widget test, which never left loading | `reconcileGivingMethod` is now only the awaited safety step (text, plus keep or drop the logo). The download runs in the background via `saveGivingLogo` and attaches only if nothing changed meanwhile. | passes |
| C2 oversized same-revision banner never repaired | adapter test failed, leaving a 5 MiB + 1 file | Every rejected image file is replaced, for banners and giving logos. | passes; no repeat download |

**Accepted residual (owner, 2026-10-28):** if the function process dies between a public upload and its take-back, the object stays until the next authorized sync. A server-side sweep would need an extra command granted to the `content_asset_retention` principal, and the owner chose not to add it now. It is documented in `docs/runbooks/content.md`.

**Not independently re-verified:** the sermon-from-duty lock recheck is tested by injecting a stale first read, not by real two-session contention.

## Verification at `cfc2e6f` (local, 2026-10-28)

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
| Restore rehearsal | **unrun**: the tool calls `spawnSync('npx')`, which does not resolve on Windows, so it exits before the rehearsal. Needs Linux CI |
| Staging migration-history drift | **unrun**: needs `SUPABASE_ACCESS_TOKEN`, which CI skips too |
| **G1** concurrent last-seat RSVP (`content-event-rsvp.mjs`) | **passed**, exit 0, 13 of 13. C21: round 1 had 1 going and 4 full, and round 2 the same. Evidence in `evidence-release/content-event-rsvp-e2e.jsonl` |
| **G2** scheduler, worker and Storage retention (`content-retention.mjs`) | **passed**, exit 0, 6 of 6. Evidence in `evidence-release/content-retention-e2e.jsonl`; the evidence scan is clean |
| Hosted GitHub CI | **not run**: no PR exists yet, and `ci.yml` triggers on pull requests and pushes to main |

Remaining before approval:
1. Open the PR so hosted CI runs. This is the first run of the restore rehearsal and the true `TZ` check.
2. The reviewer re-checks F1, F3 and F8.
3. Owner gate approvals for production (entry 17).

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

Every plan's "Review" is recorded as deferred to this PR. Known gaps and deferrals are listed in each plan.

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

## Verification on the branch tip

- pgTAP: 72 files, 5,764 tests pass. One known load-sensitive timing case, `duties_owner_decisions_test` 32, passes when run alone.
- Flutter tests: client_core 1,148, mobile 96, staff 63, design_system 19. `flutter analyze` is clean.
- `node tools/ci/check-migrations.mjs` passes.
- Staging (`tmurpotfluignacfueki`) has every migration, with function hashes verified against a fresh local reset and boundary/unowned checks at 0.
- Production is untouched; entry 6.17 promotes after review and the owner's gate approvals (Q3, Q5).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
