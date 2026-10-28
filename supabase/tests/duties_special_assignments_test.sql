-- Special assignments (owner decision 2026-10-21): a duty that belongs to no department and no
-- cell, given only by a Pastor, with either a fixed date and time or a due date ("done by"). The
-- three-owner check, the due moment (18:00 church time) and its rules (no busy time, the shared
-- answer-by default, started after it), give / revise / cancel with their refusals and replay,
-- My duties, the member's answers, overlaps as each reader may see them, the Pastors' read and
-- candidates, outcomes and Confirmed by the Pastor, My duty history (kind special), lifecycle and
-- privacy. Every account, phone and name is SYNTHETIC (fictional range +1 202 555 0111-0117).
-- Duty times are fixed church-time (Africa/Lusaka) clock times on whole days.
begin;
select plan(118);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000071' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000071' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (10 + n)::text $$;
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
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$
  select pg_temp.call(n, 'duties_command', p_command, p_expected, p_payload)
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
-- A read's outcome: 'ok' or 'SQLSTATE|message|detail'.
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
    return 'ok';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
-- Everything reader n can read in Duties (refused reads contribute nothing), as text.
create function pg_temp.everything(n int, p_target uuid) returns text
language plpgsql as $$
declare
  v_sql text;
  v_out text := '';
  r jsonb;
begin
  foreach v_sql in array array['select api.duties_my_duties()', 'select api.duties_leader_board()',
                               'select api.duties_rota()', 'select api.duties_coverage()',
                               'select api.duties_admin_overview()', 'select api.duties_outcomes()',
                               'select api.duties_special_assignments()',
                               format('select api.duties_member_history(%L::uuid)', p_target)] loop
    perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
    set local role authenticated;
    begin
      execute v_sql into r;
      v_out := v_out || coalesce(r::text, '');
    exception when others then
      null;
    end;
    reset role;
  end loop;
  return v_out;
end;
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- A fixed church-time clock time p_days church days from today (Africa/Lusaka), and the date.
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.lusaka(p_days int) returns date language sql as
$$ select (now() at time zone 'Africa/Lusaka')::date + p_days $$;

-- Accounts: 1 Admin; 2 Pastor A; 3 Pastor B; 4 member M; 5 leader L of department D (M serves in
-- D); 6 member O; 7 member Q.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.platform_set_environment('local', 'pgtap special assignments');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Special Member ' || n,
                                                         'pgtap special assignments')
  from generate_series(1, 7) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'pastor', 'israel'), (pg_temp.mid(3), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Special Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(5)),
  jsonb_build_object('member_id', pg_temp.mid(5), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d()));
select pg_temp.duties(1, 'duties.add_member',
  (select revision from app.duties_departments where department_id = pg_temp.d()),
  jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(4)));

-- Special assignments by tag.
create temp table gives (tag text primary key, r jsonb);
create function pg_temp.give(p_tag text, n int, p_payload jsonb) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(n, 'duties.give_special', null, p_payload);
  insert into gives values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from gives where tag = p_tag $$;
create function pg_temp.slot(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,slot_id}')::uuid from gives where tag = p_tag $$;
create function pg_temp.cur(p_tag text) returns uuid language sql as
$$ select assignment_id from app.duties_assignments where slot_id = pg_temp.slot(p_tag) and assignment_state = 'current' $$;
create function pg_temp.rev(p_id uuid) returns bigint language sql as
$$ select revision from app.duties_assignments where assignment_id = p_id $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.mine(n int, p_id uuid) returns jsonb language sql as $$
  select x from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_my_duties()') -> 'assignments') x
   where x ->> 'assignment_id' = p_id::text
$$;
create function pg_temp.item(n int, p_tag text) returns jsonb language sql as $$
  select x from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_special_assignments()') -> 'assignments') x
   where x ->> 'occurrence_id' = pg_temp.occ(p_tag)::text
$$;
create function pg_temp.revise(n int, p_tag text, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.revise_special', pg_temp.orev(pg_temp.occ(p_tag)),
                        jsonb_build_object('occurrence_id', pg_temp.occ(p_tag)) || p_payload)
$$;
create function pg_temp.jobs(p_id uuid, p_kind text, p_member int) returns bigint language sql as $$
  select count(*) from app.notifications_jobs j
   where j.source_id = p_id and j.reminder_kind = p_kind and j.recipient_member_id = pg_temp.mid(p_member)
