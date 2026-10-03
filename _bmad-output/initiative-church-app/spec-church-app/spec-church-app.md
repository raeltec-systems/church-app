---
id: SPEC-church-app
companions:
  - functional-requirements.md
  - design-contract.md
  - delivery-and-decisions.md
  - acceptance-map.md
  - ../architecture-church-app/architecture-church-app.md
sources:
  - ../brief-church-app/inputs/church-app-v1-spec-1.2.md
  - ../brief-church-app/brief-church-app.md
  - ../brief-church-app/addendum.md
---

> **Canonical contract.** Read this kernel and every `companions:` file. functional-requirements.md retains the detailed contract with the approved phone/password and no-SMS decision. The original spec 1.2 is an audit source; proposal labels and remaining open decisions are not production approvals. The handoff's older bundled spec does not govern behaviour.

# BIC Kafue Church App v1

## Why

Brethren in Christ Church Kafue, with fewer than 200 members, coordinates duties through calls, WhatsApp and last-minute personal chasing. Members need a clear responsibility and response route; leaders need timely, trustworthy gaps and follow-up. A church-owned mobile app and staff portal will support that duty loop and the approved content, cell, care and reporting workflows, including members without personal sign-in access, for the full-v1 November 2026 target.

## Capabilities

- **CAP-1 — Public church content**
  - **intent:** Guests and members can find church teaching, scripture, hymns, events and announcements, and authorised staff can maintain them.
  - **success:** Without signing in, a visitor can read cleared Bible/hymn content, search hymns, play an available sermon and view an event; authorised publishing, Sunday hymns, calendar export, offline public reading and unavailable-media states follow the baseline.

- **CAP-2 — Instruction-only giving**
  - **intent:** Anyone can find verified church giving instructions and complete giving independently with the provider.
  - **success:** A guest can open published numbered instructions, copy details or use a supported dialler handoff; only Admin publishes verified destinations, and no payer data, payment result or personal gift record is collected.

- **CAP-3 — Membership, sign-in and recovery**
  - **intent:** People can join and retain the correct church identity, including members without a login and members recovering access.
  - **success:** Members register and sign in with a phone username and password without SMS; email is optional, verified same-account email enables recovery, and identity-checked staff assistance serves members without it. Separate church/cell approval, current holds and stable member history survive sign-in, recovery and lifecycle changes.

- **CAP-4 — Scoped authority and privacy**
  - **intent:** Each person can see and act only on records permitted by their current membership, access state and explicit grants.
  - **success:** Allowed/denied API and client cases cover every baseline role and combined-role case; Admin alone cannot retrieve care or finance content, and stale sessions or credential changes cannot bypass holds or revoked scope.

- **CAP-5 — Assigned duties and member responses**
  - **intent:** Leaders can publish department duties and members can give an explicit response to each current responsibility.
  - **success:** Multi-position coverage, recurrence, drafts, explicit acceptance/decline, later decline, material-change reconfirmation, conflict overrides, reassignment and separately recorded completion preserve revision-specific history and reject stale responses.

- **CAP-6 — Coverage and accountable follow-up**
  - **intent:** Task owners and supervising leaders can identify unresolved work, contact the right person and track the next action.
  - **success:** Queues expose unfilled, unanswered, overdue, declined and direct-contact needs; all owners see My follow-ups, attributed leader confirmation stays distinct from member acceptance, and resolution/reassignment leaves no duplicate tracker or old-owner reminder.

- **CAP-7 — Reliable reminders and inbox**
  - **intent:** Members and staff can receive actionable reminders and recover outstanding work when push is unavailable.
  - **success:** With the app closed, due work enters the durable inbox and applicable push/contact route; retries, quiet hours, short notice, expiry and source rechecks prevent duplicate or stale work without claiming delivery, reading or consent.

- **CAP-8 — Cell attendance and private reports**
  - **intent:** Cell leaders can manage meetings, actual attendance, consented visitor follow-up and private weekly reporting.
  - **success:** Present/Absent/Excused/Unrecorded and cancelled meetings remain distinct; three recorded consecutive held-meeting absences trigger follow-up under the baseline, and report routing never exposes restricted prayer or pastoral fields.

