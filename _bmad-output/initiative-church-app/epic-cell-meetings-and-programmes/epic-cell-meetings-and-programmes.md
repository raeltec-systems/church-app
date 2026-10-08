---
id: 5
type: "epic"
title: "Cell meetings and revisioned programmes"
parent: "initiative-church-app"
covers: ["CAP-9"]
after: []
risk: "high"
---

# Cell meetings and revisioned programmes

## Description

Establish Cells-owned canonical meeting schedules and occurrences, then deliver validated published programmes linked to the shared assignment engine. This supplies the meeting kernel that later attendance, recap and offering work extends.

Milestone: 2.

## Outcome

Confirmed cell members can see the current meeting plan and respond to their own assigned parts, while leaders retain truthful coverage and separate planned, intended and actual participation.

## Requirements

The requirement source is the parent spec, CAP-9, read with every companion and with the owner's Q2 decisions in `owner-decisions-milestone-2.md`, which replace the Q2 proposals where they differ. The local ids below hold this epic's contribution; each maps to CAP-9 (C9 also to CAP-4), and the spec, its companions and the architecture stay authoritative for detail.

- **C1** (CAP-9) — Cells owns each cell's canonical recurring meeting schedule (day, time and venue with optional map pin, in the Africa/Lusaka church zone) and generates stable meeting ids from the schedule and a nominal occurrence key. A leader cancels or moves one occurrence through explicit exceptions; Duties never generates a second cell calendar. Meetings have a held/cancelled lifecycle that later attendance, recap and offering work extends. Source: AD-6, AD-9; functional-requirements.md Cell groups (Setup, Meetings), Core data model (Cells and programmes).
- **C2** (CAP-9) — Confirmed members get a meeting reminder (by default the day before; the leader may configure it, and members may snooze), and a move or cancellation cancels obsolete reminders and notifies affected members. There are no quiet hours. Source: functional-requirements.md Cell groups (Meetings); owner-decisions-milestone-2.md; AD-8.
- **C3** (CAP-9) — The scoped leader or assistant drafts, for one meeting occurrence, the topic, scripture, date, start/end, venue and ordered programme parts (label, start time, expected duration or end, optional assignee from the confirmed roster, including members without a login). Order and fit inside the meeting are validated, unassigned parts stay visible as gaps, and the plan has Draft, Published and Cancelled states with revisions; drafts reach only managing leaders and authorised oversight. Source: functional-requirements.md Meeting programmes; design-contract.md Meeting plan.
- **C4** (CAP-9) — Preview shows the member view before publishing. The published programme is a dedicated safe projection that only confirmed members of the cell with approved active accounts can read, including a private home venue; it may name programme leaders but exposes no response ledger, private decline/contact notes or assignment history. Publishing creates or links one current Duties slot per stable part/position through the 4.11 owner operations and requests an explicit response; an existing department duty is linked, never cloned or changed. Source: functional-requirements.md Meeting programmes; AD-5, AD-6; AC-13, AC-15.
- **C5** (CAP-9) — A material meeting or part change (time, venue, part time, part, assignee) flags linked parts, and the leader publishes revised cell-owned assignments atomically, which supersedes prior consent and cancels obsolete jobs. A change affecting a linked department duty creates an owner-review mismatch instead. A change to study notes alone resets no unrelated response. Moving or cancelling a meeting reconciles its linked work. Source: functional-requirements.md Meeting programmes; AD-6; AC-10, AC-15.
- **C6** (CAP-9) — My cell, Home and My duties show the member's "You're on" part with its actual Awaiting/Accepted/Declined status, reporting time and instructions, and the member responds through Duties. A leader records attributed direct confirmation for a member without a login. Displaying a name is never confirmation. Source: functional-requirements.md Meeting programmes, Navigation and visual style (My cell); design-contract.md Home, My cell.
- **C7** (CAP-9) — Cannot attend is a separately reversible intention notice for one member and occurrence, with an optional practical note and recorded actor and time. It notifies the leader, raises a coverage warning when the member has an assigned part and asks for a separate duty response, and never sets a duty response or actual attendance. Source: functional-requirements.md Meeting programmes, Important edge cases (Cell programme); design-contract.md State fidelity 6; AC-15.
- **C8** (CAP-9) — After the meeting the leader marks it held and records actual programme leaders and substitutions as separate attributed records with corrections, so later reports and recaps never report the planned person as the one who served. Source: functional-requirements.md Meeting programmes; AD-12; design-contract.md State fidelity 6.
- **C9** (CAP-9, CAP-4) — A confirmed transfer or removal ends old-cell access to programmes and venues at once, ends the member's future cell-owned assignments with vacancy flags and closes their open notices; deletion erases or anonymises Cells meeting and programme personal data. Private programmes and venues are never cached for offline use, and clients clear them when scope loss is observed. Source: AD-13, AD-14; functional-requirements.md Member-visible recaps (scope-loss rule), Important edge cases; AC-02.
- **C10** (CAP-9) — A synthetic cell pilot proves the programme/duty/notice distinctions with chat absent. After an evidence-led refactor sweep, the implemented workflows reach production once their affected gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence. Source: delivery-and-decisions.md Milestone 2; AD-15, AD-18; AC-14.

