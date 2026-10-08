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
- **Changing the contract.** Every change needs a new contract version: adding, removing or renaming a field, a kind or an error code, removing or renaming a lifecycle event, and loosening or tightening any rule. Two exceptions: a new field error code, because that vocabulary is open (below); and a new lifecycle event name, which is additive within v1 while every consumer is a server-side registered hook (lifecycle events go only to database hooks registered with `app.contract_register_lifecycle_hook`; no client receives or parses them). Removing or renaming an event, or adding the first client-visible consumer of lifecycle events, needs a new version. The shared Dart and TypeScript packages carry the event list only for fixture parity; `packages/client_core/test/boundaries_test.dart` fails if client or app code starts to consume it. Stories 2.8 (`sessions_revoked`) and 2.10 (`membership_deactivated`, `membership_restored`) are covered by this rule. This follows from strict objects, because a client of the old version rejects an unknown key. Add the fixtures first, then make all three implementations pass them. Older supported clients keep the old version.
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
- **Retired functions.** `app.contract_retired_functions` lists the exact retired functions (three from story 1.4). Any other `retired_*` name is unowned. Retire an object by revoking all privileges and renaming it, then add its exact signature to that list and a row to the ledger below. Drops wait for a cleanup the owner approves.
- **Retired-object ledger.** Every retired object waiting for an owner-approved drop. pgTAP `supabase/tests/retired_objects_ledger_test.sql` pins this exact set and that no client role holds any privilege on it. A new retirement adds its rows here and there; an approved drop removes them from both.

  | Object (with its index and sequence) | Kind | Retired by | Why | Before dropping |
  |---|---|---|---|---|
  | `app.retired_fixture_counter_command_v0(...)`, `api.retired_fixture_counter_command_v0(...)`, `app.retired_cmd_execute_v0(...)` | functions | 1.4 | typed entry points superseded by the jsonb envelope | remove from `app.contract_retired_functions` |
  | `app.ops_retired_operator_actions_v0` (`_pkey`, `_id_seq`) | table | 2.3 | operator journal CHECK widened (rows copied) | none |
  | `app.ops_retired_operator_actions_v1` (`_pkey`, `_id_seq`) | table | 2.12 | operator journal CHECK widened (rows copied) | none |
  | `app.identity_retired_access_audit_v0` (`_pkey`, `_target`, `_event_id_seq`) | table | 2.12 | access audit CHECK widened (rows copied) | take it out of the deletion retention rules ([identity-access.md](identity-access.md)) |
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

Lifecycle events (contract v1): `access_hold_applied`, `access_hold_released`, `scope_revoked`, `account_deactivated` (an account unlinked), `deletion_requested` (dispatched from story 2.11), `cell_transferred` (emitted by Cells), `sessions_revoked` (story 2.8), `membership_deactivated` / `membership_restored` (story 2.10) and `member_deleted` (story 2.11). The last four were added within v1 under the additive server-only rule above (fixtures, Dart and TypeScript mappings updated for parity).

**Handover hooks (story 2.10).** An owner whose work must be handed over when a membership is deactivated also registers a read-only handover hook with Identity: `select app.identity_register_handover_hook('<module>', 'app.<prefix>_report_handover(jsonb)'::regprocedure);`. It returns `{"obligations": [{"kind", "subject_id", "last_responsible"}]}`; `last_responsible` refuses the deactivation until the work is handed over. The owner resolves recorded obligations with `app.identity_resolve_handover_obligation('<module>', '<obligation_id>', 'handed_over' | 'no_longer_needed')`. See `identity-access.md`, story 2.10.

