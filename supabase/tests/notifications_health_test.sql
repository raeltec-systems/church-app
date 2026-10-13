-- Content-free notification health for Admins and explicitly mapped operators (story 3.8, with
-- the review 3.8-3.10 fixes: stale from the last successful hand-off, a windowed direct-contact
-- backlog, every failed push outcome, explicit session checks and the mapping lifecycle).
-- Every account is SYNTHETIC (+44 7700 900861-900866).
begin;
select plan(31);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000380' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000380' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (860 + n)::text $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object('sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1',
    'session_id', pg_temp.s(n), 'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', now() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.read_health(n int) returns jsonb language plpgsql as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  select api.notifications_health() into result;
  reset role;
  return result;
end;
$$;
-- 'ok' when the read succeeds, otherwise the refusal's SQLSTATE (PT401 / PT403).
create function pg_temp.read_code(n int) returns text language plpgsql as $$
begin
  perform pg_temp.read_health(n);
  return 'ok';
exception when others then
  reset role;
  return sqlstate;
end;
$$;
create function pg_temp.op_map() returns text language sql as
$$ select auth_user_id::text from app.ops_operators where operator = 'israel' $$;
create temp table health_fixture (k text primary key, job_id uuid);

-- 1 Admin, 2 mapped operator (no member link), 3 member, 4 soft-deleted later, 5 banned.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now()
  from generate_series(1, 5) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 5) n;
select app.platform_set_environment('local', 'pgtap notifications health');
select app.identity_seed_synthetic_link(pg_temp.u(1), 'SYNTHETIC Health Admin', 'health test');
select app.identity_seed_synthetic_link(pg_temp.u(3), 'SYNTHETIC Health Member', 'health test');
select app.identity_bootstrap_admin((select member_id from app.identity_account_links where auth_user_id = pg_temp.u(1)), 'israel');
update app.ops_operators set auth_user_id = pg_temp.u(2) where operator = 'israel';

-- Three due SYNTHETIC reminders: one failed inbox attempt; direct-contact needs unrouted now,
-- unrouted 25 hours ago and routed now; push attempts of every outcome; device tokens.
do $$
declare
  v_response jsonb;
  v_job uuid;
  v_key text;
  v_due text := app.cmd_utc(now() - interval '10 minutes');
  v_member uuid := (select member_id from app.identity_account_links where auth_user_id = pg_temp.u(3));
begin
  foreach v_key in array array['unrouted_now', 'unrouted_old', 'routed_now'] loop
    perform set_config('request.jwt.claims', pg_temp.c(1)::text, true);
    set local role authenticated;
    select api.fixture_reminder_command(jsonb_build_object(
      'version', 1, 'command', 'fixture.reminder_create', 'request_id', gen_random_uuid(),
      'expected_revision', null,
      'payload', jsonb_build_object('due_at', v_due))) into v_response;
    reset role;
    select j.job_id into v_job from app.notifications_jobs j
     where j.source_id = (v_response -> 'data' ->> 'source_id')::uuid;
    insert into health_fixture values (v_key, v_job);
    insert into app.notifications_direct_contact_needs
      (job_id, source_type, source_id, source_revision, recipient_member_id, reminder_kind,
       due_at, route_state, routed_at, routed_by_principal)
    select j.job_id, j.source_type, j.source_id, j.source_revision, j.recipient_member_id,
           j.reminder_kind, j.scheduled_at,
           case when v_key = 'routed_now' then 'routed' else 'unrouted' end,
           case when v_key = 'unrouted_old' then now() - interval '25 hours' else now() end,
           gen_random_uuid()
      from app.notifications_jobs j where j.job_id = v_job;
  end loop;
  select job_id into v_job from health_fixture where k = 'unrouted_now';
  insert into app.notifications_attempts (job_id, principal_id, request_id, outcome)
    values (v_job, gen_random_uuid(), gen_random_uuid(), 'failed');
  insert into app.notifications_attempts (job_id, channel, push_job_id, principal_id, request_id, outcome, attempted_at)
  select v_job, 'push', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), o.outcome, o.at
    from (values ('transient', now()), ('rejected', now()), ('failed', now()), ('lapsed', now()),
                 ('exhausted', now()), ('accepted', now()), ('token_invalid', now()),
                 ('transient', now() - interval '25 hours')) o(outcome, at);
  insert into app.notifications_device_tokens (account_id, member_id, platform, token, retired_at, retire_reason)
  values (pg_temp.u(3), v_member, 'android', 'fcm-' || repeat('h', 40) || ':APA91b', now(), 'provider_invalid'),
         (pg_temp.u(3), v_member, 'android', 'fcm-' || repeat('i', 40) || ':APA91b', now() - interval '2 days', 'signed_out'),
         (pg_temp.u(3), v_member, 'android', 'fcm-' || repeat('j', 40) || ':APA91b', null, null);
end;
$$;

-- Scheduler: a successful hand-off six minutes ago, then fresh ticks that handed nothing off.
select app.notifications_scheduler_note('sent');
update app.notifications_scheduler_state set last_success_at = now() - interval '6 minutes' where singleton;
select app.notifications_scheduler_note('gate_closed');
select app.notifications_scheduler_note('not_configured');

-- Privileges --------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'api.notifications_health()', 'EXECUTE'),
  'authenticated may call the server-checked health endpoint');
