# Client shells, design system and request states (story 1.7)

## Layout

| Path | What it holds |
|---|---|
| `packages/design_system` (`church_design_system`) | Semantic tokens from `design-contract.md` (mobile light/dark, staff light, navy sidebar), geometry and type scale, `churchMobileTheme` / `churchStaffTheme`, and accessible primitives. |
| `packages/client_core` (`church_client_core`) | Domain ports (`CommandGateway`, `SessionRepository`, `PlatformStatusRepository`, `FixtureCounterReader`), Riverpod controllers, the shared tracer and fixture-command screens. `supabase_adapters.dart` holds the only Supabase code; `testing.dart` holds fakes. |
| `apps/mobile` | go_router shell with bottom tabs; light/dark follows the system. |
| `apps/staff` | Flutter Web shell (provisional Q10 selection) with a 232 px navy sidebar, switching to a navy top bar on narrow windows or large text. Semantics are forced on at startup. |
| `trials/staff_web` | The disposable 1.6 evidence app. Do not build on it. |

Each app's `lib/main.dart` is its composition root: it builds the Supabase client (URL and
publishable key from `--dart-define` only, `persistSession: false`) and overrides the port
providers. Presentation never imports Supabase; `client_core/test/boundaries_test.dart` and each
app's test enforce it, together with a ban on client persistence APIs.

## Accessible primitives (carried over from the 1.6 trial)

- `FocusRing`: a 3 px focus-token ring drawn *outside* each control (white on navy). Wrap each
  control on its own.
- `NavItem`: a tab (`role=tab` in a named tab list) built on `InkWell`, whose `canRequestFocus`
  drives the browser Tab order. After keyboard navigation the selected tab keeps focus.
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
| `unavailable` / `rate_limited` | unavailable | "nothing changed"; **Try again** resends the same envelope |
| timeout, abort, network failure, 502/503/504, bad body, mismatched id | unknown outcome | "Not confirmed"; inputs locked; **Check again** resends the same `request_id` and body; **Stop checking** keeps the outcome open |
| `unauthenticated` / `forbidden` / `not_found` | denied | specific text; entry kept |
| account switch or sign-out | account changed | counter, entry and in-flight results cleared; notice shown |

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

Browser smoke check of the staff shell (tracer value, Tab order and names, keyboard-only command,
narrow window and 200% font size); evidence goes to `evidence-1.7/`:

```sh
cd apps/staff
flutter build web --no-web-resources-cdn \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<local publishable key>
python3 -m http.server 8767 --bind 127.0.0.1 --directory build/web &
PLAYWRIGHT_MODULE=/opt/node22/lib/node_modules/playwright/index.mjs node tool/browser_smoke.mjs
```
