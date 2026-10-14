---
title: 'Delete a member fully through a resumable workflow'
type: 'feature'
ticket: '11'
created: '2026-10-07'
status: 'done'
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
- [x] `supabase/migrations/20261007174952_member_deletion.sql` -- gate, events, tables, fixture rules, hooks registries, rcv split + replay, request commands, system commands, replay hook, reads, replaced functions, stubs, grants.
- [x] `supabase/migrations/20261007175000_member_deletion_rows.sql` -- the three deleting functions only.
- [x] `supabase/functions/identity-deletion/{index.ts,logic.mjs,logic.test.mjs}`, `supabase/config.toml`.
- [x] `tools/identity-deletion/{worker.mjs,worker.test.mjs}` -- the resumable worker.
- [x] contracts -- `member_deleted` (see Plan Change Log).
- [x] `supabase/tests/member_deletion_test.sql`, allowlists, smoke.
- [x] `tools/identity-e2e/deletion.mjs` (+ test) -- verify bullet incl. interrupt/resume and isolated restore.
- [x] `packages/client_core` + apps -- mobile request, staff deletion screen, fakes, widget tests.
- [x] docs (identity-access, contracts, system-access, backup-and-restore), `evidence-2.11/README.md`, CI.

**Acceptance Criteria:**
- Given the local stack, the phone switch on and the served function, when `deletion.mjs` runs, then every matrix row passes and only append-only journal entries and their acks remain.
- Given CI, when db:test, db:smoke, recovery:rehearse, node tests, contracts tests, flutter analyze and test run, then all pass; earlier identity E2Es still pass.

## Implementation Notes

- Built directly (no subagent tool in this session); checkpoint 1 pre-approved by the owner decisions. Above the 1600-token guide for the same reason as 2.7-2.10: one Identity change spans the database, a worker, an Edge Function, two clients and evidence.
- Files:
  - `supabase/migrations/20261007174952_member_deletion.sql` (no row-deletion statement, ASCII only, every function pins `search_path`, nothing granted to anon): gate `identity_deletion_retention` (labelled fixture), event `member_deleted`, tables `identity_deletions` (tombstone), `identity_deletion_steps`, `identity_deletion_audit`, `identity_deletion_hooks`, `identity_deletion_retention_rules` (FIXTURE), `rcv_replay_hooks`; three fail-closed stubs; deletion and replay hook registries; Cells hook `cells_erase_member` (registered) and SYNTHETIC `fixture_erase_member`; `rcv_apply_journal_entry_as` + `rcv_apply_journal_entry` delegating (same signature/privileges); request commands on `api.identity_deletion_command`; six system commands of purpose `identity_deletion`; replay hook `identity_rcv_replay` (registered); read `api.identity_admin_deletions`; link guard trigger; replaced in place with their latest bodies: `identity_restore_membership`, `identity_admin_membership_lifecycle` (EXECUTE re-granted), `identity_authorize_command` (every earlier command kept).
  - `supabase/migrations/20261007175000_member_deletion_rows.sql`: ONLY `identity_deletion_purge_rows`, `identity_deletion_purge_auth_user` (restore-held only), `cells_deletion_purge_rows`.
  - `supabase/functions/identity-deletion/{index.ts,logic.mjs,logic.test.mjs}`; `supabase/config.toml` (`verify_jwt = false`).
  - `tools/identity-deletion/{worker.mjs,worker.test.mjs}`.
  - Contracts: `member_deleted` in `fixtures/v1/lifecycle_event.json`, Dart `models.dart`/`check.dart` + regenerated `fixtures.g.dart`, TS `contracts.ts`.
  - Tests: `supabase/tests/member_deletion_test.sql` (93); allowlists in `command_foundation_test.sql`, `system_access_test.sql`, `cross_epic_contracts_test.sql`; `identity_api_smoke.sh` (+6); E2E `tools/identity-e2e/deletion.mjs` (+ `.test.mjs`).
  - client_core: `domain/member_deletion.dart`, `adapters/supabase_member_deletion_repository.dart`, `application/member_deletion_controllers.dart`, `presentation/member_deletion_screens.dart` (mobile `DeleteAccountScreen`, staff `MemberDeletionScreen`), routes `/delete-account` and `/admin/member-deletions` (gated), account-page link, provider, composition, exports, fakes; `test/identity/member_deletion_test.dart` (18). Apps: staff `Member deletions` destination (Admin) + 2 tests; mobile 1 test.
  - Docs/CI: `identity-access.md` section, `contracts-and-owner-seams.md` (events, deletion and replay hooks, gates), `system-access-and-operations.md` (purpose), `backup-and-restore.md` (replay), `evidence-2.11/`, CI node tests and evidence scan, three deferred-work entries (the L40 entry was removed after the coordinator fixed it).
