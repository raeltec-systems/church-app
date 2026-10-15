# Runbook: follow-up tasks (epic 4, Follow-ups owner)

Follow-ups is the one accountable task registry (architecture AD-7). Sources (duties coverage, visitors, missing reports, care, custody) do not keep their own trackers: they open one task per source and purpose in Follow-ups and register what their source events do to it. Reminders arrived with story 4.7 (below); lifecycle and handover hooks with story 4.12 (below).

## Story 4.6: open the Follow-ups registry with My follow-ups for every owner

Migration: `supabase/migrations/20261014110258_followups_registry.sql` (forward only; no destructive statements, no row deletions, no `_rows` file, so **no owner SQL paste**). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-open-the-follow-ups-registry-with-my-follow-ups-for-every-ow-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.6/`.

### Model (Follow-ups owns it)

- **Purposes** (`app.followups_purposes`): registered by the source's owner (below). Each has a generic label, the Identity scope kinds whose holders supervise its tasks, its outcome codes, the legal lifecycle effect of a source event and whether a scope holder may create tasks by hand.
- **Tasks** (`app.followups_tasks`): exactly one per `source_type/source_id/purpose`, for ever (a Done or Closed task still blocks a second one). One owner (an approved member, with or without a login), one supervisor holding the task's scope, the scope (`scope_kind`, `scope_id`), a next action (1-200 characters), the original due date (never moved in 4.6), the state and the latest outcome.
  - **States.** Open, In progress and Waiting are active and move freely between each other. Waiting needs a review date (future, at most a year away); every review-date change is recorded. Done and Closed are final (no reopen yet). Closing by hand needs a reason (1-200 characters); a source closes with `source_resolved` / `source_cancelled` and no text.
  - **Overdue.** Open and In progress are overdue once the due date passes; Waiting once the review date passes. `due_passed` keeps the original deadline's history while Waiting.
- **Activity** (`app.followups_activity`): content-free (ids, codes, states, dates): who acted, in which capacity (`owner`, `supervisor`, `admin`, `source`) and for whom (`on_behalf_of_member` when a scope holder records for the owner).
- **Private notes** (`app.followups_notes`): free text, shown only to the owner and the holders of the task's scope; never to Admin routing, never in receipts or activity.
- **Scope families** (`app.followups_scope_families`, review S1/S2): the owner of a scope kind registers its family and a read-only roster hook. Duties registers `department_leader` and `department_deputy` as family `department` (roster: the department's current members); Cells registers `cell_leader` and `cell_assistant` as family `cell` (roster: the cell's current members). A member supervises a task when they hold an active grant on the same target (`scope_id`) whose kind is in the task's family **and** is one of the kinds the purpose registers now: so a department's leader and deputy, or a cell's leader and assistant, supervise each other's tasks, and narrowing a purpose's `scope_kinds` narrows every command and read at once.
- **Owner candidates**: a task's owner is chosen from its target's roster (the target's current members and the current holders of the family's scope kinds) **plus the current Pastors** (owner decision Q4, 2026-10-14, applied by story 4.7), all approved and not under deletion. Create, reassign (also by an Admin) and the owner operation refuse anyone else (`owner_member_id: not_in_scope`), including a former Pastor. A Pastor chosen as owner gets exactly the owner's rights on that task; the Pastor role alone still shows no other task and gives no supervision.
- Every Follow-ups command, owner operation (including source events) and read is behind the Q4 personal-data gate (`app.identity_applications_open()`): open in a database marked local or staging, closed in production until Q4 is approved. Production stays inert.

### Who may do what

| Who | Sees | May |
|---|---|---|
| Owner (any member) | My follow-ups: their tasks with next action, context, notes, activity | status, review date, outcome, next action, private note on their own active task |
| Holder of the task's scope family (the supervisor, another leader or a deputy/assistant of the same target) | the scope's tasks, all of the above | the owner's updates, recorded "by me for the owner"; reassign owner (within the roster) or supervisor; create tasks for manual purposes |
| Admin (role alone) | routing metadata: owner, supervisor, scope, purpose, state, dates, and each active scope's roster | reassign owner (within the roster) or supervisor; create a manual task naming a supervisor in scope (no note) |
| Admin who also holds the scope | as a scope holder (the scope capacity wins) | as a scope holder |
| Pastor (role alone), anyone else | nothing | nothing (`forbidden` / `not_found`, without saying the task exists) |

### Commands (`POST /rest/v1/rpc/followups_command`, `Content-Profile: api`)

Body `{version: 1, command, request_id, expected_revision, payload}` (1.4 envelope; replays return the stored result after rechecking that the actor may still act on the task).

- `followups.create_task` (expected `null`): `{source_type, source_id, source_revision, purpose, owner_member_id, scope_kind, scope_id, supervisor_member_id?, next_action, due_at, note?}`. Only for purposes registered with `manual_create` (in 4.6 only the SYNTHETIC `fixture_followup/synthetic_check_in`). Refusals: `forbidden` (no scope, not Admin), `validation_failed` with `purpose: unregistered|not_manual`, `scope_kind: not_allowed`, `source_id: not_current`, `owner_member_id: unknown`, `supervisor_member_id: required|not_in_scope`, `due_at: past|out_of_range`, `note: not_allowed` (Admin); `conflict {"purpose": "task_exists"}`.
- `followups.update_task` (expected = task revision): `{task_id, status?, review_at?, close_reason?, outcome?, next_action?, note?}`, at least one (`changes: required`). Refusals: `not_found` (not yours, not your scope), `forbidden` (Admin), `conflict` (stale revision, or `{"task_id": "finished"}`), `validation_failed` with `status: unchanged`, `review_at: required|past|out_of_range|unchanged|not_waiting`, `close_reason: required|not_closing`, `outcome: unregistered`, `next_action: unchanged`.
- `followups.reassign` (expected = task revision): `{task_id, owner_member_id?, supervisor_member_id?}`. Scope holders and Admins; the owner gets `forbidden`. `owner_member_id: unchanged|unknown`, `supervisor_member_id: unchanged|not_in_scope`.

Answers carry ids, revision and state only (no text): clients read again.

### Reads

- `api.followups_my_tasks()`: the caller's tasks, active first (soonest due or review date), then those finished in the last 30 days; at most 200.
- `api.followups_task(p_task_id uuid)`: `{view: "full", task, activity, notes}` for the owner and scope holders; `{view: "routing", task}` (metadata only) for an Admin; `403 forbidden/not_granted` otherwise.
- `api.followups_supervision()`: for holders of a scope some purpose registered: their scopes (one per family and target, each with `family` and its roster `candidates`: name and `app_account`/`no_login` only), the manual purposes and the tasks they supervise.
- `api.followups_admin_routing()`: Admin only; routing metadata of every task and, per active task scope, its roster to reassign to.

### Registering a source (owners, in their own migration)

```sql
-- 1. The source type and the purpose in the shared contract (story 1.5).
select app.contract_register_source_type('cells', 'cells_visitor', 'app.cells_visitor_source_check(jsonb)'::regprocedure);
select app.contract_register_purpose('cells', 'cells_visitor', 'visitor_contact');
-- 2. The Follow-ups registration: label, scope kinds, outcomes, legal lifecycle effects and an
--    optional context hook ((jsonb) -> jsonb, your module's, search_path = '').
select app.followups_register_purpose('cells', 'cells_visitor', 'visitor_contact',
  '{"label": "Visitor contact", "scope_kinds": ["cell_leader", "cell_assistant"],
    "outcomes": ["contacted", "visited", "joined", "declined_contact", "unreachable"],
    "on_source_resolved": "close", "on_source_cancelled": "close", "manual_create": false}',
  'app.cells_visitor_followup_context(jsonb)'::regprocedure);