**Deletion hooks (story 2.11).** An owner that keeps personal data of a member registers a deletion hook before it activates: `select app.identity_register_deletion_hook('<module>', 'app.<prefix>_erase_member(jsonb)'::regprocedure);`. The handler gets `{member_id, account_id, deletion_id, phase}`, once for every Auth account the member ever linked (`account_id` null for a member who never had one); `phase` `erase` removes or anonymises the owner's personal data of that member (idempotent; Storage objects through the Storage API) and `check` only counts what is left; both answer `{"remaining": <int>}`. A full deletion completes only when every hook answers 0. Cells registers `app.cells_erase_member`. A deletion also records the member's handover obligations (2.10 hooks); erasure waits until they are resolved. See `identity-access.md`, story 2.11.

**Journal replay hooks (story 2.11, platform).** `app.rcv_apply_journal_entry` (1.10) calls every hook registered with `app.rcv_register_replay_hook('<module>', 'app.<prefix>_rcv_replay(jsonb)'::regprocedure)` with `{entry, restoring}` after recording the entry. A hook re-applies its own deny-only effects only while a restore is held (`restoring` true), and raises when it cannot, which keeps the restore held. Identity registers `app.identity_rcv_replay`.

## Notifications owner operations (story 3.1)

Call these inside your own command's transaction, after locking and changing your source. Notifications is last in the AD-2 lock order. Your module needs a dependency edge to `notifications`: every domain owner, Duties and Follow-ups already has one. Neither function is client-executable. The full runbook is [notifications.md](notifications.md).

```sql
-- Enqueue one reminder (contract v1 `notification_key`). Validates the key, the registered
-- reminder kind, your source's CURRENT revision through your check hook, and the Q2 gate
-- (fixture in local/staging, closed in production -> unavailable, so your command rolls back).
-- Answers {job_id, job_state, created}; the same logical key again changes nothing (a cancelled
-- job is never revived).
select app.notifications_enqueue(jsonb_build_object(
  'source_type', 'cells_meeting', 'source_id', <id>, 'source_revision', <new revision>,
  'recipient_member_id', <member_id>, 'reminder_kind', 'report_due',
  'scheduled_at', app.cmd_utc(<instant>)));
-- Cancel your source's pending jobs (optionally one recipient or one kind). Answers {cancelled}.
select app.notifications_cancel(jsonb_build_object(
  'source_type', 'cells_meeting', 'source_id', <id>, 'reason', 'source_cancelled'));
```

- A revision change makes older pending jobs `obsolete` at the worker's recheck. Still cancel them explicitly when your transition makes them pointless.
- The worker delivers a job only while your check hook answers `current: true` for the job's revision.
- `app.contract_reminder_key` (1.5) stays the validation-only seam; `notifications_enqueue` calls it.
- The SYNTHETIC `fixture_reminder` source (owner `fixture`, kind `fixture_due`, edge `fixture -> notifications`) is the reference consumer.
- Since story 3.2, enqueue also refuses a source type that is not registered (`{"source_type": "unregistered"}`) and a kind without a reminder contract (`{"reminder_kind": "unregistered"}`). Register the contract below first.

## Reminder contracts: consumer guide (story 3.2)

Migration: `supabase/migrations/20261008074412_notifications_source_contracts.sql`. Duties, Cells, Follow-ups and every later reminder owner follow these steps in their **own** migration, before their first enqueue. The SYNTHETIC `fixture_reminder` source in that migration is the worked example.

1. **Register the source type, its purposes and its reminder kinds** (story 1.5, above): `contract_register_source_type`, `contract_register_purpose`, `contract_register_reminder_kind`.
2. **Write the reminder check.** It is an `app.<prefix>_...(jsonb) returns jsonb` function with `set search_path = ''` (usually `stable`, no locks). It receives the job's contract v1 `notification_key` (`source_type, source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at`) and answers **exactly** these four keys:

   | Key | Meaning |
   |---|---|
   | `current` | The source exists, is live and is still at `source_revision`. |
   | `revision` | The source's current revision, or `null` when it is gone. Must equal `source_revision` when `current` is true. |
   | `actionable` | The reminder still asks for something now: not answered, not expired, not past its usefulness. |
   | `recipient_eligible` | The recipient may still see this source (their scope, role or assignment is unchanged). Identity's own live-access predicate is checked by Notifications separately. |

   Any other key, a wrong type, a missing `revision` or a `current` that names another revision is refused at call time (PCTR1). That is the guard that keeps source content out of Notifications: never add a body, a name or a note to the answer.
