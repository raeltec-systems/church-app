# Design contract

This companion carries the design requirements into the Church App specification. It covers native mobile and the responsive staff portal. The current functional requirements and approved no-SMS auth decision govern behaviour, access, data, scope and states; this contract governs visual fidelity, navigation and presentation subject to those rules. Preserve the supplied layouts while implementing the corrections below. The older specification bundled with the handoff is superseded.

## References and implementation boundaries

- [Member prototype](../../../docs/design-handoff/design/BIC%20Kafue%20App.dc.html) and [staff prototype](../../../docs/design-handoff/design/BIC%20Kafue%20Admin.dc.html) are high-fidelity HTML references, not production code. Their `class Component` scripts contain illustrative copy, mock records and simulated interactions. Recreate the mobile design in Flutter with Riverpod/go_router; validate the proposed Flutter Web staff implementation before adopting it. The HTML runtime does not select the production framework.
- [Prototype runtime](../../../docs/design-handoff/design/support.js) is needed only to open the HTML references, with their relative assets. It loads React/ReactDOM and supports the design-review environment; it is not an application API, backend or dependency requirement.
- The 32 screenshots below show the intended appearance at reduced review zoom. The phone frame, fake status bar/device cutout, surrounding canvas and review-side role/theme/jump panel are review equipment, not production UI. Use native safe areas and system status bars.
- All sample names, phone numbers, dates, giving destinations, amounts, attendance figures, role assignments, schedules and yearly-theme content are placeholders. Never ship the sample merchant/till `000000`, bank details, `*000#`, prescribed giving steps, sample contact routes or pretend operational records. Supply reviewed church content. Mock defaults, counters, toast messages and timers do not establish church policy or prove an operation happened.
- Ordinary copy and visual hierarchy remain close to the references; replace wording that claims consent, attendance, delivery, availability or access unsupported by current server state. Do not display “v1 prototype” or implementation guidance in the product.

## Tokens, type and geometry

Use semantic tokens for the full mobile light/dark swap. Staff web uses the light palette with the navy sidebar. Values are reference CSS pixels; map to logical native dimensions and scalable typography rather than locking the application to the screenshot size.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `bg` | `#F4F6FA` | `#0A0F1E` | Screen background |
| `surface` / `sf` | `#FFFFFF` | `#131A2E` | Cards, tabs, sheets |
| `surface2` / `sf2` | `#EDF0F6` | `#1B2440` | Date badges, segmented track, placeholders |
| `ink` | `#0E1530` | `#EDF0F7` | Primary text |
| `muted` / `mut` | `#586079` | `#9AA3BC` | Secondary text |
| `line` | `#DFE4EE` | `#26304D` | Borders and dividers |
| `primary` / `pri` | `#14246B` | `#2A6FD0` | Primary actions |
| `brand` | `#14246B` | `#DCE6FF` | Headings and brand |
| `link` | `#14246B` | `#8EC1FF` | Text actions and active tabs |
| `accent` / `acc` | `#0A7FE0` | `#3D9BF5` | Badges, verse numbers, highlights |
| `hero` | `#14246B` | `#182A7A` | Navy hero cards |
| `amberBg` / `amberFg` | `#FFF1CF` / `#6E4400` | `#3A2D10` / `#F5C866` | Awaiting and contact states |
| `greenBg` / `greenFg` | `#DFF3E8` / `#0D6438` | `#10301F` / `#7FD9A6` | Accepted and confirmed states |
| `redBg` / `redFg` | `#FCE5E2` / `#A3241A` | `#3A1614` / `#F4A29A` | Declines, gaps and overdue states |
| `blueBg` / `blueFg` | `#E3EEFC` / `#0B4FA6` | `#13284A` / `#9CC7FF` | Information and numbered steps |
| `grayBg` | `#EDF0F6` | `#1B2440` | Neutral chip; foreground = `muted` |

Additional accents: hero awaiting pill `#FFD66B` on `#3A2600`; coverage progress `#4FB0FF`; staff kanban column `#EBEEF5`; drop target `#DCE7FA` with 2px dashed `#0A7FE0`; dashed add/draft borders `#C9D0E0`; unfilled rota outline `#F0B8B1`; low-attendance reference bar `#E0A100` (the example 75% cutoff is not an approved church metric policy). Staff page background `#F4F6FA`, sidebar `#14246B`. Prototype canvas tokens `pageInk`/`pageLine`, device chrome and outer-canvas colours apply only to review equipment.

