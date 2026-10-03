# Story 1.6 — Q10 staff web trial: evidence and selection record

Date: 2026-10-03. Data: SYNTHETIC only. Supabase was not touched. Trial app: `trials/staff_web`
(release build, `flutter build web --no-web-resources-cdn`, Flutter 3.47.6, CanvasKit renderer),
served over http on 127.0.0.1. Harness: `trials/staff_web/tool/browser_trial.mjs` (Playwright
1.56.1 + Chrome DevTools Protocol accessibility tree).

## Decision

**Provisionally selected: Flutter Web.** The selection is conditional on the owner's spot-check
of the matrix entries that could not be tested here (see below).

Reasons:

1. Flutter Web passed all 27 automated checks on both Chromium builds available here. The checks
   covered keyboard traversal, visible focus, roles and names in the real browser accessibility
   tree, grid and list operations, 200% zoom, 200% browser font size, CSV download content
   including formula neutralisation, and a mobile-emulation smoke run.
2. Under the owner decision (`owner-decisions-milestone-1.md`), the trial result decides and a
   passing Flutter trial selects Flutter. The React/Next.js trial was therefore not built.
3. Selecting Flutter keeps one Dart stack: shared models and validation with mobile and the
   same Supabase client. The server contract does not change either way.

How the decision reopens: a must-pass item in the owner spot-check can fail on a browser in the
matrix or with a real screen reader, and an app-level change may not be able to fix it. Q10 then
reopens and the React/Next.js trial runs against the same checks before entry 1.7 builds
anything that depends on the choice.

## Browser and assistive-technology matrix

| Matrix entry (owner default) | Status in this environment | Result | Evidence |
|---|---|---|---|
| Desktop Chrome, latest | **Tested.** Chrome for Testing 153.0.8010.12, headless, Linux | 27/27 pass | `chrome-for-testing-153/` |
| (extra) Chromium 141 | **Tested.** Playwright Chromium 141.0.7390.37, headless, Linux | 27/27 pass | `chromium-141-playwright/` |
| Desktop Edge, latest | **Not tested** (no Edge binary). Edge uses the same Blink engine, so it is *expected* to match Chrome, but that is not counted as a pass | gap → owner | — |
| Desktop Firefox, latest | **Not testable here** (no Firefox build; `playwright install` not permitted) | gap → owner | — |
| Desktop Safari, where testable | **Not testable here** (needs macOS) | gap → owner | — |
| Chrome on Android | **Emulated only:** Pixel 7 viewport, touch and mobile user agent in Chromium (C13). Not a device run | gap → owner | `*/10-android-emulated-grid.png`, `*/11-android-emulated-dialog.png` |
| Screen readers (NVDA/JAWS on Windows, VoiceOver on macOS, TalkBack on Android) | **Not run.** The browser accessibility tree (what screen readers consume) was inspected through CDP instead. That is a proxy, not a screen-reader test | gap → owner | `*/ax-tree-*.json` |

Headless runs do not exercise OS-level high-contrast modes or OS text-size settings. The
browser font-size preference was tested instead (C12).

## Checks (identical in both tested browsers; details in `<browser>/results.json`)

| Id | Check |
|---|---|
| C0 | No page errors during the desktop run |
| C1 | Semantics tree present without Flutter's hidden "Enable accessibility" button (ready in ~1.4–1.5 s locally) |
| C2a–d | Table/row/columnheader/cell roles; 48 slot buttons named "position, date: member, status"; named heading, filter, export and tabs; view toggle exposed as radios with checked state |
| C3 | Every interactive accessibility node has a non-empty name |
| C4a–c | Tab follows visual order and DOM focus follows (never `<body>` while in the app); the grid is a single Tab stop |
| C5 | Each focused control differs visibly from its unfocused state (pixel diff; slot, button and field rings are the 3 px `#0A7FE0` accent) — `focus-N-*.png`, `focus-visibility.json` |
| C6 | Arrow keys, Home/End and Control+Home/End move focus slot by slot, stop at the edges and scroll the slot into view |
| C7a–c | Keyboard-only slot edit (Enter → status menu → Save). Focus returns to the slot; the change is announced politely; Escape cancels |
| C8a–b | The position filter narrows rows. No match shows a message and disables export with a reason |
| C9a–e | The export preview states scope, columns, exclusions and the "outside access controls" warning. The downloaded CSV has a BOM, CRLF line endings, an allowlisted header, 24 filtered rows × 5 columns and no private fields. Every formula-led value is prefixed with `'`. The grid edit appears in the file — `rota-export-door-filter.csv`, `csv-checks.json` |
| C10a–b | List alternative: 6 lists, 48 items, 48 named "Change …" buttons, level-2 headings. Keyboard operable |
| C11 | 200% zoom (683×450 CSS px at 2× density): all slots exposed, the toolbar wraps inside the window, no page-level horizontal scroll, the far grid column is reachable, the list fits |
| C12 | 200% browser font size (16→32 px): Flutter text renders 2.03× larger; the same layout checks as C11 |
| C13 | Mobile emulation: boots, exposes all slots, a touch tap opens the slot dialog |