```

- Refusals (PCTR1): not the source type's owner; purpose not in the shared contract; a label that is not 1-60 generic printable ASCII (no `{ } < > @ \`); unknown scope kinds; an effect other than `close` or `keep`; a context hook of another module, with the wrong signature, `VOLATILE` or `SECURITY DEFINER`; `manual_create: true` for a source type that does not start with `fixture_`. Registering again replaces the registration.
- **Manual creation rule (review S3).** `followups.create_task` never checks that a source belongs to the chosen scope, and a task blocks its source and purpose for ever. So only SYNTHETIC `fixture_` sources may register `manual_create`; every real source opens its tasks with `app.followups_open_task` inside its own command, where it has already checked its own source and scope. A real source that wants hand-made tasks needs a registered source-scope check first (a later change).
- **Context hook.** Gets `{source_type, source_id, purpose, task_id, viewer_member_id}` and answers exactly `{"label": "<1-80 characters>"}`: the minimal context that viewer may see. It runs with Follow-ups' owner rights inside the definer reads, so it must be read-only: `STABLE` or `IMMUTABLE`, not `SECURITY DEFINER` (both refused at registration), never writing or locking. Anything but a label, or a hook that raises, shows no context (fail closed; the SQLSTATE alone goes to the server log). Never return care, finance or contact details.
- **Scope family** (owners of a scope kind, review S1/S2): `select app.followups_register_scope_family('<module>', '<scope_kind>', '<family>', 'app.<prefix>_followups_roster(jsonb)'::regprocedure);`. The roster hook gets `{scope_kind, scope_id}` and answers exactly `{"member_ids": [uuid, ...]}` (the target's current members); same read-only rules as the context hook; a malformed answer or a raise names nobody (only the scope's leaders remain candidates).
- **Owner operations**, inside your own command after locking your source (Follow-ups comes after the domain owners and before Notifications in the AD-2 lock order); neither is client-executable:
  - `app.followups_open_task({source_type, source_id, source_revision, purpose, owner_member_id, supervisor_member_id, scope_kind, scope_id, next_action, due_at, actor_member_id, actor_account_id})` answers `{task_id, revision}`; refusals are the kernel's (`validation_failed`, `conflict {"purpose": "task_exists"}`, `unavailable` while the Q4 gate is closed), so your command fails with them.
  - `app.followups_source_event({source_type, source_id, event: "resolved" | "cancelled"})` applies each active task's registered effect and answers `{closed, kept}` (behind the Q4 gate like every Follow-ups change). Task completion never changes a source: Done is not attendance, visit consent, completion or receipt.
- The SYNTHETIC worked example is `fixture_followup` (owner `fixture`): any id is a source at revision 1, current only in a database marked local or staging; its context hook answers `SYNTHETIC check-in source`.

### Member deletion (2.11 hook)

`app.followups_erase_member` is registered. Erase clears the text of every note the member wrote, that was written for them, or that sits on a task they own (`erased_at`), and replaces the member's and the account's ids with the nil UUID in tasks, activity and notes. No row is removed (no `_rows` file). A deleted owner's active task stays active, shows **Former member** and can be reassigned by its scope; since story 4.12 open tasks are handed over before erasure (below). Check answers 0 afterwards.

### Clients

- **Mobile:** the Home shows a **My follow-ups** card while the member owns active work ("N active, M overdue", the next task, **See all**) and otherwise a small **My follow-ups** link, so finished work stays reachable; a failed read says so and never looks empty. **See all** opens `/followups`; **Open task** opens `/followups/tasks/<id>` with **Mark in progress**, **Done**, **Waiting** (review date and time, church time), **Record outcome**, **Change next action**, **Add note** and **Close** (reason). Nothing shows as done until the server confirms; an unknown outcome shows **Not sent yet** with **Check again** (same request). After **Saved** the typed note, next action and reason are cleared, so a second tap sends nothing. The create form keeps one SYNTHETIC source id per draft until the server answers, so a re-tap after an unknown outcome resends the same request.
- **Staff web:** **My follow-ups** (every member with access), **Follow-ups** (leaders and deputies of a department, leaders and assistants of a cell: create a SYNTHETIC task, reassign, open a task to record for its owner) and **Follow-up routing** (Admin: metadata only, reassign). Dates are church time (Lusaka).

### Local runs

```sh
npx supabase db reset
npm run -s db:test                     # includes supabase/tests/followups_registry_test.sql (143 checks)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/followups.mjs --evidence <file.jsonl>
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/followups.test.mjs
```

The E2E uses the fictional numbers +44 7700 900220-900229 (pgTAP: 900210-900219) and removes everything it created.

### Hosted staging (parent session, then the owner)

1. Parent session: apply `20261014110258_followups_registry.sql` to staging (`tmurpotfluignacfueki`) after `20261014081513`. Compare per-function md5 with the local database (the file holds no `\u` escapes; the invisible-character class is built with `chr()`). Run `tools/ci/verify-hosted.sql` (`expected_env=staging`). No Edge Function change. No owner SQL paste.
2. Rebuild the staging staff web and phone builds (publishable key only) as in `notifications.md`, story 3.7, step 2.

### Owner manual checks (staging, phone and web, story 4.6)

Use synthetic members only. You need: an Admin A, a leader L of `SYNTHETIC Preaching Rota` (from 4.1, or give the scope again), a member M with the app on an Android phone, a member O and an accountless member X (staff web **Members & applications** > create a member without a login, SYNTHETIC name, fictional number).

0. **Roster.** Staff web as A: **Departments**: M, O and X are members of `SYNTHETIC Preaching Rota` (owners are chosen from the department's members and leaders, and since story 4.7 also the current Pastors). Optionally give a deputy D of the department.
1. **Create.** Staff web as L: **Follow-ups** > **Create a task**: purpose `SYNTHETIC check-in`, scope = the department, owner M (the owner list shows only the department's members and leaders, plus any Pastors since story 4.7), next action `SYNTHETIC: phone and check in`, a due date next week, **Create task**. Expect **Task created** and the task with **Open**. Create a second task for M and one for X with a private note.
2. **My follow-ups on the phone.** As M: **Home** shows **My follow-ups** with "2 open". **See all** lists both; open the first: the next action, `SYNTHETIC check-in source`, due date and supervisor L.
3. **Every state.** Tap **In progress** (**Sending…** then **Saved**, status **In progress**). Enter a review date and time, tap **Waiting**: the due date stays and the review date shows. Pick **Contacted**, **Record outcome**. Tap **Done**: status **Done**, the update buttons are gone. On the second task type no reason: **Close** stays disabled; type a reason and **Close**: **Closed** with the reason.
4. **For the accountless owner.** Staff web as L: open X's task: the line "what you record here is shown as recorded by you for X". Record **Contacted** and a note: the activity and the note say "recorded by L for X".
5. **Reassign.** In **Follow-ups**, **Reassign** X's task to O: **Reassigned**. As O (phone or staff web **My follow-ups**) the task is listed. As M, the task never appears. (Optional, with deputy D: D's **Follow-ups** lists the same tasks as L's, and D can record and reassign.)
6. **Duplicate.** (API, optional) send `followups.create_task` again with the first task's `source_id`: `conflict` `task_exists`.
7. **Admin routing.** Staff web as A: **Follow-up routing** shows owner, supervisor, scope, state and dates of each task and no next action, outcome or note. Open a task by URL (`/followups/tasks/<id>`): routing metadata only, no notes, no update buttons.
8. **Refusals.** As O, open M's task by URL: **Not available to you**. A direct table query with a member token (`GET /rest/v1/followups_notes`, `Accept-Profile: app` or `api`) is refused (406/404).
9. **Clean up** (SQL editor): delete the `followups_notes`, `followups_activity` and `followups_tasks` rows of the synthetic tasks, then remove the members as in `identity-access.md`.

Record the outcome per step in `evidence-4.6/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Owner questions

