-- Command foundation (story 1.4, AD-2): privileges and single-session command semantics.
-- Concurrency and the real Data API path are covered by supabase/tests/command_api_smoke.sh.
-- Run with `npm run db:test`. All actors and data are SYNTHETIC.
begin;
select plan(57);

-- Structure -----------------------------------------------------------------------------------
select has_table('app', 'cmd_receipts', 'app.cmd_receipts exists');
select has_table('app', 'fixture_command_grants', 'app.fixture_command_grants exists');
select has_table('app', 'fixture_counters', 'app.fixture_counters exists');
select ok(
  (select bool_and(relrowsecurity) from pg_class
    where oid in ('app.cmd_receipts'::regclass, 'app.fixture_command_grants'::regclass,
                  'app.fixture_counters'::regclass)),
  'RLS is enabled on every command-foundation table'
);
select col_is_pk('app', 'cmd_receipts', array['actor_id', 'command', 'request_id'],
  'receipts are unique per actor/command/request_id');

-- No direct table privileges for any client role ---------------------------------------------
select table_privs_are('app', t, r, array[]::text[], format('%s has no privileges on app.%s', r, t))
  from unnest(array['cmd_receipts', 'fixture_command_grants', 'fixture_counters']) t
  cross join unnest(array['anon', 'authenticated', 'service_role']) r;

-- Function privileges -------------------------------------------------------------------------
select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname in ('app', 'api') and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  0,
  'no app/api function is executable by PUBLIC'
);
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'api') and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0,
  'anon can execute no app/api function'
);
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C"
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.fixture_counter_command'::text collate "C"), ('app.fixture_counter_command')$$,
  'authenticated can execute only the api wrapper and its definer entry point'
);
select is_definer('app', 'fixture_counter_command',
  array['integer', 'text', 'uuid', 'bigint', 'jsonb'], 'the app entry point is SECURITY DEFINER');
select isnt_definer('api', 'fixture_counter_command',
  array['integer', 'text', 'uuid', 'bigint', 'jsonb'], 'the api wrapper uses invoker security');
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'api')
      and (p.proname like 'cmd\_%' or p.proname like 'fixture\_%')
      and not coalesce('search_path=""' = any(p.proconfig), false)),
  0,
  'every command-foundation function pins an empty search_path'
);

-- Synthetic actors and fixture authority -------------------------------------------------------
-- A: create + increment; B: create + increment (other scope); C: no authority.
insert into app.fixture_command_grants (actor_id, command) values
  ('a0000000-0000-4000-8000-00000000000a', 'fixture_counter.create'),
  ('a0000000-0000-4000-8000-00000000000a', 'fixture_counter.increment'),
  ('b0000000-0000-4000-8000-00000000000b', 'fixture_counter.create'),
  ('b0000000-0000-4000-8000-00000000000b', 'fixture_counter.increment');

-- Calls the exposed wrapper as `authenticated` with the given JWT subject (null = no subject).
create function pg_temp.cmd(
  p_actor uuid, p_version integer, p_command text, p_request_id uuid,
  p_expected_revision bigint, p_payload jsonb
) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object('sub', p_actor, 'role', 'authenticated'))::text, true);
  set local role authenticated;
  v := api.fixture_counter_command(p_version, p_command, p_request_id, p_expected_revision, p_payload);
  reset role;
  return v;
end $$;

create temp table r (k text primary key, v jsonb);