select ok(not has_function_privilege('authenticated', 'app.notifications_health()', 'EXECUTE'),
  'the internal health function is not directly executable by clients');
select ok(not has_function_privilege('authenticated', 'app.notifications_scheduler_status()', 'EXECUTE'),
  'the health mapping grants no access to operator procedures');
select ok(not has_function_privilege('authenticated', 'app.ops_operators_clear_auth_mapping()', 'EXECUTE'),
  'the mapping-cleanup trigger function is not client-executable');
select hasnt_fk('app', 'ops_operators', 'the operator mapping has no foreign key into auth (restorable app backups)');

-- Access ------------------------------------------------------------------------------------------
select is(pg_temp.read_health(1) -> 'jobs' ->> 'due_pending', '3', 'live Admin sees the synthetic due jobs');
select is(pg_temp.read_code(2), 'ok', 'the mapped operator (no member link) may read');
select is(pg_temp.read_code(3), 'PT403', 'another signed-in user is refused by the server');
select ok(pg_temp.read_health(2)::text !~ '(SYNTHETIC|APA91|fcm-|source_id|recipient_member_id|worker_url)',
  'health response contains no private or worker configuration fields');

-- Jobs and scheduler ------------------------------------------------------------------------------
select is((pg_temp.read_health(2) -> 'jobs' ->> 'failed_attempts_24h'), '1', 'failed inbox attempt is counted');
select ok(pg_temp.read_health(2) -> 'jobs' ->> 'oldest_due_at' is not null,
  'oldest due timestamp is present for delayed synthetic work');
select is((pg_temp.read_health(2) -> 'scheduler' ->> 'stale'), 'true',
  'fresh not_configured/gate_closed ticks without a successful hand-off in five minutes are stale');
select is((pg_temp.read_health(2) -> 'scheduler' ->> 'last_tick_outcome'), 'not_configured',
  'the latest tick outcome is reported');
select ok(pg_temp.read_health(2) -> 'scheduler' ->> 'last_success_at' is not null,
  'last successful scheduler handoff remains recorded after later ticks');
select app.notifications_scheduler_note('sent');
select is((pg_temp.read_health(2) -> 'scheduler' ->> 'stale'), 'false', 'a fresh successful hand-off is not stale');

-- Direct contact, push and tokens -----------------------------------------------------------------
select is(pg_temp.read_health(2) -> 'direct_contact',
  jsonb_build_object('backlog', 1, 'oldest_due_at', pg_temp.read_health(2) -> 'direct_contact' -> 'oldest_due_at',
                     'routed_24h', 1, 'total_unrouted', 2, 'total', 3),
  'direct-contact backlog is unrouted needs of the last 24 hours; cumulative totals are separate');
select ok(pg_temp.read_health(2) -> 'direct_contact' ->> 'oldest_due_at' is not null,
  'the backlog reports its oldest due time');
select is(pg_temp.read_health(2) -> 'push' ->> 'failed_attempts_24h', '5',
  'push failures count transient, rejected, failed, lapsed and exhausted within 24 hours');
select is(pg_temp.read_health(2) -> 'push' ->> 'outbound_open', 'false', 'the closed outbound gate is reported');
select is(pg_temp.read_health(2) -> 'push' ->> 'enabled', 'false', 'push sending is reported off');
select is((pg_temp.read_health(2) -> 'tokens') - 'last_retired_at', '{"retired": 2, "retired_24h": 1}'::jsonb,
  'retired device tokens are counted in total and within 24 hours');
select ok(pg_temp.read_health(2) -> 'tokens' ->> 'last_retired_at' is not null, 'the latest token retirement time is reported');

-- Mapping lifecycle -------------------------------------------------------------------------------
update app.ops_operators set active = false where operator = 'israel';
select is(pg_temp.read_code(2), 'PT403', 'a deactivated operator mapping grants nothing');
update app.ops_operators set active = true, auth_user_id = null where operator = 'israel';
select is(pg_temp.read_code(2), 'PT403', 'a cleared mapping grants nothing');
update app.ops_operators set auth_user_id = pg_temp.u(5) where operator = 'israel';
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(5);
select is(pg_temp.read_code(5), 'PT401', 'a mapping to a banned Auth user is refused as an untrusted session');
update app.ops_operators set auth_user_id = pg_temp.u(2) where operator = 'israel';
delete from auth.mfa_amr_claims where session_id = pg_temp.s(2);
select is(pg_temp.read_code(2), 'PT401',
  'the mapped-operator path refuses an untrusted session explicitly (PT401, not a grant check side effect)');
select is(pg_temp.op_map(), pg_temp.u(2)::text, 'operator Auth mapping is nullable and explicitly owner-set');
delete from auth.users where id = pg_temp.u(2);
select is(pg_temp.op_map(), null, 'deleting the mapped Auth user clears the mapping');
update app.ops_operators set auth_user_id = pg_temp.u(4) where operator = 'israel';
update auth.users set deleted_at = now() where id = pg_temp.u(4);
select is(pg_temp.op_map(), null, 'soft-deleting the mapped Auth user clears the mapping');
update app.ops_operators set auth_user_id = gen_random_uuid() where operator = 'israel';
select is(pg_temp.read_code(4), 'PT401', 'a soft-deleted Auth user cannot read health');
select is(pg_temp.read_code(1), 'ok', 'the Admin path is unaffected by the operator mapping');

select * from finish();
rollback;
