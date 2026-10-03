---
type: initiative
title: "BIC Kafue Church App v1"
parent: none
covers: [CAP-1, CAP-2, CAP-3, CAP-4, CAP-5, CAP-6, CAP-7, CAP-8, CAP-9, CAP-10, CAP-11, CAP-12, CAP-13, CAP-14, CAP-15, CAP-16, CAP-17]
after: []
risk: high
---

# BIC Kafue Church App v1

## Description

Deliver the church-owned mobile app and staff portal defined by the current spec and its companions. Members see and respond to their duties; leaders coordinate coverage and follow-up alongside public content, cell life, care and reporting. All six approved additions remain in v1 across all seven milestones, targeting November 2026. Chat alone is conditional.

## Outcome

The full publish, remind, respond and follow-up loop helps leaders identify gaps before Sunday while preserving church identity, consent and restricted records, including participation by members without an account; measure the spec's success signal without treating provisional numerical targets as approved.

## Requirements

The numbered source is `_bmad-output/initiative-church-app/spec-church-app/spec-church-app.md`, CAP-1 through CAP-17, read with every companion. Its current `functional-requirements.md` supplies the complete domain rules and edge cases; original spec 1.2 is audit-only. The ownership map below assigns accountability, while each feature also applies CAP-4 permissions and CAP-16 cross-client rules to its own records and actions.

| Source | Accountable delivery |
| --- | --- |
| CAP-1 | 6. Public church content and giving instructions |
| CAP-2 | 6. Public church content and giving instructions |
| CAP-3 | 2. Membership, recovery and scoped access |
| CAP-4 | 2. Membership, recovery and scoped access |
| CAP-5 | 4. Assigned duties, coverage and accountable follow-up |
| CAP-6 | 4. Assigned duties, coverage and accountable follow-up |
| CAP-7 | 3. Durable inbox and reliable reminders |
| CAP-8 | 7. Cell attendance, consented visitors and private reports |
| CAP-9 | 5. Cell meetings and revisioned programmes |
| CAP-10 | 8. Separately published member-safe recaps |
| CAP-11 | 9. Agreed pastoral visits and continuing care |
| CAP-12 | 12. Scoped service counts and honest participation trends; 14. Staff portal completion and mobile continuity |
| CAP-13 | 13. Aggregate cell-offering custody and safe export |
| CAP-14 | 10. Private prayer requests and pastoral replies |
| CAP-15 | 11. Opt-in member directory and safe contact fields |
| CAP-16 | 2. Membership, recovery and scoped access; 14. Staff portal completion and mobile continuity |
| CAP-17 | 15. Conditional moderated group chat |

## Done when

1. Every required capability is available in production through its specified mobile and staff surfaces, including programmes, recaps, visits, service counts, staff web and cell offerings; CAP-17 is included only if Q6 selects it and its own gates pass.
2. The department/cell pilot demonstrates explicit current-revision responses, visible gaps, durable inbox/reminders and attributed direct contact for an accountless member, with no invented delivery, consent, attendance or financial receipt.
3. All 23 compound launch checks and the detailed source edge cases pass against the supported native-device/browser matrix, including current scope/hold enforcement, no-SMS auth/recovery, privacy, concurrency and cross-client consistency.
4. Operational owners approve the affected Q1–Q12 gates, content rights, verified giving destinations, privacy/retention, store submissions and onboarding; approved metrics have a recorded baseline before success claims.
5. An isolated database-plus-object restore replays the independent deletion/revocation journal and cannot reopen revoked access or restore deleted personal data; operators can run the documented recovery, handover and support procedures.
6. The full staff beta and church onboarding complete with the source's accessibility and failure states, and core workflows pass with chat disabled.

## Boundaries

One Flutter mobile app, one staff portal chosen through the Q10 trial, and one authoritative Supabase backend per environment. The spec's non-goals remain binding: public giving provides instructions only, and the separate cell offering register records aggregate custody without donors or payment processing. Every feature epic delivers its own web and essential mobile actions; staff completion does not postpone those actions to milestone 6.

The first demo is a synthetic mobile/trial-web/API/database path. The first operational tracer continues through reviewed membership, one department duty and cell programme part, durable reminders, an explicit response and a current follow-up queue.

