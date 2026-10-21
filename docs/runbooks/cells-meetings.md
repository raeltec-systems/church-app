# Runbook: cell meetings and programmes (epic 5)

Leader and operator guide for the Cells meeting kernel and, as later stories land, programmes. The
owner's decisions that apply are in `_bmad-output/initiative-church-app/owner-decisions-milestone-2.md`
(Q2: church time is Africa/Lusaka, no quiet hours) and `owner-decisions-milestone-1.md` (synthetic
data until Q4 is approved).

## Story 5.1: a cell's weekly meetings and the next one on My cell

Migration: `supabase/migrations/20261021073514_cells_meetings.sql` (no row deletions; one file).
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-generate-a-cell-s-weekly-meetings-and-show-the-next-one-on-m-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.1/`.

### Model (Cells owns it)

- **Weekly schedule** (`app.cells_meeting_schedules`, one per cell): ISO weekday (1 = Monday),
  start and end time in church time, the **private** venue (1-120 characters, `SYNTHETIC ` first
  while Q4 is unapproved) with an optional map pin, the first date, and the zone and Q2 policy
  version it was set under (AD-9). Only an Admin sets it (Setup in the functional requirements).
- **Meetings** (`app.cells_meetings`): one row per cell and nominal church-local date
  (`occurrence_date`, the occurrence key). The row id is the **stable meeting id** that programmes,
  attendance, recaps and offerings reference. Rows are generated for today plus 84 days (12 weeks)
  whenever the schedule is saved and on every meetings read; regeneration never changes an id.
- **States**: `scheduled`, `moved` (one meeting at another time and, optionally, another venue),
  `cancelled`, `withdrawn` (a future date the current rule no longer produces; hidden, never
  deleted, revived with the same id if the rule produces the date again). Story 5.8 adds `held`.
- **A schedule change** re-times future *scheduled* meetings in place (same ids). It never touches
  moved or cancelled meetings or anything that has started.
- **Who sees the venue and pin**: the cell's leader and assistant (staff web) and its confirmed
  members (mobile My cell), through `app.cells_member_has_private_access`. An Admin **writes** the
  venue but, without a leader or assistant role in that cell, reads only that one is set
  (`venue_set`, `pin_set`). A member of another cell, an account without member access and an
  Admin-only reader never receive it.
- **Audit** (`app.cells_meeting_audit`): action, ids, actor capacity (`admin`, `cell_leader`) and
  revision only. No venue, times or names.

### Commands (`POST /rest/v1/rpc/cells_command`, `Content-Profile: api`)

| Command | Who | `expected_revision` | Payload |
|---|---|---|---|
| `cells.set_schedule` | Admin | the cell revision | `{cell_id, weekday, start_time "HH:MM", end_time "HH:MM", venue?, map_pin?: {lat, lng} \| null, from_date? "YYYY-MM-DD"}` |
| `cells.move_meeting` | the cell's leader, or an Admin | the meeting revision | `{meeting_id, starts_at, ends_at, venue?}` (UTC instants; `venue` absent keeps, null = the usual venue) |
| `cells.cancel_meeting` | the cell's leader, or an Admin | the meeting revision | `{meeting_id}` |
| `cells.reinstate_meeting` | the cell's leader, or an Admin | the meeting revision | `{meeting_id}` (back to its usual time and venue) |

- `set_schedule`: `venue` is required the first time and kept when absent later; `map_pin` absent
  keeps it, `null` clears it. A meeting lasts at most 6 hours (`end_time` `before_start` /
  `too_long`). Production answers `unavailable {"policy": "gate_closed"}` until the owner approves
  the Q2 policy value (and every Cells read and command needs the Q4 gate).
- `move_meeting`: the new start is in the future (`past`) and within 30 days of the usual date
  (`out_of_range`). A meeting that has started is `validation_failed {"meeting_id": "started"}`; a
  cancelled one is `conflict {"meeting_id": "cancelled"}`.
- An assistant, a member or another cell's leader gets `forbidden`. A replay is rechecked: a leader
  whose role was removed gets `forbidden` even for their own earlier request.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.cells_meetings()` | Admin, cell leaders and assistants (`403 not_granted` otherwise) | `{cells: [{cell_id, name, is_synthetic, role, can_change, can_set_schedule, cell_revision (Admin), schedule, meetings[]}]}`; meetings from the last day to 12 weeks ahead, withdrawn ones left out |
| `api.cells_my_cell()` | a member with live access | as in 2.6, plus `meetings: {cell_id, next, cancelled[]} \| null` for the member's own confirmed cell |

