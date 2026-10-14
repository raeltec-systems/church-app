-- Revise assignments on material change and refuse stale responses (story 4.2; AD-2, AD-6, AD-8,
-- AC-10): immutable slot revisions, the assignment lifecycle (current, superseded, cancelled),
-- duties.revise_duty (material versus notes-only), kept answers with actor, time and provenance,
-- cancelled jobs and generic change notices, stale-response refusal with what changed, replay,
-- scope loss, gates and the deletion hook. HTTP evidence (including a real two-leader race):
-- tools/identity-e2e/duties-revisions.mjs. Every account, phone and name is SYNTHETIC (fictional
-- range +44 7700 900970-900979).
begin;
select plan(93);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000042' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000042' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (970 + n)::text $$;
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
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.at(p_offset interval) returns text language sql as
$$ select app.cmd_utc(date_trunc('second', now()) + p_offset) $$;
create function pg_temp.jobs(p_source uuid) returns text language sql as $$
  select string_agg(reminder_kind || ':' || job_state || ':' || coalesce(cancel_reason, finish_reason, '-'),
                    ',' order by enqueued_at, reminder_kind, job_state)
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = p_source
$$;

-- Accounts: 1 Admin; 2 leader of D; 3 deputy of D; 4 member M (assignee); 5 member O (another
-- member of D); 6 leader of the other department E; 7 Pastor; 9 a member with no role.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.2');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.2 Member ' || n, 'pgtap 4.2')
  from generate_series(1, 9) n where n <> 8;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.2 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.e() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from de $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_department uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_department))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(4, pg_temp.d());
select pg_temp.add(5, pg_temp.d());
select pg_temp.add(9, pg_temp.e());

create function pg_temp.duty(p_department uuid, n int, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('department_id', p_department, 'duty_name', 'Sunday preaching',
           'starts_at', pg_temp.at(interval '10 days'), 'ends_at', pg_temp.at(interval '10 days 2 hours'),
           'location', 'SYNTHETIC Main hall', 'instructions', 'Arrive early.',
           'member_id', pg_temp.mid(n), 'response_deadline', pg_temp.at(interval '7 days')) || p_extra
$$;
create temp table pub as select pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4)) as r;
create function pg_temp.occ() returns uuid language sql as $$ select (r #>> '{data,occurrence_id}')::uuid from pub $$;
create function pg_temp.asg1() returns uuid language sql as $$ select (r #>> '{data,assignment_id}')::uuid from pub $$;
create function pg_temp.orev() returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = pg_temp.occ() $$;
create function pg_temp.revise(n int, p_payload jsonb, p_expected bigint default null,
                               p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.revise_duty', coalesce(p_expected, pg_temp.orev()),
                        jsonb_build_object('occurrence_id', pg_temp.occ()) || p_payload, p_request)
$$;
select pg_temp.run();
create temp table item1 as
  select (pg_temp.readj(4, 'select api.notifications_my_inbox()') #>> '{items,0,item_id}')::uuid as id;
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg1(),
  'response', 'accepted', 'note', 'SYNTHETIC note one.'));

-- Structure ---------------------------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.duties_slot_revisions', p)),
  'no client role has any privilege on the slot revisions');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'app.duties_slot_revisions'::regclass),
  'RLS is on for the slot revisions');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname in ('app', 'api') and p.proname ~ '^duties_'
     and not (p.proname in ('duties_command', 'duties_my_duties', 'duties_leader_board',
                            'duties_admin_overview', 'duties_rota') and r = 'authenticated')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'still only the command and the reads (with the 4.3 rota) are client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select string_agg(f || '=' || coalesce(app.duties_slot_field_class(f), 'none'), ',' order by f)
             from unnest(array['duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id',
                               'instructions', 'response_deadline', 'department_id']) f),
  'department_id=none,duty_name=material,ends_at=material,instructions=notes,location=material,'
  'member_id=material,reporting_at=material,response_deadline=assignment,starts_at=material',
  'every revisable field is classified explicitly (spec list material; instructions notes)');
