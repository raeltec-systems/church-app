-- Programme drafts (story 5.3; epic 5 C3; AD-1, AD-2, AD-5, AD-14). One revisioned programme per
-- meeting with topic, scripture, study notes and ordered parts (stable ids, church-local times on
-- the meeting's date, optional assignee from the confirmed roster), validated order, fit and
-- overlap, visible gaps, leader/assistant drafting, Pastor oversight, Admin metadata only.
-- HTTP evidence with real phone sign-in: tools/identity-e2e/cells-programmes.mjs. Every account,
-- phone and name here is SYNTHETIC (fictional range +1 202 555 0170-0179).
begin;
select plan(40);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000053' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000053' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (70 + n)::text $$;
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
-- 5 leader of Estates, 6 Pastor, 7 an accountless member of Shikoswe, 8 member of Estates.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from (values (1), (2), (3), (4), (5), (6), (8)) v(n);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from (values (1), (2), (3), (4), (5), (6), (8)) v(n);

-- Structure -------------------------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.cells_programmes', 'app.cells_programme_parts', 'app.cells_programme_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the programme tables');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'cells_programme_audit'),
  array['action', 'actor_account_id', 'actor_capacity', 'actor_member_id', 'cell_id', 'command_request_id',
        'created_at', 'event_id', 'meeting_id', 'programme_id', 'revision_after'],
  'the programme audit holds ids, codes and revisions only');
select ok(has_function_privilege('authenticated', 'api.cells_programme(uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_programme(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_save_programme(uuid, bigint, jsonb)', 'EXECUTE'),
  'only the programme read is client-callable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Environment, members, cells, roles, memberships, a schedule --------------------------------------
select app.platform_set_environment('local', 'pgtap 5.3');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.3 Member ' || n, 'pgtap 5.3') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8)) v(n);
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.3 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(6), 'pastor', 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC Shikoswe Cell", "signup_label": "SYNTHETIC Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC Estates C5/C7 Cell", "signup_label": "SYNTHETIC Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_cell uuid) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_cell))
$$;
select pg_temp.grant_scope(2, 'cell_leader', pg_temp.sh());
select pg_temp.grant_scope(3, 'cell_assistant', pg_temp.sh());
select pg_temp.grant_scope(5, 'cell_leader', pg_temp.es());
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

-- Create ----------------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(5), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt())) ->> 'code',
  'forbidden', 'another cell''s leader cannot draft');
select is(pg_temp.cells(pg_temp.c(4), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt())) ->> 'code',
  'forbidden', 'a member cannot draft');
select is(pg_temp.cells(pg_temp.c(1), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt())) ->> 'code',
  'forbidden', 'Admin alone cannot draft');
select is(pg_temp.cells(pg_temp.c(6), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt())) ->> 'code',
  'forbidden', 'Pastor oversight does not draft');
create temp table cp as select pg_temp.cells(pg_temp.c(2), 'cells.create_programme', null,
  jsonb_build_object('meeting_id', pg_temp.mt())) as r;
create function pg_temp.pid() returns uuid language sql as $$ select (r #>> '{data,programme_id}')::uuid from cp $$;
select is((select (r #>> '{data,state}') || '|' || (r ->> 'revision') from cp), 'draft|1',
  'the leader creates an empty draft');
select is(pg_temp.cells(pg_temp.c(3), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt())) #>> '{field_errors,meeting_id}',
  'exists', 'one programme per meeting');
select is(pg_temp.cells(pg_temp.c(3), 'cells.create_programme', null, jsonb_build_object('meeting_id', pg_temp.mt2())) #>> '{data,state}',
  'draft', 'the assistant can draft too');

-- Save: a valid draft with a gap ------------------------------------------------------------------
create function pg_temp.rev() returns bigint language sql as $$ select revision from app.cells_programmes where programme_id = pg_temp.pid() $$;
create function pg_temp.save(n int, p_parts jsonb, p_extra jsonb default '{}', p_expected bigint default null)
returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.save_programme', coalesce(p_expected, pg_temp.rev()),
    jsonb_build_object('programme_id', pg_temp.pid(), 'topic', 'Rooted in love', 'scripture', 'Ephesians 3:14-21',
                       'parts', p_parts) || p_extra)
$$;
create temp table sv as select pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'duration_minutes', 10, 'assignee_member_id', pg_temp.mid(4)),
  jsonb_build_object('label', 'Worship', 'start_time', '18:10', 'end_time', '18:30'),
  jsonb_build_object('label', 'Bible study', 'start_time', '18:30', 'end_time', '19:20', 'assignee_member_id', pg_temp.mid(7))),
  '{"study_notes": "Read the passage twice.\nAsk: what does rooted mean?"}') as r;
