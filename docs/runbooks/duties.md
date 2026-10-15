# Runbook: assigned duties (epic 4)

Architecture: AD-1, AD-2, AD-4, AD-6, AD-8, AD-14. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-2.md` (Q2: Africa/Lusaka, creator-set deadlines, creator-configured reminders, member snooze, no quiet hours; the pilot department is not chosen, so staging uses `SYNTHETIC Preaching Rota`). **Leaders, deputies and Admins:** start with the task-ordered guides in [duties-guides.md](duties-guides.md) (story 4.13): setting up a department, publishing duties and rotas, coverage, contact and Confirmed by leader, outcomes, handover, Admin tasks and duty reminder problems. The sections below are the per-story detail for maintainers.

Related runbooks: [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (owner registry, reminder contracts, deletion hooks), [identity-access.md](identity-access.md) (story 2.3 grants and scope kinds, 2.5 accountless members), [notifications.md](notifications.md) (the inbox, the worker, reminder health).

## Story 4.1: publish a one-position department duty and accept it on mobile

Migrations: `supabase/migrations/20261013220239_duties_department_tracer.sql` (no destructive statements, no row deletions) and its small rows file `supabase/migrations/20261013220300_duties_department_tracer_rows.sql` (the member-deletion row purge; the owner applies it by hand on hosted projects). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-publish-a-one-position-department-duty-and-accept-it-on-mobi-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.1/`.

### Model (Duties owns it)

- **Departments** (`app.duties_departments`): created by an Admin. While Q4 (personal data) is unapproved, every name must start `SYNTHETIC ` and the department is marked synthetic. Names are unique (case-insensitive).
- **Leader and deputy are Identity scope grants**: Duties registers the scope kinds `department_leader` and `department_deputy` (scope id = department id). Give or remove them with the audited 2.3 commands `identity.grant_scope` / `identity.revoke_scope`. A cell leader scope gives no department authority. Revoking a scope takes effect on the leader's next request (also for an open tab).
- **Department members** (`app.duties_department_members`): approved members with or without a login, added by an Admin. Membership is a Duties record, not an Identity grant. One current row per department and member; since story 4.12 an Admin ends a row with `duties.remove_member` (below).
- **Occurrence, slot, assignment** (`app.duties_occurrences`, `app.duties_slots`, `app.duties_assignments`): one published occurrence with exactly one owning department, a duty name, a start, an optional end and reporting time, an optional location and instructions; one slot (position 1); and the slot's one current assignment with the leader's response deadline (never after the reporting time or start) and the member's explicit answer (`pending`, `accepted`, `declined`) with the answering member, account, time and provenance (`member`).
- **Audit** (`app.duties_audit`): action, actor member and account, capacity (`admin`, `department_leader`, `department_deputy`, `member`), request id, ids, a code and the revision. Never names, notes or free text.
- **Vocabularies** are checked by `app.duties_state_ok(kind, value)`, not inline CHECK lists, so later stories widen them with `create or replace` (no constraint is dropped).

### Commands (`POST /rest/v1/rpc/duties_command`, `Content-Profile: api`)

The `duties` authorizer is registered in the 2.3 authorizer registry. It needs a live member session (`unauthenticated` otherwise) and share-locks the actor's Admin and department leader/deputy grants; each handler checks the capacity. Every command needs the personal-data gate (`local`/`staging`, or Q4 approved), otherwise `unavailable {"policy": "gate_closed"}`.

| Command | Who | `expected_revision` | Payload |
|---|---|---|---|
| `duties.create_department` | Admin | null | `{name}` |
| `duties.add_member` | Admin | department revision | `{department_id, member_id}` |
| `duties.publish_duty` | the department's leader or deputy, or an Admin | null | `{department_id, duty_name, starts_at, ends_at?, reporting_at?, location?, instructions?, member_id, response_deadline}` (instants in UTC RFC3339) |
| `duties.respond` | the assignee only | assignment revision | `{assignment_id, response: accepted \| declined, note?}` (note up to 280 characters) |

Refusals with their field codes:

| Case | Answer |
|---|---|
| Not an Admin (setup), not a manager of the department (publish), Pastor (publish) | `forbidden` |
| Someone else's assignment, an unknown department | `not_found` |
| Name without `SYNTHETIC ` while Q4 is unapproved | `validation_failed {"name": "invalid"}` |
| Name in use | `conflict {"name": "taken"}` |
| Member not approved or under deletion | `validation_failed {"member_id": "unknown"}` |
| Member already in the department | `validation_failed {"member_id": "current"}` |
| Assignee not a current department member | `validation_failed {"member_id": "not_in_department"}` |
| Start in the past / more than 2 years ahead | `validation_failed {"starts_at": "past" \| "out_of_range"}` |
| End not after start; reporting after start or in the past | `{"ends_at": "before_start"}`, `{"reporting_at": "after_start" \| "past"}` |
| Deadline missing, in the past, or after the (reporting) start | `{"response_deadline": "required" \| "past" \| "after_start"}` |
| Stale revision | `conflict` with `current_revision` |
| Already answered | `conflict {"assignment_id": "responded"}` |
| The duty has started (reporting time or start passed) | `validation_failed {"assignment_id": "started"}` |

- A replay with the same request id returns the stored result after the kernel rechecks scope (`app.duties_in_scope`): a leader whose scope was revoked gets `forbidden` even for a replay.
- Publishing creates the occurrence, slot and pending assignment, audits it, and enqueues the new-duty inbox item (Notifications last in the lock order), all in one transaction. A response records the answer and cancels the assignment's pending jobs (`responded`).
- **Answers carry ids, revisions and states only** (`create_department`/`add_member`: `{department_id, revision}`; `publish_duty`: `{occurrence_id, department_id, revision, slot_id, assignment_id, assignment_revision, response, notice_queued}`; `respond`: `{assignment_id, revision, response}`). Command receipts keep answers and member deletion does not rewrite receipts, so no name or note goes into them; the clients read the lists again after each command.
- A concurrent create with the same department name answers `conflict {"name": "taken"}` (the unique index's violation is mapped).

### Reminder source (3.2 contract)

- Source type `duties_assignment` (source id = assignment id, source revision = the assignment's revision), kind `duty_assigned`.
- Contract text: **New duty assigned** / "You have a new duty. Open it to accept or say you cannot make it." Link `/duties/assignments/{source_id}`; both clients list it in `ClientPaths.deepLinkTargets`.
- Check `app.duties_assignment_reminder_check`: `current` while the assignment is current at that revision; `actionable` while the answer is pending and the duty has not started; `recipient_eligible` while the recipient is the assignee and still a department member. After an answer the opened item shows the generic superseded state; My duties is the live view.
- The job is scheduled at publish time. A held, deactivated or accountless assignee gets no inbox item: 3.5 routes the need to a direct-contact route, and 4.1 registers none, so the need is recorded `unrouted` (finish reason `no_direct_contact_route`) and shows in **Reminder health** until entry 8 adds the leader's Needs contact list (built in story 4.8, below).
- Response reminders, default deadlines and Short notice arrive with entry 8 (built in story 4.8, below).

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.duties_my_duties()` | a member with live access | `{member_id, assignments: [...], truncated}`: the caller's current assignments of the last 90 days onwards, future ones first (soonest first), then past ones (most recent first), at most 200 (`truncated` when more exist), with department, times, location, instructions, deadline, answer and the member's own note |
| `api.duties_leader_board()` | department leaders and deputies (their departments), Admin (all, may publish), Pastor (all, read only, without members' notes); anyone else `403 not_granted` | departments with the roster of active members (account shown only as `app_account` or `no_login`; an access review is not disclosed to leaders) and duties of the last 30 days onwards (at most 200, `duties_truncated`), each position's assignment and answer |
| `api.duties_admin_overview()` | Admin | departments with leaders, deputies (with grant revisions) and members; approved members not under deletion (at most 500, `members_truncated`). Rosters here carry the full account label (`app_account`, `no_login`, `access_review`). Members who are no longer approved or are under deletion leave every roster and the Who list; their past assignments stay readable on the duties |

### Member deletion (2.11 hook)

`app.duties_erase_member` is registered with `app.identity_register_deletion_hook('duties', ...)`. Erase deletes the member's department memberships (`app.duties_deletion_purge_rows`, body in the rows file) and keeps assignments, occurrences, departments and audit rows as anonymous facts: member and account ids become the nil UUID and the member's response note is cleared. Check counts what is left. Without the rows file the erase step answers `unavailable` and nothing is erased (fail closed).

Lifecycle hooks (deactivation or removal ending future assignments) and the handover hook (last leader of an active department) are registered since story 4.12 (below).

### Clients

- **Staff web.**
  - **Departments** (`/admin/departments`, Admin): add a department, give or remove **Leader** / **Deputy** (through `identity.grant_scope`), add members (members without a login are marked "no login").
  - **Duties** (`/duties/leader`, shown while the caller leads or deputises a department, or is Admin or Pastor): each department with its duties, "N of M confirmed", each position's answer (**Awaiting response** with the deadline, **Accepted**, **Can't make it**) and the member's note; **Publish a duty** (duty, date, start, optional end time and end date for a duty that ends after midnight, optional reporting time, location, instructions, who, answer-by date and time). Every time is entered and shown in **church time** (`Africa/Lusaka`, UTC+02:00, no daylight saving; `ChurchTime` in `client_core`), whatever zone the computer or phone is set to; mobile shows the same church times. CI also runs `packages/client_core/test/duties` with `TZ=America/New_York` to prove this. Pastor sees "Pastor oversight (read only)" and no form.
- **Mobile.** **Duties** tab (`/duties`, shown with member access): **Needs a response**, **Upcoming**, **Past**; **Accept** and **Can't make it** with an optional note; **Details** opens `/duties/assignments/<id>`, which is also where the inbox item leads. The status reads **Sending…** while the request is out and **Not sent** when the outcome is unknown (with **Check again**, same request id); **Accepted** appears only from the server's answer. "You have no upcoming duties." is shown only for a successful empty read; a network failure says so instead.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                       # supabase/tests/duties_tracer_test.sql (+ the ledgers)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties.test.mjs
(cd packages/client_core && flutter test test/duties)
```

The E2E needs a database without a usable Admin (reset first). Fictional numbers: pgTAP `+44 7700 900950-900959`, E2E `900960-900969`. The E2E removes every user, member, link, grant, department, duty, job, item and receipt it created and revokes its worker credential.

### Hosted staging (parent session, then the owner)

1. **Parent session: the main migration.** Apply `20261013220239_duties_department_tracer.sql` to staging (`tmurpotfluignacfueki`) after `20261013194009`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. No Edge Function changes. New client grants (`authenticated` only): `api.duties_command(jsonb)`, `api.duties_my_duties()`, `api.duties_leader_board()`, `api.duties_admin_overview()` and their `app` definer bodies.
2. **Owner, by hand: the rows file.** In the staging SQL editor paste and run `supabase/migrations/20261013220300_duties_department_tracer_rows.sql` after the main file, the same way as `20261008135900_notifications_routing_rows.sql`. It replaces one stub (`app.duties_deletion_purge_rows(uuid)`) and changes no schema object. Check: `select pg_get_functiondef('app.duties_deletion_purge_rows(uuid)'::regprocedure) like '%delete from app.duties_department_members%';` is true. Until then a member deletion waits at its erase step (`unavailable`), which is safe.
3. **Prerequisites (already on staging):** the environment marker `staging`, the 3.4 worker schedule and its credential, and SYNTHETIC members (seed as in `identity-access.md`, "Seeding a synthetic approved member"). The worker delivers within about a minute.
4. **Production:** nothing in this story. Publishing needs Q2 (`q2_church_time`) for its enqueue and Q4 (or the staging marker) for personal data; both stay closed in production until the owner approves them.

### Owner manual checks (staging, phone and web, story 4.1)

Use synthetic members only (no real names or numbers). You need: an Admin A, a leader L, a member M with the app on an Android phone, another member O and a member N with no role; all seeded SYNTHETIC members. Build the clients against staging as in `notifications.md`, story 3.7, step 2 (publishable key only).

1. **Department.** Staff web as A: **Departments** > **Add a department**: `SYNTHETIC Preaching Rota` > **Add department**. Expect **Department added** and the card. Try a name without `SYNTHETIC `: **Check the form**.
2. **Leader and members.** On the card: choose L, **Leader**, **Give this role** (expect **Role given**); **Add a member**: M, then O (**Member added** each time).
3. **Publish.** Staff web as L (sign in again if L was already signed in): **Duties** is in the sidebar. Under **Publish a duty** enter `Sunday preaching`, a date next week, start `09:00`, location `SYNTHETIC Main hall`, who = M, answer by = a date two days before at `18:00`, **Publish**. Expect **Duty published** and the duty with **Awaiting response** and "0 of 1 confirmed". An answer-by time after the start shows "Must be before the duty starts".
4. **Inbox on the phone.** As M on the phone, within about a minute the **Inbox** shows **New duty assigned**. Open it: **Open** leads to the duty (**Duty**) with its details and deadline.
5. **Accept.** Optionally type a note, tap **Accept**. The status shows **Sending…**, then **Accepted** with **Accepted** as the notice. (Optional: turn on airplane mode first and tap **Accept**: it must show **Not sent** with **Check again**, never **Accepted**; turn airplane mode off and **Check again**.)
6. **Leader sees it.** Staff web as L: **Reload**: **Accepted**, "1 of 1 confirmed" and M's note.
7. **Refusals.** As O on a phone or web: **Duties** shows no duty of M's, and the staff web has no **Duties** entry for O (a direct `POST /rest/v1/rpc/duties_leader_board` with O's token answers 403). As N: the same; N cannot publish (no entry, and the API answers `forbidden`). A direct table query with any member token (`GET /rest/v1/duties_assignments`, with `Accept-Profile: app` or `api`) is refused (406/404).
8. **Pastor (optional).** Give a SYNTHETIC member the Pastor role (Roles & access): **Duties** lists every department as "Pastor oversight (read only)" without the note and without a publish form.
9. **Clean up** (SQL editor): delete the duties rows of the department (audit, slot revisions (since 4.2), assignments, slots, occurrences, department members), the jobs/attempts/items of the synthetic members, the scope grants, then the department; remove the members as in `identity-access.md`.

Record the outcome per step in `evidence-4.1/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits (later entries)

- One position, one-off occurrences, no drafts, no cancellation (4.3). Edits arrive with 4.2 (below).
- No later decline ("Can't make it anymore"), bulk acceptance or calendar export (4.5, now built; see below).
- No default deadline, Short notice, response or pre-service reminders, snooze of duty reminders, or Needs contact list (4.8, 4.9).
- No lifecycle or handover hooks (built in story 4.12, below).

## Story 4.2: revise assignments on material change and refuse stale responses

Migration: `supabase/migrations/20261014001142_duties_revisions.sql` (forward only: the 4.1 files are not edited; no destructive statements, no row deletions, no new `_rows` file, no new client grant). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-revise-assignments-on-material-change-and-refuse-stale-respo-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.2/`.

### Model

- **Slot revisions** (`app.duties_slot_revisions`): one immutable row per published, material or notes change of a slot (`change_class` `published`, `material`, `notes`) with `changed_fields`, a snapshot of the slot's fields, the assignee and the current assignment at that revision. A trigger refuses every update except member deletion replacing a person id with the nil UUID. The migration back-fills revision 1 for slots published under 4.1.
- **Assignment lifecycle**: `current`, `superseded` (a material change replaced it; `end_reason` `revised`) and `cancelled` (vocabulary only until 4.3 adds the cancelling command). An assignment records the slot revision it answers and the assignment it supersedes. The answer, its member, account, time, provenance and note stay on the superseded row. A slot keeps exactly one current assignment. A trigger (`app.duties_assignment_history_guard`) makes an ended assignment immutable, except member deletion replacing person ids with the nil UUID and clearing the note.
- **What is material** (`app.duties_slot_field_class`, the single classification): `duty_name`, `starts_at` (the date and start), `ends_at`, `reporting_at`, `location` and `member_id` (the assignee) are material; `instructions` are notes. `response_deadline` belongs to the assignment. Any slot field a later story adds must be classified there.

### Command `duties.revise_duty`

`{occurrence_id, duty_name?, starts_at?, ends_at?, reporting_at?, location?, instructions?, member_id?, response_deadline?}` with `expected_revision` = the occurrence revision. The department's leader or deputy, or an Admin (not Pastor, not another department's leader, not a cell leader). The payload is a patch: present keys are the change, `null` clears an optional field, a value equal to the current one is no change.

