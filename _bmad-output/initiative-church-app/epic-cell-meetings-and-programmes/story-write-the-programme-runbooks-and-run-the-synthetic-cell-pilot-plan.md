---
title: 'Write the programme runbooks and run the synthetic cell pilot'
type: 'feature'
ticket: '10'
created: '2026-10-21'
status: 'in-review'
baseline_revision: '514f977'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/duties-guides.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Leaders and Admins have no guide, in the order they do the work, for schedules, programmes, revisions, notices and actual leaders. The cell loop has also not been rehearsed end to end with chat absent.

**Approach:**
- Write `docs/runbooks/cells-guides.md` in the duties-guides style: Admin; leader and assistant; what members see; the owner pilot.
- Add a local API rehearsal, `tools/identity-e2e/cells-pilot.mjs`, covering the ticket's verify line.
- Hand the staging pilot to Israel with a checklist for the results.

**Decisions:**
- Decision (agent, under owner pre-approval): as in story 4.13, the staging pilot is the owner's walkthrough. No script runs against staging, because this session has no staging credentials.
- Decision (agent, under owner pre-approval): "chat absent" is shown by checking for no chat table and no chat function. It also checks that no module the loop uses depends on the planned chat module, which the registry lists as optional.

## Boundaries & Constraints

**Always:** synthetic data; plain-language guides that link back to the story sections.

**Never:** a schema or client change; a script against staging.

</frozen-after-approval>

## Tasks & Acceptance

- [x] `docs/runbooks/cells-guides.md`
- [x] `tools/identity-e2e/cells-pilot.mjs` + offline test (8/8 local)
- [x] Runbook section; `evidence-5.10/owner-pilot.md`
- [ ] HITL: Israel runs the owner pilot on staging and records it (the verify line).

**Acceptance Criteria:**
- Given staging, when Israel follows the runbooks, then he confirms that:
  - a published programme creates responses;
  - a time change asks for fresh responses;
  - a Cannot attend notice changes no response or attendance;
  - a substitute is recorded as the actual leader;
  - nothing depends on chat.

## Implementation Notes

- Status `in-review`: everything except the owner's staging pilot is done. The story closes when `evidence-5.10/owner-pilot.md` is filled in.

## Review Triage Log
