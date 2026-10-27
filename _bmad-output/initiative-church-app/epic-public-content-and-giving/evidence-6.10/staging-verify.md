# Entry 6.10 staging verification (2026-10-27)

Project `tmurpotfluignacfueki` (staging). Production was not touched; no content was published, no rights record or gate changed, no notification was sent.

- Before the apply: staging's latest versions were `20261027182223` (6.8), `20261027140149` (6.11) and `20261027083618` (6.9). Entries 11 and 8 replace no sermon function, so this migration builds on 6.9's definitions.
- Applied `supabase/migrations/20261027191003_content_sermon_facebook_video.sql` verbatim through the Supabase MCP `apply_migration`; staging records version `20261027191003` (the local file was renamed from `20261027183503`).
- Function hashes, `md5(replace(pg_get_functiondef(oid), chr(13), ''))`, staging = fresh local reset (all 7 match):

| Function | Hash |
|---|---|
| app.content_public_sermon_json | 6feedf8caeae5e8d1a75fd8f698dfd74 |
| app.content_sermon_create | 8116ebd4821db0d458c30d83ce291c52 |
| app.content_sermon_facebook_url | 5c67dd6db64b68992ed7ecc54da7fc2c |
| app.content_sermon_publish | c22a55fe60396a6907a1b65fcc50725e |
| app.content_sermon_revision_guard | 6af2f73fbde913f3c38577bff04c9663 |
| app.content_sermon_revision_json | 61a5445385521b27d6b9b1eeba2c1057 |
| app.content_sermon_save | 7559f30cedd9e529638504045d704c96 |

- `app.contract_boundary_violations()` = 0; `app.contract_unowned_objects()` = 0.
- `app.content_sermon_facebook_url(jsonb)`: not executable by anon or authenticated. Sample answers on staging: an m.facebook.com video link normalises to `https://www.facebook.com/SyntheticChurch/videos/1061000000000001/`; a page `/live/` address answers `not_embeddable`.
- No sermon revision exists on staging (0 rows).
- Signed-out HTTP with the publishable key:
  - `POST /rest/v1/rpc/content_public_sermons` -> 200 `{"series": [], "sermons": [], "truncated": false}`
  - `POST /rest/v1/rpc/content_public_sermon` (unknown id) -> 200 `{"sermon": null}`
  - the validator through the `app` profile -> 406 (schema not exposed)
  - `GET /rest/v1/content_sermon_revisions` through the `app` profile -> 406
