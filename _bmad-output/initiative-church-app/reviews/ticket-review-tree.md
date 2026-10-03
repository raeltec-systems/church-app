# Independent ticket-tree review

Date: 2026-10-03

Verdict: **PASS — no remaining semantic draft blockers.** No ticket contracts were changed by this review.

## Reviewed scope

Reviewed the initiative, its `tickets.toml`, all 16 epic envelopes, the current spec kernel, design contract, delivery/decision register, acceptance map and adopted architecture. A delegated read-only coverage audit read the complete functional requirements and all 16 envelopes and independently reported no functional coverage blocker. Applied the tree/dependency checks and relevant workflow rules supplied in `work/ticket-church-app/tree-checks.json`. The separately assigned platform reviewer owns detailed validation of its 12-story breakdown.

## Coverage and boundaries

- CAP-1/2 → epic 6; CAP-3/4 → epic 2; CAP-5/6 → epic 4; CAP-7 → epic 3; CAP-8 → epic 7; CAP-9 → epic 5; CAP-10 → epic 8; CAP-11 → epic 9; CAP-12 → epics 12/14; CAP-13 → epic 13; CAP-14 → epic 10; CAP-15 → epic 11; CAP-16 → epics 2/14; conditional CAP-17 → epic 15.
- Shared coverage has an explained division: identity/access versus final client composition for CAP-16; service/cell metric definitions and calculations versus the final independently authorized pastoral overview for CAP-12. Epic 16 owns assembled release evidence, distribution and operational handover, rather than a duplicate domain implementation.
- Nonempty `covers` entries resolve directly to current parent CAP IDs, and future envelopes introduce no unmapped local requirement IDs. The opening epic deliberately has empty CAP coverage; each P1–P10 requirement names its source sections. Its synthetic provider/substrate work does not claim completion of production CAP-3/4/16.
- All six approved additions remain in scope. Milestone 1 is explicitly split between platform and identity/access by the user's recorded decision; milestones 2–7 retain the source order and outcomes. November 2026 remains a target, not an invented capacity forecast.
- Architecture units have accountable owners: Identity (2); Duties and Follow-ups (4); Notifications (3); Cells membership (2), meeting/programme kernel (5), attendance/reports (7), recaps (8); Content (6); Care (9); Prayer (10); Directory (11); Services (12); Offerings (13); optional Chat (15). Shared client composition is 14, platform/operations foundations are 1, and release operation is 16. Consumed SDKs/providers, hosting, CI, backups, media, email and distribution services are assigned touch points in the initiative.
- Safe report/recap separation, person-versus-account distinction, no-SMS recovery, current access, accountless participation, prayer anonymity, honest observed metrics, independent custody, instruction-only public giving and nonpersistent private client state remain assigned and source-bound. No detailed functional rule was found explicitly excluded or assigned to no owner.

## Dependencies and shared setup

- Platform is first and owns schema/command/access seams, source-purpose-event fixtures, provider feasibility, client/framework trial, test tooling and environment/journal substrate. AD-1–AD-20 remain the home for decisions binding multiple epics; consumers must use those contracts.
- Notifications runtime precedes the one Follow-ups registry. Its source adapters can be verified synthetically, and feature owners explicitly add real source effects before activation. This avoids a runtime/task-registry cycle or competing tracker.
- Epic 5 supplies canonical Cells meeting IDs, recurrence and actual programme leaders before attendance/reports, recaps and Offerings consume them. Duties does not generate a second cell calendar. The Cells split is sequenced through actual provider contracts.
- Counts consumes Content event references and Cells aggregate projections. It does not depend on later finance. Epic 14 composes Care/Offerings sections after their owner projections exist, which avoids an overview/finance cycle.
- Handoffs state required outputs and providers in the initiative manifest and consuming envelopes, with producer scope describing the corresponding owner operations. Narrow contracts permit unrelated producer work to continue. Future inception must pin the exact provider entries, as the initiative explicitly requires.
- Shared setup has an earliest owner. Current executable platform lanes are separately reviewed; future envelopes are intentionally not executable story sets. Their requirement to sequence shared route/schema/contract edits before concurrent execution is recorded. No concrete unowned setup, required backward dependency or current executable collision was found at this altitude.
- No required epic or release dependency points to Chat. If selected, Chat's own gates and evidence are explicitly added to release acceptance; disabled Chat is not claimed as delivered.

## Envelopes, verification and gates

Every epic has an outcome, requirements/upstream coverage, boundaries, references and five or six Done-when checks (platform and most feature epics have six). Each includes production delivery and integrated verification. Feature epics own their required staff/mobile actions as they land; epic 14 does not defer all staff work until milestone 6. Only platform is incepted. The other 15 remain envelopes, with no demand for premature detailed specs or story sets.

The Q1–Q12 register remains authoritative. Envelopes preserve affected policy/provider gates, synthetic preparation, framework trial, rights/destination checks, safeguarding/retention, care/recap consent, count definitions, custody controls and operational acceptance. None promotes sample values or provisional targets to approved policy. The 23 compound launch checks and detailed edge cases remain release obligations, including native/provider evidence and database-plus-object restoration with independent deletion/revocation reconciliation.

## Mechanical evidence

Ran from `/workspace/church-app`:

```text
UV_CACHE_DIR=/workspace/work/uv-cache uv run .agents/skills/bmad-ticket/scripts/tickets.py --project-root /workspace/church-app status _bmad-output/initiative-church-app
```

Exit 0. It reports 16 epics, 12 planned platform stories, and empty `unpinned_after`, `undeclared_after` and `order_conflict` arrays. Filesystem enumeration finds only the initiative and platform `tickets.toml` files; no loose leaf tickets or premature future breakdowns.

This is ticket-draft validation. It does not establish application, provider, policy, store or production acceptance.
