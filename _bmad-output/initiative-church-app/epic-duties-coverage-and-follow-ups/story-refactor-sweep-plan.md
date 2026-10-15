---
title: 'Refactor sweep'
type: 'refactor'
ticket: '14'
created: '2026-10-15'
status: 'in-progress'
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
- [ ] `packages/client_core/lib/src/domain/wire_json.dart`, `duties.dart`, `followups.dart` -- C1.
- [ ] `church_time.dart` + callers + `test/domain/church_time_format_test.dart` -- C2.
- [ ] `followups_screens.dart` -- C3. `commands.dart`, both controllers + test -- C4. `followups_controllers.dart` + test -- C5.
- [ ] `tools/identity-e2e/duties-shared.mjs` (+ test) and the E2Es -- E1.
- [ ] `supabase/migrations/20261015130404_duties_comment_refresh.sql` -- S1.
- [ ] `docs/runbooks/duties.md`, `follow-ups.md` -- D1, D2; `deferred-work.md` -- F2.
- [ ] `evidence-4.14/`, `.github/workflows/ci.yml` scan step.

**Acceptance Criteria:**
- Given the baseline and the change, when the full check set runs, then every result matches (counts grow only by new tests) and every `app`/`api` function md5 is unchanged.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass (baseline 43 files / 3733).
- `e2e-main.sh` (worktree copy) -- expected: every `exit=0`, counts as `evidence-4.13/e2e-suite-summary.txt`.
- `npm run -s contracts:test`, `dart test` (contracts), node tool tests (baseline 239), `ci:policy-test`, `ci:secrets`, `ci:migrations -- --base origin/main`, `ci:function-imports` -- expected: pass.
- `flutter analyze` + `flutter test` in client_core (baseline 637), staff, mobile; `TZ=America/New_York flutter test test/duties test/followups` -- expected: pass.
- `bash tools/auth-harness/scan-evidence.sh <evidence-4.14> ...` -- expected: clean.