select is((select string_agg(c.reminder_kind || '|' || c.title || '|' || c.link, ',' order by c.reminder_kind)
             from app.contract_reminder_contracts c
            where c.source_type = 'duties_assignment' and c.reminder_kind in ('duty_changed', 'duty_updated', 'duty_released')),
  'duty_changed|Duty changed|/duties/assignments/{source_id},'
  'duty_released|Duty changed|/duties,'
  'duty_updated|Duty details updated|/duties/assignments/{source_id}',
  'the generic change, update and released notices are registered');
select is((select change_class || '|' || slot_revision || '|' || (member_id = pg_temp.mid(4))::text
                  || '|' || (assignment_id = pg_temp.asg1())::text
             from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ()),
  'published|1|true|true', 'publishing records slot revision 1');

-- Refusals ------------------------------------------------------------------------------------------
select is(pg_temp.revise(9, jsonb_build_object('starts_at', pg_temp.at(interval '11 days'),
            'response_deadline', pg_temp.at(interval '8 days'))) ->> 'code',
  'forbidden', 'a member without a department scope cannot revise');
select is(pg_temp.revise(6, '{"instructions": "x"}') ->> 'code', 'forbidden',
  'another department''s leader cannot revise');
select is(pg_temp.revise(7, '{"instructions": "x"}') ->> 'code', 'forbidden', 'the Pastor cannot revise');
select is(pg_temp.revise(2, '{"instructions": "x"}', 7) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 1}'::jsonb,
  'a stale occurrence revision is a conflict with the current revision');
select is(pg_temp.duties(2, 'duties.revise_duty', null, jsonb_build_object('occurrence_id', pg_temp.occ(),
            'instructions', 'x')) -> 'field_errors',
  '{"expected_revision": "required"}'::jsonb, 'revising needs the occurrence revision');
select is(pg_temp.revise(2, '{"location": "SYNTHETIC Main hall", "instructions": "Arrive early.", "extra": 1}')
            -> 'field_errors', '{"extra": "unknown_field"}'::jsonb, 'unknown fields are refused');
select is(pg_temp.revise(2, '{"location": " SYNTHETIC  Main hall "}') -> 'field_errors',
  '{"occurrence_id": "unchanged"}'::jsonb, 'a value equal to the current one is no change');
select is(pg_temp.revise(2, jsonb_build_object('instructions', 'Bring a Bible.',
            'response_deadline', pg_temp.at(interval '8 days'))) -> 'field_errors',
  '{"response_deadline": "not_material"}'::jsonb, 'a notes-only change takes no new deadline');
select is(pg_temp.revise(2, jsonb_build_object('starts_at', pg_temp.at(interval '11 days'),
            'ends_at', pg_temp.at(interval '11 days 2 hours'))) -> 'field_errors',
  '{"response_deadline": "required"}'::jsonb, 'a material change needs a new response deadline');
select is(pg_temp.revise(2, jsonb_build_object('starts_at', pg_temp.at(interval '11 days'),
            'response_deadline', pg_temp.at(interval '12 days'))) -> 'field_errors',
  '{"ends_at": "before_start", "response_deadline": "after_start"}'::jsonb,
  'the merged times are checked (the old end is now before the new start; deadline after start)');
select is(pg_temp.revise(2, jsonb_build_object('starts_at', null, 'duty_name', '', 'member_id', 'x')) -> 'field_errors',
  '{"starts_at": "required", "duty_name": "required", "member_id": "invalid"}'::jsonb,
  'required fields cannot be cleared');
select is(pg_temp.revise(2, jsonb_build_object('member_id', pg_temp.mid(9),
            'response_deadline', pg_temp.at(interval '8 days'))) -> 'field_errors',
  '{"member_id": "not_in_department"}'::jsonb, 'a new assignee must be a member of the department');
