---
id: 14
type: "epic"
title: "Staff portal completion and mobile continuity"
parent: "initiative-church-app"
covers: ["CAP-16", "CAP-12"]
after: []
risk: "high"
---

# Staff portal completion and mobile continuity

## Description

Complete the shared-account staff portal and cross-client operational experience built incrementally with earlier domain envelopes, including authorized reporting composition, accessibility and current-state continuity.

Milestone: 6.

## Outcome

Staff can finish permitted administration/reporting on the responsive portal and essential actions on mobile using the same records, permissions and transitions.

## Requirements

The requirement source is the parent spec, CAP-16, CAP-12, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Granted-role navigation and scoped administration/reporting cover the baseline Admin, cell leader, Pastor, Treasurer, recorder, counter and visitor work. A role switch changes view context only and cannot expand current server authority.
2. Rota/care boards and dense reporting have keyboard/list/button alternatives, visible focus, responsive layouts, non-colour status labels and clear validation/save/error/conflict behavior. The selected web framework and supported browser matrix have evidence from the foundation trial and feature verification.
3. Essential mobile staff actions remain available across duties/follow-ups, programmes/attendance/reports, recaps, care proposals and permitted offering custody. Desktop edits appear as authorized current state on mobile; stale tabs/credentials reject operations rather than overwrite newer records.
4. Cross-module overview/search/navigation/inbox composition reads only independently authorized projections. Admin-only, Treasurer-only and combined-role cases preserve care/finance/anonymous-prayer boundaries and no-private-cache behavior on both surfaces.
5. Each approved domain's cross-client fixtures and full workflow checks pass, with recoverable failures and operations runbooks linked to the responsible module. Portal completion does not rely on chat or browser push.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Completes client composition and cross-client acceptance; domain envelopes own their required web/mobile screens, server commands and feature tests as they land. It does not create a second identity store, backend, permission model or shadow business rules. For shared CAP-12, this epic owns the final pastoral-overview composition of Services/Cells metrics with current separately authorized Care/Offerings sections; epic 12 retains counting definitions, observations and trend calculations.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Recorded web trial/selection, accessible design primitives and shared wire/contract fixtures before framework-dependent work.
- Epic 2 (epic-identity-and-scoped-access) supplies Same-account web/mobile authentication, current grant navigation and lifecycle/session invalidation contracts.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Durable staff inbox and generic refresh/deep-link contract.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Scoped rota/coverage/task APIs and accessible client integration points.
- Epic 5 (epic-cell-meetings-and-programmes) supplies Programme management/member projection and meeting navigation contract.
- Epic 6 (epic-public-content-and-giving) supplies Authorized content/publication administration contract.
- Epic 7 (epic-cell-attendance-and-private-reports) supplies Attendance/private-report operations and safe operational overview projection.
- Epic 8 (epic-safe-cell-recaps) supplies Recap draft/preview/publication operations and member-safe read projection.
- Epic 9 (epic-pastoral-visits) supplies Care board/list projection and consent-preserving transition commands.
- Epic 10 (epic-private-prayer-and-replies) supplies Prayer/reply entry points and anonymous-identity privacy fixtures.
- Epic 11 (epic-opt-in-member-directory) supplies Directory consent/search projection and current visibility fixtures.
- Epic 12 (epic-service-counts-and-trends) supplies Count capture/correction/missing queues and scope-safe metric projections.
- Epic 13 (epic-cell-offering-custody) supplies Restricted custody/summary/export interfaces and finance-grant fixtures.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-16
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Navigation and visual style; Staff web portal; Access and reliability requirements
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1, AD-2, AD-4, AD-5, AD-13, AD-16, AD-18, AD-20
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestones 1, 4, 5, 6; Q10, Q12
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Required first-release addition spanning M1-M6. M6 is completion and integration, not permission to defer every staff screen until the end.
- Constraint: Each listed dependency is the contract/projection needed for that integration slice; independent portal work proceeds before the corresponding whole feature is complete.
- Unknown: Q10 gates web selection/hosting and Q12 the supported device/browser/accessibility/performance acceptance matrix. No framework or hosting provider is selected by this envelope.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
