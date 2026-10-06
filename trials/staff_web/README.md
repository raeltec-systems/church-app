# staff_web_trial — DISPOSABLE

**This is a disposable Flutter Web trial, not the staff portal.** Architecture AD-16 treats
Flutter Web as a foundation spike only. `apps/staff` is created by entry 1.7 after the Q10
selection. Do not import from this folder or build features on it.

It has two tabs:

- **Rota grid trial** (story 1.6, Q10): a SYNTHETIC duty rota (6 positions × 8 Sundays). It has a
  keyboard-operable grid (one Tab stop, then arrow keys, Home/End, Control+Home/End and Enter),
  an equivalent list view, position and status filters, a slot dialog that changes the member
  or status, and a CSV export. The export shows a preview first. It uses an allowlist of
  columns, neutralises spreadsheet formulas and includes no private fields. Every status has a
  text label.
- **Platform status** (story 1.1 tracer): the tab is always present. With Supabase
  `--dart-define`s it reads `api.platform_status`. Without them, it shows a "Platform status not
  configured" message.

## Run the app

```sh
flutter run -d web-server --web-port 8080
# optional tracer tab:
#   --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
#   --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

## Run the browser trial harness

`tool/browser_trial.mjs` drives a release build in Chromium through Playwright and CDP. It
writes screenshots, the accessibility tree, the keyboard log, the downloaded CSV and
`results.json` to `_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6/<label>/`.

```sh
flutter build web --no-web-resources-cdn
python3 -m http.server 8766 --bind 127.0.0.1 --directory build/web &
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs BROWSER_LABEL=chromium node tool/browser_trial.mjs
# another Chromium-family browser (e.g. Chrome or Edge):
CHROMIUM_EXECUTABLE=/path/to/chrome BROWSER_LABEL=chrome node tool/browser_trial.mjs
```

The harness byte-compares the downloaded CSV with
`test/rota_trial/golden/door-export-after-edit.csv`. A widget test checks that same file against
`buildRotaCsv`. To regenerate it after a fixture change, run
`UPDATE_GOLDEN=1 flutter test test/rota_trial/rota_trial_screen_test.dart`.

The harness uses CDP, so it runs only on Chromium-family browsers. Firefox, Safari, Android
Chrome and real screen readers need the manual spot-check in `evidence-1.6/README.md`.

See `docs/runbooks/tracer.md` for the tracer.
