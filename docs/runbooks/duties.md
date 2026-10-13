# Runbook: assigned duties (epic 4)

Architecture: AD-1, AD-2, AD-4, AD-6, AD-8, AD-14. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-2.md` (Q2: Africa/Lusaka, creator-set deadlines, creator-configured reminders, member snooze, no quiet hours; the pilot department is not chosen, so staging uses `SYNTHETIC Preaching Rota`). Related runbooks: [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (owner registry, reminder contracts, deletion hooks), [identity-access.md](identity-access.md) (story 2.3 grants and scope kinds, 2.5 accountless members), [notifications.md](notifications.md) (the inbox, the worker, reminder health).

## Story 4.1: publish a one-position department duty and accept it on mobile

Migrations: `supabase/migrations/20261013200000_duties_department_tracer.sql` (no destructive statements, no row deletions) and its small rows file `supabase/migrations/20261013200100_duties_department_tracer_rows.sql` (the member-deletion row purge; the owner applies it by hand on hosted projects). Plan: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/story-publish-a-one-position-department-duty-and-accept-it-on-mobi-plan.md`. Evidence: `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.1/`.

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

1. **Parent session: the main migration.** Apply `20261013200000_duties_department_tracer.sql` to staging (`tmurpotfluignacfueki`) after `20261013194009`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. No Edge Function changes. New client grants (`authenticated` only): `api.duties_command(jsonb)`, `api.duties_my_duties()`, `api.duties_leader_board()`, `api.duties_admin_overview()` and their `app` definer bodies.
2. **Owner, by hand: the rows file.** In the staging SQL editor paste and run `supabase/migrations/20261013200100_duties_department_tracer_rows.sql` after the main file, the same way as `20261008135900_notifications_routing_rows.sql`. It replaces one stub (`app.duties_deletion_purge_rows(uuid)`) and changes no schema object. Check: `select pg_get_functiondef('app.duties_deletion_purge_rows(uuid)'::regprocedure) like '%delete from app.duties_department_members%';` is true. Until then a member deletion waits at its erase step (`unavailable`), which is safe.
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
9. **Clean up** (SQL editor): delete the duties rows of the department (audit, assignments, slots, occurrences, department members), the jobs/attempts/items of the synthetic members, the scope grants, then the department; remove the members as in `identity-access.md`.

Record the outcome per step in `evidence-4.1/owner-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits (later entries)

- One position, one-off occurrences, no drafts, no edits, no cancellation (4.2, 4.3).
- No later decline ("Can't make it anymore"), bulk acceptance or calendar export (4.5).
- No default deadline, Short notice, response or pre-service reminders, snooze of duty reminders, or Needs contact list (4.8, 4.9).
- No lifecycle or handover hooks (4.12).
