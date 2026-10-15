-- Apply membership lifecycle and handover to Duties and Follow-ups (story 4.12; AD-2, AD-6, AD-7,
-- AD-14): church deactivation ends the member's future assignments (department duties and cell
-- parts) in Identity's transaction, flags the vacancies, cancels the jobs and alerts the leaders;
-- removal from the department does the same for that department and tells the member; a login
-- hold keeps the duties and puts them on Needs contact at once; a revoked scope ends the removed
-- leader's alerts, commands, replays and supervision; the last reachable leader of an active
-- department cannot be deactivated until handover; open follow-up tasks are handed over under
-- the Q4 owner-scope rule; a deletion records its handovers, waits for them, and its check then
-- answers zero. Also: no Identity reason code reaches leaders (story 4.16 superseded the 4.12 "no
-- reason" decision: the department's leaders and deputies read a coarse category, tested in
-- duties_owner_decisions_test.sql), the Q2-closed path, restoration, privileges.
-- HTTP evidence: tools/identity-e2e/duties-lifecycle.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900460-900469). Duty times
-- are fixed church-time (Africa/Lusaka) clock times on whole days, never the current clock time.
begin;
select plan(155);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000004120' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000004120' || lpad(n::text, 2, '0'))::uuid $$;
-- 1-7 -> 900460-900466, 9 -> 900468, 11 -> 900469 (8 and 10 have no account).
create function pg_temp.phone(n int) returns text language sql as
$$ select '447700900' || (case when n <= 9 then 459 + n else 458 + n end)::text $$;
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
-- A read's outcome: 'ok' or the PostgREST error detail.
create function pg_temp.read(n int, p_sql text) returns text
language plpgsql as $$
declare
  r jsonb;
  v_detail text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  begin
    execute p_sql into r;
    reset role;
    return 'ok';
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
    reset role;
    return coalesce(v_detail, 'error');
  end;
end;
$$;
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
create function pg_temp.day(p_days int) returns text language sql as
$$ select to_char((now() at time zone 'Africa/Lusaka')::date + p_days, 'YYYY-MM-DD') $$;

-- Accounts: 1 Admin A (no scope); 2 leader L of D; 3 deputy P of D (not a member of D); 4 member M
-- (D and E; deactivated); 5 member O (removed from D); 6 member H (held); 7 Pastor; 8 accountless
-- member X (D); 9 leader K, the only leader of department E; 10 accountless member R, the only
-- leader of department F (deleted); 11 cell leader CL of cell C.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now()
  from generate_series(1, 11) n where n not in (8, 10);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 11) n where n not in (8, 10);
select app.platform_set_environment('local', 'pgtap 4.12');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.12 Member ' || n, 'pgtap 4.12')
  from generate_series(1, 11) n where n not in (8, 10);
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.12 Accountless X', 'approved', true),
                    ('SYNTHETIC 4.12 Accountless R', 'approved', true) returning member_id, display_name)
insert into m select case when display_name like '%X' then 8 else 10 end, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.who(p uuid) returns int language sql as $$ select n from m where member_id = p $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create function pg_temp.dep(p_name text) returns uuid language sql as $$
  select (pg_temp.duties(1, 'duties.create_department', null, jsonb_build_object('name', p_name))
          #>> '{data,department_id}')::uuid
$$;
create temp table deps as select pg_temp.dep('SYNTHETIC Preaching Rota') as d, pg_temp.dep('SYNTHETIC 4.12 Ushers') as e,
                                 pg_temp.dep('SYNTHETIC 4.12 Stewards') as f;
create function pg_temp.d() returns uuid language sql as $$ select d from deps $$;
create function pg_temp.e() returns uuid language sql as $$ select e from deps $$;
create function pg_temp.f() returns uuid language sql as $$ select f from deps $$;
create function pg_temp.drev(p uuid) returns bigint language sql as
$$ select revision from app.duties_departments where department_id = p $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope', pg_temp.grev(p_member),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member', pg_temp.drev(p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(9, 'department_leader', pg_temp.e());
select pg_temp.grant_scope(10, 'department_leader', pg_temp.f());
select pg_temp.add(n, pg_temp.d()) from unnest(array[2, 4, 5, 6, 8, 10]) n;
select pg_temp.add(n, pg_temp.e()) from unnest(array[4, 9]) n;

-- One-off duties (one position each), each on its own church day at 10:00.
create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_member int, p_days int, p_leader int default 2,
                            p_department uuid default null)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(p_leader, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', coalesce(p_department, pg_temp.d()), 'member_id', pg_temp.mid(p_member),
         'duty_name', 'Duty ' || p_tag, 'location', 'SYNTHETIC hall',
         'starts_at', app.cmd_utc(pg_temp.at(p_days))));
  insert into pubs values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.a(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.slot(p_tag text) returns uuid language sql as
$$ select slot_id from app.duties_assignments where assignment_id = pg_temp.a(p_tag) $$;
create function pg_temp.st(p_id uuid) returns text language sql as $$
  select assignment_state || coalesce(':' || end_reason, '') from app.duties_assignments where assignment_id = p_id
$$;
create function pg_temp.rev(p_id uuid) returns bigint language sql as
$$ select revision from app.duties_assignments where assignment_id = p_id $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.answer(n int, p_id uuid, p_response text) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.respond', pg_temp.rev(p_id),
                        jsonb_build_object('assignment_id', p_id, 'response', p_response))
$$;
-- Pending jobs of an assignment: recipient:kind, in a stable order.
create function pg_temp.pending(p_id uuid) returns text language sql as $$
  select coalesce(string_agg(pg_temp.who(recipient_member_id) || ':' || reminder_kind, ','
                             order by pg_temp.who(recipient_member_id), reminder_kind), '')
    from app.notifications_jobs where source_id = p_id and job_state = 'pending'
$$;
create function pg_temp.lc(n int, p_command text, p_target int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.call(n, 'identity_lifecycle_command', p_command, pg_temp.mrev(p_target),
                      jsonb_build_object('member_id', pg_temp.mid(p_target)) || p_payload)
$$;
create function pg_temp.coverage(n int) returns jsonb language sql as $$
  select pg_temp.readj(n, format('select api.duties_coverage(%L::date, %L::date)', pg_temp.day(10), pg_temp.day(30)))
$$;
create function pg_temp.cpos(n int, p_slot uuid) returns jsonb language sql as $$
  select p from jsonb_array_elements(pg_temp.coverage(n) -> 'departments') dep,
                jsonb_array_elements(dep -> 'positions') p
   where p ->> 'slot_id' = p_slot::text
$$;
create function pg_temp.task(p_src uuid) returns app.followups_tasks language sql as
$$ select t.* from app.followups_tasks t where t.source_id = p_src $$;
create function pg_temp.newtask(n int, p_owner int, p_supervisor int, p_scope uuid) returns uuid
language plpgsql as $$
declare
  v_src uuid := gen_random_uuid();
  r jsonb;
begin
  r := pg_temp.call(n, 'followups_command', 'followups.create_task', null, jsonb_build_object(
         'source_type', 'fixture_followup', 'source_id', v_src, 'source_revision', 1,
         'purpose', 'synthetic_check_in', 'owner_member_id', pg_temp.mid(p_owner),
         'supervisor_member_id', pg_temp.mid(p_supervisor),
         'scope_kind', 'department_leader', 'scope_id', p_scope,
         'next_action', 'SYNTHETIC: phone and check in', 'due_at', app.cmd_utc(pg_temp.at(9))));
  if r ->> 'code' is not null then
    raise exception 'task setup failed: %', r;
  end if;
  return v_src;
end;
$$;
create function pg_temp.pending_obligations(n int, p_module text default null) returns int language sql as $$
  select count(*)::int from app.identity_handover_obligations
   where member_id = pg_temp.mid(n) and obligation_state = 'pending'
     and (p_module is null or owner_module = p_module)
$$;

-- A cell part for M through the SYNTHETIC Cells-like caller (story 4.11).
create temp table cc as
  with ins as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
               values ('SYNTHETIC 4.12 Cell', 'SYNTHETIC area', true, 'pgtap 4.12') returning cell_id)
  select cell_id from ins;