-- Create and duplicate ------------------------------------------------------------------------
insert into r values ('create', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000001', null, '{"intent_key": "k1"}'));
select is((select v ->> 'revision' from r where k = 'create'), '1', 'create returns revision 1');
select is((select v ->> 'request_id' from r where k = 'create'),
  'c0000000-0000-4000-8000-000000000001', 'create echoes request_id');
select is((select v -> 'data' ->> 'is_synthetic' from r where k = 'create'), 'true',
  'created aggregate is labelled synthetic');

insert into r values ('create_dup', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000001', null, '{"intent_key": "k1"}'));
select is((select v from r where k = 'create_dup'), (select v from r where k = 'create'),
  'duplicate create returns the original result');
select is((select count(*)::int from app.fixture_counters where intent_key = 'k1'), 1,
  'duplicate create does not mutate twice');
select is((select count(*)::int from app.cmd_receipts
            where request_id = 'c0000000-0000-4000-8000-000000000001'), 1,
  'one receipt for the create request');

insert into r values ('create_changed', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000001', null, '{"intent_key": "k2"}'));
select is((select v ->> 'code' from r where k = 'create_changed'), 'conflict',
  'same request_id with a changed payload conflicts');
select is((select count(*)::int from app.fixture_counters where intent_key = 'k2'), 0,
  'changed-payload replay creates nothing');

insert into r values ('create_same_key', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000002', null, '{"intent_key": "k1"}'));
select is((select v ->> 'code' from r where k = 'create_same_key'), 'conflict',
  'a second create with the same intent key conflicts');

-- Increment, duplicate, stale -----------------------------------------------------------------
create temp table ids as select (v -> 'data' ->> 'id') as counter_id from r where k = 'create';

insert into r select 'inc', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000010', 1,
  jsonb_build_object('counter_id', counter_id, 'by', 5)) from ids;
select is((select v ->> 'revision' from r where k = 'inc'), '2', 'increment advances the revision');
select is((select v -> 'data' ->> 'value' from r where k = 'inc'), '5', 'increment applies the change');

insert into r select 'inc_dup', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000010', 1,
  jsonb_build_object('counter_id', counter_id, 'by', 5)) from ids;
select is((select v from r where k = 'inc_dup'), (select v from r where k = 'inc'),
  'duplicate increment replays the original result despite the newer revision');
select is((select value from app.fixture_counters where intent_key = 'k1'), 5,
  'duplicate increment does not apply twice');

insert into r select 'stale', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000011', 1,
  jsonb_build_object('counter_id', counter_id, 'by', 1)) from ids;
select is((select v ->> 'code' from r where k = 'stale'), 'conflict', 'stale revision conflicts');
select is((select v ->> 'current_revision' from r where k = 'stale'), '2',
  'stale conflict reports the readable current revision');
select is((select count(*)::int from app.cmd_receipts
            where request_id = 'c0000000-0000-4000-8000-000000000011'), 0,
  'a conflicted request stores no receipt');

-- Rolled-back failure after the receipt reservation -------------------------------------------
insert into r select 'overflow', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000012', 2,
  jsonb_build_object('counter_id', counter_id, 'by', 1000)) from ids;
select is((select v ->> 'code' from r where k = 'overflow'), 'validation_failed',
  'a write that breaks a constraint fails as validation_failed');
select is((select v ->> 'message' from r where k = 'overflow'), 'The request is not valid.',
  'the error carries only the fixed safe message');
select is(
  (select array_agg(key order by key) from r, jsonb_object_keys(v) key where k = 'overflow'),
  array['code', 'field_errors', 'message', 'request_id'],
  'error envelope holds exactly the contract keys'
);
select is((select row(value, revision)::text from app.fixture_counters where intent_key = 'k1'),
  '(5,2)', 'the failed command left value and revision unchanged');
select is((select count(*)::int from app.cmd_receipts
            where request_id = 'c0000000-0000-4000-8000-000000000012'), 0,
  'the failed command committed no receipt');

-- Scope and authority -------------------------------------------------------------------------
insert into r select 'other_scope', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000020', 2,
  jsonb_build_object('counter_id', counter_id, 'by', 1)) from ids;
insert into r values ('missing', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000021', 2,
  '{"counter_id": "d0000000-0000-4000-8000-000000000000", "by": 1}'));
select is((select v ->> 'code' from r where k = 'other_scope'), 'not_found',
  'another actor''s aggregate is not_found');
select is((select v - 'request_id' from r where k = 'other_scope'),
          (select v - 'request_id' from r where k = 'missing'),
  'out-of-scope and missing aggregates are indistinguishable');

