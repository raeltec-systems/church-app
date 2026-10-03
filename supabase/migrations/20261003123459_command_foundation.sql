-- Command foundation (story 1.4, AD-2 and Consistency Conventions).
--
-- A reusable transactional command kernel in the non-exposed `app` schema plus ONE synthetic
-- aggregate (`fixture_counter`) that exercises it through the exposed `api` schema. No feature
-- business rules live here.
--
-- Envelope
--   request : version (1), command, request_id (caller UUID), expected_revision, payload (object)
--   success : {request_id, data, revision}
--   error   : {request_id, code, message, field_errors[, current_revision]}
--   codes   : validation_failed | unauthenticated | forbidden | not_found | conflict
--             | rate_limited | unavailable
--
-- Transaction shape (app.cmd_execute)
--   validate envelope -> resolve current actor -> authorize (lock authority row FOR SHARE)
--   -> reserve receipt (actor, command, request_id) with payload hash; an existing receipt with
--      the same hash replays its stored result, a different hash is a conflict
--   -> handler locks the aggregate FOR UPDATE, checks scope and expected_revision, mutates
--   -> store the result on the receipt.
--   Everything after envelope validation runs in one subtransaction: any failure rolls back
--   the mutation AND the receipt, and returns an error envelope without SQL text.
--
-- Lock order: authority rows (Identity) -> receipt key -> domain aggregates. A receipt key is
-- private to one actor/command/request, so it only serialises duplicates of the same request.
--
-- Owner prefixes: cmd_* = API command kernel; fixture_* = synthetic test aggregate (fixture only).

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.cmd_receipts (
  actor_id uuid not null,
  command text not null,
  request_id uuid not null,
  payload_hash bytea not null,
  aggregate_type text,
  aggregate_id uuid,
  -- Null only while reserved inside the owning transaction; always set once committed.
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (actor_id, command, request_id)
);

comment on table app.cmd_receipts is
  'owner: cmd. Idempotency receipts: one per actor/command/request_id, bound to a payload hash. '
  'Written only inside the command transaction.';

create table app.fixture_command_grants (
  actor_id uuid not null,
  command text not null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  is_synthetic boolean not null default true check (is_synthetic),
  primary key (actor_id, command)
);

comment on table app.fixture_command_grants is
  'owner: fixture. SYNTHETIC command authority used only by the command-foundation fixture. '
  'The identity epic replaces app.cmd_authorize with real grants; never real member data.';

create table app.fixture_counters (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null,
  intent_key text not null check (length(btrim(intent_key)) between 1 and 100),
  value integer not null default 0 check (value between 0 and 1000),
  revision bigint not null default 1 check (revision >= 1),
  is_synthetic boolean not null default true check (is_synthetic),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, intent_key)
);

comment on table app.fixture_counters is
  'owner: fixture. SYNTHETIC aggregate that exercises the command kernel. No business meaning.';

alter table app.cmd_receipts enable row level security;
alter table app.fixture_command_grants enable row level security;
alter table app.fixture_counters enable row level security;

-- No client role touches these tables directly (no policies, no privileges). The command
-- implementation is SECURITY DEFINER and runs as the table owner.
revoke all on table app.cmd_receipts, app.fixture_command_grants, app.fixture_counters
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Kernel helpers (internal: no client EXECUTE)
-- ---------------------------------------------------------------------------------------------

-- Raise a domain error. Caught by app.cmd_execute and turned into an error envelope.
create function app.cmd_fail(
  p_code text,
  p_field_errors jsonb default null,
  p_current_revision bigint default null
) returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'PCMD1',
    message = p_code,
    detail = jsonb_build_object(
      'field_errors', coalesce(p_field_errors, '{}'::jsonb),
      'current_revision', p_current_revision
    )::text;
end;
$$;

-- Safe, fixed user-facing messages. Never SQL text or restricted content.
create function app.cmd_error_message(p_code text) returns text
language sql
immutable
set search_path = ''
as $$
  select case p_code
    when 'validation_failed' then 'The request is not valid.'
    when 'unauthenticated' then 'Sign in to continue.'
    when 'forbidden' then 'You are not allowed to do this.'
    when 'not_found' then 'The item was not found.'
    when 'conflict' then 'The item changed or this request was already used. Reload and try again.'
    when 'rate_limited' then 'Too many requests. Try again later.'
    else 'The service could not complete the request. Try again.'
  end;