- Decision (agent, under owner pre-approval): the in-app request also needs a recent password sign-in (`forbidden {"session": "reauthenticate"}`, the 2.7 check); the mobile screen confirms the password first, as 2.8 does for credential changes.
- Decision (agent, under owner pre-approval): the staff route refuses a member with working app access (`conflict {"member_id": "member_can_use_app"}`): an Admin cannot delete someone who could ask themselves; a login hold first makes the route available when the member cannot use the app.
- Decision (agent, under owner pre-approval): the Auth account step does not wait for handovers (security denial first); only erase steps do. Every destructive step also waits while a restore is held.
- Decision (agent, under owner pre-approval): retained facts keep the tombstone member id (correction links); the deleted account id becomes the nil UUID; receipts and the GoTrue `audit_log_entries` of the accounts are deleted (matching refined by the review decisions below); `rcv_journal_acks` keep the opaque ids by design (journal mirror).
- Decision (agent, under owner pre-approval): restore replay erases inline only on `deletion_completed` entries (a manifest alone re-creates the workflow and denies), so a restore never erases more than the live system had; the restored Auth row is deleted by SQL only while a restore is held.
- Decision (agent, under owner pre-approval; independent review, MEDIUM 6): two-person rule on the staff route. For a member who has a live account link, the login hold or deactivation that makes the route available must have been placed by a DIFFERENT Admin than the one asking for the deletion; otherwise `conflict {"member_id":"second_admin_required"}`. A member whose link is in review or binding review, or who never had a working account, needs no second Admin. A hold with no recorded actor counts as another Admin's.
- Decision (agent, under owner pre-approval; review HIGH 1, LOW 8, LOW 9): erasure matches by ids only, never by phone number. Before the rows go, the ids of the member's records are recorded in `app.identity_deletion_aggregates` (applications, credential changes, recovery-email proposals, recovery cases, grants and requests, phone reclaims, links). `cmd_receipts` are deleted when the actor is one of the member's accounts or the aggregate is one of those ids (or the member or the deletion); other actors' receipts that mention the member or an account are redacted (ids become the nil UUID), not deleted; `sys_receipts` likewise redacted. Recovery requests and reclaims go only when tied to the member's records or accounts. Verify uses the same matching.
- Decision (agent, under owner pre-approval; review HIGH 2): every deletion route locks the Admin role rows (`app.identity_roles where role = 'admin' for update`) before the last-Admin check, so concurrent self-deletions of the last two Admins leave exactly one usable Admin.
- Decision (agent, under owner pre-approval; review MEDIUM 3, MEDIUM 4, LOW 10): every Auth account the member ever linked (ended links and applications included) is recorded in `app.identity_deletion_accounts` (replacing the single `auth_user_id` column), banned and signed out at the request, journaled, deleted through Auth Admin and anonymised one by one; restore replay bans every recorded account. `auth.audit_log_entries` of every account (by `actor_id` or `traits.user_id`) are deleted at erase and again in the final sweep after the Auth step, so Auth's own `user_deleted` entry goes too; verify checks them.
- Decision (agent, under owner pre-approval; review MEDIUM 5): a journal acknowledgement must continue the acknowledged chain: `seq` = max acknowledged + 1, `prev_hash` = that entry's hash, `hash` = the canonical hash recomputed in SQL (`app.rcv_canonical`, `app.rcv_entry_hash`). Refusals `journal_gap`, `journal_chain_broken`, `entry_invalid`. A seventh system command `identity.deletion_journal_catch_up {entry}` acknowledges entries other writers appended first. Residual trust (documented in the runbook): a credential holder could ack a fabricated well-formed next entry; the next restore then reports `journal_mismatch` and stays held (fails closed).
- Decision (agent, under owner pre-approval; review MEDIUM 7): verify covers recovery requests, binding history, credential events, application events, sys receipts, cmd receipts (by actor and by aggregate), and per account the Auth user, identities, sessions, refresh tokens, one-time tokens, MFA factors and audit-log entries.
- Environment: the stack was reset several times from this worktree; the phone switch was found off, was on only for the E2E runs and is off again; no image pulled (edge-runtime and postgres images reused); the isolated restore container and the edge-runtime container were removed; every synthetic row removed except append-only journal segments and their acknowledgements (gitignored `.recovery-state/journal`).
- Owner and parent steps (none blocks the build; exact steps in the runbook "Hosted (parent session / owner)"): parent applies `20261007174952`; owner hand-applies `20261007175000` (and confirms `auth.audit_log_entries` deletion rights); deploy `identity-deletion` with `--no-verify-jwt` (no secret); owner mints and registers the `identity_deletion` credential for the worker; staging worker run with the Drive-mirrored journal.