## Done when

1. Cells generates stable meeting IDs from its canonical recurring schedule and occurrence/exception keys; moves/cancellations reconcile its linked work without a second calendar generated by Duties. Draft programme parts have validated order, duration and meeting bounds, including visible unassigned gaps.
2. Preview/publish exposes a dedicated safe programme to currently confirmed eligible members. Publishing assigned parts creates or links one current Duties slot per stable part/position; an existing department duty retains its owner and is never cloned or mutated through a display link.
3. Material meeting/part changes atomically publish revised cell-owned assignments, supersede prior consent and cancel obsolete jobs. Changes affecting externally owned department duties create owner-review mismatches. Notes-only changes do not reset unrelated responses.
4. My cell, Home and My duties show the member's current assignment response and support attributed direct confirmation. Cannot attend notices are separately reversible intention records with coverage warnings; they never set duty response or actual attendance. Actual leaders/substitutions have separate attributed correction records for later reporting/recaps.
5. Both surfaces pass scope, safe-projection, concurrency, lifecycle and reminder cases, including old-cell access loss and no persistent private cache. A cell pilot proves the programme/duty/notice distinctions with chat absent.
6. The implemented workflows are deployed to production after their affected operational gates pass, with an integrated mobile/staff demonstration and permission/lifecycle regression evidence for this epic’s own records and actions.

## Boundaries

Owns Cells meeting/recurrence and programme records plus actual programme-leader records. Calls Duties for assignments, Follow-ups for next actions and Notifications for delivery. Full attendance registers, visitors and private weekly reports belong to the later Cells envelope.

## Prerequisites

- Epic 2 (epic-identity-and-scoped-access) supplies Cells-owned confirmed membership, safe signup labels, current cell authority and transfer/lifecycle operations.
- Epic 3 (epic-durable-inbox-and-reminders) supplies Source registration and transactional meeting/duty reminder scheduling/cancellation contracts.
- Epic 4 (epic-duties-coverage-and-follow-ups) supplies Duties create/link/revise/cancel and conflict APIs, Follow-ups source operations and both-client fixtures; the full department UI need not be complete.

At inception, each consuming story pins the provider entry that delivers this output. These are output dependencies, not an extra whole-epic gate; unrelated provider work does not become a prerequisite.

## References

- parent — _bmad-output/initiative-church-app/initiative-church-app.md, Requirements and shared handoffs.
- spec — _bmad-output/initiative-church-app/spec-church-app/spec-church-app.md, CAP-9
- requirements — _bmad-output/initiative-church-app/spec-church-app/functional-requirements.md, Cell groups; Meeting programmes; Departments and assigned duties
- architecture — _bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md, AD-1, AD-2, AD-5, AD-6, AD-8, AD-9, AD-12, AD-13, AD-14
- design — _bmad-output/initiative-church-app/spec-church-app/design-contract.md, the applicable mobile/staff screens and state overrides.
- delivery — _bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md, Milestone 2; Q2, Q4
- acceptance — _bmad-output/initiative-church-app/spec-church-app/acceptance-map.md, relevant compound checks and detailed verification boundaries.
- owner decisions — _bmad-output/initiative-church-app/owner-decisions-milestone-2.md, Q2 (time zone, pilot cells, reminders, snooze, no quiet hours); owner-decisions-milestone-1.md (synthetic data, production gated).
- seams — docs/runbooks/identity-access.md, story 2.6 (cells, leader/assistant scopes, `cells_member_has_private_access`, transfer and the `cell_transferred` v1 payload), stories 2.10 and 2.11 (handover and deletion hooks); docs/runbooks/contracts-and-owner-seams.md; the Duties owner-operation guide written by entry 4.11.

## Notes

