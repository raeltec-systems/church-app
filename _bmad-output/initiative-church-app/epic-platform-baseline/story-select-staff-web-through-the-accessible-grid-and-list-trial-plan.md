---
title: 'Select staff web through the accessible grid and list trial'
type: 'feature'
ticket: '6'
created: '2026-10-03'
status: 'blocked'
blocked_reason: 'Owner spot-check needed: Firefox, Edge, desktop Safari, Chrome on a real Android device and real screen readers (NVDA or VoiceOver, plus TalkBack) cannot run in this environment. Flutter Web is provisionally selected after passing 29/29 desktop (non-emulated) checks on desktop Chrome (Chrome for Testing 153), with the same result on Chromium 141; the one emulated check (Pixel 7) passed but counts for no matrix entry. Steps are in evidence-1.6/README.md (Owner spot-check).'
baseline_revision: 'dfa367db1bae7ae6ade7dfab75cfaf2de99b853a'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/spec-church-app/design-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Q10 is open: Flutter Web is only proposed for the staff portal. Nobody has shown that it can deliver a dense, keyboard- and screen-reader-operable grid with a list alternative, text scaling and a safe CSV download. Entry 7 cannot build the staff shell until a framework is selected.

**Approach:** Extend the disposable `trials/staff_web` Flutter Web app with a synthetic duty-rota grid (positions × dates) and an equivalent list view. Add slot assignment and status change, plus a CSV export preview and download with formula neutralisation and an allowlist of columns. Then drive a release build in a real browser with an automated Playwright harness. The harness checks keyboard traversal, focus visibility, roles and names in the browser accessibility tree, 200% zoom and 200% font size, and the content of the downloaded CSV. It saves the evidence and records the selection. If Flutter fails a check that it is able to run, build the same trial in React/Next.js under `trials/` and select whichever trial passes.

## Decisions

- Decision (owner, owner-decisions-milestone-1.md): the trial result decides. Flutter Web is selected if it passes the default matrix; otherwise React/Next.js is trialled and selected. The default matrix is the latest desktop Chrome, Edge and Firefox, desktop Safari where testable, and Chrome on Android. The owner reviews the evidence afterwards.
- Decision (agent, under owner pre-approval): this environment has only Playwright Chromium (`/opt/pw-browsers`, with no Firefox or WebKit build) and no screen reader. Chromium desktop is the only matrix entry actually tested. Edge (also Chromium-based) is inferred, not tested. A mobile-viewport touch emulation in Chromium stands in for Chrome on Android but is not counted as a pass. Firefox, Safari, Chrome on a real Android device and real screen-reader runs (NVDA/VoiceOver/TalkBack) are documented gaps for the owner's spot-check, not passes.
- Decision (agent, under owner pre-approval): the selection is recorded as provisional — Flutter Web, conditional on the owner spot-check — when every check runnable here passes. A spot-check failure reopens the decision and triggers the React/Next.js trial. This choice is fail-closed and reversible.
- Decision (agent, under owner pre-approval): the app enables semantics at startup (`SemanticsBinding.instance.ensureSemantics()`), so a screen reader needs no hidden "enable accessibility" step. The trial measures the cost and accepts it.
- Decision (agent, under owner pre-approval): CSV neutralisation follows the OWASP guidance. A cell that starts with `=`, `+`, `-`, `@`, tab or carriage return gets a leading `'`. Every field is RFC 4180-quoted, rows end with CRLF, and the file starts with a UTF-8 BOM. Only an allowlist of columns is exported; synthetic private fields are never exported.

## Boundaries & Constraints

**Always:** use synthetic, labelled fixture data only. Keep all files inside `trials/` and this epic's `evidence-1.6/`. Show every status as a text label, never colour alone. Every action must be reachable and operable by keyboard, with a visible focus indicator. Report untested matrix entries honestly.

**Never:** write to Supabase, use real member data, or edit `apps/` or `supabase/`. Do not create `apps/staff` (that is entry 7). Do not run `playwright install`. Do not claim a pass for any browser or screen reader that was not run.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Grid keyboard | Focus a slot, press the arrow keys, Home/End, Enter | Focus moves cell by cell; Enter opens the slot dialog | Moves stop at the edges, with no wrap or trap |
| Status change | Choose a new status for a slot in the dialog | Grid, list and CSV reflect the new label | Cancel leaves the slot unchanged |
| CSV injection | A synthetic name or note starting with `=`, `+`, `-`, `@`, tab or CR | The exported cell starts with `'`, and quotes/commas/newlines are escaped | — |
| CSV allowlist | The fixture includes a private phone/note field | That field never appears in the preview or the file | — |
| Text 200% | Browser zoom 200% or root font 32px | Content stays readable; no clipped labels or horizontal page scroll; list view available | Grid scrolls horizontally inside its own region |
| Empty filter | The status filter matches nothing | A "No slots match" message; export is disabled with a reason | — |