$$;
-- Department duties for M, by tag.
create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_at timestamptz, p_reason text default null) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(5, 'duties.publish_duty', null, jsonb_strip_nulls(jsonb_build_object(
         'department_id', pg_temp.d(), 'member_id', pg_temp.mid(4), 'duty_name', 'Door ' || p_tag,
         'starts_at', app.cmd_utc(p_at), 'override_reason', p_reason)));
  insert into pubs values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.dslot(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,slot_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.docc(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;

-- The owner model --------------------------------------------------------------------------------
select throws_ok(format('insert into app.duties_occurrences (duty_name, starts_at, created_by_member, created_by_account) values (%L, %L, %L, %L)',
                        'SYNTHETIC No owner', pg_temp.at(5), pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'an occurrence with no owner is refused (exactly one of department, cell, special)');
select throws_ok(format('insert into app.duties_occurrences (special, department_id, duty_name, starts_at, created_by_member, created_by_account) values (true, %L, %L, %L, %L, %L)',
                        pg_temp.d(), 'SYNTHETIC Two owners', pg_temp.at(5), pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'a special assignment has no department');
select throws_ok(format('insert into app.duties_occurrences (special, occurrence_state, duty_name, starts_at, created_by_member, created_by_account) values (true, %L, %L, %L, %L, %L)',
                        'draft', 'SYNTHETIC Draft', pg_temp.at(5), pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'a special assignment is never a draft');
select throws_ok(format('insert into app.duties_occurrences (department_id, due_on, duty_name, starts_at, created_by_member, created_by_account) values (%L, %L, %L, %L, %L, %L)',
                        pg_temp.d(), pg_temp.lusaka(5), 'SYNTHETIC Due', pg_temp.at(5, '18:00'), pg_temp.mid(1), pg_temp.u(1)),
  '23514', null, 'only a special assignment has a due date');
select is(app.duties_due_moment('2026-11-30'), '2026-11-30 16:00:00+00'::timestamptz,
  'a due date ends at 18:00 church time (Africa/Lusaka, UTC+2)');
select ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'app' and p.proname in ('duties_due_moment', 'duties_special_timing', 'duties_lock_special',
                                             'duties_give_special', 'duties_revise_special',
                                             'duties_cancel_special', 'duties_special_json')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'the new commands and helpers are not client-executable');
select ok(has_function_privilege('authenticated', 'api.duties_special_assignments()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.duties_special_assignments()', 'EXECUTE'),
  'the Pastors'' read is executable by authenticated only');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'no module boundary violation (Duties reads only Identity, Notifications, Follow-ups, Platform)');

-- Giving --------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.give('G1', 2, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Lead the prayer meeting', 'location', 'SYNTHETIC Chapel',
  'starts_at', app.cmd_utc(pg_temp.at(10, '10:00')), 'ends_at', app.cmd_utc(pg_temp.at(10, '12:00'))))), 'ok',
  'Pastor A gives M a special assignment at a fixed time');
select is((select special::text || '|' || coalesce(department_id::text, '-') || '|' || coalesce(cell_id::text, '-')
                  || '|' || coalesce(due_on::text, '-') || '|' || occurrence_state
             from app.duties_occurrences where occurrence_id = pg_temp.occ('G1')),
  'true|-|-|-|published', 'it is owned by the church: no department, no cell, published');
select is(pg_temp.err(pg_temp.give('G2', 2, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Prepare the Christmas programme',
  'instructions', 'SYNTHETIC Draft the order of service.', 'due_on', pg_temp.lusaka(20)::text))), 'ok',
  'Pastor A gives M a special assignment with a due date');
select is((select starts_at = pg_temp.at(20, '18:00') and due_on = pg_temp.lusaka(20) and ends_at is null
             from app.duties_occurrences where occurrence_id = pg_temp.occ('G2')), true,
  'a due date is stored with its due moment (18:00 church time) and no end');
select is((select r #>> '{data,timing}' from gives where tag = 'G2'), 'due', 'the answer names the timing');
select is((select a.response_deadline = (app.duties_default_deadline(pg_temp.at(20, '18:00')) ->> 'response_deadline')::timestamptz
                  and a.deadline_source = 'default'
                  and to_char(a.response_deadline at time zone 'Africa/Lusaka', 'HH24:MI') = '18:00'
             from app.duties_assignments a where a.assignment_id = pg_temp.cur('G2')), true,
  'without an answer-by the shared lead-time default is taken against the due moment (an evening time)');
select is(pg_temp.jobs(pg_temp.cur('G1'), 'duty_assigned', 4), 1::bigint, 'M is sent the new-duty notice');
select is(app.duties_assignment_reminder_check(jsonb_build_object(
            'source_id', pg_temp.cur('G1'), 'source_revision', 1, 'recipient_member_id', pg_temp.mid(4))),
  '{"current": true, "revision": 1, "actionable": true, "recipient_eligible": true}'::jsonb,
  'M''s reminders stay deliverable (an active member; no roster)');
select is(app.duties_update_reminder_check(jsonb_build_object(
            'source_id', pg_temp.cur('G2'), 'source_revision', 1, 'recipient_member_id', pg_temp.mid(4))) ->> 'recipient_eligible',
  'true', 'the coming-up reminder of a due date is deliverable too');

select is(pg_temp.err(pg_temp.duties(1, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Admin', 'due_on', pg_temp.lusaka(9)::text))), 'forbidden',
  'the Admin role cannot give one');
select is(pg_temp.err(pg_temp.duties(5, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Leader', 'due_on', pg_temp.lusaka(9)::text))), 'forbidden',
  'a department leader cannot give one');
select is(pg_temp.err(pg_temp.duties(6, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Member', 'due_on', pg_temp.lusaka(9)::text))), 'forbidden',
  'a member cannot give one');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(2), 'duty_name', 'SYNTHETIC Self', 'due_on', pg_temp.lusaka(9)::text))),
  'validation_failed|member_id=own', 'a Pastor cannot give one to themselves');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Both', 'due_on', pg_temp.lusaka(9)::text,
  'starts_at', app.cmd_utc(pg_temp.at(9))))), 'validation_failed|due_on=with_starts_at',
  'a fixed time and a due date together are refused');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Neither'))), 'validation_failed|starts_at=required',
  'one of the two is required');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Due with end', 'due_on', pg_temp.lusaka(9)::text,
  'ends_at', app.cmd_utc(pg_temp.at(9))))), 'validation_failed|ends_at=with_due_on',
  'a due date has no end time');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Yesterday', 'due_on', pg_temp.lusaka(-1)::text))),
  'validation_failed|due_on=past', 'a due date already passed is refused');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Bad date', 'due_on', '2027-02-30'))),
  'validation_failed|due_on=invalid', 'a malformed due date is refused');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Report', 'starts_at', app.cmd_utc(pg_temp.at(9)),
  'reporting_at', app.cmd_utc(pg_temp.at(9, '09:00'))))), 'validation_failed|reporting_at=unknown_field',
  'a special assignment has no reporting time');