$$;

create function app.cmd_error_envelope(
  p_request_id uuid,
  p_code text,
  p_field_errors jsonb default null,
  p_current_revision bigint default null
) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'request_id', p_request_id,
    'code', p_code,
    'message', app.cmd_error_message(p_code),
    'field_errors', coalesce(p_field_errors, '{}'::jsonb)
  ) || case
         when p_current_revision is null then '{}'::jsonb
         else jsonb_build_object('current_revision', p_current_revision)
       end;
$$;

-- UTC RFC3339 wire form for timestamps.
create function app.cmd_utc(p_at timestamptz) returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
$$;

-- Current-actor seam. Today: the verified JWT subject. The identity epic replaces the body with
-- the AD-3 live-access predicate (trusted password AMR, live session, approved link, holds).
-- Fails closed when no actor is present.
create function app.cmd_current_actor() returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    perform app.cmd_fail('unauthenticated');
  end if;
  return v_actor;
end;
$$;

-- Authorization seam. Locks the authority row FOR SHARE so a concurrent revocation waits for
-- in-flight commands, and a command that starts after the revocation commits is denied.
-- Runs before any existence check or receipt replay (no disclosure, access rechecked on replay).
create function app.cmd_authorize(p_actor uuid, p_command text) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform 1
    from app.fixture_command_grants g
   where g.actor_id = p_actor
     and g.command = p_command
     and g.revoked_at is null
     for share;
  if not found then
    perform app.cmd_fail('forbidden');
  end if;
end;
$$;

create function app.cmd_payload_hash(
  p_version integer,
  p_command text,
  p_expected_revision bigint,
  p_payload jsonb
) returns bytea
language sql
immutable
set search_path = ''
as $$
  -- jsonb text output is canonical (sorted keys, normalised whitespace).
  select sha256(convert_to(jsonb_build_object(
    'version', p_version,
    'command', p_command,
    'expected_revision', p_expected_revision,
    'payload', p_payload
  )::text, 'UTF8'));
$$;

