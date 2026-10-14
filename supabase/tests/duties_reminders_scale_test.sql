-- Story 4.8 review fix 1: realistic rota sizes finish well inside the API statement timeout
-- (8 s) with every reminder planned: Publish N of a quarterly two-position rota (26 slots), of a
-- year-long four-position rota (200 slots) and a bulk acceptance of 50 dates. Before the fix one
-- policy validation scanned pg_timezone_names on every call (26 slots took about 17 s).
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900660-900669).
begin;
select plan(8);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000049' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000049' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (660 + n)::text $$;
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
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$ select pg_temp.call(n, 'duties_command', p_command, p_expected, p_payload) $$;
create function pg_temp.sunday(k int) returns date language sql as $$
  select ((now() at time zone 'Africa/Lusaka')::date + 4)
         + ((7 - extract(dow from (now() at time zone 'Africa/Lusaka')::date + 4)::int) % 7) + 7 * k
$$;

-- 1 Admin; 2 leader; 3 deputy; 4-7 members.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.platform_set_environment('local', 'pgtap 4.8 scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.8 Scale ' || n, 'pgtap 4.8')
  from generate_series(1, 7) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(n)),
  jsonb_build_object('member_id', pg_temp.mid(n), 'scope_kind', k, 'scope_id', pg_temp.d()))
  from (values (2, 'department_leader'), (3, 'department_deputy')) v(n, k);
create function pg_temp.add(n int) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = pg_temp.d()),
    jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(n) from generate_series(4, 7) n;

-- A series with p_positions positions, weekly for p_weeks + 1 Sundays at p_time, every position
-- planned (one member per position, so nobody overlaps).
create function pg_temp.series(p_name text, p_weeks int, p_time text, p_positions int) returns uuid
language plpgsql as $$
declare
  r jsonb;
  v uuid;
begin
  r := pg_temp.duties(2, 'duties.create_series', null, jsonb_build_object(
         'department_id', pg_temp.d(), 'duty_name', p_name, 'every', 'week',
         'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'),
         'until_date', to_char(pg_temp.sunday(p_weeks), 'YYYY-MM-DD'),
         'start_time', p_time,
         'positions', (select jsonb_agg('P' || g) from generate_series(1, p_positions) g)));
  v := (r #>> '{data,series_id}')::uuid;
  -- Planning is the 4.3 command's work, tested elsewhere; this fixture plans in bulk.
  update app.duties_slots s set draft_member_id = pg_temp.mid(3 + s.position_no)
    from app.duties_occurrences o where o.occurrence_id = s.occurrence_id and o.series_id = v;
  return v;
end;
$$;
create function pg_temp.publish(p_series uuid) returns jsonb language sql as $$
  select pg_temp.duties(2, 'duties.publish_drafts',
    (select revision from app.duties_series where series_id = p_series),
    jsonb_build_object('series_id', p_series, 'slot_count',
      (select count(*) from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
        where o.series_id = p_series)))
$$;

create temp table small as select pg_temp.series('Quarter', 12, '18:00', 2) as id;
create temp table big as select pg_temp.series('Year', 49, '10:00', 4) as id;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table ps as select pg_temp.publish((select id from small)) as r;
create temp table t1 as select clock_timestamp() as t;
create temp table pb as select pg_temp.publish((select id from big)) as r;
create temp table t2 as select clock_timestamp() as t;
create temp table am as select pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments',
  (select jsonb_agg(jsonb_build_object('assignment_id', a.assignment_id, 'revision', a.revision))
     from app.duties_assignments a join app.duties_slots s using (slot_id)
     join app.duties_occurrences o using (occurrence_id)
    where o.series_id = (select id from big) and a.member_id = pg_temp.mid(4)))) as r;
create temp table t3 as select clock_timestamp() as t;
reset statement_timeout;

select is((select r #>> '{data,assignments}' from ps), '26', 'a quarterly two-position rota publishes 26 slots');
select is((select r #>> '{data,assignments}' from pb), '200', 'a year of a four-position rota publishes 200 slots');
select is((select r #>> '{data,count}' from am), '50', 'a member accepts 50 dates together');
select ok((select t from t1) - (select t from t0) < interval '4 seconds', '26 slots well inside the 8 s timeout');
select ok((select t from t3) - (select t from t2) < interval '4 seconds', '50 dates accepted well inside the timeout');
select is((select count(*)::int from app.notifications_jobs j
            join app.duties_assignments a on a.assignment_id = j.source_id
            join app.duties_slots s using (slot_id) join app.duties_occurrences o using (occurrence_id)
           where o.series_id in ((select id from small), (select id from big))
             and j.source_type = 'duties_coverage' and j.job_state = 'pending'), 2 * 226 - 2 * 50,
  'every unanswered assignment has its leader and deputy alert (the accepted 50 have none)');
select is((select count(*)::int from app.notifications_jobs j
            join app.duties_assignments a on a.assignment_id = j.source_id
           where a.member_id = pg_temp.mid(4) and j.job_state = 'pending' and a.response = 'accepted'
             and j.reminder_kind <> 'duty_starting'), 0,
  'the accepted dates keep only their pre-service reminders');
select ok(app.notifications_policy() ->> 'zone' = 'Africa/Lusaka'
          and current_setting('app.notifications_policy_cache', true) is not null,
  'the validated policy is remembered for the transaction');

select diag('timings (ms): publish 26 = ' || round(extract(epoch from (select t from t1) - (select t from t0)) * 1000)
            || ', publish 200 = ' || round(extract(epoch from (select t from t2) - (select t from t1)) * 1000)
            || ', accept 50 = ' || round(extract(epoch from (select t from t3) - (select t from t2)) * 1000));
select * from finish();
rollback;
