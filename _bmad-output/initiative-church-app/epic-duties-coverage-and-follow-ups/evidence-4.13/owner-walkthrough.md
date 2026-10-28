# Story 4.13 owner walkthrough (HITL, staging web and APK)

Owner: Israel. Batched to the end of milestone 2. The steps are the same as in `docs/runbooks/duties-guides.md`, "Owner walkthrough on staging (HITL)". Use synthetic people only. Write **pass** or **fail** and a short note per step; never write a number, id, key, real name or the text of a note or reason.

| Run detail | Value |
|---|---|
| Date (church time) | ______ |
| Staff web build / browser | ______ |
| APK build | ______ |
| Phone model / Android version (L) | ______ |
| Phone model / Android version (M) | ______ |
| Pilot rehearsal run by the parent session first (evidence file name) | ______ |

**You need:** the staff web and the APK built against staging; Admin A; leader L with the APK and the staff web; members M (APK) and O (APK or web) with the app; X without a login, with a SYNTHETIC household number.

| # | Step | What you should see | Result | Notes |
|---|---|---|---|---|
| 1 | **Department.** As A: **Departments**: `SYNTHETIC Preaching Rota` (add it if missing). Give L **Leader**; **Add a member** M, O and X. | **Role given**, **Member added** three times; X shows "no login". | ______ | ______ |
| 2 | **Quarterly rota.** As L, staff web **Rota** > **New rota**: `Sunday service`, every 1 week, the next Sunday at least three days away to 12 weeks later, `10:00`, positions `Preacher, Reader`. Plan the first Sunday (Preacher M, Reader X) and the second Sunday (Preacher O). **Publish 26 draft slots** at the church default. | The confirmation says 3 people are asked and 23 positions stay unfilled; then 13 **Published** rows. | ______ | ______ |
| 3 | **Reminders delivered.** On M's phone, wait about a minute; **Inbox** > **New duty assigned** > **Open**. As L, staff web **Duties**. | M's item opens the duty with its answer-by time (church default). X's position shows **Needs contact**. | ______ | ______ |
| 4 | **Answers.** M: **Accept** with a note. O: **Can't make it** with a note. | L's board shows **Accepted** and **Can't make it** with both notes; L's Inbox shows **Duty declined**, whose **Open** opens **Coverage**. | ______ | ______ |
| 5 | **The gap.** As L, **Coverage**, **From** = the first Sunday, 31 days, **Show**. | Unfilled positions; O **Declined**; X **Awaiting response** with "no login: contact them directly", **Needs contact** and the labelled household number. | ______ | ______ |
| 6 | **Direct contact.** On L's phone: **Open coverage** > X's card > **Call** (do not call; go back). **Record contact attempt**: Phone call, Will answer, a SYNTHETIC note, next follow-up tomorrow. | The dialler opened with the number; **Contact attempt recorded**; **Open the follow-up task** shows the task. | ______ | ______ |
| 7 | **Confirmed by leader.** On X's card: **Confirmed by leader** > Phone call > a SYNTHETIC reason > **Record Confirmed by leader**. | The card reads **Confirmed by leader** with L, the time and the reason (not "Accepted"); staff web **Duties** shows **Confirmed by leader**; the follow-up task is closed. | ______ | ______ |
| 8 | **Short-notice Sunday.** As L, **Publish a duty** for M starting in about three hours (a Saturday evening or Sunday morning if you can), **Answer by** empty. Then M accepts. | M gets one **New duty assigned** (not two); the duty reads **Short notice: please answer now**; L gets **Short-notice duty**; the position shows **Short notice** and **Needs contact**; after M accepts, **Accepted**. | ______ | ______ |
| 9 | **No stale reminder.** As L, publish `Sunday reading` for M two days ahead with **Answer by** about 20 minutes from now and only the reminder "at the answer-by time". Within a minute: **Change this duty** > **Who** = O, the same answer-by time, save. Wait until 2 minutes after the answer-by time. | M got **Duty changed** ("no longer assigned to you") and **no Duty answer needed**; M's earlier **New duty assigned** for it says **This reminder is out of date**; O got **New duty assigned** and then **Duty answer needed**. | ______ | ______ |
| 10 | **Nothing private for a non-leader.** As M on the phone: **Duties**, **Inbox**. As O on staff web: the sidebar, then open `/duties/coverage`. As A: **Coverage**. | M sees only M's duties: no note of O, no contact note, no Confirmed by leader reason, no number, no **Coverage**. O has no **Duties** board, **Rota** or **Coverage** (the page is refused). A sees **Gaps across the church** without numbers, **Call**, notes or reasons. Every Inbox item reads only its fixed text. | ______ | ______ |
| 11 | **Clean up.** Ask the parent session to remove the walkthrough's rows (duties.md, story 4.9, step 10, with the 4.12 additions). | Done by: ______ | ______ | ______ |

**Verdict:** ______ (the loop works for a quarterly rota and a short-notice Sunday duty; X's confirmation is labelled Confirmed by leader; no stale reminder reached M; no step showed private notes to a non-leader)

**Follow-ups raised:** ______