- **Q4: who may be chosen as an owner. Decided 2026-10-14** (owner: "allow on[ly] from task's own group and pastor"): the task's own group (its target's roster) and the current Pastors; nobody else. Applied in story 4.7's migration (`app.followups_scope_roster`). A Pastor counts only with live access (an active, reviewed link, no open hold, not dormant; review N1), and the Pastor grant is share-locked while a task is created, opened or reassigned to them. Members of the task's own group stay eligible with or without a login (their supervisor records for them). The Q4 personal-data gate itself stays closed in production, and needs Q2 (above).

### Known limits (later entries)

- Reminders: done in story 4.7 (below).
- No lifecycle or handover hooks: built in story 4.12 (below).
- No real source yet: duties coverage (entry 9; built in story 4.9, below) and the consumer guide with both-client fixtures (entry 11) follow. Care and finance note grants arrive with their owners.
- No due-date change and no reopen of a Done or Closed task.

## Story 4.7: remind follow-up owners and supervisors on the task schedule

Migration: `supabase/migrations/20261014130535_followups_reminders.sql` (forward only; the 4.6 file is not edited; no destructive statements, no row deletions, no `_rows` file, so **no owner SQL paste**). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-remind-follow-up-owners-and-supervisors-on-the-task-schedule-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.7/`. Tests: `supabase/tests/followups_reminders_test.sql` (132, worker-driven), `packages/client_core/test/followups/followups_reminders_test.dart`, one test in each app, E2E `tools/identity-e2e/followups-reminders.mjs` (12 checks, R01-R90) with its offline test.

### What is sent, to whom, when

Follow-ups registers two reminder sources (3.2 contracts), both keyed by the task id, with fixed generic text and the deep link `/followups/tasks/{source_id}`:

| Source / kind | Recipient | When | Title |
|---|---|---|---|
| `followups_task` / `followup_assigned` | the owner | when the task is created or reassigned to them | New follow-up task |
| `followups_task` / `followup_due` | the owner | at the actionable deadline (the due date while Open or In progress, the review date while Waiting), or at the creator's reminder times | Follow-up task due |
| `followups_supervision` / `followup_overdue` | the supervisor | once, one day after the deadline, if the task is still active and overdue | Follow-up task overdue |

- **Logical key and revision.** The reminders' source revision is the task's `schedule_revision`. It moves when the actionable deadline moves (into or out of Waiting, a new review date), on every reassignment of the owner or the supervisor, and when a recipient whose reminders of the task ended (reassigned away, inactive) is active again (review B1: M -> O -> M and L -> P -> L keep their reminders). Notes, outcomes, next actions and Open <-> In progress re-plan at the same revision, so nothing is sent twice. Past times are never enqueued.
- **One supervisor alert per deadline (review S1).** When the alert time for the current deadline has already passed at a re-plan (leaving Waiting onto a due date long gone, a new supervisor on an already overdue task), the supervisor gets one alert now, unless an alert for that deadline already reached them; further re-plans add none.
- **Assignment notice.** Not sent to an owner who created the task for themself or reassigned it to themself (review N4). An owner who is also the supervisor gets both the due reminder and the overdue alert.
- **A narrower policy (review N2).** If a later `q2_church_time` allows fewer or shorter reminders, the specs it no longer allows are dropped at plan time (a creator's stored list is narrowed once) and recorded in the activity (`reminders_adjusted`, code `policy_limit`); a command never fails for it.
- **Review dates.** A new review date is recorded in the activity (`status_changed` or `review_date_set`, with the date), the original due date never moves, and the reminders (and any snooze of the old date) move to the new date: an item of the old date opens **out of date**.
- **Reassignment.** The old owner's pending reminders and snoozes are cancelled (`reassigned`); the new owner gets `followup_assigned` and the schedule. A supervisor change moves the alert (`supervisor_changed`). An item the old owner already has opens out of date (they are no longer the owner), and a stray job would end `ineligible` at the worker.
- **Done, Closed, a closing source event.** Every pending reminder of the task is cancelled (`task_done`, `task_closed`, `source_resolved`, `source_cancelled`) and the source is no longer current, so nothing is delivered after it.
- **Creator reminders.** `followups.create_task` and `app.followups_open_task` take an optional `reminders`: up to 6 `{"anchor": "deadline", "before"|"after": "<n> minutes|hours|days"}` (at most 90 days). Absent or null: the church default (`q2_church_time` `default_reminders.task`: at the deadline). `[]`: no deadline reminders (the assignment notice and the supervisor alert stay). Refusals: `validation_failed {"reminders": "invalid"|"out_of_range"|"fixed_by_source"}`. The staff create form offers: at the due time, 1 hour, 24 hours, 2 days before. Reminders cannot be changed after creation in 4.7.
- **Snooze** (story 3.7): the member's **Remind me later** works on every follow-up reminder (1 hour, 24 hours, 2 days); a moved deadline, a reassignment or the end of the task cancels the snooze.
- **No quiet hours** (owner Q2). Church time is Africa/Lusaka (3.3 calculation).
- **Accountless or held owners.** No direct-contact route is registered in 4.7: their reminder ends `ineligible` / `no_direct_contact_route` and is counted **Without a route** in Reminder health; the supervisor still gets the overdue alert. A Follow-ups contact route is a later change.
- **Privacy.** Titles, bodies, push payloads and links never carry a next action, outcome, close reason, context, name or private note; the task screen re-reads the task with the reader's own rights (AD-5).
- **Production and gate order (review S2).** Every Follow-ups command, read and owner operation needs the Q4 personal-data gate **and** a valid Q2 scheduling policy (`q2_church_time`). Either closed answers the same non-retryable `unavailable {"policy": "gate_closed"}` (reads `403 unavailable`; the clients say "Not available yet") and writes nothing. **Q4 approval requires Q2 approval** (listed under the gates in `production-promotion-identity.md`, section 6).
- **Tasks opened before 4.7** have no reminders until their next deadline change, state change or reassignment (no backfill: it would need the Q2 policy at migration time, which production lacks).

### Source-specific schedules (source owners, in their own migration)

A source whose purpose needs its own reminder rule (missing cell reports, epic 7, are the first) registers it after `app.followups_register_purpose`; tasks of that purpose then follow it **instead of** the generic schedule, and creators' reminders are refused for them:

```sql
select app.followups_register_reminder_schedule('cells', 'cells_meeting', 'missing_report',
  '{"owner": [{"anchor": "deadline", "before": "0 minutes"}, {"anchor": "deadline", "after": "2 days"}],
    "supervisor": [], "on_assignment": false}');
