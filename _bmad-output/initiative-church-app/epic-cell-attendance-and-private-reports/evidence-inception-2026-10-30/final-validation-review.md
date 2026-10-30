# Independent final validation — unapproved Epic 7 proposal

Date: 2026-10-30.

## Result

**The corrected inception proposal is suitable to present for owner review. The two required findings from the first independent review are resolved in the proposal. No new required mechanical, dependency or capability-coverage corrections were found.**

This is document and dependency validation of an unapproved plan. It is not approval of the breakdown, its sequencing, unresolved policies, application behavior, deployment or acceptance. The sequencing suggestion below remains explicitly for the owner. There is still no canonical Epic 7 `tickets.toml` in the real repository.

## Inputs and reproducibility

The current frozen repository files were read directly; the earlier `/tmp/church-app-epic7-validation-input.txt` was not reused as the corrected draft.

Repository: `/workspace/scratch/308c700530ee/church-app`.

Reviewed files and SHA-256:

| File | SHA-256 |
| --- | --- |
| `tickets.proposed.toml` | `d5545493bb8dbf3e34a1f0596a98bf8736b159447c9aef0d4bd5436c9c5ed01b` |
| `inception-proposal-2026-10-30.md` | `4338150da3e497e10719f7132f0a5f5780ae078560e2f95878823d44662e354c` |
| `epic-cell-attendance-and-private-reports.md` | `25aa10104438f668a0706d438c2a32cb6df6d917169f3607178ae1cab0d7e8b4` |

All three remained unchanged at the final verification.

A fresh copy of the entire initiative, including every completed child, was placed at:

`/tmp/church-app-epic7-final-validation-z916rrim/initiative-church-app`

The proposed TOML was installed as `tickets.toml` only inside that disposable copy. The repository's actual status checker ran from the repository with:

```text
python3 .agents/skills/bmad-ticket/scripts/tickets.py status /tmp/church-app-epic7-final-validation-z916rrim/initiative-church-app/epic-cell-attendance-and-private-reports
```

Evidence in this review directory:

- `ticket-status.json` — full formal status output.
- `reference-check.json` — all 57 entry references and all 18 companion Markdown links, including anchor checks.
- `dependency-check.json` — direct provider pins, consumer handoffs, all-pairs ordering and final sweep/suite checks.
- `review-metadata.json` — repository HEAD, hashes, copy location and proof that the real canonical Epic 7 file is absent.
- `final-validation-summary.json` — compact machine-readable outcome.

## Mechanical results

The status command exited 0 and reported:

- 14 planned entries; no refined or executable leaf artifacts.
- A single longest chain: 7.1 → 7.2 → 7.3 → 7.4 → 7.5 → 7.6 → 7.7 → 7.8 → 7.9 → 7.10 → 7.11 → 7.12 → 7.13 → 7.14.
- Empty `unpinned_after`, `undeclared_after` and `order_conflict` arrays; no cycle or drift reported.
- Only the three previously identified Epic 6 F1/F2/F3 plan ticket-id metadata warnings. These were preserved in the copied tree and are not new Epic 7 findings.

All 57 entry references and all 18 companion Markdown links resolve, including their named anchors. All provider entry IDs exist. There are no unordered pairs of Epic 7 entries, so the shared Cells schema, dispatcher, repositories and navigation have one implementation lane. Every entry carries description, uncertainty, verification, risk and CAP-8 traceability; the 13 high-risk entries have independent checks. The closing refactor follows all preceding work, and the closing suite follows the refactor.

## Revalidation of the required findings

### F1 — Shared Follow-ups direct-contact fallback: resolved in the proposal

The corrected 7.3 now explicitly owns implementation of the missing shared Follow-ups adapter and a real leader-visible response through the existing supervision/routing workflow. Its verification includes accountless and security-held task recipients, real worker retries, safe attributed action, deduplication, current-source checks and cancellation. It does not claim that provider 3.5 already supplies the application behavior.

