-- Programme revisions (story 5.6; epic 5 C5, C1). A published programme is changed and published
-- again in one transaction: Duties asks again only where material (a notes-only change keeps answers;
-- an earlier acceptance stays in history; no reminder is left for the old revision; a late answer to
-- it is refused); a removed part ends in Duties; a linked department duty is never changed but
-- flagged for its leader; the cell's leader moves the meeting and publishes the revision. HTTP
-- evidence: tools/identity-e2e/cells-programme-revisions.mjs. SYNTHETIC data only
-- (fictional range +1 202 555 0181-0192).
begin;
select plan(28);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000056' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000056' || lpad(n::text, 2, '0'))::uuid $$;
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
select app.platform_set_environment('local', 'pgtap 5.6');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.6 Member ' || n, 'pgtap 5.6') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.6 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.6 Shikoswe Cell", "signup_label": "SYNTHETIC 5.6 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.6 Estates Cell", "signup_label": "SYNTHETIC 5.6 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.6 Ushers"}') as r;
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
-- The department's duty at the meeting's time, the department's leader on it (shown on a part).
create temp table dq as select pg_temp.duties(9, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'member_id', pg_temp.mid(9), 'duty_name', 'SYNTHETIC Evening ushering',
  'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '18:00')),
  'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '19:30')))) as r;
create function pg_temp.dslot() returns uuid language sql as $$
  select s.slot_id from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
   where o.department_id = pg_temp.d() order by s.position_no limit 1
$$;
create temp table dbefore as select o.revision from app.duties_occurrences o where o.department_id = pg_temp.d();

-- A published programme; both members accept ------------------------------------------------------
create temp table cp as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) as r;
create function pg_temp.pid() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp $$;
create function pg_temp.rev() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid() $$;
create function pg_temp.part(p_position int) returns uuid language sql as $$
  select part_id from app.cells_programme_parts
   where programme_id = pg_temp.pid() and position = p_position and removed_at is null
$$;
-- Parts as [label, start, end, who] where who is a member number, 0 (open) or -1 (the department duty).
create function pg_temp.save(p_parts jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.rev(),
    jsonb_build_object('programme_id', pg_temp.pid(), 'topic', 'SYNTHETIC Rooted in love',
                       'study_notes', 'SYNTHETIC first notes', 'parts', (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'part_id', case when e ->> 4 is not null then (e ->> 4) end,
               'label', e ->> 0, 'start_time', e ->> 1, 'end_time', e ->> 2,
               'assignee_member_id', case when (e ->> 3)::int > 0 then pg_temp.mid((e ->> 3)::int) end,
               'linked_slot_id', case when (e ->> 3)::int = -1 then pg_temp.dslot() end)) order by o)
        from jsonb_array_elements(p_parts) with ordinality t(e, o))) || p_extra)
$$;
create function pg_temp.publish(p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(2), 'cells.publish_programme', pg_temp.rev(),
    jsonb_build_object('programme_id', pg_temp.pid()) || p_extra)
$$;
create function pg_temp.asg(p_part uuid) returns app.duties_assignments language sql as $$
  select a.* from app.duties_assignments a
    join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
   where l.source_id = p_part and a.assignment_state = 'current'
$$;
create function pg_temp.respond(n int, p_part uuid, p_response text) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.duties_command', 'duties.respond', (pg_temp.asg(p_part)).revision,
    jsonb_build_object('assignment_id', (pg_temp.asg(p_part)).assignment_id, 'response', p_response))
$$;
select pg_temp.save('[["Opening prayer", "18:00", "18:10", 4], ["Worship", "18:10", "18:30", 10],
                      ["Ushering", "18:30", "19:00", -1]]'::jsonb);
