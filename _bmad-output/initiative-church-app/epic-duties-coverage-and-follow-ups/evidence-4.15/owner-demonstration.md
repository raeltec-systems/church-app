# Duties and Follow-ups: owner demonstration on staging (story 4.15, HITL)

For Israel, on staging `tmurpotfluignacfueki`, with the 4.15 builds (`builds.md` has the file
names and sha256). About 60 minutes. Synthetic data only: names start with `SYNTHETIC `, numbers
from the fictional `+1 202 555 0100-0199` range. Write **pass** or **fail** and a short note per
step; never write a number, id, key, real name or the text of a note or reason. Screenshots are
welcome if they show no password.

The automated closing suite already ran every path below through the API
(`tools/identity-e2e/duties-staging-suite.mjs`, run on staging by the parent session; its summary
goes next to this file as `staging-suite-summary.md`). This walkthrough is the human check of the
two clients.

| Run detail | Value |
|---|---|
| Date (church time) | ______ |
| Staff web build / browser | ______ |
| APK build (sha256 first 8) | ______ |
| Phone model / Android version (L) | ______ |
| Phone model / Android version (M) | ______ |
| Closing suite on staging run by the parent session first (evidence file name, verdict) | ______ |
| 4.13 pilot rehearsal run first (evidence file name, verdict) | ______ |

## Before you start

1. **Install the APK** `church-app-4.15-staging-arm64.apk` on each Android phone (remove an older
   staging build first if Android refuses the update). It is a release build signed with the debug
   key, for testing only.
2. **Open staff web.** Serve the folder `staff-web-4.15-staging` from your computer, for example
   `python3 -m http.server 8080 --directory staff-web-4.15-staging`, and open
   `http://localhost:8080` in Chrome.
3. **People.** The same synthetic people as the 4.13 walkthrough: Admin **A**; leader **L** of
   `SYNTHETIC Preaching Rota` with the APK and staff web; deputy **P** of the same department
   (staff web); members **M** (APK) and **O** (APK or web); **X** with no login and a SYNTHETIC
   household number; and **K**, the only leader of a second synthetic department (ask the parent
   session to set up P and K if they do not exist; it uses the Admin through the API).

## A. The 4.13 walkthrough (the whole loop)

Do steps 1-10 of `evidence-4.13/owner-walkthrough.md` with the 4.15 builds and record the results
in **that** file (it is still pending): department, quarterly rota, reminders delivered, answers,
the gap, direct contact, Confirmed by leader, short-notice Sunday, no stale reminder, nothing
private for a non-leader. Then come back here.

| # | Step | Result | Notes |
|---|---|---|---|
| A1 | 4.13 steps 1-10 done, results in `evidence-4.13/owner-walkthrough.md` | ______ | ______ |

## B. The owner's decisions built in story 4.16

| # | Step | What you should see | Result | Notes |
|---|---|---|---|---|
| B1 | **Mismatch notice.** As L, staff web **Duties**: give one upcoming duty of the Preaching Rota a linked event (ask the parent session; it links a SYNTHETIC event and changes it with the SQL below). Wait about a minute. | L's and P's Inbox show one **Duty needs review** each (generic text only). **Open** goes to **Duties to review**, listing only that duty with **Needs review**. **Mark reviewed** clears it; the list says **Nothing needs review here.** M, O and A got no such notice. | ______ | ______ |
| B2 | **Vacancy reason.** As A, staff web **Departments** > Preaching Rota > O > **Remove from department** (O must have an upcoming duty there; give O one first if needed). | A sees **Removed from the department**. As L (phone **Open coverage**) and P (staff web **Coverage**): O's position reads **Needs a new person** with **Reason: Removed from the department**. As A (**Coverage**, "Gaps across the church"): the position is listed **without** a reason. As K (the other department): the position is not listed at all. Then **Add a member** O back. | ______ | ______ |
| B3 | **Hand over first.** As A, staff web **Roles & access** (or **Departments** > K's department): remove K's leader role. | **Hand over first**: "This department has no other leader or deputy who can use the app ... Nothing was changed." K still leads it. Give another synthetic member who uses the app the deputy role there, then remove K's role: it works. Give K the leader role back and remove the stand-in. | ______ | ______ |
| B4 | **Unlinking is never refused.** Optional (the suite covers it): ask the parent session for the result of suite check S95 instead. | S95 passed in the closing suite summary. | ______ | ______ |

Prepared by the parent session for B1 (staging, SYNTHETIC rows only; owner operations have no
client route, and no client field sets an event):

1. SQL: `insert into app.fixture_events (title) values ('SYNTHETIC 4.15 demo event') returning event_id;`
2. API as L: `duties.revise_duty {"occurrence_id": "<the duty L chose>", "event_ref": "<event_id>"}`
   (answers `change: "reference"`; nothing is re-asked).
3. SQL inside the synthetic Admin's session claims (the 4.11 owner call, as `ownerCallSql` in
   `tools/identity-e2e/duties-decisions.mjs`):
   `select app.fixture_event_changed('{"event_id": "<event_id>", "changed": ["time"]}');`

## C. Visible disabled gates and refusals

Staging opens the church-policy gates with labelled TEST FIXTURE values, so the **production**
disabled state is checked after promotion (`docs/runbooks/production-promotion-duties.md`, step
7). On staging, check the refusals the apps must show clearly:

| # | Step | What you should see | Result | Notes |
|---|---|---|---|---|
| C1 | As M (phone): **Duties** tab, then try to open `/duties/coverage` and `/duties/leader` (staff web as O). | M and O see only **My duties**; Coverage, Rota and the board say the page is for department leaders and deputies (refused, nothing shown). | ______ | ______ |
| C2 | As A (Admin only, no department role): staff web **Coverage**, then open a started duty and try to record an outcome. | Coverage shows the operational view (no numbers, no **Call**, no notes or reasons). Recording an outcome is not offered or is refused: outcomes are the department's leaders'. | ______ | ______ |
| C3 | As K (another department's leader): staff web **Coverage** for the Preaching Rota (filter by it). | Refused: K sees only K's own department. | ______ | ______ |
| C4 | **What production will show** (read, nothing to do on staging): the table "What production shows before any approval" in `production-promotion-duties.md`. Confirm it matches what you expect to see in production before you approve each gate. | You agree with each row, or note what to change. | ______ | ______ |

## D. Clean up

| # | Step | Result |
|---|---|---|
| D1 | Ask the parent session to remove the walkthrough's rows (duties.md story 4.9 step 10 with the 4.12 additions; the B1 event and flag go with their occurrence). | Done by: ______ |

**Verdict:** ______ (the loop works on both clients; the review notice, the vacancy reason and
Hand over first behave as decided on 2026-10-15; nothing private reached a member or the Admin
role alone)

**Follow-ups raised:** ______
