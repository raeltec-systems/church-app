# Independent BMAD validation of the unapproved Epic 7 proposal

Review date: 2026-10-30. Scope: inception, not execution or acceptance. The supplied validation input was treated as the proposed breakdown and checks; no BMAD skill or earlier build conversation was used. No application source or canonical ticket was written.

## Reviewed input and evidence

- Repository: `/workspace/scratch/308c700530ee/church-app`.
- Supplied input: `/tmp/church-app-epic7-validation-input.txt`.
- Reviewed proposal SHA-256: `d6a149b843385ef215dfb92b870bcbdce4ce90c7e1d01ec6507f03c67c12cfc3`.
- The supplied proposal text matches the real `tickets.proposed.toml` exactly.
- Full disposable initiative copy: `/tmp/church-app-epic7-independent-eaa_rgqw/initiative-church-app` (all completed and future children preserved).
- Formal status output: `/tmp/church-app-epic7-independent-eaa_rgqw/ticket-status.json`.
- Reference checks: `/tmp/church-app-epic7-independent-eaa_rgqw/reference-check.json`.
- Actual design images inspected: `docs/design-handoff/screenshots/admin-07-meeting-report.png` and `admin-10-cell-reports.png`.

Commands run from the real repository:

```text
python3 .agents/skills/bmad-ticket/scripts/tickets.py status --help
python3 .agents/skills/bmad-ticket/scripts/tickets.py status /tmp/church-app-epic7-independent-eaa_rgqw/initiative-church-app/epic-cell-attendance-and-private-reports
```

The status command returned exit 0, 14 planned entries, a single chain 7.1 through 7.14, and empty `unpinned_after`, `undeclared_after`, and `order_conflict`. It reported no cycle or drift. Its only problems are the three known pre-existing F1/F2/F3 plan ticket-id metadata warnings in Epic 6; they are not Epic 7 findings. All 47 proposed references exist and every named Markdown anchor resolves. Every entry has a description, verify, unknown, risk, covers and dependencies; the 13 high-risk entries name external checks. No entry is refined or execution-ready.

## Findings requiring proposal correction

### F1 — The first task consumer must own a real reminder fallback for accountless or held owners

Affected entries: 7.3, 7.5 and 7.9, with integrated proof in 7.10–7.12.

The provider table currently presents 3.5 as supplying direct-contact fallback. That entry supplies the registration/runtime seam, but a source owner still must register its route. `docs/runbooks/follow-ups.md:153` explicitly says no direct-contact route exists for Follow-ups: a held/accountless task owner's reminder ends `no_direct_contact_route`, and only the generic supervisor alert remains. The missing-report source-specific schedule intentionally disables that generic supervisor alert. Thus the planned missing-report schedule can leave no actionable reminder path for a held or accountless owner even if its two scheduled jobs run correctly.

Evidence:

- `spec-church-app/functional-requirements.md:242` requires routing the reminder need to the responsible leader's Needs direct contact list for no-account or suspended access, without creating undeliverable member push.
- `docs/runbooks/contracts-and-owner-seams.md:249–262` specifies an owner-registered route, idempotence on `need_id`, a leader list, no disclosure of why access is unavailable, and no relative contact number used as an automatic destination.
- `docs/runbooks/follow-ups.md:153,158–170` records the absent route and replacement schedule.
- Current migrations register direct-contact routes only for fixture, Duties and Cells meeting reminders; none registers a Follow-ups route. Follow-ups owns `followups_task` and `followups_supervision`, so Cells cannot register their route as if it owned those source types.

Concrete correction: make 7.3 the owner of the shared Follow-ups adapter and leader-visible need under the existing Notifications contract. State that 7.5 and 7.9 reuse it, including purpose-specific cancellation/revalidation. Verify accountless and held owners, safe supervisor access, idempotent retry, stale source/withdrawal/closure cancellation, and no false delivery claim. Preserve the one task registry and one scheduler.

Exact failed rules:

- checks.set: “Together the tickets account for every requirement in the epic's spec, referenced numbered source, or Requirements, except scope deferred with the user.”
- checks.set: “UX, architecture, constraints, and integration work are accounted for even when they lack ids. The combined results must satisfy the epic's Done when; citing an id alone is not coverage.”
- checks.dependencies / Needs: a needed integration must be built by the item or delivered by its `after`.
- checks.dependencies / Shared setup: shared integration needs one earliest owner and dependent consumers.
- checks.dependencies / Handoffs: producer and consumer descriptions must both name the shared output.

### F2 — Pin the real revocation-handover provider and distinguish refusal from a completed revocation

Affected entries: earliest lifecycle consumer 7.1, subsequently 7.3/7.5/7.7/7.10.

The current dependency closure through 5.9 includes 4.12 but not 4.16 until the final 7.14 release chain. The concrete Cells handover implementation supplied by 5.9 calls `app.identity_revoked_scope()`, introduced by 4.16. The same 4.16 change adds revocation-origin handover obligations and the current last-responsible-leader behavior. This actual provider should be pinned before the first story extends and exercises these hooks, instead of appearing only in release prerequisites.

Evidence:

- Epic 4 entry 4.16 describes the Identity scope-revocation handover hook.
- `supabase/migrations/20261015190139_duties_owner_decisions.sql:24–37,1100–1196` implements the hook, revocation obligations and refusal behavior.
- `supabase/migrations/20261021122802_cells_transfer_effects.sql:503–532` calls `app.identity_revoked_scope()` in Cells' last-leader handover hook.
- `docs/runbooks/follow-ups.md:286` records that Identity revocation obligations arrived in 4.16.
- `owner-decisions-milestone-2.md:67` records the owner decision to fix last-leader scope-revocation bypass before the live pilot.

