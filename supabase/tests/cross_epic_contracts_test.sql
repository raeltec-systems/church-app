-- Cross-epic contracts and owner seams (story 1.5): privileges, owner registry and boundary
-- guards, lifecycle/source/reminder registration and dispatch, environment marker, fail-closed
-- policy gates, money scale and zone existence. The shared wire fixtures run against
-- app.contract_check and api.fixture_counter_command in supabase/tests/contract_fixtures_check.sh.
-- Run with `npm run db:test`. SYNTHETIC data only.
begin;
select plan(102);

-- Helper: run a statement and return the kernel error it raised as {code, field_errors}.
create function pg_temp.cmd_error(p_sql text) returns jsonb
language plpgsql as $$
declare
  v_code text;
  v_detail text;
begin
  execute p_sql;
  return '{"code": "none"}'::jsonb;
exception when sqlstate 'PCMD1' then
  get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_code, 'field_errors', v_detail::jsonb -> 'field_errors');
end;
$$;

-- Privileges ----------------------------------------------------------------------------------
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and p.proname ~ '^(contract|policy|platform)_'
      and has_function_privilege(r, p.oid, 'EXECUTE')),
  0,
  'no client role can execute any contract/policy/platform function'
);
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname ~ '^(contract|policy|platform)_' and p.prosecdef),
  0,
  'no contract/policy/platform function is SECURITY DEFINER'
);
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relkind = 'r' and c.relname ~ '^(contract|policy|platform_environment)'),
  'RLS is enabled on every registry, gate and environment table'
);
select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
     cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
    where n.nspname = 'app' and c.relkind = 'r'
      and c.relname ~ '^(contract|policy|platform_environment)'
      and has_table_privilege(r, c.oid, priv)),
  0,
  'no client role has any privilege on registry, gate or environment tables'
);
select is(
  (select count(*)::int from pg_attribute a join pg_class c on c.oid = a.attrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and a.attnum > 0 and not a.attisdropped
      and a.atttypid in ('regproc'::regtype, 'regprocedure'::regtype, 'regclass'::regtype)),
  0,
  'no app table column uses a reg* type (they block pg_upgrade)'
);
select is(
  (select count(*)::int
     from app.contract_retired_functions r
     cross join unnest(array['anon', 'authenticated', 'service_role']) role
    where has_function_privilege(role, r.function_signature::regprocedure, 'EXECUTE')),
  0,
  'the three listed retired functions are not executable by any client role'
);
select is((select count(*)::int from app.contract_retired_functions), 3,
  'exactly three retired functions are listed');

-- Wire contract spot checks (the full fixture set runs in contract_fixtures_check.sh) --------
select is(app.contract_check('member_ref', '{"member_id": "00000000-0000-4000-8000-000000000001"}'),
  '{"valid": true, "field_errors": {}}'::jsonb, 'a canonical member_ref is valid');
select is(app.contract_check('money', '{"amount": 12.5, "currency": "XTS", "x": 1}') -> 'field_errors',
  '{"amount": "invalid", "x": "unknown_field"}'::jsonb,
  'a float amount is rejected and the unknown key is reported on itself');
select throws_ok($$select app.contract_check('nope', '{}')$$, '22023', 'unknown contract kind',
  'an unknown contract kind is a programming error');
select results_eq(
  $$select event from app.contract_lifecycle_events order by event$$,
  $$values ('access_hold_applied'::text), ('access_hold_released'), ('account_deactivated'),
           ('cell_transferred'), ('deletion_requested'), ('member_deleted'),
           ('membership_deactivated'),
           ('membership_restored'), ('scope_revoked'), ('sessions_revoked')$$,
  'the lifecycle event table is the v1 list the client mappings carry');
select is(
  (select count(*)::int from app.contract_lifecycle_events e
    where not (app.contract_check('lifecycle_event', jsonb_build_object(
      'event', e.event, 'member_id', '00000000-0000-4000-8000-000000000001',
      'occurred_at', '2026-10-03T12:00:00Z', 'identity_revision', 1)) ->> 'valid')::boolean),
  0, 'contract_check accepts exactly the events in the table (single source)');

-- Kernel envelope = contract (single authority) ----------------------------------------------
select is(
  app.cmd_execute('{"version": 1, "request_id": "00000000-0000-4000-8000-00000000000A", "expected_revision": 0, "payload": {}, "extra": 1}',
                  null, null, false) -> 'field_errors',
  '{"command": "required", "request_id": "invalid", "expected_revision": "invalid", "extra": "unknown_field"}'::jsonb,
  'the kernel reports the contract codes: missing command, uppercase request_id, revision 0, per-key unknown');
