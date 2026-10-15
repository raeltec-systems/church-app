-- Expose Duties and Follow-ups owner operations for programmes and later owners (story 4.11; AD-1,
-- AD-2, AD-6, AD-7, AD-18). A SYNTHETIC Cells-like caller (module fixture) creates, revises and
-- cancels a cell-owned position inside its own transaction, links a department duty that stays
-- unchanged and managed only by its department, flags a mismatch the department clears, and is
-- refused a second link for the same part position; a cell leader cannot edit the department
-- duty. Also: registration, authority, stable part/position-to-slot links, the overlap gate, the
-- member's answers to cell parts, the owner reads (no notes, reasons or people of another owner),
-- the linked-event reference and the sermon-draft read, the Follow-ups source operations from the
-- same caller, erasure, privileges and the Q4 gate. HTTP evidence:
-- tools/identity-e2e/duties-owner-ops.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900160-900169). Duty and
-- part times are fixed church-time (Africa/Lusaka) clock times on whole days, never the current
-- clock time.
begin;
select plan(167);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-00000041a1' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-00000041a1' || lpad(n::text, 2, '0'))::uuid $$;
-- 1-7 -> 900160-900166, 9 -> 900167, 10 -> 900168, 11 -> 900169 (8 has no account).
create function pg_temp.phone(n int) returns text language sql as
$$ select '447700900' || (case when n <= 7 then 159 + n else 158 + n end)::text $$;
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
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint,
                             p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', p_request,
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb,
                               p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.call(n, 'duties_command', p_command, p_expected, p_payload, p_request)
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
-- A server-side owner call (the caller's own command body runs as its owner, inside the request
-- of session n; n = 0 is no session). Answers the result, or the refusal as {code, field_errors,
-- current_revision}, or {sqlstate, message} for any other error. A refusal rolls back only this
-- call (a subtransaction), as the caller's whole command would be.
create function pg_temp.fx(n int, p_fn text, p_input jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', case when n = 0 then '' else pg_temp.c(n)::text end, true);
  begin
    execute format('select app.%I($1)', p_fn) into r using p_input;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    if v_state = 'PCMD1' then
      return jsonb_build_object('code', v_msg) || coalesce(v_detail::jsonb, '{}'::jsonb);
    end if;
    return jsonb_build_object('sqlstate', v_state, 'message', v_msg);
  end;
end;
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', r ->> 'sqlstate', 'ok')
         || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                               from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
-- A fixed church-time clock time p_days church days from today (Africa/Lusaka).
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;

-- Accounts: 1 Admin (no scope); 2 leader L of department D; 3 deputy P of D; 4 member M (D);
-- 5 member O; 6 cell leader CL of cell C; 7 Pastor; 8 accountless member X; 9 cell assistant CA of
-- C; 10 leader K of another cell C2; 11 member Q (D).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now()
  from generate_series(1, 11) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 11) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.11');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.11 Member ' || n, 'pgtap 4.11')
  from generate_series(1, 11) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.11 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.11 Preaching Rota"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create temp table cc as
  with ins as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
               values ('SYNTHETIC 4.11 Cell', 'SYNTHETIC area', true, 'pgtap 4.11'),
                      ('SYNTHETIC 4.11 Other Cell', 'SYNTHETIC area', true, 'pgtap 4.11')
               returning cell_id, name)
  select cell_id, name from ins;
create function pg_temp.cell() returns uuid language sql as
$$ select cell_id from cc where name = 'SYNTHETIC 4.11 Cell' $$;
create function pg_temp.cell2() returns uuid language sql as
$$ select cell_id from cc where name = 'SYNTHETIC 4.11 Other Cell' $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'cell_leader', pg_temp.cell());
select pg_temp.grant_scope(9, 'cell_assistant', pg_temp.cell());
select pg_temp.grant_scope(10, 'cell_leader', pg_temp.cell2());
create function pg_temp.add(n int) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = pg_temp.d()),
    jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(n) from unnest(array[2, 3, 4, 11]) n;

-- The SYNTHETIC caller's registrations (tests and the local E2E only).
select app.contract_register_source_type('fixture', 'fixture_programme_part',
                                         'app.fixture_programme_part_check(jsonb)'::regprocedure);
select app.contract_register_source_type('fixture', 'fixture_event',
                                         'app.fixture_event_check(jsonb)'::regprocedure);
select app.contract_register_purpose('fixture', 'fixture_programme_part', 'fill_part');
select app.followups_register_purpose('fixture', 'fixture_programme_part', 'fill_part',
  '{"label": "Fill a programme part", "scope_kinds": ["cell_leader", "cell_assistant"],
    "on_source_resolved": "close", "on_source_cancelled": "close"}'::jsonb);

-- Registration --------------------------------------------------------------------------------------
select lives_ok($$ select app.duties_register_link_source('fixture', 'fixture_programme_part', 'cell_part') $$,
  'the SYNTHETIC caller registers its part source as a cell part');
select lives_ok($$ select app.duties_register_link_source('fixture', 'fixture_event', 'event') $$,
  'and its event source as an event');
select throws_ok($$ select app.duties_register_link_source('fixture', 'cells_signup_option', 'cell_part') $$,
  'PCTR1', null, 'a module registers only a source type it owns');
select throws_ok($$ select app.duties_register_link_source('cells', 'cells_signup_option', 'event') $$,
  'PCTR1', null, 'Cells may not register an event source');
select throws_ok($$ select app.duties_register_link_source('followups', 'followups_task', 'cell_part') $$,
  'PCTR1', null, 'a module without a dependency edge to duties is refused');
select ok(exists (select 1 from app.contract_module_dependencies where from_module = 'fixture' and to_module = 'duties')
          and exists (select 1 from app.contract_module_dependencies where from_module = 'fixture' and to_module = 'followups')
          and not exists (select 1 from app.contract_module_dependencies where from_module = 'duties' and to_module in ('fixture', 'cells')),
  'the fixture stands in for Cells (edges to duties and followups); Duties never depends on its callers');

-- Create a cell-owned part (verify: create) ---------------------------------------------------------
create temp table p1 as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Worship part',
  'starts_at', app.cmd_utc(pg_temp.at(6, '18:00')), 'ends_at', app.cmd_utc(pg_temp.at(6, '19:00')),
  'location', 'SYNTHETIC cell home', 'instructions', 'SYNTHETIC private part instructions',
  'topic', 'SYNTHETIC topic', 'scripture', 'SYNTHETIC 1:1',
  'positions', jsonb_build_array(
    jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(4)),
    jsonb_build_object('position_key', 'second', 'position_name', 'Second')))) as r;
create function pg_temp.p1() returns uuid language sql as $$ select (r ->> 'part_id')::uuid from p1 $$;
create function pg_temp.occ1() returns uuid language sql as $$ select (r ->> 'occurrence_id')::uuid from p1 $$;
create function pg_temp.slot_of(p_part uuid, p_key text) returns uuid language sql as $$
  select slot_id from app.duties_part_links
   where source_type = 'fixture_programme_part' and source_id = p_part and position_key = p_key
     and ended_at is null