select pg_temp.grant_scope(11, 'cell_leader', (select cell_id from cc));
select app.contract_register_source_type('fixture', 'fixture_programme_part',
                                         'app.fixture_programme_part_check(jsonb)'::regprocedure);
select app.duties_register_link_source('fixture', 'fixture_programme_part', 'cell_part');
create temp table part as select pg_temp.fx(11, 'fixture_programme_publish', jsonb_build_object(
  'cell_id', (select cell_id from cc), 'duty_name', 'SYNTHETIC Worship part',
  'starts_at', app.cmd_utc(pg_temp.at(16, '18:00')),
  'positions', jsonb_build_array(jsonb_build_object('position_key', 'lead', 'position_name', 'Lead',
                                                    'member_id', pg_temp.mid(4))))) as r;
create function pg_temp.part_a() returns uuid language sql as $$
  select a.assignment_id from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
   where s.occurrence_id = (select (r ->> 'occurrence_id')::uuid from part)
   order by a.assigned_at limit 1
$$;

-- The duties ----------------------------------------------------------------------------------------
select pg_temp.pub('MP', 4, 11);                    -- M, pending
select pg_temp.pub('MA', 4, 12);                    -- M, accepted
select pg_temp.pub('MD', 4, 13);                    -- M, declined
select pg_temp.pub('MPAST', 4, 14);                 -- M, moved into the past below
select pg_temp.pub('ME', 4, 15, 9, pg_temp.e());    -- M in department E, accepted
select pg_temp.pub('HP', 6, 17);                    -- H, pending
select pg_temp.pub('HA', 6, 18);                    -- H, accepted
select pg_temp.pub('HD', 6, 19);                    -- H, declined
select pg_temp.pub('OP', 5, 21);                    -- O, pending
select pg_temp.pub('OA', 5, 22);                    -- O, accepted
select pg_temp.pub('XP', 8, 23);                    -- X, pending (accountless)
select pg_temp.pub('RP', 10, 24);                   -- R, pending (accountless)
select pg_temp.pub('LP', 2, 25);                    -- the leader's own duty (control)
select pg_temp.answer(4, pg_temp.a('MA'), 'accepted');
select pg_temp.answer(4, pg_temp.a('MD'), 'declined');
select pg_temp.answer(4, pg_temp.a('ME'), 'accepted');
select pg_temp.answer(6, pg_temp.a('HA'), 'accepted');
select pg_temp.answer(6, pg_temp.a('HD'), 'declined');
select pg_temp.answer(5, pg_temp.a('OA'), 'accepted');
update app.duties_occurrences set starts_at = pg_temp.at(-2), ends_at = null, reporting_at = null
 where occurrence_id = pg_temp.occ('MPAST');
-- A one-date rota in D with M planned on its draft position.
create temp table ser as select pg_temp.duties(2, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'SYNTHETIC rota day', 'every', 'week',
  'from_date', pg_temp.day(20), 'until_date', pg_temp.day(20), 'start_time', '10:00',
  'positions', jsonb_build_array('Preacher'))) as r;
create function pg_temp.draft_occ() returns uuid language sql as $$
  select occurrence_id from app.duties_occurrences where series_id = (select (r #>> '{data,series_id}')::uuid from ser)
$$;
create function pg_temp.draft_slot() returns uuid language sql as
$$ select slot_id from app.duties_slots where occurrence_id = pg_temp.draft_occ() $$;
select is(pg_temp.err(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.draft_occ()),
            jsonb_build_object('slot_id', pg_temp.draft_slot(), 'member_id', pg_temp.mid(4)))), 'ok',
  'setup: M is planned on a draft rota position');
-- A coverage case on M's pending duty (its Follow-ups task is owned by L).
create temp table att as select pg_temp.duties(2, 'duties.record_contact_attempt', pg_temp.rev(pg_temp.a('MP')),
  jsonb_build_object('assignment_id', pg_temp.a('MP'), 'channel', 'phone', 'outcome', 'no_answer',
                     'next_follow_up_at', app.cmd_utc(pg_temp.at(9, '18:00')))) as r;
select is(pg_temp.err((select r from att)), 'ok', 'setup: L records a contact attempt on M''s pending duty');
-- Follow-up tasks: T1 owned by M (supervisor L), T2 owned by X (supervisor P), T3 owned by P
-- (supervisor L; P is not a member of D).
create temp table tasks as select pg_temp.newtask(2, 4, 2, pg_temp.d()) as t1, pg_temp.newtask(2, 8, 3, pg_temp.d()) as t2,
                                  pg_temp.newtask(2, 3, 2, pg_temp.d()) as t3;
create function pg_temp.t(k int) returns uuid language sql as
$$ select case k when 1 then t1 when 2 then t2 else t3 end from tasks $$;

-- Church deactivation ends future assignments in Identity's transaction (verify: deactivate) -------------
select is(pg_temp.pending(pg_temp.a('MA')), '4:duty_starting', 'before: M''s accepted duty has its pre-service reminder');
create temp table dm4 as select pg_temp.lc(1, 'identity.deactivate_membership', 4, '{"reason_code": "moved_away"}') as r;
select is(pg_temp.err((select r from dm4)), 'ok', 'the Admin deactivates M');
select is(array[pg_temp.st(pg_temp.a('MP')), pg_temp.st(pg_temp.a('MA')), pg_temp.st(pg_temp.a('MD')),
                pg_temp.st(pg_temp.a('ME')), pg_temp.st(pg_temp.part_a())],
  array['superseded:vacated', 'superseded:vacated', 'superseded:vacated', 'superseded:vacated', 'superseded:vacated'],
  'every future assignment of M ends (pending, accepted, declined, another department, a cell part)');