```

- `owner` and `supervisor` are spec lists as above (`[]` = none); `on_assignment` sends the owner the assignment notice or not. Refusals (PCTR1): not the source type's owner, not a Follow-ups purpose, a malformed list, unknown keys, a supervisor spec `before` the deadline (review S3: an alert needs the task overdue). Registering again replaces it; it applies to existing tasks at their next re-plan.
- The kinds and texts stay the Follow-ups ones (generic). The SYNTHETIC worked example is `fixture_followup/synthetic_report_due` (not a manual purpose; opened through `app.followups_open_task`): reminders at the deadline and two days later, no assignment notice, no supervisor alert.
- Reads: the task carries `reminders: {schedule: "source"|"custom"|"default", owner, supervisor, on_assignment}`; the supervision read marks a manual purpose `fixed_reminders: true`.

### Clients

- **Deep link.** `/followups/tasks/<uuid>` is a known inbox target (`ClientPaths.deepLinkTargets`): a current follow-up reminder shows **Open**, which opens the task (owner, supervisor, or **Not available to you**). Push taps open the inbox item first, as for every reminder.
- **Task screen** (both apps): a line saying where the reminders come from, the owner's reminders and the supervisor alert; while Waiting it speaks of the review date ("at the review time", "a missed review date"; review N5).
- **Staff web, Create a task:** **Choose the owner's reminders** (at the due time, 1 hour, 24 hours, 2 days before); unticked = the church default; a purpose with its own schedule says so and offers no choice. A refused owner explains "The owner must belong to this task's group or be a Pastor."

### Local runs

```sh
npx supabase db reset
npm run -s db:test                     # includes supabase/tests/followups_reminders_test.sql (132)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/followups-reminders.mjs --evidence <file.jsonl>   # real worker script
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/followups-reminders.test.mjs
```

Fictional numbers: pgTAP +44 7700 900360-900369, E2E 900370-900379. The E2E mints its own local `notifications_worker` credential (digest only) and removes every row it created.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261014130535_followups_reminders.sql` to staging (`tmurpotfluignacfueki`) after `20261014110258` (`followups_registry`). Compare per-function md5 with the local database (the file holds no `\u` escapes). Run `tools/ci/verify-hosted.sql` (`expected_env=staging`). It adds two task columns, `app.followups_reminder_schedules`, two source types, three reminder contracts, the SYNTHETIC `synthetic_report_due` purpose and schedule, and replaces (same signatures and grants) `followups_scope_roster` (Q4), `followups_open_task`, `followups_source_event`, `followups_create_task`, `followups_update_task`, `followups_reassign`, `followups_task_json`, `followups_supervision`. **No client grant, no Edge Function change** (the worker is generic: no redeploy), **no owner SQL paste**.
2. Check: `select count(*) from app.contract_reminder_contracts where source_type like 'followups_%';` answers 3; `select app.notifications_scheduler_status() ->> 'scheduler_jobs';` answers 1 (the 3.4 Cron worker delivers).
3. Rebuild the staging staff web and phone builds (publishable key only) as in `notifications.md`, story 3.7, step 2.

