-- Transfer effects (story 5.9; epic 5 C9). Moving a member to another cell ends their old cell's
-- future work in the same transaction: their parts become gaps (draft and published, the projection
-- stops naming them), their cell-part assignments end through Duties (vacated, duty released), their
-- open notices close and the old cell's leaders are told; old-cell reads are refused at once; past
-- meetings keep their plan and actual leaders. The last reachable leader of a cell with a programme
-- published ahead is last responsible in a handover; Admin resolves a recorded one. HTTP evidence:
-- tools/identity-e2e/cells-transfer.mjs. SYNTHETIC data only (fictional range +1 202 555 0181-0190).
begin;
select plan(39);
create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000059' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000059' || lpad(n::text, 2, '0'))::uuid $$;
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
select app.platform_set_environment('local', 'pgtap 5.9');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.9 Member ' || n, 'pgtap 5.9') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8), (9), (10)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.9 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.9 Shikoswe Cell", "signup_label": "SYNTHETIC 5.9 Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 5.9 Estates Cell", "signup_label": "SYNTHETIC 5.9 Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 5.9 Ushers"}') as r;
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

-- Programmes: the next meeting published (member 4 Opening prayer, member 10 Bible study); the one
-- after a draft with member 4; a third published, then moved into the past and held with member 4
create function pg_temp.mt3() returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date offset 2 limit 1 $$;
create function pg_temp.prog(p_meeting uuid) returns uuid language sql as
$$ select programme_id from app.cells_programmes where meeting_id = p_meeting $$;
create function pg_temp.prev(p_meeting uuid) returns bigint language sql as
$$ select revision from app.cells_programmes where meeting_id = p_meeting $$;
create function pg_temp.plan(p_meeting uuid, p_parts jsonb, p_publish boolean) returns jsonb language plpgsql as $$
begin
  perform pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null, jsonb_build_object('meeting_id', p_meeting));
  perform pg_temp.cells(pg_temp.c(2), 'cells.save_programme', pg_temp.prev(p_meeting),
    jsonb_build_object('programme_id', pg_temp.prog(p_meeting), 'parts', p_parts));
  if p_publish then
    return pg_temp.cells(pg_temp.c(2), 'cells.publish_programme', pg_temp.prev(p_meeting),
      jsonb_build_object('programme_id', pg_temp.prog(p_meeting)));
  end if;
  return '{}'::jsonb;
end;
$$;
create function pg_temp.parts2(p_a int, p_b int) returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10', 'assignee_member_id', pg_temp.mid(p_a)),
    jsonb_build_object('label', 'Bible study', 'start_time', '18:10', 'end_time', '19:00', 'assignee_member_id', pg_temp.mid(p_b)))
