---
id: 6
type: "epic"
title: "Public church content and giving instructions"
parent: "initiative-church-app"
covers: ["CAP-1", "CAP-2"]
after: []
risk: "high"
---

# Public church content and giving instructions

## Description

Deliver guest-accessible Bible/hymns, sermons, events, announcements and church-verified giving instructions, with authorized publication, content rights and bounded public caching.

Milestone: 3.

## Outcome

A visitor can find cleared teaching and event content or follow verified giving instructions without signing in or creating a payer record.

## Requirements

The requirement source is the parent spec, CAP-1, CAP-2, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. Guests can read cleared Bible/hymn text, search hymns, open sermons with available audio/notes and browse events/announcements. Hymn favourites, authorized Sunday lists, content import/edit, media background controls and unavailable-media states follow the baseline.
2. Authorized publishing validates media/rich-text input and rights metadata; public caching/downloads retain publication/rights revision and honest offline/withdrawal states. Private records remain outside those caches and public asset paths.
3. Events support the required calendar export, multi-day endpoints and optional RSVP/capacity behavior. Duty-linked event changes expose a leader-review mismatch; sermon topic/scripture drafts from teaching duties still require Media publication review.
4. How to give provides published numbered instructions, copyable verified details and supported dialler handoff with manual fallback. Admin-only draft/publish/archive and revision history retain the current published revision until replacement, without payment confirmation, payer identity or personal giving records.
5. Guest/member/staff permissions, publication changes, media failures, unsafe input and external handoff/return cases pass on the intended surfaces. Actual giving destinations and distribution rights are verified before publication, and media/giving support procedures are documented.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Content owns public publishing and instruction-only giving. Offerings remains a separate private aggregate custody domain; no public Content API may expose or collect donor, collection or payment-result data. This envelope does not add payments, reading plans or livestreaming.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Public API/asset/cache boundary, client navigation/design primitives and build/test scaffold.
- Epic 2 (epic-identity-and-scoped-access) supplies Current Media/Admin/worship publication grants and member-only favourite identity; public reading itself does not require sign-in.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Generic publication notification operations for optional announcement push; basic public reading can proceed independently.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Safe event-to-duty reference and owner-review mismatch contract, plus approved sermon-draft reference fields; not full duty UI completion.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-1, CAP-2
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Giving instructions; Bible and hymn book; Sermons; Events and announcements
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-2, AD-6, AD-13, AD-15, AD-16, AD-18
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 3; Q3, Q5; External lead times and operating constraints
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.

## Notes

- Unknown: Q3 gates actual giving details/publication and Q5 gates each intended content use, including offline distribution. No prototype beneficiary, Bible choice or assumed compilation license is production approval.
- Constraint: External giving handoff does not demonstrate a completed gift or guarantee store approval. Keep manual/unavailable states explicit.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
