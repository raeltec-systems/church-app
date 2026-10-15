---
title: 'Refactor sweep'
type: 'refactor'
ticket: '14'
created: '2026-10-15'
status: 'done'
baseline_revision: 'e398b5fc8dcbbb1d3c515538cb534ee2d094c886'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 4.1-4.13 left copies that can drift: duties and follow-ups each carry their own wire-JSON parsers, church-time form formatters and the "same input, same request id" rule; follow-ups screens re-implement the secure request-id generator; eight E2Es repeat the notifications-worker credential block and several church-time and predicate helpers; four function comments and many runbook "arrives with entry N" notes predate what later stories built.

**Approach:** Behaviour-preserving cleanup only, selected from the build records (findings table below). Every check that passed before passes after, with counts growing only by new tests.

- Decision (agent, under owner pre-approval): SQL is limited to one comment-only forward migration that refreshes four stale function comments. No body is replaced: the dead-function query (no caller in any current body, trigger, policy or check, and not a registered hook or owner operation) found none, and consolidating the repeated lock/gate code means re-creating large hosted command bodies for no behaviour gain.
- Decision (agent, under owner pre-approval): the follow-ups read controller drops the in-flight request when a read finishes, so its buttons re-enable mid-send; duties fixed the same rule in 4.5. This is a clear correctness drift with a one-line fix and a test, so it is applied and recorded as a fix (C5), not a refactor.
- Decision (agent, under owner pre-approval): the one-line rule and helpers are shared only between Duties and Follow-ups. The same copies in identity and cells controllers and `cell_membership.dart` are other epics' code (2.13 already swept identity); recorded as deferred, not changed.

## Boundaries & Constraints

**Always:** Same pgTAP, smoke, contract fixtures, E2E step names, checks and JSONL shapes; public Dart exports stay available; the TZ=America/New_York duties and follow-ups runs pass; function bodies, grants and lock order unchanged (md5 of every `app`/`api` function body identical before and after the migration).

**Never:** New behaviour beyond C5; a replaced function body; grant changes; DROP/TRUNCATE/`delete from`/backslashes in the migration; editing merged migrations, evidence or historical plan records outside this plan; weakened or deleted assertions; secrets; staging or hosted calls.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wire parse | duties / follow-ups JSON, valid or malformed | same objects; same `FormatException` messages | unchanged |
| Church time | instant near midnight UTC, any device zone | same `YYYY-MM-DD` / `HH:MM` church text | unchanged |
| Resend | unconfirmed command, same input | same request id; other input -> new id | unchanged |
| Follow-ups reload mid-send (C5) | reload completes while a command is pending | still busy; no second send | outcome applied when the send answers |
| E2E | each duties/follow-ups E2E after a reset | same N/N checks | non-local origin still refused |

</frozen-after-approval>

## Findings

| # | Finding (source) | Verdict | Why |
|---|---|---|---|
| C1 | `_req/_opt/_map/_instant/_optInstant/_revision/_account` copied in `duties.dart` and `followups.dart` | apply | Shared `wire_json.dart` (not exported); one parse rule, identical messages. |
| C2 | Church `YYYY-MM-DD`/`HH:MM` built five ways (`_dateField`, `_timeField`, coverage inline, `RotaEdit.hm`, `CoverageQuery`/`OutcomesQuery` ymd) | apply | `ChurchTime.dateText/timeText/ymd`; tests near midnight. |
| C3 | `_newSourceId` in follow-ups screens = `SecureRequestIds.next` | apply | Same algorithm, one copy. |
| C4 | Same-input/same-request-id rule in both controllers | apply | `resendOrNewRequest` in `commands.dart`, duties + follow-ups only. |
| C5 | `FollowUpsController._reload` drops `pending` (duties keeps it since 4.5) | apply (fix) | One line + test; recorded under Decisions. |
| C5b | `CellsController._reload` drops `pending` (same bug as C5; review should-fix 1) | apply (fix) | One line + widget test in `cell_membership_test.dart`; recorded in the Plan Change Log. |
| C6 | Merge `DutiesController`/`FollowUpsController` into one generic base | reject | Different reload rules (`stillUnconfirmed`, candidates invalidation, grant function), notice/action types; public state types used by both apps. |
| E1 | Worker principal/credential/run-once block x8; `churchSunday` x3, `churchInstant` x5, `oneWinner` x2, `refusedTableQuery` x2, `sessionClaims`/`jsonLiteral` x2, `summarize` x3, generic-item check x4 | apply | `tools/identity-e2e/duties-shared.mjs` + test; files re-export names their tests import. |
| E2 | Per-E2E cleanup SQL, `envelope/rpc/read` closures | reject | Differ per story (tables grow); one-liners. |
| E3 | `churchAt` (no millis), `churchTen`, pilot `churchDate` | reject | Different output shapes or one caller. |
| S1 | Comments of `api.duties_command` (lists to 4.10), `api.followups_command` (no `complete_handover`), `app.duties_state_ok` ("4.1"), `app.followups_state_ok` ("4.6") | apply | Comment-only migration; no body touched. |
| S2 | Dead `duties_*`/`followups_*` functions | none found | Every no-caller function is an API read/command, a registered hook/check or an owner operation. |
| S3 | 4.10 N5 name clash `app.duties_outcomes` function vs table | reject | Rename changes an API name. |
| S4 | 4.7 N8 reminders set by an update after insert | reject | Needs a new `followups_insert_task` signature. |
| D1 | `duties.md` "arrives with entry 8/9/10/11/12" notes in 4.2-4.10 sections built by later stories | apply | Annotate "(built in story 4.x, below)" as 4.1 already does. |
| D2 | `follow-ups.md` 4.6: consumer guide "(entry 11) follow" | apply | Built in 4.11. |
| F1 | 4.12 S4 revoke-first handover bypass; 4.9 Q2-invalid task left open; 4.8 no back-fill; 4.11 cell-part limits | defer | Behaviour; already recorded known limits with their owners. |
| F2 | Same-request rule and parsers in identity/cells controllers and `cell_membership.dart` | defer | Other epics; `deferred-work.md` entry. |

