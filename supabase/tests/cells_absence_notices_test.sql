-- Cannot attend notices (story 5.7; epic 5 C7). A confirmed member sends, changes and withdraws a
-- notice for one meeting with an optional note; the cell's leader and assistant are told and read
-- it with the parts its sender holds; no duty response changes and no attendance record exists;
-- nobody else reads it. HTTP evidence: tools/identity-e2e/cells-absence.mjs. SYNTHETIC data only
-- (fictional range +1 202 555 0181-0192).
begin;
select plan(26);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000057' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000057' || lpad(n::text, 2, '0'))::uuid $$;
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
select app.platform_set_environment('local', 'pgtap 5.7');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.7 Member ' || n, 'pgtap 5.7') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.7 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.7 Shikoswe Cell", "signup_label": "SYNTHETIC 5.7 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.7 Estates Cell", "signup_label": "SYNTHETIC 5.7 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.7 Ushers"}') as r;
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

-- A published programme: member 4 has a part and accepts it -------------------------------------------
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
create function pg_temp.asg(n int) returns app.duties_assignments language sql as $$
  select a.* from app.duties_assignments a
    join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
    join app.cells_programme_parts pt on pt.part_id = l.source_id
   where pt.programme_id = pg_temp.pid() and a.member_id = pg_temp.mid(n) and a.assignment_state = 'current'
$$;
select is(pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (pg_temp.asg(4)).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(4)).assignment_id, 'response', 'accepted')) #>> '{data,response}',
  'accepted', 'setup: member 4 accepts their part');
create temp table before4 as select (pg_temp.asg(4)).revision as rev, (pg_temp.asg(4)).response as response;
create temp table before10 as select (pg_temp.asg(10)).revision as rev, (pg_temp.asg(10)).response as response;

-- Send --------------------------------------------------------------------------------------------------
create function pg_temp.send(n int, p_expected bigint, p_note text) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.send_cannot_attend', p_expected,
    jsonb_strip_nulls(jsonb_build_object('meeting_id', pg_temp.mt(), 'note', p_note)))
$$;
select is(pg_temp.send(8, null, null) ->> 'code', 'not_found', 'a member of another cell cannot send one');
create temp table s1 as select pg_temp.send(4, null, 'SYNTHETIC travelling for work') as r;
select is((select (r #>> '{data,state}') || '|' || (r ->> 'revision') || '|' || (r #>> '{data,notified}') from s1),
  'open|1|2', 'member 4 sends a notice; the leader and the assistant are told');
create function pg_temp.nid() returns uuid language sql as $$ select (r #>> '{data,notice_id}')::uuid from s1 $$;
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'cells_absence_notice' and j.source_id = pg_temp.nid()
              and j.reminder_kind = 'cells_absence_sent' and j.job_state = 'pending'
              and j.recipient_member_id in (pg_temp.mid(2), pg_temp.mid(3))), 2,
  'one inbox notice each for the leader and the assistant');
select is(pg_temp.send(4, null, null) #>> '{field_errors,meeting_id}', 'exists', 'one open notice per meeting');
select is(pg_temp.send(10, null, null) #>> '{data,state}', 'open', 'member 10 sends one without a note');

-- The duty answers are untouched; there is no attendance record ------------------------------------------
select is((select (pg_temp.asg(4)).revision = rev and (pg_temp.asg(4)).response = response from before4)
          and (select (pg_temp.asg(10)).revision = rev and (pg_temp.asg(10)).response = response from before10), true,
  'a notice changes no duty response (member 4 still Accepted, member 10 still Awaiting)');
select is((select count(*)::int from information_schema.tables
            where table_schema = 'app' and table_name like '%attendance%'), 0,
  'there is no attendance table: a notice is never attendance');

-- Who reads it ----------------------------------------------------------------------------------------------
create temp table sr as select pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) as r;
select is((select jsonb_array_length(r -> 'absences') from sr), 2, 'the leader reads both notices');
select is((select a ->> 'note' from sr, jsonb_array_elements(r -> 'absences') a where a ->> 'member_id' = pg_temp.mid(4)::text),
  'SYNTHETIC travelling for work', 'with the note');
select is((select jsonb_array_length(a -> 'part_ids') from sr, jsonb_array_elements(r -> 'absences') a
            where a ->> 'member_id' = pg_temp.mid(4)::text), 1, 'and the part member 4 holds (a coverage warning)');
select is(pg_temp.readj(pg_temp.c(6), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'absences',
  '[]'::jsonb, 'Pastor oversight does not read notices');
select is(pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) #>> '{my_absence,note}',
  'SYNTHETIC travelling for work', 'the member reads their own notice');
select ok((select not (r::text like '%travelling%') from (select pg_temp.readj(pg_temp.c(10),
            format('select api.cells_meeting_programme(%L)', pg_temp.mt())) as r) x),
  'another member never reads someone else''s notice or note');

-- Change and withdraw -----------------------------------------------------------------------------------------
create function pg_temp.change(n int, p_expected bigint, p_note text) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.change_cannot_attend', p_expected,
    jsonb_strip_nulls(jsonb_build_object('notice_id', pg_temp.nid(), 'note', p_note)))
$$;
select is(pg_temp.change(4, 1, 'SYNTHETIC back late') #>> '{data,note}', 'SYNTHETIC back late', 'the member changes the note');
select is(pg_temp.change(4, 1, 'again') ->> 'code', 'conflict', 'a stale change is a conflict');
select is(pg_temp.change(10, 2, 'not mine') ->> 'code', 'not_found', 'another member cannot change it');
select is(pg_temp.cells(pg_temp.c(10), 'cells.withdraw_cannot_attend', 2, jsonb_build_object('notice_id', pg_temp.nid())) ->> 'code',
  'not_found', 'another member cannot withdraw it');
create temp table wd as select pg_temp.cells(pg_temp.c(4), 'cells.withdraw_cannot_attend', 2,
  jsonb_build_object('notice_id', pg_temp.nid())) as r;
select is((select (r #>> '{data,state}') || '|' || (r #>> '{data,notified}') from wd), 'withdrawn|2',
  'the member withdraws it; the leaders are told');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_id = pg_temp.nid() and j.reminder_kind = 'cells_absence_sent' and j.job_state = 'pending'), 0,
  'no Cannot attend notice is left waiting for the leaders');
select is(pg_temp.cells(pg_temp.c(4), 'cells.withdraw_cannot_attend', 3, jsonb_build_object('notice_id', pg_temp.nid())) #>> '{field_errors,notice_id}',
  'withdrawn', 'a second withdrawal is refused');
select is((select count(*)::int from jsonb_array_elements(
            pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'absences') a
            where a ->> 'member_id' = pg_temp.mid(4)::text), 0, 'the leader no longer sees it');
select is(pg_temp.send(4, null, null) #>> '{data,state}', 'open', 'the member can send a new one');

-- Audit and deletion -----------------------------------------------------------------------------------------
select ok((select not (coalesce(string_agg(a::text, ' '), '') ~ '(travelling|back late)') from app.cells_absence_audit a),
  'the audit never holds a note');
select app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(10), 'phase', 'erase'));
select is((select count(*)::int from app.cells_absence_notices where member_id = pg_temp.mid(10)), 0,
  'deletion anonymises the member''s notices');

select * from finish();
rollback;