Concrete correction: add `"4.16"` to 7.1 `after` and the provider table. Clarify 7.10's test: security holds and successful access removal deny access immediately while handover remains pending; an ordinary last-responsible-leader scope removal may be refused `handover_required`, leaving the grant unchanged under the existing owner decision. The test must not claim that a refused revocation succeeded or silently change this recorded rule.

Exact failed rules:

- checks.dependencies / Needs: “The item builds it itself, or something in its `after` delivers it.”
- checks.set: “Every `after` is a real prerequisite, those in other epics included...” (missing semantic provider, despite a mechanically valid graph).
- checks.ticket: “Nothing contradicts the requirement source, its companions, the architecture, or a recorded decision.” (handover language needs the distinction above).

Root has accepted F1/F2 for correction. This review does not assert that those edits have already passed revalidation.

## Complete required-array assessment

| Rule | Result on the reviewed input |
| --- | --- |
| ticket 1: references/placeholders/assumptions | Pass; 47 paths/anchors checked, actual design inspected, policy defaults remain qualified. |
| ticket 2: no source/architecture/decision contradiction | Correction F2: precise refusal versus completed-revocation semantics. Other inspected boundaries align. |
| ticket 3: description/uncertainty/independent runnable check | Pass at inception; no premature full acceptance-criteria requirement. |
| ticket 4: unresolved Source conflict cannot be refined | Not applicable: no refined entries. The recap-owner typo has been corrected in documentation. |
| set 1: complete detailed requirement coverage | F1 needs an explicit implementation owner; otherwise all six Done when clauses and CAP-8 contributions are represented. |
| set 2: UX/architecture/constraints/integration | F1 needs the real fallback integration; other required normal navigation, backend, privacy, lifecycle and recovery paths are represented. |
| set 3: prerequisites/clean status/sequence notes | Mechanical status passes except the three pre-existing warnings; semantic provider correction F2 remains. Tracer and sequencing are documented as proposals in the companion. They must be copied/referenced into envelope Notes when the agreed breakdown is installed. |
| set 4: builder can derive criteria from epic/entry/references | Pass with the explicit gated unknowns; policy answers are not invented. |
| set 5: closing refactor sweep | Pass: 7.13 depends on 7.1–7.12, and only the closing suite follows. |
| dependencies Needs | F1/F2 as above. All referenced provider IDs otherwise exist. |
| dependencies Collisions | Pass: the added 7.3→7.4 and 7.6→7.7 edges produce one lane and eliminate unordered shared-code work. |
| dependencies Shared setup | F1 requires the earliest shared adapter owner. Other foundation/contract owners are identified. |
| dependencies Handoffs | F1 requires explicit 7.3 producer and 7.5/7.9 consumer descriptions. Existing meeting, task, identity, report-reference and aggregate handoffs are source-backed. |

## Suggestions, distinct from required corrections

1. The companion calls private-report authorization/lifecycle the least-certain integration but schedules it at 7.7. The resolved slicing rule says the least-certain slice follows the tracer. Explain this sequencing tradeoff in owner review, or move a complete report-permission slice earlier and revalidate dependencies. Owner checkpoints alone do not explain the order. Do not add a disconnected test or cross-epic architecture spike.
2. Keep the rationale for 14 entries and the offered 12-/11-entry groupings. Each grouping must preserve full behavior and be revalidated; the count alone is not a defect.
3. On canonical installation only, retain the tracer, collision-lane decisions and approved policy checkpoints in the epic Notes. The current unapproved proposal is correctly outside the runnable tree.

## Owner questions already correctly left open

- Q4: visitor fields/contact consent/provenance, youth safeguards, named report-care audiences, permitted assignee contact view, withdrawal/renewal process and each new store's retention/deletion/backup treatment.
- Q6: named leaders, pastoral reviewers, supervisors, restricted support operators, pilot participants and rollout.
- Source-specific report schedule: exact Africa/Lusaka clock and anchor, correction of meeting times, and not-held/unresolved reporting obligations. Existing approval of no quiet hours does not decide these values.
- Q8 metrics: historical roster anchor, percentage denominator, Excused/Unrecorded treatment, reporting period, completeness and definition version.
- Engineering decisions requiring explicit plans: attendance revision/snapshot granularity; absence and renewed-consent episode identity under permanent task uniqueness; report snapshot versus corrected-register display and correction transitions. These can remain gated unknowns at inception and do not justify fabricated live defaults.

## Boundaries positively verified

- A Pastor title, Admin-plus-Pastor, Media, a finance role or a practical task assignment does not confer report-care fields; 7.7 owns real scope registration and separate storage/API projections.
- Historical roster uses membership at effective meeting start, includes later transfers and accountless members, excludes later joiners, and marks uncertainty about corrected meeting times.
- All four attendance states and held/not-held/unrecorded/cancelled facts remain distinct; duty responses/notices cannot prove attendance.
- Source/purpose uniqueness is permanent; terminal tasks do not reopen, and new absence/consent episodes are an explicit design unknown.
- Missing-report reminders replace the generic task stream, with exactly the approved report-specific policy and real worker cancellation checks.
- Every personal-data story must ship its own current access, lifecycle/deletion, audit and safe-cache behavior; 7.10 is integrated composition, never delayed permission to omit hooks.
- Existing visual hierarchy and normal staff/mobile routes are retained, with obsolete premarked-Present, shared-testimony, offering and pretend-visit behavior explicitly excluded by the binding source.
- No approval, canonical tickets, deployment, acceptance completion or app implementation was performed in this validation.