$$;
create function pg_temp.cur(p_slot uuid) returns app.duties_assignments language sql as
$$ select a.* from app.duties_assignments a where a.slot_id = p_slot and a.assignment_state = 'current' $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.jobs(p_id uuid, p_kinds text[] default null) returns text language sql as $$
  select coalesce(string_agg(reminder_kind || ':' || job_state, ',' order by enqueued_at, reminder_kind), '')
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = p_id
     and (p_kinds is null or reminder_kind = any (p_kinds))
$$;
create function pg_temp.put(n int, p_part uuid, p_input jsonb) returns jsonb language sql as $$
  select pg_temp.fx(n, 'fixture_programme_publish', jsonb_build_object('part_id', p_part) || p_input)
$$;

select is((select (r ->> 'created') || '|' || (r ->> 'state') || '|' || jsonb_array_length(r -> 'positions')
             from p1), 'true|published|2', 'the caller creates one published part with two positions');
select is((select coalesce(department_id::text, 'none') || '|' || (cell_id = pg_temp.cell())
             from app.duties_occurrences where occurrence_id = pg_temp.occ1()), 'none|true',
  'the occurrence is owned by the cell alone (no department)');
select is((select string_agg(position_key || ':' || link_kind, ',' order by position_key) from app.duties_part_links
            where source_id = pg_temp.p1()), 'lead:owned,second:owned',
  'each part position has its stable owned link');
select is((select count(distinct slot_id)::int from app.duties_part_links where source_id = pg_temp.p1()), 2,
  'one slot per part position');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).response || '|'
          || (pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).deadline_source || '|'
          || (pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).short_notice,
  'pending|default|false', 'M is asked: pending, with the 4.8 default answer-by');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'second'))).assignment_id, null,
  'the unassigned position stays a visible gap');
select is(pg_temp.jobs((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).assignment_id, array['duty_assigned']),
  'duty_assigned:pending', 'M gets the new-duty notice');
select ok(exists (select 1 from app.notifications_schedules s
                   where s.source_type = 'duties_assignment'
                     and s.source_id = (pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).assignment_id),
  'and M''s response reminders are planned (4.8)');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'duties_coverage'
              and j.source_id = (pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).assignment_id), 0,
  'no leader alert for a cell part (department-only until the cell-scope contract)');
select is((select string_agg(action || ':' || actor_capacity, ',' order by event_id) from app.duties_audit
            where occurrence_id = pg_temp.occ1()), 'part_created:cell_leader,duty_revised:cell_leader',
  'audited with the cell leader''s capacity, codes only');
select ok((select r::text not like '%SYNTHETIC private part%' and r::text not like '%SYNTHETIC cell home%' from p1),
  'the answer carries ids, revisions and states only');

create temp table mine as select a from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') a
  where a ->> 'occurrence_id' = pg_temp.occ1()::text;
select is((select (a ->> 'owner_kind') || '|' || coalesce(a ->> 'department_id', 'none') || '|'
                  || coalesce(a ->> 'department_name', 'none') || '|' || (a ->> 'cell_id') from mine),
  'cell|none|none|' || pg_temp.cell(), 'My duties lists the cell part (owner cell, no department)');
select is((select a -> 'leaders' from mine),
  '[{"display_name": "SYNTHETIC 4.11 Member 6", "role": "leader"}, {"display_name": "SYNTHETIC 4.11 Member 9", "role": "assistant"}]'::jsonb,
  'with the cell''s leader and assistant by name');
select is((select a ->> 'instructions' from mine), 'SYNTHETIC private part instructions',
  'the member sees their own part''s instructions');

-- Who may create ------------------------------------------------------------------------------------
create function pg_temp.newpart(n int, p_cell uuid default null) returns jsonb language sql as $$
  select pg_temp.fx(n, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', coalesce(p_cell, pg_temp.cell()), 'duty_name', 'SYNTHETIC refused part',
    'starts_at', app.cmd_utc(pg_temp.at(7, '18:00')),
    'positions', jsonb_build_array(jsonb_build_object('position_key', 'p1'))))
$$;
select is(pg_temp.err(pg_temp.newpart(1)), 'forbidden', 'the Admin role alone is forbidden');
select is(pg_temp.err(pg_temp.newpart(7)), 'forbidden', 'Pastor is forbidden');
select is(pg_temp.err(pg_temp.newpart(2)), 'forbidden', 'a department leader is forbidden');
select is(pg_temp.err(pg_temp.newpart(10)), 'forbidden', 'another cell''s leader is forbidden');
select is(pg_temp.err(pg_temp.newpart(4)), 'forbidden', 'a member is forbidden');
select is(pg_temp.err(pg_temp.newpart(0)), 'forbidden', 'without a session the caller itself refuses');
select is(pg_temp.err(pg_temp.fx(0, 'duties_owner_put_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'source_revision', 1,
    'cell_id', pg_temp.cell(), 'duty_name', 'x', 'starts_at', app.cmd_utc(pg_temp.at(7)),
    'positions', '[{"position_key": "a"}]'::jsonb))), 'unauthenticated',
  'and so does Duties (the actor is the live session, never a payload field)');
select is((select count(*)::int from app.fixture_programme_parts where label = 'SYNTHETIC refused part'), 0,
  'a refused call leaves nothing, not even the caller''s own row (one transaction)');
-- The caller's part moves on (its own command wrote a newer revision); Duties is asked about the
-- old one.
update app.fixture_programme_parts set revision = revision + 1 where part_id = pg_temp.p1();
select is(pg_temp.err(pg_temp.fx(6, 'duties_owner_put_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'source_revision', 1,
    'cell_id', pg_temp.cell(), 'expected_revision', pg_temp.orev(pg_temp.occ1()), 'duty_name', 'x',
    'starts_at', app.cmd_utc(pg_temp.at(7)), 'positions', '[{"position_key": "a"}]'::jsonb))),
  'conflict|source_revision=stale', 'a stale part revision is refused (the caller writes its row first)');
select is(pg_temp.err(pg_temp.fx(6, 'duties_owner_put_part', jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', pg_temp.p1(), 'source_revision', 1,
    'cell_id', pg_temp.cell(), 'duty_name', 'x', 'starts_at', app.cmd_utc(pg_temp.at(7)),
    'positions', '[{"position_key": "a"}]'::jsonb))),
  'validation_failed|source_type=unregistered', 'a source not registered with Duties is refused');
select is(pg_temp.err(pg_temp.fx(6, 'duties_owner_put_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'source_revision', 0,
    'cell_id', pg_temp.cell(), 'duty_name', 'x', 'starts_at', app.cmd_utc(pg_temp.at(7)),
    'positions', '[{"position_key": "a"}]'::jsonb, 'note', 'x'))),
  'validation_failed|note=unknown_field,source_revision=invalid',
  'the part reference follows the v1 source_ref fixtures; unknown keys are refused');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC refused part', 'starts_at', app.cmd_utc(pg_temp.at(7, '18:00')),
    'positions', '[{"position_key": "Lead!"}]'::jsonb))), 'validation_failed|positions=invalid',
  'a position key is a lower-case token or uuid');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC refused part', 'starts_at', app.cmd_utc(pg_temp.at(7, '18:00')),
    'positions', '[{"position_key": "a"}, {"position_key": "a"}]'::jsonb))), 'validation_failed|positions=duplicate',
  'position keys are unique in a part');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC refused part', 'starts_at', app.cmd_utc(pg_temp.at(7, '18:00')),
    'positions', (select jsonb_agg(jsonb_build_object('position_key', 'k' || g)) from generate_series(1, 11) g)))),
  'validation_failed|positions=out_of_range', 'at most ten positions');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC refused part', 'starts_at', app.cmd_utc(pg_temp.at(-1, '18:00')),
    'positions', '[{"position_key": "a"}]'::jsonb))), 'validation_failed|starts_at=past',
  'a part cannot start in the past');
