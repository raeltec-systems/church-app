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

Migration: `supabase/migrations/20261021081026_cells_meeting_reminders.sql` (no row deletions; one file).
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

Apply `20261021081026_cells_meeting_reminders.sql` after the 5.1 migration, then run
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
- A weekday change notifies withdrawn dates but not the new ones; re-timing a cancelled meeting
  drops its waiting cancellation notice (5.2 review, accepted).

## Story 5.3: programme drafts with validated parts and visible gaps

Migration: `supabase/migrations/20261021084446_cells_programmes.sql` (no row deletions; one file; it
also carries the 5.2 review fixes).
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-draft-a-meeting-programme-with-validated-parts-and-visible-ga-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.3/`.

### Model (Cells owns it)

- `app.cells_programmes`: one per meeting (`meeting_id` unique), `programme_state` `draft` or
  `cancelled` (5.4 adds `published` through the `_ok()` check), topic and scripture (at most 120
  characters), study notes (at most 2000, multi-line), `revision`, who created and last saved it.
  The meeting's date, time and venue stay the meeting's own: changing them is a move (5.1).
- `app.cells_programme_parts`: stable `part_id`, `position` 1-20, label (1-60 characters),
  `starts_at`/`ends_at` (instants on the meeting's church date), optional `assignee_member_id`,
  `removed_at` (parts are never deleted; a save leaves out a part by marking it removed, so 5.4
  can link one Duties slot to each stable part).
- `app.cells_programme_audit`: content-free (`programme_created`, `programme_saved`,
  `programme_cancelled`, ids, capacity, revision).

### Commands (`api.cells_command`)

| Command | Who | `expected_revision` | Payload |
|---|---|---|---|
| `cells.create_programme` | the cell's leader or assistant | `null` | `{meeting_id}` (a meeting ahead, not cancelled; a second one is `conflict {"meeting_id": "exists"}`) |
| `cells.save_programme` | the cell's leader or assistant | programme `revision` | `{programme_id, topic?, scripture?, study_notes?, parts: [{part_id?, label, start_time "HH:MM", end_time "HH:MM" \| duration_minutes, assignee_member_id?}]}` |
| `cells.cancel_programme` | the cell's leader or assistant | programme `revision` | `{programme_id}` |

A save replaces the whole draft. Parts must be in time order, inside the meeting and must not
overlap; an assignee must be a current confirmed member of the cell (members without a login
included). Refused parts are reported per part: `validation_failed {"parts.<index>": "<code>"}`
with `label_required`, `label_too_long`, `label_invalid`, `start_invalid`, `end_invalid`,
`end_or_duration`, `duration_invalid`, `end_before_start`, `outside_meeting`, `out_of_order`,
`overlap`, `part_unknown`, `part_duplicate` or `assignee_not_in_cell`; nothing is written. A
cancelled programme is `conflict {"programme_id": "not_draft"}`; a cancelled or started meeting is
`validation_failed {"meeting_id": "cancelled" | "started"}`. Admin and Pastor do not edit.

### Reads

`api.cells_programme(meeting_id)`:

| Caller | `view` | Gets |
|---|---|---|
| the cell's leader or assistant | `full`, `can_edit: true` | meeting (with venue), programme, roster `[{member_id, display_name, account}]` |
| Pastor role (oversight) | `full`, `can_edit: false` | meeting without venue, programme, roster |
| Admin only | `metadata` | state, revision, `part_count`, `gaps`; no topic, notes, parts or names |
| anyone else | 403 `not_granted` | nothing |

Each part reads `assignee: {member_id, display_name, in_cell}` or `null` (a gap); `in_cell` false
means the person has left the cell (the draft keeps them; saving it that way is refused).

### Member deletion

`app.cells_erase_member` clears the member as an assignee and anonymises them as creator, saver
and audit actor (nil UUID). The 5.2 reminders audit is covered too.

### 5.2 review fixes carried here

An empty reminder list now means no reminders (only `null` is the default); planning locks the
meeting before calling Notifications; a read never fails because planning was refused; confirming
or transferring a member plans their reminders at once; "Tell directly" lists current members only.
Staff web keeps any reminder offset already set as a choice.

### Clients

- **Staff web, Cell meetings**: **Plan** on each meeting ahead, for the cell's leader and assistant.
- **Staff web, Plan meeting** (`/cells/meetings/<meeting id>/plan`): first the meeting, its state
  and "N parts, M gaps"; then topic, scripture, study notes and the parts (start, end, part, who:
  "Nobody yet" is a gap; members without a login are marked); **Add a part** starts where the last
  part ends; **Save draft**; **Cancel this programme** (asks once more). Beside the editor (below it
  on a narrow window) a preview shows what members will see once the programme is published
  (5.4); members see nothing of a draft. Pastor reads the draft without an editor; an Admin-only
  reader sees the counts.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-programmes.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900010-900019` and removes everything it created.