select is(pg_temp.st(pg_temp.a('MPAST')), 'current', 'a past duty and its answer are kept');
select is((select count(*)::int from app.duties_assignments a
            where a.slot_id in (pg_temp.slot('MP'), pg_temp.slot('MA'), pg_temp.slot('ME'))
              and a.assignment_state = 'current'), 0, 'the positions are left unfilled');
select is((select string_agg(change_class || ':' || array_to_string(changed_fields, ',') || ':' || coalesce(member_id::text, '-'), ';')
             from app.duties_slot_revisions where slot_id = pg_temp.slot('MP')
              and slot_revision = (select revision from app.duties_slots where slot_id = pg_temp.slot('MP'))),
  'vacated:member_id:-', 'the position records a vacated slot revision without an assignee');
select is(pg_temp.pending(pg_temp.a('MA')), '', 'M''s reminders end');
select is(pg_temp.pending(pg_temp.a('MP')), '2:duty_vacated,3:duty_vacated',
  'the leader and the deputy get one vacancy notice for the department (same transaction), keyed by the soonest position');
select is(pg_temp.pending(pg_temp.a('MD')), '', 'a duty M had declined sends no new notice (the leaders already know)');
select is(pg_temp.pending(pg_temp.a('ME')), '9:duty_vacated', 'department E''s leader is told about E''s duty');
select is(pg_temp.pending(pg_temp.part_a()), '', 'a cell part gets no leader alert (the owner read shows the gap)');
select is((select count(*)::int from app.notifications_jobs j
            where j.recipient_member_id = pg_temp.mid(4) and j.job_state = 'pending'
              and j.source_type in ('duties_assignment', 'duties_coverage')
              and j.source_id <> pg_temp.a('MPAST')), 0,
  'no Duties job of M is left pending');
select is((select count(*)::int from app.notifications_schedules s
            where s.recipient_member_id = pg_temp.mid(4) and s.schedule_state = 'active'
              and s.source_type = 'duties_assignment' and s.source_id <> pg_temp.a('MPAST')), 0, 'and no reminder schedule of M stays active');
select is((select close_code from app.duties_coverage_cases where assignment_id = pg_temp.a('MP')),
  'superseded', 'the coverage case closes with the assignment');
select is((select task_state || ':' || close_code from app.followups_tasks
            where task_id = (select (r #>> '{data,task_id}')::uuid from att)),
  'closed:source_resolved', 'and its Follow-ups task closes as resolved');
select is((select draft_member_id from app.duties_slots where slot_id = pg_temp.draft_slot()), null,
  'M''s planned draft position is cleared');
select is((select string_agg(action || ':' || actor_capacity || ':' || code, ',' order by action)
             from (select distinct action, actor_capacity, code from app.duties_audit
                    where member_id = pg_temp.mid(4) and action in ('assignment_vacated', 'draft_cleared')) x),
  'assignment_vacated:lifecycle:member_left,draft_cleared:lifecycle:member_left',
  'audited with codes only, attributed to the lifecycle change');
select is((select count(distinct actor_member_id)::int from app.duties_audit
            where member_id = pg_temp.mid(4) and action = 'assignment_vacated'
              and actor_member_id = pg_temp.mid(1)), 1, 'attributed to the Admin who deactivated M');
select is((select count(*)::int from app.duties_department_members
            where member_id = pg_temp.mid(4) and ended_at is null), 2,
  'department membership rows are kept (a restoration restores no assignment)');
-- Follow-ups: M's task is handed over to its supervisor.
select is(pg_temp.who((pg_temp.task(pg_temp.t(1))).owner_member_id), 2, 'M''s open task is handed to its supervisor L');
select is((select string_agg(action || ':' || actor_capacity || ':' || code || ':' || (actor_member_id is null)::text,
                         ',' order by action)
             from app.followups_activity where task_id = (pg_temp.task(pg_temp.t(1))).task_id and code = 'handover'),
  'reassigned:source:handover:true,supervisor_changed:source:handover:true', 'recorded as a handover, with no reason');
select is(pg_temp.who((pg_temp.task(pg_temp.t(1))).supervisor_member_id), 3,
  'review N3: L now owns it, so another holder of D (the deputy) supervises it');
select is((select string_agg(obligation_kind || ':' || coalesce(resolution, 'pending'), ',')
             from app.identity_handover_obligations where member_id = pg_temp.mid(4)),
  'followup_task:handed_over', 'the obligation Identity recorded is resolved in the same transaction');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'followups_task' and j.source_id = (pg_temp.task(pg_temp.t(1))).task_id
              and j.recipient_member_id = pg_temp.mid(2) and j.reminder_kind = 'followup_assigned'), 1,
  'the new owner is told');

-- The vacancy flag and the leaders' notice (story 4.16: a coarse category only, never a reason code) --
select is(pg_temp.cpos(2, pg_temp.slot('MP')) ->> 'status', 'unfilled', 'the coverage queue shows the position as unfilled');
select ok((pg_temp.cpos(2, pg_temp.slot('MP')) #>> '{vacated,since}') is not null, 'flagged as vacated');
select is((select (dep #>> '{counts,vacated}')::int from jsonb_array_elements(pg_temp.coverage(2) -> 'departments') dep
            where dep ->> 'department_id' = pg_temp.d()::text), 3, 'and counted (the position M had declined too)');
select is((select count(*)::int from jsonb_array_elements(pg_temp.coverage(1) -> 'departments') dep,
                                     jsonb_array_elements(dep -> 'positions') p
            where jsonb_typeof(p -> 'vacated') = 'object'), 4, 'Admin''s operational view shows the same flags');
select is((pg_temp.cpos(2, pg_temp.slot('MP')) #>> '{vacated,reason}') || '|'
          || coalesce(pg_temp.cpos(1, pg_temp.slot('MP')) #>> '{vacated,reason}', 'none'), 'member_inactive|none',
  'story 4.16: the leader reads the coarse category; the Admin role alone does not');
select ok(position('moved_away' in pg_temp.coverage(2)::text) = 0
          and position('member_left' in pg_temp.coverage(2)::text) = 0
          and position('deactivat' in pg_temp.coverage(2)::text) = 0
          and position('moved_away' in pg_temp.readj(2, 'select api.duties_leader_board()')::text) = 0
          and position('member_left' in pg_temp.readj(2, 'select api.duties_leader_board()')::text) = 0,
  'no deactivation reason reaches the leader''s reads');
select is((select string_agg(distinct h ->> 'end_reason', ',')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') dep,
                  jsonb_array_elements(dep -> 'duties') o, jsonb_array_elements(o -> 'positions') p,
                  jsonb_array_elements(p -> 'history') h
            where o ->> 'occurrence_id' = pg_temp.occ('MP')::text), 'vacated',
  'the board''s history shows one generic end reason');
select is((select title || '|' || link from app.contract_reminder_contracts where reminder_kind = 'duty_vacated'),
  'Positions need cover|/duties/coverage', 'the vacancy notice has a fixed generic text and opens Coverage');
select pg_temp.run();
select is((select count(*)::int from app.notifications_inbox_items i
             join app.notifications_jobs j on j.job_id = i.job_id
            where j.reminder_kind = 'duty_vacated' and i.recipient_member_id = pg_temp.mid(2)), 1,
  'the leader''s inbox has one vacancy notice (not one per position)');
-- A vacancy filled before its notice is delivered: the notice is obsolete.
select pg_temp.pub('MQ', 5, 26);
select is(pg_temp.err(pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
            jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(5)))), 'ok',
  'the Admin removes O from department D (verify: remove from the department)');
select is(array[pg_temp.st(pg_temp.a('OP')), pg_temp.st(pg_temp.a('OA')), pg_temp.st(pg_temp.a('MQ'))],
  array['superseded:vacated', 'superseded:vacated', 'superseded:vacated'], 'O''s future duties in D end');
update app.notifications_jobs set scheduled_at = now() + interval '1 hour'
 where source_id = pg_temp.a('OP') and job_state = 'pending' and reminder_kind = 'duty_vacated';
select is(pg_temp.pending(pg_temp.a('OA')), '5:duty_released', 'O is told each duty is no longer theirs');
select is(pg_temp.pending(pg_temp.a('OP')), '2:duty_vacated,3:duty_vacated,5:duty_released',
  'and the leaders get one vacancy notice for the removal');
select is((select pg_temp.who(ended_by_member) from app.duties_department_members
            where department_id = pg_temp.d() and member_id = pg_temp.mid(5)), 1,
  'the membership ends, attributed to the Admin');
select is((select string_agg(code, ',') from app.duties_audit where action = 'assignment_vacated'
              and assignment_id = pg_temp.a('OA')), 'removed', 'audited with the removal code');
create function pg_temp.vkey() returns jsonb language sql as $$
  select jsonb_build_object('source_type', 'duties_coverage', 'source_id', pg_temp.a('OP'),
           'source_revision', pg_temp.rev(pg_temp.a('OP')), 'recipient_member_id', pg_temp.mid(2),
           'reminder_kind', 'duty_vacated')
$$;
select is(pg_temp.err(pg_temp.duties(1, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('MQ')),
            jsonb_build_object('slot_id', pg_temp.slot('MQ'), 'member_id', pg_temp.mid(2)))), 'ok',
  'the Admin fills one of the three positions again');
select is((app.duties_vacancy_alert_check(pg_temp.vkey()) ->> 'actionable')::boolean, true,
  'the notice still stands while another position of the change is unfilled');
select pg_temp.duties(1, 'duties.assign_slot', pg_temp.orev(pg_temp.occ(t)),
                      jsonb_build_object('slot_id', pg_temp.slot(t), 'member_id', pg_temp.mid(2)))
  from unnest(array['OP', 'OA']) t;
update app.notifications_jobs set scheduled_at = now()
 where source_id = pg_temp.a('OP') and job_state = 'pending' and reminder_kind = 'duty_vacated';
select pg_temp.run();
select is((select string_agg(distinct job_state || ':' || coalesce(finish_reason, cancel_reason, '-'), ',')
             from app.notifications_jobs where source_id = pg_temp.a('OP') and reminder_kind = 'duty_vacated'),
  'obsolete:not_actionable', 'once every position is filled the notice is no longer delivered');
select is(pg_temp.err(pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
            jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(5)))),
  'validation_failed|member_id=not_in_department', 'removing O again is refused');
select is(pg_temp.err(pg_temp.duties(2, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
            jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(8)))), 'forbidden',
  'a leader cannot remove members (Admin only)');