</frozen-after-approval>

## Code Map

- `trials/staff_web/lib/main.dart` -- entry point. Keep `MainApp(home:)` and `MissingConfigScreen` (the existing tests use them). The tracer status screen stays reachable when configured.
- `trials/staff_web/lib/platform_status/*` -- the 1.1 tracer read. Reuse it unchanged.
- `trials/staff_web/pubspec.yaml` / `pubspec.lock` -- `web` 1.1.1 is already transitive. Make it direct at the same version so the lockfile stays stable.
- `.github/workflows/ci.yml` -- the trial already gets analyze/test/build web. No browser job is added (CI has no pinned browsers).
- `docs/design-handoff/screenshots/admin-05-duty-rotas.png` -- the visual reference for the rota grid (positions × Sundays, status-labelled slots).
- Flutter 3.47.6 engine: `SemanticsRole.table/row/cell/columnHeader` map to ARIA `table`/`row`/`cell`/`columnheader`. The web text scale comes from the root `font-size` (`platform_dispatcher.dart`).

## Tasks & Acceptance

**Execution:**
- [x] `trials/staff_web/lib/rota_trial/rota_fixture.dart` -- synthetic positions, dates and members, including the injection strings and private fields -- deterministic fixture
- [x] `trials/staff_web/lib/rota_trial/csv_export.dart` -- pure allowlisted CSV builder with neutralisation -- unit-testable safety core
- [x] `trials/staff_web/lib/rota_trial/download*.dart` -- conditional-import Blob download on web, with a stub elsewhere -- browser download
- [x] `trials/staff_web/lib/rota_trial/rota_trial_screen.dart` -- grid (semantic table, roving-focus arrow keys), list view toggle, status filter, slot dialog, export preview and download, strong focus ring -- the trial UI
- [x] `trials/staff_web/lib/main.dart` -- enable semantics; the shell opens on the rota trial, with the tracer as a second destination
- [x] `trials/staff_web/test/rota_trial/*` -- CSV unit tests; widget tests for keyboard movement, the dialog status change, the list toggle, the empty filter, the table semantics roles and the 2.0 text scale with no overflow
- [x] `trials/staff_web/tool/browser_trial.mjs` -- Playwright harness against a locally served release build; writes evidence and `results.json` to `evidence-1.6/`
- [x] `evidence-1.6/` -- screenshots, AX tree, keyboard log, downloaded CSV, results and the browser-matrix and selection record
- [x] `trials/staff_web/README.md` -- how to run the trial and the harness

**Acceptance Criteria:**
- Given the release build in Chromium, when the harness tabs through the page, then every interactive control receives DOM focus in a logical order, with a non-empty accessible name and a visible focus indicator (a pixel difference between focused and unfocused states).
- Given the Chromium accessibility tree, when it is inspected, then the grid exposes table/row/columnheader/cell roles, with slot names that include the position, the date, the member and the status label.
- Given an export, when the harness downloads the CSV, then it matches the filtered rows and allowlisted columns, and every injection-prefixed value is neutralised.
- Given the selection record, then it lists, for every matrix entry, tested / emulated / not testable here, together with the decision and its reasons.

## Implementation Notes