### Hosted staging (parent session, then the owner)

Apply the 5.3 migration after the 5.2 one, then run `tools/ci/verify-hosted.sql` with
`expected_env=staging`. No Edge Function change and no rows file.

### Owner manual checks (staging, web, story 5.3)

Use the 5.1 setup (Admin A, leader L, assistant S, member M), the 5.2 member X without a login, and
a Pastor P (role given by A).

1. **Plan.** Staff web as L: **Cell meetings**, **Plan** on the next meeting, **Start the
   programme**. Add three parts from 18:00 (opening prayer, worship, Bible study); give the first
   two to M and X, leave the third with **Nobody yet**. **Save draft**: "3 parts, 1 gap", and the
   preview shows the third part as "Open: nobody yet".
2. **Refusals.** Set the second part to start before the first one ends, **Save draft**: the row
   says "Overlaps the part above" and nothing is saved. Set a part to end after the meeting: "Keep
   it inside the meeting". Put the times back.
3. **Stale.** Open the same page as S in a second browser, save a change there, then save in the
   first browser: **Changed elsewhere**, and the page shows S's version.
4. **Who reads.** As P, open the page's address: the draft shows read-only, without the venue. As
   A (Admin only), the same address shows only the counts. M cannot open it.
5. **Cancel.** As L, **Cancel this programme**, **Yes, cancel the programme**: the page shows it
   read-only as Cancelled.

Record the outcome per step in `evidence-5.3/owner-check.md` (pass/fail, browser; no numbers, ids
or keys).

### Known limits

- Members see nothing until publishing (5.4); responses come with 5.5, change notices with 5.6.
- Pastor oversight has no list of programmes yet: a Pastor opens a meeting's plan by its address.
- Parts are not reordered by dragging: the order is the time order, and the editor reports an
  out-of-order part.

## Story 5.4: publish a safe programme that creates or links duty slots