## Findings: Flutter Web issues found, and how the trial handled each

These are real costs of choosing Flutter Web. Entry 1.7 must carry these patterns into the
shared design system.

1. **Browser Tab order ignores Flutter's `skipTraversal`.** The browser tabs through DOM
   `tabindex`, and that follows `canRequestFocus`. Material buttons do not expose
   `canRequestFocus`, so grid slots are built on `InkWell`. The widget tests passed while the
   browser behaved differently. Browser-level checks are therefore essential, and widget tests
   are not enough.
2. **`SegmentedButton` does not expose its selected segment** to the browser. Each segment is
   wrapped as a radio (`inMutuallyExclusiveGroup` + `checked`).
3. **`Semantics(liveRegion: true)` produced no `aria-live` announcement in Chromium.** Also, the
   engine moves its announcer element into any still-open modal dialog. Status changes use
   `SemanticsService.sendAnnouncement` after the dialog has closed (400 ms). They also stay
   visible as text.
4. **`FocusNode.requestFocus()` does not scroll.** Keyboard moves call
   `Scrollable.ensureVisible`.
5. **Semantics must be forced on** (`SemanticsBinding.instance.ensureSemantics()`). Without it, a
   screen-reader user must first find Flutter's hidden enable button.
6. Flutter has **no row-header role**. Each slot's name therefore carries both its position and
   its date.
7. The AppBar title is exposed as a level-2 heading before the page's level-1 heading. This is a
   minor heading-order issue for 1.7 to fix.
8. Text is painted to canvas, so find-in-page, text selection and browser translation do not
   work on page text. This is inherent to Flutter Web and acceptable for an app-style portal.
9. The sandbox reports `navigator.language` as `en-US@posix`, and Flutter fails at start-up with
   that value. Real browsers report a valid tag, so the harness pins `en-GB`. This is recorded in
   case a kiosk or locked-down browser reports odd locales.

## Owner spot-check (needed to confirm the selection)

Serve the trial from a laptop on the same Wi-Fi as the phone:

```sh
cd trials/staff_web
flutter build web --no-web-resources-cdn
python3 -m http.server 8766 --bind 0.0.0.0 --directory build/web
# desktop: http://localhost:8766/   phone: http://<laptop-LAN-IP>:8766/
```

Do the steps in **Firefox, Edge, Safari (Mac) and Chrome on an Android phone**. Do steps 1–6 with
**NVDA (Windows) or VoiceOver (Mac)**, and do steps 7–8 with **TalkBack** on the phone.

1. Press Tab from the page top. Focus goes to the tabs, the filter, Grid, List, Export, then one
   slot, then leaves the page. A blue ring is visible each time. In Safari, first turn on
   Settings → Advanced → "Press Tab to highlight each item on a webpage", or use Option+Tab.
2. Arrow keys move slot to slot, End jumps to Sun 22 Nov, and the slot scrolls into view.
3. Press Enter on a slot, change Status to Declined, then Save. The slot reads "Declined" and the
   screen reader says "Saved. …".
4. Type "door" in Filter positions; 3 rows remain. Type "zzz": "No positions match" appears and
   Export is disabled.
5. Clear the filter, open Export CSV…, then Download. Open the file in Excel, LibreOffice or
   Sheets. `=HYPERLINK(...)`, `=1+2`, `+Test Plus G` and similar values show as text (with a
   leading `'`), not as formulas or links. No phone numbers appear.
6. Choose List: every slot is a list item with a "Change …" button.
7. Zoom the browser to 200% (Ctrl/Cmd and +), or set the browser font size to Very large. Nothing
   is cut off, and the grid scrolls sideways inside its box.
8. On the phone: tap a slot, change it and save. Switch to List.

Record any failure against the browser. A failure in steps 1–6 with no app-level fix reopens Q10
(React/Next.js trial).