-- Reserve the receipt key. Returns null when this transaction now owns a fresh reservation,
-- or the stored result when the same request was already committed with the same payload.
-- A concurrent duplicate waits here on the primary key until the first transaction ends.
create function app.cmd_reserve_receipt(
  p_actor uuid,
  p_command text,
  p_request_id uuid,
  p_payload_hash bytea
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hash bytea;
  v_result jsonb;
begin
  insert into app.cmd_receipts (actor_id, command, request_id, payload_hash)
  values (p_actor, p_command, p_request_id, p_payload_hash)
  on conflict do nothing;
  if found then
    return null;
  end if;

  select r.payload_hash, r.result
    into v_hash, v_result
    from app.cmd_receipts r
   where r.actor_id = p_actor
     and r.command = p_command
     and r.request_id = p_request_id;

  if v_hash is distinct from p_payload_hash then
    perform app.cmd_fail('conflict');
  end if;
  if v_result is null then
    perform app.cmd_fail('unavailable');
  end if;
  return v_result;
end;
$$;

-- The kernel. p_handler(actor uuid, expected_revision bigint, payload jsonb) returns
-- {aggregate_type, aggregate_id, revision, data} and raises app.cmd_fail for domain errors.
create function app.cmd_execute(
  p_version integer,
  p_command text,
  p_request_id uuid,
  p_expected_revision bigint,
  p_payload jsonb,
  p_handler regprocedure,
  p_revision_required boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor uuid;
  v_stored jsonb;
  v_outcome jsonb;
  v_envelope jsonb;
  v_code text;
  v_detail text;
  v_detail_json jsonb;
begin
  -- Envelope validation (no state touched yet).
  if p_version is distinct from 1 then
    return app.cmd_error_envelope(p_request_id, 'validation_failed', '{"version": "unsupported"}');
  end if;
  if p_request_id is null then
    return app.cmd_error_envelope(null, 'validation_failed', '{"request_id": "required"}');
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return app.cmd_error_envelope(p_request_id, 'validation_failed', '{"payload": "must_be_object"}');
  end if;
  if p_revision_required and p_expected_revision is null then
    return app.cmd_error_envelope(p_request_id, 'validation_failed', '{"expected_revision": "required"}');
  end if;
  if not p_revision_required and p_expected_revision is not null then
    return app.cmd_error_envelope(p_request_id, 'validation_failed', '{"expected_revision": "must_be_null"}');
  end if;

  begin
    v_actor := app.cmd_current_actor();
    perform app.cmd_authorize(v_actor, p_command);

    v_stored := app.cmd_reserve_receipt(
      v_actor, p_command, p_request_id,
      app.cmd_payload_hash(p_version, p_command, p_expected_revision, p_payload)
    );
    if v_stored is not null then
      return v_stored;
    end if;

    execute format('select %s($1, $2, $3)', p_handler::regproc)
      into v_outcome
      using v_actor, p_expected_revision, p_payload;

    v_envelope := jsonb_build_object(
      'request_id', p_request_id,
      'data', v_outcome -> 'data',
      'revision', (v_outcome ->> 'revision')::bigint
    );

    update app.cmd_receipts r
       set result = v_envelope,
           aggregate_type = v_outcome ->> 'aggregate_type',
           aggregate_id = (v_outcome ->> 'aggregate_id')::uuid
     where r.actor_id = v_actor
       and r.command = p_command
       and r.request_id = p_request_id
       and r.result is null;
    if not found then
      perform app.cmd_fail('unavailable');
    end if;

    return v_envelope;
  exception
    when sqlstate 'PCMD1' then
      get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
      v_detail_json := v_detail::jsonb;
      return app.cmd_error_envelope(
        p_request_id, v_code,
        v_detail_json -> 'field_errors',
        (v_detail_json ->> 'current_revision')::bigint
      );
    when check_violation or not_null_violation or invalid_text_representation
      or numeric_value_out_of_range then
      raise log 'cmd % request % rejected: sqlstate %', p_command, p_request_id, sqlstate;
      return app.cmd_error_envelope(p_request_id, 'validation_failed');
    when unique_violation then
      raise log 'cmd % request % rejected: sqlstate %', p_command, p_request_id, sqlstate;
      return app.cmd_error_envelope(p_request_id, 'conflict');
    when others then
      raise log 'cmd % request % failed: sqlstate %', p_command, p_request_id, sqlstate;
      return app.cmd_error_envelope(p_request_id, 'unavailable');
  end;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Synthetic fixture aggregate handlers (internal: no client EXECUTE)
-- ---------------------------------------------------------------------------------------------

create function app.fixture_counter_data(p_row app.fixture_counters) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'intent_key', p_row.intent_key,
    'value', p_row.value,
    'is_synthetic', p_row.is_synthetic,
    'updated_at', app.cmd_utc(p_row.updated_at)
  );
$$;

create function app.fixture_counter_outcome(p_row app.fixture_counters) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'fixture_counter',
    'aggregate_id', p_row.id,
    'revision', p_row.revision,
    'data', app.fixture_counter_data(p_row)
  );
$$;

