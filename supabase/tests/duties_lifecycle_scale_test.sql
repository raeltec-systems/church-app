-- Story 4.12 scale: the lifecycle hooks stay well inside the 8-second statement timeout for a
-- member with many future duties and open follow-up tasks. S serves 150 future duties (a weekly
-- rota for nearly three years: 120 in department D, 30 in E), deputises D, owns 100 open tasks and
-- supervises 30 more. A login hold (150 Needs contact entries), the removal from E (30 vacancies,
-- notices and leader alerts) and the church deactivation (120 vacancies, 100 handed-over tasks, 30
-- supervision moves, the handover hooks, the revoked scope) are each timed through the API under
-- statement_timeout = '8s'. The cost is linear: about 9 ms per ended duty and 12 ms per handed-over
-- task (its reminders are planned again for the new owner and supervisor).
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900480-900489). Duty times
-- are fixed church-time (Africa/Lusaka) clock times on whole days.
begin;
select plan(16);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000004121' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000004121' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1', 'session_id', pg_temp.s(n),
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.ms(a timestamptz, b timestamptz) returns numeric language sql as
$$ select round(extract(epoch from b - a) * 1000) $$;

-- Accounts: 1 Admin; 2 leader L of D and E; 3 member S (deputy of D); 4 member X.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '447700900' || (479 + n)::text, now()
  from generate_series(1, 4) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 4) n;
select app.platform_set_environment('local', 'pgtap 4.12 scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.12 Scale ' || n, 'pgtap 4.12')
  from generate_series(1, 4) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
create function pg_temp.dep(p_name text) returns uuid language sql as $$
  select (pg_temp.call(1, 'duties_command', 'duties.create_department', null, jsonb_build_object('name', p_name))
          #>> '{data,department_id}')::uuid
$$;
create temp table deps as select pg_temp.dep('SYNTHETIC 4.12 Scale D') as d, pg_temp.dep('SYNTHETIC 4.12 Scale E') as e;
create function pg_temp.d() returns uuid language sql as $$ select d from deps $$;
create function pg_temp.e() returns uuid language sql as $$ select e from deps $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
    (select revision from app.identity_grant_sets where member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'duties_command', 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(2, 'department_leader', pg_temp.e());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.add(n, pg_temp.d()) from unnest(array[3, 4]) n;
select pg_temp.add(3, pg_temp.e());

-- 150 published duties for S, each on its own church day at 10:00 (days 2-151).
create temp table pubs as
  select k, pg_temp.call(2, 'duties_command', 'duties.publish_duty', null, jsonb_build_object(
           'department_id', case when k <= 120 then pg_temp.d() else pg_temp.e() end,
           'member_id', pg_temp.mid(3), 'duty_name', 'SYNTHETIC scale duty ' || k,
           'starts_at', app.cmd_utc(pg_temp.at(k + 1)))) as r
    from generate_series(1, 150) k;
select is((select count(*)::int from pubs where r ->> 'code' is null), 150, 'setup: 150 duties published for S');
-- 100 open tasks owned by S (supervised by L) and 30 owned by X supervised by S.
create temp table tasks as
  select k, pg_temp.call(2, 'followups_command', 'followups.create_task', null, jsonb_build_object(
           'source_type', 'fixture_followup', 'source_id', gen_random_uuid(), 'source_revision', 1,
           'purpose', 'synthetic_check_in',
           'owner_member_id', case when k <= 100 then pg_temp.mid(3) else pg_temp.mid(4) end,
           'supervisor_member_id', case when k <= 100 then pg_temp.mid(2) else pg_temp.mid(3) end,
           'scope_kind', 'department_leader', 'scope_id', pg_temp.d(),
           'next_action', 'SYNTHETIC: scale check-in', 'due_at', app.cmd_utc(pg_temp.at(3)))) as r
    from generate_series(1, 130) k;
select is((select count(*)::int from tasks where r ->> 'code' is null), 130, 'setup: 130 open tasks');
analyze app.duties_occurrences, app.duties_slots, app.duties_assignments, app.followups_tasks,
  app.notifications_jobs, app.notifications_schedules, app.duties_contact_needs;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table hold as select pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(3),
  jsonb_build_object('member_id', pg_temp.mid(3), 'reason_code', 'login_disabled')) as r;
create temp table t1 as select clock_timestamp() as t;
create temp table rem as select pg_temp.call(1, 'duties_command', 'duties.remove_member',
  (select revision from app.duties_departments where department_id = pg_temp.e()),
  jsonb_build_object('department_id', pg_temp.e(), 'member_id', pg_temp.mid(3))) as r;
create temp table t2 as select clock_timestamp() as t;
create temp table deact as select pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership',
  pg_temp.mrev(3), jsonb_build_object('member_id', pg_temp.mid(3), 'reason_code', 'moved_away')) as r;
create temp table t3 as select clock_timestamp() as t;
reset statement_timeout;

select is((select r ->> 'code' from hold), null, 'the login hold succeeds');
select is((select count(*)::int from app.duties_contact_needs where reminder_kind = 'access_hold'), 150,
  'every one of the 150 duties is on Needs contact');
select is((select (r #>> '{data,vacated}') from rem), '30', 'the removal from E ends its 30 duties');
select is((select r ->> 'code' from deact), null, 'the deactivation succeeds');
select is((select count(*)::int from app.duties_assignments where member_id = pg_temp.mid(3)
              and assignment_state = 'current'), 0, 'every future duty of S has ended');
select is((select count(*)::int from app.notifications_jobs where reminder_kind = 'duty_vacated'
              and job_state = 'pending'), 2, 'one leaders'' notice per department and change (not one per position)');
select is((select count(*)::int from app.followups_tasks where owner_member_id = pg_temp.mid(3)
              and task_state in ('open', 'in_progress', 'waiting')), 0, 'S owns no open task any more');
select is((select count(*)::int from app.followups_tasks where supervisor_member_id = pg_temp.mid(3)
              and task_state in ('open', 'in_progress', 'waiting')), 0, 'and supervises none');
select is((select count(*)::int from app.identity_handover_obligations
            where member_id = pg_temp.mid(3) and obligation_state = 'pending'), 0,
  'the 100 task handovers Identity recorded are resolved');
select ok(pg_temp.ms((select t from t0), (select t from t1)) < 2000, 'the hold is well inside the timeout');
select ok(pg_temp.ms((select t from t1), (select t from t2)) < 2000, 'the removal is well inside the timeout');
select ok(pg_temp.ms((select t from t2), (select t from t3)) < 6000, 'the deactivation (120 duties, 130 tasks) stays inside the timeout with room to spare');
select ok((select count(*) from app.notifications_jobs j where j.recipient_member_id = pg_temp.mid(3)
              and j.job_state = 'pending' and j.source_type in ('duties_assignment', 'duties_coverage')
              and j.reminder_kind <> 'duty_released') = 0,
  'none of S''s Duties reminders is left pending (only the removal''s released notices)');
select ok((select count(*) from app.notifications_schedules s where s.recipient_member_id = pg_temp.mid(3)
              and s.schedule_state = 'active') = 0, 'and no schedule of S stays active');
select diag('timings (ms): hold 150 = ' || pg_temp.ms((select t from t0), (select t from t1))
            || ', removal 30 = ' || pg_temp.ms((select t from t1), (select t from t2))
            || ', deactivation 120 duties + 130 tasks = ' || pg_temp.ms((select t from t2), (select t from t3)));

select * from finish();
rollback;
