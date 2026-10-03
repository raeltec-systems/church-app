---
id: 10
type: "epic"
title: "Private prayer requests and pastoral replies"
parent: "initiative-church-app"
covers: ["CAP-14"]
after: []
risk: "high"
---

# Private prayer requests and pastoral replies

## Description

Deliver Prayer-owned named/team-anonymous requests, a separately restricted author mapping and private replies without disclosing anonymous identity through general pastoral, task or notification access.

Milestone: 4.

## Outcome

Members can choose the stated request visibility, maintain their own requests and receive private pastoral replies while the prayer team cannot retrieve a team-anonymous author's identity link.

## Requirements

The requirement source is the parent spec, CAP-14, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Submission explains Named and Anonymous to the prayer team accurately, including the designated lead pastor's identity access and the possibility that text identifies its author. Members can view, edit and close their own requests.
2. Request text and author mapping have separate server grants. Only the author and designated lead pastor resolve a team-anonymous identity; Admin-only, general prayer-team and unrelated care assignments cannot retrieve it through API, search, audit, exports or source links.
3. Authorized pastors can mark Prayed for and issue private author-visible replies through server-side identity resolution that does not return the recipient link to other pastors. Generic inbox notifications and current authorized reads preserve that boundary.
4. Archival, deletion and scope-loss behavior follow approved retention configuration on both clients. Permission, replay/current-access and lifecycle tests include anonymous reply routing and core operation with chat disabled.
5. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Prayer owns requests, replies and the restricted author map. It does not create broadly visible follow-up tasks or reveal identity through Care referrals; any deliberate member request for a visit follows the separate stated consent/visibility workflow.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Stable author/member links, designated lead-pastor versus prayer-team grants, live access and deletion hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Generic private reply inbox adapter and recipient resolution boundary without identity-bearing payloads.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-14
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Prayer requests; Follow-up tasks; Pastoral visits
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-3, AD-4, AD-5, AD-13, AD-14, AD-15
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 4; Q4
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q4 gates the lead-pastor designation, retention and live sensitive-data handling. The source's archival timing is retained as supplied policy input, not independently approved here.
- Constraint: No dependency on the completed Care epic is needed; the non-disclosure/referral boundary belongs in shared fixtures before either consumer exposes it.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