### Owner manual checks (staging, phone and web, story 4.7)

Use synthetic members only, as in the 4.6 checks: Admin A, leader L of `SYNTHETIC Preaching Rota`, members M (Android phone) and O of the department, a member P who holds the **Pastor** role and is not in the department, and a member Y outside the department without the Pastor role. The staging scheduler must run (it delivers within about a minute). Push needs the 3.6 Firebase steps; without them every check still holds in **Inbox**.

1. **Assignment notice.** Staff web as L: **Follow-ups > Create a task** for M, due in about 10 minutes, leave **Choose the owner's reminders** unticked, **Create task**. Within about a minute M's phone **Inbox** shows **New follow-up task** ("A follow-up task was assigned to you. Open it to see the next action.") and nothing about the task. Tap it, then **Open**: the task opens. Its screen says **Church default reminders.**
2. **At the deadline.** When the due time passes, M's **Inbox** shows **Follow-up task due**, once. On the item choose **Remind me later > 1 hour**: **Snoozed until ...**.
3. **Supervisor alert, once.** One day after the due time (or ask the parent session to move that task's `followup_overdue` job's `scheduled_at` into the past on staging), L's **Inbox** (staff web) shows **Follow-up task overdue** once; **Open** leads to the task. Checking again later shows no second alert for that deadline.
4. **Review date.** As M, set **Waiting** with a review date tomorrow: the activity shows the change with the date, the due date is still shown, and the snoozed reminder no longer shows as snoozed (opening the old reminder says it is out of date). Change the review date again: a second activity line, not a silent reset.
5. **Reassign.** As L, **Reassign** the task to O: O's **Inbox** shows **New follow-up task**; M receives nothing more about it, and M's old items open out of date.
6. **Done and Closed.** As O mark it **Done**; create a second task for M and **Close** it with a reason. No further reminder arrives for either, also after their deadlines.
7. **Creator reminders.** As L create a task with **Choose the owner's reminders** ticked and **24 hours before** and **At the due time** chosen: the task screen lists them; both arrive at their times.
8. **Q4 owner decision.** As L, the **Owner** list offers P (the Pastor) but not Y. Create a task for P: P's **My follow-ups** shows it with the owner's actions; P cannot open L's other tasks (**Not available to you**) and has no **Follow-ups** supervision screen. (API, optional: a create for Y answers `validation_failed {"owner_member_id": "not_in_scope"}`.)
9. **Source-specific schedule (optional, SQL editor).** As in `tools/identity-e2e/followups-reminders.mjs` R70, call `app.followups_open_task` for purpose `synthetic_report_due`: the task's pending jobs are two `followup_due` jobs (at the deadline and two days later) and no assignment notice or supervisor alert.
10. **Clean up** (SQL editor): delete the attempts, inbox items, jobs and schedules of the synthetic tasks (`source_id` = the task ids), then the 4.6 cleanup (notes, activity, tasks, members).

