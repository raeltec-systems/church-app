# Church App v1 Specification

Israel Muyoba · Original September 23, 2026 · Revised October 1, 2026

## Overview

A Flutter app for iOS and Android, backed by Supabase, for a church of under 200 members. It brings together sermons, events, the Bible and hymn book, membership, prayer, directory, groups and cell life. Its main operational job is to make assigned duties clear and help leaders follow up before something is missed.

Giving is a simple public **How to give** section: choose a method, read the church's instructions, and give through that provider outside the app. The supplied Mount Zion screenshots are the reference for the method list and numbered instructions. They guide the layout; their church details and payment destinations must not be copied.

**Why custom:** church ownership of its data, familiar local giving instructions, and duty coordination that fits the church's departments. There is no separate church-app platform subscription, but hosting, authentication SMS, any email service, storage and app distribution still have operating costs.

**Priorities**

1. Members know what they have been assigned, when and where to serve, and how to respond.
2. Leaders can see unconfirmed, declined and uncovered duties and follow up in time.
3. Public church content and giving instructions are easy to find without an account.
4. Member-only community features remain useful and appropriately private.

**Constraints**

- One developer builds and maintains it; favour small, reusable workflows.
- English only; members mostly have 4G/Wi-Fi. Cache public content and downloaded hymn/Bible text, but do not build general offline-first sync.
- Money moves outside the app. The app does not record whether someone gave.
- Staff tools live inside the mobile app, gated by role and the department or group being managed.
- Reminders must run on the server even when the app is closed. Push is helpful, but an assignment is confirmed only by an explicit response or a leader-recorded confirmation.

**Non-goals for v1**

- In-app payment processing, gift claims, transaction verification, giving histories, receipts, annual statements, financial reports or cell-collection reconciliation.
- Payment-provider integrations, card checkout or recurring-giving management.
- Livestreaming, devotionals, reading plans, multi-branch support and a web admin portal.
- Direct member-to-member messaging, automatic rota optimisation, direct duty swaps, automated SMS or WhatsApp reminders.

## Roles and permissions

Guest and Pending are access states. Online member access requires an authenticated account linked to an approved member record, with no security hold. An approved record can exist without an account for leader-managed duties and attendance. Approved members with accounts can hold Media, Pastor or Admin roles. Department leaders, cell leaders and group leaders are scoped assignments, not church-wide access. A person may hold several roles or lead several teams.

| Capability | Guest or Pending | Approved member | Scoped leader | Media | Pastor or Admin |
| --- | --- | --- | --- | --- | --- |
| Public content and giving instructions | View published | View published | View published | Manage church content | Manage church content |
| Publish giving methods and destination details | No | No | No | No | Admin only |
| Own duties and responses | No | View and respond | Same | Same | Same |
| Department rota and follow-up queue | No | Own assignments only | Manage own department | Own assignments only | Church-wide oversight; Admin can manage |
| Cell attendance, reports and follow-up | No | Assigned follow-up only | Manage own cell | Assigned follow-up only | Pastor: authorised care oversight; Admin: membership, leadership and task routing, without private care content unless separately authorised |
| Prayer requests | No | Submit and view own | Own, unless on prayer team | Own, unless on prayer team | Pastor access as described below; Admin role alone adds none |
| Directory | No | Opted-in fields | Same | Same | Approved member records for pastoral care |
| Group chat | No | Own groups | Own groups and moderation | Own groups | All groups and moderation |
| Select or request a primary cell | In own application after phone verification | Request change | Same | Same | Same |
| Confirm cell membership | No | No | Own cell only | No | Admin after checking the relationship |
| Approve church membership, account links and roles | No | No | Recommend only | No | Admin only |

- Pastor and Admin are independently granted, even if the same person holds both. A designated **lead pastor** permission controls anonymous-prayer identity access.
- A **prayer team** flag grants access to prayer content under the rules in the prayer section.
- Department leaders manage members, duties, assignments and follow-up for their department. Cell leaders and assistants manage the cell duties delegated to them.
- No Treasurer application role is needed in v1. A treasurer who maintains giving instructions can be given an appropriate narrowly scoped editor permission later; v1 publication remains with Admin.
- Public content management excludes member records, private prayer content and giving destination details unless another permission explicitly allows it.

## Auth and membership

