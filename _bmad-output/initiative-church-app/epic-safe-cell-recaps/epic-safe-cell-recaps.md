---
id: 8
type: "epic"
title: "Separately published member-safe recaps"
parent: "initiative-church-app"
covers: ["CAP-10"]
after: []
risk: "high"
---

# Separately published member-safe recaps

## Description

Create the separate Cells recap publication workflow and safe member projection, with consent-aware testimony, current audience checks and correction/withdrawal history.

Milestone: 4.

## Outcome

Current permitted cell members can read an accurate, safe account of completed meetings while private reports and pastoral records retain their own restricted audience.

## Requirements

The requirement source is the parent spec, CAP-10, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Scoped leaders can draft, preview, publish, correct and withdraw a dedicated recap containing safe meeting/topic/scripture, summary, ordered key points and optional aggregate attendance/actual leaders, with publisher, revision and time.
2. Report submission never publishes a recap. API/projection tests exclude private reports, pastoral/prayer fields, visitor contacts, named absence lists and unapproved testimony; an edited testimony requires permission appropriate to the actual audience or is omitted.
3. Current cell membership and the approved archive rule gate all reads/search/deep links. Transfer/removal/withdrawal ends server access; private recap/venue records are not persistently cached and client memory clears when loss of access is observed.
4. Staff and mobile publication/member-reading flows preserve pending/error/conflict states and actual-versus-planned leaders. Correction/removal and retention procedures are available, and the workflow passes with chat absent.
5. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Owns Cells recap records and publication history only. Consumes safe actual-meeting/leader/aggregate facts; it is never a raw private report view, a report-submit side effect or a public historic home-address feed.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Current cell audience, source-specific publication grants, lifecycle invalidation and no-private-cache client contract.
- Epic 5 (epic-cell-meetings-and-programmes) supplies Canonical meeting references and attributed actual programme-leader/substitution projection.
- Epic 7 (epic-cell-attendance-and-private-reports) supplies Separate report-versus-recap storage boundary and scoped aggregate attendance/held-meeting read contract; full visitor/report UI completion is unnecessary.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-10
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Member-visible recaps; Meeting programmes
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-4, AD-5, AD-12, AD-13, AD-14, AD-15
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 4; Q4, Q7
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Required first-release addition. Q7 decides testimony consent and recap archive access before pilot; Q4 governs retention and personal-data safeguards.
- Constraint: The proposed current-member archive rule is not silently promoted to approved policy. An already-offline displayed screen cannot be remotely erased.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
