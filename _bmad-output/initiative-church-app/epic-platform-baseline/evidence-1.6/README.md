# Story 1.6 — Q10 staff web trial: evidence and selection record

Date: 2026-10-03, revised after review. Data: SYNTHETIC only, and Supabase was not touched.

- Trial app: `trials/staff_web`, release build (`flutter build web --no-web-resources-cdn`,
  Flutter 3.47.6, CanvasKit renderer), served over http on 127.0.0.1.
- Harness: `trials/staff_web/tool/browser_trial.mjs`, using Playwright 1.56.1 and the Chrome
  DevTools Protocol accessibility tree. All runs are headless.

## Decision

**Provisionally selected: Flutter Web.** The selection is conditional on the owner's spot-check
of the matrix entries that could not be tested here (see below).

Reasons:

1. On desktop Chrome, the only owner-matrix entry testable here, Flutter Web passed **29 of 29
   desktop checks**, with no emulation. Chromium 141 also passed 29/29. The checks cover:
   - keyboard traversal;
   - focus visibility, measured as a contrast change on each control's own box;
   - roles and names in the real browser accessibility tree, across 5 screen states;
   - target sizes;
   - grid, list, filter and dialog operations, including cancel paths and edge clamping;
   - real 200% browser zoom and 200% browser font size, with both dialogs open;
   - the downloaded CSV, compared byte for byte with a golden file and cross-checked against the
     grid state.

   The single emulated check (C13, Pixel 7 emulation) is reported separately and is **not**
   counted towards any matrix entry.
2. Under the owner decision (`owner-decisions-milestone-1.md`), the trial result decides and a
   passing Flutter trial selects Flutter. The React/Next.js trial was therefore not built.
3. Selecting Flutter keeps one Dart stack: shared models and validation with mobile and the
   same Supabase client. The server contract does not change either way.

How the decision reopens: a must-pass spot-check item can fail in a matrix browser or with a real
screen reader, and an app-level change may not be able to fix it. Q10 then reopens and the
React/Next.js trial runs against the same checks before entry 1.7 builds anything that depends on
the choice.

## Browser and assistive-technology matrix

| Matrix entry (owner default) | Status in this environment | Result | Evidence |
|---|---|---|---|
| Desktop Chrome, latest | **Tested** in Chrome for Testing 153.0.8010.12 (headless, Linux) | desktop 29/29 pass | `chrome-for-testing-153/` |
| (extra) Chromium 141 | **Tested** in Playwright Chromium 141.0.7390.37 (headless, Linux) | desktop 29/29 pass | `chromium-141-playwright/` |
| Desktop Edge, latest | **Not tested** (no Edge binary). Edge uses the same Blink engine, so it is *expected* to match Chrome, but that is not counted as a pass | gap → owner | — |
| Desktop Firefox, latest | **Not testable here** (no Firefox build; `playwright install` not permitted) | gap → owner | — |
| Desktop Safari, where testable | **Not testable here** (needs macOS) | gap → owner | — |
| Chrome on Android | **Emulated only:** Pixel 7 viewport, touch and mobile user agent in Chromium (C13, kind `emulated`). Not a device run | gap → owner | `*/11-android-emulated-grid.png`, `*/12-android-emulated-dialog.png` |
| Screen readers (NVDA/JAWS, VoiceOver, TalkBack) | **Not run.** The browser accessibility tree (what screen readers consume) was inspected through CDP instead. That is a proxy, not a screen-reader test | gap → owner | `*/ax-tree-*.json` |

Not covered: OS-level high-contrast modes and OS text-size settings. The browser font-size
preference was tested instead (C12).

## Checks

The checks are identical in both tested browsers. `<browser>/results.json` lists each check with
its `kind` and full detail.

**Kind `desktop`:** a real desktop browser window state, with no device emulation. 29/29 pass.

