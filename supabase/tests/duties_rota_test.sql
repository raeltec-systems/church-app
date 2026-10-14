-- Generate recurring multi-position rotas with drafts and series edits (story 4.3; AD-2, AD-6,
-- AD-9): church-local series expansion through the shared 3.3 calculation, bounded and idempotent
-- generation, drafts that never notify and stay hidden from members, Publish N draft slots,
-- per-position assignment, this-occurrence and this-and-future edits through the 4.2 engine,
-- cancellation with its jobs, confirmed-of-required coverage, refusals (scope, Pastor, gate,
-- untrusted session, revoked scope incl. replay), races and the deletion hook. HTTP evidence:
-- tools/identity-e2e/duties-rota.mjs. Every account, phone and name is SYNTHETIC (fictional range
-- +44 7700 900990-900999).
begin;
select plan(131);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000043' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000043' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (990 + n)::text $$;
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
create function pg_temp.cmd(p_claims jsonb, p_fn text, p_command text, p_expected bigint,
                            p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  execute format('select %s($1)', p_fn) into r using jsonb_build_object(
         'version', 1, 'command', p_command, 'request_id', p_request,
         'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb,
                               p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.duties_command', p_command, p_expected, p_payload, p_request)
$$;
create function pg_temp.read(n int, p_sql text) returns text
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  begin
    execute p_sql into r;
    reset role;
    return 'ok ' || coalesce(r::text, 'null');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
create function pg_temp.readj(n int, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(n, p_sql), 4)::jsonb $$;
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.at(p_offset interval) returns text language sql as
$$ select app.cmd_utc(date_trunc('second', now()) + p_offset) $$;
create function pg_temp.jobs(p_source uuid) returns text language sql as $$
  select coalesce(string_agg(reminder_kind || ':' || job_state || ':' || coalesce(cancel_reason, finish_reason, '-'),
                    ',' order by enqueued_at, reminder_kind, job_state), '')
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = p_source
$$;
-- The k-th Sunday (church-local) at least four days from now.
create function pg_temp.sunday(k int) returns date language sql as $$
  select ((now() at time zone 'Africa/Lusaka')::date + 4)
         + ((7 - extract(dow from (now() at time zone 'Africa/Lusaka')::date + 4)::int) % 7) + 7 * k
$$;

-- Accounts: 1 Admin; 2 leader of D; 3 deputy of D; 4 member M; 5 member O; 6 leader of the other
-- department E; 7 Pastor; 8 accountless member X; 9 a member of E with no role.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.3');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.3 Member ' || n, 'pgtap 4.3')
  from generate_series(1, 9) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.3 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.3 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.e() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from de $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_department uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_department))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(4, pg_temp.d());
select pg_temp.add(5, pg_temp.d());
select pg_temp.add(8, pg_temp.d());
select pg_temp.add(9, pg_temp.e());

create function pg_temp.series(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('department_id', pg_temp.d(), 'duty_name', 'Sunday service', 'every', 'week',
           'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'),
           'until_date', to_char(pg_temp.sunday(12), 'YYYY-MM-DD'),
           'start_time', '00:30', 'location', 'SYNTHETIC Main hall', 'instructions', 'Arrive early.',
           'positions', jsonb_build_array('Preacher', 'Reader', 'Usher')) || p_extra
$$;

-- Structure -------------------------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.duties_series', p)),
  'no client role has any privilege on the series (a direct table query is refused)');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'app.duties_series'::regclass),
  'RLS is on for the series');
select ok(has_function_privilege('authenticated', 'api.duties_rota()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.duties_rota()', 'EXECUTE'),
  'the rota read is for authenticated sessions only');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select string_agg(f || '=' || coalesce(app.duties_slot_field_class(f), 'none'), ',' order by f)
             from unnest(array['topic', 'scripture', 'event_ref', 'position_name']) f),
  'event_ref=reference,position_name=material,scripture=notes,topic=notes',
  'the 4.3 fields are classified explicitly');
select is((select c.title || '|' || c.link from app.contract_reminder_contracts c
            where c.source_type = 'duties_assignment' and c.reminder_kind = 'duty_cancelled'),
  'Duty cancelled|/duties', 'the generic cancellation notice is registered');

-- Generation refusals ----------------------------------------------------------------------------
select is(pg_temp.duties(4, 'duties.create_series', null, pg_temp.series()) ->> 'code', 'forbidden',
  'a member cannot create a rota');
select is(pg_temp.duties(6, 'duties.create_series', null, pg_temp.series()) ->> 'code', 'forbidden',
  'another department''s leader cannot');
select is(pg_temp.duties(7, 'duties.create_series', null, pg_temp.series()) ->> 'code', 'forbidden',
  'the Pastor cannot');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
            'every', 'day', 'until_date', to_char(pg_temp.sunday(0) + 100, 'YYYY-MM-DD')))) -> 'field_errors',
  '{"until_date": "too_many"}'::jsonb, 'at most 60 occurrences per series');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
            'until_date', to_char(pg_temp.sunday(0) + 400, 'YYYY-MM-DD')))) -> 'field_errors',
  '{"until_date": "out_of_range"}'::jsonb, 'and at most 366 days');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
            'until_date', to_char(pg_temp.sunday(0) - 7, 'YYYY-MM-DD'), 'reporting_time', '01:00',
            'positions', jsonb_build_array('Reader', 'reader')))) -> 'field_errors',
  '{"until_date": "before_from", "reporting_time": "after_start", "positions": "duplicate"}'::jsonb,
  'dates, reporting time and position names are checked together');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
            'start_time', '25:00', 'every', 'year', 'positions', '[]'::jsonb, 'extra', 1))) -> 'field_errors',
  '{"start_time": "invalid", "every": "invalid", "positions": "required", "extra": "unknown_field"}'::jsonb,
  'malformed times, rules and positions are refused');
