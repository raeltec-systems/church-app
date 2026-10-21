-- Special assignments: the Pastors' read and the church-wide candidates read stay well inside the
-- API statement timeout (8 s) at more than realistic scale: 1,200 active members (more than the
-- 1,000 listed), 600 special assignments of the last 90 days and ahead (more than the 500 listed;
-- fixed times and due dates, half of the past ones with an outcome), and a department duty for
-- every member at the time a Pastor asks about (so each candidate has an overlap to show). The
-- fixture rows are inserted directly (the commands are tested in
-- duties_special_assignments_test.sql). Every account, phone and name is SYNTHETIC (fictional
-- range +1 202 555 0118-0119). Duty times are whole church days at fixed clock times.
begin;
select plan(10);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000072' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000072' || lpad(n::text, 2, '0'))::uuid $$;
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
create function pg_temp.readj(n int, p_sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute p_sql into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.lusaka(p_days int) returns date language sql as
$$ select (now() at time zone 'Africa/Lusaka')::date + p_days $$;

-- 1 Admin; 2 Pastor.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '120255501' || (17 + n)::text, now()
  from generate_series(1, 2) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 2) n;
select app.platform_set_environment('local', 'pgtap special scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Special Scale ' || n,
                                                         'pgtap special scale')
  from generate_series(1, 2) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(2), 'pastor', 'israel');

-- 1,200 accountless members.
create temp table people as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               select 'SYNTHETIC Special Scale person ' || lpad(g::text, 4, '0'), 'approved', true
                 from generate_series(1, 1200) g
               returning member_id)
  select row_number() over (order by member_id) as k, member_id from ins;

-- 600 special assignments: 400 ahead (one a day at 10:00, every other one a due date), 200 of the
-- last 90 days (accepted, every other one with an outcome).
create temp table socc as
  with ins as (
    insert into app.duties_occurrences (special, duty_name, starts_at, ends_at, due_on, occurrence_state,
                                        published_at, created_by_member, created_by_account)
    select true, 'Special ' || g,
           case when g % 2 = 0 then pg_temp.at(d, '18:00') else pg_temp.at(d, '10:00') end,
           case when g % 2 = 0 then null else pg_temp.at(d, '12:00') end,
           case when g % 2 = 0 then pg_temp.lusaka(d) end,
           'published', now() - interval '100 days', pg_temp.mid(2), pg_temp.u(2)
      from (select g, case when g <= 400 then 1 + (g - 1) / 2 else -1 - (g - 401) * 89 / 200 end as d
              from generate_series(1, 600) g) x
    returning occurrence_id, starts_at)
  select row_number() over (order by occurrence_id) as k, occurrence_id, starts_at from ins;
insert into app.duties_slots (occurrence_id, position_no) select occurrence_id, 1 from socc;
insert into app.duties_assignments (slot_id, member_id, response, response_deadline, responded_at,
                                    responded_by_member, responded_by_account, response_provenance,
                                    assigned_by_member, assigned_by_account, assigned_at)
select s.slot_id, p.member_id,
       case when o.starts_at < now() then 'accepted' else 'pending' end,
       o.starts_at - interval '2 days',
       case when o.starts_at < now() then o.starts_at - interval '3 days' end,
       case when o.starts_at < now() then p.member_id end,
       case when o.starts_at < now() then pg_temp.u(2) end,
       case when o.starts_at < now() then 'member' end,
       pg_temp.mid(2), pg_temp.u(2), now() - interval '100 days'
  from socc o
  join app.duties_slots s on s.occurrence_id = o.occurrence_id
  join people p on p.k = 1 + (o.k - 1) % 1200;
insert into app.duties_outcomes (assignment_id, revision, outcome, recorded_by_member, recorded_by_account)
select a.assignment_id, 1, 'completed', pg_temp.mid(2), pg_temp.u(2)
  from socc o join app.duties_slots s on s.occurrence_id = o.occurrence_id
  join app.duties_assignments a on a.slot_id = s.slot_id
 where o.starts_at < now() and o.k % 2 = 0;

-- A department duty for every member on church day 30, 10:00-12:00.
create temp table dept as
  with ins as (insert into app.duties_departments (name, is_synthetic, created_by_member, created_by_account)
               values ('SYNTHETIC Special Scale department', true, pg_temp.mid(1), pg_temp.u(1))
               returning department_id)
  select department_id from ins;
create temp table docc as
  with ins as (
    insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, occurrence_state,
                                        published_at, created_by_member, created_by_account)
    select (select department_id from dept), 'Door ' || p.k, pg_temp.at(30, '10:00'), pg_temp.at(30, '12:00'),
           'published', now() - interval '10 days', pg_temp.mid(1), pg_temp.u(1)
      from people p
    returning occurrence_id, duty_name)
  select * from ins;
insert into app.duties_slots (occurrence_id, position_no) select occurrence_id, 1 from docc;
insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
select s.slot_id, p.member_id, pg_temp.at(29), pg_temp.mid(1), pg_temp.u(1)
  from docc o join app.duties_slots s on s.occurrence_id = o.occurrence_id
  join people p on 'Door ' || p.k = o.duty_name;
analyze app.duties_occurrences, app.duties_slots, app.duties_assignments, app.duties_outcomes,
  app.identity_members;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table rd as select pg_temp.readj(2, 'select api.duties_special_assignments()') as j;
create temp table t1 as select clock_timestamp() as t;
create temp table cd as select pg_temp.readj(2, format('select api.duties_candidates(starts_at => %L::timestamptz, ends_at => %L::timestamptz)',
  pg_temp.at(30, '10:30'), pg_temp.at(30, '11:30'))) as j;
create temp table t2 as select clock_timestamp() as t;
reset statement_timeout;

select is((select jsonb_array_length(j -> 'assignments') from rd), 500, 'the Pastors'' read lists 500');
select is((select (j ->> 'truncated')::boolean from rd), true, 'and says there are more');
select is((select (j #>> '{assignments,0,started}')::boolean from rd), false, 'the upcoming come first');
select is((select (j #>> '{assignments,0,starts_at}')::timestamptz from rd), pg_temp.at(1, '10:00'),
  'the soonest first');
select is((select jsonb_array_length(j -> 'members') || '/' || (j ->> 'members_truncated') from rd), '1000/true',
  'the members it may be given to: 1,000 listed, truncated said');
select is((select jsonb_array_length(j -> 'candidates') from cd), 1000, 'the candidates: 1,000 members');
select is((select count(*)::int from cd, jsonb_array_elements(j -> 'candidates') x
            where exists (select 1 from jsonb_array_elements(x #> '{conflicts,items}') i
                           where i ->> 'owner_kind' = 'department' and i ->> 'visibility' = 'limited')), 999,
  'each member (the Admin has no duty) with their department duty at that time, as a busy time');
select ok((select t from t1) - (select t from t0) < interval '3 seconds',
  'the Pastors'' read is well inside the 8 s timeout');
select ok((select t from t2) - (select t from t1) < interval '5 seconds',
  'the church-wide candidates read too (1,000 members, each with an overlap)');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no module boundary violation');

select diag('timings (ms): special assignments = ' || round(extract(epoch from (select t from t1) - (select t from t0)) * 1000)
            || ', candidates 1000 = ' || round(extract(epoch from (select t from t2) - (select t from t1)) * 1000));

select * from finish();
rollback;
