---
title: 'Establish the selected client shells and safe request states'
type: 'feature'
ticket: '7'
created: '2026-10-03'
status: 'built'
baseline_revision: 'd55a57d1ef544a396968dfe6646e9cbcd84a5c58'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/spec-church-app/design-contract.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Both clients are still tracer scaffolds with screen-local colours, no shared accessible primitives, no Riverpod/go_router, no contract wiring and no honest write states. Feature epics need one design system, one client contract adapter and one request-state pattern on mobile and the (provisionally selected) Flutter Web staff client before they build screens.

**Approach:** Add `packages/design_system` (semantic tokens: mobile light/dark, staff light; geometry; the 1.6 accessible primitives) and `packages/client_core` (domain ports, `church_contracts`-based Supabase adapters, Riverpod session/protected-state/command controllers, shared tracer and fixture-command screens). Create `apps/staff` from the 1.6 learnings and rebuild `apps/mobile` on both packages with go_router shells. Exercise the 1.4 `fixture_counter` command through honest pending, validation, conflict, unavailable, unknown-outcome and account-changed states, with widget tests for each.

## Decisions

- Decision (agent, under owner pre-approval): staff web is built on the **provisional** Flutter Web selection (1.6). A failed owner spot-check reopens Q10; only `apps/staff` presentation would be replaced, since domain, adapters and contracts stay framework-neutral at the wire.
- Decision (agent, under owner pre-approval): shared application code lives in a new `packages/client_core` (Flutter package `church_client_core`). Only `lib/src/adapters/` imports `supabase`/`http`; a guard test enforces it. Apps are composition roots (adapters + provider overrides) and shells.
- Decision (agent, under owner pre-approval): a transport failure after a command may have been sent (abort/timeout, `ClientException`, 502/503/504, a malformed or mismatched 200 body) is **unknown outcome**: inputs lock, "Check again" resends the identical envelope with the same `request_id`; success is never inferred. A server error envelope is a definite outcome.
- Decision (agent, under owner pre-approval): `request_id` is generated once per submitted input and reused for every retry of it; it changes only when the user edits after a definite outcome or starts a new command.
- Decision (agent, under owner pre-approval): conflict keeps the user's input, never adopts `current_revision`, and offers Reload. The 1.4 fixture has no read endpoint (1.4 decision), so the Supabase adapter's reload reports `unavailable` honestly; a fixture read view is a backend/contract change recorded here, not made.
- Decision (agent, under owner pre-approval): protected fixture state (counter snapshot, form input, in-flight result) is Riverpod memory scoped to the current account; any account change or sign-out disposes it, discards late responses and shows an "account changed" notice. No client persistent storage; Supabase auth stays `persistSession: false`. No sign-in UI (identity epic): signed-out commands get the server's honest `unauthenticated`.
- Decision (agent, under owner pre-approval): typography sizes/weights are tokens; the Outfit/Figtree/JetBrains Mono font files are not bundled yet (platform fonts), deferred to the first feature screen that needs them.
- Decision (agent, under owner pre-approval): live backend use is limited to calling the already-running local API with the publishable key (no `supabase start/reset`, no SQL, no user creation). Success paths are proven with fakes.

## Boundaries & Constraints

**Always:** presentation calls ports/controllers only; contract types from `church_contracts`; every status has a text label; 3 px accent focus ring outside each control; ≥44 px targets; dialogs role `dialog` named by title; InkWell `canRequestFocus` roving stops; radio semantics for segmented toggles; `SemanticsService.sendAnnouncement` (not liveRegion); `Scrollable.ensureVisible` on keyboard focus; `ensureSemantics()` at startup in staff; locked dependencies; synthetic labelled data.