select is(pg_temp.duties(2, 'duties.create_series', 1, pg_temp.series()) -> 'field_errors',
  '{"expected_revision": "must_be_null"}'::jsonb, 'creating a series takes no expected revision');

-- Generate a quarterly Sunday series ---------------------------------------------------------------
create temp table gen_req as select gen_random_uuid() as id;
create temp table gen as select pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(),
  (select id from gen_req)) as r;
create function pg_temp.sr() returns uuid language sql as $$ select (r #>> '{data,series_id}')::uuid from gen $$;
create function pg_temp.srev() returns bigint language sql as
$$ select revision from app.duties_series where series_id = pg_temp.sr() $$;
create function pg_temp.o(k int) returns uuid language sql as $$
  select occurrence_id from app.duties_occurrences where series_id = pg_temp.sr()
   order by series_date offset k - 1 limit 1
$$;
create function pg_temp.orev(k int) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = pg_temp.o(k) $$;
create function pg_temp.slot(k int, p int) returns uuid language sql as
$$ select slot_id from app.duties_slots where occurrence_id = pg_temp.o(k) and position_no = p $$;
create function pg_temp.cur(k int, p int) returns uuid language sql as
$$ select assignment_id from app.duties_assignments where slot_id = pg_temp.slot(k, p) and assignment_state = 'current' $$;

select is((select (r -> 'data') - 'series_id' - 'department_id' from gen),
  '{"revision": 1, "occurrences": 13, "draft_slots": 39}'::jsonb,
  'a quarterly Sunday series with three positions generates 13 draft occurrences (ids and counts only)');
select is((select count(*)::int || '|' || count(*) filter (where occurrence_state = 'draft')::int
                  || '|' || count(distinct series_date)::int
             from app.duties_occurrences where series_id = pg_temp.sr()),
  '13|13|13', 'every occurrence is a draft with its own church-local date');
select is((select bool_and(extract(dow from series_date) = 0
                           and extract(dow from starts_at at time zone 'UTC') = 6
                           and to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') = '00:30')::text
             from app.duties_occurrences where series_id = pg_temp.sr()),
  'true', '00:30 church time stays on the church-local Sunday (Saturday in UTC): expansion is in church time');
select is((select string_agg(position_no || ':' || position_name, ',' order by position_no)
             from app.duties_slots where occurrence_id = pg_temp.o(1)),
  '1:Preacher,2:Reader,3:Usher', 'one slot per named position');
select is((select zone || '|' || policy_version from app.duties_series where series_id = pg_temp.sr()),
  'Africa/Lusaka|1', 'the series records the church zone and the policy version (AD-9)');
select is((select count(*)::int from app.notifications_jobs j
             join app.duties_assignments a on a.assignment_id = j.source_id
             join app.duties_slots s on s.slot_id = a.slot_id
             join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
            where o.series_id = pg_temp.sr()), 0, 'drafts have no assignments and no jobs');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(), (select id from gen_req)) -> 'data',
  (select r -> 'data' from gen), 'a replay returns the original result');
select is((select count(*)::int from app.duties_series where department_id = pg_temp.d()), 1,
  'and generates nothing twice');
create temp table gen2 as select pg_temp.duties(3, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
  'duty_name', 'Midweek prayer', 'until_date', to_char(pg_temp.sunday(3), 'YYYY-MM-DD'),
  'start_time', '18:00', 'end_time', '17:00', 'positions', jsonb_build_array('Leader'),
  'exceptions', jsonb_build_array(to_char(pg_temp.sunday(1), 'YYYY-MM-DD'))))) as r;
