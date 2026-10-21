# Cell meeting guides for leaders, assistants and Admins (story 5.10)

These guides are for the people who run cell meetings: a cell's **leader**, its **assistant** and **Admins**. They follow the order you do the work in. Each task says where to go, what to press and what you should see. The technical detail for maintainers stays in [cells-meetings.md](cells-meetings.md), story by story. Each task links to it.

Until the owner approves personal data (Q4), everything on staging is synthetic:
- cell names start with `SYNTHETIC `, and the pilot cells are `SYNTHETIC Shikoswe Cell` and `SYNTHETIC Estates C5/C7 Cell`;
- people are synthetic and numbers are fictional;
- venues are made up.

Never type a real name, number, address, note or reason into staging. Group chat is not part of any of this: nothing here needs or uses chat.

All dates and times are **church time** (Africa/Lusaka), whatever your phone or computer is set to.

**Contents**

- [Words used here](#words-used-here)
- [Guide 1: Admin](#guide-1-admin)
- [Guide 2: cell leader and assistant](#guide-2-cell-leader-and-assistant)
- [Guide 3: what members see](#guide-3-what-members-see)
- [The synthetic pilot rehearsal](#the-synthetic-pilot-rehearsal)
- [Owner pilot on staging (HITL)](#owner-pilot-on-staging-hitl)

## Words used here

| Word | Meaning |
|---|---|
| Meeting | One week's cell meeting. The app makes them from the cell's weekly schedule; each keeps its identity when it is moved. |
| Programme | The plan for one meeting: topic, scripture, study notes and timed parts. **Draft** is private to the leader, assistant and pastors; **Published** is shown to the cell's members. |
| Part | One timed item (Opening prayer, Worship, Bible study). Its person is asked through **My duties**; a part with nobody is a **gap**. |
| Answer | The person's own **Accept** or **Can't do it**, or **Confirmed by leader** when you record that they said yes in person or by phone. Showing a name in the programme is never an answer. |
| Can't come? | A member's notice that they cannot attend one meeting. It never answers their part and is not attendance. |
| Held / Not held | What happened, recorded by the leader or assistant once the meeting has started. |
| Who led | The person who actually led a part (a member, a named guest or nobody). It is recorded separately from the plan, and recaps and reports use it. |

## Guide 1: Admin

### 1.1 The cell, its leader and its schedule

1. Staff web: **Admin cells**. Create the cell (or find it), give its **Leader** and, if wanted, **Assistant**, and confirm its members (also members without a login).
2. **Cell meetings** > the cell > **Set the schedule**: weekday, start and end time, venue and an optional map pin. You see the next 12 weeks of meetings.

Maintainers: [story 5.1](cells-meetings.md).

### 1.2 Moving a member to another cell

**Admin cells** > the member > move them, then confirm (or let the new cell's leader confirm). A leader or assistant of their current cell cannot be moved until you remove that role (**Leads their cell**). Removing it is refused while they are the cell's last leader with a programme ahead (1.3). Their old cell's future parts become gaps, their part duties end with **Duty released**, and their open **Can't come?** notices close. The old cell's leader and assistant get **A part needs someone**. Meetings that have already started are left as they were.

Maintainers: [story 5.9](cells-meetings.md#story-59-transfers-handovers-and-deletion).

### 1.3 A cell that needs a leader

You cannot remove (or deactivate) the last leader or assistant of a cell while it has a published programme ahead. Give the cell another leader or assistant who uses the app first. If the app recorded a handover (for example after a deletion), **Admin cells** shows **Needs a leader: a programme is published ahead**. Once the cell has a leader again, press **Mark handover done**.

## Guide 2: cell leader and assistant

### 2.1 See your meetings

Staff web (or the app): **Cell meetings**. The card answers "when do we meet next?" first, then lists the next 12 weeks and **Last 4 weeks**. The leader (or an Admin) can **Move** or **Cancel this meeting** for a meeting ahead. A meeting with a published programme can be moved by its leader or assistant (the programme follows) but not cancelled until its programme is cancelled.

Maintainers: [stories 5.1-5.2](cells-meetings.md).

### 2.2 Plan the meeting (draft)

1. **Cell meetings** > the meeting > **Plan** > **Start the programme**.
2. Fill in the topic, scripture and study notes, and the parts in order with their start and end times inside the meeting. Choose a person from the cell for each part, or leave it a **gap**.
3. **Save**. The page shows "3 parts, 1 gap". Nobody is told yet: drafts are for you, the assistant and pastors.

Maintainers: [story 5.3](cells-meetings.md).

### 2.3 Preview and publish

1. The page shows what members will see (**Preview**). It shows names, times and the study, never answers or notes.
2. **Publish**. Each person with a part is asked in **My duties**. A member without a login cannot be reached by the app: contact them yourself (2.5).
3. The page shows "0 of 3 accepted", then each part's answer as people reply.

Maintainers: [stories 5.4-5.5](cells-meetings.md).

### 2.4 Change a published programme

- **Notes only** (study notes, scripture): save and publish again. Nobody is asked again.
- **A time, a person or the meeting's time or place**: save and publish again. Only the people whose part changed are asked again: their earlier answer is replaced by a new **Awaiting response**. A part linked to a department duty is not changed; its department is asked to review it.
- The page says **Changes not yet published** until you publish them.

Maintainers: [story 5.6](cells-meetings.md).

### 2.5 Someone without a login (or who said yes by phone)

On the part, **Confirmed by leader**, then how they told you and a short reason. The part shows **Confirmed by leader** with your name, never "Accepted".

### 2.6 Someone can't come

A member's **Can't come?** notice arrives in your **Inbox** as "Someone can't attend". **Plan** shows **Can't attend (N)** with their note, and **Can't attend** next to any part they hold. Their part is still theirs until they answer it: ask them, or plan someone else and publish again.

Maintainers: [story 5.7](cells-meetings.md).

### 2.7 After the meeting: held and who led

1. **Cell meetings** > **Last 4 weeks** > **Record** (or **Plan** on the meeting).
2. **Yes, it was held**, or **It didn't happen**.
3. **Who led each part**: **N parts were led as planned** for the parts whose person led them, then **Record** on any part someone else led (a member of the cell, **Someone else (a guest)**, or **Nobody led it**).
4. A mistake: **Change** on the part (or **It wasn't held**). Give a short reason. The earlier value stays visible with who recorded it.

Recording who led never changes the plan or anyone's answer. It is the record recaps will use, so record the person who actually served.

Maintainers: [story 5.8](cells-meetings.md#story-58-meeting-records-and-actual-leaders).

## Guide 3: what members see

- **My cell** (phone): the next meeting with its time and venue, the published programme, **You're on** with their own answer, and **Can't come?**.
- **Home**: the next meeting and **You're on**.
- **My duties**: their part like any duty: **Accept** or **Can't do it**.
- They never see others' answers, notes, notices, reasons or drafts. After moving cells they see only their new cell.

## The synthetic pilot rehearsal

`tools/identity-e2e/cells-pilot.mjs` runs the loop above through the API on the local stack:
- a published programme asks each person;
- a meeting move asks again;
- a **Can't come?** notice changes no answer or attendance;
- **Confirmed by leader** for a member without a login;
- held, with a substitute as the actual leader and a correction;
- no chat, and nothing private reaches another member.

Maintainers: [cells-meetings.md, story 5.10](cells-meetings.md#story-510-runbooks-and-the-synthetic-cell-pilot).

## Owner pilot on staging (HITL)

This is the owner's run-through of the ticket's verify line, on the staging staff web and the staging APK, with chat absent. The same checklist with blanks for results is in `_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/evidence-5.10/owner-pilot.md`. Record results there (pass or fail, device model, Android version, browser; no numbers, ids or keys).

**You need:**
- the staff web and the APK built against staging;
- synthetic people:
  - Admin A;
  - leader L of `SYNTHETIC Shikoswe Cell`, with the staff web and the APK;
  - member M with the APK;
  - member X without a login;
  - a leader E of `SYNTHETIC Estates C5/C7 Cell`.

1. **Schedule.** As A, **Cell meetings** > `SYNTHETIC Shikoswe Cell` > **Set the schedule** (a weekday at least two days ahead, 18:00-19:30, a SYNTHETIC venue). See: the next 12 weeks.
2. **Draft and publish.** As L, **Plan** the next meeting: Opening prayer M, Worship X, Bible study a gap. **Publish**. See: "0 of 2 accepted"; M gets **New duty assigned** in the Inbox; X has no login, so the app cannot reach them (you contact X yourself).
3. **Answers.** M **Accept**s on the phone. As L, on X's part, **Confirmed by leader** (phone, a SYNTHETIC reason). See: M **Accepted**, X **Confirmed by leader**.
4. **A time change asks again.** As L, **Cell meetings** > **Move** the meeting 30 minutes later; **Plan** > **Publish** again. See: M is asked again (**Awaiting response** in **My duties**, with an Inbox item about the change); the programme on M's phone shows the new time.
5. **Can't come.** M, **My cell** > **I can't attend** with a SYNTHETIC note > **Tell my leader**. See: L's Inbox "Someone can't attend"; **Plan** shows **Can't attend (1)** and **Can't attend** on M's part; M's part answer is unchanged.
6. **After the meeting** (the next day). As L, **Cell meetings** > **Last 4 weeks** > **Record** > **Yes, it was held**; Opening prayer **Record**: X (a substitute); Worship **1 part was led as planned**. See: "Stood in: X" and "Led by X"; the plan and the answers are unchanged.
7. **Correction.** On Opening prayer **Change**: **Someone else (a guest)**, a SYNTHETIC name and reason. See: the guest, the reason and "Earlier: X".
8. **Another cell.** As E, the Shikoswe meeting's **Plan** page is refused.
9. **No chat.** Nothing above asked for or showed chat.
10. **Clean up.** Ask the parent session to remove the pilot's programmes, notices and records (or leave them as the synthetic baseline for 5.12).