- **CAP-9 — Cell meeting programmes**
  - **intent:** Confirmed cell members can preview a meeting and respond to their assigned programme parts.
  - **success:** A valid published programme creates or links current duty requests; material changes require fresh responses, Cannot attend remains an intention notice, and actual leaders/substitutions are recorded separately from the plan.

- **CAP-10 — Safe member recaps**
  - **intent:** Cell leaders can publish a member-safe account of a completed meeting.
  - **success:** Separate draft/preview/publish/correct/withdraw actions expose only a safe recap and consent-appropriate testimony to the current permitted audience; submitting a private report does not publish it, and cell removal revokes server access.

- **CAP-11 — Agreed pastoral visits**
  - **intent:** Members and authorised care staff can request, negotiate and record a pastoral visit with accountable follow-up.
  - **success:** Confirmation requires both sides to agree to the same current visitor/time/location proposal, including attributed direct-contact responses; changes renew consent, terminal appointment outcomes stop its reminders, and unresolved care can remain open.

- **CAP-12 — Service counts and honest trends**
  - **intent:** Assigned recorders can submit and correct aggregate service counts, and authorised staff can interpret participation trends.
  - **success:** Scoped recording distinguishes missing, draft, submitted zero and cancellation; corrections and counting-definition versions persist, and charts disclose period, denominator and incomplete coverage without claiming unique people.

- **CAP-13 — Aggregate cell-offering custody**
  - **intent:** Authorised cell and finance staff can account for a collection from witnessed count through independent receipt and discrepancy resolution.
  - **success:** Two distinct counter attestations, an eligible independent receiver, separate counted/handed/received facts, attributed corrections, partial handovers and scoped safe CSV export pass the baseline checks; no donor ledger or public financial exposure is created.

- **CAP-14 — Private prayer and replies**
  - **intent:** Members can submit named or team-anonymous prayer requests and receive a private pastoral reply.
  - **success:** The prayer team can read permitted text but cannot retrieve an anonymous author link; only the designated lead pastor and author can access that identity, with author edit/close, pastoral replies and archival behaviour following the baseline and agreed retention policy.

- **CAP-15 — Opt-in member directory**
  - **intent:** Members can choose which contact fields other approved members may discover.
  - **success:** Hidden-by-default records expose only opted-in fields, including birthday day/month only; API/search tests protect hidden and youth contacts, and assisted opt-in or relative contacts never grant automatic visibility.

- **CAP-16 — Staff web and mobile continuity**
  - **intent:** Staff can carry out their authorised work in a responsive web portal and perform essential actions on mobile against the same records.
  - **success:** Granted-role navigation, keyboard/list alternatives, save/error states and stale-edit checks work across both surfaces; desktop changes appear in mobile current state, and finance/care access is never inferred from a menu or role switch.

- **CAP-17 — Conditional moderated group chat**
  - **intent:** If the owner includes chat at launch, eligible members can communicate within their authorised moderated groups.
  - **success:** Approved active group membership, confirmed-cell eligibility, image limits, reactions, replies, read state, mute/report/block/remove flows and deletion rules pass the baseline; all approved core workflows also pass with chat disabled.

## Constraints

- Deliver the full approved v1 through all seven milestones by November 2026; programmes, recaps, visits, service counts, the staff portal and cell offerings are included. Chat alone has a separate launch decision.
- Behaviour, permissions and states follow functional-requirements.md, derived from spec 1.2 plus the approved no-SMS auth change. The adopted architecture governs implementation; design-contract applies the requirements to older prototype shortcuts.
- Use Flutter on iOS/Android and one Supabase-backed set of records, permissions and workflows. Flutter Web remains subject to the foundation trial; the adopted architecture retains stable AD IDs.
- Support a church of fewer than 200 members in English, with one volunteer owner reviewing agent-built changes. Reuse assignments, responses, follow-ups, permissions and reminders; keep changes small and testable in milestone order.
- A stable member identity can exist without credentials. Phone is an unverified login identifier; password authentication, church approval, cell confirmation and access review stay separate. No shared credentials, automatic phone-based identity merges or fake accounts.
- Current server-side grants, source-specific privacy, consent provenance, revisions and separation of duties govern every read, mutation and export on both clients. No fabricated confirmation, delivery/read state, attendance, receipt or completion.
- Cache public content and rights-cleared downloaded Bible/hymn text; do not persist private care, finance, programme or recap content for offline browsing. Unsent actions stay visibly unconfirmed; offline screens cannot be remotely erased.
- Use UTC timestamps and a church-approved IANA time zone; keep secrets server-side and schedule reminders independently of app execution. Prototype dates, people, destinations, figures and auth timers are not production configuration.
- Match the handoff visual system while retaining accessible text, touch targets, non-colour status labels and keyboard/list alternatives. Include mobile light/dark themes; the supplied staff design is light.
- Use phone number + password with no SMS. Optional recovery email must be verified and bound to the same account; otherwise use identity-checked staff assistance. Recovery never clears church/security holds or grants private access by itself. Other numerical defaults and operational-owner decisions remain provisional.
- Write permission, state-transition, concurrency and reminder tests with features from milestone 1 and run them in CI. Test database/file restoration, operational handover and support runbooks before release.

