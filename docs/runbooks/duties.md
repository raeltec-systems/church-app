# Runbook: assigned duties (epic 4)

Architecture: AD-1, AD-2, AD-4, AD-6, AD-8, AD-14. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-2.md` (Q2: Africa/Lusaka, creator-set deadlines, creator-configured reminders, member snooze, no quiet hours; the pilot department is not chosen, so staging uses `SYNTHETIC Preaching Rota`). Related runbooks: [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (owner registry, reminder contracts, deletion hooks), [identity-access.md](identity-access.md) (story 2.3 grants and scope kinds, 2.5 accountless members), [notifications.md](notifications.md) (the inbox, the worker, reminder health).

## Story 4.1: publish a one-position department duty and accept it on mobile

Migrations: `supabase/migrations/20261013220239_duties_department_tracer.sql` (no destructive statements, no row deletions) and its small rows file `supabase/migrations/20261013220300_duties_department_tracer_rows.sql` (the member-deletion row purge; the owner applies it by hand on hosted projects). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-publish-a-one-position-department-duty-and-accept-it-on-mobi-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.1/`.

### Model (Duties owns it)

- **Departments** (`app.duties_departments`): created by an Admin. While Q4 (personal data) is unapproved, every name must start `SYNTHETIC ` and the department is marked synthetic. Names are unique (case-insensitive).
- **Leader and deputy are Identity scope grants**: Duties registers the scope kinds `department_leader` and `department_deputy` (scope id = department id). Give or remove them with the audited 2.3 commands `identity.grant_scope` / `identity.revoke_scope`. A cell leader scope gives no department authority. Revoking a scope takes effect on the leader's next request (also for an open tab).
- **Department members** (`app.duties_department_members`): approved members with or without a login, added by an Admin. Membership is a Duties record, not an Identity grant. One current row per department and member (ended rows arrive with entry 12).
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
- The job is scheduled at publish time. A held, deactivated or accountless assignee gets no inbox item: 3.5 routes the need to a direct-contact route, and 4.1 registers none, so the need is recorded `unrouted` (finish reason `no_direct_contact_route`) and shows in **Reminder health** until entry 8 adds the leader's Needs contact list.
- Response reminders, default deadlines and Short notice arrive with entry 8.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.duties_my_duties()` | a member with live access | `{member_id, assignments: [...], truncated}`: the caller's current assignments of the last 90 days onwards, future ones first (soonest first), then past ones (most recent first), at most 200 (`truncated` when more exist), with department, times, location, instructions, deadline, answer and the member's own note |
| `api.duties_leader_board()` | department leaders and deputies (their departments), Admin (all, may publish), Pastor (all, read only, without members' notes); anyone else `403 not_granted` | departments with the roster of active members (account shown only as `app_account` or `no_login`; an access review is not disclosed to leaders) and duties of the last 30 days onwards (at most 200, `duties_truncated`), each position's assignment and answer |
| `api.duties_admin_overview()` | Admin | departments with leaders, deputies (with grant revisions) and members; approved members not under deletion (at most 500, `members_truncated`). Rosters here carry the full account label (`app_account`, `no_login`, `access_review`). Members who are no longer approved or are under deletion leave every roster and the Who list; their past assignments stay readable on the duties |

### Member deletion (2.11 hook)

`app.duties_erase_member` is registered with `app.identity_register_deletion_hook('duties', ...)`. Erase deletes the member's department memberships (`app.duties_deletion_purge_rows`, body in the rows file) and keeps assignments, occurrences, departments and audit rows as anonymous facts: member and account ids become the nil UUID and the member's response note is cleared. Check counts what is left. Without the rows file the erase step answers `unavailable` and nothing is erased (fail closed).

Not yet registered (entry 12): lifecycle hooks (deactivation or removal ending future assignments) and the handover hook (last leader of an active department). Until then a deactivated or held assignee keeps the assignment and the worker routes their reminder as above.

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
- No lifecycle or handover hooks (4.12).

## Story 4.2: revise assignments on material change and refuse stale responses

Migration: `supabase/migrations/20261014001142_duties_revisions.sql` (forward only: the 4.1 files are not edited; no destructive statements, no row deletions, no new `_rows` file, no new client grant). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-revise-assignments-on-material-change-and-refuse-stale-respo-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.2/`.