**Never:** edit contract rules/fixtures, `supabase/`, `trials/` or other lanes' files; membership screens or role-authorized navigation; persistent storage of protected state; silently replace `expected_revision`; claim success without a server success envelope; secrets in repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pending | Submit create/increment | "Sending…", inputs read-only, submit disabled, no success text | — |
| Success | Server success envelope | Value + "Confirmed by server, revision N" | — |
| Validation | `validation_failed` with field_errors | Field-level message; input kept and editable | — |
| Conflict | `conflict` + current_revision | Input kept; expected_revision unchanged; Reload offered; submit blocked until reload | Reload unavailable → stays in conflict with reason |
| Unavailable | `unavailable`/`rate_limited` | "Service unavailable", input kept, Try again | Same request_id |
| Unknown outcome | Timeout/abort/network/5xx-gateway/bad body | "Not confirmed", inputs locked, Check again resends same request_id + body | Never shows success |
| Denied | `unauthenticated`/`forbidden`/`not_found` | Specific text, input kept | — |
| Account change | Account id changes or signs out (incl. mid-request) | Protected state cleared, late response discarded, notice shown | — |
| Text scale 2.0 / keyboard | Both shells, both screens | No overflow; Tab reaches every control in order with a visible ring | — |

</frozen-after-approval>

## Code Map

- `apps/mobile/lib/{main,config}.dart`, `lib/platform_status/*` -- 1.1 tracer (port, Supabase adapter with `retry(enabled:false)` + abort signal, screen). Move port/adapter/screen into `client_core`; keep `MainApp`/`MissingConfigScreen` names for tests; keep `persistSession:false`.
- `apps/mobile/test/platform_status/*` -- tracer tests (MockClient adapter tests, FakeRepository with completers); move with the code.
- `trials/staff_web/lib/main.dart`, `lib/rota_trial/rota_trial_screen.dart` -- source of `FocusRing`, `TrialDialog`, radio view toggle, custom tabs, `_announce`, `_activate`, theme (standard density, 48 px min, 4 px input focus border). Copy patterns; do not edit or delete `trials/`.
- `packages/contracts/dart/lib/src/models.dart` -- `CommandRequest`, `CommandResponse`/`CommandSuccess`/`CommandError`, `ErrorCode`, `Optional<T>`, `ContractViolation`; consume as path dependency, do not edit.
- `supabase/migrations/20261003131021_command_foundation_hardening.sql` -- `api.fixture_counter_command(jsonb)`; commands `fixture_counter.create {intent_key}` (expected_revision null) and `fixture_counter.increment {counter_id, by}`; data `{id, intent_key, value, is_synthetic, updated_at}`. No read endpoint.
- `docs/runbooks/command-foundation.md` -- `POST /rest/v1/rpc/fixture_counter_command`, `Content-Profile: api`, timeout = retry same request_id.
- `.github/workflows/ci.yml` `flutter` job -- add design_system, client_core, staff steps; keep existing steps.
- `docs/runbooks/tracer.md` -- update mobile paths; add staff run command.

## Tasks & Acceptance

**Execution:**
- [x] `packages/design_system/` -- tokens (ThemeExtension light/dark), staff/mobile themes, `FocusRing`, `ChurchDialog`, `RadioSegments`, `NavItem`, `StatusLabel`, `RevealOnFocus`, `announce`, `RequestStateBanner`; tests (contrast ratios, focus ring, dialog semantics, radio semantics, targets).
- [x] `packages/client_core/` -- domain (`PlatformStatus`, `CommandGateway`, `FixtureCounter`, `SessionRepository`, request states), adapters (`SupabaseCommandGateway`, `SupabasePlatformStatusRepository`, `SupabaseSessionRepository`), Riverpod providers/controllers, shared screens; tests per matrix row, adapter MockClient tests, import-boundary and no-persistence guard tests.
- [x] `apps/staff/` -- `flutter create --platforms web --empty`; go_router shell with navy sidebar (narrow: top bar), ensureSemantics; widget tests (fixture flow, keyboard, 2.0 text scale).
- [x] `apps/mobile/` -- rebuild on packages with go_router + light/dark; same widget tests.
- [x] `.github/workflows/ci.yml`, `docs/runbooks/tracer.md`, `docs/runbooks/client-shells.md` -- CI steps; how to run both shells.

**Acceptance Criteria:**
- Given each Flutter package/app, when `flutter pub get --enforce-lockfile && flutter analyze && flutter test` run, then all pass; `apps/staff` `flutter build web` succeeds.
- Given the running local stack, when either shell's tracer and fixture command run with the publishable key, then the status shows and a signed-out command shows `unauthenticated`, not success.

## Implementation Notes

Implemented 2026-10-03 directly (no subagent tool in this session).