Record the outcome per step in `evidence-4.7/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

## Story 4.9: the first real source (duty coverage) and the source review operation

Migration: `supabase/migrations/20261014212507_duties_coverage.sql` (the Duties story 4.9 migration; the Follow-ups files are not edited and no Follow-ups body is replaced). Runbook of the source: [duties.md](duties.md), story 4.9.

### The coverage purpose (owner: Duties)

| Source type | Purpose | Label | Scope kinds | Outcomes | Effects | Hand-made |
|---|---|---|---|---|---|---|
| `duties_coverage_case` (source id = the coverage case id, revision 1; current while the case is open and its assignment is current on a published duty) | `coverage_follow_up` | Duty cover follow-up | `department_leader`, `department_deputy` | `no_answer`, `left_message`, `will_answer`, `cannot_serve`, `other` | resolved: close; cancelled: close | no (opened by `duties.record_contact_attempt` through `app.followups_open_task`) |

- Context hook `app.duties_coverage_case_context`: "Duty cover: <duty> on <church date>" (no member, note or route).
- Owner: the recording leader or deputy (always in the task's group). Supervisor: another current, reachable leader or deputy of the department (a leader first), or the recorder when nobody else holds the scope (a recorded fallback). The generic next action is "Follow up a duty position that needs an answer or cover."; due = the next follow-up date.
- Source-specific schedule (`app.followups_register_reminder_schedule`): the owner at the due or review time only, no supervisor alert, no assignment notice (the due and review dates are always before the duty, so nothing arrives after it).
- Closing: Duties applies `app.followups_source_event` when the assignment is accepted, confirmed by a leader or superseded (`resolved`) or cancelled (`cancelled`). Task completion never changes the duty: a task marked Done is not an answer or a confirmation.

### New owner operation: `app.followups_source_review(input)`

A source owner records progress on the active task of a source and purpose inside its own command, after locking its source (Follow-ups after the domain owner, before Notifications):

```sql
select app.followups_source_review(jsonb_build_object(
  'source_type', 'duties_coverage_case', 'source_id', <case_id>, 'purpose', 'coverage_follow_up',
  'review_at', '<future instant, at most a year away>', 'outcome', '<a registered outcome>',
  'actor_member_id', <member>, 'actor_account_id', <account>));
