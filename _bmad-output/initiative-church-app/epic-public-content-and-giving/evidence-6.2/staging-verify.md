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

## Not done here (owner)

Staging has no SYNTHETIC Media account whose password this agent holds. The signed-in part of the verify is therefore the owner's walkthrough in [content.md](../../../../docs/runbooks/content.md), "Story 6.2 ... Owner manual check on staging": upload the `SYNTHETIC Theme 2026` image and a campaign image, see an oversized file and a disguised file refused, publish both, and see the carousel on a signed-out phone. The same steps, run against the local stack's real GoTrue, PostgREST, Storage and Edge runtime, pass 15/15 (`content-banners-e2e.jsonl`).