**What landed**
- `packages/design_system`: `ChurchColors` ThemeExtension (all design-contract tokens, light/dark, sidebar), `ChurchGeometry`, `ChurchType`, `churchMobileTheme(brightness)` / `churchStaffTheme()`; primitives `FocusRing`, `RevealOnFocus`, `announce`, `ChurchDialog`, `RadioSegments`, `NavItem` (tab role, InkWell, optional autofocus), `StatusLabel`, `RequestStateBanner`. 11 tests: WCAG contrast of every text pair and the focus ring in both palettes, ring follows focus, dialog role/name, radio group checked state, tab role + 44 px, 2x text.
- `packages/client_core`: tracer port/adapter/screen moved here from `apps/mobile` (renames, tests kept); `CommandGateway`/`CommandOutcome` (confirmed / refused / unknown), `SecureRequestIds`, `SessionRepository`, `FixtureCounter` + `NoFixtureCounterReadEndpoint`; `AccountController` (generation per account change) and `FixtureCounterController`; `FixtureCommandScreen`, `PlatformStatusDestination`; adapters `SupabaseCommandGateway` (rpc on `api`, no retry, abort timeout, outcome rules), `SupabaseSessionRepository`; `testing.dart` fakes; `tool/live_local_check.dart`. 50 tests.
- `apps/staff` (new, `flutter create --platforms web --empty`): composition root with `ensureSemantics()`, go_router, navy 232 px sidebar → top bar when narrow or at large text. 9 tests. `tool/browser_smoke.mjs` Playwright check.
- `apps/mobile`: rebuilt on both packages; bottom tabs; system light/dark. `http` is no longer a direct dependency. 8 tests.
- CI `flutter` job: design system, client core and staff pub get (locked) / analyze / test, staff `build web --no-web-resources-cdn`; existing steps unchanged. Runbooks: new `docs/runbooks/client-shells.md`; `tracer.md` gains the staff run command.

**Surprises / decisions during build**
- Changing a widget key on `FocusRing`'s container remounted the child and dropped focus; the ring is now a pure decoration change.
- go_router `ShellRoute` nests a navigator whose route focus scope confined Tab to the page (the sidebar was unreachable in widget traversal). Shells now wrap each page in a single navigator (`NoTransitionPage`), with `WidgetOrderTraversalPolicy` (navigation first, as the browser DOM order does). Navigation rebuilt the shell and lost focus to `flutter-view` in Chromium; tab-initiated navigation now passes `NavFocusRequest` and the selected tab autofocuses (browser S3 confirms).
- The AppBar squeezed a ringed 48 px IconButton to 42 px; themes use a 64 px toolbar.
- `PostgrestException.code` is a PG/PGRST code when PostgREST answered and the bare HTTP status otherwise; only a 3-digit code is read as a status (`42501` is not an HTTP status).
- `supabase` exports its own `ErrorCode`; adapters import it with `hide ErrorCode`.
- Flutter 3.47.6 web builds ship a self-unregistering `flutter_service_worker.js`: no response cache.

**Verification**
- `flutter pub get --enforce-lockfile && flutter analyze && flutter test`: design_system 11/11, client_core 50/50, mobile 8/8, staff 9/9; no analyzer issues. `apps/staff` `flutter build web --no-web-resources-cdn` succeeds. `packages/contracts`, `trials/` and `supabase/` untouched.
- Live, local stack already running (API calls only, publishable key, no session, nothing written): `dart run tool/live_local_check.dart` → tracer `operational`, signed-out `fixture_counter.create` → `refused: unauthenticated`.
- Browser (Playwright Chromium 141, release build against the local API): 6/6 in `evidence-1.7/results.json` — S1 tracer value, S2 Tab starts at the named tabs and every stop has role+name, S3 keyboard-only command refused honestly and focus stays on the selected tab, S4 no page errors, S5a 390 px and S5b 200% root font: no page-level horizontal scroll (screenshots alongside).
- Not done here (this lane may not create users or grants): a live *successful* write. Success, conflict and unknown paths are proven with fakes and adapter MockClient tests.

