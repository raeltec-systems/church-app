# Client shells, design system and request states (story 1.7)

## Layout

| Path | What it holds |
|---|---|
| `packages/design_system` (`church_design_system`) | Semantic tokens from `design-contract.md` (mobile light/dark, staff light; `ChurchStaffChrome` for the light-only navy sidebar), `ChurchLayout` (body 16 / 15, page padding, staff max width 1280), type scale, `churchMobileTheme` / `churchStaffTheme` (mobile title 28/700 brand; staff white header, title 24/700), and accessible primitives. |
| `packages/client_core` (`church_client_core`) | Domain ports (`CommandGateway`, `SessionRepository`, `PlatformStatusRepository`, `FixtureCounterReader`), Riverpod controllers, the shared tracer and fixture-command screens, and the shared router (`buildClientRouter`, `goFromNav`). `supabase_adapters.dart` holds the Supabase adapters; `composition.dart` (`AppConfig`, `compositionOverrides`) is the composition root each app's `main.dart` calls; `testing.dart` holds fakes, `ClientTestHarness` and the `boundaryViolations` import checker. |
| `apps/mobile` | go_router shell with bottom tabs; light/dark follows the system. |
| `apps/staff` | Flutter Web shell (provisional Q10 selection) with a 232 px navy sidebar, switching to a navy top bar on narrow windows or large text. Semantics are forced on at startup. |
| `trials/staff_web` | The disposable 1.6 evidence app. Do not build on it. |

Each app's `lib/main.dart` is its composition root: it calls `compositionOverrides`, which builds
the Supabase client (URL and publishable key from `--dart-define` only, `persistSession: false`)
and overrides the port providers. Nothing else reaches Supabase or the adapters. The guards
resolve every import and export (package URIs and relative paths) with `boundaryViolations`:
`client_core/test/boundaries_test.dart` allows only `lib/src/adapters/`, `supabase_adapters.dart`
and `composition.dart`; each app allows only `lib/main.dart -> composition.dart`. Both also ban
client persistence APIs, and both have negative tests for the checker.

## Accessible primitives (carried over from the 1.6 trial)

- `FocusRing`: a 3 px focus-token ring drawn *outside* each control (white on navy). Wrap each
  control on its own. Like CSS `:focus-visible`, the ring shows only when the last input was a key
  press and the highlight mode is traditional (`FocusVisibility`): mouse clicks and taps leave no
  ring.
- `NavItem`: a tab (`role=tab` in a named tab list) built on `InkWell`, whose `canRequestFocus`
  drives the browser Tab order. After *keyboard* navigation (`goFromNav`) the selected tab keeps
  focus; a pointer tap does not move focus.
- `RequestStateBanner(focusNode:)`: a programmatic focus target (not a Tab stop) named by its
  title. Every request-state change moves focus to the banner it reports and announces it, so
  focus is never lost when a button is disabled or a banner action disappears.
- `RadioSegments`: segmented toggles as a named radio group (never `SegmentedButton`).
- `ChurchDialog`: role `dialog`, named by its title (never `AlertDialog`).
- `announce()`: `SemanticsService.sendAnnouncement` (never `liveRegion`); pass
  `kAnnouncementAfterDialog` after closing a dialog. Always show the same text persistently.
- `RevealOnFocus`: `Scrollable.ensureVisible` when keyboard focus lands.
- Themes use standard density, 48 px buttons and ≥44 px targets, a 4 px focused input border and a
  64 px app bar (room for a 48 px action plus its ring).
- Statuses always carry text (`StatusLabel`), never colour alone. Token contrast is tested.
- The shells use one navigator (no nested shell navigator), so keyboard traversal reaches both the
  navigation and the page.

## Request states (fixture command)

`FixtureCounterController` runs `fixture_counter.create` / `.increment` (story 1.4):

| Server/transport result | State | What the user sees and can do |
|---|---|---|
| sending | pending | "Sending…"; inputs read-only; nothing claims success |
| success envelope | confirmed | value and "Confirmed by server · revision N" |
| `validation_failed` | validation | field message; entry kept and editable |
| `conflict` on increment | conflict | entry kept; expected revision **not** replaced; Apply blocked until **Reload** succeeds |
| `unavailable` / `rate_limited` | unavailable | "nothing changed"; **Try again** resends the same envelope; editing the entry withdraws Try again (the edited input is a new request) |
| timeout, abort, network failure, any bare HTTP status without a PostgREST body (408, 3xx, 5xx, gateway 401…), bad body, mismatched id | unknown outcome | "Not confirmed"; inputs locked; **Check again** resends the same `request_id` and body; **Stop checking** keeps the outcome open, and resubmitting the same input reuses its `request_id` |
| no server configured | not sent | "Not sent: no server configured"; no retry |
| `unauthenticated` / `forbidden` / `not_found` | denied | specific text; entry kept |
| account switch or sign-out | account changed | counter, entry and in-flight results cleared; notice shown, focused and announced |

Protected state is memory-only and scoped to the account: AD-13 clears it on sign-out or account
change. It is kept while the user moves between destinations, so an unconfirmed command is still
checked under its own `request_id` rather than resubmitted.

The 1.4 fixture has no read endpoint, so Reload reports that honestly and the conflict stays
until a read view exists (a backend change recorded in the 1.7 plan, not made).

## Checks

```sh
# each of packages/design_system, packages/client_core, apps/mobile, apps/staff
flutter pub get --enforce-lockfile && flutter analyze && flutter test
(cd apps/staff && flutter build web --no-web-resources-cdn)
```

Live adapters against an already-running local stack (reads only; the signed-out command must be
refused as `unauthenticated`):

```sh
npx supabase status -o env > /tmp/local.env
(cd packages/client_core && dart run tool/live_local_check.dart /tmp/local.env)
```

Browser smoke check of the staff shell (tracer value, unique Tab stops to the end of the page,
focus-ring contrast per stop, keyboard-only command with focus on the result, narrow window and
200% font size); evidence goes to `evidence-1.7/`:

```sh
cd apps/staff
flutter build web --no-web-resources-cdn \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<local publishable key>
python3 -m http.server 8767 --bind 127.0.0.1 --directory build/web &
PLAYWRIGHT_MODULE=/opt/node22/lib/node_modules/playwright/index.mjs node tool/browser_smoke.mjs
```

Mobile shell on a native target (Linux desktop) against the local stack, as recorded in
`evidence-1.7/mobile-linux-live.txt`:

```sh
cd apps/mobile
flutter build linux --release --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<local publishable key>
Xvfb :99 -screen 0 1280x800x24 &
DISPLAY=:99 build/linux/x64/release/bundle/bic_kafue_mobile &
DISPLAY=:99 import -window root status.png   # then drive with xdotool
```
