---
title: 'Remind confirmed members of meetings and notify them of changes'
type: 'feature'
ticket: '2'
created: '2026-10-21'
status: 'done'
baseline_revision: 'bfa57ed'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/cells-meetings.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Meetings exist (5.1) but nobody is reminded of them, and a moved or cancelled meeting is not announced, so members can arrive at the wrong time or for a meeting that is not happening.

**Approach:** Register the Cells `cells_meeting` source with Notifications (source and reminder checks, generic text, deep link to My cell), plan each currently confirmed member's meeting reminder through the shared 3.3 calculation (`app.notifications_set_schedule`, a `response` schedule already answered so only start-anchored reminders exist; default one reminder 24 hours before the start; the cell's leader or an Admin may change the cell's reminders), and make a move, cancellation or reinstatement re-plan or cancel the reminders and enqueue a generic change notice to every confirmed member in the same transaction. Held and accountless members reach the leader through a registered direct-contact route, shown on staff web Cell meetings.

**Decisions:**
- Decision (agent, under owner pre-approval): reminders are set per cell (`cells.set_meeting_reminders {cell_id, reminders}`), by the cell's leader or an Admin, up to three `{before}` offsets of at most 7 days before the start; `null` returns to the default (24 hours before). Per-meeting overrides wait for an owner request. Owner decision Q2: whoever sets reminders may set them; members may snooze; no quiet hours.
- Decision (agent, under owner pre-approval): recipients are the cell's current confirmed members (primary membership), not leaders or assistants as such. The reminder check's `recipient_eligible` is a current membership in the meeting's cell, so a member transferred out before the reminder gets nothing.
- Decision (agent, under owner pre-approval): one reminder kind `cells_meeting_reminder` (start-anchored, snoozable) and two notices, `cells_meeting_changed` (moved, brought back, or re-timed by a schedule change) and `cells_meeting_cancelled` (cancelled, or withdrawn by a schedule change). Commands always notify; a schedule change notifies only for meetings in the next 14 days. All link to `/my-cell`; no text carries a venue, time or name.
- Decision (agent, under owner pre-approval): planning runs in the commands and, for meetings or members not yet planned, on every meetings read (the read already generates meetings). Reads skip planning silently when the Q2 policy is not usable; commands fail closed (`unavailable`) like Duties.
- Decision (agent, under owner pre-approval): direct-contact needs are kept in `app.cells_meeting_contact_needs` and listed by name on the meeting for the cell's leader and assistant only; deletion anonymises the member id (no rows file).

## Boundaries & Constraints

**Always:** Notifications last in the lock order (lock the meeting, then call Notifications); generic text only (printable ASCII, no names, venues or times); every change through `api.cells_command`; new reads behind the live-access predicate and the Q4 gate; ASCII migration with no `\u` escapes, no destructive statements, privileges revoked; the deletion hook covers every new member-linked row.

