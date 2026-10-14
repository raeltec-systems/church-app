-- Record duty completion outcomes and keep assignment history (story 4.10; AD-2, AD-5, AD-6,
-- AD-7): Completed, Excused and No-show recorded by the department's leader or deputy after the
-- duty, attributed append-only corrections (the prior value, note, actor and time kept), response,
-- coverage and completion kept separate (an unrecorded past duty stays unrecorded when time
-- passes, a declined or unanswered assignment never becomes a No-show, a cancelled accepted duty
-- or a superseded assignment has no outcome), no self-grading, the outcomes read and the member
-- history read (the member and their department's leaders and deputies only; Admin role alone,
-- Pastor, another department's leader and other members see nothing), My duties, every other read
-- free of outcome text, codes-only audit and receipts, no notifications, erasure, the Q4 gate and
-- privileges. HTTP evidence: tools/identity-e2e/duties-outcomes.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900130-900139). Duty times
-- are fixed church-time (Africa/Lusaka) clock times on whole days, never the current clock time.
begin;
select plan(126);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000410' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000410' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (130 + n)::text $$;
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
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
-- A fixed church-time clock time p_days church days from today (Africa/Lusaka).
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.lusaka(p_days int) returns date language sql as
$$ select (now() at time zone 'Africa/Lusaka')::date + p_days $$;

-- Accounts: 1 Admin (no department scope); 2 leader L of D; 3 deputy P of D; 4 member M; 5 member
-- O; 6 member Q; 7 Pastor; 8 accountless member X (no account); 9 leader K of department E;
-- 10 a member with no role and no department.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n % 10), '+'), now()
  from generate_series(1, 10) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 10) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.10');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.10 Member ' || n, 'pgtap 4.10')
  from generate_series(1, 10) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.10 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.10 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.e() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from de $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_department uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_department))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(9, 'department_leader', pg_temp.e());
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(n, pg_temp.d()) from unnest(array[2, 3, 4, 5, 6, 8]) n;
select pg_temp.add(4, pg_temp.e());

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
create function pg_temp.cur(p_tag text) returns uuid language sql as
$$ select assignment_id from app.duties_assignments where slot_id = pg_temp.slot(p_tag) and assignment_state = 'current' $$;
create function pg_temp.rev(p_id uuid) returns bigint language sql as
$$ select revision from app.duties_assignments where assignment_id = p_id $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.answer(n int, p_id uuid, p_response text) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.respond', pg_temp.rev(p_id),
                        jsonb_build_object('assignment_id', p_id, 'response', p_response))
$$;
-- Moves a duty into the past (p_days church days ago, 10:00); a test-only time shift.
create function pg_temp.past(p_tag text, p_days int) returns void language sql as $$
  update app.duties_occurrences set starts_at = pg_temp.at(-p_days), ends_at = null, reporting_at = null
   where occurrence_id = pg_temp.occ(p_tag)
$$;
create function pg_temp.orev_of(p_id uuid) returns bigint language sql as
$$ select coalesce(max(revision), 0) from app.duties_outcomes where assignment_id = p_id $$;
create function pg_temp.record(n int, p_id uuid, p_outcome text, p_note text default null,
                               p_expected bigint default null) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.record_outcome', coalesce(p_expected, pg_temp.rev(p_id)),
    jsonb_strip_nulls(jsonb_build_object('assignment_id', p_id, 'outcome', p_outcome, 'note', p_note)))
$$;
create function pg_temp.correct(n int, p_id uuid, p_outcome text, p_reason text, p_note text default null,
                                p_expected bigint default null) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.correct_outcome', coalesce(p_expected, pg_temp.orev_of(p_id)),
    jsonb_strip_nulls(jsonb_build_object('assignment_id', p_id, 'outcome', p_outcome, 'note', p_note,
                                         'reason', p_reason)))
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- A position of the outcomes read (by assignment id), as reader n sees it.
create function pg_temp.opos(n int, p_id uuid, p_args text default '') returns jsonb language sql as $$
  select p from jsonb_array_elements(pg_temp.readj(n, format('select api.duties_outcomes(%s)', p_args)) -> 'departments') dep,
                jsonb_array_elements(dep -> 'positions') p
   where p #>> '{assignment,assignment_id}' = p_id::text