select is(pg_temp.err(pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()) - 1,
            jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(8)))), 'conflict',
  'a stale department revision is refused');
select is(pg_temp.err(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('OP')),
            jsonb_build_object('slot_id', pg_temp.slot('OP'), 'member_id', pg_temp.mid(5)))),
  'validation_failed|member_id=not_in_department', 'O can no longer be given D''s duties');

-- A login hold keeps duties and routes contact to the leaders (verify: hold) -------------------------
create temp table jobs_before as select count(*) as n from app.notifications_jobs where source_type = 'duties_coverage';
select is(pg_temp.err(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(6),
            jsonb_build_object('member_id', pg_temp.mid(6), 'reason_code', 'login_disabled'))), 'ok',
  'the Admin places a login hold on H');
select is(array[pg_temp.st(pg_temp.a('HP')), pg_temp.st(pg_temp.a('HA')), pg_temp.st(pg_temp.a('HD'))],
  array['current', 'current', 'current'], 'H keeps every duty');
select is(pg_temp.cpos(2, pg_temp.slot('HP')) #>> '{needs_contact,reasons}', '["not_reached"]',
  'the pending duty is on Needs contact at once');
select is(pg_temp.cpos(2, pg_temp.slot('HA')) #>> '{needs_contact,reasons}', '["not_reached"]',
  'and so is the accepted one');
select is(pg_temp.cpos(2, pg_temp.slot('HD')) -> 'needs_contact', 'null'::jsonb, 'a declined duty needs no contact');
select is((select count(*) from app.notifications_jobs where source_type = 'duties_coverage') - (select n from jobs_before), 0::bigint,
  'no leader alert is sent for a hold');
select ok(position('login_disabled' in pg_temp.coverage(2)::text) = 0
          and position('hold' in (pg_temp.cpos(2, pg_temp.slot('HP')))::text) = 0,
  'the hold is never named');
-- Once the member can be reached again, the hold's entry no longer shows (released hold).
insert into app.duties_contact_needs (need_id, assignment_id, source_revision, reminder_kind, scheduled_at)
values (gen_random_uuid(), pg_temp.a('LP'), pg_temp.rev(pg_temp.a('LP')), 'access_hold', now());
select is(pg_temp.cpos(1, pg_temp.slot('LP')) -> 'needs_contact', 'null'::jsonb,
  'an access_hold entry of a member the app can reach is not shown');

-- A revoked scope ends the removed leader's authority (verify: scope_revoked) -----------------------------
create temp table p_req as select gen_random_uuid() as id;
select is(pg_temp.err(pg_temp.duties(3, 'duties.record_contact_attempt', pg_temp.rev(pg_temp.a('XP')),
            jsonb_build_object('assignment_id', pg_temp.a('XP'), 'channel', 'phone', 'outcome', 'no_answer',
                               'next_follow_up_at', app.cmd_utc(pg_temp.at(9, '19:00'))), (select id from p_req))), 'ok',
  'setup: deputy P records a contact attempt (before revocation)');
create function pg_temp.p_alerts() returns text language sql as $$
  select coalesce(string_agg(distinct reminder_kind || ':' || job_state || ':' || coalesce(cancel_reason, '-'), ','), '')
    from app.notifications_jobs where source_type = 'duties_coverage' and recipient_member_id = pg_temp.mid(3)
     and source_id = pg_temp.a('XP')
$$;
select is(pg_temp.p_alerts(), 'duty_response_overdue:pending:-', 'P has a pending leader alert (X''s answer-by time)');
select is(pg_temp.err(pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope', pg_temp.grev(3),
            jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'department_deputy', 'scope_id', pg_temp.d()))), 'ok',
  'the Admin revokes P''s deputy scope');
