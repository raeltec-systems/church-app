# Church App v1 Functional Requirements

Israel Muyoba · Original September 23, 2026 · Baseline revised October 2, 2026 · Authentication updated October 3, 2026

This spec-authored companion carries the full functional baseline from `../brief-church-app/inputs/church-app-v1-spec-1.2.md`, updated by the owner's October 3, 2026 approval of phone-number-and-password sign-in, optional verified email recovery and no SMS. The original 1.2 file remains unchanged as an audit source; this companion supplies the current functional requirements. All six approved first-release additions and all non-authentication domain requirements are retained. Implementation mechanisms remain subject to the architecture contract and foundation validation; this document does not claim that an auth backend has already been configured or tested.

## Overview

A Flutter app for iOS and Android and a role-gated staff web portal, backed by Supabase, for a church of under 200 members. They bring together sermons, events, the Bible and hymn book, membership, prayer, directory, groups, cell life and pastoral care. The main operational job is to make assigned duties clear and help leaders follow up before something is missed.

**Approved first-release additions:** cell meeting programmes, separately published member recaps, pastoral visit requests and scheduling, service attendance counts and trends, the staff web portal, and restricted cell offering records. All six are included in v1. Milestones sequence the work; they do not defer these additions. The BIC Kafue design handoff guides their layout, while the workflow, permissions and states in this revised specification govern implementation. All mock names, destinations, numbers and statistics are examples, not production data. Specific custody separation, metric conventions, recap archive access and reminder defaults below are proposed implementation rules for operational-owner confirmation before launch; approval of the six modules does not assert that these are existing church policies.

Giving is a simple public **How to give** section: choose a method, read the church's instructions, and give through that provider outside the app. The supplied Mount Zion screenshots are the reference for the method list and numbered instructions. They guide the layout; their church details and payment destinations must not be copied.

**Why custom:** church ownership of its data, familiar local giving instructions, and duty coordination that fits the church's departments. There is no separate church-app platform subscription, but hosting, production recovery/verification email delivery, storage and app distribution still have operating costs; authentication does not use SMS.

**Priorities**

1. Members know what they have been assigned, when and where to serve, and how to respond.
2. Leaders can see unconfirmed, declined and uncovered duties and follow up in time.
3. Public church content and giving instructions are easy to find without an account.
4. Member-only community features remain useful and appropriately private.

**Constraints**

- One developer builds and maintains it; favour small, reusable workflows.
- English only; members mostly have 4G/Wi-Fi. Cache public content and downloaded hymn/Bible text, but do not build general offline-first sync.
- Money moves outside the app. Public giving has no payer records or payment processing. The separate staff-only cell offering register records aggregate meeting collections, counters, handover and treasurer receipt; it never identifies individual donors.
- Staff use the responsive web portal for administration and reporting; essential leader actions also remain available in the mobile app. Both surfaces share the same account, role/scope checks, records and server workflows. A second screen must not create a second source of truth.
- Reminders must run on the server even when the app is closed. Push is helpful, but an assignment is confirmed only by an explicit response or a leader-recorded confirmation.

**Non-goals for v1**

- In-app payment processing, individual gift claims, payment-provider transaction verification, personal giving histories, donor/tax receipts or annual giving statements.
- Payment-provider integrations, card checkout, recurring-giving management, bank reconciliation, a general ledger, budgets, expense/payroll processing or full church accounting. Restricted cell collection counts, handover/receipt matching, discrepancies, summaries and CSV export are in scope.
- Livestreaming, devotionals, reading plans and multi-branch support.
- Direct member-to-member messaging, automatic rota optimisation, direct duty swaps, automated SMS or WhatsApp reminders.

## Roles and permissions

Guest and Pending are access states. Online member access requires an authenticated account linked to an approved member record, with no security hold. An approved record can exist without an account for leader-managed duties and attendance. Approved members with accounts can hold Media, Pastor, Admin or scoped Treasurer permissions. Service attendance recorders and pastoral visitors receive explicit scoped assignments. Department leaders, cell leaders and group leaders are scoped assignments, not church-wide access. A person may hold several roles or lead several teams.

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
| Select or request a primary cell | In own authenticated application; phone is an unverified username | Request change | Same | Same | Same |
| Confirm cell membership | No | No | Own cell only | No | Admin after checking the relationship |
| Approve church membership, account links and roles | No | No | Recommend only | No | Admin only |
| Cell programmes and published recaps | No | Own confirmed cell; own programme responses | Manage own cell | Same as member unless delegated | Authorised oversight; Admin has operational metadata, not private care content |
| Pastoral visit requests and appointments | No | Own requests and member-visible appointment details | Only explicitly assigned care cases | Same as member | Authorised pastoral team manages; Admin alone has routing metadata only |
| Service attendance counts | No | No, unless appointed recorder | Record assigned service types/occurrences | No, unless appointed recorder | Pastor views; Admin manages recorder assignments and authorised operational reports |
| Cell offering register | No | No, except assigned counter action on that collection | Own-cell collection preparation and handover | No | Pastor only with finance oversight; Admin role alone grants no financial record access |

- Pastor and Admin are independently granted, even if the same person holds both. A designated **lead pastor** permission controls anonymous-prayer identity access.
- A **prayer team** flag grants access to prayer content under the rules in the prayer section.
- Department leaders manage members, duties, assignments and follow-up for their department. Cell leaders and assistants manage the cell duties delegated to them.
- **Treasurer** is an explicitly assigned finance permission with an authorised cell/church scope. It permits receipt, discrepancy review, collection summaries and authorised CSV export within that scope; it grants no prayer, pastoral, chat or membership-management access. A designated deputy can cover absence. Assigned counters may attest only their own collection count; they do not gain the full register. Pastor finance oversight is granted separately. Admin manages permission grants and task-routing metadata, but does not inherit finance or care content. Public giving-method publication remains Admin-only.
- A **pastoral care** assignment identifies the staff allowed to triage a request, supervise it or conduct the visit. A visitor sees only assigned cases and the details needed for the visit; a church title or a prayer-team flag does not automatically expose all care cases. A Pastor may receive church-wide care oversight explicitly.
- A **service recorder** assignment identifies the service types or occurrences a person may record. It does not grant member-directory or private care access. Role/scope changes are audited and take effect on mobile and web immediately.
- Two roles held by one person do not erase separation of duties: the treasurer receiving a collection must be different from its counters and handing-over custodian. No one may manufacture another member's visit or duty consent.
- Public content management excludes member records, private prayer content and giving destination details unless another permission explicitly allows it.

## Auth and membership

