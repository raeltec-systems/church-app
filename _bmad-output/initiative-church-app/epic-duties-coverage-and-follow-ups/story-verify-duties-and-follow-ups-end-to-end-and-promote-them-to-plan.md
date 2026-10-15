---
title: 'Verify duties and follow-ups end to end and promote them to production'
type: 'chore'
ticket: '15'
created: '2026-10-15'
status: 'in-progress'
blocked_reason: ''
baseline_revision: '4ca9fe25a7fbec0f4b882ceb83f5997fc3cc891c'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context: ['{project-root}/docs/runbooks/duties.md', '{project-root}/docs/runbooks/production-promotion-identity.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 4.1-4.14 and 4.16 proved Duties and Follow-ups story by story (local E2Es with SQL, spot checks on staging and the 4.13 pilot), but there is no closing run of the integrated scenarios and the role and scope permission matrix that also runs on staging through the API alone, no clean client builds of the final code for the owner's demonstration, and no production package for the epic 3 and epic 4 approvals and the pilot department.

**Approach:** Add an API-only closing suite (`tools/identity-e2e/duties-staging-suite.mjs`) with a local target and a staging target (publishable key only, state outside the repo, synthetic data, cleanup SQL), on the 2.14 and 4.13 patterns; build the staff web and APK for staging; write the owner demonstration and `docs/runbooks/production-promotion-duties.md`; leave the staging runs, the witness, the merge, the promotion and the approvals to the parent session and the owner (`blocked`).

Decision (agent, under owner pre-approval): production is not touched. The owner merges PR #6 and runs **promote** himself after the epic (owner decision 2026-10-15); this entry delivers staging evidence and a documented package, as the ticket's `unknown` says.

Decision (agent, under owner pre-approval): the builder does not run the suite on staging; the parent session does (brief). The local target and `--staging-path` (the staging route on the local stack, cleanup SQL executed and checked), and a two-run `--rerun-state` rehearsal, prove the staging branch.

Decision (agent, under owner pre-approval): the staging people use `+1 202 555 0153-0158` (grepped: only local suites and pgTAP use them; the identity suite, the pilot and the owner's block 0170-0179 do not) and the pilot's SYNTHETIC household number 0159 as a contact route. Pastor, no-access, held, deactivated and the cell leader are the 2.14 identity suite's staging personas, only signed in, so no further numbers are consumed and the identity suite's matrix is unchanged. Local: `+44 7700 900540-900549, 900580-900582` (unused before).

Decision (agent, under owner pre-approval): command probes in the matrix carry a stale expected revision so nothing changes; expected answers are derived from the SQL (authorizer, `duties_lock_occurrence`, `duties_lock_for_leader`, `followups_capacity`). Owner operations (no client route) are checked as unreachable on both targets; the linked-event mismatch runs on the local stack only and is prepared by the parent session for the owner's demonstration.

Decision (agent, under owner pre-approval): `q4_personal_data` records the labelled-contact scope as a documented key in its approval value (`leader_contacts`); the server already returns only labelled routes of the leader's own department, so no migration. `identity_deletion_retention` = anonymise matches the built hooks.

## Boundaries & Constraints

**Always:** API only on staging (exact origin, publishable key, no SQL during the run, state and cleanup SQL outside the repo, mode 0600); SYNTHETIC names and fictional numbers; redacted evidence (codes, counts, states); builds with the key from the environment, redacted in logs; every existing check still passes.

**Never:** production, promotion, approvals or hosted changes; staging runs by the builder; migrations unless the suite finds a real bug; SMS; secrets in the repo; editing frozen blocks.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wrong target | `--target production`, or staging without the key or with state inside the repo | refused before any call | exit 1 |
| Staging number already owned | sign-up of a suite number refuses | stops with the persona named | no deletion attempted |
| Second staging run | state file reused, A and B kept | people and departments reused, checks run-specific | cleanup SQL removes each run's rows |
| Matrix cell | principal x read or probe | exact status/detail or envelope code | mismatch = FAIL, summary marks ≠ |

</frozen-after-approval>

## Code Map

- `tools/identity-e2e/duties-staging-suite.mjs` (+ `.test.mjs`) -- the closing suite (new).
- `tools/identity-e2e/{duties-pilot,staging-suite,duties-shared,harness}.mjs` -- reused guards, staging HTTP, worker, church time.
- `docs/runbooks/production-promotion-duties.md` (new), `production-promotion-identity.md` (link), `duties.md` (story 4.15).
- `.github/workflows/ci.yml` -- evidence scan step; the suite's unit tests run under the existing `tools/identity-e2e/*.test.mjs` glob.
- `evidence-4.15/` -- builds, owner demonstration, local verification, README.

## Tasks & Acceptance

**Execution:**
- [x] `tools/identity-e2e/duties-staging-suite.mjs` + `.test.mjs` -- scenarios S10-S99, matrix (12 reads, 11 probes, 11 principals), targets, cleanup SQL, summary.
- [x] scratchpad `build-4.15.sh` -- clean staff web (sealed staging, refused as production) and arm64 release APK; logs in `evidence-4.15/builds/`.
- [x] `evidence-4.15/owner-demonstration.md` -- 4.13 walkthrough, 4.16 items, refusals and disabled gates.
- [x] `docs/runbooks/production-promotion-duties.md` -- owner and operator steps after promotion, disabled baseline, read-only checklist.
- [x] CI evidence scan; full local verification.

**Acceptance Criteria:**
- Given the local stack, when the suite runs (default and `--staging-path`), then every scenario passes and every matrix cell matches.
- Given staging, when the parent session runs the suite with the env vars in duties.md, then it needs no secret and leaves only the rows its cleanup SQL removes.
- Given the repo, when the full verification runs, then all existing checks still pass.

## Implementation Notes

See `evidence-4.15/README.md` and `evidence-4.15/local-verification.md`.

## Plan Change Log

## Review Triage Log

## Verification

See `evidence-4.15/local-verification.md`.