select is(pg_temp.p_alerts(), 'duty_response_overdue:cancelled:not_recipient', 'P''s pending leader alerts end at once');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_coverage'
              and source_id = pg_temp.a('XP') and recipient_member_id = pg_temp.mid(2) and job_state = 'pending'), 1,
  'the leader''s alert stays');
select is(pg_temp.err(pg_temp.duties(3, 'duties.confirm_by_leader', pg_temp.rev(pg_temp.a('XP')),
            jsonb_build_object('assignment_id', pg_temp.a('XP'), 'channel', 'phone', 'reason', 'SYNTHETIC'))),
  'not_found', 'P cannot confirm by leader any more (the duty is not disclosed)');
select is(pg_temp.err(pg_temp.duties(3, 'duties.record_contact_attempt', pg_temp.rev(pg_temp.a('XP')),
            jsonb_build_object('assignment_id', pg_temp.a('XP'), 'channel', 'phone', 'outcome', 'no_answer',
                               'next_follow_up_at', app.cmd_utc(pg_temp.at(9, '19:00'))), (select id from p_req))),
  'forbidden', 'a replay of P''s earlier command is refused too');
select is(pg_temp.err(pg_temp.duties(3, 'duties.record_outcome', pg_temp.rev(pg_temp.a('MPAST')),
            jsonb_build_object('assignment_id', pg_temp.a('MPAST'), 'outcome', 'completed'))), 'not_found',
  'and so is recording an outcome');
select is(pg_temp.read(3, 'select api.duties_coverage()'), 'not_granted', 'P no longer reads the coverage queue');
select is(pg_temp.who((pg_temp.task(pg_temp.t(2))).supervisor_member_id), 2, 'supervision of X''s task moves to L');
select is(pg_temp.who((pg_temp.task(pg_temp.t(3))).owner_member_id), 2,
  'P''s own task (P is not in D''s group any more) is handed to its supervisor');
select is(pg_temp.read(3, format('select api.followups_task(%L::uuid)', (pg_temp.task(pg_temp.t(2))).task_id)),
  'not_granted', 'P can no longer open X''s task');

-- The last leader of an active department (verify: handover refusal) ------------------------------------
select is(pg_temp.err(pg_temp.lc(1, 'identity.deactivate_membership', 9, '{"reason_code": "member_request"}')),
  'conflict|member_id=handover_required', 'the only leader of E cannot be deactivated');
select pg_temp.grant_scope(6, 'department_deputy', pg_temp.e());
select is(pg_temp.err(pg_temp.lc(1, 'identity.deactivate_membership', 9, '{"reason_code": "member_request"}')),
  'conflict|member_id=handover_required', 'a held deputy does not count as a responsible leader');
select is(pg_temp.pending_obligations(9), 0, 'a refused deactivation records nothing');
select pg_temp.grant_scope(7, 'department_deputy', pg_temp.e());
select is(pg_temp.err(pg_temp.lc(1, 'identity.deactivate_membership', 9, '{"reason_code": "member_request"}')), 'ok',
  'with a reachable deputy in place the leader can be deactivated');
select is(app.duties_report_handover(jsonb_build_object('member_id', pg_temp.mid(2))),
  jsonb_build_object('obligations', jsonb_build_array(jsonb_build_object(
    'kind', 'department_leader', 'subject_id', pg_temp.d(), 'last_responsible', true))),
  'L is now the last leader of D (the deputy was revoked)');

-- The Q2-closed path still ends the work and audits the skipped notices --------------------------------
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Mars/Base"}' where gate = 'q2_church_time';
create temp table qx as select pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
  jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(8))) as r;
