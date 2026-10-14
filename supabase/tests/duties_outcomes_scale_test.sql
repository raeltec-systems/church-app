-- Story 4.10: the outcomes read and the member history stay well inside the API statement timeout
-- (8 s) at realistic scale: a member with fifteen years of weekly duties (780 positions, each with
-- an outcome, a tenth of them corrected, and same-person material revisions), read by the member
-- and by their leader, page after page; and a leader's view of a large department (300 members,
-- 40 two-position duties a day) over the default fortnight and the longest window (31 days, about
-- 2,500 positions, more than the 1,000 listed). The fixture rows are inserted directly (the
-- commands are tested in duties_outcomes_test.sql). Every account, phone and name is SYNTHETIC
-- (fictional range +44 7700 900130-900139). Duty times are whole church days at fixed clock times.
begin;
select plan(12);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000411' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000411' || lpad(n::text, 2, '0'))::uuid $$;
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
-- Church midnight p_days church days from today (Africa/Lusaka).
create function pg_temp.day(p_days int) returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days)::timestamp) at time zone 'Africa/Lusaka' $$;

-- 1 Admin; 2 leader L of the department; 3 member M (fifteen years of duties).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '44770090013' || n::text, now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;
select app.platform_set_environment('local', 'pgtap 4.10 scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.10 Scale ' || n, 'pgtap 4.10')
  from generate_series(1, 3) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

-- 300 accountless members.
create temp table people as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               select 'SYNTHETIC 4.10 Scale person ' || g, 'approved', true from generate_series(1, 300) g
               returning member_id)
  select row_number() over (order by member_id) as k, member_id from ins;
create temp table dept as
  with ins as (insert into app.duties_departments (name, is_synthetic, created_by_member, created_by_account)
               values ('SYNTHETIC 4.10 Scale department', true, pg_temp.mid(1), pg_temp.u(1))
               returning department_id)
  select department_id from ins;
create function pg_temp.d() returns uuid language sql as $$ select department_id from dept $$;
insert into app.duties_department_members (department_id, member_id, added_by_member, added_by_account)
select pg_temp.d(), p.member_id, pg_temp.mid(1), pg_temp.u(1) from people p
union all select pg_temp.d(), pg_temp.mid(3), pg_temp.mid(1), pg_temp.u(1);
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_member, granted_by_account)
values (pg_temp.mid(2), 'department_leader', pg_temp.d(), pg_temp.mid(1), pg_temp.u(1));

-- M: 780 weekly duties over fifteen years (07:00 church time), and 4 upcoming ones.
create temp table mocc as
  with ins as (
    insert into app.duties_occurrences (department_id, duty_name, starts_at, location, occurrence_state,
                                        published_at, created_by_member, created_by_account)
    select pg_temp.d(), 'M duty ' || g, pg_temp.day(-7 * g) + interval '7 hours', 'SYNTHETIC hall', 'published',
           pg_temp.day(-7 * g - 14), pg_temp.mid(2), pg_temp.u(2)
      from generate_series(-4, 780) g where g <> 0
    returning occurrence_id)
  select * from ins;
-- The large department: 40 two-position duties a day over the last 31 church days (08:00-20:00).
create temp table bocc as
  with ins as (
    insert into app.duties_occurrences (department_id, duty_name, starts_at, location, occurrence_state,
                                        published_at, created_by_member, created_by_account)
    select pg_temp.d(), 'Rota duty ' || dd || '-' || g,
           pg_temp.day(-dd) + interval '8 hours' + g * interval '18 minutes', 'SYNTHETIC hall', 'published',
           pg_temp.day(-dd - 14), pg_temp.mid(2), pg_temp.u(2)
      from generate_series(1, 31) dd cross join generate_series(1, 40) g
    returning occurrence_id)
  select * from ins;
insert into app.duties_slots (occurrence_id, position_no, position_name)
select occurrence_id, 1, 'Position 1' from mocc
union all
select o.occurrence_id, k, 'Position ' || k from bocc o cross join generate_series(1, 2) k;
-- M's assignments: accepted; every 20th was first asked at another time (a superseded revision of
-- the same person, so one history row per position).
insert into app.duties_assignments (slot_id, member_id, response, response_deadline, responded_at,
                                    responded_by_member, responded_by_account, response_provenance,
                                    assigned_by_member, assigned_by_account, assignment_state, ended_at,
                                    end_reason)
select s.slot_id, pg_temp.mid(3), 'accepted', o.starts_at - interval '2 days', o.starts_at - interval '3 days',
       pg_temp.mid(3), pg_temp.u(3), 'member', pg_temp.mid(2), pg_temp.u(2), 'superseded',
       o.starts_at - interval '3 days', 'revised'
  from mocc x join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join app.duties_slots s on s.occurrence_id = o.occurrence_id
 where right(o.duty_name, 1) = '0' and right(o.duty_name, 2) in ('20', '40', '60', '80', '00');
insert into app.duties_assignments (slot_id, member_id, response, response_deadline, responded_at,
                                    responded_by_member, responded_by_account, response_provenance,
                                    assigned_by_member, assigned_by_account, supersedes_assignment_id)
select s.slot_id, pg_temp.mid(3), 'accepted', o.starts_at - interval '1 day', o.starts_at - interval '2 days',
       pg_temp.mid(3), pg_temp.u(3), 'member', pg_temp.mid(2), pg_temp.u(2),
       (select a.assignment_id from app.duties_assignments a where a.slot_id = s.slot_id)
  from mocc x join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join app.duties_slots s on s.occurrence_id = o.occurrence_id;
