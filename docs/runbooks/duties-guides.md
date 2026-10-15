# Duties guides for leaders, deputies and Admins (story 4.13)

These guides are for the people who run duties at the church: department **leaders**, their **deputies** and **Admins**. They follow the order you do the work in. Each task says where to go, what to press and what you should see. The technical detail for maintainers stays in [duties.md](duties.md), story by story; each task links to it.

Until the owner approves personal data (Q4), everything on staging is synthetic: department names start with `SYNTHETIC `, people are synthetic and numbers are fictional. Never type a real name, number, note or reason into staging.

All dates and times are **church time** (Africa/Lusaka), whatever your phone or computer is set to.

**Contents**

- [Words used here](#words-used-here)
- [Guide 1: department leader and deputy](#guide-1-department-leader-and-deputy)
- [Guide 2: Admin](#guide-2-admin)
- [Guide 3: duty reminder problems](#guide-3-duty-reminder-problems)
- [The synthetic pilot rehearsal](#the-synthetic-pilot-rehearsal)
- [Owner walkthrough on staging (HITL)](#owner-walkthrough-on-staging-hitl)

## Words used here

| Word | Meaning |
|---|---|
| Department | A team that serves, such as `SYNTHETIC Preaching Rota`. An Admin creates it. |
| Leader, deputy | The people who run a department. A deputy can do everything a leader can. An Admin gives the role. |
| Member with the app | Signs in on the phone or the web; gets duties and reminders in the **Inbox**. |
| Member without a login | An Admin record ("no login"). The app cannot reach them: the leader contacts them directly. |
| Answer-by time | When the member should accept or say they can't make it. Leave it empty for the **church default** (14 days before for a duty a month or more away, 48 hours before for one 3 to 30 days away, otherwise 24 hours before). |
| Short notice | A duty given with less than an hour left to answer by default. The member is asked to answer now and the leaders are alerted. |
| Needs contact | The app cannot reach this person, or the duty is short notice: contact them yourself. The app never says why (for example, it never says someone is on hold). |
| Coverage | The leader's list of what still needs attention: unfilled, waiting, overdue, declined, needs contact. |
| Confirmed by leader | You recorded that the member agreed in person or by phone. It is shown as **Confirmed by leader**, never as the member's own answer. |

## Guide 1: department leader and deputy

You see **Duties**, **Rota**, **Coverage** and **Outcomes** in the staff web sidebar once an Admin has made you leader or deputy of a department. On the phone, **Home** shows a **Needs attention** card and **Open coverage**.

### 1.1 Set up your department

An Admin creates the department, makes you leader and adds the members ([Guide 2, task 2.1](#21-departments-and-leaders)). Then check it:

1. Staff web: **Duties**. Your department is listed with its members. Members without a login show "no login".
2. If someone is missing, ask an Admin to add them. Only people in the department can be given its duties.

Maintainers: [duties.md, story 4.1](duties.md#story-41-publish-a-one-position-department-duty-and-accept-it-on-mobile).

### 1.2 Publish one duty

1. **Duties** > **Publish a duty**.
2. Enter the duty name, date, start time, and (optional) end time, reporting time, place and instructions.
3. **Who**: choose the member. The list shows each person's load ("3 upcoming (1 here)"). If they already have something at that time you see a warning and must give a reason, or choose someone else. No warning does not mean they are free: check with them.
4. **Answer by**: leave it empty for the church default, or pick a time before the duty starts.
5. **Choose the member's reminders** (optional): pick none for no reminders, or the ones you want. Without a choice, the church defaults apply.
6. **Publish**. You should see **Duty published** and the duty with **Awaiting response**.

The member gets **New duty assigned** in their Inbox within about a minute. Maintainers: [story 4.4](duties.md#story-44-warn-on-overlapping-duties-and-record-reasoned-overrides), [story 4.8](duties.md#story-48-set-response-deadlines-and-schedule-creator-configured-duty-reminders).

### 1.3 Publish a rota (for example a quarter of Sundays)

1. **Rota** > **New rota**: duty name, every 1 week(s), first and last date (for a quarter: 13 Sundays), start time, the positions separated by commas (for example `Preacher, Reader`), place and reminders. **Make the draft dates**.
2. You see a grid: one row per date, one column per position, every row **Draft**. Drafts are private: nobody is told yet.
3. Select a date and choose **Who** for each position, then **Save plan**. Repeat for the dates you want to plan now. Positions you leave empty are published as **Unfilled**.
4. **Publish N draft slots**. The confirmation says how many people will be asked and how many positions stay unfilled. Leave **Answer by** at the church default (a duty months away gets an answer-by time two weeks before it). Confirm.
5. You see **Drafts published** and every row **Published**. Each planned person gets one **New duty assigned**.

To change a date later: select it > **Change** > **This date only** or **This and later dates**. The form tells you whether people will be asked again. To cancel: **Cancel date(s)…**. Maintainers: [story 4.3](duties.md#story-43-generate-recurring-multi-position-rotas-with-drafts-and-series-edits).

### 1.4 Read the answers

- **Duties** shows each position: **Awaiting response** (with the answer-by time), **Accepted**, **Can't make it**, **Can't make it anymore** ("Had accepted …; needs cover") or **Confirmed by leader**, with the member's note.
- "N of M confirmed" counts accepted positions.
- When someone says they can't make it, you and the other leaders get **Duty declined** in the Inbox; **Open** goes to Coverage.
- When an answer-by time passes without an answer, you get **Duty answer overdue**.

Maintainers: [story 4.5](duties.md#story-45-respond-from-my-duties-with-later-decline-and-bulk-acceptance), [story 4.9](duties.md#the-leaders-decline-alert).

### 1.5 Work the coverage queue

1. **Coverage** (phone: **Home** > **Needs attention** > **Open coverage**).
2. Choose **From** and the number of days (up to 31), then **Show**.
3. The department line reads "N of M confirmed, … unfilled, … overdue, … declined or changed, … need contact". Use the chips (**Unfilled**, **Overdue**, **Declined**, **Awaiting**, **Needs contact**, **Confirmed**) to filter.
4. Each card says what to do next:
   - **Unfilled** or **Needs a new person**: **Assign** someone.
   - **Declined**: **Reassign** (the earlier answer is kept in the history).
   - **Awaiting** or **Overdue**: contact the member (task 1.6).
   - **Needs contact**: the app cannot reach them; contact them directly.
   - A position you no longer need: **Cancel position**.

Maintainers: [story 4.9](duties.md#story-49-work-the-coverage-queue-with-contact-attempts-and-leader-confirmation).

### 1.6 Contact a member and confirm by leader

1. On the member's card, use **Call** or **Message** if a labelled number is shown (the phone opens its own dialler or messages; the app never calls or sends anything).
2. **Record contact attempt**: how (phone call, message, in person, other), what happened (no answer, left a message, will answer, cannot serve, other), a short practical note (no health or pastoral detail) and the next follow-up time (before the duty). **Save contact attempt**. The first attempt opens a follow-up task for you ("Duty cover: …"), shown with **Open the follow-up task** and in **My follow-ups**.
3. When the member agrees by phone or in person and cannot answer in the app (for example a member without a login): **Confirmed by leader** > how > a short reason > **Record Confirmed by leader**.
4. The card reads **Confirmed by leader** with your name, the time and the reason. The follow-up task closes. Other leaders see it; an Admin or the Pastor sees that it was confirmed by a leader but not your reason; the member sees "Confirmed by your leader" (never the reason).

Confirmed by leader is only for someone who has not answered. If they said they can't make it, reassign instead. Maintainers: [story 4.9, commands](duties.md#commands-apiduties_command-1).

### 1.7 A short-notice duty (for example the coming Sunday)

1. **Publish a duty** for a member with the duty starting soon and **Answer by** left empty.
2. If less than an hour would be left to answer, it is **Short notice**: the member gets one **New duty assigned** that asks them to answer now ("Short notice: please answer now"), and every leader and deputy gets **Short-notice duty**.
3. The position shows **Short notice** and **Needs contact**: phone the member. If they agree by phone and do not answer in the app, record **Confirmed by leader** (task 1.6).

Maintainers: [story 4.8, deadlines](duties.md#deadlines).

### 1.8 Change who serves, or cancel

- **Coverage** > **Reassign**, or **Duties** > **Change this duty** > **Who** (one-position duties), or **Rota** > select the date > **Who** > **Give this position**.
- The person who had it gets "Duty changed: … no longer assigned to you". Their reminders for it stop at once: nothing more about that duty reaches them. The new person gets **New duty assigned** and their own reminders.
- **Cancel position** or **Cancel date(s)…**: the people who were waiting or had accepted get **Duty cancelled**.
- A member without a login is listed under **Needs contact** ("Tell X: … is no longer theirs" / "… is cancelled") until the duty would have started: tell them yourself.

Maintainers: [story 4.2](duties.md#story-42-revise-assignments-on-material-change-and-refuse-stale-responses), [story 4.8, what stops what](duties.md#reminder-kinds-32-contracts).

### 1.9 Record what happened after the duty

1. **Outcomes** (phone: **Home** > **Needs attention** > **Record outcomes of past duties**).
2. On each past duty: **Record outcome** > **Completed**, **Excused** or **No-show** (No-show only after an acceptance), with an optional short note > **Save outcome**.
3. A mistake: **Correct outcome** with a reason. Every earlier value is kept.
4. Your own duty is recorded by another leader or deputy.

Outcomes are seen only by the member and their department's leaders and deputies. It is not a ranking. Maintainers: [story 4.10](duties.md#story-410-record-duty-completion-outcomes-and-keep-assignment-history).

### 1.10 Hand over leadership

1. Ask an Admin to give the new person the **Leader** or **Deputy** role on **Departments** (task 2.1). They must use the app.
2. Then the Admin removes your role. Your access to the department ends at your next action or reload; your pending leader alerts stop.
3. Follow-up tasks you supervised move to another leader or deputy. Tasks you own move when you leave the department's group (Admin: **Follow-up routing** > **Waiting for handover**).
4. The last leader or deputy of a department cannot be deactivated until someone else who uses the app holds the role ("Hand over first").

Maintainers: [story 4.12](duties.md#story-412-apply-membership-lifecycle-and-handover-to-duties-and-follow-ups), [follow-ups.md, story 4.12](follow-ups.md#story-412-lifecycle-and-handover-of-follow-up-tasks).

## Guide 2: Admin

You see **Departments**, **Members & applications**, **Roles & access**, **Access reviews**, **Membership status**, **Member deletions**, **Follow-up routing** and **Reminder health** in the staff web sidebar.

### 2.1 Departments and leaders

1. **Departments** > **Add a department** > the name (on staging it must start `SYNTHETIC `) > **Add department**. You see **Department added**.
2. On the card: choose a member > **Leader** or **Deputy** > **Give this role** (**Role given**).
3. **Add a member** for each person who serves. For someone without a phone, first create them on **Members & applications** > **Add member record (no login)**, with a labelled contact number (whose number it is), then add them here.
4. A card that says **No leader or deputy can use the app: alerts reach nobody** needs a leader or deputy who uses the app.

Maintainers: [story 4.1](duties.md#story-41-publish-a-one-position-department-duty-and-accept-it-on-mobile), [identity-access.md, story 2.5](identity-access.md#membership-review-linking-accountless-members-and-reclaim-story-25).

### 2.2 Remove a member from a department

1. **Departments** > the department > the member > **Remove from department**. The confirmation says their future duties in this department end now.
2. You see **Removed from the department**. Their future positions read **Needs a new person**; the leaders get one **Positions need cover**. The member is told each duty is no longer theirs; someone the app cannot reach is listed for the leaders to tell.
3. **Removed, but nobody was told** means the church-time policy was unavailable: tell the leaders yourself (see [Guide 3, task 3.4](#34-the-q2-church-time-gate-is-closed)).

Maintainers: [story 4.12, commands](duties.md#commands-apiduties_command-admin-only).

### 2.3 What holds, deactivation and deletion do to duties

| You do | Their duties | What leaders see |
|---|---|---|
| **Disable login (hold)** on Access reviews or Membership status | kept | **Needs contact** on each upcoming duty; no reason, no alert |
| **Deactivate membership** | every future duty ends | **Needs a new person**, one **Positions need cover** notice per department |
| **Member deletions** > delete | as deactivation | as deactivation |
| **Restore membership** | nothing comes back | give the duties again; the member is asked afresh |

Past duties, answers and outcomes are kept. Leaders never learn why. Their follow-up tasks are handed over (task 2.4). Maintainers: [story 4.12](duties.md#what-each-lifecycle-change-does-to-duties-inside-identitys-transaction-ad-14).

### 2.4 Handovers

- **Hand over first** on a deactivation: the member is the last leader or deputy of a department, or the only possible owner of an open follow-up task. Give the department another leader or deputy who uses the app (task 2.1), or reassign the task, then deactivate again.
- **Handover pending** on a department (after a deletion): give it a leader, then **Mark handover done**. The deletion continues at the next worker run. The button stays disabled until the department has a leader or deputy who uses the app ("Give it a leader first").
- **Hand over the next 100 follow-up tasks** on Membership status: a member who left still owns tasks (one change hands over at most 25). Press until nothing is left; **Nobody could take them** means nobody in the task's group can receive them yet.

Maintainers: [story 4.12, handover](duties.md#handover-the-last-leader-of-an-active-department).

### 2.5 Follow-up routing

**Follow-up routing** lists tasks by scope with owner, supervisor, purpose, state and dates (never notes). You may reassign the owner (within the task's group) or the supervisor. **Waiting for handover** lists members whose tasks or supervision wait for someone, also after a removed role, each with **Hand over the next 100**. Maintainers: [follow-ups.md, story 4.6](follow-ups.md#story-46-open-the-follow-ups-registry-with-my-follow-ups-for-every-owner) and [story 4.12](follow-ups.md#owner-authority-is-live-what-waits-is-listed-review-b1).

### 2.6 Coverage across the church

**Coverage** shows Admins and the Pastor **Gaps across the church**: positions, states, names and counts, never a contact number, note, reason or task. An Admin may **Reassign** and **Cancel position**, but contact attempts and Confirmed by leader belong to the department's leaders.

## Guide 3: duty reminder problems

Start here when a leader or member says a reminder was wrong, late or missing. Never ask anyone to send screenshots with real numbers; ids and times are enough.

### 3.1 A reminder arrived for a duty that is no longer theirs (stale reminder)

1. Ask the member to open the item. **This reminder is out of date** means the duty changed after the reminder was made: the app checked it again and shows nothing more. My duties is the live view.
2. Leader: **Duties** > the duty > **Earlier versions** shows who had it and when it changed.
3. Every reminder is checked again when it is sent: it goes only to the current person, at the current version, while it still applies. A **Duty changed** ("no longer assigned to you") after a reassignment is expected; a **Duty answer needed** or **Duty coming up** for a duty that is no longer theirs is not.
4. If that happened, give a maintainer the time it arrived and the duty's date (no names). Maintainers run, read only, the stale-job check of [duties.md, story 4.8](duties.md#reminder-kinds-32-contracts) (the query is in `tools/identity-e2e/duties-reminders.mjs`, step D90, and in the pilot, step P80): it must answer 0.

### 3.2 A member was not reached

The leader sees **Needs contact** ("Reminders cannot reach them in the app"). Common causes, none of which the app shows to the leader:

- the member has no login (an Admin record);
- the member is on a login hold or under an access review (Admin: **Access reviews**);
- the member has left the church or is being deleted (the position then reads **Needs a new person**).

What to do: the leader contacts the member directly, records a contact attempt and, if they agree, **Confirmed by leader** ([task 1.6](#16-contact-a-member-and-confirm-by-leader)). An Admin can release a hold when the identity check is done. A member with the app who sees nothing: ask them to open **Inbox** and pull to refresh; push is only a hint, the Inbox is the record.

### 3.3 The Needs contact list

Each department on **Duties** starts with **Needs contact (n)**: short-notice duties, people the app cannot reach, and "Tell X: … is no longer theirs / … is cancelled" for people who cannot be reached about a change. Entries leave the list when the person answers, the hold is released, the position is given again, or the duty would have started.

### 3.4 The Q2 church-time gate is closed

Duties needs the church-time policy (Q2) to plan answer-by times and reminders.

- **Signs:** publishing or changing duties shows **Not available yet** ("Duties cannot be changed here right now. Nothing was changed."); a removal says **Removed, but nobody was told**.
- **Still works:** members' answers, contact attempts, Confirmed by leader and cancellations are recorded; only their reminders are skipped (audited `reminders_skipped`, code `policy_unavailable`).
- **Fix:** the owner approves `q2_church_time` (production) or the parent session restores the staging fixture, then runs the re-plan: [notifications.md, story 3.3](notifications.md#the-policy-value-q2_church_time). Duties published before the fix get their reminders at their next change (or **Change reminders** > **Save the reminders**).
- Check (SQL editor, read only): `select gate, state from app.policy_gates where gate in ('q2_church_time', 'q4_personal_data');`.

### 3.5 Reminder health

Staff web **Reminder health** (Admin or the mapped operator) shows counts only:

- **Scheduler status may be stale**: nothing has been handed to the worker for five minutes. Check the scheduler as in [system-access-and-operations.md](system-access-and-operations.md).
- **Due and pending** and the oldest due time: reminders are late.
- **Direct contact**: needs with no route in the last 24 hours; Duties needs are routed to the leaders' Needs contact list, so this should stay at zero for duties.

Details: [notifications.md, story 3.8](notifications.md#story-38-staff-reminder-health-and-notification-recovery).

## The synthetic pilot rehearsal

`tools/identity-e2e/duties-pilot.mjs` runs the whole loop of the guides above through the API with `SYNTHETIC Preaching Rota`: a quarterly rota, reminders delivered by the worker, answers, the visible gap, a direct contact attempt, Confirmed by leader for a member without a login, a short-notice duty, a reassignment whose reminder reaches only the new person, and the privacy checks. How to run it locally and against staging: [duties.md, story 4.13](duties.md#story-413-duties-runbooks-and-the-synthetic-department-pilot).

## Owner walkthrough on staging (HITL)

This is the owner's run-through of the ticket's verify line, on the staging staff web and the staging APK. The same checklist with blanks for results is in `_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.13/owner-walkthrough.md`; record results there (pass or fail, device model, Android version, browser; no numbers, ids or keys).

**You need:** the staff web and the APK built against staging (as in [notifications.md, story 3.7](notifications.md#hosted-staging-parent-session-then-the-owner-5)); synthetic people: Admin A; leader L with the APK and the staff web; members M (APK) and O (APK or web) with the app; X without a login, with a SYNTHETIC household number. If the parent session ran the rehearsal first, it has cleaned up after itself.

1. **Department.** As A: **Departments**: `SYNTHETIC Preaching Rota` (add it if missing). Give L **Leader**; **Add a member** M, O and X. See: X shows "no login".
2. **Quarterly rota.** As L, staff web **Rota** > **New rota**: `Sunday service`, every 1 week, the next Sunday at least three days away to 12 weeks later, `10:00`, positions `Preacher, Reader`. Plan the first Sunday (Preacher M, Reader X) and the second Sunday (Preacher O). **Publish 26 draft slots** at the church default. See: 13 **Published** rows; the confirmation said 3 people asked and 23 positions unfilled.
3. **Reminders delivered.** On M's phone within about a minute: **Inbox** > **New duty assigned** > **Open**: the duty, with an answer-by time marked (church default). On staff web as L, **Duties**: X's position shows **Needs contact**.
4. **Answers.** M: **Accept** with a note. O: **Can't make it** with a note. See: L's board shows **Accepted** and **Can't make it** with both notes; L's Inbox shows **Duty declined**, whose **Open** opens **Coverage**.
5. **The gap.** As L, **Coverage**, **From** = the first Sunday, 31 days, **Show**. See: the unfilled positions, O **Declined**, X **Awaiting response** with "no login: contact them directly", **Needs contact** and the household number with its label.
6. **Direct contact.** On L's phone: **Open coverage** > X's card > **Call** opens the dialler (do not call; go back). **Record contact attempt**: Phone call, Will answer, a SYNTHETIC note, next follow-up tomorrow. See: **Contact attempt recorded** and **Open the follow-up task**.
7. **Confirmed by leader.** On X's card: **Confirmed by leader** > Phone call > a SYNTHETIC reason > **Record Confirmed by leader**. See: the card reads **Confirmed by leader** with L, the time and the reason (not "Accepted"); staff web **Duties** shows **Confirmed by leader**; the follow-up task is closed.
8. **Short-notice Sunday.** As L, **Publish a duty** for M starting in about three hours (on a Saturday evening or Sunday morning if you can), **Answer by** empty. See: M gets one **New duty assigned** (not two) and the duty reads **Short notice: please answer now**; L gets **Short-notice duty**; the position shows **Short notice** and **Needs contact**. M accepts.
9. **No stale reminder.** As L, publish `Sunday reading` for M two days ahead with **Answer by** about 20 minutes from now and only the reminder "at the answer-by time". Within a minute, **Change this duty** > **Who** = O, the same answer-by time, save. Wait until 2 minutes after the answer-by time. See: M got **Duty changed** ("no longer assigned to you") and **no** **Duty answer needed**; M's earlier **New duty assigned** for it says **This reminder is out of date**; O got **New duty assigned** and then **Duty answer needed**.
10. **Nothing private for a non-leader.** As M on the phone: **Duties** shows only M's duties; no note of O, no contact note, no Confirmed by leader reason, no number; no **Coverage**. As O on staff web: no **Duties** board, **Rota** or **Coverage** entry (opening `/duties/coverage` is refused). As A: **Coverage** shows **Gaps across the church** without numbers, **Call**, notes or reasons. Every Inbox item reads only its fixed text (no names, no notes).
11. **Clean up.** Ask the parent session to remove the walkthrough's rows (as in [duties.md, story 4.9](duties.md#owner-manual-checks-staging-phone-and-web-story-49), step 10, with the 4.12 additions).