insert into r values ('no_grant', pg_temp.cmd('c0000000-0000-4000-8000-00000000000c', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000030', null, '{"intent_key": "c1"}'));
select is((select v ->> 'code' from r where k = 'no_grant'), 'forbidden',
  'an actor without authority is forbidden');

update app.fixture_command_grants set revoked_at = now()
 where actor_id = 'a0000000-0000-4000-8000-00000000000a' and command = 'fixture_counter.increment';
insert into r select 'revoked_replay', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000010', 1,
  jsonb_build_object('counter_id', counter_id, 'by', 5)) from ids;
select is((select v ->> 'code' from r where k = 'revoked_replay'), 'forbidden',
  'after revocation a stored receipt is not replayed');
insert into r select 'revoked_new', pg_temp.cmd('a0000000-0000-4000-8000-00000000000a', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000031', 2,
  jsonb_build_object('counter_id', counter_id, 'by', 1)) from ids;
select is((select v ->> 'code' from r where k = 'revoked_new'), 'forbidden',
  'after revocation a new command is forbidden');
select is((select value from app.fixture_counters where intent_key = 'k1'), 5,
  'revoked authority changed nothing');

-- Actor and envelope validation ---------------------------------------------------------------
insert into r values ('no_actor', pg_temp.cmd(null, 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000040', null, '{"intent_key": "n1"}'));
select is((select v ->> 'code' from r where k = 'no_actor'), 'unauthenticated',
  'a session without a subject is unauthenticated');

insert into r values ('bad_version', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 2,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000041', null, '{"intent_key": "v2"}'));
select is((select v -> 'field_errors' ->> 'version' from r where k = 'bad_version'), 'unsupported',
  'an unknown envelope version is rejected');
insert into r values ('no_request_id', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.create', null, null, '{"intent_key": "x"}'));
select is((select v -> 'field_errors' ->> 'request_id' from r where k = 'no_request_id'), 'required',
  'a missing request_id is rejected');
insert into r select 'no_revision', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.increment', 'c0000000-0000-4000-8000-000000000042', null,
  jsonb_build_object('counter_id', counter_id, 'by', 1)) from ids;
select is((select v -> 'field_errors' ->> 'expected_revision' from r where k = 'no_revision'),
  'required', 'a mutation without expected_revision is rejected');
insert into r values ('bad_command', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.delete', 'c0000000-0000-4000-8000-000000000043', null, '{}'));
select is((select v -> 'field_errors' ->> 'command' from r where k = 'bad_command'), 'unsupported',
  'an unlisted command is rejected');
insert into r select 'bad_payload', pg_temp.cmd('b0000000-0000-4000-8000-00000000000b', 1,
  'fixture_counter.create', 'c0000000-0000-4000-8000-000000000044', null,
  '{"intent_key": "x", "actor_id": "a0000000-0000-4000-8000-00000000000a"}');
select is((select v ->> 'code' from r where k = 'bad_payload'), 'validation_failed',
  'payload fields outside the contract (e.g. an actor id) are rejected');

-- Direct access is denied ---------------------------------------------------------------------
set local role anon;
select throws_ok(
  $$select api.fixture_counter_command(1, 'fixture_counter.create',
      'c0000000-0000-4000-8000-000000000050', null, '{"intent_key": "anon"}')$$,
  '42501', null, 'anon cannot execute the command');
reset role;

set local role authenticated;
select throws_ok(
  $$insert into app.fixture_counters (created_by, intent_key)
      values ('b0000000-0000-4000-8000-00000000000b', 'direct')$$,
  '42501', null, 'authenticated cannot INSERT into the aggregate directly');
select throws_ok(
  $$update app.cmd_receipts set result = '{}'$$,
  '42501', null, 'authenticated cannot UPDATE receipts directly');
select throws_ok(
  $$select app.cmd_execute(1, 'fixture_counter.create', 'c0000000-0000-4000-8000-000000000051',
      null, '{"intent_key": "k"}', 'app.fixture_counter_create(uuid, bigint, jsonb)'::regprocedure, false)$$,
  '42501', null, 'authenticated cannot call the kernel with an arbitrary handler');
reset role;

select * from finish();
rollback;
