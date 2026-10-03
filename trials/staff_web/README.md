# staff_web_trial — DISPOSABLE

**This is a disposable Flutter Web trial, not the staff portal.** Architecture AD-16 treats
Flutter Web as a foundation spike only; `apps/staff` stays empty until the Q10 web-framework
decision. Delete this folder once Q10 is recorded. Do not import from it or build features on it.

It repeats the mobile tracer's read of `api.platform_status` (loading, data, empty and
error-with-retry states) to prove the browser path through Supabase.

```sh
flutter run -d web-server --web-port 8080 \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

See `docs/runbooks/tracer.md`.
