---
id: 1
type: "epic"
title: "A runnable, testable platform with proven authentication mechanisms"
parent: "initiative-church-app"
covers: []
after: []
risk: "high"
---

# A runnable, testable platform with proven authentication mechanisms

## Description

Establish the shared Flutter/Supabase build substrate, prove the provider-dependent phone/password and no-SMS recovery mechanisms against a real isolated provider, select the staff web framework through its required trial, and make subsequent feature work consume one tested API, deployment and operations contract.

Milestone: 1 — platform foundation; identity/access completes milestone 1.

## Outcome

Israel can run the mobile and trial staff clients against the same synthetic backend, inspect the evidence for the risky authentication assumptions, and build the identity/access milestone on reproducible contracts and environments.

## Requirements

- **P1** — Run a thin actual Flutter mobile and trial-web path through the same explicit Supabase API and database, using official scaffolding, locked tool versions and synthetic data. Source: architecture-church-app.md AD-1, AD-16, Stack and Structural Seed; spec delivery-and-decisions.md milestone 1.
- **P2** — Prove native phone/password with optional same-account verified email and no SMS, signed password AMR, live-session enforcement, denial of private-data access from sessions without trusted password authentication and session revocation against the deployed provider before private-data implementation relies on them. Source: architecture-church-app.md AD-3 and AD-20; acceptance-map.md Auth verification detail; functional-requirements.md Sign-in and continued access.
- **P3** — Prove trusted direct credential-change detection, recovery generations, one-use setup grants and serialized/fenced external Auth reset handling without claiming cross-system atomicity or showing staff passwords. Source: architecture-church-app.md AD-20; functional-requirements.md Changed credentials and secure recovery; acceptance-map.md Auth verification detail.
- **P4** — Make the explicit API, owner schema, current-actor authorization seam, versioned command envelope, revisions, receipts, lock ordering, safe errors and transaction boundaries reusable before feature consumers. Source: architecture-church-app.md AD-1, AD-2 and Consistency Conventions.
- **P5** — Land shared identity/source/purpose/time/money/lifecycle wire contracts and both-client fixtures, with owner interfaces and intentional contract stubs, without moving feature business rules into the contracts package. Source: architecture-church-app.md AD-1, AD-6 through AD-9, AD-14, AD-18 and Consistency Conventions.
- **P6** — Resolve the staff web framework using the foundation keyboard, screen-reader, grid/list, CSV and supported-browser trial, then provide accessible shared client primitives and recoverable request states. Source: architecture-church-app.md AD-16; spec design-contract.md Tokens, type and geometry; delivery-and-decisions.md Q10 and Q12.
- **P7** — Separate local, staging and production configuration and synthetic recipients, run required contract/permission/concurrency checks in CI, and promote reviewed compatible migrations and immutable client builds without exposed secrets. Source: architecture-church-app.md AD-17 and AD-18; delivery-and-decisions.md Delivery commitment.
- **P8** — Provide bounded environment-bound system principals, content-free operational signals, restricted operator procedures and fail-closed policy activation controls. Source: architecture-church-app.md AD-9, AD-17, AD-19 and Deferred; delivery-and-decisions.md Q1, Q2, Q4, Q10 and Q12.
- **P9** — Provide an independent restricted recovery journal and an isolated synthetic database-plus-object restore rehearsal that keeps private access and sending disabled until revocation/deletion journal reconciliation succeeds. Source: architecture-church-app.md AD-14 and AD-17; spec delivery-and-decisions.md Q4 and Q12.
- **P10** — Close the platform with evidence-led cleanup and an integrated suite covering its real shared interfaces; feature and production-policy acceptance remain owned by the relevant later epics. Source: architecture-church-app.md AD-18; bmad-ticket workflow.ordering.

## Done when