Migrations: `supabase/migrations/20261021093943_duties_owner_linkable.sql` (a Duties contract change) and `supabase/migrations/20261021094249_cells_programme_publish.sql` (no row deletions; it also carries the 5.3 review fixes).
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-preview-and-publish-a-safe-programme-that-creates-or-links-d-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.4/`.

### Release gate (4.11, consumer guide step 7)

This story registers `cells_programme_part` as a Duties `cell_part` source. A client older than the 4.11 build cannot show My duties once a cell part exists. **Apply 5.4 to staging only after the owner confirms every client in use there runs the 4.11 build or later** (staff web deployment and every installed phone build).

### Publishing

`cells.publish_programme {programme_id, override_reason?}` (the cell's leader or assistant; expected = programme `revision`). Each live part reaches Duties in the same transaction:

| Part | In Duties |
|---|---|
| a person | a cell-owned occurrence (name = the part's label, times = the part's, location = the meeting's venue, topic and scripture = the programme's) with one position `lead`; the person is asked (Awaiting) and gets the Duties notice and reminders |
| nobody | the same occurrence with an open position |
| a department duty (`linked_slot_id`) | a display link (`department`) to that department position; the duty is not changed and stays its department's |

A republish puts the same state again: no new slot, link or assignment. Refusals: `forbidden` (anyone but the cell's leader or assistant), `conflict` (stale, or `{"programme_id": "cancelled"}`), `validation_failed {"parts": "required"}`, `{"meeting_id": "cancelled" | "started"}`, `{"parts.<i>": "assignee_not_in_cell"}`, and Duties refusals under their part, e.g. `{"parts.2.member_id": "overlap", "parts.2.override_reason": "required"}` when the person is on another duty then (publish again with `override_reason`, or change the part).

`cells.save_programme` parts may carry `linked_slot_id` (one of the meeting's department positions; not with an assignee: `assignee_and_link`; unknown or no longer offered: `link_unavailable`). A published programme is not saved as a draft (`not_draft`); changing it comes with 5.6.

`cells.cancel_programme` on a published programme cancels its cell-owned duties through Duties (their people are told), ends its display links and withdraws what members read.

### Reads

- `api.cells_programme(meeting_id)` adds `preview` (the member-safe projection of the programme as it stands), `published` (what members read now, with `revision` and `published_at`), and for the cell's leader and assistant `duties` (per part: the owned position's answer, or the display link) and `linkable` (department positions overlapping the meeting).
- `api.cells_meeting_programme(meeting_id)` (new): current confirmed members of the meeting's cell with an approved active account read `{meeting (with venue), programme}`; the programme is the stored projection (topic, scripture, parts with times, `leader` name or `department`), never study notes, answers, notes or history; null until published or after a cancel. Anyone else (another cell, Admin alone, the cell's leader when not a member, no member access) is 403 `not_granted`.
- Duties (contract change): `app.duties_owner_linkable({cell_id, starts_at, ends_at})`, not client-executable; see the consumer guide.

### Member deletion

Names leave every projection (the part reads as open); publishers are anonymised.

### 5.3 review fixes carried here

A draft's parts follow a moved meeting (and its revision moves on); a part after midnight lands on the next day when the meeting runs past midnight; two concurrent creates answer `conflict`; a removed part never comes back; save locks the meeting first; study notes with Windows line endings are accepted; a confirmation is never blocked by reminder planning. Staff web keeps the typed draft after a conflict (**Load the latest**), clears part errors when a row is removed, and **Add a part** stays inside the meeting.

### Clients

- **Staff web, Plan meeting**: **Publish to members** (a saved draft; "Save the draft to publish it." otherwise). A part can show **Department duty: ...** instead of a person. An overlap shows "On another duty at this time" on its part, with a reason field and **Publish with this reason**. A published programme shows **Who is on** with each answer (Awaiting response, Accepted, Confirmed by leader, Declined, Open: nobody asked, Department duty: filled), "N of M accepted" at the top, and what members see now; **Cancel this programme** asks once more.
- Mobile My cell and Home show the programme in 5.5.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-programme-publish.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900020-900029` and removes everything it created (Duties rows included).

### Hosted staging (parent session, then the owner)

After the release gate is confirmed: apply `20261021093943_duties_owner_linkable.sql`, then `20261021094249_cells_programme_publish.sql` (renamed to their hosted versions), then run `tools/ci/verify-hosted.sql` with `expected_env=staging`.

### Owner manual checks (staging, web and phone, story 5.4)

Use the 5.3 setup (leader L, member M with the app on your phone, member X without a login) and a department with a published duty at the meeting's time.

1. **Publish.** As L, open **Plan** on the next meeting: give one part to M, one to X, leave one with **Nobody yet**, and set one to **Department duty: ...**. **Save draft**, then **Publish to members**: "Published to members"; **Who is on** shows M and X as Awaiting response, the open part as Open, the department part as Department duty.
2. **M's phone.** M gets the duty notice; **My duties** shows the part (Cell programme) waiting for an answer.
3. **Department duty unchanged.** As the department's leader, the duty shows "Shown on 1 cell programme part" and nothing else changed.
4. **Cancel.** As L, **Cancel this programme**: M's part leaves My duties with a cancellation notice; the department duty is unchanged.

Record the outcome per step in `evidence-5.4/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- A published programme can't be changed yet (5.6). While it is published, **Move** and **Cancel this meeting** on Cell meetings answer `conflict {"meeting_id": "programme_published"}` ("Programme published: cancel the programme on Plan first"). A schedule change that re-times or withdraws the meeting is not refused and does not yet reconcile its duties (5.6).
- Mobile shows the programme from 5.5; leader confirmation for members without a login is 5.5 (a Duties contract change).
- One position per part; no per-part instructions or reporting time.

## Story 5.5: You're on, answers and direct confirmation

Migrations: `supabase/migrations/20261021101314_duties_cell_confirmation.sql` (a Duties contract change) and `supabase/migrations/20261021101323_cells_youre_on.sql`.
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-show-you-re-on-and-respond-to-programme-parts-on-my-cell-and-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.5/`.

### What changed