- Touch point: Flutter/Dart and native packaging — scaffold, reproducible toolchain and support-matrix trial; owner: epic-platform-baseline.
- Touch point: Supabase Auth, PostgreSQL, Storage, Realtime, Cron and Edge services — environment/command/security foundations owned by epic-platform-baseline, production membership/recovery by epic-identity-and-scoped-access, notification execution by epic-durable-inbox-and-reminders, and feature records by their owning epics.
- Touch point: Firebase/FCM and APNs — test-recipient setup, device registrations, delivery attempts and revocation; owner: epic-durable-inbox-and-reminders.
- Touch point: Transactional email and reset/deep-link redirects — optional same-account email verification/recovery and operational sender setup; owner: epic-identity-and-scoped-access.
- Touch point: Public media, YouTube, Bible/hymn sources, calendars and external giving destinations — publishing, licensing, safe handoffs and unavailable states; owner: epic-public-content-and-giving.
- Touch point: Existing design handoff — shared semantic tokens and accessible shells owned by epic-platform-baseline; each feature owns its specified screens and state corrections.
- Touch point: Hosting/domain, CI, secrets, database/object backup and independent recovery-journal storage — platform setup owned by epic-platform-baseline, production deletion behavior by epic-identity-and-scoped-access, and full release restore evidence by epic-release-and-operational-acceptance.
- Touch point: Apple/Google distribution and church onboarding — external lead times tracked from foundation; submission, review and operational release owned by epic-release-and-operational-acceptance.

## Shared contracts and handoffs

Architecture AD-1–AD-20 is the single home for decisions binding multiple epics. Platform publishes reviewed ownership, schema and versioned command/result/error fixtures, source/purpose/event contracts and test harnesses before consumers implement them. Identity owns account/member links, grants and recovery authority; Cells owns primary membership and then canonical meeting IDs, which Programmes delivers before attendance/reports and Offerings extend them. Duties never creates a second cell calendar. Notifications owns job/inbox runtime; Duties and follow-up owns the one task registry. Each domain registers its source purposes, notification effects and lifecycle/deletion handlers against those contracts.

Entries added at each later inception must pin the exact provider entry for their declared prerequisites. An initiative dependency states the required output; it does not silently gate the whole epic on unrelated provider work. Shared route/schema/contract changes must be sequenced where concurrent lanes would collide. Future envelopes are not execution-ready story sets.

## References

- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, Capabilities, Constraints, Non-goals and Success signal; read every companion.
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, complete baseline and launch checks.
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1–AD-20, shared contracts and Deferred.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, all seven milestones and Q1–Q12.
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, mobile/staff screens and prototype overrides.
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, AC-01–AC-23 and verification boundaries.

## Notes

- Decision: 2026-10-03 — the approved authentication route is phone number plus password, optional verified same-account recovery email, identity-checked recovery without email, and no SMS; ticketing does not reopen that decision.
- Assumption: Store tickets as local repository files using the BMad repo starter because no tracker is configured; this run writes reviewable files without publishing a commit or starting implementation.
- Decision: 2026-10-03 — the user selected a split of milestone 1 into platform foundations with a synthetic auth feasibility pilot, then production identity/access; both are required before dependent private feature activation. This preserves the milestone rather than moving auth scope out of it.
- Assumption: Only the opening platform epic is incepted in this run; later epics retain complete outcome envelopes and are sliced when selected.
- Unknown: Q1–Q12 and provider/operating choices remain owned by the current decision register; each epic lists its affected gate. Synthetic preparation can proceed where the unresolved choice cannot change its result; no live policy value is inferred.
- Open question: Chat selection and safeguarding remain Q6; core and release work have no prerequisite on the disabled chat epic, while an enabled chat release must include its full verification.
- Risk: High because authentication, private data, lifecycle deletion and finance custody cross client/backend boundaries; an independent permission/security review and the release acceptance suite are required beyond each story's own checks.
- Assumption: No point estimates or finish dates are invented; BMad estimation is off and November 2026 remains the source target, not a capacity forecast from ticket counts.