select is(pg_temp.err(pg_temp.put(6, pg_temp.p1(), jsonb_build_object(
    'duty_name', 'SYNTHETIC Worship part', 'starts_at', app.cmd_utc(pg_temp.at(6, '18:00')),
    'positions', '[{"position_key": "lead"}]'::jsonb))), 'validation_failed|expected_revision=required',
  'a revision names the expected occurrence revision');

-- Revise (verify: revise) ---------------------------------------------------------------------------
create temp table m_first as select (pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).assignment_id as id;
create temp table p1r as select pg_temp.put(9, pg_temp.p1(), jsonb_build_object(
  'expected_revision', pg_temp.orev(pg_temp.occ1()), 'duty_name', 'SYNTHETIC Worship part',
  'starts_at', app.cmd_utc(pg_temp.at(6, '18:30')), 'ends_at', app.cmd_utc(pg_temp.at(6, '19:30')),
  'location', 'SYNTHETIC cell home', 'instructions', 'SYNTHETIC private part instructions',
  'topic', 'SYNTHETIC topic', 'scripture', 'SYNTHETIC 1:1',
  'positions', jsonb_build_array(
    jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(5)),
    jsonb_build_object('position_key', 'third', 'position_name', 'Third', 'member_id', pg_temp.mid(8))))) as r;
select is((select pg_temp.err(r) || '|' || (r ->> 'changed') from p1r), 'ok|true',
  'the cell assistant revises the part: new time, another member, one position added and one removed');
select is((select assignment_state || '|' || end_reason || '|' || response from app.duties_assignments
            where assignment_id = (select id from m_first)), 'superseded|revised|pending',
  'M''s assignment is superseded, its answer kept');
select is(pg_temp.jobs((select id from m_first), array['duty_assigned', 'duty_released']),
  'duty_assigned:cancelled,duty_released:pending', 'M''s notice is cancelled and M is told the part is no longer theirs');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).member_id, pg_temp.mid(5),
  'O now holds the lead position');
select is(pg_temp.jobs((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead'))).assignment_id, array['duty_assigned']),
  'duty_assigned:pending', 'O is asked with a new-duty notice (never a phantom re-ask of M)');
select is((select count(*)::int from app.duties_assignments a
            where a.slot_id = pg_temp.slot_of(pg_temp.p1(), 'lead')), 2,
  'two assignments on the lead position: M''s superseded and O''s current (nothing in between)');
select is((select (cancelled_at is not null)::text from app.duties_slots
            where slot_id = (select slot_id from app.duties_part_links where source_id = pg_temp.p1()
                              and position_key = 'second')), 'true', 'the removed position is cancelled');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'third'))).member_id, pg_temp.mid(8),
  'the added position asks the accountless member X');
select is((select starts_at = pg_temp.at(6, '18:30') from app.duties_occurrences where occurrence_id = pg_temp.occ1()),
  true, 'the part''s new time is stored');
select is((select count(*)::int from app.duties_part_links where source_id = pg_temp.p1()), 3,
  'the links stay stable: lead, the cancelled second and third');
select is((select source_revision from app.duties_part_links where source_id = pg_temp.p1() and position_key = 'lead'),
  (select revision from app.fixture_programme_parts where part_id = pg_temp.p1()),
  'the links remember the caller''s latest part revision');

create function pg_temp.lead_put(n int, p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.put(n, pg_temp.p1(), jsonb_build_object(
    'expected_revision', pg_temp.orev(pg_temp.occ1()), 'duty_name', 'SYNTHETIC Worship part',
    'starts_at', app.cmd_utc(pg_temp.at(6, '18:30')), 'ends_at', app.cmd_utc(pg_temp.at(6, '19:30')),
    'location', 'SYNTHETIC cell home', 'instructions', 'SYNTHETIC private part instructions',
    'topic', 'SYNTHETIC topic', 'scripture', 'SYNTHETIC 1:1',
    'positions', jsonb_build_array(
      jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(5)),
      jsonb_build_object('position_key', 'third', 'position_name', 'Third', 'member_id', pg_temp.mid(8))))
    || p_extra)
$$;
create temp table same as select pg_temp.orev(pg_temp.occ1()) as rev,
  (select count(*) from app.duties_assignments) as asg;
select is((select (r ->> 'changed') from (select pg_temp.lead_put(6) as r) x), 'false',
  'an identical put changes nothing (a republish creates no duplicate)');
select is(pg_temp.orev(pg_temp.occ1()) || '|' || (select count(*) from app.duties_assignments),
          (select rev || '|' || asg from same), 'no revision and no assignment were added');
select is(pg_temp.err(pg_temp.lead_put(6, jsonb_build_object('expected_revision', pg_temp.orev(pg_temp.occ1()) - 1))),
  'conflict', 'a stale expected revision is a conflict');
select is((pg_temp.lead_put(6, jsonb_build_object('expected_revision', pg_temp.orev(pg_temp.occ1()) - 1)) ->> 'current_revision')::bigint,
  pg_temp.orev(pg_temp.occ1()), 'naming the current revision');
select is(pg_temp.err(pg_temp.lead_put(6, jsonb_build_object('positions', jsonb_build_array(
    jsonb_build_object('position_key', 'lead', 'position_name', 'Leader', 'member_id', pg_temp.mid(5)))))),
  'validation_failed|position:lead=renamed', 'a renamed position is refused (a new key is a new position)');
select is(pg_temp.err(pg_temp.lead_put(6, jsonb_build_object('positions', jsonb_build_array(
    jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(5)),
    jsonb_build_object('position_key', 'second', 'position_name', 'Second'))))),
  'validation_failed|position:second=cancelled', 'a cancelled key is never given again');
select is(pg_temp.err(pg_temp.lead_put(6, jsonb_build_object('instructions', 'SYNTHETIC new note',
    'response_deadline', app.cmd_utc(pg_temp.at(5, '18:00'))))),
  'validation_failed|response_deadline=not_material', 'an answer-by with a notes-only change is refused');

-- The member answers a cell part (4.5 paths, since 4.11) ------------------------------------------
create function pg_temp.olead() returns app.duties_assignments language sql as
$$ select pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'lead')) $$;
select is(pg_temp.duties(5, 'duties.respond', (pg_temp.olead()).revision,
            jsonb_build_object('assignment_id', (pg_temp.olead()).assignment_id, 'response', 'accepted')) #>> '{data,response}',
  'accepted', 'O accepts the cell part from My duties');
select is(pg_temp.jobs((pg_temp.olead()).assignment_id, array['duty_assigned']), 'duty_assigned:cancelled',
  'the notice is cancelled by the answer');
select is(pg_temp.err(pg_temp.lead_put(9, '{"instructions": "SYNTHETIC updated part note"}')), 'ok',
  'a notes-only change of the part');
select is((pg_temp.olead()).response, 'accepted', 'keeps O''s acceptance');
select is(pg_temp.jobs((pg_temp.olead()).assignment_id, array['duty_updated']), 'duty_updated:pending',
  'and sends O a details-updated notice');