select is(pg_temp.publish() #>> '{data,state}', 'published', 'setup: published');
select is(pg_temp.respond(4, pg_temp.part(1), 'accepted') #>> '{data,response}', 'accepted', 'setup: member 4 accepts');
select is(pg_temp.respond(10, pg_temp.part(2), 'accepted') #>> '{data,response}', 'accepted', 'setup: member 10 accepts');
create temp table a1 as select pg_temp.asg(pg_temp.part(1)) as a;
create temp table a2 as select pg_temp.asg(pg_temp.part(2)) as a;
create function pg_temp.parts_now() returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(pt.label, to_char(pt.starts_at at time zone 'Africa/Lusaka', 'HH24:MI'),
                                     to_char(pt.ends_at at time zone 'Africa/Lusaka', 'HH24:MI'),
                                     case when pt.assignee_member_id = pg_temp.mid(4) then 4
                                          when pt.assignee_member_id = pg_temp.mid(10) then 10
                                          when pt.assignee_member_id = pg_temp.mid(7) then 7
                                          when pt.linked_slot_id is not null then -1 else 0 end,
                                     pt.part_id) order by pt.position)
    from app.cells_programme_parts pt where pt.programme_id = pg_temp.pid() and pt.removed_at is null
$$;

-- Notes only: answers kept ---------------------------------------------------------------------------
select is(pg_temp.save(pg_temp.parts_now(), '{"study_notes": "SYNTHETIC changed notes", "scripture": "John 15"}') #>> '{data,unpublished_changes}',
  'true', 'a saved change to a published programme waits to be published');
select is(pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) #>> '{programme,scripture}',
  null, 'members keep reading the last publish until then');
select is(pg_temp.publish() #>> '{data,state}', 'published', 'the notes-only revision is published');
select is((select (pg_temp.asg(pg_temp.part(1))).assignment_id = (a).assignment_id
                  and (pg_temp.asg(pg_temp.part(1))).response = 'accepted' from a1)
          and (select (pg_temp.asg(pg_temp.part(2))).response = 'accepted' from a2), true,
  'a notes-only change keeps every answer');

-- A part's time and an assignee change: asked again only where material ------------------------------
select pg_temp.save((select jsonb_set(jsonb_set(pg_temp.parts_now(), '{0,1}', '"18:02"'), '{1,3}', '7')));
create temp table pb as select pg_temp.publish() as r;
select is((select r #>> '{data,state}' from pb), 'published', 'the material revision is published');
select is((select (pg_temp.asg(pg_temp.part(1))).response || '|' || ((pg_temp.asg(pg_temp.part(1))).assignment_id <> (a).assignment_id)::text from a1),
  'pending|true', 'the re-timed part asks its person again (a new pending revision)');
select is((select x.assignment_state || '|' || x.response from app.duties_assignments x, a1 where x.assignment_id = (a1.a).assignment_id),
  'superseded|accepted', 'the earlier acceptance is kept in history');
select is((select (pg_temp.asg(pg_temp.part(2))).member_id = pg_temp.mid(7)), true,
  'the swapped part asks the new person');
select is((select x.assignment_state <> 'current' from app.duties_assignments x, a2 where x.assignment_id = (a2.a).assignment_id),
  true, 'the replaced person''s assignment ends (Duties keeps it in history)');
select is((select count(*)::int from app.notifications_jobs j, a1
            where j.source_id = (a1.a).assignment_id and j.job_state = 'pending'), 0,
  'no reminder is left pending for the old revision');
select is(pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (select (a).revision from a1),
  jsonb_build_object('assignment_id', (select (a).assignment_id from a1), 'response', 'declined')) ->> 'code',
  'conflict', 'a late answer to the old revision is refused');

-- The department duty: never changed, flagged for its leader --------------------------------------------
select pg_temp.save((select jsonb_set(pg_temp.parts_now(), '{2,0}', '"Ushers at the door"')));
select is(pg_temp.publish() #> '{data,duties,2,flagged}', '["label"]'::jsonb,
  'a renamed department part flags its department (label)');
select is((select string_agg(f.changed::text, ',') from app.duties_review_flags f
            join app.duties_occurrences o using (occurrence_id)
           where o.department_id = pg_temp.d() and f.cleared_at is null) like '%label%', true,
  'the department sees the mismatch for review');
select is((select o.revision from app.duties_occurrences o where o.department_id = pg_temp.d()),
  (select revision from dbefore), 'the department duty itself is unchanged');

-- Kind cannot switch; a removed part ends in Duties ---------------------------------------------------------
select is(pg_temp.save((select jsonb_set(pg_temp.parts_now(), '{0,3}', '-1'))) -> 'field_errors',
  '{"parts.0": "published_kind"}'::jsonb, 'a published part cannot switch to a department duty');
create temp table p2 as select pg_temp.part(2) as id;
select pg_temp.save((select jsonb_build_array(pg_temp.parts_now() -> 0, pg_temp.parts_now() -> 2)));
select is(pg_temp.publish() #>> '{data,state}', 'published', 'the revision without the second part is published');
select is((select o.occurrence_state from app.duties_occurrences o join app.duties_slots s using (occurrence_id)
             join app.duties_part_links l using (slot_id) where l.source_id = (select id from p2) and l.link_kind = 'owned'),
  'cancelled', 'the removed part''s duty is cancelled through Duties');

-- The meeting moves: the leader may, the programme follows, the revision is published -----------------------
select is(pg_temp.cells(pg_temp.c(1), 'cells.move_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt()),
  jsonb_build_object('meeting_id', pg_temp.mt(),
    'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '18:30')),
    'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '20:00')))) #>> '{field_errors,meeting_id}',
  'programme_published', 'Admin alone cannot move a meeting with a published programme');
select is(coalesce(pg_temp.cells(pg_temp.c(2), 'cells.move_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt()),
  jsonb_build_object('meeting_id', pg_temp.mt(),
    'starts_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '18:30')),
    'ends_at', app.cmd_utc(pg_temp.at(pg_temp.mt(), '20:00')))) ->> 'code', 'ok'), 'ok',
  'the cell''s leader moves it');
select is((select pg_temp.readj(pg_temp.c(2), format('select api.cells_programme(%L)', pg_temp.mt())) #>> '{programme,meeting_changed}')
          || '|' || (pg_temp.readj(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) #>> '{programme,meeting_changed}'),
  'true|true', 'staff and members are told the meeting moved since the publish');
create temp table pm as select pg_temp.publish() as r;
select is((select to_char(o.starts_at at time zone 'Africa/Lusaka', 'HH24:MI') from app.duties_occurrences o
             join app.duties_slots s using (occurrence_id) join app.duties_part_links l using (slot_id)
            where l.source_id = pg_temp.part(1) and l.link_kind = 'owned'), '18:32',
  'publishing moves the part''s duty with the meeting');
select is((select r #> '{data,duties,1,flagged}' from pm), '["time"]'::jsonb,
  'the department is flagged that the time changed');
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt()),
  jsonb_build_object('meeting_id', pg_temp.mt())) #>> '{field_errors,meeting_id}',
  'programme_published', 'cancelling the meeting waits for the programme to be cancelled');
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting',
  (select revision from app.cells_meetings where meeting_id = pg_temp.mt2()),
  jsonb_build_object('meeting_id', pg_temp.mt2())) #>> '{data,state}', 'cancelled',
  'another meeting without a programme is cancelled as before');

-- Cancelling the programme flags the department ----------------------------------------------------------
select pg_temp.cells(pg_temp.c(2), 'cells.cancel_programme', pg_temp.rev(), jsonb_build_object('programme_id', pg_temp.pid()));
select is((select count(*)::int from app.duties_review_flags f join app.duties_occurrences o using (occurrence_id)
            where o.department_id = pg_temp.d() and f.cleared_at is null and f.changed::text like '%cancelled%'), 1,
  'the department is flagged when the programme is cancelled');

select * from finish();
rollback;
