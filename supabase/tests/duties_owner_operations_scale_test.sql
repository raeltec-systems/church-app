-- Story 4.11: the owner operations and reads stay well inside the API statement timeout (8 s) at
-- realistic scale: an event named by 400 department duties (flagged, listed, and the board read
-- with every review open), and a ten-position cell part given to ten members who each already hold
-- 400 upcoming duties (the overlap gate over every commitment), created, revised (a material
-- change that asks all ten again) and read, plus one member's My duties with 200 cell parts. The
-- fixture rows are inserted directly (the operations are tested in
-- duties_owner_operations_test.sql). Every account, phone and name is SYNTHETIC (fictional range
-- +44 7700 900160-900169). Duty times are whole church days at fixed clock times.
begin;
select plan(12);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-00000041b1' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-00000041b1' || lpad(n::text, 2, '0'))::uuid $$;
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
-- A server-side owner call inside session n's request.
create function pg_temp.fx(n int, p_fn text, p_input jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  execute format('select app.%I($1)', p_fn) into r using p_input;
  return r;
end;
$$;
-- A fixed church-time clock time p_days church days from today (Africa/Lusaka).
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;

-- 1 Admin; 2 leader L of the department; 3 cell leader CL; 4 member M (200 cell parts).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '44770090016' || n::text, now()
  from generate_series(1, 4) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 4) n;
select app.platform_set_environment('local', 'pgtap 4.11 scale');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.11 Scale ' || n, 'pgtap 4.11')
  from generate_series(1, 4) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

-- Ten accountless members with 400 upcoming duties each (one a day at 07:00), in the department.
create temp table people as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               select 'SYNTHETIC 4.11 Scale person ' || g, 'approved', true from generate_series(1, 10) g
               returning member_id)
  select row_number() over (order by member_id) as k, member_id from ins;
create temp table dept as
  with ins as (insert into app.duties_departments (name, is_synthetic, created_by_member, created_by_account)
               values ('SYNTHETIC 4.11 Scale department', true, pg_temp.mid(1), pg_temp.u(1))
               returning department_id)
  select department_id from ins;
create function pg_temp.d() returns uuid language sql as $$ select department_id from dept $$;
insert into app.duties_department_members (department_id, member_id, added_by_member, added_by_account)
select pg_temp.d(), p.member_id, pg_temp.mid(1), pg_temp.u(1) from people p;
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_member, granted_by_account)
values (pg_temp.mid(2), 'department_leader', pg_temp.d(), pg_temp.mid(1), pg_temp.u(1));
create temp table cc as
  with ins as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
               values ('SYNTHETIC 4.11 Scale cell', 'SYNTHETIC area', true, 'pgtap 4.11') returning cell_id)
  select cell_id from ins;
create function pg_temp.cell() returns uuid language sql as $$ select cell_id from cc $$;
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_member, granted_by_account)
values (pg_temp.mid(3), 'cell_leader', pg_temp.cell(), pg_temp.mid(1), pg_temp.u(1));
insert into app.fixture_events (title) values ('SYNTHETIC 4.11 Scale event');
create function pg_temp.ev() returns uuid language sql as $$ select event_id from app.fixture_events limit 1 $$;

create temp table socc as
  with ins as (
    insert into app.duties_occurrences (department_id, duty_name, starts_at, location, occurrence_state,
                                        published_at, created_by_member, created_by_account, event_ref)
    select pg_temp.d(), 'Scale duty ' || p.k || '-' || g, pg_temp.at(g, '07:00'), 'SYNTHETIC hall', 'published',
           now(), pg_temp.mid(2), pg_temp.u(2), case when p.k = 1 then pg_temp.ev() end
      from people p cross join generate_series(2, 401) g
    returning occurrence_id, duty_name)
  select * from ins;
insert into app.duties_slots (occurrence_id, position_no) select occurrence_id, 1 from socc;
insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
select s.slot_id, p.member_id, o.starts_at - interval '1 day', pg_temp.mid(2), pg_temp.u(2)
  from socc x join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join app.duties_slots s on s.occurrence_id = o.occurrence_id
  join people p on x.duty_name like 'Scale duty ' || p.k || '-%';
-- M: 200 cell parts (one every other day at 20:00), each with an owned link.
create temp table cocc as
  with ins as (
    insert into app.duties_occurrences (cell_id, duty_name, starts_at, location, occurrence_state,
                                        published_at, created_by_member, created_by_account)
    select pg_temp.cell(), 'Scale part ' || g, pg_temp.at(2 * g, '20:00'), 'SYNTHETIC cell home', 'published',
           now(), pg_temp.mid(3), pg_temp.u(3)
      from generate_series(1, 200) g
    returning occurrence_id)
  select * from ins;
insert into app.duties_slots (occurrence_id, position_no) select occurrence_id, 1 from cocc;
insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
select s.slot_id, pg_temp.mid(4), o.starts_at - interval '1 day', pg_temp.mid(3), pg_temp.u(3)
  from cocc x join app.duties_occurrences o on o.occurrence_id = x.occurrence_id
  join app.duties_slots s on s.occurrence_id = o.occurrence_id;

select app.contract_register_source_type('fixture', 'fixture_programme_part',
                                         'app.fixture_programme_part_check(jsonb)'::regprocedure);
