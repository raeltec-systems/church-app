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

The requirement source is the parent spec, CAP-7, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Transactional enqueue/cancel operations and a stable logical key produce one durable inbox item per reminder independently of push permission. Versioned source/revision/purpose contracts, generic payloads and current authorized deep links are consumable by later domain owners.
2. A separately authenticated bounded system principal claims logged jobs with leases and fencing, rechecks current source and recipient eligibility before each attempt, retries within configured limits, expires obsolete work and retires invalid tokens. Duplicate workers and uncertain provider outcomes preserve logical identity without promising exactly-once external delivery.
3. One tested scheduling calculation handles church-local intent, policy versions, quiet hours, passed short-notice offsets, recurrence exceptions and task review dates. Accountless or held recipients use the source owner's direct-contact route; relative contacts are not automatic notification destinations.
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

## Notes

- Unknown: Q2 must approve the church zone and scheduling policy before production scheduling; synthetic fixture values are visibly test-only. Q12 supplies release timing tolerance.
- Constraint: Duty acceptance cancels response chasing but preserves eligible accepted-duty pre-service reminders. Missing reports retain their source-specific schedule rather than receiving both it and generic task alerts.
- Constraint: A cancellation after the last check cannot retract an externally accepted push. Generic expiring pointers and authorization on open bound that race.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
