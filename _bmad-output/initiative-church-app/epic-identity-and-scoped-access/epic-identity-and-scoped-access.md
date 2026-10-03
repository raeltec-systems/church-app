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

The requirement source is the parent spec, CAP-3, CAP-4, CAP-16, read with every companion. The local ids below hold this epic's contribution; each maps to the parent capability shown, and the spec, its companions and the architecture stay authoritative for detail.

- **I1** (CAP-3, CAP-4) — Identity owns stable member records, account links with a versioned approved phone/recovery-email binding, holds and activity, and one server live-access predicate that every protected read, command, subscription and file route uses: password AMR, a live Auth session, the approved link, the current binding, holds, dormancy evaluated before activity refresh, and current grants. Source: architecture AD-1, AD-3, AD-4, AD-20; functional-requirements.md Separate the person from the account, Core data model, Access and reliability requirements.
- **I2** (CAP-3, CAP-16) — Members create an account and sign in with a normalized unique unverified phone username and a password on mobile and the selected staff client, without SMS. Failures are generic, sessions persist, returning and new-device sign-in needs no reapproval, and protected state clears on sign-out or account change. Source: functional-requirements.md Joining from the app step 1, Sign-in and continued access; design-contract.md Phone signup and sign-in; AD-13, AD-20; AC-01, AC-04.
- **I3** (CAP-3, CAP-4) — An applicant submits a correctable membership application with name, privacy notice and a safe cell choice (a cell, I'm not sure, I'm not in a cell yet), and sees church approval separately from cell status. A pending account reaches only its own application status and public content. Source: functional-requirements.md Joining from the app steps 2–3, Membership and account lifecycle (Pending/rejected); design-contract.md Home Pending card, Profile; AC-01, AC-02.
- **I4** (CAP-3) — Admin approves, rejects or asks for details after an identity check, reviews duplicate candidates and explicitly links an account to an existing member record. Admin creates consented accountless member records, and a later account link preserves member ID and history. Matching phone, email or name never links, merges or discloses a record. Source: functional-requirements.md Joining from the app step 4, Members without a usable personal account; design-contract.md Admin overview/members; AC-03, AC-05.
- **I5** (CAP-3, CAP-4) — Cells owns cell records, the safe signup projection and zero or one confirmed primary cell per member. Leader or Admin confirmation is separate from church approval, unresolved choices reach an Admin follow-up queue, and a confirmed transfer atomically ends old-cell access and calls registered owner transfer hooks. Source: functional-requirements.md Joining from the app step 5 and cell paragraphs, Core data model (Cell choice and confirmation); AD-1, AD-14; AC-02.
- **I6** (CAP-4, CAP-16) — Admin grants and revokes explicit, independently held roles and scopes with audit and immediate effect. Admin gains no care or finance content. Navigation on both clients follows current server grants and is never the security control. Identity-owned church settings stay unset and fail closed until approved. Source: functional-requirements.md Roles and permissions, Staff web portal; AD-4, AD-9; AC-13, AC-22, AC-23.
- **I7** (CAP-3) — A member adds an optional recovery email to the same account, verifies it and has the binding approved. Forgot password returns a neutral result and resets only to that email through allowlisted redirects. The recovery session reaches only recovery actions, a fresh password sign-in is required, and holds stay in force. Source: functional-requirements.md Changed credentials and secure recovery (forgotten password, recovery-email changes); AD-20; AC-06.
- **I8** (CAP-3, CAP-4) — Phone-username and recovery-email changes replace the binding only after review. Direct Auth credential changes, accepted disputes and security holds put the account into Access review required with a generic help screen. Dormancy is checked under versioned policy, and affected sessions are revoked on both clients. Source: functional-requirements.md Sign-in and continued access (holds, dormancy), Changed credentials and secure recovery; AD-3, AD-20; AC-05.
- **I9** (CAP-3, CAP-4) — A member without a usable recovery email gets identity-checked staff-assisted recovery: a recorded case, a single-use generation-bound setup grant stored only as a digest, a privately chosen password applied by server-side Auth Admin, serialized and fenced external resets, and no staff view of passwords or care/finance content. Source: functional-requirements.md Changed credentials and secure recovery (no recovery email); AD-20; acceptance-map.md Auth verification detail; AC-06.
- **I10** (CAP-3, CAP-4) — Login hold, church deactivation, restoration and full deletion have distinct transactional effects. Owner lifecycle hooks record handover obligations, and last-Admin or last-responsible-staff cases cannot lock the church out. Full deletion is a tombstoned resumable workflow recorded in the independent recovery journal. Restricted runbooks never disclose passwords or grant Admin care/finance access. Source: functional-requirements.md Membership and account lifecycle, Important edge cases (Accounts); AD-14, AD-19; AC-22.
- **I11** (CAP-3, CAP-4, CAP-16) — After an evidence-led refactor sweep, the implemented workflows reach production once their affected gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence. Source: AD-18; delivery-and-decisions.md Milestone 1; bmad-ticket workflow.ordering.

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
- Decision (agent, under owner pre-approval, 2026-10-03): Incepted as a full inception under owner-decisions-milestone-1.md, which authorises the milestone-1 run without stopping. The envelope's line saying no local requirement ids are introduced is replaced by I1–I11, mapped to CAP-3, CAP-4 and CAP-16, so entries cite stable ids as the platform epic does. Scope, Done when and the epic's ID are unchanged.
- Decision (agent, under owner pre-approval, 2026-10-03): The tracer bullet is entry 1: phone/password sign-up and sign-in on mobile and the selected staff client reach one live-access-checked Identity read on hosted staging. Entry 2 follows as the least certain slice: it hardens the predicate against alternate Auth routes, stale sessions and direct credential changes.
- Decision (agent, under owner pre-approval, 2026-10-03): Fourteen entries exceed the typical eight to twelve. The epic is not split, because the entries form one Identity/Cells lane with one owner and the source milestone keeps membership, recovery and access together.
- Decision (agent, under owner pre-approval, 2026-10-03): Sequencing. After entries 1 and 2, grants (3) and registration (4) run in parallel; review and linking (5) joins them; cells (6) and email recovery (7) then run in parallel. Credential changes (8), assisted recovery (9), lifecycle (10), deletion (11) and runbooks (12) are serial, because each edits the binding, generation or hold state that the next one reads.
- Decision (agent, under owner pre-approval, 2026-10-03): Platform prerequisites are pinned per entry. The tracer needs 1.2 (password AMR and no-SMS evidence) and 1.7 (selected client shells, which follow the 1.5 contracts and the 1.6 framework trial). Predicate hardening needs 1.3 (direct-change detection and fenced reset evidence), and assisted recovery inherits it through entry 2. First-Admin bootstrap needs 1.9 (restricted operator and system principal). Deletion needs 1.10 (independent recovery journal). Production delivery needs 1.12 (platform closure, which includes the 1.8 production baseline).
- Decision (agent, under owner pre-approval, 2026-10-03): Unapproved Q1 values (dormancy period, password length/breach policy, rate limits, email sender) are versioned Identity settings. Staging uses clearly labelled fixture values, including the proposed 90-day dormancy. Production keeps them unset, and private access there stays fail-closed until Israel approves them at entry 14. No value is treated as church policy.
- Decision (agent, under owner pre-approval, 2026-10-03): Staging email recovery uses the owner-approved test inboxes `israelmuyoba+<tag>@gmail.com`, read through the owner's connected Gmail. Production SMTP, sender/domain and redirects are an owner gate at entry 14 and never block phone/password sign-in.
- Decision (agent, under owner pre-approval, 2026-10-03): Approving a verified recovery email into the credential binding is an Admin action in the same review queue as applications and links, because the source requires approval and only Admin approves account links.
- Decision (agent, under owner pre-approval, 2026-10-03): Admin and cell-leader review and confirmation screens are built on the selected staff web client. Member flows (sign-up, application status, recovery, credential changes, deletion request) are built on mobile, and sign-in works on both. Cell confirmation is not in functional-requirements.md's list of essential mobile staff actions, so no mobile leader screen is deferred.
- Decision (agent, under owner pre-approval, 2026-10-03): Scope kinds owned by later epics (department, service type, care, finance, prayer team, lead pastor) are registered against this epic's grant model by those owners through the platform owner registry. This epic delivers the grant model, church-wide roles, cell scopes and fixtures that prove combined-role and Admin-without-care/finance denial.
- Decision (agent, under owner pre-approval, 2026-10-03): Lifecycle effects owned by later epics (device tokens, duties, follow-ups, chat, directory, custody) are registered hooks. This epic implements and tests the Identity and Cells effects and the hook contract with synthetic hook fixtures; it does not fabricate those future workflows.
- Decision (agent, under owner pre-approval, 2026-10-03): Israel, the only restricted operator, bootstraps the first Admin through the platform's restricted operator procedure. Staging uses synthetic Admins. Naming the first real Admin is a production gate at entry 14.
- Decision (agent, under owner pre-approval, 2026-10-03): No `plan_checkpoint`, `done_checkpoint` or `refine` flags are set. The hitl entries (1, 12, 14) pause for the owner by their nature, and builders plan criteria from the epic, the entry and its `verify`.
- Decision (agent, under owner pre-approval, 2026-10-03): The draft set and dependency checks ran inline, because this run could not start independent validation agents. `tickets.py status` and `next` were run on the written breakdown.
- Lane boundary: Entries 3 and 4 run in parallel only while 3 owns grant tables, grant commands and the client navigation shell, and 4 owns sign-up screens, membership applications and the Cells sign-up projection. Entries 6 and 7 likewise split Cells membership code from credential-binding and recovery-email code.
- External high-risk checks: An independent security reviewer repeats the alternate-route, stale-grant and reset-race cases from entries 2 and 9 before entry 14. Israel reviews the integrated demonstration and approves each production gate.