- Owner decision (2026-10-08, owner-decisions-milestone-2.md): the pilot cells are Shikoswe Cell and Estates C5/C7 Cell (one cell). Real names are production configuration only; staging and tests use `SYNTHETIC Shikoswe Cell` and `SYNTHETIC Estates C5/C7 Cell`. The church zone is Africa/Lusaka, reminders are configured by whoever sets them, members can snooze, and there are no quiet hours, replacing the spec's "same quiet-hours rules" for meeting changes. The spec text is unchanged; the stories follow the owner decision.
- Constraint: Required first-release addition. Its M2 meeting kernel precedes M4 attendance/reports, avoiding a dependency cycle between programmes and the full Cells feature.
- Unknown: Q4 gates live member data and private home venues in production; the pilot cells' leaders and assistants are still open under Q2 and are named at the pilot. Private home venues stay behind current cell access; no chat linkage grants authority.
- Constraint: This owner implements its required mobile/staff screens, source-specific safe projections, files and refresh signals, and registers its real lifecycle/handover/deletion effects before activation; shared platform stubs are not completed feature behavior.
- Risk: high because this epic changes shared application behavior or protected state; require the independent permission/contract regression suite and owner release review in addition to story checks.
- Decision (agent, under owner pre-approval, 2026-10-08): Incepted as a full inception under owner-decisions-milestone-1.md and owner-decisions-milestone-2.md, which authorise the milestone runs without stopping. The envelope's line saying no local requirement ids are introduced is replaced by C1–C10, mapped to CAP-9 (C9 also to CAP-4). Scope, Done when, ID and production verification are unchanged.
- Decision (agent, under owner pre-approval, 2026-10-08): The tracer bullet is entry 1: Admin sets a synthetic cell's weekly schedule and venue, Cells generates stable meeting ids in Africa/Lusaka time, the leader cancels or moves one occurrence on staff web, and a confirmed member sees the next meeting with its private venue on mobile My cell while a non-member is refused. Entry 4 (publishing through the Duties owner operations) is the least certain slice and follows the programme draft.
- Decision (agent, under owner pre-approval, 2026-10-08): Cells applies a transfer's programme and cell-duty effects inside its own transfer command (entry 9) by calling the Duties owner operations, not through a `cell_transferred` lifecycle hook. No other owner registers a real hook on that event in this epic, so the contract v2 payload with cell ids that identity-access.md requires before a real hook is not introduced here; the first real external consumer (for example chat) adds it.
- Decision (agent, under owner pre-approval, 2026-10-08): The default meeting reminder is one reminder 24 hours before the meeting start (the spec's day-before reminder); the leader may change or add reminders on the schedule or one occurrence, and members may snooze. Programme parts use the duty reminder rules from 4.8. No quiet hours apply.
- Decision (agent, under owner pre-approval, 2026-10-08): The cell schedule and venue are set by Admin with the cell (functional-requirements.md Setup); one-off moves and cancellations are the scoped leader's or Admin's. The programme editor, preview and publish are staff web screens (design-contract.md Meeting plan); members' My cell, Home, responses and Cannot attend are on mobile; the leader's essential programme coverage actions reuse the 4.9 coverage queue on both clients under the cell scope.
- Decision (agent, under owner pre-approval, 2026-10-08): Cell assistants manage programmes for their cell (the assistant scope from 2.6 already gives cell-private access, and functional-requirements.md lets leaders and assistants manage delegated cell duties). Pastor sees authorised oversight; Admin alone sees operational metadata only, never a draft's private notes.
- Decision (agent, under owner pre-approval, 2026-10-08): The meeting held/cancelled lifecycle is delivered here (cancel in entry 1, held in entry 8) because epic 7 depends on it; attendance registers, visitors and private reports stay in epic 7.
- Decision (agent, under owner pre-approval, 2026-10-08): Cross-epic prerequisites are pinned per entry: the tracer needs 2.6 (cells and leader scopes) and 3.3 (church-time calculation); meeting reminders need 3.5 (recipient routing); publishing needs 4.11 (owner operations); member responses need 4.5 (My duties) and 4.9 (coverage queue and direct confirmation); lifecycle needs 4.12 (Duties lifecycle hooks); production delivery needs 4.15 (duties in production, which includes 3.10 and 2.14).
- Decision (agent, under owner pre-approval, 2026-10-08): No `plan_checkpoint`, `done_checkpoint` or `refine` flags are set. The hitl entries (10, 12) pause for the owner by their nature.
- Decision (agent, under owner pre-approval, 2026-10-08): The draft set and dependency checks ran inline, because this run could not start independent validation agents. `tickets.py status` was run on the written breakdown.
- Lane boundary: Entries 2 and 3 run in parallel only while 2 owns the meeting source registration, meeting reminders and the move/cancel notices, and 3 owns programme tables, the draft editor and its validation. Entry 6 follows 2 because both change the meeting move/cancel command. Entries 7 and 8 split notices from actual-leader records.
- External high-risk checks: An independent reviewer repeats the safe-projection, old-cell access loss and material-revision cases before entry 12. Israel witnesses the synthetic pilot (entry 10) and approves each production gate.
