# Evidence: story 1.8, environments and promotion

Recorded 2026-10-03. All data is synthetic. No secret values appear here; the publishable key used for the build checks is public and is not recorded.

## 1. Staging environment marker on `bic-kafue-platform-test` (`tmurpotfluignacfueki`)

### Before

**Advisors.**
- `get_advisors security`: one finding, `rls_enabled_no_policy` (INFO) on 16 `app.*` tables. These tables are deny-all by design and reached only through the `api` schema, so marking the environment breaks nothing.
- `get_advisors performance`: `unindexed_foreign_keys` (INFO) on 6 contract registry tables. This is unrelated.

**Database state.** Raw result:

```json
[{"current_env":"production","history_rows":0,"gates":[{"gate":"q1_auth_recovery","state":"unresolved","has_fixture":false},{"gate":"q2_church_time","state":"unresolved","has_fixture":true},{"gate":"q4_personal_data","state":"unresolved","has_fixture":false},{"gate":"q9_money","state":"unresolved","has_fixture":true},{"gate":"q12_operations","state":"unresolved","has_fixture":false},{"gate":"private_access","state":"unresolved","has_fixture":false},{"gate":"outbound_sending","state":"unresolved","has_fixture":false}]}]
```

Marking the database `staging` only lets the labelled Q2 and Q9 fixtures resolve. `private_access` and `outbound_sending` have no fixture, so they stay closed.

### Set

The marker was set through `execute_sql`:

```sql
select app.platform_set_environment('staging','israel');
```

Raw result:

```json
[{"platform_set_environment":""}]
```

### After

Raw result:

```json
[{"current_env":"staging","history":[{"id":1,"environment":"staging","set_by":"israel","set_at":"2026-10-03T15:01:52.416109+00:00"}],"private_access_open":false,"outbound_sending_open":false,"q9_source":"fixture"}]
```

The body of `tools/ci/verify-hosted.sql` was run against staging through `execute_sql`, with the expected environment set to `staging`:

```json
[{"result":"verify-hosted: staging marker confirmed; private_access and outbound_sending closed"}]
```

### Staging Data API

These are the reads the published client makes, sent with the publishable key:

- `GET /rest/v1/platform_status` with `Accept-Profile: api` returned `[{"status":"operational","is_synthetic":true}]`.
- The same request with `Accept-Profile: app` returned HTTP 406, because the private schema is not exposed.

## 2. Migration history: local vs hosted staging

`list_migrations` (Supabase MCP) returned [`staging-hosted-migrations.json`](staging-hosted-migrations.json). The drift check then ran on that file:

```
$ node tools/ci/check-migration-drift.mjs --env staging --hosted-file …/staging-hosted-migrations.json --require-synced
check-migration-drift: staging (tmurpotfluignacfueki) in_sync
```

In CI, the same check fetches `GET /v1/projects/<ref>/database/migrations` with the `SUPABASE_ACCESS_TOKEN` secret. Until the owner adds that secret, the check skips with a notice.

## 3. Migration policy

```
$ node tools/ci/check-migrations.mjs
check-migrations: 5 migration(s) ordered, unique and non-destructive
$ node tools/ci/check-migrations.mjs --base 85eb9fd5a4aeea15a5888aead7fb5fea6067bbf9
check-migrations: 0 new migration(s) since base
check-migrations: 5 migration(s) ordered, unique and non-destructive (base 85eb9fd…)
```

A historical replay against `d437b2b~1` shows the rule rejects what really happened there. In that commit a merged migration was renamed to match the hosted version:

```
$ node tools/ci/check-migrations.mjs --base d437b2b~1
check-migrations: 20261003190000_cross_epic_contracts.sql: already-merged migrations cannot be renamed or deleted
check-migrations: 20261003134340_cross_epic_contracts.sql: version 20261003134340 must be later than the latest merged version 20261003190000
```

## 4. Secret scans and immutable client artifacts

**Repository scan.**

```
$ node tools/ci/scan-secrets.mjs
scan-secrets: clean (repo mode, 877 files)
```

**Staff web build configured for staging.** The build used `--dart-define` with the staging URL and the `sb_publishable_…` key. It was then scanned, sealed and verified:

```
scan-secrets: clean (bundle mode, 40 files)
package-web: sealed staff-web-staging for staging @ 85eb9fd5…: 40 files, tree ebba823751cd35eccbddbf853ceac613afa6cdda5bed88da7cfa26bba6cdc50e
package-web: verified staff-web-staging for staging @ 85eb9fd5…: tree ebba8237…
package-web: artifact was built for staging, not production        (verify --env production, exit 1)
```

**Negative build.** A synthetic secret-format value was passed as the client key: `sb_secret_` followed by a 34-character synthetic body, not a real key. The scan caught it:

```
scan-secrets: apps/staff/build/web/main.dart.js:8039 supabase_secret_key (sb_secret_…)
scan-secrets: 1 finding(s) in bundle mode — remove the value and rotate it        (exit 1)
```

A finding was dropped while building this. The bare prefix `"sb_secret_"` appears in `main.dart.js` because supabase-dart checks key prefixes as string literals. A real key (the prefix plus its body) is still flagged.

**CI-style unconfigured builds.** The `apps/staff` and `trials/staff_web` builds made without defines were also clean:

```
scan-secrets: clean (bundle mode, 78 files)
```

## 5. Verify-hosted SQL against the local stack

These runs were read-only or rolled back, and the local marker was left unset:

| Case | Result |
|---|---|
| Unmarked database | `ERROR: verify-hosted: database has no environment marker (owner step: …('staging', <name>))` |
| Marked staging inside a transaction, then rolled back | `NOTICE: verify-hosted: staging marker confirmed; private_access and outbound_sending closed` |
| Marked staging, but production expected | `ERROR: verify-hosted: database is marked staging, expected production` |

After these runs, `app.platform_environment_history` on the local database still has 0 rows.

## 6. Existing checks are still green

| Check | Result |
|---|---|
| `npm run db:test` | 201 tests, PASS |
| `npm run db:smoke` | PASS |
| `npm run contracts:test` | 226 pass |
| `npm run ci:policy-test` | 25 pass |
| `actionlint` 1.7.7 on `ci.yml` and `promote.yml` | no findings |

## Not demonstrated, because it waits on owner gates

- **A run of `promote.yml` from GitHub.** It needs the `staging` / `production` environments and their secrets.
- **The production baseline deployment.** The production project does not exist (owner-decisions-milestone-1.md).
- **A deploy to a static host.** No hosting account exists yet.

The exact steps are in `docs/runbooks/environments-and-promotion.md`, under **Owner steps**.