## Code Map

- `packages/client_core/lib/src/domain/duties.dart:164-235`, `followups.dart:70-109` -- private parsers; `duty_coverage.dart`, `duty_outcomes.dart` are `part`s of `duties.dart`.
- `packages/client_core/lib/src/domain/church_time.dart` -- exported; add formatters.
- `packages/client_core/lib/src/presentation/duties_screens.dart:750-761` (`_dateField/_timeField`), `duties_coverage_screens.dart:334-337`, `domain/duties.dart:2017` (`RotaEdit.hm`), `duty_coverage.dart:608-620`, `duty_outcomes.dart:386-393`.
- `packages/client_core/lib/src/presentation/followups_screens.dart:1342` (`_newSourceId`); `domain/commands.dart:56` (`SecureRequestIds`).
- `packages/client_core/lib/src/application/duties_controllers.dart:342-370`, `followups_controllers.dart:127-185`.
- `tools/identity-e2e/{duties,duties-revisions,duties-rota,duties-reminders,duties-coverage,duties-outcomes,duties-lifecycle,followups-reminders}.mjs` -- worker block; helper copies listed in E1; `*.test.mjs` import helpers from their script.
- `supabase/migrations/20261015110202_duties_lifecycle.sql` -- latest bodies (not touched).
- `docs/runbooks/duties.md`, `follow-ups.md`; `.github/workflows/ci.yml:163` (4.13 scan step).

## Tasks & Acceptance

**Execution:**
- [x] `packages/client_core/lib/src/domain/wire_json.dart`, `duties.dart`, `followups.dart` -- C1.
- [x] `church_time.dart` + callers + `test/duties/duties_refactor_sweep_test.dart` -- C2.
- [x] `followups_screens.dart` -- C3. `commands.dart`, both controllers + test -- C4. `followups_controllers.dart` + test -- C5.
- [x] `tools/identity-e2e/duties-shared.mjs` (+ test) and the E2Es -- E1.
- [x] `supabase/migrations/20261015143102_duties_comment_refresh.sql` (+ `supabase/tests/duties_comments_test.sql`) -- S1.
- [x] `docs/runbooks/duties.md`, `follow-ups.md` -- D1, D2 (+ a 4.14 section with the staging step); `deferred-work.md` -- F2.
- [x] `evidence-4.14/`, `.github/workflows/ci.yml` scan step.

**Acceptance Criteria:**
- Given the baseline and the change, when the full check set runs, then every result matches (counts grow only by new tests) and every `app`/`api` function md5 is unchanged.

## Implementation Notes

