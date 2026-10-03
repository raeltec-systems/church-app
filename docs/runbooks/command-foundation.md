# Command foundation (story 1.4)

Every state change goes through one transactional command kernel, `app.cmd_execute`, in
`supabase/migrations/20261003123459_command_foundation.sql`, hardened by
`supabase/migrations/20261003131021_command_foundation_hardening.sql`. The synthetic `fixture_counter`
aggregate is the reference consumer.

## Wire contract

- Call: `POST /rest/v1/rpc/<command_fn>` with `Content-Profile: api` and a user JWT.
- Body: `{version: 1, command, request_id, expected_revision, payload}`. The `api` function takes this
  whole body as ONE unnamed `jsonb` parameter, so a missing or malformed field comes back as a
  `validation_failed` envelope naming the field, never as a raw SQL or PostgREST error.
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
   - mutate the aggregate and bump its revision; translate constraint outcomes it expects (for example a check or unique violation that means bad input) into `app.cmd_fail` itself, because the kernel reports any other error as `unavailable`
   - return `{aggregate_type, aggregate_id, revision, data}`
2. Write a scope function `app.<owner>_<aggregate>_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid) returns boolean`. It must say whether the actor still has scope on that stored aggregate, locking the rows it reads `for share`. The kernel calls it with the aggregate stored on the receipt before it replays any receipt, and answers `forbidden` without the stored result when it returns anything but true (AD-2 "recheck access before replaying").
3. Add the command name to a `security definer` entry function in `app`, which calls `app.cmd_execute(envelope, handler, scope, revision_required)` with the handler's and scope function's `regprocedure` (handler null for an unknown command). That function holds the allowlist, so commands it does not list cannot run.
4. Expose it through an `api` wrapper function that is `security invoker` and SQL-only.
5. `revoke all` on every new function from `public, anon, authenticated, service_role`. Then grant EXECUTE only on the `app` entry function and the `api` wrapper, and only to the roles that need them.
6. Add pgTAP cases to `supabase/tests/` and, for races, HTTP cases like `command_api_smoke.sh`.

## Seams that later epics replace

- `app.cmd_current_actor()` currently returns the JWT `sub`, read without a cast so that a missing or non-UUID `sub` is `unauthenticated`. Identity replaces it with the AD-3 live-access predicate.
- `app.cmd_authorize(actor, command)` currently checks the synthetic `app.fixture_command_grants` table. Identity replaces it with real grants and scope. It must keep locking authority rows `for share` before receipts and aggregates.

## Locks and atomicity

- Locks are taken in this order: authority rows, then the receipt key, then the aggregates (by type and ID), then follow-ups, then notifications.
- If anything fails after envelope validation, the mutation and the receipt reservation are both rolled back. A failed command therefore leaves no receipt.
- The security advisor reports `rls_enabled_no_policy` (INFO) on the three `app` tables. This is intended: client roles get no table access, and only the definer functions touch these tables.