select is((select (r ->> 'revision') || '|' || jsonb_array_length(r #> '{data,parts}') || '|' || (r #>> '{data,gaps}') from sv),
  '2|3|1', 'the leader saves three parts; the unassigned one is a visible gap');
select is((select to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') || '-' || to_char(ends_at at time zone 'Africa/Lusaka', 'HH24:MI')
             from app.cells_programme_parts where programme_id = pg_temp.pid() and position = 1 and removed_at is null),
  '18:00-18:10', 'part times are church-local on the meeting''s date (a duration gives the end)');
select is((select r #>> '{data,study_notes}' from sv), E'Read the passage twice.\nAsk: what does rooted mean?',
  'study notes keep their line break');
select is((select r #>> '{data,parts,2,assignee,display_name}' from sv), 'SYNTHETIC 5.3 Accountless',
  'a member without a login can be planned');

-- Save: refusals ----------------------------------------------------------------------------------
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:20'),
  jsonb_build_object('label', 'Worship', 'start_time', '18:10', 'end_time', '18:30'))) -> 'field_errors',
  '{"parts.1": "overlap"}'::jsonb, 'overlapping parts are refused');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Worship', 'start_time', '18:30', 'end_time', '18:40'),
  jsonb_build_object('label', 'Opening prayer', 'start_time', '18:00', 'end_time', '18:10'))) -> 'field_errors',
  '{"parts.1": "out_of_order"}'::jsonb, 'parts out of time order are refused');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Early', 'start_time', '17:30', 'end_time', '18:10'),
  jsonb_build_object('label', 'Late', 'start_time', '19:00', 'end_time', '20:00'))) -> 'field_errors',
  '{"parts.0": "outside_meeting", "parts.1": "outside_meeting"}'::jsonb, 'parts outside the meeting are refused');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('label', 'Backwards', 'start_time', '18:30', 'end_time', '18:20'),
  jsonb_build_object('label', '', 'start_time', '18:40', 'end_time', '18:50'),
  jsonb_build_object('label', 'Both', 'start_time', '18:50', 'end_time', '19:00', 'duration_minutes', 10),
  jsonb_build_object('label', 'Stranger', 'start_time', '19:00', 'end_time', '19:10', 'assignee_member_id', pg_temp.mid(8)),
  jsonb_build_object('label', 'Bad clock', 'start_time', '7pm', 'end_time', '19:20'))) -> 'field_errors',
  '{"parts.0": "end_before_start", "parts.1": "label_required", "parts.2": "end_or_duration",
    "parts.3": "assignee_not_in_cell", "parts.4": "start_invalid"}'::jsonb,
  'every part error at once: end before start, no label, end and duration, a member of another cell, a bad clock');
select is(pg_temp.save(2, '[]'::jsonb, '{"topic": 5}') -> 'field_errors', '{"topic": "invalid"}'::jsonb,
  'a non-text topic is refused');
select is(pg_temp.save(2, '[]'::jsonb, '{}', 1) ->> 'code', 'conflict', 'a save under a stale revision is a conflict');
select is(pg_temp.rev(), 2::bigint, 'refused saves wrote nothing');

-- Stable part ids --------------------------------------------------------------------------------
create temp table ids as select part_id, position from app.cells_programme_parts where programme_id = pg_temp.pid() and removed_at is null;
create temp table sv2 as select pg_temp.save(3, jsonb_build_array(
  jsonb_build_object('part_id', (select part_id from ids where position = 1), 'label', 'Opening prayer',
                     'start_time', '18:00', 'end_time', '18:10', 'assignee_member_id', pg_temp.mid(4)),
  jsonb_build_object('part_id', (select part_id from ids where position = 3), 'label', 'Bible study',
                     'start_time', '18:15', 'end_time', '19:15', 'assignee_member_id', pg_temp.mid(7)),
  jsonb_build_object('label', 'Closing prayer', 'start_time', '19:20', 'end_time', '19:30'))) as r;
