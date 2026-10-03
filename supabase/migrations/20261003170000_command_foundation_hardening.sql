-- Command foundation hardening (story 1.4 review follow-up). Amends
-- 20261003123459_command_foundation.sql, which is already applied and stays unchanged.
--
-- 1. Receipt replay rechecks the caller's current scope on the receipt's stored aggregate
--    through a per-command scope seam; out of scope replays are `forbidden`, with no stored data.
-- 2. The api command takes ONE jsonb envelope (PostgREST single unnamed json parameter), so a
--    missing or malformed field is a `validation_failed` envelope, never a raw SQL/PostgREST error.
-- 3. The current actor is resolved defensively: a missing or non-UUID `sub` is `unauthenticated`.
--    Only explicit input validation yields `validation_failed`; any other internal error is
--    `unavailable`. Handlers translate their own known constraint outcomes.
-- 4. Functions that use STABLE builtins (to_char, jsonb_build_object, convert_to) are STABLE.

-- ---------------------------------------------------------------------------------------------
-- Replace the old typed-parameter entry points and kernel (signatures change)
-- ---------------------------------------------------------------------------------------------
drop function api.fixture_counter_command(integer, text, uuid, bigint, jsonb);
drop function app.fixture_counter_command(integer, text, uuid, bigint, jsonb);
drop function app.cmd_execute(integer, text, uuid, bigint, jsonb, regprocedure, boolean);

-- ---------------------------------------------------------------------------------------------
-- Volatility corrections
-- ---------------------------------------------------------------------------------------------
alter function app.cmd_utc(timestamptz) stable;
alter function app.cmd_error_envelope(uuid, text, jsonb, bigint) stable;
alter function app.cmd_payload_hash(integer, text, bigint, jsonb) stable;
alter function app.fixture_counter_data(app.fixture_counters) stable;
alter function app.fixture_counter_outcome(app.fixture_counters) stable;

-- ---------------------------------------------------------------------------------------------
-- Defensive current-actor seam
-- ---------------------------------------------------------------------------------------------
create or replace function app.cmd_current_actor() returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_sub text;
begin
  -- Read the verified JWT subject without casting first: auth.uid() raises on a non-UUID sub.
  begin
    v_sub := coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    );
  exception when others then
    v_sub := null;
  end;
  if v_sub is null
     or v_sub !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform app.cmd_fail('unauthenticated');
  end if;
  return v_sub::uuid;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Kernel: one jsonb envelope, per-command handler and scope seam
-- ---------------------------------------------------------------------------------------------
-- p_handler(actor uuid, expected_revision bigint, payload jsonb) -> {aggregate_type,
--   aggregate_id, revision, data}; null means the command is not allowlisted.
-- p_scope(actor uuid, aggregate_type text, aggregate_id uuid) -> boolean: does the actor still
--   have scope on the stored aggregate? Called before any receipt replay.
create function app.cmd_execute(
  p_envelope jsonb,
  p_handler regprocedure,
  p_scope regprocedure,
  p_revision_required boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_uuid_re constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_errors jsonb := '{}'::jsonb;
  v_request_id uuid;
  v_command text;
  v_expected bigint;
  v_payload jsonb;
  v_actor uuid;
  v_stored jsonb;
  v_agg_type text;
  v_agg_id uuid;
  v_in_scope boolean;
  v_outcome jsonb;
  v_envelope jsonb;
  v_code text;
  v_detail text;
  v_detail_json jsonb;
begin
  -- Envelope validation: explicit, type-safe, no state touched, all field errors at once.
  if p_envelope is null or jsonb_typeof(p_envelope) <> 'object' then
    return app.cmd_error_envelope(null, 'validation_failed', '{"envelope": "must_be_object"}');
  end if;

  if jsonb_typeof(p_envelope -> 'request_id') = 'string'
     and (p_envelope ->> 'request_id') ~* v_uuid_re then
    v_request_id := (p_envelope ->> 'request_id')::uuid;
  elsif coalesce(jsonb_typeof(p_envelope -> 'request_id'), 'null') = 'null' then
    v_errors := v_errors || '{"request_id": "required"}';
  else
    v_errors := v_errors || '{"request_id": "invalid"}';
  end if;

  if coalesce(jsonb_typeof(p_envelope -> 'version'), 'null') = 'null' then
    v_errors := v_errors || '{"version": "required"}';
  elsif jsonb_typeof(p_envelope -> 'version') <> 'number' or (p_envelope ->> 'version') <> '1' then
    v_errors := v_errors || '{"version": "unsupported"}';
  end if;

  if p_handler is null then
    v_errors := v_errors || '{"command": "unsupported"}';
  else
    v_command := p_envelope ->> 'command';
  end if;

  if coalesce(jsonb_typeof(p_envelope -> 'expected_revision'), 'null') = 'null' then
    v_expected := null;
  elsif jsonb_typeof(p_envelope -> 'expected_revision') = 'number'
        and (p_envelope ->> 'expected_revision') ~ '^[0-9]{1,18}$' then
    v_expected := (p_envelope ->> 'expected_revision')::bigint;
  else
    v_errors := v_errors || '{"expected_revision": "invalid"}';
  end if;
  if p_handler is not null and not (v_errors ? 'expected_revision') then
    if p_revision_required and v_expected is null then
      v_errors := v_errors || '{"expected_revision": "required"}';
    elsif not p_revision_required and v_expected is not null then
      v_errors := v_errors || '{"expected_revision": "must_be_null"}';
    end if;
  end if;

  if jsonb_typeof(p_envelope -> 'payload') = 'object' then
    v_payload := p_envelope -> 'payload';
  else
    v_errors := v_errors || '{"payload": "must_be_object"}';
  end if;

  if exists (select 1 from jsonb_object_keys(p_envelope) k
              where k not in ('version', 'command', 'request_id', 'expected_revision', 'payload')) then
    v_errors := v_errors || '{"envelope": "unknown_field"}';
  end if;

  if v_errors <> '{}'::jsonb then
    return app.cmd_error_envelope(v_request_id, 'validation_failed', v_errors);
  end if;

  begin
    v_actor := app.cmd_current_actor();
    perform app.cmd_authorize(v_actor, v_command);

    v_stored := app.cmd_reserve_receipt(
      v_actor, v_command, v_request_id,
      app.cmd_payload_hash(1, v_command, v_expected, v_payload)
    );
    if v_stored is not null then
      -- AD-2: recheck current access on the receipt's aggregate before replaying it.
      select r.aggregate_type, r.aggregate_id
        into v_agg_type, v_agg_id
        from app.cmd_receipts r
       where r.actor_id = v_actor and r.command = v_command and r.request_id = v_request_id;
      execute format('select %s($1, $2, $3)', p_scope::regproc)
        into v_in_scope
        using v_actor, v_agg_type, v_agg_id;
      if v_in_scope is not true then
        perform app.cmd_fail('forbidden');
      end if;
      return v_stored;
    end if;

    execute format('select %s($1, $2, $3)', p_handler::regproc)
      into v_outcome
      using v_actor, v_expected, v_payload;

    v_envelope := jsonb_build_object(
      'request_id', v_request_id,
      'data', v_outcome -> 'data',
      'revision', (v_outcome ->> 'revision')::bigint
    );

    update app.cmd_receipts r
       set result = v_envelope,
           aggregate_type = v_outcome ->> 'aggregate_type',
           aggregate_id = (v_outcome ->> 'aggregate_id')::uuid
     where r.actor_id = v_actor
       and r.command = v_command
       and r.request_id = v_request_id
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
        v_request_id, v_code,
        v_detail_json -> 'field_errors',
        (v_detail_json ->> 'current_revision')::bigint
      );
    when others then
      -- Unexpected internal failure: rolled back, reported without SQL detail.
      raise log 'cmd % request % failed: sqlstate %', v_command, v_request_id, sqlstate;
      return app.cmd_error_envelope(v_request_id, 'unavailable');
  end;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Fixture handlers: explicit validation, own constraint translation
