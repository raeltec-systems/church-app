-- You're on (story 5.5; epic 5 C6). A member reads which published parts are theirs, answers them
-- through the Duties response commands (a stale answer is refused), and a cell's leader or assistant
-- records an attributed direct confirmation for a member without a login (the 5.5 Duties contract
-- change), distinct from the member's own acceptance; nobody else may. HTTP evidence:
-- tools/identity-e2e/cells-youre-on.mjs. Every account, phone and name here is SYNTHETIC
-- (fictional range +1 202 555 0181-0192).
begin;
select plan(20);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000055' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000055' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (80 + n)::text $$;
create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.cmd(p_claims jsonb, p_fn text, p_command text, p_expected bigint,
                            p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb language plpgsql as $$
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
create function pg_temp.cells(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$
  select pg_temp.cmd(p_claims, 'api.cells_command', p_command, p_expected, p_payload)
$$;
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.duties_command', p_command, p_expected, p_payload)
$$;
create function pg_temp.read(p_claims jsonb, p_sql text) returns text language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
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
create function pg_temp.readj(p_claims jsonb, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(p_claims, p_sql), 4)::jsonb $$;

-- Fixtures. 1 Admin, 2 leader of Shikoswe, 3 assistant of Shikoswe, 4 member of Shikoswe,
-- 5 leader of Estates, 6 Pastor, 7 an accountless member of Shikoswe, 8 member of Estates,
-- 9 leader of the department, 10 member of Shikoswe and of the department.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);

-- Environment, members, cells, roles, a department ---------------------------------------------------
select app.platform_set_environment('local', 'pgtap 5.5');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.5 Member ' || n, 'pgtap 5.5') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.5 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.5 Shikoswe Cell", "signup_label": "SYNTHETIC 5.5 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.5 Estates Cell", "signup_label": "SYNTHETIC 5.5 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.5 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
select pg_temp.grant_scope(2, 'cell_leader', pg_temp.sh());
select pg_temp.grant_scope(3, 'cell_assistant', pg_temp.sh());
select pg_temp.grant_scope(5, 'cell_leader', pg_temp.es());
select pg_temp.grant_scope(9, 'department_leader', pg_temp.d());
create function pg_temp.add(n int) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = pg_temp.d()),
    jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(9);
select pg_temp.add(10);
create function pg_temp.place(p_member int, p_cell uuid) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.cells(pg_temp.c(1), 'cells.request_change',
         coalesce((select revision from app.cells_member_states where member_id = pg_temp.mid(p_member)), 1),
         jsonb_build_object('member_id', pg_temp.mid(p_member), 'cell_id', p_cell,
                            'cell_revision', app.cells_option_revision(p_cell)));
  return pg_temp.cells(pg_temp.c(1), 'cells.confirm_request',
           (select revision from app.cells_member_states where member_id = pg_temp.mid(p_member)),
           jsonb_build_object('request_id', r #>> '{data,open_request,request_id}'));
end;
$$;
select pg_temp.place(4, pg_temp.sh());
select pg_temp.place(7, pg_temp.sh());
select pg_temp.place(10, pg_temp.sh());
select pg_temp.place(8, pg_temp.es());
-- Two days from today in church time, 18:00-19:30.
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule',
  (select revision from app.cells_cells where cell_id = pg_temp.sh()),
  jsonb_build_object('cell_id', pg_temp.sh(),
    'weekday', ((extract(isodow from (now() at time zone 'Africa/Lusaka')::date)::int + 1) % 7) + 1,
    'start_time', '18:00', 'end_time', '19:30', 'venue', 'SYNTHETIC 12 Shikoswe Road'));
create function pg_temp.mt() returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date limit 1 $$;
create function pg_temp.mt2() returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date offset 1 limit 1 $$;
create function pg_temp.at(p_meeting uuid, p_hhmm text) returns timestamptz language sql as $$
  select ((m.starts_at at time zone 'Africa/Lusaka')::date + p_hhmm::time) at time zone 'Africa/Lusaka'
    from app.cells_meetings m where m.meeting_id = p_meeting
$$;

-- A published programme: member 4, accountless member 7, member 10 and an open part ------------------
create temp table cp as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) as r;
create function pg_temp.pid() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp $$;
create function pg_temp.rev() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid() $$;
select pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid(), 'topic', 'SYNTHETIC Rooted in love', 'parts', jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10', 'assignee_member_id', pg_temp.mid(4)),
    jsonb_build_object('label', 'Worship', 'start_time', '18:10', 'end_time', '18:30', 'assignee_member_id', pg_temp.mid(7)),
    jsonb_build_object('label', 'Bible study', 'start_time', '18:30', 'end_time', '19:00', 'assignee_member_id', pg_temp.mid(10)),
    jsonb_build_object('label', 'Closing prayer', 'start_time', '19:00', 'end_time', '19:10'))));
