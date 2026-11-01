# Review and ticket validation — 30 October 2026

## BMAD route and completion boundary

The repository-rendered `bmad-build` oneshot workflow is used for documentation/evidence
reconciliation under the 6.15 plan. Its pinned **quick** lens ran in an independent,
context-free reviewer session against the complete unified diff from main
`c96cd562b2650c37f5d3d879cb12891419700139`, including untracked work and complete evidence.
The optional deeper runtime code-review lenses were not run: this branch changes no app
runtime, database migration, dependency or public API. A separate independent BMAD
ticket/set/dependency review validates the Epic 7 proposal.

The user's explicit requirement to leave owner acceptance open governs completion.
Preparing and reviewing these artifacts does not mark the whole 6.15 story built/done;
its plan remains **in-progress**. 6.17 remains **planned** behind 6.15, 6.16 and 5.12.

## Context-free quick findings and root triage

| Finding | Source evidence checked | Root verdict and correction |
| --- | --- | --- |
| The manager-revocation race attempted to remove the only reachable department leader, so the provider change would not commit | `duties_report_handover`, `duties_has_reachable_leader` and `identity_revoke_scope` deliberately refuse/roll back the last-responsible removal; Admin alone is not a department scope | **Medium; patched.** Establish Peter's explicit active reachable deputy scope before the case, require actual successful revocation and distinguish `handover_required` refusal from access denial. |
| UI-04 expected a future Sunday list to be visible immediately | `content_this_sunday`, the public read and `PublicSundayHymns.idsFor` select/match the current church week; Home has its additional weekend window | **Medium; patched.** Read and use the server's current Sunday, require device-week agreement, and leave future/weekend-positive cases unverified until applicable. |

Both are procedure defects exposed by this change, not newly discovered application bugs.
No required quick finding was deferred or rejected. The corrected walkthrough remains
**authored only**; code review does not execute its pilot or concurrency scenarios.
The same independent reviewer rechecked both source-based corrections and returned no
remaining findings on those fixes.

## Additional independent procedure audit

The earlier source audit also corrected the following before the quick review:

| Procedure issue | Disposition |
| --- | --- |
| Assignment UUID from the member route used as occurrence lock UUID | Medium, patched with an exact assignment → slot → occurrence lookup. |
| Any waiting transaction could be mistaken for the test's blocked sender | Medium, patched with the recorded holder PID and exact advisory waiter relation. |
| Manager revocation used the member/assignee route | Medium, patched with separate staff rota and mobile duty paths. |
| Several staff navigation labels differed from the actual app | Medium, patched from current People, Cells, Duties and Content routes. |
| Department fixture lacked its required synthetic prefix | Medium, patched to `SYNTHETIC Preaching Rota`. |
| Local WEB positive setup was not concrete | Medium, patched with the existing local `web` fixture and ordinary rights/import/publish UI; production policy remains separate. |
| SAMPLE Giving inputs were incomplete | Medium, patched with valid fictional non-payable values and honest verification text; no live transaction. |
| Sunday Home check implied device-time changes alone were sufficient | Low, patched to require server/device week agreement. |
| Aggregate runner can miss a separately installed Chrome | Low, patched with the explicit browser-contract fallback and preserved `UNRUN` record. |

No runtime test was claimed by that audit. The formal quick review then found the two
additional fixture issues above, demonstrating why an authored test procedure also
needs source review.

## Actual real-tree ticket check

Executed from the repository:

```bash
python3 .agents/skills/bmad-ticket/scripts/tickets.py \
  --project-root /workspace/scratch/308c700530ee/church-app \
  status _bmad-output/initiative-church-app
python3 .agents/skills/bmad-ticket/scripts/tickets.py \
  --project-root /workspace/scratch/308c700530ee/church-app \
  find _bmad-output/initiative-church-app 6.15
python3 .agents/skills/bmad-ticket/scripts/tickets.py \
  --project-root /workspace/scratch/308c700530ee/church-app \
  find _bmad-output/initiative-church-app 6.17
```

Exit 0: 84 known entries; 50 done, 26 review, 7 in-progress and 1 planned. No
`unpinned_after`, `undeclared_after` or `order_conflict`. 6.15 is in-progress and 6.17 is
planned as intended. The proposal filename leaves Epic 7 outside the real runnable tree.

Three **pre-existing** metadata warnings remain: `story-f1-giving-admin-tenure-plan.md`,
`story-f2-church-owned-images-plan.md` and `story-f3-delete-unreferenced-uploads-plan.md`
have empty ticket IDs and no registered leaf, so the status tool skips those plans.
This is not a new Epic 7 error or proof that their already built code is absent. No new
IDs or acceptance states were invented to make the output appear globally clean.

The final copied-tree Epic 7 result, reviewed hashes and full source/dependency analysis
are in [its validation evidence](../../epic-cell-attendance-and-private-reports/evidence-inception-2026-10-30/README.md).
