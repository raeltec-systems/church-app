# Epic 7 inception proposal: attendance, consented visitors and private reports

**Prepared 30 October 2026. Unapproved proposal; no Epic 7 implementation or acceptance is claimed.**

The proposed outcome is that a cell leader can record what happened at a meeting, arrange permitted follow-up and submit a private report through the ordinary staff and mobile app, while an authorized pastoral reviewer can review it and an Admin can route missing work without receiving care content. The existing [Epic 7 envelope](epic-cell-attendance-and-private-reports.md), its six Done when checks and CAP-8 remain the authority.

The candidate breakdown is [tickets.proposed.toml](tickets.proposed.toml). Its deliberate filename keeps it outside the runnable ticket tree. There is no canonical `tickets.toml`, new leaf, build plan, status change or owner acceptance from this proposal. Owner agreement is required before the agreed set is installed as the epic's breakdown. Estimation is disabled; this document makes no completion-date promise.

## Basis and BMAD method

The source inspection began from verified main `c96cd562b2650c37f5d3d879cb12891419700139`, with its existing merged Cells, Identity, Follow-ups and Notifications implementation. This is a brownfield Flutter mobile/staff monorepo with shared `packages/client_core`, `packages/design_system` and an authoritative Supabase/Postgres backend.

The parent build run activated the repository's `bmad-ticket` skill through its config, store and customization resolvers, read `slice.md`, `ticket.md` and `validate.md`, and delegated codebase learning. This draft applies the resolved rules: a real first tracer, implementation-sized stories, all feature surfaces included in their owning stories, risk on every entry, an independent check for high-risk work, and the mandatory refactor sweep before the closing verification. Structural/dependency and independent set validation belong to the parent run; writing these files alone is not evidence that those checks passed.

Source chain:

- [Initiative and capability ownership](../initiative-church-app.md) and [declared dependencies](../tickets.toml).
- [CAP-8](../spec-church-app/spec-church-app.md), [full functional requirements](../spec-church-app/functional-requirements.md), [design contract](../spec-church-app/design-contract.md), [acceptance map](../spec-church-app/acceptance-map.md) and [delivery decisions](../spec-church-app/delivery-and-decisions.md).
- [Architecture](../architecture-church-app/architecture-church-app.md), especially AD-4, AD-5, AD-7, AD-8, AD-9, AD-12, AD-13 and AD-14.
- [Milestone 1](../owner-decisions-milestone-1.md) and [milestone 2 owner decisions](../owner-decisions-milestone-2.md), plus the [Epic 5 envelope](../epic-cell-meetings-and-programmes/epic-cell-meetings-and-programmes.md) and its [provider entries](../epic-cell-meetings-and-programmes/tickets.toml).
- `docs/runbooks/contracts-and-owner-seams.md`, `follow-ups.md`, `identity-access.md`, existing Cells/Identity/Follow-ups migrations and shared client implementations.
- Actual design images `admin-07-meeting-report.png` and `admin-10-cell-reports.png`, interpreted with the binding design overrides.

No new local requirement IDs are introduced. Every proposed entry identifies its CAP-8 contribution; the coverage map below preserves the more detailed source obligations.

## Scope and boundaries

Cells owns historical registers, visitors, consent provenance and private weekly reports. Reuse existing meeting identities, effective membership dates, actual held/not-held records and actual programme leaders. Reuse the one Follow-ups task registry and Notifications scheduler. Do not build a second calendar, task tracker, identity-matching rule or reminder worker.

This epic provides the safe aggregate/reference outputs later owners need. Separate recap preview/publication is Epic 8; pastoral appointment negotiation is Epic 9; prayer and directory have their own epics; service reporting/trends and offerings remain Epics 12 and 13. A report submission must create none of those outcomes implicitly. There is no dependency on chat.

Epic 6 acceptance reconciliation comes first in this assignment. It does not add an undeclared whole-Epic-6 feature dependency to Epic 7: the initiative names provider outputs from Epics 2, 3, 4 and 5. Production migration ordering remains a separate operational release check and will include all preceding merged migrations.

## Proposed first demonstration

A leader opens a past meeting through the normal Cells route. The app uses the existing Cells action to record whether it was held. For a held meeting, the leader sees its historical roster, including a member without a login and a member who later transferred, and marks some people Present, Absent or Excused while leaving others Unrecorded. Saving returns a server-confirmed result. Reopening on mobile shows the same record and its incomplete coverage. A leader from another cell and an Admin without the required scope cannot read protected details.

