---
title: 'Write and rehearse the restricted identity runbooks'
type: 'feature'
ticket: '12'
created: '2026-10-07'
status: 'done'
baseline_revision: 'fb12fe8abaf032e4228db52b01441a9d1501c7dd'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 2.1-2.11 left per-story operational notes but no restricted support runbooks a church office or the restricted operator can follow, and no identity-checked way back when the only Admin(s) exist on paper but cannot act (forgot password without a recovery email, left the church, died): `app.identity_bootstrap_admin` refuses while any Admin is "usable", and every Admin-side recovery needs a second Admin.

**Approach:** Write `docs/runbooks/identity-support.md` (one runbook per support case, roles not names) linked from `identity-access.md`; add one minimal restricted-operator command that grants Admin to an existing, linked, identity-checked member with a recorded identity check and reason (no Auth row touched); rehearse every runbook on the local stack with synthetic records in `tools/identity-e2e/runbooks.mjs` and record evidence and an owner staging checklist in `evidence-2.12/`.

## Boundaries & Constraints

**Always:** Steps go through staff web, mobile and the existing operator procedures (SQL editor only where a documented operator path already uses it). Owner names stay `<named owner: fill at entry 14>`. The fallback command needs a restricted operator, an identity check code, a reason code that matches the real Admin state, an approved member whose live link passes `app.identity_account_standing` = `ok` and is not dormant, no deletion; it is audited (`identity_access_audit` `admin_bootstrapped`, a new content-free `app.identity_admin_fallbacks` row) and journalled (`ops_operator_actions`). Rehearsal output and evidence carry codes, statuses and counts only. Fictional numbers only.

**Never:** No password set, reset, shown or chosen by staff or the operator; no session, token, link or grant minted for anyone; no Auth row written by the fallback; no care/finance scope for a support account; no anon/client grants on new objects; no DROP/TRUNCATE/literal `delete from` in the migration; no SMS configuration; no secrets in the repo; no Flutter changes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fallback, Admins unreachable | one usable Admin who cannot sign in; target approved, linked, standing ok | Admin granted; returns ids/codes only; target's password hash and sessions unchanged; target signs in with own password and is Admin | — |
| Fallback, no usable Admin | every Admin held/dormant/banned; reason `no_usable_admin` | Admin granted, audited | — |
| Reason contradicts state | `no_usable_admin` while one is usable, or `admins_unreachable` while none is | refused 22023, nothing written | operator re-reads runbook |
| Bad target | accountless, held, in review, dormant, deleted, already Admin, unknown | refused 22023, nothing written | — |
| Not an operator / bad identity check | unknown operator; check not `in_person`/`established_relationship` | 42501 / 22023 | — |
| Admin-only support account | Admin reads fixture care/finance and an unjoined cell's private fixture | 403 `not_granted` each | — |
| Leak scan | every staff, operator and worker output in the rehearsal | contains no password, grant secret, digest, request code, token, reset/confirm link or code | rehearsal fails |

## Decisions

- Decision (agent, under owner pre-approval): one new restricted-operator command with two truthful reason codes (`no_usable_admin`, `admins_unreachable`) rather than widening the bootstrap; the bootstrap stays the first-Admin path. Audit reuses the existing `admin_bootstrapped` action values (widening a CHECK needs a DROP) plus a new content-free fallback table for the reason and identity check.
- Decision (agent, under owner pre-approval): the named owners' two-person identity check is a runbook step, recorded by code in the database and by the owners in their restricted case note; names never enter the database (Q1, entry 14). Runbooks use `<named owner: fill at entry 14>`.
- Decision (agent, under owner pre-approval): production has no path to link the first real Admin (applications need an Admin; the synthetic seeding refuses production). Out of this ticket's minimal scope; RB1 records it as an entry 14 gap needing a reviewed operator procedure, and staging uses the synthetic seed.

</frozen-after-approval>

## Code Map