select is(pg_temp.err(pg_temp.duties(2, 'duties.give_special', null, jsonb_build_object(
  'member_id', gen_random_uuid(), 'duty_name', 'SYNTHETIC Nobody', 'due_on', pg_temp.lusaka(9)::text))),
  'validation_failed|member_id=unknown', 'an unknown member is refused');
create temp table rp as select pg_temp.call(2, 'duties_command', 'duties.give_special', null,
  jsonb_build_object('member_id', pg_temp.mid(6), 'duty_name', 'SYNTHETIC Replay', 'due_on', pg_temp.lusaka(40)::text),
  '00000000-0000-4000-a000-000000007101'::uuid) as r;
select is(pg_temp.call(2, 'duties_command', 'duties.give_special', null,
  jsonb_build_object('member_id', pg_temp.mid(6), 'duty_name', 'SYNTHETIC Replay', 'due_on', pg_temp.lusaka(40)::text),
  '00000000-0000-4000-a000-000000007101'::uuid), (select r from rp), 'a replay returns the original answer');
select is((select count(*)::int from app.duties_occurrences where duty_name = 'SYNTHETIC Replay'), 1,
  '... and gives it once');

-- My duties ----------------------------------------------------------------------------------------
select is((select (x ->> 'owner_kind') || '|' || coalesce(x ->> 'department_id', '-') || '|'
                  || coalesce(x ->> 'cell_id', '-') || '|' || coalesce(x ->> 'due_on', '-')
             from (select pg_temp.mine(4, pg_temp.cur('G1')) as x) y), 'special|-|-|-',
  'M''s My duties lists it as a special assignment (no department, no cell)');
select is((select (x ->> 'due_on') || '|' || coalesce(x ->> 'ends_at', '-')
             from (select pg_temp.mine(4, pg_temp.cur('G2')) as x) y), pg_temp.lusaka(20)::text || '|-',
  'a due-date assignment carries its due date');
select is((select x -> 'leaders' from (select pg_temp.mine(4, pg_temp.cur('G1')) as x) y),
  jsonb_build_array(jsonb_build_object('display_name', 'SYNTHETIC Special Member 2', 'role', 'pastor'),
                    jsonb_build_object('display_name', 'SYNTHETIC Special Member 3', 'role', 'pastor')),
  'the member is pointed to the Pastors, the one who gave it first');
select is(pg_temp.err(pg_temp.duties(4, 'duties.respond', pg_temp.rev(pg_temp.cur('G1')),
  jsonb_build_object('assignment_id', pg_temp.cur('G1'), 'response', 'accepted'))), 'ok', 'M accepts the first');
select is(pg_temp.err(pg_temp.duties(4, 'duties.respond', pg_temp.rev(pg_temp.cur('G2')),
  jsonb_build_object('assignment_id', pg_temp.cur('G2'), 'response', 'declined', 'note', 'SYNTHETIC travelling'))),
  'ok', 'M cannot make the second, with a note');

-- The Pastors' read ----------------------------------------------------------------------------------
select is((select array_agg(x ->> 'duty_name' order by n)
             from jsonb_array_elements(pg_temp.readj(3, 'select api.duties_special_assignments()') -> 'assignments')
                  with ordinality t(x, n)),
  array['SYNTHETIC Lead the prayer meeting', 'SYNTHETIC Prepare the Christmas programme', 'SYNTHETIC Replay'],
  'Pastor B reads every special assignment of the church, the soonest first');
