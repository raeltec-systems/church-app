-- Cross-epic contracts and owner seams (story 1.5): privileges, owner registry and boundary
-- guard, lifecycle/source/reminder registration and dispatch, fail-closed policy gates, money
-- scale and zone existence. The shared wire fixtures run against app.contract_check in
-- supabase/tests/contract_fixtures_check.sh. Run with `npm run db:test`. SYNTHETIC data only.
begin;
select plan(77);

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
    where n.nspname = 'app' and p.proname ~ '^(contract|policy|platform)_'
      and not coalesce('search_path=""' = any(p.proconfig), false)),
  0,
  'every contract/policy/platform function pins an empty search_path'
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
select hasnt_column('app', 'contract_lifecycle_hooks', 'handler_oid',
  'hooks are stored as signature text (no reg* columns that block pg_upgrade)');
select is(
  (select count(*)::int from pg_attribute a join pg_class c on c.oid = a.attrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and a.attnum > 0 and not a.attisdropped
      and a.atttypid in ('regproc'::regtype, 'regprocedure'::regtype, 'regclass'::regtype)),
  0,
  'no app table column uses a reg* type'
);

-- Wire contract spot checks (the full fixture set runs in contract_fixtures_check.sh) --------
select is(app.contract_check('member_ref', '{"member_id": "00000000-0000-4000-8000-000000000001"}'),
  '{"valid": true, "field_errors": {}}'::jsonb, 'a canonical member_ref is valid');
select is(app.contract_check('money', '{"amount": 12.5, "currency": "XTS"}') -> 'field_errors',
  '{"amount": "invalid"}'::jsonb, 'a float amount is rejected');
select throws_ok($$select app.contract_check('nope', '{}')$$, '22023', 'unknown contract kind',
  'an unknown contract kind is a programming error');

-- Owner registry and boundary guard ----------------------------------------------------------
select is((select count(*)::int from app.contract_unowned_objects()), 0,
  'every app table, view, sequence and function has a registered owner prefix');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'no app function references an owner its module may not depend on');
select is(app.contract_object_module('fixture_counters'), 'fixture', 'prefix lookup: fixture');
select is(app.contract_object_module('cmd_execute'), 'platform', 'prefix lookup: platform kernel');
select ok(
  exists (select 1 from app.contract_module_dependencies where from_module = 'cells' and to_module = 'duties')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'duties' and to_module = 'cells')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'identity' and to_module <> 'platform')
  and not exists (select 1 from app.contract_module_dependencies where from_module = 'notifications' and to_module = 'followups'),
  'dependency edges follow the architecture diagram (owners -> duties, never back; identity depends on no owner)'
);
select is(
  array(select module from app.contract_modules where lock_rank is not null order by lock_rank, module),
  array['identity', 'care', 'cells', 'chat', 'content', 'directory', 'duties', 'fixture',
        'offerings', 'prayer', 'services', 'followups', 'notifications'],
  'lock ranks follow AD-2: identity, domain owners, follow-ups, notifications'
);

create function app.cells_fixture_peek() returns void language plpgsql set search_path = '' as $$
begin perform 1 from app.care_fixture_secret; end; $$;
create function app.cells_fixture_uses_duties() returns void language plpgsql set search_path = '' as $$
begin perform 1 from app.duties_fixture_slots; end; $$;
create function app.duties_fixture_calls_cells() returns void language plpgsql set search_path = '' as $$
begin perform 1 from "app"."cells_fixture_meetings"; end; $$;
create function app.zz_unowned_fixture() returns void language sql as $$ select $$;

select results_eq(
  $$select function_name || '->' || referenced_module from app.contract_boundary_violations() order by 1$$,
  $$values ('cells_fixture_peek->care'::text), ('duties_fixture_calls_cells->cells')$$,
  'the guard reports disallowed owner references (quoted or not) and allows owner -> duties'
);
select results_eq(
  $$select object_kind || ':' || object_name from app.contract_unowned_objects()$$,
  $$values ('function:zz_unowned_fixture'::text)$$,
  'the guard reports an object without an owner prefix'
);
drop function app.cells_fixture_peek();
drop function app.duties_fixture_calls_cells();
drop function app.zz_unowned_fixture();

-- Lifecycle hooks -----------------------------------------------------------------------------
create temp table hook_log (seq serial, module text, event text);
grant all on table hook_log to public;
grant all on sequence hook_log_seq_seq to public;

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
create function app.cells_fixture_wrong_args(p text) returns void language sql as $$ select $$;
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
  'public.cells_fixture_outside(jsonb)')$$, 'PCTR1', null, 'a hook outside app is refused');
select throws_ok($$select app.contract_register_lifecycle_hook('cells', 'access_hold_applied',
  'app.cells_fixture_on_event(jsonb)')$$, '23505', null, 'one hook per owner and event');

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
  select jsonb_build_object('current', (p ->> 'source_revision') = '3', 'revision', 3); $$;

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

