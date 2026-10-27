# Story 6.8 staging verification (2026-10-27)

Project `tmurpotfluignacfueki` (staging). Nothing touched production; no gate approved; no notification sent.

1. Before the apply, staging history ended at `20261027083618` (6.9). A first apply attempt failed atomically (`content_member_commands already exists`): story 6.11 had just been applied as `20261027140149`. The migration was adapted to keep 6.11's member-command registry (`create table if not exists`, identical `content_register_member_command` and `content_member_actor` bodies) and its RSVP replay branch, re-tested locally (full pgTAP suite on a fresh reset; 6.8 and 6.11 pgTAP files together with 6.11's migration applied first; E2E 13/13), then applied verbatim.
2. Staging records `20261027182223 content_hymn_lists`. Local files renamed to `20261027182223_content_hymn_lists.sql` and `20261027182300_content_hymn_lists_rows.sql`.
3. Function hashes (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`) of the 39 added or replaced `app`/`api` functions: 38 identical to a fresh local reset; `app.content_hymn_favourite_purge_rows(uuid)` differs as expected (staging: fail-closed stub `81ae5c5c...`; local, with the rows file: `d8577030...`). After the owner applies the rows file its hash should be `d85770302de316d2757cad95a6fd2e2c`.
4. `app.contract_boundary_violations()` 0, `app.contract_unowned_objects()` 0, `app.contract_unpinned_functions()` 0.
5. Public read (signed-out projection): `app.content_public_sunday_hymns()` = `{"sunday": "2026-11-01", "edition": null, "items": [], "publication_revision": null}`.
6. The `_rows` file is NOT applied (owner step).