select is((select count(*)::int from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ()) + pg_temp.orev()::int, 2, 'refused revisions wrote nothing');

-- Material change, same assignee ------------------------------------------------------------------
-- A pending future job on the accepted assignment stands in for its later reminders (entry 8).
select app.notifications_enqueue(jsonb_build_object('source_type', 'duties_assignment',
  'source_id', pg_temp.asg1(), 'source_revision', 2, 'recipient_member_id', pg_temp.mid(4),
  'reminder_kind', 'duty_updated', 'scheduled_at', pg_temp.at(interval '1 day')));
create temp table rev_req as select gen_random_uuid() as id;
create temp table rev as select pg_temp.revise(2, jsonb_build_object(
  'starts_at', pg_temp.at(interval '11 days'), 'ends_at', pg_temp.at(interval '11 days 2 hours'),
  'response_deadline', pg_temp.at(interval '8 days')), null, (select id from rev_req)) as r;
create function pg_temp.asg2() returns uuid language sql as $$ select (r #>> '{data,assignment_id}')::uuid from rev $$;
select is((select (r -> 'data') - 'occurrence_id' - 'slot_id' - 'assignment_id' from rev),
  jsonb_build_object('revision', 2, 'change', 'material', 'slot_revision', 2, 'assignment_revision', 1,
                     'superseded_assignment_id', pg_temp.asg1(), 'response', 'pending', 'notice_queued', true),
  'a time change is material: a new pending assignment revision; the answer holds ids and states only');
select isnt(pg_temp.asg2(), pg_temp.asg1(), 'the new revision is a new assignment for the same member');
select is((select assignment_state || '|' || end_reason || '|' || response || '|' || response_provenance
                  || '|' || (responded_by_member = pg_temp.mid(4))::text || '|' || (responded_by_account = pg_temp.u(4))::text
                  || '|' || (responded_at is not null)::text || '|' || (ended_at is not null)::text || '|' || response_note
             from app.duties_assignments where assignment_id = pg_temp.asg1()),
  'superseded|revised|accepted|member|true|true|true|true|SYNTHETIC note one.',
  'the old acceptance is kept with its actor, account, time, provenance and note');
select is((select assignment_state || '|' || response || '|' || slot_revision || '|' || (member_id = pg_temp.mid(4))::text
                  || '|' || (supersedes_assignment_id = pg_temp.asg1())::text
                  || '|' || (response_deadline = date_trunc('second', now()) + interval '8 days')::text
             from app.duties_assignments where assignment_id = pg_temp.asg2()),
  'current|pending|2|true|true|true', 'the new assignment is pending with the recalculated deadline');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ() and a.assignment_state = 'current'), 1,
  'the slot still has exactly one current assignment');
select is((select change_class || '|' || array_to_string(changed_fields, ',') || '|' || (assignment_id = pg_temp.asg2())::text
             from app.duties_slot_revisions r join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ() and r.slot_revision = 2),
  'material|starts_at,ends_at|true', 'slot revision 2 records the material change and the new assignment');
select is(pg_temp.jobs(pg_temp.asg1()), 'duty_assigned:delivered:delivered,duty_updated:cancelled:source_revised',
  'the old revision''s pending reminder is cancelled (source_revised); the delivered item stays');
select is(pg_temp.jobs(pg_temp.asg2()), 'duty_changed:pending:-', 'one generic change notice is queued');
select is(pg_temp.revise(2, jsonb_build_object('starts_at', pg_temp.at(interval '11 days'),
            'ends_at', pg_temp.at(interval '11 days 2 hours'), 'response_deadline', pg_temp.at(interval '8 days')),
            1, (select id from rev_req)),
  (select r from rev), 'a replay returns the original result');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ()) || '|' || pg_temp.orev(), '2|2', 'and changes nothing');
select is(pg_temp.readj(4, format('select api.notifications_open_item(%L::uuid)', (select id from item1))) ->> 'state',
  'superseded', 'the old new-duty item opens as out of date');
