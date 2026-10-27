# Story 6.9 staging verification

Date: 2026-10-27

## Target and migration

- Supabase project: `tmurpotfluignacfueki` (staging only).
- Before the apply, staging's migration history ended at `20261026151013_content_bible_review_hardening` and included the prerequisite `20261022012809_content_rights_banners`.
- A rolled-back dry run of the migration text against staging's schema passed first (one `do` block that executed the migration and a few reads, then raised so nothing persisted); a follow-up read confirmed no sermon kind, table or function remained.
- The local gate then ran on a fresh reset (shared-database lock held): every migration replayed, the full pgTAP suite passed (65 files, 5,243 tests) and the local HTTP runner passed 16/16 (`content-sermons-e2e.jsonl`).
- The migration was applied verbatim. Supabase recorded it as `20261027083618_content_sermons`; the local file now carries that version.
- It adds no row deletion and has no owner `_rows` step.

## Read-only staging results after application

- All 33 added sermon/series functions (`app.content_sermon*`, `app.content_public_sermon*`, `app.content_staff_sermon*` and their `api` wrappers) hash identically to the fresh local replay (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`).
- `app.contract_boundary_violations()`: 0. `app.contract_unowned_objects()`: 0.
- Kinds `sermon` and `sermon_series` are edited by admin, pastor and media; the `sermon_series_poster` purpose is display, 5 MB, at least 960 x 540, ratio 1.30-2.40; ten commands and the two erase parts are registered; both revision tables have RLS and no client grant; anon may execute the public reads only.
- No sermon or series exists on staging. The notes check refuses a U+2028 line separator.
- Seven signed-out HTTP checks with only the publishable key pass (`staging-public-read-20261027.jsonl`): the empty catalog `{"series":[],"sermons":[],"truncated":false}`, a null unknown detail, 401 for both staff reads and for a sermon command, and both revision tables unreadable.

## Not verified here

- No staging content was published: the owner's manual check (two SYNTHETIC series and sermons, unsafe notes refused in the editor, signed-out browsing and search, playback, a removed or private video, offline reading) is in `docs/runbooks/content.md`, "Story 6.9 / Owner manual check on staging".
- Physical playback, the unavailable-video state on a device and airplane-mode reading belong to the entry 15 pilot; widget and API tests do not demonstrate them.
- No policy gate or rights record was changed, no notification was sent and production was not accessed.
