---
id: 3
type: "epic"
title: "Durable inbox and reliable reminders"
parent: "initiative-church-app"
covers: ["CAP-7"]
after: []
risk: "high"
---

# Durable inbox and reliable reminders

## Description

Provide the Notifications-owned inbox, jobs, attempts, tokens and authenticated worker, plus one policy-versioned scheduling calculation. Source owners register their actionability, recipient and lifecycle contracts; notification delivery never owns their business state.

Milestone: 2.

## Outcome

Outstanding work remains visible when push is unavailable, and app-closed scheduling retries useful work without sending known-obsolete reminders or inventing delivery, reading or consent.

## Requirements

The requirement source is the parent spec, CAP-7, read with every companion and with the owner's Q2 decisions in `owner-decisions-milestone-2.md`, which replace the Q2 proposals where they differ. The local ids below hold this epic's contribution; each maps to CAP-7 (N6 also to CAP-16), and the spec, its companions and the architecture stay authoritative for detail.

- **N1** (CAP-7) — Notifications owns `notification_jobs`, `notification_attempts` and durable inbox items. Owner operations enqueue and cancel jobs inside the calling source owner's transaction, under the unique logical key source_type/source_id/revision/recipient_member_id/reminder_kind/scheduled_at, and persist one inbox item per logical key whether or not push is allowed. Jobs record the source revision and the applied scheduling-policy version. Source: architecture AD-1, AD-2, AD-8; functional-requirements.md Reminder reliability, Core data model (Notifications).
- **N2** (CAP-7) — Source owners register a source check (current, revision, actionable, recipient still eligible), purposes, reminder kinds, generic notification text and an authorised deep-link target before they enqueue. Payloads and previews carry no private bodies, contact details or care/finance text; opening an item or a push re-reads current authorised state and explains a superseded source. Source: AD-5, AD-8, AD-13; functional-requirements.md Reminder reliability (lock-screen previews), Navigation (notification links); contracts-and-owner-seams.md.
- **N3** (CAP-7) — One tested scheduling calculation turns church-local intent in the Africa/Lusaka zone into UTC instants under a recorded policy version: creator-configured reminder offsets with owner defaults, the lead-time response-deadline default, short notice (passed offsets skipped, response requested now), merging of simultaneous reminders for one source, expiry, Waiting review dates, recurrence exceptions and member snooze. There are no quiet hours (owner decision 2026-10-08). A policy, zone or material schedule change reconciles future jobs in the same transaction without a retroactive flood. Source: AD-9; functional-requirements.md Proposed duty reminder defaults, Follow-up tasks (Task reminders); owner-decisions-milestone-2.md.
- **N4** (CAP-7) — A Cron-triggered, separately authenticated Edge worker running as a bounded system principal claims logged jobs in bounded batches with leases and fencing tokens, reclaims expired leases, and before each attempt rechecks the lease, the current source and revision, recipient binding and grants, actionability, the approved schedule and expiry. It retries within configured limits with backoff, expires obsolete work, never dispatches known-cancelled work, keeps one logical identity across duplicate workers and uncertain outcomes, and promises no exactly-once external delivery. Source: AD-8, AD-17, AD-19; functional-requirements.md Reminder reliability.
- **N5** (CAP-7) — Recipients resolve through current Identity state. An active linked account gets the inbox item and, if allowed, push work. A held, deactivated or accountless recipient gets no member-push job; the need goes to the source owner's registered direct-contact route. A relative's contact is never a destination. Device tokens and push settings follow the account link, and Identity lifecycle events (`sessions_revoked`, `access_hold_applied`, `membership_deactivated`, `account_deactivated`, deletion) retire tokens and cancel member-push jobs in Identity's transaction. Source: AD-3, AD-8, AD-14; functional-requirements.md Proposed duty reminder defaults (accountless and suspended members), Important edge cases (Reminders, Duties).
- **N6** (CAP-7, CAP-16) — Mobile and staff web show the durable inbox, notification settings (push categories; turning push off never removes in-app work) and member snooze (for example 2 days, 24 hours, 1 hour), with recoverable action states, generic per-account refresh signals and deep links that return to the item after sign-in and permission checks. Browser push is not required. Source: functional-requirements.md Navigation and visual style, Visit and operational reminders (web inbox); design-contract.md State fidelity 9; AD-5, AD-16; owner-decisions-milestone-2.md (snooze).
- **N7** (CAP-7) — Push goes through FCM (with iOS delivery configured) as generic expiring pointers with a stable notification id, bounded retry and invalid-token retirement. Each attempt records provider acceptance or failure only, never delivery, reading, response or consent. Native push acceptance uses suitable device and provider evidence, not the installed AOSP emulator. Source: AD-8, AD-18; functional-requirements.md Reminder reliability, Architecture (Push).
- **N8** (CAP-7) — Staff operational health shows last scheduler success, delayed jobs, failed leases and attempts and retired tokens without private content, and a notification-failure runbook covers recovery. After an evidence-led refactor sweep, the implemented workflows reach production once their affected gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence. Source: functional-requirements.md Reminder reliability (admin health view), Access and reliability requirements (runbooks); AD-17, AD-18.