- **Material change** (any material field differs): needs a new `response_deadline` (the leader's until entry 8 adds the 3.3 default; built in story 4.8, below), checked against the new times. The current assignment becomes `superseded` (answer kept), a new `pending` assignment is created for the same member or the new one, the old assignment's pending jobs are cancelled `source_revised` and a generic notice is queued: `duty_changed` to the same member, or `duty_assigned` to a new member plus `duty_released` to the old one.
- **Notes-only change** (only `instructions`): the answer stands (no new assignment, no revision change of the assignment); one generic notice goes to a pending or accepted assignee: any notice of the assignment not yet sent (`duty_assigned`, `duty_changed`, `duty_updated`) is cancelled `replaced` and re-sent once as the most telling kind (a new duty stays a new duty), otherwise `duty_updated`.
- **Erased or departed assignee**: no notice is ever addressed to an erased member (nil UUID). A material change that keeps an assignee who was erased, left the department or is under deletion is refused `{"member_id": "required_reassign"}`: choose a new assignee. An instructions-only change still saves (no notice).
- Answer: `{occurrence_id, revision, change: material | notes, slot_id, slot_revision, assignment_id, assignment_revision, superseded_assignment_id, response, notice_queued}`: ids, revisions and states only.

| Case | Answer |
|---|---|
| Not a manager of the department, Pastor | `forbidden` |
| Unknown occurrence | `not_found` |
| Stale occurrence revision (another manager saved first) | `conflict` with `current_revision` |
| The duty has started | `validation_failed {"occurrence_id": "started"}` |
| Nothing differs | `validation_failed {"occurrence_id": "unchanged"}` |
| Material change without a deadline; deadline past or after the (reporting) start | `{"response_deadline": "required" \| "past" \| "after_start"}` |
| A deadline with a notes-only change | `{"response_deadline": "not_material"}` |
| A required field cleared; times out of order | `{"duty_name" \| "starts_at": "required"}`, `{"ends_at": "before_start"}`, `{"reporting_at": "after_start" \| "past"}` |
| New assignee not a current, active department member | `{"member_id": "not_in_department" \| "unknown"}` |
| Material change keeping an assignee who can no longer serve | `{"member_id": "required_reassign"}` |
| Gate closed (production without Q4); untrusted session | `unavailable {"policy": "gate_closed"}`; `unauthenticated` |

A replay with the same request id returns the stored answer after the kernel rechecks the leader's scope; a leader whose scope was revoked gets `forbidden`.

### Stale responses

`duties.respond` on a superseded assignment answers `conflict` with `field_errors` `{"assignment_id": "superseded", "<field>": "changed", ...}`: the fields changed from the change that replaced it onwards (`member_id` when the duty went to someone else, but not when it is the member's again after A -> B -> A; never the new assignee's id or name). A cancelled assignment answers `conflict {"assignment_id": "cancelled"}`. Nothing changes. A revise and a respond racing on the same assignment serialise on the assignment row: whichever commits first wins, and the other sees the new state.

### Notices (3.2 contracts on `duties_assignment`)

| Kind | Title / body | Link | Delivered while |
|---|---|---|---|
| `duty_changed` | **Duty changed** / "One of your duties changed. Open it to see what changed and answer again." | `/duties/assignments/{source_id}` (the new revision) | the assignment is current and pending, the duty has not started, the member serves in the department |
| `duty_updated` | **Duty details updated** / "The details of one of your duties were updated. Open it to read them." | `/duties/assignments/{source_id}` | the assignment is current, not declined, not started |
| `duty_released` | **Duty changed** / "A duty you were given has changed and is no longer assigned to you." | `/duties` | the superseded assignment's position is not the member's again, not started |

The source check now also treats a superseded assignment at its final revision as current, so the released notice can be keyed to it; the per-kind checks decide delivery. An inbox item of an older revision opens as out of date. Push stays generic (story 3.6).

### Reads

- `api.duties_my_duties`: each assignment adds `slot_revision`, `changes` (what the change that created it changed, when it replaced the member's own earlier assignment; null otherwise), `previous_response`, `previous_assignment_ids` (the member's own earlier assignments of the position, following the position's chain through other members' assignments, so an old reminder link still finds the current version; other members' ids are never listed) and `notes_updated_at`.
- `api.duties_leader_board`: each position adds `slot_revision` and `history` (ended assignments, newest first, at most 20, with `state`, `end_reason`, `ended_at`, the kept `response`, `responded_at`, `response_provenance` and the note; Pastor sees no notes); the current assignment adds `slot_revision`, `changes` and `notes_updated_at`.

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: slot revisions (`member_id`, `created_by_member`, `created_by_account`) are anonymised with the nil UUID, like assignments and audit. No new rows are deleted, so the 4.1 rows file stays the only purge.

### Clients

- **Staff web, Duties** (leader, deputy, Admin): **Change this duty** on a duty that has not started opens the form prefilled in church time. It says what will happen: "<name> will be asked to answer again (changed: …)" or "Only the instructions change: the answer stands." A material change needs **New answer by** (date and time) before **Save the change** is enabled. Each position shows **Changed: …** on a new revision and **Earlier versions** with each kept answer ("SYNTHETIC Ruth: Accepted, answered …, by the member, replaced by a change …"). A conflict ("Changed elsewhere") reloads the board. Pastor sees the history and no form.
- **Mobile, Duties**: a new revision shows **Changed** with "What changed: …" and "Your earlier answer was "Accepted". Please answer again."; an instructions update shows "Details updated …. Your answer stands." An answer to an old version is refused: **This duty changed** ("Your answer was not recorded: the … changed since you opened it…", or "…no longer assigned to you") and the list reloads. An old reminder link opens the current version under **This duty changed**. **Sending…** / **Not sent** / **Check again** (same request id) work as in 4.1.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_revisions_test.sql (+ duties_tracer_test.sql)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-revisions.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-revisions.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900970-900979`, E2E `900980-900989`. The E2E proves the race with two real concurrent HTTP requests (leader and deputy at the same revision).

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261014001142_duties_revisions.sql` to staging (`tmurpotfluignacfueki`) after `20261013220300`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. Compare the md5 of each replaced or new `app.duties_*` function body with the local one (the MCP apply decodes `\uXXXX` escapes; this migration has none, but check). No Edge Function change, no new client grant, no rows file. Check: `select count(*) from app.duties_slot_revisions;` equals the number of slots published before (revision 1 back-filled).
2. **Owner:** nothing to paste. Then the manual checks below.
3. **Production:** nothing in this story (Q2 and Q4 gates stay closed).

### Owner manual checks (staging, phone and web, story 4.2)

Use synthetic members only. You need the setup of the 4.1 checks (Admin A, leader L, a deputy D of the same department, member M with the app on an Android phone, member O). Build the clients against staging as in 4.1.

1. **Accept.** As L publish `Sunday preaching` to M (a date next week, start `09:00`, answer by two days before). On the phone as M, open the **New duty assigned** item and tap **Accept**: **Accepted**.
2. **Change the time.** Staff web as L: on the duty, **Change this duty**. Change **Start time** to `10:00`: the form says "… will be asked to answer again (changed: date or start time)". **Save the change** stays disabled until **New answer by** is filled; fill it, save. Expect **Duty changed**, the position **Awaiting response** with **Changed: date or start time**, and under **Earlier versions** "M: Accepted, answered …, by the member, replaced by a change …".
3. **Change notice.** Within about a minute M's **Inbox** shows **Duty changed**; **Open** shows the duty at 10:00 with **Changed**, "What changed: date or start time." and "Your earlier answer was "Accepted". Please answer again." The old **New duty assigned** item now says it is out of date.
4. **Late answer to the old version.** As L publish a second duty (`Reading`) to M. On M's phone open it and keep that screen in the foreground with the screen on (the app re-reads only on **Reload** or when it comes back to the foreground). As L change its start time (with a new answer-by time). Then, without leaving the screen, tap **Accept** on the phone. Expect **This duty changed** ("Your answer was not recorded: the date or start time changed …") and the duty reloads to the new version; the leader still sees **Awaiting response**. **Accept** the new version: the leader sees **Accepted**.
5. **Instructions only.** Staff web as D: **Change this duty**, change only **Instructions**: the form says "Only the instructions change: the answer stands." Save: **Details updated**; the position still shows **Accepted**. M gets **Duty details updated**; the duty shows "Details updated …. Your answer stands." and **Accepted**.
6. **Two leaders at once.** Open the duty's **Change this duty** form as L and as D in two browsers; change the instructions in both and save one after the other without reloading. The first shows **Details updated**; the second shows **Changed elsewhere** and its board reloads with the first one's text.
7. **Give it to someone else.** As L change **Who** to O with a new answer-by time. O gets **New duty assigned**; M gets **Duty changed** ("… no longer assigned to you"), whose **Open** shows My duties without that duty. The history keeps M's acceptances.
8. **Refusals.** As O (a member), the staff web has no **Change this duty**; a direct `POST /rest/v1/rpc/duties_command` with `duties.revise_duty` and O's token answers `forbidden`. As Pastor the history shows without notes and without the form. `GET /rest/v1/duties_slot_revisions` with any member token is refused.
9. **Clean up** as in 4.1, step 9 (slot revisions before assignments).

Record the outcome per step in `evidence-4.2/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits (later entries)

- One position per occurrence: `member_id` in a revision is refused (`unsupported`) once occurrences have several positions (4.3 adds per-position edits, series edits and cancellation).
- The new deadline is the leader's; the 3.3 default deadline, Short notice and response or pre-service reminders arrive with entry 8 (a material change will then re-plan them; built in story 4.8, below).
- A declined assignment stays current until the leader changes or reassigns it; the coverage queue and leader confirmation arrive with entry 9 (built in story 4.9, below).

## Story 4.3: generate recurring multi-position rotas with drafts and series edits

Migration: `supabase/migrations/20261014023442_duties_rota_series.sql` (forward only: the 4.1 and 4.2 files are not edited; no destructive statements, no row deletions, no new `_rows` file). New client grant: `api.duties_rota()` and its `app` body (authenticated only). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-generate-recurring-multi-position-rotas-with-drafts-and-seri-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.3/`.

### Model

- **Rota series** (`app.duties_series`): a Duties-owned standalone recurrence for one department: duty name, every N days, weeks or months, a first and last **church-local date** (the same date for a one-off multi-position duty), church-local start, optional end and reporting times, location, instructions, optional topic and scripture, an optional linked-event reference (`event_ref`, an opaque id until Content exists), 1 to 10 named positions and optional exception dates. It records the church zone and the Q2 policy version used (AD-9).
- **Generation** happens once, when the series is created, through the shared 3.3 calculation (`app.notifications_occurrences` under the Q2 zone, `Africa/Lusaka`): a duty at 00:30 church time on Sunday stays on Sunday although it is Saturday in UTC. It is bounded (at most 60 occurrences, a window of at most 366 days, only starts that are still in the future) and idempotent (one occurrence per series and church-local date; a replayed command returns the stored answer). An end time at or before the start time ends on the next day.
- **Drafts**: every generated occurrence starts as `draft` with one slot per named position. A slot may carry a **planned person** (`draft_member_id`): not an assignment, no notice, no reminder. My duties, reminders and the 4.1/4.2 leader board never show drafts; the leader board lists published duties only.
- **Occurrence states**: `draft`, `published`, `cancelled`. A cancelled occurrence ends its current assignments (`cancelled`, `end_reason` `cancelled`; their answers are kept) and records a `cancelled` slot revision per position.
- **Field classes** (`app.duties_slot_field_class`): `topic` and `scripture` are notes (an update notice; answers stand); `event_ref` is a reference (recorded as a `reference` slot revision, no notice, and not reported to the member as a details update; `revise_duty` answers `change: reference`); `position_name` is material and fixed at creation (4.3 cannot rename or add positions).
- **Audit**: every rota action is audited with its series id; published, revised and cancelled positions also carry their assignment id.

### Commands (all through `api.duties_command`)

The department's leader or deputy, or an Admin (never Pastor, another department's leader or a cell leader). Times in a series are church-local `HH:MM`, dates `YYYY-MM-DD`. Answers carry ids, revisions, states and counts only.

| Command | `expected_revision` | Payload | What it does |
|---|---|---|---|
| `duties.create_series` | null | `{department_id, duty_name, every: day\|week\|month, interval?, from_date, until_date, start_time, end_time?, reporting_time?, location?, instructions?, topic?, scripture?, event_ref?, positions: [names], exceptions?: [dates]}` | generates the draft occurrences; `{series_id, department_id, revision, occurrences, draft_slots}` |
| `duties.assign_slot` | occurrence revision | `{slot_id, member_id, response_deadline?}` | draft: plan (or with `member_id: null` clear) the person, no notice; published: give the position to a current department member with the answer-by `response_deadline` (a current assignment of someone else is superseded by the 4.2 rules: answer kept, jobs cancelled, released notice) |
| `duties.publish_drafts` | series revision | `{series_id, slot_count, deadline_before}` | "Publish N draft slots": every draft of the series that has not started; `slot_count` must be N; each planned person gets a pending assignment with the answer-by `(reporting or start) - deadline_before` in church time and one `duty_assigned` notice; positions without anyone publish unfilled; all or nothing |
| `duties.revise_duty` | occurrence revision | 4.2 payload plus `topic?`, `scripture?`, `event_ref?` | **this date only**: every position changes together (material: every assignee is asked again with the new `response_deadline`; notes: answers stand, one update notice each); a draft is edited in place without notices and takes no `response_deadline`; `member_id` only for a one-position published duty |
| `duties.revise_series` | series revision | `{series_id, from_occurrence_id, duty_name?, start_time?, end_time?, reporting_time?, location?, instructions?, topic?, scripture?, event_ref?, deadline_before?}` | **this and later dates**: the anchor and every later occurrence that has not started and is not cancelled, on each one's own church-local date; earlier and started occurrences are never changed; a material change of a published occurrence needs `deadline_before` |
| `duties.cancel_occurrence` | occurrence revision | `{occurrence_id}` | cancels one series occurrence (draft or published, not started) |
| `duties.cancel_series` | series revision | `{series_id, from_occurrence_id}` | cancels the anchor and every later occurrence that has not started |

Refusals with their field codes:

| Case | Answer |
|---|---|
| Not a manager of the department, Pastor | `forbidden` |
| Unknown series, occurrence or slot | `not_found` |
| Stale revision (another leader saved first) | `conflict` with `current_revision` |
| N no longer the number of draft slots | `conflict {"slot_count": "changed"}` |
| More than 60 dates; more than 366 days; last before first; last date past; nothing in the future | `{"until_date": "too_many" \| "out_of_range" \| "before_from" \| "past"}`, `{"from_date": "no_occurrences"}` |
| Bad times, rule, positions | `{"start_time" \| "end_time" \| "reporting_time": "invalid"}`, `{"reporting_time": "after_start"}`, `{"every": "invalid"}`, `{"interval": "out_of_range"}`, `{"positions": "required" \| "too_many" \| "invalid" \| "duplicate"}` |
| An answer-by that has already passed for a date | `{"deadline_before": "passed"}` |
| A material this-and-future change of published duties without the lead time | `{"deadline_before": "required"}` |
| A planned person who can no longer serve (left, not approved, under deletion) | `{"member_id": "unavailable"}` (publish), `{"member_id": "required_reassign"}` (a material edit keeping them) |
| A person who is not a current department member | `{"member_id": "not_in_department" \| "unknown"}` |
| An answer-by on a draft | `{"response_deadline": "draft"}` |
| Started or cancelled occurrence; anchor not in the series | `{"occurrence_id" \| "from_occurrence_id": "started" \| "cancelled"}`, `{"from_occurrence_id": "not_in_series"}` |
| A one-off duty cancelled here | `{"occurrence_id": "not_in_series"}` (entry 9 brings position cancellation: `duties.cancel_position`, built in story 4.9, below) |
| Nothing changes | `{"occurrence_id" \| "series_id" \| "slot_id": "unchanged"}` |
| Gate closed (production without Q4, or without Q2 for generation and publishing); untrusted session | `unavailable {"policy": "gate_closed"}`; `unauthenticated` |

**Which date?** When one date of a series stops a `publish_drafts` or `revise_series` (an answer-by that has passed, a person who can no longer serve, a time that does not fit), the answer also names that date with the key `occurrence:<occurrence_id>` and the same code (ids only); the Rota page shows the problem and an **Open** button for that date.

A replay with the same request id returns the stored answer after the kernel rechecks scope (series: a current manager of its department); a leader whose scope was revoked gets `forbidden`, also for a replay. Lock order: grants -> receipt -> department -> series -> occurrences (date order) -> membership -> slots -> assignments -> Notifications (always last; the change engine returns its notification work and the command runs it after every Duties row is written). A member's answer racing a series edit serialises on the assignment row: whichever commits first wins, and the other sees the new state.

### Notices

| Kind | Title / body | Link | Delivered while |
|---|---|---|---|
| `duty_cancelled` | **Duty cancelled** / "One of your duties was cancelled. Open My duties to see what is still yours." | `/duties` | the cancelled assignment is at its final revision and the duty would not yet have started; sent to assignees who were pending or had accepted |

Publishing a rota uses the 4.1 `duty_assigned` contract for every generated assignment; changes use the 4.2 kinds. Cancelling an occurrence cancels every pending job of its assignments (`source_cancelled`). An accountless or held assignee's notice is recorded `ineligible`/`no_direct_contact_route` until entry 8 adds the leader's Needs contact list (built in story 4.8, below).

### Reads

- `api.duties_rota()` (leaders and deputies: their departments; Admin: all; Pastor: all, read only; anyone else `403 not_granted`; Q4 gate; synthetic departments hidden outside local/staging): each department with `can_manage`, its roster (`app_account`/`no_login` only; inactive members filtered) and its series that end 30 days ago or later (at most 50, `series_truncated`), each with its template, `draft_slots` (the N to publish) and every occurrence (`draft`, `published`, `cancelled`) with `started`, `confirmed` of `required` (current accepted positions over all positions) and each position's planned person or current assignment with `available` (false when the person can no longer serve; no reason given). No member notes.
- `api.duties_my_duties` adds `position_name`, `topic` and `scripture`; `api.duties_leader_board` (published duties only) adds `series_id`, `position_name`, `topic`, `scripture` and `event_ref`.

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: a planned (draft) position of the member becomes unplanned, and series creators are anonymised with the nil UUID. No new rows are deleted, so the 4.1 rows file stays the only purge.

### Clients

- **Staff web, Rota** (`/duties/rota`, sidebar **Rota** next to **Duties**; leaders, deputies, Admin; Pastor read only): **New rota** (duty, repeats every N day(s)/week(s)/month(s), first and last date, start, optional end and reporting time, positions separated by commas, location, instructions, topic, scripture) makes the draft dates. Each rota shows a **grid** (one row per date, one column per position, **Confirmed** "2 of 3") and **Show as list**, an accessible text list of the same facts. **Publish N draft slots** asks for confirmation with the number of planned people and unfilled positions and an **Answer by** lead time (2 hours to 30 days before the reporting or start time). Selecting a date opens it: **Who** per position (**Save plan** for a draft, **Give this position** with the answer-by for a published date; members without a login are marked "no login: contact them directly"), **Change** (scope **This date only** or **This and later dates**; it says whether people will be asked again) and **Cancel date(s)…** (same scopes; the confirmation says how many dates and who gets a notice: people who were waiting to answer or had accepted, not those who declined, and nothing for drafts). A refused answer-by shows on the **Answer by** picker, a refused person under that position, and a refusal for another date names it with an **Open** button. Grid dates are buttons for screen readers too; in the list each date is a heading and its button names the date. Every state is the server's: **Sending…**, **Not sent yet** with **Check again** (same request id), and a reload while a command is out keeps it pending.
- **Staff web, Duties** (the 4.1/4.2 board) lists published duties with their position names, topic and scripture; **Change this duty** on a multi-position date changes every position together and has no **Who** field (positions are given on the Rota page).
- **Mobile, Duties** shows the position ("Sunday service: Preacher"), the topic and the scripture. Cancelled duties leave the list; the **Duty cancelled** notice opens My duties.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_rota_test.sql (+ 4.1, 4.2 and the ledgers)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-rota.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-rota.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900990-900999`, E2E `900740-900749`. The E2E proves two real races (two leaders planning the same position, two leaders publishing at once) and a member's answer racing a series edit.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261014023442_duties_rota_series.sql` to staging (`tmurpotfluignacfueki`) after `20261014001142`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. Compare the md5 of each new or replaced `app.duties_*` function body with the local one (the MCP apply decodes `\uXXXX` escapes; this migration has none, but check). New client grant: `api.duties_rota()` / `app.duties_rota()` (authenticated only). No Edge Function change, no rows file. Check: `select count(*) from app.duties_series;` is 0 and `select count(*) from app.duties_occurrences where occurrence_state <> 'published';` is 0 right after the apply.
2. **Owner:** nothing to paste. Then the manual checks below.
3. **Production:** nothing in this story (Q2 and Q4 gates stay closed: generation and publishing answer `unavailable`).

### Owner manual checks (staging, phone and web, story 4.3)

Use synthetic members only. You need the 4.1 setup (Admin A, leader L, deputy D of `SYNTHETIC Preaching Rota`, member M with the app on an Android phone, member O, and an accountless member X added to the department), and the staff web built against staging.

1. **Generate.** Staff web as L: **Rota** > **New rota**: `Sunday service`, every 1 week(s), first date a Sunday at least three days away, last date 12 weeks later, start `10:00`, positions `Preacher, Reader, Usher`, **Make the draft dates**. Expect **Rota created** and a grid of 13 Sundays (church time), each **Draft** with **Not planned** in the three columns; **Publish 39 draft slots**.
2. **Drafts are private.** On the phone as M: **Duties** shows nothing new and the inbox has no item. As O on staff web there is no **Rota** entry; a direct `POST /rest/v1/rpc/duties_rota` with O's token answers 403.
3. **Plan.** Select the first Sunday: Preacher = M (**Save plan**), Reader = O, Usher = X ("no login: contact them directly"); the second and third Sundays: Preacher = M. Expect **Plan saved** each time, the grid showing "Planned: …", and still no notice on M's phone. **Show as list** shows the same in text.
4. **Publish.** **Publish 39 draft slots**: the confirmation says 5 planned people are asked and 34 positions stay unfilled; **Answer by** 1 day before; confirm. Expect **Drafts published**, every row **Published**, unplanned cells **Unfilled**; within about a minute M's inbox shows three **New duty assigned** items.
5. **Coverage.** M accepts the first Sunday on the phone; O accepts on another device. Staff web **Reload**: the first Sunday's **Confirmed** reads **2 of 3** (X still **Awaiting response**).
6. **This date.** Select the second Sunday > **Change** > **This date only**, start `09:00`; the form says everyone assigned is asked again; pick **Answer by** 1 day before; **Save for this date**. Expect **Duty changed**: only that row moves to 09:00 and M's position there is **Awaiting response**; the first Sunday still shows **2 of 3**.
7. **This and later dates.** Select the third Sunday > **Change** > **This and later dates**, start `11:00`, **Answer by** 2 days before, **Save for this and later dates**. Expect **Rota changed**: the third Sunday onwards show 11:00; the first two Sundays are unchanged (10:00 and 09:00) and each keeps its own answers.
8. **Cancel.** Select the second Sunday > **Cancel date(s)…** > **This date only** > **Cancel this date**. Expect **Cancelled** and the row **Cancelled**; M gets **Duty cancelled** on the phone and the duty leaves My duties.
9. **Pastor and refusals.** As a Pastor (Roles & access), **Rota** shows every department with "Pastor oversight (read only)", drafts included, and no buttons. A direct `GET /rest/v1/duties_series` with any member token is refused.
10. **Clean up** as in 4.1, step 9, with `app.duties_series` deleted after the occurrences.

Record the outcome per step in `evidence-4.3/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits (later entries)

- Positions are fixed when a rota is generated (no adding, removing or renaming in 4.3), and a series is not extended after creation (make a new rota for the next quarter).
- Overlap warnings and each candidate's upcoming load arrive with entry 4; default deadlines, Short notice and response or pre-service reminders with entry 8; the coverage queue, position cancellation of one-off duties and leader confirmation with entry 9 (built in stories 4.4, 4.8 and 4.9, below).
- A this-and-future edit overwrites the given fields on later dates, including dates changed one at a time before; fields not given keep each date's own value.
- Series times are on one church-local date: a reporting time must be at or before the start time on the same day, so a duty starting just after midnight with reporting the evening before cannot be expressed in a series (publish it as a one-off duty with instants instead).

## Story 4.4: warn on overlapping duties and record reasoned overrides

Migration: `supabase/migrations/20261014052239_duties_overlaps.sql` (forward only: the 4.1-4.3 files are not edited; no destructive statements, no row deletions, no new `_rows` file; `department_id` on occurrences becomes nullable with `ALTER ... DROP NOT NULL`, which the migration policy allows). New client grant: `api.duties_candidates(...)` and its `app` body (authenticated only). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-warn-on-overlapping-duties-and-record-reasoned-overrides-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.4/`.

### Model

- **Owning scope.** Every occurrence is owned by exactly one department or one cell (`app.duties_occurrences.cell_id`; check `duties_occurrences_one_owner`). No command creates a cell-owned occurrence yet: entry 11 adds the Cells owner operations (built in story 4.11, below). Until then cell-owned occurrences exist only as SYNTHETIC fixtures in pgTAP and the local E2E, and My duties lists department-owned duties only.
- **Commitment.** A current assignment the member has not declined (`pending` or `accepted`) on a published occurrence of any owner. Declined, superseded and cancelled assignments and cancelled occurrences are not commitments.
- **Busy time** (`app.duties_busy_range`): from the reporting time (or the start) to the end time; with no end time, **two hours** from the start (an adjustable assumption in one function). Ranges are half-open: a duty ending at 10:00 does not overlap one starting at 10:00.
- **The conflict query** (`app.duties_busy_items(member, range, exclude_slot, department)`): the member's commitments overlapping the range, other than the position itself, plus (when a department is given) the member's planned draft positions in that department. **No conflict never means free**: availability is not collected, and the screens say so.
- **Override.** Recorded with the assignment: `override_reason` (1-280 characters, the leader's words), `override_overlaps` (how many commitments overlapped), `override_by_member`/`override_by_account` and `override_at`. A planned (draft) position keeps `draft_override_reason` with its planner and time; Publish N copies it into the assignment. Ended assignments keep their override unchanged (only erasure may clear the reason).
- **Audit:** `overlap_override` with code `overlap` (ids only, never the reason); a draft planned over an overlap is audited `draft_assigned` with code `overlap`.

### The override gate

Every command that creates an assignment for a **new assignee** or with **new times** checks the person's commitments at the new busy time. Per-member transaction advisory locks (member id order, at the membership step of the lock order) serialise concurrent assignments of the same person, so two leaders cannot both skip the warning.

| Command | When it checks | Field |
|---|---|---|
| `duties.publish_duty` | always | `override_reason?` |
| `duties.assign_slot` (published) | the person given the position | `override_reason?` |
| `duties.assign_slot` (draft) | the planned person, against commitments **and** other planned positions of the department | `override_reason?`, kept on the slot; the same person with a new reason replaces it |
| `duties.publish_drafts` | every new assignment, after all of them exist (two positions of one person in one publish overlap each other) | the reason planned on each slot |
| `duties.revise_duty` | assignments re-created with new times or for a new person | `override_reason?` (one for the change) |
| `duties.revise_series` | likewise, on every date | `override_reason?` (one for the change) |

- An overlap without a reason: `validation_failed {"member_id": "overlap", "override_reason": "required"}`; nothing is written. Series commands also name the first date that needs it (`occurrence:<id>`).
- With a reason the assignment is made **pending**: the assignee still chooses whether to accept. Notices are the usual ones and never contain the reason.
- A change that keeps the person and the times (place, duty name) **carries the earlier override forward** without a new check, but only while that person's answer still stands (pending or accepted): asking a member again after they declined is a new commitment and is checked like any other. A reason given when nothing overlaps is not recorded.
- Cancelling a draft date (this date or this and later dates) clears its planned people and their planned reasons.
- A reason longer than 280 characters: `{"override_reason": "invalid"}`.
- Answers add counts only: `override_recorded` (`publish_duty`, `assign_slot`), `overrides` (`publish_drafts`, `revise_duty`, `revise_series`).

### Reads

- `api.duties_candidates(slot_id)`, `(slot_id, starts_at, ends_at?, reporting_at?)` (a position at the new times of an edit; the person's other positions of the same date move with it and count as overlaps) or `(department_id, starts_at, ends_at?, reporting_at?)` (a one-off duty not yet published), named parameters. The department's leader, deputy or an Admin; anyone else (Pastor and members included), an unknown or cell-owned position, or a synthetic department in production: `403 not_granted`; Q4 gate closed: `403 unavailable`; a malformed request: `400 validation_failed`. Answer: `{department_id, slot_id, window: {from, to}, candidates: [{member_id, display_name, account (app_account|no_login), current, upcoming: {total, here}, conflicts: {count, items}}]}` for the department's current active members.
  - `upcoming`: pending or accepted duties starting in the next 90 days, all owners (`total`) and this department (`here`).
  - Each conflict item (at most 10, earliest first) is **full** when the caller manages its department (leader, deputy, Admin) or leads or assists its cell: `occurrence_id`, `owner_kind`, `owner_name` (department name; null for a cell, because Duties never reads Cells), `duty_name`, `position_name`, `state` (`published`, or `draft` for a plan of this department), `response`, `starts_at`, `ends_at`, `reporting_at`, `location`, `from`, `to`. Otherwise it is **limited**: `visibility`, `owner_kind` and the busy time `from`/`to` only. Instructions are never part of a conflict. An Admin role alone gives no cell detail, and a synthetic department is never shown in full outside local and staging.
- `api.duties_leader_board` and `api.duties_rota` add, per current assignment, `overlaps` (how many commitments and planned positions of the department overlap it now; 0 for started or cancelled dates) and `override` (`{reason, overlaps, at, by}`), and per planned person `overlaps` and `override_reason`. Both are shown to the department's managers and Pastor oversight; never to the member, never to another department, and a reader never sees the reason recorded about their own assignment or plan (a leader who also serves). The counts are computed once per read, set-based (`app.duties_overlap_counts`), with the partial index `duties_assignments_member_current`. Measured locally on a seeded rota of 50 series x 52 weekly dates x 3 positions, every position assigned (2,600 dates, 7,800 assignments): all series projected in about 2.9 s (1.6 s without counts) and 200 board duties in about 0.25 s (0.09 s without); the per-position query it replaced took about 49 s.

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: an erased assignee's override reasons are cleared (the fact that an override was recorded stays, anonymous); recorders of overrides and planned reasons are anonymised with the nil UUID; a planned position of the erased member loses its planned reason with the person. No new rows are deleted.

### Clients (staff web)

- **Who** pickers (Publish a duty, Change this duty on a one-position duty, and each position on the Rota page) carry a permanent **Who** label and show every member with their load ("3 upcoming (1 here)") and "overlaps N at this time" on a second line that is never cut off (also in the item's screen-reader label). While times are typed, the check runs after a 400 ms pause. Choosing someone with an overlap shows a warning box listing what the leader may see: their own department's duties in full ("SYNTHETIC Preaching Rota: Evening service (Reader), <date> 10:30 to 11:30, at SYNTHETIC Side room, Accepted"), anyone else's as "Another department's duty, <time>" or "A cell programme part, <time>". A **Why assign them anyway? (required)** field appears, saying it is seen by the department's leaders and Pastor, not the member, and that they still choose whether to accept. With no overlap the picker says "No overlapping duty found ... This does not mean they are free: check with them."
- If the check could not run, the picker says so and the server still checks: a refusal shows **Overlaps another duty** and the reason field with "Give a reason, or choose someone else". A refused rota change shows a reason field for the change; a refused Publish N names the date with an **Open** button, where the leader re-plans the person with a reason (**Save the reason**).
- The board shows **Overlaps N other duties** and "Assigned despite an overlap: "..." (leader, time)"; the rota grid and list add "; overlaps N other duties (reason given)" to the position text.
- Mobile is unchanged: the member never sees the reason.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_overlaps_test.sql (+ 4.1-4.3 and the ledgers)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-overlaps.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-overlaps.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900770-900779`, E2E `900760-900769`. The E2E proves real races: two leaders of different departments assign the same member to the same time at once without reasons, three rounds of two one-off duties and one round of a rota position against a one-off duty, and exactly one succeeds each time (with the member lock disabled both succeed, so the check is meaningful). It also proves that asking a member again after they declined (a place change) needs a reason when another department has since given them that time.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261014052239_duties_overlaps.sql` to staging (`tmurpotfluignacfueki`) after `20261014023442`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. Compare the md5 of each new or replaced `app.duties_*` function body with the local one (the migration has no `\u` escapes, but check). New client grant: `api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)` / `app.duties_candidates(...)` (authenticated only). No Edge Function change, no rows file. Checks right after the apply: `select count(*) from app.duties_occurrences where cell_id is not null;` is 0 and `select count(*) from app.duties_assignments where override_at is not null;` is 0.
2. **Owner:** nothing to paste. Then the manual checks below.
3. **Production:** nothing in this story (the Q4 gate keeps the reads and commands closed).

### Owner manual checks (staging, phone and web, story 4.4)

Use synthetic members only. You need the 4.1 setup (Admin A, leader L of `SYNTHETIC Preaching Rota`, member M with the app on an Android phone), a second department `SYNTHETIC 4.4 Ushers` with leader U (another synthetic account; as A: **Departments** > add it, **Leader** = U), M added to both departments, and the staff web built against staging.

1. **First duty.** Staff web as U: **Duties** > **Publish a duty** in Ushers: `Sunday ushering`, a Sunday at least three days away, `10:00` to `12:00`, instructions `SYNTHETIC private ushers note`, Who = M, answer-by the day before. Expect **Duty published**.
2. **The warning, limited.** Staff web as L: **Publish a duty** in Preaching Rota: `Sunday preaching`, the same Sunday, `11:00` to `12:00`. Open **Who**: M shows "1 upcoming (0 here), overlaps 1 at this time". Choose M: the warning box says "M has 1 other duty at that time" and lists "Another department's duty, <date> 10:00 to 12:00" only: no "Ushers", no "Sunday ushering", no place and not the private note. The reason field appears.
3. **Refused without a reason.** Leave the reason empty, set the answer-by, **Publish**. Expect **Overlaps another duty** and "Give a reason, or choose someone else"; the board shows no new duty.
4. **Recorded with a reason.** Enter `SYNTHETIC: agreed to arrive after the first hour.` and **Publish**. Expect **Duty published**; the duty shows **Awaiting response**, **Overlaps 1 other duty** and "Assigned despite an overlap: ..." with L's name and the time. On M's phone, **Duties** shows both duties awaiting an answer and no reason anywhere; the inbox item is the usual **New duty assigned**.
5. **The other team cannot see it.** As U, **Duties**: the ushering duty shows **Overlaps 1 other duty** but no reason and no preaching details.
6. **No overlap, no warning.** As L, publish another duty for M the same Sunday `12:00` to `13:00`. Choosing M says "No overlapping duty found ... This does not mean they are free" and asks no reason; **Publish** succeeds.
7. **Rota.** As L, **Rota** > **New rota** for that Sunday only, start `10:30`, end `11:30`, positions `Preacher`; select the date, Who = M: the warning lists the 11:00 preaching duty in full (your department) and the ushering duty as "Another department's duty". **Save plan** without a reason is refused; with a reason the grid reads "Planned: M; overlaps 2 other duties (reason given)". **Publish 1 draft slot** succeeds and the position shows the recorded reason; M is **Awaiting response**.
8. **Refusals.** A direct `POST /rest/v1/rpc/duties_candidates` (`Content-Profile: api`) with M's token answers 403; with L's token and the Ushers `department_id` also 403.
9. **Clean up** as in 4.1, step 9, plus the Ushers department and its grants.

Record the outcome per step in `evidence-4.4/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits (later entries)

- Cell-owned occurrences arrive with entry 11 (the Cells owner operations; built in story 4.11, below); until then they are fixtures only, and a cell conflict never shows the cell's name (Duties never reads Cells).
- A duty without an end time is assumed to take two hours; every warning shows the busy time used.
- An overlap created later by someone else is recorded on the later assignment (with its reason); the earlier one only shows the overlap count.
- Draft edits (this date or this and later dates on drafts) ask no reason; Publish N checks and names the date.
- The member never sees the reason; the coverage queue, leader confirmation and the Home "upcoming conflicts" count arrive with entry 9 (built in story 4.9, below: the count is the overlapping duties line of the leader's **Needs attention** card).

## Story 4.5: respond from My duties with later decline and bulk acceptance

Migration: `supabase/migrations/20261014081513_duties_member_responses.sql`.
- Forward only: the 4.1-4.4 files are not edited.
- No destructive statements, no row deletions and no `_rows` file.
- No new client grant: both new commands go through `api.duties_command`.

Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-respond-from-my-duties-with-later-decline-and-bulk-acceptanc-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.5/`.

### Model

- **Earlier acceptance.** `app.duties_assignments.prior_accepted_at` holds the time the member had accepted before saying they can't make it anymore. The `duties_assignments_prior_accepted` check allows it only on a `declined` answer. Ended assignments keep it unchanged (the history guard is replaced to cover it).
- **Audit.** A later decline is `acceptance_withdrawn` with code `declined`. Each date of a bulk acceptance is a `response_recorded` row with code `accepted`, all under the one request id. Ids and codes only, never the note.
- **Cell-owned assignments fail closed.** Members cannot answer a cell-owned assignment until entry 11 builds the member view for cell parts (built in story 4.11, below: the refusal ends there). `duties.respond`, `duties.withdraw_acceptance` and `duties.accept_many` all answer `not_found` for an assignment of a cell-owned occurrence. My duties still lists department-owned duties only.

### Commands (`api.duties_command`)

**`duties.withdraw_acceptance {assignment_id, note?}`** ("Can't make it anymore")
- `expected_revision` is the assignment's revision. Only the assignee may send it, only for an acceptance the member recorded (`response_provenance = 'member'`), and only before the reporting time (or the start). An acceptance recorded any other way (a leader confirming on the member's behalf, entry 9) is refused as `responded` (fail closed).
- Ownership is checked first without a lock (`not_found` takes no row lock); the assignment is then locked and checked again.
- The answer becomes `declined` and the earlier acceptance time is kept. The response actor and time become the withdrawal's, and the note (1..280 characters, practical) replaces any earlier one.
- The assignment's pending jobs are cancelled (`responded`). The answer holds ids and states only: `{assignment_id, revision, response: "declined", withdrawn: true}`.
- Refusals:

  | Situation | Answer |
  |---|---|
  | Someone else's, unknown or cell-owned | `not_found` |
  | Still pending (answer it with Accept or Can't make it) | `conflict {"assignment_id": "not_accepted"}` |
  | Already declined | `conflict {"assignment_id": "responded"}` |
  | Another revision | `conflict` with `current_revision` |
  | Replaced by a change | `conflict {"assignment_id": "superseded", "<field>": "changed"}` |
  | Cancelled | `conflict {"assignment_id": "cancelled"}` |
  | Started | `validation_failed {"assignment_id": "started"}` |

**`duties.accept_many {assignments: [{assignment_id, revision}, ...]}`**
- `expected_revision` must be null. The payload carries 1..50 distinct dates, each at the revision the member saw.
- **All or nothing.** If any date is superseded, cancelled, already answered (`responded`), at another revision (`stale`) or started, nothing is recorded and the answer is `conflict {"assignments": "changed", "assignment:<id>": "<code>"}`, naming only the dates that failed.
- Someone else's, unknown or cell-owned dates answer `not_found` for the whole command, which says nothing about which date.
- Shape errors are `validation_failed` with `{"assignments": "required" | "invalid" | "too_many" | "duplicate"}`.
- Success: `{response: "accepted", count, assignments: [{assignment_id, revision}]}` in lock order (below). The receipt's aggregate is the first date in that order, so a replay is rechecked against its assignee. A retry under the same request id (a timeout) returns the stored answer and records nothing new.

**Lock order** follows the 4.3 and 4.4 header: authority grants, then the receipt, then occurrences, then assignments, then Notifications last.
- `accept_many` takes its occurrences FOR SHARE in (series, series date, start, id) order, with one-off duties after every series date, then its assignments FOR UPDATE in the same order. Series order by series date is the order `duties.revise_series` and `duties.cancel_series` lock a series' dates in; start order would differ from it once one date was moved with `duties.revise_duty`, and the two could deadlock.
- `withdraw_acceptance`, like `respond`, locks only its assignment (after an unlocked ownership check).

A leader's material change racing a bulk acceptance either lands first, so the bulk acceptance is refused whole, or lands second, so every date was accepted and the moved one is asked again. A partial acceptance never happens.

**Overlaps (4.4).**
- Accepting creates no new commitment, because a pending duty already counts. A decline only removes one.
- Neither command runs the override gate or takes the per-member locks.
- A gate racing a decline can at worst ask a leader for a reason that is no longer needed.
- After a later decline the leader's earlier override is not carried on a material change, so asking the member again is checked again.
- Members see no overlap warning: they choose.

### Reads

**`api.duties_my_duties`** adds, per assignment:
- `slot_id` (the position; stays the same when a material change replaces the assignment, so it is the calendar entry's id);
- `owner_kind` (`department`). The app answers only a `department` duty; any other value is shown but cannot be answered (fail closed). A missing value (a server before 4.5) is a department, since those list department-owned duties only;
- `prior_accepted_at`;
- `leaders`: `[{display_name, role: leader|deputy}]` for the department's current leaders and deputies.

Leader names only: contact details wait on Q4 and the entry 9 contact routes.

**`api.duties_leader_board` and `api.duties_rota`** add `prior_accepted_at` to each current assignment; the board also adds it to history entries. `confirmed` counts accepted answers only, so a later decline lowers it at once.

### Clients (mobile; staff web labels)

**My duties** has three segments, each with its count and its own empty copy:

| Segment | Shows | Empty copy |
|---|---|---|
| **Needs a response (n)** | pending and not started | "Nothing waiting for your response." |
| **Upcoming (n)** | accepted, and declined shown as "Can't make it" | "You have no upcoming duties." |
| **Past (n)** | started | "No past duties yet." |

- A failed read shows **No connection** / **Couldn't load**, never an empty list.
- Cards have a date badge (church date), the duty and position, department, times (church time), place and status.

**Answering**
- A duty that waits for an answer has an optional **Note for your leader** field on its card (list and detail). **Accept** sends it with the answer (the list card's **Accept**, the detail footer's **Accept**). The Home card's **Accept** sends no note.
- **Can't make it** opens a sheet with an optional practical note (prefilled with anything already typed on the card) and **Cancel**. Nothing is sent until **Send: can't make it**.
- **Details** opens the duty with a sticky footer:
  - pending: **Accept** and **Can't make it**;
  - accepted and not started: **Can't make it anymore**, which opens the same sheet and says the leader sees at once that the position needs cover;
  - otherwise nothing.
- A declined-after-accepting duty reads **Can't make it anymore**, with "You had accepted on ...".

**Bulk acceptance.** With two or more dates waiting, each card has a checkbox. **Accept selected (n)** opens a confirmation listing each date, duty and department. **Accept n duties** sends one `duties.accept_many`; **Cancel** sends nothing. A bulk acceptance carries no note, and the confirmation says so ("To add a note, accept that date on its own"). If a date changed, **Nothing accepted** explains and the list is read again.

**Honest states**
- While a command is out, the duty (every selected duty for a bulk acceptance) reads **Sending…**.
- An unknown outcome (airplane mode, a timeout) reads **Not sent**. **Check again** resends the same request id and body. **Accepted** shows only after the server confirms.
- **Not sent** lasts only while the server still shows the duty as the command found it (pending for Accept, Can't make it and a bulk acceptance; accepted for Can't make it anymore). When a read (Reload, resume) shows it answered, the server did record it: the server's answer is shown and the Not sent notice goes away.
- Screens shown together (the Home card, a list under a detail) read once on resume, not once each.

**Add to calendar** (detail; not for declined or started duties)
- The app builds an iCalendar file: reporting or start time to end time (two hours with no end), duty, position, department and place. Instructions and notes are never exported.
- The event's UID is the occurrence and its position (`duty-<occurrence_id>-<slot_id>@bickafue.app`), so exporting again after a material change replaces the earlier copy in calendars that honour it; `SEQUENCE` is the slot revision.
- On an iPad the share sheet is a popover anchored to the **Add to calendar** button (`sharePositionOrigin`).
- The mobile app hands the file to the phone's share sheet (`share_plus`). The wording follows the platform's answer:
  - "Calendar file shared ...";
  - "Calendar file handed to your phone. We can't tell whether it was saved ...";
  - "Not added: the share sheet was closed";
  - "Add to calendar isn't available in this version of the app" (staff web and tests).
- The caveat is always shown: the copy does not change if the duty changes or is cancelled, and My duties shows the current version.
- The deep link back is the in-app route `/duties/assignments/{id}` (the same as the reminders). The app's link scheme is not widened.

**Home.** A **Home** tab appears once member access is granted and holds the navy **My duties** card:
- "n awaiting your response";
- the next duty (date, duty, department, times, place, status) with inline **Accept** and **Can't make it**;
- **See all**.

Empty and failed reads differ. Later features add their own cards to Home. The `/home` route is registered in the mobile app only (staff web has no member Home).

**Staff web.** The board, its history and the rota read **Can't make it anymore** for a later decline, with "Had accepted <time>; needs cover".

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_responses_test.sql (+ 4.1-4.4)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-responses.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-responses.test.mjs
(cd packages/client_core && flutter test test/duties)
(cd apps/mobile && flutter test)
```

Fictional numbers: pgTAP `+44 7700 900550-900559`, E2E `900560-900569`. The E2E runs a real race in three rounds: the member accepts three dates together while the leader moves one of them. Each round must be all or nothing. Every round records the order it took (`bulk_first`: all three accepted, the moved date asked again; `edit_first`: the bulk acceptance refused whole), and `orders_seen` lists them; a timing run may see only one order.

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261014081513_duties_member_responses.sql` to staging (`tmurpotfluignacfueki`) after `20261014052239`.
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*` function with the local one. The migration has no backslashes, so no `\u` decoding applies.
   - Grants: there is no new client grant. Check that `authenticated` has no execute on `app.duties_withdraw_acceptance`, `app.duties_accept_many`, `app.duties_refuse_ended` or `app.duties_assignment_occurrence`.
   - Right after the apply, `select count(*) from app.duties_assignments where prior_accepted_at is not null;` is 0.
   - There is no Edge Function change and no rows file.
2. **Mobile build:** rebuild the staging APK. This story adds the `share_plus` plugin (13.3.0), which needs `flutter pub get` and a full build, not a hot reload.
3. **Owner:** nothing to paste. Then the manual checks below.
4. **Production:** nothing in this story (the Q4 gate keeps the reads and commands closed).

### Owner manual checks (staging, phone and web, story 4.5)

Use synthetic members only. You need the 4.1 setup: Admin A, leader L of `SYNTHETIC Preaching Rota`, and member M with the new staging APK on an Android phone. You also need the staff web built against staging.

1. **Accept.** As L, publish a duty for M next Sunday (`Sunday preaching`, `09:00`, answer-by two days before). On the phone, open **Home**: the card says "1 awaiting your response" and shows the duty. Tap **Accept**: **Sending…**, then **Accepted**. As L, **Reload**: **Accepted**, "1 of 1 confirmed".
2. **Decline with a note.** As L, publish a second duty for M a week later. On the phone, go to **Duties** > **Needs a response**, then **Can't make it** on it. The sheet asks for an optional note. Tap **Cancel** first: nothing changes. Tap **Can't make it** again, type `SYNTHETIC: travelling`, **Send: can't make it**. As L, **Reload**: **Can't make it** with the note.
3. **Later decline.** On the phone, go to **Duties** > **Upcoming**, open the accepted duty (**Details**). The footer shows **Can't make it anymore**. Tap it, add a note and send. The status reads **Can't make it anymore** with "You had accepted on ...". As L, **Reload**: **Can't make it anymore**, "Had accepted ...; needs cover", "0 of 1 confirmed".
4. **Bulk: three of four.** As L, **Rota** > **New rota**: four Sundays, position `Reader`. Plan M on every date and **Publish 4 draft slots**. On the phone, go to **Needs a response**: four dates with checkboxes. Tick three, then **Accept selected (3)**. The confirmation lists the three dates. Tap **Accept 3 duties**: **Accepted** "... accepted 3 duties". The fourth still waits. As L, the rota shows three **Accepted** and one **Awaiting response**.
5. **Airplane mode stays Not sent.** On the fourth date, turn on airplane mode and tap **Accept**. It must show **Not sent** with **Check again**, never **Accepted**. As L (web), **Reload**: still **Awaiting response**. Turn airplane mode off and tap **Check again**: **Accepted** (the same request is sent again). L sees it on **Reload**.
6. **A changed date refuses the selection.** As L, publish two more Sundays for M. On the phone, tick both but do not confirm. As L, change the time of one of them. On the phone, confirm: **Nothing accepted**. The list is read again, and the changed date shows **Changed**. Then, on the date that did not change, type `SYNTHETIC: on my way` in **Note for your leader** and tap its **Accept**: **Accepted**. As L, **Reload**: **Accepted** with the note.
7. **Empty versus error.** With nothing left to answer, **Needs a response** says "Nothing waiting for your response.". In airplane mode, **Reload** shows **No connection** (not an empty list), and the Home card says "No connection ... This is not an empty list."
8. **Add to calendar.** Open an accepted duty, **Add to calendar**. The share sheet opens with a `.ics` file; choose the calendar app. The app says the file was shared or handed over (never "added"), and the caveat says the copy does not update. Change the duty's time as L: the calendar entry stays old, and My duties shows the new time with **Changed**.
9. **Clean up** as in 4.1, step 9.

Record the outcome of each step in `evidence-4.5/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Known limits (later entries)

- Leaders get no push or inbox alert for a decline yet; the board shows it at once. The leader decline alert and the coverage queue arrive with entry 9 (built in story 4.9, below).
- Cell programme parts are not answerable or listed in My duties until entry 11 (built in story 4.11, below).
- No phone or Call action for the leader on the detail screen (Q4, entry 9 contact routes).
- Accepting several dates together is without a note; accept a date on its own to add one. The Home card's Accept sends no note.
- The calendar export is a copy. The iOS share sheet (iPad popover anchor) is unverified on a device until an iOS build exists.

## Story 4.8: set response deadlines and schedule creator-configured duty reminders

Migration: `supabase/migrations/20261014171038_duties_reminders.sql`.
- Forward only: the 4.1-4.5 files are not edited (replaced function bodies are listed in its header and keep every earlier review fix).
- No destructive statements, no row deletions and no `_rows` file.
- No new client grant: `duties.set_reminders` goes through `api.duties_command`.

Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-set-response-deadlines-and-schedule-creator-configured-duty-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.8/`.

### Deadlines

- The answer-by time is optional everywhere a duty is given to someone: `response_deadline` on `duties.publish_duty`, `duties.assign_slot` and `duties.revise_duty`, `deadline_before` on `duties.publish_drafts` and `duties.revise_series`. A leader's time keeps the 4.1-4.3 checks (`past`, `after_start`, `passed`); an answer-by time equal to the start (or the reporting time) is `after_start` too, and a `deadline_before` of zero is `out_of_range`.
- Without one, each new assignment takes the **3.3 lead-time default** for an assignment made now (`app.notifications_response_deadline`, anchored on the reporting time or the start). With the Q2 fixture: a duty 30 days or more ahead, 14 days before; 3 to 30 days ahead, 48 hours before; otherwise 24 hours before.
- When that default has already passed, or leaves less than **one hour** to answer (an agent decision under owner pre-approval: a reminder minutes after the assignment is no use), the assignment is **Short notice**: its deadline is the moment it was given, `app.duties_assignments.short_notice` is true, the member's new-duty (or change) notice is the one "answer now" message, and each leader and deputy gets `duty_short_notice` at once.
- `app.duties_assignments.deadline_source` is `creator` or `default` (rows from before 4.8 are `creator`). The stored deadline is always passed to Notifications explicitly, so an operator re-plan after a policy change never moves it.

### Reminders (creator-configured)

- `reminders` on `duties.publish_duty` and `duties.create_series` (copied to every generated date): `null` or absent = the defaults, `[]` = none, or up to the policy's `max_reminders` 3.3 `response` specs `{"anchor": "response_deadline" | "starts_at", "before" | "after": "<n> minutes|hours|days"}`. Refusals: `validation_failed {"reminders": "invalid" | "out_of_range"}`.
- **Defaults** (`app.duties_default_reminders`, one function to adjust): the policy's response defaults (24 hours before and at the deadline) and one pre-service reminder 24 hours before the reporting time or start. While the member has not answered, a pre-service reminder is sent as `duty_response_due` (it asks for the answer); after an acceptance it is `duty_starting`. Clients say "before the reporting time" when the duty has one. Specs a narrower policy no longer allows are dropped at plan time; a command never fails for them.
- **`duties.set_reminders`** (the department's leader or deputy, or an Admin):

  | Payload | `expected_revision` | Effect |
  |---|---|---|
  | `{occurrence_id, reminders}` | the occurrence revision | one date (draft or published, not started, not cancelled) |
  | `{series_id, from_occurrence_id, reminders}` | the series revision | the series template and every later date that has not started and is not cancelled |

  `reminders` is required (`null` for the defaults). Nobody is asked to answer again: current assignments are re-planned at their revision (a pending snooze survives). The same value again is `validation_failed {"occurrence_id" | "series_id": "unchanged"}`. Audited `reminders_set` (code `occurrence` or `series`). Answer: `{occurrence_id | series_id, revision, occurrences, replanned}`.
- **Leaders' alerts** are fixed rules, not creator options: one job per leader, `duty_response_overdue` at the deadline and `duty_short_notice` at once on Short notice, to each current department leader and deputy the app can reach (never the assignee; a held or in-review leader is skipped and refused at delivery, never an unrouted need), rechecked at delivery (still manages the department, answer still pending, not started). A re-plan of an unanswered assignment whose deadline has passed gives each leader who has no alert at that revision one now (a leader granted after the deadline gets it at the next re-plan, for example `duties.set_reminders`).
- **An answer is always recorded.** If the Q2 church-time policy is unavailable when a member accepts, declines or withdraws, the answer is still saved: the re-plan is skipped and audited (`reminders_skipped`, code `policy_unavailable`); the answer has already cancelled the response reminders and the leaders' alerts. Publishing or changing duties still needs the policy (fail-closed).
- **Cost.** The Q2 policy is validated once per transaction (`app.notifications_zone_known` and `app.notifications_policy` memoise per transaction), so a publish of 200 rota slots plans well inside the 8-second statement timeout (`supabase/tests/duties_reminders_scale_test.sql`; local: 26 slots 0.5 s, 200 slots 4.1 s, `accept_many` of 50 dates 0.55 s; before the fix 26 slots took 16.7 s).
- **No quiet hours**: reminders are sent when due, at any hour (a 23:30 church-time reminder stays at 23:30). The member can snooze a reminder from the Inbox (1 hour, 24 hours, 2 days); an answer stops the snooze.

### Reminder kinds (3.2 contracts)

| Source / kind | Title / body | Link | Delivered while |
|---|---|---|---|
| `duties_assignment` / `duty_response_due` | **Duty answer needed** / "One of your duties is waiting for your answer. Open it to accept or say you cannot make it." | `/duties/assignments/{source_id}` | current at that revision, pending, not started, still a member of the department |
| `duties_assignment` / `duty_starting` | **Duty coming up** / "One of your duties is coming up soon. Open it to see the details." | `/duties/assignments/{source_id}` | current at that revision, not declined, not started |
| `duties_coverage` / `duty_response_overdue` | **Duty answer overdue** / "A duty in your department passed its answer-by time without an answer. Open Duties to follow it up." | `/duties/leader` | the assignment is current and pending, not started, the recipient leads or deputises the department |
| `duties_coverage` / `duty_short_notice` | **Short-notice duty** / "A duty in your department was given at short notice and needs an answer now. Contact the member directly." | `/duties/leader` | as above |

`duties_coverage` is a second source keyed by the same assignment id (the member's reminders are a Notifications schedule; the leaders' alerts are single enqueued jobs, so a leader who also serves keeps both). Every new assignment, also after A -> B -> A, is a new source id: a returning member never meets a cancelled logical key.

**What stops what.** Accept: the member's response reminders and the leaders' alerts are cancelled (`responded`), the pre-service reminder is planned again at the new revision. Decline and "Can't make it anymore": everything is cancelled. A material change, reassignment or cancellation: every pending job of the old assignment ends (`source_revised` / `source_cancelled`), including the leaders' alerts; the new assignment gets a fresh plan.

### Needs contact (3.5 direct-contact route)

- `app.duties_record_contact_need` is registered for every kind an assignee is sent (`duty_assigned`, `duty_changed`, `duty_updated`, `duty_released`, `duty_cancelled`, `duty_response_due`, `duty_starting`). A held, in-review, accountless or deactivated assignee gets no inbox item; the worker records the need in `app.duties_contact_needs` (need id, assignment id, revision, kind, time; idempotent; no member id, no reason) and Notifications marks it `routed` (no longer `unrouted` in Reminder health).
- `api.duties_leader_board` and `api.duties_rota` add, per current assignment, `deadline_source`, `short_notice` and `needs_contact` (`{reasons: ["short_notice" | "not_reached"], since}` or null) and, per occurrence, `reminders`. `api.duties_my_duties` adds `deadline_source`, `short_notice` and `reminders`. The reason a member was not reached is never given (a hold is never disclosed).
- **Released and cancelled notices** (`app.duties_contact_notices`, in `api.duties_leader_board` as `contact_notices` per department for its leaders, deputies and Admins; empty for Pastor oversight): a member the app cannot reach whose duty was given to someone else or whose date was cancelled is listed (`notice`: `released` | `cancelled`, the duty, date and position, `since`) until the duty would have started, so the leader tells them in person. Never why. A released notice disappears when the position is theirs again.
- Contact attempts, leader confirmation and the coverage queue arrive with entry 9 (built in story 4.9, below).

### Clients

- **Staff web, Duties.** **Publish a duty**: **Answer by** is optional ("Leave the answer-by time empty for the church default ..."); **Choose the member's reminders** offers 2 days, 24 hours and at the answer-by time, 24 hours and 2 hours before the start (none picked = no reminders). **Change this duty** saves a material change without a new answer-by time (the default applies). Each duty shows its reminders with **Change reminders**. A position shows **Short notice** ("Given at short notice: answer requested now") and **Needs contact**; "(church default)" follows a default answer-by time. Each department starts with **Needs contact (n)**, listing who to contact directly and why in general terms, and "Tell <name>: <duty>, <date> is cancelled / is no longer theirs" for released and cancelled members the app cannot reach. **Change reminders** stays open with any refusal shown until the server accepts; **Cancel** puts the stored reminders back; a stored reminder that is not one of the choices is shown as "(custom)" and kept unless unticked.
- **Staff web, Rota.** **New rota** has the same reminder choice. **Publish N draft slots** and the date panel's **Answer by** start at **the church default (by lead time)**. A date shows its reminders with **Change reminders** and **Reminders: this and later dates**. The grid adds "; short notice" and "; needs contact".
- **Mobile.** A short-notice duty that waits for an answer reads **Short notice: please answer now**; the detail shows its reminders and that a reminder can be snoozed from the Inbox. The leaders' alert opens `/duties/leader` (now in `ClientPaths.deepLinkTargets`).

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_reminders_test.sql (+ 4.1-4.5)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-reminders.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-reminders.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900650-900669`, E2E `900670-900689`. The 4.1-4.5 E2E clean-ups now also remove the Notifications schedules and Needs contact rows their duties create.

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261014171038_duties_reminders.sql` to staging (`tmurpotfluignacfueki`) after `20261014130535`.
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*` function with the local one (the migration has no backslashes, so no `\u` decoding applies).
   - Grants: no new client grant. `authenticated` has no execute on any new `app.duties_*` function.
   - Right after the apply: `select count(*) from app.duties_assignments where deadline_source <> 'creator' or short_notice;` is 0, and `select count(*) from app.contract_direct_contact_routes where source_type = 'duties_assignment';` is 7.
   - Existing pending duties keep their 4.1-4.5 jobs; reminders are planned from the next assignment or change (no back-fill), like 4.7.
   - No Edge Function change, no rows file, no owner SQL paste.
2. **Staging clients:** rebuild the staff web and the staging APK (new screens).
3. **Owner:** nothing to paste. Then the manual checks below.
4. **Production:** nothing in this story (Q2 and Q4 stay closed; every Duties command needs both).

### Owner manual checks (staging, phone and web, story 4.8)

Use synthetic members only. You need the 4.1 setup: Admin A, leader L and deputy D of `SYNTHETIC Preaching Rota`, member M with the staging APK on an Android phone, member O, and an accountless member X in the department. The staging worker runs every minute.

1. **Mid-week for Sunday (default).** As L, **Publish a duty** for M next Sunday `10:00`, leave **Answer by** empty. Expect **Duty published**; the position reads "Answer by <Friday 10:00> (church default)" (48 hours before) and "Reminders: the defaults ...".
2. **A quarterly rota.** As L, **Rota** > **New rota** every week for 12 weeks; plan M on the first and last Sundays; **Publish N draft slots** with **Answer by: the church default (by lead time)**. The last Sunday's answer-by is 2 weeks before it; the first one's 2 days before.
3. **Same day (Short notice).** As L, publish a duty for M starting in 3 hours with no answer-by time. On the phone M gets one **New duty assigned** (not two items); the duty reads **Short notice: please answer now**. L and D each get **Short-notice duty** in their Inbox; **Open** leads to **Duties**, where the position shows **Short notice**, **Needs contact** and the department's **Needs contact (1)** list.
4. **Creator's reminders.** As L, publish another duty for O in 3 weeks with an answer-by time 3 days before and **Choose the member's reminders**: "2 days before the answer-by time" and "2 hours before the start". The duty shows exactly those.
5. **Accept and decline.** As M accept the step 1 duty: the leaders' overdue alert and the answer reminders stop (nothing arrives at its answer-by time); the pre-service reminder still arrives the day before. As O decline the step 4 duty: nothing more arrives for it.
6. **Reassign there and back.** As L, **Change this duty** on a duty of M's: Who = O (no new answer-by), save; then back to M. M gets **Duty changed** / **New duty assigned** as each time; O's reminders stop when it moves back.
7. **Accountless and held.** Publish a duty for X, and one for a SYNTHETIC member with the app who is then placed on hold (Admin, credential review). Within a minute neither gets an inbox item, and the board lists both under **Needs contact** ("Reminders cannot reach them in the app"; no reason given). Then **Change this duty** on X's duty to give it to O, and cancel another date of X's (Rota): **Needs contact** lists "Tell X: ... is no longer theirs" and "... is cancelled" until each date would have started.
7a. **Held deputy.** Place D on hold (Admin) and publish a duty for O in 3 hours (Short notice): only L gets **Short-notice duty**; D gets nothing, also after the hold is released for that duty. Release D's hold.
8. **Snooze.** When M's **Duty answer needed** arrives (or use a duty whose answer-by is about a day away), open it, **Remind me later** > **1 hour**: it comes back an hour later. Snooze again and then accept: it does not come back.
9. **Change reminders later.** On a published duty, **Change reminders** > none picked > **Save the reminders**: **Reminders saved**; nobody is asked to answer again (the position keeps its answer).
10. **No quiet hours.** Give a duty an answer-by time of `23:30`: the reminder arrives at 23:30 church time.
10a. **Answer-by edges.** Publish a duty for O starting in 24 hours 30 minutes with no answer-by time: it is **Short notice** (less than an hour to answer). Publish one with an answer-by time equal to its start: refused "Must be before the start". With a reporting time set, the reminder choices read "... before the reporting time"; a pre-service reminder while O has not answered reads **Duty answer needed**.
11. **Clean up** as in 4.1, step 9 (also `app.duties_contact_needs` and `app.notifications_schedules` of the synthetic members before the assignments).

Record the outcome of each step in `evidence-4.8/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Known limits (later entries)

- Leaders and deputies are chosen when an assignment is planned (or re-planned by `duties.set_reminders`): a leader granted later gets no alert for an earlier assignment until it is re-planned; one whose scope is revoked or who is held is not alerted (rechecked at delivery).
- Cell-owned occurrences get no reminders until entry 11 builds their member view (built in story 4.11, below: cell parts get the church default reminders).
- A very large publish (hundreds of slots) is planned in one transaction (about 4 s locally for 200 slots). On an almost empty database an autovacuum ANALYZE during it can make it much slower; publish a big rota in parts if a timeout is seen.
- Released and cancelled notices are listed until the old start and cannot be marked done yet. Contact attempts, leader confirmation and the coverage queue arrive with entry 9 (built in story 4.9, below).
- An operator re-plan after a policy change (`app.notifications_replan_all`) cannot call Duties: a leader alert it moves into the past is not re-sent until the assignment is next re-planned.
- Duties published before 4.8 keep their 4.1-4.5 jobs; there is no back-fill of reminders. **On staging**, duties published before this migration get the new reminders and leader alerts only after their next change (a reassignment, a material change, an answer or `duties.set_reminders`); test with duties published after the apply.

## Story 4.9: work the coverage queue with contact attempts and leader confirmation

Migration: `supabase/migrations/20261014212507_duties_coverage.sql`.
- Forward only: the 4.1-4.8 files and the Follow-ups files are not edited. The replaced function bodies are listed in its header; each is copied from its latest version and keeps every earlier review fix.
- No destructive statements, no row deletions and no `_rows` file.
- One new client grant: `api.duties_coverage(date, date, uuid, text)` and its `app` body (authenticated only). The three new commands go through `api.duties_command`.

Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-work-the-coverage-queue-with-contact-attempts-and-leader-con-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.9/`.

### Who sees what

| Reader | Departments | View |
|---|---|---|
| A department's leader or deputy | the departments they lead or deputise | **full**: positions, states, names, deadlines, counts, the labelled contact routes of members not yet confirmed, contact attempts with their notes, the Follow-ups task link, member notes and Confirmed by leader reasons |
| Admin (role alone) | every department | **operational**: positions, states, names, deadlines and counts; may reassign and cancel positions; never a contact route, note, reason or task link (also not the Confirmed by leader reason on the Duties board: review B1); cannot record contact attempts or confirmations (`forbidden`) |
| Pastor | every department (the church-wide gap view) | **operational**, read only |
| Anyone else, a member | none | `403 not_granted` |

A leader asking for another department (`department_id`) gets `403 not_granted`. Synthetic departments are hidden outside local and staging. With the Q4 gate closed the read answers `403 unavailable`.

### Contact routes (Identity, behind Q4)

`app.identity_scoped_contact_routes(viewer, scope_kind, scope_id, member_ids)` (owner Identity, not client-executable) returns the **labelled 2.5 contact routes** (`app.identity_contact_routes`: number, whose it is, holder label) of the given members to a viewer who holds that department scope now. Never a phone username, never a hold or deletion reason. It is behind `identity_applications_open()` (local, staging or Q4 approved); until `q4_personal_data` itself is approved only SYNTHETIC routes are returned. Members no longer approved or under deletion have none. The caller (the Duties read) passes only members of its own department positions. Clients open the phone's dialler or messages (`tel:` / `sms:`) through a launcher port; the app never calls or sends anything itself.

### The queue (`api.duties_coverage(from_date?, to_date?, department_id?, duty?)`)

- Window: church dates (Africa/Lusaka), default today and the next six days, at most 31 days; only duties that have not started (completion outcomes are entry 10). `duty` filters by name (case-insensitive). Errors: `400 validation_failed` (`window`, `duty`).
- Per position of a published duty (cancelled positions are left out): `status` = `unfilled` (no current assignment), `awaiting` (pending, before the answer-by time), `overdue` (pending, answer-by passed), `changed` (pending re-ask of the same member after a material change), `declined`, `confirmed` (accepted by the member, or Confirmed by leader); the 4.8 `needs_contact`; `overlaps`; the assignment (account `app_account` / `no_login`, `response_provenance` `member` / `leader`, `confirmation` `{by, at, channel, reason}`); the open coverage case `follow_up` (attempts, latest attempt, next follow-up, `overdue`, `task_id`).
- Per department: `counts` (`required`, `confirmed`, `unfilled`, `awaiting`, `overdue`, `declined` (declined or changed: a changed position counts here only, review N8), `needs_contact`, `conflicts`, `overdue_follow_ups`), `can_manage`, `can_contact`, the roster for reassignment (managers only) and `contact_routes`.
- At most 1000 positions are listed, soonest first (`truncated`); the counts always cover every position, and the JSON is built only for the listed ones (review N5).
- Cost: set-based; the overlap counts and the contact routes are computed once per read. `supabase/tests/duties_coverage_scale_test.sql` (under `statement_timeout = '8s'`): a leader's week of 250 positions about 0.2 s, Pastor's view of 40 departments (2,590 positions) about 0.7 s, an Admin's 31 days of a real month (4,930 positions) about 0.7 s (local).

### Commands (`api.duties_command`)

| Command | Who | `expected_revision` | Payload | Effect |
|---|---|---|---|---|
| `duties.record_contact_attempt` | the department's leader or deputy | assignment revision (unchanged by an attempt) | `{assignment_id, channel: phone\|message\|in_person\|other, outcome: no_answer\|left_message\|will_answer\|cannot_serve\|other, note?, next_follow_up_at}` | records the practical attempt (note 1-280, no pastoral or medical detail); the first attempt of an assignment opens a coverage case and its Follow-ups task (below); later ones set that task Waiting with the next follow-up as review date |
| `duties.confirm_by_leader` | the department's leader or deputy | assignment revision | `{assignment_id, channel, reason}` | a **pending** assignment becomes accepted with provenance `leader`, the leader as actor, the time, the channel and the reason (1-200); its answer reminders and leader alerts stop, the pre-service reminder is planned, the case and task close |
| `duties.cancel_position` | leader, deputy or Admin | occurrence revision | `{slot_id}` | cancels one position of a published duty (its assignee who was waiting or had accepted gets `duty_cancelled`; it no longer counts as required); the last remaining position cancels the whole date, one-off duties included |
| `duties.assign_slot` (4.3) | leader, deputy or Admin | occurrence revision | `{slot_id, member_id, override_reason?}` | reassignment: the old assignment is superseded (answer kept), its reminders and alerts end, `duty_released` goes to the old assignee, the new one gets a fresh plan |

Refusals:

| Case | Answer |
|---|---|
| Admin (role alone) recording contact or confirming | `forbidden` |
| Pastor, another department's leader, a member, an unknown or cell-owned assignment | `not_found` |
| An ended assignment | `conflict {"assignment_id": "superseded" \| "cancelled"}` |
| Stale revision | `conflict` with `current_revision` |
| The duty has started | `validation_failed {"assignment_id": "started"}` |
| An attempt on an accepted assignment | `validation_failed {"assignment_id": "confirmed"}` |
| The leader's own assignment (answer it in My duties; review S2) | `validation_failed {"assignment_id": "own"}` |
| An attempt on an erased or departed assignee (review N9) | `validation_failed {"member_id": "required_reassign"}` |
| Next follow-up in the past, at or after the (reporting) start, more than a year away | `{"next_follow_up_at": "past" \| "after_start" \| "out_of_range"}` |
| Bad channel or outcome | `{"channel" \| "outcome": "invalid" \| "required"}` |
| Confirmation without a reason; on an answered or declined assignment; of a member who can no longer serve | `{"reason": "required"}`; `conflict {"assignment_id": "responded" \| "declined"}`; `{"member_id": "required_reassign"}` |
| A cancelled position (given again, cancelled again); a draft date's position | `{"slot_id": "cancelled"}`; `{"slot_id": "draft"}` |
| Gate closed (production without Q4); untrusted session | `unavailable {"policy": "gate_closed"}`; `unauthenticated` |

Answers carry ids, revisions and codes only (never a note or reason). A replay rechecks that the actor still manages the occurrence's department.

### Coverage cases and the Follow-ups task

- `app.duties_coverage_cases`: one open case per assignment, opened by the first contact attempt; `app.duties_contact_attempts`: the attempts (immutable, except erasure). Both RLS on, no client privilege.
- The task: Follow-ups source `duties_coverage_case` (source id = the case id), purpose `coverage_follow_up` (label "Duty cover follow-up", scope kinds `department_leader`/`department_deputy`, outcomes = the attempt outcomes, `close` on resolved and cancelled, not hand-made). Owner: the recording leader or deputy. Supervisor (review S3): another current leader or deputy of the department whom the app can reach, a leader first; only when nobody else holds the scope the recorder supervises (the answer says `supervisor_fallback: true`). The task's scope is the supervisor's; next action generic; due at the next follow-up; context label "Duty cover: <duty> on <church date>". See `follow-ups.md`, story 4.9, for the new owner operation `app.followups_source_review`.
- Reminders (review N1): a source-specific schedule: the owner at the due or review time only (both always before the duty), no supervisor alert and no assignment notice, so nothing arrives after the service. A case whose duty has started closes (`started`, task `source_resolved`) at the next coverage command of a leader of that department (the lazy close).
- A new attempt on a case whose task was finished by hand, or whose task owner no longer holds the department scope, closes that case (`replaced`; its task, if still active, `source_resolved`) and opens a fresh case and task for the recorder (reviews N2, N3).
- The case closes, and its task with it, when the assignment is accepted by the member (`accepted`), confirmed by a leader (`confirmed`), superseded by a change or reassignment (`superseded`; task `source_resolved`) or cancelled (`cancelled`; task `source_cancelled`). A decline keeps it open (the position needs cover). A later need opens a fresh case and task (fresh keys).
- Lock order: grants -> receipt -> department -> series -> occurrence -> slots -> assignment -> coverage case -> Follow-ups (its task and its own reminders) -> Notifications.

### The leaders' decline alert

`duties_coverage` / `duty_declined`: **Duty declined** / "A member cannot make a duty in your department. Open Coverage to find cover." Link `/duties/coverage` (in `ClientPaths.deepLinkTargets`). Sent now to each current leader and deputy the app can reach (never the assignee; a held or in-review leader is skipped and refused at delivery) when a member declines or says they can't make it anymore; keyed by the assignment's declined revision, so every decline is a fresh key (A -> B -> A included). Delivered while the assignment is current, declined and not started; a reassignment or cancellation ends it, and a reminder re-plan never cancels it.

### Gates

- Every read and command needs the Q4 personal-data gate (production stays inert).
- With the Q2 policy closed or invalid a confirmation, an answer, a contact attempt and a cancellation are still recorded (as 4.8 decided for answers). Closing a case still closes its Follow-ups task and cancels the task's reminders (review S1: `app.followups_source_event` needs only the Q4 gate). Only work that schedules something is skipped and audited (`followup_skipped` for an attempt's new task, `reminders_skipped` for re-plans and alerts; code `policy_unavailable`); the change engine and the cancellations pass their actor, so every skip is audited.

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: the attempt notes about an erased assignee and the confirmation reason are cleared; the recorders of attempts, cases and cancelled positions are anonymised with the nil UUID. No new rows are deleted.

### Clients

- **Staff web, Coverage** (`/duties/coverage`, sidebar **Coverage** with **Duties** and **Rota**): the window (**From**, 7/14/31 days; a malformed date shows "Use YYYY-MM-DD"), **Duty name contains**, a department choice and **Show**; filter chips **All**, **Unfilled**, **Overdue**, **Declined**, **Awaiting**, **Needs contact**, **Confirmed** with counts; per department "N of M confirmed, ... unfilled, ... overdue, ... declined or changed, ... need contact" and an issue card per position: duty, position, church time, place, the state, Short notice, Needs contact, overlaps, the assignee ("no login: contact them directly"), the answer-by time, **Confirmed by leader** (by, when, how, reason), the latest attempt and next follow-up with **Open the follow-up task**, the labelled contact routes with **Call** and **Message**, and the actions **Record contact attempt**, **Confirmed by leader**, **Assign**/**Reassign** (the 4.4 picker with load and overlaps) and **Cancel position**. Pastor and Admin read **Gaps across the church** with the per-department totals; Pastor read only, Admin with Reassign and Cancel position only.
- **Mobile**: the same screen at `/duties/coverage` (the leader's essential actions on the phone; Call and Message open the dialler and messages), and the leader's **Needs attention** card first on **Home** (only for leaders and deputies): Unfilled, Overdue, Declined or changed, Needs contact, "This week: N of M positions confirmed", overlapping duties and overdue follow-ups, **Open coverage**. A member reads **Confirmed by your leader** on a duty a leader confirmed (never the reason).
- The Duties board shows **Confirmed by leader** with the recorder, time, channel and (managers) reason, and cancelled positions as **Cancelled** ("N of M confirmed" counts required positions only); the rota grid reads "Confirmed by leader" and "Cancelled".
- Every action shows **Sending…**, and **Not sent yet** with **Check again** (same request id) when the outcome is unknown; nothing is shown as done until the server answers.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_coverage_test.sql, duties_coverage_scale_test.sql (+ 4.1-4.8)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-coverage.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-coverage.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900780-900789`, E2E `900790-900799` (including the accountless member's household number). The 4.8 E2E `D31` and pgTAP decline checks now expect the leaders' decline alert.

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261014212507_duties_coverage.sql` to staging (`tmurpotfluignacfueki`) after `20261014171038` (rename the local file to the recorded hosted version if the apply records another one, as for 4.8).
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*`, `app.followups_source_review` and `app.identity_scoped_contact_routes` function with the local one (the migration has no backslashes).
   - Grants: among the new functions `authenticated` executes only `api.duties_coverage` and `app.duties_coverage`; `anon` none.
   - Right after the apply: `select count(*) from app.duties_coverage_cases;` is 0; `select count(*) from app.contract_reminder_contracts where reminder_kind = 'duty_declined';` is 1; `select count(*) from app.followups_purposes where source_type = 'duties_coverage_case';` is 1.
   - No Edge Function change (the worker is generic), no rows file, no owner SQL paste.
2. **Staging clients:** rebuild the staff web and the staging APK (new screens; both apps add `url_launcher` 6.3.3, already a transitive dependency, so `flutter pub get` and a full build are needed; Android declares the `tel:`/`sms:` queries).
3. **Production:** nothing in this story (Q2 and Q4 stay closed; every Duties command and read needs Q4).

### Owner manual checks (staging, phone and web, story 4.9)

Use synthetic members only. You need the 4.1 setup: Admin A, leader L of `SYNTHETIC Preaching Rota` with the staging APK on an Android phone (and staff web), member M with the app, member O with the app, member R, and an accountless member X with a SYNTHETIC labelled contact number (staff web **Members & applications** > **Add member record (no login)** with a fictional contact number and "whose it is" = household with a SYNTHETIC label); a second department `SYNTHETIC 4.9 Ushers` with leader K; a member P with the Pastor role. Add M, O, R and X to the Preaching Rota.

1. **A synthetic rota.** As L, **Rota** > **New rota**: one Sunday at least four days away, `10:00`, positions `Preacher, Reader, Usher, Steward`; plan M (Preacher), X (Reader) and O (Usher), leave Steward unplanned; **Publish 4 draft slots** (church default answer-by).
2. **The decline alert.** As O on a phone, decline the Usher duty. Within about a minute L's **Inbox** shows **Duty declined**; **Open** opens **Coverage**.
3. **The queue.** Staff web as L: **Coverage**: "0 of 4 confirmed, 1 unfilled, ... 1 declined or changed, 1 need contact". M is **Awaiting response** with the answer-by time; X shows "(no login: contact them directly)", **Needs contact** and the household number with its label, **Call** and **Message**; O is **Declined**; Steward is **Unfilled**. The **Declined** chip shows only O.
4. **Contact attempt.** On M's card: **Record contact attempt**: Phone call, No answer, note `SYNTHETIC: rang twice`, next follow-up tomorrow `18:00`, **Save contact attempt**: **Contact attempt recorded**; the card shows "1 contact attempt ... Next follow-up ..." and **Open the follow-up task**, which opens the task ("Duty cover: Sunday service on <date>", due tomorrow 18:00; also in **My follow-ups**). Record a second attempt (Left a message, the day after): the task is **Waiting** with that review date.
5. **Confirm by phone (mobile).** On L's phone: **Home** shows **Needs attention** first (Unfilled 1, Declined 1, Needs contact 1); **Open coverage**; on X's card **Call** opens the dialler with the number (do not call; go back). **Confirmed by leader**: Phone call, reason `SYNTHETIC: confirmed by phone with the household`, **Record Confirmed by leader**: **Confirmed by leader**; the card reads **Confirmed by leader** with L, the time and the reason. Staff web **Duties** shows **Confirmed by leader** too.
6. **Reassign the decline.** On O's card: **Record contact attempt** (Cannot serve), then **Reassign** > R > **Give this position**. O's card leaves; O gets **Duty changed** ("no longer assigned to you") and no further reminder; O's follow-up task is **Closed** (source resolved); R gets **New duty assigned**.
7. **The member's own answer.** As M, accept on the phone: M's follow-up task closes; M's duty reads **Accepted**. As L, confirm another of R's pending duties as **Confirmed by leader**: on R's phone that duty reads **Confirmed by your leader** (never the reason), and **Can't make it anymore** is not offered for it.
8. **Nothing private.** As K (Ushers leader): **Coverage** lists only the Ushers department; nothing of the Preaching Rota. As A (Admin, no department scope): **Coverage** shows **Gaps across the church** and the Preaching Rota with states and names but no number, no **Call**, no attempt note, no reason and no **Record contact attempt** or **Confirmed by leader**; A may **Reassign** and **Cancel position**. As P (Pastor): the same operational view, read only. (API, optional: `duties.record_contact_attempt` as A answers `forbidden`, as K `not_found`.)
9. **Cancel a position.** As L, **Cancel position** on the Steward: it leaves the queue and "N of 3" is shown. Cancel the remaining positions: the last one cancels the date and the assignees get **Duty cancelled**.
10. **Clean up** as in 4.8, step 11, plus (SQL editor) the `app.duties_contact_attempts` and `app.duties_coverage_cases` rows of the synthetic assignments and the `app.followups_*` rows of their tasks (`source_type = 'duties_coverage_case'`), before the assignments.

Record the outcome of each step in `evidence-4.9/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Owner questions

- **Q4 (open, fail-closed default):** which member contact fields a leader may see in production. Staging shows only the labelled 2.5 contact routes through the scoped Identity read; production shows nothing until `q4_personal_data` is approved, and even then only labelled routes (never phone usernames).

### Known limits (later entries)

- The queue lists duties that have not started; completion outcomes (Completed, Excused, No-show) are entry 10 (built in story 4.10, below); cell-owned positions are entry 11 (story 4.11 keeps them out of the queue: epic 5, see its known limits); lifecycle and handover hooks are entry 12 (built in story 4.12, below).
- Confirmed by leader is for a member who has not answered: a decline is reassigned, not overwritten, and the same member cannot be given the position back without first giving it to someone else (the 4.3 command refuses an unchanged assignee).
- Contact details are the labelled 2.5 routes only (no phone usernames); members with an app account usually have none, so the leader contacts them through other agreed means.
- "Needs contact" does not yet include "no active push device" (the 3.6 device state is not disclosed to leaders).
- A case of a started duty closes lazily (at the next coverage command of the department's leaders), not at the start itself; its task sends nothing after the duty. A reminder the owner snoozes past the duty can still arrive once.
- A leader's own duty is answered in My duties; the queue shows no contact actions on it.
- The board's history list shows ended assignments with their provenance; a cancelled position's earlier assignment is in its history.

## Story 4.10: record duty completion outcomes and keep assignment history

Migration: `supabase/migrations/20261015002121_duties_outcomes.sql`.
- Forward only: the 4.1-4.9 files are not edited. The replaced function bodies are listed in its header (`duties_state_ok`, `duties_authorize_command`, `duties_command`, `duties_my_assignment_json`, `duties_deletion_remaining`, `duties_erase_member`, all copied from `20261014212507`, 4.9, with every earlier review fix kept).
- No destructive statements, no row deletions and no `_rows` file.
- New client grants: `api.duties_outcomes(date, date, uuid, text)` and `api.duties_member_history(uuid, timestamptz, uuid)` with their `app` bodies (authenticated only). The two new commands go through `api.duties_command`.

Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-record-duty-completion-outcomes-and-keep-assignment-history-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.10/`.

### Response, coverage and completion stay separate

- An outcome is only what a leader records after the duty: **Completed**, **Excused** or **No-show**, with an optional short note. Nothing records an outcome when time passes: every read says `unrecorded` ("Not recorded") until someone records it.
- Recording or correcting an outcome never changes the assignment row, its response or its revision.
- Only the **current** assignment of a **published** duty whose reporting (or start) time has passed may have an outcome. A superseded assignment (reassigned or changed) and a cancelled position, assignment or duty have none: a cancelled accepted duty has no outcome.
- **No-show** only for an accepted assignment (the member's acceptance or Confirmed by leader). A declined or never-answered assignment may be Completed or Excused, never No-show.
- A leader never records or corrects the outcome of their own duty: another leader or deputy of the department does.

### Who sees what

| Reader | Outcomes (`api.duties_outcomes`) | A member's history (`api.duties_member_history`) |
|---|---|---|
| The member | none (unless they lead a department) | their own, every department, with notes, corrections and reasons; My duties shows their own outcome |
| A department's leader or deputy | that department's started duties with outcomes, notes, trail and reasons | a member who is or was in that department: that department's assignments only |
| Admin (role alone), Pastor | `403 not_granted` | `403 not_granted` |
| Another department's leader, another member | only their own departments; `403 not_granted` for a department filter they do not lead | `403 not_granted` (also for an unknown member: nothing is disclosed) |

No read returns figures about more than one member: department counts are totals only, and a history summary is one member's own figures. There is no ranking or league table. The board, rota, coverage queue and Admin overview carry no outcome. The audit holds codes only (`outcome_recorded`, `outcome_corrected`, the outcome value); receipts hold ids, codes and revisions; no notification is sent.

### Commands (`api.duties_command`)

| Command | `expected_revision` | Payload | Effect |
|---|---|---|---|
| `duties.record_outcome` | the assignment revision (the answer the leader saw) | `{assignment_id, outcome: completed\|excused\|no_show, note?}` | the first outcome (revision 1), with the leader and the time |
| `duties.correct_outcome` | the current outcome revision | `{assignment_id, outcome, note?, reason}` | a new revision that names the one it replaces, with the leader, the time and the reason (1-200); every earlier value, note, actor and time stay |

Notes are short (1-200, single line, practical). There is no time limit on corrections (the spec sets none) and no way back to Unrecorded.

Refusals:

| Case | Answer |
|---|---|
| Admin (role alone) | `forbidden` |
| Pastor, a member, a leader whose scope was revoked, another department's leader, an unknown, draft or cell-owned assignment | `not_found` (nothing is disclosed) |
| A leader or deputy on hold | `forbidden` |
| The leader's own duty | `validation_failed {"assignment_id": "own"}` |
| A superseded assignment; a cancelled position, assignment or duty | `conflict {"assignment_id": "superseded" \| "cancelled"}` |
| The duty has not started | `validation_failed {"assignment_id": "not_started"}` |
| An erased assignee; one who left the church or is under deletion (review S1) | `validation_failed {"member_id": "erased" \| "inactive"}` |
| Record when one exists | `conflict {"assignment_id": "recorded"}` |
| Correct when none exists | `validation_failed {"assignment_id": "unrecorded"}` |
| Stale revision | `conflict` with `current_revision` |
| No-show without an acceptance | `validation_failed {"outcome": "not_accepted"}` |
| A correction that changes nothing; without a reason | `{"outcome": "unchanged"}`; `{"reason": "required"}` |
| Gate closed (production without Q4); untrusted session | `unavailable {"policy": "gate_closed"}`; `unauthenticated` |

A replay rechecks that the actor still manages the occurrence's department.

### The reads

- `api.duties_outcomes(from_date?, to_date?, department_id?, duty?)`: church dates (Africa/Lusaka), default the last 14 days up to today, at most 31 days, never after today (any past window: no time limit). The clients always send both dates: without a From date the window ends today and reaches back the chosen number of days; with one it ends that many days later or today, whichever is sooner (review S2). Both reads check the Q4 gate before the caller's grants (review N5). Per position of a started published duty: the assignment (name, `own`, response and provenance), `outcome_state` (`unrecorded` or the value), `outcome` `{outcome, revision, note, recorded_at, recorded_by, corrected, trail}` (trail newest first, at most 20) and `allowed`. Per department: `counts` `{positions, unfilled, unrecorded, completed, excused, no_show}`. At most 1000 positions (latest first, `truncated`). Errors: `400 validation_failed` (`window`, `duty`), `403 not_granted`, `403 unavailable`.
- `api.duties_member_history(member_id?, before_at?, before_id?)`: one row per position held (a material change that re-asks the same person is one row: the latest revision), newest first, 100 per page (`has_more`; the next page passes the last row's `starts_at` and `assignment_id`; a half cursor is `400 validation_failed cursor`). Each row: department, duty, position, times, `state` (`current`, `reassigned`, `cancelled`), response and provenance, `outcome_state` (`upcoming`, `unrecorded`, a value, or `none` for an ended row) and `outcome`. `summary` (the last 365 days, past duties): `held`, `accepted`, `confirmed_by_leader`, `declined`, `unanswered`, `completed`, `excused`, `no_show`, `unrecorded`, `ended`; and `upcoming`.
- Cost: set-based, the current outcome by index. `supabase/tests/duties_outcomes_scale_test.sql` (under `statement_timeout = '8s'`): a member with fifteen years of weekly duties (780 positions, corrections and same-person revisions) read by the member, by their leader and at a late page about 0.05-0.1 s each; a department of 300 members with 80 positions a day: the leader's fortnight (over 1000 positions) and the 31-day window about 0.4-0.5 s each (local).

### Gates and locks

- Every read and command needs the Q4 personal-data gate (production stays inert). Nothing is scheduled, so the Q2 policy is not needed.
- Lock order: grants -> receipt -> department -> series -> occurrence (FOR SHARE) -> assignment (FOR UPDATE, which also serialises the outcome log of that assignment) -> outcome log. No Follow-ups, no Notifications.

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: the outcome notes and correction reasons about an erased assignee are cleared (the values stay on the anonymised assignment); the recorder of an outcome is anonymised with the nil UUID. `_remaining` counts both. No rows are deleted.

- Review S1: the erase phase first locks, in the commands' order, the departments and series the member created, the occurrences they created or hold a position in, and their assignments (all FOR UPDATE), then clears the outcome and contact-attempt text by those assignment ids. An outcome or attempt in flight either commits before the clear or waits and then finds the member erased. The commands also refuse an assignee who left the church or is under deletion (`inactive`). Probe: `evidence-4.10/erase-race-probe.txt`.
- `app.duties_outcomes` is append-only: a trigger refuses every update except erasure, an insert whose `supersedes_outcome_id` is not the same assignment's previous revision, and a direct DELETE (rows go only with their assignment, by cascade, as the local test clean-ups do; review N3).

### Clients

- **Staff web, Outcomes** (`/duties/outcomes`, sidebar **Outcomes** for department leaders and deputies): **From** (empty: the window ends today; a date after today shows "Must not be after today"), 7/14/31 days, **Duty name contains**, a department choice, **Show**, and **Not recorded only**. Per department "N positions: ... completed, ... excused, ... no-show, ... not recorded". A card per position: duty, time, place, the member, **Answer: Accepted / Declined / Never answered / Confirmed by leader** (apart from the outcome), **Not recorded** or **Outcome: ...** with who recorded it, when, the note, **Corrected** and every earlier value with its recorder, time and reason. Actions **Record outcome** (chips for the allowed values: No-show only after an acceptance, a short note) or **Correct outcome** (a required reason), and **History of <member>**. On the leader's own duty: "another leader or deputy of the department records its outcome", no action. An erased member's position shows "This member's record was removed" with no action; a member who left meanwhile is explained (**No longer a member**).
- **Staff web, My duty history** (`/duties/history`, every member) and a member's history (`/duties/history?member=<id>`, opened from Outcomes): the summary for the last 12 months, the upcoming count, each duty with its answer and outcome, **Older** / **Newer**, and "Seen only by the member and their department's leaders and deputies, for fair workload conversations. It is not a ranking."
- **Mobile**: the same screens. The leader's **Needs attention** card on **Home** has **Record outcomes of past duties**; **My duties** has **My duty history**, and a past duty shows **Outcome: ...** (with the note and corrections) or "Outcome: not recorded yet."
- Every action shows **Sending…**, and **Not sent yet** with **Check again** when the outcome is unknown; nothing is shown as recorded until the server answers. Refusals are explained (already recorded, not a No-show, not started, your own duty, changed elsewhere).

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # supabase/tests/duties_outcomes_test.sql, duties_outcomes_scale_test.sql (+ 4.1-4.9)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-outcomes.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-outcomes.test.mjs
(cd packages/client_core && flutter test test/duties/duties_outcomes_test.dart)
```

Fictional numbers: pgTAP `+44 7700 900130-900139` and `900151-900153`, E2E `900140-900149`. Past duties are made by publishing them ahead and moving their start into the past with SQL (test-only time shift).

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261015002121_duties_outcomes.sql` to staging (`tmurpotfluignacfueki`) after `20261014212507` (rename the local file to the recorded hosted version if the apply records another one).
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*` and `api.duties_outcomes` / `api.duties_member_history` function with the local one (the migration has no backslashes).
   - Grants: among the new functions `authenticated` executes only `api.duties_outcomes`, `app.duties_outcomes`, `api.duties_member_history` and `app.duties_member_history`; `anon` none.
   - Right after the apply: `select count(*) from app.duties_outcomes;` is 0.
   - No Edge Function change, no rows file, no owner SQL paste.
2. **Staging clients:** rebuild the staff web and the staging APK (new screens; no new dependency).
3. **Production:** nothing in this story (Q4 stays closed; every Duties command and read needs Q4).

### Owner manual checks (staging, phone and web, story 4.10)

Use synthetic members only. You need the 4.9 setup: Admin A, leader L and a deputy D of `SYNTHETIC Preaching Rota` (L with the staging APK on an Android phone, and staff web), members M, O and R with the app, the second department `SYNTHETIC 4.9 Ushers` with leader K, and a member P with the Pastor role.

1. **Past synthetic duties.** As L publish three one-off duties a day or two ahead: M (M accepts on the phone), O (O declines), R (R does not answer), and a fourth for M that M accepts and that L then cancels (**Coverage** > **Cancel position**). Wait until they have started (or ask the parent session to move their start into the past with SQL on staging; test-only).
2. **Unrecorded stays unrecorded.** Staff web as L, **Outcomes**: the three duties show **Not recorded**; nothing changes after waiting (passing time never records an outcome). The cancelled duty is not listed.
3. **Record.** On M's card **Record outcome** > **Completed**, note `SYNTHETIC: on time`, **Save outcome**: **Outcome recorded**; the card reads **Outcome: Completed** with L and the time. M's card still reads **Answer: Accepted**.
4. **Declined is never a No-show.** On O's card **Record outcome**: no **No-show** chip; choose **Excused**, save.
5. **Correct (mobile).** On D's phone (or L's): **Home** > **Record outcomes of past duties** > M's card > **Correct outcome** > **No-show**, reason `SYNTHETIC: checked the sign-in sheet`, **Save correction**: **Outcome corrected**; the card shows **Corrected** and "Earlier: Completed ... recorded by L ...".
6. **Own duty.** If L has a past duty of their own, its card says another leader or deputy records it and offers no action.
7. **The member's history.** On M's phone: **My duties** > **Past**: the duty reads **Outcome: No-show** with the note and the earlier value; **My duty history** shows the summary and "It is not a ranking". On staff web as L, **History of M** shows the same for this department only.
8. **Nothing for others.** As R: **My duty history** shows only R's own duties; R cannot open M's history (a refusal, nothing shown). As K: **Outcomes** lists only the Ushers; M's history is refused. As A (Admin, no scope) and as P (Pastor): **Outcomes** and M's history are refused; **Duties**, **Rota** and **Coverage** show no outcome or note.
9. **Clean up** as in 4.9, step 10. The `app.duties_outcomes` rows of the synthetic assignments go with the assignments (cascade); a direct delete of an outcome is refused.

Record the outcome of each step in `evidence-4.10/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Owner questions

- **Q4 (open, fail-closed default; unchanged from 4.9):** personal data in production. Outcomes and history are behind the Q4 gate, so production shows nothing until it is approved.
- None new: the ticket's unknown (no time limit on corrections) is built as stated: every correction is recorded, none is limited.

### Known limits (later entries)

- Outcomes are for department-owned duties; cell-owned programme parts are entry 11 (story 4.11 leaves cell-part outcomes to epic 5, see its known limits). Leaving a department or the church (entry 12, built in story 4.12, below) does not remove outcomes; erasure clears their text.
- An outcome cannot be cleared back to Unrecorded; a mistaken record is corrected to the right value with a reason.
- The history counts one row per position held; the 12-month summary covers past duties only (upcoming duties are counted apart).

## Story 4.11: expose Duties owner operations for programmes and later owners

Migration: `supabase/migrations/20261015035112_duties_owner_operations.sql` (forward only; no destructive statements, no row deletions, no `_rows` file, so **no owner SQL paste**). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-expose-duties-and-follow-ups-owner-operations-for-programmes-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.11/`. The consumer guide for owners (Cells, Content and later) is in [contracts-and-owner-seams.md](contracts-and-owner-seams.md#duties-owner-operations-consumer-guide-story-411).

### What changed for Duties

- **Cell-owned parts.** A registered `cell_part` source (Cells; the SYNTHETIC `fixture_programme_part` in tests) creates, revises and cancels a published cell-owned occurrence through `app.duties_owner_put_part` / `app.duties_owner_cancel_part`, inside its own command. Each part position has a stable key and one permanent owned link to its slot (`app.duties_part_links`). The 4.2 engine revises it (material changes ask again, notes-only changes keep the answer); a removed position is cancelled (4.9 rules); a renamed position or a cancelled key is refused; an identical put changes nothing.
- **Members answer cell parts.** My duties lists them (owner **Cell programme**, the cell's leader and assistant by name); `duties.respond`, `duties.withdraw_acceptance` and `duties.accept_many` answer them (the 4.5 refusal ends); notices and member reminders (4.8) are sent and checked as for department duties (eligibility: the assignee, still an active member).
- **Department-only (fail closed, the first contract change Cells needs):** leader alerts (overdue, short notice, declined), the coverage queue, Confirmed by leader, contact attempts, Needs contact list and outcomes stay department-only. The cell's owner read (`app.duties_owner_part`) shows each position's answer, Short notice and needs-contact flag meanwhile.
- **Display links.** `app.duties_owner_link_duty` links a part position to a published, not started department position. Nothing of the duty changes (no revision, answer, reminder or notice); only its department manages it. The board and the rota say "Shown on N cell programme part(s)".
- **Owner-review mismatches.** `app.duties_owner_flag_review` flags the department duties a changed meeting (display links) or event (`event_ref`) is linked to, with codes `time`, `place`, `label`, `assignee`, `cancelled`. The duty is never rescheduled or republished and no answer is reset. The board and the rota show **Needs review** with the change; the department's leader, deputy or Admin marks it reviewed (`duties.clear_review {flag_id}`, expected = the review revision; Pastor and everyone else `forbidden`; a second clear `conflict {"flag_id": "cleared"}`).
- **Who may.** Owner operations are never client-executable; the actor is the live session; only the cell's leader or assistant acts for a cell (the Admin role alone, Pastor, department scopes and other cells' leaders are `forbidden`). A cell leader's department commands stay `forbidden`.
- **Privacy.** No response note, override or confirmation reason, contact data, or person of the department crosses to the cell (display links show `filled` only). Audit rows hold codes; answers hold ids, revisions, states and counts.
- **Deletion.** The hook anonymises who linked, unlinked, flagged or cleared; `_remaining` counts them.
- **Review fixes (2026-10-15).** A part is bound to the cell its first link named (another cell answers `not_found`); a create that asks nobody refuses an answer-by; an identical put still records the caller's part revision; the conflicts read covers at most 120 days; a review of a duty that started or was cancelled no longer shows as open; only the foreign-key cascade removes a link; My duties skips (and logs) a row the client cannot read; the member's notice for a cell part says the cell leader sees it in the programme.
- **Release gate.** No `cell_part` registration in a migration and no cell-part data on staging until every client runs the 4.11 build or later (older builds cannot show My duties once a cell part exists). See [contracts-and-owner-seams.md](contracts-and-owner-seams.md#duties-owner-operations-consumer-guide-story-411), step 7.

### Gates and locks

Q4 on every operation, read and on `duties.clear_review`; Q2 through the notification calls (production inert). Lock order: the caller's Identity grant rows and its own source row, then Duties (department, series, occurrence, slots, member locks, assignments, links or flags), then Follow-ups, Notifications last.

### Clients

Staff web and mobile (shared screens): My duties shows a cell part with **Cell programme** and its leaders; the leader board and the rota date panel show **Needs review** with **Mark reviewed** (managers only) and the linked-parts line. Notices: **Marked reviewed**, **Already reviewed**.

### Local runs

```bash
npx supabase db reset && npm run -s db:test   # duties_owner_operations_test.sql, duties_owner_operations_scale_test.sql
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-owner-ops.mjs --evidence /tmp/duties-owner-ops.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261015035112_duties_owner_operations.sql` to staging (`tmurpotfluignacfueki`) after `20261015002121` (rename the local file to the recorded hosted version if the apply records another one).
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*` and `app.fixture_*` function with the local one (the migration has no backslashes).
   - Grants: no new function is executable by `anon`, `authenticated` or `service_role`.
   - Right after the apply: `select count(*) from app.duties_part_links;` and `select count(*) from app.duties_review_flags;` are 0, and `app.duties_link_sources` is empty (nothing is registered until Cells, or a test).
   - No Edge Function change, no rows file, no owner SQL paste.
2. **Staging clients (review N8, deploy order):** apply the migration first, then publish the staff web and the staging APK **in the same rollout** (no new dependency). Older clients keep working against the new database (new fields and notice kinds are ignored or shown generically), but only the new ones show the vacancy flag, the removal and handover actions and the honest notices.
3. **Production:** nothing in this story.

### Owner manual checks (staging, phone and web, story 4.11)

Cells' screens do not exist yet (epic 5), so the cell side is driven by the parent session in the SQL editor with the SYNTHETIC caller, inside a signed-in cell leader's session (the E2E's `ownerCallSql`). Use synthetic members only.

1. **Parent session setup:** register the SYNTHETIC sources as in the E2E (`contract_register_source_type` and `duties_register_link_source` for `fixture_programme_part` and `fixture_event`), give a synthetic member C the `cell_leader` scope of a SYNTHETIC cell, and create a part for member M (with the app) with `app.fixture_programme_publish`.
2. **M's phone:** **My duties** shows the part with **Cell programme** and C as leader; **Accept** works.
3. **Revise:** the parent session moves the part 30 minutes later; M sees **Changed** and is asked again; the earlier acceptance is in the history.
4. **Link and review:** L publishes a department duty on staff web; the parent session links a part position to it and flags `time`. On staff web as L the duty reads **Shown on 1 cell programme part** and **Needs review: A linked cell meeting changed (time)**; the duty's time and answer are unchanged. **Mark reviewed**: **Marked reviewed**; the review is gone. As P (Pastor) the review shows without **Mark reviewed**.
5. **Cancel:** the parent session cancels the part; M gets **Duty cancelled**; the department duty is unchanged.
6. **Clean up** as in 4.10, step 9, plus the `app.fixture_programme_parts` rows; links and flags go with their slots and occurrences.

Record the outcome of each step in `evidence-4.11/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Owner questions

- **Q4 (open, fail-closed default; unchanged):** personal data in production. Every operation and read is behind the Q4 gate.
- **New (fail-closed default chosen):** may a cell programme name the person a linked department duty is assigned to? Built: no (the cell sees the duty, its times and whether it is filled, never who). Changing it is a contract change.
- **New (default built: board only):** should the department's leader be notified when a linked meeting or event changes (a mismatch flag)? Built: no notification; the board and rota show it until reviewed.
- **Pending owner acknowledgement:** `duties.clear_review` answers `forbidden` (not `not_found` as planned) to anyone who does not manage the department, like every other department command.

### Known limits (later entries)

- Cell-scope leader alerts, coverage queue, Confirmed by leader, contact attempts and outcomes for cell parts: the first contract change epic 5 needs (entries 5.5, 5.6).
- No discovery read of linkable department duties for cells (epic 5 asks for one if needed; a contract change).
- The creator's reminder choice for a part (`reminders`) is not taken; cell parts use the church defaults.
- A system-principal caller (no live session) is not supported; owner operations need the acting member's session.
- A part holds at most 50 positions over its life (cancelled ones count); beyond that a programme starts a new part.
- Lifecycle effects on cell parts (transfer, removal) are Cells' calls to these operations (epic 5.9) and entry 12 (built in story 4.12, below: a deactivated member's cell parts end).

## Story 4.12: apply membership lifecycle and handover to duties and follow-ups

Migration: `supabase/migrations/20261015110202_duties_lifecycle.sql` (forward only; the 4.1-4.11 files are not edited; no destructive statements, no row deletions, no `_rows` file, so **no owner SQL paste**; no new client grant: both new commands go through `api.duties_command`). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-apply-membership-lifecycle-and-handover-to-duties-and-follow-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.12/`. The Follow-ups side is in [follow-ups.md](follow-ups.md) (story 4.12); the Identity seams in [identity-access.md](identity-access.md) (stories 2.10, 2.11 and the 4.12 note there).

### What each lifecycle change does to Duties (inside Identity's transaction, AD-14)

| Identity change | Duties effect |
|---|---|
| **Church deactivation** (`membership_deactivated`), and a **deletion** request (`deletion_requested`, also for a member deactivated earlier) | Every current assignment of the member on a published duty that has not started ends: department duties and cell parts, pending, accepted or declined. The assignment becomes `superseded` with end reason `vacated`, the position is left **unfilled** (a `vacated` slot revision), the member's reminders and notices for it and the leaders' alerts about it are cancelled, its coverage case closes (`superseded`, its follow-up task resolved). The member's planned draft positions are cleared. The member gets no notice (no access). Past and started duties, answers, outcomes and history are kept. Department membership rows are kept: a **restoration** brings back no assignment (give the duties again; a returning member gets new assignments and fresh notices). |
| **Removal from a department** (`duties.remove_member`, below) | The same for that department's future duties only, and the member is told each duty is no longer theirs (`duty_released`; a member the app cannot reach is listed under **Needs contact** "Tell X: ... is no longer theirs"). The membership row ends (who and when). |
| **Login hold** (or any hold, `access_hold_applied`) | Duties are **kept**. Each current, not declined duty that has not started goes on the leaders' **Needs contact** list at once ("Reminders cannot reach them in the app"), shown while the member still cannot be reached in the app (a released hold clears it). No leader alert: a hold is never disclosed. |
| **Scope removed** (`scope_revoked`: a leader or deputy loses the department scope, also when they are deactivated) | Their authority already ended: every command, replay and read checks the current grants (coverage, contact attempts, Confirmed by leader, cancellations, outcomes, reviews). The hook also cancels their pending leader alerts of the departments they no longer lead or deputise (`not_recipient`), and Follow-ups moves their supervision (follow-ups.md). |

**Vacancy flag and the leaders' notice.** A position whose person can no longer serve shows **Needs a new person** on the board and in **Coverage** (`vacated: {since}` per position and a `vacated` count per department in `api.duties_coverage`; on the board the newest history entry has end reason `vacated`). The department's reachable leaders and deputies (never the member; a held or in-review leader is skipped and refused at delivery) get **one** notice per department and change, `duties_coverage` / `duty_vacated`: **Positions need cover** / "One or more positions in your department no longer have anyone assigned. Open Coverage to find cover." (link `/duties/coverage`). It is keyed by the soonest position the change ended (a fresh key every time) and is delivered while any position that change ended in the department is still unfilled, not cancelled and not started (review N1: the source check's `current` only asks whether that assignment still ended `vacated` at that revision; whether anything still needs cover is `actionable`'s answer). No notice when the member had declined every ended position (the leaders already know). **One notice per department and change** (instead of one per position) is a deviation from the plan's frozen text, made for leaders' inboxes and the scale budget; it is **pending owner acknowledgement**. Cell parts get no leader alert (4.11: cell-scope alerts are a later contract change); the cell's owner read shows the gap.

**Never a reason.** Leaders see one generic end reason (`vacated`) and **Needs a new person**: never whether the member was held, deactivated, deleted or removed, and never a reason code. The audit keeps codes only (`assignment_vacated` with `member_left` or `removed`, `draft_cleared`, `member_removed`, `handover_resolved`), attributed to the Admin (or the deleting member) with capacity `lifecycle` for a lifecycle change.

### Commands (`api.duties_command`, Admin only)

| Command | `expected_revision` | Payload | Effect / refusals |
|---|---|---|---|
| `duties.remove_member` | department revision | `{department_id, member_id}` | as above; answer `{department_id, revision, vacated, drafts_cleared, notices_skipped}`. `forbidden` (not Admin), `validation_failed {"member_id": "not_in_department"}`, `conflict` (stale revision) |
| `duties.resolve_handover` | department revision | `{department_id}` | marks the department's pending `department_leader` handovers done once it has an approved leader or deputy the app can reach; `conflict {"department_id": "leader_required"}` otherwise, `validation_failed {"department_id": "no_handover"}` when nothing is pending |

A replay rechecks that the actor is still an Admin. With the Q2 policy unavailable a removal (and a lifecycle change) is still recorded: the notices are skipped and audited `reminders_skipped` (`policy_unavailable`), the answer says `notices_skipped: true` and the staff web says **Removed, but nobody was told** (review N4). A removed member the app cannot reach (held, in review, no account) gets their `duty_released` need listed for the leaders under **Contact notices** on the board ("Tell X: ... is no longer theirs") once the worker runs.

### Handover (the last leader of an active department)

Duties' handover hook reports `department_leader` (subject = the department, last responsible) when the member leads or deputises an active department and nobody else approved and reachable in the app holds its leader or deputy scope. A **deactivation** is then refused `conflict {"member_id": "handover_required"}` and nothing changes: give the department another leader or deputy who uses the app (a held one does not count), then deactivate. A **deletion** is never refused: the obligation is recorded pending and the erase steps wait (`handover_pending`) until an Admin gives the department a leader and presses **Mark handover done** (`duties.resolve_handover`) on **Departments**. `api.duties_admin_overview` adds per department `handovers` (ids and times) and `needs_leader`.

### Gates and locks

Ending work needs neither Q2 nor Q4 (the hooks only reduce processing; production holds no duties while Q4 is closed). The commands need Q4 like every Duties command. Lock order: Identity rows (the lifecycle command's member row `FOR UPDATE` and grants; a command's people `FOR KEY SHARE`, below) -> departments -> series -> occurrences -> slots -> the member's advisory lock -> the membership row -> assignments -> coverage cases -> Follow-ups -> Notifications last.

**People first (review S2).** A notice queued to a member takes a key-share lock on that member's `identity_members` row (the foreign key of `notifications_jobs`), which a lifecycle change holds `FOR UPDATE` while it ends that member's duties. So every Duties command that may queue a notice to a member takes `FOR KEY SHARE` on those members' rows, in member-id order and through one helper (`app.duties_lock_people`), **before any Duties row**:
- the dispatcher (`app.duties_command`) hands the payload to the authorizer in a transaction-local setting (`duties.command_payload`, cleared after; it only decides what is locked, never who may act), because the 1.4 authorizer seam sees only the actor and the command;
- order (review N9): the actor's own member row, then the actor's grants (`FOR SHARE`, as Identity locks a member and then its grants), then the payload's people. The people are locked once the actor is known to be a trusted, granted member, but before the handler decides whether this actor may act on that duty: any signed-in member's command can thus make a deactivation of the people it names wait for the length of that one request (milliseconds; nothing is changed or disclosed). Locking after the handler's own check would put Duties rows first and bring the deadlock back;
- `app.duties_command_people` reads (without locks) the actor, a named member, the current assignees and planned members of the occurrences the payload names (directly or through a slot, assignment, assignments, series or review flag), and the leaders and deputies of their departments or of a named department. This covers `publish_duty`, `revise_duty`, `assign_slot`, `publish_drafts`, `revise_series`, the cancellations, `remove_member`, the coverage commands and the rest;
- the 4.11 owner operations lock the actor and the cell's assignees in `duties_owner_session`, and the members a part names in `duties_owner_positions` (both bodies replaced, copied from 4.11).

Identity's own `FOR UPDATE` is unchanged (Notifications routing relies on it). A racing command now waits for the lifecycle change and then succeeds or is refused cleanly (`conflict` or `validation_failed`), never `unavailable`, and the change never waits on a command holding a duty. E2E: `L20` (a publish raced with a deactivation, strict: never `unavailable`), `L23` (a deactivation held open while the leader revises and publishes: they wait, then `conflict` and `validation_failed`), `L24` and `L25` (a `revise_duty` and a `publish_duty` paused mid-command by a third connection while the Admin deactivates the member: both succeed, the duty is vacated; without the people lock both end in `40P01`). **Cells** (stories 5.x) must take the same lock for the members a cell command may notify before its own rows. Within the vacate itself (review N5) the member's advisory lock comes first; occurrences it finds then are locked before their assignments.

**Cost.** Ending duties is set-based (one update of the assignments, slots and audit, one notice per department). Locally, `supabase/tests/duties_lifecycle_scale_test.sql` (230 future duties, 1030 open tasks): a hold over 230 duties about 30-40 ms; a removal ending 30 duties about 0.15-0.25 s; a **deactivation ending 200 duties with 1030 open tasks** (25 handed over, the rest pending, their reminders cancelled) about **1.5-2.6 s** (the upper end with other suites running) (asserted under 3 s; statement timeout 8 s); one `followups.complete_handover` step (100 tasks) about 1.7-2.5 s. A handed-over task costs about 15-20 ms (Notifications cancels and plans its reminders per task), so one lifecycle change hands over at most 25 tasks (follow-ups.md).

### Known limit: revoking the last leader first (review S4)

`identity.revoke_scope` does not call the handover hooks (Identity's 2.10 seam is only on deactivation and deletion), so an Admin can remove the last leader's or deputy's scope first and then deactivate the member without the `handover_required` refusal. Nothing is lost: the department then shows **No leader or deputy can use the app: alerts reach nobody** on **Departments** (always when `needs_leader` is true) until a leader is given. **Follow-up item:** an Identity grant-revocation handover hook (Identity owns the change).

### Member deletion

`app.duties_erase_member` and `app.duties_deletion_remaining` are replaced: who removed a member from a department (`ended_by_member`, `ended_by_account`) is anonymised and counted; the 4.10 S1 lock-first order is kept. What a deletion anonymises versus erases follows Identity's `identity_deletion_retention` gate (labelled fixture in local and staging, closed in production).

### Clients

- **Staff web, Departments (Admin):** each member has **Remove from department** (confirmed first: "Their future duties in this department end now ... told when notices can be sent; a member the app cannot reach is listed for the leaders to tell directly"); notice **Removed from the department**, or **Removed, but nobody was told** when the notices were skipped (review N4). A department with a pending handover shows **Handover pending** and **Mark handover done** (disabled until it has a leader or deputy who uses the app; **Give it a leader first** otherwise); any other department with no leader or deputy the app can reach shows **No leader or deputy can use the app: alerts reach nobody** (review S4).
- **Staff web, Membership status (Admin):** a member with Follow-ups handovers still pending (deactivated, being deleted) has **Hand over the next 100 follow-up tasks** (`followups.complete_handover`); the notice says **Nobody could take them** when nothing moved (review N11).
- **Staff web, Follow-up routing (Admin):** **Waiting for handover** lists every member whose tasks or supervision wait for someone in the task's group, also after a revoked scope, each with **Hand over the next 100** (follow-ups.md, story 4.12).
- **Staff web and mobile, Coverage and the board:** **Needs a new person** on a vacated position, "N need a new person" in the counts, and "The person given this position can no longer serve it. Give it to someone else." A board history entry of a Confirmed by leader assignment that ended now reads correctly (it used to fail the board read).
- **Staff web, Membership status:** the **Hand over first** notice says what to hand over and where (a department's last leader or deputy, or the only possible owner of an open follow-up task).

### Local runs

```bash
npx supabase db reset
npm run -s db:test                           # duties_lifecycle_test.sql, duties_lifecycle_scale_test.sql (+ 4.1-4.11)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-lifecycle.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-lifecycle.test.mjs
(cd packages/client_core && flutter test test/duties)
```

Fictional numbers: pgTAP `+44 7700 900460-900469`, scale `900480-900489`, E2E `900470-900479`. Earlier tests changed for the new behaviour: `cross_epic_contracts_test.sql` (it removes the real Duties and Follow-ups hooks too while testing its synthetic ones), `notifications_routing_test.sql` (three hooks on `deletion_requested`), `duties_reminders_test.sql` (a revoked deputy's alert is now cancelled at once; a hold adds an `access_hold` entry; the vacancy notice opens Coverage), `duties_coverage_test.sql` (the `vacated` count; a revoked deputy's coverage task is handed to the leader at once, so the leader's next attempt continues it; review N7: a revoked deputy who stays a member of the department keeps the task, and the leader's next attempt still replaces the case as in 4.9).

### Hosted staging (parent session, then the owner)

1. **Parent session:**
   - Apply `20261015110202_duties_lifecycle.sql` to staging (`tmurpotfluignacfueki`) after `20261015035112` (rename the local file to the recorded hosted version if the apply records another one).
   - Run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
   - Compare the md5 of each new or replaced `app.duties_*` and `app.followups_*` function with the local one (the migration has no backslashes).
   - Grants: no new function is executable by `anon`, `authenticated` or `service_role`.
   - Right after the apply: `select string_agg(event || ':' || module, ',' order by event, module) from app.contract_lifecycle_hooks where module in ('duties', 'followups');` lists seven rows; `select string_agg(module, ',' order by module) from app.identity_handover_hooks where module in ('duties', 'followups');` is `duties,followups`; `select count(*) from app.contract_reminder_contracts where reminder_kind = 'duty_vacated';` is 1.
   - Existing duties are not changed by the apply; the hooks act from the next lifecycle change.
   - No Edge Function change, no rows file, no owner SQL paste.
2. **Staging clients:** rebuild the staff web and the staging APK (no new dependency).
3. **Production:** nothing in this story (Q4 and the deletion retention gate stay closed).

### Owner manual checks (staging, phone and web, story 4.12)

Use synthetic members only. You need: Admin A, leader L and deputy P of `SYNTHETIC Preaching Rota`, members M, O and H with the staging APK, an accountless member R in the department, and a second department `SYNTHETIC 4.12 Ushers` whose only leader is K. Publish duties about two weeks ahead: two for M (M accepts one), one for M in Ushers, two for H (H accepts one), two for O, one for R. As L create follow-up tasks owned by M and by R (supervisor L).

1. **Login hold.** Staff web as A: **Membership status** > find H > **Disable login (hold)**. Staff web as L: **Coverage** (choose the two weeks): H's duties are still there, with **Needs contact** ("Reminders cannot reach them in the app"); nothing says why; L's Inbox gets no alert.
2. **Deactivation.** As A: **Deactivate membership** for M (any reason). As L: **Coverage** shows M's positions as **Unfilled** with **Needs a new person** and "N need a new person"; within about a minute L's and P's Inbox show one **Positions need cover** (K gets one for Ushers); M's phone gets nothing more. **Follow-ups**: M's task is now L's ("Reassigned to L, handed over automatically"). Nothing anywhere names the reason.
3. **Last leader.** As A: **Deactivate membership** for K: **Hand over first** (it names a department's last leader or deputy). As A: **Departments** > Ushers: give another member who uses the app the **Deputy** role; deactivate K again: done.
4. **Removal.** As A: **Departments** > Preaching Rota > O > **Remove from department** > confirm: **Removed from the department**. O's phone gets **Duty changed** for each duty; the positions read **Needs a new person**.
5. **Revoked deputy.** As A: remove P's **Deputy** role. P's open **Coverage** tab: the next action or reload is refused; P's pending notices do not arrive.
6. **Deletion.** As A: **Member deletions** > R > identity check > **Delete member**. R's duty reads **Needs a new person**; R's task is L's. The deletion's steps show no handover wait.
7. **Restore.** As A: **Restore membership** for M: M's earlier duties stay ended; give M a duty again: M gets **New duty assigned**.
8. **Clean up** as in 4.9, step 10, plus (SQL editor) the `app.identity_handover_obligations`, `app.identity_membership_lifecycle` and deletion rows of the synthetic members.

Record the outcome of each step in `evidence-4.12/owner-check.md`: pass or fail, device model, Android version and browser. Include no numbers, ids or keys.

### Owner questions

- **Q4 (open, fail-closed default; unchanged):** what a deletion anonymises versus erases, and personal data in production. Built: the `identity_deletion_retention` fixture locally and on staging; production erasure waits for the owner's approval.
- **New (default built: one generic flag):** may leaders learn *why* a position became vacant (left the church, removed from the department, deleted)? Built: no; one generic **Needs a new person** and end reason `vacated`.
- **New (default built: one notice per department and change):** one vacancy notice per position would flood a leader when a long-serving member leaves; built: one notice per department per change; the queue shows each position.
- **New (default built: a deputy counts):** may a deputy alone be the responsible person of a department (so its last leader can be deactivated once a reachable deputy is in place)? Built: yes (functional requirements: "Admin assigns a deputy/replacement"); a held or accountless deputy does not count.

### Known limits (later entries)

- Cell parts: a deactivated member's cell parts end (the cell's owner read shows the gap), but there is no cell-scope leader alert and no Cells handover (epic 5: cell transfer and removal call the owner operations).
- The vacancy notice is cancelled with its key position (when that position is cancelled the notice goes even if other vacancies of the same change remain; the queue still shows them).
- Released notices to a member removed from a department stay queued if the member is deactivated afterwards (they route to Needs contact).
- A removal of a member with very many future duties sends one released notice per duty.

## Story 4.13: duties runbooks and the synthetic department pilot

No migration and no client change. Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-write-the-duties-runbooks-and-run-the-synthetic-department-p-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.13/`.

### The guides

[duties-guides.md](duties-guides.md) holds three task-ordered guides in plain language (department leader and deputy; Admin; duty reminder problems) and the owner walkthrough. Each task links back to the story section here. Keep both in step: a story that changes a screen or a rule updates its section here and the guide task that names it.

### The pilot rehearsal (`tools/identity-e2e/duties-pilot.mjs`)

It runs the success-evidence loop (spec `delivery-and-decisions.md`, Success evidence) through the API with `SYNTHETIC Preaching Rota`, an app member M, a second app member O and an accountless member X with a SYNTHETIC household number:

| Step | What it proves |
|---|---|
| P10 | a quarterly rota (13 weekly Sundays, Preacher and Reader) is generated; M, X and O are planned; **Publish 26 draft slots** at the church default asks three people and leaves 23 positions unfilled |
| P20 | reminders are queued (M's answer reminders and the leaders' overdue alert, church-default answer-by) and the worker delivers M's **New duty assigned** (generic text, opens the duty); X is on **Needs contact** |
| P30 | M accepts and O declines, each with a note; the leader's board shows both; the leaders get **Duty declined** (opens Coverage); M's accepted duty keeps its pre-service reminder |
| P40 | Coverage shows the gap: unfilled positions, the decline, X awaiting with Needs contact and the labelled household route (leader only) |
| P50 | a direct contact attempt on X opens the coverage follow-up task |
| P60 | **Confirmed by leader** for X: provenance `leader` with channel and recorder, the task closes, X's answer reminders stop (only the pre-service reminder stays) |
| P70 | a short-notice Sunday assignment (a duty three hours ahead with no answer-by time; the server judges Short notice by lead time, not weekday): Short notice, one **New duty assigned** to M, **Short-notice duty** to the leader, Needs contact `short_notice` |
| P80 | reassignment with no stale reminder: a probe duty for M with a creator reminder due ten minutes before an answer-by time 15 minutes away is given to O at once; when the reminder falls due, O gets **Duty answer needed** (the control) and M gets only **Duty changed** (released), never the reminder; M's old item opens out of date; locally no pending job is stale |
| P90 | nothing private for a non-leader: M and O get 403 on the board, Coverage and Rota; their My duties hold no leader-only text, no number and not each other's notes; the Admin's Coverage is operational (no route, note, reason or task) and the board hides the confirmation reason; every Inbox item of the run is its fixed generic text |
| P98, P99 | cleanup through the API (the rota cancelled from its first date, the one-off duties' positions cancelled, M, O and X removed from the department, the leader's scope revoked); nothing of the run is left open |

Fictional numbers: local `+44 7700 900410-900419`; staging `+1 202 555 0166-0168` (personas) and `0159` (X's household route). Leader-only texts start `SYNTHETIC leader-only` so a leak is detectable.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/duties-pilot.mjs --evidence <file>.jsonl                  # about 10 s
node tools/identity-e2e/duties-pilot.mjs --staging-path --evidence <file>.jsonl   # about 6 min (see below)
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/duties-pilot.test.mjs
```

- The default local run makes its personas with the local Auth admin route and the synthetic seed link, drives `tools/notifications/worker.mjs run-once` with its own credential (revoked at the end), reads the job tables for the extra checks and moves the P80 reminder forward with SQL (test-only). It deletes everything it created.
- `--staging-path` takes the staging route against the local stack: personas sign up, apply and are approved by the Admin; no job-table check; P80 waits for the real due time; at the end the staging cleanup SQL is generated and executed, and the run checks it removed the run's rows. Use it after changing the staging branch of the script.

### Against staging (parent session only; never from a builder)

Prerequisites: every 4.x migration on staging, the scheduled worker running (Reminder health fresh), the synthetic Admin `+1 202 555 0150` with its password in a JSON file outside the repository (the 2.14 suite's `STAGING_SUITE_ADMIN`), the staging publishable key. No secret or service-role key, no SQL during the run.

```bash
DUTIES_PILOT_TARGET=staging \
STAGING_PUBLISHABLE_KEY=sb_publishable_... \
STAGING_SUITE_ADMIN=/path/outside/repo/admin.json \
DUTIES_PILOT_STATE=/path/outside/repo/duties-pilot-state.json \
node tools/identity-e2e/duties-pilot.mjs --evidence /path/outside/repo/duties-pilot-staging.jsonl \
  --cleanup-sql /path/outside/repo/duties-pilot-cleanup.sql
```

- The script refuses any origin but `https://tmurpotfluignacfueki.supabase.co`, any key but an `sb_publishable_` key and any state, Admin or cleanup file inside the repository, before any call.
- First run: it signs up the three personas (`+1 202 555 0166-0168`), sends their applications and approves them as the synthetic Admin (passwords are written to the state file, mode 0600), and creates X with `identity.create_member`. Later runs reuse them. A persona left on hold or deactivated stops the run with "heal it by hand".
- `SYNTHETIC Preaching Rota` is used if it exists, otherwise created (the state file remembers that the pilot created it).
- It waits for the scheduled worker (polling every 15 s, up to 4 minutes per step; P80 waits for the reminder's due time, about 5 minutes). A whole run takes about 10-15 minutes.
- **Cleanup:** the API cleanup runs at the end, also after a failure (P98). The run's remaining rows (cancelled duties, their jobs, items and follow-up tasks, the ended department memberships of M, O and X, and the department when the pilot created it) are removed by the SQL written to `--cleanup-sql`: run it in the staging SQL editor (or through the connector) after the run. It names only the run's series, occurrences and members, keeps the personas and the Admin, and changes no schema. `--staging-path` proves it locally.
- Evidence: copy the JSONL (it holds statuses, codes, counts and states only) to `evidence-4.13/` and run `bash tools/auth-harness/scan-evidence.sh` on it.

### Owner walkthrough (HITL, open)

Israel's run-through on the staging web and APK is in [duties-guides.md](duties-guides.md#owner-walkthrough-on-staging-hitl); results go into `evidence-4.13/owner-walkthrough.md`. It is batched to the end of milestone 2.

### Owner questions

- **Q2 (open, unchanged):** the real pilot department and its leaders; the live pilot waits for Israel to name them, and for Q4 for live personal data. This story is the synthetic rehearsal.
- None new.


## Story 4.14: refactor sweep

Migration: `supabase/migrations/20261015130404_duties_comment_refresh.sql` (comments only: the comments of `api.duties_command`, `api.followups_command`, `app.duties_state_ok` and `app.followups_state_ok` name the stories and commands up to 4.12; no function body, grant, table or row changes; no `_rows` file, so **no owner SQL paste**). `supabase/tests/duties_comments_test.sql` fails when a command is routed that the api comment does not name: a story that adds a command updates the comment in its own migration. Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-refactor-sweep-plan.md` (findings table: what was cleaned up, rejected or deferred). Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.14/`.

- **No behaviour change** for members, leaders or Admins, except one client fix: a Follow-ups screen keeps an in-flight update pending while a reload finishes (its buttons stay disabled), as Duties screens have since 4.5.
- **E2E helpers:** the notifications-worker credential block and the church-time and answer helpers of the Duties and Follow-ups E2Es live in `tools/identity-e2e/duties-shared.mjs`; a new E2E imports them from there.
- **Hosted staging (parent session):** apply `20261015130404_duties_comment_refresh.sql` after `20261015110202`; per-function md5 must be unchanged against the local database, and the four comments must match. No Edge Function change; no client rebuild is needed for the comments (the Follow-ups fix ships with the next staging client build).