**Matrix audit** (each covering test ran and passed):
- Pending, Success, Validation, Conflict (reload unavailable and reload success), Unavailable (same envelope resent), Unknown outcome (same id + body; Stop checking; malformed success body), Denied ×3, Account change (switch; sign-out mid-request with late response dropped): `client_core/test/fixture/fixture_command_screen_test.dart`; transport mapping in `test/adapters/supabase_command_gateway_test.dart`; staff/mobile app tests repeat create/conflict/account change.
- Text scale 2.0 / keyboard: client_core 2x tests (light + dark) and Tab order test; staff 2x desktop/narrow + sidebar→top bar; mobile 2x light/dark; both shells' Tab order and focus retention; browser S2/S3/S5.

**Review follow-up (2026-10-03, coordinator review).** Each finding was fixed with the smallest change that does the job:
- **Focus.** `RequestStateBanner(focusNode:)` is now a programmatic focus target named by its title; it is not a Tab stop and not a heading. Every request-state transition moves focus to the banner it reports. This covers submit, Try again, Check again, Stop checking and Reload. The account notice takes focus; Dismiss returns focus to Intent key.
- **Stale retry.** After `unavailable`, editing an input withdraws Try again (`inputChanged()`), so the next submit is the edited input with a new id. `canRetry` gates the action.
- **Request ids.** Stop checking keeps the command as `unconfirmed`. Resubmitting the same input (same command, revision and payload) reuses its `request_id`; a changed input gets a new one. The first definite outcome for that id settles it.
- **Announcements.** Every banner change is announced through `SemanticsService.sendAnnouncement`, with its own message: sending, every outcome, "Couldn't reload. <reason>", "Reloaded. …", "Stopped checking. …", not sent, and account changed or signed out.
- **Focus rings after pointer use.** `FocusVisibility` (design system) works like `:focus-visible`: rings show only when the highlight mode is traditional *and* the last input was a key press. A desktop mouse click, which keeps the traditional mode, therefore shows no ring. `goFromNav` asks the shell to refocus the tab only after keyboard activation.
- **Boundary guards.** The guards now resolve every import and export directive, both package URIs and relative paths, through the shared `boundaryViolations` in `testing.dart`. client_core allows only `lib/src/adapters/`, `supabase_adapters.dart` and `composition.dart`. Each app allows only `lib/main.dart -> composition.dart`. Negative tests cover relative adapter imports, barrel re-exports, and the adapter and composition package URIs.
- **Live evidence.**
  - The mobile shell ran natively (Linux desktop, Xvfb) against the running local stack. Raw output is in `mobile-linux-live.txt`, screenshots in `04-…`/`05-…`: the tracer showed `Status: operational`, and the signed-out Create showed "Not saved: sign-in required".
  - The `live_local_check` output is stored in `live-local-check.txt`.
- **Browser smoke: 7/7.**
  - S1 records the tracer value.
  - S2 tabs until focus wraps or leaves the page, and asserts unique stops with role and name.
  - S3 is new: a 1.6 C5-style contrast-change check on every stop (7 controls, crops in `focus/`).
  - S4 asserts that focus lands on the refusal banner.
  - S6a/b replace the old S5a/b.
- **Test names.**
  - "protected state is dropped when leaving and returning" became "an account switch drops the protected state". A real leave/re-enter test shows the state is kept and checked again under the same id. Decision (agent, under owner pre-approval): AD-13 clears protected state on sign-out or account change, not on navigation. Keeping it across navigation prevents an unconfirmed command from being resubmitted under a new id.
  - The unconfigured test now sends a command. `UnconfiguredCommandGateway` returns a new `CommandNotSent` outcome, shown as "Not sent: no server configured" with no retry.
- **Tokens.**
  - The dark focus ring is the dark accent `#3D9BF5`.
  - The sidebar tokens moved out of `ChurchColors` into the light-only `ChurchStaffChrome`. The invented dark values are gone.
