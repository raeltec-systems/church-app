# Epic 5 external check: independent review (LOCAL stack)

Reviewer: an independent agent session that did not write this code. Date: 2026-10-21. Branch: story/5.8-meetings-held (HEAD 80c4b47).

Scope: the safe-projection, material-revision and old-cell access cases, on the server and in the shared client logic (`client_core` serves both the staff web and the mobile app).

**Staging was not rerun.** That needs the owner's synthetic staging accounts, which this session does not have. The owner still has to do the staging steps (cells-meetings.md 5.9 step 5 and the cells-guides.md pilot).

## 1. What I ran

| Run | Result |
|---|---|
| pgTAP: `cells_programme_publish`, `cells_programme_revisions`, `cells_transfer_effects`, `cells_youre_on` | 4 files, **164/164 pass** |
| E2E `cells-programme-publish.mjs` | **12/12 pass**, cleanup `users_left` 0 |
| E2E `cells-programme-revisions.mjs` | **6/6 pass**, cleanup 0 |
| E2E `cells-transfer.mjs` | **7/7 pass**, cleanup 0 |
| E2E `cells-pilot.mjs` | **8/8 pass**, cleanup 0, `leader_only_text_seen` false |
| Flutter `cell_programmes`, `cell_youre_on`, `cell_transfer`, `cell_meeting_records` | **58/58 pass** |
| My own pgTAP probe (temp file outside the repo, `begin ... rollback`) | 60 assertions plus diagnostics. 3 assertions "failed" as false positives: my leak detector also flagged the member's **own** cell venue, which members are allowed to see. Nothing else failed. |

The phone switch was turned on before the E2E runs and off afterwards (`GOTRUE_EXTERNAL_PHONE_ENABLED=false` confirmed). Nothing was committed and no repo file was edited.

Probe set-up:
- fictional phones +1 202 555 0141-0152, all names SYNTHETIC;
- marker strings planted so that a leak would show up in any read:
  - study notes `LEAKMARK_NOTES`;
  - draft text `LEAKMARK_DRAFT`;
  - the confirm-by-leader reason `LEAKMARK_REASON`;
  - another member's Cannot attend note `LEAKMARK_NOTICE10`;
- venue `SYNTHETIC 77 Shikoswe Road`.

The probe impersonates each role with `set local role authenticated` and JWT claims, the same way `cells_transfer_effects_test.sql` does.

## 2. Probes

### Safe projection

| # | Probe | Result | Evidence |
|---|---|---|---|
| S1 | Member (4) reads `api.cells_meeting_programme` | PASS | No markers. Top-level keys: `yours, meeting, programme, my_absence`. Programme keys: `parts, topic, revision, scripture, meeting_id, programme_id, published_at, meeting_changed`. Part keys: `label, leader, ends_at, part_id, starts_at, department`. No other member's id and no answer words (`accepted`, `pending` and so on). The member's own venue is shown, as intended. |
| S2 | Member reads a draft | PASS | `programme: null`; no draft text. |
| S3 | `api.cells_my_cell` and `api.duties_my_duties` as a member | PASS | No markers; only the member's own cell venue. |
| S4 | Member calls the staff reads (`cells_meetings`, `cells_programme`, `cells_leader_queue`) | PASS | All three return `PT403 forbidden not_granted`. |
| S5 | Member of another cell | PASS | `cells_meeting_programme`, `cells_programme` and `cells_private_fixture_read` all return 403. My cell shows no leak. |
| S6 | Pending applicant | PASS | Both programme reads return 403. My cell shows `primary: null, meetings: null`, plus the applicant's own open request. |
| S7 | Admin alone | PASS | `cells_programme` returns `view=metadata`. No notes, drafts, reasons, notices or venue in `cells_programme`, `cells_meetings` or `cells_admin_overview`. The member read returns 403. |
| S8 | Pastor | PASS (by design) | `cells_programme` returns `view=full` with the study notes and the draft, but venue `null`, `absences: []` and no reason. `cells_meetings` and the member read return 403. Pastors seeing drafts is the documented design (cells-guides.md:28). |
| S9 | Leader who is not a member | as documented | The member read returns 403. |

Exposure surface: PostgREST exposes only the `api` schema (`PGRST_DB_SCHEMAS=api`). `authenticated` has no grants on `app` tables except `platform_status`.

### Material revision

Each person part was snapshotted as `position:member:assignment:answer` before and after each publish.

| # | Change, then publish | Result | Evidence |
|---|---|---|---|
| R1 | Notes and topic only | PASS | Every assignment and answer identical. No department flag; the department duty's revision is unchanged. |
| R2 | Part 1's time only | PASS | Part 1 got a new pending assignment. Parts 2 and 4 kept the same assignment and answer. The department was not flagged. |
| R3 | Person swap on part 2 | PASS | The new person is asked (pending); the old person has no current assignment. Parts 1 and 4 untouched. |
| R4 | Label of person part 4 | PASS | Only part 4 is asked again (label counts as material, as the spec says). |
| R5 | Venue-only move | PASS | All person parts are asked again (place affects every part) and their occurrence location becomes the new venue. The department gets `{place}`; its duty revision, time and location are unchanged. |
| R6 | Meeting moved 30 minutes later | PASS | All person parts are asked again. The department gets a `time` flag. Department revision and start time are unchanged, with 1 slot. |

### Old-cell access

I moved two people to Estates through `cells.confirm_request` (Admin):
- member 4, who had an accepted part and an open notice;
- member 12, a Shikoswe member who also holds the Shikoswe assistant scope.