select is((select (x ->> 'timing') || '|' || (x ->> 'due_on') || '|' || (x ->> 'given_by') || '|'
                  || (x #>> '{assignment,response}') || '|' || (x #>> '{assignment,note}') || '|'
                  || (x #>> '{assignment,display_name}')
             from (select pg_temp.item(3, 'G2') as x) y),
  'due|' || pg_temp.lusaka(20)::text || '|SYNTHETIC Special Member 2|declined|SYNTHETIC travelling|SYNTHETIC Special Member 4',
  'with the timing, who gave it, the answer and the member''s note');
select is((select x #> '{assignment,allowed}' from (select pg_temp.item(3, 'G1') as x) y), '[]'::jsonb,
  'no outcome may be recorded before the start');
select is((select (j -> 'members') @> jsonb_build_array(jsonb_build_object('member_id', pg_temp.mid(4)))
                  and not (j -> 'members') @> jsonb_build_array(jsonb_build_object('member_id', pg_temp.mid(3)))
             from (select pg_temp.readj(3, 'select api.duties_special_assignments()') as j) y), true,
  'the members it may be given to: every active member but the reader');
select is(pg_temp.read(1, 'select api.duties_special_assignments()'), 'PT403|forbidden|not_granted',
  'the Admin role cannot read it');
select is(pg_temp.read(5, 'select api.duties_special_assignments()'), 'PT403|forbidden|not_granted',
  'a department leader cannot read it');
select is(pg_temp.read(4, 'select api.duties_special_assignments()'), 'PT403|forbidden|not_granted',
  'the member reads theirs in My duties, not here');

-- Overlaps -------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.pub('D1', pg_temp.at(10, '11:00'))), 'validation_failed|member_id=overlap,override_reason=required',
  'a department duty over M''s fixed-time special assignment needs a reason');
select is(pg_temp.err(pg_temp.pub('D1b', pg_temp.at(10, '11:00'), 'SYNTHETIC short of ushers')), 'ok',
  '... and is published with one');
select is((select c -> 'items' from jsonb_array_elements(pg_temp.readj(5, format(
             'select api.duties_candidates(department_id => %L::uuid, starts_at => %L::timestamptz)',
             pg_temp.d(), pg_temp.at(10, '10:30'))) -> 'candidates') x, lateral (select x -> 'conflicts' as c) z
            where x ->> 'member_id' = pg_temp.mid(4)::text) @> jsonb_build_array(jsonb_build_object(
              'visibility', 'limited', 'owner_kind', 'special')), true,
  'the leader sees the special assignment as a busy time only');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(5, format(
             'select api.duties_candidates(department_id => %L::uuid, starts_at => %L::timestamptz)',
             pg_temp.d(), pg_temp.at(10, '10:30'))) -> 'candidates') x, jsonb_array_elements(x #> '{conflicts,items}') i
            where i ->> 'owner_kind' = 'special' and i ? 'duty_name'), 0,
  '... never its name');
create temp table pc as select pg_temp.readj(2, format('select api.duties_candidates(starts_at => %L::timestamptz)',
  pg_temp.at(10, '10:30'))) as j;
select is((select array_agg((i ->> 'owner_kind') || ':' || (i ->> 'visibility') || ':' || coalesce(i ->> 'duty_name', '-')
                            order by i ->> 'owner_kind')
             from pc, jsonb_array_elements(j -> 'candidates') x, jsonb_array_elements(x #> '{conflicts,items}') i
            where x ->> 'member_id' = pg_temp.mid(4)::text),
  array['department:limited:-', 'special:full:SYNTHETIC Lead the prayer meeting'],
  'a Pastor''s candidates: special assignments in full, department duties as busy times');
select is((select count(*)::int from pc, jsonb_array_elements(j -> 'candidates') x
            where x ->> 'member_id' in (pg_temp.mid(2)::text, pg_temp.mid(4)::text)), 1,
  'every active member is a candidate except the Pastor asking');
select is(pg_temp.read(5, format('select api.duties_candidates(starts_at => %L::timestamptz)', pg_temp.at(10, '10:30'))),
  'PT403|forbidden|not_granted', 'only a Pastor asks for a special assignment''s candidates');
select is(pg_temp.read(2, format('select api.duties_candidates(slot_id => %L::uuid)', pg_temp.slot('G2'))),
  'PT400|validation_failed|window', 'a due date has no busy time to check');
select is(pg_temp.err(pg_temp.pub('D2', pg_temp.at(20, '18:00'))), 'ok',
  'a department duty at a due moment needs no reason: a due date never overlaps');
select is(app.duties_overlap_counts(array[pg_temp.docc('D1b'), pg_temp.docc('D2')]),
  jsonb_build_object(pg_temp.dslot('D1b'), 1),
  'the board counts the fixed-time overlap only');

-- Changing ---------------------------------------------------------------------------------------------
create temp table g2old as select pg_temp.cur('G2') as id, pg_temp.orev(pg_temp.occ('G2')) as orev;
select is((select r #>> '{data,change}' from (select pg_temp.revise(3, 'G2',
  jsonb_build_object('due_on', pg_temp.lusaka(25)::text)) as r) y), 'material',
  'Pastor B moves the due date (a material change)');
select is((select (x ->> 'response') || '|' || (x -> 'changes')::text || '|' || (x ->> 'previous_response') || '|' || (x ->> 'due_on')
             from (select pg_temp.mine(4, pg_temp.cur('G2')) as x) y),
  'pending|["starts_at", "due_on"]|declined|' || pg_temp.lusaka(25)::text,
  'M is asked again, with what changed and the earlier answer kept');
