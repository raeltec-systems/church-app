# Command foundation (story 1.4)

Every state change goes through one transactional command kernel, `app.cmd_execute`, in
`supabase/migrations/20261003123459_command_foundation.sql`. The synthetic `fixture_counter`
aggregate is the reference consumer.

## Wire contract

- Call: `POST /rest/v1/rpc/<command_fn>` with `Content-Profile: api` and a user JWT.
- Body: `{version: 1, command, request_id, expected_revision, payload}`.
  - `request_id` is a UUID that the caller generates.
  - `expected_revision` is `null` for a create and the current revision for a mutation.
- Success: `{request_id, data, revision}`.
- Error (HTTP 200): `{request_id, code, message, field_errors[, current_revision]}`.
  - `code` is one of `validation_failed`, `unauthenticated`, `forbidden`, `not_found`, `conflict`, `rate_limited` or `unavailable`.
  - Messages are fixed, safe text and never include SQL detail.
- Timeout means the outcome is unknown. Retry with the same `request_id` and the same body to get the original result. Sending the same `request_id` with a changed body returns `conflict`.

## Adding a command

1. Write a handler `app.<owner>_<aggregate>_<verb>(p_actor uuid, p_expected_revision bigint, p_payload jsonb) returns jsonb` with `set search_path = ''` and qualified names. It must:
   - reject unknown payload fields and validate inputs with `app.cmd_fail('validation_failed', '{"field": "reason"}')`
   - lock the aggregate `for update`
   - check scope, returning `not_found` for rows outside the caller's scope
   - check the revision, returning `app.cmd_fail('conflict', null, current_revision)` on a mismatch
   - mutate the aggregate and bump its revision
   - return `{aggregate_type, aggregate_id, revision, data}`
2. Add the command name to a `security definer` entry function in `app`, which calls `app.cmd_execute(...)` with the handler's `regprocedure`. That function holds the allowlist, so commands it does not list cannot run.
3. Expose it through an `api` wrapper function that is `security invoker` and SQL-only.
4. `revoke all` on every new function from `public, anon, authenticated, service_role`. Then grant EXECUTE only on the `app` entry function and the `api` wrapper, and only to the roles that need them.
5. Add pgTAP cases to `supabase/tests/` and, for races, HTTP cases like `command_api_smoke.sh`.

## Seams that later epics replace

- `app.cmd_current_actor()` currently returns the JWT `sub`. Identity replaces it with the AD-3 live-access predicate.
- `app.cmd_authorize(actor, command)` currently checks the synthetic `app.fixture_command_grants` table. Identity replaces it with real grants and scope. It must keep locking authority rows `for share` before receipts and aggregates.

## Locks and atomicity

- Locks are taken in this order: authority rows, then the receipt key, then the aggregates (by type and ID), then follow-ups, then notifications.
- If anything fails after envelope validation, the mutation and the receipt reservation are both rolled back. A failed command therefore leaves no receipt.
- The security advisor reports `rls_enabled_no_policy` (INFO) on the three `app` tables. This is intended: client roles get no table access, and only the definer functions touch these tables.