select is((select (r #>> '{data,occurrences}') || '|' ||
                  (select string_agg(to_char(series_date, 'YYYY-MM-DD'), ',' order by series_date)
                     from app.duties_occurrences where series_id = (gen2.r #>> '{data,series_id}')::uuid)
             from gen2),
  '3|' || to_char(pg_temp.sunday(0), 'YYYY-MM-DD') || ',' || to_char(pg_temp.sunday(2), 'YYYY-MM-DD') || ','
       || to_char(pg_temp.sunday(3), 'YYYY-MM-DD'),
  'the deputy creates a series; exception dates are skipped');
select is((select to_char(ends_at at time zone 'Africa/Lusaka', 'YYYY-MM-DD HH24:MI')
             from app.duties_occurrences where series_id = (select (r #>> '{data,series_id}')::uuid from gen2)
            order by series_date limit 1),
  to_char(pg_temp.sunday(0) + 1, 'YYYY-MM-DD') || ' 17:00', 'an end time before the start ends on the next day');

create function pg_temp.g2(k int) returns uuid language sql as $$
  select occurrence_id from app.duties_occurrences where series_id = (select (r #>> '{data,series_id}')::uuid from gen2)
   order by series_date offset k - 1 limit 1
$$;
create temp table d_edit as select pg_temp.duties(2, 'duties.revise_duty',
  (select revision from app.duties_occurrences where occurrence_id = pg_temp.g2(2)),
  jsonb_build_object('occurrence_id', pg_temp.g2(2), 'location', 'SYNTHETIC Side hall',
                     'starts_at', app.cmd_utc(app.duties_wall(pg_temp.sunday(2), '19:00', 'Africa/Lusaka')))) as r;
select is((select (r #>> '{data,change}') || '|' ||
                  (select count(*) from app.duties_slot_revisions where occurrence_id = pg_temp.g2(2))
             from d_edit), 'draft|0', 'a draft occurrence is edited in place (no revision rows, no notice)');
create temp table d_future as select pg_temp.duties(3, 'duties.revise_series',
  (select revision from app.duties_series where series_id = (select (r #>> '{data,series_id}')::uuid from gen2)),
  jsonb_build_object('series_id', (select r #>> '{data,series_id}' from gen2), 'from_occurrence_id', pg_temp.g2(1),
                     'start_time', '18:30', 'topic', 'SYNTHETIC Prayer')) as r;
select is((select (r -> 'data') - 'series_id' - 'from_occurrence_id' from d_future),
  '{"revision": 2, "occurrences": 3, "drafts": 3, "material": 0, "assignments": 0, "notices_queued": 0, "overrides": 0}'::jsonb,
  'this and future on drafts edits them in place without a lead time or a notice');

-- Drafts are hidden from members -----------------------------------------------------------------
select is(jsonb_array_length(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments'), 0,
  'a member sees no draft');
select is(split_part(pg_temp.read(4, 'select api.duties_rota()'), '|', 3), 'not_granted',
  'and cannot read the rota');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') x,
                  jsonb_array_elements(x -> 'duties') y), 0,
  'the 4.1/4.2 leader board lists published duties only');
create function pg_temp.rota(n int) returns jsonb language sql as $$
  select (select x from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_rota()') -> 'departments') x
           where x ->> 'department_id' = pg_temp.d()::text)
$$;
create function pg_temp.rocc(n int, k int) returns jsonb language sql as $$
  select o from jsonb_array_elements(pg_temp.rota(n) -> 'series') s, jsonb_array_elements(s -> 'occurrences') o
   where o ->> 'occurrence_id' = pg_temp.o(k)::text
$$;
select is((select (x ->> 'capacity') || '|' || (x ->> 'can_manage') || '|' || jsonb_array_length(x -> 'series')
             from (select pg_temp.rota(7) as x) y),
  'pastor|false|2', 'the Pastor sees the drafts read-only');
select is((select (x ->> 'can_manage') || '|' || (select y ->> 'draft_slots' from jsonb_array_elements(x -> 'series') y
                                                         where y ->> 'series_id' = pg_temp.sr()::text)
             from (select pg_temp.rota(2) as x) y),
  'true|39', 'the leader sees the drafts and the number of draft slots');
select is((select string_agg(m ->> 'account', ',' order by m ->> 'display_name')
             from jsonb_array_elements(pg_temp.rota(2) -> 'members') m),
  'no_login,app_account,app_account', 'candidates include a member without a login (labels only)');
select ok(not (pg_temp.readj(6, 'select api.duties_rota()')::text like '%Sunday service%'),
  'another department''s leader sees nothing of this rota');

-- Assign draft positions -----------------------------------------------------------------------------
create function pg_temp.assign(n int, k int, p int, p_member uuid, p_extra jsonb default '{}',
                               p_expected bigint default null) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.assign_slot', coalesce(p_expected, pg_temp.orev(k)),
    jsonb_build_object('slot_id', pg_temp.slot(k, p), 'member_id', p_member) || p_extra)
$$;
select is(pg_temp.assign(2, 1, 1, pg_temp.mid(9)) -> 'field_errors', '{"member_id": "not_in_department"}'::jsonb,
  'a draft position goes only to a department member');
select is(pg_temp.assign(4, 1, 1, pg_temp.mid(4)) ->> 'code', 'forbidden', 'a member cannot assign');
select is(pg_temp.assign(2, 1, 1, pg_temp.mid(4), jsonb_build_object('response_deadline', pg_temp.at('1 day')))
            -> 'field_errors', '{"response_deadline": "draft"}'::jsonb, 'a draft takes no answer-by');
create temp table a1 as select pg_temp.assign(2, 1, 1, pg_temp.mid(4)) as r;
select is((select (r -> 'data') - 'occurrence_id' - 'slot_id' from a1),
  '{"revision": 2, "state": "draft", "draft_assigned": true, "override_recorded": false}'::jsonb,
  'the leader plans M as Preacher (ids and states only)');
select is(pg_temp.assign(3, 1, 2, pg_temp.mid(5), '{}', 1) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 2}'::jsonb,
  'the deputy, planning from the same revision at the same time, gets a conflict');
select pg_temp.assign(3, 1, 2, pg_temp.mid(5));
select pg_temp.assign(2, 1, 3, pg_temp.mid(8));
select pg_temp.assign(2, 2, 1, pg_temp.mid(5));
select pg_temp.assign(2, 2, 2, pg_temp.mid(4));
select pg_temp.assign(2, 3, 1, pg_temp.mid(4));
select pg_temp.assign(2, 6, 1, pg_temp.mid(4));
select pg_temp.assign(2, 6, 2, pg_temp.mid(5));
select pg_temp.assign(2, 10, 1, pg_temp.mid(4));
select is(pg_temp.assign(2, 1, 3, pg_temp.mid(8)) -> 'field_errors', '{"slot_id": "unchanged"}'::jsonb,
  'planning the same person again changes nothing');
select is((select count(*)::int from app.notifications_jobs where recipient_member_id in (pg_temp.mid(4), pg_temp.mid(5), pg_temp.mid(8))),
  0, 'planning drafts never notifies');
select is((select (o #>> '{positions,0,draft,display_name}') || '|' || (o #>> '{positions,0,draft,available}')
                  || '|' || (o ->> 'required') || '|' || (o ->> 'confirmed')
             from (select pg_temp.rocc(2, 1) as o) x),
  'SYNTHETIC 4.3 Member 4|true|3|0', 'the rota shows the planned person and 0 of 3 confirmed');

-- Publish N draft slots -----------------------------------------------------------------------------
create function pg_temp.publish(n int, p_count int, p_lead text, p_expected bigint default null,
                                p_request uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.publish_drafts', coalesce(p_expected, pg_temp.srev()),
    jsonb_build_object('series_id', pg_temp.sr(), 'slot_count', p_count, 'deadline_before', p_lead), p_request)
$$;
select is(pg_temp.publish(2, 38, '1 day') - 'request_id' - 'message',
  jsonb_build_object('code', 'conflict', 'field_errors', '{"slot_count": "changed"}'::jsonb, 'current_revision', 1),
  'Publish N refuses when N is not the number of draft slots');
select is(pg_temp.publish(2, 39, '30 days') -> 'field_errors',
  jsonb_build_object('deadline_before', 'passed', 'occurrence:' || pg_temp.o(1), 'passed'),
  'an answer-by that has already passed is refused');
select is(pg_temp.publish(7, 39, '1 day') ->> 'code', 'forbidden', 'the Pastor cannot publish');
create temp table pub_req as select gen_random_uuid() as id;
create temp table pub as select pg_temp.publish(2, 39, '1 day', null, (select id from pub_req)) as r;
select is((select (r -> 'data') - 'series_id' from pub),
  '{"revision": 2, "occurrences": 13, "slots": 39, "assignments": 9, "notices_queued": 9, "overrides": 0}'::jsonb,
  'publishing 39 draft slots creates 9 assignments with one notice each (counts only)');
select is((select count(*) filter (where occurrence_state = 'published')::int
             from app.duties_occurrences where series_id = pg_temp.sr()), 13, 'every occurrence is published');
select is((select count(*)::int from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
            where o.series_id = pg_temp.sr() and s.draft_member_id is not null), 0,
  'the planned assignees became assignments');
select is((select response || '|' || slot_revision || '|' ||
                  to_char(response_deadline at time zone 'Africa/Lusaka', 'YYYY-MM-DD HH24:MI')
             from app.duties_assignments where assignment_id = pg_temp.cur(1, 1)),
  'pending|1|' || to_char(pg_temp.sunday(0) - 1, 'YYYY-MM-DD') || ' 00:30',
  'each assignment is pending with the answer-by a church-local day before the start');
select is(pg_temp.jobs(pg_temp.cur(1, 1)), 'duty_assigned:pending:-',
  'each generated assignment uses the duties_assignment new-duty contract');
select is((select count(*)::int from app.duties_slot_revisions r join app.duties_occurrences o using (occurrence_id)
            where o.series_id = pg_temp.sr() and r.change_class = 'published' and r.slot_revision = 1), 39,
  'every published position records slot revision 1');
select is(pg_temp.cur(1, 1) is not null and pg_temp.cur(4, 1) is null, true,
  'unplanned positions publish unfilled');
select is(pg_temp.publish(2, 39, '1 day', 1, (select id from pub_req)) -> 'data',
  (select r -> 'data' from pub), 'a replay returns the original result');
select is(pg_temp.publish(2, 1, '1 day') -> 'field_errors', '{"series_id": "no_drafts"}'::jsonb,
  'nothing is left to publish');
select is(jsonb_array_length(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments'), 5,
  'M now sees the five published positions');
select is((select x ->> 'position_name' from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = pg_temp.cur(1, 1)::text), 'Preacher', 'with the position');
select pg_temp.run();
select is((select count(*)::int from app.notifications_inbox_items where recipient_member_id = pg_temp.mid(4)), 5,
  'the worker delivers one inbox item per assignment');

-- A planned assignee who left the department blocks publishing (fail closed).
create temp table gen3 as select pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
  'duty_name', 'Evening service', 'until_date', to_char(pg_temp.sunday(1), 'YYYY-MM-DD'), 'start_time', '17:00',
  'positions', jsonb_build_array('Usher')))) as r;
select pg_temp.duties(2, 'duties.assign_slot',
  (select o.revision from app.duties_occurrences o where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen3) order by series_date limit 1),
  jsonb_build_object('slot_id', (select s.slot_id from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
                                   where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen3)
                                   order by o.series_date limit 1), 'member_id', pg_temp.mid(5)));
update app.duties_department_members set ended_at = now() where department_id = pg_temp.d() and member_id = pg_temp.mid(5);
select is(pg_temp.duties(2, 'duties.publish_drafts', 1, jsonb_build_object('series_id', (select r #>> '{data,series_id}' from gen3),
            'slot_count', 2, 'deadline_before', '1 day')) -> 'field_errors',
  jsonb_build_object('member_id', 'unavailable', 'occurrence:' || (select o.occurrence_id from app.duties_occurrences o
    where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen3) order by o.series_date limit 1), 'unavailable'),
  'a planned assignee who can no longer serve is refused, naming the date');
select is((select o #>> '{positions,0,draft,available}' from jsonb_array_elements(pg_temp.rota(2) -> 'series') s,
                  jsonb_array_elements(s -> 'occurrences') o
            where s ->> 'series_id' = (select r #>> '{data,series_id}' from gen3) order by o ->> 'series_date' limit 1),
  'false', 'and the rota marks the planned person unavailable (no reason disclosed)');
update app.duties_department_members set ended_at = null where department_id = pg_temp.d() and member_id = pg_temp.mid(5);

-- Answers and coverage ----------------------------------------------------------------------------
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.cur(1, 1), 'response', 'accepted'));
select pg_temp.duties(5, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.cur(1, 2), 'response', 'accepted'));
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.cur(2, 2), 'response', 'accepted'));
select is((select (o ->> 'confirmed') || ' of ' || (o ->> 'required') from (select pg_temp.rocc(2, 1) as o) x),
  '2 of 3', '2 of 3 confirmed is derived from the current positions');
select is((select o #>> '{positions,2,assignment,response}' from (select pg_temp.rocc(2, 1) as o) x),
  'pending', 'the accountless member''s position is still awaiting a response');
select ok(not (pg_temp.rota(7)::text ~ '"note"'), 'the rota carries no member notes');

-- This occurrence --------------------------------------------------------------------------------
create temp table o1_before as select o.*, (select array_agg(assignment_id order by assignment_id)
  from app.duties_assignments a join app.duties_slots s using (slot_id) where s.occurrence_id = o.occurrence_id) as asg
  from app.duties_occurrences o where occurrence_id = pg_temp.o(1);
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(2), jsonb_build_object('occurrence_id', pg_temp.o(2),
            'member_id', pg_temp.mid(4))) -> 'field_errors', '{"member_id": "unsupported"}'::jsonb,
  'a rota position is given with duties.assign_slot, not revise_duty');
create temp table this1 as select pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(2), jsonb_build_object(
  'occurrence_id', pg_temp.o(2),
  'starts_at', app.cmd_utc(app.duties_wall(pg_temp.sunday(1), '09:00', 'Africa/Lusaka')),
  'response_deadline', app.cmd_utc(app.duties_wall(pg_temp.sunday(1) - 1, '09:00', 'Africa/Lusaka')))) as r;
select is((select r #>> '{data,change}' from this1), 'material', 'changing one occurrence''s time is material');
select is((select string_agg(assignment_state || ':' || response, ',' order by s.position_no, a.assigned_at)
             from app.duties_assignments a join app.duties_slots s using (slot_id) where s.occurrence_id = pg_temp.o(2)),
  'superseded:pending,current:pending,superseded:accepted,current:pending',
  'every position of the occurrence is revised together; the kept acceptance stays in history');
select is((select string_agg(change_class || ':' || array_to_string(changed_fields, '+'), ',' order by slot_id)
             from app.duties_slot_revisions r where r.occurrence_id = pg_temp.o(2) and r.slot_revision = 2),
  'material:starts_at,material:starts_at,material:starts_at', 'each position records the material revision');
select is((select revision || '|' || occurrence_state from app.duties_occurrences where occurrence_id = pg_temp.o(1)),
  (select revision || '|' || occurrence_state from o1_before), 'the other occurrences are unchanged');
create temp table notes1 as select pg_temp.duties(3, 'duties.revise_duty', pg_temp.orev(1), jsonb_build_object(
  'occurrence_id', pg_temp.o(1), 'topic', 'SYNTHETIC Hope', 'scripture', 'Psalm 23')) as r;
select is((select (r #>> '{data,change}') || '|' || (r #>> '{data,notice_queued}') from notes1), 'notes|true',
  'a topic and scripture edit is notes-only and sends an update');
select is((select string_agg(response, ',' order by s.position_no) from app.duties_assignments a
             join app.duties_slots s using (slot_id) where s.occurrence_id = pg_temp.o(1) and a.assignment_state = 'current'),
  'accepted,accepted,pending', 'the answers stand');
select is((select x ->> 'topic' || '|' || (x ->> 'scripture') from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = pg_temp.cur(1, 1)::text), 'SYNTHETIC Hope|Psalm 23',
  'the member reads the topic and scripture');
create temp table ref1 as select pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(1), jsonb_build_object(
  'occurrence_id', pg_temp.o(1), 'event_ref', gen_random_uuid())) as r;
select is((select (r #>> '{data,change}') || '|' || (r #>> '{data,notice_queued}') from ref1), 'reference|false',
  'a linked-event reference is recorded without a notice');
select is((select change_class from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.o(1) and s.position_no = 1
            order by r.slot_revision desc limit 1) || '|' ||
          coalesce((select x ->> 'notes_updated_at' from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
                     where x ->> 'assignment_id' = pg_temp.cur(1, 1)::text), 'none') ||
          '|' || ((select count(*) from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
                    where s.occurrence_id = pg_temp.o(1) and r.change_class = 'notes') > 0)::text,
  'reference|' || coalesce((select app.cmd_utc(max(r.created_at)) from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
                             where s.occurrence_id = pg_temp.o(1) and s.position_no = 1 and r.change_class = 'notes'), 'none') || '|true',
  'it is a reference revision, so My duties still reports only the earlier notes update');

-- This and future ------------------------------------------------------------------------------------
-- Occurrence 5 has started (its time came while the rota was being edited).
update app.duties_occurrences set starts_at = now() - interval '1 minute' where occurrence_id = pg_temp.o(5);
create temp table o5_before as select revision, starts_at from app.duties_occurrences where occurrence_id = pg_temp.o(5);
create function pg_temp.future(n int, p_from int, p_extra jsonb, p_expected bigint default null) returns jsonb
language sql as $$
  select pg_temp.duties(n, 'duties.revise_series', coalesce(p_expected, pg_temp.srev()),
    jsonb_build_object('series_id', pg_temp.sr(), 'from_occurrence_id', pg_temp.o(p_from)) || p_extra)
$$;
select is(pg_temp.future(2, 3, '{"start_time": "10:00"}') -> 'field_errors',
  jsonb_build_object('deadline_before', 'required', 'occurrence:' || pg_temp.o(3), 'required'),
  'a material this-and-future change of published duties needs the answer-by lead time');
select is(pg_temp.future(2, 5, '{"start_time": "10:00"}') -> 'field_errors', '{"from_occurrence_id": "started"}'::jsonb,
  'a started occurrence cannot be the anchor');
create temp table fut as select pg_temp.future(2, 3, '{"start_time": "10:00", "deadline_before": "2 days"}') as r;
select is((select (r -> 'data') - 'series_id' - 'from_occurrence_id' from fut),
  '{"revision": 3, "occurrences": 10, "drafts": 0, "material": 10, "assignments": 4, "notices_queued": 4, "overrides": 0}'::jsonb,
  'this and future changes the anchor and the 10 later occurrences that have not started (counts only)');
select is((select count(*)::int from app.duties_occurrences where series_id = pg_temp.sr()
            and to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') = '10:00'), 10,
  'each moves to 10:00 church time on its own date');
select is((select revision || '|' || starts_at from app.duties_occurrences where occurrence_id = pg_temp.o(5)),
  (select revision || '|' || starts_at from o5_before), 'the started occurrence is unchanged');
select is((select to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') || '|' || revision
             from app.duties_occurrences where occurrence_id = pg_temp.o(2)),
  '09:00|5', 'the earlier occurrence keeps its own edit');
select is((select to_char(response_deadline at time zone 'Africa/Lusaka', 'YYYY-MM-DD HH24:MI') from app.duties_assignments
            where assignment_id = pg_temp.cur(3, 1)),
  to_char(pg_temp.sunday(2) - 2, 'YYYY-MM-DD') || ' 10:00', 'the new answer-by is two church-local days before');
select is((select count(distinct a.assignment_id)::int from app.duties_assignments a join app.duties_slots s using (slot_id)
             join app.duties_occurrences o using (occurrence_id) where o.series_id = pg_temp.sr() and a.member_id = pg_temp.mid(4)
              and a.assignment_state = 'current'), 5, 'each occurrence keeps its own assignment for M');
create temp table futn as select pg_temp.future(3, 3, '{"instructions": "Bring a Bible."}') as r;
select is((select (r #>> '{data,material}') || '|' || (r #>> '{data,notices_queued}') from futn), '0|4',
  'an instructions-only this-and-future edit asks nobody again and sends updates');
select is(pg_temp.future(2, 3, '{"instructions": "x"}', 3) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 4}'::jsonb,
  'a second leader editing from the same series revision gets a conflict');
select is(pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id',
            (select a.assignment_id from app.duties_assignments a where a.slot_id = pg_temp.slot(3, 1)
              and a.assignment_state = 'superseded'), 'response', 'accepted')) -> 'field_errors',
  '{"assignment_id": "superseded", "starts_at": "changed", "instructions": "changed"}'::jsonb,
  'an answer to the version before the series edit is refused with what changed');

-- Per-position assignment of a published rota ---------------------------------------------------------
select is(pg_temp.assign(2, 4, 1, pg_temp.mid(5)) -> 'field_errors', '{"response_deadline": "required"}'::jsonb,
  'giving a published position needs an answer-by');
create temp table give as select pg_temp.assign(2, 4, 1, pg_temp.mid(5), jsonb_build_object(
  'response_deadline', app.cmd_utc(app.duties_wall(pg_temp.sunday(3) - 1, '10:00', 'Africa/Lusaka')))) as r;
select is((select (r #>> '{data,state}') || '|' || (r #>> '{data,response}') || '|' || (r #>> '{data,notice_queued}') from give),
  'published|pending|true', 'an unfilled published position is given with a new-duty notice');
select is(pg_temp.jobs(pg_temp.cur(4, 1)), 'duty_assigned:pending:-', 'with one job');

-- A later date's assignee left the department: a series time change names that date.
update app.duties_department_members set ended_at = now() where department_id = pg_temp.d() and member_id = pg_temp.mid(5);
select is(pg_temp.future(3, 4, '{"start_time": "12:00", "deadline_before": "1 day"}') -> 'field_errors',
  jsonb_build_object('member_id', 'required_reassign', 'occurrence:' || pg_temp.o(4), 'required_reassign'),
  'a this-and-future change that would ask someone who left names the date to fix first (ids only)');
select is((select to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') from app.duties_occurrences
            where occurrence_id = pg_temp.o(3)), '10:00', 'and nothing was changed');
update app.duties_department_members set ended_at = null where department_id = pg_temp.d() and member_id = pg_temp.mid(5);
select is(pg_temp.future(3, 4, '{"start_time": "07:00", "reporting_time": "08:00"}') -> 'field_errors',
  '{"reporting_time": "after_start"}'::jsonb, 'a reporting time after the new start is a field error');

-- Audit carries the assignment ids ---------------------------------------------------------------------
select is((select count(*)::int from app.duties_audit where series_id = pg_temp.sr() and action = 'duty_published'
            and code is null and assignment_id is null), 0, 'every published assignment is audited with its id');
select is((select count(*)::int from app.duties_audit where series_id = pg_temp.sr() and action = 'duty_published'
            and assignment_id is not null), 9, 'nine published assignments are audited');
select ok((select bool_and(assignment_id is not null) from app.duties_audit
            where occurrence_id = pg_temp.o(2) and action = 'duty_revised' and member_id is not null),
  'each revised position is audited with its assignment');

-- Cancel one occurrence ------------------------------------------------------------------------------
create temp table c6_asg as select pg_temp.cur(6, 1) as m_asg, pg_temp.cur(6, 2) as o_asg;
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', (select m_asg from c6_asg), 'response', 'accepted'));
select is(pg_temp.duties(2, 'duties.cancel_occurrence', 1, jsonb_build_object('occurrence_id', pg_temp.o(6))) ->> 'code',
  'conflict', 'cancelling needs the current occurrence revision');
create temp table can6 as select pg_temp.duties(2, 'duties.cancel_occurrence', pg_temp.orev(6),
  jsonb_build_object('occurrence_id', pg_temp.o(6))) as r;
select is((select (r -> 'data') - 'occurrence_id' - 'revision' from can6),
  '{"state": "cancelled", "assignments_cancelled": 2, "notices_queued": 2}'::jsonb,
  'cancelling an occurrence ends both its assignments and notifies both assignees');
select is(pg_temp.jobs((select m_asg from c6_asg)), 'duty_changed:cancelled:replaced,duty_changed:cancelled:responded,duty_cancelled:pending:-',
  'the accepted member''s jobs end and one cancellation notice is queued');
select is(pg_temp.jobs((select o_asg from c6_asg)), 'duty_changed:cancelled:replaced,duty_changed:cancelled:source_cancelled,duty_cancelled:pending:-',
  'the pending member''s change notice is cancelled with the occurrence');
select is((select string_agg(distinct assignment_state || ':' || end_reason, ',') from app.duties_assignments
            where assignment_id in ((select m_asg from c6_asg), (select o_asg from c6_asg))),
  'cancelled:cancelled', 'the assignments are cancelled (their answers kept)');
select is(pg_temp.duties(4, 'duties.respond', 2, jsonb_build_object('assignment_id', (select m_asg from c6_asg),
            'response', 'declined')) -> 'field_errors', '{"assignment_id": "cancelled"}'::jsonb,
  'a late answer to a cancelled duty is refused');
select is((select string_agg(distinct change_class, ',') from app.duties_slot_revisions where occurrence_id = pg_temp.o(6)
            and (slot_id, slot_revision) in (select slot_id, max(slot_revision) from app.duties_slot_revisions
                                              where occurrence_id = pg_temp.o(6) group by slot_id)), 'cancelled', 'each position records the cancellation');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
                       where x ->> 'occurrence_id' = pg_temp.o(6)::text), 'My duties no longer lists it');
select is((select o ->> 'state' from (select pg_temp.rocc(2, 6) as o) x), 'cancelled', 'the rota shows it cancelled');
select pg_temp.run();
create temp table cancelled_item as select x from jsonb_array_elements(pg_temp.readj(4, 'select api.notifications_my_inbox()') -> 'items') x
  where x ->> 'title' = 'Duty cancelled';
select is((select count(*)::int from cancelled_item), 1, 'M''s inbox shows one generic Duty cancelled notice');
select is(pg_temp.duties(2, 'duties.cancel_occurrence', pg_temp.orev(6), jsonb_build_object('occurrence_id', pg_temp.o(6)))
            -> 'field_errors', '{"occurrence_id": "cancelled"}'::jsonb, 'it cannot be cancelled twice');
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(6), jsonb_build_object('occurrence_id', pg_temp.o(6),
            'instructions', 'x')) -> 'field_errors', '{"occurrence_id": "cancelled"}'::jsonb, 'nor changed');
create temp table oneoff as select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'One-off', 'starts_at', pg_temp.at('10 days'), 'member_id', pg_temp.mid(4),
  'response_deadline', pg_temp.at('7 days'))) as r;
select is(pg_temp.duties(2, 'duties.cancel_occurrence', 1, jsonb_build_object('occurrence_id',
            (select r #>> '{data,occurrence_id}' from oneoff))) -> 'field_errors',
  '{"occurrence_id": "not_in_series"}'::jsonb, 'a one-off duty is not cancelled here (entry 9)');

-- Cancel this and future -------------------------------------------------------------------------------
create temp table o9_before as select revision, occurrence_state from app.duties_occurrences where occurrence_id = pg_temp.o(9);
create temp table canf as select pg_temp.duties(3, 'duties.cancel_series', pg_temp.srev(), jsonb_build_object(
  'series_id', pg_temp.sr(), 'from_occurrence_id', pg_temp.o(10))) as r;
select is((select (r -> 'data') - 'series_id' - 'from_occurrence_id' - 'revision' from canf),
  '{"occurrences": 4, "assignments_cancelled": 1, "notices_queued": 1}'::jsonb,
  'cancelling this and future ends the anchor and the three later occurrences');
select is((select string_agg(occurrence_state, ',' order by series_date) from app.duties_occurrences
            where series_id = pg_temp.sr() and series_date >= (select series_date from app.duties_occurrences where occurrence_id = pg_temp.o(9))),
  'published,cancelled,cancelled,cancelled,cancelled', 'earlier occurrences are kept');
select is((select revision || '|' || occurrence_state from app.duties_occurrences where occurrence_id = pg_temp.o(9)),
  (select revision || '|' || occurrence_state from o9_before), 'unchanged');

select is((select string_agg(coalesce(assignment_id::text, 'none'), ',' order by assignment_id::text)
             from app.duties_audit where occurrence_id = pg_temp.o(6) and action = 'occurrence_cancelled'
              and assignment_id is not null),
  (select string_agg(x::text, ',' order by x::text) from (select m_asg as x from c6_asg union all select o_asg from c6_asg) y),
  'the cancellation is audited per cancelled assignment');

-- Receipts and audit hold ids, counts and codes only ---------------------------------------------------
select is((select count(*)::int from app.cmd_receipts c where c.command in ('duties.create_series',
            'duties.assign_slot', 'duties.publish_drafts', 'duties.revise_series', 'duties.cancel_occurrence',
            'duties.cancel_series')
            and (c.result::text like '%SYNTHETIC%' or c.result::text like '%Preacher%' or c.result::text like '%Bible%'
                 or c.result::text like '%Sunday%')), 0,
  'command answers carry ids, revisions, states and counts only');
select is((select string_agg(distinct action, ',' order by action) from app.duties_audit where series_id = pg_temp.sr()),
  'draft_assigned,duty_published,duty_revised,occurrence_cancelled,series_created,series_revised',
  'every rota action is audited with its series');
select ok((select count(*) from app.duties_audit where series_id is not null and code is not null
            and code !~ '^[a-z][a-z0-9_]{0,62}$') = 0, 'audit codes are codes');

-- Untrusted session, scope loss and replay ----------------------------------------------------------
insert into auth.sessions (id, user_id, aal, created_at)
values (pg_temp.s(21), pg_temp.u(2), 'aal1', clock_timestamp() - interval '1 hour');
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), pg_temp.s(21), now(), now(), 'otp');
select is(pg_temp.cmd(jsonb_build_object('sub', pg_temp.u(2), 'role', 'authenticated', 'aal', 'aal1',
            'session_id', pg_temp.s(21), 'is_anonymous', false,
            'amr', jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', 1790000000))),
            'api.duties_command', 'duties.create_series', null, pg_temp.series()) ->> 'code',
  'unauthenticated', 'a leader''s untrusted session is unauthenticated');
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d()));
select is(pg_temp.publish(2, 39, '1 day', 1, (select id from pub_req)) ->> 'code', 'forbidden',
  'after the leader''s scope is revoked even a replay of their publish is refused');
select is(pg_temp.duties(2, 'duties.create_series', null, pg_temp.series(), (select id from gen_req)) ->> 'code',
  'forbidden', 'and a replay of their series creation');
select is(split_part(pg_temp.read(2, 'select api.duties_rota()'), '|', 3), 'not_granted',
  'and they no longer read the rota');
select is(pg_temp.future(3, 3, '{"instructions": "Deputy text."}') #>> '{data,material}', '0',
  'the deputy still manages the rota');

-- A started draft is not published and not counted in N --------------------------------------------
update app.duties_occurrences set starts_at = now() - interval '1 minute', ends_at = null
 where occurrence_id = pg_temp.g2(1);
select is(pg_temp.duties(3, 'duties.publish_drafts',
            (select revision from app.duties_series where series_id = (select (r #>> '{data,series_id}')::uuid from gen2)),
            jsonb_build_object('series_id', (select r #>> '{data,series_id}' from gen2), 'slot_count', 3,
                               'deadline_before', '1 day')) ->> 'code',
  'conflict', 'a draft that has started is not one of the N draft slots');
create temp table pub2 as select pg_temp.duties(3, 'duties.publish_drafts',
  (select revision from app.duties_series where series_id = (select (r #>> '{data,series_id}')::uuid from gen2)),
  jsonb_build_object('series_id', (select r #>> '{data,series_id}' from gen2), 'slot_count', 2,
                     'deadline_before', '1 day')) as r;
select is((select (r #>> '{data,occurrences}') || '|' ||
                  (select occurrence_state from app.duties_occurrences where occurrence_id = pg_temp.g2(1)) from pub2),
  '2|draft', 'the two future drafts publish; the started one stays an unpublished draft');

-- Window: a valid year-long series far ahead is generated (the 400-day window starts at the first date).
create temp table far as select pg_temp.duties(6, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.e(), 'duty_name', 'Welcome', 'every', 'week', 'start_time', '09:00',
  'from_date', to_char(pg_temp.sunday(0) + 300, 'YYYY-MM-DD'),
  'until_date', to_char(pg_temp.sunday(0) + 300 + 364, 'YYYY-MM-DD'),
  'positions', jsonb_build_array('Door'))) as r;
select is((select (r #>> '{data,occurrences}')::int from far), 53,
  'a weekly series a year long starting 300 days ahead is generated (not refused for the window)');
select is(pg_temp.duties(6, 'duties.create_series', null, jsonb_build_object(
            'department_id', pg_temp.e(), 'duty_name', 'Welcome', 'every', 'week', 'start_time', '09:00',
            'from_date', to_char(pg_temp.sunday(0) + 800, 'YYYY-MM-DD'),
            'until_date', to_char(pg_temp.sunday(0) + 801, 'YYYY-MM-DD'),
            'positions', jsonb_build_array('Door'))) -> 'field_errors',
  '{"from_date": "out_of_range"}'::jsonb, 'a first date more than two years ahead is a field error');

-- Cancel this and future over drafts: no notices, planned people cleared.
create temp table gen5 as select pg_temp.duties(6, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.e(), 'duty_name', 'Usher rota', 'every', 'week', 'start_time', '09:00',
  'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'until_date', to_char(pg_temp.sunday(1), 'YYYY-MM-DD'),
  'positions', jsonb_build_array('Door'))) as r;
select pg_temp.duties(6, 'duties.assign_slot', 1, jsonb_build_object('slot_id',
  (select s.slot_id from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
    where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen5) order by o.series_date limit 1),
  'member_id', pg_temp.mid(9)));
create temp table can5 as select pg_temp.duties(6, 'duties.cancel_series', 1, jsonb_build_object(
  'series_id', (select r #>> '{data,series_id}' from gen5),
  'from_occurrence_id', (select o.occurrence_id from app.duties_occurrences o
                          where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen5)
                          order by o.series_date limit 1))) as r;
select is((select (r -> 'data') - 'series_id' - 'from_occurrence_id' - 'revision' from can5),
  '{"occurrences": 2, "assignments_cancelled": 0, "notices_queued": 0}'::jsonb,
  'cancelling drafts this and future cancels both without a notice');
select is((select count(*)::int || '|' || count(s.draft_member_id)::int from app.duties_occurrences o
             join app.duties_slots s using (occurrence_id)
            where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen5) and o.occurrence_state = 'cancelled'),
  '2|0', 'and a cancelled draft keeps no planned person');

-- Deletion ------------------------------------------------------------------------------------------
create temp table gen4 as select pg_temp.duties(3, 'duties.create_series', null, pg_temp.series(jsonb_build_object(
  'duty_name', 'Youth service', 'until_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'start_time', '15:00',
  'positions', jsonb_build_array('Leader')))) as r;
select pg_temp.duties(3, 'duties.assign_slot',
  (select o.revision from app.duties_occurrences o where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen4)),
  jsonb_build_object('slot_id', (select s.slot_id from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
                                   where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen4)), 'member_id', pg_temp.mid(5)));
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(5), pg_temp.u(5), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'erasing a planned assignee leaves nothing of them in Duties');
select is((select count(*)::int from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
            where o.series_id = (select (r #>> '{data,series_id}')::uuid from gen4) and s.draft_member_id is null), 1,
  'their planned position is unassigned');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(3), pg_temp.u(3), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'erasing a series creator anonymises the series');
select is((select count(*)::int from app.duties_series where created_by_member = '00000000-0000-0000-0000-000000000000'), 2,
  'the deputy''s series keep the facts with the nil UUID');

-- Gates: production without Q4 closes the rota; with Q4 synthetic departments are hidden -----------------
select app.platform_set_environment('production', 'pgtap 4.3');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.3 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.3 production check', 'pgtap');
select is(pg_temp.duties(1, 'duties.create_series', null, pg_temp.series()) ->> 'code', 'unavailable',
  'with Q4 closed (production) series cannot be created');
select is(split_part(pg_temp.read(1, 'select api.duties_rota()'), '|', 2), 'unavailable',
  'nor the rota read');
select app.policy_approve('q4_personal_data', '{}'::jsonb, 'pgtap', 'pgtap 4.3 production check');
select is(pg_temp.duties(1, 'duties.create_series', null, pg_temp.series()) ->> 'code', 'unavailable',
  'with Q4 open but Q2 (church time) unapproved in production, generation fails closed');
select is(jsonb_array_length(pg_temp.readj(1, 'select api.duties_rota()') -> 'departments'), 0,
  'in production the synthetic departments and their rotas are hidden');

select * from finish();
rollback;
