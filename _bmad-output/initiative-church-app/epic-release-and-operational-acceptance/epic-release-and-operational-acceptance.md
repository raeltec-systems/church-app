---
id: 16
type: "epic"
title: "Full-v1 release and operational acceptance"
parent: "initiative-church-app"
covers: ["CAP-1", "CAP-2", "CAP-3", "CAP-4", "CAP-5", "CAP-6", "CAP-7", "CAP-8", "CAP-9", "CAP-10", "CAP-11", "CAP-12", "CAP-13", "CAP-14", "CAP-15", "CAP-16"]
after: []
risk: "high"
---

# Full-v1 release and operational acceptance

## Description

Assemble full-v1 evidence, run the staff beta and complete native/browser/accessibility, rights/privacy/store and operational acceptance, including database-plus-object restoration and church onboarding.

Milestone: 7.

## Outcome

Every required module and all six additions are ready for the November 2026 full-v1 target with named operators, exercised support procedures and evidence of safe recovery; optional chat changes only its own conditional acceptance scope.

## Requirements

The requirement source is the parent spec, CAP-1, CAP-2, CAP-3, CAP-4, CAP-5, CAP-6, CAP-7, CAP-8, CAP-9, CAP-10, CAP-11, CAP-12, CAP-13, CAP-14, CAP-15, CAP-16, read with every companion. The scope and Done when below define this epic’s contribution. Detailed implementation slices are completed at its inception; no new local requirement IDs are introduced.

## Done when

1. All 23 compound launch checks, detailed requirement edge cases and design checks are traced to passing feature/integration evidence, including accountless participation, current permissions, source revisions, idempotency/concurrency, denied push/app-closed behavior and full core operation with chat absent.
2. A staff beta exercises every required module and essential mobile/web workflow against the selected native-device/browser/accessibility matrix. Approved performance/availability/reminder tolerances are measured; real device/provider evidence supports push claims and outstanding failures are resolved or explicitly block release.
3. An isolated restoration demonstrates database and object-byte recovery, session invalidation, ordered replay of the independent deletion/revocation journal and access revalidation before private serving/sending resumes. The documented recovery objectives, operational alerts, secrets and environment separation are verified.
4. Named operators receive exercised membership/recovery, last-staff and care/custody handover, count/discrepancy, safe CSV, media, reminder, deletion and restore runbooks. Church onboarding/pilot feedback covers app and accountless members without substituting adoption targets for correctness.
5. Affected policy gates, real content rights/giving details, privacy/deletion disclosures, developer/store accounts and current store requirements are resolved before publication. If chat is selected, its separate moderation/safeguarding and feature evidence is added; otherwise it remains disabled without blocking the approved core.
6. The approved full-v1 mobile app and staff portal are published to production through the reviewed distribution paths, with the operational handover and church onboarding in use; unresolved required gates prevent release rather than becoming implied acceptance.

## Boundaries

Owns release evidence, cross-feature acceptance and operational handover, not late invention of domain rules or policy values. Reuses feature verification and investigates unresolved risks rather than replacing ongoing tests with a final test-only phase.

## Prerequisites

- Epic 1 (epic-platform-baseline) supplies Reproducible builds, CI/environment/backup topology and platform verification artifacts; release preparation may start from the contracts.
- Epic 2 (epic-identity-and-scoped-access) supplies Membership/recovery/access/lifecycle acceptance evidence, support procedures and the independent recovery journal contract.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Worker/inbox/device-provider evidence, operational health and reminder recovery procedures.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Duty/follow-up pilot and revision/concurrency/direct-contact evidence.
- Epic 5 (epic-cell-meetings-and-programmes) supplies Cell programme pilot and notice/response/actual-participation evidence.
- Epic 6 (epic-public-content-and-giving) supplies Verified publication rights/destinations, public-content behavior and external handoff evidence.
- Epic 7 (epic-cell-attendance-and-private-reports) supplies Cell register/visitor/report privacy and recorded-observation evidence.
- Epic 8 (epic-safe-cell-recaps) supplies Recap publication/consent/audience/withdrawal evidence.
- Epic 9 (epic-pastoral-visits) supplies Visit negotiation/direct-consent/continuing-care evidence and operator procedure.
- Epic 10 (epic-private-prayer-and-replies) supplies Prayer/reply and anonymous-author access evidence.
- Epic 11 (epic-opt-in-member-directory) supplies Directory consent/hidden-field/youth-gate evidence.
- Epic 12 (epic-service-counts-and-trends) supplies Approved count-definition, correction/missing-data/trend evidence and recorder procedure.
- Epic 13 (epic-cell-offering-custody) supplies Approved custody/independence/correction/export evidence and finance handover/retention procedure.
- Epic 14 (epic-staff-portal-and-mobile-continuity) supplies Completed required staff/mobile continuity evidence across shared contracts and supported browser/native surfaces.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, Constraints; Success signal; CAP-1 through CAP-17
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Important edge cases; Risks and release checks; Milestones and acceptance criteria
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-13, AD-14, AD-15, AD-17, AD-18, AD-19, AD-20; Deferred
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Delivery commitment; Decision register; Success evidence; External lead times and operating constraints
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md

## Notes

- Constraint: All seven milestones remain stages within one full-v1 commitment by November 2026. None of the six additions is moved to later scope.
- Constraint: CAP-17 is included in release acceptance only if enabled; there is deliberately no unconditional dependency on epic 15.
- Unknown: Q1-Q10 and Q12 close only where their affected activation/release requires it. Q11 resolves target/baseline claims; no numerical success threshold, RPO/RTO, uptime, latency or supported-version floor is invented.
- Constraint: Planning, architecture or document reviews do not establish application/provider/store approval. Production publication and paid/provider selections require the relevant concrete authorization, separate from this envelope.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Assumption: This is a future epic envelope; run bmad-ticket inception before building it, preserving its ID, scope, dependencies and production verification.