select is(pg_temp.err(pg_temp.duties(2, 'duties.revise_special', (select orev from g2old),
  jsonb_build_object('occurrence_id', pg_temp.occ('G2'), 'duty_name', 'SYNTHETIC Stale'))), 'conflict',
  'a change at an old revision is a conflict');
create temp table g1acc as select pg_temp.cur('G1') as id;
select is((select r #>> '{data,change}' from (select pg_temp.revise(2, 'G1',
  jsonb_build_object('instructions', 'SYNTHETIC Bring the hymn list.')) as r) y), 'notes',
  'an instructions-only change keeps the answer');
select is((select pg_temp.cur('G1') = id and (pg_temp.mine(4, id) ->> 'response') = 'accepted' from g1acc), true,
  '... M''s acceptance stands');
select is(pg_temp.err(pg_temp.revise(2, 'G1', jsonb_build_object('due_on', pg_temp.lusaka(30)::text))), 'ok',
  'a fixed time becomes a due date');
select is((select starts_at = pg_temp.at(30, '18:00') and ends_at is null and due_on = pg_temp.lusaka(30)
             from app.duties_occurrences where occurrence_id = pg_temp.occ('G1')), true,
  '... with its due moment and no end');
create temp table g1m as select pg_temp.cur('G1') as id;
select is(pg_temp.err(pg_temp.revise(2, 'G1', jsonb_build_object('member_id', pg_temp.mid(6)))), 'ok',
  'Pastor A gives it to O instead');
select is((select (select member_id from app.duties_assignments where assignment_id = pg_temp.cur('G1')) = pg_temp.mid(6)
                  and pg_temp.jobs(id, 'duty_released', 4) = 1 from g1m), true,
  'O holds it now and M is told it is no longer theirs');
select is(pg_temp.err(pg_temp.revise(2, 'G1', jsonb_build_object('member_id', pg_temp.mid(2)))),
  'validation_failed|member_id=own', 'a Pastor cannot give it to themselves');
select is(pg_temp.err(pg_temp.revise(2, 'G1', jsonb_build_object('member_id', null))),
  'validation_failed|member_id=required', 'a special assignment always has someone');
select is(pg_temp.err(pg_temp.revise(1, 'G1', jsonb_build_object('duty_name', 'SYNTHETIC Admin edit'))), 'not_found',
  'the Admin role cannot change it (not disclosed)');
select is(pg_temp.err(pg_temp.revise(5, 'G1', jsonb_build_object('duty_name', 'SYNTHETIC Leader edit'))), 'not_found',
  'a department leader cannot change it');
select is(pg_temp.err(pg_temp.duties(2, 'duties.revise_special', pg_temp.orev(pg_temp.docc('D2')),
  jsonb_build_object('occurrence_id', pg_temp.docc('D2'), 'duty_name', 'SYNTHETIC Hijack'))), 'not_found',
  'a Pastor cannot change a department duty through it');
select is(pg_temp.err(pg_temp.revise(2, 'G1', jsonb_build_object('duty_name', 'SYNTHETIC Lead the prayer meeting'))),
  'validation_failed|occurrence_id=unchanged', 'a change that changes nothing is refused');

-- Confirmed by the Pastor --------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.duties(2, 'duties.confirm_by_leader', pg_temp.rev(pg_temp.cur('G1')),
  jsonb_build_object('assignment_id', pg_temp.cur('G1'), 'channel', 'phone', 'reason', 'SYNTHETIC said yes on a call'))),
  'ok', 'Pastor A records O''s acceptance after a call');
select is((select response || '|' || response_provenance || '|' || confirmed_channel
             from app.duties_assignments where assignment_id = pg_temp.cur('G1')), 'accepted|leader|phone',
  '... kept apart from an answer in the app');
select is((select actor_capacity from app.duties_audit where action = 'leader_confirmed'
            and assignment_id = pg_temp.cur('G1')), 'pastor', '... audited with the Pastor''s capacity');
select is(pg_temp.err(pg_temp.duties(5, 'duties.confirm_by_leader', pg_temp.rev(pg_temp.cur('G2')),
  jsonb_build_object('assignment_id', pg_temp.cur('G2'), 'channel', 'phone', 'reason', 'SYNTHETIC no'))), 'not_found',
  'a department leader cannot confirm a special assignment');

-- Cancelling -------------------------------------------------------------------------------------------
create temp table g2c as select pg_temp.cur('G2') as id;
select is((select r #>> '{data,state}' from (select pg_temp.duties(2, 'duties.cancel_special',
  pg_temp.orev(pg_temp.occ('G2')), jsonb_build_object('occurrence_id', pg_temp.occ('G2'))) as r) y), 'cancelled',
  'Pastor A cancels the second');
select is((select pg_temp.jobs(id, 'duty_cancelled', 4) from g2c), 1::bigint, 'M is told');
select is((select pg_temp.item(2, 'G2') is null and pg_temp.mine(4, id) is null from g2c), true,
  'a cancelled special assignment leaves the Pastors'' read and My duties');
