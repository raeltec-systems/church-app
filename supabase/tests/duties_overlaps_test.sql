-- Warn on overlapping duties and record reasoned overrides (story 4.4; AD-2, AD-6): the busy
-- time of a duty, the conflict query over every owner (department duties and a SYNTHETIC
-- cell-owned occurrence fixture), the candidates read with upcoming load and viewer-safe
-- disclosure, the override gate on publishing, giving and planning positions, Publish N and
-- material edits (one-off and this-and-future), carried overrides, the projections, refusals
-- and the deletion hook. HTTP evidence (including the concurrent race):
-- tools/identity-e2e/duties-overlaps.mjs. Every account, phone and name is SYNTHETIC
-- (fictional range +44 7700 900770-900779).
begin;
select plan(93);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000044' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000044' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (770 + n)::text $$;
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
create function pg_temp.sunday(k int) returns date language sql as $$
  select ((now() at time zone 'Africa/Lusaka')::date + 4)
         + ((7 - extract(dow from (now() at time zone 'Africa/Lusaka')::date + 4)::int) % 7) + 7 * k
$$;
-- The instant of church-local time t on the k-th Sunday.
create function pg_temp.lt(k int, t text) returns timestamptz language sql as
$$ select (pg_temp.sunday(k) + t::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.utc(k int, t text) returns text language sql as
$$ select app.cmd_utc(pg_temp.lt(k, t)) $$;

-- Accounts: 1 Admin; 2 leader of D; 3 deputy of D; 4 member M (in D and E); 5 member O (in D);
-- 6 leader of E and leader of the SYNTHETIC cell C; 7 Pastor; 8 member N (in E).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 8) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 8) n;
select app.platform_set_environment('local', 'pgtap 4.4');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.4 Member ' || n, 'pgtap 4.4')
  from generate_series(1, 8) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.4 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.e() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from de $$;
create temp table cc as
  with ins as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
               values ('SYNTHETIC 4.4 Cell', 'SYNTHETIC area', true, 'pgtap 4.4') returning cell_id)
  select cell_id from ins;
create function pg_temp.cell() returns uuid language sql as $$ select cell_id from cc $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());
select pg_temp.grant_scope(6, 'cell_leader', pg_temp.cell());
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(4, pg_temp.d());
select pg_temp.add(5, pg_temp.d());
select pg_temp.add(4, pg_temp.e());
select pg_temp.add(8, pg_temp.e());

-- A one-off duty of department p_department for member p_member on Sunday k, church-local times.
create function pg_temp.pub(n int, p_department uuid, p_member int, k int, p_from text, p_to text,
                            p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.publish_duty', null, jsonb_build_object(
           'department_id', p_department, 'member_id', pg_temp.mid(p_member), 'duty_name', 'Sunday duty',
           'starts_at', pg_temp.utc(k, p_from), 'ends_at', pg_temp.utc(k, p_to),
           'response_deadline', app.cmd_utc(pg_temp.lt(k, p_from) - interval '1 day')) || p_extra)
$$;
create function pg_temp.asg(p_publish jsonb) returns app.duties_assignments language sql as
$$ select a.* from app.duties_assignments a where a.assignment_id = (p_publish #>> '{data,assignment_id}')::uuid $$;
-- The candidates read for a prospective duty of p_department on Sunday k.
create function pg_temp.cand(n int, p_department uuid, k int, p_from text, p_to text) returns text
language sql as $$
  select pg_temp.read(n, format('select api.duties_candidates(department_id => %L::uuid, starts_at => %L::timestamptz, ends_at => %L::timestamptz)',
                                p_department, pg_temp.lt(k, p_from), pg_temp.lt(k, p_to)))
$$;
create function pg_temp.candj(n int, p_department uuid, k int, p_from text, p_to text) returns jsonb
language sql as $$ select substr(pg_temp.cand(n, p_department, k, p_from, p_to), 4)::jsonb $$;
create function pg_temp.of(p_read jsonb, p int) returns jsonb language sql as
$$ select c from jsonb_array_elements(p_read -> 'candidates') c where c ->> 'member_id' = pg_temp.mid(p)::text $$;
create function pg_temp.board(n int, p_department uuid) returns jsonb language sql as $$
  select d -> 'duties' from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_leader_board()') -> 'departments') d
   where d ->> 'department_id' = p_department::text
$$;
create function pg_temp.board_assignment(n int, p_department uuid, p_occurrence uuid) returns jsonb language sql as $$
  select x #> '{positions,0,assignment}' from jsonb_array_elements(pg_temp.board(n, p_department)) x
   where x ->> 'occurrence_id' = p_occurrence::text
$$;

-- Structure -------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)', 'EXECUTE'),
  'the candidates read is for authenticated sessions only');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'app' and p.proname in ('duties_busy_items', 'duties_overlap_gate', 'duties_lock_members',
                                             'duties_conflicts_json', 'duties_gate_created', 'duties_upcoming')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'the conflict query and the gate are not client-executable');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'no boundary violations (Duties never reads Cells: cell detail comes from Identity scopes)');
