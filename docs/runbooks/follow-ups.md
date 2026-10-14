# Runbook: follow-up tasks (epic 4, Follow-ups owner)

Follow-ups is the one accountable task registry (architecture AD-7). Sources (duties coverage, visitors, missing reports, care, custody) do not keep their own trackers: they open one task per source and purpose in Follow-ups and register what their source events do to it. Reminders arrive with entry 7, lifecycle and handover hooks with entry 12.

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
- **Owner candidates** (fail closed): a task's owner is chosen from its target's roster only: the target's current members and the current holders of the family's scope kinds, approved and not under deletion. Create, reassign (also by an Admin) and the owner operation refuse anyone else (`owner_member_id: not_in_scope`). Widening this is open owner question Q4 below.
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

`app.followups_erase_member` is registered. Erase clears the text of every note the member wrote, that was written for them, or that sits on a task they own (`erased_at`), and replaces the member's and the account's ids with the nil UUID in tasks, activity and notes. No row is removed (no `_rows` file). A deleted owner's active task stays active, shows **Former member** and can be reassigned by its scope; the handover obligation for open tasks arrives with entry 12. Check answers 0 afterwards.

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

0. **Roster.** Staff web as A: **Departments**: M, O and X are members of `SYNTHETIC Preaching Rota` (owners are chosen from the department's members and leaders only). Optionally give a deputy D of the department.
1. **Create.** Staff web as L: **Follow-ups** > **Create a task**: purpose `SYNTHETIC check-in`, scope = the department, owner M (the owner list shows only the department's members and leaders), next action `SYNTHETIC: phone and check in`, a due date next week, **Create task**. Expect **Task created** and the task with **Open**. Create a second task for M and one for X with a private note.
2. **My follow-ups on the phone.** As M: **Home** shows **My follow-ups** with "2 open". **See all** lists both; open the first: the next action, `SYNTHETIC check-in source`, due date and supervisor L.
3. **Every state.** Tap **In progress** (**Sending…** then **Saved**, status **In progress**). Enter a review date and time, tap **Waiting**: the due date stays and the review date shows. Pick **Contacted**, **Record outcome**. Tap **Done**: status **Done**, the update buttons are gone. On the second task type no reason: **Close** stays disabled; type a reason and **Close**: **Closed** with the reason.
4. **For the accountless owner.** Staff web as L: open X's task: the line "what you record here is shown as recorded by you for X". Record **Contacted** and a note: the activity and the note say "recorded by L for X".
5. **Reassign.** In **Follow-ups**, **Reassign** X's task to O: **Reassigned**. As O (phone or staff web **My follow-ups**) the task is listed. As M, the task never appears. (Optional, with deputy D: D's **Follow-ups** lists the same tasks as L's, and D can record and reassign.)
6. **Duplicate.** (API, optional) send `followups.create_task` again with the first task's `source_id`: `conflict` `task_exists`.
7. **Admin routing.** Staff web as A: **Follow-up routing** shows owner, supervisor, scope, state and dates of each task and no next action, outcome or note. Open a task by URL (`/followups/tasks/<id>`): routing metadata only, no notes, no update buttons.
8. **Refusals.** As O, open M's task by URL: **Not available to you**. A direct table query with a member token (`GET /rest/v1/followups_notes`, `Accept-Profile: app` or `api`) is refused (406/404).
9. **Clean up** (SQL editor): delete the `followups_notes`, `followups_activity` and `followups_tasks` rows of the synthetic tasks, then remove the members as in `identity-access.md`.

Record the outcome per step in `evidence-4.6/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Open owner questions

- **Q4: who may be chosen as an owner.** Since the review, a leader (and an Admin) chooses only from the task's target: the department's or cell's current members and its leaders (the fail-closed default). Everything also stays behind the Q4 personal-data gate in production. Decide whether owners may ever be chosen from outside the target (for example a church-wide follow-up team).

### Known limits (later entries)

- No reminders on assignment, at the deadline or to the supervisor a day later (entry 7).
- No lifecycle or handover hooks: deactivation does not yet hand over open tasks (entry 12).
- No real source yet: duties coverage (entry 9) and the consumer guide with both-client fixtures (entry 11) follow. Care and finance note grants arrive with their owners.
- No due-date change and no reopen of a Done or Closed task.
