-- Cross-epic contracts and owner seams (story 1.5).
--
-- 1. Wire contract v1: `app.contract_check(kind, value)` is the SQL authority for the shared
--    fixtures in packages/contracts/fixtures/v1 (identifiers, actor, source/purpose, revisions,
--    UTC instants, church-local intent, exact money, command request/response). The Dart and
--    TypeScript client mappings pass the same fixtures.
-- 2. Owner registry (AD-1): modules, their object-name prefixes, the allowed dependency edges
--    from the architecture's binding diagram and a guard that reports unowned `app` objects
--    and literal references to an owner a module may not depend on.
-- 3. Owner seams: source owners register source types (with a current-state check hook),
--    purposes and reminder kinds; owners register lifecycle hooks. Emitters call hooks through
--    the registry, so they never reference another owner's implementation.
-- 4. Fail-closed policy gates (AD-9, AD-17, AD-18): unresolved decisions stay closed. Labelled
--    fixture values are honoured only in an explicitly marked local/staging environment; an
--    unmarked database behaves as production. No gate is approved here.
--
-- Everything here is migration-time or server-internal: no client role gets any privilege.
-- No feature business rules or concrete state machines; owners add those in later epics.

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

-- Monotonic revision: JSON integer 1..2^53-1 (safe in every client runtime).
create function app.contract_revision_error(p_value jsonb, p_nullable boolean default false)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then
      case when p_nullable then null else 'required' end
    when jsonb_typeof(p_value) = 'number'
         and (p_value #>> '{}') ~ '^[1-9][0-9]{0,15}$'
         and (p_value #>> '{}')::numeric <= 9007199254740991
      then null
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

-- IANA zone name shape; existence is checked server-side by contract_require.
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
         and (p_value #>> '{}') ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$'
      then null
    else 'invalid'
  end;
$$;

-- Exact decimal string: no float, no exponent, no separators, <= 15 integer and <= 6 fraction
-- digits, no negative zero. The approved per-currency scale is a policy check (Q9).
create function app.contract_amount_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) = 'string'
         and (p_value #>> '{}') ~ '^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$'
         and (p_value #>> '{}') !~ '^-0(\.0+)?$'
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

-- {"$": "unknown_field"} when the object carries a key outside the allowed set.
create function app.contract_unknown_keys(p_value jsonb, p_allowed text[], p_root text default '$')
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case
    when exists (select 1 from jsonb_object_keys(p_value) k where k <> all (p_allowed))
      then jsonb_build_object(p_root, 'unknown_field')
    else '{}'::jsonb
  end;
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

-- Contract v1 lifecycle events (Identity-owned stub list, AD-14). A new event is a contract
-- version change: update this list, app.contract_lifecycle_events and the shared fixtures.
create function app.contract_lifecycle_event_names()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['access_hold_applied', 'access_hold_released', 'scope_revoked',
               'account_deactivated', 'deletion_requested', 'cell_transferred'];
$$;

-- The single SQL authority for the shared v1 fixtures. Returns {valid, field_errors}.
create function app.contract_check(p_kind text, p_value jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := coalesce(p_value, 'null'::jsonb);
  e jsonb := '{}'::jsonb;
  v_root text := case when p_kind = 'command_request' then 'envelope' else '$' end;
begin
  if p_kind not in ('member_ref', 'account_ref', 'actor', 'source_ref', 'task_source',
                    'notification_key', 'lifecycle_event', 'instant', 'zoned_local', 'money',
                    'command_request', 'command_response') then
    raise exception using errcode = '22023', message = 'unknown contract kind';
  end if;

  if p_kind = 'instant' then
    e := jsonb_strip_nulls(jsonb_build_object('$', app.contract_instant_error(v)));
    return jsonb_build_object('valid', e = '{}'::jsonb, 'field_errors', e);
  end if;

  if jsonb_typeof(v) <> 'object' then
    e := jsonb_build_object(v_root, 'must_be_object');
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
                           and (v ->> 'event') = any (app.contract_lifecycle_event_names()) then null
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
    -- Mirrors the kernel envelope (20261003170000) with stricter revision and command shapes.
    e := jsonb_build_object(
           'version', case
                        when coalesce(jsonb_typeof(v -> 'version'), 'null') = 'null' then 'required'
                        when jsonb_typeof(v -> 'version') = 'number' and (v ->> 'version') = '1' then null
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
              v, array['version', 'command', 'request_id', 'expected_revision', 'payload'],
              'envelope');

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
                                       where jsonb_typeof(f.value) <> 'string')
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

-- Server-side use: raises the kernel's validation_failed (PCMD1) with the contract field errors,
-- and adds the server-only zone existence check.
create function app.contract_require(p_kind text, p_value jsonb)
returns void
language plpgsql
volatile
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

-- ---------------------------------------------------------------------------------------------
-- Owner registry (AD-1) and boundary guard
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

insert into app.contract_modules (module, lock_rank, description) values
  ('platform', null, 'Command kernel, wire contracts, owner registry, policy gates, tracer status'),
  ('orchestration', null, 'Cross-domain application commands that call owner operations'),
  ('retired', null, 'Inert objects retired by revoke + rename (retired_<name>_v<n>) awaiting an owner-approved drop'),
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
  ('orch_', 'orchestration'), ('retired_', 'retired'),
  ('identity_', 'identity'), ('content_', 'content'), ('cells_', 'cells'), ('care_', 'care'),
  ('prayer_', 'prayer'), ('directory_', 'directory'), ('services_', 'services'),
  ('offerings_', 'offerings'), ('chat_', 'chat'), ('duties_', 'duties'),
  ('fixture_', 'fixture'), ('followups_', 'followups'), ('notifications_', 'notifications');

-- Every module may use the platform kernel; all owners may use Identity checks.
insert into app.contract_module_dependencies (from_module, to_module)
select m.module, 'platform' from app.contract_modules m where m.module <> 'platform'
union
select m.module, 'identity' from app.contract_modules m
 where m.module not in ('platform', 'identity', 'fixture')
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
-- Temporary, recorded exception: the kernel's authorization seam app.cmd_authorize (story 1.4)
-- reads the SYNTHETIC fixture grants until the identity epic replaces its body.
select 'platform', 'fixture'
union
-- Cross-domain orchestration may call every owner.
select 'orchestration', m.module from app.contract_modules m
 where m.module not in ('orchestration', 'platform', 'identity')
union
-- Retired objects have no client privileges and keep their original bodies.
select 'retired', m.module from app.contract_modules m
 where m.module not in ('retired', 'platform', 'identity');

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

-- App tables, views, sequences and functions with no registered owner prefix.
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
  select 'function', p.proname::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and app.contract_object_module(p.proname) is null;
$$;

-- Literal references from an app function body to an app object whose owner the function's
-- module may not depend on. A lint over function source: registered hooks are called through
-- the registry (no literal reference), which is the sanctioned way to reach another owner.
create function app.contract_boundary_violations()
returns table (function_name text, function_module text, referenced_object text,
               referenced_module text)
language sql
stable
set search_path = ''
as $$
  select distinct f.proname::text, f.module, r.object_name, r.module
    from (
      select p.proname, p.prosrc, app.contract_object_module(p.proname) as module
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app'
    ) f
   cross join lateral (
      select lower(m[1]) as object_name, app.contract_object_module(lower(m[1])) as module
        from regexp_matches(f.prosrc, '"?\mapp"?\s*\.\s*"?([a-z0-9_]+)', 'gi') as m
   ) r
   where f.module is not null
     and r.module is not null
     and r.module <> f.module
     and not exists (
       select 1 from app.contract_module_dependencies d
        where d.from_module = f.module and d.to_module = r.module
     );
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner seams: lifecycle hooks, source types, purposes, reminder kinds
-- ---------------------------------------------------------------------------------------------

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

-- The handler must be an app function named with the registering owner's prefix and have
-- exactly the given argument/return types.
create function app.contract_validate_handler(
  p_module text,
  p_handler regprocedure,
  p_return regtype
) returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_proc record;
begin
  if not exists (select 1 from app.contract_modules m
                  where m.module = p_module and m.lock_rank is not null) then
    perform app.contract_registration_fail('unknown or non-owner module: ' || coalesce(p_module, '<null>'));
  end if;
  select p.proname, n.nspname, p.pronargs, p.proargtypes, p.prorettype, p.proretset
    into v_proc
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where p.oid = p_handler;
  if not found or v_proc.nspname <> 'app' then
    perform app.contract_registration_fail('handler must be an app function');
  end if;
  if app.contract_object_module(v_proc.proname) is distinct from p_module then
    perform app.contract_registration_fail(
      format('handler %s is not owned by module %s', p_handler, p_module));
  end if;
  if v_proc.pronargs <> 1 or v_proc.proargtypes[0] <> 'jsonb'::regtype::oid
     or v_proc.prorettype <> p_return::oid or v_proc.proretset then
    perform app.contract_registration_fail(
      format('handler %s must take (jsonb) and return %s', p_handler, p_return));
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
volatile
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

-- Absent row = production behaviour. Local seed marks 'local'; a hosted project is marked only
-- by its operator (entry 8 / owner), so an unmarked hosted database never honours fixtures.
create table app.platform_environment (
  singleton boolean primary key default true check (singleton),
  environment text not null check (environment in ('local', 'staging', 'production')),
  set_by text not null check (length(btrim(set_by)) > 0),
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
begin
  insert into app.platform_environment (singleton, environment, set_by)
  values (true, p_environment, p_set_by)
  on conflict (singleton) do update
    set environment = excluded.environment, set_by = excluded.set_by, set_at = now();
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
   '{"fixture_label": "TEST FIXTURE - not church policy", "zone": "Etc/UTC", "quiet_hours": null}'),
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

-- Effective policy value or the kernel's `unavailable` (PCMD1) when the gate is closed.
create function app.policy_effective(p_gate text)
returns jsonb
language plpgsql
volatile
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
  perform app.cmd_fail('unavailable', jsonb_build_object(p_gate, 'gate_closed'));
  return null;
end;
$$;

create function app.policy_is_open(p_gate text)
returns boolean
language plpgsql
volatile
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
volatile
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

-- Wire form of an exact amount at the approved scale; never rounds silently.
create function app.contract_money_json(p_amount numeric, p_currency text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_scale integer;
begin
  v_scale := (app.policy_effective('q9_money') -> 'value' -> 'currencies' ->> p_currency)::integer;
  if v_scale is null or p_amount is null or p_amount <> round(p_amount, v_scale)
     or abs(p_amount) >= 1e15 then
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
