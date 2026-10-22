# Runbook: promote public content and giving instructions to the production baseline (epic 6)

Status: **started at story 6.1; not executed.** Nothing in this file has run against production. Each epic 6 entry adds its migrations and checks here; entry 17 completes it and the owner (Israel) promotes.

The owner promotes epic 6 himself, with the same promote workflow as the earlier epics, only:
- after the cells promotion (story 5.12, [production-promotion-cells.md](production-promotion-cells.md)) has run, because migrations promote in order;
- after he has witnessed the staging demonstration (entry 17);
- with `q3_giving` and `q5_content_rights` either approved by him or left closed (entries 2 and 3 add these gates).

Related: [content.md](content.md), [contracts-and-owner-seams.md](contracts-and-owner-seams.md). Staging evidence: `_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.*/`.

## What is promoted

Migrations, in this order. Each was applied to staging under its hosted version, and its functions were checked identical to a fresh local reset (`evidence-6.x/staging-verify.md`):

| Story | Migration (hosted version) |
|---|---|
| 6.1 | `20261021233523_content_events_tracer.sql`: the Content lifecycle, registries, events, `api.content_command`, the public reads `api.content_public_events` / `api.content_public_event` (anon) and `api.content_staff_events`, the Content deletion hook |
| 6.13 | `20261022011557_content_announcements.sql`: the `announcement` kind and its five commands, the public reads `api.content_public_announcements` / `api.content_public_announcement` (anon), `api.content_staff_announcements`, the `content_announcement` / `announcement_published` reminder contract (generic text), the `announcement_revisions` erase part |

Client compatibility (6.1): production clients must be built from `main` at promotion. Older mobile builds keep the Duties and My cell tabs and have no Calendar; older staff web has no Events entry. Nothing breaks for them: the migration only adds objects.

## What production shows before any approval

| Item | Server answer | What the clients show |
|---|---|---|
| Events (6.1) | Church-authored content: no gate. No event exists until a Media member, Pastor or Admin creates and publishes one. | Calendar: "No upcoming events." Home: Coming up says the same. |
| Editors (6.1) | Only members holding Media, Pastor or Admin (story 2.3) can edit; the first real Admin is the identity production gate. | Staff web shows **Events** only to them. |
| Announcements (6.13) | Church-authored: no gate to publish. A publication **with a notice** answers `unavailable` (nothing published) until Israel approves `q2_church_time`; once approved, inbox items are delivered, and pushes also need `outbound_sending` and `push_enabled` in production. | Home: "No announcements right now." Staff web: **Announcements** for editors; the publish dialog says notices are not available yet when refused. |

No epic 6 migration approves anything, and there are no fixture values in production.

## Ordered steps after promotion

1. **Verify the deploy** (operator, SQL editor). These answer as on staging:
   ```sql
   select count(*) from supabase_migrations.schema_migrations where version in ('20261021233523', '20261022011557');  -- 2
   select count(*) from app.contract_boundary_violations();                                                -- 0
   select count(*) from app.contract_unowned_objects();                                                     -- 0
   select kind, editor_roles from app.content_kinds order by 1;   -- announcement, event | {admin,pastor,media} (plus later kinds)
   select command from app.content_commands order by 1;           -- the five content.*_event and five content.*_announcement commands
   select handler from app.identity_deletion_hooks where module = 'content';        -- app.content_erase_member(jsonb)
   select part from app.content_erase_parts order by 1;           -- announcement_revisions, event_revisions
   select title, body, link from app.contract_reminder_contracts where source_type = 'content_announcement';  -- the generic text, /announcements/{source_id}
   select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relname like 'content%' and c.relkind in ('r', 'S')
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'));  -- 0
   ```
   Compare `md5(replace(pg_get_functiondef(p.oid), chr(13), ''))` of every `app`/`api` `content%` function with staging. Expect no difference.
2. **Signed-out read** (operator, from any machine): `POST <production url>/rest/v1/rpc/content_public_events` with only the publishable key and `Content-Profile: api` answers `200 {"events": [], "truncated": false}`; `content_public_announcements` answers `200 {"announcements": [], "truncated": false}`.
3. **Editors** (Admin, staff web, **Roles & access**): give Media to the people the owner names.
4. **First event** (Media): follow [content.md](content.md), "Owner manual check", with the church's real event instead of the SYNTHETIC one.

## Rollback

6.1 and 6.13 are additive (no destructive statement, no row deletion). To take an announcement down, an editor withdraws it (**Announcements** > Withdraw); its undelivered notices are cancelled with it. To take every event off the public calendar without a schema change, an editor withdraws each published event (`content.withdraw_event`, **Events** > Withdraw): the public reads answer without it at once. To stop someone editing, an Admin removes their Media, Pastor or Admin role (**Roles & access**); it applies to their next command. No down migration is needed.