- `api.cells_meeting_programme` adds `yours: [{part_id, occurrence_id}]`: the reader's own published parts and their Duties occurrence. The programme read never carries an answer; the member's own answer, reporting time and instructions come from their My duties read (`api.duties_my_duties`), matched by `occurrence_id`.
- Members answer with the Duties commands (`duties.respond`, `duties.withdraw_acceptance`, `duties.accept_many`) at the assignment revision; a stale answer is `conflict`.
- **Duties contract change:** `duties.confirm_by_leader {assignment_id, channel, reason}` (expected = assignment revision) also accepts a cell-owned assignment when the actor is a current leader or assistant of that cell. It records the 4.9 attributed confirmation (provenance `leader`, channel, reason, the leader as `responded_by`; audit `leader_confirmed` with capacity `cell_leader`/`cell_assistant`). Anyone else is `not_found` (a member, Admin alone, Pastor, another cell's leader, a department leader). A second confirmation is `conflict {"assignment_id": "responded"}`. Contact attempts, the coverage queue, leader alerts and outcomes stay department-only.

### Clients

- **Mobile My cell**: under the next meeting, the programme. The member's own part leads as **You're on** with its answer (Awaiting your answer, Accepted, Confirmed by leader, Declined), "Please arrive by ..." and the instructions, and **Accept** / **Can't do it** while it waits. Other parts show the leader's name, never an answer. Before publishing: "The programme for this meeting is not published yet."
- **Mobile Home**: a **My cell** card (members with a confirmed cell and a next meeting): when the cell meets and "You're on: <part>, <time>" with the answer; **Open My cell**.
- **Staff web, Plan meeting** (published): **They said yes directly** on a part awaiting an answer opens how (Phone call, Message, In person, Other) and what they said; **Record: confirmed by leader** shows the part as Confirmed by leader.
- My duties keeps listing programme parts (Cell programme) as before.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-youre-on.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900030-900039` and removes everything it created.

### Hosted staging (parent session, then the owner)

Apply the Duties migration, then the Cells one (renamed to their hosted versions), then the verify-hosted assertions. The mobile app on the owner's phone must be rebuilt from this branch to show You're on.

### Owner manual checks (staging, phone and web, story 5.5)

Use the 5.4 setup: a published programme with a part for M (you, on your phone), one for X (no login) and one for another member N.

1. **You're on.** On your phone, **Home** shows **My cell** with "You're on: <part>, 18:00" and Awaiting your answer. Open **My cell**: the part leads with "Please arrive by" and the instructions.
2. **Accept from My cell.** Tap **Accept**: the label becomes Accepted. **My duties** shows the same.
3. **Decline from My duties.** As N (another phone or account), decline the part in **My duties**; M's My cell shows N's name for that part but no answer.
4. **Confirm by leader.** As L on staff web, **Plan**, **They said yes directly** on X's part, Phone call, "Said yes on Tuesday", **Record**: the part shows Confirmed by leader.
5. **Stale answer.** (API or two devices) answer the same part twice with the first revision: the second is refused as changed.

Record the outcome per step in `evidence-5.5/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- No cell coverage queue, contact attempts or leader alerts for cell parts yet (department-only); the leader confirms from the published programme.
- A declined part is not reassigned from the programme yet (5.6 publishes revisions).
- A member who moved to another cell keeps their old cell's parts until story 5.9 (transfers end them), and can still be confirmed there by the old leader.

## Story 5.6: programme revisions and department mismatches

Migration: `supabase/migrations/20261021104522_cells_programme_revisions.sql` (no row deletions; it backfills the published snapshot of programmes already published).
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-publish-material-programme-revisions-atomically-and-flag-dep-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.6/`.

### Changing a published programme

- `cells.save_programme` now saves a published programme too. It stays **Published**: members and Duties keep the last publish, and the staff read says `unpublished_changes: true`. A cancelled programme is still `conflict {"programme_id": "not_draft"}`.
- A published part keeps its kind: a person's part cannot become a department duty or the reverse (`parts.<i>: published_kind`); remove it and add a new part.
- `cells.publish_programme` publishes the revision in one transaction through the owner operations:

| Change since the last publish | In Duties |
|---|---|
| topic or scripture only (study notes never reach Duties) | nothing material: answers kept |
| a part's time or label, or its person | Duties' material revision: the person is asked again (a new pending revision), the earlier answer kept in history, its reminders cancelled; a swapped-out person is released |
| a part removed | its duty cancelled (its person told), or for a department part: flagged `cancelled` and the display link ended |
| a department part's time or label, or the meeting's time or venue | the department duty is **not** changed; its department gets a review flag (`time`, `label`, `place`) on its board |

- `cells.cancel_programme` also flags linked department duties `cancelled` before ending their links, and ends parts removed since the last publish.

### When the meeting changes

- The cell's leader (or an Admin who also holds the cell's scope) may **Move** a meeting with a published programme (a venue-only move too): its parts move with it (revision bumped), the staff read says `meeting_changed: true`, and the member read's programme says `meeting_changed: true` until the leader publishes. Publishing moves the parts' duties (asked again, as a material change) and flags department links `time`.
- Admin alone cannot move such a meeting, and nobody can cancel it from Cell meetings, until the programme is cancelled (`conflict {"meeting_id": "programme_published"}`). A schedule change re-times its parts but does not publish (the leader sees "The meeting changed since you published"), and never withdraws a meeting whose programme is published.

### Clients

- **Staff web, Plan meeting** (published): a warning banner when there are unpublished changes or the meeting moved, with **Publish changes**; **Change the programme** opens the editor (its button reads **Publish changes**; cancelling stays under Who is on). A kind switch says "Published with a person or with a department duty: remove this part and add a new one".
- **Mobile My cell**: after a move, "The meeting moved. Your leader is updating the programme; the times below may change."

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-programme-revisions.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900040-900049` and removes everything it created.

### Hosted staging (parent session, then the owner)

Apply the migration (renamed to its hosted version), then the verify-hosted assertions.

### Owner manual checks (staging, web and phone, story 5.6)

Use the 5.5 setup with a published programme whose parts M (your phone) and N accepted, plus a department part.

1. **Notes only.** As L, **Change the programme**, edit only the study notes, **Save draft**: "Changes not published yet". **Publish changes**: M and N still show Accepted.
2. **Material.** Change M's part start by 5 minutes and give N's part to X; **Save draft**, **Publish changes**: M's phone shows the part Awaiting again with a change notice; N's part leaves N's My duties; X's part asks X.
3. **Department.** Rename the department part and publish: the department's leader sees **Needs review** (label) on their board; the duty itself is unchanged.
4. **Move.** As L on Cell meetings, **Move** the meeting 30 minutes later: Plan meeting says "The meeting moved since you published"; M's My cell says the programme is being updated. **Publish changes**: M's part moves and asks again; the department is flagged (time).
5. **Cancel guard.** **Cancel this meeting** on Cell meetings is refused ("Programme published"); cancel the programme first.

Record the outcome per step in `evidence-5.6/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- A schedule change by an Admin moves a published programme's parts but cannot publish (Duties owner operations need the cell scope); the cell's leader publishes it.
- A cancelled programme stays cancelled when its meeting is brought back; a new programme for that meeting is not possible yet.

## Story 5.7: Cannot attend notices

Migration: `supabase/migrations/20261021111547_cells_absence_notices.sql`.
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-send-cannot-attend-notices-separately-from-duty-responses-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.7/`.

### What it is

An intention, not attendance: a confirmed member tells the cell they cannot come to one meeting, with an optional practical note (at most 280 characters). It never sets a duty answer, Excused or any attendance (there is no attendance record before epic 7). A member who holds a part still answers it separately (My cell's You're on, or My duties).

### Commands (`api.cells_command`, the member themself)

| Command | `expected_revision` | Payload | Refusals |
|---|---|---|---|
| `cells.send_cannot_attend` | `null` | `{meeting_id, note?}` | not a current member of the meeting's cell: `not_found`; one already open: `conflict {"meeting_id": "exists"}`; cancelled or started meeting: `validation_failed` |
| `cells.change_cannot_attend` | notice `revision` | `{notice_id, note?}` | someone else's, or the sender no longer in the cell: `not_found`; withdrawn: `conflict {"notice_id": "withdrawn"}`; stale: `conflict`; cancelled or started meeting: `validation_failed` |
| `cells.withdraw_cannot_attend` | notice `revision` | `{notice_id}` | as change |

Each one tells the cell's current leaders and assistants through the inbox (a withdrawal they never heard about the first time is not announced) (`cells_absence_sent` "Someone can't attend", or `cells_absence_withdrawn` "Can come after all"; generic text, no name; the link opens **Cell meetings**). A change replaces a notice still waiting.

### Reads

- `api.cells_programme` adds `absences: [{notice_id, member_id, display_name, note, sent_at, updated_at, part_ids}]` for the cell's leader and assistant only (not Pastor oversight), from current members of the cell. Deleting a member withdraws and anonymises their notices.
- `api.cells_meeting_programme` adds `my_absence` (the reader's own open notice). No member reads another's notice or note.

### Clients

- **Mobile My cell**: **Can't come?** under You're on (also before a programme is published): **I can't attend** with an optional note and **Tell my leader**; then "You told your leader you can't attend", the note, **Change the note** and **I can come after all** (asks once more). A member with a part reads "Your part is still yours until you answer it above."
- **Staff web, Plan meeting**: **Can't attend (N)** with each person's note and "Holds a part"; the part shows **Can't attend** next to its answer.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-absence.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900050-900059` and removes everything it created.

### Owner manual checks (staging, phone and web, story 5.7)

1. As M (with a part) on your phone, **My cell**, **I can't attend**, note "Travelling", **Tell my leader**: "You told your leader you can't attend"; your part still shows its answer.
2. As L, the inbox shows "Someone can't attend"; **Plan** shows **Can't attend (1)** with your name and note, and **Can't attend** on your part.
3. As M, **Change the note**, then **I can come after all**: L is told each time; the list empties.
4. As another member N, My cell shows nothing of M's notice.

Record the outcome per step in `evidence-5.7/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- Actual attendance (Present, Absent, Excused) is epic 7; a notice is never turned into one.
- The cell coverage queue does not list notices (department-only); Plan meeting shows them.

## Story 5.8: meeting records and actual leaders

Migration: `supabase/migrations/20261021115855_cells_meeting_records.sql`.
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-mark-meetings-held-and-record-actual-programme-leaders-with-c-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.8/`.

### What it is

What happened, recorded after the meeting starts and never assumed from the plan. The cell's leader or assistant records whether the meeting was held, and for a held meeting who actually led each programme part: a member of the cell, a named guest, or nobody. Every value keeps its actor and time. A correction needs a reason and keeps the earlier value. The plan (parts and planned people), every duty answer and duty outcome (4.10), and any attendance are untouched. Nothing here writes them, and nothing there writes these records.

### Commands (`api.cells_command`, the cell's current leader or assistant)

| Command | `expected_revision` | Payload | Refusals |
|---|---|---|---|
| `cells.record_meeting_held` | `null` | `{meeting_id, held}` | another cell, Admin alone, a member: `forbidden`; ahead: `validation_failed {"meeting_id": "not_started"}`; cancelled: `validation_failed {"meeting_id": "cancelled"}`; already recorded: `conflict {"meeting_id": "recorded"}` |
| `cells.correct_meeting_held` | record `revision` | `{meeting_id, held, reason}` | no reason: `validation_failed {"reason": "required"}`; same value: `{"held": "unchanged"}`; stale: `conflict` |
| `cells.record_actual_leaders` | record `revision` | `{meeting_id, parts: [{part_id, leader, reason?}]}` (1-20) | not held: `{"held": "not_held"}`; no programme or a cancelled one: `{"meeting_id": "no_programme"}`; `parts.N.part_id` `not_found`/`duplicate`; `parts.N.member_id` `not_in_cell`; a change without a reason: `parts.N.reason` `required` |

`leader` is `{"member_id": <a current member of the cell>}`, `{"name": <a guest, 1-80>}` or `null` (nobody led it). An identical value adds nothing (`data.changed` says how many parts changed). Parts left out are unchanged. A changed part supersedes its current row, which is kept with `superseded_at`, and the new row carries the reason. A substitution is a guest, or a member other than the person planned when the row was written. Held and cancelled exclude each other: cancelling needs a meeting ahead, and recording needs one that has started.

### Reads

- `api.cells_programme` adds `status`, `can_record` and `record: {held, revision, history (every value, newest first, with reason and who), actual (current rows with earlier rows and reasons)}`. The leader, assistant and Pastor oversight read it. An Admin-only reader does not.
- `api.cells_meetings` adds `recent` per cell: meetings that started in the last 28 days, newest first, each with `status`.
- `app.cells_meeting_reference(meeting_id)` is the internal reference for later owners (see contracts-and-owner-seams.md).
- Members read nothing new (recaps are epic 7).

### Clients (staff web, and mobile through the same pages)

- **Cell meetings**: "N recent meetings not recorded" beside the cell's name; **Last 4 weeks** with Held, Not held, Not recorded or Cancelled, and **Record** or **Open**.
- **Plan meeting**, once the meeting has started: **After the meeting**. **Yes, it was held** or **It didn't happen**, then **It wasn't held** or **It was held after all** (with a reason). **Who led each part** offers **N parts were led as planned** (one click, explicit) and, per part, **Record** or **Change** (a member of the cell, **Someone else (a guest)** or **Nobody led it**; a change asks why). Each part shows its planned person, its current value (Led by, Stood in, Nobody led it, Not recorded), the reason and earlier values.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-meeting-records.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900060-900069`, moves its meetings into the past directly in the database (the stand-in for time passing), and removes everything it created.

### Owner manual checks (staging, web and phone, story 5.8)

1. As L on staff web, after a SYNTHETIC meeting with a published programme has started: **Cell meetings** shows it under **Last 4 weeks** as Not recorded. **Record**, then **Yes, it was held**: Held, with your name.
2. **2 parts were led as planned** (or per part): Led by the planned person. On one part, **Change**, choose another member, give a reason, **Save**: "Stood in", with the reason and the earlier value.
3. **My duties** for the planned members still shows their own answers. Nothing changed there.
4. As the leader of another cell, the meeting's page is refused. A cancelled meeting has no **After the meeting**.
5. On your phone, as L, open the same Plan meeting page: the same record shows.

Record the outcome per step in `evidence-5.8/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- Attendance (Present, Absent, Excused, visitors) is epic 7. A held meeting records no attendance.
- A duty's Completed outcome (4.10) is never set or suggested from an actual leader record (the ticket's unknown, left to epic 7 and the leader).
- No notification is sent for a record. An unrecorded meeting only shows on Cell meetings.
- Transfers (story 5.9) leave meeting records and actual leaders as they are: they are past facts.

## Story 5.9: transfers, handovers and deletion

Migration: `supabase/migrations/20261021122802_cells_transfer_effects.sql`.
Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-apply-cell-transfer-removal-and-deletion-to-programmes-and-c-plan.md`.
Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.9/`.

### What a transfer does to the old cell

A transfer is `cells.confirm_request` for a member who already has a cell. It is the only way a membership ends (2.6), and it ends the member's old-cell work in the same transaction (one failing step rolls the transfer back):

- **Access:** the old cell's programme, venue and meeting reads are refused at once, because they check the current membership. The new cell opens at once.
- **Scope:** meetings of the old cell that have not started. A meeting already under way keeps its plan, duties and notices.
- **Programme parts:** the member leaves every part they are planned for (draft and published), so each becomes a gap. The published projection stops naming them only where they held the published duty: someone else's published name stays even when an unpublished change gave the part to the member. Each changed programme takes a new revision, so a leader's open editor conflicts instead of saving the member back. The leader publishes again when they have someone.
- **Cell duties:** the member's current assignments on the old cell's future published parts end through Duties (`app.duties_owner_vacate_member`, a Duties contract change, see contracts-and-owner-seams.md). Their status is `superseded` and `vacated`, the position is unfilled, their jobs are cancelled, and they get **Duty released**. Planned (draft) positions are cleared. Any answer ends, an accepted one included. The old cell's leader can no longer confirm them on it (the 5.5 finding).
- **Notices:** their open Cannot attend notices for the old cell's meetings still ahead close (`withdrawn`, `withdrawn_reason` `left_cell`, an audit row with the transfer's actor). A notice still waiting for the leaders is cancelled, and nothing is announced.
- **Leaders:** the old cell's current leader and assistant get **A part needs someone** (`cells_programme` / `cells_part_vacated`, generic, link **Cell meetings**), once per published programme that lost its person. A draft-only change tells nobody. The notice is actionable while a part of the published programme has nobody and the meeting is on and ahead. Without the Q2 policy no notice is planned, and the transfer still completes.
- **The past stays:** started meetings keep their plan, duties and actual leaders (5.8).

