-- Meeting records (story 5.8; epic 5 C8). Once a meeting has started, the cell's leader or assistant
-- records whether it was held and who actually led each part; corrections need a reason and keep the
-- earlier value and actor; the plan, duty responses and outcomes are untouched; a cancelled meeting
-- cannot be held; another cell's leader is refused. HTTP evidence: tools/identity-e2e/cells-meeting-records.mjs.
-- SYNTHETIC data only (fictional range +1 202 555 0181-0190).
begin;
select plan(53);
create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000058' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000058' || lpad(n::text, 2, '0'))::uuid $$;
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
select app.platform_set_environment('local', 'pgtap 5.8');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.8 Member ' || n, 'pgtap 5.8') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.8 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.8 Shikoswe Cell", "signup_label": "SYNTHETIC 5.8 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.8 Estates Cell", "signup_label": "SYNTHETIC 5.8 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.8 Ushers"}') as r;
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

-- A published programme: member 4 (Opening prayer) accepts; member 10 (Bible study) has not answered
create temp table cp as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) as r;
create function pg_temp.pid() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp $$;
create function pg_temp.rev() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid() $$;
select pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid(), 'parts', jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10', 'assignee_member_id', pg_temp.mid(4)),
    jsonb_build_object('label', 'Bible study', 'start_time', '18:10', 'end_time', '19:00', 'assignee_member_id', pg_temp.mid(10)))));
select is(pg_temp.cells(pg_temp.c(2), 'cells.publish_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid())) #>> '{data,state}', 'published', 'setup: published');
create function pg_temp.part(p_label text) returns uuid language sql as $$
  select part_id from app.cells_programme_parts where programme_id = pg_temp.pid() and label = p_label and removed_at is null
$$;
create function pg_temp.asg(n int) returns app.duties_assignments language sql as $$
  select a.* from app.duties_assignments a
    join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
    join app.cells_programme_parts pt on pt.part_id = l.source_id
   where pt.programme_id = pg_temp.pid() and a.member_id = pg_temp.mid(n) and a.assignment_state = 'current'
$$;
select is(pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (pg_temp.asg(4)).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(4)).assignment_id, 'response', 'accepted')) #>> '{data,response}',
  'accepted', 'setup: member 4 accepts their part');
create temp table before_plan as
  select (pg_temp.asg(4)).revision as r4, (pg_temp.asg(4)).response as a4,
         (pg_temp.asg(10)).revision as r10, (pg_temp.asg(10)).response as a10,
         (select jsonb_agg(jsonb_build_array(label, assignee_member_id) order by position)
            from app.cells_programme_parts where programme_id = pg_temp.pid()) as parts;

create function pg_temp.held(n int, p_meeting uuid, p_held boolean) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.record_meeting_held', null,
    jsonb_build_object('meeting_id', p_meeting, 'held', p_held))
$$;
create function pg_temp.rrev() returns bigint language sql as
$$ select revision from app.cells_meeting_records where meeting_id = pg_temp.mt() $$;
create function pg_temp.leaders(n int, p_expected bigint, p_parts jsonb) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.record_actual_leaders', p_expected,
    jsonb_build_object('meeting_id', pg_temp.mt(), 'parts', p_parts))
$$;
create function pg_temp.correct(n int, p_held boolean, p_reason text) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.correct_meeting_held', pg_temp.rrev(),
    jsonb_strip_nulls(jsonb_build_object('meeting_id', pg_temp.mt(), 'held', p_held, 'reason', p_reason)))
$$;

-- Before the meeting starts -----------------------------------------------------------------------------
select is(pg_temp.held(2, pg_temp.mt(), true) #>> '{field_errors,meeting_id}', 'not_started',
  'a meeting ahead cannot be recorded');

-- The meeting has happened (moved three days back, its programme with it) ------------------------------
update app.cells_meetings
   set starts_at = starts_at - interval '3 days', ends_at = ends_at - interval '3 days',
       nominal_starts_at = nominal_starts_at - interval '3 days', nominal_ends_at = nominal_ends_at - interval '3 days'
 where meeting_id = pg_temp.mt();
-- Time passing: the cell's members joined before that meeting (story 5.12: actual leaders must have
-- been members when it started).
update app.cells_memberships set started_at = started_at - interval '60 days' where ended_at is null;

