# Story 6.11 external check (independent review)

The ticket's external check: an independent reviewer repeats the capacity race and the
deactivation release (before entry 17), with special attention, per the coordinator's brief, to
RSVP names reaching only organisers and Admins and to capacity holding under concurrent RSVPs.
The entry 17 suite reruns the RSVP deletion case on staging after the owner applies the `_rows`
file.

## Who reviewed what

1. **Reviewer A** (separate agent, fresh context) read the change and wrote its own live probe
   (`independent-review-run*.jsonl` here) and a rolled-back SQL script. An account usage limit
   stopped it before it ran them and erased its written static findings; it reported one low
   finding (below) and confirmed that the Duties `.ics` text rules are byte-identical to the 4.5
   builder (75/75 client tests in `event_rsvp_test.dart` and the three duties test files).
   The build agent then ran Reviewer A's probe and SQL script unchanged on the local stack (the
   only edit: a copy with a longer lock hold for one interleaving, see run 2).
2. **Reviewer B** (separate agent, fresh context, read-only) repeated the static review of the
   three focus areas.

## Results

### Names privacy (Reviewer B): no defect

Names are produced only by `app.content_staff_event_rsvps`, after the live-access and
event-editor check and then Admin or active-organiser-who-still-edits-events. Public reads, the
member's own read, the editors' list, command outcomes, stored receipts, error details and the
mobile offline snapshot carry counts or the caller's own row only. Low finding: the organiser
command checked `not_editor` without locking the named members' grants, so a revocation at the
same instant could leave an active organiser row for a member without an event role (names stay
hidden; they would return only if the role were granted again). **Fixed:** the grants are now
share-locked before the check.

### Capacity (Reviewer B static; Reviewer A probe): no defect

An RSVP becomes `going` only under the event's item row lock; the count is a new statement after
the lock under READ COMMITTED. Replays return the stored receipt. Cancel, release and erase only
lower `going`. `going` exceeds `rsvp_capacity` only when an editor publishes a lower capacity
(nobody is removed; the event reads Full until places free), as designed.

Probe (`independent-review-run1.jsonl`): 12 members racing for 1 place, three rounds: exactly 1
`going` and 11 `full` each time; 12 RSVPs queued behind a held event-row lock: 1
`going`, 11 `full`; a cancel racing two RSVPs, six repetitions (half behind a held lock): never
more than one `going`; a capacity cut to 2 published ahead of 8 queued RSVPs: 2 `going`, 6
`full`; 4 RSVPs that ran just before a cut from 5 to 3 took places up to the capacity in force
when each ran (5 going), after which the event read Full and a newcomer was refused until going
fell below 3 (the plan's no-bumping rule); a replay after a cancel returns the stored answer and
changes nothing, a different body with the same request id is `conflict`.

### Lifecycle and erasure (Reviewer B static; Reviewer A probe and SQL): no defect

Deactivation and a deletion request release `going` RSVPs of events that have not started and
keep those of events under way; a login hold keeps the RSVP; an RSVP racing the member's own
deactivation either commits first and is then released, or waits at the member-row lock and is
refused (`forbidden`). Run 1 observed the lock wait for interleaving A; run 2 (8 s hold) for
interleaving B; the outcomes were correct in all six executions (A, B and C, twice). The
remaining FAIL lines in the two runs are the probe's own timing assertion (it looks for the lock
wait within a 3 s hold), not a wrong outcome.

Rolled-back SQL script, 30/30: the login hold keeps the RSVP; the member's own deletion request
releases the future RSVP, keeps the started one, ends their organiser rows and refuses a later
RSVP; with the main migration's stub the real `erase_owners` step fails closed (`unavailable`,
`rows_migration_missing`, nothing of Content changed); with the `_rows` body the step completes,
every owner's check answers 0 and no `app.content_*` table keeps the member or account id, while
other members' rows are kept.

### Other findings

| Finding | Severity | Action |
|---|---|---|
| A rare race (a retention claim between the poster check and the attachment) reports the field as `image_asset_id` (the shared attach helper's key) | low | Fixed: the save locks the upload row and checks it again under the lock |
| The organisers dialog pre-ticked an organiser who no longer edits events, so Save was refused with a generic notice | low | Fixed: such organisers are listed unticked and disabled ("saving removes them"); a refused list has its own notice |
| After an editor turns RSVP off, a member who was going cannot cancel from the app until RSVP is turned back on | low | Deferred (plan `deferred`): the place is not counted publicly while RSVP is off; showing an answer section for events without RSVP would add a member read to every event detail |
| A replay of `content.set_event_organisers` needs only event-editor capacity | informational | Kept: the stored outcome holds ids and revisions only |
| `content.cancel_rsvp` works on a withdrawn or archived event that has not started | informational | Intended: it only frees a place |

Verdict: PASS after the fixes (no high or medium finding; three lows fixed, one deferred).
