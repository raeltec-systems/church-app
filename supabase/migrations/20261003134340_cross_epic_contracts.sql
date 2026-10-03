-- Cross-epic contracts and owner seams (story 1.5).
--
-- 1. Wire contract v1: `app.contract_check(kind, value)` is the SQL authority for the shared
--    fixtures in packages/contracts/fixtures/v1 (identifiers, actor, source/purpose, revisions,
--    UTC instants, church-local intent, exact money, command request/response). The Dart and
--    TypeScript client mappings pass the same fixtures. The command kernel's envelope
--    validation (app.cmd_execute) now delegates to it, so the two cannot drift.
-- 2. Owner registry (AD-1): modules, their object-name prefixes, the allowed dependency edges
--    from the architecture's binding diagram, explicit object-level exceptions and retired
--    objects, and guards that report unowned `app` objects, functions without an empty
--    search_path, and references to an owner a module may not depend on (function bodies,
--    BEGIN ATOMIC bodies, views, RLS policies, column defaults and triggers).
-- 3. Owner seams: source owners register source types (with a current-state check hook),
--    purposes and reminder kinds; owners register lifecycle hooks. Emitters call hooks through
--    the registry, so they never reference another owner's implementation.
-- 4. Fail-closed policy gates (AD-9, AD-17, AD-18): unresolved decisions stay closed. Labelled
--    fixture values are honoured only in an explicitly marked local/staging environment; an
--    unmarked database behaves as production, and production can never be downgraded.
--    No gate is approved here.
--
-- No destructive statements. Everything is migration-time or server-internal: no client role
-- gets any privilege. No feature business rules or concrete state machines.

-- ---------------------------------------------------------------------------------------------
-- Wire contract v1 validators (shape only; registration, zone existence and money scale are
-- server-side checks layered on top, see contract_require and contract_money_amount)
-- ---------------------------------------------------------------------------------------------