select is(pg_temp.err(pg_temp.lead_put(9, jsonb_build_object('instructions', 'SYNTHETIC updated part note',
    'starts_at', app.cmd_utc(pg_temp.at(6, '18:45'))))), 'ok', 'a material change of the part');
select is((pg_temp.olead()).response || '|' || (pg_temp.olead()).member_id::text, 'pending|' || pg_temp.mid(5),
  'asks O again (a new pending revision for the same person)');
select is(pg_temp.duties(5, 'duties.withdraw_acceptance', 1,
            jsonb_build_object('assignment_id', (select id from m_first))) ->> 'code', 'not_found',
  'O cannot touch M''s old assignment');
select is(pg_temp.duties(4, 'duties.respond', (select revision from app.duties_assignments where assignment_id = (select id from m_first)),
            jsonb_build_object('assignment_id', (select id from m_first), 'response', 'accepted')) -> 'field_errors',
  '{"assignment_id": "superseded", "member_id": "changed", "starts_at": "changed", "ends_at": "changed", "instructions": "changed"}'::jsonb,
  'M''s late answer to the old revision is refused with what changed');

-- Overlap gate (4.4) ---------------------------------------------------------------------------------
create temp table dq as select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'member_id', pg_temp.mid(11), 'duty_name', 'SYNTHETIC Evening ushering',
  'starts_at', app.cmd_utc(pg_temp.at(6, '18:00')), 'ends_at', app.cmd_utc(pg_temp.at(6, '20:00')),
  'instructions', 'SYNTHETIC department private instructions')) as r;
select is(pg_temp.err(pg_temp.lead_put(6, jsonb_build_object('instructions', 'SYNTHETIC updated part note',
    'starts_at', app.cmd_utc(pg_temp.at(6, '18:45')), 'positions', jsonb_build_array(
      jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(5)),
      jsonb_build_object('position_key', 'third', 'position_name', 'Third', 'member_id', pg_temp.mid(11)))))),
  'validation_failed|member_id=overlap,override_reason=required',
  'giving Q a part over Q''s department duty needs a reason');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'third'))).member_id, pg_temp.mid(8),
  'and nothing changed (X still holds the position)');
create temp table ov as select pg_temp.lead_put(6, jsonb_build_object('instructions', 'SYNTHETIC updated part note',
    'starts_at', app.cmd_utc(pg_temp.at(6, '18:45')),
    'override_reason', 'SYNTHETIC: Q leaves ushering early for the cell.',
    'positions', jsonb_build_array(
      jsonb_build_object('position_key', 'lead', 'position_name', 'Lead', 'member_id', pg_temp.mid(5)),
      jsonb_build_object('position_key', 'third', 'position_name', 'Third', 'member_id', pg_temp.mid(11))))) as r;
select is((select (r ->> 'overrides_recorded') from ov), '1', 'with a reason the override is recorded');
select ok((select r::text not like '%Q leaves ushering%' from ov), 'the reason is not in the answer');
select is((pg_temp.cur(pg_temp.slot_of(pg_temp.p1(), 'third'))).override_reason,
  'SYNTHETIC: Q leaves ushering early for the cell.', 'it is stored with Q''s assignment');

-- Link a department duty (verify: link, unchanged, managed only by its department) -----------------
create temp table dl as select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'member_id', pg_temp.mid(11), 'duty_name', 'SYNTHETIC Cell preaching',
  'starts_at', app.cmd_utc(pg_temp.at(8, '18:00')), 'ends_at', app.cmd_utc(pg_temp.at(8, '19:00')),
  'instructions', 'SYNTHETIC preaching private instructions')) as r;
create function pg_temp.docc() returns uuid language sql as $$ select (r #>> '{data,occurrence_id}')::uuid from dl $$;
create function pg_temp.dslot() returns uuid language sql as $$
  select slot_id from app.duties_assignments where assignment_id = (select (r #>> '{data,assignment_id}')::uuid from dl)
$$;
create temp table dbefore as
  select (select to_jsonb(o) from app.duties_occurrences o where o.occurrence_id = pg_temp.docc()) as occ,
         (select to_jsonb(a) from app.duties_assignments a where a.slot_id = pg_temp.dslot()) as asg,
         (select count(*) from app.notifications_jobs j
           where j.source_id = (select (r #>> '{data,assignment_id}')::uuid from dl)) as jobs;
create temp table p2 as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Study part',
  'starts_at', app.cmd_utc(pg_temp.at(8, '19:00')), 'ends_at', app.cmd_utc(pg_temp.at(8, '20:00')),
  'positions', jsonb_build_array(jsonb_build_object('position_key', 'host', 'member_id', pg_temp.mid(4))))) as r;
create function pg_temp.p2() returns uuid language sql as $$ select (r ->> 'part_id')::uuid from p2 $$;
create temp table l1 as select pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
  'part_id', pg_temp.p2(), 'position_key', 'preacher', 'slot_id', pg_temp.dslot())) as r;
select is((select pg_temp.err(r) || '|' || (r ->> 'kind') from l1), 'ok|linked',
  'the cell leader display-links the part''s preacher to the department duty');
select is((select to_jsonb(o) from app.duties_occurrences o where o.occurrence_id = pg_temp.docc()),
          (select occ from dbefore), 'the department duty is unchanged (no clone, same revision)');
select is((select to_jsonb(a) from app.duties_assignments a where a.slot_id = pg_temp.dslot()),
          (select asg from dbefore), 'its assignment and answer are unchanged');
select is((select count(*) from app.notifications_jobs j
            where j.source_id = (select (r #>> '{data,assignment_id}')::uuid from dl)),
          (select jobs from dbefore), 'and no notice or reminder was added');
select is((select count(*)::int from app.duties_occurrences where duty_name = 'SYNTHETIC Cell preaching'), 1,
  'there is still exactly one such duty');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
    'part_id', pg_temp.p2(), 'position_key', 'preacher', 'slot_id', pg_temp.dslot()))),
  'conflict|position_key=linked', 'a second link for the same part position is refused');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
    'part_id', pg_temp.p2(), 'position_key', 'host', 'slot_id', pg_temp.dslot()))),
  'conflict|position_key=linked', 'an owned position key cannot become a display link');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
    'part_id', pg_temp.p2(), 'position_key', 'other', 'slot_id', pg_temp.slot_of(pg_temp.p1(), 'lead')))),
  'not_found', 'a cell-owned position is not linkable');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
    'part_id', pg_temp.p2(), 'position_key', 'other', 'slot_id', gen_random_uuid()))),
  'not_found', 'an unknown position is not found');
select is(pg_temp.err(pg_temp.fx(10, 'duties_owner_link_duty', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p2(),
    'source_revision', (select revision from app.fixture_programme_parts where part_id = pg_temp.p2()),
    'cell_id', pg_temp.cell(), 'position_key', 'other', 'slot_id', pg_temp.dslot()))),
  'forbidden', 'another cell''s leader cannot link for this cell');
select is((select (d ->> 'linked_parts')::int
             from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') #> '{departments,0,duties}') d
            where d ->> 'occurrence_id' = pg_temp.docc()::text), 1,
  'the department''s board shows that one programme part links the duty');