| Typography | Requirement |
| --- | --- |
| Families | Outfit 500/600/700 for headings and large numbers; Figtree 400/500/600/700 for body/UI; JetBrains Mono 400/500 for eyebrow labels, programme times and placeholder captions |
| Mobile | Screen title 28/700 Outfit in `brand`; section title 19/600; card title 17–18/600–700; body 16 minimum where practical; secondary 14; chips 13/600; tab labels 11.5, 700 active/500 inactive; detail toolbar title 20/600 |
| Reading | Bible text 18 with 1.6 line height; hymn text 19 with 1.55 line height; verse numbers in accent; italic chorus |
| Hero | Eyebrow 11 mono with .12em tracking; theme headline 22/700 Outfit; copy must come from current reviewed church content |
| Staff | Page title 24/700 Outfit `#14246B`; card title 17–18/600; body 15; table header 12/700 uppercase with .06em tracking, `#586079`; KPI values 30–34/700; modal title 21/700 |

- Radii: mobile hero/large cards 20–22; cards 16–18; mobile inputs 14; staff inputs 10; mobile buttons fully rounded (radius half height), staff buttons 10–12; chips 999; sheet top corners 26; date badges 12–14.
- Spacing: mobile horizontal content padding 16, forms 20; section gap 18–22; card padding 14–18; row minimum height 54–72. Icon targets 44×44 and targets at least 44; primary buttons 46–54 tall. Smaller reference controls must retain adequate hit areas and scalable labels.
- Shadows: mobile sheet none; sheet scrim `rgba(5,10,30,.5)`; toast `0 10px 30px rgba(0,0,0,.25)`; staff modal `0 30px 80px rgba(0,0,0,.25)`; active segment `0 1px 3px rgba(0,0,0,.12)`.
- Mobile reference frame 390×844 with 50px mock status bar; fixed top/bottom chrome and scrolling content. Top logo 44px white circle. Hero carousel cards width 310, aspect 16:9, radius 20, snap scroll. Bottom tabs have surface background and 1px top border. Full-screen details overlay tabs with a back chevron. Sheets overlay the current screen; toast is a dark `#0E1530` pill above tabs, about 2.2s for nonessential feedback. Persistent state must remain visible after a toast disappears.
- Staff sidebar 232px wide, sticky, padding 20/14, white-disc logo 84px; active navigation translucent white and blue count badges. Sticky white header padding 18/32; content max-width 1280, padding 28/32/48 and 24px gaps. Tables can scroll horizontally with useful minimum widths (member table 760px); responsive/list alternatives remain required. Modal width 460px, max-width 100%, radius 18, padding 24; two-column schedule fields with Member/Where full width; inputs/actions 42px in the reference, with accessible targets. Native date/time controls: derive date constraints from current church time, never the sample `2026-10-02`; 15-minute picker step is presentation guidance, not a settled scheduling policy.
- All statuses include readable labels, never colour alone. Preserve visible focus, keyboard operation, meaningful accessible names, text scaling, contrast and native safe areas. Dense grid/kanban controls require button/list alternatives. Exact screenshot fitting must not truncate real content or disable accessibility.

## Assets

- [Church emblem](../../../docs/design-handoff/design/assets/bic-logo.png): 1254×1254 white-background asset, displayed inside a white circle. It already contains the church name, so the app top bar uses the emblem alone with an accessible “Brethren in Christ Church Kafue” label.
- [White emblem](../../../docs/design-handoff/design/assets/bic-logo-white.png): transparent monochrome mark for navy surfaces, including the theme card with decorative concentric rings.
- Icons are simple 2px-stroke line icons, using Lucide/Material Symbols equivalents: home, book-open, microphone, heart, calendar, message, search, chevrons, copy, phone, map-pin and check.
- Striped posters/thumbnails and provider-logo slots are placeholders. Render reviewed 16:9 Storage images with text alternatives, caching and tap-to-open original posters. Do not turn striped placeholders into final content.

## Mobile screen and flow obligations

The five persistent tabs are **Home**, **Bible & Hymns**, **Sermons**, **Give**, **Calendar**. Top chrome has logo, search, chat/unread when available and permitted, and profile; guests receive Sign in. Guest/Pending/Member/Leader reference views are access presentations, not user-selectable permissions.