select ok(app.duties_state_ok('audit_action', 'overlap_override'), 'the override audit action is in the vocabulary');
select is(app.duties_busy_range_of('2099-01-04 08:00Z', null, null),
  tstzrange('2099-01-04 08:00Z', '2099-01-04 10:00Z', '[)'), 'without an end time a duty is busy for two hours');
select is(app.duties_busy_range_of('2099-01-04 08:00Z', '2099-01-04 09:00Z', '2099-01-04 07:30Z'),
  tstzrange('2099-01-04 07:30Z', '2099-01-04 09:00Z', '[)'), 'busy from the reporting time to the end');
select ok(not (app.duties_busy_range_of('2099-01-04 08:00Z', '2099-01-04 09:00Z', null)
               && app.duties_busy_range_of('2099-01-04 09:00Z', '2099-01-04 10:00Z', null)),
  'back-to-back duties do not overlap');
select throws_ok(
  format($$insert into app.duties_occurrences (department_id, cell_id, duty_name, starts_at, created_by_member, created_by_account)
           values (%L, %L, 'x', now() + interval '1 day', %L, %L)$$, pg_temp.d(), pg_temp.cell(), pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'an occurrence cannot be owned by a department and a cell');
select throws_ok(
  format($$insert into app.duties_occurrences (duty_name, starts_at, created_by_member, created_by_account)
           values ('x', now() + interval '1 day', %L, %L)$$, pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'nor by neither');

-- The SYNTHETIC cell-owned fixture: M has a pending part on Sunday 1, 18:00-19:00 (entry 11 adds
-- the Cells operations that create these).
create temp table cell_occ as
  with o as (insert into app.duties_occurrences (cell_id, duty_name, starts_at, ends_at, location, instructions,
                                                 created_by_member, created_by_account)
             values (pg_temp.cell(), 'SYNTHETIC cell part', pg_temp.lt(1, '18:00'), pg_temp.lt(1, '19:00'),
                     'SYNTHETIC cell home', 'SYNTHETIC cell private instructions', pg_temp.mid(6), pg_temp.u(6))
             returning occurrence_id),
       s as (insert into app.duties_slots (occurrence_id, position_no, position_name)
             select occurrence_id, 1, 'Prayer' from o returning slot_id)
  select (select occurrence_id from o) as occurrence_id, (select slot_id from s) as slot_id;
insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
select slot_id, pg_temp.mid(4), pg_temp.lt(1, '17:00'), pg_temp.mid(6), pg_temp.u(6) from cell_occ;

-- Two departments ------------------------------------------------------------------------------------
create temp table e1 as select pg_temp.pub(6, pg_temp.e(), 4, 0, '10:00', '12:00', jsonb_build_object(
  'instructions', 'SYNTHETIC E private instructions', 'location', 'SYNTHETIC E hall')) as r;
select is((select r #>> '{data,override_recorded}' from e1), 'false',
  'the first duty of the member overlaps nothing: no override');

create temp table c1 as select pg_temp.candj(2, pg_temp.d(), 0, '11:00', '12:00') as r;
select is((select pg_temp.of(r, 4) #> '{conflicts,count}' from c1), '1'::jsonb,
  'leader D sees that M already has an overlapping duty');
select is((select pg_temp.of(r, 4) #> '{conflicts,items,0}' from c1),
  jsonb_build_object('visibility', 'limited', 'owner_kind', 'department',
                     'from', pg_temp.utc(0, '10:00'), 'to', pg_temp.utc(0, '12:00')),
  'another department''s duty is disclosed as its busy time only');
select ok((select c1.r::text not like '%SYNTHETIC E private%' and c1.r::text not like '%Ushers%'
                  and c1.r::text not like '%E hall%' and c1.r::text not like '%' || (e1.r #>> '{data,occurrence_id}') || '%'
             from c1, e1),
  'without the other team''s instructions, name, place or ids');
select is((select pg_temp.of(r, 4) -> 'upcoming' from c1), '{"total": 2, "here": 0}'::jsonb,
  'M''s upcoming load: two duties in all (E''s and the cell part), none in D');
select is((select pg_temp.of(r, 5) -> 'conflicts' from c1), '{"count": 0, "items": []}'::jsonb,
  'O has no overlap');
select is((select r -> 'window' from c1),
  jsonb_build_object('from', pg_temp.utc(0, '11:00'), 'to', pg_temp.utc(0, '12:00')), 'the window is the busy time asked about');
select is((select string_agg(c ->> 'account', ',' order by c ->> 'display_name') from c1, jsonb_array_elements(r -> 'candidates') c),
  'app_account,app_account', 'the roster is D''s active members with the leader-level account label');

create temp table refused as select pg_temp.pub(2, pg_temp.d(), 4, 0, '11:00', '12:00') as r;
select is((select r -> 'field_errors' from refused), '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'an overlapping assignment without a reason is refused');
select is((select count(*)::int from app.duties_occurrences where department_id = pg_temp.d()), 0,
  'and nothing was written');
select is(pg_temp.pub(2, pg_temp.d(), 4, 0, '11:00', '12:00', '{"override_reason": "   "}') -> 'field_errors',
  '{"member_id": "overlap", "override_reason": "required"}'::jsonb, 'a blank reason is no reason');
select is(pg_temp.pub(2, pg_temp.d(), 4, 0, '11:00', '12:00', jsonb_build_object('override_reason', repeat('x', 281))) -> 'field_errors',
  '{"override_reason": "invalid"}'::jsonb, 'a reason is at most 280 characters');

create temp table d1 as select pg_temp.pub(2, pg_temp.d(), 4, 0, '11:00', '12:00',
  '{"override_reason": "SYNTHETIC: M agreed to come after the first hour."}') as r;
select is((select (r #>> '{data,override_recorded}') || '|' || (r #>> '{data,response}') from d1), 'true|pending',
  'with a reason the assignment is made and stays Awaiting response');
select is((select a.override_reason || '|' || a.override_overlaps || '|' || (a.override_by_member = pg_temp.mid(2))
                  || '|' || (a.override_at is not null)
             from d1, pg_temp.asg(d1.r) a),
  'SYNTHETIC: M agreed to come after the first hour.|1|true|true', 'the reason, the count, the recorder and the time are recorded');
select is((select au.code || '|' || au.actor_capacity from app.duties_audit au
            where au.action = 'overlap_override' and au.assignment_id = (select (r #>> '{data,assignment_id}')::uuid from d1)),
  'overlap|department_leader', 'the override is audited content-free');
select is((select string_agg(reminder_kind || ':' || job_state, ',') from app.notifications_jobs
            where source_id = (select (r #>> '{data,assignment_id}')::uuid from d1)), 'duty_assigned:pending',
  'the assignee is notified as usual');
select ok((select r::text not like '%SYNTHETIC: M agreed%' from d1), 'the reason is not in the answer (receipts stay content-free)');
select is((select string_agg(a ->> 'response', ',' order by a ->> 'starts_at')
             from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') a),
  'pending,pending', 'M still chooses: both duties await M''s answer (the cell part is not listed yet)');
select ok(pg_temp.readj(4, 'select api.duties_my_duties()')::text not like '%SYNTHETIC: M agreed%',
  'the member never sees the leader''s reason');

-- Projections ------------------------------------------------------------------------------------------
select is((select (pg_temp.board_assignment(2, pg_temp.d(), (r #>> '{data,occurrence_id}')::uuid) -> 'override') - 'at' from d1),
  jsonb_build_object('reason', 'SYNTHETIC: M agreed to come after the first hour.', 'overlaps', 1,
                     'by', 'SYNTHETIC 4.4 Member 2'),
  'leader D''s board shows the recorded override');
select is((select pg_temp.board_assignment(2, pg_temp.d(), (r #>> '{data,occurrence_id}')::uuid) -> 'overlaps' from d1),
  '1'::jsonb, 'and the current overlap count');
select is((select pg_temp.board_assignment(7, pg_temp.d(), (r #>> '{data,occurrence_id}')::uuid) #>> '{override,reason}' from d1),
  'SYNTHETIC: M agreed to come after the first hour.', 'Pastor oversight sees it too');
select is((select (pg_temp.board_assignment(6, pg_temp.e(), (r #>> '{data,occurrence_id}')::uuid) -> 'overlaps')::text
                  || '|' || coalesce(pg_temp.board_assignment(6, pg_temp.e(), (r #>> '{data,occurrence_id}')::uuid) ->> 'override', 'none')
             from e1),
  '1|none', 'leader E sees that E''s duty now overlaps (a count), with no override of its own');
select ok(pg_temp.board(6, pg_temp.e())::text not like '%SYNTHETIC: M agreed%',
  'and never D''s reason');

-- Who sees what ------------------------------------------------------------------------------------------
select is((select pg_temp.of(pg_temp.readj(6, format('select api.duties_candidates(slot_id => %L::uuid)',
                                                      (r #>> '{data,slot_id}'))), 4) #> '{conflicts,items,0,visibility}' from e1),
  '"limited"'::jsonb, 'leader E sees D''s overlapping duty as limited');
select is((select pg_temp.of(pg_temp.readj(6, format('select api.duties_candidates(slot_id => %L::uuid)',
                                                      (r #>> '{data,slot_id}'))), 4) -> 'current' from e1),
  'true'::jsonb, 'and marks M as the position''s current assignee');
create temp table cadm as select pg_temp.candj(1, pg_temp.e(), 0, '10:30', '11:30') as r;
select is((select jsonb_agg(x - 'occurrence_id' - 'from' - 'to' - 'starts_at' - 'ends_at' - 'reporting_at' order by x ->> 'owner_name')
             from cadm, jsonb_array_elements(pg_temp.of(r, 4) #> '{conflicts,items}') x),
  jsonb_build_array(
    jsonb_build_object('visibility', 'full', 'owner_kind', 'department', 'owner_name', 'SYNTHETIC 4.4 Ushers',
                       'duty_name', 'Sunday duty', 'position_name', null, 'state', 'published', 'response', 'pending',
                       'location', 'SYNTHETIC E hall'),
    jsonb_build_object('visibility', 'full', 'owner_kind', 'department', 'owner_name', 'SYNTHETIC Preaching Rota',
                       'duty_name', 'Sunday duty', 'position_name', null, 'state', 'published', 'response', 'pending',
                       'location', null)),
  'an Admin manages both departments and sees both in full');
select ok((select r::text not like '%private instructions%' from cadm), 'instructions are never part of a conflict');

-- The cell-owned fixture -------------------------------------------------------------------------------
select is(pg_temp.of(pg_temp.candj(2, pg_temp.d(), 1, '18:30', '19:30'), 4) #> '{conflicts,items,0}',
  jsonb_build_object('visibility', 'limited', 'owner_kind', 'cell',
                     'from', pg_temp.utc(1, '18:00'), 'to', pg_temp.utc(1, '19:00')),
  'a cell programme part shows to leader D as a busy time only');
select is((pg_temp.of(pg_temp.candj(6, pg_temp.e(), 1, '18:30', '19:30'), 4) #> '{conflicts,items,0}') - 'occurrence_id',
  jsonb_build_object('visibility', 'full', 'owner_kind', 'cell', 'owner_name', null, 'duty_name', 'SYNTHETIC cell part',
                     'position_name', 'Prayer', 'state', 'published', 'response', 'pending',
                     'starts_at', pg_temp.utc(1, '18:00'), 'ends_at', pg_temp.utc(1, '19:00'), 'reporting_at', null,
                     'location', 'SYNTHETIC cell home', 'from', pg_temp.utc(1, '18:00'), 'to', pg_temp.utc(1, '19:00')),
  'the cell''s leader sees the part in full (no instructions)');
select is(pg_temp.candj(1, pg_temp.d(), 1, '18:30', '19:30')::text like '%SYNTHETIC cell part%', false,
  'an Admin role alone gives no cell detail');
select is(pg_temp.pub(2, pg_temp.d(), 4, 1, '18:30', '19:30') -> 'field_errors',
  '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'a cell-owned commitment needs a reason like any other');

-- No overlap -----------------------------------------------------------------------------------------------
select is(pg_temp.of(pg_temp.candj(2, pg_temp.d(), 0, '12:00', '13:00'), 4) #> '{conflicts,count}', '0'::jsonb,
  'a duty that starts when the other ends raises no warning');
create temp table d2 as select pg_temp.pub(2, pg_temp.d(), 4, 0, '12:00', '13:00') as r;
select is((select (r #>> '{data,override_recorded}') || '|' || coalesce(r ->> 'code', 'ok') from d2), 'false|ok',
  'and is published without a reason');
create temp table d3 as select pg_temp.pub(2, pg_temp.d(), 5, 0, '12:00', '13:00',
  '{"override_reason": "SYNTHETIC unused reason"}') as r;
select is((select coalesce(a.override_reason, 'none') || '|' || (d3.r #>> '{data,override_recorded}') from d3, pg_temp.asg(d3.r) a),
  'none|false', 'a reason given without an overlap is not recorded');
select is((select pg_temp.of(pg_temp.candj(2, pg_temp.d(), 0, '09:00', '09:30'), 4) -> 'upcoming'),
  '{"total": 4, "here": 2}'::jsonb, 'upcoming load counts pending duties of every owner');

-- A declined duty is no commitment ---------------------------------------------------------------------
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', r #>> '{data,assignment_id}', 'response', 'declined'))
  from e1;
select is(pg_temp.of(pg_temp.candj(2, pg_temp.d(), 0, '10:00', '10:30'), 4) -> 'conflicts', '{"count": 0, "items": []}'::jsonb,
  'once M declined E''s duty it no longer conflicts');
select is(pg_temp.of(pg_temp.candj(2, pg_temp.d(), 0, '10:00', '10:30'), 4) -> 'upcoming', '{"total": 3, "here": 2}'::jsonb,
  'nor counts as load');

-- Refusals of the read ------------------------------------------------------------------------------------
select is(split_part(pg_temp.cand(4, pg_temp.d(), 0, '11:00', '12:00'), '|', 3), 'not_granted', 'a member cannot read candidates');
select is(split_part(pg_temp.cand(7, pg_temp.d(), 0, '11:00', '12:00'), '|', 3), 'not_granted', 'nor Pastor oversight');
select is(split_part(pg_temp.cand(2, pg_temp.e(), 0, '11:00', '12:00'), '|', 3), 'not_granted',
  'nor the leader of another department');
select is(split_part(pg_temp.read(2, format('select api.duties_candidates(slot_id => %L::uuid)', (r #>> '{data,slot_id}'))), '|', 3),
  'not_granted', 'nor for another department''s position') from e1;
select is(split_part(pg_temp.read(6, format('select api.duties_candidates(slot_id => %L::uuid)', slot_id)), '|', 3),
  'not_granted', 'a cell-owned position has no candidates read (entry 11)') from cell_occ;
select is(split_part(pg_temp.read(2, format('select api.duties_candidates(slot_id => %L::uuid)', gen_random_uuid())), '|', 3),
  'not_granted', 'an unknown position answers the same');
select is(split_part(pg_temp.read(2, format('select api.duties_candidates(slot_id => %L::uuid, department_id => %L::uuid)',
                                            (select r #>> '{data,slot_id}' from d1), pg_temp.d())), '|', 1),
  'PT400', 'a position and a window together are refused');
select is(split_part(pg_temp.cand(2, pg_temp.d(), 0, '12:00', '11:00'), '|', 2), 'validation_failed',
  'an end before the start is refused');

-- Changes to published duties -------------------------------------------------------------------------------
-- O on Sunday 0, 12:00-13:00 (d3) moves to 11:30-12:30: no overlap for O.
-- M's 12:00-13:00 duty (d2) moves to 11:30-12:30: it now overlaps M's 11:00-12:00 duty (d1).
create function pg_temp.revise(n int, p_publish jsonb, p_patch jsonb) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.revise_duty',
    (select revision from app.duties_occurrences where occurrence_id = (p_publish #>> '{data,occurrence_id}')::uuid),
    jsonb_build_object('occurrence_id', p_publish #>> '{data,occurrence_id}') || p_patch)
$$;
select is((select pg_temp.of(pg_temp.readj(2, format(
             'select api.duties_candidates(slot_id => %L::uuid, starts_at => %L::timestamptz, ends_at => %L::timestamptz)',
             r #>> '{data,slot_id}', pg_temp.lt(0, '11:30'), pg_temp.lt(0, '12:30'))), 4) #> '{conflicts,count}' from d2),
  '1'::jsonb, 'the picker can ask about a position at its new times (its own assignment is not a conflict)');
select is((select pg_temp.revise(2, r, jsonb_build_object('starts_at', pg_temp.utc(0, '11:30'), 'ends_at', pg_temp.utc(0, '12:30'),
              'response_deadline', app.cmd_utc(pg_temp.lt(0, '09:00')))) -> 'field_errors' from d2),
  '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'moving a duty into an overlap needs a reason');
select is((select pg_temp.revise(2, r, jsonb_build_object('starts_at', pg_temp.utc(0, '11:30'), 'ends_at', pg_temp.utc(0, '12:30'),
              'response_deadline', app.cmd_utc(pg_temp.lt(0, '09:00')),
              'override_reason', 'SYNTHETIC: short handover.')) #> '{data,overrides}' from d2),
  '1'::jsonb, 'with one the new pending revision records it');
select is((select a.override_reason || '|' || a.response from app.duties_assignments a
            where a.slot_id = (select (r #>> '{data,slot_id}')::uuid from d2) and a.assignment_state = 'current'),
  'SYNTHETIC: short handover.|pending', 'on the new current assignment, still awaiting M''s answer');
create temp table d1_before as select a.* from app.duties_assignments a
 where a.slot_id = (select (r #>> '{data,slot_id}')::uuid from d1) and a.assignment_state = 'current';
select is((select pg_temp.revise(3, r, jsonb_build_object('location', 'SYNTHETIC side room',
              'response_deadline', app.cmd_utc(pg_temp.lt(0, '09:00')))) #>> '{data,change}' from d1),
  'material', 'a place change of the overridden duty is material (asked again) and needs no new reason');
select is((select (a.override_reason = b.override_reason and a.override_at = b.override_at
                   and a.override_by_member = b.override_by_member and a.assignment_id <> b.assignment_id)::text
             from app.duties_assignments a, d1_before b
            where a.slot_id = b.slot_id and a.assignment_state = 'current'),
  'true', 'the same person at the same times keeps the earlier override');

-- Drafts and Publish N -------------------------------------------------------------------------------------
create temp table gen as select pg_temp.duties(2, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'Evening service', 'every', 'week',
  'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'until_date', to_char(pg_temp.sunday(2), 'YYYY-MM-DD'),
  'start_time', '11:00', 'end_time', '12:00', 'positions', jsonb_build_array('Preacher', 'Reader'))) as r;
create function pg_temp.sr() returns uuid language sql as $$ select (r #>> '{data,series_id}')::uuid from gen $$;
create function pg_temp.o(k int) returns uuid language sql as $$
  select occurrence_id from app.duties_occurrences where series_id = pg_temp.sr() order by series_date offset k - 1 limit 1
$$;
create function pg_temp.orev(k int) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = pg_temp.o(k) $$;
create function pg_temp.slot(k int, p int) returns uuid language sql as
$$ select slot_id from app.duties_slots where occurrence_id = pg_temp.o(k) and position_no = p $$;
create function pg_temp.plan(n int, k int, p int, who int, p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.assign_slot', pg_temp.orev(k),
    jsonb_build_object('slot_id', pg_temp.slot(k, p), 'member_id', pg_temp.mid(who)) || p_extra)
$$;
select is(pg_temp.plan(2, 1, 1, 4) -> 'field_errors', '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'planning M as Preacher on Sunday 0 at 11:00 overlaps M''s duties: a reason is needed');
select is(pg_temp.plan(2, 1, 1, 4, '{"override_reason": "SYNTHETIC: M preaches, others cover."}') #> '{data,override_recorded}',
  'true'::jsonb, 'with one the plan is kept');
select is((select draft_override_reason || '|' || (draft_override_by_member = pg_temp.mid(2)) from app.duties_slots
            where slot_id = pg_temp.slot(1, 1)),
  'SYNTHETIC: M preaches, others cover.|true', 'the reason is planned on the position');
select is(pg_temp.plan(2, 1, 1, 4, '{"override_reason": "SYNTHETIC: M preaches, others cover."}') -> 'field_errors',
  '{"slot_id": "unchanged"}'::jsonb, 'the same person with the same reason is unchanged');
select is(pg_temp.plan(2, 1, 1, 4) -> 'field_errors', '{"slot_id": "unchanged"}'::jsonb,
  'the same person without a reason keeps the planned one');
select is(pg_temp.plan(3, 1, 1, 4, '{"override_reason": "SYNTHETIC: agreed with M."}') #> '{data,override_recorded}',
  'true'::jsonb, 'a new reason replaces the planned one');
select is(pg_temp.plan(2, 2, 1, 5) #> '{data,override_recorded}', 'false'::jsonb, 'O on Sunday 1 overlaps nothing');
select is(pg_temp.plan(2, 3, 2, 4) #> '{data,override_recorded}', 'false'::jsonb,
  'M as Reader on Sunday 2 overlaps nothing yet');
select is((select (p #> '{draft,overlaps}') || (p #> '{draft,override_reason}') from jsonb_array_elements(
             (select o -> 'positions' from jsonb_array_elements((select s -> 'occurrences' from jsonb_array_elements(
               (select d -> 'series' from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_rota()') -> 'departments') d
                 where d ->> 'department_id' = pg_temp.d()::text)) s)) o where o ->> 'occurrence_id' = pg_temp.o(1)::text)) p
            where p ->> 'position_no' = '1'),
  '[2, "SYNTHETIC: agreed with M."]'::jsonb, 'the rota shows the planned overlap count and reason');
select is(pg_temp.plan(2, 1, 2, 4) -> 'field_errors', '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'the same person in a second position of the same date overlaps their own plan');
select pg_temp.plan(2, 1, 2, 4, '{"override_reason": "SYNTHETIC: M reads too."}');
-- After planning, M is given an E duty on Sunday 2 at 11:30 (E's gate sees no commitment: drafts
-- of D are D's plans).
create temp table e2 as select pg_temp.pub(6, pg_temp.e(), 4, 2, '11:30', '12:30') as r;
select is((select r #>> '{data,override_recorded}' from e2), 'false', 'D''s drafts are not commitments for E');
create function pg_temp.publish(n int) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.publish_drafts', (select revision from app.duties_series where series_id = pg_temp.sr()),
    jsonb_build_object('series_id', pg_temp.sr(), 'slot_count', 6, 'deadline_before', '1 day'))
$$;
select is(pg_temp.publish(2) -> 'field_errors',
  jsonb_build_object('member_id', 'overlap', 'override_reason', 'required', 'occurrence:' || pg_temp.o(3), 'overlap'),
  'Publish N refuses an overlap that appeared after planning, naming the date');
select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(3), jsonb_build_object(
  'slot_id', pg_temp.slot(3, 2), 'member_id', pg_temp.mid(4), 'override_reason', 'SYNTHETIC: E agreed.'));
create temp table pub as select pg_temp.publish(2) as r;
select is((select r #> '{data,overrides}' from pub), '3'::jsonb, 'once re-planned with a reason, all three overrides are recorded');
select is((select string_agg(coalesce(a.override_reason, '-') || ':' || a.response, ',' order by o.series_date, s.position_no)
             from app.duties_occurrences o join app.duties_slots s using (occurrence_id)
             join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
            where o.series_id = pg_temp.sr()),
  'SYNTHETIC: agreed with M.:pending,SYNTHETIC: M reads too.:pending,-:pending,SYNTHETIC: E agreed.:pending',
  'each planned reason travels with its assignment; O''s plain plan has none; everyone is pending');
select is((select (a.override_by_member = pg_temp.mid(3))::text from app.duties_assignments a
            where a.slot_id = pg_temp.slot(1, 1) and a.assignment_state = 'current'),
  'true', 'attributed to whoever planned it (the deputy)');
select is((select count(*)::int from app.duties_slots s join app.duties_occurrences o using (occurrence_id)
            where o.series_id = pg_temp.sr() and (s.draft_override_reason is not null or s.draft_member_id is not null)),
  0, 'published positions keep no planned reason');

-- Giving a published position ------------------------------------------------------------------------------
select is(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(2), jsonb_build_object(
            'slot_id', pg_temp.slot(2, 2), 'member_id', pg_temp.mid(5),
            'response_deadline', app.cmd_utc(pg_temp.lt(1, '09:00')))) -> 'field_errors',
  '{"member_id": "overlap", "override_reason": "required"}'::jsonb,
  'giving O a second position on the same date needs a reason');
select is(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(2), jsonb_build_object(
            'slot_id', pg_temp.slot(2, 2), 'member_id', pg_temp.mid(5), 'override_reason', 'SYNTHETIC: small team.',
            'response_deadline', app.cmd_utc(pg_temp.lt(1, '09:00')))) #> '{data,override_recorded}',
  'true'::jsonb, 'and records it');

-- This and future ---------------------------------------------------------------------------------------------
create function pg_temp.future(n int, p_extra jsonb) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.revise_series', (select revision from app.duties_series where series_id = pg_temp.sr()),
    jsonb_build_object('series_id', pg_temp.sr(), 'from_occurrence_id', pg_temp.o(1), 'start_time', '10:30',
                       'deadline_before', '1 day') || p_extra)
$$;
select is(pg_temp.future(2, '{}') -> 'field_errors',
  jsonb_build_object('member_id', 'overlap', 'override_reason', 'required', 'occurrence:' || pg_temp.o(1), 'overlap'),
  'new times that keep an overlap need a reason; the date is named');
create temp table fut as select pg_temp.future(2, '{"override_reason": "SYNTHETIC: rota moved, still agreed."}') as r;
select is((select (r #>> '{data,occurrences}') || '|' || (r #>> '{data,overrides}') from fut), '3|5',
  'with one, every new revision that overlaps records it (all five assigned positions)');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
            join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
            where o.series_id = pg_temp.sr() and a.assignment_state = 'current'
              and a.override_reason = 'SYNTHETIC: rota moved, still agreed.' and a.response = 'pending'), 5,
  'and every one of them awaits a fresh answer');

-- A cancelled date is no commitment ---------------------------------------------------------------------
select is(pg_temp.of(pg_temp.candj(6, pg_temp.e(), 2, '10:30', '11:30'), 4) #> '{conflicts,count}', '1'::jsonb,
  'M''s Sunday 2 reading (10:30-12:00) conflicts with an E duty at 10:30');
select pg_temp.duties(2, 'duties.cancel_occurrence', pg_temp.orev(3), jsonb_build_object('occurrence_id', pg_temp.o(3)));
select is(pg_temp.of(pg_temp.candj(6, pg_temp.e(), 2, '10:30', '11:30'), 4) #> '{conflicts,count}', '0'::jsonb,
  'once that date is cancelled it no longer conflicts');

-- Deletion -------------------------------------------------------------------------------------------------
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(5), pg_temp.u(5), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'erasing an overridden assignee leaves nothing of them in Duties');
select is((select count(*)::int from app.duties_assignments
            where member_id = '00000000-0000-0000-0000-000000000000' and override_reason is not null), 0,
  'the leader''s words about them are cleared');
select is((select count(*)::int from app.duties_assignments
            where member_id = '00000000-0000-0000-0000-000000000000' and override_at is not null), 3,
  'the fact that an override was recorded stays (anonymous)');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(3), pg_temp.u(3), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'erasing a recorder anonymises the overrides they recorded');
select is((select count(*)::int from app.duties_assignments
            where override_by_member = '00000000-0000-0000-0000-000000000000' and override_reason is not null), 1,
  'their recorded reasons stay with the nil UUID as recorder');
select throws_ok(
  $$update app.duties_assignments set override_reason = 'changed' where assignment_state <> 'current'
      and override_reason is not null$$,
  'P0001', 'ended duties assignments are immutable', 'an ended assignment''s reason cannot be rewritten');

-- Gate closed (production without Q4) -----------------------------------------------------------------------
select app.platform_set_environment('production', 'pgtap 4.4');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.4 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.4 production check', 'pgtap');
select is(split_part(pg_temp.cand(2, pg_temp.d(), 0, '11:00', '12:00'), '|', 2), 'unavailable',
  'with Q4 closed (production) the candidates read is unavailable');
select app.policy_approve('q4_personal_data', '{}'::jsonb, 'pgtap', 'pgtap 4.4 production check');
select is(split_part(pg_temp.cand(2, pg_temp.d(), 0, '11:00', '12:00'), '|', 3), 'not_granted',
  'and in production a synthetic department has no candidates read');

select * from finish();
rollback;