## Non-goals

- In-app payments, provider transaction verification, donor identities/allocations, gift claims/history, donor/tax receipts, card checkout or recurring giving.
- General ledger, bank reconciliation, budgets, expenses/payroll, exchange-rate conversion, named service attendance or unique-person claims from aggregate counts.
- Direct member-to-member chat, direct duty swaps, automatic rota optimisation or general availability collection; automated email/SMS/WhatsApp duty reminders remain deferred, and authentication sends no SMS.
- Livestreaming, devotionals, reading plans, multi-branch support, family-account switching or guardian-proxy access.
- General offline-first sync, browser-push dependency, a second staff identity/data store, or importing prototype runtime/state shortcuts as application logic.
- Mandatory chat, routine passkey/local-unlock features, SMS signup/login/recovery or a separate custom password store. Optional verified email recovery is included; a separate email-first product sign-in flow is not required.

## Success signal

- All approved modules pass the current requirements' detailed rules and 23 compound launch checks, mapped in `acceptance-map.md`, with the same privacy and workflow behaviour on mobile and web and the core usable without chat.
- A live church pilot demonstrates current duty coverage and explicit app/direct-contact responses before leaders need to chase on Sunday; assess the owner's involvement/chasing outcomes and proposed numerical measures in `delivery-and-decisions.md` without inventing baselines or treating push acceptance as delivery.

## Assumptions

- Source-labelled operational defaults remain provisional build inputs pending the corresponding owner decisions; they are not asserted church policy.
- Numerical success targets remain provisional while the final brief and its history disagree about approval status; clarification is recorded as Q11.

## Open Questions

- **Q1 — Access operations:** Who owns approvals and assisted recovery, what dormancy/password/abuse controls apply, and which production email configuration, budget and recovery procedure will support the approved no-SMS flow?
- **Q2 — Duties:** What church time zone, pilot teams/leaders, response deadlines, reminder offsets and quiet hours are approved?
- **Q3 — Giving:** What tested destinations, methods, purposes, currency and responsible publishing Admin should replace the examples?
- **Q4 — Safeguarding/privacy:** What youth/contact safeguards, lead-pastor designation, visitor consent and retention/deletion/backup policies apply?
- **Q5 — Rights:** Which Bible texts, hymn lyrics/recordings and Sunday-list content owners are cleared?
- **Q6 — Rollout/chat:** Who owns each approved module, in what rollout order, and is chat enabled at launch?
- **Q7 — Care/recaps:** Who holds care/visitor scopes, and what contact expectations, youth safeguards, testimony consent and recap-archive access apply?
- **Q8 — Service reporting:** Which recorders, service types, counting definitions, comparable periods, submission deadlines and retention rules are approved?
- **Q9 — Offerings:** Which currency, counter/custody procedure, independent Treasurer/deputy, export grants, deadlines and retention are approved?
- **Q10 — Web:** Does Flutter Web pass the foundation accessibility/grid trial, and what HTTPS hosting/domain/budget is selected?
- **Q11 — Success measures:** Are the 90% explicit-response and 48-hour coverage targets approved targets or still provisional, and what baselines and measurement definitions apply?
- **Q12 — Operational acceptance:** Which supported device/browser versions, performance and availability targets, reminder-timing tolerance and backup recovery objectives should release verification use?
