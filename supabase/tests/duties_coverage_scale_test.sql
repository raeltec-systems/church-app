-- Story 4.9: the coverage queue stays well inside the API statement timeout (8 s) at realistic
-- scale: a leader's board with 250 positions in the week (every state, cases and attempts, Needs
-- contact) and Pastor's church-wide gap view over 40 departments (about 2,500 positions, more than
-- the 1,000 listed), with the overlap counts and contact routes computed once per read (no per-row
-- expensive calls). The fixture rows are inserted directly (the commands are tested in
-- duties_coverage_test.sql). Every account, phone and name is SYNTHETIC (fictional range
-- +44 7700 900780-900789).
begin;
select plan(9);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000051' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000051' || lpad(n::text, 2, '0'))::uuid $$;
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

-- 1 Admin; 2 leader L of department 0; 3 Pastor.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '44770090078' || n::text, now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;
select app.platform_set_environment('local', 'pgtap 4.9 scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.9 Scale ' || n, 'pgtap 4.9')
  from generate_series(1, 3) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(3), 'pastor', 'israel');

-- 60 accountless members, each with a SYNTHETIC household contact route.
create temp table people as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               select 'SYNTHETIC 4.9 Scale person ' || g, 'approved', true from generate_series(1, 60) g
               returning member_id)
  select row_number() over (order by member_id) as k, member_id from ins;
insert into app.identity_contact_routes (member_id, value, belongs_to, holder_label, is_synthetic,
                                         created_by_member, created_by_account)
select p.member_id, '+447700900789', 'household', 'SYNTHETIC household', true, pg_temp.mid(1), pg_temp.u(1)
  from people p;

-- 40 departments, every person a member of each.
create temp table depts as
  with ins as (insert into app.duties_departments (name, is_synthetic, created_by_member, created_by_account)
               select 'SYNTHETIC 4.9 Scale department ' || lpad(g::text, 2, '0'), true, pg_temp.mid(1), pg_temp.u(1)
                 from generate_series(0, 39) g returning department_id, name)
  select (right(name, 2))::int as k, department_id from ins;
insert into app.duties_department_members (department_id, member_id, added_by_member, added_by_account)
select d.department_id, p.member_id, pg_temp.mid(1), pg_temp.u(1) from depts d cross join people p;
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_member, granted_by_account)
select pg_temp.mid(2), 'department_leader', d.department_id, pg_temp.mid(1), pg_temp.u(1) from depts d where d.k = 0;

-- Department 0: 125 two-position duties over the next six days (250 positions); every other
-- department: 30 two-position duties (60 positions). One hour each, spread through the week.
create temp table occs as
  with ins as (
    insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, location,
                                        created_by_member, created_by_account)
    select d.department_id, 'Duty ' || g, date_trunc('hour', now()) + interval '3 hours' + g * interval '67 minutes',
           date_trunc('hour', now()) + interval '4 hours' + g * interval '67 minutes', 'SYNTHETIC hall',
           pg_temp.mid(2), pg_temp.u(2)
      from depts d cross join lateral generate_series(1, case when d.k = 0 then 125 else 30 end) g
    returning occurrence_id, department_id)
  select * from ins;
insert into app.duties_slots (occurrence_id, position_no, position_name)
select o.occurrence_id, k, 'Position ' || k from occs o cross join generate_series(1, 2) k;
-- Nine of ten positions assigned (to people in turn), with every answer and deadline state.
insert into app.duties_assignments (slot_id, member_id, response, response_deadline, responded_at,
                                    responded_by_member, responded_by_account, response_provenance,
                                    assigned_by_member, assigned_by_account)
select x.slot_id, p.member_id,
       case x.rn % 3 when 0 then 'accepted' when 1 then 'pending' else 'declined' end,
       case when x.rn % 4 = 0 then now() - interval '1 hour' else o.starts_at - interval '1 hour' end,
       case when x.rn % 3 <> 1 then now() end,
       case when x.rn % 3 <> 1 then p.member_id end,
       case when x.rn % 3 <> 1 then pg_temp.u(2) end,
       case when x.rn % 3 <> 1 then 'member' end,
       pg_temp.mid(2), pg_temp.u(2)
  from (select s.slot_id, s.occurrence_id, row_number() over (order by s.occurrence_id, s.position_no) as rn
          from app.duties_slots s join occs o on o.occurrence_id = s.occurrence_id) x
  join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join people p on p.k = 1 + x.rn % 60
 where x.rn % 10 <> 0;