## Done when

1. Transactional enqueue/cancel operations and a stable logical key produce one durable inbox item per reminder independently of push permission. Versioned source/revision/purpose contracts, generic payloads and current authorized deep links are consumable by later domain owners.
2. A separately authenticated bounded system principal claims logged jobs with leases and fencing, rechecks current source and recipient eligibility before each attempt, retries within configured limits, expires obsolete work and retires invalid tokens. Duplicate workers and uncertain provider outcomes preserve logical identity without promising exactly-once external delivery.
3. One tested scheduling calculation handles church-local intent, policy versions, quiet hours (none, by owner decision 2026-10-08: reminders are sent when due at any hour), creator-configured offsets and member snooze, passed short-notice offsets, recurrence exceptions and task review dates. Accountless or held recipients use the source owner's direct-contact route; relative contacts are not automatic notification destinations.
4. Mobile and staff expose the durable inbox, notification preferences and recoverable action states; staff operational health shows scheduler and failure metadata without private content. Browser push remains unnecessary.
5. Synthetic source adapters prove app-closed processing, denied push, retries, cancellation, stale revisions and revoked scope. Consuming feature envelopes add their real source adapters and end-to-end cases; native push acceptance uses suitable device/provider evidence rather than the installed AOSP emulator alone.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Notifications alone owns delivery records, worker leases and the inbox. Follow-ups is implemented by the duties/follow-up envelope; this envelope defines and tests its notification-facing contract with synthetic fixtures, never creates a competing task registry or mutates another owner's source.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Shared source/purpose/event and command fixtures, authenticated system-principal boundary, synthetic CI/environment separation and server-secret conventions.
- Epic 2 (epic-identity-and-scoped-access) supplies Current account/grant eligibility checks, account-to-member bindings, holds and token-revocation hooks; the whole membership UI need not be complete.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-7
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Reminders and follow-up; Reminder reliability
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-2, AD-5, AD-7, AD-8, AD-9, AD-17, AD-18, AD-19
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 2; Q2, Q12; Success evidence
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.
- owner decisions — _bmad-output/initiative-church-app/owner-decisions-milestone-2.md, Q2 (time zone, reminders, snooze, no quiet hours); owner-decisions-milestone-1.md (synthetic data, no SMS, production gated, owner-held secrets).
- seams — docs/runbooks/contracts-and-owner-seams.md (source/purpose/reminder-kind registration, lifecycle, handover and deletion hooks, policy gates); docs/runbooks/system-access-and-operations.md (system route, principals, credentials); docs/runbooks/identity-access.md, stories 2.3, 2.8, 2.10, 2.11.

## Notes

