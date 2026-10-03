# Handoff: Brethren in Christ Church Kafue — Member App + Church Admin

## Overview
Two connected products for a church of under 200 members:

1. **Member mobile app** (Flutter, iOS + Android) — sermons, events, Bible & hymn book, giving instructions, calendar, assigned duties, cell group life, pastoral visits, phone sign-up and profile. Leaders get a duty coverage queue inside the app.
2. **Church admin web app** — three role views: **Admin** (members, cell groups, duty rotas), **Cell leader** (own cell, meeting planning, weekly report incl. offering), **Pastor** (congregation overview, cell reports, cell giving, pastoral care kanban).

The functional source of truth is `spec/Church App - v1 Spec.md`. **Where the designs go beyond the spec, the designs reflect newer owner decisions** — see "Scope changes vs spec" below.

## About the Design Files
The files in `design/` are **design references created in HTML** — interactive prototypes showing intended look and behaviour, not production code. Recreate them in the target stack:
- Member app: **Flutter** (Riverpod, go_router) per the spec.
- Admin: the spec has no web stack; choose an appropriate one (e.g. Flutter Web sharing the Supabase layer, or React/Next + Supabase JS). Backend is **Supabase** (Auth, Postgres + RLS, Storage, Realtime, Edge Functions, Cron) + FCM push.

To view: open `design/BIC Kafue App.dc.html` and `design/BIC Kafue Admin.dc.html` in a browser (they load `support.js` and `assets/` relatively; fonts from Google Fonts). Each prototype's mock data and state logic live in the `class Component` script at the bottom of the file — read it for exact copy, sample data and state transitions.

## Fidelity
**High-fidelity.** Final colours, type, spacing, radii and interactions. Recreate pixel-closely using native widgets. All names, phone numbers, giving destinations, amounts and attendance figures are **placeholders**.

## Scope changes vs spec (owner-approved in design review)
- **Web admin portal exists** (spec listed it as a v1 non-goal).
- **Cell offering records** are captured in the cell report (amount, two counters, handed-to-treasurer) and shown to Pastor on a Cell giving page. Spec previously excluded cell-collection records. Restrict to cell leader/assistant, pastor and treasurer; never visible to members.
- **Pastoral visits**: pastor schedules visits; members accept / suggest another time / decline / request a visit on their phone. Private to the pastoral team.
- **Cell meeting planning & recaps**: leader publishes next meeting with venue and a programme (who leads each part); members see next meeting + recaps of past meetings (summary, key points, who led). Prayer needs / pastoral notes remain private.
- **Pastor overview** covers Sunday service, midweek service, prayer meeting and cells (requires attendance capture per service — add a `services` / `service_occurrences` / `service_attendance` model; counts only, not names, unless the church decides otherwise).

Update the spec and data model/RLS accordingly before building.

---

## Design Tokens

### Colours — member app (light / dark)
| Token | Light | Dark | Use |
|---|---|---|---|
| bg | #F4F6FA | #0A0F1E | screen background |
| surface (sf) | #FFFFFF | #131A2E | cards, tab bar, sheets |
| surface2 (sf2) | #EDF0F6 | #1B2440 | date badges, segmented track, placeholders |
| ink | #0E1530 | #EDF0F7 | primary text |
| muted (mut) | #586079 | #9AA3BC | secondary text |
| line | #DFE4EE | #26304D | borders/dividers |
| primary (pri) | #14246B | #2A6FD0 | primary buttons |
| brand | #14246B | #DCE6FF | large headings, logotype colour |
| link | #14246B | #8EC1FF | text buttons, active tab |
| accent (acc) | #0A7FE0 | #3D9BF5 | badges, verse numbers, highlights |
| hero | #14246B | #182A7A | navy hero cards |
| amber bg/fg | #FFF1CF / #6E4400 | #3A2D10 / #F5C866 | awaiting, needs contact |
| green bg/fg | #DFF3E8 / #0D6438 | #10301F / #7FD9A6 | accepted, confirmed |
| red bg/fg | #FCE5E2 / #A3241A | #3A1614 / #F4A29A | declined, unfilled, overdue |
| blue bg/fg | #E3EEFC / #0B4FA6 | #13284A / #9CC7FF | info chips, numbered steps |
| gray bg | #EDF0F6 | #1B2440 | neutral chips (fg = muted) |