-- Needs contact on pending answers, and an open case with two attempts on a third of them.
insert into app.duties_contact_needs (need_id, assignment_id, source_revision, reminder_kind, scheduled_at)
select gen_random_uuid(), a.assignment_id, a.revision, 'duty_assigned', now()
  from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
  join occs o on o.occurrence_id = s.occurrence_id where a.response = 'pending';
create temp table cases as
  with ins as (insert into app.duties_coverage_cases (assignment_id, department_id, opened_by_member, opened_by_account)
               select a.assignment_id, o.department_id, pg_temp.mid(2), pg_temp.u(2)
                 from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
                 join occs o on o.occurrence_id = s.occurrence_id
                where a.response <> 'accepted' and s.position_no = 1
               returning case_id, assignment_id)
  select * from ins;
insert into app.duties_contact_attempts (case_id, assignment_id, channel, outcome, note, next_follow_up_at,
                                         recorded_by_member, recorded_by_account)
select c.case_id, c.assignment_id, 'phone', o, 'SYNTHETIC practical note', now() + interval '2 hours',
       pg_temp.mid(2), pg_temp.u(2)
  from cases c cross join unnest(array['no_answer', 'left_message']) o;
analyze app.duties_occurrences, app.duties_slots, app.duties_assignments, app.duties_contact_needs,
  app.duties_coverage_cases, app.duties_contact_attempts, app.duties_department_members;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table ql as select pg_temp.readj(2, 'select api.duties_coverage()') as j;
create temp table t1 as select clock_timestamp() as t;
create temp table qp as select pg_temp.readj(3, 'select api.duties_coverage()') as j;
create temp table t2 as select clock_timestamp() as t;
create temp table qa as select pg_temp.readj(1, 'select api.duties_coverage(to_date => (now() at time zone ''Africa/Lusaka'')::date + 30)') as j;
create temp table t3 as select clock_timestamp() as t;
reset statement_timeout;

select is((select (j #>> '{departments,0,counts,required}')::int from ql), 250,
  'the leader''s week holds 250 positions');
select is((select jsonb_array_length(j #> '{departments,0,positions}') from ql), 250, 'all listed');
select ok((select (j #>> '{departments,0,counts,needs_contact}')::int > 0
                  and (j #>> '{departments,0,counts,overdue}')::int > 0
                  and (j #>> '{departments,0,counts,unfilled}')::int > 0
                  and (j #>> '{departments,0,counts,declined}')::int > 0
                  and jsonb_typeof(j #> '{departments,0,contact_routes}') = 'object'
                  and (select count(*) from jsonb_object_keys(j #> '{departments,0,contact_routes}')) > 0
             from ql), 'with every state, Needs contact and the contact routes');
select is((select jsonb_array_length(j -> 'departments') from qp), 40, 'Pastor sees all 40 departments');
select is((select sum((d #>> '{counts,required}')::int)::int from qp, jsonb_array_elements(j -> 'departments') d),
  250 + 39 * 60, 'the counts cover every position church-wide');
select ok((select (j ->> 'truncated')::boolean and (select sum(jsonb_array_length(d -> 'positions'))
                                                     from jsonb_array_elements(j -> 'departments') d) = 1000
             from qp), 'at most 1000 positions are listed (truncated is said)');
select ok((select t from t1) - (select t from t0) < interval '3 seconds', 'the leader''s read is well inside the 8 s timeout');
select ok((select t from t2) - (select t from t1) < interval '4 seconds', 'Pastor''s church-wide view is well inside it');
select ok((select t from t3) - (select t from t2) < interval '4 seconds', 'an Admin''s 31-day view too');

select diag('timings (ms): leader 250 = ' || round(extract(epoch from (select t from t1) - (select t from t0)) * 1000)
            || ', pastor 40 departments = ' || round(extract(epoch from (select t from t2) - (select t from t1)) * 1000)
            || ', admin 31 days = ' || round(extract(epoch from (select t from t3) - (select t from t2)) * 1000));

select * from finish();
rollback;
