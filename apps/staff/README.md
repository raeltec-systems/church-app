# bic_kafue_staff

Staff web portal shell (Flutter Web). Flutter Web is **provisionally** selected by the story 1.6
trial, pending the owner's browser and screen-reader spot-check
(`_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6/README.md`). If that
reopens Q10, only this app's presentation is replaced; contracts and the API stay.

The current portal has navigation filtered by live roles and scopes, including membership,
cell programmes, duties/follow-ups and Content administration. Signed-out users see the
current sign-in experience; the old story 1.7 tracer destinations are not the acceptance flow.

Use the [owner walkthrough](../../docs/runbooks/content-owner-walkthrough.md) for current
setup, fictional roles, normal navigation, negative permissions and recovery cases. A passing
build or widget suite does not replace the outstanding owner browser/accessibility check.

```sh
flutter run -d web-server --web-port 8081 \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

Only the project URL and the publishable key may be passed to the client. Backend adapters
are composed through shared client core. The original `tool/browser_smoke.mjs` targets the
story 1.7 tracer navigation and is historical evidence; do not interpret its old signed-out
navigation assertions as the current app contract.