Brand origin: emblem navy **#14246B** and water blue **#0A7FE0**.

Admin uses the light set only, plus: page bg #F4F6FA, sidebar #14246B, kanban column #EBEEF5, drop-target #DCE7FA with 2px dashed #0A7FE0, dashed add buttons #C9D0E0.

### Typography
- **Outfit** (500/600/700) — headings, large numbers. **Figtree** (400/500/600/700) — body/UI. **JetBrains Mono** (400/500) — eyebrow labels, programme times, placeholder captions.
- App scale: screen title 28/700 Outfit (brand colour); section title 19/600 Outfit; card title 17–18/600–700; body 16 (min where practical, per spec); secondary 14; chips 13/600; tab labels 11.5 (700 active / 500 inactive); hero eyebrow 11 mono, letter-spacing .12em; Bible text 18/1.6; hymn text 19/1.55.
- Admin: page title 24/700 Outfit #14246B; card title 17–18/600 Outfit; body 15; table header 12/700 uppercase, letter-spacing .06em, #586079; KPI numbers 30–34/700 Outfit.

### Radii, spacing, shadows
- Radii: hero/large cards 20–22; cards 16–18; inputs 14 (app) / 10 (admin); buttons fully rounded (height/2) in app, 10–12 in admin; chips 999; bottom sheet 26 top corners; date badge 12–14.
- Spacing: screen horizontal padding 16 (forms 20); section gap 18–22; card padding 14–18; list row min-height 54–72.
- Touch targets ≥44px (icon buttons 44×44, primary buttons 46–54 tall).
- Shadows: phone sheet none (scrim rgba(5,10,30,.5)); toast 0 10px 30px rgba(0,0,0,.25); admin modal 0 30px 80px rgba(0,0,0,.25); segmented active 0 1px 3px rgba(0,0,0,.12).

### Status chips (text always present — never colour alone)
Awaiting your response (amber) · Accepted (green) · Can't make it · sent (red) · Not sent · sending… (gray) · Completed (gray) · Unfilled / Overdue response / Declined (red) · Needs contact / Awaiting response (amber) · Confirmed / Confirmed by leader (green) · Draft (gray, dashed border).

## Assets
- `design/assets/bic-logo.png` — church emblem (1254×1254, white background). Use inside a white circle.
- `design/assets/bic-logo-white.png` — white monochrome version, transparent background (generated from the emblem) for navy surfaces.
- The emblem already contains the church name, so the **top bar shows the logo alone** (44px circle) — no text beside it.
- Icons: simple 2px-stroke line icons (Lucide-style: home, book-open, mic, heart, calendar, message, search, chevrons, copy, phone, map-pin, check). Use the Lucide/Material Symbols equivalents.
- Posters/thumbnails are striped placeholders: real content is 16:9 images from Storage, with tap-to-open full poster.

---

## Member App — Screens

Frame 390×844; content area below a 50px status bar. Persistent **top bar** (logo left; search, chat with unread badge, profile avatar right; guests see a **Sign in** pill instead of chat/profile). **Bottom tabs**: Home, Bible & Hymns, Sermons, Give, Calendar (surface bg, 1px top border, active = link colour + 700). Detail screens push full-screen over tabs with a back chevron + 20/600 title.

Access states (prototype side panel "View as"): **Guest**, **Pending**, **Member**, **Leader**.

1. **Home**
   - Horizontal snap carousel (310px wide, 16:9, radius 20). First card = yearly theme on navy: eyebrow "THEME FOR 2026", title **"God's faithfulness in Self Sustenance"** (22/700 Outfit), "Deuteronomy 7:9"; decorative concentric rings + white monochrome logo top-right. Then event/campaign banners.
   - Guest: "Part of the church family?" card + Join. Pending: membership request card with two separate status chips (church approval, cell).
   - Leader: **Needs attention** card (4-up grid: Unfilled, Overdue, Declined, Needs contact; "Sun 4 Oct: 6 of 10 confirmed").
   - Member: **My duties** navy hero — "N awaiting response" amber pill, next duty (date badge, duty, dept, report time, place), inline **Accept** / **Can't make it**, "See all my duties".
   - **Pastoral visit** card when a visit awaits reply — Accept / Another time / Decline.
   - Leader: **My follow-ups** row.
   - **My cell** card — next meeting date/time/venue, topic + Bible study lead, "You're on: <part> · <time>" if the member has a programme part.
   - **Hymns for this Sunday** chips (number + title), then **Coming up** poster cards (16:9 + title + when/place).