select app.contract_register_source_type('fixture', 'fixture_event', 'app.fixture_event_check(jsonb)'::regprocedure);
select app.duties_register_link_source('fixture', 'fixture_programme_part', 'cell_part');
select app.duties_register_link_source('fixture', 'fixture_event', 'event');
analyze app.duties_occurrences, app.duties_slots, app.duties_assignments, app.duties_part_links,
  app.duties_review_flags;

set local statement_timeout = '8s';
create temp table t0 as select clock_timestamp() as t;
create temp table flag as select pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object(
  'event_id', pg_temp.ev(), 'changed', '["time"]'::jsonb)) as r;
create temp table t1 as select clock_timestamp() as t;
create temp table links as select pg_temp.fx(1, 'duties_owner_event_links', jsonb_build_object(
  'source_type', 'fixture_event', 'source_id', pg_temp.ev())) as r;
create temp table t2 as select clock_timestamp() as t;
create temp table board as select pg_temp.readj(2, 'select api.duties_leader_board()') as r;
create temp table t3 as select clock_timestamp() as t;
create temp table part as select pg_temp.fx(3, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Scale part',
  'starts_at', app.cmd_utc(pg_temp.at(200, '07:30')), 'ends_at', app.cmd_utc(pg_temp.at(200, '08:30')),
  'override_reason', 'SYNTHETIC scale: everyone is already busy that morning.',
  'positions', (select jsonb_agg(jsonb_build_object('position_key', 'p' || k, 'member_id', member_id) order by k)
                  from people))) as r;
create temp table t4 as select clock_timestamp() as t;
create temp table revised as select pg_temp.fx(3, 'fixture_programme_publish', jsonb_build_object(
  'part_id', (select r ->> 'part_id' from part), 'expected_revision', (select r -> 'revision' from part),
  'duty_name', 'SYNTHETIC Scale part',
  'starts_at', app.cmd_utc(pg_temp.at(200, '06:30')), 'ends_at', app.cmd_utc(pg_temp.at(200, '07:30')),
  'override_reason', 'SYNTHETIC scale: everyone is already busy that morning.',
  'positions', (select jsonb_agg(jsonb_build_object('position_key', 'p' || k, 'member_id', member_id) order by k)
                  from people))) as r;
create temp table t5 as select clock_timestamp() as t;
create temp table ownread as select pg_temp.fx(3, 'duties_owner_part', jsonb_build_object(
  'source_type', 'fixture_programme_part', 'source_id', (select r ->> 'part_id' from part),
  'cell_id', pg_temp.cell())) as r;
create temp table t6 as select clock_timestamp() as t;
create temp table mine as select pg_temp.readj(4, 'select api.duties_my_duties()') as r;
create temp table t7 as select clock_timestamp() as t;
reset statement_timeout;

create function pg_temp.ms(a timestamptz, b timestamptz) returns numeric language sql as
$$ select round(extract(epoch from b - a) * 1000) $$;
select is((select r ->> 'flagged' from flag), '400', 'the event flags its 400 department duties');
select is((select jsonb_array_length(r -> 'duties') || '|' || (r ->> 'truncated') from links), '200|true',
  'the event owner lists the first 200 (truncated)');
select is((select count(*)::int from board, jsonb_array_elements(r #> '{departments,0,duties}') d
            where jsonb_array_length(d -> 'reviews') = 1) > 0, true, 'the board shows the open reviews');
select is((select r ->> 'overrides_recorded' from part), '10',
  'the part is given to ten members, each over 400 commitments (every overlap recorded)');
select is((select r ->> 'overrides_recorded' from revised), '10', 'a material change asks all ten again');
select is((select jsonb_array_length(r -> 'positions') from ownread), 10, 'the owner reads all ten positions');
select is((select jsonb_array_length(r -> 'assignments') from mine), 200, 'M sees 200 cell parts in My duties');
select ok(pg_temp.ms((select t from t0), (select t from t1)) < 3000, 'flagging 400 duties is well inside the timeout');
select ok(pg_temp.ms((select t from t1), (select t from t2)) < 3000, 'the event links read is well inside the timeout');
select ok(pg_temp.ms((select t from t2), (select t from t3)) < 3000, 'the board with 400 open reviews is well inside the timeout');
select ok(pg_temp.ms((select t from t3), (select t from t5)) < 6000,
  'creating and revising the ten-position part over 4,000 commitments is well inside the timeout');
select ok(pg_temp.ms((select t from t5), (select t from t7)) < 3000, 'the owner read and My duties are well inside the timeout');
select diag('timings (ms): flag 400 = ' || pg_temp.ms((select t from t0), (select t from t1))
            || ', event links = ' || pg_temp.ms((select t from t1), (select t from t2))
            || ', board = ' || pg_temp.ms((select t from t2), (select t from t3))
            || ', create part = ' || pg_temp.ms((select t from t3), (select t from t4))
            || ', revise part = ' || pg_temp.ms((select t from t4), (select t from t5))
            || ', owner read = ' || pg_temp.ms((select t from t5), (select t from t6))
            || ', My duties = ' || pg_temp.ms((select t from t6), (select t from t7)));

select * from finish();
rollback;