select is(pg_temp.err(pg_temp.duties(2, 'duties.cancel_special', pg_temp.orev(pg_temp.occ('G2')),
  jsonb_build_object('occurrence_id', pg_temp.occ('G2')))), 'validation_failed|occurrence_id=cancelled',
  'it cannot be cancelled twice');
select is(pg_temp.err(pg_temp.duties(5, 'duties.cancel_special', pg_temp.orev(pg_temp.occ('G1')),
  jsonb_build_object('occurrence_id', pg_temp.occ('G1')))), 'not_found', 'a department leader cannot cancel one');

-- Outcomes ---------------------------------------------------------------------------------------------
-- Three more, then moved into the past (a test-only time shift): P1 accepted by M at a fixed
-- time, P2 a due date M never answered, P3 Pastor B's own.
select pg_temp.give('P1', 2, jsonb_build_object('member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Visit the sick',
  'starts_at', app.cmd_utc(pg_temp.at(3, '15:00'))));
select pg_temp.give('P2', 2, jsonb_build_object('member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC Write the report',
  'due_on', pg_temp.lusaka(4)::text));
select pg_temp.give('P3', 2, jsonb_build_object('member_id', pg_temp.mid(3), 'duty_name', 'SYNTHETIC Lead Sunday worship',
  'starts_at', app.cmd_utc(pg_temp.at(5, '09:00'))));
select pg_temp.duties(4, 'duties.respond', pg_temp.rev(pg_temp.cur('P1')),
  jsonb_build_object('assignment_id', pg_temp.cur('P1'), 'response', 'accepted'));
select pg_temp.duties(3, 'duties.respond', pg_temp.rev(pg_temp.cur('P3')),
  jsonb_build_object('assignment_id', pg_temp.cur('P3'), 'response', 'accepted'));
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P1')),
  jsonb_build_object('assignment_id', pg_temp.cur('P1'), 'outcome', 'completed'))),
  'validation_failed|assignment_id=not_started', 'no outcome before the start');
update app.duties_occurrences set starts_at = pg_temp.at(-3, '15:00') where occurrence_id = pg_temp.occ('P1');
update app.duties_occurrences set due_on = pg_temp.lusaka(-2), starts_at = pg_temp.at(-2, '18:00')
 where occurrence_id = pg_temp.occ('P2');
update app.duties_occurrences set starts_at = pg_temp.at(-1, '09:00') where occurrence_id = pg_temp.occ('P3');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P1')),
  jsonb_build_object('assignment_id', pg_temp.cur('P1'), 'outcome', 'completed', 'note', 'SYNTHETIC went twice'))), 'ok',
  'after it, Pastor A records Completed');
select is((select actor_capacity from app.duties_audit where action = 'outcome_recorded'
            and assignment_id = pg_temp.cur('P1')), 'pastor', '... with the Pastor''s capacity');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P2')),
  jsonb_build_object('assignment_id', pg_temp.cur('P2'), 'outcome', 'no_show'))), 'validation_failed|outcome=not_accepted',
  'an unanswered due date past its due moment cannot be a No-show');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P2')),
  jsonb_build_object('assignment_id', pg_temp.cur('P2'), 'outcome', 'excused'))), 'ok', '... it can be Excused');
select is(pg_temp.err(pg_temp.duties(3, 'duties.correct_outcome', 1,
  jsonb_build_object('assignment_id', pg_temp.cur('P1'), 'outcome', 'no_show', 'reason', 'SYNTHETIC wrong person recorded'))),
  'ok', 'Pastor B corrects it with a reason');
select is((select x #>> '{assignment,outcome,outcome}' || '|' || (x #>> '{assignment,outcome,revision}') || '|'
                  || jsonb_array_length(x #> '{assignment,outcome,trail}')
             from (select pg_temp.item(2, 'P1') as x) y), 'no_show|2|2',
  'the Pastors'' read shows the outcome with its trail');
select is((select x #> '{assignment,allowed}' from (select pg_temp.item(2, 'P1') as x) y),
  '["completed", "excused", "no_show"]'::jsonb, '... and what may be recorded for an accepted one');
select is(pg_temp.err(pg_temp.duties(1, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P3')),
  jsonb_build_object('assignment_id', pg_temp.cur('P3'), 'outcome', 'completed'))), 'not_found',
  'the Admin role cannot record it (not disclosed)');
select is(pg_temp.err(pg_temp.duties(5, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P3')),
  jsonb_build_object('assignment_id', pg_temp.cur('P3'), 'outcome', 'completed'))), 'not_found',
  'a department leader cannot record it');
select is(pg_temp.err(pg_temp.duties(3, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P3')),
  jsonb_build_object('assignment_id', pg_temp.cur('P3'), 'outcome', 'completed'))), 'validation_failed|assignment_id=own',
  'a Pastor never records their own');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', pg_temp.rev(pg_temp.cur('P3')),
  jsonb_build_object('assignment_id', pg_temp.cur('P3'), 'outcome', 'completed'))), 'ok',
  'another Pastor does');