select is(pg_temp.err((select r from qx)) || '|' || ((select r from qx) #>> '{data,notices_skipped}'), 'ok|true',
  'with Q2 unavailable the removal is still recorded (notices skipped)');
select is(pg_temp.st(pg_temp.a('XP')), 'superseded:vacated', 'X''s duty ends');
select is(pg_temp.pending(pg_temp.a('XP')), '', 'its jobs are cancelled and no notice is planned');
select is((select string_agg(code, ',') from app.duties_audit where action = 'reminders_skipped'
              and member_id = pg_temp.mid(8)), 'policy_unavailable', 'the skip is audited');
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Africa/Lusaka"}' where gate = 'q2_church_time';

-- Deletion: handovers recorded, erasure waits, then the check answers zero (verify: delete) ------------
create temp table t4 as select pg_temp.newtask(1, 10, 10, pg_temp.f()) as src;
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where role = 'pastor' and revoked_at is null;
select is(app.followups_report_handover(jsonb_build_object('member_id', pg_temp.mid(10))),
  jsonb_build_object('obligations', jsonb_build_array(jsonb_build_object(
    'kind', 'followup_task', 'subject_id', (pg_temp.task((select src from t4))).task_id, 'last_responsible', true),
    jsonb_build_object('kind', 'followup_supervision', 'subject_id', (pg_temp.task((select src from t4))).task_id,
                       'last_responsible', false))),
  'nobody else may own or supervise R''s task (no other member of its group, no live Pastor; review N2)');
select is(pg_temp.err(pg_temp.lc(1, 'identity.deactivate_membership', 10, '{"reason_code": "church_decision"}')),
  'conflict|member_id=handover_required', 'so R cannot be deactivated');
create temp table del as select pg_temp.call(1, 'identity_deletion_command', 'identity.request_member_deletion',
  pg_temp.mrev(10), jsonb_build_object('member_id', pg_temp.mid(10), 'identity_check', 'in_person')) as r;
select is(pg_temp.err((select r from del)), 'ok', 'a deletion is never refused for a handover');
create function pg_temp.del() returns app.identity_deletions language sql as
$$ select d.* from app.identity_deletions d where d.member_id = pg_temp.mid(10) $$;
select is(pg_temp.st(pg_temp.a('RP')), 'superseded:vacated', 'R''s future duty ends');
select is(pg_temp.pending(pg_temp.a('RP')), '2:duty_vacated', 'and the leader is told');
select is((select string_agg(owner_module || ':' || obligation_kind, ',' order by owner_module, obligation_kind)
             from app.identity_handover_obligations where member_id = pg_temp.mid(10) and obligation_state = 'pending'),
  'duties:department_leader,followups:followup_supervision,followups:followup_task', 'the handovers are recorded pending');
select is(app.identity_deletion_blocker(pg_temp.del(), 'erase_owners'), 'handover_pending', 'erasure waits for them');
select is(pg_temp.err(pg_temp.duties(1, 'duties.resolve_handover', pg_temp.drev(pg_temp.f()),
            jsonb_build_object('department_id', pg_temp.f()))), 'conflict|department_id=leader_required',
  'F''s handover cannot be resolved without a reachable leader');
select is(pg_temp.err(pg_temp.duties(2, 'duties.resolve_handover', pg_temp.drev(pg_temp.f()),
            jsonb_build_object('department_id', pg_temp.f()))), 'forbidden', 'nor by a leader (Admin only)');
select is((select (d -> 'needs_leader')::text || '|' || jsonb_array_length(d -> 'handovers')
             from jsonb_array_elements(pg_temp.readj(1, 'select api.duties_admin_overview()') -> 'departments') d
            where d ->> 'department_id' = pg_temp.f()::text), 'true|1', 'the Admin sees F needs a leader and a pending handover');
select pg_temp.grant_scope(2, 'department_leader', pg_temp.f());
select is(pg_temp.err(pg_temp.duties(1, 'duties.resolve_handover', pg_temp.drev(pg_temp.f()),
            jsonb_build_object('department_id', pg_temp.f()))), 'ok', 'with L as leader the Admin resolves it');
select is(pg_temp.err(pg_temp.duties(1, 'duties.resolve_handover', pg_temp.drev(pg_temp.f()),
            jsonb_build_object('department_id', pg_temp.f()))), 'validation_failed|department_id=no_handover',
  'a second resolve finds nothing pending');
select is(app.identity_deletion_blocker(pg_temp.del(), 'erase_owners'), 'handover_pending', 'the task''s handover still waits');
select is(pg_temp.err(pg_temp.call(1, 'followups_command', 'followups.reassign',
            (pg_temp.task((select src from t4))).revision,
            jsonb_build_object('task_id', (pg_temp.task((select src from t4))).task_id, 'owner_member_id', pg_temp.mid(2),
                               'supervisor_member_id', pg_temp.mid(2)))),
  'ok', 'the Admin reassigns R''s task to L and names L as its supervisor');
select is((select string_agg(obligation_kind || ':' || resolution, ',' order by obligation_kind)
             from app.identity_handover_obligations where member_id = pg_temp.mid(10) and owner_module = 'followups'),
  'followup_supervision:handed_over,followup_task:handed_over', 'the reassignment resolves both of the task''s obligations');
select is(pg_temp.pending_obligations(10), 0, 'nothing of R is pending');
select is(app.identity_deletion_blocker(pg_temp.del(), 'erase_owners'), null, 'erasure may run now');
select is((select string_agg((r ->> 'module') || '=' || (r ->> 'remaining'), ',' order by r ->> 'module')
             from jsonb_array_elements(app.identity_call_deletion_hooks(pg_temp.mid(10), null, (pg_temp.del()).deletion_id, 'erase')) r
            where r ->> 'module' in ('duties', 'followups')), 'duties=0,followups=0',
  'the erase phase leaves nothing of R in Duties or Follow-ups');
select is((select string_agg((r ->> 'module') || '=' || (r ->> 'remaining'), ',' order by r ->> 'module')
             from jsonb_array_elements(app.identity_call_deletion_hooks(pg_temp.mid(10), null, (pg_temp.del()).deletion_id, 'check')) r
            where r ->> 'module' in ('duties', 'followups')), 'duties=0,followups=0', 'and the check answers zero');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

-- Restoration restores no assignment; a returning member gets fresh keys ---------------------------
select is(pg_temp.err(pg_temp.lc(1, 'identity.restore_membership', 4, '{"identity_check": "in_person"}')), 'ok',
  'the Admin restores M');
select is(pg_temp.st(pg_temp.a('MP')), 'superseded:vacated', 'M''s ended duties stay ended');
select is(pg_temp.err(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('MP')),
            jsonb_build_object('slot_id', pg_temp.slot('MP'), 'member_id', pg_temp.mid(4)))), 'ok',
  'the leader gives M the position again');
select isnt((select assignment_id from app.duties_assignments where slot_id = pg_temp.slot('MP') and assignment_state = 'current'),
  pg_temp.a('MP'), 'as a new assignment');
select is((select count(*)::int from app.notifications_jobs j
             join app.duties_assignments a on a.assignment_id = j.source_id
            where a.slot_id = pg_temp.slot('MP') and a.assignment_state = 'current'
              and j.recipient_member_id = pg_temp.mid(4) and j.reminder_kind = 'duty_assigned'
              and j.job_state = 'pending'), 1, 'with a fresh notice (a new logical key)');
select is((select count(*)::int from app.notifications_jobs j where j.source_id = pg_temp.a('MP')
              and j.reminder_kind = 'duty_vacated' and j.job_state = 'pending'), 0,
  'and the old vacancy notices no longer stand');

-- Review N4: a removed member the app cannot reach (H, held): the released notices become the
-- leaders' contact notices ---------------------------------------------------------------------------
create temp table hx as select pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
  jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(6))) as r;
select is(pg_temp.err((select r from hx)) || '|' || ((select r from hx) #>> '{data,notices_skipped}'), 'ok|false',
  'the Admin removes held H from D (notices are planned)');
select is(pg_temp.pending(pg_temp.a('HA')), '6:duty_released', 'H''s released notice is queued');
select pg_temp.run();
select is((select string_agg(n ->> 'notice', ',' order by n ->> 'starts_at')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') dep,
                  jsonb_array_elements(dep -> 'contact_notices') n
            where dep ->> 'department_id' = pg_temp.d()::text and n ->> 'member_id' = pg_temp.mid(6)::text
              and n ->> 'assignment_id' in (pg_temp.a('HP')::text, pg_temp.a('HA')::text)),
  'released,released', 'the leader is asked to tell H directly (contact notices on the board)');

-- Review S3: handover candidates are reachable members only ------------------------------------------
create temp table g as select pg_temp.dep('SYNTHETIC 4.12 Welcome') as g;
select pg_temp.grant_scope(11, 'department_leader', (select g from g));
select pg_temp.grant_scope(8, 'department_deputy', (select g from g));
create temp table t5 as select pg_temp.newtask(1, 11, 8, (select g from g)) as src;
select is((select pg_temp.who(p.owner_to) from app.followups_handover_plan(pg_temp.mid(11), true) p
            where p.task_id = (pg_temp.task((select src from t5))).task_id), 7,
  'the unreachable supervisor (accountless X) is passed over for a reachable Pastor');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where role = 'pastor' and revoked_at is null;
select is((select o from jsonb_array_elements(app.followups_report_handover(
             jsonb_build_object('member_id', pg_temp.mid(11))) -> 'obligations') o
            where o ->> 'subject_id' = (pg_temp.task((select src from t5))).task_id::text),
  jsonb_build_object('kind', 'followup_task', 'subject_id', (pg_temp.task((select src from t5))).task_id,
                     'last_responsible', true),
  'with no reachable candidate left, CL is the last responsible owner');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

-- followups.complete_handover (Admin): continues a capped handover -------------------------------------
select is(pg_temp.err(pg_temp.call(2, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(4)))), 'forbidden', 'a leader cannot run it');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(2))) -> 'data') - 'member_id',
  '{"handed_over": 0, "remaining": 0}'::jsonb,
  'an active member still in every task''s group has nothing to hand over (review B1)');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(9))) -> 'data') - 'member_id',
  '{"handed_over": 0, "remaining": 0}'::jsonb, 'for a deactivated member with nothing left it reports zero');