create temp table part2 as select pg_temp.fx(6, 'duties_owner_part', jsonb_build_object(
  'source_type', 'fixture_programme_part', 'source_id', pg_temp.p2(), 'cell_id', pg_temp.cell())) as r;
select is((select p - 'link_id' - 'slot_id' - 'occurrence_id' - 'department_id' - 'starts_at' - 'ends_at' - 'linked_at'
             from part2, jsonb_array_elements(r -> 'positions') p where p ->> 'kind' = 'linked'),
  '{"kind": "linked", "position_key": "preacher", "department_name": "SYNTHETIC 4.11 Preaching Rota", "duty_name": "SYNTHETIC Cell preaching", "position_name": null, "reporting_at": null, "state": "published", "cancelled": false, "filled": true}'::jsonb,
  'the cell sees the linked duty''s name, times, state and that it is filled');
select ok((select r::text not like '%' || pg_temp.mid(11) || '%' and r::text not like '%Member 11%'
                  and r::text not like '%preaching private%' from part2),
  'but never the department''s assignee, answer or instructions');

-- A cell leader cannot edit the department duty --------------------------------------------------------
select is(pg_temp.duties(6, 'duties.revise_duty', pg_temp.orev(pg_temp.docc()), jsonb_build_object(
    'occurrence_id', pg_temp.docc(), 'location', 'SYNTHETIC moved by the cell')) ->> 'code', 'forbidden',
  'a cell leader cannot revise the linked department duty');
select is(pg_temp.duties(6, 'duties.cancel_position', pg_temp.orev(pg_temp.docc()), jsonb_build_object(
    'slot_id', pg_temp.dslot())) ->> 'code', 'forbidden', 'nor cancel its position');
select is(pg_temp.duties(6, 'duties.assign_slot', pg_temp.orev(pg_temp.docc()), jsonb_build_object(
    'slot_id', pg_temp.dslot(), 'member_id', pg_temp.mid(4))) ->> 'code', 'forbidden', 'nor reassign it');
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.docc()), jsonb_build_object(
    'occurrence_id', pg_temp.docc(), 'instructions', 'SYNTHETIC department note')) #>> '{data,change}', 'notes',
  'its department still manages it');
select is((select count(*)::int from app.duties_part_links where slot_id = pg_temp.dslot() and ended_at is null), 1,
  'and the display link survives the department''s edit');

-- Owner-review mismatch (verify: flag and clear) --------------------------------------------------------
create temp table dbefore2 as
  select (select to_jsonb(o) from app.duties_occurrences o where o.occurrence_id = pg_temp.docc()) as occ,
         (select count(*) from app.notifications_jobs) as jobs;
select is(pg_temp.fx(6, 'fixture_programme_changed', jsonb_build_object('part_id', pg_temp.p2(),
    'changed', '["time"]'::jsonb)) ->> 'flagged', '1', 'the meeting moved: the linked department duty is flagged');
select is((select to_jsonb(o) from app.duties_occurrences o where o.occurrence_id = pg_temp.docc()),
          (select occ from dbefore2), 'the duty itself is not rescheduled or republished');
select is((select count(*) from app.notifications_jobs), (select jobs from dbefore2),
  'no reminder or notice is created or reset');
select is(pg_temp.fx(6, 'fixture_programme_changed', jsonb_build_object('part_id', pg_temp.p2(),
    'changed', '["place"]'::jsonb)) ->> 'flagged', '1', 'a second change');
create function pg_temp.reviews(n int) returns jsonb language sql as $$
  select d -> 'reviews'
    from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_leader_board()') #> '{departments,0,duties}') d
   where d ->> 'occurrence_id' = pg_temp.docc()::text
$$;
select is((select jsonb_agg(x - 'flag_id' - 'flagged_at' - 'updated_at') from jsonb_array_elements(pg_temp.reviews(2)) x),
  '[{"source": "cell_part", "changed": ["place", "time"], "revision": 2}]'::jsonb,
  'merges into the one open review the department sees (codes only)');
create function pg_temp.flag() returns app.duties_review_flags language sql as
$$ select f.* from app.duties_review_flags f where f.occurrence_id = pg_temp.docc() and f.cleared_at is null $$;
select is(pg_temp.duties(6, 'duties.clear_review', (pg_temp.flag()).revision,
    jsonb_build_object('flag_id', (pg_temp.flag()).flag_id)) ->> 'code', 'forbidden',
  'the cell leader cannot clear the department''s review');
select is(pg_temp.duties(7, 'duties.clear_review', (pg_temp.flag()).revision,
    jsonb_build_object('flag_id', (pg_temp.flag()).flag_id)) ->> 'code', 'forbidden', 'nor can Pastor');
select is(pg_temp.duties(2, 'duties.clear_review', 1,
    jsonb_build_object('flag_id', (pg_temp.flag()).flag_id)) ->> 'code', 'conflict',
  'a stale review revision is a conflict');
create temp table clr as select gen_random_uuid() as req, (pg_temp.flag()).flag_id as id, (pg_temp.flag()).revision as rev;
create temp table clr1 as select pg_temp.duties(2, 'duties.clear_review', (select rev from clr),
  jsonb_build_object('flag_id', (select id from clr)), (select req from clr)) as r;
select is((select r #>> '{data,cleared}' from clr1), 'true', 'the department''s leader marks it reviewed');
select is(pg_temp.reviews(2), '[]'::jsonb, 'the board shows no open review');
select is(pg_temp.duties(2, 'duties.clear_review', (select rev from clr),
            jsonb_build_object('flag_id', (select id from clr)), (select req from clr)) -> 'data',
          (select r -> 'data' from clr1), 'a replay answers the original result');
select is(pg_temp.duties(3, 'duties.clear_review', (select rev from clr) + 1,
    jsonb_build_object('flag_id', (select id from clr))) -> 'field_errors', '{"flag_id": "cleared"}'::jsonb,
  'clearing it again is refused');
select is((select cleared_by_member from app.duties_review_flags where flag_id = (select id from clr)), pg_temp.mid(2),
  'who cleared it is recorded');
select is((select to_jsonb(o) - 'revision' - 'instructions' from app.duties_occurrences o where o.occurrence_id = pg_temp.docc()),
          (select occ - 'revision' - 'instructions' from dbefore), 'the duty kept its own details throughout');

-- The linked-event reference -----------------------------------------------------------------------------
insert into app.fixture_events (title) values ('SYNTHETIC 4.11 Event');
create function pg_temp.ev() returns uuid language sql as $$ select event_id from app.fixture_events where title = 'SYNTHETIC 4.11 Event' $$;
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.docc()), jsonb_build_object(
    'occurrence_id', pg_temp.docc(), 'event_ref', pg_temp.ev())) #>> '{data,change}', 'reference',
  'the department names the event on its duty (a reference change, no notice)');
create temp table el as select pg_temp.fx(1, 'duties_owner_event_links', jsonb_build_object(
  'source_type', 'fixture_event', 'source_id', pg_temp.ev())) as r;
select is((select jsonb_agg(x - 'starts_at') from el, jsonb_array_elements(r -> 'duties') x),
  jsonb_build_array(jsonb_build_object('occurrence_id', pg_temp.docc(), 'department_id', pg_temp.d(),
                                       'revision', pg_temp.orev(pg_temp.docc()), 'state', 'published',
                                       'review_open', false)),
  'the event''s owner reads the duties that name it (ids and states only)');