```

- The active task becomes **Waiting** with that review date (the original due date never moves), `latest_outcome` is set when given, and the activity records `outcome_recorded` and `status_changed` / `review_date_set` with capacity `source` (ids, states and dates only). The reminders follow the new review date (the 4.7 scheduler; `schedule_revision` moves only when the date changes).
- Answers `{task_id, revision}`, or `{task_id: null}` when the source has no active task (finished by hand). Refusals: `validation_failed` (`review_at: past | out_of_range`, `outcome: unregistered`, `purpose: unregistered`, malformed input) and `unavailable` while the Q4 or Q2 gate is closed (the calling Duties command catches it, records the attempt and audits `followup_skipped`).
- Not client-executable (revoked from public, anon, authenticated and service_role).

### `app.followups_source_event` needs only the Q4 gate (review S1)

Replaced (same signature and answers): closing or keeping a source's tasks only removes work, and cancelling their reminders needs no scheduling policy, so a source event is applied whenever the Q4 personal-data gate is open, also with the Q2 policy closed or invalid. Every other Follow-ups command, read and owner operation still needs both gates.

### Staging and owner checks

Nothing separate: the parent session applies the Duties 4.9 migration (see duties.md, story 4.9); the owner's checks 4, 6 and 7 there cover the task's opening, update and closing.

## Story 4.11: Follow-ups source operations for later owners

No Follow-ups function changes in this story. It adds the consumer checklist below, both-client fixtures for the later owners' task sources (`packages/contracts/fixtures/v1/task_source.json` and `source_ref.json`, passing in SQL, Dart and TypeScript), and a SYNTHETIC Cells-like caller that uses the operations end to end (`app.fixture_programme_open_followup` opens a `fill_part` task for a part with a gap; `app.fixture_programme_publish` resolves it when the gap is filled, `app.fixture_programme_cancel` cancels it; `supabase/tests/duties_owner_operations_test.sql`).

### Checklist for a source owner (programmes, visitors, care, missing reports and counts, custody)

1. **Register in your own migration:** your source type and check hook (1.5), each purpose with `contract_register_purpose`, then `app.followups_register_purpose(module, source_type, purpose, {label, scope_kinds, outcomes?, on_source_resolved, on_source_cancelled}, context_hook?)` (story 4.6). `label` is generic printable text; never a name or care detail. Only SYNTHETIC `fixture_` sources may allow `manual_create`.
2. **Open tasks inside your own command** after locking your source row: `app.followups_open_task({source_type, source_id, source_revision, purpose, owner_member_id, supervisor_member_id, scope_kind, scope_id, next_action, due_at, actor_member_id, actor_account_id, reminders?})`. One task per source and purpose. The owner comes from your scope family's roster (Cells and Duties register theirs).
3. **Apply your lifecycle:** `app.followups_source_event({source_type, source_id, event: resolved | cancelled})` applies the registered effect (`close` or `keep`); it needs only the Q4 gate (4.9 S1). `app.followups_source_review` (4.9) moves an active task to Waiting with a review date and an outcome.
4. **Schedules:** Follow-ups schedules task reminders itself; replace the generic schedule for a purpose only with `app.followups_register_reminder_schedule` (missing reports are the first).
5. **What never rides on a task identity:** the identity is `{source_type, source_id, purpose}` (`task_source`). The fixtures refuse a note, an amount, a prayer text, a revision or an owner on it (`unknown_field`). Private context stays in your source and reaches the task only through your context hook's minimal `{label}`.

Fixture source types named in the shared fixtures (for the later owners to register under these names or record a contract change): `cells_programme_part` / `fill_part`, `cells_visitor` / `visitor_follow_up`, `care_visit_request` / `care_follow_up`, `cells_meeting` / `missing_report`, `services_count` / `missing_count`, `offerings_collection` / `custody_follow_up`, and Duties' own `duties_coverage_case` / `coverage_follow_up`.

### Staging and owner checks

Nothing separate: see duties.md, story 4.11 (the SYNTHETIC caller's follow-up is exercised in pgTAP only).

## Story 4.12: lifecycle and handover of follow-up tasks

Migration: `supabase/migrations/20261015043644_duties_lifecycle.sql` (with Duties; no `_rows` file, so **no owner SQL paste**). The Duties side and the owner manual checks are in [duties.md](duties.md) (story 4.12).

### Handover under the Q4 owner-scope rule

- **Handover hook** (`app.followups_report_handover`, read only, before Identity decides, set-based: one plan per call): one obligation `followup_task` (subject = the task) per active task the member owns. It is the **last responsible** person when nobody **the app can reach** may own the task (review S3): a **deactivation** is then refused `handover_required` (reassign or close the task first); a **deletion** records it pending and erasure waits. Review N2: one `followup_supervision` obligation per task the member supervises that nobody else can supervise (never last responsible: a supervision gap never blocks a change; it stays pending for an Admin).
- **Lifecycle hook** (`app.followups_on_member_lifecycle`, inside Identity's transaction, after Duties and before Notifications):
  - `membership_deactivated` and `deletion_requested`: each active task the member **owns** goes to the first candidate of the owner decision Q4 rule (the task's own group or a current Pastor) **whom the app can reach** (review S3; an accountless, held or in-review member is never chosen): its **supervisor** (when they hold the task's scope), then **another holder of the task's scope** (leader kinds first, then by grant age), then a **live Pastor**, then **another member of the task's group**. Each task the member **supervises** goes to another active holder of its scope (reachable first), else to its owner when they hold the scope (self-supervision, the 4.9 fallback); else a `followup_supervision` obligation stays pending. Review N3: when a task is handed to its supervisor, a new supervisor is chosen the same way from the other holders. The obligations Identity recorded are resolved `handed_over` in the same transaction.
  - **At most 25 tasks per lifecycle change** (review S1; one budget for the transaction, shared by the change's events, soonest due or review date first). The rest keep their owner and their pending obligations, listed for the Admin on **Membership status** and on **Follow-up routing**, where **Hand over the next 100** runs `followups.complete_handover` `{member_id}` (Admin, `expected_revision` null; for a member still in the church only what they may no longer hold; answer `{member_id, handed_over, remaining}`). The plan (owners, supervisors, reachability) is computed once per distinct owner, supervisor, scope and purpose, so it stays cheap for a member with many tasks.
  - `scope_revoked`: a leader or deputy who lost a scope stops supervising its tasks (supervision moves as above) and hands over the tasks they own once they are no longer in the task's group (for example a leader who is not a member of the department). Their authority already ended: every command, replay and read checks current grants.
- **What changes on a task:** owner and/or supervisor, a new schedule revision (fresh logical keys), the old recipient's reminders cancelled, the new owner told (`followup_assigned`) and the reminders planned again. Activity: `reassigned` / `supervisor_changed` with capacity `source`, no person and code `handover` (clients: "handed over automatically"; never why). With the Q2 policy unavailable the handover still happens and the activity records `reminders_skipped` (`policy_unavailable`).
- **Resolving later:** a trigger resolves a task's pending obligation when its owner changes (`followups.reassign` by its scope or an Admin: `handed_over`) or the task is Done or Closed (`no_longer_needed`). A deletion's erasure then continues at the next worker run.

### Owner authority is live; what waits is listed (review B1)

- **Owner capacity needs the owner to be in the task's group now** (`followups_capacity`, replaced): the task's roster under the owner decision Q4 rule (the target's members through its owner's roster hook, the holders of the family's scope kinds and the live Pastors, all active). An owner who left the group (a revoked scope, a removal from the department) or lost the Pastor role can no longer open, update or list the task (`api.followups_task` refuses `not_granted`, commands `not_found`, **My follow-ups** leaves it out), whether or not it was handed over yet. An accountless member still in the group keeps owner capacity (the 4.6 design). Supervisor and Admin capacities are unchanged.
- **What waits is visible.** `app.followups_pending_handovers()` lists every active task whose owner is no longer in its group (`followup_task`) or whose supervisor left or no longer holds its scope (`followup_supervision`), the same kinds as Identity's handover obligations. `api.followups_admin_routing` adds `handovers` per member (`member_id`, `display_name`, `membership_state` approved / deactivated / deleting, `tasks`, `supervisions`), shown on **Follow-up routing** (staff web, Admin) under **Waiting for handover** with **Hand over the next 100**. A revoked scope records no Identity obligation (Identity's obligations belong to a deactivation or deletion and need its lifecycle event; Follow-ups cannot write them), so this list is where the Admin sees what the hook could not hand over within its cap. Erased (former) members' tasks are left out: they are reassigned one by one (4.6).
- **`followups.complete_handover` acts on active members too:** for a member still in the church it moves what they may no longer hold (not in the group, scope lost); for one who left, everything. It never refuses an active member any more.
- **The people chosen are locked (review S5).** `followups_handover_member` share-locks the new owners and supervisors it chose (member-id order, before the tasks), checks them again (active; owners reachable) and computes the plan again when one was deactivated or held meanwhile (up to three times; then the rows naming such a person wait for the next step). E2E `L27`: the Admin's step raced with the deactivation of the first candidate gives the tasks to the next holder; without the lock they went to the member being deactivated. Two lifecycle changes handing tasks to each other at the same moment can still meet in a deadlock; Postgres refuses one (`unavailable`) and it can be retried.
- **No reminders for someone who left (review N12).** A deactivation or deletion cancels the member's reminders of the tasks still waiting (owner `followups_task`, supervisor `followups_supervision`); whoever takes a task over gets them planned again. This adds about 0.5 ms per waiting task to the change. After a revoked scope the waiting tasks' reminders still go to the former owner (still a member, reachable) until the Admin continues; their content is not shown to them.

### Locks (review S2)

Every Follow-ups command that may queue a notice to a member (`followups.create_task`, `update_task`, `reassign`, `complete_handover`) takes `FOR KEY SHARE` on those members' `identity_members` rows (the task's owner and supervisor, a named owner, supervisor or member), in member-id order through `app.followups_lock_people`, in the authorizer before any Follow-ups row (the dispatcher hands the payload over in the transaction-local `followups.command_payload`). Order (review N9): the actor's own member row, then the actor's grants (`FOR SHARE`), then the other members, then (4.6 review N5, now really firing: review N10) a named supervisor's grants. A command racing a lifecycle change then waits instead of deadlocking (duties.md, story 4.12, Gates and locks).

### Cost

A handed-over task costs about 15-20 ms locally (Notifications cancels and plans its reminders per task, as a reassignment does); one plan over 1000 tasks about 50 ms; cancelling a waiting task's reminders about 0.5 ms. `supabase/tests/duties_lifecycle_scale_test.sql`: a deactivation of a member owning 1000 and supervising 30 tasks (and serving 200 future duties) about 1.5-2.2 s with 25 handed over and the rest's reminders cancelled; each `followups.complete_handover` step (100 tasks) about 1.7-2.5 s; eleven steps leave nothing pending (see duties.md, story 4.12).

### Staging and owner checks

Applied with the Duties migration (duties.md, story 4.12, Hosted staging); owner checks 2 and 6 there cover the task handover.