select is(pg_temp.held(5, pg_temp.mt(), true) ->> 'code', 'forbidden', 'another cell''s leader is refused');
select is(pg_temp.held(1, pg_temp.mt(), true) ->> 'code', 'forbidden', 'Admin alone does not record a cell meeting');
select is(pg_temp.held(4, pg_temp.mt(), true) ->> 'code', 'forbidden', 'a member does not record it');
select is(pg_temp.cells(pg_temp.c(2), 'cells.record_meeting_held', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) #>> '{field_errors,held}', 'required', 'held is required');
create temp table h1 as select pg_temp.held(2, pg_temp.mt(), true) as r;
select is((select (r #>> '{data,held}') || '|' || (r ->> 'revision') from h1), 'true|1', 'the leader records it held');
select is(pg_temp.held(3, pg_temp.mt(), true) #>> '{field_errors,meeting_id}', 'recorded',
  'a second record is refused (it is corrected instead)');
select is((select count(*)::int from app.cells_meeting_record_history
            where meeting_id = pg_temp.mt() and actor_member_id = pg_temp.mid(2) and held and reason is null), 1,
  'the record is attributed to the leader');

-- Actual leaders ------------------------------------------------------------------------------------------
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', jsonb_build_object('member_id', pg_temp.mid(4))),
    jsonb_build_object('part_id', pg_temp.part('Bible study'), 'leader', jsonb_build_object('member_id', pg_temp.mid(7)))))
  #>> '{data,changed}', '2', 'the leader records who led each part (member 7 stood in for member 10)');
create temp table sr1 as select pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) as r;
select is((select string_agg((a ->> 'display_name') || ':' || (a ->> 'substitute'), ',' order by a ->> 'display_name')
             from sr1, jsonb_array_elements(r #> '{record,actual}') a),
  'SYNTHETIC 5.8 Accountless:true,SYNTHETIC 5.8 Member 4:false', 'the staff read shows the substitution');
select is((select r ->> 'status' from sr1) || '|' || (select (r ->> 'can_record') from sr1), 'held|true',
  'status held; the leader may still record');
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', jsonb_build_object('member_id', pg_temp.mid(4)))))
  #>> '{data,changed}', '0', 'the same value again adds nothing');
select is(pg_temp.leaders(3, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Bible study'), 'leader', jsonb_build_object('name', 'SYNTHETIC Guest Pastor'))))
  #>> '{field_errors,parts.0.reason}', 'required', 'a correction needs a reason');
select is(pg_temp.leaders(3, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Bible study'), 'leader', jsonb_build_object('name', 'SYNTHETIC Guest Pastor'),
                       'reason', 'SYNTHETIC it was the visiting pastor')))
  #>> '{data,changed}', '1', 'the assistant corrects it with a reason');
select is((select string_agg(leader_kind || ':' || (superseded_at is null)::text || ':' ||
                             (recorded_by_member = pg_temp.mid(case when superseded_at is null then 3 else 2 end))::text,
                             ',' order by recorded_at, superseded_at nulls last)
             from app.cells_actual_leaders where part_id = pg_temp.part('Bible study')),
  'member:false:true,guest:true:true', 'the earlier record and its actor are kept, superseded');
create temp table sr2 as select pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) as r;
select is((select (a ->> 'guest_name') || '|' || (a ->> 'reason') || '|' || (a #>> '{earlier,0,display_name}')
             from sr2, jsonb_array_elements(r #> '{record,actual}') a where a ->> 'part_id' = pg_temp.part('Bible study')::text),
  'SYNTHETIC Guest Pastor|SYNTHETIC it was the visiting pastor|SYNTHETIC 5.8 Accountless',
  'the read shows the correction, its reason and the earlier value');
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', jsonb_build_object('member_id', pg_temp.mid(8)),
                       'reason', 'SYNTHETIC test')))
  #>> '{field_errors,parts.0.member_id}', 'not_in_cell', 'a member of another cell is named as a guest instead');
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', gen_random_uuid(), 'leader', null)))
  #>> '{field_errors,parts.0.part_id}', 'not_found', 'only the meeting''s own parts');
select is(pg_temp.leaders(2, pg_temp.rrev() - 1, jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', null, 'reason', 'SYNTHETIC test')))
  ->> 'code', 'conflict', 'a stale revision is a conflict');
select is(pg_temp.leaders(5, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', null, 'reason', 'SYNTHETIC test')))
  ->> 'code', 'forbidden', 'another cell''s leader cannot record leaders');

-- Review gaps: an ex-member, a batch with one bad part --------------------------------------------------
with x as (insert into app.identity_members (display_name, membership_state, is_synthetic)
           values ('SYNTHETIC 5.8 Moved Away', 'approved', true) returning member_id)
insert into m select 11, member_id from x;
select pg_temp.place(11, pg_temp.sh());
select pg_temp.place(11, pg_temp.es());
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', jsonb_build_object('member_id', pg_temp.mid(11)),
                       'reason', 'SYNTHETIC test')))
  #>> '{field_errors,parts.0.member_id}', 'not_in_cell', 'a member who left the cell is not a member of it');
create temp table before_bad as select count(*) as n, pg_temp.rrev() as rev from app.cells_actual_leaders where meeting_id = pg_temp.mt();
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', null, 'reason', 'SYNTHETIC test'),
    jsonb_build_object('part_id', gen_random_uuid(), 'leader', null)))
  #>> '{field_errors,parts.1.part_id}', 'not_found', 'one bad part refuses the batch');