1. An owner runs Flutter on a native target and the trial or selected staff web client, and both show the same actual API/database value with honest network-error and retry states.
2. Saved provider evidence proves phone/password without SMS, verified-email recovery isolation, trusted session checks and the assisted-reset generation/fencing mechanism against the selected Auth version; a failed assumption blocks closure until a reviewed architecture correction preserves the approved flow and its replacement passes the same evidence checks.
3. The selected staff framework passes the agreed accessible grid/list, keyboard, screen-reader and CSV browser trial, and both clients pass the shared wire fixtures.
4. CI builds and checks the platform from a clean checkout, promotes compatible migrations and immutable client artifacts through isolated staging to an owner-approved production baseline with private features and sending disabled, and demonstrates environment/secret separation and a bounded system endpoint.
5. An isolated synthetic database-plus-file restore replays independent revocation/deletion journal entries before enabling serving or sending, and an incomplete journal leaves access disabled.
6. The closing integrated suite passes after the refactor sweep; no real-member onboarding, complete recovery workflow, role matrix or source milestone-1 completion is claimed by this epic.

## Boundaries

Platform ownership boundary: shared Flutter/Supabase substrate, provider feasibility, client framework, contracts and operations; the next identity/access epic owns production membership and access workflows and completes milestone 1.

## Prerequisites

No earlier epic is required; the opening stories establish the substrate for the rest of the initiative.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, Constraints and CAP-3/CAP-4/CAP-16
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Auth and membership; Staff web portal; Important edge cases
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1 through AD-5, AD-13, AD-14, AD-16 through AD-20, Consistency Conventions, Stack, Structural Seed, Deferred
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, shared visual/accessibility and request-state obligations
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, milestone 1, Q1/Q2/Q4/Q10/Q12
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, Auth verification detail and Verification boundaries

## Notes

- Decision: 2026-10-03 — The user selected Split: platform and identity/access are separate epics within milestone 1; only platform is incepted now.
- Sequencing: Entries 2 and 3 immediately follow the tracer because deployed Auth behavior and external-reset fencing are the least certain and highest-risk mechanisms.
- Human gates: Entry 1 needs the first actual isolated Supabase project/access; entry 2 needs test inboxes/allowed redirects and captures actual provider versions; entry 6 needs a provisional test matrix and owner framework decision; entry 8 needs approved environment/hosting access for affected deployment; entry 10 needs an independent journal/object-backup location and restricted operator selection.
- Unresolved Q1/Q2/Q4/Q10/Q12 values block only their affected activation; synthetic scaffolding, contracts and negative tests continue independently, with production features fail-closed and fixture values clearly labelled.
- External high-risk checks: Israel reviews the actual-provider evidence from entries 2 and 3 before it is accepted as the identity epic's prerequisite; an independent security review checks the direct-Auth and reset-race cases; entry 12 independently reruns schema/API/environment/principal/journal checks for entries 1 through 5 and 8 through 10 before platform closure.
- Parallelism: After entry 1, the Auth feasibility lane (2 then 3), backend lane (4 then 5) and web trial lane (6) can progress independently only while respecting their listed file ownership; entry 7 joins contract and web outputs, entry 9 joins backend and environment outputs, and entry 10 joins contracts and system operations.
- Lane ownership: Auth experiments live under an isolated provider-evidence harness; backend work owns migrations/contracts; the web trial owns its disposable trial app; environment work owns CI/deployment; after selection, client-shell work owns application/design-system code; no parallel entry edits another lane's files.
- Refactor sweep scope comes only from build records and deferred review findings; missing source behavior must become a new implementation entry and cannot be hidden in cleanup.
- No spike is introduced implicitly: entries 2, 3 and 6 are stories whose delivered artifacts are runnable provider/trial harnesses plus recorded decisions, not unimplemented production behavior.
- Assumption: The opening epic delivers a production platform baseline only after its owner setup gates pass, with private features and sending disabled; isolated staging preparation does not count as that production delivery.
- Lane boundary: Provider experiments use a dedicated isolated Auth test project and harness; backend and CI work use the separate platform project, so direct credential/configuration tests cannot mutate a concurrent lane’s environment.
- External lead times: Begin tracking Apple/Google developer access and available iOS signing/hardware during entry 1; release submissions remain epic-release-and-operational-acceptance work, and emulator-only evidence does not satisfy native distribution gates.
- Constraint: Native verification and recovery endpoints may remain reachable; only trusted password sessions can pass the private-data gate, and a same-account verified-email/password alias obeys the same binding, membership, hold and scope checks.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