### Member deletion (2.11 hook)

`app.cells_erase_member` now also replaces the deleted member's and account's ids with the nil UUID
in the schedule, meeting and meeting-audit rows (attributed facts kept anonymously) and counts them
in `remaining`. No rows file is needed.

### Clients

- **Staff web, Cell meetings** (`/cells/meetings`, shown to Admins and to cell leaders and
  assistants): each cell leads with its next meeting and how many of the next meetings are moved or
  cancelled, then its 12 weeks with **Move**, **Cancel this meeting** and **Bring it back** (leader
  or Admin), then the Admin's **Change the schedule**. Times are typed and shown in church time.
- **Mobile, My cell**: the screen opens with **Next meeting**: the time, the venue and the map pin
  (copyable coordinates), any cancelled meeting before it, and "Moved from its usual time" when it
  was moved. Nothing is stored for offline reading.

### Local runs

```bash
npx supabase db reset                          # empty Admin roster
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-meetings.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900200-900206` and removes everything it created.

### Hosted staging (parent session, then the owner)

Apply `20261021073514_cells_meetings.sql` to staging after `20261015190139`, then run
`tools/ci/verify-hosted.sql` with `expected_env=staging`. No Edge Function changes and no rows file.

### Owner manual checks (staging, phone and web, story 5.1)

Use synthetic members only. You need an Admin A, a leader L and an assistant T of
`SYNTHETIC Shikoswe Cell`, a confirmed member M of that cell with the app on your phone, a confirmed
member E of `SYNTHETIC Estates C5/C7 Cell`, and the leader of Estates (set them up on staff web
**Cells** as in 2.6).

1. **Schedule.** Staff web as A: **Cell meetings** > `SYNTHETIC Shikoswe Cell` > set Friday,
   `18:00` to `19:30`, venue `SYNTHETIC 12 Shikoswe Road`, a map pin, **Save schedule**. Expect
   **Schedule saved**, "Next: Friday …" and twelve weeks of Fridays. A's card shows "Venue: set", not
   the address. A venue without `SYNTHETIC ` shows **Check the form**.
2. **Leader's view.** Staff web as L: the same cell shows the venue. **Move** the second meeting to
   the Saturday, `10:00`-`11:30`, venue `SYNTHETIC Church hall`: **Meeting moved**, the row says
   **Moved, other venue**. **Cancel this meeting** on the third: **Meeting cancelled**.
   **Reload**: the same meetings in the same places.
3. **Assistant.** Staff web as T: the venue is shown, there is no **Move** or **Cancel**.
4. **Member on the phone.** As M: **My cell** opens with **Next meeting**, the time in church time,
   the venue and the map pin. Cancel the first meeting as L and reload on the phone: it shows
   "Cancelled: …" and the moved meeting as next, with "Moved from its usual time".
5. **Bring it back.** As L: **Bring it back** on the first meeting: **Meeting brought back**; on the
   phone it is next again at its usual time.
6. **Others see no venue.** As E on a phone: **My cell** has no Shikoswe meeting or venue. As A on a
   phone: no meeting card. The Estates leader's **Cell meetings** lists only Estates.
7. **Clean up** (SQL editor): delete the cell's rows from `app.cells_meeting_audit`,
   `app.cells_meetings` and `app.cells_meeting_schedules`, or keep them for story 5.2.

Record the outcome per step in `evidence-5.1/owner-check.md` (pass/fail, device, browser; no
numbers, ids or keys).

### Known limits (later entries)

- No meeting reminder or change notice yet (5.2).
- No programme, publishing or duty slots (5.3, 5.4), no Cannot attend (5.7), no held state or actual
  leaders (5.8), no transfer effects on meetings (5.9).
- The map pin is shown as coordinates; opening a maps app needs a new launcher seam.
- A moved meeting whose usual date the schedule no longer produces stays moved (it still happens).

## Story 5.2: meeting reminders and change notices