**Recommended v1:** phone-first sign-in with a one-time SMS code, optional email, and a church member record that can exist without a login. A member should not need to know an email address or remember a new password to use the app. Phone sign-in requires a configured SMS provider and an approved delivery budget; it is not a free built-in messaging service. [Supabase phone sign-in](https://supabase.com/docs/guides/auth/phone-login)

### Separate the person from the account

Keep three decisions separate:

1. **Authentication:** has this person verified a sign-in method?
2. **Church membership:** has the church approved this member record?
3. **Cell membership:** has the selected cell relationship been confirmed by its leader or Admin?

A stable member ID owns cell membership, department membership, attendance and assigned duties. An optional account link connects that member to Supabase Auth. A member can therefore be on a rota or cell register without owning a smartphone, having an email address or having a login. A verified phone number alone does not establish church membership or permission to enter a cell.

One login links to one person, and one member has at most one active login link in v1. Shared contact numbers may appear on several member records, but must never become shared credentials or cause those records to merge. No family-account switching or guardian proxy access in v1.

### Joining from the app

1. Choose **Continue with phone**, enter a number with country code, request a code and verify it. Use the displayed expiry/resend rules, clear wrong-number and retry actions, and generic errors that do not reveal another member's existence. Request a code only when the user asks.
2. Enter full name and **Which cell group do you belong to?** Choose a cell, **I'm not sure**, or **I'm not in a cell yet**. Email is optional contact information; skipping it never blocks phone registration or approval. Show the privacy notice.
3. Submit the membership request. Show **Awaiting church approval** and, separately, the selected cell or unresolved choice. The applicant may correct their own request but cannot set their membership or cell status.
4. Admin checks the application, resolves possible duplicate member records and approves, rejects with an optional reason, or requests clarification. Where a known member record already exists, link the account to that record after identity checks instead of creating another person.
5. The nominated cell leader confirms that cell relationship, or Admin records a confirmation after checking with the leader. Admin may approve church membership and confirmed cell membership in one review; the two permissions remain separate. If the cell check is still outstanding, general member features may open while cell-private access remains blocked.

The cell chooser contains church-approved cell names and broad areas only. It must not expose member lists, private home addresses, phone numbers, chat or reports. “Not sure” and “Not in a cell yet” go to an Admin follow-up queue and do not block otherwise valid church membership. In v1, each member has zero or one primary cell; other ministries remain departments or groups.

A cell change creates a request rather than immediately moving the member. The new cell leader or Admin confirms it. The server then ends the old primary membership, activates the new one and updates any linked cell-chat access atomically. Leaving a cell removes its private access immediately; the responsible leader reviews any cell-owned follow-up tasks. General church membership is unchanged.

### Sign-in and continued access

- Keep a valid session signed in securely on the member's own device. Normal app reopening and token refresh must not trigger an SMS code or another membership review. Reauthentication is needed after logout, loss of the session, recovery or a security-sensitive change. Supabase supports refreshable sessions; configure and test the chosen session policy rather than promising sessions never expire. [Supabase sessions](https://supabase.com/docs/guides/auth/sessions)
- A normal returning OTP sign-in, including on a new device, opens the same already-approved account without another church approval. Registration approval and recovery review are different processes. A new device alone is not a reason to block access.
- Put an account into **Access review required** for a reported lost/changed number, suspected ownership dispute, recovery/relinking request or church-imposed security hold. Proposed dormancy default: after 90 days without authenticated member activity, require an identity recheck before private access; the church should approve the period. Evaluate dormancy against the previously stored activity timestamp before updating it. OTP verification, login and token refresh must not reset dormancy or clear a hold; only authorised member activity after access checks updates the timestamp. A hold is enforced server-side across existing and new sessions.
- During access review, show only a generic review/help screen and the current recovery request. Do not show old profile, prayer or chat data. Provide a clear church contact and an Admin queue; approval removes the hold after the required identity checks.
- **Residual risk:** an unreported recycled number can pass OTP and reach an existing active account before a hold or dormancy check applies. Phone OTP cannot automatically detect a change of owner. This is a conscious security/usability tradeoff of the simple v1 proposal, not a solved risk. The church must accept it before private member features launch, or choose an independent sign-in factor; device unlock alone would not protect a fresh sign-in by a new number holder.
- Optional email is contact information in the primary v1 flow, not an automatic alternate recovery credential. Never merge accounts merely because contact details match. If the church chooses an email sign-in alternative, verify it and link it through an explicit identity-checked account flow.
- A leader helping with signup may explain the screens, but must not collect, save or forward the member's code, choose a shared password, or leave the member signed in on the leader's phone. Clear sensitive local caches and device registrations on sign-out/account change.

### Members without a personal phone or usable email

- Admin can create or approve a member record with the person's permission, assisted by the relevant leader. Record name, confirmed cell, optional contact route and who entered/confirmed it. Do not fabricate an email address or create a dummy login.
- An approved member record without an app account can receive duties and appear in authorised attendance lists. The leader sees **Needs direct contact**, contacts them through an agreed route or in person, and records a leader-confirmed response. Do not silently count a queued push as contact.
- If the member later obtains a personal sign-in method, verify it and have Admin link the new account to the existing member ID; preserve their duties and attendance history without creating a duplicate.
- A relative's number may be an explicitly agreed contact route, clearly labelled with whose number it is. It does not grant the relative access to the member's private information, inbox or prayer requests. Avoid sensitive notification previews on shared devices.
- For minors, use the church's agreed safeguarding/consent process, minimise collected details and keep youth contact/directory access disabled until that process is approved. Do not treat an adult's phone verification as a child's identity verification.

### Changed numbers and secure recovery

- **Still signed in:** request a number change through the account flow, verify the new number and complete the church identity check before replacing the old credential or account link. Warn about any conflicting account; never overwrite or merge automatically.
- **Lost phone or no longer receiving codes:** offer **I need help accessing my account**. Admin verifies the member using an established church relationship or an in-person check, records the reason and verifies the replacement sign-in method. A name, birthday, matching number or forwarded code alone is insufficient.
- **Lost or compromised device:** place the account on a security hold where necessary, revoke affected auth sessions, remove push registrations and preserve the member record and duties. Recovery must not require access to a lost email account or the old SIM.
- **Known recycled number or duplicate claim:** immediately hold private access while Admin investigates, then explicitly link, separate or correct records with an audit trail. Never treat an OTP as evidence that the new holder owns the historical member record. Unreported recycling remains the residual risk described above. Keep internal member IDs stable; phone numbers are changeable contact/authentication attributes.
- Only authorised staff can approve account relinking or access recovery; no self-approval of a staff recovery or security hold. Before launch, document first-Admin setup and an identity-checked fallback for loss of the last Admin's device. Do not build an unaudited “change anyone's number” shortcut.

Supabase supports phone/password sign-in too, but it retains password/recovery support work and its documentation warns about recycled numbers. It is not the recommended shortcut for avoiding SMS setup or identity checks. [Supabase password authentication](https://supabase.com/docs/guides/auth/passwords)

### Delivery costs and the fallback decision

- Choose one Supabase-compatible SMS provider, confirm its current Zambia route and sender requirements, complete required sender registration, and test real delivery across the church's relevant networks before enabling phone signup. Twilio's published Zambia guidance calls for sender-ID registration and warns about numeric-sender support on MTN, Airtel and Zamtel; this makes it a candidate to evaluate, not a preselected or already-working provider. [Twilio Zambia guidance](https://www.twilio.com/en-us/guidelines/zm/sms)
- Obtain an actual quote for messages/segments, registration or sender fees, any verification-product fees, taxes and retries. Budget for initial onboarding plus future sign-ins and recovery. No fixed SMS price or delivery guarantee is assumed in this spec.
- Set resend cooldowns, verification limits, abuse protection, spending alerts and an operational stop-send limit. Check both Auth and provider limits; never rely on a disabled resend button alone. Show a helpful support route for delays, exhausted limits or an outage. [Supabase rate limits](https://supabase.com/docs/guides/auth/rate-limits)
- SMS here is for authentication. Duty reminders remain push, in-app and leader contact; adding phone sign-in does not silently add paid SMS rota reminders.
- **If the church cannot fund or reliably deliver SMS:** use verified email sign-in for people who can access email, with production email delivery configured, and leader-managed member records for everyone else. Keep public content open. This is an explicit reduced-access fallback: members without either usable channel will not have personal member-app access yet. Do not hide that limitation with fake emails, shared passwords or an unverified custom PIN system.

### Membership and account lifecycle

- **Pending/rejected requests:** public content and the applicant's current request status only. Phone verification does not bypass approval.
- **Disable or recover login:** suspends online access while keeping the person's church membership, cell register and duties intact; leaders use direct contact meanwhile.
- **Deactivate church membership:** removes community access and directory visibility, revokes auth sessions, and flags future duties/owned follow-ups for reassignment. Admin can restore membership through a reviewed process.
- **Full deletion:** provide an in-app request and a staff-assisted route for members with no login. Revoke sessions and delete the Supabase Auth user and its sign-in identities, personal member/profile and account-link data, personal application/recovery data, authored chat content and attachments, prayer content and device tokens; reassign open work and remove identity/private notes from retained operational records. Do not silently retain an identifiable member record under a second account. Document backup retention and distinguish full deletion from simply removing login access.
- **Public access:** sermons, events, announcements, cleared Bible/hymn content and giving instructions require no account.

## Navigation and visual style

- **Bottom tabs:** Home, Bible & Hymns, Sermons, Give, Calendar.
- **Top bar:** church logo and name, chat icon with unread badge, search and profile. Hide member-only shortcuts for guests; public tabs remain fully usable.
- **Member Home:** a prominent **My duties** card above the poster feed, showing the next assignment and the count awaiting response. **My follow-ups** appears when the member owns open work. These are one-tap entry points, also available from the profile menu.
- **Leader Home:** an additional **Needs attention** card for unfilled slots, overdue responses, recent declines, upcoming conflicts and overdue follow-ups. Pastor sees the church-wide overview; leaders see their own scope.
- **Home content:** swipeable upcoming-event and campaign banners, with the yearly theme first, followed by poster cards for events and sermon series.
- **Calendar:** public events in a list with date badge, thumbnail and start/end time. Signed-in members can enable **My duties** and **My cell** overlays without exposing anyone else's rota. A duty detail opens directly from its calendar entry.
- **Sermons:** latest series poster, then the sermon list; detail opens the player and notes.
- **Give:** a **How to give** list with a method/provider name, optional logo and a short purpose or currency subtitle. A row opens instructions and copyable details.
- **Profile:** church approval status and a separate **My cell** status (confirmed, awaiting confirmation, not sure or not yet in a cell), request/change-cell action, notification settings, departments, prayer, directory, account controls and staff tools. Pending applicants see their application status without private community data.
- One sign-in covers all member features, including messaging. Notification links return to the correct item after sign-in and permission checks.

Use church brand colours, a light content area and dark mode. Poster cards use 16:9 thumbnails while allowing the original poster to be opened. Include readable text alternatives and cache images. Use large touch targets, text of at least 16sp where practical, scalable text and status labels that do not depend on colour alone.

## Departments and assigned duties

This is a core launch feature. The app should replace repeated checking of paper rotas and scattered messages with one current assignment list and a clear follow-up queue.

### Set up departments and duties

- Admin creates departments such as ushering, cleaning, intercession, preaching and Christian education, assigns a leader and optional deputy, and adds approved members.
- Each department defines duties such as Main door, Cleaning after service, Lead Tuesday prayers or Sunday teaching. Members may serve in several departments.
- A duty slot contains department, duty, date, start/end time, reporting time if earlier, location, optional linked event, leader instructions and optional topic/scripture.
- If a duty needs several people, create one position per person within the same stable duty occurrence. Show “2 of 3 confirmed”, derived from its active positions, so partial coverage is visible. Occurrence-wide edits or cancellation update affected positions together; reassignment changes only the selected position.
- Preaching and teaching slots can supply a draft topic/scripture reference for a sermon record; the media team reviews it before publication.

### Create and publish a rota

1. The leader creates one-off slots or generates repeated occurrences, such as every Sunday, for a chosen date range.
2. The leader assigns members and reviews gaps, overlapping duties and each person's upcoming load.
3. Drafts are visible only to the managing leader, their deputy and authorised Pastor/Admin. Publishing makes assignments visible to assignees and creates notifications.
4. Each published assignment starts **Awaiting response**. The member can **Accept** or **Can't make it**, with an optional note.
5. A decline immediately flags the position as needing cover and notifies the leader. The leader reassigns it; the replacement responds in-app or the leader records their explicit confirmation after direct contact.

Repeating patterns generate individual occurrences, not one shared response for an entire series. Editing a series must offer “this occurrence” or “this and future occurrences”; past assignments are preserved. A member may accept several listed future assignments together only after seeing the dates and confirming the selection.

### My duties

- Show **Needs a response**, **Upcoming** and **Past** lists across all of the member's departments.
- Detail shows the duty, department, date, reporting and service times, location, instructions, topic/scripture if any, response deadline and leader contact route.
- After acceptance, show **Accepted** with a **Can't make it anymore** action. A later decline reopens the coverage issue immediately.
- Offer **Add to calendar** and a deep link back to the live assignment. Explain that an exported calendar entry may need updating after a change.
- Empty state: “You have no upcoming duties.” A network error must not look like an empty rota or a successful response.
- Pending offline actions show **Not sent** until confirmed by the server. The leader must never see an acceptance that exists only on the member's device.

### Leader follow-up and coverage

The department dashboard shows the next seven days by default, with date and duty filters:

- **Unfilled:** positions without a current assignee.
- **Awaiting response:** assigned members who have not accepted or declined, with response deadline.
- **Overdue response:** deadline passed without a response.
- **Declined or changed:** assignments that need a replacement or a new confirmation.
- **Confirmed:** accepted positions, alongside total positions required.
- **Needs contact:** unresolved responses and members with no active push device or known notification problems.

For each issue the leader can open the assignment, contact the member using contact details made available for their department, record a brief contact attempt and next follow-up date, or reassign. Contact actions open the phone or messaging app; v1 does not send SMS or WhatsApp automatically. Contact notes must stay practical and avoid pastoral or medical detail.

If a member confirms by phone or in person, including a member without a login, the leader can record **Confirmed by leader**, with who recorded it, when and a short reason. Keep this distinct from a member's own acceptance. Opening a notification or sending a push never counts as confirmation.

Pastor sees coverage gaps and overdue follow-ups across departments. Admin can appoint a deputy or new leader when the usual leader is unavailable. Member assignment histories support fair workload discussions; they are not public rankings.

### Changes and completion

- Changing the date, reporting/start/end time, location, duty or assignee sends a change notice and requires a fresh response from affected assignees. Create a pending assignment revision with a recalculated response deadline and supersede the previous revision, preserving its response, actor, time and member/leader-recorded provenance. Only the current revision contributes to confirmed coverage. A notes-only edit sends an update without resetting acceptance.
- Reassignment preserves the previous response in history and cancels the old assignee's pending reminders. Cancellation removes the duty from upcoming work and informs affected members.
- Warn on overlapping time ranges across departments. Leaders may override a conflict with a reason; the assignee still chooses whether to accept. Availability collection is deferred, so the app does not assume a member is free just because no conflicting assignment exists.
- After the duty, the leader records **Completed**, **Excused** or **No-show**, with a correction path and optional short note. Passing the time does not automatically mean a no-show.
- Keep response, coverage and attendance separate: an accepted duty can later be cancelled, and a declined assignment should not become a no-show.
- Members cannot directly swap duties in v1. The leader remains responsible for approving and publishing any replacement.

## Reminders and follow-up

Use a shared in-app notification inbox and server-side scheduling for duty reminders, visitor follow-ups and missing cell reports. Push opens the relevant item; the inbox remains available when push is disabled or missed. Reminders should make the next action clear.

### Proposed duty reminder defaults

These are starting defaults for church approval, not fixed policy. All times use the configured church time zone and appear with that zone where ambiguity is possible.

| Trigger | Member action or message | Leader action or visibility |
| --- | --- | --- |
| Rota published or reassigned | New duty with Accept and Can't make it actions | Assignment enters Awaiting response |
| Response deadline | One reminder if still unanswered | Item enters Overdue response and the leader is notified |
| 24 hours before reporting time, or start time if none | Reminder to accepted and unanswered assignees; unanswered members are prompted to respond | Unresolved coverage stays prominent |
| 2 hours before reporting/start time | Reminder to confirmed assignees | No new escalation if already resolved |
| Member declines or an important detail changes | Response/result or change notice | Immediate coverage/change alert |
| Leader's next follow-up date arrives | Only the owner of that follow-up is reminded | Unfinished item remains due/overdue |

- Default response deadline: the earlier of 48 hours after publication or 24 hours before reporting/start time. If that time has already passed, mark the assignment **Short notice**, ask for a response now and alert the leader to contact the member.
- For short-notice assignments, skip reminder times already passed. Combine simultaneous messages for the same assignment instead of sending several alerts together.
- Stop response reminders on acceptance or decline. Stop all pending duty reminders on cancellation, reassignment, church-membership deactivation or removal from the department. Login suspension or a security hold cancels member-push jobs but preserves duties and routes outstanding contact needs to the responsible leader. A fresh assignment or material change creates a new revision and reminder schedule.
- Proposed quiet hours: 21:00–07:00 in the church time zone. Put routine reminders that would fall in quiet hours in the previous permitted evening window when they must arrive before the duty. Otherwise send at the next permitted time. A late-night short-notice change is immediately visible in-app; push waits until permitted, and the leader sees a direct-contact warning. No quiet-hours override in v1.
- Members with accounts can control push categories and group mutes; disabling push does not remove in-app tasks, deadlines or leader visibility. For members without accounts or while access is suspended, route the reminder need to the responsible leader's **Needs direct contact** list and do not create undeliverable member-push jobs. A relative's contact number never becomes an automatic notification destination.
- A provider accepting a push is not evidence that the member received or read it. The leader dashboard uses explicit responses and actual contact notes, not a “delivered” assumption. [Firebase message lifespan guidance](https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan?hl=en)

### Follow-up tasks

A follow-up task has a source, one accountable owner, a supervising leader, a next action, a due date/time and a status: **Open**, **In progress**, **Waiting**, **Done** or **Closed**. Open, In progress and Waiting are active states. Open/In progress use the due date; Waiting requires a next review date that becomes the next reminder deadline while the original deadline remains in history. Closing requires a reason. Owners see their tasks in **My follow-ups**, and supervisors see overdue items within their scope.

- **Duty follow-up:** the response/coverage queue is the source of truth. Recording a contact attempt may create a next-action task; resolving the assignment closes its response follow-up automatically. Do not create a second disconnected rota tracker.
- **Visitors and absent members:** the cell leader assigns a contact or visit task with a due date. Outcomes such as contacted, visited, joined, declined contact or unreachable are recorded separately from task status. If another attempt is needed, set the next action and date.
- **Missing reports:** an unsubmitted weekly cell report becomes due to its leader the day after the meeting. Remind then and three days after the meeting if still missing; Pastor sees the gap. Cancelled meetings do not require a report.
- **Task reminders:** notify on assignment and at the actionable deadline (due time for Open/In progress; review time for Waiting). If still active one day later, notify the supervising leader once for that deadline and keep the task overdue. Changing a review date is recorded, not a silent reset. For missing reports, use the specific report schedule above instead of both schedules. No daily stream of duplicate alerts.
- **Closure and reassignment:** cancel pending reminders when a task is done or closed; reassignment notifies the new owner and removes future reminders from the previous owner. Do not silently extend an overdue deadline. For an owner without online access, the supervising leader records contact and updates on their behalf with clear actor attribution.
- **Privacy:** only the assignee, responsible leader and authorised pastoral staff see private follow-up content. Admin can route tasks using non-sensitive owner, scope, status and deadline metadata; Admin alone does not grant care-note access. Anonymous prayer requests use their own private reply flow and do not automatically create a broadly visible task.

### Reminder reliability

- Store notification jobs durably with recipient, source ID, source revision, reminder type, due time and status. A unique deduplication key prevents the scheduler from creating the same logical reminder twice.
- Before sending, re-check that the source is current, still actionable and visible to the recipient. Cancel obsolete jobs after edits or reassignment.
- Retry transient delivery failures with bounded backoff until the message is no longer useful; record failures and retire invalid device tokens. Use a stable notification identifier to reduce duplicate display when retries have an uncertain outcome. Set expiry so an old duty reminder is not delivered after the duty.
- An admin health view shows last scheduler success, delayed jobs and failed deliveries. A visible in-app queue and leader contact process remain the fallback.
- Never put prayer text, visitor phone numbers or sensitive follow-up notes in lock-screen previews; use a generic message and an authenticated deep link.

## Giving instructions

### Member and guest flow

1. Open **Give** without signing in.
2. Choose a method from **How to give**, such as Airtel Money, MTN MoMo or a bank account approved by this church.
3. Read the method's numbered instructions and destination details. A subtitle can identify the purpose, such as Tithes & Offerings or Building Project, and currency where needed.
4. Copy the merchant code, account number or reference instructions, or open the phone dialler with the displayed starting USSD code where supported.
5. Complete the gift independently in the provider's USSD menu, mobile app, banking app or other church-approved channel.

Returning to the church app simply returns to the instructions. There is no payment-success screen, **Record my gift** button, claim form or giving history. The app does not request amount, transaction ID, sender phone, proof of payment or payer identity.

### Method details

- **Mobile money:** provider name and optional logo; beneficiary/church name; merchant, till or recipient identifier where applicable; numbered current steps; optional starting USSD code; and a short support note.
- **Bank:** bank name, account name, account number, branch/code where needed, currency, purpose and any transfer-reference instructions. Show copy buttons beside individual values.
- **Other church-approved methods:** an instruction-only entry for cash or another method if the church wants it. Do not invent a collection procedure.
- Show the last verified date and a church contact for questions. Ask the giver to check the beneficiary shown by their provider before confirming payment.
- Use the device's normal handoff to the dialler. Do not promise automatic USSD execution; if unsupported, keep the code and manual instructions visible and copyable.
- A method may have a purpose label, but there is no transaction-category ledger, amount allocation or financial reporting behind it.

### Administration and safeguards

- Admin can add, edit, reorder, publish, hide and archive methods. Draft changes are private until published. Public users can read only published methods.
- Confirm church ownership and accuracy of every destination before first publication and after any change; retain who changed and published it and when.
- Do not copy Mount Zion's beneficiary, account details, merchant identifiers or USSD selection steps. The church must supply and test its own information.
- Cache the last published instructions with their verification date and an offline label. On reconnect, refresh and remove hidden methods. If the church flags a method as unsafe, show an in-app warning as soon as the device refreshes; already-offline copies cannot be remotely erased.
- Finance records, reconciliation, receipts and cell cash collections remain in the church's existing processes outside the app. Do not recreate them in cell reports, admin dashboards or profile screens.

## Bible and hymn book

- **Bible:** chapter reader with book/chapter picker and translation switch. Use a licensed API or text cleared for the intended distribution and offline use. Reading plans are deferred.
- **Hymn book:** searchable by number, title and first line. Each hymn has number, title, verses and chorus, with optional key and audio.
- **Favourites:** members can save hymns. A **Hymns for this Sunday** list is set by an authorised worship leader or Media and appears on Home on Saturday.
- Import content through a CSV or plain-text admin tool, then edit in-app with Media permissions. Bundle or download cleared hymn text for offline reading.
- The church must confirm rights for the underlying hymn lyrics, translations and recordings. Owning a compilation does not by itself establish permission for every item in it.

## Sermons

- Each sermon has title, speaker, date, series, scripture reference, rich-text notes, YouTube video ID and optional audio file.
- Video uses an embedded YouTube player. Audio is stored in Supabase Storage with background playback and lock-screen controls.
- Browse by latest, series and speaker; search by title. Media uploads and edits.
- Unavailable video shows a clear message and any available audio/notes. Include broken-link checks in the media runbook.

## Events and announcements

- Events contain title, description, start/end, location and optional poster, plus optional RSVP and capacity.
- **Add to calendar** exports an event to the phone calendar. Multi-day events display both endpoints.
- Announcements are short posts that can be pinned, with an optional push on publication.
- Linking a duty to an event does not expose the rota publicly. A linked event time or venue change flags affected duties for leader review; the leader must confirm and publish each updated duty before replacement reminders are generated. The dashboard shows the unresolved mismatch.

## Prayer requests

- Members choose **Named** or **Anonymous to the prayer team**. Named requests are visible to the prayer team and authorised pastors. For anonymous requests, the prayer team sees the text without the author's identity; only the designated lead pastor and the author can access the identity link.
- Explain this visibility before submission. Do not label it anonymous to everyone, and remind members that the text itself may identify them.
- Pastor can mark a request **Prayed for** and send a private reply visible to the author. Members can view, edit or close their own requests. Closed requests archive after 90 days under the agreed retention policy.
- Keep the author/identity mapping separate from the prayer-team-readable record. RLS filters rows; it does not hide one sensitive column in an otherwise readable row. Use appropriately restricted tables or a narrowly scoped server interface.

## Member directory

- Hidden by default. A member opts in and chooses visible fields: photo, phone, email and birthday day/month only.
- Search by name, with call, WhatsApp and email actions only for fields the viewer is allowed to see.
- Pastor/Admin can access approved member records for pastoral care. Department and cell leaders see only contact information needed for people they supervise, with this visibility explained at signup or assisted registration. A record without a login remains hidden from the member directory unless the person's explicit opt-in and field choices are recorded by authorised staff. A relative's contact details do not become public by default.
- Public visitors, pending accounts and other members cannot access hidden contact fields through the API or search.

## Group chat

- Admin creates groups such as choir, ushers, youth and cells. Group leaders add and remove approved members with active accounts within their groups. Cell-chat eligibility additionally requires confirmed membership of that cell; typing a cell name at registration is not enough.
- Realtime text, compressed images up to 1 MB each and 10 per message, emoji reactions, reply-to and per-user read state.
- New-message push with per-group mute. A muted group does not mute duty reminders, which have a separate setting.
- Leaders can remove messages in their group and mute a member to read-only or remove them. Members can report messages; reports go to the relevant leader and Admin.
- Blocking hides that person's chat content from the blocker. Blocking does not conceal an official assignment or prevent its response from reaching the responsible leader.
- After removal, a member loses group history access; retained messages follow the account-deletion and moderation policy.
- No direct member-to-member chat in v1. Complete the safeguarding and moderation decisions below before enabling youth groups.

## Cell groups

A cell has a leader, assistant, member list, meeting schedule and weekly report. It can be linked to a chat group, but meetings, attendance and follow-up must work without chat.

- **Setup:** Admin creates the cell and assigns leader/assistant, meeting day/time, venue with optional map pin, zone and a safe signup-list label. Admin or the scoped cell leader confirms membership requests under the auth/membership rules. Member records without accounts can belong to cells and appear in attendance; private app/chat access still requires a linked active account.
- **Meetings:** generate weekly occurrences; leader can cancel or move one. Members receive a day-before reminder. A change cancels obsolete reminders and notifies affected members using the same quiet-hours rules.
- **Attendance:** leader marks members present, absent or excused and records visitors with name and optional phone. Three consecutive held meetings marked absent generate a follow-up flag. Present or excused breaks the streak; cancelled meetings are skipped. Missing attendance requires leader review and must not produce an automatic absence or follow-up flag.
- **Visitors:** an assigned follow-up uses the shared owner, next-action, due-date and status workflow. Record only details the visitor agreed the church could use, including any contact preference. Stop contact tasks if they decline further contact.
- **Joining:** offer phone-based signup to a visitor with a personal phone, or assisted member registration if they lack a usable sign-in method. Invite through an agreed contact route or in person; do not assume email. Reuse the existing visitor/member relationship after checking identity. Do not invent credentials or bypass church/cell approval.
- **Weekly reports:** topic, attendance totals, testimonies, prayer needs and pastoral issues. Separate private prayer/pastoral fields from report metadata and restrict them to the cell leader/assistant and authorised pastoral staff. Admin can see submission status and route missing reports without receiving private care content. Pastor can filter authorised reports by cell/week and see gaps.
- **Pastor overview:** attendance trends, visitors this month, open/overdue follow-ups and missing reports. No collections, deposits or financial totals.

## Architecture

The Flutter client uses Supabase Auth, Postgres, Storage and Realtime. Database permissions and RLS enforce access; server functions handle privileged workflows and notification scheduling. No separate long-running custom API server is needed.

| Layer | Choice | Responsibility |
| --- | --- | --- |
| Client | Flutter for iOS and Android | Riverpod state management, go_router deep links, local content cache |
| Auth | Supabase Auth | Phone OTP, session management and verified credential changes; optional email route only if chosen |
| Data | Supabase Postgres | Separate member records, account links and cell membership; content, rotas and follow-ups with grants/RLS |
| Realtime | Supabase Realtime | Scoped chat updates and refreshed assignment/task status |
| Files | Supabase Storage | Sermon audio, posters, chat images, avatars and cleared hymn assets |
| Server logic | Edge Functions and transactional database functions | Authorised assignment changes, notifications, controlled account deletion |
| Scheduler | Supabase Cron invoking server-side work | Durable due-job processing and recurrence generation |
| Push | Firebase Cloud Messaging with iOS delivery configured | Per-device tokens, notification expiry and deep links |
| Auth SMS | One evaluated Supabase-compatible provider | OTP delivery with Zambia sender/route verification, abuse limits and an approved budget |
| Email if needed | Production transactional provider | Optional verified email sign-in/recovery route if chosen; never mandatory for phone members |
| Video | YouTube embeds | Video playback without hosting church video files |

Supabase documents scheduled Edge Function invocation through Postgres scheduling. The reminder worker must still implement the source re-checks, deduplication and retry rules above. [Supabase scheduling documentation](https://supabase.com/docs/guides/functions/schedule-functions)

### Core data model

These are logical entities, not migration-ready SQL. Use foreign keys, explicit allowed states, timestamps and appropriate indexes; enforce transitions in server-side transactions.

- **Member records:** `members` with a stable `member_id`, pending/approved/rejected/deactivated membership state, private name/contact data and consent records; `directory_entries` containing only opted-in fields. A member record does not require an auth user, phone or email. Store household/relative contacts as labelled contact routes, not unique identities.
- **Accounts and applications:** `member_account_links` between member ID and Supabase Auth user ID, with active/suspended/review-required access status, last member activity, an approved sign-in credential snapshot/version and an audit trail; one active link per person/account. `membership_applications` records the applicant, proposed/existing member, review state and cell-choice response. `account_recovery_requests` records assigned reviewer and outcome without storing OTPs. `user_roles`, scoped leaders, `notification_preferences` and per-account `device_tokens` follow the active account link.
- **Cell choice and confirmation:** a safe `cell_signup_options` projection; `cell_membership_requests` for selection/transfer with requested cell or not-sure/not-in-cell choice, review status and reviewer; `cell_members` stores confirmed member IDs and effective dates. Enforce at most one current primary cell per member. A request never grants access.
- **Configuration:** `church_settings` with time zone, review/dormancy policy and operational contact; provider secrets remain server-side and are not ordinary settings fields.
- **Content:** `sermons`, `series`, `events`, `event_rsvps`, `announcements`, `hymns`, `hymn_favourites`, `sunday_hymns` and hymn/Bible content rights metadata.
- **Giving:** `giving_methods` with type, provider, label, purpose/currency, destination details, ordered instructions, optional dial code, sort order, draft/published/archived state, verification date and revision. Keep an existing published revision live until its replacement is published. No payer or transaction entities.
- **Departments:** `departments`, `department_members`, `duties`, `rota_series`, `duty_occurrences` and `rota_slots`. Each occurrence has a stable ID and optional series ID; its active slots define the required positions. A slot has reporting/start/end times, location, linked event, instructions, an immutable revision reference and draft/published/cancelled state. Preserve prior slot revisions for the assignment history.
- **Assignments:** `duty_assignments` with slot, slot revision, assignee, response deadline, pending/accepted/declined response, response actor/time and provenance, current/superseded/cancelled lifecycle, and optional completion outcome. A material change creates a new pending assignment record even if the assignee stays the same. Preserve the old response on its superseded record; allow only one current assignment per slot. A decline can remain current while the slot needs cover; reassignment supersedes it atomically.
- **Follow-up:** `follow_up_tasks`, `follow_up_activity`, restricted `follow_up_private_notes` and `duty_contact_attempts`; source, owner, supervisor/scope, next action, due/review date, status, outcome and visibility. Keep Admin-routable metadata separate from private descriptions, contact details and care notes.
- **Notifications:** `notification_jobs`, `notification_attempts` and `notifications` for the inbox. Jobs include source revision and a unique logical-reminder key; attempts record provider acceptance or failure without claiming the user has seen the message.
- **Prayer:** `prayer_requests`, a separately restricted `prayer_request_authors` identity mapping, and `prayer_replies`. Anonymous-team access never exposes the identity mapping.
- **Chat:** `groups`, `group_members`, `messages`, `message_reactions`, `message_reads`, `message_reports` and `blocks`.
- **Cells:** `cells` with optional `group_id`, leader/assistant, meeting schedule, venue and zone; `cell_members`, `cell_meetings`, `cell_attendance`, `visitors`, `cell_reports`, restricted `cell_report_pastoral_notes` and links to shared follow-up tasks. No `cell_collections`.
- **Identity references:** cell/department rosters, attendance, duty assignments and follow-up owners reference `member_id`; authenticated activity also records the acting account. Chat sessions, auth credentials and device tokens remain account-bound. Resolving an account link must never rewrite another person's authorship or share a household's private data.
- **Operational audit:** `audit_events` for permission changes, giving-method publication, assignment changes and recorded leader confirmations. Store actor, action, entity ID, changed field names and time; avoid copying prayer text, visitor contacts or full private notes into an unrestricted audit log.

### Access and reliability requirements

- Enable RLS and explicit least-privilege grants for every exposed table, and protect storage objects and any views/functions as well. Test allowed and denied reads/writes for Guest, Pending, Member, scoped leader, Media, Pastor and Admin. [Supabase RLS documentation](https://supabase.com/docs/guides/database/postgres/row-level-security)
- Member status, account links/security holds, staff roles and confirmed cell/department membership must be controlled by authorised server operations, never editable profile metadata. Protected access resolves `auth.uid()` through the active approved member link and current hold/dormancy state; matching a phone number is never an RLS ownership rule. Reject stale assignment updates.
- Before private access, compare the approved account binding with current trusted Auth credentials server-side. Any unapproved credential change is treated as review-required immediately, including changes through direct Auth update calls. Access remains blocked until identity review approves the new binding. Disable unselected sign-in routes; app-screen restrictions or client-supplied claims are insufficient.
- Assignment publication, reassignment, response recording and job creation/cancellation must be transactional so coverage and reminder state cannot diverge.
- Task assignees can record activity, outcomes and permitted status/review-date changes on their own tasks. Reassignment, supervisor and scope changes belong to the responsible leader or an authorised Admin. Source-specific sensitive content remains restricted regardless of routing permission. Members can respond only to their own current duty assignment revisions, not assign themselves or edit another member's response.
- Secret/service-role credentials remain server-side. Scheduled endpoints must authenticate their caller, and privileged functions must check their permitted action and target.
- Store timestamps in UTC with the church's IANA time zone for scheduling and display. Reporting time drives duty reminders when set. Daylight-saving changes, travel and device clock differences must not change the intended church time.
- Church-membership deactivation or role removal must immediately prevent protected access and cancel obsolete work, even if a device still holds an older sign-in token. A login security hold blocks access across sessions but preserves the member's duties/attendance, routing reminders to leader contact until access is restored.
- Back up both the database and stored files under an approved retention plan, and test restoration. Keep an admin runbook for approvals, account recovery, leader handover, notification failures and backup restoration.

## Important edge cases

| Area | Case | Required behaviour |
| --- | --- | --- |
| Giving | Dialler or USSD handoff is unsupported | Show/copy the code and manual instructions; never imply that a payment occurred |
| Giving | A method changes or is withdrawn | Publish reviewed details, refresh cached content, and show verification/offline state |
| Duties | A member never responds | Keep Awaiting/Overdue visible, notify leader at the deadline, and record direct follow-up |
| Duties | Push is disabled, token invalid or device offline | Preserve the in-app task; show known notification issues to the leader without inventing delivery/read status |
| Duties | Accepted member later declines | Reopen coverage immediately, notify leader, cancel that member's remaining service reminders |
| Duties | Same member has overlapping slots | Warn across departments; require a reason to override and retain the member's response choice |
| Duties | A published duty changes after acceptance | Require reconfirmation for material changes and cancel jobs for the old revision |
| Duties | Member opens an old notification | Show the latest authorised state; reject stale responses and explain what changed |
| Duties | Several people are needed but only some accept | Show confirmed count against required positions and keep remaining gaps visible |
| Duties | Leader is unavailable or leaves | Admin assigns a deputy/replacement; do not leave an active department without a responsible leader |
| Duties | Member is deactivated or leaves department | End current future assignments, flag vacancies and notify the leader |
| Reminders | Scheduler retries or runs twice | One logical notification, idempotent state changes, recorded attempts and expiry handling |
| Reminders | Assignment is made shortly before service | Immediate in-app alert, skip past reminders, show Short notice and direct-contact warning |
| Follow-up | Owner changes or task is closed | Cancel old-owner jobs and notify the new owner; stop reminders for closed work |
| Cells | No phone number or permission to contact visitor | Allow name only; leader decides an appropriate next step without inventing contact information |
| Cells | Attendance was never submitted | Mark the meeting record incomplete, not everyone absent |
| Cells | Weekly report is missing | Apply the report-specific reminders and keep it on Pastor's gap list |
| Prayer | Anonymous author needs a reply | Private in-app reply through the restricted identity mapping |
| Membership | Applicant selects the wrong cell | Keep the request pending/correctable; no private cell access until confirmed |
| Membership | Applicant is not sure or has not joined a cell | Admin follows up; church membership may proceed without a confirmed cell |
| Membership | Existing member signs up again | Review the candidate match and link the existing member ID; do not auto-merge on name/number |
| Membership | Several people share a contact number | Separate member records; no shared account and no automatic access for the contact person |
| Duties | Assignee has no account or login is on hold | Leader receives the contact task and records an attributed response; no lost-duty assumption |
| Auth | Normal returning sign-in or new device | OTP restores the same approved active account without blanket staff reapproval |
| Auth | Code delayed, wrong, expired or resend limit hit | Clear retry/correction and help path; no repeated automatic SMS requests |
| Auth | Number changes, access is disputed or recovery is requested | Hold private access, verify the person and replacement method, audit the link change and revoke obsolete sessions |
| Auth | Number is recycled without anyone reporting it | SMS-only may authenticate the new holder while the account is active; retain this explicit owner-approved risk rather than claiming detection |
| Auth | Account is dormant under the chosen policy | Require church identity recheck before private data access; keep member records and duties intact |
| Accounts | Last Admin or a key leader requests deletion | Complete an authorised handover or supported recovery path; do not leave the church locked out |
| Chat | Offensive content is reported | Hide it for the reporter immediately and send it to authorised moderation |
| Content | Video is removed or private | Clear unavailable state with other sermon material still accessible |

## Tradeoffs and launch decisions

### Tradeoffs

| Decision | Benefit | Cost or limitation |
| --- | --- | --- |
| Instruction-only giving | Small scope; no donor financial data or reconciliation workload | Giving confirmation and accounting remain outside the app |
| Duties and follow-up before chat | Addresses the stated coordination problem early | Realtime social features may arrive later |
| Push plus in-app tasks and human escalation | Low channel cost with visible outstanding work | Leaders still contact members who do not respond |
| Phone OTP with persistent sessions and approved membership | No mandatory email or new password for members | SMS costs/delivery requirements; recovery work and residual recycled-number risk |
| Member record separate from login | Includes members without personal phones and preserves attendance/duty history | Leaders handle their contact and record explicit responses |
| Scoped leaders and shared follow-up model | Consistent ownership without a large workflow engine | Permission rules need careful testing |
| Flutter and Supabase | Shared mobile codebase and managed backend services | Ongoing hosting and disciplined database/security work |

### Decisions for the church owner

1. **Access and registration:** approve the phone-first route, choose/quote/test the SMS provider, set a spending limit, and name staff responsible for membership, cell confirmation and recovery. Confirm the proposed dormancy period and explicitly accept the residual SMS-only recycled-number risk or choose an independent factor before private features launch. If SMS is unaffordable/unreliable, approve the reduced-access email-plus-assisted-registration fallback.
2. **Duties and reminders:** confirm the church time zone, initial departments and leaders/deputies, response deadline, reminder offsets and quiet hours. The defaults above make the spec buildable but should be checked with the people doing the follow-up.
3. **Giving content:** supply the actual methods, beneficiary/account details, purposes, currency, tested instructions and responsible Admin. The reference screenshots do not establish this church's destinations.
4. **Safeguarding and privacy:** decide how under-18 membership and youth groups are handled, who can see contact details, the designated lead pastor, consent for visitor follow-up and retention periods. Do not enable youth directory/contact features until safeguards are agreed.
5. **Content rights:** confirm permitted Bible translations, hymn lyrics and audio, and who maintains the Sunday hymn list.
6. **Launch scope:** confirm whether chat is needed on launch day. Duties, reminders and basic cell follow-up should not depend on chat being ready.

### Risks and release checks

- **Missed reminders:** push can be delayed or unavailable. Prove that server scheduling works with the app closed and that leaders can see unresolved work without relying on delivery claims.
- **Sensitive information:** prayer and visitor records need narrow access, safe notifications, clear consent and tested deletion/retention rules.
- **Public giving destinations:** a wrong or maliciously changed number can redirect money. Limit editors, record changes and require church verification before publication.
- **Store readiness:** check the current iOS/Android requirements for external giving instructions, user-generated content, moderation, account deletion and privacy disclosures before submission. Instruction-only giving is not a guarantee of store approval.
- **Content permissions:** clear the actual material before bundling or publishing it; remove unsupported assumptions that a compilation needs no licences.
- **Authentication and support:** budget and test OTP delivery, abuse controls, assisted registration and account recovery with members who are less comfortable with technology. Do not claim that OTP detects recycled numbers or that phone verification proves church/cell membership.
- **One developer:** keep launch scope small, document support procedures, identify a church-side owner and budget for production hosting, auth SMS, storage, any email service and store accounts using current provider prices.

## Milestones and acceptance criteria

1. **Foundation:** independent member records and account links, phone OTP pilot, assisted registration, church/cell approval, scoped roles, time zone and permissions. Test SMS delivery/cost controls, Guest/Pending restrictions, account holds/recovery and deletion before private data is loaded.
2. **Duties and reminders:** departments, draft/published rotas, My duties, responses, leader coverage queue, contact follow-up, notification inbox and server scheduling. Pilot with a real department before broad rollout.
3. **Public content and giving:** sermons, events, announcements, Bible/hymns and the instruction-only Give list. Verify every giving destination with church staff.
4. **Member care and cells:** prayer, opt-in directory, cell meetings/attendance, visitor follow-up and weekly reports using the shared reminder system.
5. **Chat if launch capacity allows:** groups, images, reactions, reporting, blocking and moderation; link existing cells without changing their attendance/follow-up data.
6. **Launch:** staff beta, accessibility and device tests, rights/privacy/store review, tested restoration and onboarding at church.

**Must pass before launch**

- A member can register with their own phone, leave email blank, select a cell and understand the separate church/cell approval states. Not sure and Not in a cell yet are valid choices.
- Selecting a cell never reveals its private data or joins its chat. Confirmed transfers remove old-cell private access and enable new-cell access atomically.
- Staff can include a consenting member without a phone/email, assign them a duty, mark attendance and record direct-contact confirmation. Linking a later login preserves their member ID and history.
- Normal reopening and token refresh send no OTP; ordinary returning/new-device sign-in does not request staff approval unless an explicit hold/dormancy rule applies.
- Test duplicate applicants, shared household contacts, optional email, changed/lost numbers, deliberate access holds and dormancy against API/RLS as well as screens. Document the remaining unreported-number-recycling risk; do not present it as a passing security guarantee.
- Test OTP delivery on relevant networks, resend/rate limits and spend controls with the selected provider. A production-ready quote/configuration and church approval are prerequisites to phone signup.
- A guest can open a giving method and follow numbered instructions without signing in. The app never requests or stores a gift amount, proof, transaction ID or payer identity.
- A leader can publish a multi-person duty, members can accept or decline, and the leader can identify all remaining gaps at a glance.
- A declined or unanswered assignment leads to a visible follow-up action; a replacement gets a new request while the old assignee stops receiving reminders.
- A material time/location change requires reconfirmation. A late response to the old revision cannot overwrite the new state.
- Reminder tests cover app closed, push denied, invalid tokens, short notice, quiet hours, recurrence edits, cancellation and worker retries. No stale reminder is sent for a resolved or superseded source.
- A visitor follow-up or missing report has an owner, due date, overdue visibility and a clear completion path. Completing it stops its pending reminders.
- Permission tests prove that a member cannot read another person's assignments, hidden contacts, private follow-up notes or anonymous prayer identity; scoped leaders cannot operate outside their teams.
- Content, hymn search, prayer, directory and cell workflows remain usable if chat is deferred.

## Later

Optional independent-factor/passkey access, local device unlock for privacy, a linked email sign-in option if needed, member-approved email/SMS duty reminders, availability collection and a more advanced rota workflow, web admin, livestreaming, devotionals and reading plans. Direct swaps and any payment processing or financial record-keeping would require a separate scope decision; they are not dependencies of this v1.