select is(
  app.cmd_execute('{"version": 1, "command": "fixture_counter.nope", "request_id": "00000000-0000-4000-8000-000000000001", "payload": {}}',
                  null, null, false) -> 'field_errors',
  '{"command": "unsupported"}'::jsonb,
  'a well-formed command that is not allowlisted stays unsupported');

-- Owner registry and boundary guards ----------------------------------------------------------
select is((select count(*)::int from app.contract_unowned_objects()), 0,
  'every app table, view, sequence and function has a registered owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0,
  'every app/api function pins search_path = '''' (references must be schema-qualified)');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'nothing in app references an owner its module may not depend on');
select is(app.contract_object_module('fixture_counters'), 'fixture', 'prefix lookup: fixture');
select is(app.contract_function_module('app.retired_cmd_execute_v0(integer,text,uuid,bigint,jsonb,regprocedure,boolean)'::regprocedure),
  'retired', 'a listed retired function belongs to the retired module');
select ok(
  exists (select 1 from app.contract_module_dependencies where from_module = 'cells' and to_module = 'duties')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'duties' and to_module = 'cells')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'identity' and to_module <> 'platform')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'platform')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'notifications' and to_module = 'followups'),
  'dependency edges follow the architecture diagram; platform depends on no owner'
);
select is(
  array(select module from app.contract_modules where lock_rank is not null order by lock_rank, module),
  array['identity', 'care', 'cells', 'chat', 'content', 'directory', 'duties', 'fixture',
        'offerings', 'prayer', 'services', 'followups', 'notifications'],
  'lock ranks follow AD-2: identity, domain owners, follow-ups, notifications'
);

-- Each bypass the review reproduced is now reported.
create table app.care_fixture_secret (id integer);
create function app.care_fixture_value() returns integer language sql set search_path = '' as $$ select 1 $$;
create function app.care_fixture_trg() returns trigger language plpgsql set search_path = '' as $$
begin return new; end; $$;
create function app.cells_fixture_peek() returns void language plpgsql set search_path = '' as $$
begin perform 1 from app.care_fixture_secret; end; $$;
create function app.cells_atomic_peek() returns bigint language sql set search_path = ''
begin atomic select count(*) from app.care_fixture_secret; end;
create function app.cells_fixture_uses_duties() returns void language plpgsql set search_path = '' as $$
begin perform 1 from app.duties_fixture_slots; end; $$;
create function app.duties_fixture_calls_cells() returns void language plpgsql set search_path = '' as $$
begin perform 1 from "app"."cells_fixture_meetings"; end; $$;
create function app.cmd_fixture_peek() returns void language plpgsql set search_path = '' as $$
begin perform 1 from app.fixture_counters; end; $$;
create function app.cells_fixture_unqualified() returns bigint language sql set search_path = app as $$
  select count(*) from care_fixture_secret $$;
create view app.cells_fixture_view as select id from app.care_fixture_secret;
create table app.cells_fixture_rows (id integer default app.care_fixture_value());
create policy cells_fixture_policy on app.cells_fixture_rows
  using (exists (select 1 from app.care_fixture_secret s where s.id = cells_fixture_rows.id));
create trigger cells_fixture_trigger before insert on app.cells_fixture_rows
  for each row execute function app.care_fixture_trg();
create function public.fixture_outside_trg() returns trigger language plpgsql as $$
begin return new; end; $$;
create trigger cells_fixture_outside before update on app.cells_fixture_rows
  for each row execute function public.fixture_outside_trg();
create function app.zz_unowned_fixture() returns void language sql set search_path = '' as $$ select $$;
create function app.retired_fixture_sneak_v0() returns void language sql set search_path = '' as $$ select $$;

select results_eq(
  $$select source_kind || ':' || source_name || '->' || referenced_module
      from app.contract_boundary_violations() order by 1$$,
  $$values
    ('default:app.cells_fixture_rows.id->care'::text),
    ('function:app.cells_atomic_peek()->care'),
    ('function:app.cells_fixture_peek()->care'),
    ('function:app.cmd_fixture_peek()->fixture'),
    ('function:app.duties_fixture_calls_cells()->cells'),
    ('policy:app.cells_fixture_rows.cells_fixture_policy->care'),
    ('trigger:app.cells_fixture_rows.cells_fixture_outside->outside_app'),
    ('trigger:app.cells_fixture_rows.cells_fixture_trigger->care'),
    ('view:app.cells_fixture_view->care')$$,
  'the guard reports BEGIN ATOMIC, quoted, view, policy, default and trigger references, a platform function other than cmd_authorize reaching fixture, and allows owner -> duties'
);
select results_eq(
  $$select function_signature from app.contract_unpinned_functions()$$,
  $$values ('app.cells_fixture_unqualified()'::text)$$,
  'a function with a non-empty search_path (unqualified reads) is reported'
);
select results_eq(
  $$select object_kind || ':' || object_name from app.contract_unowned_objects() order by 1$$,
  $$values ('function:app.retired_fixture_sneak_v0()'::text), ('function:app.zz_unowned_fixture()')$$,
  'unprefixed objects and unlisted retired_* names are unowned'
);
drop function app.cells_fixture_peek();
drop function app.cells_atomic_peek();
drop function app.duties_fixture_calls_cells();
drop function app.cmd_fixture_peek();
drop function app.cells_fixture_unqualified();
drop function app.zz_unowned_fixture();
drop function app.retired_fixture_sneak_v0();
drop view app.cells_fixture_view;
drop table app.cells_fixture_rows;

-- Lifecycle hooks -----------------------------------------------------------------------------
-- Story 3.5 registers Notifications' real hooks; this test uses its own synthetic ones instead
-- (rolled back with the test).
delete from app.contract_lifecycle_hooks where module = 'notifications';
create temp table hook_log (seq serial, module text, event text);

create function app.cells_fixture_on_event(p jsonb) returns void language sql set search_path = '' as $$
  insert into pg_temp.hook_log (module, event) values ('cells', p ->> 'event'); $$;
create function app.duties_fixture_on_event(p jsonb) returns void language sql set search_path = '' as $$
  insert into pg_temp.hook_log (module, event) values ('duties', p ->> 'event'); $$;
create function app.followups_fixture_on_event(p jsonb) returns void language sql set search_path = '' as $$
  insert into pg_temp.hook_log (module, event) values ('followups', p ->> 'event'); $$;
create function app.notifications_fixture_on_event(p jsonb) returns void language plpgsql set search_path = '' as $$
begin
  if p ->> 'identity_revision' = '99' then
    raise exception 'synthetic hook failure';
  end if;
  insert into pg_temp.hook_log (module, event) values ('notifications', p ->> 'event');
end; $$;
create function app.cells_fixture_wrong_args(p text) returns void language sql set search_path = '' as $$ select $$;
create function app.cells_fixture_unpinned(p jsonb) returns void language sql as $$ select $$;
create function public.cells_fixture_outside(p jsonb) returns void language sql as $$ select $$;

-- Registered out of order on purpose: dispatch order comes from the registry, not insertion.
select lives_ok($$select app.contract_register_lifecycle_hook('notifications', 'access_hold_applied',
  'app.notifications_fixture_on_event(jsonb)')$$, 'notifications registers its own hook');
select lives_ok($$select app.contract_register_lifecycle_hook('followups', 'access_hold_applied',
  'app.followups_fixture_on_event(jsonb)')$$, 'followups registers its own hook');
select lives_ok($$select app.contract_register_lifecycle_hook('duties', 'access_hold_applied',
  'app.duties_fixture_on_event(jsonb)')$$, 'duties registers its own hook');
select lives_ok($$select app.contract_register_lifecycle_hook('cells', 'access_hold_applied',
  'app.cells_fixture_on_event(jsonb)')$$, 'cells registers its own hook');

select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'scope_revoked',
  'app.duties_fixture_on_event(jsonb)')$$, 'PCTR1', null,
  'an owner cannot register another owner''s implementation');
select throws_ok($$select app.contract_register_lifecycle_hook('identity', 'scope_revoked',
  'app.cells_fixture_on_event(jsonb)')$$, 'PCTR1', null, 'identity emits but cannot hook');
select throws_ok($$select app.contract_register_lifecycle_hook('orchestration', 'scope_revoked',
  'app.cells_fixture_on_event(jsonb)')$$, 'PCTR1', null, 'a non-owner module cannot register');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'member_promoted',
  'app.cells_fixture_on_event(jsonb)')$$, 'PCTR1', null, 'an unknown lifecycle event is refused');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'scope_revoked',
  'app.cells_fixture_wrong_args(text)')$$, 'PCTR1', null, 'a hook with the wrong signature is refused');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'scope_revoked',
  'app.cells_fixture_unpinned(jsonb)')$$, 'PCTR1', null, 'a hook without an empty search_path is refused');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'scope_revoked',
  'public.cells_fixture_outside(jsonb)')$$, 'PCTR1', null, 'a hook outside app is refused');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'access_hold_applied',
  'app.cells_fixture_on_event(jsonb)')$$, '23505', null, 'one hook per owner and event');
drop function app.cells_fixture_unpinned(jsonb);

select is(
  app.contract_dispatch_lifecycle('{"event": "access_hold_applied", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 1}'),
  4, 'dispatch calls every registered hook');
select results_eq(
  $$select module from hook_log order by seq$$,
  $$values ('cells'::text), ('duties'), ('followups'), ('notifications')$$,
  'hooks run in AD-2 lock order (domain owners by name, then follow-ups, then notifications)'
);
select throws_ok(
  $$select app.contract_dispatch_lifecycle('{"event": "access_hold_applied", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 99}')$$,
  'P0001', 'synthetic hook failure', 'a failing hook fails the lifecycle dispatch');
select is((select count(*)::int from hook_log), 4,
  'the failed dispatch left no partial hook effects');
select is(
  pg_temp.cmd_error($$select app.contract_dispatch_lifecycle('{"event": "member_promoted", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 1}')$$),
  '{"code": "validation_failed", "field_errors": {"event": "invalid"}}'::jsonb,
  'an event outside the contract is validation_failed');
select is(
  app.contract_dispatch_lifecycle('{"event": "scope_revoked", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 2}'),
  0, 'an event with no registered hooks dispatches nothing');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'registered hooks and the dispatcher import no other owner''s implementation');

-- Source types, purposes, reminder kinds -------------------------------------------------------
create function app.cells_fixture_meeting_check(p jsonb) returns jsonb language sql set search_path = '' as $$
  select jsonb_build_object('current', (p ->> 'source_revision')::numeric = 3, 'revision', 3); $$;

select lives_ok($$select app.contract_register_source_type('cells', 'cells_fixture_meeting',
  'app.cells_fixture_meeting_check(jsonb)')$$, 'cells registers a source type with its check hook');
select lives_ok($$select app.contract_register_purpose('cells', 'cells_fixture_meeting', 'fixture_review')$$,
  'the source owner registers a purpose');
select lives_ok($$select app.contract_register_reminder_kind('cells', 'cells_fixture_meeting', 'fixture_nudge')$$,
  'the source owner registers a reminder kind');
select throws_ok($$select app.contract_register_purpose('duties', 'cells_fixture_meeting', 'steal')$$,
  'PCTR1', null, 'another owner cannot register purposes on a source it does not own');
select throws_ok($$select app.contract_register_reminder_kind('notifications', 'cells_fixture_meeting', 'x')$$,
  'PCTR1', null, 'notifications cannot invent reminder kinds for a source');
select throws_ok($$select app.contract_register_source_type('cells', 'cells_fixture_other',
  'app.cells_fixture_on_event(jsonb)')$$, 'PCTR1', null, 'a source hook must return jsonb');
select throws_ok($$select app.contract_register_source_type('cells', 'Bad.Type',
  'app.cells_fixture_meeting_check(jsonb)')$$, 'PCTR1', null, 'a malformed source_type is refused');

select is(
  app.contract_check_source('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3}'),
  '{"current": true, "revision": 3}'::jsonb, 'the source check calls the owner hook');
select is(
  pg_temp.cmd_error($$select app.contract_check_source('{"source_type": "unknown_source", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3}')$$),
  '{"code": "validation_failed", "field_errors": {"source_type": "unregistered"}}'::jsonb,
  'an unregistered source type is validation_failed');
select is(
  pg_temp.cmd_error($$select app.contract_check_source('{"source_type": "cells_fixture_meeting", "source_id": "x", "source_revision": 0}')$$),
  '{"code": "validation_failed", "field_errors": {"source_id": "invalid", "source_revision": "invalid"}}'::jsonb,
  'a malformed source reference carries the contract field errors');

-- Environment marker ---------------------------------------------------------------------------
select is((select count(*)::int from app.platform_environment), 0,
  'nothing marks the environment automatically (no seed write)');
select is(app.platform_current_environment(), 'production', 'an unmarked database behaves as production');
select is(
  pg_temp.cmd_error($$select app.policy_effective('q2_church_time')$$),
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'unmarked: the Q2 fixture is ignored and the error names no internal gate');
select lives_ok($$select app.platform_set_environment('local', 'pgTAP')$$, 'an unmarked database can be marked local');
select is(app.platform_current_environment(), 'local', 'the marker reads back');

-- Policy gates (local) ------------------------------------------------------------------------
select is((select count(*)::int from app.policy_gates where state = 'approved'), 0,
  'no policy gate is approved by any migration');
select results_eq(
  $$select gate from app.policy_gates where fixture_value is not null order by gate$$,
  $$values ('identity_deletion_retention'::text), ('q2_church_time'), ('q9_money')$$,
  'only the Q2, Q9 and Q4 deletion-retention (2.11) gates carry (labelled) test fixtures; access and sending have none');
select is(app.policy_effective('q2_church_time') ->> 'source', 'fixture',
  'local development reads the labelled fixture');
select is(
  pg_temp.cmd_error($$select app.policy_effective('q1_auth_recovery')$$),
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'a gate without a fixture stays closed even locally');
select ok(not app.policy_is_open('private_access') and not app.policy_is_open('outbound_sending'),
  'private access and outbound sending stay closed');

-- Money and zones (local fixture policy) ------------------------------------------------------
select is(app.contract_money_amount('{"amount": "12.50", "currency": "XTS"}'), 12.50::numeric,
  'exact money parses at the fixture scale');
select is(
  pg_temp.cmd_error($$select app.contract_money_amount('{"amount": "12.505", "currency": "XTS"}')$$),
  '{"code": "validation_failed", "field_errors": {"amount": "scale_exceeded"}}'::jsonb,
  'more fraction digits than the approved scale are refused');
select is(
  pg_temp.cmd_error($$select app.contract_money_amount('{"amount": "12.50", "currency": "ZMW"}')$$),
  '{"code": "validation_failed", "field_errors": {"currency": "unsupported"}}'::jsonb,
  'a currency without an approved scale is refused (no church currency is implied)');
select is(
  pg_temp.cmd_error($$select app.contract_money_amount('{"amount": "-1.00", "currency": "XTS"}')$$),
  '{"code": "validation_failed", "field_errors": {"amount": "invalid"}}'::jsonb,
  'the money contract is unsigned');
select is(app.contract_money_json(12.5, 'XTS'), '{"amount": "12.50", "currency": "XTS"}'::jsonb,
  'money is written at the approved scale');
select throws_ok($$select app.contract_money_json(12.505, 'XTS')$$, '22023', null,
  'money is never rounded silently');
select throws_ok($$select app.contract_money_json(-1, 'XTS')$$, '22023', null,
  'a negative amount has no wire form');
select lives_ok($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "UTC"}')$$,
  'UTC is accepted');
select lives_ok($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "Europe/London"}')$$,
  'an existing Area/Location zone is accepted');
select is(
  pg_temp.cmd_error($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "Pacific/Olympus_Mons"}')$$),
  '{"code": "validation_failed", "field_errors": {"zone": "unknown"}}'::jsonb,
  'a well-formed but unknown zone is refused server-side');
select is(
  pg_temp.cmd_error($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "posix/Europe/London"}')$$),
  '{"code": "validation_failed", "field_errors": {"zone": "invalid"}}'::jsonb,
  'posix/ aliases that pg_timezone_names lists are still refused');

-- Reminder key stub (local fixture policy) ----------------------------------------------------
select is(
  app.contract_reminder_key('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "fixture_nudge", "scheduled_at": "2026-10-04T07:00:00Z"}'),
  '{"key": {"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "fixture_nudge", "scheduled_at": "2026-10-04T07:00:00.000000Z"}, "policy_source": "fixture"}'::jsonb,
  'a registered, current reminder key is returned in canonical form under the fixture policy');
select is(
  pg_temp.cmd_error($$select app.contract_reminder_key('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 2, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "fixture_nudge", "scheduled_at": "2026-10-04T07:00:00Z"}')$$),
  '{"code": "conflict", "field_errors": {}}'::jsonb,
  'a reminder for a superseded source revision is a conflict');
select is(
  pg_temp.cmd_error($$select app.contract_reminder_key('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "made_up", "scheduled_at": "2026-10-04T07:00:00Z"}')$$),
  '{"code": "validation_failed", "field_errors": {"reminder_kind": "unregistered"}}'::jsonb,
  'an unregistered reminder kind is refused');

-- Environment transitions: staging and production are one-way ---------------------------------
select lives_ok($$select app.platform_set_environment('staging', 'pgTAP')$$, 'local -> staging is allowed');
select is(app.policy_effective('q9_money') ->> 'source', 'fixture', 'staging reads labelled fixtures');
select throws_ok($$select app.platform_set_environment('local', 'pgTAP')$$, '22023', null,
  'a database once marked staging can never be marked local');
select lives_ok($$select app.platform_set_environment('production', 'pgTAP')$$, 'staging -> production is allowed');
select throws_ok($$select app.platform_set_environment('staging', 'pgTAP')$$, '22023', null,
  'production can never be re-marked staging');
select throws_ok($$select app.platform_set_environment('local', 'pgTAP')$$, '22023', null,
  'production can never be re-marked local');
select lives_ok($$select app.platform_set_environment('production', 'pgTAP again')$$,
  'production can be re-asserted (e.g. after a restore)');
select is(
  array(select environment from app.platform_environment_history order by id),
  array['local', 'staging', 'production', 'production'],
  'every accepted marking is recorded in the history');
select is(
  pg_temp.cmd_error($$select app.contract_money_amount('{"amount": "12.50", "currency": "XTS"}')$$),
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'production ignores the Q9 fixture: money scale stays closed');
select is(
  pg_temp.cmd_error($$select app.contract_reminder_key('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "fixture_nudge", "scheduled_at": "2026-10-04T07:00:00Z"}')$$),
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'production refuses reminder keys while Q2 is unresolved');

-- Approval is explicit, attributed and validated ----------------------------------------------
select throws_ok($$select app.policy_approve('q2_church_time', '{"zone": "UTC"}', '  ', 'note')$$,
  '22023', null, 'approval needs a named approver');
select throws_ok($$select app.policy_approve('q2_church_time', '{"zone": "UTC"}', 'synthetic owner', '')$$,
  '22023', null, 'approval needs a decision note');
select throws_ok($$select app.policy_approve('q2_church_time', (select fixture_value from app.policy_gates where gate = 'q2_church_time'), 'synthetic owner', 'note')$$,
  '22023', null, 'a labelled fixture value cannot be approved');
select throws_ok($$update app.policy_gates set state = 'approved' where gate = 'q4_personal_data'$$,
  '23514', null, 'a gate cannot be flipped to approved without value, approver and note');
select throws_ok($$select app.policy_approve('q9_money', '{"currencies": {"XTS": 7}}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: a scale above 6 is refused');
select throws_ok($$select app.policy_approve('q9_money', '{"currencies": {"XTS": "2"}}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: a string scale is refused');
select throws_ok($$select app.policy_approve('q9_money', '{"currencies": {"XTS": 2.5}}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: a fractional scale is refused');
select throws_ok($$select app.policy_approve('q9_money', '{"currencies": {"xts": 2}}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: a non-ISO currency code is refused');
select throws_ok($$select app.policy_approve('q9_money', '{"currencies": {}}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: an empty currency map is refused');
select throws_ok($$select app.policy_approve('q9_money', '{"scale": 2}', 'synthetic owner', 'note')$$,
  '22023', null, 'q9: a value without currencies is refused');
select is((select state from app.policy_gates where gate = 'q9_money'), 'unresolved',
  'refused approvals left the gate unresolved');
select lives_ok($$select app.policy_approve('q9_money', '{"currencies": {"XTS": 0}}', 'synthetic owner', 'pgTAP only, rolled back')$$,
  'a valid q9 approval is recorded');
select lives_ok($$select app.policy_approve('q2_church_time', '{"zone": "UTC"}', 'synthetic owner', 'pgTAP only, rolled back')$$,
  'an explicit attributed approval is recorded');
select is(app.policy_effective('q2_church_time'),
  '{"gate": "q2_church_time", "source": "approved", "value": {"zone": "UTC"}}'::jsonb,
  'an approved gate opens in production with the approved value');

-- A registered hook whose function disappeared fails closed -----------------------------------
drop function app.cells_fixture_on_event(jsonb);
select throws_ok(
  $$select app.contract_dispatch_lifecycle('{"event": "access_hold_applied", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 3}')$$,
  'PCTR1', null, 'a missing registered hook aborts the lifecycle dispatch');

select * from finish();
rollback;