select is((select x #>> '{assignment,own}' from (select pg_temp.item(3, 'P3') as x) y), 'true',
  'Pastor B sees their own marked as theirs');

-- My duty history --------------------------------------------------------------------------------------
create temp table hm as select pg_temp.readj(4, 'select api.duties_member_history()') as j;
select is((select j -> 'kinds' from hm), '{"department": 2, "cell": 0, "special": 4}'::jsonb,
  'M''s history counts the special assignments under their own kind');
create temp table hs as select pg_temp.readj(4, 'select api.duties_member_history(kind => ''special'')') as j;
select is((select array_agg(distinct e ->> 'owner_kind') from hs, jsonb_array_elements(j -> 'entries') e),
  array['special'], 'the special filter lists special assignments only');
select is((select string_agg((e ->> 'duty_name') || ':' || (e ->> 'state') || ':' || (e ->> 'outcome_state'), ', '
                             order by e ->> 'duty_name')
             from hs, jsonb_array_elements(j -> 'entries') e),
  'SYNTHETIC Lead the prayer meeting:reassigned:none, SYNTHETIC Prepare the Christmas programme:cancelled:none, '
  || 'SYNTHETIC Visit the sick:current:no_show, SYNTHETIC Write the report:current:excused',
  'each with its state and the outcome the Pastor recorded');
select is((select e ->> 'due_on' from hs, jsonb_array_elements(j -> 'entries') e
            where e ->> 'duty_name' = 'SYNTHETIC Write the report'), pg_temp.lusaka(-2)::text,
  'a due-date entry carries its due date');
select is((select (j #>> '{summary,held}') || '/' || (j #>> '{summary,excused}') || '/' || (j #>> '{summary,no_show}')
                  || '/' || (j #>> '{summary,unrecorded}') from hs), '2/1/1/0',
  'the summary counts special assignments'' outcomes');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(5, format(
             'select api.duties_member_history(%L::uuid)', pg_temp.mid(4))) -> 'entries') e
            where e ->> 'owner_kind' = 'special'), 0,
  'a department leader reading M''s history never sees a special assignment');

-- Review finding F7: the timing mode is a change of its own ------------------------------------------------
-- A due date (due moment 18:00) becomes an appointment at 18:00 on the same date with no end: the
-- normalised start and end are equal, the obligation is not.
select pg_temp.give('F7A', 3, jsonb_build_object('member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC F7 Hand in the plan',
  'due_on', pg_temp.lusaka(50)::text));
select is((select due_on from app.duties_slot_revisions where slot_id = pg_temp.slot('F7A') and slot_revision = 1),
  pg_temp.lusaka(50), 'F7: revision 1 records the due date');
select pg_temp.duties(4, 'duties.respond', pg_temp.rev(pg_temp.cur('F7A')),
  jsonb_build_object('assignment_id', pg_temp.cur('F7A'), 'response', 'accepted'));
create temp table f7a as select pg_temp.cur('F7A') as id;
select is((select r #>> '{data,change}' from (select pg_temp.revise(3, 'F7A', jsonb_build_object(
  'starts_at', app.cmd_utc(pg_temp.at(50, '18:00')), 'ends_at', null)) as r) y), 'material',
  'F7: deadline to appointment at the same instant, alone, is a material change (not unchanged)');
select is((select o.due_on is null and o.starts_at = pg_temp.at(50, '18:00') from app.duties_occurrences o
            where o.occurrence_id = pg_temp.occ('F7A')), true, 'F7: it is now a fixed time');
select is((select pg_temp.cur('F7A') <> id and (pg_temp.mine(4, pg_temp.cur('F7A')) ->> 'response') = 'pending'
                  and (pg_temp.mine(4, pg_temp.cur('F7A')) -> 'changes') = '["due_on"]'::jsonb
                  and (pg_temp.mine(4, pg_temp.cur('F7A')) ->> 'previous_response') = 'accepted' from f7a), true,
  'F7: M is asked again (a new acceptance), told the due date changed, the earlier answer kept');
select is((select pg_temp.jobs(pg_temp.cur('F7A'), 'duty_changed', 4)), 1::bigint, 'F7: with the changed-duty notice');
select is((select change_class || '|' || coalesce(due_on::text, '-') || '|' || array_to_string(changed_fields, ',')
             from app.duties_slot_revisions where slot_id = pg_temp.slot('F7A')
            order by slot_revision desc limit 1), 'material|-|due_on', 'F7: the revision history records it');
create temp table f7a2 as select pg_temp.cur('F7A') as id;
select is((select r #>> '{data,change}' from (select pg_temp.revise(3, 'F7A', jsonb_build_object(
  'due_on', pg_temp.lusaka(50)::text)) as r) y), 'material',
  'F7: and back, appointment to deadline at the same instant, alone');
select is((select pg_temp.cur('F7A') <> id from f7a2)
          and (select due_on from app.duties_slot_revisions where slot_id = pg_temp.slot('F7A')
                order by slot_revision desc limit 1) = pg_temp.lusaka(50), true,
  'F7: a new assignment, and the history has the due date again');

