# Story 6.2 on staging (`tmurpotfluignacfueki`), 2026-10-22

All SYNTHETIC. Production was not touched.

## Migration

- Applied verbatim through the Supabase connector (`apply_migration`, name `content_rights_banners`). Staging recorded it as **`20261022012809`**, after entries 3 (`20261022011438_content_giving_methods`) and 13 (`20261022011557_content_announcements`), and the local file was renamed to that version.
- Before the apply: `postgres` bypasses RLS and may insert into `storage.buckets` and read `storage.objects`; no bucket and no `storage` policy existed.

## Function hashes against the fresh local reset

`md5(replace(pg_get_functiondef(oid), chr(13), ''))` was computed for each of the 56 `app`/`api` functions this migration creates. It was computed on staging and on the local database right after `npx supabase db reset --local` (which ran this migration with the full suite green, 59 files / 4638 tests). **All 56 are identical** (comparison output: `compared 56`, no `DIFF` line). Entries 3 and 13 replaced or added other `content_%` functions on staging, so the hash over every `content_%` function differs by design; this entry replaces none of them.

## Guards and objects on staging

| Check | Answer |
|---|---|
| `app.contract_boundary_violations()` | 0 |
| `app.contract_unowned_objects()` | 0 |
| `app.contract_unpinned_functions()` | 0 |
| Buckets | `content-drafts` public = false, `content-public` public = true, both 10485760 bytes |
| `pg_policies` in schema `storage` | 0 |
| `q5_content_rights` | `unresolved`, labelled fixture present (honoured only because staging is marked `staging`) |
| Content kinds | announcement, asset, banner, event, giving_method, rights |

## Edge Function

`content-assets` was deployed through the connector (`deploy_edge_function`, files `index.ts`, `logic.mjs`, `../_shared/system_access.mjs`, `verify_jwt = false`) and is ACTIVE at version 1. It needs no secret of its own.

## Signed-out probes (publishable key only, nothing written)

| Probe | Result |
|---|---|
| `OPTIONS content-assets?action=sync` (a foreign origin) | 204, `access-control-allow-origin: *`, no `allow-credentials` |
| `POST content-assets?action=sync` without a session | 401 `{"outcome":"unauthenticated"}` |
| `POST content-assets?action=upload...` without a session | 401 |
| `POST content-assets?action=sync` with the legacy anon JWT as bearer | 401: the function reached PostgREST, which refused `anon` |
| `GET content-assets?action=preview...` with the anon JWT | 401 |
| `POST content-assets?action=delete` | 400 `invalid_action` |
| `rpc/content_public_banners` | 200 `{"banners": [], "truncated": false}` |
| `rpc/content_staff_banners`, `content_staff_rights`, `content_file_plan` as anon | 401 each |
| `storage/v1/object/list/content-drafts` and `content-public` as anon | 200 with 0 objects listed (no policy) |
| `storage/v1/object/public/content-drafts/...` and `content-public/...` (absent path) | 400 each |
| Anonymous upload into either bucket through Storage | 400 each (refused) |
| `rest/v1/content_assets`, `content_banner_revisions`, `content_rights_revisions` (profile `app`) | 406 (schema not exposed) |

## Follow-up F3 on staging (`tmurpotfluignacfueki`), 2026-10-22

- Before apply, the latest migration was `20261022102525_f2_church_owned_q5_exemption`; the required `20261022012809_content_rights_banners` was present. F3 was applied verbatim as `content_asset_retention`. Staging recorded hosted version `20261022112247`, so the local file and promotion/runbook references use `20261022112247_content_asset_retention.sql` per the handoff rule.
- `content-assets` is ACTIVE v2 (`verify_jwt = false`, SHA-256 `8aac3953e691a7d1b43410bd901c48fd6b6e435df49be6786e627300c82d2cb1`); `notifications-worker` is ACTIVE v10 (`verify_jwt = false`, SHA-256 `3c36547e36a46990e4ae6474dcc09ef23f5998762b43be6901e29d01ef40b7f7`). Both match the deployed source bundles.
- The 12 relevant `app`/`api` function definition hashes match a fresh local reset: `api.content_asset_preview` (`e4bc47e425ff8b97ad5c9b36335280c7`), `api.identity_my_access` (`22c28650d7a8ba1e9bf9919713735481`), `app.content_asset_complete` (`bb7acea096113104c8c59914a6dfe65d`), `app.content_asset_error` (`9cc394092342692c9b259662bd0d54fc`), `app.content_asset_preview` (`de8a86253e1842c9f6a7f768834c51d4`), `app.content_asset_retention_check_claim` (`8431db719ae8854a254724257d31278a`), `app.content_asset_retention_check_finalize` (`b35266218e1b101548101d09de3a23a5`), `app.content_asset_retention_claim` (`7463a724a706361a3546f053b1f23d54`), `app.content_asset_retention_finalize` (`85b18819308c45738df782eb5af3c34a`), `app.content_file_attach` (`1b252f1ccbfd462dbaa7499323287872`), `app.content_rights_clear` (`f6967934d6f108892ad7eaab8cd07600`), and `app.identity_my_access` (`f90ed5aeb6ec2ba9fafdd8a737838a36`).
- `app.contract_boundary_violations()`, `app.contract_unowned_objects()` and `app.contract_unpinned_functions()` each returned 0. The two registered commands both use purpose `content_asset_retention`; no staging principal or grants exist yet. `content_assets` has both claim columns and no table grants to `anon`, `authenticated` or `service_role`.
- `q3_giving` and `q5_content_rights` remain `unresolved`. The signed-out `api.content_public_banners()` read returned `{"banners": [], "truncated": false}`.
- The existing scheduler remains active with one job. No staging worker was manually invoked and no notification was created by this verification. The status snapshot showed 0 due notifications, 0 pending push jobs and 0 content-announcement jobs; the existing staging database had 43 notification jobs, 14 inbox items and 10 push jobs total.
- The retention path is deployed but remains fail-closed until the owner creates the staging `content_asset_retention` principal, registers its digest, and sets `CONTENT_ASSET_RETENTION_SYSTEM_CREDENTIAL` plus the existing Vault trigger copy as secrets on `content-assets`. See `content.md`, Story F3. No raw secret was read or logged.

## Not done here (owner)

Staging has no SYNTHETIC Media account whose password this agent holds. The signed-in part of the verify is therefore the owner's walkthrough in [content.md](../../../../docs/runbooks/content.md), "Story 6.2 ... Owner manual check on staging": upload the `SYNTHETIC Theme 2026` image and a campaign image, see an oversized file and a disguised file refused, publish both, and see the carousel on a signed-out phone. The same steps, run against the local stack's real GoTrue, PostgREST, Storage and Edge runtime, pass 15/15 (`content-banners-e2e.jsonl`).