- Implemented directly (no subagent tool in this session). Files: `trials/staff_web/lib/main.dart` (semantics forced on, `TrialShell` with tabs, focus-ring theme); `lib/rota_trial/{rota_fixture,csv_export,download,download_stub,download_web,rota_trial_screen}.dart`; `test/rota_trial/{csv_export_test,rota_trial_screen_test}.dart`; `tool/browser_trial.mjs`; `README.md`; `pubspec.yaml`/`pubspec.lock` (`web` 1.1.1 is now a direct dependency at the same version). CI is unchanged: the existing analyze/test/build web steps cover the trial. The browser harness is not in CI because CI has no pinned browsers.
- Browser findings fixed in the app: browser Tab ignores `skipTraversal`, so the roving tab stop uses `InkWell(canRequestFocus:)`; `SegmentedButton` hid its selection, so segments are exposed as radios; `Semantics(liveRegion)` never announced, so the app calls `SemanticsService.sendAnnouncement` after the dialog closes; `requestFocus` did not scroll, so keyboard moves call `Scrollable.ensureVisible`. Widget tests passed before each browser fix, so browser-level evidence is required.
- Environment: only Chromium builds exist under `/opt/pw-browsers`: Playwright Chromium 141 and Chrome for Testing 153 (run through `CHROMIUM_EXECUTABLE`). The sandbox reports `navigator.language` as `en-US@posix`, which Flutter rejects at start-up, so the harness pins the `en-GB` locale.
- Results (superseded by the review revision below): the first run reported 27/27, mixing emulated checks into the total.
- Decision (agent, under owner pre-approval): Flutter Web is **provisionally selected**. The React/Next.js trial was not built because Flutter passed every check that could run here. A must-pass spot-check failure with no app-level fix reopens Q10. Entry 1.7 can start on the provisional selection.
- Matrix test audit (first pass, corrected below): it wrongly counted the free-text position filter as the matrix's status filter.
- Review revision (2026-10-03). Changes:
  - Added a **status filter**. Non-matching cells read "…: hidden by status filter"; when nothing matches, "No slots match these filters" appears and export is disabled with a reason. The fixture now varies statuses by row, so a position plus status combination can match nothing.
  - Dialogs are `TrialDialog`: role `dialog`, named by the title. The table is named through a `Table`/`RenderTable` subclass.
  - Focus indicators:
    - `FocusRing` draws a 3 px accent ring outside each button.
    - The view toggle is a named radio group of two buttons; `SegmentedButton` is gone.
    - The shell uses custom tabs in a named tab list with a white ring; `TabBar` is gone.
    - Text fields have a 4 px focused border, and menu options a near-solid accent highlight.
  - Every target is at least 48 px tall (standard density).
  - Dropdown items wrap instead of ellipsising.
  - The download announcement now says "Download started: <file> (N rows)."
  - The fixture adds CR-led and space-led values.
  - A golden CSV (`test/rota_trial/golden/door-export-after-edit.csv`) is shared by the widget test and the harness.
  - Harness:
    - Focus visibility uses a contrast-change area rule on each control's own box, measured against a non-adjacent, same-layout baseline. It covers 28 controls: the page, slot dialog fields and buttons, status menu options, export dialog buttons and 6 of 48 list Change buttons.
    - Names are checked in 5 states, and the 44 px target check is new.
    - Cancel and Escape are tested after editing both member and status.
    - All four edges clamp.
    - The edit is checked in grid, list and CSV.
    - The CSV is byte-compared with the golden file and its Member/Status values cross-checked against the grid.
    - The preview text is checked for privacy.
    - Zoom is **real browser zoom** (profile default-zoom preference, DPR 2), with both dialogs opened.
    - Checks carry `kind` `desktop` or `emulated`, and results report the two separately.
  - Results: **desktop 29/29** on Chrome for Testing 153 and Chromium 141, plus **emulated 1/1** (C13 only). Trial README corrected: the Platform status tab is always present.
- Matrix test audit (revised). Every check below ran and passed:
  - **Grid keyboard:** widget test "clamp at all edges" and harness C6.
  - **Status change:** widget test "grid, list and CSV" and harness C7c/C10b.
  - **Cancel/Escape after editing:** widget tests and harness C7b.
  - **CSV injection and allowlist:** csv unit tests and harness C9b–d, with all 7 trigger kinds.
  - **200% text:** widget tests with both dialogs and the menu at 2.0 scale (no truncation or overflow) and harness C11/C12.
  - **Empty status filter:** widget test "filters that match no slot" and harness C8b.

## Plan Change Log

- 2026-10-03 — review findings: the status filter was missing from the frozen matrix; focus and name checks covered only top-level stops; the focus pass rule accepted faint tints and neighbour contamination; dialogs and the table were unnamed; the cancel tests made no edit; only two edges were tested; the CSV checked counts only; the emulated checks were counted in the headline; zoom was emulated; targets were 32 px; "Downloaded" overclaimed. Amended: the implementation and harness as listed in Implementation Notes ("Review revision"). This avoids claiming accessibility passes that were not measured on the real control, and avoids presenting emulation as matrix coverage. KEEP: roving tab stop on `InkWell(canRequestFocus)`, post-dialog `sendAnnouncement`, `ensureSemantics`, the evidence layout under `evidence-1.6/<browser>/`, and the honest gap matrix.

## Review Triage Log

## Verification

**Commands:**
- `cd trials/staff_web && flutter analyze && flutter test` -- expected: clean, all pass
- `cd trials/staff_web && flutter build web --no-web-resources-cdn` then serve `build/web` over http and run `node tool/browser_trial.mjs` -- expected: every check `pass` in `evidence-1.6/results.json`