select is(pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
    'changed', '["time", "place"]'::jsonb)) ->> 'flagged', '1', 'the event moved: the duty is flagged');
select is((select jsonb_agg(x ->> 'source') from jsonb_array_elements(pg_temp.reviews(3)) x), '["event"]'::jsonb,
  'the deputy sees the event review');
select is((select x ->> 'review_open' from jsonb_array_elements(pg_temp.fx(1, 'duties_owner_event_links',
    jsonb_build_object('source_type', 'fixture_event', 'source_id', pg_temp.ev())) -> 'duties') x), 'true',
  'and the event''s owner sees that a review is open');
select is(pg_temp.err(pg_temp.fx(1, 'duties_owner_event_links', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.ev()))), 'validation_failed|source_type=unregistered',
  'only a registered event source has event links');

-- Unlink ---------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_unlink', jsonb_build_object('part_id', pg_temp.p2(),
    'position_key', 'host'))), 'validation_failed|position_key=owned', 'an owned link is permanent');
select is(pg_temp.fx(6, 'fixture_programme_unlink', jsonb_build_object('part_id', pg_temp.p2(),
    'position_key', 'preacher')) ->> 'ended', 'true', 'a display link ends');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_link', jsonb_build_object(
    'part_id', pg_temp.p2(), 'position_key', 'preacher', 'slot_id', pg_temp.dslot()))), 'ok',
  'and the position may link again');
select throws_ok(format('update app.duties_part_links set slot_id = %L where source_id = %L and position_key = %L',
                        pg_temp.dslot(), pg_temp.p1(), 'lead'),
  'P0001', 'duties part links are permanent', 'a link never moves to another slot');
select throws_ok(format('delete from app.duties_part_links where source_id = %L', pg_temp.p1()),
  'P0001', 'duties part links are permanent', 'nor is it deleted');

-- Reads -----------------------------------------------------------------------------------------------
create temp table part1 as select pg_temp.fx(9, 'duties_owner_part', jsonb_build_object(
  'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'cell_id', pg_temp.cell())) as r;
select is((select string_agg(p ->> 'position_key' || ':' || (p ->> 'cancelled') || ':'
                             || coalesce(p #>> '{assignment,response}', '-'), ',' order by p ->> 'position_no')
             from part1, jsonb_array_elements(r -> 'positions') p),
  'lead:false:pending,second:true:-,third:false:pending', 'the assistant reads the part''s positions and answers');
select ok((select r::text not like '%Q leaves ushering%' and r::text not like '%"note"%' from part1),
  'without notes or override reasons');
select is(pg_temp.err(pg_temp.fx(10, 'duties_owner_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'cell_id', pg_temp.cell()))),
  'forbidden', 'another cell''s leader cannot read it');
select is(pg_temp.err(pg_temp.fx(10, 'duties_owner_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'cell_id', pg_temp.cell2()))),
  'not_found', 'not even through their own cell');

create temp table cf as select pg_temp.fx(6, 'duties_owner_conflicts', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'member_id', pg_temp.mid(11),
  'starts_at', app.cmd_utc(pg_temp.at(6, '18:00')), 'ends_at', app.cmd_utc(pg_temp.at(6, '19:00')))) as r;
select is((select r ->> 'count' from cf), '2', 'the cell leader sees Q''s two commitments at that time');
select is((select string_agg(i ->> 'owner_kind' || ':' || (i ->> 'visibility'), ',' order by i ->> 'owner_kind') from cf,
             jsonb_array_elements(r -> 'items') i),
  'cell:full,department:limited', 'the cell''s own part in full, the department duty as a busy time only');
select ok((select r::text not like '%department private%' and r::text not like '%Evening ushering%' from cf),
  'never the other team''s name or instructions');

select is((select (r ->> 'topic') || '|' || (r ->> 'scripture') || '|' || (r ->> 'owner_kind') || '|' || (r ->> 'assigned')
             from (select pg_temp.fx(5, 'duties_owner_topic', jsonb_build_object('occurrence_id', pg_temp.occ1())) as r) x),
  'SYNTHETIC topic|SYNTHETIC 1:1|cell|true', 'the sermon-draft read: the part''s assignee reads its topic and scripture');
select is(pg_temp.err(pg_temp.fx(4, 'duties_owner_topic', jsonb_build_object('occurrence_id', pg_temp.occ1()))),
  'not_found', 'a member no longer assigned does not');
select is(pg_temp.fx(2, 'duties_owner_topic', jsonb_build_object('occurrence_id', pg_temp.docc())) ->> 'assigned',
  'false', 'the department''s leader reads its duty''s reference');
select is(pg_temp.err(pg_temp.fx(6, 'duties_owner_topic', jsonb_build_object('occurrence_id', pg_temp.docc()))),
  'not_found', 'a cell leader does not read a department duty through a link');

-- Follow-ups source operations from the same caller ----------------------------------------------------
create temp table p3 as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Prayer part',
  'starts_at', app.cmd_utc(pg_temp.at(9, '18:00')),
  'positions', '[{"position_key": "prayer"}]'::jsonb)) as r;
create function pg_temp.p3() returns uuid language sql as $$ select (r ->> 'part_id')::uuid from p3 $$;
select is((select pg_temp.err(r) from p3), 'ok', 'a part with a gap');
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_open_followup', jsonb_build_object(
    'part_id', pg_temp.p3(), 'owner_member_id', pg_temp.mid(9), 'supervisor_member_id', pg_temp.mid(6),
    'next_action', 'SYNTHETIC find someone to pray', 'due_at', app.cmd_utc(pg_temp.at(8, '18:00'))))), 'ok',
  'the caller opens its fill_part follow-up through followups_open_task');
select is((select task_state || '|' || owner_member_id::text from app.followups_tasks
            where source_type = 'fixture_programme_part' and source_id = pg_temp.p3()), 'open|' || pg_temp.mid(9),
  'one open task for the part, owned by the cell assistant');
select is(pg_temp.err(pg_temp.put(6, pg_temp.p3(), jsonb_build_object(
    'expected_revision', pg_temp.orev((select (r ->> 'occurrence_id')::uuid from p3)),
    'duty_name', 'SYNTHETIC Prayer part', 'starts_at', app.cmd_utc(pg_temp.at(9, '18:00')),
    'positions', jsonb_build_array(jsonb_build_object('position_key', 'prayer', 'member_id', pg_temp.mid(4)))))), 'ok',
  'the gap is filled');
select is((select task_state || '|' || close_code from app.followups_tasks
            where source_type = 'fixture_programme_part' and source_id = pg_temp.p3()), 'closed|source_resolved',
  'and the source event closes the task (its registered effect)');

-- Cancel, and create-revise-cancel in one transaction (verify) -----------------------------------------
create temp table c1 as select pg_temp.fx(9, 'fixture_programme_cancel', jsonb_build_object(
  'part_id', pg_temp.p2(), 'expected_revision', pg_temp.orev((select (r ->> 'occurrence_id')::uuid from p2)))) as r;
select is((select (r ->> 'state') || '|' || (r ->> 'assignments_cancelled') || '|' || (r ->> 'links_ended') from c1),
  'cancelled|1|1', 'cancelling a part cancels its assignment and ends its display link');
select is(pg_temp.jobs((select (p ->> 'assignment_id')::uuid from p2, jsonb_array_elements(r -> 'positions') p limit 1),
                       array['duty_cancelled']), 'duty_cancelled:pending', 'M is told');
select is((select to_jsonb(o) - 'revision' - 'instructions' - 'event_ref' from app.duties_occurrences o
            where o.occurrence_id = pg_temp.docc()),
          (select occ - 'revision' - 'instructions' - 'event_ref' from dbefore),
  'the formerly linked department duty is untouched');
select is(pg_temp.err(pg_temp.put(6, pg_temp.p2(), jsonb_build_object(
    'expected_revision', pg_temp.orev((select (r ->> 'occurrence_id')::uuid from p2)),
    'duty_name', 'SYNTHETIC Study part', 'starts_at', app.cmd_utc(pg_temp.at(8, '19:00')),
    'positions', '[{"position_key": "host"}]'::jsonb))), 'validation_failed|source_id=cancelled',
  'a cancelled part cannot be revised');

create function pg_temp.one_transaction() returns text language plpgsql as $$
declare
  r jsonb;
  v_part uuid;
  v_occ uuid;
begin
  perform set_config('request.jwt.claims', pg_temp.c(6)::text, true);
  r := app.fixture_programme_publish(jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC One-transaction part',
    'starts_at', app.cmd_utc(pg_temp.at(10, '18:00')),
    'positions', jsonb_build_array(jsonb_build_object('position_key', 'solo', 'member_id', pg_temp.mid(4)))));
  v_part := (r ->> 'part_id')::uuid;
  v_occ := (r ->> 'occurrence_id')::uuid;
  r := app.fixture_programme_publish(jsonb_build_object(
    'part_id', v_part, 'expected_revision', r -> 'revision', 'duty_name', 'SYNTHETIC One-transaction part',
    'starts_at', app.cmd_utc(pg_temp.at(10, '18:00')),
    'positions', jsonb_build_array(jsonb_build_object('position_key', 'solo', 'member_id', pg_temp.mid(5)))));
  r := app.fixture_programme_cancel(jsonb_build_object('part_id', v_part, 'expected_revision', r -> 'revision'));
  return (select o.occurrence_state from app.duties_occurrences o where o.occurrence_id = v_occ) || '|'
         || (select string_agg(a.assignment_state || ':' || coalesce(a.end_reason, '-'), ','
                           order by a.supersedes_assignment_id nulls first)
               from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
              where s.occurrence_id = v_occ);
