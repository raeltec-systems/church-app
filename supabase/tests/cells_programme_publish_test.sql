-- Publishing programmes (story 5.4; epic 5 C4; AD-2, AD-5, AD-6) and the 5.3 review fixes. A
-- published programme reaches Duties in the command's own transaction: one cell-owned slot per
-- part (assignee asked, Awaiting; unassigned open), or a display link to a department position
-- that stays unchanged and owned by its department; a republish duplicates nothing; members of the
-- cell read a separate safe projection that equals the staff preview and holds no response, note
-- or history. HTTP evidence: tools/identity-e2e/cells-programme-publish.mjs. Every account, phone
-- and name here is SYNTHETIC (fictional range +1 202 555 0181-0192).
begin;
select plan(48);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000054' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000054' || lpad(n::text, 2, '0'))::uuid $$;
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

-- Structure -------------------------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.cells_programme_projections', p)),
  'no client role has any privilege on the projections');
select ok(has_function_privilege('authenticated', 'api.cells_meeting_programme(uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_meeting_programme(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_publish_programme(uuid, bigint, jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.duties_owner_linkable(jsonb)', 'EXECUTE'),
  'only the member read is client-callable; the Duties read is not');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((app.cells_free_text(to_jsonb(E'Line one\r\nLine two'::text), 100, true)).value, E'Line one\nLine two',
  '5.3 fix 9: Windows line endings in study notes are normalised');

-- Environment, members, cells, roles, a department ---------------------------------------------------
select app.platform_set_environment('local', 'pgtap 5.4');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.4 Member ' || n, 'pgtap 5.4') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.4 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.4 Shikoswe Cell", "signup_label": "SYNTHETIC 5.4 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.4 Estates Cell", "signup_label": "SYNTHETIC 5.4 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.4 Ushers"}') as r;
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
-- The department's duty at the meeting's time, member 10 on it (the ushers' evening position).
create temp table dq as select pg_temp.duties(9, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'member_id', pg_temp.mid(10), 'duty_name', 'SYNTHETIC Evening ushering',
  'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '18:00')),
  'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '19:30')),
  'instructions', 'SYNTHETIC department private instructions')) as r;
create function pg_temp.dslot() returns uuid language sql as $$
  select s.slot_id from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
   where o.department_id = pg_temp.d() order by s.position_no limit 1
$$;
create temp table dbefore as
  select o.revision as occ_rev, o.department_id, o.cell_id,
         (select count(*) from app.duties_assignments a where a.slot_id = pg_temp.dslot()) as assignments
    from app.duties_occurrences o where o.department_id = pg_temp.d();

-- Draft with an assigned, an unassigned and a department-linked part -------------------------------
create temp table cp as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) as r;
create function pg_temp.pid() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp $$;
create function pg_temp.rev() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid() $$;
create function pg_temp.save(n int, p_parts jsonb) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.save_programme', pg_temp.rev(),
    jsonb_build_object('programme_id', pg_temp.pid(), 'topic', 'SYNTHETIC Rooted in love',
                       'scripture', 'Ephesians 3:14-21', 'study_notes', 'SYNTHETIC private study notes',
                       'parts', p_parts))
$$;
select is((pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) #>> '{linkable,0,slot_id}')::uuid,
  pg_temp.dslot(), 'the leader''s read offers the department position at the meeting''s time');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Ushering', 'start_time', '18:00', 'end_time', '18:10',
                     'assignee_member_id', pg_temp.mid(4), 'linked_slot_id', pg_temp.dslot()))) -> 'field_errors',
  '{"parts.0": "assignee_and_link"}'::jsonb, 'a part shows a department position or has a person, not both');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Ushering', 'start_time', '18:00', 'end_time', '18:10',
                     'linked_slot_id', gen_random_uuid()))) -> 'field_errors',
  '{"parts.0": "link_unavailable"}'::jsonb, 'an unknown department position is refused');