$$;
-- A history entry (by assignment id) of member p_target as reader n sees it.
create function pg_temp.hist(n int, p_target int) returns jsonb language sql as $$
  select pg_temp.readj(n, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(p_target)))
$$;
create function pg_temp.hentry(n int, p_target int, p_id uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.hist(n, p_target) -> 'entries') e
   where e ->> 'assignment_id' = p_id::text
$$;
create function pg_temp.jobcount() returns bigint language sql as $$ select count(*) from app.notifications_jobs $$;

-- The duties ----------------------------------------------------------------------------------------
select pg_temp.pub('A', 4, 11);          -- M accepts; completed, then corrected to No-show
select pg_temp.pub('B', 5, 12);          -- O declines
select pg_temp.pub('C', 6, 13);          -- Q never answers (stays unrecorded)
select pg_temp.pub('K', 4, 14);          -- M accepts, then the duty is cancelled
select pg_temp.pub('F', 4, 15);          -- M accepts; has not started
select pg_temp.pub('S', 4, 16);          -- M, then reassigned to Q (superseded)
select pg_temp.pub('R', 4, 17);          -- M, a material change re-asks M (one history row)
select pg_temp.pub('L', 2, 18);          -- the leader's own duty
select pg_temp.pub('X', 8, 19);          -- accountless X, Confirmed by leader
select pg_temp.pub('E', 4, 20, 9, pg_temp.e());  -- M in department E
select pg_temp.answer(4, pg_temp.a('A'), 'accepted');
select pg_temp.answer(5, pg_temp.a('B'), 'declined');
select pg_temp.answer(4, pg_temp.a('K'), 'accepted');
select pg_temp.answer(4, pg_temp.a('F'), 'accepted');
select pg_temp.answer(2, pg_temp.a('L'), 'accepted');
select pg_temp.answer(4, pg_temp.a('E'), 'accepted');
select pg_temp.duties(2, 'duties.confirm_by_leader', pg_temp.rev(pg_temp.a('X')),
  jsonb_build_object('assignment_id', pg_temp.a('X'), 'channel', 'phone', 'reason', 'SYNTHETIC: said yes by phone'));
select is(pg_temp.err(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.occ('K')),
                                     jsonb_build_object('slot_id', pg_temp.slot('K')))), 'ok',
  'setup: the accepted duty K is cancelled');
select is(pg_temp.err(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('S')),
                                     jsonb_build_object('slot_id', pg_temp.slot('S'), 'member_id', pg_temp.mid(6)))),
  'ok', 'setup: S is reassigned from M to Q');
select is(pg_temp.err(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('R')),
                                     jsonb_build_object('occurrence_id', pg_temp.occ('R'),
                                                        'starts_at', app.cmd_utc(pg_temp.at(17, '11:00'))))),
  'ok', 'setup: R changes time (M is asked again on a new assignment)');
select pg_temp.answer(4, pg_temp.cur('R'), 'accepted');
select pg_temp.past('A', 1); select pg_temp.past('B', 2); select pg_temp.past('C', 2);
select pg_temp.past('K', 3); select pg_temp.past('S', 3); select pg_temp.past('R', 4);
select pg_temp.past('L', 1); select pg_temp.past('X', 5); select pg_temp.past('E', 6);

-- Passing time never sets an outcome -----------------------------------------------------------------
select pg_temp.run();
select is((select count(*)::int from app.duties_outcomes), 0, 'after the duties passed (and the worker ran) nothing recorded an outcome');
select is(pg_temp.opos(2, pg_temp.a('C')) #>> '{assignment,outcome_state}', 'unrecorded',
  'an unanswered past duty shows Unrecorded');
select is(pg_temp.opos(2, pg_temp.a('A')) #>> '{assignment,outcome_state}', 'unrecorded',
  'an accepted past duty shows Unrecorded until a leader records it');
