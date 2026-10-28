# Epics 4-6: duties, cells and public church content and giving

`main` was last updated at PR #3, so this branch (`story/5.8-meetings-held`) carries epic 4 (duties), epic 5 (cells and meetings) and epic 6 (public content and giving). Epics 4 and 5 were reviewed story by story when they were built. **Epic 6 has not been reviewed** (owner decision 2026-10-27: the build agent only builds, and this PR is the review). Please focus the review on epic 6.

## Review fixes (after the 2026-10-28 review, HOLD)

All findings of the 2026-10-28 review are fixed on this branch, each with a regression test. Every migration is on staging with its hashes verified, and boundary/unowned are 0.

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

Known on this Windows build host only: four Node policy tests fail, on a file-permission check and a line-ending regex in files no fix touched. The hosted CI run will confirm.

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