Migration: `supabase/migrations/20261021120000_cells_meeting_reminders.sql` (no row deletions; one file).
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-remind-confirmed-members-of-meetings-and-notify-them-of-cha-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.2/`.

### Source, kinds and text (Notifications 3.2 contracts)

Source type `cells_meeting` (source id = meeting id, revision = meeting revision). Every kind links
to `/my-cell` (My cell reads the meeting again; the link is a pointer, not a grant):

| Kind | When | Title |
|---|---|---|
| `cells_meeting_reminder` | before the start, per the cell's reminders (default 24 hours) | Cell meeting coming up |
| `cells_meeting_changed` | a move, a bring back, or a schedule change re-timing a meeting in the next 14 days | Cell meeting changed |
| `cells_meeting_cancelled` | a cancellation, or a schedule change withdrawing a meeting in the next 14 days | Cell meeting cancelled |

The text is generic: no time, venue or name ever travels in a notification.

### Who is reminded

- The cell's **current confirmed members** (primary membership), with or without a login. A leader
  or assistant who is not a member of the cell is not reminded. The reminder check's
  `recipient_eligible` is a current membership, so a member transferred out before the reminder
  gets nothing (the worker ends the job `ineligible`; the next meetings read ends their schedule).
- Held, in-review and accountless members get no inbox item: the need lands in
  `app.cells_meeting_contact_needs`, and staff web **Cell meetings** shows "Tell directly: <names>"
  on the meeting, to the cell's leader and assistant only.
- Members can snooze a meeting reminder (**Remind me later**). There are no quiet hours.

### Commands (`api.cells_command`)

| Command | Who | `expected_revision` | Payload |
|---|---|---|---|
| `cells.set_meeting_reminders` | the cell's leader, or an Admin | `schedule.reminders_revision` | `{cell_id, reminders: [{before: "<n> minutes\|hours\|days"}] \| null}` (at most 3, at most 7 days, distinct; `null` = the default, `[]` = none) |

Move, cancel and bring back (5.1) now re-plan the meeting's reminders and enqueue their notice to
every confirmed member in the same transaction (Notifications last in the lock order). Planning
also runs on every meetings read for meetings or members not yet planned at the current revision.
Reads skip planning while the Q2 policy is not usable; commands then fail closed
(`unavailable {"policy": "gate_closed"}`).

### Reads

`api.cells_meetings()` now also returns, per cell, `schedule.reminders`, `reminders_default` and
`reminders_revision`, and per meeting `contact_needs: [{member_id, display_name, kinds}]` (empty
for an Admin-only reader).

### Member deletion

`app.cells_erase_member` also replaces the member id on their contact needs with the nil UUID.
Notifications' own hooks remove the member's jobs, items and schedules.

### 5.1 review fixes carried here

Cancelling a meeting moved to another venue now works (the moved venue is cleared); a map pin
without `lat` or `lng` is `validation_failed {"map_pin": "invalid"}`; a withdrawn meeting comes
back when its new time is still ahead; staff web offers **Bring it back** by the meeting's usual
time, as the server checks.

### Clients

- **Staff web, Cell meetings**: "Reminders: 1 day before (usual)" under the schedule, with
  **Change reminders** (leader or Admin: up to three of 1 hour, 2 hours, 1 day, 2 days, 7 days
  before; **Use the usual**). "Tell directly: <names>" on a meeting the app could not announce to
  someone.
- **Both apps**: the reminder and notices open **My cell** from the Inbox.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-meeting-reminders.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900390-900393`, runs the real worker, and removes everything it created.

### Hosted staging (parent session, then the owner)

Apply `20261021120000_cells_meeting_reminders.sql` after the 5.1 migration, then run
`tools/ci/verify-hosted.sql` with `expected_env=staging`. No Edge Function change and no rows file.
Staging's synthetic scheduler delivers the reminders.

### Owner manual checks (staging, phone and web, story 5.2)

Use the 5.1 setup (Admin A, leader L, member M with the app on your phone) plus a member X without
a login confirmed in `SYNTHETIC Shikoswe Cell`.

1. **Reminders.** Staff web as L: **Cell meetings** shows "Reminders: 1 day before (usual)".
   **Change reminders**, choose **2 hours before**, **Save reminders**: **Reminders saved**.
2. **Move.** As L, **Move** the next meeting by an hour. Within a few minutes M's phone Inbox shows
   **Cell meeting changed**; opening it leads to **My cell** with the new time. The notice text
   names no time or place.
3. **Cancel.** As L, **Cancel this meeting** on a later meeting: M gets **Cell meeting cancelled**;
   My cell shows it as cancelled.
4. **Tell directly.** After the next notice, L's meeting row shows "Tell directly: X".
5. **Snooze.** When the reminder **Cell meeting coming up** arrives, **Remind me later** > 1 hour:
   it comes back an hour later.

Record the outcome per step in `evidence-5.2/owner-check.md` (pass/fail, device, browser; no
numbers, ids or keys).

### Known limits

- Reminders are per cell; one meeting cannot have its own reminders yet.
- A schedule change notifies only for meetings in the next 14 days.
- "Tell directly" lists names only; recording that the leader made contact comes with programme
  responses (5.5).