select is(pg_temp.opos(2, pg_temp.a('A')) #> '{assignment,outcome}', 'null'::jsonb, 'with no outcome object');

-- Recording ----------------------------------------------------------------------------------------
create temp table ra as select pg_temp.jobcount() as before, pg_temp.record(2, pg_temp.a('A'), 'completed', 'SYNTHETIC 4.10 note A') as r;
select is(pg_temp.err((select r from ra)), 'ok', 'the leader records Completed with a short note');
select is((select r -> 'data' from ra),
  jsonb_build_object('assignment_id', pg_temp.a('A'), 'outcome', 'completed', 'outcome_revision', 1),
  'the answer holds ids, codes and revisions only (no note)');
select is((select result::text from app.cmd_receipts where command = 'duties.record_outcome' limit 1) ~ 'SYNTHETIC 4.10 note',
  false, 'the receipt holds no note');
select is(pg_temp.jobcount(), (select before from ra), 'recording an outcome sends no notification');
select is((select outcome || '|' || revision || '|' || note || '|' || (recorded_by_member = pg_temp.mid(2))
             from app.duties_outcomes where assignment_id = pg_temp.a('A')),
  'completed|1|SYNTHETIC 4.10 note A|true', 'revision 1 is attributed to the leader');
select is((select response || '|' || revision from app.duties_assignments where assignment_id = pg_temp.a('A')),
  'accepted|2', 'the response and the assignment revision are untouched (completion is separate)');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('A'), 'excused')), 'conflict|assignment_id=recorded',
  'a second record is refused (correct it instead)');
select is(pg_temp.err(pg_temp.record(3, pg_temp.a('C'), 'completed')), 'ok',
  'the deputy may record (an unanswered member who came anyway)');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('C'), 'no_show')), 'conflict|assignment_id=recorded',
  'recorded once only');
select is((select action || ':' || code || ':' || revision_after || ':' || actor_capacity from app.duties_audit
            where assignment_id = pg_temp.a('A') and action like 'outcome%'),
  'outcome_recorded:completed:1:department_leader', 'the audit holds the code and revision');

-- Declined and unanswered never become No-show; accepted (member or leader) may -------------------------
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('B'), 'no_show')), 'validation_failed|outcome=not_accepted',
  'a declined assignment cannot become a No-show');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('B'), 'excused')), 'ok', 'it may be Excused');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.a('B'), 'no_show', 'SYNTHETIC: wrong')),
  'validation_failed|outcome=not_accepted', 'nor corrected into a No-show');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('X'), 'no_show', 'SYNTHETIC 4.10 note X')), 'ok',
  'Confirmed by leader is an acceptance: No-show may be recorded');
select is(pg_temp.opos(2, pg_temp.a('B')) #> '{assignment,allowed}', '["completed", "excused"]'::jsonb,
  'the read says what a declined assignment may take');
select is(pg_temp.opos(2, pg_temp.a('X')) #> '{assignment,allowed}', '["completed", "excused", "no_show"]'::jsonb,
  'and an accepted one');

-- Cancelled, superseded, not started, draft-free, erased -----------------------------------------------
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('K'), 'completed')), 'conflict|assignment_id=cancelled',
  'a cancelled accepted duty has no outcome');
select is(pg_temp.opos(2, pg_temp.a('K')), null, 'and is not listed');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('S'), 'no_show')), 'conflict|assignment_id=superseded',
  'a superseded assignment has no outcome');
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('F'), 'completed')), 'validation_failed|assignment_id=not_started',
  'a duty that has not started has no outcome yet');
select is(pg_temp.err(pg_temp.record(2, pg_temp.cur('S'), 'completed', null, pg_temp.rev(pg_temp.cur('S')) + 5)),
  'conflict', 'a stale assignment revision is refused');

-- Who may record ------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.record(2, pg_temp.a('L'), 'completed')), 'validation_failed|assignment_id=own',
  'a leader cannot grade their own duty');
select is(pg_temp.err(pg_temp.record(1, pg_temp.cur('R'), 'completed')), 'forbidden', 'the Admin role alone cannot');
select is(pg_temp.err(pg_temp.record(9, pg_temp.cur('R'), 'completed')), 'not_found', 'another department''s leader cannot (nothing disclosed)');
select is(pg_temp.err(pg_temp.record(7, pg_temp.cur('R'), 'completed')) in ('forbidden', 'not_found'), true, 'Pastor cannot');
select is(pg_temp.err(pg_temp.record(4, pg_temp.cur('R'), 'completed')) in ('forbidden', 'not_found'), true, 'the member cannot grade themselves');
select is(pg_temp.err(pg_temp.record(10, pg_temp.cur('R'), 'completed')) in ('forbidden', 'not_found'), true, 'another member cannot');
select is(pg_temp.err(pg_temp.record(3, pg_temp.a('L'), 'completed')), 'ok', 'the deputy may record the leader''s duty');
select is(pg_temp.err(pg_temp.record(9, pg_temp.a('E'), 'excused', 'SYNTHETIC 4.10 note E')), 'ok',
  'department E''s leader records E''s duty');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_outcome', 1, '{"assignment_id": "x", "outcome": "late", "extra": 1}')),
  'validation_failed|assignment_id=invalid,extra=unknown_field,outcome=invalid', 'a malformed record is refused');
