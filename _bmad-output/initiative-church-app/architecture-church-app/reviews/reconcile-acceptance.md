# Acceptance-map reconciliation

Date: 2026-10-03

**Verdict: PASS.** All AC-01–AC-23 have an architecture owner, an applicable invariant and a verification route. No missing shared foundation or contradictory mechanism requiring a spine change was found. This is document reconciliation, not a claim that application, infrastructure or provider tests passed.

Compared `spec-church-app/acceptance-map.md`, the corresponding 23 launch bullets in adopted spec 1.2, and the draft `architecture-church-app.md`. The architecture explicitly retains the complete baseline and all detailed edge cases; source-level test details do not need duplication in the initiative spine. The new architecture memlog was not read.

## Check-by-check coverage

| Check | Architecture home and rules | Verification constraint retained |
| --- | --- | --- |
| AC-01 | Identity; AD-3, AD-18; Q1 | Separate registration, church approval and cell confirmation; bounded applicant access. Blank optional email and unresolved-cell choices remain required baseline fixtures. |
| AC-02 | Identity + Cells lifecycle command; AD-2, AD-3, AD-4, AD-14 | Cell selection conveys no approved scope; confirmed transfer changes grants, relevant work and group access in one transaction. Test stale sessions and both clients. |
| AC-03 | Identity + Duties + Cells; AD-3, AD-6, AD-8, AD-14 | Stable member identity supports no-login members, attributed direct confirmation and later reviewed account linking. Test history preservation and contact routing. |
| AC-04 | Identity/Auth adapter; AD-3, AD-16, AD-18 | Refresh and new-device login cannot change approval/review states. The adopted no-OTP-on-reopen rule remains a native session test, not an assertion made by architecture review. |
| AC-05 | Identity/live access; AD-3, AD-4, AD-18; Q1 | Contacts are not identity keys; current credential binding, holds and dormancy are server checked. Duplicate/shared-contact/recovery fixtures and residual recycled-number risk remain explicit. |
| AC-06 | Auth provider/environment configuration; AD-3, AD-17, AD-18; Q1 | Selected route, real-network OTP delivery, rate/spend controls, quote and owner approval remain activation gates. Synthetic preparation cannot satisfy them. |
| AC-07 | Content, isolated from Offerings; AD-15 | Public giving is accessible without Auth and has no payer/payment entities. Test absence of personal financial history as well as the guest instruction flow. |
| AC-08 | Duties + Follow-ups; AD-6, AD-7 | Multi-position ownership and current assignments drive coverage; explicit responses remain distinct facts. Verify coverage queries and visible remaining gaps. |
| AC-09 | Duties + Follow-ups + Notifications; AD-2, AD-6, AD-7, AD-8 | Replacement and task/job effects are transactional; old-recipient work is cancelled. Test decline/unanswered routes, reassignment and retry races. |
| AC-10 | Duties revisions; AD-2, AD-6 | Material changes supersede consent; expected revisions and current-response checks reject stale responses. Test concurrent and late submissions. |
| AC-11 | Notifications + scheduling policy; AD-8, AD-9, AD-17, AD-18 | Durable jobs, bounded retries, token retirement, recurrence, short notice and quiet hours are centrally governed. Exercise native denied/offline/app-closed cases using an FCM-capable environment. |
| AC-12 | Cells + Follow-ups + Notifications; AD-7, AD-8, AD-9 | One source-linked task has an owner, deadline, review/overdue semantics and terminal cancellation effects. Test source-specific missing-report schedules. |
| AC-13 | Identity + owner projections; AD-3, AD-4, AD-5, AD-13 | Current scope applies across APIs, files, queries and subscriptions. Separate programme/routing/prayer projections prevent field-hiding leaks. Test every allowed and denied role/combined-role case. |
| AC-14 | Every core owner independent of Chat; AD-15, AD-18 | CAP-17 alone is conditional. Run core feature workflows with Chat absent/disabled; all six additions remain required. |
| AC-15 | Cells using Duties; AD-6, AD-12 | One revisioned assignment engine, direct-confirmation provenance and separate intent/actual facts. Test replacement and actual-leader correction history. |
| AC-16 | Cells safe publication; AD-4, AD-5, AD-13, AD-14 | Reports and published recaps are separate records; explicit revision publication and current-cell access. Test preview/publish/withdraw plus raw-report denial and transferred-member access. |
| AC-17 | Care + Follow-ups + Notifications; AD-2, AD-7, AD-8, AD-10 | Current-revision bilateral consent, attributed direct contact and independent outstanding care. Test drag without evidence, material changes and terminal appointment states. |
| AC-18 | Follow-ups and both clients; AD-7, AD-8, AD-16, AD-18 | Ordinary assigned members can use My follow-ups; source/task transitions share a transaction. Home placement remains adopted design behaviour. Test no orphan trackers/jobs on completion or reassignment. |
| AC-19 | Services + Follow-ups; AD-4, AD-7, AD-12; Q8 | Scoped observations, historical definitions, missing/zero/cancelled distinctions and honest comparison metadata. Test corrections and approved counting definitions before live comparisons. |
| AC-20 | Offerings + lifecycle commands; AD-2, AD-4, AD-11, AD-14 | Person-level independence, exact amounts, append-only corrected attestations and idempotent locked commands. Test partial/mismatch/duplicate/concurrent/no-collection/handover cases from the baseline. |
| AC-21 | Offerings reporting/export; AD-4, AD-11, AD-12 | Current revisions and amount bases govern totals; scoped allowlisted formula-safe CSV records audit. Test superseded records, date/currency filters and private-field exclusion. |
| AC-22 | Identity + all surfaces + deletion workflow; AD-3, AD-4, AD-13, AD-14, AD-16 | Same live access predicate and commands across clients; access-denied tombstone precedes resumable external deletion. Test scope combinations, stale tabs, cleared sessions and approved retention/restore handling. |
| AC-23 | Shared client contract + staff framework trial; AD-2, AD-16, AD-18; Q10/Q12 | Keyboard/screen-reader/grid/CSV/browser trial precedes framework selection; stale writes conflict and recoverable form input survives failure. All six additions retain release workflow tests. |

## Verification cautions already correctly represented

- AD-8 distinguishes cancellation of known obsolete jobs from the unavoidable race after the last server check and external provider acceptance. Its generic expiring payload and authorised deep-link read preserve current-state safety without asserting exactly-once delivery. AC-11 fixtures should separately verify pre-send eligibility/cancellation and post-acceptance pointer safety; a provider acknowledgement is not proof of device delivery.
- AD-18 requires both API permission tests and client workflows from milestone 1. Screenshots, this reconciliation and the installed AOSP emulator are not evidence that those tests passed.
- Owner/provider choices Q1–Q12 remain affected activation gates. The spine does not silently approve values needed by OTP, scheduling, safeguarding, finance, web accessibility or restoration acceptance.

No blocking findings. No additional architecture decision is requested by this reconciliation.
