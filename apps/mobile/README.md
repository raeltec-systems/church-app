# bic_kafue_mobile

Flutter mobile client (Android, iOS; Linux desktop is used only as interim native evidence).
A go_router shell over the shared packages (`packages/design_system`, `packages/client_core`):
the platform-status tracer (story 1.1) and the synthetic fixture command with honest request
states (story 1.7). `lib/main.dart` is the composition root and the only file that touches
Supabase. See `docs/runbooks/tracer.md` and `docs/runbooks/client-shells.md`.

```sh
flutter run -d linux \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

Only the project URL and the publishable key may be passed to the client.
