-- Work the coverage queue with contact attempts and leader confirmation (story 4.9; AD-2, AD-5,
-- AD-7): the scoped queue (states, counts, filters, window), the full view for the department's
-- leaders and deputies (labelled 2.5 contact routes through the scoped Identity read, notes,
-- reasons) and the operational view for Admin and Pastor (nothing private), refusals for another
-- department's leader and a member; contact attempts opening and updating one Follow-ups task;
-- Confirmed by leader with actor, time, channel and reason, distinct from the member's acceptance;
-- reassigning a decline (old reminders and alerts cancelled, task closed); cancelling a position
-- (and the last position, one-off duties too); the leaders' decline alert (fresh keys after
-- A -> B -> A, held deputy skipped); Q2 closed (confirmation and attempt still recorded), Q4
-- closed (nothing); erasure; privileges. HTTP evidence: tools/identity-e2e/duties-coverage.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900780-900789).
begin;
select plan(157);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000050' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000050' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (780 + n)::text $$;
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
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.t(p_offset interval) returns timestamptz language sql as
$$ select date_trunc('minute', now()) + p_offset $$;
create function pg_temp.lusaka_date(p_offset interval) returns date language sql as
$$ select ((now() + p_offset) at time zone 'Africa/Lusaka')::date $$;

-- Accounts: 1 Admin (no department scope); 2 leader L of D; 3 deputy P of D; 4 member M; 5 member
-- O; 6 member Q; 7 Pastor; 8 accountless member X (no account); 9 leader K of department E;
-- 10 a member with no role.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n % 10), '+'), now()
  from generate_series(1, 10) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 10) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.9');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.9 Member ' || n, 'pgtap 4.9')
  from generate_series(1, 10) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.9 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.who(p uuid) returns text language sql as
$$ select coalesce((select m.n::text from m where m.member_id = p), '?') $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');
-- Labelled 2.5 contact routes (SYNTHETIC): X's household number, M's own number.
insert into app.identity_contact_routes (member_id, value, belongs_to, holder_label, is_synthetic,
                                         created_by_member, created_by_account)
values (pg_temp.mid(8), '+447700900788', 'household', 'SYNTHETIC sister', true, pg_temp.mid(1), pg_temp.u(1)),
       (pg_temp.mid(4), '+447700900784', 'member', null, true, pg_temp.mid(1), pg_temp.u(1));

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.9 Ushers"}') as r;
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
select pg_temp.add(n, pg_temp.d()) from unnest(array[2, 4, 5, 6, 8]) n;
select pg_temp.add(4, pg_temp.e());

-- One-off duties of D and the answers.
create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_member int, p_start timestamptz, p_extra jsonb default '{}')
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', pg_temp.d(), 'member_id', pg_temp.mid(p_member), 'duty_name', 'Duty ' || p_tag,
         'location', 'SYNTHETIC hall', 'starts_at', app.cmd_utc(p_start)) || p_extra);
  insert into pubs values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.a(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.row(p_id uuid) returns app.duties_assignments language sql as
$$ select a.* from app.duties_assignments a where a.assignment_id = p_id $$;
create function pg_temp.rev(p_id uuid) returns bigint language sql as
$$ select revision from app.duties_assignments where assignment_id = p_id $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.answer(n int, p_id uuid, p_response text) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.respond', pg_temp.rev(p_id),
                        jsonb_build_object('assignment_id', p_id, 'response', p_response))
$$;
create function pg_temp.attempt(n int, p_id uuid, p_outcome text, p_next interval,
                                p_note text default null, p_channel text default 'phone') returns jsonb
language sql as $$
  select pg_temp.duties(n, 'duties.record_contact_attempt', pg_temp.rev(p_id),
    jsonb_strip_nulls(jsonb_build_object('assignment_id', p_id, 'channel', p_channel, 'outcome', p_outcome,
                                         'note', p_note, 'next_follow_up_at', app.cmd_utc(pg_temp.t(p_next)))))
$$;
create function pg_temp.confirm(n int, p_id uuid, p_reason text, p_channel text default 'phone') returns jsonb
language sql as $$
  select pg_temp.duties(n, 'duties.confirm_by_leader', pg_temp.rev(p_id),
    jsonb_strip_nulls(jsonb_build_object('assignment_id', p_id, 'channel', p_channel, 'reason', p_reason)))
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- An assignment's pending jobs, "<m|l>:<kind>:<member n>".
create function pg_temp.jobs(p_id uuid, p_state text default 'pending') returns text language sql as $$
  select coalesce(string_agg(
           case j.source_type when 'duties_assignment' then 'm' else 'l' end || ':' || j.reminder_kind
           || ':' || pg_temp.who(j.recipient_member_id),
           ',' order by j.source_type, j.reminder_kind, pg_temp.who(j.recipient_member_id)), '-')
    from app.notifications_jobs j
   where j.source_id = p_id and j.job_state = p_state and j.snoozed_from_item_id is null
$$;
create function pg_temp.queue(n int, p_args text default '') returns jsonb language sql as $$
  select pg_temp.readj(n, format('select api.duties_coverage(%s)', p_args))
$$;
-- A position of the queue (by assignment or slot), as reader n sees it.
create function pg_temp.qpos(n int, p_id uuid) returns jsonb language sql as $$
  select p from jsonb_array_elements(pg_temp.queue(n) -> 'departments') dep,
                jsonb_array_elements(dep -> 'positions') p
   where p #>> '{assignment,assignment_id}' = p_id::text or p ->> 'slot_id' = p_id::text
$$;
create function pg_temp.qdep(n int, p_department uuid) returns jsonb language sql as $$
  select dep from jsonb_array_elements(pg_temp.queue(n) -> 'departments') dep
   where dep ->> 'department_id' = p_department::text
