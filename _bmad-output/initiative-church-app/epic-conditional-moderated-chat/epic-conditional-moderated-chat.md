---
id: 15
type: "epic"
title: "Conditional moderated group chat"
parent: "initiative-church-app"
covers: ["CAP-17"]
after: []
risk: "high"
---

# Conditional moderated group chat

## Description

If selected for launch, add Chat-owned authorized group communication and moderation on the existing identity, notification and private-file boundaries, with no dependency from core workflows.

Milestone: 6.

## Outcome

Eligible members can communicate in their current permitted groups under the church's approved moderation/safeguarding process, while all core capabilities work with chat disabled or absent.

## Requirements

The requirement source is the parent spec, CAP-17, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Admin/scoped group-leader operations admit only approved active-account members; cell groups additionally require current confirmed cell membership. Removal/transfer/revocation ends server history access and never changes an unrelated duty or care grant.
2. Text, compressed images within the baseline limits, reactions, replies and per-user read state use authorized reads and generic receive-only refresh signals. Private image ownership/access routes and lifecycle deletion prevent reusable unrestricted private links.
3. Group mutes, member reports, immediate reporter hiding, scoped moderation, read-only mute, blocking and removal follow the baseline. Blocking/muting chat does not suppress official duties or their responses/reminders.
4. Current-scope, stale-session, file, moderation and account-deletion tests pass on enabled clients. Policy/configuration keeps chat off until selected and ready, and the full required core suite passes with chat absent.
5. If the owner selects chat, its approved workflows are deployed to production with moderation, safeguarding and integrated permission/file checks; otherwise it stays explicitly disabled and is not counted as delivered or required for core release.

## Boundaries

Chat owns optional group membership, messages, read/reaction/report/block state and attachment references. Cells owns primary membership; Identity owns account eligibility. No direct member-to-member messaging, core workflow dependency or alternative delivery authority is introduced.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Current active-account/group grants, confirmed-cell membership and transfer/deletion/lifecycle hooks.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Separate chat notification category/group mute, generic refresh signaling and authorized private-link delivery contract.
- Epic 1 (epic-platform-baseline) supplies Authenticated private-file access, object ownership and deletion contract plus client test scaffold.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-17; Non-goals
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Group chat; Cell groups; Important edge cases
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-4, AD-5, AD-8, AD-13, AD-14, AD-15, AD-19
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 6; Q4, Q6
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Constraint: Conditional only: Q6 must select launch inclusion and named moderation readiness. Q4 youth/contact/privacy/deletion safeguards gate affected chat activation.
- Constraint: Core programmes, recaps, visits, prayer, directory, counts and offerings must not import Chat records or depend on chat delivery. This epic is not a required predecessor of Release.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
