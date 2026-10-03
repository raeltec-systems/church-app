# Runbook — platform-status tracer (story 1.1)

The tracer proves one read path end to end: Flutter client → Supabase Data API (`api` schema only) →
`api.platform_status` (security_invoker view) → `app.platform_status` (RLS). All data is synthetic.

Clients receive only the project URL and the **publishable** key, through `--dart-define`.
Never pass a secret/service-role key to a client and never commit one.

## Prerequisites

- Docker running (`sudo dockerd &` in a bare container).
- Node 22 and `npm ci` at the repo root (installs the pinned Supabase CLI 2.119.0).
- Flutter 3.47.6 / Dart 3.13.5. Linux desktop also needs `libgtk-3-dev`, `clang`, `cmake`, `ninja-build`.

## 1. Start the local stack

```sh
npm run db:start      # supabase start: applies supabase/migrations and supabase/seed.sql
npm run db:test       # pgTAP permission tests (supabase/tests/*.sql)
npm run db:smoke      # HTTP checks: api readable, app/public not exposed, writes denied
npx supabase status   # prints API_URL and PUBLISHABLE_KEY
npm run db:reset      # re-create the database from migrations + seed
```

## 2. Run the clients

```sh
export SUPABASE_URL=http://127.0.0.1:54321
export SUPABASE_PUBLISHABLE_KEY=<PUBLISHABLE_KEY from `npx supabase status`>

# Run each command from the repository root.

# Mobile, native Linux desktop target (interim native evidence)
(cd apps/mobile && flutter run -d linux \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY)

# Disposable staff web trial
(cd trials/staff_web && flutter run -d web-server --web-port 8080 \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY)
```

On an Android emulator use `http://10.0.2.2:54321` for the local stack; a physical phone should
use the hosted test project.

A build without both defines shows an "App not configured" screen rather than failing silently.

### Hosted test project

`bic-kafue-platform-test` (ref `tmurpotfluignacfueki`, eu-central-1) holds synthetic data only.
URL `https://tmurpotfluignacfueki.supabase.co`; take the publishable key from the dashboard
(Project Settings → API Keys) or the Supabase connector. It is not staging or production.

**Owner step (required once):** Dashboard → Project Settings → Data API → *Exposed schemas*: add
`api` and remove `public` and `graphql_public`; set *Extra search path* to `api`. Until then the API
answers `PGRST106 Invalid schema: api` and the clients show *"The server couldn't provide the
platform status"*.

Android APK against the hosted project:

```sh
cd apps/mobile
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<hosted publishable key>
# → build/app/outputs/flutter-apk/app-release.apk (debug-signed; test use only)
```

## 3. Change the status with SQL

Only a privileged role can write; clients cannot.

```sh
docker exec supabase_db_church-app psql -U postgres -c \
  "update app.platform_status set status = 'degraded', message = 'SYNTHETIC: changed by SQL', updated_at = now() where id = 1;"
```

Hosted: run the same `update` in the dashboard SQL editor. Then press **Reload** (top-right) in
either client; the new value appears. To see the empty state: `delete from app.platform_status;`
then reload ("No platform status recorded"); restore with `npm run db:reset` or re-run `supabase/seed.sql`.

## 4. Simulate a failure

- **API down (local):** `docker stop supabase_kong_church-app`, then reload → *"Couldn't reach the
  server"* with **Try again** (a load gives up after at most 10 s).
  `docker start supabase_kong_church-app`, then **Try again** → the current value returns.
- **Unreachable URL:** run a client with `--dart-define=SUPABASE_URL=http://127.0.0.1:9`.
- **Phone:** toggle airplane mode, reload, then turn it off and press **Try again**.

The old value is never kept on screen while a request runs or after it fails.

## Expected states

| State | Text |
|---|---|
| Loading | "Loading platform status…" with a spinner |
| Data | "Status: <status>", message, "Updated YYYY-MM-DD HH:MM UTC", "Synthetic test data" |
| Empty | "No platform status recorded" + Reload |
| Unreachable / timeout | "Couldn't reach the server" + Try again |
| Server error (e.g. schema not exposed) | "The server couldn't provide the platform status" + Try again |