Entry 1 includes the necessary owner review of attendance readership and retention boundaries before affected behavior is built or activated; it is not preceded by a disconnected setup story. Synthetic proof may proceed where policy cannot change its result. The first demonstration must not premark everyone Present, derive attendance from an accepted duty, or turn a Cannot attend notice into Excused.

The least certain integration is private report authorization and lifecycle, followed by consent withdrawal racing an active contact task. **Review that private-care authority, field separation and lifecycle contract at the first planning checkpoint in 7.1**, so a scope or policy conflict is discovered before attendance/contact contracts harden. The report implementation remains in 7.7 because it consumes the stable historical register and visitor contracts; later implementation does not mean late discovery of its privacy risk. Any unresolved owner choice stays explicit and prevents the affected behavior, while independent fictional proof may proceed where that choice cannot change the result. The relevant later plans also receive proposed owner checkpoints, and each high-risk entry names an independent check beyond its own tests.

## Proposed sequence and why it has 14 entries

The usual guidance is 8–12 entries. This proposal has **14** because the epic spans three personal-data domains, two clients, identity-linked joining, source-specific scheduling and an owner acceptance/release boundary. Combining the work more aggressively risks a single large story hiding authorization, lifecycle or normal-navigation gaps.

| Proposed ID | Result available through the app | Boundary rationale |
| --- | --- | --- |
| 7.1 | Record and reopen a historical register on staff and mobile | First end-to-end tracer; reviews the high-risk report-care contract early and includes foundational permissions and record lifecycle. |
| 7.2 | Correct attendance and recover conflicts/uncertain saves | Completes the correction and incomplete-data experience before deriving flags. |
| 7.3 | Review proven absence streaks and assign a next action | Adds the missing shared Follow-ups direct-contact adapter and leader-visible response for accountless/held recipients; completion never alters attendance. |
| 7.4 | Capture a visitor with only agreed details | Separate consent and contact authorization boundary, including name-only support. |
| 7.5 | Work visitor follow-up and stop on withdrawal | Consumes 7.3's fallback and cancels contact needs as well as task reminders on withdrawal, without a second tracker. |
| 7.6 | Invite and review joining | Reuses identity review and independent approvals, including accountless people. |
| 7.7 | Draft, submit and correct a private weekly report | Establishes real report-care grants and separate private storage/API contracts. |
| 7.8 | Review authorized reports and see safe submission gaps | Completes the reviewer and Admin metadata surfaces without fetching care for Admin. |
| 7.9 | Route missing reports and apply their exact reminders | Uses 7.3's accountable fallback even though the report schedule suppresses the generic supervisor alert. |
| 7.10 | Verify integrated lifecycle, handover and erasure | Verifies successful security denial separately from refused ordinary revocation and approved handover/retry; cannot postpone earlier safety. |
| 7.11 | Read scoped coverage and authorized downstream references | Gives later epics stable, tested contracts without implementing their domains. |
| 7.12 | Rehearse the owner pilot and support procedures | Human evidence and operating decisions stay distinct from automated engineering checks. |
| 7.13 | Refactor the completed workflows | Mandatory sweep after prior work and before final verification; no missing feature hidden as cleanup. |
| 7.14 | Verify the exact candidate and prepare controlled promotion | Keeps deployment, owner approval and post-deployment evidence separate from build status. |

For owner review, a 12-entry alternative can merge 7.1 with 7.2 and 7.7 with 7.8, preserving every check. The tradeoff is larger initial attendance and reporting stories. An 11-entry alternative additionally merges 7.4 with 7.5, but combines consent capture, contact-task authority and worker races in one build. The recommended proposal retains the 14 boundaries; it does not split CAP-8 into new epics or drop any scope. If the owner changes the grouping, preserve IDs appropriately and rerun the dependency and set checks before installing a canonical breakdown.

Entry 7.8 intentionally exposes safe submission metadata only; actual missing-report task routing is completed by 7.9. It must not show an enabled action that has no backend behavior during that interval.

## Dependencies and build lanes

The proposed TOML pins providers by actual entry, not by a whole epic:

| Required output | Existing provider |
| --- | --- |
| Independently granted roles and scope registration | 2.3 |
| Phone/password application and reviewed/accountless identity linking | 2.4, 2.5 |
| Confirmed primary membership and effective dates | 2.6 |
| Security holds, handover and resumable deletion | 2.10, 2.11 |
| Source contracts and authorized deep links | 3.2 |
| Church-time calculation and policy versioning | 3.3 |
| Worker lease, retry and final source checks | 3.4 |
| Current recipient eligibility and the direct-contact registration seam; no implemented Follow-ups fallback | 3.5; the missing shared adapter and normal leader response are delivered by 7.3 |
| Canonical owned tasks and task reminders | 4.6, 4.7 |
| Source owner operations and both-client fixtures | 4.11 |
| Task lifecycle and handover | 4.12 |
| `identity_revoked_scope()` and revocation/unlink handover collection used by Cells | 4.16, pinned on earliest lifecycle consumer 7.1 and integrated verification 7.10 |
| Canonical meeting identity and exceptions | 5.1 |
| Held/not-held facts and actual programme leaders | 5.8 |
| Cells transfer/removal/deletion behavior | 5.9 |
| Predecessor Cells production verification for controlled release | 5.12, only on closing 7.14 |

Visitor and report work share Cells migrations, command registration/dispatch, client repositories and routes. The dependency self-check therefore added **7.3 → 7.4** and **7.6 → 7.7**, making this proposed set one implementation lane. These dependencies protect the evolving shared code and registry; they are not a claim that visitor consent logically depends on absence flags. Opening independent lanes later requires an explicit file/schema/registry ownership plan and a revalidated breakdown. The lifecycle integration follows all owner records, and aggregates/references follow the integrated safety verification.

The technical provider entries are already built in the inspected source; that fact does not turn their owner acceptance or production status into a new claim. The final release must inspect actual authorized migration state rather than infer it from a ticket status.

### Required Follow-ups fallback: implemented in 7.3, reused by 7.5 and 7.9