**Never:** programme parts or duty reminders (5.3+), Cannot attend (5.7), quiet hours, a venue or name in a notification, reminders to people who are not confirmed members.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Normal week | schedule set, confirmed members | one pending `cells_meeting_reminder` per member at start - 24 h; none for non-members | none |
| Leader changes reminders | leader, reminders revision, `[{before: "2 hours"}]` | future jobs move to start - 2 h | non-leader: `forbidden`; bad offset: `validation_failed {"reminders": ...}`; stale: `conflict` |
| Move | leader moves a meeting | old jobs cancelled (`rescheduled`/stale), new reminder at new start - offset, one `cells_meeting_changed` notice per member now | as in 5.1 |
| Cancel | leader cancels | reminders cancelled `source_cancelled`, one `cells_meeting_cancelled` notice per member | as in 5.1 |
| Bring back | leader reinstates | reminders planned again, `cells_meeting_changed` notice | as in 5.1 |
| Snooze | member snoozes a delivered reminder | deferred job for that member only | expired: `conflict` |
| Transferred out | member's membership ends before the reminder | worker ends the job `ineligible`; next sync cancels the schedule | none |
| Accountless / held | member without a live link | no inbox item; need recorded on the leader's meeting | none |
| Payload | any job or item | ids, kinds and instants only; generic title and body | none |
| Production, Q2 closed | read | no planning, read works | command: `unavailable` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021073514_cells_meetings.sql` -- meetings, generation, commands and reads to extend.
- `supabase/migrations/20261014171038_duties_reminders.sql` -- the worked consumer: source/kind/contract/route registration, `notifications_set_schedule` with an answered `response` schedule for start reminders, direct-contact needs table.
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `notifications_set_schedule`, `notifications_snooze_item`, `notifications_policy_errors`.
- `tools/identity-e2e/duties-reminders.mjs`, `duties-shared.mjs` -- worker-driven E2E pattern.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021081026_cells_meeting_reminders.sql`
- [x] `supabase/tests/cells_meeting_reminders_test.sql`
- [x] Clients: reminders on the staff Cell meetings card (leader/Admin), contact needs on meetings, `/my-cell` deep link.
- [x] `tools/identity-e2e/cells-meeting-reminders.mjs` + offline test.
- [x] Runbook section in `docs/runbooks/cells-meetings.md`.

**Acceptance Criteria:**
- Given the local stack and the worker, when the E2E runs the seven cases (normal week, leader-changed reminder, move, cancellation, snooze, transfer out, accountless), then only the expected inbox items exist, nothing is reminded for a cancelled or moved-away time, and no payload carries a venue or a name.

## Implementation Notes

- Server: `supabase/migrations/20261021081026_cells_meeting_reminders.sql`. Reminders use an answered `response` schedule with only a `starts_at` kind, so `app.notifications_response_kinds` is empty and members may snooze. Planning (`app.cells_plan_meeting`) ends every schedule of a meeting that is not on, re-plans each current member, ends schedules of former members (`not_recipient`), withdraws a waiting cancellation notice when the meeting is on again, and enqueues the given notice. `app.cells_sync_meeting_reminders` runs at the end of generation for meetings missing a plan at their current revision or still reminding a former member; generation also re-plans re-timed and withdrawn meetings (notice only within 14 days). Reads plan only when `app.cells_reminders_available()` (the Q2 value is usable); deleted members are skipped through `app.identity_deletions`.
- Replaced from 5.1: `cells_generate_meetings`, `cells_set_schedule` (review fix 2), `cells_move_meeting`, `cells_cancel_meeting` (review fix 1), `cells_reinstate_meeting`, `cells_authorize_command`, `cells_in_scope` (new aggregate `cells_meeting_reminders` with a real recheck), `cells_command`, `cells_schedule_json`, `cells_meetings`, `cells_erase_member`. The audit action CHECK is widened by drop and add constraint (`reminders_set`).
- pgTAP `supabase/tests/cells_meeting_reminders_test.sql` (41). The full db:test passes; no Notifications ledger needed a change.
- Clients: `MeetingSchedule.reminders`, `remindersDefault`, `remindersRevision`, `CellMeeting.contactNeeds`, `CellMeetingsController.setReminders`, the reminders row and the "Tell directly" label on staff Cell meetings (taste rules: the job on the row it concerns, the rare setting behind a button), `/my-cell` in `ClientPaths.deepLinkTargets`. Tests: 5 more in `test/identity/cell_meetings_test.dart` (18).
- E2E `tools/identity-e2e/cells-meeting-reminders.mjs` (9 checks, real worker) with offline `cells-meeting-reminders.test.mjs`; numbers `+44 7700 900390-900393`. The `cells-meetings.mjs` cleanup now removes Notifications rows (since 5.2 a schedule plans reminders).

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke`
- `node tools/identity-e2e/cells-meeting-reminders.mjs`, `cells-meetings.mjs`, `cells.mjs`
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/ccr-93e730dd-89lbvg`
