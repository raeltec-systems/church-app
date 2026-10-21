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