Entries 7.5 and 7.9 explicitly name 7.3's output and directly depend on 7.3. The companion explains why the source-specific report schedule's lack of a generic supervisor alert makes this fallback necessary. It preserves unresolved accountable work when no eligible leader can act, without exposing care context to an Admin metadata route or restoring a held recipient's access.

The actual contracts were rechecked:

- `supabase/migrations/20261008135811_notifications_routing.sql`, `app.contract_register_direct_contact_route`, requires registration by the source owner and validates the handler under that owner's module.
- `supabase/migrations/20261014130535_followups_reminders.sql` registers `followups_task` and `followups_supervision` under Follow-ups, and separates owner versus supervisor recipient checks.
- `docs/runbooks/follow-ups.md:153` documents the current missing route; its source-specific schedule section disables the generic supervisor alert for missing reports.
- `docs/runbooks/contracts-and-owner-seams.md`, Direct-contact routes, requires idempotence on `need_id`, a leader-visible need, safe generic data and no use of a relative's contact number as an automatic notification destination.

The proposal's “shared Follow-ups adapter” is consistent with those ownership rules. Implementation must keep registration within Follow-ups; the review has not treated this as a Cells-owned registration of someone else's source type. The existing Notifications needs/route contract and canonical task remain authoritative.

Previously failed checks.set coverage/integration and checks.dependencies Needs, Shared setup and Handoffs now pass for this correction.

### F2 — Revocation handover provider and truthful result semantics: resolved in the proposal

Entry 7.1 directly pins `4.16`, and 7.10 also pins it explicitly. The provider table identifies the actual `identity_revoked_scope()` and revocation/unlink handover collection supplied by that entry. This prerequisite is available before per-story lifecycle behavior begins.

The corrected 7.10 and companion distinguish:

1. An ordinary last-responsible-leader scope removal refused with `handover_required`, whose grant change rolls back and whose UI must report the refusal.
2. Approved handover followed by a successful retry.
3. A successful revocation, applied security hold or successful account unlink, after which access is denied even when handover work remains pending.

This matches `supabase/migrations/20261015190139_duties_owner_decisions.sql:1178–1196` and its account-unlink branch, together with `docs/runbooks/duties.md`, Decision 10. The existing Cells handover function in `20261021122802_cells_transfer_effects.sql` uses the 4.16 helper. The proposal does not assume every unlink succeeds, bypass the last-Admin protection, silently override the recorded owner rule, or report a refused revocation as completed.

Previously failed checks.dependencies Needs and the ticket source-consistency concern now pass for this correction.

## Full required-check matrix

| Required check | Final assessment |
| --- | --- |
| ticket: every reference exists, no placeholder, assumptions marked | Pass. Paths/anchors are mechanically verified; the actual two design references were inspected in the independent review. Policy and engineering uncertainties remain explicit. |
| ticket: no source, architecture or recorded-decision contradiction | Pass. Corrected handover semantics agree with the actual provider; private care grants, meeting observations, task uniqueness and report scheduling remain source-consistent. |
| ticket: description, known uncertainty, runnable independent verification | Pass at inception. Each entry provides these; no full Given/When/Then is required because there is no bug, refined entry or standalone ticket. |
| ticket: unresolved source conflict cannot carry refined status | Not applicable. No entry is refined. The documented attendance/recap owner typo has been corrected, with no remaining claim that Epic 7 publishes recaps. |
| set: complete requirement coverage with valid covers IDs | Pass for proposal scope. CAP-8 exists; each entry states its contribution, and the six Done when clauses are accounted for. |
| set: UX, architecture, constraints and integration | Pass. Normal staff/mobile paths, private field boundaries, backend persistence, safe metadata, reminders/fallback, correction/concurrency, lifecycle and recovery have implementation owners. |
| set: genuine prerequisites, clean status and sequence notes | Pass for the unapproved proposal. Formal status has no new Epic 7 problem; 4.16 and adapter handoffs are explicit. The companion holds proposed tracer/sequencing decisions; adoption into epic Notes remains an owner-controlled installation step. |
| set: enough source to derive story criteria | Pass. The epic, entry and references define behavior; unresolved policy choices gate affected work instead of becoming fabricated defaults. |
| set: refactor after prior work | Pass. 7.13 follows 7.1–7.12; 7.14 is the one closing suite. |
| dependencies: Needs | Pass. Referenced providers exist; missing fallback is now built by its earliest consumer; required revocation helper is pinned at 7.1. |
| dependencies: Collisions | Pass. No unordered Epic 7 entry pairs remain; the rationale for collision edges is explicit. |
| dependencies: Shared setup | Pass. 7.3 owns the shared fallback; later consumers name and depend on it. Existing identity, meeting, task, notification and client foundations remain reused. |
| dependencies: Handoffs | Pass. Producer and consumer descriptions name the corrected fallback, alongside existing meeting, task, joining and downstream aggregate/reference outputs. |