-- ---------------------------------------------------------------------------------------------
create or replace function app.fixture_counter_create(
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

  begin
    insert into app.fixture_counters (created_by, intent_key)
    values (p_actor, p_payload ->> 'intent_key')
    returning * into v_row;
  exception when unique_violation then
    -- The actor already has a counter with this intent key.
    perform app.cmd_fail('conflict');
  end;

  return app.fixture_counter_outcome(v_row);
end;
$$;

create or replace function app.fixture_counter_increment(
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
     or (p_payload ->> 'by') !~ '^-?[0-9]{1,4}$' then
    perform app.cmd_fail('validation_failed', '{"by": "invalid"}');
  end if;
  -- Casts only after the shape checks above, in separate statements.
  v_id := (p_payload ->> 'counter_id')::uuid;
  v_by := (p_payload ->> 'by')::integer;
  if v_by = 0 or v_by not between -1000 and 1000 then
    perform app.cmd_fail('validation_failed', '{"by": "invalid"}');
  end if;

  select * into v_row from app.fixture_counters c where c.id = v_id for update;
  -- Scope: only the creating actor may act on a counter. Out-of-scope rows look missing.
  if not found or v_row.created_by <> p_actor then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;

  -- The write happens after the receipt reservation; an out-of-range result breaks the value
  -- check, which this handler reports as invalid input and the kernel rolls everything back.
  begin
    update app.fixture_counters c
       set value = c.value + v_by,
           revision = c.revision + 1,
           updated_at = now()
     where c.id = v_id
    returning * into v_row;
  exception when check_violation then
    perform app.cmd_fail('validation_failed', '{"by": "out_of_range"}');
  end;

  return app.fixture_counter_outcome(v_row);
end;
$$;

-- Scope seam for replays: the actor must still own the stored counter (FOR SHARE: a concurrent
-- scope change waits for the replay to finish).
create function app.fixture_counter_in_scope(
  p_actor uuid,
  p_aggregate_type text,
  p_aggregate_id uuid
) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if p_aggregate_type is distinct from 'fixture_counter' or p_aggregate_id is null then
    return false;
  end if;
  perform 1
    from app.fixture_counters c
   where c.id = p_aggregate_id
     and c.created_by = p_actor
     for share;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------------------------
create function app.fixture_counter_command(p_envelope jsonb) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'fixture_counter.create' then 'app.fixture_counter_create(uuid, bigint, jsonb)'::regprocedure
      when 'fixture_counter.increment' then 'app.fixture_counter_increment(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.fixture_counter_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is not distinct from 'fixture_counter.increment'
  );
end;
$$;

-- PostgREST passes the whole JSON request body to a single unnamed jsonb parameter:
-- POST /rest/v1/rpc/fixture_counter_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.fixture_counter_command(jsonb) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.fixture_counter_command($1);
$$;

comment on function api.fixture_counter_command(jsonb) is
  'SYNTHETIC fixture command (story 1.4) exercising the transactional command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.cmd_current_actor(),
  app.cmd_execute(jsonb, regprocedure, regprocedure, boolean),
  app.fixture_counter_create(uuid, bigint, jsonb),
  app.fixture_counter_increment(uuid, bigint, jsonb),
  app.fixture_counter_in_scope(uuid, text, uuid),
  app.fixture_counter_command(jsonb),
  api.fixture_counter_command(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.fixture_counter_command(jsonb) to authenticated;
grant execute on function api.fixture_counter_command(jsonb) to authenticated;

notify pgrst, 'reload schema';
