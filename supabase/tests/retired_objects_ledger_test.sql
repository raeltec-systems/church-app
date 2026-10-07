-- Retired-object ledger (story 2.13): pins the exact set of retired_* objects that wait for an
-- owner-approved drop, as listed in docs/runbooks/contracts-and-owner-seams.md ("Retired-object
-- ledger"). A new retirement must add its row to that table and to the lists below; an
-- owner-approved drop removes it from both. Every retired object is closed to every client role.
begin;
select plan(5);

-- Every relation (table, index, sequence) or function in app/api whose name marks it retired.
create temp view ledger_actual as
  select c.relkind::text as kind, n.nspname || '.' || c.relname as name
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('app', 'api', 'public') and c.relname like '%retired%'
     and c.relname <> 'contract_retired_functions' and c.relname not like 'contract_retired_functions_%'
  union all
  select 'f', p.oid::regprocedure::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'api', 'public') and p.proname like '%retired%';

select set_eq(
  $$select kind, name from ledger_actual$$,
  $$values
    -- story 1.4: typed command entry points (also in app.contract_retired_functions)
    ('f', 'app.retired_fixture_counter_command_v0(integer,text,uuid,bigint,jsonb)'),
    ('f', 'api.retired_fixture_counter_command_v0(integer,text,uuid,bigint,jsonb)'),
    ('f', 'app.retired_cmd_execute_v0(integer,text,uuid,bigint,jsonb,regprocedure,boolean)'),
    -- story 2.3: operator journal before the wider action list
    ('r', 'app.ops_retired_operator_actions_v0'),
    ('i', 'app.ops_retired_operator_actions_v0_pkey'),
    ('S', 'app.ops_retired_operator_actions_v0_id_seq'),
    -- story 2.12: access audit and operator journal before the wider action lists
    ('r', 'app.identity_retired_access_audit_v0'),
    ('i', 'app.identity_retired_access_audit_v0_pkey'),
    ('i', 'app.identity_retired_access_audit_v0_target'),
    ('S', 'app.identity_retired_access_audit_v0_event_id_seq'),
    ('r', 'app.ops_retired_operator_actions_v1'),
    ('i', 'app.ops_retired_operator_actions_v1_pkey'),
    ('S', 'app.ops_retired_operator_actions_v1_id_seq')$$,
  'the retired objects are exactly the ledger in contracts-and-owner-seams.md'
);

select set_eq(
  $$select function_signature from app.contract_retired_functions$$,
  $$select name from ledger_actual where kind = 'f'$$,
  'every retired function in the ledger is listed in app.contract_retired_functions'
);

select is(
  (select count(*)::int
     from ledger_actual l
     cross join unnest(array['anon', 'authenticated', 'service_role', 'public']) r
     cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
    where l.kind = 'r' and has_table_privilege(r, l.name, p)),
  0,
  'no client role has any privilege on a retired table'
);

select is(
  (select count(*)::int
     from ledger_actual l
     cross join unnest(array['anon', 'authenticated', 'service_role', 'public']) r
     cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
    where l.kind = 'S' and has_sequence_privilege(r, l.name, p)),
  0,
  'no client role has any privilege on a retired sequence'
);

select is(
  (select count(*)::int
     from ledger_actual l
     cross join unnest(array['anon', 'authenticated', 'service_role', 'public']) r
    where l.kind = 'f' and has_function_privilege(r, l.name, 'EXECUTE')),
  0,
  'no client role can execute a retired function'
);

select * from finish();
rollback;