- Owner decision (2026-10-08, owner-decisions-milestone-2.md): Q2 is answered. The church zone is Africa/Lusaka. Reminders are configured by the person who sets the duty or task; the assigned member can snooze; there are no quiet hours. These replace the Q2 proposals (quiet hours 21:00–07:00, fixed −24 h/−2 h offsets) in functional-requirements.md and delivery-and-decisions.md. The spec text is unchanged; the stories follow the owner decision.
- Unknown: Production scheduling still needs `q2_church_time` approved in production by Israel with the decided values (`app.policy_approve`), and Q12 must set the measurable reminder-lateness tolerance before release; staging uses labelled fixture values.
- Unknown: Push needs a Firebase project, an FCM service credential held only in server secrets, an APNs key for iOS and a real Android/iOS device for evidence. Israel creates and holds these; until then push stays off and the inbox and leader direct-contact routes carry every reminder.
- Constraint: Duty acceptance cancels response chasing but preserves eligible accepted-duty pre-service reminders. Missing reports retain their source-specific schedule rather than receiving both it and generic task alerts.
- Constraint: A cancellation after the last check cannot retract an externally accepted push. Generic expiring pointers and authorization on open bound that race.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Decision (agent, under owner pre-approval, 2026-10-08): Incepted as a full inception under owner-decisions-milestone-1.md and owner-decisions-milestone-2.md, which authorise the milestone runs without stopping. The envelope's line saying no local requirement ids are introduced is replaced by N1–N8, mapped to CAP-7 (and CAP-16 for N6), so entries cite stable ids as the identity epic does. Scope, ID and production verification are unchanged; Done when 3 is reworded only to state the owner's no-quiet-hours decision and the configurable reminders and snooze.
- Decision (agent, under owner pre-approval, 2026-10-08): The tracer bullet is entry 1: a synthetic source command enqueues a due job in its own transaction, the worker run through the bounded system route turns it into one inbox item, and the same item is visible on mobile and staff web on hosted staging. Entry 2 (source contracts, generic payloads and deep links) and entry 3 (the scheduling calculation) follow in parallel, because Duties needs both and the scheduling calculation is the least certain part.
- Decision (agent, under owner pre-approval, 2026-10-08): No quiet hours. The scheduling calculation has no quiet-hours window, deferral or "previous evening" rule, and the late-night direct-contact warning that depended on quiet hours is not built. The no-spam intent is met by sending only creator-configured reminders and member snoozes, merging simultaneous reminders for one source, deduplicating by logical key and stopping response reminders once the member answers. `q2_church_time` keeps `quiet_hours: null`.
- Decision (agent, under owner pre-approval, 2026-10-08): The response-deadline default from the owner decision is computed by the shared scheduling calculation (entry 3), because Duties and later visit proposals reuse it. Creator-set deadlines win when they are before the duty start. Default when none is set: duty starts 30 days or more after assignment → 14 days before start; 2 to 30 days → 48 hours before start; within 48 hours → 24 hours before start, or due now (short notice) if that has passed; never later than the start. These are the agent's interpretation of the owner's ranges and stay adjustable policy values, not code constants.
- Decision (agent, under owner pre-approval, 2026-10-08): Default reminder offsets when the creator sets none are the owner's: one reminder 24 hours before the response deadline and one at the deadline. Snooze choices offered to members are 1 hour, 24 hours and 2 days (the owner's examples), stored as policy so they can change. A snooze defers only that recipient's copy of that reminder, can never move it past the source's expiry, and is cancelled with the job when the member responds or the source is cancelled.
- Decision (agent, under owner pre-approval, 2026-10-08): Staging and local keep a labelled TEST FIXTURE for `q2_church_time`, changed from UTC to Africa/Lusaka with the decided defaults, so tests exercise the real zone. Production stays fail-closed until Israel approves the gate at entry 10; no production scheduling is enabled before that.
- Decision (agent, under owner pre-approval, 2026-10-08): Push is split from the worker. Entries 1–5 and 7 deliver a complete inbox, scheduling and direct-contact path with push off; entry 6 adds FCM and is the only entry that needs the owner's Firebase/APNs setup and device evidence, so a late Firebase project does not block Duties.
- Decision (agent, under owner pre-approval, 2026-10-08): Generic per-account refresh signalling (AD-5) is delivered with the inbox screens in entry 7, because the inbox is its first consumer and later epics (staff portal, chat) reuse it.
- Decision (agent, under owner pre-approval, 2026-10-08): Cross-epic prerequisites are pinned per entry: the tracer needs 1.9 (system route), 2.1 (live access predicate) and 1.7 (client shells); recipient routing needs 2.8 (`sessions_revoked`, holds), 2.10 (deactivation events, handover hooks) and 2.11 (deletion hooks); the health view needs 2.3 (Admin role); production delivery needs 2.14 (identity in production, which includes 1.12).
- Decision (agent, under owner pre-approval, 2026-10-08): No `plan_checkpoint`, `done_checkpoint` or `refine` flags are set. The hitl entries (1, 4, 6, 10) pause for the owner by their nature: each needs a secret or account only Israel holds, or his release review.
- Decision (agent, under owner pre-approval, 2026-10-08): The draft set and dependency checks ran inline, because this run could not start independent validation agents. `tickets.py status` was run on the written breakdown.
- Lane boundary: Entries 2 and 3 run in parallel only while 2 owns source registration, payload templates and deep-link targets, and 3 owns the scheduling functions and the policy value. Entries 6 and 7 run in parallel only while 6 owns the FCM adapter, push registration and push-tap handling, and 7 owns inbox screens, snooze and settings screens and the refresh signal.
- External high-risk checks: An independent reviewer repeats the duplicate-worker, lease-expiry and stale-revision cases from entry 4 and the held/accountless routing cases from entry 5 before entry 10. Israel reviews the integrated demonstration and approves each production gate.