create function pg_temp.draft() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10', 'assignee_member_id', pg_temp.mid(4)),
    jsonb_build_object('label', 'Worship', 'start_time', '18:10', 'end_time', '18:30'),
    jsonb_build_object('label', 'Bible study', 'start_time', '18:30', 'end_time', '19:00', 'assignee_member_id', pg_temp.mid(10)),
    jsonb_build_object('label', 'Ushering', 'start_time', '19:00', 'end_time', '19:30', 'linked_slot_id', pg_temp.dslot()))
$$;
create temp table sv as select pg_temp.save(2, pg_temp.draft()) as r;
select is((select r #>> '{data,parts,3,linked_label}' || '|' || (r #>> '{data,gaps}') from sv),
  'SYNTHETIC 5.4 Ushers: SYNTHETIC Evening ushering|1',
  'the linked part names its department duty; only the unassigned part is a gap');

-- Publish: who may ----------------------------------------------------------------------------------
create function pg_temp.publish(n int, p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.publish_programme', pg_temp.rev(),
    jsonb_build_object('programme_id', pg_temp.pid()) || p_extra)
$$;
select is(pg_temp.publish(4) ->> 'code', 'forbidden', 'a member cannot publish');
select is(pg_temp.publish(1) ->> 'code', 'forbidden', 'Admin alone cannot publish');
select is(pg_temp.publish(6) ->> 'code', 'forbidden', 'Pastor oversight cannot publish');
select is(pg_temp.publish(5) ->> 'code', 'forbidden', 'another cell''s leader cannot publish');
select is((select count(*)::int from app.duties_part_links l
            join app.cells_programme_parts pt on pt.part_id = l.source_id
           where pt.programme_id = pg_temp.pid()), 0, 'refused publishes left nothing in Duties');

-- Publish: an overlap is answered on its part; a reason keeps it ----------------------------------
select is(pg_temp.publish(2) -> 'field_errors',
  '{"parts.2.member_id": "overlap", "parts.2.override_reason": "required"}'::jsonb,
  'the assignee''s overlap with their department duty is refused on that part');
select is((select programme_state from app.cells_programmes where programme_id = pg_temp.pid())
          || '|' || (select count(*) from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
                      where pt.programme_id = pg_temp.pid()), 'draft|0',
  'and nothing was published, nothing left in Duties');
create temp table pb as select pg_temp.publish(2, '{"override_reason": "SYNTHETIC leads study after ushering starts"}') as r;
select is((select (r #>> '{data,state}') || '|' || (r ->> 'revision') || '|' || jsonb_array_length(r #> '{data,duties}') from pb),
  'published|' || pg_temp.rev() || '|4', 'the leader publishes with a reason: four parts reach Duties');

-- Duties: one slot per owned part, Awaiting, the department duty unchanged ---------------------------
create temp table owned as
  select pt.position, l.slot_id, s.occurrence_id, o.cell_id, o.department_id,
         (select a.member_id from app.duties_assignments a where a.slot_id = l.slot_id and a.assignment_state = 'current') as member_id,
         (select a.response from app.duties_assignments a where a.slot_id = l.slot_id and a.assignment_state = 'current') as response
    from app.cells_programme_parts pt
    join app.duties_part_links l on l.source_type = 'cells_programme_part' and l.source_id = pt.part_id
                                and l.link_kind = 'owned' and l.ended_at is null
    join app.duties_slots s on s.slot_id = l.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where pt.programme_id = pg_temp.pid() and pt.removed_at is null;
select is((select string_agg(position || ':' || coalesce(response, 'open'), ',' order by position) from owned),
  '1:pending,2:open,3:pending', 'one cell-owned slot per part: assignees Awaiting, the unassigned part open');
select ok((select bool_and(cell_id = pg_temp.sh() and department_id is null) from owned),
  'each owned slot belongs to the cell alone');
select is((select count(*)::int from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
            where pt.programme_id = pg_temp.pid() and l.link_kind = 'linked' and l.ended_at is null
              and l.slot_id = pg_temp.dslot()), 1, 'the ushering part display-links the department position');
select is((select o.revision || '|' || o.department_id || '|' || coalesce(o.cell_id::text, 'none') || '|'
                  || (select count(*) from app.duties_assignments a where a.slot_id = pg_temp.dslot())
             from app.duties_occurrences o where o.department_id = pg_temp.d()),
  (select occ_rev || '|' || department_id || '|' || coalesce(cell_id::text, 'none') || '|' || assignments from dbefore),
  'the department duty is unchanged and still owned by its department alone');
select is((select a ->> 'owner_kind' from jsonb_array_elements(
            pg_temp.readj(pg_temp.c(4), 'select api.duties_my_duties()') -> 'assignments') a
            where a ->> 'duty_name' = 'Opening prayer'), 'cell', 'the member finds their part in My duties');

-- Republish: nothing duplicated -----------------------------------------------------------------------
create temp table counts as
  select (select count(*) from app.duties_slots s join owned o using (slot_id)) as slots,
         (select count(*) from app.duties_assignments a join owned o using (slot_id)) as assignments;
select is(pg_temp.publish(3) #>> '{data,state}', 'published', 'the assistant republishes');
select is((select count(*)::int from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
            where pt.programme_id = pg_temp.pid() and l.ended_at is null), 4, 'still one link per part');
select is((select (select count(*) from app.duties_assignments a where a.slot_id in (select slot_id from owned))
             = assignments from counts), true, 'no assignment was added or re-asked');

-- Reads: the member projection equals the preview; nothing private --------------------------------------
create temp table mr as select pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) as r;
create temp table sr as select pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) as r;
select is((select jsonb_array_length(r #> '{programme,parts}') || '|' || (r #>> '{programme,parts,0,leader}')
                  || '|' || coalesce(r #>> '{programme,parts,1,leader}', 'null') || '|' || (r #>> '{programme,parts,3,department}')
                  || '|' || (r #>> '{meeting,venue}') from mr),
  '4|SYNTHETIC 5.4 Member 4|' || 'null|' || 'SYNTHETIC 5.4 Ushers: SYNTHETIC Evening ushering|SYNTHETIC 12 Shikoswe Road',
  'a member reads the parts, named leaders, the linked department and the private venue');
select is((select (mr.r -> 'programme') - 'revision' - 'published_at' from mr), (select sr.r -> 'preview' from sr),
  'the staff preview equals what members read');
select ok((select not (r::text ~ '(study_notes|response|note|history|instructions|private study)') from mr),
  'the member read holds no study notes, response, note, history or instructions');
select is(pg_temp.read(pg_temp.c(8), format('select api.cells_meeting_programme(%L)', pg_temp.mt())),
  'PT403|forbidden|not_granted', 'a member of another cell cannot read it');
select is(pg_temp.read(pg_temp.c(2), format('select api.cells_meeting_programme(%L)', pg_temp.mt())),
  'PT403|forbidden|not_granted', 'the member read is for members (managers read the staff view)');
select is(pg_temp.read(pg_temp.c(1), format('select api.cells_meeting_programme(%L)', pg_temp.mt())),
  'PT403|forbidden|not_granted', 'Admin alone cannot read it');
select is((select jsonb_array_length(r -> 'duties') || '|' || (r #>> '{duties,0,positions,0,assignment,response}') from sr),
  '4|pending', 'the leader sees each part''s Duties state (Awaiting)');
select is(pg_temp.readj(pg_temp.c(6), format('select api.cells_programme(%L)', pg_temp.mt())) -> 'duties',
  '[]'::jsonb, 'Pastor oversight sees no Duties state');
select is(pg_temp.save(2, pg_temp.draft()) #>> '{field_errors,programme_id}', 'not_draft',
  'a published programme is not edited as a draft');
select is(pg_temp.cells(pg_temp.c(2), 'cells.move_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt()),
  jsonb_build_object('meeting_id', pg_temp.mt(),
    'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '19:00')),
    'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '20:30')))) #>> '{field_errors,meeting_id}',
  'programme_published', 'review fix 2: a meeting with a published programme is not moved');
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt()),
  jsonb_build_object('meeting_id', pg_temp.mt())) #>> '{field_errors,meeting_id}',
  'programme_published', 'nor cancelled');

-- 5.3 review fixes ------------------------------------------------------------------------------------
create temp table cp2 as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt2())) as r;
create function pg_temp.pid2() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp2 $$;
create function pg_temp.rev2() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid2() $$;
create temp table s2 as select pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev2(),
  jsonb_build_object('programme_id', pg_temp.pid2(), 'parts', jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10'),
    jsonb_build_object('label', 'Worship', 'start_time', '18:10', 'end_time', '18:30')))) as r;
-- Move the meeting to 22:00-01:00 (past midnight).
select pg_temp.cells(pg_temp.c(2), 'cells.move_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt2()),
  jsonb_build_object('meeting_id', pg_temp.mt2(),
    'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt2(), '22:00')),
    'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt2(), '22:00') + interval '3 hours')));
select is((select string_agg(to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI'), ',' order by position)
             from app.cells_programme_parts where programme_id = pg_temp.pid2() and removed_at is null)
          || '|' || pg_temp.rev2(),
  '22:00,22:10|3', 'fix 1: a draft''s parts follow the moved meeting and the revision moves on');
select is(pg_temp.cells(pg_temp.c(2), 'cells.save_programme', 2,
  jsonb_build_object('programme_id', pg_temp.pid2(), 'parts', '[]'::jsonb)) ->> 'code',
  'conflict', 'so an editor holding the old revision gets a conflict');
create temp table s3 as select pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev2(),
  jsonb_build_object('programme_id', pg_temp.pid2(), 'parts', jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '22:00', 'end_time', '23:50'),
    jsonb_build_object('label', 'Late prayer', 'start_time', '00:15', 'end_time', '00:45')))) as r;
select is(coalesce((select r ->> 'code' from s3), 'ok') || '|'
          || ((select (r #>> '{data,parts,1,starts_at}')::timestamptz from s3) - pg_temp.at(pg_temp.mt2(), '22:00'))::text,
  'ok|02:15:00', 'fix 2: a part after midnight lands on the next day');
select is(pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev2(),
  jsonb_build_object('programme_id', pg_temp.pid2(), 'parts', jsonb_build_array(
    jsonb_build_object('part_id', (select r #>> '{data,parts,1,part_id}' from s2), 'label', 'Worship',
                       'start_time', '22:10', 'end_time', '22:30')))) -> 'field_errors',
  '{"parts.0": "part_unknown"}'::jsonb, 'fix 6: a removed part never comes back');

-- Cancel a published programme: its duties end, members read nothing ---------------------------------
create temp table cx as select pg_temp.cells(pg_temp.c(2), 'cells.cancel_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid())) as r;
select is((select r #>> '{data,state}' from cx), 'cancelled', 'the leader cancels the published programme');
select is((select string_agg(o.occurrence_state, ',' order by ow.position) from owned ow
             join app.duties_occurrences o on o.occurrence_id = ow.occurrence_id),
  'cancelled,cancelled,cancelled', 'its cell-owned duties are cancelled through Duties');
select is((select count(*)::int from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
            where pt.programme_id = pg_temp.pid() and l.link_kind = 'linked' and l.ended_at is null), 0,
  'its display link is ended, the department duty untouched');
select is(pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) -> 'programme',
  'null'::jsonb, 'members no longer read it');

-- Audit and deletion ------------------------------------------------------------------------------------
select is((select string_agg(distinct action, ',' order by action) from app.cells_programme_audit
            where programme_id = pg_temp.pid()),
  'programme_cancelled,programme_created,programme_published,programme_saved', 'the audit records the publish');
select pg_temp.place(4, pg_temp.es());
select is(pg_temp.read(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())),
  'PT403|forbidden|not_granted', 'a member who moved to another cell no longer reads it');
select app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(4), 'phase', 'erase'));
select ok((select not (body::text like '%SYNTHETIC 5.4 Member 4%') from app.cells_programme_projections
            where programme_id = pg_temp.pid()), 'deletion takes the member''s name out of the projection');

select * from finish();
rollback;
