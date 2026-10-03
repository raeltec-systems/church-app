---
id: 12
type: "epic"
title: "Scoped service counts and honest participation trends"
parent: "initiative-church-app"
covers: ["CAP-12"]
after: []
risk: "high"
---

# Scoped service counts and honest participation trends

## Description

Deliver Services-owned occurrences, recorder assignments, aggregate submissions/corrections and missing-count queues, with versioned comparable metrics and safe pastoral overview integration.

Milestone: 5.

## Outcome

Authorized staff can capture observed aggregate attendance and understand trends with the exact count basis, period and incomplete coverage visible.

## Requirements

The requirement source is the parent spec, CAP-12, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Authorized setup assigns service types/schedules and scoped recorders to stable occurrences, linking an existing event without duplicate counting. Scheduled/Held/Cancelled remain distinct from Unrecorded/Draft/Submitted count state, including explicit submitted zero.
2. Recorders submit and correct counts using the approved versioned definition, revision checks and attributed reasoned history. Validation, unusual-value warnings and duplicate/replay handling never infer observations from RSVP, duty or missing data.
3. Missing submissions have an accountable recorder and follow-up date through the existing task registry. Scope/lifecycle changes reroute responsibility and cancel obsolete reminder work; cancelled occurrences require no count.
4. Trends and pastoral overview disclose period, metric-definition version, denominator, included/missing coverage and cancellation treatment; incompatible definitions do not silently mix. Cell aggregates retain historical-roster and incomplete-register meaning, and visitor figures mean attendances rather than unique people.
5. Web recording/correction/queue/trend surfaces and required mobile continuity pass permission, concurrency, incomplete-data and correction tests, with real-procedure pilots under approved definitions; this epic exports the safe count/cell-metric projection for epic 14 to compose with separately authorized care and finance sections.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Services owns aggregate service observations and counting definitions. Cells owns named cell registers and its aggregate projection; Care and Offerings retain private sources. No named service attendance, demographic breakdown or unique-congregant total is introduced. Full pastoral-overview composition across Care and Offerings belongs to epic 14; this epic supplies service metrics and consumes the Cells aggregate contract without waiting for the later finance implementation.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Scoped recorder and authorized overview grants, stable actor attribution and staff handover hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Missing-count/task notification contract and cancellation behavior.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Follow-ups source/purpose registration, accountable recorder task operations and safe routing projection.
- Epic 6 (epic-public-content-and-giving) supplies Stable public event reference/occurrence-link contract for services linked to existing events; no need to await all content features.
- Epic 7 (epic-cell-attendance-and-private-reports) supplies Scoped historical-roster-based cell aggregate/coverage projection for the shared overview; service recording can be implemented independently of its full UI.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-12
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Service attendance and pastoral overview; Staff web portal
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-2, AD-4, AD-7, AD-9, AD-12, AD-14, AD-18
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 5; Q8, Q11
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Required first-release addition. Q8 gates service types, recorder assignments, counting definitions, comparison rules, deadlines and retention before live pilot.
- Unknown: Q11 gates claims against proposed numerical success targets rather than ordinary authorized reporting. No comparison interval, visitor-subset rule or denominator is silently approved here.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
