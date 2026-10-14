# Story 3.8 retrospective verification record

**Record created:** 2026-10-13, after the original Story 3.8 implementation.
**Implementation revision:** `b1c870c` (`feat: show reminder health to staff`).
**Owner staging witness:** Pending. This file is not a staging witness or a claim that hosted
acceptance occurred.

This record separates checks rerun while preparing it from earlier results preserved in the Story
3.8 plan. No hosted project or database was accessed for this record.

## Repository checks rerun for this record

| Check | Result | Evidence |
|---|---|---|
| Client Core tests | Pass, 427 tests | `/tmp/flutter/bin/flutter test` in `packages/client_core`, Flutter 3.47.6 |
| Staff tests | Pass, 31 tests | `/tmp/flutter/bin/flutter test` in `apps/staff`, Flutter 3.47.6 |
| Migration policy | Pass, 34 migrations | `npm run -s ci:migrations` |

## Earlier recorded verification

The [Story 3.8 plan](../story-show-reminder-health-to-staff-and-write-the-notification-fai-plan.md)
records these completed checks. They are transcribed from that plan and were not rerun as part of
this retrospective:

| Check | Recorded result | Source |
|---|---|---|
| Scoped notification health, push and worker pgTAP suites | Pass, 224 tests | Story 3.8 plan, Verification |
| Scheduler-success backfill SQL | Checked in a rolled-back transaction | Story 3.8 plan, Verification |
| Standard local Supabase reset and `db:test` | Blocked by Docker `db` alias connectivity; host-gateway pgTAP path passed | Story 3.8 plan, Database environment limitation |

## Owner staging acceptance

The staging demonstration remains **not witnessed**. The owner still needs to map the operator
account, create synthetic delayed/failure states, verify authorized Admin and mapped-operator
views, verify refusal for another account and redaction, and exercise the documented pause/resume
procedure. No staging result, owner identity, or timestamp is supplied here.