## Capability and safety boundaries retained

- Attendance retains historical membership at the effective meeting start, accountless members, later transfers, four separate states and attributed corrections. Corrected-time roster handling remains an explicit decision, not an accidental current-roster query.
- Absence flags require three recorded consecutive held-meeting absences. Missing evidence requires review; duty responses and Cannot attend notices cannot supply actual attendance.
- Name-only visitors, optional agreed contact details, consent provenance, withdrawal, renewed consent and reviewed identity-preserving joining are covered on both clients. Shared phones do not auto-link identities.
- Report-care access requires real registered scopes. A Pastor title, Admin-plus-Pastor without that scope, Media or practical task ownership does not expose private fields.
- Metadata, private report fields and later recap publication remain separate. Downstream recap, visit and service implementations remain with their own epics.
- Source/purpose uniqueness is permanent. Terminal tasks cannot be reopened with a new request ID; absence and consent episode identity stays an explicit engineering decision.
- Missing-report reminders replace the generic stream. Exact day-after/day-three clock values, meeting-state treatment and corrected-time handling remain policy questions; no quiet hours is already decided.
- Every personal-data story owns current access, lifecycle/handover/deletion, audit and private-state clearing as it ships. 7.10 verifies composition and cannot justify earlier omissions.
- The proposal preserves the inspected design hierarchy while applying binding corrections for unrecorded attendance, private reports, role-aware routing, real actions and recoverable state.
- The release entry preserves actual migration ordering and explicit owner release approval; the proposal neither adds a whole-Epic-6 feature dependency nor claims deployment or acceptance.

## Suggestions and owner choices — not approved by validation

### Sequencing suggestion remains explicit

The updated proposal moves the joint report-care authority, field-separation and lifecycle contract review to the first 7.1 planning checkpoint. That addresses late discovery of a shared policy or authority conflict. Report implementation remains at 7.7 after the attendance/visitor contracts, with the rationale recorded.

The resolved slicing guidance still says the least-certain slice follows the tracer. An early contract review is not the same as executing that uncertain implementation slice second. The owner should explicitly accept this sequencing tradeoff or request a complete earlier report-permission slice and a revalidated graph. This review does not silently approve the exception. No disconnected spike is required.

### Other owner questions remain genuinely unresolved

- Whether to retain 14 entries or approve a proposed grouping while preserving every requirement and check.
- Q4 visitor contact fields and consent evidence, youth safeguards, report-care readership, permitted assignee context, renewed consent, and new-store retention/deletion/backup handling.
- Q6 named pilot leaders, reviewers, supervisors, restricted support operators and rollout order.
- Exact source-specific report deadline clock/anchor and not-held/unresolved meeting obligations; approved Africa/Lusaka and no quiet hours do not settle these values.
- Q8 denominators, Excused/Unrecorded treatment, coverage, comparison period and metric-definition versions.
- Proposed plan/done checkpoints and the supported owner/device walkthrough.

Engineering choices such as row versus aggregate revisions, episode identity and report snapshot versus current corrected attendance must be recorded before the affected build. They remain valid gated unknowns at inception.

## Execution boundary

No app source, real-tree canonical ticket, approval, deployment, notification send or acceptance status was changed. The only writes by this independent reviewer are disposable copies and validation evidence under `/tmp`. Future feature, device, scheduler and lifecycle tests described by the entries have not been run as part of this document review.