-- With a notes change too, the mode change still asks again and checks overlaps.
select pg_temp.give('F7B', 3, jsonb_build_object('member_id', pg_temp.mid(4), 'duty_name', 'SYNTHETIC F7 Count the hymn books',
  'due_on', pg_temp.lusaka(51)::text));
select pg_temp.duties(4, 'duties.respond', pg_temp.rev(pg_temp.cur('F7B')),
  jsonb_build_object('assignment_id', pg_temp.cur('F7B'), 'response', 'accepted'));
select is(pg_temp.err(pg_temp.pub('F7D', pg_temp.at(51, '18:00'))), 'ok',
  'F7 setup: M has a department duty at 18:00 that day (no overlap with a due date)');
select is(pg_temp.err(pg_temp.revise(3, 'F7B', jsonb_build_object(
  'starts_at', app.cmd_utc(pg_temp.at(51, '18:00')), 'ends_at', null, 'instructions', 'SYNTHETIC In the vestry.'))),
  'validation_failed|member_id=overlap,override_reason=required',
  'F7: deadline to appointment with a notes change meets the overlap check (refused without a reason)');
create temp table f7b as select pg_temp.cur('F7B') as id;
select is((select r #>> '{data,change}' || '|' || (r #>> '{data,overrides}') from (select pg_temp.revise(3, 'F7B', jsonb_build_object(
  'starts_at', app.cmd_utc(pg_temp.at(51, '18:00')), 'ends_at', null, 'instructions', 'SYNTHETIC In the vestry.',
  'override_reason', 'SYNTHETIC both are short')) as r) y), 'material|1',
  'F7: with an approved override it is a material change, the override recorded');
select is((select pg_temp.cur('F7B') <> id and (pg_temp.mine(4, pg_temp.cur('F7B')) ->> 'response') = 'pending'
                  and (pg_temp.mine(4, pg_temp.cur('F7B')) -> 'changes') = '["due_on", "instructions"]'::jsonb from f7b), true,
  'F7: and M must accept again');
create temp table f7b2 as select pg_temp.cur('F7B') as id;
select is((select r #>> '{data,change}' from (select pg_temp.revise(3, 'F7B', jsonb_build_object(
  'due_on', pg_temp.lusaka(51)::text, 'instructions', 'SYNTHETIC In the office.')) as r) y), 'material',
  'F7: appointment to deadline with a notes change is material too');
select is((select pg_temp.cur('F7B') <> id from f7b2), true, 'F7: ... a new assignment');
create temp table f7b3 as select pg_temp.cur('F7B') as id;
select is((select r #>> '{data,change}' from (select pg_temp.revise(3, 'F7B', jsonb_build_object(
  'instructions', 'SYNTHETIC In the library.')) as r) y), 'notes',
  'F7: a pure notes change keeps its behaviour');
select is((select pg_temp.cur('F7B') = id from f7b3), true, 'F7: ... the same assignment, no new acceptance');

-- Lifecycle and privacy --------------------------------------------------------------------------------
select pg_temp.give('G7', 3, jsonb_build_object('member_id', pg_temp.mid(7), 'duty_name', 'SYNTHETIC Count the offering',
  'due_on', pg_temp.lusaka(12)::text));
select is((app.duties_vacate_member(pg_temp.mid(7), null, 'member_left', false, pg_temp.mid(1), pg_temp.u(1),
                                    'lifecycle', null) ->> 'vacated'), '1',
  'a member leaving the church ends their special assignment');
select is((select x -> 'assignment' = 'null'::jsonb
                  and x -> 'vacancy' = jsonb_build_object('reason', 'member_inactive', 'since',
                        (select app.cmd_utc(ended_at) from app.duties_assignments where slot_id = pg_temp.slot('G7')))
             from (select pg_temp.item(2, 'G7') as x) y), true,
  'the Pastors see it needs someone new');
select is(pg_temp.err(pg_temp.revise(2, 'G7', jsonb_build_object('member_id', pg_temp.mid(6)))), 'ok',
  'a Pastor gives it to someone else');
select ok((select position('SYNTHETIC Lead the prayer' in pg_temp.everything(5, pg_temp.mid(4))) = 0
                  and position('SYNTHETIC Visit the sick' in pg_temp.everything(5, pg_temp.mid(4))) = 0),
  'nothing a department leader reads names a special assignment');
select ok((select position('SYNTHETIC Visit the sick' in pg_temp.everything(1, pg_temp.mid(4))) = 0),
  'nothing the Admin role reads names one');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where member_id = pg_temp.mid(2) and role = 'pastor';
select is(pg_temp.err(pg_temp.call(2, 'duties_command', 'duties.give_special', null,
  jsonb_build_object('member_id', pg_temp.mid(6), 'duty_name', 'SYNTHETIC Replay', 'due_on', pg_temp.lusaka(40)::text),
  '00000000-0000-4000-a000-000000007101'::uuid)), 'forbidden',
  'a replay after the Pastor role ends is refused');
select is(pg_temp.read(2, 'select api.duties_special_assignments()'), 'PT403|forbidden|not_granted',
  'and the read with it');

select * from finish();
rollback;
