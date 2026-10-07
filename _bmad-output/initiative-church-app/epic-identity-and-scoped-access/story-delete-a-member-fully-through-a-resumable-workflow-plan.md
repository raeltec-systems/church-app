---
title: 'Delete a member fully through a resumable workflow'
type: 'feature'
ticket: '11'
created: '2026-10-07'
status: 'in-progress'
blocked_reason: ''
baseline_revision: 'd709ab907759eaf7a8d2c8e0aee117c922dcf985'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/backup-and-restore.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-hold-deactivate-and-restore-membership-with-handover-obligat-plan.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-recover-access-with-staff-assistance-and-a-single-use-grant-plan.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Identity can hold, deactivate and restore (2.10) but cannot delete a member (I10, AD-14, AC-22). There is no tombstone, no deletion manifest in the 1.10 recovery journal, no Auth account removal, and a restored backup would resurrect a deleted member.

**Approach:** A member (mobile) or an Admin for a member without a login (staff web) requests deletion. One transaction denies access for good (tombstone row, link ended, sessions revoked, Auth user banned, grants ended, handovers recorded). A resumable, idempotent worker on the AD-19 system route (new purpose `identity_deletion`) then journals the manifest, deletes the Auth user through a new Edge Function holding Auth Admin, erases Identity, Cells and registered owner data, anonymises retained facts, verifies every store, journals completion and only then completes. Journal replay after a restore re-applies the deletion before the hold lifts.

## Boundaries & Constraints

**Always:** reuse 2.10 deactivation pieces (`identity_end_grant`, `identity_recovery_end_grants`, handover collection, lifecycle dispatch), `identity_revoke_auth_sessions`, the 1.4 envelope and `identity` authorizer, the 2.9 sys registry/kernel, the 1.10 journal (`tools/recovery/journal.mjs`, `rcv_*`). Main migration later than `20261007160100`, ASCII only, no row-deletion statements, `search_path` set, nothing to anon; replaced functions keep latest body, signature and privileges. EVERY row-deletion statement lives in ONE small later migration (`*_member_deletion_rows.sql`) holding only the deleting functions; the main migration's stubs answer `unavailable` until it is applied. Journal entries carry opaque UUIDs only. Phones `+1 202 555 0100–0199` / `+44 7700 900000–900999`; emails `@example.test`. Local stack only; staging steps are recorded for the owner.

