# Runbook: follow-up tasks (epic 4, Follow-ups owner)

Follow-ups is the one accountable task registry (architecture AD-7). Sources (duties coverage, visitors, missing reports, care, custody) do not keep their own trackers: they open one task per source and purpose in Follow-ups and register what their source events do to it. Reminders arrive with entry 7, lifecycle and handover hooks with entry 12.

## Story 4.6: open the Follow-ups registry with My follow-ups for every owner

Migration: `supabase/migrations/20261014120000_followups_registry.sql` (forward only; no destructive statements, no row deletions, no `_rows` file, so **no owner SQL paste**). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-open-the-follow-ups-registry-with-my-follow-ups-for-every-ow-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.6/`.

### Model (Follow-ups owns it)

- **Purposes** (`app.followups_purposes`): registered by the source's owner (below). Each has a generic label, the Identity scope kinds whose holders supervise its tasks, its outcome codes, the legal lifecycle effect of a source event and whether a scope holder may create tasks by hand.
- **Tasks** (`app.followups_tasks`): exactly one per `source_type/source_id/purpose`, for ever (a Done or Closed task still blocks a second one). One owner (an approved member, with or without a login), one supervisor holding the task's scope, the scope (`scope_kind`, `scope_id`), a next action (1-200 characters), the original due date (never moved in 4.6), the state and the latest outcome.
  - **States.** Open, In progress and Waiting are active and move freely between each other. Waiting needs a review date (future, at most a year away); every review-date change is recorded. Done and Closed are final (no reopen yet). Closing by hand needs a reason (1-200 characters); a source closes with `source_resolved` / `source_cancelled` and no text.
  - **Overdue.** Open and In progress are overdue once the due date passes; Waiting once the review date passes. `due_passed` keeps the original deadline's history while Waiting.
- **Activity** (`app.followups_activity`): content-free (ids, codes, states, dates): who acted, in which capacity (`owner`, `supervisor`, `admin`, `source`) and for whom (`on_behalf_of_member` when a scope holder records for the owner).
- **Private notes** (`app.followups_notes`): free text, shown only to the owner and the holders of the task's scope; never to Admin routing, never in receipts or activity.
- Every Follow-ups command and read is behind the Q4 personal-data gate (`app.identity_applications_open()`): open in a database marked local or staging, closed in production until Q4 is approved. Production stays inert.

### Who may do what

| Who | Sees | May |
|---|---|---|
| Owner (any member) | My follow-ups: their tasks with next action, context, notes, activity | status, review date, outcome, next action, private note on their own active task |
| Holder of the task's scope (the supervisor or another leader of it) | the scope's tasks, all of the above | the owner's updates, recorded "by me for the owner"; reassign owner or supervisor; create tasks for manual purposes |
| Admin (role alone) | routing metadata: owner, supervisor, scope, purpose, state, dates | reassign owner or supervisor; create a manual task naming a supervisor in scope (no note) |
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
- `api.followups_supervision()`: for holders of a scope some purpose registered: their scopes, the manual purposes, the scopes' tasks and the approved members to choose an owner from (name and `app_account`/`no_login` only).
- `api.followups_admin_routing()`: Admin only; routing metadata of every task and the members to reassign to.

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

- Refusals (PCTR1): not the source type's owner; purpose not in the shared contract; a label that is not 1-60 generic printable ASCII (no `{ } < > @ \`); unknown scope kinds; an effect other than `close` or `keep`; a context hook of another module or the wrong signature. Registering again replaces the registration.
- **Context hook.** Gets `{source_type, source_id, purpose, task_id, viewer_member_id}` and answers exactly `{"label": "<1-80 characters>"}`: the minimal context that viewer may see. Anything else, or a hook that raises, shows no context (fail closed). Never return care, finance or contact details.
- **Owner operations**, inside your own command after locking your source (Follow-ups comes after the domain owners and before Notifications in the AD-2 lock order); neither is client-executable:
  - `app.followups_open_task({source_type, source_id, source_revision, purpose, owner_member_id, supervisor_member_id, scope_kind, scope_id, next_action, due_at, actor_member_id, actor_account_id})` answers `{task_id, revision}`; refusals are the kernel's (`validation_failed`, `conflict {"purpose": "task_exists"}`, `unavailable` while the Q4 gate is closed), so your command fails with them.
  - `app.followups_source_event({source_type, source_id, event: "resolved" | "cancelled"})` applies each active task's registered effect and answers `{closed, kept}`. Task completion never changes a source: Done is not attendance, visit consent, completion or receipt.
- The SYNTHETIC worked example is `fixture_followup` (owner `fixture`): any id is a source at revision 1, current only in a database marked local or staging; its context hook answers `SYNTHETIC check-in source`.

### Member deletion (2.11 hook)

`app.followups_erase_member` is registered. Erase clears the text of every note the member wrote, that was written for them, or that sits on a task they own (`erased_at`), and replaces the member's and the account's ids with the nil UUID in tasks, activity and notes. No row is removed (no `_rows` file). A deleted owner's active task stays active, shows **Former member** and can be reassigned by its scope; the handover obligation for open tasks arrives with entry 12. Check answers 0 afterwards.

### Clients

- **Mobile:** the Home shows a **My follow-ups** card only while the member owns open work (count, overdue count, the next task, **See all**); a failed read says so and never looks empty. **See all** opens `/followups`; a task opens `/followups/tasks/<id>` with **In progress**, **Done**, **Waiting** (review date and time, church time), **Record outcome**, **Change next action**, **Add note** and **Close** (reason). Nothing shows as done until the server confirms; an unknown outcome shows **Not sent yet** with **Check again** (same request).
- **Staff web:** **My follow-ups** (every member with access), **Follow-ups** (leaders and deputies of a department, leaders and assistants of a cell: create a SYNTHETIC task, reassign, open a task to record for its owner) and **Follow-up routing** (Admin: metadata only, reassign). Dates are church time (Lusaka).

### Local runs

```sh
npx supabase db reset
npm run -s db:test                     # includes supabase/tests/followups_registry_test.sql (117 checks)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/followups.mjs --evidence <file.jsonl>
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/followups.test.mjs
```

The E2E uses the fictional numbers +44 7700 900220-900229 (pgTAP: 900210-900219) and removes everything it created.

### Hosted staging (parent session, then the owner)

1. Parent session: apply `20261014120000_followups_registry.sql` to staging (`tmurpotfluignacfueki`) after `20261014081513`. Compare per-function md5 with the local database (the file holds no `\u` escapes; the invisible-character class is built with `chr()`). Run `tools/ci/verify-hosted.sql` (`expected_env=staging`). No Edge Function change. No owner SQL paste.
2. Rebuild the staging staff web and phone builds (publishable key only) as in `notifications.md`, story 3.7, step 2.

### Owner manual checks (staging, phone and web, story 4.6)

Use synthetic members only. You need: an Admin A, a leader L of `SYNTHETIC Preaching Rota` (from 4.1, or give the scope again), a member M with the app on an Android phone, a member O and an accountless member X (staff web **Members & applications** > create a member without a login, SYNTHETIC name, fictional number).

1. **Create.** Staff web as L: **Follow-ups** > **Create a task**: purpose `SYNTHETIC check-in`, scope = the department, owner M, next action `SYNTHETIC: phone and check in`, a due date next week, **Create task**. Expect **Task created** and the task with **Open**. Create a second task for M and one for X with a private note.
2. **My follow-ups on the phone.** As M: **Home** shows **My follow-ups** with "2 open". **See all** lists both; open the first: the next action, `SYNTHETIC check-in source`, due date and supervisor L.
3. **Every state.** Tap **In progress** (**Sending…** then **Saved**, status **In progress**). Enter a review date and time, tap **Waiting**: the due date stays and the review date shows. Pick **Contacted**, **Record outcome**. Tap **Done**: status **Done**, the update buttons are gone. On the second task type no reason: **Close** stays disabled; type a reason and **Close**: **Closed** with the reason.
4. **For the accountless owner.** Staff web as L: open X's task: the line "what you record here is shown as recorded by you for X". Record **Contacted** and a note: the activity and the note say "recorded by L for X".
5. **Reassign.** In **Follow-ups**, **Reassign** X's task to O: **Reassigned**. As O (phone or staff web **My follow-ups**) the task is listed. As M, the task never appears.
6. **Duplicate.** (API, optional) send `followups.create_task` again with the first task's `source_id`: `conflict` `task_exists`.
7. **Admin routing.** Staff web as A: **Follow-up routing** shows owner, supervisor, scope, state and dates of each task and no next action, outcome or note. Open a task by URL (`/followups/tasks/<id>`): routing metadata only, no notes, no update buttons.
8. **Refusals.** As O, open M's task by URL: **Not available to you**. A direct table query with a member token (`GET /rest/v1/followups_notes`, `Accept-Profile: app` or `api`) is refused (406/404).
9. **Clean up** (SQL editor): delete the `followups_notes`, `followups_activity` and `followups_tasks` rows of the synthetic tasks, then remove the members as in `identity-access.md`.

Record the outcome per step in `evidence-4.6/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Open owner questions

- **Q4: who may be chosen as an owner.** Today a leader picks any approved member (name and app account / no login only). This stays behind the Q4 personal-data gate, so production shows nothing until you decide whether leaders may choose any church member or only the members of their own scope.

### Known limits (later entries)

- No reminders on assignment, at the deadline or to the supervisor a day later (entry 7).
- No lifecycle or handover hooks: deactivation does not yet hand over open tasks (entry 12).
- No real source yet: duties coverage (entry 9) and the consumer guide with both-client fixtures (entry 11) follow. Care and finance note grants arrive with their owners.
- No due-date change and no reopen of a Done or Closed task.
