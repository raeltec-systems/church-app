---
title: 'Verify cell programmes end to end and promote them to production'
type: 'release'
ticket: '12'
created: '2026-10-21'
status: 'blocked'
baseline_revision: '80c4b47'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/production-promotion-cells.md'
  - '{project-root}/docs/runbooks/production-promotion-duties.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 5's workflows exist on staging. Production does not have them yet, and no closing evidence covers the whole programme loop.

**Approach:**
- Run the closing local suite: clean builds of both clients, every cells, duties and lifecycle E2E, pgTAP and the client tests.
- Have an independent reviewer rerun the safe-projection, material-revision and old-cell access cases.
- Prepare the production runbook.
- Israel then witnesses the demonstration, decides Q4 and the pilot leaders, and runs the promotion himself, after 4.15.

**Decisions:**
- Decision (agent, under owner pre-approval):
  - While 4.15 (Duties in production), Israel's Q4 decision and the named pilot leaders are missing, this entry delivers staging and local evidence and stays open (the ticket's unknown).
  - Production is promoted by the owner only. Nothing here touches production.

## Boundaries & Constraints

**Always:** synthetic data; gates fail closed; the evidence is redacted.

**Never:** a production change from this session.

</frozen-after-approval>

## Tasks & Acceptance

- [x] `docs/runbooks/production-promotion-cells.md` (prepared, not executed)
- [ ] Closing local suite (`evidence-5.12/closing-suite-summary.txt`)
- [ ] Independent reviewer reruns of safe projection, material revision and old-cell access (`evidence-5.12/external-check.md`)
- [ ] HITL: Israel witnesses the mobile and staff demonstration on staging (with the 5.10 owner pilot and the 5.x owner checks)
- [ ] HITL: 4.15 promoted; Israel's Q4 decision and pilot leaders; Israel promotes epic 5 and follows the runbook

**Acceptance Criteria:**
- Given clean builds of both clients:
  - they pass the integrated programme scenarios (AC-02, AC-10, AC-13, AC-14, AC-15) and the independent reviewer's reruns;
  - Israel witnesses the demonstration;
  - production shows the deployed workflows, with the unapproved gates visibly disabled.

## Implementation Notes

## Review Triage Log
