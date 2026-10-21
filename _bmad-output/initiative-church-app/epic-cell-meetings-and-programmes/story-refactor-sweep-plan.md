---
title: 'Refactor sweep'
type: 'refactor'
ticket: '11'
created: '2026-10-21'
status: 'done'
baseline_revision: '3774ab9'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic's stories left duplication and test-harness drift in Cells. The scope must not change, and no unfinished behaviour may be absorbed.

**Approach:** Review the triage logs and implementation notes of 5.1-5.10. Apply only cleanups that are justified and change no behaviour. Rerun the affected checks.

## Boundaries & Constraints

**Always:** no contract, schema or behaviour change; every affected check rerun.

**Never:** a migration whose only purpose is tidying a hosted function; new scope.

</frozen-after-approval>

## Findings reviewed

| Finding (source) | Decision |
|---|---|
| The four newest cells E2E scripts (5.7 absence, 5.8 records, 5.9 transfer, 5.10 pilot) each carried the same 100-line cleanup SQL, extended by copy at every story | **Applied:** `tools/identity-e2e/cells-cleanup.mjs` (`cellsCleanupSql`) is the one copy, covering every Cells table through 5.9. It accepts only SYNTHETIC names, uuids and phone numbers. The four scripts call it, removing 419 lines. Offline test `cells-cleanup.test.mjs` (2). |
| `boundaries_test.dart` failed on Windows hosts (noted in 5.8 and 5.9): `replaceAll(r'\\', '/')` replaces a two-backslash sequence, never the single separator | **Applied:** `replaceAll('\\', '/')` (4 places). The boundary checks themselves are unchanged and now run green on Windows as well as Linux. |
| The un-naming of programme parts in `app.cells_erase_member` (5.4) and `app.cells_transfer_effects` (5.9) uses the same jsonb rewrite | **Not applied:** it would need a migration re-creating two hosted functions only to share a statement (excluded above), and the two select their parts differently on purpose. The note is in the 5.9 code comments. |
| `cell_screens.dart` is large (about 4,900 lines across Admin, leader, meetings, plan and My cell) | **Not applied:** splitting a presentation file this late only moves code. It stays a candidate for the epic 7 Cells work, which adds attendance screens to it. |
| Older cells E2E scripts (5.3-5.6) keep their own, narrower cleanup | **Not applied:** they pass and remove what they create. Moving them onto the shared helper is churn without a defect. |
| Known flake: `duties_owner_decisions_test.sql` #32 (a 3 s board timing under full-suite load) | **Not applied:** it is Duties' own test, and it passes alone. Recorded again in the 5.12 evidence. |

## Verification

- E2E with the shared cleanup: cells-absence 5/5, cells-meeting-records 6/6, cells-transfer 7/7, cells-pilot 8/8. Each run left 0 users, cells and members behind.
- Client: the full `client_core` suite passes, 732 tests (the two Windows-only boundary failures are gone).
- No migration or schema change, so pgTAP is unaffected; the last full db:test, on a fresh reset, passed with 5.9.