| Id | Check |
|---|---|
| C0 | No page errors during the desktop run |
| C1 | The semantics tree is present without Flutter's hidden "Enable accessibility" button (ready in ~1.3 s locally) |
| C2a–d | The grid is a **named** table ("Ushering rota: positions by Sunday") with row/columnheader/cell roles. 48 slot buttons are named "position, date: member, status". The heading, both filters, export and the tab list are named. The view toggle is a named radio group with a checked state |
| C3 | Every interactive node, table, list, tab list and dialog has a non-empty accessible name. Checked in 5 states: grid page, slot dialog, status menu, export dialog, list view |
| C4a–c | Tab follows visual order and DOM focus follows it (never `<body>` inside the app). The grid is a single Tab stop. Every stop has a role and a name |
| C5 | **Focus visibility for 28 controls:** the page Tab order, slot dialog fields and buttons, status menu options, export dialog buttons, and 6 of the 48 list "Change" buttons (sample). Each focused state must differ from an unfocused state of the same screen by a ≥3:1 contrast change over at least the area of a 2 CSS px perimeter of the control (the WCAG 2.2 SC 2.4.13 area rule). The comparison baseline is a step where focus sat on a non-adjacent control and the rest of the screen was unchanged, so a neighbour's ring or a scroll cannot count. Crops are in `focus/NN-focused.png` / `NN-unfocused.png`; figures are in `focus-visibility.json` |
| C6 | Arrow keys, Home/End and Control+Home/End move focus slot by slot and **clamp at all four edges**: left, top, right at the last column, and bottom at the last row. Focus scrolls into view |
| C7a–c | The slot dialog is role `dialog`, named by its title. Changing **both member and status**, then pressing Escape, leaves the slot unchanged and restores focus; doing the same and then pressing Cancel does too. A keyboard-only Declined edit saves, focus returns to the slot, and the change is announced politely |
| C8a–c | The **status filter** shows only matching slots; the others are labelled "hidden by status filter". A position plus status combination that matches nothing shows "No slots match…" and disables export with a reason. The position filter narrows rows |
| C9a | The export dialog is a named `dialog`. The preview states scope, columns, exclusions and the outside-access warning, and the **preview text** contains no phone number or care note |
| C9b | The downloaded CSV has a BOM, CRLF line endings, the allowlisted header and 24×5 cells. It is **byte-identical to `test/rota_trial/golden/door-export-after-edit.csv`**, which a widget test checks against `buildRotaCsv`. Every Member/Status value also equals the grid's accessible names for the same slot |
| C9c | Formula-led values led by `=`, `+`, `-`, `@`, tab, CR, **and leading spaces** are all prefixed with `'`. No field starts raw |
| C9d | No private field appears in the file |
| C9e | The announcement says "Download started: <file> (24 rows)." The app only observes the browser's save step, so it does not claim the file was saved |
| C10a–c | List alternative: 6 named lists, 48 items, 48 named Change buttons and level-2 headings. The Declined edit shows the same in **grid, list and CSV**. Change opens the same named dialog by keyboard |
| C11 | **Real 200% browser zoom.** The profile's default zoom preference is set to 200%: devicePixelRatio 2, a 683 CSS px window, no device emulation. All slots are exposed, there is no page-level horizontal scroll, and no text box is cut by the window edge. The far column is reachable by keyboard. **Both dialogs open and fit**, with all their buttons. The list fits |
| C12 | 200% browser font size (16→32 px root). Text renders at 2.03× and passes the same checks as C11, including both dialogs |
| C14 | Every visible interactive target is at least 44×44 CSS px, checked in 5 screen states |

**Kind `emulated`:** device emulation. 1/1 pass, and it counts towards no matrix entry.

| Id | Check |
|---|---|
| C13 | Pixel 7 emulation (viewport, touch, mobile user agent): the app boots, all slots are exposed, and a tap opens the named slot dialog |

Truncated text: the widget tests open the grid, the list, both dialogs and the member menu at 2×
text. They assert that no `RenderParagraph` exceeds its line limit or is ellipsised, and that no
layout overflows. Long member names now wrap in the dropdown (`itemHeight: null`, no ellipsis).
In the browser, C11 and C12 check geometrically that no text box is cut by the window or dialog
edge.