| Surface | Design obligation |
| --- | --- |
| Home | Theme first in horizontal banner carousel, then campaigns/events. Guest Join card. Pending card with separate church-approval and cell-status chips. Member navy My duties card shows awaiting count, next date/duty/department/report time/place, inline Accept/Can't make it and See all. Leader Needs attention four-up Unfilled/Overdue/Declined/Needs contact and current coverage; include conflicts and overdue follow-ups required by the specification. Relevant visit-response card. My follow-ups for **any** owner with open work. My cell with next meeting/topic/study leader and own programme part/status. Sunday hymn chips and Coming up 16:9 poster cards. |
| My duties and detail | Segments Needs a response (count), Upcoming, Past. Date badge and duty/department/report time/place/status. Empty copy: “Nothing waiting for your response.” / “You have no upcoming duties.” / “No past duties yet.” Detail: status, duty, department, date, report/service times, location, optional topic, deadline, instructions, permitted leader contact/Call, calendar export with stale-export caveat. Sticky state-dependent response footer. Decline sheet includes optional practical note and Cancel. |
| Leader coverage | Navy occurrence summary and confirmed/required progress; filters All, Unfilled, Overdue, Declined, Awaiting, Needs contact, Confirmed. Issue cards show allowed contact/record-confirmation/assign/reassign actions. Confirmation form captures provenance and required reason; label Confirmed by leader. Candidate list shows upcoming load and conflict warnings; require authorised conflict override reason. |
| Bible & Hymns | Bible/Hymn book segment. Bible book/chapter and cleared-translation picker, chapter heading, numbered verses, previous/next. Hymns search by number/title/first line; rows with large number, title, first line and Sunday chip. Detail has title/key, numbered verses, chorus and permitted Save/Saved favourite action. |
| Sermons | Series hero, Latest/Series/Speaker controls, thumbnail/title/speaker/date/scripture rows. Detail includes actual YouTube player, series, title, speaker/date, optional background audio and lock-screen controls, scripture and notes; unavailable media has a real fallback. |
| Give | Public How to give explanation and method/provider, optional logo, purpose/currency. Method detail contains individually copyable values, numbered current instructions, optional dialler handoff, beneficiary-check reminder, last verified date and real office contact. Remove sample-data banner only after replacing and verifying data. No amount form, payer data, gift record, payment-success state or donor history. |
| Calendar/event | Public event list with date badge, start/end, place and thumbnail; My duties/My cell overlays only for authorised own data. Duty opens duty detail, cell opens My cell, event opens full detail/poster and Add to calendar; multi-day endpoints remain visible. |
| My cell | Cell hero: name, leader/assistant, schedule/member count and separately gated chat. Next meeting: date/time, permitted venue/address/Directions, topic/scripture, ordered time/part/person programme with You highlight, own current response state, calendar export and Cannot attend notice. Last meeting: topic/scripture, optional aggregate attendance, when/where/actual leaders, clamped summary and Read recap; earlier published recaps list. |
| Meeting recap | Date/topic/scripture, safe venue and actual leaders, optional aggregate attendance, discussion summary, numbered key points, actual programme contributors, privacy explanation. Never render private report fields or imply publication from report submission. |
| Pastoral visits | Privacy explanation; proposal date/time/visitor/location and state-dependent Accept/Suggest another time/Decline or Change time actions; current requests, request action and concise history. Suggest-time sheet and explicit contact fallback; request sheet with reason choices Prayer/Illness/Bereavement/Counsel/Home blessing/Other, venue preference, time window and optional note; disabled submit until required fields valid. Distinguish request, proposal, agreement and outcome. |
| Profile and groups | Name/phone and distinct church/cell chips, request/correct/change-cell action. My cell, visits, duties, follow-ups, prayer, directory, departments, notifications, account and allowed staff tools; Sign out. Groups list has name, last message and unread badge only if chat launches and access permits. Pending sees application controls without private member menus/data. |
| Phone signup and sign-in | Preserve the form styling; collect normalized phone username, password and name with safe cell choices including I’m not sure/I’m not in a cell yet. Email is optional. Provide labelled show/hide password, password-manager/autofill and paste support, server validation, pending/failure states and a separate Sign in action. No Send code, SMS code entry or resend timer. Explain that a phone username is not verified ownership. Optional email is attached to the same account after phone signup and is eligible for recovery only after verification/approved binding; email setup failure does not remove the phone account. Request sent retains independent church/cell states. +260 is an initial country-picker presentation, not proof of location or ownership. |
| Password recovery and credential changes | Forgot password collects the previously verified recovery email and returns a neutral acknowledgement; never reveal an account’s email from its phone number. Show pending, sent, expired/used link, retry and support states from actual responses. No email or loss of that mailbox leads to identity-checked staff assistance. Password setup never clears holds or grants private access; require a fresh password sign-in after reset. Changing phone/recovery email uses the approved credential-binding workflow. Staff cannot view passwords. |

