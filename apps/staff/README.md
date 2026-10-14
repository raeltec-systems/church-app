# bic_kafue_staff

Staff web portal shell (Flutter Web). Flutter Web is **provisionally** selected by the story 1.6
trial, pending the owner's browser and screen-reader spot-check
(`_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6/README.md`). If that
reopens Q10, only this app's presentation is replaced; contracts and the API stay.

It holds platform destinations only (platform status, synthetic fixture command). Real staff
navigation, filtered by granted roles and scopes, arrives with the identity epic.

```sh
flutter run -d web-server --web-port 8081 \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

Only the project URL and the publishable key may be passed to the client. `lib/main.dart` is the
composition root and the only file that touches Supabase. See `docs/runbooks/client-shells.md`
for the browser smoke check (`tool/browser_smoke.mjs`).