select is(pg_temp.err(pg_temp.record(2, pg_temp.cur('R'), 'completed', repeat('x', 201))),
  'validation_failed|note=invalid', 'the note is short (200 characters)');

-- Corrections are append-only and attributed ---------------------------------------------------------
select is(pg_temp.err(pg_temp.correct(3, pg_temp.a('A'), 'no_show', null, 'SYNTHETIC 4.10 note A2')),
  'validation_failed|reason=required', 'a correction needs a reason');
select is(pg_temp.err(pg_temp.correct(3, pg_temp.a('A'), 'completed', 'SYNTHETIC 4.10 reason', 'SYNTHETIC 4.10 note A')),
  'validation_failed|outcome=unchanged', 'a correction that changes nothing is refused');
create temp table ca as select pg_temp.correct(3, pg_temp.a('A'), 'no_show', 'SYNTHETIC 4.10 reason: checked the sign-in sheet',
                                               'SYNTHETIC 4.10 note A2') as r;
select is(pg_temp.err((select r from ca)), 'ok', 'the deputy corrects Completed to No-show with a reason');
select is((select r -> 'data' from ca), jsonb_build_object('assignment_id', pg_temp.a('A'), 'outcome', 'no_show',
                                                          'outcome_revision', 2, 'previous_outcome', 'completed'),
  'the answer names the new and the previous value (codes only)');
select is((select string_agg(revision || ':' || outcome || ':' || coalesce(note, '-') || ':'
                             || coalesce(correction_reason, '-') || ':'
                             || case recorded_by_member when pg_temp.mid(2) then 'L' when pg_temp.mid(3) then 'P' end,
                             ',' order by revision)
             from app.duties_outcomes where assignment_id = pg_temp.a('A')),
  '1:completed:SYNTHETIC 4.10 note A:-:L,2:no_show:SYNTHETIC 4.10 note A2:SYNTHETIC 4.10 reason: checked the sign-in sheet:P',
  'the prior value, note and actor are kept; the correction names its actor and reason');
select is((select supersedes_outcome_id = (select outcome_id from app.duties_outcomes where assignment_id = pg_temp.a('A') and revision = 1)
             from app.duties_outcomes where assignment_id = pg_temp.a('A') and revision = 2), true,
  'revision 2 names the revision it replaces');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.a('A'), 'excused', 'SYNTHETIC 4.10 again', null, 1)),
  'conflict', 'a correction at a stale outcome revision is refused');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.a('A'), 'excused', 'SYNTHETIC 4.10 reason 3')), 'ok',
  'a later correction (no time limit) by the leader');
select is(pg_temp.orev_of(pg_temp.a('A')), 3::bigint, 'every correction is a new revision');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.cur('R'), 'completed', 'SYNTHETIC 4.10 x', null, 1)),
  'validation_failed|assignment_id=unrecorded', 'nothing to correct before a record');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.a('L'), 'excused', 'SYNTHETIC 4.10 x')), 'validation_failed|assignment_id=own',
  'a leader cannot correct their own duty either');
select is(pg_temp.err(pg_temp.correct(1, pg_temp.a('A'), 'completed', 'SYNTHETIC 4.10 x')), 'forbidden',
  'nor can the Admin role alone');
select throws_ok(format('update app.duties_outcomes set outcome = %L where assignment_id = %L and revision = 1',
                        'excused', pg_temp.a('A')),
  'P0001', 'duties outcomes are append-only', 'a recorded value never changes');
select throws_ok(format('update app.duties_outcomes set note = %L where assignment_id = %L and revision = 1',
                        'edited', pg_temp.a('A')),
  'P0001', 'duties outcomes are append-only', 'nor its note');
