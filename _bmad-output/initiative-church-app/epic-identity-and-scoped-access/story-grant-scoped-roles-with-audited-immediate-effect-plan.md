---
title: 'Grant scoped roles with audited, immediate effect'
type: 'feature'
ticket: '3'
created: '2026-10-06'
status: 'in-progress'
baseline_revision: '77bf40f0e0f55b43fe6e8ab990761786a2af1eef'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The live-access predicate decides only whether a person may see their own data. Nothing records who is Admin, Pastor, Media or lead pastor, or which scopes a person holds. The 1.4 command seam `app.cmd_authorize` still reads synthetic fixture grants, so no real command can be authorised and neither client can build navigation from server grants.

**Approach:** Add Identity grants: a role catalogue, a scope-kind registry for later owners, versioned grant sets and content-free audit. Four Admin grant commands go through the 1.4 envelope. A platform authorizer registry lets owners plug their command checks into `cmd_authorize`. Role and scope helpers compose `app.identity_access_evaluate()`, so every check reads the current rows. Add a restricted-operator first-Admin bootstrap, Identity church settings that stay unset, synthetic care and finance fixture surfaces, and an `api` read of the caller's own access. Both clients build navigation from that read and refresh it at every navigation, on resume and after any `forbidden`. Staff web gets the Admin grant screen.

## Boundaries & Constraints

