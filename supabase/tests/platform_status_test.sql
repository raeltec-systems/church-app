-- Permission evidence for the tracer read path (AD-2). Run with `npm run db:test`.
begin;
select plan(29);

-- Structure -----------------------------------------------------------------
select has_table('app', 'platform_status', 'app.platform_status exists');
select has_view('api', 'platform_status', 'api.platform_status view exists');
select ok(
  (select relrowsecurity from pg_class where oid = 'app.platform_status'::regclass),
  'RLS is enabled on app.platform_status'
);
select ok(
  (select coalesce(reloptions, '{}') @> array['security_invoker=true']
     from pg_class where oid = 'api.platform_status'::regclass),
  'api.platform_status is security_invoker'
);
select is(
  (select count(*)::int from app.platform_status where is_synthetic),
  1,
  'seed holds exactly one synthetic row'
);
select throws_ok(
  $$insert into app.platform_status (id, status, message) values (2, 'x', 'y')$$,
  '23514',
  null,
  'only the single id = 1 row is allowed'
);

-- Privileges: SELECT only, nothing else, for both client roles ----------------
select table_privs_are('api', 'platform_status', 'anon', array['SELECT'],
  'anon has only SELECT on api.platform_status');
select table_privs_are('api', 'platform_status', 'authenticated', array['SELECT'],
  'authenticated has only SELECT on api.platform_status');
select table_privs_are('app', 'platform_status', 'anon', array['SELECT'],
  'anon has only SELECT on app.platform_status (needed by security_invoker)');
select table_privs_are('app', 'platform_status', 'authenticated', array['SELECT'],
  'authenticated has only SELECT on app.platform_status');
select schema_privs_are('app', 'anon', array['USAGE'], 'anon cannot create in app');
select schema_privs_are('api', 'anon', array['USAGE'], 'anon cannot create in api');
select schema_privs_are('app', 'authenticated', array['USAGE'], 'authenticated cannot create in app');
select schema_privs_are('api', 'authenticated', array['USAGE'], 'authenticated cannot create in api');

-- Functions created later do not get default PUBLIC EXECUTE --------------------
create function app.tracer_probe() returns int language sql as 'select 1';
select ok(
  not has_function_privilege('anon', 'app.tracer_probe()', 'execute'),
  'new app functions are not executable by anon without an explicit grant'
);

-- New postgres-created public objects are not exposed to client roles by default ---
create table public.tracer_default_acl_probe (id int);
select table_privs_are('public', 'tracer_default_acl_probe', 'anon', array[]::text[],
  'a new public table grants anon nothing by default');
select table_privs_are('public', 'tracer_default_acl_probe', 'authenticated', array[]::text[],
  'a new public table grants authenticated nothing by default');
create function public.tracer_default_acl_probe_fn() returns int language sql as 'select 1';
select ok(
  not has_function_privilege('anon', 'public.tracer_default_acl_probe_fn()', 'execute'),
  'a new public function is not executable by anon by default'
);

-- anon: can read, cannot write -------------------------------------------------
set local role anon;
select is(
  (select count(*)::int from api.platform_status),
  1,
  'anon reads the status through api'
);
select throws_ok(
  $$insert into api.platform_status (status, message) values ('x', 'y')$$,
  '42501', null, 'anon cannot INSERT through api'
);
select throws_ok(
  $$update api.platform_status set status = 'x'$$,
  '42501', null, 'anon cannot UPDATE through api'
);
select throws_ok(
  $$delete from api.platform_status$$,
  '42501', null, 'anon cannot DELETE through api'
);
select throws_ok(
  $$update app.platform_status set status = 'x'$$,
  '42501', null, 'anon cannot UPDATE app directly'
);
select throws_ok(
  $$insert into app.platform_status (id, status, message) values (1, 'x', 'y')$$,
  '42501', null, 'anon cannot INSERT into app directly'
);
reset role;

-- authenticated: can read, cannot write ---------------------------------------
set local role authenticated;
select is(
  (select count(*)::int from api.platform_status),
  1,
  'authenticated reads the status through api'
);
select throws_ok(
  $$insert into api.platform_status (status, message) values ('x', 'y')$$,
  '42501', null, 'authenticated cannot INSERT through api'
);
select throws_ok(
  $$update api.platform_status set status = 'x'$$,
  '42501', null, 'authenticated cannot UPDATE through api'
);
select throws_ok(
  $$delete from api.platform_status$$,
  '42501', null, 'authenticated cannot DELETE through api'
);
select throws_ok(
  $$insert into app.platform_status (id, status, message) values (1, 'x', 'y')$$,
  '42501', null, 'authenticated cannot INSERT into app directly'
);
reset role;

select * from finish();
rollback;