### Handover: a cell's last leader

`app.cells_report_handover` (registered with Identity, 2.10/4.16) reports `cell_leader` (subject: the cell, last responsible) when the member is the last approved leader or assistant the app can reach of an active cell with a published programme for a meeting ahead.

- Deactivating them is refused `handover_required`, and so is revoking that scope.
- A deletion or an unlink records the obligation as pending. **Admin cells** then shows **Needs a leader: a programme is published ahead** on the cell.
- Once the cell has a reachable leader or assistant again, **Mark handover done** sends `cells.resolve_handover {cell_id}` (Admin, cell revision). If there is still no reachable leader, it is refused `conflict {"cell_id": "leader_required"}` ("Still no leader"). With nothing pending it is refused `validation_failed {"cell_id": "no_handover"}`.

### Deletion

`app.cells_erase_member` covers meetings, notices, programmes, meeting records and actual leaders (5.1-5.8). Story 5.9 adds no personal data. A moved member's deletion check answers zero.

### Clients

Programme, venue and record state lives in memory only, never on disk (AD-13). A refused read replaces it with the refusal, so the old cell's meeting, venue and programme leave My cell, Home and Plan meeting on the next read after the move. Widget tests: `cell_youre_on_test.dart` (story 5.9) and `cell_transfer_test.dart`.