## Staff screens and flows

Navigation shows only granted roles/scopes. Admin, cell leader and Pastor screenshots are not the complete permission taxonomy: Treasurer, assigned counter, service recorder and pastoral visitor work must also be provided without broader access.

| Surface | Design obligation |
| --- | --- |
| Admin overview/members | Four operational tiles: applications, cell requests, duty gaps, draft slots; actionable attention list. Applications/All members segments; duplicate warning and identity-checked Link existing, Approve, Ask details, Reject. Searchable member table with name/contact, cell, departments, roles, App account/No login/Access review; Add member record supports no-login people. Side panel presents permitted fields and audited role/access/deactivation actions. |
| Cell groups/leader overview | Cell cards and selected outline, zone/count/leader/request badge; New cell. Authorised leader/assistant configuration, schedule/venue, membership confirm/not-in-cell actions and confirmed roster. Leader overview is scoped to own cell with requests, report due, follow-ups and member tiles. |
| Rota | Department filters, text status legend, positions × occurrence dates grid, per-date confirmed/required counts, coloured current slots, dashed draft/unfilled slots and inline candidate picker. Explicit Publish N draft slots; conflict reason, scope and current revision checks; accessible list controls equivalent to grid. |
| Meeting plan | Date, start/end, venue/address, topic/scripture; ordered programme editor with time, duration/end, part, optional assignee, add/remove and member preview. Publish/update/cancel actions drive linked duty revisions and reminders. Preview names are not accepted responses. |
| Attendance/report/recap | Actual Present/Absent/Excused/Unrecorded roster; visitors with consent-aware contact fields and aggregate summary. Private weekly report and separate member-safe recap editor with key points, preview, publish/correct/withdraw and audience/consent cues. Offering status/link/editor appears only with appropriate finance scope; private care editor is never fetched for Admin alone. |
| Pastor overview | Authorised member/service/cell/care/report tiles; finance tiles only with separate grant. Eight-week attendance bars (latest accent, others navy), service-type switcher, values/dates; service table with last held/leader/attendances/comparable four-week basis/visitor attendances/next occurrence; cell table with roster denominator, incomplete-data status, trend and report. Visits ahead and drill-down into authorised reports. All numbers derive from current records and explicit metric definitions. |
| Cell reports | List by cell/week and submission/missing status; selected detail with actual attendance aggregates, topic/discussion/testimonies and separately restricted care fields. Missing notice and reminder action use actual reminder/job state. Schedule-visit referral from authorised care report links source without copying sensitive text into broad metadata. |
| Cell giving | Scoped cell/date/state filters; counted/received/outstanding and discrepancy totals, clearly labelled currency/basis; table with meeting/cell, independent count attestations, handover/receipt status and practical custody notes. Two-counter action, custodian handover and independent Treasurer receipt are separate forms/events. Preview scope/columns before CSV export and apply specification safeguards. |
| Pastoral care | Board columns Requested, Awaiting member, Confirmed, New time suggested, Completed with counts; Declined/Cancelled/Not completed/Closed filters and equivalent list/keyboard/buttons. Cards show scoped safe details and permitted Schedule/Mark completed/Accept new time actions. Dragged card opacity 45%; drop target dashed blue. Schedule/complete drops open forms; all other moves still validate permitted transition and consent. Schedule form includes member, broad reason, authorised visitor(s), exact date/start/end or duration, zone and location. Completion records actual outcome and remaining care action. |
| Additional required staff work | Service-count capture/correction and unrecorded queue; counter attestation, independent receipt, discrepancies and amendments; assigned visitor cases; reminder health, recovery/handover and audited permission administration. Reuse the supplied typography/forms/tables; their absence from the screenshot set does not remove scope. |

## State fidelity and binding prototype overrides