$$;
create function pg_temp.case_of(p_id uuid) returns app.duties_coverage_cases language sql as $$
  select c.* from app.duties_coverage_cases c where c.assignment_id = p_id order by c.opened_at desc limit 1
$$;
create function pg_temp.task(p_case uuid) returns app.followups_tasks language sql as $$
  select t.* from app.followups_tasks t
   where t.source_type = 'duties_coverage_case' and t.source_id = p_case and t.purpose = 'coverage_follow_up'
$$;

-- A one-date, three-position rota of D (Preacher planned for M, Reader and Usher left unfilled),
-- published.
create temp table sr as select pg_temp.duties(2, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'Sunday service', 'every', 'week',
  'from_date', to_char(pg_temp.lusaka_date('5 days'), 'YYYY-MM-DD'),
  'until_date', to_char(pg_temp.lusaka_date('5 days'), 'YYYY-MM-DD'),
  'start_time', '10:00', 'positions', jsonb_build_array('Preacher', 'Reader', 'Usher'))) as r;
create function pg_temp.series() returns uuid language sql as $$ select (r #>> '{data,series_id}')::uuid from sr $$;
create function pg_temp.socc() returns uuid language sql as
$$ select occurrence_id from app.duties_occurrences where series_id = pg_temp.series() $$;
create function pg_temp.slot(k int) returns uuid language sql as
$$ select slot_id from app.duties_slots where occurrence_id = pg_temp.socc() and position_no = k $$;
select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.socc()),
  jsonb_build_object('slot_id', pg_temp.slot(1), 'member_id', pg_temp.mid(4)));
select pg_temp.duties(2, 'duties.publish_drafts', (select revision from app.duties_series where series_id = pg_temp.series()),
  jsonb_build_object('series_id', pg_temp.series(), 'slot_count', 3));
create function pg_temp.sa(k int) returns uuid language sql as $$
  select assignment_id from app.duties_assignments where slot_id = pg_temp.slot(k) and assignment_state = 'current'
$$;

select pg_temp.pub('M', 4, pg_temp.t('3 days'));
select pg_temp.pub('X', 8, pg_temp.t('3 days 2 hours'));
select pg_temp.pub('O', 5, pg_temp.t('4 days'));
select pg_temp.pub('O2', 5, pg_temp.t('4 days 3 hours'));
select pg_temp.pub('FAR', 4, pg_temp.t('20 days'));
select pg_temp.run();

-- Structure and privileges ---------------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.duties_coverage_cases', 'app.duties_contact_attempts']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the coverage cases and contact attempts');
select ok((select bool_and(c.relrowsecurity) from pg_class c
            where c.oid in ('app.duties_coverage_cases'::regclass, 'app.duties_contact_attempts'::regclass)),
  'RLS is on for both');
