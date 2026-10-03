---
id: 7
type: "epic"
title: "Cell attendance, consented visitors and private reports"
parent: "initiative-church-app"
covers: ["CAP-8"]
after: []
risk: "high"
---

# Cell attendance, consented visitors and private reports

## Description

Extend the Cells meeting kernel with historical rosters, actual attendance, consented visitor relationships and private weekly reports, using the canonical follow-up and reminder services.

Milestone: 4.

## Outcome

Cell leaders can record what happened, follow up permitted needs and submit private reports without fabricating absences or exposing pastoral fields to general administration.

## Requirements

The requirement source is the parent spec, CAP-8, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Registers preserve the roster applicable to the meeting and Present/Absent/Excused/Unrecorded states with attributed corrections. Only three recorded consecutive held-meeting absences trigger the baseline flag; Present/Excused break the streak, cancelled meetings are skipped and missing attendance requires review.
2. Visitor capture records only agreed details/contact preference, supports name-only records and stops contact work after consent withdrawal. Reviewed invitation/linking supports phone/password or assisted accountless registration without automatic phone matching or bypassing church/cell approval.
3. Private weekly report submission keeps prayer/pastoral fields separate from operational metadata. Authorized pastoral review and scoped leader access work; Admin can route missing submissions without retrieving care content; report submission never publishes a recap.
4. Visitor/absence follow-up and missing-report work use the shared task registry, scoped context and source-specific deadlines/reminders. Completion, reassignment, cancellation and lifecycle changes remove obsolete work without treating a task outcome as attendance.
5. Web and essential mobile workflows pass permission, historical-roster, incomplete-data, correction and concurrency cases. The module exports scoped aggregate/coverage and actual-meeting records for later recaps and trends, with approved visitor and report support procedures.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Cells owns registers, visitors and report records. Programme recurrence and meeting identities are reused from the programme envelope; safe recap publication, prayer requests and negotiated visits remain separate owner workflows.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Stable accountless/member identity, cell/care grants, membership effective dates, safe contact provenance and lifecycle hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Source-specific report/task reminder and cancellation contracts.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Follow-ups owner APIs, source/purpose registration, restricted task context and authorized attributed owner actions.
- Epic 5 (epic-cell-meetings-and-programmes) supplies Canonical Cells meeting/occurrence IDs, meeting held/cancelled lifecycle and separate actual programme-leader records; not every programme screen.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-8
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Cell groups; Follow-up tasks; Service attendance and pastoral overview; Important edge cases
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-4, AD-5, AD-7, AD-8, AD-9, AD-12, AD-14
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 4; Q4, Q6, Q8
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q4 gates visitor/youth safeguards and live personal-data retention; Q6 names module operators. Operational schedules remain governed by approved configuration rather than invented values.
- Constraint: Follow-up flags, trend denominators and report completeness must use recorded meeting facts. Neither intention notices nor duty acceptance are attendance evidence.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