1. **Separate recap publication.** The reference report submit action and “shared with cell members” labels are obsolete. A private report never publishes a recap/testimony. Use a separate safe revision, audience preview, publish/correct/withdraw, edited consented stories and no prayer/visitor-contact/named-absence fields.
2. **Independent offering custody.** Counter dropdown names are not attestations; the leader's Handed to the treasurer checkbox is not receipt. Implement two distinct explicit counters, attributed assisted actions, custodian handover and an independent authorised receiver different from both counters and custodian. Keep counted/handed/received amounts and discrepancy history separate; show Missing/No collection/zero/cancelled distinctly.
3. **Consent governs care.** Free movement to Confirmed and “Accept new time” shortcuts are superseded by agreement on the current proposal revision. Suggested slots do not prove availability. “None of these work” creates owned contact work; it must not promise an office call without an accountable task. Do not mark visits completed because time passed. The member's decline does not erase an open care need.
4. **Role/scope governs every screen.** The prototype's unrestricted role switch is review-only. Admin cell-meeting routes must not fetch/render care or finance fields without additional grants. Pastor finance totals need a separate finance grant. Pending profile/chat chrome must not reveal private data; favourites and cell access require their actual permissions. Chat launch remains a separate decision and cannot gate other modules.
5. **Honest mutation states.** App acceptance's 1.1-second timer, immediate decline/visit success, clipboard/dialler/calendar/audio/reminder/export toasts and local role toggles are simulations. Awaiting → Sending/Not sent → Accepted only on server confirmation; recoverable failures remain distinct from empty/success. Decline and later decline reopen coverage and cancel obsolete reminders. A permission-checked server response, verified local handoff or provider result governs the corresponding wording; no fabricated delivery/read claims.
6. **Intent, duty response and attendance remain separate.** My cell's Can't attend cannot mark the member Excused or silently decline a programme duty. Offer change/withdraw of the notice and a separate assignment response. The prototype automatically maps past duties to Completed and premarks most attendance Present: production requires actual leader-recorded outcomes and preserves Unrecorded. Recaps use actual contributors, not planned assignees.
7. **Validate transitions and drafts.** Prototype conflict choices only show a warning toast; production requires authorised reasoned overrides and cross-department/programme checks. Prototype chooses draft/awaiting from column position; production uses explicit draft/publication lifecycle. Material duty/meeting/visit changes require current revision checks, correct reconfirmation and cancellation of obsolete jobs. A staff-recorded confirmation remains visibly distinct from a member response, with actor/time/channel/reason as required.
8. **Metrics and collection labels are meaningful.** Sample KPI totals, hard-coded trends, fallback attendance counts, “Visitors this month,” broad “Giving” figures and 75% colour thresholds cannot invent complete data or unique people. Use count-definition versions, denominators, period/basis/currency and missing coverage; “Insufficient data” where required. Pending handover, Awaiting receipt and Received are not interchangeable.
9. **Complete the specified flows beyond screenshots.** My follow-ups is available to ordinary owners, not leader-only. Provide actual search, chapter/translation pickers, notification inbox/preferences, directory consent, prayer, account recovery/deletion and allowed staff forms even where the prototype only toasts. Explicit save/submission/validation/loading/error/stale-revision states, deep-link permission checks and accessible list alternatives apply across surfaces.
10. **Auth reference override.** The phone-signup screenshot’s Send code/PIN/resend sequence is historical. Implement the approved password and optional verified-email/staff recovery flows above on both surfaces; do not simulate verification or recovery success.
11. **Privacy follows current access.** Private programmes/recaps/venues, care and finance are not durable offline caches. Clear observed stale scope/session state without claiming remote erasure of an offline screen. Cell transfer ends old-cell access and resolves future old-cell assignments. Notifications carry generic authenticated links without sensitive care or contact text.

Confirmed scope includes all six additions: programmes, separate recaps, care visits, service counts, staff web and restricted cell offerings. Operational staff appointments, password/recovery controls and email delivery setup, reminder/time-zone policy, actual giving content, safeguards/testimony consent/retention, metric definitions, currency/custody deadlines, recap archive policy and web hosting/framework validation remain owner decisions or proposed defaults; visuals settle none of these.

## Screenshot map

These files are visual targets for their named state, with all preceding permission and state corrections applied.