| # | Probe after the move | Result | Evidence |
|---|---|---|---|
| O1 | Reads | PASS | The member read returns 403 for the published meeting, the draft meeting and the past meeting. My cell has no old cell id and no old venue. My duties no longer lists the vacated assignment. The one remaining listing is the past meeting's duty, a fixture artefact: I shifted that meeting's Cells time back but not its Duties time (confirmed by occurrence id). |
| O2 | Respond to the old duty | PASS | The assignment is `superseded:vacated`. `duties.respond` on it returns `conflict`. |
| O3 | Notices | PASS | The notice is `withdrawn:left_cell`. Withdraw returns `not_found`. Sending a new notice for an old meeting (published or draft) returns `not_found`. |
| O4 | Record or plan the moved member | PASS | `record_actual_leaders` returns `validation_failed {"parts.0.member_id":"not_in_cell"}`. `save_programme` with them returns `{"parts.0":"assignee_not_in_cell"}`. |
| O5 | Plan and projection | PASS | The part is a gap and the projection's `leader` is null. |
| O6 | Moved member who still holds the old cell's assistant scope | **FAIL** against the runbook claim | The member read returns 403. But `api.cells_programme` returns `view=full, can_edit=true`, including the study notes, another member's Cannot attend note and the venue. `api.cells_meetings` still lists the old cell with its venue. `cells.save_programme` on the old cell's programme was **accepted**. The grant is still active (count 1). |
| C | Client | PASS | `CellsController._reload` (`packages/client_core/lib/src/application/cell_controllers.dart:197-214`) replaces `result` with the refusal or failure, so no data survives a refusal. Programme providers are `autoDispose.family` keyed by meeting (lines 790-799), and all state is rebuilt on an `accountGenerationProvider` change. The only things stored on the device are the Auth session (secure storage, or `sessionStorage` on web) and the recovery verifier. No shared_preferences, files or caches in the cells code. |

## 3. Findings

### 1. Medium: a transfer leaves the old cell's leader or assistant scope in place

The moved person keeps full private access to the old cell and can still edit it.

Where:
- `supabase/migrations/20261021122802_cells_transfer_effects.sql:611-693`: `cells_confirm_request` and `cells_transfer_effects` neither revoke nor flag the scope.
- Line 444 of the same file (`g.member_id <> p_member`) even skips telling the moved person, which shows the case was foreseen.
- Access comes through `20261007075946_cell_membership.sql:233` (the scope branch of `cells_member_has_private_access`) and `20261021084446_cells_programmes.sql:131` (`cells_programme_capacity`).

Scenario: the Shikoswe assistant, who is also a Shikoswe member, is moved to Estates. They still read Shikoswe's study notes, members' Cannot attend notes and the venue, and can save its programme, until an Admin separately revokes the scope.

Why it matters: `docs/runbooks/cells-meetings.md:681` says old-cell reads "are refused at once, because they check the current membership". That is true only for people without a scope.

Owner decision needed, one of:
- revoke or block the scope on transfer (a handover);
- or state that leadership is independent of membership and add an Admin warning.

### 2. Low: a past meeting cannot credit a moved member as its actual leader

`20261021115855_cells_meeting_records.sql:486` requires current membership, even for a meeting that started before the move.

Scenario: M leads on Tuesday and moves on Wednesday. When the leader records the meeting on Thursday, recording M is refused `not_in_cell`, so M has to be recorded as a guest. Recaps and reports would then attribute that part wrongly.

### 3. Info: over-flagging of department links on a meeting time change

`20261021104522_cells_programme_revisions.sql:766` flags every department link `time` whenever the meeting's start or end changes, even when that department part's own time does not change. I found this by reading the code; it was not exercised by a test. It errs on the side of review, so it is not a safety issue.

### 4. Info: Pastors read drafts and notes for every cell

This is documented. The venue and notices are withheld from them.

## 4. Verdict

| Area | Verdict |
|---|---|
| Safe projection | **PASS** |
| Material revision | **PASS** |
| Old-cell access | **FAIL**: PASS for ordinary members on server and client, but a moved leader or assistant keeps private read and edit access to the old cell (finding 1). It turns to PASS once the owner decides and the code or runbook is changed to match. |

Staging reruns are still outstanding and need the owner's accounts.


## Triage (parent session, 2026-10-21)

Fixed in `supabase/migrations/20261021132636_cells_external_check_fixes.sql`. Staging gets it under its hosted version: see `staging-verify.md`.

1. **Medium, fixed (fail closed):** a transfer of a member who leads or assists their current cell is now refused with `conflict {"member_id": "leads_current_cell"}`.
   - An Admin removes that role first. Identity's revocation runs the 5.9 handover check, so the last leader of a cell with a programme ahead is never removed silently.
   - The clients say "Leads their cell: remove that role first".
   - The other choice is to end the role automatically on transfer. That is the owner's to make later. The runbook claim (old-cell reads refused at once) now holds, because a person cannot be both moved away and leading.
   - pgTAP: moving the assistant is refused and nothing moves.
2. **Low, fixed:** an actual leader must have been a member of the cell when the meeting started, not necessarily now. A member who led and then moved is credited correctly.
   - pgTAP: the moved member is credited on a past meeting.
   - The time-travel tests and E2Es now also backdate memberships, the stand-in for time passing.
3. **Info, accepted:** a meeting time change flags every linked department duty `time`, even when that part's own time is unchanged. It over-flags, which is safe: the department reviews it and clears the flag.
4. **Info, accepted:** Pastor oversight reads drafts and notes of every cell, as documented in 5.3.

The reviewer's verdict above predates these fixes. The fixes are covered by the parent session's pgTAP and E2E reruns (`external-check-fixes-verify.txt`), but the old-cell access area has not been re-reviewed independently. That rerun is due before promotion, with the staging rerun. A staging rerun needs the owner's staging accounts and is part of the owner's 5.12 demonstration.