$$;
select is(pg_temp.plan(pg_temp.mt(), pg_temp.parts2(4, 10), true) #>> '{data,state}', 'published', 'setup: published');
select pg_temp.plan(pg_temp.mt2(), pg_temp.parts2(4, 10), false);
select is(pg_temp.plan(pg_temp.mt3(), pg_temp.parts2(4, 10), true) #>> '{data,state}', 'published',
  'setup: a third published');
create function pg_temp.part(p_meeting uuid, p_label text) returns app.cells_programme_parts language sql as $$
  select pt.* from app.cells_programme_parts pt
   where pt.programme_id = pg_temp.prog(p_meeting) and pt.label = p_label and pt.removed_at is null
$$;
create function pg_temp.asg(p_meeting uuid, p_label text) returns app.duties_assignments language sql as $$
  select a.* from app.duties_assignments a
    join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
   where l.source_id = (pg_temp.part(p_meeting, p_label)).part_id
   order by a.assignment_state = 'current' desc, a.ended_at desc nulls last, a.assignment_id limit 1
$$;
select is(pg_temp.cmd(pg_temp.c(4), 'api.duties_command', 'duties.respond', (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).assignment_id, 'response', 'accepted'))
  #>> '{data,response}', 'accepted', 'setup: member 4 accepts their part');
create temp table before10 as select (pg_temp.asg(pg_temp.mt(), 'Bible study')).* ;
select is(pg_temp.cells(pg_temp.c(4), 'cells.send_cannot_attend', null,
  jsonb_build_object('meeting_id', pg_temp.mt(), 'note', 'SYNTHETIC away')) #>> '{data,state}', 'open',
  'setup: member 4 sent a Cannot attend notice');
-- The third meeting happened: held, member 4 led as planned.
update app.cells_meetings
   set starts_at = starts_at - interval '21 days', ends_at = ends_at - interval '21 days',
       nominal_starts_at = nominal_starts_at - interval '21 days', nominal_ends_at = nominal_ends_at - interval '21 days'
 where meeting_id = pg_temp.mt3();
select pg_temp.cells(pg_temp.c(2), 'cells.record_meeting_held', null, jsonb_build_object('meeting_id', pg_temp.mt3(), 'held', true));
select is(pg_temp.cells(pg_temp.c(2), 'cells.record_actual_leaders',
  (select revision from app.cells_meeting_records where meeting_id = pg_temp.mt3()),
  jsonb_build_object('meeting_id', pg_temp.mt3(), 'parts', jsonb_build_array(
    jsonb_build_object('part_id', (pg_temp.part(pg_temp.mt3(), 'Opening prayer')).part_id,
                       'leader', jsonb_build_object('member_id', pg_temp.mid(4)))))) #>> '{data,changed}', '1',
  'setup: the past meeting records member 4 as its leader');
create temp table rev_before as select pg_temp.prev(pg_temp.mt()) as published, pg_temp.prev(pg_temp.mt2()) as draft;
select is(pg_temp.read(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) like 'ok %', true,
  'setup: member 4 reads the programme and its venue');

-- The transfer --------------------------------------------------------------------------------------------
select is(pg_temp.place(4, pg_temp.es()) ->> 'code', null, 'the Admin moves member 4 to Estates');
select is((select cell_id from app.cells_memberships where member_id = pg_temp.mid(4) and ended_at is null), pg_temp.es(),
  'member 4 is now in Estates');

-- Access ---------------------------------------------------------------------------------------------------
select is(pg_temp.read(pg_temp.c(4), format('select api.cells_meeting_programme(%L)', pg_temp.mt())) like 'PT403%', true,
  'the old cell''s programme and venue are refused at once');
select is(pg_temp.readj(pg_temp.c(4), 'select api.cells_my_cell()') #>> '{primary,cell_id}', pg_temp.es()::text,
  'My cell is the new cell');

-- The plan and its projection ----------------------------------------------------------------------------
select is((pg_temp.part(pg_temp.mt(), 'Opening prayer')).assignee_member_id, null, 'the published part becomes a gap');
select is((pg_temp.part(pg_temp.mt(), 'Bible study')).assignee_member_id, pg_temp.mid(10), 'other parts keep their person');
select is((pg_temp.part(pg_temp.mt2(), 'Opening prayer')).assignee_member_id, null, 'the draft part becomes a gap too');
select is((select e -> 'leader' from app.cells_programme_projections pr, jsonb_array_elements(pr.body -> 'parts') e
            where pr.programme_id = pg_temp.prog(pg_temp.mt()) and pr.withdrawn_at is null and e ->> 'label' = 'Opening prayer'),
  'null'::jsonb, 'members no longer read their name on it');
select is((select pg_temp.prev(pg_temp.mt()) = published + 1 and pg_temp.prev(pg_temp.mt2()) = draft + 1 from rev_before), true,
  'both programmes move to a new revision (an open editor conflicts)');

-- Duties --------------------------------------------------------------------------------------------------
select is((select assignment_state || ':' || end_reason || ':' || coalesce(vacancy_reason, '-')
             from app.duties_assignments where assignment_id = (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).assignment_id),
  'superseded:vacated:-', 'the accepted part''s assignment ends (vacated)');
select is((select count(*)::int from app.duties_assignments a
            join app.duties_part_links l on l.slot_id = a.slot_id and l.link_kind = 'owned'
           where l.source_id = (pg_temp.part(pg_temp.mt(), 'Opening prayer')).part_id and a.assignment_state = 'current'), 0,
  'the position is left unfilled');
select is((select (pg_temp.asg(pg_temp.mt(), 'Bible study')).revision = revision
                  and (pg_temp.asg(pg_temp.mt(), 'Bible study')).assignment_state = 'current' from before10), true,
  'member 10''s part is untouched');
select is((select count(*)::int from app.notifications_jobs j
            where j.recipient_member_id = pg_temp.mid(4) and j.reminder_kind = 'duty_released'
              and j.source_id = (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).assignment_id), 1,
  'member 4 is told their duty was released');
select is(pg_temp.duties(2, 'duties.confirm_by_leader', (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).revision,
  jsonb_build_object('assignment_id', (pg_temp.asg(pg_temp.mt(), 'Opening prayer')).assignment_id,
                     'channel', 'phone', 'reason', 'SYNTHETIC test')) ->> 'code' in ('conflict', 'not_found', 'validation_failed'),
  true, 'the old cell''s leader can no longer confirm them on it (5.5 finding)');

-- Notices and the leaders' notice --------------------------------------------------------------------------
select is((select notice_state || ':' || withdrawn_reason from app.cells_absence_notices
            where member_id = pg_temp.mid(4) and meeting_id = pg_temp.mt()), 'withdrawn:left_cell',
  'their open notice closes (left the cell)');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'cells_absence_notice' and j.job_state = 'pending'
              and j.source_id in (select notice_id from app.cells_absence_notices where member_id = pg_temp.mid(4))), 0,
  'nothing about it is left waiting for the leaders');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'cells_absence_notice' and j.reminder_kind = 'cells_absence_withdrawn'
              and j.source_id in (select notice_id from app.cells_absence_notices where member_id = pg_temp.mid(4))), 0,
  'and no "can come after all" is sent');