### Model

- **Slot revisions** (`app.duties_slot_revisions`): one immutable row per published, material or notes change of a slot (`change_class` `published`, `material`, `notes`) with `changed_fields`, a snapshot of the slot's fields, the assignee and the current assignment at that revision. A trigger refuses every update except member deletion replacing a person id with the nil UUID. The migration back-fills revision 1 for slots published under 4.1.
- **Assignment lifecycle**: `current`, `superseded` (a material change replaced it; `end_reason` `revised`) and `cancelled` (vocabulary only until 4.3 adds the cancelling command). An assignment records the slot revision it answers and the assignment it supersedes. The answer, its member, account, time, provenance and note stay on the superseded row. A slot keeps exactly one current assignment. A trigger (`app.duties_assignment_history_guard`) makes an ended assignment immutable, except member deletion replacing person ids with the nil UUID and clearing the note.
- **What is material** (`app.duties_slot_field_class`, the single classification): `duty_name`, `starts_at` (the date and start), `ends_at`, `reporting_at`, `location` and `member_id` (the assignee) are material; `instructions` are notes. `response_deadline` belongs to the assignment. Any slot field a later story adds must be classified there.

### Command `duties.revise_duty`

`{occurrence_id, duty_name?, starts_at?, ends_at?, reporting_at?, location?, instructions?, member_id?, response_deadline?}` with `expected_revision` = the occurrence revision. The department's leader or deputy, or an Admin (not Pastor, not another department's leader, not a cell leader). The payload is a patch: present keys are the change, `null` clears an optional field, a value equal to the current one is no change.