### Local runs

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-transfer.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900070-900079` and removes everything it created.

### Owner manual checks (staging, phone and web, story 5.9)

1. As M with an accepted part and an open **Can't come?** notice in `SYNTHETIC Shikoswe Cell`, have an Admin move M to `SYNTHETIC Estates C5/C7 Cell` (Admin cells: request and confirm).
2. On M's phone, pull to refresh **My cell**: Estates shows. The Shikoswe meeting, venue and programme are gone. **My duties** no longer lists the part. The inbox has **Duty released**.
3. As Shikoswe's leader, the inbox shows **A part needs someone**. **Plan** shows the part as a gap and the notice gone.
4. With Shikoswe's assistant removed, removing its leader is refused ("hand over first").
5. After a different reviewer, repeat steps 1-2 on the other client (web and mobile) (the epic's external check before 5.12).

Record the outcome per step in `evidence-5.9/owner-check.md` (pass/fail, device, browser; no numbers, ids or keys).

### Known limits

- There is no removal from a cell without a new cell (a later Cells feature). Deactivation and deletion end the member's duties through Duties (4.12) but leave the cell membership and plan names to the deletion hook.
- The Duties department coverage queue does not list vacated cell parts (department-only). The Cells notice and Plan meeting show them.

## Story 5.10: runbooks and the synthetic cell pilot

There is no migration and no client change.
- Plan: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-write-the-programme-runbooks-and-run-the-synthetic-cell-pilot-plan.md`.
- Evidence: `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.10/`.

