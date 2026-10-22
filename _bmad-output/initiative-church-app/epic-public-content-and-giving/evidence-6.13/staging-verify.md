# Story 6.13 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-22 through the Supabase connector (`apply_migration`, name `content_announcements`),
right after entry 3's `20261022011438_content_giving_methods` (applied by its own agent two minutes
earlier) and with the external review's fixes in it. ASCII only, no backslashes; it travelled
verbatim.

- Staging recorded `content_announcements` as `20261022011557`; the local file was renamed.
- Guards on staging: `app.contract_boundary_violations()` 0, `app.contract_unowned_objects()` 0,
  `app.contract_unpinned_functions()` 0.
- Drift (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`, by signature, aggregated):
  - the 26 `app`/`api` `content%announcement%` functions: `63fa8f20e250679c534f88d9b7ed2eda` on
    staging and on a fresh local reset;
  - the 24 shared functions this entry calls (the 6.1 lifecycle helpers, dispatch, authorizer,
    replay recheck, deletion hook and registration functions, and `notifications_enqueue`,
    `notifications_enqueue_job`, `notifications_cancel`, `notifications_recipient_route`,
    `notifications_policy`): `9f6246ceb4e4791f7a43389d5ac704c1` on both, so neither this entry nor
    entry 3 replaced one of them;
  - `app.content_announcement_revisions` constraints `5e55caacdc729ea46c6c90f1a4b705ed` (9) and
    columns `bc19745dcd578d511e08dce777f33c7b` (15) on both;
  - the event and announcement registrations (kinds, commands, erase parts, the
    `content_announcement` source type and its reminder contract): 16 rows,
    `412fdd5fd8cfee408e7f18c0885094ff` on both. (The aggregate over every `content%` function and
    registration differs only by entry 3's giving objects, which this branch does not have yet.)
- Privileges: no `anon`, `authenticated` or `service_role` privilege on
  `app.content_announcement_revisions`; `anon` executes exactly `app`/`api`
  `content_public_announcement(s)`; `authenticated` adds only `app`/`api`
  `content_staff_announcements`.
- Signed out over HTTP with the publishable key only: `POST /rest/v1/rpc/content_public_announcements`
  200 `{"truncated": false, "announcements": []}`; `content_public_announcement` with an unknown id
  200 `{"announcement": null}`; `content_staff_announcements` 401; `GET /rest/v1/content_announcement_revisions`
  with `Accept-Profile: app` 406.
- State that matters for the owner check: staging has `outbound_sending` approved and
  `push_enabled` true, `q2_church_time` on its fixture, and 30 members a notice would reach now. A
  publication with a notice therefore pushes to every registered SYNTHETIC device within minutes,
  so this check published nothing on staging; no data was written.
- The ticket's verify on staging (publish a pinned and an unpinned SYNTHETIC announcement, one
  with a notice, then read the inbox, job, attempt and push-job rows) is the owner manual check in
  `docs/runbooks/content.md`, story 6.13, with the SQL to read the rows; real-phone receipt is
  Israel's in entry 15. Locally the same function bodies pass it end to end
  (`content-announcements-e2e.jsonl`, 14/14).