**Approved v1:** sign in with a phone number and a user-chosen password. Email is optional; a previously verified email linked to the same account and included in its approved credential binding can recover a forgotten password. No SMS is used for registration, sign-in, credential changes or recovery. A member without a recovery email uses identity-checked staff-assisted recovery. The phone number is a normalized, unique **unverified username**: entering it proves neither control of the number nor church membership. Supabase Auth manages passwords and sessions; there is no custom password database, invented email identity, shared login or custom authentication PIN. [Supabase password authentication](https://supabase.com/docs/guides/auth/passwords)

### Separate the person from the account

Keep three decisions separate:

1. **Authentication:** has this person supplied valid credentials for this account? Phone-and-password authentication does not verify ownership of the phone number.
2. **Church membership:** has the church approved this member record and its link to the account?
3. **Cell membership:** has the selected cell relationship been confirmed by its leader or Admin?

A stable member ID owns cell membership, department membership, attendance and assigned duties. An optional account link connects that member to Supabase Auth. A member can therefore be on a rota or cell register without owning a smartphone, having an email address or having a login. Neither knowing a phone number nor authenticating to an account establishes ownership of an existing church member record or permission to enter a cell.

One login links to one person, and one member has at most one active login link in v1. Normalize sign-in numbers consistently to international format with country code and enforce uniqueness at the account-credential boundary. Shared contact numbers may appear on several member records, but must never become shared credentials or cause those records to merge. A contact number is not an account lookup or ownership rule. No family-account switching or guardian proxy access in v1.

### Joining from the app

1. Choose **Create account**, enter a phone number with country code and choose a password. Label the number as the sign-in username; do not show an SMS code, resend action or a claim that the number was verified. Provide password visibility, accessible guidance and generic failure/help states without disclosing an existing member's identity or private records. Normalize and validate the number server-side, enforce the password policy through Supabase Auth, and reject a conflicting username without overwriting or merging an account.
2. Enter full name and **Which cell group do you belong to?** Choose a cell, **I'm not sure**, or **I'm not in a cell yet**. After creating the phone-and-password account, offer an optional **Recovery email** through the same-account email-addition and verification flow; the native phone signup does not create a separate email account or combine two identities in one signup request. Explain that the email must be verified and approved before it can recover this same account. Skipping or not yet verifying email never blocks phone-and-password registration or otherwise valid church approval; show that staff help will be needed if the password is forgotten. Show the privacy notice. Contact/directory email consent remains separate from recovery-email verification.
3. Submit the membership request. Show **Awaiting church approval** and, separately, the selected cell or unresolved choice. The applicant may correct their own request but cannot set their membership or cell status. An authenticated pending account can access only its permitted application/recovery status and public content.
4. Admin checks the applicant's identity through an established church relationship or an in-person check, resolves possible duplicate member records and approves, rejects with an optional reason, or requests clarification. Where a known member record already exists, explicitly link the account to that record after identity checks instead of creating another person. Never link, merge, approve or disclose a member record automatically from a matching phone number, email address or name.
5. The nominated cell leader confirms that cell relationship, or Admin records a confirmation after checking with the leader. Admin may approve church membership and confirmed cell membership in one review; the two permissions remain separate. If the cell check is still outstanding, general member features may open while cell-private access remains blocked.

The cell chooser contains church-approved cell names and broad areas only. It must not expose member lists, private home addresses, phone numbers, chat or reports. “Not sure” and “Not in a cell yet” go to an Admin follow-up queue and do not block otherwise valid church membership. In v1, each member has zero or one primary cell; other ministries remain departments or groups.

A cell change creates a request rather than immediately moving the member. The new cell leader or Admin confirms it. The server then ends the old primary membership, activates the new one and updates any linked cell-chat access atomically. Leaving or transferring from a cell removes its private access immediately; supersede/cancel future old-cell programme assignments and their jobs, flag vacancies to the old leader, and review/reassign any cell-owned follow-up tasks. Preserve historic responses and attendance; a transfer never silently carries an old-cell assignment into the new cell. General church membership is unchanged.

### Sign-in and continued access

- The product sign-in screen asks for **Phone number** and **Password**, with **Forgot password?** and **Get church help** routes. It does not send SMS. The same account and member link work on mobile and staff web.
- Private member/staff access requires a trusted Supabase-issued session containing password authentication, as well as the current account/member/hold/scope checks. Email verification, OTP or recovery-session authentication alone cannot unlock private data. Public content, permitted application status and narrowly authorised recovery actions remain available in their appropriate states. Test the provider's signed authentication-method claim rather than trusting a client flag.
- Keep a valid session signed in securely on the member's own device. Normal app reopening and token refresh must not request the password again or trigger another membership review. Reauthentication is needed after logout, loss of the session, recovery or a security-sensitive change. Supabase supports refreshable sessions; configure and test the chosen session policy rather than promising sessions never expire. [Supabase sessions](https://supabase.com/docs/guides/auth/sessions)
- A normal returning phone-and-password sign-in, including on a new device, opens the same already-approved account without another church approval. Registration approval and recovery review are different processes. A new device alone is not a reason to block access.
- Put an account into **Access review required** for an accepted staff recovery/relinking case, a reported lost/changed username, a suspected ownership dispute or a church-imposed security hold. A public forgot-password request alone must not suspend another person's account. Proposed dormancy default: after 90 days without authenticated member activity, require an identity recheck before private access; the church should approve the period. Evaluate dormancy against the previously stored activity timestamp before updating it. Login, email verification, password reset and token refresh must not reset dormancy or clear a hold; only authorised member activity after access checks updates the timestamp. A hold is enforced server-side across existing and new sessions.
- During access review, show only a generic review/help screen and the current recovery request. Do not show old profile, prayer or chat data. Provide a clear church contact and an Admin queue; only an authorised reviewer removes the hold after the required identity checks.
- **Identifier and password risks:** registration does not prove phone ownership, so an applicant may mistype or deliberately claim another person's number. A recycled number alone cannot authenticate without the password and must never become a recovery credential. Credential theft, password reuse and false identity claims remain risks requiring password/abuse controls and reviewed account linking. Do not claim that the app detects number reassignment or that a local device unlock protects a fresh sign-in.
- Optional recovery email belongs to the same Supabase Auth account. It becomes eligible only after verification and approval in the trusted credential binding; a contact field or a newly supplied address cannot recover an existing account. Never merge accounts merely because contact details match. A verified email attached to Supabase Auth may also support provider-native email authentication: a phone-first product screen is not proof that every email route is disabled. Every provider-supported route must resolve the same account and pass the same current member-link, credential-binding, hold and scope checks.
- A leader helping with signup may explain the screens, but must not choose, collect, save or forward the member's password, use a shared credential, or leave the member signed in on the leader's phone. Clear sensitive local caches and device registrations on sign-out/account change.

### Members without a usable personal account

- Admin can create or approve a member record with the person's permission, assisted by the relevant leader. Record name, confirmed cell, optional contact route and who entered/confirmed it. Do not fabricate an email address or create a dummy login. Email is not required for a personal phone-and-password account; someone unable to maintain a private account can continue with leader-managed participation.
- An approved member record without an app account can receive duties and appear in authorised attendance lists. The leader sees **Needs direct contact**, contacts them through an agreed route or in person, and records a leader-confirmed response. Do not silently count a queued push as contact.
- If the member later creates a personal phone-and-password account, have Admin check their identity and link it to the existing member ID; preserve their duties and attendance history without creating a duplicate. Matching an unverified username never supplies this approval.
- A relative's number may be an explicitly agreed contact route, clearly labelled with whose number it is. It does not grant the relative access to the member's private information, inbox or prayer requests. Avoid sensitive notification previews on shared devices.
- For minors, use the church's agreed safeguarding/consent process, minimise collected details and keep youth contact/directory access disabled until that process is approved. Do not treat an adult's account or contact details as a child's identity verification.

### Changed credentials and secure recovery

- **Forgotten password with eligible email:** offer a reset link sent only to the previously verified recovery email in the same account's approved binding. Return a generic result that does not disclose whether an account/email exists. The user privately sets the new password using the supported recovery flow; apply expiry, replay protection and approved redirect/deep-link handling. Do not create a second account or relink a member during password reset. A recovery session is restricted to the required recovery actions; after reset, require a fresh password sign-in before private access and apply the normal current server checks. An existing security/dormancy hold remains in force after reset.
- **No recovery email, inaccessible email or disputed access:** offer **I need help accessing my account**. An authorised staff reviewer verifies the member using an established church relationship or an in-person check and records the reason, reviewer and outcome. A name, birthday, matching number, newly claimed email address or possession of the SIM alone is insufficient. Use an identity-checked process that lets the member set their own password privately on the same account without SMS or mandatory email. Staff must never see, choose, store or send a password. Only the current reviewed recovery case may authorize password setup. Bind any assisted setup grant to the stable member ID, Auth account ID, approved account-link revision and Identity-owned recovery/credential generation. A new recovery, relevant credential change, relink, cancellation or lifecycle restriction invalidates obsolete grants. Consume a valid unexpired grant once under server-side concurrency control; stale, replayed or cross-member grants fail. Serialize privileged Auth resets for each account and block relinking while an earlier reset outcome is unresolved; security denial must remain immediate. A late or uncertain external result cannot approve a newer link or clear a hold. Observe direct Auth credential changes through a tested trusted server mechanism so they cannot evade invalidation. The generation, change detection and external-operation handling are architecture mechanisms to prove before assisted recovery is enabled; Auth remains the only password store.
- **Phone username change:** request the change through the account flow, reauthenticate when possible and complete the church identity review before replacing the approved binding. Normalize the replacement number and handle conflicting accounts without automatic overwrite or merge. The replacement remains an unverified username; do not request an SMS or claim number ownership. Keep the member ID and account history stable and revoke obsolete sessions/device registrations as required by the reviewed change.
- **Recovery-email addition, replacement or removal:** use the same-account credential-change flow with current authentication and the required identity review; verify a new email before it becomes an approved recovery destination. Do not convert an unverified contact email into a recovery identity. A proposed email change, a completed verification or a native Auth update must not silently clear a hold or replace the approved binding. Loss of the old email has the staff-assisted route; never require the old email or SIM as the only way to recover.
- **Lost or compromised device:** place the account on a security hold where necessary, revoke affected auth sessions, remove push registrations and preserve the member record and duties. Password changes and recovery invalidate older sessions for private access through tested revocation or a server-controlled credential epoch on both clients; changing a password alone is not evidence that every old token lost private access. The trusted detection/enforcement mechanism is a foundation validation obligation, without copying password hashes into application tables.
- **Claimed/recycled number or duplicate account:** hold private access when an ownership dispute is accepted for review, then explicitly link, separate or correct records with an audit trail. Never treat ownership of a phone or email as evidence of ownership of the historical member record. Keep internal member IDs stable; phone numbers and recovery emails are changeable account attributes, separate from ordinary member contact routes.
- Only authorised staff can approve account relinking, assisted recovery or removal of a security hold; no self-approval of a staff recovery or security hold. Before launch, document first-Admin setup and an identity-checked fallback for loss of the last Admin's device or password. Do not build an unaudited “change anyone's credentials” shortcut. Staff recovery authority does not grant access to the member's private care or finance content.

### Delivery costs and foundation validation

- No authentication SMS provider, SMS sender registration, SMS budget or SMS delivery test is required. Do not configure an SMS provider, send-SMS hook or test-OTP bypass. Disabling phone confirmation alone does not prove OTP is disabled: test direct provider OTP/request and verification routes and require that they cannot send SMS or unlock private data without password authentication. Never describe provider auto-confirmation as proof of number ownership. Duty reminders remain push, in-app and leader contact.
- Configure and budget a production transactional email service for optional email verification and password recovery, including sender/domain setup, deliverability, approved redirects, throttling and support for expired/invalid links. The optional email feature is first-release scope, but email is never a prerequisite for creating an otherwise valid phone-and-password account.
- Enforce password policy, sign-in/registration/recovery rate limits, anti-enumeration behaviour and appropriate abuse protection server-side; do not rely on disabled buttons. Explain retry/help routes for wrong credentials, unavailable email delivery and rate limits. Never log passwords, reset links or recovery secrets. [Supabase rate limits](https://supabase.com/docs/guides/auth/rate-limits)
- In the foundation milestone, prove phone-and-password registration/sign-in without SMS, same-account verified email attachment/recovery, identity-checked no-email recovery, credential-binding checks and session revocation against the actual Supabase configuration on both mobile and web. Authentication mechanisms must not be described as already implemented from documentation alone. If a provider limitation prevents an approved flow, resolve that mechanism before private launch without silently making email mandatory, adding SMS or substituting fake emails, shared passwords or custom authentication PINs.

### Membership and account lifecycle

- **Pending/rejected requests:** public content and the applicant's current request status only. Knowing a phone number, creating an account or verifying a recovery email does not bypass approval.
- **Disable or recover login:** suspends online access while keeping the person's church membership, cell register and duties intact; leaders use direct contact meanwhile.
- **Deactivate church membership:** removes community access and directory visibility, revokes mobile/web auth sessions, and flags future duties, care visits, owned follow-ups and active recorder/custodian responsibilities for authorised handover. Collection amounts and receipt history are not silently deleted. Admin can restore membership through a reviewed process.
- **Full deletion:** provide an in-app request and a staff-assisted route for members with no login. Revoke sessions and delete the Supabase Auth user and its sign-in identities, personal member/profile and account-link data, personal application/recovery data, authored chat content and attachments, prayer content and device tokens; reassign open work and remove identity/private notes from retained operational records. Do not silently retain an identifiable member record under a second account. Document backup retention and distinguish full deletion from simply removing login access.
- **Public access:** sermons, events, announcements, cleared Bible/hymn content and giving instructions require no account.
- Account deletion and retention rules also cover visit reasons, appointment locations, recaps containing personal stories and collection actor identities. Remove or anonymise personal data in retained operational records under the church-approved policy while preserving non-personal collection totals and correction links; do not invent a legally required retention period. Transfer open work and collection custody before removing the last responsible staff account. Web sessions and local sensitive caches follow the same hold, logout and deletion rules as mobile.

## Navigation and visual style

- **Bottom tabs:** Home, Bible & Hymns, Sermons, Give, Calendar.
- **Top bar:** church logo, chat icon with unread badge, search and profile. The supplied emblem already contains the church name, so the visual header may use the emblem alone with an accessible church-name label. Hide member-only shortcuts for guests; public tabs remain fully usable.
- **Member Home:** a prominent **My duties** card above the poster feed, showing the next assignment and the count awaiting response. **My follow-ups** appears when the member owns open work. These are one-tap entry points, also available from the profile menu.
- **Leader Home:** an additional **Needs attention** card for unfilled slots, overdue responses, recent declines, upcoming conflicts and overdue follow-ups. Pastor sees the church-wide overview; leaders see their own scope.
- **Home content:** swipeable upcoming-event and campaign banners, with the yearly theme first, followed by poster cards for events and sermon series.
- **Calendar:** public events in a list with date badge, thumbnail and start/end time. Signed-in members can enable **My duties** and **My cell** overlays without exposing anyone else's rota. A duty detail opens directly from its calendar entry.
- **Sermons:** latest series poster, then the sermon list; detail opens the player and notes.
- **Give:** a **How to give** list with a method/provider name, optional logo and a short purpose or currency subtitle. A row opens instructions and copyable details.
- **Profile:** church approval status and a separate **My cell** status (confirmed, awaiting confirmation, not sure or not yet in a cell), request/change-cell action, My duties, My follow-ups, pastoral visits, notification settings, departments, prayer, directory, account controls and permitted staff tools. Pending applicants see their application status without private community data.
- **My cell:** next meeting, approved venue/directions, programme, own assigned part, an optional Cannot attend notice, and published recaps of earlier meetings. Cell chat remains a separate action and dependency.
- **Pastoral visits:** show proposals awaiting a response, confirmed visits, requests in progress and a concise history. Home shows a response card when relevant; sensitive reasons are not placed in notification previews.
- **Staff web:** role/scoped navigation for membership, cells, rotas, programmes, reports, service counts, pastoral care and cell offerings. An account sees only its granted roles; any role switcher selects among those grants and never grants access. Use responsive tables, a rota grid, explicit filters and the care board/list described below. My follow-ups is available to every task owner, not only leaders.
- One sign-in covers all member features, including messaging. Notification links return to the correct item after sign-in and permission checks.

Use church brand colours, a light content area and dark mode. Poster cards use 16:9 thumbnails while allowing the original poster to be opened. Include readable text alternatives and cache images. Use large touch targets, text of at least 16sp where practical, scalable text and status labels that do not depend on colour alone.

## Departments and assigned duties

This is a core launch feature. The app should replace repeated checking of paper rotas and scattered messages with one current assignment list and a clear follow-up queue.

### Set up departments and duties

Department duties and assigned cell-programme parts use the same assignment engine. Each occurrence has exactly one owning scope, either a department or a cell; only its authorised leaders may manage it. A cell leader does not gain department authority. Where a programme part represents an already-existing duty, link that same assignment rather than issue duplicate requests.

- Admin creates departments such as ushering, cleaning, intercession, preaching and Christian education, assigns a leader and optional deputy, and adds approved members.
- Each department defines duties such as Main door, Cleaning after service, Lead Tuesday prayers or Sunday teaching. Members may serve in several departments.
- A duty slot contains its owning department or cell, duty/part, date, start/end time, reporting time if earlier, location, optional linked event or cell meeting, leader instructions and optional topic/scripture.
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

- Show **Needs a response**, **Upcoming** and **Past** lists across all of the member's departments and assigned cell-programme parts. Identify the owning team on each item.
- Detail shows the duty/part, owning department or cell, date, reporting and service times, location, instructions, topic/scripture if any, response deadline and leader contact route.
- After acceptance, show **Accepted** with a **Can't make it anymore** action. A later decline reopens the coverage issue immediately.
- Offer **Add to calendar** and a deep link back to the live assignment. Explain that an exported calendar entry may need updating after a change.
- Empty state: “You have no upcoming duties.” A network error must not look like an empty rota or a successful response.
- Pending offline actions show **Not sent** until confirmed by the server. The leader must never see an acceptance that exists only on the member's device.

### Leader follow-up and coverage

The leader coverage dashboard shows the next seven days by default, scoped to the managed department/cell, with date and duty filters:

- **Unfilled:** positions without a current assignee.
- **Awaiting response:** assigned members who have not accepted or declined, with response deadline.
- **Overdue response:** deadline passed without a response.
- **Declined or changed:** assignments that need a replacement or a new confirmation.
- **Confirmed:** accepted positions, alongside total positions required.
- **Needs contact:** unresolved responses and members with no active push device or known notification problems.

For each issue the leader can open the assignment, contact the member using contact details made available for their department or cell, record a brief contact attempt and next follow-up date, or reassign. Contact actions open the phone or messaging app; v1 does not send SMS or WhatsApp automatically. Contact notes must stay practical and avoid pastoral or medical detail.

If a member confirms by phone or in person, including a member without a login, the leader can record **Confirmed by leader**, with who recorded it, when and a short reason. Keep this distinct from a member's own acceptance. Opening a notification or sending a push never counts as confirmation.

Pastor sees authorised operational coverage gaps and overdue follow-ups across departments/cells without acquiring unrelated private notes. Admin can appoint a deputy or new leader when the usual leader is unavailable. Member assignment histories support fair workload discussions; they are not public rankings.

### Changes and completion

- Changing the date, reporting/start/end time, location, duty or assignee sends a change notice and requires a fresh response from affected assignees. Create a pending assignment revision with a recalculated response deadline and supersede the previous revision, preserving its response, actor, time and member/leader-recorded provenance. Only the current revision contributes to confirmed coverage. A notes-only edit sends an update without resetting acceptance.
- Reassignment preserves the previous response in history and cancels the old assignee's pending reminders. Cancellation removes the duty from upcoming work and informs affected members.
- Warn on overlapping time ranges across departments and cell-programme assignments; disclose only the conflict detail the viewer is authorised to see, not another team's private instructions or care appointments. Leaders may override a conflict with a reason; the assignee still chooses whether to accept. Availability collection is deferred, so the app does not assume a member is free just because no conflicting assignment exists.
- After the duty, the leader records **Completed**, **Excused** or **No-show**, with a correction path and optional short note. Passing the time does not automatically mean a no-show.
- Keep response, coverage and attendance separate: an accepted duty can later be cancelled, and a declined assignment should not become a no-show.
- Members cannot directly swap duties in v1. The leader remains responsible for approving and publishing any replacement.

## Reminders and follow-up

Use a shared in-app/web notification inbox and server-side scheduling for duty/programme reminders, care and visitor follow-ups, visit proposals and appointments, missing cell reports and offering handover/discrepancy tasks. Push opens the relevant item; the inbox remains available when push is disabled or missed. Reminders should make the next action clear.

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
- Stop response reminders on acceptance or decline. Stop all pending duty reminders on cancellation, reassignment, church-membership deactivation or removal from the owning department/cell. Login suspension or a security hold cancels member-push jobs but preserves duties and routes outstanding contact needs to the responsible leader. A fresh assignment or material change creates a new revision and reminder schedule.
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
- **Privacy:** private follow-up content requires the applicable source-specific permissions (care or finance grants only where relevant) and the permitted assignee/supervisor scope. Ordinary practical duty-follow-up notes do not require a care/finance role. Assignment of a practical next action never grants unrestricted access to its source report, financial record or anonymous identity. A pastoral role alone does not expose finance notes; a finance role does not expose care notes. Admin can route non-sensitive owner, scope, status and deadline metadata without private content. Anonymous prayer requests use their own private reply flow and do not automatically create a broadly visible task.

### Visit and operational reminders

- A visit proposal notifies the member and responsible care owner and includes a response-by time. Proposed default: reuse the duty deadline calculation against the visit start; a short-notice proposal requires direct-contact visibility. Notify the owner if no answer by the deadline. Sending or reading a proposal never confirms it.
- A confirmed visit creates one day-before reminder for the member and assigned visitor, using the same quiet hours and direct-contact fallback. A proposed new time is visibly pending until the other party agrees; cancel obsolete reminders when either party requests a change. Cancellation/decline/completion ends that appointment's reminders, while a separate unresolved care need may remain open with a next action.
- Programme assignments use the duty rules. Meeting attendance notices do not create accepted duties, suppress a declined-part coverage issue or substitute for a visit response.
- A cell offering awaiting handover/receipt or with an unresolved discrepancy has a responsible custodian/reviewer and due/review date. Use the shared task reminder rules, not a separate daily finance-alert stream. Reminders expose only generic operational text; amounts, counting differences and care details stay behind authorised sign-in.
- Web users can see the durable inbox without browser push. Browser notification permission and browser push are not required for v1; mobile push plus staff queues/direct contact remain the delivery routes.

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

Returning to the church app simply returns to the instructions. There is no payment-success screen, **Record my gift** button, claim form or giving history. This public/member giving flow does not request amount, transaction ID, sender phone, proof of payment or payer identity. Aggregate staff collection amounts belong only to the separate Cell offerings register.

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
- Personal giving records, payment processing, donor receipts and full church accounting remain outside this flow. The separate **Cell offerings** staff module records aggregate collections and accountable custody, as specified below. Its amounts never appear in member profiles, public giving screens, recaps or a personal giving history.

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
- **Joining:** offer phone-number-and-password signup, with optional verified recovery email and no SMS, to a visitor able to maintain a personal account; otherwise offer assisted member registration without a login. Invite through an agreed contact route or in person; do not assume email. Reuse the existing visitor/member relationship only after checking identity, never automatically from the supplied phone number. Do not invent credentials or bypass church/cell approval.
- **Weekly reports:** topic, attendance totals, testimonies, prayer needs and pastoral issues. Separate private prayer/pastoral fields from report metadata and restrict them to the cell leader/assistant and authorised pastoral staff. Admin can see submission status and route missing reports without receiving private care content. Pastor can filter authorised reports by cell/week and see gaps.
- **Pastor overview:** authorised cell/service attendance trends, visitor attendances this month, open/overdue follow-ups, visits and missing reports. Cell offering totals appear only with a separate finance-oversight grant, with counted/received/outstanding bases clearly labelled; no donor-level totals or bank deposits are tracked.

### Meeting programmes

- For each cell meeting occurrence, the scoped leader/assistant drafts topic, scripture, date, start/end, venue and ordered programme parts. A part has a label, start time, expected duration/end and optional assigned member. Validate order and that parts fit the meeting; allow unassigned parts as visible gaps.
- Use **Draft**, **Published** and **Cancelled** plan states with revisions. Drafts are limited to managing leaders and authorised oversight. Preview the member view before publishing; only confirmed members of that cell with approved active accounts can read it, including a private home venue. The shared plan may name programme leaders, but only the assignee and managing staff see that person's response, private decline/contact notes and assignment history; the member-facing plan exposes no private response ledger. Public signup options continue to contain only safe cell labels/areas.
- Publishing an assigned responsibility creates or links its current duty assignment and requests an explicit response. The member sees “You're on” with its actual Awaiting/Accepted/Declined status, reporting time and instructions, on My cell, Home and My duties. Members without accounts use attributed direct-contact confirmation. Displaying a name in the programme is not confirmation.
- Reuse conflict checks across departments and cell parts, deadlines, leader coverage, contact attempts, revision/reconfirmation and cancellation rules. Changing the meeting's time/venue flags linked parts and requires the leader to publish revised assignments atomically; do not silently keep acceptance for changed details. A change to study notes alone does not reset unrelated duty responses.
- **Cannot attend** is an intention notice for that member and occurrence, with an optional practical note and a withdraw/change action. Notify the leader; record its actor/time. Keep it separate from actual Present/Absent/Excused attendance. If the member has an assigned part, show that assignment and request an explicit decline/change response; ensure the leader sees a coverage warning. A meeting notice never silently accepts, declines or completes a duty.
- After the meeting, the leader records actual attendance and any substitutions/actual programme leaders, with corrections. Recaps must not misreport the planned person as the person who served.

### Member-visible recaps

- Keep **leader report submission** and **recap publication** separate. Submitting attendance or a private weekly report never automatically publishes its discussion, testimony or care content.
- A scoped leader/assistant prepares a separate member-safe recap: meeting/topic/scripture, concise summary, ordered key points, optional aggregate attendance and actual programme leaders. Include a preview and clear “Visible to confirmed members of this cell” label. States are **Draft**, **Published** and **Withdrawn**, with publisher, time and revision history. Corrections can replace the published revision; withdrawal removes it from the member feed.
- Use a dedicated safe record/projection for member reads. Private prayer/pastoral fields, visitor contact details and named absence lists are never part of that response. Testimonies can themselves reveal illness, bereavement or other private information: include only an appropriately edited story with the subject's permission for this audience, or omit it. Provide a correction/removal route. Do not copy restricted notes into analytics, notifications or search indexes.
- Proposed v1 access rule: currently confirmed cell members may read its published recap archive; no public recap feed. If the church wants joining-date limits, configure that before launch. A cell transfer/removal immediately ends server access to old-cell recaps, programmes and venues. Do not persist those private records for offline reading in v1; clear in-memory/browser state when scope loss is observed and on logout/account change. An already-offline screen cannot be remotely erased, so do not promise immediate device wipe. Do not publicly expose a historic private home address merely because a meeting ended.
- Retain the private report's separate submission, missing-report reminders and authorised Pastor review even when no recap is published. Add/edit key points in the staff UI, matching the mobile recap screen. Recaps and programmes remain usable without chat.

## Pastoral visits

This v1 module adds an agreed appointment to the existing care/follow-up workflow. Requests may come from the member, a consent-aware leader referral or an authorised pastoral report. Each request has one accountable care owner and supervising pastoral authority. Do not expose anonymous-prayer identity through a referral; use its private reply route unless the author deliberately requests a visit under the stated visibility rules.

### Request and appointment flow

1. An approved member requests a visit, chooses a broad reason (for example Prayer, Illness, Bereavement, Counsel, Home blessing or Other), preferred venue/time window and an optional note. Explain exactly which authorised pastoral staff can see it. Collect only what is needed; allow the member to correct or withdraw the request. A request is not an emergency response service: show the church's agreed contact/help route without promising a response time the church has not adopted.
2. Authorised pastoral staff triage the request, assign the care owner/visitor and next-action deadline, and propose the visitor(s), exact date, start/end or duration, church time zone and agreed location/contact route. Check the visitor's known duties/appointments and warn about conflicts without exposing another person's private visit reason/location; any override needs a reason. A proposal does not reserve consent from the member.
3. The member **Accepts**, **Declines**, or **Suggests another time**. Suggested slots are preferences, not guaranteed availability. If none fit, create an owned contact task rather than falsely promise that the office will call. A staff-originated proposal requires the member's acceptance; a member-originated alternative requires authorised staff acceptance after checking the visitor and location. Confirmed requires both sides' agreement to the same current visitor/time/location proposal revision, including after a member-suggested alternative. Notify both sides when agreement is complete.
4. For someone without online access or whose account is on hold, the care owner uses the agreed direct-contact route and records the member's explicit response, actor, time, channel and short practical reason. Never confirm merely because a notification was sent or a staff card was dragged. No unapproved relative gains access to the request.
5. Either side may request a change or cancel. A material visitor, time or location change creates a new proposal revision, preserves the prior response and requires the affected party's fresh agreement. Staff records **Completed**, **Not completed** or **Cancelled** with a concise outcome and next action where needed. Not completed is a terminal state for that appointment occurrence, stops its appointment reminders and leaves the care task open when another action is needed; scheduling another attempt creates a new proposal. The passing of time does not complete a visit.

Track request lifecycle (Open/Withdrawn/Closed), appointment state (**Proposed**, **Confirmed**, **Change requested**, **Declined**, **Cancelled**, **Completed**, **Not completed**) and the linked follow-up task status separately. A declined appointment does not automatically close a still-requested care need. Close/withdraw actions record the reason and cancel only obsolete work. One source-linked task owns the next action; do not create duplicate care trackers.

### Staff board and privacy

- The web care board includes Requested, Awaiting member, Confirmed, New time suggested and Completed views, with Declined/Cancelled/Not completed/Closed filters. It groups the underlying request/appointment states; moving a card invokes only a permitted transition. **Confirmed** requires a recorded consent event. Schedule/completion drops open their relevant forms. Provide equivalent buttons, keyboard controls and a list view.
- Members see only their own request, safe appointment details and outcome intended for them. Assigned pastoral visitors see their own authorised cases; supervisors see their permitted scope. Admin can route non-sensitive owner/status/deadline metadata without the reason, note or precise home/hospital location. Treasurer, Media, service-recorder and general prayer-team permissions add no care access.
- Store internal pastoral notes separately from member-facing details and from general task metadata. A private report's Schedule visit action links its restricted source without copying its text into a broad task. Only authorised care staff can read the source. The shared Admin report page must never fetch/render the private care editor unless that user has a separate care permission.
- Generic inbox/push previews contain no illness, bereavement, prayer text, home address or visit reason. Avoid persistent private care caches and clear in-memory/browser state on observed logout, holds, scope removal or account changes; do not claim to remotely erase an offline screen. Apply the approved retention/deletion process to requests, notes and history. Youth visits require the church's agreed safeguarding/consent process before activation.

## Service attendance and pastoral overview

- Admin defines service types such as Sunday service, midweek service and prayer meeting, their schedules and authorised recorders. Generate stable service occurrences or link an existing event without double counting it; distinguish **Scheduled**, **Held** and **Cancelled**. Record actual date/time and optional public leader/venue metadata.
- An assigned recorder enters aggregate **total attendance** and **visitor attendances** for an occurrence, then submits. Proposed v1 counting convention, to confirm with the church: total includes visitors and visitor count cannot exceed total. Confirm and version the counting definition before first use; a later change must identify its effective date and cannot silently combine incompatible historical definitions. Do not infer unique people from these counts. Named service attendance and demographic breakdowns are outside v1.
- A count record is **Unrecorded**, **Draft** or **Submitted**; a submitted zero is an explicit observed zero, not an empty form. Cancelled occurrences require no count. Warn on unusual values and duplicate submissions, but do not invent counts from RSVPs or duties. Show incomplete coverage beside charts.
- Allow authorised corrections with previous value, new value, reason, actor and time. Edits use revision checks so concurrent changes do not silently overwrite each other. Pastor views counts; Admin manages recorder assignments and authorised operational reporting; general members see only public event information.
- The pastoral overview includes Sunday/midweek/prayer-service trends and cell aggregate attendance, plus missing reports, care work and upcoming visits. Label the exact period and denominator. Proposed reporting default: four-week comparisons use the previous four comparable calendar weeks, include submitted held occurrences only, and show included/missing counts; show “Insufficient data” rather than an invented baseline. A monthly visitor figure is **visitor attendances**, never “unique visitors”. Do not sum service and cell counts as a count of unique congregation members.
- For cell participation, use the roster applicable to the meeting and preserve Present/Absent/Excused/Unrecorded separately. A percentage must state its denominator, and an incomplete register cannot be treated as a complete low-attendance result. Follow-up flags remain based on recorded consecutive held-meeting absences.
- Add a capture/correction screen and an unrecorded-count queue, not just charts. Each missing submission has an assigned recorder and follow-up date through the existing task system. Church-approved deadlines and data retention remain launch configuration.

## Cell offerings

This restricted v1 register records the aggregate offering collected at a cell meeting and its custody through treasurer receipt. It does not take payment, identify donors, create personal giving histories, issue donor receipts or replace church accounting. Public Give remains instruction-only. The cell report may link to a permitted offering entry/status, but its financial data is separate from the recap and private care report.

### Count, handover and receipt

1. The scoped cell leader/assistant prepares one collection record per meeting and currency, with amount, two distinct named counters and the responsible custodian. Use exact currency amounts with validated precision; never floating-point totals. Proposed initial currency is ZMW, subject to church confirmation; no exchange-rate conversion or multi-currency grand total in v1. Explicit **No collection** is different from Missing, Draft, a cancelled meeting, or a counted amount of zero.
2. Both counters confirm the counted amount and currency. With no account, an authorised leader may record a counter's explicit in-person attestation with who recorded it, when and how; it must be labelled staff-recorded rather than an app acceptance. The two counter identities must still be different. A disputed count stays unresolved; no published total may imply both agreed when they did not.
3. Once counted, the custodian records the amount handed over, date/time and intended treasurer/deputy. A handover is **Awaiting receipt**, not “Received”. Record any outstanding amount and its owner/due date. The custodian's checkbox cannot attest the treasurer's receipt.
4. The authorised Treasurer/deputy records the actual amount/currency received and receipt date/time. The receiving person must be different from the counters and handover custodian, even when people hold multiple roles. If nobody eligible is available, keep it pending and assign a suitable deputy; never silently self-receive. The record is operational acknowledgement of custody, not a donor/payment-provider receipt.
5. A mismatch or disputed handover opens a **Discrepancy** with a responsible reviewer, reason, next action and due/review date. Keep counted, handed-over and received amounts visible as separate facts. Do not overwrite one to force a match. Record a resolution and any approved correction after review. A count correction requires renewed counter attestations; a receipt correction belongs to an independent authorised finance reviewer. Preserve prior versions and attribution.

Collection workflow states are **Draft**, **Counted**, **Awaiting receipt**, **Received**, **Discrepancy**, **No collection** and **Voided**. Keep count attestations, custody events, discrepancies and revisions as separate records so one label does not erase history. A record becomes Received only when the matching amount is acknowledged by an eligible receiver and no discrepancy remains. Support more than one handover/receipt event only when needed to represent an actual partial or corrected handover; aggregate against the collection and prevent duplicate or excess receipt without review. No transfers between church financial accounts are performed by the app.

### Access, reporting and corrections

- Cell leaders/authorised assistants prepare and follow their own cell's collections. Assigned counters see only the data needed to attest that record. Treasurer permissions define the cells/church scope for receipts, discrepancy review and export. Pastor sees authorised collection oversight only with an explicit finance grant. Admin-only, Media, ordinary members and guests cannot read amounts, counter details or finance notes. Admin may assign roles and route non-sensitive tasks.
- Submitted counts, handovers and receipts cannot be silently edited or hard-deleted from the UI. Before handover, an erroneous draft may be voided with a reason; later changes use linked amendments/corrections, including actor, reason and original/new values. Do not rewrite a received collection to remove an unresolved difference. Restrict finance notes to practical custody explanations, excluding donor identities and pastoral information.
- The Cell giving view supports cell/date/state filters, counted totals, received totals, outstanding amounts and discrepancy counts. Distinguish the accounting basis and currency on every figure; sum each current collection once and each valid receipt event once. Exclude voided records and superseded revisions; show missing/no-collection/cancelled cases explicitly. Collection summaries may appear on the authorised pastoral dashboard only with finance access.
- CSV export is permission-gated, scoped to the chosen cells/date range and limited to operational collection fields. Preview scope/columns, include currency and workflow state, neutralise spreadsheet-formula text, and audit who exported when and the filter used. Exclude donor identities, care notes and unrelated member contacts. Warn that the downloaded copy is outside the app's access controls; use the church's agreed storage/retention process. No automatic email or external sharing of exports.
- Role loss, staff departure and account deletion require custody/task handover. Preserve non-personal amounts and correction history under the approved policy while removing unnecessary personal information. Define finance retention with the church before launch; this specification does not invent a legal retention requirement.

## Staff web portal

- The web portal is part of v1. It uses the same Supabase account/member link as mobile, phone-number-and-password sign-in, optional verified email recovery, staff-assisted recovery and all hold/dormancy checks, without SMS. No separate staff credential database, guessed email addresses or bypass login. Do not require a new membership approval solely because staff signs in through a browser.
- Admin: membership applications and duplicate review, member/account records, scoped roles, cell setup/confirmation, department rotas and operational health. Cell leader: own-cell overview, plan/programme, attendance, separate report/recap and permitted offering work. Pastor: authorised reports, counts and care board, plus finance summaries only when granted. Treasurer: scoped offering register, receipt/discrepancy work and exports. Recorders/counters/visitors see only their assigned work.
- Essential mobile staff actions remain available: respond/manage own duties and follow-ups, record direct contact, handle own-cell attendance/programme/report, publish safe recaps, manage authorised care proposals and record permitted offering count/handover/receipt. Dense grids, trend review and CSV export are web-first. Both surfaces use the same server commands, validation and optimistic concurrency; a desktop edit appears in the mobile current state.
- Forms have explicit save/submission states, validation and recoverable failures. A role label or hidden menu is not a security control. Authorise every read/mutation/export at the database/server layer and clear sensitive browser state at logout or loss of access. Do not persist private care/finance caches for offline browsing in v1.
- The care board and rota grid need accessible list/button alternatives, visible focus, keyboard operation, readable text, non-colour status labels and responsive layouts. Test mobile and desktop browsers as well as native apps. The design's review-side role/theme panel is not a production permission picker.

## Architecture

The mobile app and staff web portal use Supabase Auth, Postgres, Storage and Realtime. Database permissions and RLS enforce access; server functions handle privileged workflows, state transitions and notification scheduling. No separate long-running custom API server is needed.

**Implementation proposal:** use Flutter Web for the staff portal to reuse Dart models, validation and Supabase integration with the existing Flutter stack, while building responsive staff layouts rather than stretching phone screens. Validate the dense grid, keyboard/screen-reader support and CSV download on target browsers in the foundation milestone. A React/Next.js client remains an implementation alternative if that spike fails; choosing it must preserve the same API/RLS and approved feature scope. The web framework, hosting provider and domain are not recorded as church-owner decisions already made. This is an app-style portal, consistent with [Flutter's web support guidance](https://docs.flutter.dev/platform-integration/web); validate actual keyboard and semantics behavior using [Flutter's web accessibility guidance](https://docs.flutter.dev/ui/accessibility/web-accessibility).

| Layer | Choice | Responsibility |
| --- | --- | --- |
| Mobile client | Flutter for iOS and Android | Riverpod state management, go_router deep links, public-content cache and essential scoped staff actions |
| Staff web client | Proposed Flutter Web, subject to the foundation accessibility/grid spike | Responsive staff portal, shared models/server commands, no separate permissions or data store |
| Web hosting | HTTPS hosting to be selected and budgeted | Staff portal delivery, approved domain and deployment/rollback process; no secrets in the client bundle |
| Auth | Supabase Auth | Phone-number-and-password sign-in without SMS, sessions, same-account optional verified email recovery and reviewed credential changes; staff-assisted no-email recovery mechanism must pass foundation validation |
| Data | Supabase Postgres | Member/account links, content, scoped duties/programmes, recaps, care visits, service counts and restricted cell offerings with grants/RLS |
| Realtime | Supabase Realtime | Scoped chat updates and refreshed assignment/task status |
| Files | Supabase Storage | Sermon audio, posters, chat images, avatars and cleared hymn assets |
| Server logic | Edge Functions and transactional database functions | Authorised assignments, visit consent transitions, recap publication, collection attestations/receipt/corrections, scoped export, notifications and account deletion |
| Scheduler | Supabase Cron invoking server-side work | Durable due-job processing and recurrence generation |
| Push | Firebase Cloud Messaging with iOS delivery configured | Per-device tokens, notification expiry and deep links |
| Recovery email | Production transactional provider to configure and budget | Verification and password-reset delivery to an optional approved email on the same account; never mandatory for phone-and-password members |
| Video | YouTube embeds | Video playback without hosting church video files |

Supabase documents scheduled Edge Function invocation through Postgres scheduling. The reminder worker must still implement the source re-checks, deduplication and retry rules above. [Supabase scheduling documentation](https://supabase.com/docs/guides/functions/schedule-functions)

### Core data model

These are logical entities, not migration-ready SQL. Use foreign keys, explicit allowed states, timestamps and appropriate indexes; enforce transitions in server-side transactions.

- **Member records:** `members` with a stable `member_id`, pending/approved/rejected/deactivated membership state, private name/contact data and consent records; `directory_entries` containing only opted-in fields. A member record does not require an auth user, phone or email. Store household/relative contacts as labelled contact routes, not unique identities.
- **Accounts and applications:** `member_account_links` between member ID and Supabase Auth user ID, with active/suspended/review-required access status, last member activity, a versioned approved binding for the normalized unique phone username and optional same-account verified recovery email, and an audit trail; one active link per person/account. The username is unverified as a phone number, and contact emails are not recovery identities. Supabase Auth owns passwords; application tables and audit logs never store passwords, password hashes or usable reset secrets. `membership_applications` records the applicant, proposed/existing member, review state and cell-choice response. `account_recovery_requests` records recovery route, assigned reviewer where needed, identity-review outcome, expiry/completion metadata and audited credential/session actions; the no-email handoff mechanism is defined and validated in architecture. `user_roles`, scoped leaders, `notification_preferences` and per-account `device_tokens` follow the active account link.
- **Cell choice and confirmation:** a safe `cell_signup_options` projection; `cell_membership_requests` for selection/transfer with requested cell or not-sure/not-in-cell choice, review status and reviewer; `cell_members` stores confirmed member IDs and effective dates. Enforce at most one current primary cell per member. A request never grants access.
- **Configuration:** `church_settings` with time zone, review/dormancy policy and operational contact; provider secrets remain server-side and are not ordinary settings fields.
- **Content:** `sermons`, `series`, `events`, `event_rsvps`, `announcements`, `hymns`, `hymn_favourites`, `sunday_hymns` and hymn/Bible content rights metadata.
- **Giving:** `giving_methods` with type, provider, label, purpose/currency, destination details, ordered instructions, optional dial code, sort order, draft/published/archived state, verification date and revision. Keep an existing published revision live until its replacement is published. No payer or payment-provider transaction entities; the separate cell-offering custody records below do not belong to public giving.
- **Duties and owning scope:** `departments`, `department_members`, `duties`, `rota_series`, `duty_occurrences` and `rota_slots`. Each occurrence has a stable ID, exactly one validated owning department/cell scope, optional cell-meeting/part link and optional series ID; its active slots define the required positions. A slot has reporting/start/end times, location, linked event, instructions, an immutable revision reference and draft/published/cancelled state. Preserve prior slot revisions for the assignment history.
- **Assignments:** `duty_assignments` with slot, slot revision, assignee, response deadline, pending/accepted/declined response, response actor/time and provenance, current/superseded/cancelled lifecycle, and optional completion outcome. A material change creates a new pending assignment record even if the assignee stays the same. Preserve the old response on its superseded record; allow only one current assignment per slot. A decline can remain current while the slot needs cover; reassignment supersedes it atomically.
- **Follow-up:** `follow_up_tasks`, `follow_up_activity`, restricted `follow_up_private_notes` and `duty_contact_attempts`; source, owner, supervisor/scope, next action, due/review date, status, outcome and visibility. Keep Admin-routable metadata separate from private descriptions, contact details and care notes.
- **Notifications:** `notification_jobs`, `notification_attempts` and `notifications` for the inbox. Jobs include source revision and a unique logical-reminder key; attempts record provider acceptance or failure without claiming the user has seen the message.
- **Prayer:** `prayer_requests`, a separately restricted `prayer_request_authors` identity mapping, and `prayer_replies`. Anonymous-team access never exposes the identity mapping.
- **Chat:** `groups`, `group_members`, `messages`, `message_reactions`, `message_reads`, `message_reports` and `blocks`.
- **Cells and programmes:** `cells` with optional `group_id`, leader/assistant, meeting schedule, venue and zone; `cell_members`, `cell_meetings`, revisioned `cell_meeting_parts` linked to duty assignments, `cell_attendance_notices`, actual `cell_attendance`, `visitors`, `cell_reports` and restricted `cell_report_pastoral_notes`. Keep attendance-notice and final-register states separate.
- **Recaps:** `cell_meeting_recaps` with safe member-visible fields, draft/published/withdrawn state, revision/publisher/time and publication history; published projections exclude raw private report content.
- **Pastoral visits:** `pastoral_visit_requests`, revisioned `pastoral_visit_proposals`/appointments, `pastoral_visit_responses` and separately restricted `pastoral_visit_private_notes`, with care assignments and one source-linked follow-up task. Store response actor/time/channel and accountless confirmation provenance; retain old proposed details without treating old consent as current.
- **Services:** `service_types`, `service_occurrences`, scoped `service_recorders`, `service_attendance_counts` and correction history; held/cancelled state, unrecorded/draft/submitted count status, counts under the confirmed/versioned metric definition (proposed total including visitors), visitor attendances and submission actor/time.
- **Cell offerings:** `cell_offerings` keyed to meeting/currency with current revision and workflow state; `cell_offering_count_attestations`, `cell_offering_handover_events`, `cell_offering_receipt_events`, `cell_offering_discrepancies` and linked correction/audit records. Store exact amounts/currency and stable member IDs for counters, custodian and receiver, with the acting account recorded separately. Enforce two different counters and a receiver different from both counters and the custodian; a custodian may also be one counter. Preserve attribution, source-revision checks, ownership/deadlines and separate amount bases. `finance_grants` defines receipt/oversight/export scope. There are no individual donor allocations, payment instructions executed by this module or personal contribution records.
- **Exports:** `export_audit_events` records permitted report type, scope/date filter, actor and time without copying private notes into a broad log; generate only authorised fields.
- **Identity references:** cell/department rosters, attendance, duty assignments and follow-up owners reference `member_id`; authenticated activity also records the acting account. Chat sessions, auth credentials and device tokens remain account-bound. Resolving an account link must never rewrite another person's authorship or share a household's private data.
- **Operational audit:** `audit_events` for permission changes, giving-method/recap publication, assignment revisions, recorded direct confirmations, visit transitions and service-count corrections. Finance amount changes and attestation/receipt history belong to a separately restricted finance audit trail. Store actor, action, entity ID, revision, reason where required, changed field names and time; never copy prayer text, visitor contacts or full private notes into an unrestricted audit log.

### Access and reliability requirements

- Enable RLS and explicit least-privilege grants for every exposed table, and protect storage objects and any views/functions as well. Test allowed and denied reads/writes/exports for Guest, Pending, Member, scoped leader, Media, Pastor, Admin, Treasurer, counter, pastoral visitor and service recorder on both clients, including accounts holding multiple roles. [Supabase RLS documentation](https://supabase.com/docs/guides/database/postgres/row-level-security)
- Member status, account links/security holds, staff roles and confirmed cell/department membership must be controlled by authorised server operations, never editable profile metadata. Protected access resolves `auth.uid()` through the active approved member link and current hold/dormancy state; matching a phone number is never an RLS ownership rule. Reject stale assignment updates.
- Before private access, require password authentication in the trusted Supabase-issued session and compare the approved account binding with current trusted Auth identity data server-side; absent or non-password authentication fails closed. An unapproved phone-username or recovery-email change is treated as review-required immediately, including changes through direct Auth update calls; access remains blocked until the required identity review approves the binding. Password values remain opaque to application records; a valid password reset does not by itself alter the member link, approve a credential-identity change or clear a hold/dormancy state. Restrict recovery sessions to recovery actions, require a fresh password sign-in after reset, and invalidate older sessions for private access through a tested server-controlled revocation/credential-epoch mechanism. Configure no SMS provider, send-SMS hook or test-OTP bypass; prove direct provider OTP/request and verification routes cannot send SMS or unlock private data. Phone confirmation disabled is not proof that OTP endpoints are disabled. Hidden email sign-in UI is not a security boundary: enabled native email routes must resolve the same account and satisfy the same password-authentication and current server checks.
- Assignment publication, reassignment, programme revisions, visit proposal/consent transitions and related job creation/cancellation must be transactional so coverage, agreement and reminder state cannot diverge. Recap publication exposes only its approved safe revision. Collection count attestations, handover/receipt matching and corrections use server-side transactions and revision/idempotency checks to reject stale or duplicate writes.
- Task assignees can record activity, outcomes and permitted status/review-date changes on their own tasks. Reassignment, supervisor and scope changes belong to the responsible leader or an authorised Admin. Source-specific sensitive content remains restricted regardless of routing permission. Members can respond only to their own current duty assignment revisions, not assign themselves or edit another member's response.
- Secret/service-role credentials remain server-side. Scheduled endpoints must authenticate their caller, and privileged functions must check their permitted action and target.
- Store timestamps in UTC with the church's IANA time zone for scheduling and display. Reporting time drives duty reminders when set. Daylight-saving changes, travel and device clock differences must not change the intended church time.
- Church-membership deactivation or role removal must immediately prevent protected access and cancel obsolete work, even if a device still holds an older sign-in token. A login security hold blocks access across sessions but preserves the member's duties/attendance, routing reminders to leader contact until access is restored.
- Back up both the database and stored files under an approved retention plan, and test restoration. Keep runbooks for approvals, account recovery, leader/care/custody handover, count corrections, collection discrepancies, notification failures, safe CSV handling and backup restoration. Test recovery without exposing finance or care content to unprivileged Admin-only operators.

## Important edge cases

| Area | Case | Required behaviour |
| --- | --- | --- |
| Cell programme | Assigned person cannot attend or meeting changes | Preserve the separate notice, duty response and actual attendance; reopen coverage and request revision-specific consent |
| Recaps | Private report submitted or testimony names someone | No automatic publication; review and publish only a safe consent-appropriate recap |
| Recaps | Member leaves or transfers cell | Immediately revoke server access; no persistent offline private cache; clear local state when the change is observed |
| Visits | Staff drags card to Confirmed | Reject unless an authorised explicit response/direct-consent record supports the current proposal |
| Visits | Member suggests another time or has no login | Preserve pending negotiation and an owned next action; use attributed direct contact when needed |
| Visits | Appointment declined but care still wanted | Stop appointment reminders; keep the care request/task open with a next action |
| Services | Counts missing, corrected or meeting cancelled | Keep missing distinct from zero; preserve correction history and exclude cancelled/unrecorded counts from baselines |
| Offerings | Counter, custodian and Treasurer are the same person | Block self-receipt and require an eligible independently assigned receiver |
| Offerings | Amounts differ or only part is handed over | Preserve counted/handed/received amounts, outstanding balance and owned discrepancy; never force a match |
| Offerings | Submitted record needs correcting | Append an attributed reasoned amendment and renew affected attestations; never overwrite history |
| Offerings | Export requested outside granted cells | Deny the export server-side; never leak care, donor or unrelated member data |
| Web | Stale tab, role removed or login held | Reject protected operations immediately and refresh to current authorised state |
| Giving | Dialler or USSD handoff is unsupported | Show/copy the code and manual instructions; never imply that a payment occurred |
| Giving | A method changes or is withdrawn | Publish reviewed details, refresh cached content, and show verification/offline state |
| Duties | A member never responds | Keep Awaiting/Overdue visible, notify leader at the deadline, and record direct follow-up |
| Duties | Push is disabled, token invalid or device offline | Preserve the in-app task; show known notification issues to the leader without inventing delivery/read status |
| Duties | Accepted member later declines | Reopen coverage immediately, notify leader, cancel that member's remaining service reminders |
| Duties | Same member has overlapping slots | Warn across departments/cell parts; require a reason to override and retain the member's response choice |
| Duties | A published duty changes after acceptance | Require reconfirmation for material changes and cancel jobs for the old revision |
| Duties | Member opens an old notification | Show the latest authorised state; reject stale responses and explain what changed |
| Duties | Several people are needed but only some accept | Show confirmed count against required positions and keep remaining gaps visible |
| Duties | Leader is unavailable or leaves | Admin assigns a deputy/replacement; do not leave an active department/cell without a responsible leader |
| Duties | Member is deactivated or leaves the owning department/cell | End current future assignments, flag vacancies and notify the leader |
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
| Auth | Normal returning sign-in or new device | Phone number and password restore the same approved active account without SMS or blanket staff reapproval; current holds/dormancy still apply |
| Auth | Wrong password, rate limit or invalid/expired email reset link | Generic retry/help state, server-side abuse limits and the approved email or staff-assisted recovery route; no SMS |
| Auth | Username/email changes, accepted ownership dispute or assisted recovery | Apply review/hold, verify the person and any proposed recovery email, audit the approved binding and revoke obsolete sessions; generic reset requests alone do not hold an account |
| Auth | Someone claims a registered/recycled number or supplies a new email for recovery | Number knowledge/possession alone cannot authenticate, recover or link the old member record; reject automatic merge and use identity review. Only a previously verified approved same-account email can receive self-service reset |
| Auth | Account is dormant under the chosen policy | Require church identity recheck before private data access; keep member records and duties intact |
| Accounts | Last Admin or a key leader requests deletion | Complete an authorised handover or supported recovery path; do not leave the church locked out |
| Chat | Offensive content is reported | Hide it for the reporter immediately and send it to authorised moderation |
| Content | Video is removed or private | Clear unavailable state with other sermon material still accessible |

## Tradeoffs and launch decisions

### Tradeoffs

| Decision | Benefit | Cost or limitation |
| --- | --- | --- |
| Instruction-only public giving plus restricted cell offering register | No payment processing or donor ledger; accountable aggregate collection custody | Staff still count and receive real money outside the app; discrepancy, audit and retention work is required |
| Programmes and safe recaps | Members know their part and can catch up | Reuse duties and maintain a separate publication/privacy boundary |
| Pastoral visit agreement | Visible ownership and explicit member consent | More states, sensitive-data controls and direct-contact support |
| Service counts | Useful participation trends without named attendance | Counts cannot establish unique people; reporting needs an owner and missing-data checks |
| Staff web plus mobile | Practical grids/reporting and mobile field actions | Adds responsive/browser testing and hosting; use shared server workflows |
| Duties and follow-up before chat | Addresses the stated coordination problem early | Realtime social features may arrive later |
| Push plus in-app tasks and human escalation | Low channel cost with visible outstanding work | Leaders still contact members who do not respond |
| Phone username and password, optional verified email recovery, persistent sessions and reviewed membership | No SMS costs/dependency and no mandatory email; same account on mobile and web | Members maintain a password; username ownership is unverified; secure no-email staff recovery and production optional-email delivery must be proved and supported |
| Member record separate from login | Includes members without personal phones and preserves attendance/duty history | Leaders handle their contact and record explicit responses |
| Scoped leaders and shared follow-up model | Consistent ownership without a large workflow engine | Permission rules need careful testing |
| Flutter and Supabase | Shared mobile codebase and managed backend services | Ongoing hosting and disciplined database/security work |

### Decisions for the church owner

1. **Access and registration:** phone username plus password, optional verified same-account recovery email and no SMS are approved. Name staff responsible for membership, cell confirmation, identity-checked assisted recovery and last-Admin continuity; confirm the proposed dormancy period and account-support procedure. Configure and budget production email delivery before enabling email verification/recovery. Validate the no-email recovery mechanism before private launch; unavailable email delivery must not block otherwise valid phone/password access for members without email. Do not reopen the approved route as an SMS-provider or mandatory-email decision.
2. **Duties and reminders:** confirm the church time zone, initial departments and leaders/deputies, response deadline, reminder offsets and quiet hours. The defaults above make the spec buildable but should be checked with the people doing the follow-up.
3. **Giving content:** supply the actual methods, beneficiary/account details, purposes, currency, tested instructions and responsible Admin. The reference screenshots do not establish this church's destinations.
4. **Safeguarding and privacy:** decide how under-18 membership and youth groups are handled, who can see contact details, the designated lead pastor, consent for visitor follow-up and retention periods. Do not enable youth directory/contact features until safeguards are agreed.
5. **Content rights:** confirm permitted Bible translations, hymn lyrics and audio, and who maintains the Sunday hymn list.
6. **Approved launch scope:** programmes, recaps, pastoral visits, service counts, web admin and cell offering records are included in v1. Confirm only operational owners and rollout order, not whether these six features belong. The pre-existing chat launch decision remains separate; duties, care, cells and offerings must work without chat.
7. **Care and recaps:** name the authorised pastoral team/visitor scopes, agree response/contact expectations, safeguarding for youth visits, testimony consent and recap archive access/retention. The proposed current-cell archive rule is a default for confirmation, not a claimed existing church policy.
8. **Service reporting:** name recorders, service types, submission/follow-up deadlines and reporting/retention policy. Confirm that aggregate attendance includes visitors and monthly visitor figures mean attendances.
9. **Cell offerings:** confirm currency, counter and custody procedure, eligible independent Treasurer/deputy, permitted finance oversight/export scopes, handover/receipt deadlines and retention. No real beneficiary, amount, policy or staff appointment is taken from mock data.
10. **Web implementation:** validate the proposed Flutter Web approach and choose/budget HTTPS hosting/domain. This is an implementation decision still to be tested, not a reason to drop the approved web portal.

### Risks and release checks

- **Missed reminders:** push can be delayed or unavailable. Prove that server scheduling works with the app closed and that leaders can see unresolved work without relying on delivery claims.
- **Sensitive information:** prayer, visitor records, visit reasons/locations and personal testimonies need narrow access, safe notifications, clear consent and tested deletion/retention rules. Keep safe recaps separate from private reports; Admin-only access must not expose private-care fields.
- **Finance integrity:** enforce independent count/receipt attribution, exact amounts, append-only corrections and scoped exports. A handover is not a receipt; a matching total cannot conceal an unresolved discrepancy. This module must not expand into donor accounting by accident.
- **Reporting integrity:** no fabricated acceptance, visit confirmation, attendance or completed outcome; missing data stays explicit. Dashboards must derive from authorised current records and explain their count basis.
- **Two client surfaces:** test web and mobile with the same permission and concurrency cases; hidden menus and role-switch prototypes provide no server protection.
- **Public giving destinations:** a wrong or maliciously changed number can redirect money. Limit editors, record changes and require church verification before publication.
- **Store readiness:** check the current iOS/Android requirements for external giving instructions, user-generated content, moderation, account deletion and privacy disclosures before submission. Instruction-only giving is not a guarantee of store approval.
- **Content permissions:** clear the actual material before bundling or publishing it; remove unsupported assumptions that a compilation needs no licences.
- **Authentication and support:** test phone/password usability, password/abuse controls, optional-email verification/recovery, secure no-email staff assistance and account/session recovery with members who are less comfortable with technology. Prove that a supplied number cannot claim an existing member, an unverified/new email cannot recover that account, and password/email recovery cannot clear a hold or bypass current permissions. Do not claim phone ownership is verified or that a recovery mechanism is working before the foundation validation passes.
- **One developer:** keep each approved module minimal and reuse duties, follow-ups, notifications and access checks. Sequence delivery without silently removing the six approved v1 additions. Document support procedures, identify church-side owners and budget for production/backend and web hosting, storage, recovery/verification email delivery and store accounts using current provider prices.

## Milestones and acceptance criteria

All six approved additions are first-release scope. These are implementation/pilot stages within v1, not separate promises of delivery dates.

1. **Foundation and shared access:** independent member/account records, phone-number-and-password pilot without SMS, optional same-account verified email recovery, identity-checked no-email staff recovery, assisted registration, church/cell approval, scoped staff/finance/care/recorder permissions and time zone. Prove actual Supabase configuration, password/abuse controls, credential-binding checks, recovery-session restrictions and session revocation on both clients; the custom no-email handoff is not assumed complete. Validate web framework/hosting and accessible grid/list patterns. Test Guest/Pending restrictions, holds/recovery, last-staff handover and deletion before private data is loaded.
2. **Duties, programmes and reminders:** departments and cell-owned assignments, draft/published rotas/programmes, My duties, all-owner My follow-ups, member/direct responses, coverage/contact queue, inbox and scheduling. Pilot a department and a cell; prove programme changes and Cannot attend notices preserve correct duty/attendance states.
3. **Public content and giving:** sermons, events, announcements, Bible/hymns and the instruction-only Give list. Verify every giving destination with church staff; no donor or payment-processing workflow.
4. **Cells, recaps and care:** cell attendance, visitors, private weekly reports, separate recap preview/publication, prayer/directory privacy and pastoral visit request/proposal/member response/completion. Deliver web care board with accessible buttons/list and essential mobile staff actions.
5. **Service counts and cell offerings:** service recording/correction/missing-count queues and pastoral trends; aggregate collection count/attestations, custody handover, independent Treasurer receipt, discrepancies, scoped summaries and CSV export. Pilot real church procedures only after permissions and correction tests pass.
6. **Staff portal completion and optional chat:** complete web administration/reporting and cross-client consistency. If chat is included at launch, add groups, images, reactions, reporting, blocking and moderation without making the approved core depend on it.
7. **Release:** staff beta for all approved modules, accessibility/browser/native-device tests, rights/privacy/store review, tested restoration, named operational owners and onboarding at church.

**Must pass before launch**

- A member can register with a normalized unique phone username and user-chosen password without SMS, leave recovery email blank, select a cell and understand the unverified username and separate church/cell approval states. Not sure and Not in a cell yet are valid choices; a matching number never links existing member records automatically.
- Selecting a cell never reveals its private data or joins its chat. Confirmed transfers remove old-cell private access and enable new-cell access atomically.
- Staff can include a consenting member without a phone/email, assign them a duty, mark attendance and record direct-contact confirmation. Identity-reviewed linking of a later phone-and-password account preserves their member ID and history; shared contact numbers do not become shared logins.
- Normal reopening and token refresh reuse a valid session without asking for the password; returning/new-device sign-in uses phone number and password with no SMS or staff reapproval unless an explicit hold/dormancy rule applies. Mobile and web resolve the same account.
- Test duplicate applicants, normalized username conflicts, shared household contacts, changed/lost/recycled numbers, direct Auth credential updates, deliberate holds and dormancy against API/RLS as well as screens. A number claim or newly supplied/unverified email never grants historical-member access or recovery; login, password reset and email verification cannot clear holds or reset dormant activity. Test enabled provider-native email routes under the same current-account checks, and prove missing/non-password session authentication, including direct OTP/verification sessions, cannot unlock private data or send SMS.
- Prove optional email is added to the existing phone account, verified and approved before self-service reset; test production delivery, expiry/replay/redirect handling, abuse limits and recovery-only access. Prove identity-checked recovery without email or SMS lets the member privately choose a password while preserving the account/member ID. Both reset routes require fresh password sign-in and invalidate older sessions for private access, while keeping holds in force until authorised release. Staff never sees or sends passwords; no fake email, shared login or custom authentication PIN is used. Foundation release requires tested provider configuration and a documented last-Admin recovery route.
- A guest can open a giving method and follow numbered instructions without signing in. Public/member giving never requests or stores an individual gift amount, proof, provider transaction ID or payer identity. Staff-only aggregate cell collections are tested separately and cannot appear in a personal giving history.
- A leader can publish a multi-person duty, members can accept or decline, and the leader can identify all remaining gaps at a glance.
- A declined or unanswered assignment leads to a visible follow-up action; a replacement gets a new request while the old assignee stops receiving reminders.
- A material time/location change requires reconfirmation. A late response to the old revision cannot overwrite the new state.
- Reminder tests cover app closed, push denied, invalid tokens, short notice, quiet hours, recurrence edits, cancellation and worker retries. No stale reminder is sent for a resolved or superseded source.
- A visitor follow-up or missing report has an owner, due date, overdue visibility and a clear completion path. Completing it stops its pending reminders.
- Permission tests prove that a member cannot read another person's private assignment record/response/notes, hidden contacts, private follow-up notes or anonymous prayer identity; a safe published programme may name who leads each part; scoped leaders cannot operate outside their teams.
- Content, hymn search, prayer, directory, programmes, recaps, care visits, service counts and offering workflows remain usable if chat is deferred.
- Publishing a cell programme produces revision-linked assignments; members can accept/decline, direct confirmation is attributed, and a meeting notice cannot automatically set attendance or duty response. A replacement and an actual programme-leader correction remain auditable.
- Submitting a private report never publishes a recap. An authorised leader can preview/publish/withdraw a safe recap; API tests prove that members cannot fetch raw reports or restricted testimony/care fields. Cell transfer revokes previous-cell recap/venue access.
- A member can request, accept, decline or reschedule a pastoral visit; staff can record consent after direct contact. Dragging a card alone cannot manufacture consent. Material changes cancel old reminders and require the right party's agreement; decline/completion do not silently erase outstanding care needs.
- Ordinary members who own follow-up tasks see them on Home and in My follow-ups. Completing/reassigning/closing a source-linked task leaves no duplicate orphan tracker or stale reminders.
- Service recorders can submit and correct scoped aggregate counts. Tests distinguish no record from zero and cancelled services, validate the confirmed counting definition (proposed visitor subset totals), preserve its version in comparisons, and show missing coverage in comparable-week trends without claiming unique visitors.
- Two distinct counters attest a collection; only an eligible independent Treasurer/deputy can acknowledge receipt. Test partial handover, mismatch, renewed count attestation after correction, concurrent edits, duplicate requests, missing/no-collection and staff handover. Original amounts/responses remain in restricted history.
- Finance totals do not double-count superseded records or receipt events. CSV export respects current scope, date/currency basis, safe columns and spreadsheet-formula neutralisation; it excludes care and donor details and records an export audit event.
- Mobile and web enforce identical current account holds/roles/scopes. Admin alone cannot retrieve private care or finance content; Treasurer permission alone cannot retrieve care; a visitor/counter/recorder cannot broaden their assigned scope. Account deletion clears both surfaces and handles approved operational retention.
- The web portal supports actual permitted roles, keyboard/list alternatives for rota/care operations, responsive forms, clear pending/error states and stale-edit rejection. All six approved additions pass their workflow tests before the v1 release gate.

## Later

Optional additional-factor/passkey access, local device unlock for privacy, an explicit email sign-in product screen if separately chosen, member-approved email duty reminders, general availability collection and rota optimisation, livestreaming, devotionals, reading plans, named service attendance, multi-branch support and broader accounting. SMS is not part of the approved authentication or reminder flows; adding it requires a separate scope decision. Direct swaps, payment processing, donor-level financial records, bank reconciliation and a general ledger require a separate scope decision. Web admin, the care board/basic visit negotiation, programmes/recaps, service counts and the limited cell-offering register are already v1 scope and are not deferred here.