## Plan Change Log

- 2026-10-07, during implementation (agent, under owner pre-approval; not a step-04 loop). The frozen decision said contract v1 "gains `member_deletion_requested` and `member_deleted`". Investigation found `deletion_requested` ("Full deletion started: access-denied tombstone recorded") already in v1, unused; the request dispatches it instead of adding a duplicate name, and only `member_deleted` is added. Avoids two event names for one fact. KEEP: additive server-only rule.

- 2026-10-07, after the independent review (coordinator request; agent, under owner pre-approval). Two HIGH (receipts not purged by aggregate; last-Admin check racy), five MEDIUM (Auth audit after the Auth step, earlier accounts, unchained journal acks, one Admin could hold and delete, verify gaps) and three LOW findings (phone matching, other actors' receipts deleted, replay ban only for the live link) fixed in place in `20261007174952` and `20261007175000` (hosted rules kept: row deletions only in the second file; replaced functions keep signature and privileges). `identity_deletion_purge_rows` now takes the deletion id. The worker catches up foreign journal entries. pgTAP 93 -> 105; E2E 11 -> 12 checks (real-flow seeding of every store, Auth deletes through the Edge Function, Auth tables scanned, concurrent last-Admin self-deletion). The coordinator's L40 fix (151ee2f) was merged; its deferred entry was removed. KEEP: the original step order and fail-closed stubs.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke && npm run recovery:rehearse` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/deletion.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- regressions `lifecycle`, `assisted`, `credentials`, `recovery`, `cells`, `review`, `grants`, `apply`, `run` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`; contracts Dart/TS; node tool tests -- expected: pass
- Results after the review fixes (2026-10-07, local, fresh reset each): `db:test` 1435/1435 (member deletion 105); `db:smoke` 138 ok; `recovery:rehearse` six scenarios, no problems; `deletion.mjs` 12/12; `lifecycle` 9/9, `assisted` 16, `credentials` 15, `recovery` 20, `cells` 13, `review` 18, `grants` 18, `apply` 27, `run` 30; client_core 345, mobile 27, staff 26, analyze clean; node tool tests 84 and policy tests 49 pass; `ci:migrations --base ccr-93e730dd-89lbvg` (24, non-destructive); `ci:secrets` and `scan-evidence` clean; the main migration has no `delete from`, both files ASCII, no anon grants.
- Results of the first build (2026-10-07, superseded above):
  - `db:test` 1423/1423 (member deletion 93); `db:smoke` exit 0 (138 ok); `recovery:rehearse` all six scenarios, no problems.
  - `deletion.mjs` 11/11 (`evidence-2.11/deletion-e2e.jsonl`); regressions `run` 30, `grants` 18, `apply` 27, `review` 18, `cells` 13, `recovery` 20, `credentials` 15, `assisted` 16, `lifecycle` 8/9 (`L40` fails identically on the baseline schema: pre-existing, deferred).
  - client_core 345 tests, mobile 27, staff 26; analyze clean in all three; format applied; staff `flutter build web --no-web-resources-cdn` ok; contracts Dart 256, TS 239.
  - Node tool tests (auth-harness, identity-e2e, functions, identity-deletion) pass; policy tests 49/49; `ci:migrations --base ccr-93e730dd-89lbvg` (24, non-destructive); `ci:secrets` clean; `scan-evidence` on evidence-2.11, `tools/identity-deletion`, `supabase/functions`, `tools/identity-e2e` clean.
- Matrix audit: in-app (pgTAP + D10/D13 + widgets), staff (pgTAP + D20 + widgets), interrupt (pgTAP + D11/D12/D13 + worker tests), handover (pgTAP wait then completion), last Admin/repeat (pgTAP + D01), restore (pgTAP replay + replay failure keeps the hold + D40; incomplete journals: 1.10 rehearsal scenarios): every row has a passing test.
