# Cross-epic contracts and owner seams (story 1.5)

Migration: `supabase/migrations/20261003134340_cross_epic_contracts.sql`.

## Wire contract v1

- **Fixtures.** `packages/contracts/fixtures/v1/*.json` holds the valid and invalid cases for each kind, with the exact `field_errors` each invalid case must produce. Three implementations must pass them:
  - SQL: `app.contract_check(kind, value)`, the authority. `npm run db:smoke` runs `supabase/tests/contract_fixtures_check.sh`, which also sends every `command_request` fixture through `api.fixture_counter_command`. The kernel's envelope validation (`app.cmd_execute`) calls `contract_check`; the only codes it adds are per command:
    - `command`: `unsupported`
    - `expected_revision`: `required` or `must_be_null`
  - Dart: `packages/contracts/dart`, package `church_contracts`, used by both Flutter clients. Run `dart test` and `dart test -p chrome` there; set `CHROME_EXECUTABLE` if Chrome is not on PATH. The tests read embedded copies of the fixtures from `test/fixtures.g.dart`. After changing a fixture, regenerate them with `dart run tool/embed_fixtures.dart`; a VM test fails while the copy is stale.
  - TypeScript: `packages/contracts/ts`, kept for the Q10 React/Next.js alternative. Run `npm run contracts:test`.
- **Kinds.**
  - Identity and attribution: `member_ref`, `account_ref`, `actor`.
  - Sources and reminders: `source_ref`, `task_source`, `notification_key`, `lifecycle_event`.
  - Values: `instant`, `zoned_local`, `money`.
  - Commands: `command_request`, `command_response`.
- **Rules.**
  - Objects are strict. Every unknown key is reported on itself as `{"<key>": "unknown_field"}`.
  - Integers are checked by value: `1`, `1.0` and `1e0` are all the same integer. Revisions run from 1 to 2^53−1.
  - UUIDs must be lowercase.
  - Money is an unsigned decimal string. Whether an amount may be negative belongs to the owner's own rules.
  - Zones are canonical IANA `Area/Location` names, or `UTC`.
- **Changing the contract.** Every change needs a new contract version: adding, removing or renaming a field, a kind, a lifecycle event or an error code, and loosening or tightening any rule. The one exception is a new field error code, because that vocabulary is open (below). This follows from strict objects, because a client of the old version rejects an unknown key. Add the fixtures first, then make all three implementations pass them. Older supported clients keep the old version.
- **Field error codes** are an open, documented vocabulary: any lower_snake_case token (`^[a-z][a-z0-9_]{0,62}$`) is a valid code, so adding a command-specific code needs no new contract version. A value of another shape still makes the envelope invalid. (Fixed after story 2.8: the list below used to be closed, and the clients read every Identity/Cells refusal with a specific code as an unknown outcome. See `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/fix-field-error-vocabulary.md`.)
  - Core codes of the shape checks (`app.contract_field_error_codes()`, Dart `fieldErrorCodeNames`, TS `FIELD_ERROR_CODES`):
    - `required`, `invalid`, `unknown_field`, `must_be_object`
    - `unsupported`, `must_be_null`, `out_of_range`
    - `unknown`, `unregistered`, `scale_exceeded`, `gate_closed`
  - Command-specific codes are documented with their command in `docs/runbooks/identity-access.md` (for example `last_admin`, `reauthenticate`, `held`, `password_reset_required`, `stale`, `other_changes`, `open_request`, `current`, `decided`).
  - Clients map the codes they know to specific notices. Any other code falls back to the notice for the envelope's top-level `code`, with its `message`. A well-formed error envelope is never an unknown outcome because of its field error codes.
- **Client vs server checks.** Clients check shape only. Only the server checks:
  - registration membership (`app.contract_check_source`, `app.contract_reminder_key`)
  - that an IANA zone exists (`app.contract_require('zoned_local', …)`)
  - the money scale for a currency (`app.contract_money_amount`, which needs gate `q9_money`)

## Owner registry and guards

- **Prefixes.** Every `app` table, view, sequence and function name starts with its owning module's prefix, as listed in `app.contract_module_prefixes`. A new owner adds its module and prefix in its first migration.
- **Dependencies.** `app.contract_module_dependencies` holds the allowed edges, copied from the architecture's dependency diagram.
- **Exceptions.** `app.contract_dependency_exceptions` names single functions that may reach outside their module's edges. Today there is only one: `app.cmd_authorize(uuid,text)` reaches `fixture`, until the identity epic replaces it.
- **Retired functions.** `app.contract_retired_functions` lists the exact retired functions (three from story 1.4). Any other `retired_*` name is unowned. Retire an object by revoking all privileges and renaming it, then add its exact signature to that list. Drops wait for a cleanup the owner approves.
- **Guards.** pgTAP fails when any of these returns rows:
  - `app.contract_unowned_objects()`
  - `app.contract_unpinned_functions()`: every `app`/`api` function must set `search_path = ''`, so every reference is schema-qualified and visible to the guard
  - `app.contract_boundary_violations()`, which scans function bodies (including `BEGIN ATOMIC` bodies), view definitions, RLS policy expressions, column defaults and triggers on `app` tables. A trigger must run an `app` function. Dynamic SQL is not visible to it; reach another owner through a registered hook instead.

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
- the handler does not set `search_path = ''`
- the handler's signature is wrong
- the event is unknown
- the module is not an owner
- the module registers a purpose or reminder kind on a source type it does not own

Identity calls `app.contract_dispatch_lifecycle(event)` in lock order: domain owners, then follow-ups, then notifications. If any hook fails, the whole lifecycle change rolls back, and so does a registered hook whose function no longer exists.

## Policy gates and environment

- **Gates are closed by default.** `app.policy_gates` lists `q1_auth_recovery`, `q2_church_time`, `q4_personal_data`, `q9_money`, `q12_operations`, `private_access` and `outbound_sending`. Every gate starts `unresolved`.
- **Reading a gate.** `app.policy_effective(gate)` raises the kernel's `unavailable` with `{"policy": "gate_closed"}`, which names no internal gate, unless one of these holds:
  - the gate is approved, or
  - the environment is marked `local` or `staging` and the gate has a labelled fixture. Only Q2 (`UTC`) and Q9 (`XTS`, scale 2) have fixtures.
- **Environment marker.** `app.platform_environment`, with every change recorded in `app.platform_environment_history`:
  - **Nothing sets it automatically**: no seed and no migration writes it. A database with no marker behaves as **production**.
  - To use fixture policy on a local database, run `select app.platform_set_environment('local', '<you>');`.
  - On hosted staging, the operator runs `select app.platform_set_environment('staging', '<operator>');`. That is an entry 8 / owner action.
  - **Transitions are one-way.** A database marked production can only be re-marked production. A database that was ever marked staging or production can never be marked local.
  - **Restores and clones.** A restored or cloned database keeps the marker of its source. The restore procedure must re-assert the correct marker before the database serves anything, for example `select app.platform_set_environment('production', '<operator>')` on a production restore. A clone made for testing must be created as a fresh database, not by downgrading a copy. A restore also lands held (private_access and outbound_sending closed) until the independent recovery journal is reconciled; see `backup-and-restore.md` (story 1.10).
- **Approving a gate.** Only the owner approves, per environment, with an attributed note:
  `select app.policy_approve('q2_church_time', '{"zone": "<IANA zone>", ...}', '<owner name>', '<decision reference>');`
  - `q9_money` must look like `{"currencies": {"<ISO 4217 code>": <integer scale 0..6>}}`.
  - A value that carries a `fixture_label` cannot be approved.
  - No client role can execute any of these functions.
