# bic_kafue_mobile

Flutter mobile client (Android, iOS; Linux desktop is used only as interim native evidence).
Story 1.1 holds just the platform-status tracer. See `docs/runbooks/tracer.md` to run it.

```sh
flutter run -d linux \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

Only the project URL and the publishable key may be passed to the client.