The independent dependency review found a real provider limitation: [`docs/runbooks/follow-ups.md`, Story 4.7](../../../docs/runbooks/follow-ups.md#story-47-remind-follow-up-owners-and-supervisors-on-the-task-schedule) documents that accountless or security-held owners currently finish with `no_direct_contact_route`; their reminder appears as **Without a route** in Reminder health. Story 3.5 supplies the [registration seam](../../../docs/runbooks/contracts-and-owner-seams.md#direct-contact-routes-story-35), not the shared Follow-ups adapter. The report-specific schedule also suppresses the generic supervisor alert, so that alert cannot stand in for an accountable response to a missed report.

As the earliest consumer, 7.3 must implement and register the shared Follow-ups fallback using the existing Notifications needs/route contract, canonical task source and existing supervision/routing surfaces. Repeated emission is idempotent; the current source, task, recipient and supervisor authority are checked before exposing an actionable need. Generic route data must contain no hold reason, contact details or report-care text. The ordinary authorized leader sees **Needs direct contact**, opens the permitted task context and records a contact attempt and next review on behalf of the owner, or arranges an approved handover to an eligible responsible person. If no eligible person can act, the existing routing/handover workflow retains the unresolved accountable need instead of dropping it. An Admin's metadata view does not gain private context from the fallback.

Entries 7.5 and 7.9 explicitly depend on and consume this adapter. Visitor consent withdrawal, stale source revision, task closure, report submission and relevant reassignment/lifecycle changes cancel or remove obsolete contact needs as well as reminders. Test accountless and held recipients through the real worker and both clients, including duplicate delivery attempts, withdrawal/submission races, denied source reads and the leader's actual response. No new tracker or scheduler is introduced, and a held recipient does not regain app access through a direct-contact action.

### Revocation results and handover must be reported truthfully

Story 4.16 supplies `identity_revoked_scope()` and the revocation/unlink hook collection used by Cells 5.9; it is a real prerequisite, not an implied capability of 2.10 alone. See [`identity-access.md`](../../../docs/runbooks/identity-access.md) and [Duties decision 10](../../../docs/runbooks/duties.md#decision-10-the-last-leaders-scope-cannot-be-revoked-first-cross-epic-identity-change).

An ordinary attempt to revoke the last responsible leader can return `handover_required` and roll back the grant change. The UI must show the refusal, preserve the true grant state, support the approved handover and retry, and never report that access was revoked or bypass the safeguard. Immediate denial in this proposal means **a successful revocation, applied security hold or successful account unlink**, even if a handover obligation remains pending. Security hold/unlink semantics are not replaced by an ordinary revoke. Entry 7.10 verifies both outcomes with separate sessions, including the successful retry after handover, rather than asserting that every revoke request succeeds.

## Unresolved owner requirements

These questions are policy or scope decisions. They are not implementation defaults and are not answered by this proposal.

### Q4: visitor, youth, report privacy and retention

Confirm the agreed contact fields and consent evidence, who can see each field, withdrawal and renewed-consent procedures, under-18 safeguards, report-care readership, and retention/deletion/backup treatment for visitors, registers and reports. Name-only visitor support and stopping contact after withdrawal are already mandatory. Unapproved youth/contact behavior stays disabled.

Prior milestone 2 approval of labelled **department** contacts and anonymized **duty/task** history is limited to those subjects. It does not approve unrestricted visitor contacts, new private report retention or a legal retention period for this epic. Existing production gate state must not be treated as approval of these new policy values.

Report care access needs real registered scopes. Identity's existing role definition explicitly says care and finance oversight are separate from the Pastor role, and only fixture care scopes currently stand in for later owners. Decide which named pastoral staff receive report-care oversight and its scope. Admin or Admin-plus-Pastor without that grant receives operational metadata only. The existing cell leader/assistant's authorized report access remains scoped to their cell and subject to current access checks.

### Q6: named operators and rollout

Name the pilot cell leaders/assistants, report reviewers, supervising follow-up owners and restricted support operator, and approve the rollout order. This is Q6's module-ownership decision; it is not a substitute for privacy or retention policy. Chat remains optional and cannot gate these features.

The recorded pilot cells are Shikoswe and Estates C5/C7 (one combined cell). Automated staging fixtures continue to use safe `SYNTHETIC` identities and reserved fictional phone ranges. The existing allowance for real names during owner-led interactive staging feedback does not authorize an agent to create real visitor or pastoral records automatically.

### Q8: report timing and truthful metrics

The baseline requires missing-report reminders the day after the meeting and three days after it, with no parallel generic task reminder stream. It does not specify the precise clock or anchor. Confirm whether these are church-local calendar dates and the intended time, or another expressly chosen rule, and how corrected meeting times affect outstanding deadlines. Confirm the reporting obligation and gap treatment for explicitly not-held versus unresolved meeting facts. Until then use explicitly fictional fixture policy for testing, not an inferred production setting.

For coverage/aggregate outputs, confirm the percentage denominator, treatment of Excused and Unrecorded, inclusion of incomplete registers, reporting periods, versioning and retention. Ordinary authorized counts can remain explicit without an unapproved percentage or comparison. Visitor totals are attendances, never unique people.

The later owner decision already fixes Africa/Lusaka and **no quiet hours** for Q2. Old proposal text about 21:00–07:00 quiet hours does not apply. Q2 does not settle the missing report's source-specific clock.

Q7 care/visitor scopes must remain compatible with any future report referral, but actual visit negotiation and youth-visit policy belong to Epic 9. This proposal does not choose them or add a pretend Schedule visit action.

## Proposed technical choices to confirm during builds

These are engineering choices within the source requirements, not claimed owner decisions:

- Reuse the historical membership interval rule already implemented by `20261028130727_cells_record_roster.sql`: started by the effective meeting start and not ended at that instant. Define how an attendance snapshot records that basis and how an authorized meeting-time correction is reconciled without silently rewriting facts.
- Preserve the canonical meeting states `scheduled`, `unrecorded`, `held`, `not_held`, `cancelled` and `withdrawn`. Only recorded qualifying facts support absence flags. An unresolved held meeting or Unrecorded register entry cannot prove a consecutive absence; later correction may establish the true sequence.
- Choose row/aggregate revision granularity explicitly; retain server authorization, expected revisions, idempotent request receipts and attributed correction history either way.
- Define an immutable absence/contact episode identity. Follow-ups has one task per source/purpose forever and no terminal reopen. Repeated attempts use Waiting and a recorded review date while active; a genuinely new episode must not revive an old terminal task or create duplicate active tasks.
- Preserve `cells_visitor/visitor_follow_up` and `cells_meeting/missing_report` fixture conventions, or record and validate a deliberate contract change. Register source checks, safe context, lifecycle effects and source-specific schedules in the owning migration.
- Implement the absent shared Follow-ups direct-contact route in 7.3 using 3.5's seam, then reuse it in 7.5 and 7.9; a reminder-health counter or suppressed generic supervisor alert is not the required leader-visible response.
- Store report metadata separately from private fields and expose distinct audience-safe reads. Grant assignment to practical work must not imply access to its complete private source.
- State whether report attendance is a submitted snapshot, current corrected register, or both with clear labels. A later correction must not make a submitted report silently contradict the displayed totals.
- Use the existing `CellsController` uncertain-command recovery and protected-memory invalidation patterns. Private domain records remain session memory; offline writes are visibly unsent/unconfirmed and never silently replayed.

Each personal-data story must ship current authorization, scope/hold refresh, safe audit, lifecycle/handover/deletion registration and no-private-cache behavior for the fields it adds. Use 4.16's actual revocation hook and distinguish successful security denial from a rolled-back `handover_required` refusal. Entry 7.10 verifies cross-domain composition and completes handover workflow; it is not a later safety milestone that permits unsafe interim records.

## Design fidelity and ordinary navigation

Use `packages/design_system` and shared client components, retaining the approved navy staff navigation, card/list hierarchy, type, spacing and status vocabulary. The report editor reference has the register beside report content; the review reference has a cell/week selection list beside the selected report. On small screens preserve the same hierarchy with accessible controls and visible save/state feedback.

The binding corrections matter more than obsolete prototype behavior:

- Show Present, Absent, Excused and Unrecorded; do not preload Present or combine absent/excused into an unexplained count.
- Display legitimate empty, missing data, load failure, unsent change, uncertain submission, permission denial and stale-write conflict distinctly.
- A private report does not share testimony with members. No recap record is published by report submission.
- Admin-only report routes do not fetch the private care editor. Pastor title, Media, finance permission and a practical task assignment add no report-care access by themselves.
- Do not add the prototype's offering form or a toast-only Schedule visit action to this epic.
- Keep the five mobile tabs. Reach leader work through Home/account/authorized staff routes and preserve My cell and My follow-ups for their proper audiences.
- Make retry, back/cancel, keyboard operation, clear status text and ordinary permitted deep links part of the working flow, not a later polishing task.

Source conflict corrected during reconciliation: `docs/runbooks/contracts-and-owner-seams.md` now assigns attendance to Epic 7 and recap publication to Epic 8, matching the initiative. The old prototype's shared-testimony wording and old Q2 quiet-hours proposals are superseded by the cited binding sources, not new missing features.

## Coverage of the existing Done when and launch checks

| Existing Done when | Proposed coverage | Required acceptance evidence |
| --- | --- | --- |
| 1. Historical roster, four attendance states, corrections and three recorded absences | 7.1–7.3; lifecycle 7.10 | Historical transfer/accountless fixtures, complete and incomplete registers, explicit corrections, exact streak cases and two-session conflict. |
| 2. Agreed visitor details, withdrawal and reviewed joining | 7.4–7.6; lifecycle 7.10 | Name-only and contactable visitors, withdrawal race, agreed-route invitation, shared-phone conflict and reviewed identity-preserving joining. |
| 3. Private report separation and permitted review/routing; no recap publication | 7.7–7.9 | Direct API field exclusions, real care grants, ordinary author/reviewer/Admin flows, empty versus failure, no public/recap side effect. |
| 4. Shared tasks, exact reminders, cancellation, reassignment and lifecycle | 7.3, 7.5, 7.9, 7.10 | My follow-ups/supervision/routing screenshots; real worker fallback for accountless/held recipients; idempotent needs and cancellation; terminal episodes; refused ordinary revocation, approved handover/retry and successful security denial. |
| 5. Both clients, scoped aggregates/references and approved support procedures | 7.1–7.12 | Normal UI journeys, concurrency/recovery evidence, denominator/version/coverage cases and reviewed runbooks. |
| 6. Approved production delivery with integrated permission/lifecycle evidence | 7.12–7.14 | Owner pilot, exact-head test ledger, approved affected gates, actual migration state, explicit release approval and post-deployment verification. |

The compound acceptance map contributions are AC-03 (accountless attendance and later linking), AC-12 (visitor/missing-report work), AC-14 (core work without chat), AC-16 (private report does not publish a recap), AC-18 (canonical tasks), AC-22 (current access/deletion) and AC-23 (usable staff/mobile actions). This epic proves its side of those checks; it cannot claim the downstream recap, visits or services requirements complete.

The minimum integrated fictional walkthrough includes a historical meeting roster, a later transfer and later joiner; all four attendance states; a cancelled meeting and missing fact between recorded absences; an accountless member; name-only and consenting visitors; an active withdrawal; a shared-phone joining conflict; a private report and correction; a denied Admin/Pastor-without-care read; an accountless and a held task/report recipient whose leader actually works the direct-contact need; a refused last-leader revoke followed by approved handover and successful retry; applied security hold/unlink despite pending obligations; and honest aggregate coverage. Each step records setup, role, expected useful result, actual result and evidence.

## Risk and validation plan

The resolved BMAD scale classifies schema, deletion, authentication and protected-state work as high risk. Accordingly all personal-data, lifecycle and release entries name an independent check beyond their own tests; the bounded cleanup is medium risk. The principal failure mechanisms are:

| Risk | Likelihood if the existing shortcut is reused | Impact | Required check |
| --- | --- | --- | --- |
| Broad Pastor programme read reused for care reports | Plausible: the nearby programme code has broader oversight | High: private pastoral disclosure | Direct API field-level and combined-role review with real report-care scopes. |
| Current roster or intent used as attendance | Plausible: both current roster and notices already exist | High: false absence/follow-up and misleading reports | Historical membership, held-state and four-state fixtures plus normal UI review. |
| Terminal task reused for a new absence/consent episode | Plausible: registry uniqueness is permanent | High: missing or inappropriate contact work | Episode identity and terminal-history review; withdrawal/correction races. |
| Duplicate report reminders or invented local clock | Plausible: generic task scheduling exists | Medium to high: repeated contact and dishonest overdue state | Explicit approved policy, source replacement schedule and real worker evidence. |
| Assuming 3.5 already supplies Follow-ups fallback | Confirmed provider gap: current Follow-ups returns `no_direct_contact_route` | High: accountless/held owners have no actionable reminder route, especially when report schedules suppress supervisor alerts | 7.3-owned shared adapter, explicit 7.5/7.9 handoff, normal leader response and idempotent cancellation/race evidence. |
| Treating an ordinary refused revoke as successful security denial | Plausible if lifecycle assertions ignore 4.16's rollback | High: false permission state or bypassed last-responsible-person safeguard | Exact 4.16 prerequisite, visible `handover_required`, approved handover/retry and separate successful hold/unlink/revoke tests. |
| Deferred lifecycle/erasure hooks | Plausible if data stories are treated as CRUD alone | High: revoked access or deleted content survives | Per-story hook checks, integrated transfer/deletion/restore rehearsal. |
| Passing unit tests with unreachable or misleading UI | Plausible across shared mobile/staff paths | High: promised ministry work cannot be finished | Normal navigation, real persistence, errors/recovery, design screenshots and owner pilot. |

Apart from the explicitly documented existing Follow-ups fallback limitation, these are planning risks rather than claims of defects in the current unimplemented Epic 7. The future test files and fixtures must be authored during the appropriate stories; this proposal has not run them.

For every validation record exact command or manual procedure, commit, environment, date, result/count where meaningful and evidence path. Use explicit `authored only`, `run-passed`, `run-failed`, `skipped` or `blocked` labels. Include current role/combined-role permission tests, stale sessions, two real clients, idempotent uncertain retries, worker cancellation, cross-client persistence, accessible forms and private-state clearing. Provide exact local-machine/device steps for any unsupported environment checks. A green job is evidence only for its commit and executed steps.

The high-risk independent reviewer must be separate from implementation; owner pilot and device evidence are additional. Required release gates stay open until their evidence and approval exist. Never record a functional omission as merely unverified, nor classify an unsupported physical-device check as missing backend code.

## Owner review and approval requested

Before this becomes the executable breakdown, confirm:

1. **Sequence and size:** keep the recommended 14 entries, or group the specified pairs while retaining the complete scope and verification?
2. **Privacy and operators:** what visitor fields/contact consent, youth safeguards, report-care grants, named operators and retention/deletion/backup procedures are approved under Q4/Q6?
3. **Timing and metrics:** what exact report deadline clock/anchor, not-held/unresolved meeting treatment, denominator and completeness rules should the Q8 policy use?
4. **Checkpoints:** retain the proposed plan/done checkpoints for the first tracer and owner pilot/release, plus plan checks on visitor consent, private-report authorization, missing-report timing and aggregate definitions; should any description, note or reference be changed?

Approval of this proposal would approve the agreed breakdown, not deployment or completion. Only after it is approved should `tickets.proposed.toml` be adopted as canonical `tickets.toml`, the envelope Notes record the agreed decisions, downstream whole-epic dependencies be pinned to the delivering entries where applicable, and ticket status/dependency checks be rerun. Remaining policy unknowns must stay attached to the affected entries, with live behavior gated. The owner-only pilot and release work remain human checkpoints.