select throws_ok(format('insert into app.duties_outcomes (assignment_id, revision, outcome, recorded_by_member, recorded_by_account) values (%L, 9, %L, %L, %L)',
                        pg_temp.a('A'), 'completed', pg_temp.mid(2), pg_temp.u(2)),
  '23514', null, 'a later revision must name the one it replaces');
select is(pg_temp.err(pg_temp.duties(6, 'duties.respond', pg_temp.rev(pg_temp.a('C')),
                                     jsonb_build_object('assignment_id', pg_temp.a('C'), 'response', 'accepted'))) <> 'ok',
  true, 'an outcome does not reopen the response (a started duty takes no answer)');

-- The outcomes read --------------------------------------------------------------------------------
select is(pg_temp.opos(2, pg_temp.a('A')) #>> '{assignment,outcome_state}', 'excused', 'the read shows the current value');
select is((select jsonb_agg(t -> 'outcome' order by (t ->> 'revision')::int desc)
             from jsonb_array_elements(pg_temp.opos(2, pg_temp.a('A')) #> '{assignment,outcome,trail}') t),
  '["excused", "no_show", "completed"]'::jsonb, 'with its trail, newest first');
select is(pg_temp.opos(2, pg_temp.a('A')) #>> '{assignment,outcome,trail,2,note}', 'SYNTHETIC 4.10 note A',
  'the first note is still there');
select is(pg_temp.opos(3, pg_temp.a('A')) #>> '{assignment,outcome,trail,1,reason}',
  'SYNTHETIC 4.10 reason: checked the sign-in sheet', 'the deputy sees the correction reason');
select is(pg_temp.opos(2, pg_temp.a('A')) #>> '{assignment,outcome,corrected}', 'true', 'and that it was corrected');
select is(pg_temp.opos(2, pg_temp.a('L')) #>> '{assignment,own}', 'true', 'the leader''s own duty is marked own');
select is(pg_temp.opos(2, pg_temp.a('X')) #>> '{assignment,response_provenance}', 'leader',
  'Confirmed by leader stays distinct from a member''s acceptance');
select is((select d -> 'counts' from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_outcomes()') -> 'departments') d),
  '{"positions": 7, "unfilled": 0, "unrecorded": 2, "completed": 2, "excused": 2, "no_show": 1}'::jsonb,
  'department totals (A, B, C, L, X, S and R; S and R unrecorded)');
select is((select jsonb_agg(d ->> 'name') from jsonb_array_elements(pg_temp.readj(9, 'select api.duties_outcomes()') -> 'departments') d),
  '["SYNTHETIC 4.10 Ushers"]'::jsonb, 'another department''s leader sees only their own department');
select is(pg_temp.read(9, format('select api.duties_outcomes(department_id => %L::uuid)', pg_temp.d())),
  'PT403|forbidden|not_granted', 'and is refused department D');
select is(pg_temp.read(1, 'select api.duties_outcomes()'), 'PT403|forbidden|not_granted', 'the Admin role alone is refused');
select is(pg_temp.read(7, 'select api.duties_outcomes()'), 'PT403|forbidden|not_granted', 'Pastor is refused');
select is(pg_temp.read(4, 'select api.duties_outcomes()'), 'PT403|forbidden|not_granted', 'a member is refused');
select is(pg_temp.read(2, format('select api.duties_outcomes(to_date => %L::date)', pg_temp.lusaka(1))),
  'PT400|validation_failed|window', 'the window never reaches past today');
select is(pg_temp.read(2, format('select api.duties_outcomes(from_date => %L::date, to_date => %L::date)',
                                 pg_temp.lusaka(-40), pg_temp.lusaka(-1))),
  'PT400|validation_failed|window', 'at most 31 days');
select is(pg_temp.read(2, format('select api.duties_outcomes(from_date => %L::date, to_date => %L::date)',
                                 date '2001-01-01', date '2001-01-31')),
  'ok', 'an old window may be read (no time limit)');
select is(jsonb_array_length(pg_temp.readj(2, 'select api.duties_outcomes(duty => ''Duty A'')') #> '{departments,0,positions}'),
  1, 'the duty filter narrows the list');

-- The member history -------------------------------------------------------------------------------
create temp table hm as select pg_temp.hist(4, 4) as j;
select is((select j ->> 'self' from hm), 'true', 'M reads their own history');
select is((select count(*)::int from hm, jsonb_array_elements(j -> 'entries') e), 6,
  'one row per position held: A, K, F, S, R (once) and E');
select is((select count(*)::int from hm, jsonb_array_elements(j -> 'entries') e
            where e ->> 'duty_name' = 'Duty R'), 1, 'the re-asked same person is one row (the latest revision)');
select is((select e ->> 'state' || '|' || (e ->> 'outcome_state') from hm, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = pg_temp.a('K')::text), 'cancelled|none', 'the cancelled duty: no outcome');
select is((select e ->> 'state' || '|' || (e ->> 'outcome_state') from hm, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = pg_temp.a('S')::text), 'reassigned|none', 'the reassigned duty: no outcome');
select is((select e ->> 'outcome_state' from hm, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = pg_temp.a('F')::text), 'upcoming', 'the future duty is upcoming');
select is((select e #>> '{outcome,trail,1,note}' from hm, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = pg_temp.a('A')::text), 'SYNTHETIC 4.10 note A2',
  'M sees the notes and corrections about their own duty');
select is((select (j -> 'summary') - 'since' from hm),
  '{"held": 3, "accepted": 3, "confirmed_by_leader": 0, "declined": 0, "unanswered": 0, "completed": 0, "excused": 2, "no_show": 0, "unrecorded": 1, "ended": 2}'::jsonb,
  'M''s own summary (A, R, E held; K, S ended)');
select is((select j -> 'upcoming' from hm), '1'::jsonb, 'and one upcoming duty');
select is((select count(*)::int from jsonb_array_elements(pg_temp.hist(2, 4) -> 'entries') e
            where e ->> 'department_name' = 'SYNTHETIC 4.10 Ushers'), 0,
  'M''s leader in D does not see M''s duty in E');
select is(pg_temp.hentry(2, 4, pg_temp.a('A')) #>> '{outcome,trail,0,reason}', 'SYNTHETIC 4.10 reason 3',
  'M''s leader sees D''s history with its text');
select is(pg_temp.hentry(3, 4, pg_temp.a('A')) #>> '{outcome,outcome}', 'excused', 'so does the deputy');
select is((select jsonb_agg(e ->> 'duty_name') from jsonb_array_elements(pg_temp.hist(9, 4) -> 'entries') e),
  '["Duty E"]'::jsonb, 'department E''s leader sees only E''s duty');
select is(pg_temp.read(9, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(5))),
  'PT403|forbidden|not_granted', 'a leader cannot read a member outside their departments');
select is(pg_temp.read(1, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(4))),
  'PT403|forbidden|not_granted', 'the Admin role alone cannot read a member''s history');
select is(pg_temp.read(7, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(4))),
  'PT403|forbidden|not_granted', 'Pastor cannot');
select is(pg_temp.read(5, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(4))),
  'PT403|forbidden|not_granted', 'another member cannot');
select is(pg_temp.read(2, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(10))),
  'PT403|forbidden|not_granted', 'a member never in the department: the same refusal');
select is(pg_temp.read(2, format('select api.duties_member_history(%L::uuid)', gen_random_uuid())),
  'PT403|forbidden|not_granted', 'an unknown member: the same refusal');
select is(pg_temp.read(4, format('select api.duties_member_history(before_at => %L::timestamptz)', now())),
  'PT400|validation_failed|cursor', 'a half cursor is refused');
select is(pg_temp.readj(1, 'select api.duties_member_history()') #>> '{summary,held}', '0',
  'anyone may read their own (empty) history');
select is(jsonb_array_length(pg_temp.readj(4, format('select api.duties_member_history(before_at => %L::timestamptz, before_id => %L::uuid)',
                                                    pg_temp.at(-1), pg_temp.a('A'))) -> 'entries'), 4,
  'the next page starts after the cursor');
select is((select count(*)::int from jsonb_array_elements(pg_temp.hist(2, 5) -> 'entries') e), 1,
  'the leader sees O''s declined duty');
select is(pg_temp.hentry(2, 5, pg_temp.a('B')) #>> '{response}', 'declined', 'with its response kept apart from the outcome');

-- My duties ----------------------------------------------------------------------------------------
select is((select a #>> '{outcome,outcome}' from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') a
            where a ->> 'assignment_id' = pg_temp.a('A')::text), 'excused', 'My duties shows M''s own outcome');
select is((select a -> 'outcome' from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') a
            where a ->> 'assignment_id' = pg_temp.cur('R')::text), 'null'::jsonb, 'and null while unrecorded');

-- Privacy: nobody else sees outcome text -----------------------------------------------------------------
select is(pg_temp.everything(n, pg_temp.mid(4)) ~ 'SYNTHETIC 4.10 (note A|reason)', false,
  'reader ' || n || ' sees no outcome note or correction reason about M in any Duties read')
  from unnest(array[1, 5, 6, 7, 9, 10]) n;
select is(pg_temp.everything(n, pg_temp.mid(4)) ~ '"outcome(_state)?"', false,
  'reader ' || n || ' sees no outcome at all')
  from unnest(array[1, 7, 10]) n;
select is(pg_temp.readj(2, 'select api.duties_leader_board()')::text ~ 'SYNTHETIC 4.10 (note|reason)', false,
  'the leader board carries no outcome text');
select is(pg_temp.readj(2, 'select api.duties_coverage()')::text ~ 'SYNTHETIC 4.10 (note|reason)', false,
  'nor does the coverage queue');
select is((select count(*)::int from app.duties_audit where code ~ ' '), 0, 'the audit holds codes only');
select is((select count(*)::int from app.cmd_receipts where result::text ~ 'SYNTHETIC 4.10 (note|reason)'), 0,
  'no receipt holds outcome text');

-- Erasure ------------------------------------------------------------------------------------------
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(3), 'account_id', pg_temp.u(3),
                                                      'phase', 'check')) ->> 'remaining')::int > 0, true,
  'the deputy''s recorded outcomes are counted for their own erasure');
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(4), 'account_id', pg_temp.u(4),
                                                      'phase', 'erase')) ->> 'remaining')::int, 0,
  'erasing M leaves no Duties personal data');