## Findings: Flutter Web issues found, and how the trial handled each

Entry 1.7 must carry these patterns into the shared design system:

1. **Browser Tab order ignores Flutter's `skipTraversal`.** The browser tabs through DOM
   `tabindex`, which follows `canRequestFocus`, so the grid slots are built on `InkWell`.
2. **`SegmentedButton` does not expose its selected segment, and its focus ring outlines the whole
   control.** It was replaced by a named radio group of two buttons, each with its own ring.
3. **`TabBar` shows focus only as a faint overlay.** That overlay is under 3:1 on the navy bar.
   Custom tabs (role `tab` in a named `tablist`) draw a white ring.
4. **Rings drawn on a filled control's edge have low contrast.** `FocusRing` draws the 3 px accent
   ring outside the control instead. Text fields use a 4 px focused border. Menu options use a
   near-solid accent highlight.
5. **`AlertDialog` is exposed as an unnamed `alertdialog`.** `TrialDialog` uses role `dialog`
   named by its title.
6. **`Table` has no accessible-name hook.** A small `Table`/`RenderTable` subclass adds the label.
7. **`Semantics(liveRegion: true)` produced no announcement in Chromium.** The app calls
   `SemanticsService.sendAnnouncement` after the dialog closes.
8. **`requestFocus()` does not scroll.** Keyboard moves call `Scrollable.ensureVisible`.
9. **Desktop default density is compact, which makes buttons 32 px tall.** The theme sets
   standard density with a 48 px minimum.
10. **Semantics must be forced on** (`SemanticsBinding.instance.ensureSemantics()`).
11. Flutter has **no row-header role**, so each slot's name carries both its position and its
    date.
12. When a route opens, Flutter puts programmatic focus on its heading (`tabindex=-1`). This is
    harmless, but it means the first Tab starts from the heading.
13. Text is painted to canvas, so find-in-page, text selection and browser translation do not
    work on page text. This is inherent to Flutter Web and acceptable for an app-style portal.
14. The sandbox reports `navigator.language` as `en-US@posix`, which crashes Flutter at start-up,
    so the harness pins `en-GB`. Real browsers report a valid tag.

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

1. Press Tab from the page top. Focus goes to the two tabs, Filter positions, Filter by status,
   Grid, List, Export, then one slot, then leaves the page. A clear ring is visible each time.
   In Safari, first turn on Settings → Advanced → "Press Tab to highlight each item on a
   webpage", or use Option+Tab.
2. Arrow keys move slot to slot and stop at every edge; End jumps to Sun 22 Nov, and the slot
   scrolls into view.
3. Press Enter on a slot, change Member and Status, then press Escape: the slot is unchanged.
   Repeat, change Status to Declined and Save. The slot reads "Declined", and the screen reader
   says "Saved. …".
4. Set Filter by status to Unfilled: only Unfilled slots remain. Type "Main door" in Filter
   positions and choose Draft: "No slots match" appears and Export is disabled.
5. Reset both filters, type "door", open Export CSV… and choose Download. The screen reader says
   "Download started…". Open the file in Excel, LibreOffice or Sheets. `=HYPERLINK(...)`,
   `=1+2`, `+Test Plus G`, `  =SUM(1,2)…` and similar values show as text (with a leading `'`),
   not as formulas or links. No phone numbers appear.
6. Choose List: every slot is a list item with a "Change …" button, and the Declined edit
   shows.
7. Zoom the browser to 200% (Ctrl/Cmd and +), or set the browser font size to Very large.
   Nothing is cut off, both dialogs fit, and the grid scrolls sideways inside its box.
8. On the phone: tap a slot, change it and save. Switch to List.

Record any failure against the browser. A failure in steps 1–6 with no app-level fix reopens Q10
(React/Next.js trial).