### The guides

[cells-guides.md](cells-guides.md) holds the guides in plain language, in the order the work is done: Admin; cell leader and assistant; what members see; and the owner pilot. Each task links back to its story section here. Keep the two files in step: when a story changes a screen or a rule, update its section here and the guide task that names it.

### The pilot rehearsal (`tools/identity-e2e/cells-pilot.mjs`)

| Step | What it proves |
|---|---|
| P10 | A published programme asks each person: M and O in My duties, and X (no login) on the leader's board. |
| P20 | The meeting moves 30 minutes and the leader publishes again. M's earlier Accept becomes `superseded` and a new pending answer replaces it. Members are told the meeting changed. |
| P30 | M's Cannot attend notice leaves M's answer and its revision unchanged. There is no attendance table. The leader sees the part warning. |
| P40 | X is Confirmed by leader (provenance `leader`). |
| P50 | After the meeting it is recorded as held. X stood in for M, which shows as a substitute in the canonical reference. The assistant corrects another part to nobody, with a reason. The plan and M's answer are unchanged. |
| P60 | There is no chat table or function, and nothing in Cells, Duties, Follow-ups, Notifications or Identity depends on the planned chat module. O reads no leader-only text and cannot open the staff programme. |

```bash
npx supabase db reset
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells-pilot.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/cells-pilot.test.mjs
```

The run uses fictional numbers `+44 7700 900080-900089`. Leader-only texts start with `SYNTHETIC leader-only`, so any leak can be detected. It removes everything it created.

### Staging

The staging pilot is run by the owner, using the synthetic staging accounts (cells-guides.md, Owner pilot on staging). No script runs against staging from here. Results go in `evidence-5.10/owner-pilot.md`.
