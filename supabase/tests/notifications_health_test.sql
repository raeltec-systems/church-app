-- Content-free notification health for Admins and explicitly mapped operators.
begin;
select plan(12);

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
create function pg_temp.read_health_denied(n int) returns boolean language plpgsql as $$
begin
  perform pg_temp.read_health(n);
  return false;
exception when sqlstate 'PT403' then
  reset role;
  return true;
end;
$$;
create temp table health_fixture (job_id uuid);


insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;
select app.platform_set_environment('local', 'pgtap notifications health');
select app.identity_seed_synthetic_link(pg_temp.u(1), 'SYNTHETIC Health Admin', 'health test');
select app.identity_seed_synthetic_link(pg_temp.u(3), 'SYNTHETIC Health Member', 'health test');
select app.identity_bootstrap_admin((select member_id from app.identity_account_links where auth_user_id = pg_temp.u(1)), 'israel');
update app.ops_operators set auth_user_id = pg_temp.u(2) where operator = 'israel';
select app.notifications_scheduler_note('sent');
select app.notifications_scheduler_note('gate_closed');
update app.notifications_scheduler_state
   set last_tick_at = now() - interval '6 minutes', last_tick_outcome = 'gate_closed'
 where singleton;

do $$
declare
  v_response jsonb;
  v_source uuid;
  v_job uuid;
  v_due text;
begin
  v_due := app.cmd_utc(now() - interval '10 minutes');
  perform set_config('request.jwt.claims', pg_temp.c(1)::text, true);
  set local role authenticated;
  select api.fixture_reminder_command(jsonb_build_object(
    'version', 1, 'command', 'fixture.reminder_create', 'request_id', gen_random_uuid(),
    'expected_revision', null,
    'payload', jsonb_build_object('due_at', v_due))) into v_response;
  reset role;
  v_source := (v_response -> 'data' ->> 'source_id')::uuid;
  select j.job_id into v_job from app.notifications_jobs j where j.source_id = v_source;
  insert into health_fixture values (v_job);
  insert into app.notifications_attempts (job_id, principal_id, request_id, outcome)
    values (v_job, gen_random_uuid(), gen_random_uuid(), 'failed');
  insert into app.notifications_direct_contact_needs
    (job_id, source_type, source_id, source_revision, recipient_member_id, reminder_kind,
     due_at, route_state, routed_by_principal)
  select j.job_id, j.source_type, j.source_id, j.source_revision, j.recipient_member_id,
         j.reminder_kind, j.scheduled_at, 'routed', gen_random_uuid()
    from app.notifications_jobs j where j.job_id = v_job;
end;
$$;

select ok(has_function_privilege('authenticated', 'api.notifications_health()', 'EXECUTE'),
  'authenticated may call the server-checked health endpoint');
select ok(not has_function_privilege('authenticated', 'app.notifications_health()', 'EXECUTE'),
  'the internal health function is not directly executable by clients');
select is(pg_temp.read_health(1) -> 'jobs' ->> 'due_pending', '1', 'live Admin sees a synthetic due job');
select is(pg_temp.read_health(2) -> 'direct_contact' ->> 'backlog', '1', 'mapped operator sees the contact backlog count');
select ok(pg_temp.read_health_denied(3), 'other signed-in user is refused by the server');
select ok(pg_temp.read_health(2)::text !~ '(SYNTHETIC|APA91|fcm-|source_id|recipient_member_id|worker_url)',
  'health response contains no private or worker configuration fields');
select ok(not has_function_privilege('authenticated', 'app.notifications_scheduler_status()', 'EXECUTE'),
  'the health mapping grants no access to operator procedures');
select is((pg_temp.read_health(2) -> 'jobs' ->> 'failed_attempts_24h'), '1', 'failed attempt is included in the health aggregate');
select ok(pg_temp.read_health(2) -> 'jobs' ->> 'oldest_due_at' is not null,
  'oldest due timestamp is present for delayed synthetic work');
select is((pg_temp.read_health(2) -> 'scheduler' ->> 'stale'), 'true', 'missing scheduler activity is stale');
select ok(pg_temp.read_health(2) -> 'scheduler' ->> 'last_success_at' is not null,
  'last successful scheduler handoff remains recorded after a later failed tick');
select is((select auth_user_id from app.ops_operators where operator = 'israel')::text,
  pg_temp.u(2)::text, 'operator Auth mapping is nullable and explicitly owner-set');

select * from finish();
rollback;