select is((select string_agg(distinct j.source_id::text, ',') || '|' || count(*)
             from app.notifications_jobs j
            where j.source_type = 'cells_programme' and j.reminder_kind = 'cells_part_vacated' and j.job_state = 'pending'
              and j.recipient_member_id in (pg_temp.mid(2), pg_temp.mid(3))),
  pg_temp.prog(pg_temp.mt())::text || '|2', 'the leader and the assistant are told about the published programme only');
select is((app.cells_programme_reminder_check(jsonb_build_object(
            'source_id', pg_temp.prog(pg_temp.mt()), 'source_revision', pg_temp.prev(pg_temp.mt()),
            'reminder_kind', 'cells_part_vacated', 'recipient_member_id', pg_temp.mid(2))) ->> 'actionable'), 'true',
  'the notice is actionable while the part has nobody');

-- The past ------------------------------------------------------------------------------------------------
select is((pg_temp.part(pg_temp.mt3(), 'Opening prayer')).assignee_member_id, pg_temp.mid(4),
  'a meeting that has happened keeps its plan');
select is((select member_id from app.cells_actual_leaders
            where part_id = (pg_temp.part(pg_temp.mt3(), 'Opening prayer')).part_id and superseded_at is null), pg_temp.mid(4),
  'and who actually led it');

-- The new cell -------------------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(4), 'cells.send_cannot_attend', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) ->> 'code', 'not_found', 'no notice for the old cell''s meeting');

-- Handover ------------------------------------------------------------------------------------------------
select is(jsonb_array_length(app.cells_report_handover(jsonb_build_object('event', 'membership_deactivated',
  'member_id', pg_temp.mid(2))) -> 'obligations'), 0, 'the leader is not the last one while the assistant is reachable');
select is(jsonb_array_length(app.cells_report_handover(jsonb_build_object('event', 'membership_deactivated',
  'member_id', pg_temp.mid(5))) -> 'obligations'), 0, 'a cell with nothing published ahead needs no handover');
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(3)),
  jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'cell_assistant', 'scope_id', pg_temp.sh()));
select is(app.cells_report_handover(jsonb_build_object('event', 'membership_deactivated', 'member_id', pg_temp.mid(2))),
  jsonb_build_object('obligations', jsonb_build_array(jsonb_build_object(
    'kind', 'cell_leader', 'subject_id', pg_temp.sh(), 'last_responsible', true))),
  'now the leader is last responsible (a programme is published ahead)');
select is(pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'cell_leader', 'scope_id', pg_temp.sh()))
  #>> '{field_errors,member_id}', 'handover_required', 'revoking the last leader is refused');
select is((select count(*)::int from app.identity_grants where member_id = pg_temp.mid(2) and scope_id = pg_temp.sh()
            and revoked_at is null), 1, 'and nothing changed');

-- Resolve ------------------------------------------------------------------------------------------------
insert into app.identity_handover_obligations (member_id, revoked_grant_id, owner_module, obligation_kind, subject_id)
select pg_temp.mid(3), g.grant_id, 'cells', 'cell_leader', pg_temp.sh()
  from app.identity_grants g where g.member_id = pg_temp.mid(3) and g.scope_id = pg_temp.sh() and g.revoked_at is not null;
create function pg_temp.crev(p_cell uuid) returns bigint language sql as $$ select revision from app.cells_cells where cell_id = p_cell $$;
select is((app.cells_cell_json(pg_temp.sh()) ->> 'handover_pending'), 'true', 'Admin reads a pending handover');
select is(pg_temp.cells(pg_temp.c(2), 'cells.resolve_handover', pg_temp.crev(pg_temp.sh()),
  jsonb_build_object('cell_id', pg_temp.sh())) ->> 'code', 'forbidden', 'only Admin resolves it');
select is(pg_temp.cells(pg_temp.c(1), 'cells.resolve_handover', pg_temp.crev(pg_temp.es()),
  jsonb_build_object('cell_id', pg_temp.es())) #>> '{field_errors,cell_id}', 'no_handover', 'nothing to resolve elsewhere');
select is(pg_temp.cells(pg_temp.c(1), 'cells.resolve_handover', pg_temp.crev(pg_temp.sh()),
  jsonb_build_object('cell_id', pg_temp.sh())) #>> '{data,resolved}', '1', 'Admin resolves it: the cell has its leader');
select is((app.cells_cell_json(pg_temp.sh()) ->> 'handover_pending'), 'false', 'and it is no longer pending');

-- Deletion ------------------------------------------------------------------------------------------------
select is((app.cells_erase_member(jsonb_build_object('member_id', pg_temp.mid(4), 'phase', 'erase')) ->> 'remaining'), '0',
  'deleting the member who moved leaves nothing of them in Cells');

select * from finish();
rollback;
