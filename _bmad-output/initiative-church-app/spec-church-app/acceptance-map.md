# Acceptance and preservation map

This is a verification plan, not a claim that application tests have run. Read the exact requirements in [functional-requirements.md](functional-requirements.md). Its **Must pass before launch** section has 23 compound bullets; the brief's “roughly 40” is not a literal test inventory. Each bullet can require several tests, and the detailed section/edge-case rules remain mandatory.

## Launch checks

AC numbers below are traceability labels in source order, not additional capability IDs. Conditional chat references do not make chat mandatory. The line numbers refer to the current functional-requirements.md. Original spec 1.2 is audit-only; auth checks reflect the owner-approved no-SMS update.

| Check | Source line | Coverage summary | Capabilities |
| --- | --- | --- | --- |
| AC-01 | 603 | Phone/password signup without SMS; blank email; distinct approvals and unresolved-cell choices | CAP-3 |
| AC-02 | 604 | Cell choice grants no access; confirmed transfers change scope atomically | CAP-3, CAP-4, CAP-9, CAP-10, CAP-17 |
| AC-03 | 605 | Consented accountless registration, duties/attendance and later reviewed identity-preserving link | CAP-3, CAP-5, CAP-6, CAP-8 |
| AC-04 | 606 | Persistent refresh; returning/new-device password login without SMS or blanket reapproval | CAP-3 |
| AC-05 | 607 | Unverified/duplicate/shared phone usernames, verified-email or assisted recovery, credential changes, holds/dormancy and no phone-based takeover | CAP-3, CAP-4 |
| AC-06 | 608 | Password/rate limits; verified-email delivery/reset and no-email assistance; direct OTP/verify denial; no SMS; fresh password login and old-session invalidation | CAP-3, CAP-4 |
| AC-07 | 609 | Guest giving instructions; no individual payer/payment records | CAP-2, CAP-13 |
| AC-08 | 610 | Publish multi-position duties; explicit response and visible remaining gaps | CAP-5, CAP-6 |
| AC-09 | 611 | Declined/unanswered follow-up; replacement request and old-job cancellation | CAP-5, CAP-6, CAP-7 |
| AC-10 | 612 | Material-change reconfirmation and rejection of old-revision responses | CAP-5, CAP-9 |
| AC-11 | 613 | App-closed/denied/invalid/offline push, quiet hours, short notice, recurrence and retry cases | CAP-7 |
| AC-12 | 614 | Visitor/missing-report ownership, due dates, overdue visibility and reminder closure | CAP-6, CAP-7, CAP-8 |
| AC-13 | 615 | Private records/contacts/anonymous identity protected; safe programme names; team scope | CAP-4, CAP-5, CAP-6, CAP-9, CAP-14, CAP-15 |
| AC-14 | 616 | All approved core features remain usable with chat deferred | CAP-1, CAP-8, CAP-9, CAP-10, CAP-11, CAP-12, CAP-13, CAP-14, CAP-15, CAP-17 |
| AC-15 | 617 | Programme revision assignments, direct provenance, separate notice and actual leaders | CAP-5, CAP-9 |
| AC-16 | 618 | Private report versus safe recap publication/withdrawal and cell-scope loss | CAP-4, CAP-8, CAP-10 |
| AC-17 | 619 | Visit request/negotiation/current consent, direct contact and outstanding care separation | CAP-7, CAP-11 |
| AC-18 | 620 | Every owner sees follow-ups; no orphan trackers or stale jobs after terminal/reassigned work | CAP-6, CAP-7, CAP-16 |
| AC-19 | 621 | Scoped/versioned counts and corrections; zero/missing/cancelled and honest trends | CAP-12 |
| AC-20 | 622 | Independent count/receipt; partial/mismatch/corrections/concurrency/idempotency/handover | CAP-4, CAP-13 |
| AC-21 | 623 | Current finance totals; scoped/formula-safe export, excluded private fields and audit | CAP-13 |
| AC-22 | 624 | Identical client scope/hold restrictions and deletion with approved retention | CAP-3, CAP-4, CAP-16 |
| AC-23 | 625 | Accessible permitted-role portal, recoverable forms/stale writes and all six additions | CAP-4, CAP-16, CAP-9, CAP-10, CAP-11, CAP-12, CAP-13 |

## Auth verification detail