-- The department's positions: nine of ten assigned to people in turn, most accepted.
insert into app.duties_assignments (slot_id, member_id, response, response_deadline, responded_at,
                                    responded_by_member, responded_by_account, response_provenance,
                                    assigned_by_member, assigned_by_account)
select x.slot_id, p.member_id,
       case when x.rn % 7 = 0 then 'declined' when x.rn % 11 = 0 then 'pending' else 'accepted' end,
       o.starts_at - interval '1 day',
       case when x.rn % 11 <> 0 or x.rn % 7 = 0 then o.starts_at - interval '2 days' end,
       case when x.rn % 11 <> 0 or x.rn % 7 = 0 then p.member_id end,
       case when x.rn % 11 <> 0 or x.rn % 7 = 0 then pg_temp.u(2) end,
       case when x.rn % 11 <> 0 or x.rn % 7 = 0 then 'member' end,
       pg_temp.mid(2), pg_temp.u(2)
  from (select s.slot_id, s.occurrence_id, row_number() over (order by s.occurrence_id, s.position_no) as rn
          from app.duties_slots s join bocc b on b.occurrence_id = s.occurrence_id) x
  join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join people p on p.k = 1 + x.rn % 300
 where x.rn % 10 <> 0;
-- Outcomes: every past current assignment but one in eight, with a note; a tenth corrected.
insert into app.duties_outcomes (assignment_id, revision, outcome, note, recorded_by_member, recorded_by_account)
select a.assignment_id, 1,
       case when a.response = 'accepted' and row_number() over (order by a.assignment_id) % 9 = 0 then 'no_show'
            when row_number() over (order by a.assignment_id) % 5 = 0 then 'excused' else 'completed' end,
       'SYNTHETIC scale note', pg_temp.mid(2), pg_temp.u(2)
  from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
  join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
 where o.department_id = pg_temp.d() and a.assignment_state = 'current' and o.starts_at < now()
   and right(a.assignment_id::text, 1) <> '0' and right(a.assignment_id::text, 1) <> '8';
insert into app.duties_outcomes (assignment_id, revision, outcome, note, supersedes_outcome_id, correction_reason,
                                 recorded_by_member, recorded_by_account)
select x.assignment_id, 2, 'excused', 'SYNTHETIC scale corrected', x.outcome_id, 'SYNTHETIC scale reason',
       pg_temp.mid(2), pg_temp.u(2)
  from app.duties_outcomes x where right(x.assignment_id::text, 1) = 'a' and x.outcome <> 'excused';
analyze app.duties_occurrences, app.duties_slots, app.duties_assignments, app.duties_outcomes,
  app.duties_department_members;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table hs as select pg_temp.readj(3, 'select api.duties_member_history()') as j;
create temp table t1 as select clock_timestamp() as t;
create temp table hl as select pg_temp.readj(2, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(3))) as j;
create temp table t2 as select clock_timestamp() as t;
create temp table hp as select pg_temp.readj(3, format(
  'select api.duties_member_history(before_at => %L::timestamptz, before_id => %L::uuid)',
  pg_temp.day(-7 * 700), gen_random_uuid())) as j;
create temp table t3 as select clock_timestamp() as t;
create temp table od as select pg_temp.readj(2, 'select api.duties_outcomes()') as j;
create temp table t4 as select clock_timestamp() as t;
create temp table om as select pg_temp.readj(2, format('select api.duties_outcomes(from_date => %L::date)',
  (now() at time zone 'Africa/Lusaka')::date - 30)) as j;
create temp table t5 as select clock_timestamp() as t;
reset statement_timeout;

select is((select jsonb_array_length(j -> 'entries') from hs), 100, 'M''s history pages 100 rows');
select is((select (j ->> 'has_more')::boolean from hs), true, 'and says there is more');
select is((select (j #>> '{summary,held}')::int from hs), 52, 'the summary covers one year of weekly duties');
select is((select j ->> 'upcoming' from hs), '4', 'and the upcoming ones');
select is((select count(*)::int from hs, jsonb_array_elements(j -> 'entries') e where e ->> 'state' = 'reassigned'), 0,
  'same-person revisions are one row each (no reassigned row)');
select is((select jsonb_array_length(j -> 'entries') from hp), 80, 'the last page after fifteen years');
select ok((select (j #>> '{departments,0,counts,positions}')::int > 1000 and (j ->> 'truncated')::boolean
                  and (select jsonb_array_length(j #> '{departments,0,positions}')) = 1000 from od),
  'the leader''s fortnight is over 1000 positions: 1000 listed, truncated said');
select is((select (j #>> '{departments,0,counts,positions}')::int from om), 30 * 80 + 4,
  'the 31-day window (today and the 30 days before) counts every position (the department''s and M''s)');
select ok((select t from t1) - (select t from t0) < interval '3 seconds', 'M''s own history is well inside the 8 s timeout');
select ok((select t from t2) - (select t from t1) < interval '3 seconds', 'the leader''s view of M''s history too');
select ok((select t from t3) - (select t from t2) < interval '3 seconds', 'a late page too');
select ok((select t from t5) - (select t from t3) < interval '6 seconds', 'the leader''s fortnight and month too');

select diag('timings (ms): history self = ' || round(extract(epoch from (select t from t1) - (select t from t0)) * 1000)
            || ', history by leader = ' || round(extract(epoch from (select t from t2) - (select t from t1)) * 1000)
            || ', late page = ' || round(extract(epoch from (select t from t3) - (select t from t2)) * 1000)
            || ', outcomes fortnight = ' || round(extract(epoch from (select t from t4) - (select t from t3)) * 1000)
            || ', outcomes 31 days = ' || round(extract(epoch from (select t from t5) - (select t from t4)) * 1000));

select * from finish();
rollback;