select is(pg_temp.run() ->> 'delivered', '1', 'the worker delivers the change notice');
create temp table item2 as select (x ->> 'item_id')::uuid as id
  from jsonb_array_elements(pg_temp.readj(4, 'select api.notifications_my_inbox()') -> 'items') x
 where x ->> 'reminder_kind' = 'duty_changed';
select is((select (o ->> 'title') || '|' || (o ->> 'target') from (select pg_temp.readj(4,
            format('select api.notifications_open_item(%L::uuid)', (select id from item2))) o) x),
  'Duty changed|/duties/assignments/' || pg_temp.asg2(), 'it is generic and opens the new revision');

-- Stale responses -----------------------------------------------------------------------------------
select is(pg_temp.duties(4, 'duties.respond', 3, jsonb_build_object('assignment_id', pg_temp.asg1(),
            'response', 'accepted')) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {"assignment_id": "superseded", "starts_at": "changed", "ends_at": "changed"}}'::jsonb,
  'a late accept of the old revision is refused with what changed');
select is(pg_temp.duties(4, 'duties.respond', 2, jsonb_build_object('assignment_id', pg_temp.asg1(),
            'response', 'declined')) #>> '{field_errors,assignment_id}',
  'superseded', 'whatever revision the client still holds');
select is(pg_temp.duties(5, 'duties.respond', 3, jsonb_build_object('assignment_id', pg_temp.asg1(),
            'response', 'accepted')) ->> 'code', 'not_found', 'another member learns nothing about it');
select is((select response || '|' || revision from app.duties_assignments where assignment_id = pg_temp.asg1()),
  'accepted|3', 'the refused answers changed nothing');

-- Reads ----------------------------------------------------------------------------------------------
create temp table mine as select pg_temp.readj(4, 'select api.duties_my_duties()') as j;
select is((select jsonb_array_length(j -> 'assignments') from mine), 1, 'My duties lists the current revision only');
select is((select (j -> 'assignments' -> 0) - 'occurrence_id' - 'department_id' - 'starts_at' - 'ends_at'
                  - 'response_deadline' - 'duty_name' - 'department_name' - 'location' - 'instructions'
                  - 'reporting_at' - 'responded_at' - 'note'
                  -- Story 4.3 keys are checked in duties_rota_test.sql.
                  - 'position_name' - 'topic' - 'scripture' from mine),
  jsonb_build_object('assignment_id', pg_temp.asg2(), 'revision', 1, 'response', 'pending', 'slot_revision', 2,
                     'changes', jsonb_build_array('starts_at', 'ends_at'), 'previous_response', 'accepted',
                     'previous_assignment_ids', jsonb_build_array(pg_temp.asg1()), 'notes_updated_at', null),
  'with what changed, the earlier answer and the earlier assignment id (old links find it)');
create temp table board as select jsonb_path_query_first(pg_temp.readj(2, 'select api.duties_leader_board()'),
  '$.departments[0].duties[0].positions[0]') as p;