- **Typography and layout.** New `ChurchLayout` extension: mobile body 16 and padding 16; staff body 15, padding 28/32/48 and max width 1280. App bar titles: mobile 28/700 brand; staff 24/700 `#14246B` on a white header with a bottom line and title spacing 32. Mobile tab labels are 11.5.
- **Duplication.** `AppConfig` and `compositionOverrides` (`composition.dart`), plus `buildClientRouter`, `goFromNav`, `NavFocusRequest`, `ClientPaths` and `ClientTestHarness`, now live in client_core. Each app keeps only its shell layout. The apps' `config.dart` files are removed, and `supabase_flutter` is now a dependency of client_core only.
- **Mobile safe area.** The shell removes bottom padding from the page (`MediaQuery.removePadding`), and the tab bar's `SafeArea` applies the inset once. A test simulates a 34 px bottom inset.
- **Gateway.** Only a PostgREST-bodied error (a SQLSTATE or a PGRST code) is definite. Any bare status (408, 3xx, 429, a gateway 401, 404 HTML, 5xx) is now unknown outcome; tests cover each.
- **Verification.**
  - `pub get --enforce-lockfile`, `analyze` and `test` pass in all four packages: design_system 14, client_core 72, mobile 13, staff 13.
  - The staff web release build and the browser smoke against the local API passed 7/7.
  - The mobile Linux release build and the live run passed.
  - `trials/`, `supabase/` and `packages/contracts` are untouched.

## Plan Change Log

- 2026-10-03, review follow-up (coordinator review findings):
  - **Findings:** fourteen, listed in Implementation Notes under "Review follow-up".
  - **Amended:**
    - Frozen decision refined: `request_id` reuse now also covers an unchanged input after Stop checking. Editing after `unavailable` withdraws the retry.
    - Frozen decision (memory-only protected state) clarified: the state is kept across navigation and dropped on any account change. A new definite outcome type, `CommandNotSent`, was added for unconfigured builds.
    - Gateway rule tightened: bare HTTP statuses are unknown outcome.
  - **Avoids:**
    - keyboard focus dropped to the page on state changes;
    - a stale body resent after an edit;
    - duplicate ids for one input;
    - silent state changes for screen-reader users;
    - focus rings that persist after a mouse click or tap;
    - adapter leaks the guards could not see;
    - a double safe-area inset;
    - proxy statuses wrongly read as "nothing changed".
  - **KEEP:**
    - the single-navigator shells;
    - the outside 3 px ring;
    - the tab `NavItem` on `InkWell`;
    - account-generation keyed forms;
    - the honest unavailable Reload until a fixture read view exists.

## Review Triage Log

**Pass 1 (quick lens, independent reviewer), 2026-10-03.** Verdicts: high 3 · medium 8 · low 3 · false 0. All 14 were patched.

| # | Finding | Verdict | Route | Action |
|---|---------|---------|-------|--------|
| 1 | Focus is lost on every request-state transition | high | patch | Make focus deterministic, and add tests plus a browser assertion. |
| 2 | Try again resends a stale body while the field stays editable | high | patch | Lock inputs, or drop the submitted body on edit. |
| 3 | Stop checking resends the same input under a new `request_id` | medium | patch | Keep the id for unchanged input. |
| 4 | Account change, sign-out, reload failure and stop are not announced | medium | patch | Announce each one via `sendAnnouncement`. |
| 5 | Pointer and touch tab taps leave a permanent focus ring | medium | patch | Use `highlightMode`-aware rings and keyboard-only focus requests. |
| 6 | Boundary guards miss relative imports and adapter re-exports | medium | patch | Check resolved paths, with negative tests. |
| 7 | Mobile shell never run live; live check output not stored | medium | patch | Run it under Xvfb read-only and store the outputs. |
| 8 | S2 counts repeated stops as unique; S1 is empty; no ring check | medium | patch | Assert unique stops and the tracer value, and add a ring check. |
| 9 | Test names overstate; the unconfigured build sends no command | low | patch | Write honest tests and show the "no server configured" message. |
| 10 | Dark focus ring uses the link colour; invented dark sidebar tokens | medium | patch | Use the contract accent and remove the invented tokens. |
| 11 | Typography and staff layout tokens are not applied | medium | patch | Apply the design-contract values. |
| 12 | Code duplicated between the apps | low | patch | Move shared composition into `client_core`. |
| 13 | Mobile bottom safe area padded twice | low | patch | Remove the inner bottom padding. |
| 14 | Bare 3xx/4xx treated as a definite "nothing changed" | high | patch | Treat only PostgREST-bodied 4xx as definite; anything else is an unknown outcome. |

## Verification

**Commands:**
- `cd packages/design_system && flutter analyze && flutter test` -- pass
- `cd packages/client_core && flutter analyze && flutter test` -- pass
- `cd apps/mobile && flutter analyze && flutter test` -- pass
- `cd apps/staff && flutter analyze && flutter test && flutter build web` -- pass