select is((select count(*) from app.cells_actual_leaders where meeting_id = pg_temp.mt()) = (select n from before_bad)
          and pg_temp.rrev() = (select rev from before_bad), true, 'and nothing of it is written');

-- The plan and the duties are untouched --------------------------------------------------------------------
select is((select (pg_temp.asg(4)).revision = r4 and (pg_temp.asg(4)).response = a4
              and (pg_temp.asg(10)).revision = r10 and (pg_temp.asg(10)).response = a10 from before_plan), true,
  'no duty response changes (member 4 still Accepted, member 10 still Awaiting)');
select is((select jsonb_agg(jsonb_build_array(label, assignee_member_id) order by position)
             from app.cells_programme_parts where programme_id = pg_temp.pid()) = (select parts from before_plan), true,
  'the plan keeps its planned people');
select is((select count(*)::int from app.duties_outcomes o
            where o.assignment_id in ((pg_temp.asg(4)).assignment_id, (pg_temp.asg(10)).assignment_id)), 0,
  'no duty outcome is recorded');

-- Corrections of held ---------------------------------------------------------------------------------------
select is(pg_temp.correct(2, false, null) #>> '{field_errors,reason}', 'required', 'a held correction needs a reason');
select is(pg_temp.correct(2, true, 'SYNTHETIC test') #>> '{field_errors,held}', 'unchanged', 'and a different value');
select is(pg_temp.correct(2, false, 'SYNTHETIC we met for prayer only') #>> '{data,held}', 'false',
  'the leader corrects it to not held');
select is((select string_agg(held::text || ':' || coalesce(reason, '-'), ',' order by history_id)
             from app.cells_meeting_record_history where meeting_id = pg_temp.mt()),
  'true:-,false:SYNTHETIC we met for prayer only', 'the history keeps the earlier value');
select is(pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', null, 'reason', 'SYNTHETIC test')))
  #>> '{field_errors,held}', 'not_held', 'no actual leaders for a meeting not held');
select is((app.cells_meeting_reference(pg_temp.mt()) ->> 'status') || '|' ||
          jsonb_array_length(app.cells_meeting_reference(pg_temp.mt()) -> 'actual_leaders'), 'not_held|0',
  'the canonical reference: not held, no leaders');
select is(pg_temp.correct(3, true, 'SYNTHETIC it was held after all') #>> '{data,held}', 'true', 'and back to held');
select is((select string_agg((a ->> 'label') || ':' || (a ->> 'kind') || ':' || (a ->> 'substitute'), ',' order by a ->> 'label')
             from jsonb_array_elements(app.cells_meeting_reference(pg_temp.mt()) -> 'actual_leaders') a)
          || '|' || (app.cells_meeting_reference(pg_temp.mt()) ->> 'status'),
  'Bible study:guest:true,Opening prayer:member:false|held',
  'the canonical reference: held, with the actual leaders (not the planned ones)');
select is(app.cells_meeting_reference(pg_temp.mt()) ? 'reason', false, 'the reference carries no reasons');

select is((select pg_temp.rrev()) + 1 = (select (pg_temp.leaders(2, pg_temp.rrev(), jsonb_build_array(
    jsonb_build_object('part_id', pg_temp.part('Opening prayer'), 'leader', jsonb_build_object('member_id', pg_temp.mid(4))),
    jsonb_build_object('part_id', pg_temp.part('Bible study'), 'leader', null, 'reason', 'SYNTHETIC we skipped it')))
    ->> 'revision')::bigint), true, 'one identical and one changed part: the revision moves once');

-- A cancelled meeting cannot be held ----------------------------------------------------------------------
select pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt2()), jsonb_build_object('meeting_id', pg_temp.mt2()));
update app.cells_meetings
   set starts_at = starts_at - interval '14 days', ends_at = ends_at - interval '14 days',
       nominal_starts_at = nominal_starts_at - interval '14 days', nominal_ends_at = nominal_ends_at - interval '14 days'
 where meeting_id = pg_temp.mt2();
select is(pg_temp.held(2, pg_temp.mt2(), true) #>> '{field_errors,meeting_id}', 'cancelled',
  'a cancelled meeting cannot be marked held');

-- Who reads -------------------------------------------------------------------------------------------------
select isnt(pg_temp.readj(pg_temp.c(6), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'record', 'null'::jsonb,
  'Pastor oversight reads the record');
select is(pg_temp.readj(pg_temp.c(1), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'record', 'null'::jsonb,
  'an Admin-only reader does not');
select is(pg_temp.read(pg_temp.c(5), format('select api.cells_programme(%L)', pg_temp.mt())) like 'PT403%', true,
  'another cell''s leader reads nothing');
select is((select m ->> 'status' from jsonb_array_elements(
             pg_temp.readj(pg_temp.c(2), 'select api.cells_meetings()') #> '{cells,0,recent}') m
            where m ->> 'meeting_id' = pg_temp.mt()::text), 'held', 'Cell meetings lists it as held in the last four weeks');
select is(pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) ? 'record', false,
  'the member read is unchanged');
select is(pg_temp.read(pg_temp.c(2), 'select to_jsonb(count(*)) from app.cells_actual_leaders') like '42501%', true,
  'the tables are not readable directly');

select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(3)),
  jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'cell_assistant', 'scope_id', pg_temp.sh()));
select is(pg_temp.correct(3, false, 'SYNTHETIC test') ->> 'code', 'forbidden', 'an ex-assistant is refused');

-- Deletion ---------------------------------------------------------------------------------------------------
select is((app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(7), 'phase', 'erase')) ->> 'remaining'), '0',
  'deleting the member who stood in leaves nothing of them');