select is((select (p ->> 'slot_revision') || '|' || (p #>> '{assignment,response}') || '|'
                  || (p #>> '{assignment,changes}') || '|' || jsonb_array_length(p -> 'history') from board),
  '2|pending|["starts_at", "ends_at"]|1', 'the leader sees the new pending revision and one history entry');
select is((select (p -> 'history' -> 0) - 'ended_at' - 'responded_at' - 'display_name' from board),
  jsonb_build_object('assignment_id', pg_temp.asg1(), 'member_id', pg_temp.mid(4), 'state', 'superseded',
                     'end_reason', 'revised', 'response', 'accepted', 'response_provenance', 'member',
                     'note', 'SYNTHETIC note one.', 'slot_revision', 1),
  'the history keeps the old acceptance with its provenance and note');
select is((select coalesce(x #>> '{duties,0,positions,0,history,0,note}', 'none') || '|'
                  || (x #>> '{duties,0,positions,0,history,0,response}')
             from jsonb_array_elements(pg_temp.readj(7, 'select api.duties_leader_board()') -> 'departments') x
            where x ->> 'name' = 'SYNTHETIC Preaching Rota'),
  'none|accepted', 'the Pastor sees the history without the note');

-- Notes-only change keeps the answer -----------------------------------------------------------------
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg2(), 'response', 'accepted'));
create temp table notes as select pg_temp.revise(3, '{"instructions": "Bring a Bible."}') as r;
select is((select (r -> 'data') - 'occurrence_id' - 'slot_id' from notes),
  jsonb_build_object('revision', 3, 'change', 'notes', 'slot_revision', 3, 'assignment_id', pg_temp.asg2(),
                     'assignment_revision', 2, 'superseded_assignment_id', null, 'response', 'accepted',
                     'notice_queued', true),
  'the deputy''s instructions edit is notes-only: same assignment, still Accepted');
select is((select response || '|' || revision || '|' || assignment_state from app.duties_assignments
            where assignment_id = pg_temp.asg2()), 'accepted|2|current', 'the acceptance is untouched');
select is((select change_class || '|' || array_to_string(changed_fields, ',') from app.duties_slot_revisions r
             join app.duties_slots s using (slot_id) where s.occurrence_id = pg_temp.occ() and r.slot_revision = 3),
  'notes|instructions', 'slot revision 3 records the notes-only change');
select is(pg_temp.jobs(pg_temp.asg2()), 'duty_changed:delivered:delivered,duty_updated:pending:-',
  'one generic update notice is queued');
select pg_temp.revise(2, '{"instructions": "Bring a Bible and a pen."}');
select is(pg_temp.jobs(pg_temp.asg2()),
  'duty_changed:delivered:delivered,duty_updated:cancelled:replaced,duty_updated:pending:-',
  'a second edit replaces the unsent update notice');
select is((select x ->> 'instructions' || '|' || (x ->> 'response') || '|' || (x ->> 'notes_updated_at' is not null)::text
             from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x),
  'Bring a Bible and a pen.|accepted|true', 'My duties shows the new instructions, still Accepted, marked updated');
-- The replacing job is stamped with the clock time, after this test transaction's now().
update app.notifications_jobs set scheduled_at = now()
 where source_id = pg_temp.asg2() and reminder_kind = 'duty_updated' and job_state = 'pending';
select is(pg_temp.run() ->> 'delivered', '1', 'the worker delivers one update');
select is((select string_agg(x ->> 'title', ',' order by x ->> 'title')
             from jsonb_array_elements(pg_temp.readj(4, 'select api.notifications_my_inbox()') -> 'items') x),
  'Duty changed,Duty details updated,New duty assigned', 'the inbox holds only generic text');

-- Concurrent edits: one success and one conflict ------------------------------------------------------
create temp table race as select pg_temp.orev() as expected;
create temp table race1 as select pg_temp.revise(2, '{"location": "SYNTHETIC Side hall"}', (select expected from race)) as r;
select is((select r ->> 'code' from race1), 'validation_failed', 'a location change is material and needs a deadline');
create temp table race2 as select pg_temp.revise(2, jsonb_build_object('location', 'SYNTHETIC Side hall',
  'response_deadline', pg_temp.at(interval '9 days')), (select expected from race)) as r;
create temp table race3 as select pg_temp.revise(1, '{"instructions": "Admin text."}', (select expected from race)) as r;
select is((select (race2.r #>> '{data,change}') || '|' || (race3.r ->> 'code') || '|' || (race3.r ->> 'current_revision')
             from race2, race3),
  'material|conflict|' || ((select expected from race) + 1),
  'two managers editing the same revision: one success, one conflict with the current revision');

-- Reassignment (material: the assignee) ------------------------------------------------------------
create function pg_temp.cur() returns uuid language sql as $$
  select a.assignment_id from app.duties_assignments a join app.duties_slots s using (slot_id)
   where s.occurrence_id = pg_temp.occ() and a.assignment_state = 'current' $$;
create temp table m_last as select pg_temp.cur() as id;
select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.cur(), 'response', 'accepted'));
create temp table re as select pg_temp.revise(2, jsonb_build_object('member_id', pg_temp.mid(5),
  'response_deadline', pg_temp.at(interval '8 days'))) as r;
select is((select (r #>> '{data,change}') || '|' || (r #>> '{data,response}') || '|'
                  || (a.member_id = pg_temp.mid(5))::text
             from re join app.duties_assignments a on a.assignment_id = (r #>> '{data,assignment_id}')::uuid),
  'material|pending|true', 'giving the duty to O creates O''s pending assignment');
select is(pg_temp.jobs((select (r #>> '{data,assignment_id}')::uuid from re)), 'duty_assigned:pending:-',
  'O gets the new-duty notice');
select is(pg_temp.jobs((select id from m_last)), 'duty_changed:cancelled:responded,duty_released:pending:-',
  'M gets a generic released notice');
select is((select response || '|' || assignment_state from app.duties_assignments where assignment_id = (select id from m_last)),
  'accepted|superseded', 'M''s acceptance is kept in history');
select is(jsonb_array_length(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments'), 0,
  'the duty leaves M''s list');
select is(pg_temp.duties(4, 'duties.respond', 3, jsonb_build_object('assignment_id', (select id from m_last),
            'response', 'declined')) -> 'field_errors',
  '{"assignment_id": "superseded", "member_id": "changed"}'::jsonb,
  'M''s late answer is refused: the assignee changed (no id or name of the new assignee)');
select is(pg_temp.run() ->> 'delivered', '2', 'the worker delivers O''s new duty and M''s released notice');
create temp table item3 as select (x ->> 'item_id')::uuid as id
  from jsonb_array_elements(pg_temp.readj(4, 'select api.notifications_my_inbox()') -> 'items') x
 where x ->> 'reminder_kind' = 'duty_released';
select is((select (o ->> 'title') || '|' || (o ->> 'target') from (select pg_temp.readj(4,
            format('select api.notifications_open_item(%L::uuid)', (select id from item3))) o) x),
  'Duty changed|/duties', 'the released notice is generic and opens My duties');
select is((select jsonb_array_length(x #> '{duties,0,positions,0,history}')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') x),
  3, 'the leader sees every earlier revision in the history');

-- Back to M (A -> B -> A): the duty is M's again.
create temp table back as select pg_temp.revise(2, jsonb_build_object('member_id', pg_temp.mid(4),
  'response_deadline', pg_temp.at(interval '8 days'))) as r;
select is(pg_temp.jobs((select (r #>> '{data,assignment_id}')::uuid from back)), 'duty_assigned:pending:-',
  'giving it back to M is a new duty for M');
select is(pg_temp.duties(4, 'duties.respond', 3, jsonb_build_object('assignment_id', (select id from m_last),
            'response', 'accepted')) -> 'field_errors',
  '{"assignment_id": "superseded"}'::jsonb,
  'a late answer to M''s old version no longer says the assignee changed (it is M''s again)');
select ok((select (x -> 'previous_assignment_ids') @> jsonb_build_array((select id from m_last), pg_temp.asg1())
             from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'duty_name' = 'Sunday preaching'),
  'M''s old links (before O) find the current version through the position''s chain');
select ok(not (select (x -> 'previous_assignment_ids') @> jsonb_build_array((r #>> '{data,assignment_id}'))
                 from re, jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
                where x ->> 'duty_name' = 'Sunday preaching'),
  'but never O''s assignment id');

-- Cancelled assignments are refused too (the cancelling command arrives with 4.3).
create temp table pub2 as select pg_temp.duties(2, 'duties.publish_duty', null,
  pg_temp.duty(pg_temp.d(), 4, '{"duty_name": "Reading"}')) as r;
update app.duties_assignments set assignment_state = 'cancelled', ended_at = now(), end_reason = 'cancelled'
 where assignment_id = (select (r #>> '{data,assignment_id}')::uuid from pub2);
select is(pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object(
            'assignment_id', (select r #>> '{data,assignment_id}' from pub2), 'response', 'accepted')) -> 'field_errors',
  '{"assignment_id": "cancelled"}'::jsonb, 'an answer to a cancelled assignment is refused');
select throws_ok($$update app.duties_assignments set assignment_state = 'current', ended_at = null,
                      end_reason = null where assignment_state = 'superseded'$$,
  'P0001', 'ended duties assignments are immutable', 'an ended assignment cannot be reopened');
select throws_ok($$update app.duties_assignments set response = 'declined' where assignment_state = 'superseded'$$,
  'P0001', 'ended duties assignments are immutable', 'nor its kept answer changed');
select throws_ok($$update app.duties_assignments set ended_at = now() where assignment_state = 'current'$$,
  '23514', null, 'the lifecycle check keeps ended_at consistent with the state');

-- Immutable slot revisions ---------------------------------------------------------------------------
select throws_ok(format($$update app.duties_slot_revisions set location = 'SYNTHETIC elsewhere'
                          where occurrence_id = %L$$, pg_temp.occ()),
  'P0001', 'duties slot revisions are immutable', 'a slot revision cannot be edited');
select throws_ok(format($$update app.duties_slot_revisions set member_id = %L where occurrence_id = %L$$,
                        pg_temp.mid(5), pg_temp.occ()),
  'P0001', 'duties slot revisions are immutable', 'nor its assignee moved to someone else');

-- A started duty cannot be revised ------------------------------------------------------------------
create temp table pub3 as select pg_temp.duties(2, 'duties.publish_duty', null,
  pg_temp.duty(pg_temp.d(), 5, '{"duty_name": "Welcome"}')) as r;
update app.duties_occurrences set starts_at = now() - interval '1 minute', ends_at = null
 where occurrence_id = (select (r #>> '{data,occurrence_id}')::uuid from pub3);
select is(pg_temp.duties(2, 'duties.revise_duty', 1, jsonb_build_object(
            'occurrence_id', (select r #>> '{data,occurrence_id}' from pub3), 'instructions', 'x')) -> 'field_errors',
  '{"occurrence_id": "started"}'::jsonb, 'a duty that has started cannot be revised');

-- Receipts hold no names or notes ---------------------------------------------------------------------
select is((select count(*)::int from app.cmd_receipts c where c.command = 'duties.revise_duty'
            and (c.result::text like '%SYNTHETIC 4.2 Member%' or c.result::text like '%Bible%'
                 or c.result::text like '%SYNTHETIC note%' or c.result::text like '%Side hall%')), 0,
  'revise receipts hold ids, revisions and states only');
select is((select string_agg(distinct code, ',' order by code) from app.duties_audit where action = 'duty_revised'),
  'material,notes', 'revisions are audited with their class only');

-- Untrusted session, scope loss and replay ----------------------------------------------------------
insert into auth.sessions (id, user_id, aal, created_at)
values (pg_temp.s(21), pg_temp.u(2), 'aal1', clock_timestamp() - interval '1 hour');
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), pg_temp.s(21), now(), now(), 'otp');
select is(pg_temp.cmd(jsonb_build_object('sub', pg_temp.u(2), 'role', 'authenticated', 'aal', 'aal1',
            'session_id', pg_temp.s(21), 'is_anonymous', false,
            'amr', jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', 1790000000))),
            'api.duties_command', 'duties.revise_duty', pg_temp.orev(),
            jsonb_build_object('occurrence_id', pg_temp.occ(), 'instructions', 'x')) ->> 'code',
  'unauthenticated', 'a leader''s untrusted session is unauthenticated');
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d()));
select is(pg_temp.revise(2, jsonb_build_object('starts_at', pg_temp.at(interval '11 days'),
            'ends_at', pg_temp.at(interval '11 days 2 hours'), 'response_deadline', pg_temp.at(interval '8 days')),
            1, (select id from rev_req)) ->> 'code',
  'forbidden', 'after the leader''s scope is revoked even a replay of their revision is refused');
select is(pg_temp.revise(2, '{"instructions": "x"}') ->> 'code', 'forbidden', 'and so is a new revision');
select is(pg_temp.revise(3, '{"instructions": "Deputy text."}') #>> '{data,change}', 'notes',
  'the deputy still manages the department');
select is(pg_temp.jobs((select (r #>> '{data,assignment_id}')::uuid from back)),
  'duty_assigned:cancelled:replaced,duty_assigned:pending:-',
  'a notes-only edit replaces the unsent new-duty notice with one of the same kind (one notice)');

-- Deletion --------------------------------------------------------------------------------------------
select is((select (r ->> 'remaining')::int > 0 from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'check')) r
            where r ->> 'module' = 'duties'), true, 'the check counts M''s slot revisions and history');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'erasing M leaves nothing of M in Duties');
select is((select count(*)::int from app.duties_slot_revisions
            where member_id = '00000000-0000-0000-0000-000000000000' and occurrence_id = pg_temp.occ()), 7,
  'M''s slot revisions keep the facts with the nil UUID');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s using (slot_id)
            where s.occurrence_id = pg_temp.occ() and a.member_id = '00000000-0000-0000-0000-000000000000'
              and a.response_note is null and a.response = 'accepted'), 3,
  'M''s superseded acceptances stay as anonymous facts without the note');
select is((select count(*)::int from jsonb_array_elements(jsonb_path_query_first(
             pg_temp.readj(3, 'select api.duties_leader_board()'), '$.departments[0].duties[*] ? (@.duty_name == "Sunday preaching").positions[0].history')) h
            where h ->> 'display_name' is null), 3, 'the leader''s history shows them without a name');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(2), pg_temp.u(2), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'a leader''s revision traces are anonymised too');

-- Revising after the current assignee was erased (M holds the position as the nil UUID).
create temp table after_erase as select pg_temp.revise(3, '{"instructions": "After erase."}') as r;
select is((select (r #>> '{data,change}') || '|' || (r #>> '{data,notice_queued}') from after_erase),
  'notes|false', 'an instructions edit still saves and sends no notice to an erased member');
select is(pg_temp.revise(3, jsonb_build_object('location', 'SYNTHETIC Side hall 2',
            'response_deadline', pg_temp.at(interval '8 days'))) -> 'field_errors',
  '{"member_id": "required_reassign"}'::jsonb,
  'a material change that keeps an erased assignee needs a new assignee');
select is(pg_temp.revise(3, jsonb_build_object('location', 'SYNTHETIC Side hall 2', 'member_id', pg_temp.mid(9),
            'response_deadline', pg_temp.at(interval '8 days'))) -> 'field_errors',
  '{"member_id": "not_in_department"}'::jsonb, 'and the new assignee must serve in the department');

-- Gates: production without Q4 closes revisions; with Q4 synthetic departments are hidden ------------
select app.platform_set_environment('production', 'pgtap 4.2');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.2 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.2 production check', 'pgtap');
select is(pg_temp.revise(3, '{"instructions": "Closed."}') ->> 'code', 'unavailable',
  'with Q4 closed (production) revisions are unavailable');
select is(pg_temp.duties(5, 'duties.respond', 1, jsonb_build_object(
            'assignment_id', (select r #>> '{data,assignment_id}' from re), 'response', 'accepted')) ->> 'code',
  'unavailable', 'and so are answers');
select app.policy_approve('q4_personal_data', '{}'::jsonb, 'pgtap', 'pgtap 4.2 production check');
select is(jsonb_array_length(pg_temp.readj(3, 'select api.duties_leader_board()') -> 'departments'), 0,
  'in production the synthetic department and its history are hidden');

select * from finish();
rollback;