- Registration with no email and with an optional email creates one Auth account; linking/verification never duplicates or auto-merges a member. Shared-contact and number-claim conflicts have reviewed resolution.
- Check valid/wrong password, configured length/breach/abuse controls, enumeration-safe errors, password-manager support, persistent refresh and new-device login.
- Email recovery accepts only the previously verified approved account binding; bad, expired, reused, changed or unverified addresses/links cannot grant private access. No-email assistance binds one-use setup to the reviewed member/account-link revision and recovery generation. Test an unused older grant after reissue, password/credential change, relink, deactivation/deletion, plus concurrent redemption, uncertain Auth outcomes and stale completion; none may reset a new identity, bypass a hold or overtake the current recovery.
- Call native Auth endpoints directly: OTP, magic-link and recovery sessions (including those labelled otp) fail private-data gates unless followed by current password authentication. No SMS provider, hook, test code or mock confirmation can bypass the gate.
- Verify password-change/reset invalidation of older sessions across mobile/web, fresh password login, preserved holds/deactivation/roles and identity history, and no password/token leakage in logs or staff tools.
- Email outages preserve phone/password access and the staff help route; no email is made mandatory. These are required implementation tests, not tests run by this document update.

## Detailed source coverage

functional-requirements.md preserves the full spec 1.2 role matrix, state catalogues, logical entities, schedules, limits and edge cases, replacing only the approved authentication requirements and their dependent checks. The updated architecture is a required adopted companion. This mapping locates the kernel entry points; it does not replace those details.

| Source section/content | Contract destination |
| --- | --- |
| Overview, priorities, constraints and non-goals | Kernel Why/Constraints/Non-goals; delivery commitment; current functional requirements |
| Roles and permissions | CAP-4; adopted role matrix and scoped-grant rules, including combined-role separation |
| Auth and membership (all subsections) | CAP-3/CAP-4; Q1/Q4; approved phone/password/no-SMS, verified-email/staff recovery, credential-binding and lifecycle rules |
| Navigation and visual style | CAP-1/CAP-5/CAP-6/CAP-9/CAP-11/CAP-16; design-contract and adopted safe navigation/access states |
| Departments/duties (all subsections) | CAP-5/CAP-6; adopted occurrence/position/revision/conflict/completion rules |
| Reminders, task/visit schedules and reliability | CAP-6/CAP-7; Q2; adopted exact schedules, privacy, deduplication and cancellation rules |
| Giving instructions (all subsections) | CAP-2; Q3; adopted publication, destination verification and cache/withdrawal rules |
| Bible/hymns, sermons, events/announcements | CAP-1; Q5; adopted content fields, import/search/audio/rights and linked-event mismatch rules |
| Prayer and directory | CAP-14/CAP-15; Q4; adopted identity separation, reply/archive and field-level opt-in rules |
| Group chat | Conditional CAP-17; Q6; adopted 1 MB/image and 10/message limits, scope, reporting/blocking/moderation and retention |
| Cells, programmes and recaps | CAP-8/CAP-9/CAP-10; Q7; adopted absence streaks, private reports, safe publication and archive/scope-loss rules |
| Pastoral visits | CAP-11; Q7; adopted request/appointment/task separation, bilateral current-revision consent and private-source handling |
| Service attendance/pastoral overview | CAP-12; Q8; adopted metric-definition versioning, correction, denominators and missing-count queues |
| Cell offerings | CAP-13; Q9; adopted independent receipt, exact amount bases, corrections, safe scoped CSV and custody handover |
| Staff web portal | CAP-16; Q10; adopted shared identity/server commands, essential mobile work and accessible alternatives |
| Architecture, core data model, access/reliability | Kernel constraints; adopted architecture AD-1–AD-20; full entity catalogue, RLS/storage/function grants, transactions, credential/session checks, audits and restoration |
| Important edge cases | Adopted entire table; capability-specific negative/recovery tests, not only happy-path launch demos |
| Tradeoffs, owner decisions, risks/release checks, milestones, Later | Delivery-and-decisions; kernel boundaries; adopted source qualifications and explicit deferrals |
| Brief solution, approval, full-November target, agent/owner workflow, success measures and delivery risks | Kernel Why/Constraints/Success; delivery-and-decisions including Q11 |
| Addendum's binding design map/conflicts; Oct 2 integration additions | Design-contract and source-precedence constraint; all six additions retained |
| Handoff visual values, copy, screen layouts, assets and safe interactions | Design-contract links all 32 reference screens and both prototypes; older permission/state shortcuts explicitly overridden |

## Verification boundaries

- Exercise allowed and denied reads/mutations/exports for every role, access state and relevant combined-role case through APIs as well as both clients; include revoked grants and stale sessions/tabs.
- Test source revision races, retries, duplicate writes, reassignment, holds, removal and deletion at transactional boundaries. Acceptance/attendance/consent/receipt facts retain actor, time and provenance.
- Demonstrate public versus private caching, safe notification/deep-link/search/audit behaviour, and practical restore/handover runbooks. An offline private screen cannot be remotely wiped.
- Test native iOS/Android and target mobile/desktop browsers, readable light/dark member screens, keyboard/focus/list alternatives, pending/error states and comparison against supplied visual references.
- No app code, infrastructure or live church data is created by this spec run. Document validation does not mean permissions, delivery, store approval, rights or church policy have already passed their release gates.
