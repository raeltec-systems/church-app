# Story 6.1 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 through the Supabase connector (`apply_migration`), after `20261021211830`
(duties special assignments), with the external review's fixes in it. ASCII only, no backslashes;
it travelled verbatim.

- Staging recorded `content_events_tracer` as `20261021233523`; the local file was renamed.
- Guards on staging: `app.contract_boundary_violations()` 0, `app.contract_unowned_objects()` 0,
  `app.contract_unpinned_functions()` 0.
- Registries: commands `content.archive_event, content.create_event, content.publish_event,
  content.save_event, content.withdraw_event`; authorizer `app.content_authorize_command(jsonb)`;
  deletion hook `app.content_erase_member(jsonb)`; erase part `event_revisions`.
- Privileges: no `anon`, `authenticated` or `service_role` privilege on any `app.content%` table or
  sequence (count 0). `anon` executes exactly `app/api.content_public_event` and
  `app/api.content_public_events`.
- Drift: the aggregate md5 over the 41 `app`/`api` `content%` functions
  (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`, by signature) is
  `b5474e9d52ee5c969ad82a08b5bf9b3d` on staging and on a fresh local reset. Table constraints
  (`bc6c5dd9191656ab22918b10abbd7bd2`) and columns (`c23a16683de09d7c21e8814f8fce7cfe`) match too.
- Signed out over HTTP with the publishable key only: `POST /rest/v1/rpc/content_public_events`
  200 `{"events": [], "truncated": false}`; `content_staff_events` 401; `content_command` 401;
  `GET /rest/v1/content_items` with `Accept-Profile: app` 406.
- No data was written on staging by this check.
- Owner manual check (the ticket's verify on a phone and staff web): [content.md](../../../../docs/runbooks/content.md),
  "Owner manual check on staging".