- **Material change** (any material field differs): needs a new `response_deadline` (the leader's until entry 8 adds the 3.3 default), checked against the new times. The current assignment becomes `superseded` (answer kept), a new `pending` assignment is created for the same member or the new one, the old assignment's pending jobs are cancelled `source_revised` and a generic notice is queued: `duty_changed` to the same member, or `duty_assigned` to a new member plus `duty_released` to the old one.
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
- The new deadline is the leader's; the 3.3 default deadline, Short notice and response or pre-service reminders arrive with entry 8 (a material change will then re-plan them).
- A declined assignment stays current until the leader changes or reassigns it; the coverage queue and leader confirmation arrive with entry 9.

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
| A one-off duty cancelled here | `{"occurrence_id": "not_in_series"}` (entry 9 brings position cancellation) |
| Nothing changes | `{"occurrence_id" \| "series_id" \| "slot_id": "unchanged"}` |
| Gate closed (production without Q4, or without Q2 for generation and publishing); untrusted session | `unavailable {"policy": "gate_closed"}`; `unauthenticated` |

**Which date?** When one date of a series stops a `publish_drafts` or `revise_series` (an answer-by that has passed, a person who can no longer serve, a time that does not fit), the answer also names that date with the key `occurrence:<occurrence_id>` and the same code (ids only); the Rota page shows the problem and an **Open** button for that date.

A replay with the same request id returns the stored answer after the kernel rechecks scope (series: a current manager of its department); a leader whose scope was revoked gets `forbidden`, also for a replay. Lock order: grants -> receipt -> department -> series -> occurrences (date order) -> membership -> slots -> assignments -> Notifications (always last; the change engine returns its notification work and the command runs it after every Duties row is written). A member's answer racing a series edit serialises on the assignment row: whichever commits first wins, and the other sees the new state.

### Notices

| Kind | Title / body | Link | Delivered while |
|---|---|---|---|
| `duty_cancelled` | **Duty cancelled** / "One of your duties was cancelled. Open My duties to see what is still yours." | `/duties` | the cancelled assignment is at its final revision and the duty would not yet have started; sent to assignees who were pending or had accepted |

Publishing a rota uses the 4.1 `duty_assigned` contract for every generated assignment; changes use the 4.2 kinds. Cancelling an occurrence cancels every pending job of its assignments (`source_cancelled`). An accountless or held assignee's notice is recorded `ineligible`/`no_direct_contact_route` until entry 8 adds the leader's Needs contact list.

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
- Overlap warnings and each candidate's upcoming load arrive with entry 4; default deadlines, Short notice and response or pre-service reminders with entry 8; the coverage queue, position cancellation of one-off duties and leader confirmation with entry 9.
- A this-and-future edit overwrites the given fields on later dates, including dates changed one at a time before; fields not given keep each date's own value.
- Series times are on one church-local date: a reporting time must be at or before the start time on the same day, so a duty starting just after midnight with reporting the evening before cannot be expressed in a series (publish it as a one-off duty with instants instead).

## Story 4.4: warn on overlapping duties and record reasoned overrides

Migration: `supabase/migrations/20261014052239_duties_overlaps.sql` (forward only: the 4.1-4.3 files are not edited; no destructive statements, no row deletions, no new `_rows` file; `department_id` on occurrences becomes nullable with `ALTER ... DROP NOT NULL`, which the migration policy allows). New client grant: `api.duties_candidates(...)` and its `app` body (authenticated only). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-warn-on-overlapping-duties-and-record-reasoned-overrides-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.4/`.

### Model

- **Owning scope.** Every occurrence is owned by exactly one department or one cell (`app.duties_occurrences.cell_id`; check `duties_occurrences_one_owner`). No command creates a cell-owned occurrence yet: entry 11 adds the Cells owner operations. Until then cell-owned occurrences exist only as SYNTHETIC fixtures in pgTAP and the local E2E, and My duties lists department-owned duties only.
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

- Cell-owned occurrences arrive with entry 11 (the Cells owner operations); until then they are fixtures only, and a cell conflict never shows the cell's name (Duties never reads Cells).
- A duty without an end time is assumed to take two hours; every warning shows the busy time used.
- An overlap created later by someone else is recorded on the later assignment (with its reason); the earlier one only shows the overlap count.
- Draft edits (this date or this and later dates on drafts) ask no reason; Publish N checks and names the date.
- The member never sees the reason; the coverage queue, leader confirmation and the Home "upcoming conflicts" count arrive with entry 9.

## Story 4.5: respond from My duties with later decline and bulk acceptance

Migration: `supabase/migrations/20261014093012_duties_member_responses.sql`.
- Forward only: the 4.1-4.4 files are not edited.
- No destructive statements, no row deletions and no `_rows` file.
- No new client grant: both new commands go through `api.duties_command`.

Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-respond-from-my-duties-with-later-decline-and-bulk-acceptanc-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.5/`.

### Model

- **Earlier acceptance.** `app.duties_assignments.prior_accepted_at` holds the time the member had accepted before saying they can't make it anymore. The `duties_assignments_prior_accepted` check allows it only on a `declined` answer. Ended assignments keep it unchanged (the history guard is replaced to cover it).
- **Audit.** A later decline is `acceptance_withdrawn` with code `declined`. Each date of a bulk acceptance is a `response_recorded` row with code `accepted`, all under the one request id. Ids and codes only, never the note.
- **Cell-owned assignments fail closed.** Members cannot answer a cell-owned assignment until entry 11 builds the member view for cell parts. `duties.respond`, `duties.withdraw_acceptance` and `duties.accept_many` all answer `not_found` for an assignment of a cell-owned occurrence. My duties still lists department-owned duties only.

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
   - Apply `20261014093012_duties_member_responses.sql` to staging (`tmurpotfluignacfueki`) after `20261014052239`.
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

- Leaders get no push or inbox alert for a decline yet; the board shows it at once. The leader decline alert and the coverage queue arrive with entry 9.
- Cell programme parts are not answerable or listed in My duties until entry 11.
- No phone or Call action for the leader on the detail screen (Q4, entry 9 contact routes).
- Accepting several dates together is without a note; accept a date on its own to add one. The Home card's Accept sends no note.
- The calendar export is a copy. The iOS share sheet (iPad popover anchor) is unverified on a device until an iOS build exists.