| Member screenshot | Surface/state |
| --- | --- |
| [app-01-home-member](../../../docs/design-handoff/screenshots/app-01-home-member.png) | Member Home and duty/visit response cards |
| [app-02-my-duties](../../../docs/design-handoff/screenshots/app-02-my-duties.png) | Duties segments/list |
| [app-03-duty-detail](../../../docs/design-handoff/screenshots/app-03-duty-detail.png) | Duty detail and response footer |
| [app-04-my-cell](../../../docs/design-handoff/screenshots/app-04-my-cell.png) | Cell plan/programme and recap entry |
| [app-05-meeting-recap](../../../docs/design-handoff/screenshots/app-05-meeting-recap.png) | Safe published recap |
| [app-06-pastoral-visits](../../../docs/design-handoff/screenshots/app-06-pastoral-visits.png) | Own visit proposals/history |
| [app-07-request-visit-sheet](../../../docs/design-handoff/screenshots/app-07-request-visit-sheet.png) | Private visit-request sheet |
| [app-08-profile](../../../docs/design-handoff/screenshots/app-08-profile.png) | Profile and independent membership/cell states |
| [app-09-bible](../../../docs/design-handoff/screenshots/app-09-bible.png) | Bible reader |
| [app-10-hymn-book](../../../docs/design-handoff/screenshots/app-10-hymn-book.png) | Hymn search/list |
| [app-11-sermons](../../../docs/design-handoff/screenshots/app-11-sermons.png) | Sermon browsing |
| [app-12-give](../../../docs/design-handoff/screenshots/app-12-give.png) | Public methods list |
| [app-13-give-instructions](../../../docs/design-handoff/screenshots/app-13-give-instructions.png) | Copyable giving instructions |
| [app-14-calendar](../../../docs/design-handoff/screenshots/app-14-calendar.png) | Public list and own overlays |
| [app-15-home-leader](../../../docs/design-handoff/screenshots/app-15-home-leader.png) | Leader Home and attention summary |
| [app-16-leader-coverage](../../../docs/design-handoff/screenshots/app-16-leader-coverage.png) | Scoped coverage queue |
| [app-17-phone-signup](../../../docs/design-handoff/screenshots/app-17-phone-signup.png) | Phone/password signup; visual reference only, OTP interaction superseded |
| [app-18-home-guest](../../../docs/design-handoff/screenshots/app-18-home-guest.png) | Guest Home and Join/Sign in |
| [app-19-home-dark](../../../docs/design-handoff/screenshots/app-19-home-dark.png) | Full member dark palette |

| Staff screenshot | Surface/state |
| --- | --- |
| [admin-01-overview](../../../docs/design-handoff/screenshots/admin-01-overview.png) | Admin operational overview |
| [admin-02-applications](../../../docs/design-handoff/screenshots/admin-02-applications.png) | Membership/duplicate review |
| [admin-03-members-panel](../../../docs/design-handoff/screenshots/admin-03-members-panel.png) | Member side panel |
| [admin-04-cell-groups](../../../docs/design-handoff/screenshots/admin-04-cell-groups.png) | Cell setup/membership |
| [admin-05-duty-rotas](../../../docs/design-handoff/screenshots/admin-05-duty-rotas.png) | Rota grid and publication |
| [admin-06-plan-meeting](../../../docs/design-handoff/screenshots/admin-06-plan-meeting.png) | Programme editor/member preview |
| [admin-07-meeting-report](../../../docs/design-handoff/screenshots/admin-07-meeting-report.png) | Attendance/private report layout, corrected publication/custody |
| [admin-08-cell-leader-overview](../../../docs/design-handoff/screenshots/admin-08-cell-leader-overview.png) | Own-cell overview |
| [admin-09-pastor-overview](../../../docs/design-handoff/screenshots/admin-09-pastor-overview.png) | Scoped care/report/count overview |
| [admin-10-cell-reports](../../../docs/design-handoff/screenshots/admin-10-cell-reports.png) | Authorised report review |
| [admin-11-cell-giving](../../../docs/design-handoff/screenshots/admin-11-cell-giving.png) | Finance-scoped register |
| [admin-12-pastoral-care-kanban](../../../docs/design-handoff/screenshots/admin-12-pastoral-care-kanban.png) | Care board with consent-checked moves |
| [admin-13-schedule-visit-modal](../../../docs/design-handoff/screenshots/admin-13-schedule-visit-modal.png) | Current-proposal schedule form |
