---
title: 'Reconcile the media and giving runbooks and prepare the owner content pilot'
type: 'chore'
ticket: 15
created: '2026-10-30'
status: 'in-progress'
baseline_revision: 'c96cd562b2650c37f5d3d879cb12891419700139'
route: 'oneshot'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/spec-church-app/design-contract.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 6 is merged, but its acceptance instructions mix superseded scope and historical staging observations with current work. A church owner cannot safely determine what to demonstrate, what has passed, or whether an old migration instruction should still be executed.

**Approach:** Reconcile the existing runbooks and evidence with the current main commit and later owner decisions, prepare a coherent normal-app pilot for guests, members and leaders, and run every supported check. Record implementation gaps separately from unverified workflows. Keep device checks, current staging verification, policy approvals and production promotion open; the user has authorised branch commits and pushes, not deployment, gate approval or acceptance completion.

</frozen-after-approval>

## Implementation Notes

- 2026-10-30: The oneshot route covers documentation/evidence reconciliation and runnable acceptance preparation; no application-code change has been identified by the initial source audit. If a material product defect is established, give it a separate investigated build plan rather than hiding it as a manual-test limitation.
- Base verified from a fresh clone: main `c96cd562b2650c37f5d3d879cb12891419700139`, tree `6f7a62d931683c680cbb0bafb3fa52e12b912621`. Working branch: `acceptance/epic-6-reconcile-epic-7-plan`; no pre-existing local changes.
- BMAD renderer initially failed to fetch Jinja2 in the restricted execution sandbox. The unchanged renderer succeeded through the supported permission escalation and produced `_bmad/render/bmad-build/church-app-bdbd976fec6f/e4ba5eb60bcf887ef0d2/workflow.md`. No workflow source was substituted. Config/store/customization were resolved using the repository scripts; the existing initiative is passed explicitly to ticket commands because no local active-initiative setting is present.
- Later owner decisions replace background audio with YouTube/Facebook video links, ship the official hymn book in the app, and permit church-owned images under the recorded exemption. These decisions govern the pilot. Original historical evidence remains attributed to its commit/environment.
- Reconcile `pr-description.md`, `codex-handoff-prompt.md`, `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md` and the Epic 6 envelope/ticket acceptance wording. Add an owner walkthrough, evidence ledger and exact-head migration manifest beside the Epic 6 release evidence. Use the existing app navigation and design-system components; this preparation changes no screen or token.
- Required useful outcomes: discover/read/search public content; publish/replace/withdraw with recovery; personal favourites and Sunday hymns; capacity-controlled RSVP and calendar export; current-role/stale-session denials; two-person giving verification and honest external handoff; own-only Calendar overlays and duty-to-Media draft; restart/offline/slow-media behavior. Each walkthrough step names role, setup, expected result and evidence.
- Keep the accepted persistent public-upload take-back failure/process-death residual visible. Historical RSVP and retention integration results are evidence of their recorded revisions, not a substitute for the candidate's affected checks. Two-session sermon-duty lock contention remains a specific evidence gap until actually run.
- The remaining human-in-the-loop pilot makes this story `in-progress`; completing its preparation does not mark the whole story `built` or `done`. Story 6.17 and production approval stay open. Epic 7 inception can proceed independently after this reconciliation without treating Epic 6 as accepted.

## Plan Change Log

## Review Triage Log

## Verification

- Execute the available CI-equivalent commands from `.github/workflows/ci.yml` and `tools/ci/run-local-ci.sh` only where their dependencies are present and the database is demonstrably isolated. Record command, full commit, environment/toolchain, date, exit/counts, evidence path and `run-passed`, `run-failed`, `blocked`, `skipped` or `authored only`.
- Run the BMAD ticket status/find tools and validate edited TOML/reference paths. Scan new evidence for credentials and personal data; inspect `git diff --check` and the final branch diff.
- Cross-check every current runbook assertion against later code/evidence. Verify applied-row history read-only before any further action; a stale paragraph does not authorise replay.
- Independently review the changes against this intent and the user's handoff. Do not turn source review, widget tests, old hosted CI, or written device instructions into claims of a witnessed normal-app/device pilot.