- `docs/runbooks/identity-access.md` -- per-story mechanics (commands, refusals, hosted steps); runbooks cite its sections, never copy them. Add a link near the top.
- `supabase/migrations/20261006234820_identity_grants.sql:1364` -- `app.identity_bootstrap_admin` (first Admin; only while `identity_usable_admin_count()=0`); `:800` usable count; `:440` `identity_access_audit` action CHECK (reuse `admin_bootstrapped`, do not widen); `:159` `ops_operator_actions` CHECK (reuse `admin_bootstrapped`).
- `app.identity_designate_lead_pastor`, `app.identity_approve_church_setting` -- first-Admin setup follow-ups.
- `app.identity_deletions` (2.11) -- a member under deletion is never a fallback target.
- `supabase/tests/identity_grants_test.sql` -- pgTAP fixture pattern (synthetic auth users, `pg_temp.session`, `identity_seed_synthetic_link`).
- `tools/identity-e2e/{lifecycle,assisted,recovery,credentials,deletion,review}.mjs` -- flows to reuse: `findLeaks/newGrantSecret/digestOf` (assisted), `pkcePair/codeFrom/redirectFacts/MAILPIT` (recovery), `requestCode` (lifecycle), `redact/amrMethods/assertLocalOrigin` (run); function serving and worker invocation patterns (assisted, deletion).
- `tools/identity-deletion/worker.mjs` -- deletion worker; `.recovery-state/journal` shared local journal.
- `docs/runbooks/system-access-and-operations.md`, `backup-and-restore.md` -- operator procedures and restore hold, referenced by the runbooks.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261007193513_identity_admin_fallback.sql` -- table `app.identity_admin_fallbacks` (ids, codes, counts; RLS on, no client privileges) and `app.identity_admin_fallback_grant(member_id, identity_check, reason_code, operator) returns jsonb`; locks the admin role row like bootstrap -- the one missing operator path.
- [x] `supabase/tests/identity_admin_fallback_test.sql` -- pgTAP for every matrix row on the fallback, privileges, no Auth write, audit and journal.
- [x] `docs/runbooks/identity-support.md` -- runbooks: first-Admin setup, applications and linking (incl. reclaim), email recovery, staff-assisted recovery, holds and disputes (incl. credential review), deactivation and handover, deletion, last-Admin fallback; each with when, who, preconditions, steps, never, audit evidence, back out. `docs/runbooks/identity-access.md` -- link it and document the fallback command.
- [x] `tools/identity-e2e/runbooks.mjs` + `runbooks.test.mjs` -- local rehearsal of each runbook (numbers `+44 7700 900700-900719`), leak scan over every staff/operator/worker output and the evidence file, Admin-only care/finance denial, fallback without credential shortcut; pure helpers unit-tested.
- [x] `_bmad-output/.../evidence-2.12/` -- `README.md`, rehearsal JSONL, `owner-rehearsal.md` (staging, synthetic, `+1 202 555 0100-0199`).

**Acceptance Criteria:**
- Given a fresh local stack, when `node tools/identity-e2e/runbooks.mjs` runs, then every check passes and the stack is left without the run's users, members or hooks.
- Given the new migration, when `check-migrations` and `db:test` run, then both pass and the fallback function has no client EXECUTE.

## Implementation Notes

- Files: `supabase/migrations/20261007193513_identity_admin_fallback.sql`, `supabase/tests/identity_admin_fallback_test.sql` (32 assertions), `docs/runbooks/identity-support.md` (RB1-RB8), `docs/runbooks/identity-access.md` (link + fallback section), `tools/identity-e2e/runbooks.mjs` + `runbooks.test.mjs`, `.github/workflows/ci.yml` (evidence scan for 2.12), `evidence-2.12/`.
- The rehearsal reuses `findLeaks/newGrantSecret/digestOf` (assisted.mjs) and `pkcePair/codeFrom/redirectFacts` (recovery.mjs); it serves both Edge Functions in one `supabase functions serve --env-file` and runs the real deletion worker on the shared `.recovery-state/journal`.
- The leak scan has a positive control (a planted password and request code are found) so a silent scanner cannot pass.
- RB8 scenario: the only Admin is signed out everywhere and "forgot" the password; bootstrap refuses (one usable Admin on paper); the fallback grants Admin to an application-approved member with no Auth fact changed; the new Admin brings the old one back through RB4.
- Review fix: a parsed `admin_via_fallback` flag and a Roles & access label in `packages/client_core` (analyze and test pass for client_core and apps/staff); the live adapter checks were not rerun.

## Plan Change Log

- Review pass 1 changed the design (coordinator's renegotiation of the frozen intent):
  - The fallback takes `confirming_owner` and `case_reference`.
  - It audits with `admin_fallback_granted` instead of reusing `admin_bootstrapped`, which superseded the earlier "reuse the action values" decision and needed the retire-and-recreate of `identity_access_audit` and `ops_operator_actions`.
  - It refuses scope holders.
  - It is flagged in Roles & access.

## Review Triage Log

- Independent review (coordinator), 5 findings, all patched:
  1. (medium) The owner cleanup pointed at SQL purges. Now RB7 through the product only, and leftovers may stay on staging.
  2. (medium) The fallback relied on one operator's claim. Now it requires and stores `confirming_owner` (distinct from the operator) and `case_reference`, and records the distinct action `admin_fallback_granted`. `identity_access_audit` and `ops_operator_actions` were retired and recreated with wider CHECKs; the retired audit was added to the deletion retention rules. Roles & access shows `admin_via_fallback`, with a staff web label. No lifecycle event: it needs a contract version change.
  3. (low) Refuse a target holding any scope grant; added to RB8.
  4. (low) RB8 now says existing sessions gain Admin at once; the epoch is not moved.
  5. (low) pgTAP messages pinned; added deactivated and banned cases.

## Design Notes

Why a new command, not bootstrap: "usable" means "passes every non-session check", so a sole Admin who forgot the password (no email) or left without being deactivated still counts, bootstrap refuses, and every Admin-side exit (assisted recovery, hold, deactivation) needs another Admin. The operator already holds database-owner power; the command turns that into a constrained, audited path instead of raw SQL. It never touches `auth.*`: the new Admin signs in with their own password, then helps the original Admin through the normal runbooks.


## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- all pass
- each `tools/identity-e2e/*.mjs` E2E (reset between runs, phone switch on) and `node --test tools/identity-e2e/` -- all pass
- `npm run -s contracts:test && npm run -s ci:secrets && npm run -s ci:migrations` -- pass