select is((app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(3), 'account_id', pg_temp.u(3),
                                                     'phase', 'erase')) ->> 'remaining'), '0',
  'deleting the assistant who corrected it leaves nothing of them');
select is((select count(*)::int from app.cells_actual_leaders where part_id = pg_temp.part('Bible study')), 3,
  'the records stay as anonymous facts');
select is((select count(*)::int from app.cells_actual_leaders where reason = 'SYNTHETIC it was the visiting pastor')
          + (select count(*)::int from app.cells_meeting_record_history where reason = 'SYNTHETIC it was held after all'), 0,
  'the reasons the assistant wrote go with them');
select is((select count(*)::int from app.cells_meeting_record_history where reason = 'SYNTHETIC we met for prayer only'), 1,
  'the leader''s own reasons stay');
select is((app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(4), 'phase', 'erase')) ->> 'remaining'), '0',
  'deleting the member who led as planned');
select is((select (a ->> 'removed') || '|' || coalesce(a ->> 'member_id', 'null')
             from jsonb_array_elements(app.cells_meeting_reference(pg_temp.mt()) -> 'actual_leaders') a
            where a ->> 'part_id' = pg_temp.part('Opening prayer')::text), 'true|null',
  'the reference shows a removed person, never the nil id');

select * from finish();
rollback;