create function app.contract_uuid_error(p_value jsonb, p_nullable boolean default false)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then
      case when p_nullable then null else 'required' end
    when jsonb_typeof(p_value) = 'string'
         and (p_value #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then null
    else 'invalid'
  end;
$$;

-- Lower_snake_case token: source_type, purpose, reminder_kind (1..63 chars).
create function app.contract_token_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ '^[a-z][a-z0-9_]{0,62}$' then null
    else 'invalid'
  end;
$$;

-- Integers are defined by value: any JSON number whose value is an exact integer in range
-- (1, 1.0 and 1e0 are the same integer in every runtime).
create function app.contract_integer_in(p_value jsonb, p_min numeric, p_max numeric)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_value) = 'number'
     and (p_value #>> '{}')::numeric = trunc((p_value #>> '{}')::numeric)
     and (p_value #>> '{}')::numeric between p_min and p_max;
$$;

-- Monotonic revision: integer 1..2^53-1 (safe in every client runtime).
create function app.contract_revision_error(p_value jsonb, p_nullable boolean default false)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then
      case when p_nullable then null else 'required' end
    when app.contract_integer_in(p_value, 1, 9007199254740991) then null
    else 'invalid'
  end;
$$;

create function app.contract_calendar_ok(
  p_year integer, p_month integer, p_day integer,
  p_hour integer, p_minute integer, p_second integer
) returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_year >= 1
     and p_month between 1 and 12
     and p_day between 1 and case
           when p_month = 2 then
             case when (p_year % 4 = 0 and p_year % 100 <> 0) or p_year % 400 = 0 then 29 else 28 end
           when p_month in (4, 6, 9, 11) then 30
           else 31
         end
     and p_hour between 0 and 23
     and p_minute between 0 and 59
     and p_second between 0 and 59;
$$;

-- UTC RFC3339 instant: YYYY-MM-DDTHH:MM:SS[.f{1,6}]Z, a real calendar time, no leap second.
create function app.contract_instant_error(p_value jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  m text[];
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return 'required';
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    return 'invalid';
  end if;
  m := regexp_match(
    p_value #>> '{}',
    '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?Z$'
  );
  if m is null
     or not app.contract_calendar_ok(m[1]::int, m[2]::int, m[3]::int, m[4]::int, m[5]::int, m[6]::int) then
    return 'invalid';
  end if;
  return null;
end;
$$;

-- Church-local wall time (intent, no offset): YYYY-MM-DDTHH:MM:SS.
create function app.contract_local_error(p_value jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  m text[];
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return 'required';
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    return 'invalid';
  end if;
  m := regexp_match(
    p_value #>> '{}',
    '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})$'
  );
  if m is null
     or not app.contract_calendar_ok(m[1]::int, m[2]::int, m[3]::int, m[4]::int, m[5]::int, m[6]::int) then
    return 'invalid';
  end if;
  return null;
end;
$$;

-- Canonical IANA Area/Location name (or UTC), at most 64 chars. No Etc/, posix/, right/ or
-- legacy aliases (EST5EDT, US/Eastern, Factory, UCT). Existence is checked server-side.
create function app.contract_zone_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) = 'string'
         and length(p_value #>> '{}') <= 64
         and (p_value #>> '{}') ~ ('^(UTC|(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia'
                                   '|Europe|Indian|Pacific)(/[A-Za-z][A-Za-z0-9_+-]*){1,2})$')
      then null
    else 'invalid'
  end;
$$;

-- Exact unsigned decimal string: no float, sign, exponent or separators, <= 15 integer and
-- <= 6 fraction digits. Signs belong to owner rules; the approved scale is a Q9 policy check.
create function app.contract_amount_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) = 'string'
         and (p_value #>> '{}') ~ '^(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$'
      then null
    else 'invalid'
  end;
$$;

create function app.contract_currency_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ '^[A-Z]{3}$' then null
    else 'invalid'
  end;
$$;

-- {"<key>": "unknown_field"} for every key outside the allowed set.
create function app.contract_unknown_keys(p_value jsonb, p_allowed text[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(k, 'unknown_field'), '{}'::jsonb)
    from jsonb_object_keys(p_value) k
   where k <> all (p_allowed);
$$;

create function app.contract_error_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['validation_failed', 'unauthenticated', 'forbidden', 'not_found', 'conflict',
               'rate_limited', 'unavailable'];
$$;

-- Every field error code any server path may return (clients validate against this list).
create function app.contract_field_error_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['required', 'invalid', 'unknown_field', 'must_be_object', 'unsupported',
               'must_be_null', 'out_of_range', 'unknown', 'unregistered', 'scale_exceeded',
               'gate_closed'];
$$;

-- The single SQL authority for the shared v1 fixtures. Returns {valid, field_errors}.
-- Lifecycle event names come from app.contract_lifecycle_events (single source).
create function app.contract_check(p_kind text, p_value jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := coalesce(p_value, 'null'::jsonb);
  e jsonb := '{}'::jsonb;
begin
  if p_kind is null
     or p_kind not in ('member_ref', 'account_ref', 'actor', 'source_ref', 'task_source',
                       'notification_key', 'lifecycle_event', 'instant', 'zoned_local', 'money',
                       'command_request', 'command_response') then
    raise exception using errcode = '22023', message = 'unknown contract kind';
  end if;

  if p_kind = 'instant' then
    e := jsonb_strip_nulls(jsonb_build_object('$', app.contract_instant_error(v)));
    return jsonb_build_object('valid', e = '{}'::jsonb, 'field_errors', e);
  end if;

  if jsonb_typeof(v) <> 'object' then
    e := jsonb_build_object(case when p_kind = 'command_request' then 'envelope' else '$' end,
                            'must_be_object');
    return jsonb_build_object('valid', false, 'field_errors', e);
  end if;

  case p_kind
  when 'member_ref' then
    e := jsonb_build_object('member_id', app.contract_uuid_error(v -> 'member_id'))
         || app.contract_unknown_keys(v, array['member_id']);

  when 'account_ref' then
    e := jsonb_build_object('auth_user_id', app.contract_uuid_error(v -> 'auth_user_id'))
         || app.contract_unknown_keys(v, array['auth_user_id']);

  when 'actor' then
    if coalesce(jsonb_typeof(v -> 'kind'), 'null') = 'null' then
      e := '{"kind": "required"}';
    elsif (v -> 'kind') = '"member"'::jsonb then
      e := jsonb_build_object(
             'member_id', app.contract_uuid_error(v -> 'member_id'),
             'auth_user_id', app.contract_uuid_error(v -> 'auth_user_id'))
           || app.contract_unknown_keys(v, array['kind', 'member_id', 'auth_user_id']);
    elsif (v -> 'kind') = '"system"'::jsonb then
      e := jsonb_build_object(
             'system_principal_id', app.contract_uuid_error(v -> 'system_principal_id'),
             'job_id', app.contract_uuid_error(v -> 'job_id'),
             'initiating_member_id', app.contract_uuid_error(v -> 'initiating_member_id', true))
           || app.contract_unknown_keys(
                v, array['kind', 'system_principal_id', 'job_id', 'initiating_member_id']);
    else
      e := '{"kind": "invalid"}';
    end if;

  when 'source_ref' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'source_revision', app.contract_revision_error(v -> 'source_revision'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'source_revision']);

  when 'task_source' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'purpose', app.contract_token_error(v -> 'purpose'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'purpose']);

  when 'notification_key' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'source_revision', app.contract_revision_error(v -> 'source_revision'),
           'recipient_member_id', app.contract_uuid_error(v -> 'recipient_member_id'),
           'reminder_kind', app.contract_token_error(v -> 'reminder_kind'),
           'scheduled_at', app.contract_instant_error(v -> 'scheduled_at'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'source_revision',
                                               'recipient_member_id', 'reminder_kind',
                                               'scheduled_at']);

  when 'lifecycle_event' then
    e := jsonb_build_object(
           'event', case
                      when coalesce(jsonb_typeof(v -> 'event'), 'null') = 'null' then 'required'
                      when jsonb_typeof(v -> 'event') = 'string'
                           and exists (select 1 from app.contract_lifecycle_events le
                                        where le.event = v ->> 'event') then null
                      else 'invalid'
                    end,
           'member_id', app.contract_uuid_error(v -> 'member_id'),
           'occurred_at', app.contract_instant_error(v -> 'occurred_at'),
           'identity_revision', app.contract_revision_error(v -> 'identity_revision'))
         || app.contract_unknown_keys(v, array['event', 'member_id', 'occurred_at',
                                               'identity_revision']);

  when 'zoned_local' then
    e := jsonb_build_object(
           'local', app.contract_local_error(v -> 'local'),
           'zone', app.contract_zone_error(v -> 'zone'))
         || app.contract_unknown_keys(v, array['local', 'zone']);

  when 'money' then
    e := jsonb_build_object(
           'amount', app.contract_amount_error(v -> 'amount'),
           'currency', app.contract_currency_error(v -> 'currency'))
         || app.contract_unknown_keys(v, array['amount', 'currency']);

  when 'command_request' then
    -- Authoritative envelope shape; app.cmd_execute calls this and adds only the per-command
    -- checks (allowlisted command -> unsupported, expected_revision required/must_be_null).
    e := jsonb_build_object(
           'version', case
                        when coalesce(jsonb_typeof(v -> 'version'), 'null') = 'null' then 'required'
                        when app.contract_integer_in(v -> 'version', 1, 1) then null
                        else 'unsupported'
                      end,
           'command', case
                        when coalesce(jsonb_typeof(v -> 'command'), 'null') = 'null' then 'required'
                        when jsonb_typeof(v -> 'command') = 'string'
                             and length(v ->> 'command') <= 127
                             and (v ->> 'command') ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' then null
                        else 'invalid'
                      end,
           'request_id', app.contract_uuid_error(v -> 'request_id'),
           'expected_revision', app.contract_revision_error(v -> 'expected_revision', true),
           'payload', case when jsonb_typeof(v -> 'payload') = 'object' then null
                           else 'must_be_object' end)
         || app.contract_unknown_keys(
              v, array['version', 'command', 'request_id', 'expected_revision', 'payload']);

  when 'command_response' then
    if v ? 'code' then
      e := jsonb_build_object(
             'request_id', case when v ? 'request_id'
                                then app.contract_uuid_error(v -> 'request_id', true)
                                else 'required' end,
             'code', case
                       when coalesce(jsonb_typeof(v -> 'code'), 'null') = 'null' then 'required'
                       when jsonb_typeof(v -> 'code') = 'string'
                            and (v ->> 'code') = any (app.contract_error_codes()) then null
                       else 'invalid'
                     end,
             'message', case
                          when coalesce(jsonb_typeof(v -> 'message'), 'null') = 'null' then 'required'
                          when jsonb_typeof(v -> 'message') = 'string' then null
                          else 'invalid'
                        end,
             'field_errors', case
                               when coalesce(jsonb_typeof(v -> 'field_errors'), 'null') = 'null'
                                 then 'required'
                               when jsonb_typeof(v -> 'field_errors') = 'object'
                                    and not exists (
                                      select 1 from jsonb_each(v -> 'field_errors') f
                                       where jsonb_typeof(f.value) <> 'string'
                                          or (f.value #>> '{}') <> all (app.contract_field_error_codes()))
                                 then null
                               else 'invalid'
                             end,
             'current_revision', app.contract_revision_error(v -> 'current_revision', true))
           || app.contract_unknown_keys(
                v, array['request_id', 'code', 'message', 'field_errors', 'current_revision']);
    else
      e := jsonb_build_object(
             'request_id', app.contract_uuid_error(v -> 'request_id'),
             'data', case when v ? 'data' then null else 'required' end,
             'revision', app.contract_revision_error(v -> 'revision'))
           || app.contract_unknown_keys(v, array['request_id', 'data', 'revision']);
    end if;
  end case;

  e := jsonb_strip_nulls(e);
  return jsonb_build_object('valid', e = '{}'::jsonb, 'field_errors', e);
end;
$$;

comment on function app.contract_check(text, jsonb) is
  'Wire contract v1 shape authority; packages/contracts/fixtures/v1 is its shared test set.';

-- ---------------------------------------------------------------------------------------------
-- Kernel envelope validation delegates to the contract (same signature: create or replace)
-- ---------------------------------------------------------------------------------------------
create or replace function app.cmd_execute(
  p_envelope jsonb,
  p_handler regprocedure,
  p_scope regprocedure,
  p_revision_required boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
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
  -- Envelope shape: wire contract v1 (app.contract_check), all field errors at once.
  v_errors := app.contract_check('command_request', p_envelope) -> 'field_errors';

  if jsonb_typeof(p_envelope) = 'object' then
    if not (v_errors ? 'request_id') then
      v_request_id := (p_envelope ->> 'request_id')::uuid;
    end if;
    -- Per-command checks, only on fields the contract accepted.
    if not (v_errors ? 'command') then
      if p_handler is null then
        v_errors := v_errors || '{"command": "unsupported"}';
      else
        v_command := p_envelope ->> 'command';
      end if;
    end if;
    if not (v_errors ? 'expected_revision') then
      if coalesce(jsonb_typeof(p_envelope -> 'expected_revision'), 'null') <> 'null' then
        v_expected := (p_envelope ->> 'expected_revision')::numeric::bigint;
      end if;
      if p_handler is not null then
        if p_revision_required and v_expected is null then
          v_errors := v_errors || '{"expected_revision": "required"}';
        elsif not p_revision_required and v_expected is not null then
          v_errors := v_errors || '{"expected_revision": "must_be_null"}';
        end if;
      end if;
    end if;
    v_payload := p_envelope -> 'payload';
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

revoke all on function app.cmd_execute(jsonb, regprocedure, regprocedure, boolean)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Owner registry (AD-1) and boundary guards
-- ---------------------------------------------------------------------------------------------

create table app.contract_modules (
  module text primary key check (module ~ '^[a-z][a-z0-9_]{0,62}$'),
  -- AD-2 global lock order for owners of aggregates; null = owns no lockable aggregates.
  lock_rank smallint check (lock_rank > 0),
  description text not null
);

comment on table app.contract_modules is
  'AD-1 module registry. Owners with a lock_rank may register sources and lifecycle hooks.';

create table app.contract_module_prefixes (
  prefix text primary key check (prefix ~ '^[a-z][a-z0-9]*_$'),
  module text not null references app.contract_modules (module)
);

comment on table app.contract_module_prefixes is
  'Every app table, view and function name starts with its owning module''s prefix.';

create table app.contract_module_dependencies (
  from_module text not null references app.contract_modules (module),
  to_module text not null references app.contract_modules (module),
  primary key (from_module, to_module),
  check (from_module <> to_module)
);

comment on table app.contract_module_dependencies is
  'Allowed "may depend on/call" edges from the architecture dependency diagram.';

-- One named function may reference one module outside its module's edges, with a reason.
create table app.contract_dependency_exceptions (
  function_signature text not null,
  to_module text not null references app.contract_modules (module),
  reason text not null check (length(btrim(reason)) > 0),
  primary key (function_signature, to_module)
);

-- Exactly these retired functions (revoked + renamed, awaiting an owner-approved drop) belong
-- to the inert `retired` module. Any other retired_* name stays unowned and fails the guard.
create table app.contract_retired_functions (
  function_signature text primary key,
  reason text not null check (length(btrim(reason)) > 0)
);

insert into app.contract_modules (module, lock_rank, description) values
  ('platform', null, 'Command kernel, wire contracts, owner registry, policy gates, tracer status'),
  ('orchestration', null, 'Cross-domain application commands that call owner operations'),
  ('retired', null, 'Explicitly listed retired functions awaiting an owner-approved drop'),
  ('identity', 10, 'Members, account links, approvals, grants, settings, lifecycle'),
  ('content', 20, 'Publishing and instruction-only giving'),
  ('cells', 20, 'Cell membership, meetings, programmes, registers, reports, recaps'),
  ('care', 20, 'Visit requests, proposals, responses'),
  ('prayer', 20, 'Prayer requests, restricted author links, replies'),
  ('directory', 20, 'Opted-in directory projections'),
  ('services', 20, 'Aggregate service counts'),
  ('offerings', 20, 'Collection custody'),
  ('chat', 20, 'Optional group messages'),
  ('duties', 20, 'Duty occurrences, slots, revisions, assignments, standalone recurrence'),
  ('fixture', 20, 'SYNTHETIC platform fixtures (story 1.4 command aggregate)'),
  ('followups', 30, 'Canonical follow-up task registry'),
  ('notifications', 40, 'Inbox, jobs, attempts, tokens');

insert into app.contract_module_prefixes (prefix, module) values
  ('cmd_', 'platform'), ('contract_', 'platform'), ('policy_', 'platform'),
  ('platform_', 'platform'),
  ('orch_', 'orchestration'),
  ('identity_', 'identity'), ('content_', 'content'), ('cells_', 'cells'), ('care_', 'care'),
  ('prayer_', 'prayer'), ('directory_', 'directory'), ('services_', 'services'),
  ('offerings_', 'offerings'), ('chat_', 'chat'), ('duties_', 'duties'),
  ('fixture_', 'fixture'), ('followups_', 'followups'), ('notifications_', 'notifications');

-- Every module may use the platform kernel; all owners may use Identity checks.
insert into app.contract_module_dependencies (from_module, to_module)
select m.module, 'platform' from app.contract_modules m where m.module <> 'platform'
union
select m.module, 'identity' from app.contract_modules m
 where m.module not in ('platform', 'identity', 'fixture', 'retired')
union
-- Owners may call Duties, Follow-ups and Notifications operations.
select o.module, t.target
  from app.contract_modules o
 cross join (values ('duties'), ('followups'), ('notifications')) t (target)
 where o.module in ('content', 'cells', 'care', 'prayer', 'directory', 'services', 'offerings', 'chat')
union
select 'duties', t.target from (values ('followups'), ('notifications')) t (target)
union
select 'followups', 'notifications'
union
-- Cross-domain orchestration may call every owner.
select 'orchestration', m.module from app.contract_modules m
 where m.module not in ('orchestration', 'platform', 'identity', 'retired')
union
-- The retired story 1.4 entry points keep their original bodies over the fixture aggregate.
select 'retired', 'fixture';

insert into app.contract_dependency_exceptions (function_signature, to_module, reason) values
  ('app.cmd_authorize(uuid,text)', 'fixture',
   'Story 1.4 authorization seam reads the SYNTHETIC fixture grants until the identity epic replaces its body');

insert into app.contract_retired_functions (function_signature, reason) values
  ('app.retired_fixture_counter_command_v0(integer,text,uuid,bigint,jsonb)',
   'Story 1.4 typed entry point, superseded by the jsonb envelope'),
  ('api.retired_fixture_counter_command_v0(integer,text,uuid,bigint,jsonb)',
   'Story 1.4 typed api wrapper, superseded by the jsonb envelope'),
  ('app.retired_cmd_execute_v0(integer,text,uuid,bigint,jsonb,regprocedure,boolean)',
   'Story 1.4 typed kernel, superseded by the jsonb envelope');

-- Owning module of an app object name: the longest registered prefix.
create function app.contract_object_module(p_name text)
returns text
language sql
stable
set search_path = ''
as $$
  select p.module
    from app.contract_module_prefixes p
   where left(p_name, length(p.prefix)) = p.prefix
   order by length(p.prefix) desc
   limit 1;
$$;

-- Owning module of a function: an explicitly listed retired function, else its name prefix.
create function app.contract_function_module(p_function regprocedure)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when exists (select 1 from app.contract_retired_functions r
                  where r.function_signature = p_function::text) then 'retired'
    else app.contract_object_module((select p.proname::text from pg_catalog.pg_proc p
                                      where p.oid = p_function))
  end;
$$;

-- App tables, views, sequences and functions with no registered owner.
create function app.contract_unowned_objects()
returns table (object_kind text, object_name text)
language sql
stable
set search_path = ''
as $$
  select case c.relkind when 'r' then 'table' when 'p' then 'table' when 'v' then 'view'
                        when 'm' then 'materialized view' else 'sequence' end,
         c.relname::text
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'app'
     and c.relkind in ('r', 'p', 'v', 'm', 'S')
     and app.contract_object_module(c.relname) is null
  union all
  select 'function', p.oid::regprocedure::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and app.contract_function_module(p.oid::regprocedure) is null;
$$;

-- app/api functions without `search_path = ''`: unqualified names would escape the guard.
create function app.contract_unpinned_functions()
returns table (function_signature text)
language sql
stable
set search_path = ''
as $$
  select p.oid::regprocedure::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'api')
     and not coalesce('search_path=""' = any (p.proconfig), false);
$$;

-- References to an app object whose owner the source's module may not depend on. Sources:
-- function bodies (plpgsql/sql text and BEGIN ATOMIC bodies), view definitions, RLS policy
-- expressions, column defaults and trigger functions on app tables. Deparsed text is
-- schema-qualified because this function runs with an empty search_path; functions must pin
-- an empty search_path (contract_unpinned_functions). Dynamic SQL is not visible: reach
-- another owner through registered hooks instead.
create function app.contract_boundary_violations()
returns table (source_kind text, source_name text, source_module text,
               referenced_object text, referenced_module text)
language sql
stable
set search_path = ''
as $$
  with sources (source_kind, source_name, source_module, body) as (
    select 'function', p.oid::regprocedure::text, app.contract_function_module(p.oid::regprocedure),
           coalesce(p.prosrc, '') || ' ' || coalesce(pg_catalog.pg_get_function_sqlbody(p.oid), '')
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
    union all
    select 'view', 'app.' || c.relname, app.contract_object_module(c.relname),
           pg_catalog.pg_get_viewdef(c.oid)
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and c.relkind in ('v', 'm')
    union all
    select 'policy', 'app.' || c.relname || '.' || pol.polname, app.contract_object_module(c.relname),
           coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid), '') || ' '
           || coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid), '')
      from pg_catalog.pg_policy pol
      join pg_catalog.pg_class c on c.oid = pol.polrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app'
    union all
    select 'default', 'app.' || c.relname || '.' || a.attname, app.contract_object_module(c.relname),
           pg_catalog.pg_get_expr(d.adbin, d.adrelid)
      from pg_catalog.pg_attrdef d
      join pg_catalog.pg_class c on c.oid = d.adrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join pg_catalog.pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
     where n.nspname = 'app'
    union all
    select 'trigger', 'app.' || c.relname || '.' || t.tgname, app.contract_object_module(c.relname),
           t.tgfoid::regproc::text
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and not t.tgisinternal
  )
  select distinct s.source_kind, s.source_name, s.source_module, r.object_name, r.module
    from sources s
   cross join lateral (
      select lower(m[1]) as object_name, app.contract_object_module(lower(m[1])) as module
        from regexp_matches(s.body, '"?\mapp"?\s*\.\s*"?([a-z0-9_]+)', 'gi') as m
   ) r
   where s.source_module is not null
     and r.module is not null
     and r.module <> s.source_module
     and not exists (
       select 1 from app.contract_module_dependencies d
        where d.from_module = s.source_module and d.to_module = r.module
     )
     and not (s.source_kind = 'function' and exists (
       select 1 from app.contract_dependency_exceptions x
        where x.function_signature = s.source_name and x.to_module = r.module
     ))
  union
  -- A trigger on an app table must run an app function.
  select 'trigger', 'app.' || c.relname || '.' || t.tgname, app.contract_object_module(c.relname),
         t.tgfoid::regproc::text, 'outside_app'
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    join pg_catalog.pg_proc p on p.oid = t.tgfoid
    join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
   where n.nspname = 'app' and not t.tgisinternal and pn.nspname <> 'app';
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner seams: lifecycle hooks, source types, purposes, reminder kinds
-- ---------------------------------------------------------------------------------------------

-- Single source of the contract v1 lifecycle event names (Identity-owned stub list, AD-14).
-- A new event is a contract version change: add it here and to the shared fixtures.
create table app.contract_lifecycle_events (
  event text primary key check (event ~ '^[a-z][a-z0-9_]{0,62}$'),
  emitter_module text not null default 'identity' references app.contract_modules (module),
  contract_version integer not null default 1,
  description text not null
);

insert into app.contract_lifecycle_events (event, description) values
  ('access_hold_applied', 'A security or login hold now denies the member''s access'),
  ('access_hold_released', 'A hold was released by the authorised workflow'),
  ('scope_revoked', 'A role, grant or cell scope was removed'),
  ('account_deactivated', 'The member''s account access was deactivated'),
  ('deletion_requested', 'Full deletion started: access-denied tombstone recorded'),
  ('cell_transferred', 'Confirmed primary cell membership moved to another cell');

-- Handlers are stored as signature text, never reg* columns (they block pg_upgrade), and are
-- re-resolved on every call.
create table app.contract_lifecycle_hooks (
  event text not null references app.contract_lifecycle_events (event),
  module text not null references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now(),
  primary key (event, module)
);

create table app.contract_source_types (
  source_type text primary key check (source_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  module text not null references app.contract_modules (module),
  check_hook text not null,
  registered_at timestamptz not null default now()
);

create table app.contract_source_purposes (
  source_type text not null references app.contract_source_types (source_type),
  purpose text not null check (purpose ~ '^[a-z][a-z0-9_]{0,62}$'),
  registered_at timestamptz not null default now(),
  primary key (source_type, purpose)
);

create table app.contract_reminder_kinds (
  source_type text not null references app.contract_source_types (source_type),
  reminder_kind text not null check (reminder_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  registered_at timestamptz not null default now(),
  primary key (source_type, reminder_kind)
);

-- Registration errors are migration-time programming errors (SQLSTATE PCTR1).
create function app.contract_registration_fail(p_message text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = 'PCTR1', message = p_message;
end;
$$;

-- The handler must be an app function named with the registering owner's prefix, pin an empty
-- search_path and have exactly the given argument/return types.
create function app.contract_validate_handler(
  p_module text,
  p_handler regprocedure,
  p_return regtype
) returns text
language plpgsql
set search_path = ''
as $$
declare
  v_proc record;
begin
  if not exists (select 1 from app.contract_modules m
                  where m.module = p_module and m.lock_rank is not null) then
    perform app.contract_registration_fail('unknown or non-owner module: ' || coalesce(p_module, '<null>'));
  end if;
  select p.proname, n.nspname, p.pronargs, p.proargtypes, p.prorettype, p.proretset, p.proconfig
    into v_proc
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where p.oid = p_handler;
  if not found or v_proc.nspname <> 'app' then
    perform app.contract_registration_fail('handler must be an app function');
  end if;
  if app.contract_function_module(p_handler) is distinct from p_module then
    perform app.contract_registration_fail(
      format('handler %s is not owned by module %s', p_handler, p_module));
  end if;
  if v_proc.pronargs <> 1 or v_proc.proargtypes[0] <> 'jsonb'::regtype::oid
     or v_proc.prorettype <> p_return::oid or v_proc.proretset then
    perform app.contract_registration_fail(
      format('handler %s must take (jsonb) and return %s', p_handler, p_return));
  end if;
  if not coalesce('search_path=""' = any (v_proc.proconfig), false) then
    perform app.contract_registration_fail(
      format('handler %s must set search_path = ''''', p_handler));
  end if;
  return p_handler::text;
end;
$$;

-- Lifecycle hook: (event jsonb) returns void, runs inside Identity's lifecycle transaction.
create function app.contract_register_lifecycle_hook(
  p_module text,
  p_event text,
  p_handler regprocedure
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
begin
  if not exists (select 1 from app.contract_lifecycle_events e where e.event = p_event) then
    perform app.contract_registration_fail('unknown lifecycle event: ' || coalesce(p_event, '<null>'));
  end if;
  if p_module = 'identity' then
    perform app.contract_registration_fail('identity emits lifecycle events; it does not hook them');
  end if;
  v_handler := app.contract_validate_handler(p_module, p_handler, 'void'::regtype);
  insert into app.contract_lifecycle_hooks (event, module, handler)
  values (p_event, p_module, v_handler);
end;
$$;

-- Source type: check hook (source_ref jsonb) returns jsonb {"current": bool, "revision": int?}.
create function app.contract_register_source_type(
  p_module text,
  p_source_type text,
  p_check_hook regprocedure
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
begin
  if app.contract_token_error(to_jsonb(p_source_type)) is not null then
    perform app.contract_registration_fail('invalid source_type');
  end if;
  v_hook := app.contract_validate_handler(p_module, p_check_hook, 'jsonb'::regtype);
  insert into app.contract_source_types (source_type, module, check_hook)
  values (p_source_type, p_module, v_hook);
end;
$$;

create function app.contract_require_source_owner(p_module text, p_source_type text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.contract_source_types s
                  where s.source_type = p_source_type and s.module = p_module) then
    perform app.contract_registration_fail(
      format('module %s does not own source type %s', p_module, p_source_type));
  end if;
end;
$$;

create function app.contract_register_purpose(p_module text, p_source_type text, p_purpose text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if app.contract_token_error(to_jsonb(p_purpose)) is not null then
    perform app.contract_registration_fail('invalid purpose');
  end if;
  insert into app.contract_source_purposes (source_type, purpose) values (p_source_type, p_purpose);
end;
$$;

create function app.contract_register_reminder_kind(
  p_module text,
  p_source_type text,
  p_reminder_kind text
) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if app.contract_token_error(to_jsonb(p_reminder_kind)) is not null then
    perform app.contract_registration_fail('invalid reminder_kind');
  end if;
  insert into app.contract_reminder_kinds (source_type, reminder_kind)
  values (p_source_type, p_reminder_kind);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Server-side contract use
-- ---------------------------------------------------------------------------------------------

-- Raises the kernel's validation_failed (PCMD1) with the contract field errors, and adds the
-- server-only zone existence check.
create function app.contract_require(p_kind text, p_value jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_result jsonb := app.contract_check(p_kind, p_value);
begin
  if not (v_result ->> 'valid')::boolean then
    perform app.cmd_fail('validation_failed', v_result -> 'field_errors');
  end if;
  if p_kind = 'zoned_local'
     and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value ->> 'zone') then
    perform app.cmd_fail('validation_failed', '{"zone": "unknown"}');
  end if;
end;
$$;

-- Identity's lifecycle transaction calls this. Hooks run in AD-2 lock order (rank, module) in
-- the caller's transaction: one failing hook aborts the whole lifecycle change.
create function app.contract_dispatch_lifecycle(p_event jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_hook record;
  v_proc regprocedure;
  v_count integer := 0;
begin
  perform app.contract_require('lifecycle_event', p_event);
  for v_hook in
    select h.module, h.handler
      from app.contract_lifecycle_hooks h
      join app.contract_modules m on m.module = h.module
     where h.event = p_event ->> 'event'
     order by m.lock_rank, h.module
  loop
    v_proc := pg_catalog.to_regprocedure(v_hook.handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered lifecycle hook %s is missing', v_hook.handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) using p_event;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Follow-ups/Notifications call this to recheck a source through its owner's hook.
create function app.contract_check_source(p_source jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_proc regprocedure;
  v_result jsonb;
begin
  perform app.contract_require('source_ref', p_source);
  select s.check_hook into v_hook
    from app.contract_source_types s
   where s.source_type = p_source ->> 'source_type';
  if not found then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  v_proc := pg_catalog.to_regprocedure(v_hook);
  if v_proc is null then
    raise exception using errcode = 'PCTR1',
      message = format('registered source hook %s is missing', v_hook);
  end if;
  execute format('select %s($1)', v_proc::regproc) into v_result using p_source;
  if jsonb_typeof(v_result) is distinct from 'object'
     or jsonb_typeof(v_result -> 'current') is distinct from 'boolean' then
    raise exception using errcode = 'PCTR1',
      message = format('source hook %s returned a malformed result', v_hook);
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Environment marker and fail-closed policy gates
-- ---------------------------------------------------------------------------------------------

-- Absent row = production behaviour. Nothing (no seed) writes it automatically: an operator or
-- a local script sets it. Production is terminal, and a database ever marked staging or
-- production can never be marked local. A restored or cloned database keeps the source's
-- marker: the restore procedure must re-assert it before serving.
create table app.platform_environment (
  singleton boolean primary key default true check (singleton),
  environment text not null check (environment in ('local', 'staging', 'production')),
  set_by text not null check (length(btrim(set_by)) > 0),
  set_at timestamptz not null default now()
);

create table app.platform_environment_history (
  id bigint generated always as identity primary key,
  environment text not null check (environment in ('local', 'staging', 'production')),
  set_by text not null,
  set_at timestamptz not null default now()
);

create function app.platform_current_environment()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce((select e.environment from app.platform_environment e), 'production');
$$;

create function app.platform_set_environment(p_environment text, p_set_by text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_current text := (select e.environment from app.platform_environment e for update);
begin
  if p_environment is null or p_environment not in ('local', 'staging', 'production') then
    raise exception using errcode = '22023', message = 'unknown environment';
  end if;
  if length(btrim(coalesce(p_set_by, ''))) = 0 then
    raise exception using errcode = '22023', message = 'set_by is required';
  end if;
  if v_current = 'production' and p_environment <> 'production' then
    raise exception using errcode = '22023', message = 'a production database cannot be re-marked';
  end if;
  if p_environment = 'local' and exists (
       select 1 from app.platform_environment_history h
        where h.environment in ('staging', 'production')) then
    raise exception using errcode = '22023',
      message = 'a database ever marked staging or production cannot be marked local';
  end if;
  insert into app.platform_environment (singleton, environment, set_by)
  values (true, p_environment, btrim(p_set_by))
  on conflict (singleton) do update
    set environment = excluded.environment, set_by = excluded.set_by, set_at = now();
  insert into app.platform_environment_history (environment, set_by)
  values (p_environment, btrim(p_set_by));
end;
$$;

create table app.policy_gates (
  gate text primary key check (gate ~ '^[a-z][a-z0-9_]{0,62}$'),
  decision_ref text not null,
  description text not null,
  state text not null default 'unresolved' check (state in ('unresolved', 'approved')),
  approved_value jsonb,
  approved_by text,
  approved_at timestamptz,
  approval_note text,
  -- Test-only value, honoured only in local/staging, always labelled.
  fixture_value jsonb check (
    fixture_value is null
    or (jsonb_typeof(fixture_value) = 'object'
        and length(btrim(coalesce(fixture_value ->> 'fixture_label', ''))) > 0)
  ),
  check (
    (state = 'approved') = (approved_value is not null and approved_by is not null
                            and approved_at is not null and approval_note is not null)
  ),
  check (approved_by is null or length(btrim(approved_by)) > 0),
  check (approval_note is null or length(btrim(approval_note)) > 0)
);

comment on table app.policy_gates is
  'Fail-closed policy activation. Only the owner approves a gate (app.policy_approve).';

insert into app.policy_gates (gate, decision_ref, description, fixture_value) values
  ('q1_auth_recovery', 'Q1',
   'Approval/recovery owners, password/abuse/dormancy controls, email delivery, assisted procedure',
   null),
  ('q2_church_time', 'Q2',
   'Church IANA zone, pilots, deadlines and quiet hours; gates production scheduling',
   '{"fixture_label": "TEST FIXTURE - not church policy", "zone": "UTC", "quiet_hours": null}'),
  ('q4_personal_data', 'Q4',
   'Youth/contact/visitor safeguards, retention, deletion and backups; gates live personal data',
   null),
  ('q9_money', 'Q9',
   'Currency, approved scale, custody, export and retention; gates Offerings',
   '{"fixture_label": "TEST FIXTURE - XTS is the ISO 4217 testing code", "currencies": {"XTS": 2}}'),
  ('q12_operations', 'Q12',
   'Device/browser floors, performance, reminder tolerance, RPO/RTO, alert thresholds',
   null),
  ('private_access', 'Release gate',
   'Serving private member data in this environment', null),
  ('outbound_sending', 'Release gate',
   'Sending push/email to recipients from this environment', null);

-- Effective policy value, or the kernel's `unavailable` (PCMD1) with the public field error
-- {"policy": "gate_closed"} when the gate is closed (internal gate names are not exposed).
create function app.policy_effective(p_gate text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate app.policy_gates;
begin
  select * into v_gate from app.policy_gates g where g.gate = p_gate;
  if not found then
    raise exception using errcode = '22023', message = 'unknown policy gate';
  end if;
  if v_gate.state = 'approved' then
    return jsonb_build_object('gate', p_gate, 'source', 'approved', 'value', v_gate.approved_value);
  end if;
  if v_gate.fixture_value is not null
     and app.platform_current_environment() in ('local', 'staging') then
    return jsonb_build_object('gate', p_gate, 'source', 'fixture', 'value', v_gate.fixture_value);
  end if;
  perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  return null;
end;
$$;

create function app.policy_is_open(p_gate text)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  perform app.policy_effective(p_gate);
  return true;
exception when sqlstate 'PCMD1' then
  return false;
end;
$$;

-- Owner-only (no grants): records an explicit, attributed approval for this environment.
create function app.policy_approve(
  p_gate text,
  p_value jsonb,
  p_approved_by text,
  p_note text
) returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object' then
    raise exception using errcode = '22023', message = 'approved value must be an object';
  end if;
  if length(btrim(coalesce(p_approved_by, ''))) = 0 or length(btrim(coalesce(p_note, ''))) = 0 then
    raise exception using errcode = '22023', message = 'approver and decision note are required';
  end if;
  if p_value ? 'fixture_label' then
    raise exception using errcode = '22023', message = 'a fixture value cannot be approved';
  end if;
  if p_gate = 'q9_money' and (
       jsonb_typeof(p_value -> 'currencies') is distinct from 'object'
       or (p_value -> 'currencies') = '{}'::jsonb
       or exists (select 1 from jsonb_each(p_value -> 'currencies') c
                   where c.key !~ '^[A-Z]{3}$'
                      or jsonb_typeof(c.value) <> 'number'
                      or (c.value #>> '{}') !~ '^[0-6]$')) then
    raise exception using errcode = '22023',
      message = 'q9_money needs {"currencies": {"<ISO 4217 code>": <integer scale 0..6>}}';
  end if;
  update app.policy_gates g
     set state = 'approved', approved_value = p_value, approved_by = btrim(p_approved_by),
         approved_at = now(), approval_note = btrim(p_note)
   where g.gate = p_gate;
  if not found then
    raise exception using errcode = '22023', message = 'unknown policy gate';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Encodings needing policy: exact money and the reminder key stub
-- ---------------------------------------------------------------------------------------------

-- Parses wire money to an exact numeric, enforcing the approved per-currency scale (Q9).
create function app.contract_money_amount(p_money jsonb)
returns numeric
language plpgsql
set search_path = ''
as $$
declare
  v_scale integer;
  v_amount text;
begin
  perform app.contract_require('money', p_money);
  v_scale := (app.policy_effective('q9_money') -> 'value' -> 'currencies' ->> (p_money ->> 'currency'))::integer;
  if v_scale is null then
    perform app.cmd_fail('validation_failed', '{"currency": "unsupported"}');
  end if;
  v_amount := p_money ->> 'amount';
  if length(split_part(v_amount, '.', 2)) > v_scale then
    perform app.cmd_fail('validation_failed', '{"amount": "scale_exceeded"}');
  end if;
  return v_amount::numeric;
end;
$$;

-- Wire form of an exact non-negative amount at the approved scale; never rounds silently.
create function app.contract_money_json(p_amount numeric, p_currency text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_scale integer;
begin
  v_scale := (app.policy_effective('q9_money') -> 'value' -> 'currencies' ->> p_currency)::integer;
  if v_scale is null or p_amount is null or p_amount < 0 or p_amount <> round(p_amount, v_scale)
     or p_amount >= 1e15 then
    raise exception using errcode = '22023', message = 'amount not representable at the approved scale';
  end if;
  return jsonb_build_object('amount', round(p_amount, v_scale)::text, 'currency', p_currency);
end;
$$;

-- Notifications seam stub (AD-8): validates the logical key, its registration and the source's
-- current revision through the owner hook, behind the Q2 scheduling gate. Returns the canonical
-- key; the Notifications epic replaces this body with the durable job insert.
create function app.contract_reminder_key(p_key jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_policy jsonb;
  v_source jsonb;
  v_state jsonb;
begin
  perform app.contract_require('notification_key', p_key);
  if not exists (select 1 from app.contract_reminder_kinds r
                  where r.source_type = p_key ->> 'source_type'
                    and r.reminder_kind = p_key ->> 'reminder_kind') then
    perform app.cmd_fail('validation_failed', '{"reminder_kind": "unregistered"}');
  end if;
  v_policy := app.policy_effective('q2_church_time');
  v_source := jsonb_build_object(
    'source_type', p_key -> 'source_type',
    'source_id', p_key -> 'source_id',
    'source_revision', p_key -> 'source_revision');
  v_state := app.contract_check_source(v_source);
  if not (v_state ->> 'current')::boolean then
    perform app.cmd_fail('conflict');
  end if;
  return jsonb_build_object(
    'key', p_key || jsonb_build_object(
             'source_revision', (p_key ->> 'source_revision')::numeric::bigint,
             'scheduled_at', app.cmd_utc((p_key ->> 'scheduled_at')::timestamptz)),
    'policy_source', v_policy ->> 'source');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing here is reachable by client roles
-- ---------------------------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as fn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname ~ '^(contract|policy|platform)_'
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.fn);
  end loop;
  for r in
    select c.oid::regclass as tbl
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and c.relkind = 'r'
       and c.relname ~ '^(contract|policy|platform_environment)'
  loop
    execute format('alter table %s enable row level security', r.tbl);
    execute format('revoke all on table %s from public, anon, authenticated, service_role', r.tbl);
  end loop;
end;
$$;
