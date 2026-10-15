---
title: 'Write the duties runbooks and run the synthetic department pilot'
type: 'chore'
ticket: '13'
created: '2026-10-15'
status: 'in-progress'
baseline_revision: '9ae2b6762c56772ad5bd75aadaafadd805d3375b'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
  - '{project-root}/_bmad-output/initiative-church-app/spec-church-app/delivery-and-decisions.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The duties runbooks are written per story for maintainers; a department leader, a deputy or an Admin cannot follow them task by task, nobody has a guide for duty reminder problems, and the full publish → remind → response → visible gap → direct contact → confirmation loop has never been rehearsed end to end with `SYNTHETIC Preaching Rota`, an app member and an accountless member.

**Approach:** Add task-ordered, plain-language guides for leaders and deputies, for Admins and for duty reminder troubleshooting (linking the per-story sections), a repeatable synthetic pilot rehearsal script (`tools/identity-e2e/duties-pilot.mjs`, API only for the loop, local by default and staging behind an explicit target) with an offline test, and an owner walkthrough checklist for the HITL staging step.

**Decisions:**
- Decision (agent, under owner pre-approval): the guides live in one new file, `docs/runbooks/duties-guides.md` (leader and deputy, Admin, troubleshooting, owner walkthrough); `duties.md` keeps every per-story section and gains a pointer and a story 4.13 section; `follow-ups.md`, `identity-access.md` and `contracts-and-owner-seams.md` gain one link each. No per-story section is moved or rewritten.
- Decision (agent, under owner pre-approval): the server judges Short notice by lead time, not by weekday, so the rehearsal's "short-notice Sunday assignment" is a one-off duty starting three hours after the run with no answer-by time (the same-day case); a run cannot be both repeatable on any day and on a Sunday. The owner walkthrough does the same on staging.
- Decision (agent, under owner pre-approval): "no stale reminder reaches the replaced assignee" is proven with a probe duty whose creator-set reminder falls due minutes after the reassignment; the new assignee receiving the same reminder is the positive control. Locally the due time is moved forward with SQL (test-only); on staging the run waits for the scheduled worker.
- Decision (agent, under owner pre-approval): staging mode uses the publishable key and synthetic accounts only (no secret or service-role key, no SQL), refuses any origin but the staging project, keeps persona passwords in a state file outside the repository, and cleans up through the API (cancel the run's duties, remove its members from the department, revoke its leader scope); it writes the SQL that removes the run's remaining rows for the parent session. The department is found or created and never deleted through the API.
- Decision (agent, under owner pre-approval): fictional numbers: local `+44 7700 900410-900419`; staging `+1 202 555 0166-0168` (personas) and `0159` (the accountless member's household route); both grepped unused.

## Boundaries & Constraints

**Always:** SYNTHETIC names and fictional numbers only; the loop runs through the public API (Auth, Data API) in both modes; evidence is redacted JSONL (no token, password, number, note or reason); the run removes what it created; plain-language guides with no private data or secrets; fixed church-time dates in offline tests.

**Never:** SMS; secrets in the repository; running the rehearsal against staging from this build; touching hosted Supabase, GitHub or production; editing a merged migration, a hand-pasted function or a frozen block; a code change the rehearsal does not need.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Local run | reset local stack, phone switch on | every check passes; cleanup leaves no pilot row | a failed check sets exit 1, cleanup still runs |
| Staging run | `DUTIES_PILOT_TARGET=staging`, publishable key, Admin and state files outside the repo | the same loop through the API, waiting for the scheduled worker; API cleanup and a cleanup SQL file | a non-staging origin, a non-publishable key or a state file inside the repo is refused before any call |
| Wrong target | any other target value, or a non-fictional number | refused before any call | thrown error, exit 1 |
| Non-leader | member reads the board, coverage, rota | 403; My duties and inbox items hold no leader note, reason or route | check fails |

</frozen-after-approval>

## Code Map

- `tools/identity-e2e/harness.mjs` -- local origin guard, `localKey`, `psql`, `startRun`, `localHttp`, `runMain` (reuse; unchanged).
- `tools/identity-e2e/staging-suite.mjs` -- `STAGING_ORIGIN`, `ADMIN_PHONE`, `assertStagingOrigin`, `assertPublishableKey`, `assertStateOutsideRepo`, `redactEvidence`, `makePacer` (reuse by import; unchanged); persona sign-up, application and approval pattern.
- `tools/identity-e2e/duties-coverage.mjs` -- the closest model: worker credential and `tools/notifications/worker.mjs run-once`, contact attempt, Confirmed by leader, `holdsPrivate`, SQL cleanup.
- `tools/identity-e2e/duties-reminders.mjs` -- job summaries, the stale-job query, moving due jobs forward (test-only).
- `tools/identity-e2e/duties-lifecycle.mjs` -- the fullest SQL cleanup list (duties, follow-ups, notifications, identity rows).
- Commands and reads (unchanged): `api.duties_command` (`create_department`, `add_member`, `create_series`, `assign_slot`, `publish_drafts`, `publish_duty`, `respond`, `record_contact_attempt`, `confirm_by_leader`, `cancel_series`, `cancel_position`, `remove_member`), `api.identity_review_command` (`identity.create_member`), `api.identity_grant_command`, `api.duties_rota`, `api.duties_leader_board`, `api.duties_coverage`, `api.duties_my_duties`, `api.duties_admin_overview`, `api.notifications_my_inbox`, `api.notifications_open_item`, `api.followups_task`.
- Runbooks: `docs/runbooks/duties.md` (stories 4.1-4.12), `follow-ups.md`, `identity-access.md`, `contracts-and-owner-seams.md`, `notifications.md` (story 3.8 Reminder health).
- CI: `.github/workflows/ci.yml` (node tool tests, the per-story evidence scan steps).

## Tasks & Acceptance

**Execution:**
- [ ] `tools/identity-e2e/duties-pilot.mjs` -- the rehearsal: personas, quarterly rota, worker delivery, answers, gap, contact, Confirmed by leader, Short notice, reassignment probe, privacy, API cleanup; local SQL checks and cleanup; staging mode.
- [ ] `tools/identity-e2e/duties-pilot.test.mjs` -- offline: target parsing and guards, church dates (fixed instants), rota and probe placement, privacy and generic-text detectors, cleanup SQL builder.
- [ ] `docs/runbooks/duties-guides.md` -- leader/deputy, Admin and troubleshooting guides, owner walkthrough.
- [ ] `docs/runbooks/duties.md`, `follow-ups.md`, `identity-access.md`, `contracts-and-owner-seams.md` -- pointers; story 4.13 section (runs, staging command, cleanup).
- [ ] `_bmad-output/.../evidence-4.13/` -- owner walkthrough with blanks, local run evidence, suite summary; CI scan step.

**Acceptance Criteria:**
- Given a reset local stack, when `duties-pilot.mjs` runs, then the whole loop passes and nothing of the run is left.
- Given the guides, when a leader, a deputy or an Admin follows a task, then each step names the screen and button and links the maintainer section.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-pilot` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, `dart test` in `packages/contracts/dart`, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan of `evidence-4.13/` -- expected: clean.

**Manual checks (if no CLI):**
- HITL (open, owner): Israel's staging walkthrough, `evidence-4.13/owner-walkthrough.md`.