end;
$$;
select is(pg_temp.one_transaction(), 'cancelled|superseded:revised,cancelled:cancelled',
  'one caller transaction creates, revises and cancels a cell-owned position');
create function pg_temp.rolled_back() returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', pg_temp.c(6)::text, true);
  begin
    perform app.fixture_programme_publish(jsonb_build_object(
      'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Rolled-back part',
      'starts_at', app.cmd_utc(pg_temp.at(10, '19:00')),
      'positions', jsonb_build_array(jsonb_build_object('position_key', 'solo', 'member_id', pg_temp.mid(4)))));
    -- The caller's next step fails, so its whole command (and Duties' work in it) rolls back.
    perform app.cmd_fail('conflict');
  exception when sqlstate 'PCMD1' then
    null;
  end;
  return (select count(*) from app.duties_occurrences where duty_name = 'SYNTHETIC Rolled-back part') || '|'
         || (select count(*) from app.fixture_programme_parts where label = 'SYNTHETIC Rolled-back part');
end;
$$;
select is(pg_temp.rolled_back(), '0|0', 'a failure later in the caller''s transaction leaves no Duties row behind');

-- Accountless member: the need is recorded and shown to the part's owner ------------------------------
create temp table p4 as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC Welcome part',
  'starts_at', app.cmd_utc(pg_temp.at(9, '19:00')),
  'positions', jsonb_build_array(jsonb_build_object('position_key', 'welcome', 'member_id', pg_temp.mid(8))))) as r;
select ok(pg_temp.run() is not null, 'the worker routes the accountless member''s notice');
select is((select p ->> 'position_key' || ':' || (p #>> '{assignment,needs_contact}')
             from jsonb_array_elements(pg_temp.fx(6, 'duties_owner_part', jsonb_build_object(
                    'source_type', 'fixture_programme_part', 'source_id', (select (r ->> 'part_id')::uuid from p4),
                    'cell_id', pg_temp.cell())) -> 'positions') p), 'welcome:true',
  'the cell sees that X needs direct contact (never why)');

-- Review fixes (independent review of 4.11) ----------------------------------------------------------
-- S1: a part belongs to its cell; another cell's leader naming their own cell finds nothing.
create temp table pc as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC C1 part',
  'starts_at', app.cmd_utc(pg_temp.at(11, '18:00')),
  'positions', jsonb_build_array(jsonb_build_object('position_key', 'host', 'member_id', pg_temp.mid(4))))) as r;
create function pg_temp.pc() returns uuid language sql as $$ select (r ->> 'part_id')::uuid from pc $$;
create function pg_temp.pcrev() returns bigint language sql as
$$ select revision from app.fixture_programme_parts where part_id = pg_temp.pc() $$;
select is(pg_temp.err(pg_temp.fx(10, 'duties_owner_put_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.pc(), 'source_revision', pg_temp.pcrev(),
    'cell_id', pg_temp.cell2(), 'expected_revision', pg_temp.orev((select (r ->> 'occurrence_id')::uuid from pc)),
    'duty_name', 'SYNTHETIC taken over', 'starts_at', app.cmd_utc(pg_temp.at(11, '18:00')),
    'positions', '[{"position_key": "host"}]'::jsonb))), 'not_found',
  'review S1: another cell''s leader cannot revise a cell''s part by naming their own cell');
select is(pg_temp.err(pg_temp.fx(10, 'duties_owner_link_duty', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.pc(), 'source_revision', pg_temp.pcrev(),
    'cell_id', pg_temp.cell2(), 'position_key', 'other', 'slot_id', pg_temp.dslot()))), 'not_found',
  'review S1: nor link a position of it');
select is((select count(*)::int || '|' || bool_and(cell_id = pg_temp.cell()) from app.duties_part_links
            where source_id = pg_temp.pc()), '1|true', 'the part and its links stay with its own cell');
select is((select duty_name from app.duties_occurrences where occurrence_id = (select (r ->> 'occurrence_id')::uuid from pc)),
  'SYNTHETIC C1 part', 'and its occurrence is unchanged');

-- S4: accepting, then withdrawing a cell part.
create function pg_temp.pca() returns app.duties_assignments language sql as
$$ select pg_temp.cur(pg_temp.slot_of(pg_temp.pc(), 'host')) $$;
select is(pg_temp.duties(4, 'duties.respond', (pg_temp.pca()).revision,
            jsonb_build_object('assignment_id', (pg_temp.pca()).assignment_id, 'response', 'accepted')) #>> '{data,response}',
  'accepted', 'review S4: M accepts the cell part');
select is(pg_temp.jobs((pg_temp.pca()).assignment_id, array['duty_starting']), 'duty_starting:pending',
  'its pre-service reminder is planned');
select is(pg_temp.duties(4, 'duties.withdraw_acceptance', (pg_temp.pca()).revision,
            jsonb_build_object('assignment_id', (pg_temp.pca()).assignment_id,
                               'note', 'SYNTHETIC private withdrawal note')) #>> '{data,response}',
  'declined', 'M says they can''t make it anymore');