3. **Register the reminder contract** for each kind:

   ```sql
   select app.contract_register_reminder_contract(
     'duties', 'duties_assignment', 'response_due',
     'app.duties_assignment_reminder_check(jsonb)'::regprocedure,
     '{"title": "Duty response needed",
       "body": "Please accept or decline your duty.",
       "link": "/duties/assignments/{source_id}"}'::jsonb);
   ```

   - `title` (1-60 characters) and `body` (1-160) are **fixed generic text**: no placeholders, no `{ } < > @ \`, no links (`http`, `www.`) and no runs of 7 or more digits (phone numbers). They appear in the inbox and, from entry 6, on lock screens. Never put prayer text, names, phone numbers, care or finance details here (functional requirements, Reminder reliability).
   - `link` is a relative client route: lower-case segments, at most one whole `{source_id}` segment, no scheme, host, query or fragment. Notifications fills in `{source_id}` only when the opened item is `current`.
   - The object takes exactly these three keys. A refused registration raises PCTR1 and names the fields, for example `{"body": "not_generic"}`.
   - Registering again from the owner's later migration replaces the contract (text, link or check). Only the module that owns the source type may register.
4. **Enqueue and cancel** with `app.notifications_enqueue` and `app.notifications_cancel` inside your command, as above. Cancel pending jobs when your transition makes them pointless (`source_revised`, `scope_revoked`, `source_expired`, ...); the worker also rechecks through your contract and ends a job `obsolete` (not current, or not actionable) or `ineligible` (recipient no longer admitted).
5. **Add the client route.** Add your screen's route to the client router, then add its pattern to `ClientPaths.deepLinkTargets` (`packages/client_core/lib/src/presentation/shell_routing.dart`). Until then the opened item shows "Still current" without an **Open** button. Your screen must still do its own authorised read: the target is a pointer, not a grant (AD-5).

**What a member sees when they open an item** (`api.notifications_open_item`, see [notifications.md](notifications.md)): `current` with your generic text and the resolved target only when your check answers `current`, `actionable` and `recipient_eligible`. Otherwise they see the generic `superseded` state: your generic text, no target, and no reason. Revoked, cancelled, expired and stale items look alike on purpose.

**Contract version.** This fits wire contract v1. Registration is server-side SQL; the check's input is the v1 `notification_key`; the open answer is a Notifications read projection, not a shared kind. Fixture cases in `notification_key.json` and `source_ref.json` pin that a private field (`body`, `recipient_phone`, `title`, `link`, `note`) is `unknown_field` in SQL, Dart and TypeScript.

## Policy gates and environment

- **Gates are closed by default.** `app.policy_gates` lists `q1_auth_recovery`, `q2_church_time`, `q4_personal_data`, `q9_money`, `q12_operations`, `private_access` and `outbound_sending`, plus `ops_alert_destination` and `ops_system_access` (story 1.9) and `identity_deletion_retention` (story 2.11, Q4: what a full deletion erases or anonymises). Every gate starts `unresolved`.
- **Reading a gate.** `app.policy_effective(gate)` raises the kernel's `unavailable` with `{"policy": "gate_closed"}`, which names no internal gate, unless one of these holds:
  - the gate is approved, or
  - the environment is marked `local` or `staging` and the gate has a labelled fixture. Only Q2 (`UTC`), Q9 (`XTS`, scale 2) and the Q4 deletion retention (`identity_deletion_retention`, labelled `TEST FIXTURE - Q4 retention and backup periods unapproved`) have fixtures.
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
