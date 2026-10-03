---
id: 4
type: "epic"
title: "Assigned duties, coverage and accountable follow-up"
parent: "initiative-church-app"
covers: ["CAP-5", "CAP-6"]
after: []
risk: "high"
---

# Assigned duties, coverage and accountable follow-up

## Description

Implement Duties as the sole assignment authority and Follow-ups as the shared all-owner task registry. Deliver department rotas, revision-specific member/direct responses, coverage and practical contact work, while exposing owner operations for cell programmes and later care/reporting/custody consumers.

Milestone: 2.

## Outcome

Members know their current responsibilities, and leaders can see each uncovered or unanswered position and its accountable next action without a disconnected tracker.

## Requirements

The requirement source is the parent spec, CAP-5, CAP-6, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Leaders create draft/published one-off and recurring multi-position department duties with validated ownership, safe overlap warnings and reasoned overrides. One current assignment per slot, occurrence/series exceptions and atomic multi-position edits preserve history and truthful coverage.
2. My duties supports explicit Accept, decline, later decline, revision-specific reconfirmation, selected-date bulk acceptance and separately attributed leader confirmation for direct contact. Stale responses fail; offline/unknown outcomes never appear confirmed; completion/corrections remain separate from response and time passing.
3. Scoped leader queues expose unfilled, unanswered, overdue, declined, material-change and direct-contact needs. Reassignment, cancellation and lifecycle effects update assignment history, coverage, source-linked tasks and notification jobs together.
4. Follow-ups provides one source/purpose-keyed task with accountable owner, supervisor, next action, original due date and current status/review date. All owners see My follow-ups; source-specific minimal context and private notes stay separate; reassignment/resolution removes old-owner or obsolete work without inventing source completion.
5. Permission, revision, replay/concurrency and reminder tests cover app members, accountless members, scope loss and accepted-duty reminders. Shared Duties and Follow-ups owner APIs and fixtures are ready for programmes, visitors, care, missing counts/reports and offering custody; a department pilot exercises the complete response/contact loop.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Owns department setup/standalone duty recurrence, Duties assignments and Follow-ups task/activity records. Does not own cell meeting recurrence, visit consent, attendance or finance facts. Cell programmes call these owner operations instead of cloning their records; Notifications retains inbox/job/attempt ownership.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Shared owner registry, command/revision/idempotency contracts, lock-order fixtures and accessible reusable client primitives.
- Epic 2 (epic-identity-and-scoped-access) supplies Stable member/account identity, department/cell authority, accountless contact attribution and current lifecycle/access hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Transactional enqueue/cancel/inbox APIs, policy-versioned scheduling and synthetic source-contract fixtures; all later domain notification integrations are not prerequisites.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-5, CAP-6
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Departments and assigned duties; Follow-up tasks; Important edge cases
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1, AD-2, AD-4, AD-6, AD-7, AD-8, AD-9, AD-14, AD-18
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 2; Q2, Q11; Success evidence
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q2 gates the real department/cell pilot, zone, deadlines, offsets and quiet hours. Numerical 90%/48-hour success targets remain Q11 proposals rather than acceptance defaults.
- Constraint: Programme owner operations can be integrated as soon as Duties and Follow-ups contracts land; that work need not wait for every rota screen.
- Constraint: The later Content event-link integration flags a mismatch for leader review; content editing must not silently reschedule or republish a duty.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