- No coding subagent was available in this run; implemented directly from the plan.
- C1: `lib/src/domain/wire_json.dart` (`wireReq/wireOpt/wireMap/wireInstant/wireOptInstant/wireRevision/wireAccount`, not exported). `duties.dart` (and its parts) and `followups.dart` keep their short private names as `const _req = wireReq;` and so on, so about 440 call sites are unchanged. The error messages are the same, and a test pins them.
- C2: `ChurchTime.dateText`, `timeText` and `ymd` (additive public API). `_dateField`/`_timeField` are removed (their callers use ChurchTime). `RotaEdit.hm` stays public and delegates. `OutcomesQuery` and `CoverageQuery` use `ChurchTime.ymd`. A test checks the new helpers against the replaced formulas at every quarter hour of 2026.
- C3: `_newSourceId()` is `SecureRequestIds().next()`. The existing test that a new draft gets a new source id still passes.
- C4: `resendOrNewRequest` in `commands.dart`, used by both controller bases. `dart:convert` is no longer imported by either controller.
- C5: one line, `pending: state.pending` in `FollowUpsController._reload`. A new widget test in `followups_test.dart` checks that a reload mid-send stays busy, sends nothing a second time, and that Check again reuses the request id. Mutation check: without the line the test fails (`followups-pending` not found).
- E1: `tools/identity-e2e/duties-shared.mjs` (+ 5 tests in `duties-shared.test.mjs`). The 8 worker blocks keep their principal names and labels. Scripts re-export the helpers their offline tests import. Imports that became unused were removed (`node:crypto`, `node:path`, `node:url`, `node:util`, `node:child_process`, `ROOT`, `CHURCH_OFFSET_MS`). `duties-lifecycle.mjs` keeps `execFile` and `promisify` for its docker psql. The pilot's and 4.8's `churchInstant` (`+02:00` form) were replaced by the offset form; the two forms give identical output, which a test checks across 2026.
- S1: `supabase/migrations/20261015143102_duties_comment_refresh.sql`, comment-only. It touches no function body: all four functions keep their 4.12 bodies from `20261015110202_duties_lifecycle.sql`. Local md5 of `pg_get_functiondef`, the ACLs and the comments for all 805 app/api/public functions, before and after: only the four comment hashes differ (`evidence-4.14/function-md5-diff.txt`). New `supabase/tests/duties_comments_test.sql` (4 tests): every command routed by `app.duties_command` / `app.followups_command` is named in its api wrapper's comment. Mutation check: with the old comments, tests 2 and 4 fail.
- D1/D2: 18 annotations in `duties.md` and 1 in `follow-ups.md` (each checked against the later story's section; the cell-part queue and outcomes point to epic 5 as 4.11 says), plus a new `duties.md` "Story 4.14" section with the staging step. Review fixes: the 4.5 note on a member-to-leader Call and the 4.8 note on marking released/cancelled notices done were rewritten with the coordinator's wording (not built, not planned in epic 4).
- F2: `deferred-work.md` entry added.
- CI: `.github/workflows/ci.yml` gains the 4.14 scan-evidence step.

## Plan Change Log

- 2026-10-15, independent review of 4.14 (no blockers; coordinator relayed):
  - **Should-fix 1:** `CellsController._reload` dropped `pending`, the same bug as C5. Amended: `pending: state.pending` plus the widget test "a reload while a confirmation is in flight cannot send it twice" in `test/identity/cell_membership_test.dart`. Without the line the test fails (`cells-pending` is not found). This is a correctness fix outside Duties and Follow-ups, made at the reviewer's request. The F2 deferred entry now notes that it is done.
  - **Should-fix 2 and nit 1:** the `duties.md` 4.5 Call note and the 4.8 "marked done" note now use the reviewer's wording.
  - **Nit 2:** `duties_comments_test.sql` matches commands on word boundaries (`\m...\M`).
  - **Nit 3:** the C2 test file name in the task list is corrected.
  - **Nit 4:** the `duties-shared.mjs` name is kept.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass (baseline 43 files / 3733).
- `e2e-main.sh` (worktree copy) -- expected: every `exit=0`, counts as `evidence-4.13/e2e-suite-summary.txt`.
- `npm run -s contracts:test`, `dart test` (contracts), node tool tests (baseline 239), `ci:policy-test`, `ci:secrets`, `ci:migrations -- --base origin/main`, `ci:function-imports` -- expected: pass.
- `flutter analyze` + `flutter test` in client_core (baseline 637), staff, mobile; `TZ=America/New_York flutter test test/duties test/followups` -- expected: pass.
- `bash tools/auth-harness/scan-evidence.sh <evidence-4.14> ...` -- expected: clean.

**Results (2026-10-15, local stack, after the change; `evidence-4.14/local-verification.md`):**
- db reset 0; pgTAP 44 files / 3737 PASS (baseline 43 / 3733, +4); db:smoke exit 0.
- All 30 E2Es, each after a reset: every `exit=0` with the same N/N counts as `evidence-4.13/e2e-suite-summary.txt`.
- Function md5s: all 805 bodies and ACLs are identical; only the 4 refreshed comments changed.
- Tool and contract checks: contracts:test 265, Dart contracts 282, node tool tests 244 (baseline 239, +5), ci:policy-test 56; ci:secrets, ci:function-imports and the evidence scans are clean; ci:migrations reports 49 migrations.
- Flutter: client_core analyze is clean, with 645 tests after the review fixes (baseline 637, +8) and TZ=America/New_York runs of 176 (duties) and 37 (follow-ups); staff 40, mobile 55, both analyze clean.
- Matrix audit:
  - Wire parse: `duties_refactor_sweep_test` wire readers, plus every existing duties and follow-ups parse test.
  - Church time: quarter-hour comparison and midnight cases, also run in New York time.
  - Resend: `resendOrNewRequest` tests, plus the existing duties and follow-ups Check again tests.
  - Follow-ups reload mid-send: the new `followups_test` case (mutation-checked).
  - E2E: suite summary.

**Staging (parent session, no owner action):** apply `20261015143102_duties_comment_refresh.sql` after `20261015110202`. Check that the per-function md5 is unchanged against local and that the four comments match. No Edge Function change. The Follow-ups client fix ships with the next staging staff/APK build.