select is(pg_temp.jobs((pg_temp.pca()).assignment_id, array['duty_starting']), 'duty_starting:cancelled',
  'the pre-service reminder is cancelled');
select is((select count(*)::int from app.notifications_jobs
            where source_type = 'duties_coverage' and source_id = (pg_temp.pca()).assignment_id), 0,
  'no leader alert is raised for a cell part');
select ok(pg_temp.fx(6, 'duties_owner_part', jsonb_build_object('source_type', 'fixture_programme_part',
            'source_id', pg_temp.pc(), 'cell_id', pg_temp.cell()))::text not like '%private withdrawal%',
  'the cell sees the answer, never the member''s note');
select is((select p #>> '{assignment,response}' from jsonb_array_elements(pg_temp.fx(6, 'duties_owner_part',
             jsonb_build_object('source_type', 'fixture_programme_part', 'source_id', pg_temp.pc(),
                                'cell_id', pg_temp.cell())) -> 'positions') p), 'declined',
  'it sees Declined');

-- N1, N2, N3.
select is(pg_temp.err(pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC nobody asked', 'starts_at', app.cmd_utc(pg_temp.at(12, '18:00')),
    'response_deadline', app.cmd_utc(pg_temp.at(11, '18:00')),
    'positions', '[{"position_key": "gap"}]'::jsonb))), 'validation_failed|response_deadline=not_material',
  'review N1: a create that asks nobody refuses an answer-by');
select is((pg_temp.put(6, pg_temp.pc(), jsonb_build_object(
    'expected_revision', pg_temp.orev((select (r ->> 'occurrence_id')::uuid from pc)), 'duty_name', 'SYNTHETIC C1 part',
    'starts_at', app.cmd_utc(pg_temp.at(11, '18:00')),
    'positions', jsonb_build_array(jsonb_build_object('position_key', 'host', 'member_id', pg_temp.mid(4))))) ->> 'changed'),
  'false', 'review N2: an identical put changes nothing');
select is((select source_revision from app.duties_part_links where source_id = pg_temp.pc() and position_key = 'host'),
  pg_temp.pcrev(), 'and the link still records the caller''s latest part revision');
select is(pg_temp.err(pg_temp.fx(6, 'duties_owner_conflicts', jsonb_build_object(
    'cell_id', pg_temp.cell(), 'member_id', pg_temp.mid(4),
    'starts_at', app.cmd_utc(pg_temp.at(1, '18:00')), 'ends_at', app.cmd_utc(pg_temp.at(200, '18:00'))))),
  'validation_failed|ends_at=out_of_range', 'review N3: the conflicts read covers one part''s time, at most 120 days');

-- N5: a review of a duty that started is no longer open.
create temp table dn as select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'member_id', pg_temp.mid(11), 'duty_name', 'SYNTHETIC Morning ushering',
  'starts_at', app.cmd_utc(pg_temp.at(12, '07:00')))) as r;
insert into app.duties_review_flags (occurrence_id, source_type, source_id, source_revision, changed,
                                     flagged_by_member, flagged_by_account)
select (r #>> '{data,occurrence_id}')::uuid, 'fixture_event', pg_temp.ev(), 1, '{time}', pg_temp.mid(1), pg_temp.u(1) from dn;
select is(jsonb_array_length(app.duties_review_json((select (r #>> '{data,occurrence_id}')::uuid from dn))), 1,
  'review N5: an open review of an upcoming duty shows');
update app.duties_occurrences set starts_at = pg_temp.at(-1, '07:00')
 where occurrence_id = (select (r #>> '{data,occurrence_id}')::uuid from dn);
select is(app.duties_review_json((select (r #>> '{data,occurrence_id}')::uuid from dn)), '[]'::jsonb,
  'once the duty has started it no longer shows as open');

-- N7: only the foreign-key cascade removes a link.
create temp table pz as select pg_temp.fx(6, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', pg_temp.cell(), 'duty_name', 'SYNTHETIC cascade part', 'starts_at', app.cmd_utc(pg_temp.at(12, '19:00')),
  'positions', '[{"position_key": "gap"}]'::jsonb)) as r;
select throws_ok(format('delete from app.duties_part_links where source_id = %L', (select r ->> 'part_id' from pz)),
  'P0001', 'duties part links are permanent', 'review N7: a direct delete is still refused');
delete from app.duties_slot_revisions where slot_id = pg_temp.slot_of((select (r ->> 'part_id')::uuid from pz), 'gap');
delete from app.duties_slots where slot_id = pg_temp.slot_of((select (r ->> 'part_id')::uuid from pz), 'gap');
select is((select count(*)::int from app.duties_part_links where source_id = (select (r ->> 'part_id')::uuid from pz)), 0,
  'the cascade from its slot removes it');

-- Privileges, guards, vocabulary ------------------------------------------------------------------------
select is((select count(*)::int from information_schema.routine_privileges
            where routine_schema = 'app' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role')
              and (routine_name like 'duties_owner%' or routine_name in ('duties_register_link_source',
                   'duties_clear_review', 'duties_review_json', 'duties_linked_parts', 'duties_part_link_guard',
                   'duties_position_key_error', 'duties_review_fields_ok')
                   or routine_name like 'fixture_programme%' or routine_name like 'fixture_event%')), 0,
  'no owner operation, read or SYNTHETIC caller function is client-executable');
select ok(not has_table_privilege('authenticated', 'app.duties_part_links', 'select')
          and not has_table_privilege('authenticated', 'app.duties_review_flags', 'select')
          and not has_table_privilege('anon', 'app.duties_link_sources', 'select'),
  'the new tables have no client privilege');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok(app.duties_state_ok('audit_action', 'review_cleared') and app.duties_state_ok('capacity', 'cell_assistant')
          and app.duties_state_ok('audit_action', 'outcome_corrected'),
  'the vocabularies gain the 4.11 values and keep the earlier ones');

-- Erasure ------------------------------------------------------------------------------------------------
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(6), 'account_id', pg_temp.u(6),
                                                     'phase', 'check')) ->> 'remaining')::int > 0, true,
  'before erasure the cell leader''s links and flags are counted');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(6), pg_temp.u(6), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'the erase phase leaves nothing of the cell leader in Duties');
select is((select count(*)::int from app.duties_part_links where linked_by_member = pg_temp.mid(6)
              or ended_by_member = pg_temp.mid(6)), 0, 'links are anonymised');
select is((select count(*)::int from app.duties_review_flags where flagged_by_member = pg_temp.mid(6)), 0,
  'and so are the flags it raised');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(2), pg_temp.u(2), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'the department leader who cleared a review is erased too');

-- Q4 closed (production marker): nothing ---------------------------------------------------------------
select app.platform_set_environment('production', 'pgtap 4.11');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.11 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.11 production check', 'pgtap');
select is(pg_temp.err(pg_temp.fx(9, 'duties_owner_part', jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', pg_temp.p1(), 'cell_id', pg_temp.cell()))),
  'unavailable|policy=gate_closed', 'with Q4 closed the owner reads are unavailable');
select is(pg_temp.err(pg_temp.newpart(9)), 'unavailable|policy=gate_closed', 'and so are the operations');

select * from finish();
rollback;