select is((select (r #>> '{data,parts,0,part_id}')::uuid = (select part_id from ids where position = 1)
                  and (r #>> '{data,parts,1,part_id}')::uuid = (select part_id from ids where position = 3)
                  and (r #>> '{data,parts,2,part_id}')::uuid not in (select part_id from ids)
             from sv2), true, 'the assistant reorders: sent parts keep their ids, a new part gets one');
select is((select removed_at is not null from app.cells_programme_parts where part_id = (select part_id from ids where position = 2)), true,
  'a part left out is marked removed, not deleted');
select is(pg_temp.save(2, jsonb_build_array(
  jsonb_build_object('part_id', gen_random_uuid(), 'label', 'Ghost', 'start_time', '18:00', 'end_time', '18:10'))) -> 'field_errors',
  '{"parts.0": "part_unknown"}'::jsonb, 'a part id of another programme is refused');

-- Read ----------------------------------------------------------------------------------------------
create function pg_temp.prog(n int) returns text language sql as
$$ select pg_temp.read(pg_temp.c(n), format('select api.cells_programme(%L)', pg_temp.mt())) $$;
select is((select (x ->> 'view') || '|' || (x ->> 'can_edit') || '|' || (x #>> '{programme,topic}') || '|'
                  || jsonb_array_length(x -> 'roster') || '|' || (x #>> '{meeting,venue}')
             from (select substr(pg_temp.prog(2), 4)::jsonb as x) q),
  'full|true|Rooted in love|2|SYNTHETIC 12 Shikoswe Road', 'the leader reads the full draft, the roster and the venue');
select is((select x #>> '{roster}' from (select substr(pg_temp.prog(3), 4)::jsonb as x) q)::jsonb @> '[{"account": "no_login"}]'::jsonb,
  true, 'the roster shows who has no login');
select is((select (x ->> 'view') || '|' || (x ->> 'can_edit') || '|' || (x #>> '{programme,topic}') || '|'
                  || coalesce(x #>> '{meeting,venue}', 'none')
             from (select substr(pg_temp.prog(6), 4)::jsonb as x) q),
  'full|false|Rooted in love|none', 'Pastor oversight reads the draft, cannot edit, sees no private venue');
select is((select (x ->> 'view') || '|' || coalesce(x #>> '{programme,topic}', 'none') || '|'
                  || coalesce(x #>> '{programme,parts}', 'none') || '|' || (x #>> '{programme,gaps}') || '|'
                  || jsonb_array_length(x -> 'roster')
             from (select substr(pg_temp.prog(1), 4)::jsonb as x) q),
  'metadata|none|none|1|0', 'Admin alone reads state, revision and counts only');
select ok(pg_temp.prog(4) like 'PT403|forbidden|not_granted%', 'a member of the cell cannot read the draft');
select ok(pg_temp.prog(5) like 'PT403|forbidden|not_granted%', 'another cell''s leader cannot read the draft');
select ok(pg_temp.prog(8) like 'PT403|forbidden|not_granted%', 'a member of another cell cannot read the draft');

-- Cancel ----------------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_programme', pg_temp.rev(),
  jsonb_build_object('programme_id', pg_temp.pid())) #>> '{data,state}', 'cancelled', 'the leader cancels the draft');
select is(pg_temp.save(2, '[]'::jsonb) #>> '{field_errors,programme_id}', 'not_draft',
  'a cancelled programme cannot be saved');
select is((select string_agg(action, ',' order by event_id) from app.cells_programme_audit where programme_id = pg_temp.pid()),
  'programme_created,programme_saved,programme_saved,programme_cancelled', 'every change is audited');

-- Deletion ----------------------------------------------------------------------------------------
select is((app.cells_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(7),
                                                     'account_id', null)) ->> 'remaining')::int, 0,
  'the deletion hook clears the member''s planned parts and answers zero');
select is((select count(*)::int from app.cells_programme_parts where assignee_member_id = pg_temp.mid(7)), 0,
  'the erased member''s part is now a gap');
select is((app.cells_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(3),
                                                     'account_id', pg_temp.u(3))) ->> 'remaining')::int, 0,
  'an erased drafter is anonymised in the programme and its audit');

select * from finish();
rollback;