**Always:**
- Grants belong to the member and work only while `identity_access_evaluate()` says `granted`. Every helper reads the current rows on each call. JWT claims, metadata and client state never grant access.
- Grant and revoke are 1.4 commands: `request_id`, a required `expected_revision` (the member's grant-set revision), a payload hash and receipts. The command locks authority, then the receipt, then the aggregate. Only an Admin with live access may call them.
- Audit rows hold ids, codes and revisions only, never names, phones or reasons in free text. Each revoke sends the `scope_revoked` lifecycle event through the owner seam.
- No one may remove the last usable Admin; the command is refused. Admin, Pastor, Media and lead pastor are held independently. No role implies a care or finance scope.
- Q-values: the lead-pastor designation (Q4) and the operational contact (Q1) are Identity church settings. Production leaves them unset, so they fail closed. A labelled lead-pastor fixture is honoured only in local and staging.
- Synthetic data only. Use the fictional number ranges, and clean up every user created.

**Decisions:**
- Decision (agent, under owner pre-approval): owners register `(jsonb)->boolean` authorizers by namespace (`app.cmd_register_authorizer`; the namespace must equal the module). `cmd_authorize` calls the registered authorizer and otherwise keeps the 1.4 fixture path. This keeps the rule that platform depends on no owner. `cmd_current_actor` is unchanged: the Identity authorizer applies the predicate itself.
- Decision (agent, under owner pre-approval): scope kinds (cell, department, care, finance, prayer team and others) are registered by their owners through `app.identity_register_scope_kind` with a target-check hook. This entry registers only the SYNTHETIC `fixture_care` and `fixture_finance` kinds. The Cells owner registers `cell` at entry 6.
- Decision (agent, under owner pre-approval): all grant commands serialise on the Admin catalogue row (FOR UPDATE), then share-lock the actor's Admin grant. Two Admins removing each other therefore cannot deadlock or both succeed.
- Decision (agent, under owner pre-approval): a role needs an approved member with a live link; a scope needs an approved member. The last-Admin refusal returns `forbidden` with `{"role": "unsupported"}`. A role whose setting is unset returns `unavailable` with `{"policy": "gate_closed"}`. These use existing contract codes, so the contract version does not change.
- Decision (agent, under owner pre-approval): the restricted operator may bootstrap an Admin only while no usable Admin exists. The bootstrap is audited with the operator's name.

**Never:** SMS configuration; hosted apply; destructive SQL; editing earlier migrations; inventing business rules for department, care, finance or prayer scopes; a client-side role switch acting as a control; caching grants beyond the account generation.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Grant role | Admin, `identity.grant_role {member_id, role}`, current revision | success, revision+1, audit row; the target's next `identity_my_access` lists the role, with no re-sign-in | — |
| Revoke mid-session | Admin revokes Pastor | the target's next call no longer lists Pastor; `scope_revoked` dispatched | — |
| Stale tab | old expected_revision | `conflict` + current_revision | client reloads |
| Non-Admin / revoked Admin | command, or stale tab after own revoke | `forbidden`; client refreshes access and nav hides Admin | — |
| Untrusted / held Admin | predicate not granted | `unauthenticated` / `forbidden` | — |
| Last Admin | revoke the only usable Admin | `forbidden` `{"role":"unsupported"}`, no change | message |
| Replay | same request_id + payload | stored result after an authority recheck; changed payload → `conflict` | — |
| Admin+Pastor+Media, or Admin only | `fixture_scoped_read` care/finance | `forbidden` | — |
| Scoped fixture member | holds `fixture_care` X | X readable; Y and finance forbidden | — |
| Lead pastor in production | setting unset | grant `unavailable`; the role is not effective | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003123459_command_foundation.sql`, `…131021_…hardening.sql`, `…134340_cross_epic_contracts.sql` -- `app.cmd_execute(jsonb, handler, scope, revision_required)`, `cmd_authorize(uuid,text)` (replace the body in a NEW migration), `cmd_fail`, `contract_validate_handler`, `contract_dispatch_lifecycle`, the module and dependency registry (`fixture` lacks an edge to identity: add one), `policy_effective` pattern.
- `supabase/migrations/20261006215842_…`, `20261006223524_…` -- `identity_access_evaluate()` (compose it, do not copy it), `identity_require_access`, `identity_record_activity`, `identity_setting` (fixture/approved pattern), `identity_seed_synthetic_link`.
- `supabase/migrations/20261003154040_bounded_system_access.sql` -- `app.ops_require_operator(text)` for the bootstrap.
- `supabase/tests/command_foundation_test.sql` -- exact allowlist of executable functions (cross-lane edit, as 2.1 did); `identity_live_access_test.sql` fixture helpers.
- `packages/client_core` -- ports in `domain/`, adapters in `adapters/` (boundary test), `providers.dart`, `account_controllers.dart` (pattern for generation-scoped state), `shell_routing.dart`, `testing.dart`, `composition.dart`; `apps/{mobile,staff}/lib/app.dart` static destination lists that become grant-driven.
- `tools/identity-e2e/run.mjs` helpers (local origin, psql, redact) and `live-adapter-check.sh` pattern; the local phone switch `tools/auth-harness/local-phone-auth.mjs`.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261006235500_identity_grants.sql` -- authorizer registry and `cmd_authorize`; roles, church settings, scope-kind registry, grant sets, grants, audit; the helpers `identity_has_role/has_scope/require_grant/evaluate_grant`; Identity authorizer; the four commands; the `api.identity_grant_command`, `api.identity_my_access` and `api.identity_admin_member_grants` reads; the bootstrap; the fixture scope kinds and `api.fixture_scoped_read`.
- [ ] `supabase/tests/identity_grants_test.sql` -- pgTAP for the matrix, locks, audit, settings, privileges and registry guards; update `command_foundation_test.sql`.
- [ ] `supabase/tests/identity_api_smoke.sh` -- anon is denied the new api functions.
- [ ] `tools/identity-e2e/grants.mjs` -- real Auth sessions: mid-session grant and revoke, stale revision, last Admin, combined and Admin-only fixture denial, replay; redacted evidence; cleanup.
- [ ] `packages/client_core` -- grants domain, adapter, `MyAccessController`, grant-driven destinations, `MyAccessScreen`, `GrantAdminScreen`, routes, fakes, tests; live check `grants` mode.
- [ ] `apps/{mobile,staff}` -- navigation from grants; app tests.
- [ ] `docs/runbooks/identity-access.md`, `evidence-2.3/README.md`, CI evidence scan.

**Acceptance Criteria:**
- Given two signed-in sessions, when an Admin grants and then revokes a role, then the other session's next protected call reflects each change, with no re-sign-in, and audit rows exist.
- Given CI, when db:test, db:smoke, flutter analyze and flutter test run, then all pass.

## Implementation Notes

## Verification

**Commands:**
- `npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/grants.mjs --evidence … && … off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
