# Runbook: promote cell meetings and programmes to the production baseline (story 5.12)

Status: **prepared, not executed.** Nothing in this file has run against production.

The owner (Israel) promotes epic 5 himself, with the same promote workflow as the earlier epics, only:
- after the Duties and Follow-ups promotion (story 4.15, [production-promotion-duties.md](production-promotion-duties.md)) has run;
- after he has witnessed the staging demonstration.

This file is what the owner and the restricted operator do **after** that promotion for Cells meetings and programmes. It does not repeat the identity or duties packages.

Related: [cells-meetings.md](cells-meetings.md) (stories 5.1-5.11), [cells-guides.md](cells-guides.md), [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (the Duties contract changes of epic 5). Staging evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.*/`.

## What is promoted

Fourteen migrations, in this order. Each was applied to staging under its hosted version, and its functions were checked identical to a fresh local reset (`evidence-5.x/staging-verify.md`):

| Story | Migration (hosted version) |
|---|---|
| 5.1 | `20261021073514_cells_meetings.sql` |
| 5.2 | `20261021081026_cells_meeting_reminders.sql` |
| 5.3 | `20261021084446_cells_programmes.sql` |
| 5.4 | `20261021093943_duties_owner_linkable.sql`, `20261021094249_cells_programme_publish.sql` |
| 5.5 | `20261021101314_duties_cell_confirmation.sql`, `20261021101323_cells_youre_on.sql` |
| 5.6 | `20261021104522_cells_programme_revisions.sql` |
| 5.7 | `20261021111547_cells_absence_notices.sql` |
| 5.8 | `20261021115855_cells_meeting_records.sql` |
| 5.9 | `20261021122802_cells_transfer_effects.sql` |
| 5.12 | `20261021132636_cells_external_check_fixes.sql` |
| History (owner decision 2026-10-21) | `20261021195642_duties_history_all_kinds.sql`: My duty history lists cell programme parts too, with a `kind` filter |
| Special assignments (owner decision 2026-10-21) | `20261021211830_duties_special_assignments.sql`: the Pastors give duties that belong to no department and no cell, at a fixed time or with a due date; My duties, the history (kind `special`) and **Special assignments** on staff web |
| Review fixes 2026-10-28 | `20261028130727_cells_record_roster.sql` (F6, historical leader roster), `20261028130849_duties_special_due_on_changes.sql` (F7, due date is a material change; `duties_slot_revisions.due_on`), `20261028130929_cells_schedule_place_notices.sql` (F8, venue and pin changes notify) |
| Coverage for cells (owner decision 2026-10-28) | `20261028131249_duties_cell_coverage.sql`: contact attempts, the coverage queue (`cells`), leader alerts (`cell_part_*` kinds) and outcomes for a cell's programme parts; `duties_coverage_cases.cell_id` (its `owner-approved-cleanup` marker cites the decision). Clients older than this build ignore `cells` (no regression) |

The history migration replaces `api.duties_member_history` with a fourth argument, `kind`, and its entries may have no department (a cell part). A client older than this change fails to read a history that holds a cell part, so production clients must be built from `main` at promotion (the same rule as below).

The special assignments migration adds a third owner kind to `app.duties_occurrences` (`special`, with `due_on`) and replaces the two-owner check with a three-owner one in one statement (its `owner-approved-cleanup` marker cites the owner decision; no data is touched). Applied to staging on 2026-10-21 as `20261021211830`: all 193 `app`/`api` `duties*` functions identical to a fresh local reset (aggregate md5 `aee5e8f613e2aa39fc17407219bd35f8`), `app.contract_boundary_violations()` 0. Client compatibility: builds from 4.11 on leave a special assignment out of My duties and say "Update the app to see them"; an older history client labels a special row "Department"; an older staff web shows "Could not check their other duties" when a candidate has a special assignment at that time (the server still checks). Build production clients from `main` at promotion. Nothing to configure: the feature is used by whoever holds the Pastor role once Q4 is open.

The 4.11 release gate carries over: `cell_part` is registered in 5.4. Every client in production must therefore run the 4.11 build or later; production clients are built from `main` at promotion.

## What production shows before any approval (the deployed, visibly disabled baseline)

| Gate unapproved | Server answer | What the clients show |
|---|---|---|
| `q4_personal_data` (G5) | Every Cells read (Cell meetings, Plan meeting, My cell's meetings and programme, Admin cells) answers `403 unavailable`. Every Cells command answers `unavailable {"policy": "gate_closed"}` and writes nothing (`app.cells_require_open`, through `app.identity_applications_open()`). No cell, schedule, venue or programme can be entered. | **Not available yet** on Cell meetings, Plan meeting, Admin cells and My cell (mobile and staff web). The Home card shows nothing. |
| `q2_church_time` (with Q4 open) | Meetings and programmes work. No meeting reminder, change notice, Cannot attend notice, vacancy notice or duty request is enqueued (`app.cells_reminders_available()` is false; Duties skips and audits). | Everything works without notifications. Leaders tell members directly. |
| Scheduler gates (`ops_system_access`, `q12_operations`) | Nothing is delivered (production-promotion-duties.md, step 1). | The Inbox stays empty. |
| `identity_deletion_retention` (G6) | A deletion ends access at once. The Cells erase step (meetings, notices, programmes, records, actual leaders) waits `policy_gate_closed`. | **Member deletions** shows `accepting: false`. |
| Real cell configuration (owner, Q2 leaders) | No cell exists until an Admin creates it. SYNTHETIC cells are never listed outside `local` and `staging`. | Admin cells is empty. |

No migration of epic 5 approves anything, and there are no fixture values in production.

## Ordered steps after promotion

Prerequisites:
- the identity and duties packages are done, and their verification passed;
- the owner has approved `q4_personal_data` (Q4: live member data and private home venues).

While Q4 stays closed, stop here: production shows the baseline above.

1. **Verify the deploy** (operator, SQL editor). These answer as on staging:
   ```sql
   select count(*) from supabase_migrations.schema_migrations
    where version in ('20261021073514','20261021081026','20261021084446','20261021093943','20261021094249','20261021101314','20261021101323',
                      '20261021104522','20261021111547','20261021115855','20261021122802','20261021132636',
                      '20261021195642','20261021211830');  -- 14
   select count(*) from app.contract_boundary_violations();                                  -- 0
   select conname from pg_constraint where conrelid = 'app.duties_occurrences'::regclass
      and conname in ('duties_occurrences_one_owner', 'duties_occurrences_one_owner_kind');  -- one_owner_kind only
   select source_type from app.contract_source_types where owner_module = 'cells' order by 1;
     -- cells_absence_notice, cells_meeting, cells_programme, cells_programme_part, cells_signup_option
   select module from app.identity_handover_hooks order by 1;                                -- cells, duties, followups
   ```
   Compare `md5(replace(pg_get_functiondef(p.oid), chr(13), ''))` of every `app`/`api` `cells*` function, and of every `app`/`api` `duties*` function (the history and special assignments migrations replace several), with staging. Expect no difference other than the known `app.cells_text` drift (2.6).
2. **The pilot cells** (Admin, staff web, **Admin cells**): create `Shikoswe Cell` and `Estates C5/C7 Cell`, with their real names, labels and broad areas. Grant their leaders and assistants as the owner names them (Q2). Confirm their members.
3. **Schedules and venues** (Admin, **Cell meetings** > **Set the schedule**): the real weekday, times and venue. The venue is private to each cell's leader, assistant and confirmed members.
4. **Reminders**: once Q2 and the scheduler are open, the cells' default reminder is the day before. A leader may change it on **Cell meetings**.
5. **First programme**: a leader follows [cells-guides.md, Guide 2](cells-guides.md#guide-2-cell-leader-and-assistant), and the owner checks the result as in the staging owner pilot.

## Rollback

The epic 5 migrations are additive: no destructive statement and no row deletion. The history migration drops and recreates the two history functions (no data is touched); to undo it, recreate them from `20261015002121_duties_outcomes.sql` (the `duties_member_history` section and its grants), and old clients read history again. The special assignments migration is additive apart from the owner check it widens; with no special assignment given, every earlier read and command behaves as before, and the feature stops at once if the Pastor role is not granted (only Pastors give, read or record them). To stop the feature without a schema change, close `q4_personal_data` again: every Cells read and command fails closed at once, and clients show **Not available yet**. Nothing in epic 5 needs a down migration.