2. **My duties** — segmented: Needs a response (n) / Upcoming / Past. Cards: date badge, duty, dept · report time, location, status chip. Empty states: "Nothing waiting for your response." / "You have no upcoming duties." / "No past duties yet."
3. **Duty detail** — status chip, title 28 Outfit, dept; rows (Date, Report at, Service, Location, Topic, Respond by); INSTRUCTIONS; leader contact row with Call; Add to calendar (+ note that exported entries may need updating). Sticky footer by state: Awaiting → Can't make it + Accept; Sending → "Not sent yet · sending your response…"; Accepted → "You accepted this duty" + "Can't make it anymore"; Declined → leader notified text; Past → recorded as completed.
   - **Decline sheet**: title, duty/date, optional note textarea, "Let Br. Mwansa know", Cancel.
4. **Leader coverage** (Ushering) — navy summary "Sun 4 Oct · Morning service — 6 of 10 confirmed" with progress bar (#4FB0FF); horizontal filter pills with counts (All, Unfilled, Overdue, Declined, Awaiting, Needs contact, Confirmed); issue cards with name, position · date, chip, detail, actions (Call / Record confirmation / Assign|Reassign). Sheets: **Record confirmation** (reason input; saved as "Confirmed by leader", distinct from member acceptance) and **Assign** (member list with load; conflicts shown in red, e.g. "Conflict: already on Side door, Sun 4 Oct").
5. **Bible & Hymns** — segmented Bible / Hymn book. Bible: book/chapter picker + translation picker (KJV), chapter heading, verses with accent superscript numbers, prev/next chapter. Hymn book: search (number, title, first line), list (big number, title, first line, "Sunday" chip). **Hymn detail**: number in header, Save/Saved favourite pill (members), title, key, numbered verses, italic CHORUS block.
6. **Sermons** — current series navy card (poster placeholder), filter pills Latest/Series/Speaker, list rows (16:9 thumb with play, title, speaker, date · scripture). **Sermon detail**: YouTube player area, series eyebrow, title, speaker · date, audio row (play, length, "keeps playing with the screen locked"), scripture chip, Notes.
7. **Give** — "How to give" + explainer that the app doesn't process or record gifts; method list (logo slot, name, purpose · currency). **Method detail**: header, amber sample-data banner (remove in prod), copyable detail rows (Copy button per value), numbered steps, "Open dialler with *code#" (mobile money only), "Before you confirm" beneficiary check, last verified date + office contact. No payment success state, amount, or "record my gift".
8. **Calendar** — "October 2026", member overlay toggles (✓ My duties, My cell), list items: date badge, title, time · place, optional tag chip (My duty blue / My cell green), event thumbnail. Duty items open duty detail; cell items open My cell.
9. **My cell** — navy hero (cell name, leader + assistant, schedule · member count, Open cell chat). **Next meeting** card: date badge, day/time; venue + address + Directions; Bible study topic + scripture; PROGRAMME rows (mono time, part, person; "You" chip for the viewer); Add to calendar / Can't attend. **Last meeting** card: topic, scripture, attendance chip, When/Where/Led by grid, 3-line clamped summary, "Read the recap". **Earlier meetings** list.
10. **Meeting recap** — date eyebrow, topic, scripture; Where / Led by / Attended rows; What we discussed; numbered Key points; Who led each part; privacy note that prayer needs stay with leaders/pastors.
11. **Pastoral visits** — privacy line; current visit card (status chip, date/time big, who · where, reason; actions by state: awaiting → Accept visit, Suggest another time, Decline; accepted → Change time; postponed → "You suggested X. The pastor will confirm."; declined → can request any time). My requests list. **Request a visit** button. Past visits. Sheets: **Suggest another time** (3 offered slots + "None of these work — I'll call the office"), **Decline** (optional note), **Request a pastoral visit** (reason pills: Prayer, Illness, Bereavement, Counsel, Home blessing, Other; where: My home / Church office / Hospital; when: Weekday evening / Saturday / Sunday afternoon; note; Send disabled until reason chosen).
12. **Profile** — avatar initials, name, phone; Church membership chip and **separate** My cell chip + action (Request a cell change / Correct my request); menu (My cell, Pastoral visits, My duties, My follow-ups, Prayer requests, Directory, Departments, Notifications, Account); leader STAFF TOOLS → coverage; Sign out.
13. **Groups (chat list)** — group mark, name, last message, unread badge.
14. **Phone sign-up** (3 steps + done): (1) "Continue with phone", +260 prefix field, Send code (enabled at ≥9 digits), SMS/membership disclaimer; (2) 6-digit code (mono, spaced), Verify (enabled at 6), Wrong number?, "Resend in 0:45", "I need help accessing my account"; (3) Full name, "Which cell group do you belong to?" radio cards incl. **I'm not sure** and **I'm not in a cell yet**, optional email, privacy notice, Submit (needs name + cell); (4) Request sent with separate Awaiting church approval + cell status chips → role becomes Pending.

Toast: dark #0E1530 pill above tab bar, auto-dismiss ~2.2s.

---

## Admin Web — Screens

Layout: 232px navy sidebar (sticky, logo 84px circle in white disc, role switch Admin / Cell leader / Pastor, nav with blue count badges), main area with sticky white header (title + subtitle, contextual action), content max-width 1280, padding 28/32. Fluid; tables scroll horizontally with min-widths.

**Admin role**
- **Overview**: 4 KPI tiles (applications, cell requests, duty gaps, draft rota slots) + Needs attention list (chip, title, detail, Open).
- **Members**: segmented Applications (n) / All members. Application cards: name + status chip, phone · email · submitted, cell choice, amber possible-duplicate notice; actions Link to existing record (if duplicate), Approve, Ask for details, Reject. All members: search, "Add member record" (for people without phone/email), table (Name+phone, Cell, Departments, Roles, Account chip: App account / No login / Access review). Row → right panel: details, role toggle pills (Media, Pastor, Admin, Prayer team; audited), Place access review hold, Deactivate membership.
- **Cell groups**: left cell cards (name, zone, members, leader, request badge; selected = 2px #0A7FE0) + New cell; right: leader/assistant selects, schedule, venue; Membership requests (Confirm in cell / Not in this cell); confirmed member grid.
- **Duty rotas**: department pills; status legend; grid (positions × 4 Sundays, per-date "x of y confirmed"); slot = coloured tile with name + status, empty = dashed red "+ Assign"; click → inline select listing members ("· already serving" on conflicts). Header **Publish N draft slots** → drafts become Awaiting response.
- **Cell meetings** (also cell leader): see below.

**Cell leader role** — nav: Overview (own-cell tiles: requests, report due, follow-ups, members), My cell, Cell meetings.
- **Cell meetings → Next meeting**: fields (Date, Time, Venue, Address, Bible study topic, Scripture); Programme table (time, part, person select, remove) + Add part; Publish to members / Cancel this meeting; live **"What members see"** phone preview.
- **Cell meetings → Last meeting (report)**: Attendance list with Present / Absent / Excused per member + summary count; Visitors list + add; report card with status chip; "What we discussed" and "Testimonies" (shared with members); private "Prayer needs & pastoral issues" (leader, assistant, pastors only); **Cell offering** block (Amount ZMW, Counted by, Second counter, "Handed to the treasurer" checkbox); Submit report.

**Pastor role** — nav: Overview, Cell reports (missing badge), Cell giving, Pastoral care (requests badge).
- **Overview**: 6 KPI tiles (Approved members, Sunday attendance, Visitors this month, Pastoral visits ahead, Missing reports, Cell giving · Sep). **Attendance** chart (8 weekly bars, last bar #0A7FE0, others #14246B, value above, date below) with switcher Sunday service / Midweek service / Prayer meeting / Cell groups. Pastoral visits ahead list. **Services & meetings** table (Service, Last held, Led by, Attended, vs 4-wk avg (+green/−red with up/down text), Visitors, Next). **How the cells are doing** table (Cell, Leader, Last met, Attendance bar + x/y (amber when <75%), 4-week trend word, Report chip, Giving · Sep) → row opens report.
- **Cell reports**: left list (cell, status chip Submitted/Missing, date · leader, attendance line); right detail: stats (Present, Absent or excused, Visitors, Offering), Bible study, What was discussed, Testimonies, PRIVATE block (Prayer needs, Pastoral issues) with **Schedule a visit for <name>** when a report flags someone. Missing → amber notice + Remind leader.
- **Cell giving**: tiles (all cells total + per cell with relative bar and pending hand-overs), cell filter pills, Export CSV, table (Meeting, Cell, Amount, Counted by, Treasurer chip Received/Pending/—, Note e.g. counting differences, cancelled meetings).
- **Pastoral care**: **drag-and-drop kanban** — columns Requested → Awaiting member → Confirmed → New time suggested → Completed (counts + hint). Cards: member, reason chip, when, detail, contextual button (Schedule visit / Mark completed / Accept new time). Drag behaviour: dragged card 45% opacity; hovered column #DCE7FA with dashed #0A7FE0 outline; dropping on **Awaiting member** opens the schedule modal; on **Completed** opens the private-note modal; other columns move directly + toast. **Schedule modal**: Member (dropdown), Reason (dropdown), Who is visiting (dropdown), Date (native date picker, min today), Time (native time, 15-min step), Where (dropdown) → "Send to member" creates a phone request.

---

## Interactions & State (key flows)
- Duty response: Awaiting → (Accept) **Sending/Not sent** → Accepted (only after server confirms); Decline → note → Declined, leader notified, coverage reopens. Accepted → "Can't make it anymore" reopens coverage.
- Leader coverage item kinds: unfilled, overdue, declined, contact, awaiting, confirmed, leaderConfirmed. Record confirmation → leaderConfirmed (store actor, time, reason). Reassign → new person, Awaiting, new deadline.
- Rota slot states: draft → (publish) awaiting → confirmed | declined | leaderConfirmed | contact.
- Pastoral visit (shared by phone + admin): requested → awaiting (pastor scheduled) → confirmed | postponed (member suggested alt) | declined → completed (private note). Member request creates "requested".
- Cell report submit → appears in Pastor's Cell reports; recap summary/testimonies become visible to cell members; offering row added to Cell giving (Pending until treasurer receipt).
- Sign-up: phone → code → details → pending; church approval and cell confirmation are independent states.
- Dark mode: full token swap (member app).
- Copy-to-clipboard and dialler handoff on Give; Add to calendar on duties/events/meetings.

## Data additions implied by these designs
`cell_meetings` (+ `cell_meeting_parts`: time, part, member_id), `cell_reports` (+ restricted `cell_report_pastoral_notes`), `cell_offerings` (meeting_id, amount, counter_1, counter_2, handed_over_at, treasurer_received_at, note — restricted RLS), `pastoral_visits` (member_id, reason, status, proposed_at, alt_proposed_at, visitor, location, source, private_note restricted), `service_occurrences` + `service_attendance` (counts, visitors). Respect spec privacy rules: no prayer/pastoral text in push previews; Admin role alone doesn't see care notes.

## Files
- `design/BIC Kafue App.dc.html` — member app prototype (all phone screens; side panel switches role/theme and jumps to screens).
- `design/BIC Kafue Admin.dc.html` — admin web prototype (Admin / Cell leader / Pastor).
- `design/support.js` — prototype runtime (needed only to open the HTML files).
- `design/assets/` — logo files.
- `spec/Church App - v1 Spec.md` — functional spec (apply the scope changes above).
- `screenshots/` — reference captures (prototype shown at reduced zoom with the review side panel; the side panel is not part of the product).
  - Member app: `app-01-home-member` … `app-19-home-dark` (home member/leader/guest/dark, duties, duty detail, my cell, meeting recap, pastoral visits + request sheet, profile, Bible, hymn book, sermons, give + instructions, calendar, leader coverage, phone sign-up).
  - Admin: `admin-01-overview` … `admin-13-schedule-visit-modal` (admin overview, applications, member panel, cell groups, duty rotas, plan meeting, meeting report, cell leader overview, pastor overview, cell reports, cell giving, pastoral care kanban, schedule visit modal).