-- fixture_counter.create  payload {intent_key: string}; expected_revision must be null.
create function app.fixture_counter_create(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_row app.fixture_counters;
begin
  if exists (select 1 from jsonb_object_keys(p_payload) k where k <> 'intent_key') then
    perform app.cmd_fail('validation_failed', '{"payload": "unknown_field"}');
  end if;
  if jsonb_typeof(p_payload -> 'intent_key') is distinct from 'string'
     or length(btrim(p_payload ->> 'intent_key')) not between 1 and 100 then
    perform app.cmd_fail('validation_failed', '{"intent_key": "required"}');
  end if;

  insert into app.fixture_counters (created_by, intent_key)
  values (p_actor, p_payload ->> 'intent_key')
  returning * into v_row;

  return app.fixture_counter_outcome(v_row);
end;
$$;

-- fixture_counter.increment  payload {counter_id: uuid, by: integer -1000..1000, not 0}.
create function app.fixture_counter_increment(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_by integer;
  v_row app.fixture_counters;
begin
  if exists (select 1 from jsonb_object_keys(p_payload) k where k not in ('counter_id', 'by')) then
    perform app.cmd_fail('validation_failed', '{"payload": "unknown_field"}');
  end if;
  if jsonb_typeof(p_payload -> 'counter_id') is distinct from 'string'
     or (p_payload ->> 'counter_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform app.cmd_fail('validation_failed', '{"counter_id": "invalid"}');
  end if;
  if jsonb_typeof(p_payload -> 'by') is distinct from 'number'
     or (p_payload ->> 'by') !~ '^-?[0-9]{1,4}$'
     or (p_payload ->> 'by')::integer not between -1000 and 1000
     or (p_payload ->> 'by')::integer = 0 then
    perform app.cmd_fail('validation_failed', '{"by": "invalid"}');
  end if;
  v_id := (p_payload ->> 'counter_id')::uuid;
  v_by := (p_payload ->> 'by')::integer;

  select * into v_row from app.fixture_counters c where c.id = v_id for update;
  -- Scope: only the creating actor may act on a counter. Out-of-scope rows look missing.
  if not found or v_row.created_by <> p_actor then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;

  -- An out-of-range result violates the value check here, after the receipt was reserved;
  -- the kernel rolls both back.
  update app.fixture_counters c
     set value = c.value + v_by,
         revision = c.revision + 1,
         updated_at = now()
   where c.id = v_id
  returning * into v_row;

  return app.fixture_counter_outcome(v_row);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------------------------

-- Elevated implementation: SECURITY DEFINER in non-exposed `app`, fixed empty search_path,
-- allowlisted commands only. Actor and authority are resolved inside, never from the payload.
create function app.fixture_counter_command(
  p_version integer,
  p_command text,
  p_request_id uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  case p_command
    when 'fixture_counter.create' then
      return app.cmd_execute(p_version, p_command, p_request_id, p_expected_revision, p_payload,
        'app.fixture_counter_create(uuid, bigint, jsonb)'::regprocedure, false);
    when 'fixture_counter.increment' then
      return app.cmd_execute(p_version, p_command, p_request_id, p_expected_revision, p_payload,
        'app.fixture_counter_increment(uuid, bigint, jsonb)'::regprocedure, true);
    else
      return app.cmd_error_envelope(p_request_id, 'validation_failed', '{"command": "unsupported"}');
  end case;
end;
$$;

-- Exposed command wrapper: invoker security, so the caller's own EXECUTE privileges apply.
-- PostgREST: POST /rest/v1/rpc/fixture_counter_command with Content-Profile: api.
create function api.fixture_counter_command(
  version integer,
  command text,
  request_id uuid,
  expected_revision bigint default null,
  payload jsonb default '{}'::jsonb
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.fixture_counter_command(version, command, request_id, expected_revision, payload);
$$;

comment on function api.fixture_counter_command(integer, text, uuid, bigint, jsonb) is
  'SYNTHETIC fixture command (story 1.4) exercising the transactional command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing for PUBLIC/anon/service_role; authenticated may only call the wrapper and
-- its definer entry point.
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cmd_fail(text, jsonb, bigint),
  app.cmd_error_message(text),
  app.cmd_error_envelope(uuid, text, jsonb, bigint),
  app.cmd_utc(timestamptz),
  app.cmd_current_actor(),
  app.cmd_authorize(uuid, text),
  app.cmd_payload_hash(integer, text, bigint, jsonb),
  app.cmd_reserve_receipt(uuid, text, uuid, bytea),
  app.cmd_execute(integer, text, uuid, bigint, jsonb, regprocedure, boolean),
  app.fixture_counter_data(app.fixture_counters),
  app.fixture_counter_outcome(app.fixture_counters),
  app.fixture_counter_create(uuid, bigint, jsonb),
  app.fixture_counter_increment(uuid, bigint, jsonb),
  app.fixture_counter_command(integer, text, uuid, bigint, jsonb),
  api.fixture_counter_command(integer, text, uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.fixture_counter_command(integer, text, uuid, bigint, jsonb)
  to authenticated;
grant execute on function api.fixture_counter_command(integer, text, uuid, bigint, jsonb)
  to authenticated;