-- Review B1: a revoked scope over the cap. O (reachable, not a member of G) deputises G and owns
-- 30 open tasks there (supervised by CL); the scope is revoked: 25 are handed over at once, the
-- other 5 wait. O loses owner authority over them at once (a), they are listed for the Admin with
-- the obligation kind (b), and complete_handover moves them though O is still active (c) ------------
select pg_temp.grant_scope(5, 'department_deputy', (select g from g));
create temp table b1 as
  select k, pg_temp.call(1, 'followups_command', 'followups.create_task', null, jsonb_build_object(
           'source_type', 'fixture_followup', 'source_id', gen_random_uuid(), 'source_revision', 1,
           'purpose', 'synthetic_check_in', 'owner_member_id', pg_temp.mid(5),
           'supervisor_member_id', pg_temp.mid(11), 'scope_kind', 'department_leader',
           'scope_id', (select g from g), 'next_action', 'SYNTHETIC: phone and check in',
           'due_at', app.cmd_utc(pg_temp.at(9)))) as r
    from generate_series(1, 30) k;
select is((select count(*)::int from b1 where r ->> 'code' is null), 30, 'setup: O owns 30 open tasks in G');
select is(pg_temp.err(pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope', pg_temp.grev(5),
            jsonb_build_object('member_id', pg_temp.mid(5), 'scope_kind', 'department_deputy',
                               'scope_id', (select g from g)))), 'ok', 'the Admin revokes O''s deputy scope of G');
create function pg_temp.b1_left() returns setof uuid language sql as $$
  select t.task_id from app.followups_tasks t
   where t.task_id in (select (r #>> '{data,task_id}')::uuid from b1) and t.owner_member_id = pg_temp.mid(5)
   order by t.task_id
$$;
select is((select count(*)::int from pg_temp.b1_left()), 5, 'the hook hands over 25 (its cap); 5 are left with O');
select is(pg_temp.read(5, format('select api.followups_task(%L::uuid)', (select pg_temp.b1_left() limit 1))),
  'not_granted', '(a) O can no longer open a task left with them');
select is(pg_temp.err(pg_temp.call(5, 'followups_command', 'followups.update_task',
            (select revision from app.followups_tasks where task_id = (select pg_temp.b1_left() limit 1)),
            jsonb_build_object('task_id', (select pg_temp.b1_left() limit 1), 'next_action', 'SYNTHETIC: changed'))),
  'not_found', '(a) nor update it');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(5, 'select api.followups_my_tasks()') -> 'tasks') x
            where (x ->> 'task_id')::uuid in (select pg_temp.b1_left())), 0,
  '(a) and My follow-ups no longer lists them');
select is((select string_agg(obligation_kind || '=' || n, ',') from (
             select h.obligation_kind, count(*) as n from app.followups_pending_handovers() h
              where h.member_id = pg_temp.mid(5) group by h.obligation_kind) x), 'followup_task=5',
  '(b) the 5 wait as followup_task handovers');
select is((select (h ->> 'tasks') || '|' || (h ->> 'membership_state')
             from jsonb_array_elements(pg_temp.readj(1, 'select api.followups_admin_routing()') -> 'handovers') h
            where h ->> 'member_id' = pg_temp.mid(5)::text), '5|approved', '(b) and the Admin sees them on Follow-ups');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(5))) -> 'data') - 'member_id',
  '{"handed_over": 5, "remaining": 0}'::jsonb, '(c) complete_handover moves them though O is still active');
select is((select count(*)::int from pg_temp.b1_left()) + (select count(*)::int from app.followups_pending_handovers() h
            where h.member_id = pg_temp.mid(5)), 0, '(c) nothing of O waits any more');
-- An accountless member still in the task's group keeps owner authority (the 4.6 design).
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.12 Accountless Z', 'approved', true) returning member_id)
insert into m select 12, member_id from ins;
select pg_temp.add(12, pg_temp.d());
create temp table tz as select pg_temp.newtask(1, 12, 2, pg_temp.d()) as src;
select is(app.followups_capacity(pg_temp.mid(12), pg_temp.task((select src from tz))), 'owner',
  'an accountless owner still in the group keeps owner capacity');

-- Review R1: a held or dormant Pastor keeps their pastoral task (the live-Pastor rule only picks
-- new owners). Pastor PS (7) deputises D and owns a task there (supervisor L) ---------------------
select pg_temp.grant_scope(7, 'department_deputy', pg_temp.d());
create temp table tp as select pg_temp.newtask(1, 7, 2, pg_temp.d()) as src;
create function pg_temp.tp() returns app.followups_tasks language sql as
$$ select pg_temp.task((select src from tp)) $$;
select is(pg_temp.err(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(7),
            jsonb_build_object('member_id', pg_temp.mid(7), 'reason_code', 'login_disabled'))), 'ok',
  'setup: a login hold on the Pastor');
select is(pg_temp.err(pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope', pg_temp.grev(7),
            jsonb_build_object('member_id', pg_temp.mid(7), 'scope_kind', 'department_deputy',
                               'scope_id', pg_temp.d()))), 'ok',
  'the held Pastor''s deputy scope is revoked (the scope_revoked hook runs)');
select is(pg_temp.who((pg_temp.tp()).owner_member_id), 7, 'the hook leaves the held Pastor''s task with them');
select is(app.followups_capacity(pg_temp.mid(7), pg_temp.tp()), 'owner', 'they keep owner capacity while held');
select is((select count(*)::int from app.followups_pending_handovers() h where h.member_id = pg_temp.mid(7)), 0,
  'nothing of theirs is listed as waiting');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(7))) -> 'data') - 'member_id',
  '{"handed_over": 0, "remaining": 0}'::jsonb, 'and complete_handover moves nothing');
select is(pg_temp.err(pg_temp.call(1, 'identity_credential_command', 'identity.release_hold', pg_temp.mrev(7),
            jsonb_build_object('member_id', pg_temp.mid(7), 'identity_check', 'in_person',
              'hold_id', (select h.hold_id from app.identity_holds h
                           where h.member_id = pg_temp.mid(7) and h.released_at is null)))), 'ok',
  'the hold is released');
select is(pg_temp.who((pg_temp.tp()).owner_member_id) || ':' || app.followups_capacity(pg_temp.mid(7), pg_temp.tp()),
  '7:owner', 'they still own it afterwards');
update app.identity_account_links set last_member_activity_at = now() - interval '3000 days',
       approved_at = least(approved_at, now() - interval '3000 days')
 where member_id = pg_temp.mid(7);
select ok(not app.followups_pastor_live(pg_temp.mid(7)), 'setup: the Pastor is now dormant (not live)');
select is(app.followups_capacity(pg_temp.mid(7), pg_temp.tp()), 'owner', 'a dormant Pastor keeps owner capacity');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(7))) -> 'data') - 'member_id',
  '{"handed_over": 0, "remaining": 0}'::jsonb, 'and their task is not handed away');
