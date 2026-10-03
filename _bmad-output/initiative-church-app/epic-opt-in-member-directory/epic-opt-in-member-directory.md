---
id: 11
type: "epic"
title: "Opt-in member directory and safe contact fields"
parent: "initiative-church-app"
covers: ["CAP-15"]
after: []
risk: "high"
---

# Opt-in member directory and safe contact fields

## Description

Implement Directory-owned opted-in projections and field-level publication choices, distinct from restricted operational member contacts and account credentials.

Milestone: 4.

## Outcome

Approved members can discover only the contact fields a person chose to share, while hidden records, youth restrictions and assisted consent remain enforceable at API/search level.

## Requirements

The requirement source is the parent spec, CAP-15, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Directory entries are hidden by default. Members choose visible photo, phone, email and birthday day/month fields, with current consent provenance and reversible publication; credentials/recovery email are not automatically directory contact fields.
2. Name search and call/WhatsApp/email actions operate only on authorized opted-in projections. Guests, pending users and other members cannot retrieve hidden fields through alternate API/search/count paths.
3. Authorized assisted opt-in records the accountless person's explicit choices and actor provenance. Shared household or relative contact routes never become visible or confer login/access automatically; youth/contact capabilities remain disabled until their policy is approved.
4. Consent withdrawal, membership deactivation/deletion and scope changes update projections and clear affected client state. Tests distinguish directory publication from necessary scoped leader contacts and preserve the baseline's private care/administration limits.
5. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Directory owns only the opted-in member-facing projection. Identity owns member/account/contact records; duty/cell/care staff obtain necessary operational contacts through their own restricted contracts, not by forcing directory opt-in.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Approved member identity, separate contact and credential fields, explicit consent/assisted-attribution primitives, current access and lifecycle events.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-15
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Member directory; Members without a usable personal account; Roles and permissions
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-3, AD-4, AD-5, AD-13, AD-14, AD-15
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 4; Q4
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q4 gates youth/contact safeguards, visibility limits and retention. No birth year, broad relative-contact visibility or consent default is invented.
- Constraint: No dependence on Care, Prayer or Chat implementation is necessary; all use Identity's appropriate source-specific contact/grant contract.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
