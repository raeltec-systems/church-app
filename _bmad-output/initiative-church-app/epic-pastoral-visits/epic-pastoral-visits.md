---
id: 9
type: "epic"
title: "Agreed pastoral visits and continuing care"
parent: "initiative-church-app"
covers: ["CAP-11"]
after: []
risk: "high"
---

# Agreed pastoral visits and continuing care

## Description

Implement Care-owned requests, revisioned appointment proposals and attributed responses with one accountable follow-up, accessible staff board/list and essential mobile actions.

Milestone: 4.

## Outcome

Members and authorized care staff agree to the same current visitor/time/location proposal, while appointment outcomes and any unresolved care need remain truthful and separately actionable.

## Requirements

The requirement source is the parent spec, CAP-11, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Members and consent-aware authorized referrers create requests with stated visibility, minimal reason/preferences and correction/withdrawal controls. Care owner/visitor/supervisor scopes expose only authorized case details; Admin routing excludes reasons, notes and precise private locations.
2. Proposal, acceptance, decline and suggested-time flows confirm only when both required parties agree to the same current revision. Attributed direct-contact consent supports accountless/held members; material visitor/time/location changes renew agreement and cancel obsolete reminders.
3. Safe conflict checks and reasoned overrides cover known duties and authorized appointment conflicts without leaking other care details or asserting availability. Board movement invokes permitted forms/transitions; drag-to-Confirmed cannot manufacture consent, and keyboard/list alternatives perform the same commands.
4. Request lifecycle, appointment state and source-linked task status stay separate. Decline, cancellation, completion and Not completed terminate the appointment's reminders; still-wanted care retains an owned next action without duplicate trackers or automatic completion from time passing.
5. Both clients pass privacy, current-scope, stale-revision, direct-consent, reassignment and reminder tests. Referral links to private reports preserve source permissions, and anonymous-prayer identity cannot be obtained through a referral or task.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Care owns visit requests/proposals/responses/private notes and registers their task/job effects. Duties supplies safe duty-conflict information; Follow-ups owns tasks and Notifications delivery. No emergency-service guarantee, inferred consent or general availability engine is introduced.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Current explicit care/visitor scopes, stable member/contact attribution, accountless access model and lifecycle hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Proposal/deadline/appointment reminder adapters and transactional cancellation contracts.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Canonical Follow-ups operations, safe conflict query and minimal routing-context contracts.
- Epic 7 (epic-cell-attendance-and-private-reports) supplies Permission-preserving private-report referral reference contract for the report-originated entry point; member-originated visits may be built earlier.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-11
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Pastoral visits; Visit and operational reminders; Staff web portal
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-2, AD-4, AD-5, AD-7, AD-8, AD-9, AD-10, AD-13, AD-14
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 4; Q4, Q7
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Required first-release addition. Q7 gates care/visitor owners, contact expectations and youth safeguards; Q4 governs live personal data and retention.
- Constraint: Prayer remains a separate privacy owner: ordinary pastoral/care assignment never grants the anonymous author mapping. Integration uses an explicitly authorized member-originated request when needed.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
