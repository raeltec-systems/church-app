# Cross-epic contracts and owner seams (story 1.5)

Migration: `supabase/migrations/20261003190000_cross_epic_contracts.sql`.

## Wire contract v1

- **Fixtures.** `packages/contracts/fixtures/v1/*.json` holds the valid and invalid cases for each kind, with the exact `field_errors` each invalid case must produce. Three implementations must pass them:
  - SQL: `app.contract_check(kind, value)`, the authority. `npm run db:smoke` runs `supabase/tests/contract_fixtures_check.sh`.
  - Dart: `packages/contracts/dart`, package `church_contracts`, used by both Flutter clients. Run `dart test` there.
  - TypeScript: `packages/contracts/ts`, kept for the Q10 React/Next.js alternative. Run `npm run contracts:test`.
- **Kinds.**
  - Identity and attribution: `member_ref`, `account_ref`, `actor`.
  - Sources and reminders: `source_ref`, `task_source`, `notification_key`, `lifecycle_event`.
  - Values: `instant`, `zoned_local`, `money`.
  - Commands: `command_request`, `command_response`.
- **Changing the contract.** Add a fixture first, then make all three implementations pass it. Removing a field or tightening a rule needs a new contract version, and older supported clients keep the old one.
- **Client vs server checks.** Clients check shape only. Only the server checks:
  - that a source type, purpose or reminder kind is registered (`app.contract_check_source`, `app.contract_reminder_key`)
  - that an IANA zone exists (`app.contract_require('zoned_local', …)`)
  - the money scale for a currency (`app.contract_money_amount`, which needs gate `q9_money`)

## Owner registry

- **Prefixes.** Every `app` table, view, sequence and function name starts with its owning module's prefix, as listed in `app.contract_module_prefixes`. A new owner adds its module and prefix in its first migration.
- **Dependencies.** `app.contract_module_dependencies` holds the allowed edges, copied from the architecture's dependency diagram.
- **Guards.** pgTAP fails when either of these returns rows:
  - `app.contract_unowned_objects()`: objects with no owner prefix
  - `app.contract_boundary_violations()`: a literal `app.<prefix>` reference to an owner the module may not depend on. This is a lint over function source, so it does not see dynamic SQL. Never build another owner's object name in a string; register a hook instead.
- **Retired objects.** Retire an object by revoking all privileges and renaming it with the `retired_` prefix. Drops wait for a cleanup the owner approves.

## Registering as an owner (in the owner's own migration)

```sql
-- Source type plus check hook: (source_ref jsonb) returns jsonb {"current": bool, "revision": int}
select app.contract_register_source_type('cells', 'cells_meeting', 'app.cells_meeting_source_check(jsonb)');
select app.contract_register_purpose('cells', 'cells_meeting', 'missing_report');
select app.contract_register_reminder_kind('cells', 'cells_meeting', 'report_due');
-- Lifecycle hook: (lifecycle_event jsonb) returns void. It runs inside Identity's transaction.
select app.contract_register_lifecycle_hook('cells', 'cell_transferred', 'app.cells_on_cell_transferred(jsonb)');
```

A registration is refused (SQLSTATE `PCTR1`) when:
- the handler is not an `app` function carrying the registering module's prefix
- the handler's signature is wrong
- the event is unknown
- the module is not an owner
- the module registers a purpose or reminder kind on a source type it does not own

Identity calls `app.contract_dispatch_lifecycle(event)` in lock order: domain owners, then follow-ups, then notifications. If any hook fails, the whole lifecycle change rolls back. A registered hook whose function no longer exists also fails the dispatch, so the change fails closed.

## Policy gates and environment

- **Gates are closed by default.** `app.policy_gates` lists `q1_auth_recovery`, `q2_church_time`, `q4_personal_data`, `q9_money`, `q12_operations`, `private_access` and `outbound_sending`. Every gate starts `unresolved`.
- **Reading a gate.** `app.policy_effective(gate)` raises the kernel's `unavailable` with `{<gate>: "gate_closed"}` unless one of these holds:
  - the gate is approved, or
  - the environment is marked `local` or `staging` and the gate has a labelled fixture. Only Q2 (`Etc/UTC`) and Q9 (`XTS`, scale 2) have fixtures.
- **Environment marker.** `app.platform_environment`:
  - The local seed marks the database `local`.
  - A database with no row behaves as **production**, so a hosted project ignores fixtures until its operator runs `select app.platform_set_environment('staging', '<operator>');`. That is an entry 8 / owner action.
- **Approving a gate.** Only the owner approves, per environment, with an attributed note:
  `select app.policy_approve('q2_church_time', '{"zone": "<IANA zone>", ...}', '<owner name>', '<decision reference>');`
  A value that carries a `fixture_label` cannot be approved. No client role can execute any of these functions.
