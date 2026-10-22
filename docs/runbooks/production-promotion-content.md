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
| 6.2 | `20261022012809_content_rights_banners.sql`: rights records, the `q5_content_rights` gate (unresolved; fixture honoured only in local/staging), the buckets `content-drafts` (private) and `content-public` (public), uploads, file slots, per-kind public conditions, banners, `api.content_public_banners` (anon), `api.content_staff_banners`, `api.content_staff_rights`, `api.content_file_plan`, `api.content_asset_preview`, three erase parts |

Edge Functions, deployed after the migrations:

| Story | Function | Settings |
|---|---|---|
| 6.2 | `content-assets` (`supabase/functions/content-assets/index.ts`, `logic.mjs`, `../_shared/system_access.mjs`) | `verify_jwt = false`; no secret of its own (the platform's `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) |

Client compatibility (6.1): production clients must be built from `main` at promotion. Older mobile builds keep the Duties and My cell tabs and have no Calendar; older staff web has no Events entry. Nothing breaks for them: the migration only adds objects.

## What production shows before any approval

| Item | Server answer | What the clients show |
|---|---|---|
| Events (6.1) | Church-authored content: no gate. No event exists until a Media member, Pastor or Admin creates and publishes one. | Calendar: "No upcoming events." Home: Coming up says the same. |
| Editors (6.1) | Only members holding Media, Pastor or Admin (story 2.3) can edit; the first real Admin is the identity production gate. | Staff web shows **Events** only to them. |
| Banners (6.2) | `q5_content_rights` is unresolved, so no rights record clears anything: every banner publish is refused (`image_rights_id: source_not_cleared`) and the public read is empty. Editors can still record and verify rights records and upload images; drafts stay private. | Home shows no carousel. Staff web **Rights** says "Not on the Q5 list" for every record. |

No epic 6 migration approves anything, and there are no fixture values in production.

## Ordered steps after promotion

1. **Verify the deploy** (operator, SQL editor). These answer as on staging:
   ```sql
   select count(*) from supabase_migrations.schema_migrations where version in ('20261021233523', '20261022012809');  -- 2
   select count(*) from app.contract_boundary_violations();                                                -- 0
   select count(*) from app.contract_unowned_objects();                                                     -- 0
   select kind, editor_roles from app.content_kinds order by 1;                    -- asset, banner, event, rights | {admin,pastor,media} (and later kinds)
   select command from app.content_commands order by 1;                            -- the five content.*_event commands, plus 6.2's twelve
   select handler from app.identity_deletion_hooks where module = 'content';        -- app.content_erase_member(jsonb)
   select part from app.content_erase_parts order by 1;                            -- asset_uploads, banner_revisions, event_revisions, rights_revisions
   select id, public from storage.buckets where id like 'content-%' order by 1;    -- content-drafts f | content-public t
   select count(*) from pg_policies where schemaname = 'storage';                  -- 0
   select state from app.policy_gates where gate = 'q5_content_rights';            -- unresolved (until Israel approves)
   select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relname like 'content%' and c.relkind in ('r', 'S')
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'));  -- 0
   ```
   Compare `md5(replace(pg_get_functiondef(p.oid), chr(13), ''))` of every `app`/`api` `content%` function with staging. Expect no difference.
2. **Signed-out read** (operator, from any machine): `POST <production url>/rest/v1/rpc/content_public_events` with only the publishable key and `Content-Profile: api` answers `200 {"events": [], "truncated": false}`.
   And (6.2) `POST <production url>/functions/v1/content-assets?action=sync` with only the publishable key answers `401 {"outcome": "unauthenticated"}`; `POST .../rest/v1/rpc/content_public_banners` answers `200 {"banners": [], "truncated": false}`.
3. **Editors** (Admin, staff web, **Roles & access**): give Media to the people the owner names.
4. **First event** (Media): follow [content.md](content.md), "Owner manual check", with the church's real event instead of the SYNTHETIC one.

5. **Q5 (6.2, owner).** When Israel has cleared the church's own images and any third-party sources, he approves `q5_content_rights` with the sources and uses he clears (see [content.md](content.md), "The Q5 gate"); until then no banner can be published. Then a Media member records and verifies the matching rights records and publishes the yearly theme.

## Rollback

6.1 and 6.2 are additive (no destructive statement, no row deletion). To take a banner off Home, an editor withdraws it (or suspends its rights record) and syncs; the public read drops it at once and the sync deletes its public file. To take every event off the public calendar without a schema change, an editor withdraws each published event (`content.withdraw_event`, **Events** > Withdraw): the public reads answer without it at once. To stop someone editing, an Admin removes their Media, Pastor or Admin role (**Roles & access**); it applies to their next command. No down migration is needed.
