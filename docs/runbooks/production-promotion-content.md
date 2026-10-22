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
| 6.3 | `20261022011438_content_giving_methods.sql`: the `giving_method` kind (Admin only), its eight commands, the second-Admin verification (check and trigger), the `q3_giving` gate, the public reads `api.content_public_giving_methods` / `api.content_public_giving_method` (anon), `api.content_staff_giving_methods`, the `giving_methods` erase part |
| 6.13 | `20261022011557_content_announcements.sql`: the `announcement` kind and its five commands, the public reads `api.content_public_announcements` / `api.content_public_announcement` (anon), `api.content_staff_announcements`, the `content_announcement` / `announcement_published` reminder contract (generic text), the `announcement_revisions` erase part |
| 6.2 | `20261022012809_content_rights_banners.sql`: rights records, the `q5_content_rights` gate (unresolved; fixture honoured only in local/staging), the buckets `content-drafts` (private) and `content-public` (public), uploads, file slots, per-kind public conditions, banners, `api.content_public_banners` (anon), `api.content_staff_banners`, `api.content_staff_rights`, `api.content_file_plan`, `api.content_asset_preview`, three erase parts |
| F1 | `20261022100601_f1_giving_admin_tenure.sql`: the Identity self-read's current-caller-only Admin tenure context and Content's 14-elapsed-day giving verification guard; no gate, public read or notification changes |
| F2 | `20261022102525_f2_church_owned_q5_exemption.sql`: updates only `app.content_rights_clear`; verified church-owned records bypass Q5 while lifecycle and per-use checks remain, and all other bases still require Q5 |
| F3 | `20261022112247_content_asset_retention.sql`: bounded 30-day cleanup claims for unreferenced private uploads, a separate `content_asset_retention` system purpose, and attachment/preview guards while a claim is live; SQL removes metadata only after the Content Edge Function deletes bytes through Storage |

Edge Functions, deployed after the migrations:

| Story | Function | Settings |
|---|---|---|
| 6.2 | `content-assets` (`supabase/functions/content-assets/index.ts`, `logic.mjs`, `../_shared/system_access.mjs`) | `verify_jwt = false`; no secret of its own (the platform's `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) |
| F3 | `content-assets` and `notifications-worker` | Both updated, `verify_jwt = false`; Content alone receives the separate `CONTENT_ASSET_RETENTION_SYSTEM_CREDENTIAL`, the existing trigger copy, and its existing Storage key. The worker receives no Content credential or service-role key. |

Client compatibility (6.1): production clients must be built from `main` at promotion. Older mobile builds keep the Duties and My cell tabs and have no Calendar; older staff web has no Events entry. Nothing breaks for them: the migration only adds objects. (6.3): older mobile builds have no Give tab and older staff web no Giving entry; the migration only adds objects.

## What production shows before any approval

| Item | Server answer | What the clients show |
|---|---|---|
| Events (6.1) | Church-authored content: no gate. No event exists until a Media member, Pastor or Admin creates and publishes one. | Calendar: "No upcoming events." Home: Coming up says the same. |
| Editors (6.1) | Only members holding Media, Pastor or Admin (story 2.3) can edit; the first real Admin is the identity production gate. | Staff web shows **Events** only to them. |
| Giving (6.3) | `q3_giving` is closed: Admins can draft and verify methods, but every publish answers `unavailable {"policy": "gate_closed"}`. The public reads answer `{"sample": false, "methods": [], ...}`. | Give: "No giving methods yet. When the church adds how to give, it will show here." On staff web **Giving** (Admins only), Publish answers "Not open yet" (publishing waits for the owner's approval). No sample banner (production). |
| Announcements (6.13) | Church-authored: no gate to publish. A publication **with a notice** answers `unavailable` (nothing published) until Israel approves `q2_church_time`; once approved, inbox items are delivered, and pushes also need `outbound_sending` and `push_enabled` in production. | Home: "No announcements right now." Staff web: **Announcements** for editors; the publish dialog says notices are not available yet when refused. |
| Banners (6.2/F2) | `q5_content_rights` is unresolved, so third-party sources do not clear any use and third-party banner publication is refused (`image_rights_id: source_not_cleared`). A verified `church_owned` record can publish when its requested use flag is clear. Editors can record and verify rights and upload images; drafts stay private. | Home is empty until a church-owned banner is published. Staff web **Rights** says Q5 approval is not required for church-owned images and reports unlisted third-party sources as not on Q5. |
| Private upload retention (F3) | An asset referenced by any draft, historical or published revision remains. An unreferenced `content-drafts` asset at least 30 days old may be deleted by the existing scheduled worker after the owner configures the separate Content principal and Edge secrets. No member/editor action is added; `content-public` is unaffected. | No client flow changes. |

No epic 6 migration approves anything, and there are no fixture values in production.

## Ordered steps after promotion

1. **Verify the deploy** (operator, SQL editor). These answer as on staging:
   ```sql
   select count(*) from supabase_migrations.schema_migrations
    where version in ('20261021233523', '20261022011438', '20261022011557', '20261022012809', '20261022100601', '20261022102525', '20261022112247');  -- 7
   select count(*) from app.contract_boundary_violations();                                                -- 0
   select count(*) from app.contract_unowned_objects();                                                     -- 0
   select kind, editor_roles from app.content_kinds order by 1;   -- announcement, asset, banner, event, rights | {admin,pastor,media}; giving_method | {admin}
   select command from app.content_commands order by 1;           -- the five content.*_event, 6.2's twelve, five content.*_announcement and eight giving commands
   select handler from app.identity_deletion_hooks where module = 'content';        -- app.content_erase_member(jsonb)
   select part from app.content_erase_parts order by 1;           -- announcement_revisions, asset_uploads, banner_revisions, event_revisions, giving_methods, rights_revisions
   select state from app.policy_gates where gate in ('q3_giving', 'q5_content_rights');  -- unresolved, unresolved (no migration approves them)
   select md5(replace(pg_get_functiondef('app.content_rights_clear(uuid,text)'::regprocedure), chr(13), ''));  -- compare with the reviewed staging hash
   select id, public from storage.buckets where id like 'content-%' order by 1;    -- content-drafts f | content-public t
   select count(*) from pg_policies where schemaname = 'storage';                  -- 0
   select command, purpose from app.sys_command_kinds where command like 'content.asset_retention_%' order by command; -- two F3 commands, content_asset_retention
   select count(*) from information_schema.columns where table_schema = 'app' and table_name = 'content_assets'
     and column_name in ('retention_claim_id', 'retention_claimed_at');             -- 2
   select title, body, link from app.contract_reminder_contracts where source_type = 'content_announcement';  -- the generic text, /announcements/{source_id}
   select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relname like 'content%' and c.relkind in ('r', 'S')
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'));  -- 0
   ```
   Compare `md5(replace(pg_get_functiondef(p.oid), chr(13), ''))` of every `app`/`api` `content%` function, plus `app.identity_my_access` and `api.identity_my_access`, with staging. Expect no difference; this includes the F2 rights helper and the F3 claim/finalize handlers and asset guards. Confirm the gate rows, module guards and signed-out `content_public_banners` response are unchanged; no gate value is approved by these migrations.
2. **Signed-out read** (operator, from any machine): `POST <production url>/rest/v1/rpc/content_public_events` with only the publishable key and `Content-Profile: api` answers `200 {"events": [], "truncated": false}`; `content_public_announcements` answers `200 {"announcements": [], "truncated": false}`.
   And (6.2) `POST <production url>/functions/v1/content-assets?action=sync` with only the publishable key answers `401 {"outcome": "unauthenticated"}`; `POST .../rest/v1/rpc/content_public_banners` answers `200 {"banners": [], "truncated": false}`.
3. **Editors** (Admin, staff web, **Roles & access**): give Media to the people the owner names.
4. **First event** (Media): follow [content.md](content.md), "Owner manual check", with the church's real event instead of the SYNTHETIC one.
5. **Giving (6.3 and F1, Q3; owner only).** Only after the church has named its real methods, destinations, purposes, currency, contact and at least two Admins (Q3):
   1. Admin A enters each real method on staff web **Giving** (it stays a private draft); an Admin who saved none of it, has held an active Admin grant for at least 14 elapsed 24-hour days, and has tested the details with the provider verifies each one (Tested on, How it was tested). The Verify dialog shows the verifier's own “Admin since <Lusaka date>, granted by <name>” context; the server enforces elapsed time from the grant timestamp.
   2. Israel approves the gate in production, with an attributed note naming the verified methods: `select app.policy_approve('q3_giving', '{"methods": "<the verified methods>"}', '<owner name>', '<Q3 decision reference>');`. Do not include `sample_only`.
   3. An Admin publishes each verified method and orders them; a signed-out phone's **Give** shows them with "Details checked by the church on ..." and no sample banner.
   Until then nothing is published; the gate stays closed and Give says the church has published no methods.

6. **Q5 (6.2/F2, owner).** When Israel has cleared third-party sources, he approves `q5_content_rights` with the sources and uses he clears (see [content.md](content.md), "The Q5 gate"). The church-owned basis does not need a gate entry. A Media member may record and verify a church-owned rights record and publish a banner when its requested use is clear; third-party material waits for its source and use to be approved.

## Rollback

6.1, 6.2, 6.3 and 6.13 are additive (no destructive statement, no row deletion). To take a banner off Home, an editor withdraws it (or suspends its rights record) and syncs; the public read drops it at once and the sync deletes its public file. To take a giving method off Give at once, an Admin hides it (**Giving** > Hide, `content.hide_giving_method`); to stop all giving publication, leave `q3_giving` unapproved. To take an announcement down, an editor withdraws it (**Announcements** > Withdraw); its undelivered notices are cancelled with it. To take every event off the public calendar without a schema change, an editor withdraws each published event (`content.withdraw_event`, **Events** > Withdraw): the public reads answer without it at once. To stop someone editing, an Admin removes their Media, Pastor or Admin role (**Roles & access**); it applies to their next command. No down migration is needed.