select ok(not has_function_privilege('authenticated', 'app.identity_scoped_contact_routes(uuid, text, uuid, uuid[])', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.followups_source_review(jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.duties_record_contact_attempt(uuid, bigint, jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.duties_coverage(date, date, uuid, text)', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.duties_coverage(date, date, uuid, text)', 'EXECUTE'),
  'only the queue read is client-executable (authenticated); the Identity read, the Follow-ups seam and the commands are not');
select is((select title || ' / ' || body || ' / ' || link from app.contract_reminder_contracts
            where source_type = 'duties_coverage' and reminder_kind = 'duty_declined'),
  'Duty declined / A member cannot make a duty in your department. Open Coverage to find cover. / /duties/coverage',
  'the decline alert has fixed generic text and opens the coverage queue');
select is((select label || '|' || array_to_string(scope_kinds, ',') || '|' || on_source_resolved || '|'
                  || on_source_cancelled || '|' || manual_create::text
             from app.followups_purposes where source_type = 'duties_coverage_case'),
  'Duty cover follow-up|department_deputy,department_leader|close|close|false',
  'Duties registers the coverage follow-up purpose with Follow-ups (not hand-made)');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');

-- The queue: states, counts, routes (full view) -------------------------------------------------------
select is(pg_temp.qpos(2, pg_temp.a('M')) ->> 'status', 'awaiting', 'M''s unanswered duty is Awaiting response');
select ok((pg_temp.qpos(2, pg_temp.a('M')) #>> '{assignment,response_deadline}') is not null,
  'with its answer-by time');
select is(pg_temp.qpos(2, pg_temp.slot(2)) ->> 'status', 'unfilled', 'a position nobody holds is Unfilled');
select is((pg_temp.qpos(2, pg_temp.a('X')) #>> '{needs_contact,reasons}'), '["not_reached"]',
  'the accountless member needs contact (no reason given)');
select is(pg_temp.qpos(2, pg_temp.a('X')) #>> '{assignment,account}', 'no_login', 'and is marked no login');
select is(pg_temp.answer(5, pg_temp.a('O'), 'declined') #>> '{data,response}', 'declined', 'O declines duty O');
select is(pg_temp.qpos(2, pg_temp.a('O')) ->> 'status', 'declined', 'the decline is under Declined');
select is(pg_temp.qdep(2, pg_temp.d()) -> 'counts',
  '{"required": 7, "confirmed": 0, "unfilled": 2, "awaiting": 4, "overdue": 0, "declined": 1, "needs_contact": 1, "conflicts": 0, "overdue_follow_ups": 0}'::jsonb,
  'the department''s counts cover the next seven days (the duty 20 days ahead is outside the window)');
select is(pg_temp.qdep(2, pg_temp.d()) ->> 'view', 'full', 'the leader gets the full view');
select is(pg_temp.qdep(2, pg_temp.d()) #> array['contact_routes', pg_temp.mid(8)::text],
  '[{"phone": "+447700900788", "belongs_to": "household", "holder_label": "SYNTHETIC sister"}]'::jsonb,
  'with the accountless member''s labelled contact route (scoped Identity read)');
select is(pg_temp.qdep(3, pg_temp.d()) #>> array['contact_routes', pg_temp.mid(4)::text, '0', 'belongs_to'], 'member',
  'the deputy sees the member''s own route too');
select is(jsonb_array_length(pg_temp.qdep(2, pg_temp.d()) -> 'members'), 5, 'and the roster to reassign from');
select is(pg_temp.queue(2, 'from_date => ' || quote_literal(pg_temp.lusaka_date('19 days')) || '::date')
            #>> '{departments,0,counts,required}', '1', 'a later window finds the far duty');
select is(pg_temp.queue(2, 'duty => ''service''') #>> '{departments,0,counts,required}', '3',
  'the duty filter matches the duty name (case-insensitive)');
select is(pg_temp.read(2, 'select api.duties_coverage(to_date => (now()::date + 40))'), 'PT400|validation_failed|window',
  'a window over 31 days is refused');
select is(pg_temp.read(2, format('select api.duties_coverage(department_id => %L::uuid)', pg_temp.e())),
  'PT403|forbidden|not_granted', 'the leader cannot ask for another department');

-- Nothing private for Admin (role alone), Pastor, another department's leader, a member -----------------
select is(pg_temp.qdep(1, pg_temp.d()) ->> 'view', 'operational', 'Admin without the scope gets the operational view');
select is(pg_temp.qdep(1, pg_temp.d()) -> 'contact_routes', '{}'::jsonb, 'with no contact route');
select is((pg_temp.qdep(1, pg_temp.d()) ->> 'can_manage')::boolean, true, 'Admin may still reassign and cancel');
select is((pg_temp.qdep(1, pg_temp.d()) ->> 'can_contact')::boolean, false, 'but not record contact or confirmations');
select is(pg_temp.qdep(7, pg_temp.d()) ->> 'view', 'operational', 'Pastor sees the department''s gaps church-wide');
select is(pg_temp.qdep(7, pg_temp.d()) -> 'contact_routes', '{}'::jsonb, 'without contact routes');
select is(pg_temp.qdep(7, pg_temp.d()) -> 'members', '[]'::jsonb, 'without the roster (read only)');
select is((select string_agg(dep ->> 'name', ',' order by dep ->> 'name')
             from jsonb_array_elements(pg_temp.queue(7) -> 'departments') dep),
  'SYNTHETIC 4.9 Ushers,SYNTHETIC Preaching Rota', 'Pastor''s view covers every department');
select is((select string_agg(dep ->> 'name', ',') from jsonb_array_elements(pg_temp.queue(9) -> 'departments') dep),
  'SYNTHETIC 4.9 Ushers', 'another department''s leader sees only their own department');
select ok(pg_temp.queue(9)::text !~ 'SYNTHETIC sister|900788|Duty M', 'and nothing of D''s duties, members or routes');
select is(pg_temp.read(10, 'select api.duties_coverage()'), 'PT403|forbidden|not_granted', 'a member without a role is refused');
select is(pg_temp.read(4, 'select api.duties_coverage()'), 'PT403|forbidden|not_granted', 'so is an assignee');

-- The leaders' decline alert -------------------------------------------------------------------------
select is(pg_temp.jobs(pg_temp.a('O')), 'l:duty_declined:2,l:duty_declined:3',
  'the decline alerts the leader and the deputy (never the assignee)');
select pg_temp.run();
select is((select count(*)::int from app.notifications_inbox_items i
            where i.recipient_member_id in (pg_temp.mid(2), pg_temp.mid(3)) and i.reminder_kind = 'duty_declined'), 2,
  'both get one Duty declined item (the contract''s generic text)');
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(3),
            jsonb_build_object('member_id', pg_temp.mid(3), 'reason_code', 'security_concern')) ->> 'code',
  null, 'the Admin places a hold on the deputy');
select is(pg_temp.answer(5, pg_temp.a('O2'), 'declined') #>> '{data,response}', 'declined', 'O declines duty O2');
select is(pg_temp.jobs(pg_temp.a('O2')), 'l:duty_declined:2', 'a held deputy is not alerted (no unrouted need)');

-- Review S3: a reachable deputy (member 10; the first deputy is held) supervises the leader's tasks.
select is(pg_temp.grant_scope(10, 'department_deputy', pg_temp.d()) ->> 'code', null, 'member 10 becomes a deputy of D');

-- Contact attempts and the Follow-ups task ------------------------------------------------------------
create temp table at1 as select pg_temp.attempt(2, pg_temp.a('M'), 'no_answer', '1 day',
                                                'SYNTHETIC: rang twice, will try after work.') as r;
select is(pg_temp.err((select r from at1)), 'ok', 'the leader records a contact attempt');
select is((select r #>> '{data,followup}' from at1), 'opened', 'which opens the follow-up task');
select is((pg_temp.case_of(pg_temp.a('M'))).task_id::text, (select r #>> '{data,task_id}' from at1),
  'one coverage case per assignment holds its task');
select is((select t.owner_member_id = pg_temp.mid(2) and t.supervisor_member_id = pg_temp.mid(10)
                  and t.scope_kind = 'department_deputy' and t.scope_id = pg_temp.d() and t.task_state = 'open'
                  and t.due_at = pg_temp.t('1 day')
             from app.followups_tasks t where t.task_id = (select (r #>> '{data,task_id}')::uuid from at1)), true,
  'the task: owner the leader, supervised by the other reachable deputy (review S3), Open, due at the next follow-up');
select is((select (r #>> '{data,supervisor_fallback}')::boolean from at1), false, 'not a fallback');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'followups_supervision'
              and j.source_id = (select (r #>> '{data,task_id}')::uuid from at1)), 0,
  'review N1: no supervisor alert (it could come after the service)');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'followups_task' and j.job_state = 'pending'
              and j.source_id = (select (r #>> '{data,task_id}')::uuid from at1)
              and j.reminder_kind = 'followup_due' and j.scheduled_at = pg_temp.t('1 day')), 1,
  'and Follow-ups reminds its owner at the next follow-up');
select is(pg_temp.rev(pg_temp.a('M')), 1::bigint, 'an attempt does not change the assignment''s revision');
create temp table at2 as select pg_temp.attempt(2, pg_temp.a('M'), 'left_message', '2 days', null, 'message') as r;
select is((select r #>> '{data,followup}' from at2), 'updated', 'a second attempt updates the same task');
select is((select t.task_state || '|' || (t.review_at = pg_temp.t('2 days'))::text || '|' || t.latest_outcome
             from app.followups_tasks t where t.task_id = (select (r #>> '{data,task_id}')::uuid from at1)),
  'waiting|true|left_message', 'Waiting, reviewed at the new next follow-up, with the outcome');
select is((select string_agg(a.action || ':' || a.actor_capacity, ',' order by a.activity_id)
             from app.followups_activity a where a.task_id = (select (r #>> '{data,task_id}')::uuid from at1)),
  'created:source,outcome_recorded:source,status_changed:source', 'the task''s activity records each step (codes only)');
select is((select count(*)::int from app.duties_coverage_cases where assignment_id = pg_temp.a('M')), 1,
  'still one case');
select is(pg_temp.qpos(2, pg_temp.a('M')) #>> '{follow_up,attempts}', '2', 'the queue counts the attempts');
select is(pg_temp.qpos(2, pg_temp.a('M')) #>> '{follow_up,last_attempt,outcome}', 'left_message', 'shows the latest');
select is(pg_temp.qpos(2, pg_temp.a('M')) #>> '{follow_up,next_follow_up_at}', app.cmd_utc(pg_temp.t('2 days')),
  'and the next follow-up');
select is((select pg_temp.qpos(2, pg_temp.a('M')) -> 'follow_up' ->> 'task_id'), (select r #>> '{data,task_id}' from at1),
  'the leader sees the task link');
select is(pg_temp.qpos(1, pg_temp.a('M')) #>> '{follow_up,task_id}', null, 'Admin does not');
select is((select x #>> '{follow_up,last_attempt,note}' from (select pg_temp.qpos(2, pg_temp.a('X')) as x) y), null,
  'no attempt on X yet');
-- The first attempt's note is the leader's; others see none.
create temp table at3 as select pg_temp.attempt(2, pg_temp.a('X'), 'will_answer', '6 hours',
                                                'SYNTHETIC: sister passes the message on.') as r;
select is(pg_temp.qpos(2, pg_temp.a('X')) #>> '{follow_up,last_attempt,note}', 'SYNTHETIC: sister passes the message on.',
  'the leader sees the practical note');
select is(pg_temp.qpos(1, pg_temp.a('X')) #>> '{follow_up,last_attempt,note}', null, 'Admin does not');
select is(pg_temp.qpos(7, pg_temp.a('X')) #>> '{follow_up,last_attempt,note}', null, 'nor does Pastor');
select is(pg_temp.err(pg_temp.attempt(1, pg_temp.a('X'), 'no_answer', '6 hours')), 'forbidden',
  'Admin (role alone) cannot record a contact attempt');
select is(pg_temp.err(pg_temp.attempt(7, pg_temp.a('X'), 'no_answer', '6 hours')), 'not_found',
  'Pastor cannot (no disclosure)');
select is(pg_temp.err(pg_temp.attempt(9, pg_temp.a('X'), 'no_answer', '6 hours')), 'not_found',
  'nor can another department''s leader');
select is(pg_temp.err(pg_temp.attempt(4, pg_temp.a('M'), 'no_answer', '6 hours')), 'not_found', 'nor the assignee');
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('X'), 'no_answer', '-1 hour')), 'validation_failed|next_follow_up_at=past',
  'the next follow-up must be in the future');
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('X'), 'no_answer', '4 days')),
  'validation_failed|next_follow_up_at=after_start', 'and before the duty starts');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_contact_attempt', pg_temp.rev(pg_temp.a('X')),
            jsonb_build_object('assignment_id', pg_temp.a('X'), 'channel', 'sms', 'outcome', 'reached',
                               'next_follow_up_at', app.cmd_utc(pg_temp.t('1 hour'))))),
  'validation_failed|channel=invalid,outcome=invalid', 'channels and outcomes are fixed codes');
select is(pg_temp.err(pg_temp.duties(2, 'duties.record_contact_attempt', 7,
            jsonb_build_object('assignment_id', pg_temp.a('X'), 'channel', 'phone', 'outcome', 'no_answer',
                               'next_follow_up_at', app.cmd_utc(pg_temp.t('1 hour'))))),
  'conflict', 'a stale assignment revision is a conflict');

-- Review S3: a deputy records, a leader supervises; only one leader in a department: the fallback.
create temp table atd as select pg_temp.attempt(10, pg_temp.a('O'), 'no_answer', '1 day') as r;
select is((select t.owner_member_id = pg_temp.mid(10) and t.supervisor_member_id = pg_temp.mid(2)
                  and t.scope_kind = 'department_leader'
             from app.followups_tasks t where t.task_id = (select (r #>> '{data,task_id}')::uuid from atd)), true,
  'a deputy records: the leader supervises (a leader first)');
create temp table pe as select pg_temp.duties(9, 'duties.publish_duty', null, jsonb_build_object(
  'department_id', pg_temp.e(), 'member_id', pg_temp.mid(4), 'duty_name', 'Duty E',
  'starts_at', app.cmd_utc(pg_temp.t('5 days 6 hours')))) as r;
create temp table ate as select pg_temp.attempt(9, (select (r #>> '{data,assignment_id}')::uuid from pe),
                                                'no_answer', '1 day') as r;
select is((select (r #>> '{data,supervisor_fallback}')::boolean from ate), true,
  'the only leader of a department supervises their own task (recorded fallback)');
select is((select t.supervisor_member_id = pg_temp.mid(9)
             from app.followups_tasks t where t.task_id = (select (r #>> '{data,task_id}')::uuid from ate)), true,
  'and is the supervisor');

-- Review S2: never on the actor's own assignment.
select pg_temp.pub('OWN', 2, pg_temp.t('5 days 2 hours'));
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('OWN'), 'no_answer', '1 day')), 'validation_failed|assignment_id=own',
  'a leader cannot record contact with themselves');
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('OWN'), 'SYNTHETIC')), 'validation_failed|assignment_id=own',
  'nor confirm themselves');

-- Review N2: a task closed by hand: the next attempt opens a fresh case and task.
select pg_temp.pub('N2', 5, pg_temp.t('5 days 4 hours'));
create temp table n2a as select pg_temp.attempt(2, pg_temp.a('N2'), 'no_answer', '1 day') as r;
select is(pg_temp.call(2, 'followups_command', 'followups.update_task',
            (select revision from app.followups_tasks where task_id = (select (r #>> '{data,task_id}')::uuid from n2a)),
            jsonb_build_object('task_id', (select r #>> '{data,task_id}' from n2a), 'status', 'closed',
                               'close_reason', 'SYNTHETIC: handled elsewhere')) ->> 'code', null,
  'the owner closes the task by hand');
create temp table n2b as select pg_temp.attempt(2, pg_temp.a('N2'), 'left_message', '1 day') as r;
select is((select r #>> '{data,followup}' || '|' || (r #>> '{data,replaced_case}') from n2b), 'opened|true',
  'the next attempt opens a fresh case and task');
select is((select count(*)::int from app.duties_coverage_cases where assignment_id = pg_temp.a('N2')
             and close_code = 'replaced'), 1, 'the old case is closed as replaced');

-- Review N3: the task owner lost the scope: the next attempt (by the leader) takes it over.
select pg_temp.pub('N3', 5, pg_temp.t('5 days 8 hours'));
create temp table n3a as select pg_temp.attempt(10, pg_temp.a('N3'), 'no_answer', '1 day') as r;
select is(pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope',
            (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(10)),
            jsonb_build_object('member_id', pg_temp.mid(10), 'scope_kind', 'department_deputy',
                               'scope_id', pg_temp.d())) ->> 'code', null, 'the second deputy''s scope is revoked');
create temp table n3b as select pg_temp.attempt(2, pg_temp.a('N3'), 'no_answer', '1 day') as r;
select is((select (r #>> '{data,replaced_case}') from n3b)
          || '|' || (pg_temp.task((select (r #>> '{data,case_id}')::uuid from n3a))).close_code
          || '|' || ((pg_temp.task((select (r #>> '{data,case_id}')::uuid from n3b))).owner_member_id = pg_temp.mid(2))::text,
  'true|source_resolved|true', 'the old task closes and the leader owns the fresh one');

-- Review N9: an assignee who left the department is reassigned, not contacted.
select pg_temp.pub('N9', 6, pg_temp.t('5 days 10 hours'));
update app.duties_department_members set ended_at = now()
 where department_id = pg_temp.d() and member_id = pg_temp.mid(6) and ended_at is null;
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('N9'), 'no_answer', '1 day')),
  'validation_failed|member_id=required_reassign', 'an attempt on a departed assignee is refused');
update app.duties_department_members set ended_at = null
 where department_id = pg_temp.d() and member_id = pg_temp.mid(6)
   and membership_id = (select membership_id from app.duties_department_members
                         where department_id = pg_temp.d() and member_id = pg_temp.mid(6)
                         order by started_at desc limit 1);

-- Review B1: the Confirmed by leader reason is for the department's leaders and deputies only.
create temp table b1 as select pg_temp.confirm(2, pg_temp.a('N3'), 'SYNTHETIC: board reason check.') as r;
create function pg_temp.board_conf(n int, p_id uuid) returns jsonb language sql as $$
  select p #> '{assignment,confirmation}'
    from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_leader_board()') -> 'departments') dep,
         jsonb_array_elements(dep -> 'duties') du, jsonb_array_elements(du -> 'positions') p
   where p #>> '{assignment,assignment_id}' = p_id::text
$$;
select is(pg_temp.board_conf(2, pg_temp.a('N3')) ->> 'reason', 'SYNTHETIC: board reason check.',
  'the leader''s board shows the reason');
select is(pg_temp.board_conf(1, pg_temp.a('N3')) ->> 'reason', null, 'the Admin''s board does not (review B1)');
select is(pg_temp.board_conf(1, pg_temp.a('N3')) ->> 'channel', 'phone', 'only the fact and the channel');
select is(pg_temp.board_conf(7, pg_temp.a('N3')) ->> 'reason', null, 'nor Pastor''s');
select is(pg_temp.qpos(1, pg_temp.a('N3')) #>> '{assignment,confirmation,reason}', null, 'nor the Admin''s queue');
select ok(pg_temp.readj(1, 'select api.duties_rota()')::text !~ 'board reason check'
          and pg_temp.readj(2, 'select api.duties_rota()')::text !~ 'board reason check',
  'the rota never carries the reason');

-- The member's own acceptance closes the case and its task --------------------------------------------
select is(pg_temp.answer(4, pg_temp.a('M'), 'accepted') #>> '{data,response}', 'accepted', 'M accepts');
select is((pg_temp.case_of(pg_temp.a('M'))).close_code, 'accepted', 'the coverage case closes');
select is((select t.task_state || '|' || t.close_code from app.followups_tasks t
            where t.task_id = (select (r #>> '{data,task_id}')::uuid from at1)), 'closed|source_resolved',
  'and its Follow-ups task closes with the assignment (source resolved)');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_id = (select (r #>> '{data,task_id}')::uuid from at1) and j.job_state = 'pending'), 0,
  'the task''s reminders are cancelled');
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('M'), 'no_answer', '6 hours')),
  'validation_failed|assignment_id=confirmed', 'no attempt on a confirmed position');

-- Confirmed by leader (the accountless member, by phone) ---------------------------------------------
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('X'), null)), 'validation_failed|reason=required',
  'Confirmed by leader needs a reason');
select is(pg_temp.err(pg_temp.confirm(1, pg_temp.a('X'), 'SYNTHETIC reason')), 'forbidden', 'Admin alone cannot confirm');
create temp table cx as select pg_temp.confirm(2, pg_temp.a('X'), 'SYNTHETIC: confirmed by phone with her sister.') as r;
select is((select r #>> '{data,provenance}' from cx), 'leader', 'the leader confirms X by phone');
select is((select (a.response, a.response_provenance, a.confirmed_channel, a.confirmed_reason,
                   a.responded_by_member = pg_temp.mid(2), a.responded_at is not null)::text
             from app.duties_assignments a where a.assignment_id = pg_temp.a('X')),
  '(accepted,leader,phone,"SYNTHETIC: confirmed by phone with her sister.",t,t)',
  'accepted with provenance leader: the leader, the time, the channel and the reason');
select is((select r #>> '{data,followup}' from at3) || '|' || (pg_temp.case_of(pg_temp.a('X'))).close_code || '|'
          || (pg_temp.task((pg_temp.case_of(pg_temp.a('X'))).case_id)).close_code, 'opened|confirmed|source_resolved',
  'the case and its task close as confirmed');
select is(pg_temp.jobs(pg_temp.a('X')), 'm:duty_starting:8',
  'the answer reminders and leader alerts stop; the pre-service reminder is planned');
select is(pg_temp.qpos(2, pg_temp.a('X')) ->> 'status', 'confirmed', 'the queue counts it confirmed');
select is(pg_temp.qpos(2, pg_temp.a('X')) #>> '{assignment,confirmation,reason}', 'SYNTHETIC: confirmed by phone with her sister.',
  'labelled Confirmed by leader with its reason for the leader');
select is(pg_temp.qpos(2, pg_temp.a('X')) #>> '{assignment,confirmation,by}', 'SYNTHETIC 4.9 Member 2', 'and who recorded it');
select is(pg_temp.qpos(7, pg_temp.a('X')) #>> '{assignment,confirmation,reason}', null, 'Pastor sees no reason');
select is(pg_temp.qpos(7, pg_temp.a('X')) #>> '{assignment,confirmation,channel}', 'phone', 'only the fact and the channel');
select is((select count(*)::int from app.duties_audit where action = 'leader_confirmed' and code = 'phone'
             and actor_capacity = 'department_leader' and assignment_id = pg_temp.a('X')), 1,
  'audited with ids and codes only');
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('X'), 'again')), 'conflict|assignment_id=responded', 'only once');
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('O'), 'SYNTHETIC: changed mind')), 'conflict|assignment_id=declined',
  'a decline is replaced, not overwritten');
-- A member's view of a leader confirmation (app member Q).
select pg_temp.pub('Q', 6, pg_temp.t('2 days'));
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('Q'), 'SYNTHETIC: said yes after the service.', 'in_person')), 'ok',
  'the leader confirms Q in person');
select is((select x ->> 'response_provenance' || '|' || (x ->> 'confirmed_channel') || '|' || (x ? 'confirmed_reason')::text
             from jsonb_array_elements(pg_temp.readj(6, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = pg_temp.a('Q')::text), 'leader|in_person|false',
  'Q sees Confirmed by your leader (never the leader''s reason)');
select is(pg_temp.err(pg_temp.duties(6, 'duties.withdraw_acceptance', pg_temp.rev(pg_temp.a('Q')),
            jsonb_build_object('assignment_id', pg_temp.a('Q')))), 'conflict|assignment_id=responded',
  'a leader confirmation cannot be withdrawn by the member (4.5 rule)');
select is((pg_temp.qpos(2, pg_temp.a('Q')) -> 'assignment') ->> 'response_provenance', 'leader',
  'kept distinct from the member''s own acceptance');

-- Reassign the decline: old assignee's reminders cancelled, task closed --------------------------------
create function pg_temp.o2slot() returns uuid language sql as
$$ select slot_id from app.duties_assignments where assignment_id = pg_temp.a('O2') $$;
create temp table ao as select pg_temp.attempt(2, pg_temp.a('O2'), 'cannot_serve', '1 day') as r;
select is((select r #>> '{data,followup}' from ao), 'opened', 'the leader records that O cannot serve (task opened)');
create temp table ro as select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('O2')),
  jsonb_build_object('slot_id', pg_temp.o2slot(), 'member_id', pg_temp.mid(6))) as r;
select is(pg_temp.err((select r from ro)), 'ok', 'the leader reassigns the declined position to Q');
select is((pg_temp.row(pg_temp.a('O2'))).assignment_state, 'superseded', 'the old assignment is superseded');
select is(pg_temp.jobs(pg_temp.a('O2')), 'm:duty_released:5',
  'only the released notice is left for the old assignee');
select ok(pg_temp.jobs(pg_temp.a('O2'), 'cancelled') like '%l:duty_declined:2%',
  'its leaders'' decline alert was cancelled with it');
select is((pg_temp.case_of(pg_temp.a('O2'))).close_code || '|'
          || (pg_temp.task((pg_temp.case_of(pg_temp.a('O2'))).case_id)).close_code,
  'superseded|source_resolved', 'the case closes as superseded and its task closes (source resolved)');
select is(pg_temp.jobs((select (r #>> '{data,assignment_id}')::uuid from ro)),
  'm:duty_assigned:6,m:duty_response_due:6,m:duty_response_due:6,m:duty_response_due:6,l:duty_response_overdue:2',
  'the new assignee gets fresh reminders (the held deputy no alert)');
-- A -> B -> A: O again, then a second decline gets a fresh key.
create temp table back as select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.occ('O2')),
  jsonb_build_object('slot_id', pg_temp.o2slot(), 'member_id', pg_temp.mid(5))) as r;
select is(pg_temp.answer(5, (select (r #>> '{data,assignment_id}')::uuid from back), 'declined') #>> '{data,response}',
  'declined', 'O, given the position back, declines again');
select is(pg_temp.jobs((select (r #>> '{data,assignment_id}')::uuid from back)), 'l:duty_declined:2',
  'a fresh decline alert (a new assignment is a new key)');

-- Cancel a position ------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.duties(7, 'duties.cancel_position', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(3)))), 'forbidden', 'Pastor cannot cancel a position');
select is(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(3))) #>> '{data,cancelled}', 'position',
  'the leader cancels the Usher position');
select is(pg_temp.qpos(2, pg_temp.slot(3)), null, 'it leaves the queue');
select is((select x #>> '{counts,required}' from (select pg_temp.queue(2, 'duty => ''service''') #> '{departments,0}' as x) y),
  '2', 'and no longer counts as required');
select is((select (p ->> 'cancelled')::boolean
             from jsonb_array_elements(app.duties_occurrence_json(pg_temp.socc(), true, '{}') -> 'positions') p
            where p ->> 'slot_id' = pg_temp.slot(3)::text), true, 'the board shows it cancelled');
select is((app.duties_rota_occurrence_json(pg_temp.socc(), '{}') ->> 'required')::int, 2, 'the rota requires two');
select is(pg_temp.err(pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(3), 'member_id', pg_temp.mid(5)))),
  'validation_failed|slot_id=cancelled', 'a cancelled position is never given again');
select is(pg_temp.err(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(3)))), 'validation_failed|slot_id=cancelled', 'nor cancelled twice');
create temp table cp1 as select pg_temp.sa(1) as id;
select is(pg_temp.duties(1, 'duties.cancel_position', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(1))) #>> '{data,cancelled}', 'position',
  'an Admin cancels the Preacher position (M had been asked)');
select is(pg_temp.jobs((select id from cp1)), 'm:duty_cancelled:4', 'M gets only the cancellation notice');
select is(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.socc()),
            jsonb_build_object('slot_id', pg_temp.slot(2))) #>> '{data,cancelled}', 'occurrence',
  'cancelling the last position cancels the date');
select is((select occurrence_state from app.duties_occurrences where occurrence_id = pg_temp.socc()), 'cancelled',
  'the occurrence is cancelled');
select is((select count(*)::int from app.duties_slot_revisions where slot_id = pg_temp.slot(3)
             and change_class = 'cancelled'), 1,
  'review N4: a position cancelled before keeps its single cancelled revision');
-- A one-off duty with an open case: cancelling its position cancels the duty, the case and the task.
create temp table af as select pg_temp.attempt(2, pg_temp.a('FAR'), 'no_answer', '2 days') as r;
select is(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.occ('FAR')),
            jsonb_build_object('slot_id', (select slot_id from app.duties_assignments where assignment_id = pg_temp.a('FAR'))))
          #>> '{data,cancelled}', 'occurrence', 'a one-off duty is cancelled through its position (4.3 could not)');
select is((pg_temp.case_of(pg_temp.a('FAR'))).close_code || '|'
          || (pg_temp.task((pg_temp.case_of(pg_temp.a('FAR'))).case_id)).close_code,
  'cancelled|source_cancelled', 'its case and task close as cancelled');
select is(pg_temp.jobs(pg_temp.a('FAR')), 'm:duty_cancelled:4', 'and only the cancellation notice is left');

-- Q2 closed: a confirmation and an attempt are still recorded ------------------------------------------
select pg_temp.pub('Z1', 5, pg_temp.t('6 days'));
select pg_temp.pub('Z2', 6, pg_temp.t('6 days 2 hours'));
create temp table az as select pg_temp.attempt(2, pg_temp.a('Z1'), 'no_answer', '1 day') as r;
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Mars/Base"}' where gate = 'q2_church_time';
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('Z1'), 'SYNTHETIC: confirmed at the door.')), 'ok',
  'with Q2 invalid the leader can still confirm');
select is((pg_temp.case_of(pg_temp.a('Z1'))).close_code || '|'
          || (pg_temp.task((pg_temp.case_of(pg_temp.a('Z1'))).case_id)).close_code || '|'
          || (select count(*) from app.notifications_jobs j where j.job_state = 'pending'
               and j.source_id = (pg_temp.task((pg_temp.case_of(pg_temp.a('Z1'))).case_id)).task_id)::text,
  'confirmed|source_resolved|0', 'review S1: the case and its task close, the task''s reminders cancelled');
select is((select string_agg(action || ':' || code, ',' order by action) from app.duties_audit
            where assignment_id = pg_temp.a('Z1') and code = 'policy_unavailable'),
  'reminders_skipped:policy_unavailable', 'only the reminder re-plan is skipped (and audited)');
select is((app.duties_coverage_case_source_check(jsonb_build_object(
            'source_id', (pg_temp.case_of(pg_temp.a('Z1'))).case_id, 'source_revision', 1)) ->> 'current')::boolean,
  false, 'the closed case is no longer a current Follow-ups source');
select is(pg_temp.attempt(2, pg_temp.a('Z2'), 'no_answer', '1 day') #>> '{data,followup}', 'skipped',
  'an attempt is recorded too; its task is skipped');
select is((select count(*)::int from app.duties_contact_attempts where assignment_id = pg_temp.a('Z2')), 1,
  'the attempt itself is kept');
select is(pg_temp.answer(6, pg_temp.a('Z2'), 'declined') #>> '{data,response}', 'declined',
  'a decline is recorded too (the alert is skipped)');
-- Review S1: accept and cancel_position close the task with Q2 invalid too.
select is(pg_temp.answer(5, pg_temp.a('N2'), 'accepted') #>> '{data,response}', 'accepted', 'O accepts N2 (Q2 invalid)');
select is((pg_temp.task((select (r #>> '{data,case_id}')::uuid from n2b))).close_code || '|'
          || (select count(*) from app.notifications_jobs j where j.job_state = 'pending'
               and j.source_id = (select (r #>> '{data,task_id}')::uuid from n2b))::text,
  'source_resolved|0', 'its task closes, reminders cancelled');
select is(pg_temp.duties(2, 'duties.cancel_position', pg_temp.orev(pg_temp.occ('O')),
            jsonb_build_object('slot_id', (select slot_id from app.duties_assignments where assignment_id = pg_temp.a('O'))))
          #>> '{data,cancelled}', 'occurrence', 'the leader cancels O''s declined duty (Q2 invalid)');
select is((pg_temp.task((select (r #>> '{data,case_id}')::uuid from atd))).close_code || '|'
          || (select count(*) from app.notifications_jobs j where j.job_state = 'pending'
               and j.source_id = (select (r #>> '{data,task_id}')::uuid from atd))::text,
  'source_cancelled|0', 'its task closes as cancelled, reminders cancelled');
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Africa/Lusaka"}' where gate = 'q2_church_time';

-- Review N1: a case whose duty has started closes (with its task) at the next coverage command.
select pg_temp.pub('L1', 5, pg_temp.t('7 days'));
create temp table l1 as select pg_temp.attempt(2, pg_temp.a('L1'), 'no_answer', '1 day') as r;
update app.duties_occurrences set starts_at = now() - interval '1 minute' where occurrence_id = pg_temp.occ('L1');
select pg_temp.pub('L2', 5, pg_temp.t('7 days 3 hours'));
select is(pg_temp.err(pg_temp.attempt(2, pg_temp.a('L2'), 'no_answer', '1 day')), 'ok', 'another attempt in D');
select is((pg_temp.case_of(pg_temp.a('L1'))).close_code || '|'
          || (pg_temp.task((select (r #>> '{data,case_id}')::uuid from l1))).close_code,
  'started|source_resolved', 'the started duty''s case and task are closed');

-- History guard, attempts guard, erasure --------------------------------------------------------------
select throws_ok(format('update app.duties_assignments set confirmed_channel = %L where assignment_id = %L',
                        'message', pg_temp.a('O2')),
  'P0001', 'ended duties assignments are immutable', 'an ended assignment''s confirmation facts cannot change');
select throws_ok(format('update app.duties_contact_attempts set outcome = %L where assignment_id = %L', 'other', pg_temp.a('X')),
  'P0001', 'duties contact attempts are immutable', 'contact attempts are immutable');
select throws_ok(format('update app.duties_assignments set response_provenance = %L where assignment_id = %L',
                        'leader', pg_temp.a('Z2')),
  '23514', null, 'leader provenance needs an accepted answer with its channel');
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(8), 'phase', 'erase')) ->> 'remaining')::int,
  0, 'erasing X leaves no Duties personal data');
select is((select count(*)::int from app.duties_contact_attempts where assignment_id = pg_temp.a('X') and note is not null)
          + (select count(*)::int from app.duties_assignments where assignment_id = pg_temp.a('X') and confirmed_reason is not null),
  0, 'the practical notes and the confirmation reason about X are cleared');
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(2), 'account_id', pg_temp.u(2),
                                                      'phase', 'check')) ->> 'remaining')::int > 0, true,
  'the leader''s attempts and confirmations are counted for their own erasure');

-- Review N1: the source-specific schedule (owner at the due or review time only).
select is((select on_assignment || ':' || owner_reminders::text || ':' || supervisor_reminders::text
             from app.followups_reminder_schedules where purpose = 'coverage_follow_up'),
  'false:[{"anchor": "deadline", "before": "0 minutes"}]:[]',
  'the coverage task reminds its owner at the due time only: no supervisor alert, no assignment notice');

-- Q4 closed (production marker): nothing --------------------------------------------------------------
select app.platform_set_environment('production', 'pgtap 4.9');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.9 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.9 production check', 'pgtap');
select is(pg_temp.read(2, 'select api.duties_coverage()'), 'PT403|unavailable|unavailable',
  'with Q4 closed the queue is unavailable');
select is(pg_temp.err(pg_temp.confirm(2, pg_temp.a('Z2'), 'x')), 'unavailable|policy=gate_closed', 'and so are the commands');
select is(app.identity_scoped_contact_routes(pg_temp.mid(2), 'department_leader', pg_temp.d(), array[pg_temp.mid(4)]),
  '{}'::jsonb, 'and the scoped Identity read returns nothing');

select * from finish();
rollback;
