---
id: 13
type: "epic"
title: "Aggregate cell-offering custody and safe export"
parent: "initiative-church-app"
covers: ["CAP-13"]
after: []
risk: "high"
---

# Aggregate cell-offering custody and safe export

## Description

Implement the Offerings-owned aggregate collection ledger with independent count/receipt attribution, exact amounts, correction/discrepancy workflows and scoped reporting/export.

Milestone: 5.

## Outcome

Authorized cell and finance staff can account for actual counted, handed-over, received and outstanding amounts without self-receipt, erased discrepancies or donor accounting.

## Requirements

The requirement source is the parent spec, CAP-13, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. One collection per meeting/currency distinguishes Missing, Draft, No collection, explicit zero, cancelled meeting and the custody workflow. Exact decimal amount/scale validation and two distinct counter member identities govern attestations, including attributed in-person attestations for accountless counters.
2. Custodians record handover facts and an eligible authorized Treasurer/deputy separately records actual receipt. Receiver independence is checked against both counters and custodian as people, regardless of account or combined roles; lack of an eligible receiver leaves pending accountable work.
3. Partial, excess, disputed and mismatched custody preserves separate facts, owned discrepancies and append-only amendments. Count correction renews both attestations; receipt correction requires an independent authorized reviewer. Aggregate locks/revisions/idempotency prevent duplicate effects and totals exclude superseded/voided facts correctly.
4. Scoped cell/finance summaries label amount basis and currency; permitted CSV previews scope/columns, neutralizes formula text, excludes donor/care/unrelated contacts and records export audit. Admin routing, ordinary members and public Give cannot retrieve finance content.
5. Web and essential mobile count/handover/receipt work pass permission, concurrency, correction, independence, partial-custody and lifecycle/handover tests. Shared tasks/reminders expose generic operational context, and authorized real-procedure pilots/runbooks cover discrepancies, safe CSV and approved retention.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Offerings alone owns collection/attestation/custody/discrepancy/correction records and restricted finance audit. Cells supplies the canonical meeting reference; Identity supplies stable persons and grants. This does not add payment processing, donor allocations, bank reconciliation or general accounting.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Stable member/account distinction, explicit counter/custodian/finance scopes, staff handover and approved retention/lifecycle hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Generic source-linked custody/discrepancy reminder and cancellation operations.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Follow-ups owner APIs for accountable outstanding-custody/discrepancy work with separate restricted finance context.
- Epic 5 (epic-cell-meetings-and-programmes) supplies Canonical cell meeting ID, owning-cell authority and meeting cancellation contract; attendance/report completion is not a prerequisite.
- Epic 1 (epic-platform-baseline) supplies Exact wire-money convention, restricted export/API test substrate and selected web framework's accessible CSV/grid capability.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-13
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Cell offerings; Visit and operational reminders; Staff web portal
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1, AD-2, AD-4, AD-7, AD-8, AD-9, AD-11, AD-12, AD-14, AD-15
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 5; Q4, Q9
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Required first-release addition. Q9 gates actual currency/scale, custody procedure, independent Treasurer/deputy, export grants, deadlines and retention; the proposed ZMW value is not selected here.
- Unknown: Q4/Q9 restoration and retention treatment must preserve permitted non-personal facts without a hidden identity map. Downloaded CSV is outside live app access controls; the agreed storage procedure is part of the workflow.
- Constraint: No dependency on Public Give or the completed Services epic: finance remains isolated, while a later overview composes only a current finance-authorized summary.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
