---
id: 2
type: "epic"
title: "Membership, recovery and scoped access"
parent: "initiative-church-app"
covers: ["CAP-3", "CAP-4", "CAP-16"]
after: []
risk: "high"
---

# Membership, recovery and scoped access

## Description

Deliver the member and account lifecycle on the platform's proven authentication substrate, including accountless participation, separate church and cell approval, current grants and restricted recovery. Establish the Identity and Cells membership owner operations needed by later modules.

Milestone: 1.

## Outcome

A person retains one stable church identity through registration, linking, sign-in, recovery and access changes, while both clients enforce current authority independently of menu visibility or cached credentials.

## Requirements

The requirement source is the parent spec, CAP-3, CAP-4, CAP-16, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Members can register and sign in with a normalized phone username and password without SMS, leave email blank, request a cell or select the supported undecided choices, and see church approval separately from confirmed primary-cell membership. Assisted registration and reviewed later account linking preserve accountless members' history without shared credentials or phone-based merges.
2. Same-account verified and approved email recovery and identity-checked no-email assistance preserve account/member links and holds. Assisted grants use the Identity-owned generation, single-use consumption and serialized external-operation fencing; direct Auth credential changes, uncertain results, replay and stale links cannot restore private access. Both routes require fresh password sign-in after reset and enforce obsolete-session denial.
3. The shared server access predicate and explicit grants protect every implemented read, mutation and file surface, including Guest/Pending, combined-role, Admin-without-care-or-finance, restricted recovery-session and stale-session cases. Role/account/cell changes are checked against current records on mobile and the selected staff client.
4. Cells-owned primary membership and safe signup projections support approval and atomic transfer. Lifecycle orchestration immediately denies affected access, records handover obligations and exposes reviewed owner hooks for future duties, tasks, custody and private content without fabricating those future workflows.
5. Login hold, church deactivation and full deletion have distinct effects. Resumable deletion, last-Admin/last-responsible-staff recovery and the independent restricted recovery journal are exercised with synthetic records; the support runbook never discloses passwords or grants Admin private care/finance access.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Owns Identity records and commands, account lifecycle orchestration, and the minimal Cells-owned membership contract. Uses the platform's scaffold and authentication feasibility evidence; does not duplicate Supabase's password store or implement later domain workflows. Later owners add their required handover/deletion hooks before activation.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Versioned command/read/access fixtures, module ownership and test scaffold, synthetic proof of the selected Supabase no-SMS password/session mechanism, and the staff trial result before framework-dependent screens.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-3, CAP-4, CAP-16
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Roles and permissions; Auth and membership; Access and reliability requirements; Important edge cases
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1, AD-2, AD-3, AD-4, AD-13, AD-14, AD-17, AD-18, AD-19, AD-20
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 1; Q1, Q4, Q10, Q12
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q1 still gates operational recovery owners, password/abuse/dormancy controls, production email setup and the assisted procedure; email setup gates email recovery rather than password login without email.
- Unknown: Q4 gates live personal data, youth/contact features and retention/deletion/backup policy. Q10 gates framework-dependent staff work; independent contracts and synthetic tests may proceed.
- Constraint: The stable person, acting account, contact routes and approved credential binding are distinct. Security denial is immediate even when handover or an external Auth operation is unresolved.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