**Decisions:**
- Decision (agent, under owner pre-approval): requests. `identity.request_my_deletion {confirm: "delete_my_account"}` (granted member session, no expected revision) and `identity.request_member_deletion {member_id, identity_check}` (Admin, expected = member revision, not the Admin's own record) on `api.identity_deletion_command`. Refused: an existing deletion (`conflict {"member_id":"deletion_requested"}`), the last usable Admin (`forbidden {"member_id":"last_admin"}`).
- Decision (agent, under owner pre-approval): request effects in one transaction: an approved member is deactivated first (2.10 body: grants end, recovery grants end, pending ops obsolete, lifecycle row `membership_deactivated`/`member_request`, handover obligations recorded pending; never refused for a last-responsible obligation); then the live link is `ended`, every Auth session revoked, the Auth user banned (`banned_until` 100 years: sign-in fails at GoTrue from this step), `app.identity_deletions` (the tombstone) and its steps inserted; events `membership_deactivated` (when it applied), `member_deletion_requested`, `sessions_revoked`. A link to a member with a deletion can never become live again (trigger); `identity.restore_membership` refuses it.
- Decision (agent, under owner pre-approval): steps, in order, each with status/attempts/outcome: `journal_access_revoked`, `journal_manifest_member`, `journal_manifest_account`*, `auth_account`*, `erase_identity`, `erase_owners`, `anonymise`, `verify`, `journal_completed_member`, `journal_completed_account`*, `complete` (* only with a login). Erase steps wait (`handover_pending`) while the member has a pending obligation; `auth_account` and erase steps wait (`policy_gate_closed`) unless the new gate `identity_deletion_retention` (labelled fixture in local/staging, unresolved in production) is open. `verify` reopens the failing step on any remaining row.
- Decision (agent, under owner pre-approval): journal entries: `access_revoked {subject: member}`, `deletion_manifest {subject: member, object: identity-member/<member> | auth-user/<account>}`, `deletion_completed {object: …}`. The worker acks each through the system route; the database checks it is exactly the expected entry and records it via a new operator-free `app.rcv_apply_journal_entry_as` (the operator function delegates to it). A resumed worker re-acks an already appended matching entry instead of appending again.
- Decision (agent, under owner pre-approval): restore replay: `rcv_apply_journal_entry_as` calls registered replay hooks (`app.rcv_register_replay_hook`); Identity's hook acts only while the restore hold is on: `access_revoked` denies (deletion tombstone, else a `security` hold), a manifest re-creates/marks the workflow and denies, a `deletion_completed` erases and verifies inline (raises if anything remains, so the hold stays).
- Decision (agent, under owner pre-approval): erasure keeps the `identity_members` row as the tombstone (`display_name` = `Deleted member`, `deactivated`) because other members' records reference it as actor; erased: links and their binding history, credential events, proposals, changes, recovery requests/cases/grants/operations, holds, contact routes, provenance, applications and events, phone reclaims; Cells (via its registered deletion hook): memberships, requests, member state. Retained facts (audit, lifecycle, grants, obligations) keep the tombstone member id; the deleted account id is replaced by the nil UUID per the labelled fixture rule table `app.identity_deletion_retention_rules`.
- Decision (agent, under owner pre-approval): worker = `tools/identity-deletion/worker.mjs` (server-side/operator, holds the deletion credential and the journal adapter); Auth Admin = new Edge Function `identity-deletion` (`verify_jwt = false`) that forwards the caller's `x-system-credential` to the system route and calls Auth Admin only for the account the database returns. No new function secret (the 2.9 function and credential stay separate).
- Decision (agent, under owner pre-approval): contract v1 gains `member_deletion_requested` and `member_deleted` (additive, server-side consumers only). Owner deletion hooks: `app.identity_register_deletion_hook(module, handler)`, handler `(jsonb {member_id, phase: erase|check}) -> jsonb {remaining}`.

**Never:** deleting applicants without a member record (deferred); erasing while a handover is pending or the retention gate is closed; the service-role key in the repo, worker or client; SMS; hosted applies or secrets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| In-app | member with login, cell, grant | sessions 401, password sign-in refused at once; worker completes; no personal row, Auth user gone | — |
| Staff | accountless member, Admin + identity check | tombstone; no account steps; completes | self/no check refused |
| Interrupt | worker stopped after N steps; crash after append; Auth deleted but unrecorded | resume finishes without duplicate entries; attempts recorded | function unreachable -> attempt `failed`, retried |
| Handover | pending obligation | erase waits `handover_pending`; resolves -> continues | — |
| Last Admin / repeat | sole Admin; second request | `last_admin`; `deletion_requested` | — |
| Restore | backup before request, restored after completion | held; replay erases; reconcile opens; tombstone only | incomplete journal -> stays held |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261007151523_membership_lifecycle.sql` -- deactivation body (copy steps), `identity_restore_membership`, `identity_admin_membership_lifecycle` (replace both), `identity_collect_handover`, `identity_authorize_command` (replace, keep every command), `identity_lifecycle_outcome`.
- `…/20261007140729_assisted_recovery.sql` -- sys registry insert pattern, system handler shape `(principal, request, payload) -> {data}`, payload check functions, `identity_recovery_end_grants`, `identity_recovery_audit_add`.
- `…/20261006215306_recovery_journal.sql` -- `rcv_apply_journal_entry` (split into `_as`), `rcv_serving_hold`, privileges block; `20261006215400` restore hold.
- `…/20261007160100_credential_review_auth_rows.sql` -- separate deletion-file pattern; `identity_revoke_auth_sessions`.
- `…/20261003134340_cross_epic_contracts.sql` -- `policy_gates`, `contract_validate_handler`, lifecycle event list; `20261007075946` cells tables.
- `tools/recovery/journal.mjs` (LocalSegmentJournal, DriveJournal, buildEntry, validateEntry, verifyJournal), `rehearse.mjs` (isolated restore pattern; unchanged).
- `supabase/functions/identity-assisted-recovery/` -- function pattern (`keyHeaders`, timed fetch, coarse logs).
- Tests: `membership_lifecycle_test.sql`, `assisted_recovery_test.sql` helpers; allowlists in `command_foundation_test.sql`, `system_access_test.sql`; `identity_api_smoke.sh`; E2E `tools/identity-e2e/lifecycle.mjs`, `assisted.mjs` (serve function, credential).
- Contracts: `packages/contracts/fixtures/v1/lifecycle_event.json`, Dart `models.dart`/`check.dart`/`fixtures.g.dart`, TS `contracts.ts`, `cross_epic_contracts_test.sql`.
- Clients: `packages/client_core` lifecycle files (domain/adapter/controller/screen), `account_screen.dart`, `shell_routing.dart`, `providers.dart`, `composition.dart`, `testing.dart`, exports; apps `mobile`/`staff` `app.dart` and tests.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261007171500_member_deletion.sql` -- gate, events, tables, fixture rules, hooks registries, rcv split + replay, request commands, system commands, replay hook, reads, replaced functions, stubs, grants.
- [ ] `supabase/migrations/20261007171600_member_deletion_rows.sql` -- the three deleting functions only.
- [ ] `supabase/functions/identity-deletion/{index.ts,logic.mjs,logic.test.mjs}`, `supabase/config.toml`.
- [ ] `tools/identity-deletion/{worker.mjs,worker.test.mjs}` -- the resumable worker.
- [ ] contracts -- two events.
- [ ] `supabase/tests/member_deletion_test.sql`, allowlists, smoke.
- [ ] `tools/identity-e2e/deletion.mjs` (+ test) -- verify bullet incl. interrupt/resume and isolated restore.
- [ ] `packages/client_core` + apps -- mobile request, staff deletion screen, fakes, widget tests.
- [ ] docs (identity-access, contracts, system-access, backup-and-restore), `evidence-2.11/README.md`, CI.

**Acceptance Criteria:**
- Given the local stack, the phone switch on and the served function, when `deletion.mjs` runs, then every matrix row passes and only append-only journal entries and their acks remain.
- Given CI, when db:test, db:smoke, recovery:rehearse, node tests, contracts tests, flutter analyze and test run, then all pass; earlier identity E2Es still pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke && npm run recovery:rehearse` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/deletion.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- regressions `lifecycle`, `assisted`, `credentials`, `recovery`, `cells`, `review`, `grants`, `apply`, `run` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`; contracts Dart/TS; node tool tests -- expected: pass