select is((select count(*)::int from app.followups_pending_handovers() h where h.member_id = pg_temp.mid(7)), 0,
  'nor listed as waiting');
update app.identity_account_links set last_member_activity_at = now() where member_id = pg_temp.mid(7);

-- Review R2: a roster hook that fails moves nothing for good (owner access stays closed meanwhile).
create function pg_temp.bad_roster(p jsonb) returns jsonb language plpgsql as
$$ begin raise exception 'SYNTHETIC roster failure'; end $$;
create temp table fam as select scope_kind, roster_hook from app.followups_scope_families;
update app.followups_scope_families set roster_hook = 'pg_temp.bad_roster(jsonb)'
 where app.followups_family(scope_kind) = app.followups_family('department_leader');
select is(app.followups_owner_roster('department_leader', pg_temp.d()), null, 'setup: D''s roster hook fails');
select is((select count(*)::int from app.followups_pending_handovers() h where h.member_id = pg_temp.mid(12)), 0,
  'a department member''s task is not listed as waiting while the hook fails');
select is((pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(12))) -> 'data') - 'member_id',
  '{"handed_over": 0, "remaining": 0}'::jsonb, 'complete_handover moves nothing');
select is(pg_temp.who((pg_temp.task((select src from tz))).owner_member_id), 12, 'the task stays with its owner');
select is(app.followups_capacity(pg_temp.mid(12), pg_temp.task((select src from tz))), null,
  'owner access stays closed while the roster is unknown');
update app.followups_scope_families f set roster_hook = x.roster_hook from fam x where x.scope_kind = f.scope_kind;
select is(app.followups_capacity(pg_temp.mid(12), pg_temp.task((select src from tz))), 'owner',
  'once the hook answers again the owner has their task back');

-- Review N10: a named supervisor's grants are share-locked by the authorizer (the payload is read
-- from the dispatcher's setting). The lock is seen on the grant row (xmax set).
create function pg_temp.grant_xmax(n int) returns text language sql as $$
  select string_agg(g.xmax::text, ',') from app.identity_grants g
   where g.member_id = pg_temp.mid(n) and g.revoked_at is null and g.scope_kind = 'department_deputy'
$$;
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select is(pg_temp.grant_xmax(3), '0', 'setup: P''s new deputy grant is not locked');
create function pg_temp.authorize_as(n int, p_payload jsonb) returns boolean language plpgsql as $$
declare v boolean;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  perform set_config('followups.command_payload', p_payload::text, true);
  v := app.followups_authorize_command('{"command": "followups.reassign"}'::jsonb);
  perform set_config('followups.command_payload', '', true);
  return v;
end;
$$;
select is(pg_temp.authorize_as(2, jsonb_build_object('supervisor_member_id', pg_temp.mid(3))), true,
  'the leader''s reassign naming P as supervisor is authorized');
select isnt(pg_temp.grant_xmax(3), '0', 'and P''s grant was share-locked first (review N10)');

-- Review S2: the members a command may notify, read from its payload (locked FOR KEY SHARE by the
-- authorizer before any Duties or Follow-ups row; HTTP race evidence in duties-lifecycle.mjs) ----------
select ok(app.duties_command_people(jsonb_build_object('payload', jsonb_build_object('occurrence_id', pg_temp.occ('LP'))),
            pg_temp.mid(1)) @> array[pg_temp.mid(1), pg_temp.mid(2)],
  'a Duties command on an occurrence names the actor, its assignee and its department''s leaders');
select is(app.duties_command_people('{"payload": {"occurrence_id": "not-a-uuid"}}'::jsonb, pg_temp.mid(1)),
  array[pg_temp.mid(1)], 'a malformed payload names only the actor (the handler refuses it later)');
select is((select array_agg(x order by x) from unnest(app.followups_command_people(
             jsonb_build_object('payload', jsonb_build_object('task_id', (pg_temp.task(pg_temp.t(2))).task_id)),
             pg_temp.mid(1))) x),
  (select array_agg(x order by x) from unnest(array[pg_temp.mid(1), pg_temp.mid(8), pg_temp.mid(2)]) x),
  'a Follow-ups command on a task names the actor, its owner and its supervisor');

-- Handover hooks are read only and well formed ------------------------------------------------------
select is((app.identity_collect_handover(jsonb_build_object('event', 'membership_deactivated',
            'member_id', pg_temp.mid(5), 'occurred_at', '2026-10-15T00:00:00Z', 'identity_revision', 1))),
  '[]'::jsonb, 'a member with nothing to hand over reports nothing');

-- Privileges, vocabulary, guards ----------------------------------------------------------------------
select is((select count(*)::int from information_schema.routine_privileges
            where routine_schema = 'app' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role')
              and routine_name in ('duties_lifecycle_actor', 'duties_vacated_since', 'duties_lifecycle_notify',
                                   'duties_vacate_member', 'duties_hold_contact', 'duties_scope_revoked',
                                   'duties_on_member_lifecycle', 'duties_report_handover',
                                   'duties_vacancy_alert_check', 'duties_remove_member',
                                   'duties_pending_handovers', 'duties_has_reachable_leader',
                                   'duties_resolve_handover', 'duties_lock_people', 'duties_command_people',
                                   'duties_jsonb_uuid', 'followups_jsonb_uuid', 'followups_in_group',
                                   'followups_pending_handovers', 'followups_owner_roster',
                                   'followups_reachable', 'followups_handover_plan',
                                   'followups_handover_member', 'followups_resolve_obligations',
                                   'followups_complete_handover', 'followups_lock_people',
                                   'followups_command_people',
                                   'followups_on_member_lifecycle', 'followups_report_handover',
                                   'followups_task_handover_sync')), 0,
  'nothing new is client-executable');
select is((select string_agg(event || ':' || module, ',' order by event, module) from app.contract_lifecycle_hooks
            where module in ('duties', 'followups')),
  'access_hold_applied:duties,deletion_requested:duties,deletion_requested:followups,membership_deactivated:duties,membership_deactivated:followups,scope_revoked:duties,scope_revoked:followups',
  'Duties and Follow-ups register their lifecycle hooks');
select is((select string_agg(module, ',' order by module) from app.identity_handover_hooks
            where module in ('duties', 'followups')), 'duties,followups', 'and their handover hooks');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok(app.duties_state_ok('assignment_end_reason', 'vacated') and app.duties_state_ok('capacity', 'lifecycle')
          and app.duties_state_ok('audit_action', 'review_cleared') and app.followups_state_ok('activity', 'reminders_skipped')
          and app.followups_state_ok('activity', 'reminders_adjusted'),
  'the vocabularies gain the 4.12 values and keep the earlier ones');

-- Erasure: who removed a member is anonymised -------------------------------------------------------
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(1), pg_temp.u(1), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'the erase phase leaves nothing of the Admin in Duties');
select is((select count(*)::int from app.duties_department_members
            where ended_by_member = pg_temp.mid(1) or ended_by_account = pg_temp.u(1)), 0,
  'the removals they made are anonymised');

select * from finish();
rollback;