select is(pg_temp.cells(pg_temp.c(2), 'cells.publish_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid())) #>> '{data,state}', 'published', 'setup: the programme is published');
create function pg_temp.asg(n int) returns app.duties_assignments language sql as $$
  select a.* from app.duties_assignments a
    join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
    join app.cells_programme_parts pt on pt.part_id = l.source_id
   where pt.programme_id = pg_temp.pid() and a.member_id = pg_temp.mid(n) and a.assignment_state = 'current'
$$;
create function pg_temp.part(p_position int) returns uuid language sql as $$
  select part_id from app.cells_programme_parts
   where programme_id = pg_temp.pid() and position = p_position and removed_at is null
$$;

-- Yours ----------------------------------------------------------------------------------------------
create temp table mr as select pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) as r;
select is((select jsonb_array_length(r -> 'yours') || '|' || (r #>> '{yours,0,part_id}') from mr),
  '1|' || pg_temp.part(1), 'a member reads which published part is theirs');
select is((select (r #>> '{yours,0,occurrence_id}')::uuid from mr),
  (select s.occurrence_id from app.duties_slots s where s.slot_id = (pg_temp.asg(4)).slot_id),
  'with its Duties occurrence (to find it in My duties)');
select ok((select not (r::text ~ '(response|pending|accepted|declined|note)') from mr),
  'the programme read shows no answer, the reader''s own included (that is My duties)');
select is(pg_temp.readj(pg_temp.c(10), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) #>> '{yours,0,part_id}',
  pg_temp.part(3)::text, 'another member reads only their own part as theirs');

-- My duties: the part with its answer, reporting time and instructions --------------------------------
create temp table md as select a from jsonb_array_elements(
  pg_temp.readj(pg_temp.c(4), 'select api.duties_my_duties()') -> 'assignments') a
  where a ->> 'assignment_id' = (pg_temp.asg(4)).assignment_id::text;
select is((select (a ->> 'owner_kind') || '|' || (a ->> 'response') || '|' || (a ? 'reporting_at') || '|' || (a ? 'instructions') from md),
  'cell|pending|true|true', 'My duties shows the part Awaiting, with reporting time and instructions fields');

-- The member answers through Duties; a stale answer is refused -------------------------------------
create temp table acc as select pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (pg_temp.asg(4)).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(4)).assignment_id, 'response', 'accepted')) as r;
select is((select r #>> '{data,response}' from acc), 'accepted', 'the member accepts their part');
select is(pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (pg_temp.asg(4)).revision - 1,
  jsonb_build_object('assignment_id', (pg_temp.asg(4)).assignment_id, 'response', 'declined')) ->> 'code',
  'conflict', 'an answer to an old revision is refused');
select is(pg_temp.cmd(pg_temp.c(10), 'api.duties_command', 'duties.respond', (pg_temp.asg(10)).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(10)).assignment_id, 'response', 'declined')) #>> '{data,response}',
  'declined', 'another member declines theirs');

-- Leader confirmation for a member without a login (the cell-scope contract change) ------------------
create function pg_temp.confirm(n int, p_member int, p_request uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.duties_command', 'duties.confirm_by_leader', (pg_temp.asg(p_member)).revision,
    jsonb_build_object('assignment_id', (pg_temp.asg(p_member)).assignment_id, 'channel', 'phone',
                       'reason', 'SYNTHETIC said yes on the phone'), p_request)
$$;
select is(pg_temp.confirm(4, 7) ->> 'code', 'not_found', 'a member cannot confirm for someone');
select is(pg_temp.confirm(5, 7) ->> 'code', 'not_found', 'another cell''s leader cannot');
select is(pg_temp.confirm(1, 7) ->> 'code', 'not_found', 'Admin alone cannot');
select is(pg_temp.confirm(6, 7) ->> 'code', 'not_found', 'Pastor oversight cannot');
select is(pg_temp.confirm(9, 7) ->> 'code', 'not_found', 'a department leader cannot confirm a cell part');
create temp table cf as select pg_temp.confirm(2, 7, '00000000-0000-4000-a000-000000005501') as r;
select is((select (r #>> '{data,response}') || '|' || (r #>> '{data,provenance}') from cf), 'accepted|leader',
  'the cell''s leader records the confirmation by phone');
select is((select a.response_provenance || '|' || a.confirmed_channel || '|' || (a.responded_by_member = pg_temp.mid(2))
             from app.duties_assignments a where a.assignment_id = (pg_temp.asg(7)).assignment_id),
  'leader|phone|true', 'attributed to the leader, distinct from a member''s own acceptance');
select is(pg_temp.cmd(pg_temp.c(2), 'api.duties_command', 'duties.confirm_by_leader',
  (select (r #>> '{data,revision}')::bigint - 1 from cf),
  jsonb_build_object('assignment_id', (pg_temp.asg(7)).assignment_id, 'channel', 'phone',
                     'reason', 'SYNTHETIC said yes on the phone'),
  '00000000-0000-4000-a000-000000005501') -> 'data', (select r -> 'data' from cf),
  'a replay answers the stored result (the cell scope is rechecked)');
select is(pg_temp.confirm(3, 7) #>> '{field_errors,assignment_id}', 'responded',
  'a second confirmation is refused as already answered');
select is((select p #>> '{positions,0,assignment,response}' || '|' || (p #>> '{positions,0,assignment,response_provenance}')
             from jsonb_array_elements(
               pg_temp.readj(pg_temp.c(3), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'duties') p
            where p ->> 'part_id' = pg_temp.part(2)::text),
  'accepted|leader', 'the assistant''s plan shows Confirmed by leader');
select is(pg_temp.cmd(pg_temp.c(2), 'api.duties_command', 'duties.record_contact_attempt', (pg_temp.asg(10)).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(10)).assignment_id, 'channel', 'phone', 'outcome', 'no_answer',
                     'next_follow_up_at', app.cmd_utc(now() + interval '1 hour'))) ->> 'code',
  'not_found', 'contact attempts stay department-only');

select * from finish();
rollback;