select is((select count(*)::int from app.duties_outcomes where assignment_id = pg_temp.a('A')
             and (note is not null or correction_reason is not null)), 0,
  'the notes and correction reasons about M are cleared');
select is((select string_agg(outcome, ',' order by revision) from app.duties_outcomes where assignment_id = pg_temp.a('A')),
  'completed,no_show,excused', 'the anonymised outcome values stay');
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(3), 'account_id', pg_temp.u(3),
                                                      'phase', 'erase')) ->> 'remaining')::int, 0,
  'erasing the deputy anonymises their recorded outcomes');
select is((select count(*)::int from app.duties_outcomes where recorded_by_member = pg_temp.mid(3)
             or recorded_by_account = pg_temp.u(3)), 0, 'no outcome names the erased deputy');
select is(pg_temp.err(pg_temp.correct(2, pg_temp.a('A'), 'completed', 'SYNTHETIC 4.10 x')),
  'validation_failed|member_id=erased', 'an erased assignee''s outcome is not corrected');

-- Privileges --------------------------------------------------------------------------------------
select ok(not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r,
                                    unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
                       where has_table_privilege(r, 'app.duties_outcomes', p)),
  'no client role has any privilege on the outcome log');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'app.duties_outcomes'::regclass),
  'RLS is on for the outcome log');
select ok(not has_function_privilege('anon', 'api.duties_outcomes(date, date, uuid, text)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.duties_member_history(uuid, timestamptz, uuid)', 'EXECUTE'),
  'anon cannot call the reads');
select ok(not has_function_privilege('authenticated', 'app.duties_record_outcome(uuid, bigint, jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.duties_outcome_json(uuid, integer)', 'EXECUTE')
          and not has_function_privilege('service_role', 'app.duties_correct_outcome(uuid, bigint, jsonb)', 'EXECUTE'),
  'the command bodies and helpers are not client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');

-- Q4 closed (production marker): nothing ---------------------------------------------------------------
select app.platform_set_environment('production', 'pgtap 4.10');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.10 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.10 production check', 'pgtap');
select is(pg_temp.read(2, 'select api.duties_outcomes()'), 'PT403|unavailable|unavailable',
  'with Q4 closed the outcomes read is unavailable');
select is(pg_temp.read(5, 'select api.duties_member_history()'), 'PT403|unavailable|unavailable',
  'and so is the history');
select is(pg_temp.err(pg_temp.record(2, pg_temp.cur('R'), 'completed')), 'unavailable|policy=gate_closed',
  'and so are the commands');

select * from finish();
rollback;