-- Policy gates and environment ---------------------------------------------------------------
select is((select count(*)::int from app.policy_gates where state = 'approved'), 0,
  'no policy gate is approved by any migration');
select results_eq(
  $$select gate from app.policy_gates where fixture_value is not null order by gate$$,
  $$values ('q2_church_time'::text), ('q9_money')$$,
  'only the Q2 and Q9 gates carry (labelled) test fixtures; access and sending have none');
select is(app.platform_current_environment(), 'local', 'the local seed marks the local environment');
select is(app.policy_effective('q2_church_time') ->> 'source', 'fixture',
  'local development reads the labelled fixture');
select is(
  pg_temp.cmd_error($$select app.policy_effective('q1_auth_recovery')$$),
  '{"code": "unavailable", "field_errors": {"q1_auth_recovery": "gate_closed"}}'::jsonb,
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
select is(app.contract_money_json(12.5, 'XTS'), '{"amount": "12.50", "currency": "XTS"}'::jsonb,
  'money is written at the approved scale');
select throws_ok($$select app.contract_money_json(12.505, 'XTS')$$, '22023', null,
  'money is never rounded silently');
select lives_ok($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "Etc/UTC"}')$$,
  'an existing IANA zone is accepted');
select is(
  pg_temp.cmd_error($$select app.contract_require('zoned_local', '{"local": "2026-10-04T09:00:00", "zone": "Mars/Olympus_Mons"}')$$),
  '{"code": "validation_failed", "field_errors": {"zone": "unknown"}}'::jsonb,
  'a well-formed but unknown zone is refused server-side');

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

-- Production behaviour: unmarked or production environment never honours fixtures -------------
delete from app.platform_environment;
select is(app.platform_current_environment(), 'production', 'an unmarked database behaves as production');
select is(
  pg_temp.cmd_error($$select app.policy_effective('q2_church_time')$$),
  '{"code": "unavailable", "field_errors": {"q2_church_time": "gate_closed"}}'::jsonb,
  'production ignores the Q2 fixture: scheduling policy stays closed');
select is(
  pg_temp.cmd_error($$select app.contract_money_amount('{"amount": "12.50", "currency": "XTS"}')$$),
  '{"code": "unavailable", "field_errors": {"q9_money": "gate_closed"}}'::jsonb,
  'production ignores the Q9 fixture: money scale stays closed');
select is(
  pg_temp.cmd_error($$select app.contract_reminder_key('{"source_type": "cells_fixture_meeting", "source_id": "00000000-0000-4000-8000-000000000001", "source_revision": 3, "recipient_member_id": "00000000-0000-4000-8000-000000000002", "reminder_kind": "fixture_nudge", "scheduled_at": "2026-10-04T07:00:00Z"}')$$),
  '{"code": "unavailable", "field_errors": {"q2_church_time": "gate_closed"}}'::jsonb,
  'production refuses reminder keys while Q2 is unresolved');
select lives_ok($$select app.platform_set_environment('staging', 'synthetic test')$$, 'staging can be marked');
select is(app.policy_effective('q9_money') ->> 'source', 'fixture', 'staging reads labelled fixtures');
select lives_ok($$select app.platform_set_environment('production', 'synthetic test')$$, 'production can be marked');
select ok(not app.policy_is_open('q2_church_time'), 'a marked production database stays closed too');

-- Approval is explicit and attributed ---------------------------------------------------------
select throws_ok($$select app.policy_approve('q2_church_time', '{"zone": "Etc/UTC"}', '  ', 'note')$$,
  '22023', null, 'approval needs a named approver');
select throws_ok($$select app.policy_approve('q2_church_time', '{"zone": "Etc/UTC"}', 'synthetic owner', '')$$,
  '22023', null, 'approval needs a decision note');
select throws_ok($$select app.policy_approve('q2_church_time', (select fixture_value from app.policy_gates where gate = 'q2_church_time'), 'synthetic owner', 'note')$$,
  '22023', null, 'a labelled fixture value cannot be approved');
select throws_ok($$update app.policy_gates set state = 'approved' where gate = 'q4_personal_data'$$,
  '23514', null, 'a gate cannot be flipped to approved without value, approver and note');
select lives_ok($$select app.policy_approve('q2_church_time', '{"zone": "Etc/UTC"}', 'synthetic owner', 'pgTAP only, rolled back')$$,
  'an explicit attributed approval is recorded');
select is(app.policy_effective('q2_church_time'),
  '{"gate": "q2_church_time", "source": "approved", "value": {"zone": "Etc/UTC"}}'::jsonb,
  'an approved gate opens in production with the approved value');

-- A registered hook whose function disappeared fails closed -----------------------------------
drop function app.cells_fixture_on_event(jsonb);
select throws_ok(
  $$select app.contract_dispatch_lifecycle('{"event": "access_hold_applied", "member_id": "00000000-0000-4000-8000-000000000001", "occurred_at": "2026-10-03T12:00:00Z", "identity_revision": 3}')$$,
  'PCTR1', null, 'a missing registered hook aborts the lifecycle dispatch');

select * from finish();
rollback;
