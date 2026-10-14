-- Publish a one-position department duty and accept it (story 4.1; AD-1, AD-2, AD-4, AD-6,
-- AD-8, AD-14): Admin department setup, Duties-registered leader/deputy scopes, department
-- members (with or without a login), publishing with a leader-entered deadline, the
-- duties_assignment reminder source reaching the inbox, the assignee's accept/decline, scope
-- refusals, replay and the deletion hook. HTTP evidence: tools/identity-e2e/duties.mjs. Every
-- account, phone and name here is SYNTHETIC (fictional range +44 7700 900950-900959).
begin;
select plan(94);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000041' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000041' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (950 + n)::text $$;
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

-- Accounts: 1 Admin; 2 leader of D; 3 deputy of D; 4 member M (assignee); 5 member O (another
-- member of D); 6 leader of the other department E; 7 Pastor; 8 (no account) accountless member;
-- 9 a member with no role at all.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.1');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.1 Member ' || n, 'pgtap 4.1')
  from generate_series(1, 9) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.1 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

-- Structure, privileges and guards -------------------------------------------------------------
select ok((select count(*) from information_schema.tables where table_schema = 'app'
            and table_name in ('duties_departments', 'duties_department_members', 'duties_occurrences',
                               'duties_slots', 'duties_assignments', 'duties_audit')) = 6,
  'department, membership, occurrence, slot, assignment and audit tables exist');
select ok(not exists (
  select 1 from unnest(array['app.duties_departments', 'app.duties_department_members',
                             'app.duties_occurrences', 'app.duties_slots', 'app.duties_assignments',
                             'app.duties_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the Duties tables (a direct table query is refused)');
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relname ~ '^duties_' and c.relkind = 'r'),
  'RLS is on for every Duties table');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'duties_audit'),
  array['action', 'actor_account_id', 'actor_capacity', 'actor_member_id', 'assignment_id', 'code',
        'command_request_id', 'department_id', 'environment', 'event_id', 'member_id',
        'occurred_at', 'occurrence_id', 'revision_after', 'series_id'],
  'the audit holds ids, codes and revisions only (no names, notes or free text)');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname in ('app', 'api') and p.proname ~ '^duties_'
     and not (p.proname in ('duties_command', 'duties_my_duties', 'duties_leader_board',
                            'duties_admin_overview', 'duties_rota', 'duties_candidates')
                  and r = 'authenticated')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'only the command and the reads (with the 4.3 rota and the 4.4 candidates) are client-executable, and only by authenticated');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select array_agg(k.scope_kind || ':' || k.module order by k.scope_kind)
             from app.identity_scope_kinds k where k.module = 'duties'),
  array['department_deputy:duties', 'department_leader:duties'],
  'Duties registers the department leader and deputy scope kinds in the Identity grant model');
select is((select a.handler from app.cmd_authorizers a where a.namespace = 'duties'),
  'app.duties_authorize_command(jsonb)', 'the duties authorizer is registered for duties.*');
select is((select handler from app.identity_deletion_hooks where module = 'duties'),
  'app.duties_erase_member(jsonb)', 'Duties registered its deletion hook');
select is((select c.title || '|' || c.link from app.contract_reminder_contracts c
            where c.source_type = 'duties_assignment' and c.reminder_kind = 'duty_assigned'),
  'New duty assigned|/duties/assignments/{source_id}', 'the duty_assigned reminder contract is registered');

-- Admin department setup --------------------------------------------------------------------------
select is(pg_temp.duties(9, 'duties.create_department', null, '{"name": "SYNTHETIC Preaching Rota"}') ->> 'code',
  'forbidden', 'a member without Admin cannot create a department');
select is(pg_temp.duties(1, 'duties.create_department', null, '{"name": "Preaching", "x": 1}') -> 'field_errors',
  '{"name": "invalid", "x": "unknown_field"}'::jsonb,
  'every field error at once; while Q4 is unapproved department names are SYNTHETIC');
create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "  SYNTHETIC   Preaching Rota "}') as r;
create temp table de as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC 4.1 Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.e() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from de $$;
select is((select d.name || '|' || (r ->> 'revision') || '|' || d.is_synthetic::text
             from dd join app.duties_departments d on d.department_id = pg_temp.d()),
  'SYNTHETIC Preaching Rota|1|true', 'an Admin creates SYNTHETIC Preaching Rota (whitespace collapsed)');
select is((select (r -> 'data') - 'department_id' from dd), '{"revision": 1}'::jsonb,
  'the command answer holds ids and the revision only (no names in the receipt)');
select is(pg_temp.duties(1, 'duties.create_department', null, '{"name": "synthetic preaching rota"}') -> 'field_errors',
  '{"name": "invalid"}'::jsonb, 'a lower-case name is not SYNTHETIC-prefixed');
select is(pg_temp.duties(1, 'duties.create_department', null, '{"name": "SYNTHETIC PREACHING ROTA"}') ->> 'code',
  'conflict', 'department names are unique');

create function pg_temp.grant_scope(p_member int, p_kind text, p_department uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_department))
$$;
select is(pg_temp.grant_scope(2, 'department_leader', '00000000-0000-4000-8000-00000000dead') -> 'field_errors',
  '{"scope_id": "unknown"}'::jsonb, 'a leader scope needs an existing department (Duties target hook)');
select is(pg_temp.grant_scope(2, 'department_leader', pg_temp.d()) #>> '{data,scopes,0,scope_kind}',
  'department_leader', 'an Admin makes member 2 the leader of D with identity.grant_scope');
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());

create function pg_temp.add(n int, p_department uuid, p_by int default 1) returns jsonb language sql as $$
  select pg_temp.duties(p_by, 'duties.add_member',
    (select revision from app.duties_departments where department_id = p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select is(pg_temp.add(4, pg_temp.d(), 2) ->> 'code', 'forbidden', 'a leader cannot add members in 4.1 (Admin only)');
select is(pg_temp.duties(1, 'duties.add_member', 9, jsonb_build_object('department_id', pg_temp.d(),
            'member_id', pg_temp.mid(4))) ->> 'code', 'conflict', 'a stale department revision is a conflict');
select is(pg_temp.add(4, pg_temp.d()) ->> 'revision', '2', 'an Admin adds member M to D');
select pg_temp.add(5, pg_temp.d());
select pg_temp.add(8, pg_temp.d());
select is((select string_agg(app.identity_member_account_label(member_id), ',' order by member_id)
             from app.duties_department_members where member_id = pg_temp.mid(8)),
  'no_login', 'a member without a login is a department member too');
select is(pg_temp.add(4, pg_temp.d()) -> 'field_errors', '{"member_id": "current"}'::jsonb,
  'adding a current member again is refused');
select is(pg_temp.duties(1, 'duties.add_member', 1, jsonb_build_object('department_id', pg_temp.e(),
            'member_id', '00000000-0000-4000-8000-00000000dead')) -> 'field_errors',
  '{"member_id": "unknown"}'::jsonb, 'only approved members can be added');
select pg_temp.add(9, pg_temp.e());
select is((select string_agg(action, ',' order by event_id) from app.duties_audit),
  'department_created,department_created,member_added,member_added,member_added,member_added',
  'department setup is audited');

-- Publishing ---------------------------------------------------------------------------------------
create function pg_temp.duty(p_department uuid, n int, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('department_id', p_department, 'duty_name', 'Sunday preaching',
           'starts_at', pg_temp.at(interval '10 days'), 'ends_at', pg_temp.at(interval '10 days 2 hours'),
           'location', 'SYNTHETIC Main hall', 'instructions', 'Arrive early.',
           'member_id', pg_temp.mid(n), 'response_deadline', pg_temp.at(interval '7 days')) || p_extra
$$;
select is(pg_temp.duties(9, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4)) ->> 'code',
  'forbidden', 'a member with no department scope cannot publish');
select is(pg_temp.duties(6, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4)) ->> 'code',
  'forbidden', 'another department''s leader cannot publish for D');
select is(pg_temp.duties(7, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4)) ->> 'code',
  'forbidden', 'the Pastor oversees but does not publish');
with c as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
           values ('SYNTHETIC 4.1 Cell', 'SYNTHETIC North', true, 'pgtap 4.1') returning cell_id)
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator)
select pg_temp.mid(9), 'cell_leader', cell_id, 'israel' from c;
select is(pg_temp.duties(9, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4)) ->> 'code',
  'forbidden', 'a cell leader gains no department authority');
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 9)) -> 'field_errors',
  '{"member_id": "not_in_department"}'::jsonb, 'the assignee must be a current member of the department');
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4,
            jsonb_build_object('starts_at', pg_temp.at(interval '-1 hour'),
                               'response_deadline', pg_temp.at(interval '-2 hours'),
                               'ends_at', pg_temp.at(interval '-2 hours'), 'duty_name', '', 'extra', true)))
            -> 'field_errors',
  '{"starts_at": "past", "ends_at": "before_start", "response_deadline": "past", "duty_name": "required", "extra": "unknown_field"}'::jsonb,
  'every shape and time error at once');
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4,
            jsonb_build_object('reporting_at', pg_temp.at(interval '10 days -30 minutes'),
                               'response_deadline', pg_temp.at(interval '10 days -10 minutes'))))
            -> 'field_errors',
  '{"response_deadline": "after_start"}'::jsonb, 'the deadline is never after the (reporting) start');
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4,
            jsonb_build_object('response_deadline', null))) -> 'field_errors',
  '{"response_deadline": "required"}'::jsonb, 'the leader enters the deadline (no default in 4.1)');
select is(pg_temp.duties(2, 'duties.publish_duty', 1, pg_temp.duty(pg_temp.d(), 4)) -> 'field_errors',
  '{"expected_revision": "must_be_null"}'::jsonb, 'publishing is a create (expected_revision null)');
select is((select count(*)::int from app.duties_occurrences) + (select count(*)::int from app.notifications_jobs
            where source_type = 'duties_assignment'), 0, 'refused publishes wrote nothing');

create temp table pub_req as select gen_random_uuid() as id;
create temp table pub as select pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4),
  (select id from pub_req)) as r;
create function pg_temp.asg() returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pub $$;
select is((select (r ->> 'revision') || '|' || (r #>> '{data,response}') || '|'
                  || (r #>> '{data,notice_queued}') || '|'
                  || (select string_agg(k, ',' order by k) from jsonb_object_keys(r -> 'data') k) from pub),
  '1|pending|true|assignment_id,assignment_revision,department_id,notice_queued,occurrence_id,override_recorded,response,revision,slot_id',
  'the leader publishes one position with a pending assignment; the answer holds ids and states only');
select is((select string_agg(job_state || ':' || reminder_kind || ':' || source_revision, ',')
             from app.notifications_jobs where source_type = 'duties_assignment' and source_id = pg_temp.asg()),
  'pending:duty_assigned:1', 'publishing enqueued one duty_assigned job in the same transaction');
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4), (select id from pub_req)),
  (select r from pub), 'replaying the same request returns the stored result');
select is((select count(*)::int from app.duties_occurrences), 1, 'and adds nothing');
create temp table dep_req as select gen_random_uuid() as id;
select is(pg_temp.duties(3, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 8,
            '{"duty_name": "Reading"}'), (select id from dep_req)) #>> '{data,response}',
  'pending', 'the deputy publishes too (to the accountless member)');

-- Inbox: the worker delivers one item to M; the open target is the duty screen --------------------
select is(pg_temp.run() ->> 'delivered', '1', 'the worker delivers the app member''s new-duty item');
select is((select string_agg(job_state || '|' || coalesce(finish_reason, '-'), ',' order by enqueued_at)
             from app.notifications_jobs where source_type = 'duties_assignment'
               and recipient_member_id = pg_temp.mid(8)),
  'ineligible|no_direct_contact_route',
  'the accountless member gets no inbox item (a direct-contact need, unrouted until 4.8)');
create temp table item as select (pg_temp.readj(4, 'select api.notifications_my_inbox()') #>> '{items,0,item_id}')::uuid as id;
select is((pg_temp.readj(4, format('select api.notifications_open_item(%L::uuid)', (select id from item)))) ->> 'target',
  '/duties/assignments/' || pg_temp.asg(), 'opening the item gives the duty''s deep link');
select is((pg_temp.readj(4, format('select api.notifications_open_item(%L::uuid)', (select id from item)))) ->> 'title',
  'New duty assigned', 'with the contract''s generic title');

create temp table pub_admin as select pg_temp.duties(1, 'duties.publish_duty', null,
  pg_temp.duty(pg_temp.d(), 5, '{"duty_name": "Prayer"}')) as r;
select is((select r #>> '{data,response}' from pub_admin), 'pending',
  'an Admin can manage any department');
select is((select string_agg(actor_capacity, ',' order by event_id) from app.duties_audit where action = 'duty_published'),
  'department_leader,department_deputy,admin', 'publishing is audited with the capacity');

-- Reads ---------------------------------------------------------------------------------------------
select is(pg_temp.readj(4, 'select api.duties_my_duties()') #>> '{assignments,0,department_name}',
  'SYNTHETIC Preaching Rota', 'M sees the duty with its owning department');
select is((pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments' -> 0) - 'assignment_id' - 'occurrence_id'
            - 'department_id' - 'starts_at' - 'ends_at' - 'response_deadline'
            -- Story 4.2 keys (revisions) are checked in duties_revisions_test.sql.
            - 'slot_revision' - 'changes' - 'previous_response' - 'previous_assignment_ids' - 'notes_updated_at'
            -- Story 4.3 keys are checked in duties_rota_test.sql.
            - 'position_name' - 'topic' - 'scripture',
  '{"revision": 1, "duty_name": "Sunday preaching", "department_name": "SYNTHETIC Preaching Rota", "reporting_at": null, "location": "SYNTHETIC Main hall", "instructions": "Arrive early.", "response": "pending", "responded_at": null, "note": null}'::jsonb,
  'with its detail, deadline and pending response');
select is(jsonb_array_length(pg_temp.readj(5, 'select api.duties_my_duties()') -> 'assignments'), 1,
  'another member sees only their own duty');
select is(pg_temp.read(9, 'select api.duties_leader_board()'), 'PT403|forbidden|not_granted',
  'a member with no department scope has no leader board');
select is(pg_temp.read(9, 'select api.duties_admin_overview()') like 'PT403|forbidden|%', true,
  'and no Admin overview');
select is((select string_agg(x ->> 'name', ',') from jsonb_array_elements(
             pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') x),
  'SYNTHETIC Preaching Rota', 'the leader sees only their department');
select is((select string_agg(x ->> 'name', ',' order by x ->> 'name') from jsonb_array_elements(
             pg_temp.readj(6, 'select api.duties_leader_board()') -> 'departments') x),
  'SYNTHETIC 4.1 Ushers', 'the other leader sees only theirs');
select is((select string_agg((x ->> 'capacity') || ':' || (x ->> 'can_publish'), ',' order by x ->> 'name')
             from jsonb_array_elements(pg_temp.readj(7, 'select api.duties_leader_board()') -> 'departments') x),
  'pastor:false,pastor:false', 'the Pastor sees every department read-only');
select is(jsonb_array_length(pg_temp.readj(1, 'select api.duties_admin_overview()') -> 'departments'), 2,
  'the Admin overview lists both departments');

-- Responses ------------------------------------------------------------------------------------------
select is(pg_temp.duties(5, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'accepted')) ->> 'code', 'not_found', 'another member cannot answer M''s duty');
select is(pg_temp.duties(2, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'accepted')) ->> 'code', 'not_found', 'nor can the leader (that is 4.9''s confirmation)');
select is(pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'maybe', 'note', repeat('x', 281))) -> 'field_errors',
  '{"response": "invalid", "note": "invalid"}'::jsonb, 'the response and note are checked');
select is(pg_temp.duties(4, 'duties.respond', 5, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'accepted')) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 1}'::jsonb, 'a stale revision is a conflict');
create temp table acc_req as select gen_random_uuid() as id;
create temp table acc as select pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg(),
  'response', 'accepted', 'note', '  Happy to  serve. '), (select id from acc_req)) as r;
select is((select (r ->> 'revision') || '|' || (r #>> '{data,response}') || '|' || coalesce(r #>> '{data,note}', 'none')
                  || '|' || (select response_note from app.duties_assignments where assignment_id = pg_temp.asg()) from acc),
  '2|accepted|none|Happy to serve.', 'M accepts with a practical note (stored, but not in the receipt)');
select is((select response_provenance || '|' || (responded_by_member = pg_temp.mid(4))::text
                  || '|' || (responded_by_account = pg_temp.u(4))::text
             from app.duties_assignments where assignment_id = pg_temp.asg()),
  'member|true|true', 'the response records the member, the account and the provenance');
select is(pg_temp.duties(4, 'duties.respond', 1, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'accepted', 'note', '  Happy to  serve. '), (select id from acc_req)),
  (select r from acc), 'a replay returns the stored answer');
select is(pg_temp.duties(4, 'duties.respond', 2, jsonb_build_object('assignment_id', pg_temp.asg(),
            'response', 'declined')) -> 'field_errors',
  '{"assignment_id": "responded"}'::jsonb, 'an answered duty cannot be answered again in 4.1');
select is(jsonb_path_query_first(pg_temp.readj(2, 'select api.duties_leader_board()'),
            '$.departments[0].duties[*] ? (@.duty_name == "Sunday preaching").positions[0].assignment.response') #>> '{}',
  'accepted', 'the leader sees Accepted at once');
select is(jsonb_path_query_first(pg_temp.readj(2, 'select api.duties_leader_board()'),
            '$.departments[0].duties[*] ? (@.duty_name == "Sunday preaching").positions[0].assignment.note') #>> '{}',
  'Happy to serve.', 'with the member''s note');
select is((select (jsonb_path_query_first(x, '$.duties[*] ? (@.duty_name == "Sunday preaching").positions[0].assignment') ->> 'response')
                  || '|' || coalesce(jsonb_path_query_first(x, '$.duties[*] ? (@.duty_name == "Sunday preaching").positions[0].assignment') ->> 'note', 'none')
             from jsonb_array_elements(
             pg_temp.readj(7, 'select api.duties_leader_board()') -> 'departments') x
            where x ->> 'name' = 'SYNTHETIC Preaching Rota'),
  'accepted|none', 'the Pastor sees the response without the note');
select is((pg_temp.readj(4, format('select api.notifications_open_item(%L::uuid)', (select id from item)))) ->> 'state',
  'superseded', 'after the answer the inbox item no longer opens the duty');
create temp table dec as select pg_temp.duties(5, 'duties.respond', 1, jsonb_build_object(
  'assignment_id', (select r #>> '{data,assignment_id}' from pub_admin),
  'response', 'declined')) as r;
select is((select r #>> '{data,response}' from dec), 'declined', 'O says they cannot make it');
select is((select string_agg(job_state || '|' || coalesce(cancel_reason, '-'), ',')
             from app.notifications_jobs where source_type = 'duties_assignment'
              and source_id = (select (r #>> '{data,assignment_id}')::uuid from pub_admin)),
  'cancelled|responded', 'an answer before delivery cancels the pending job');
select is((select string_agg(code, ',' order by event_id) from app.duties_audit where action = 'response_recorded'),
  'accepted,declined', 'responses are audited with their code only');
-- A duty that has started cannot be answered.
update app.duties_occurrences set starts_at = now() - interval '1 minute', ends_at = null,
       reporting_at = null
 where occurrence_id = (select (r #>> '{data,occurrence_id}')::uuid from pub_admin);
create temp table late as select pg_temp.duties(1, 'duties.publish_duty', null,
  pg_temp.duty(pg_temp.d(), 5, '{"duty_name": "Welcome"}')) as r;
update app.duties_occurrences set starts_at = now() - interval '1 minute', ends_at = null
 where occurrence_id = (select (r #>> '{data,occurrence_id}')::uuid from late);
select is(pg_temp.duties(5, 'duties.respond', 1, jsonb_build_object(
            'assignment_id', (select r #>> '{data,assignment_id}' from late),
            'response', 'accepted')) -> 'field_errors',
  '{"assignment_id": "started"}'::jsonb, 'a duty that has started cannot be answered');
select is(app.duties_assignment_reminder_check(jsonb_build_object(
            'source_id', (select r #>> '{data,assignment_id}' from late),
            'source_revision', 1, 'recipient_member_id', pg_temp.mid(5))) ->> 'actionable',
  'false', 'and its reminder is no longer actionable');

-- Scope loss and replay recheck --------------------------------------------------------------------
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d()));
select is(pg_temp.duties(2, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 4), (select id from pub_req)) ->> 'code',
  'forbidden', 'after the scope is revoked even a replay of the leader''s publish is refused');
select is(pg_temp.read(2, 'select api.duties_leader_board()'), 'PT403|forbidden|not_granted',
  'and the leader board is gone at once');

-- Deputy loss: a new publish and a replay of the deputy's earlier publish are refused.
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(3)),
  jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'department_deputy', 'scope_id', pg_temp.d()));
select is(pg_temp.duties(3, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 8, '{"duty_name": "Reading"}'),
            (select id from dep_req)) ->> 'code',
  'forbidden', 'a revoked deputy''s replay is refused');
select is(pg_temp.duties(3, 'duties.publish_duty', null, pg_temp.duty(pg_temp.d(), 5)) ->> 'code',
  'forbidden', 'and so is a new publish');

-- An untrusted (OTP) session is unauthenticated.
insert into auth.sessions (id, user_id, aal, created_at)
values (pg_temp.s(21), pg_temp.u(6), 'aal1', clock_timestamp() - interval '1 hour');
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), pg_temp.s(21), now(), now(), 'otp');
select is(pg_temp.cmd(jsonb_build_object('sub', pg_temp.u(6), 'role', 'authenticated', 'aal', 'aal1',
            'session_id', pg_temp.s(21), 'is_anonymous', false,
            'amr', jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', 1790000000))),
            'api.duties_command', 'duties.publish_duty', null, pg_temp.duty(pg_temp.e(), 9)) ->> 'code',
  'unauthenticated', 'a leader''s untrusted session is unauthenticated');

-- A member with a pending deletion request cannot be given a duty.
insert into app.identity_deletions (member_id, had_account, origin, is_synthetic)
values (pg_temp.mid(9), true, 'member_request', true);
select is(pg_temp.duties(6, 'duties.publish_duty', null, pg_temp.duty(pg_temp.e(), 9)) -> 'field_errors',
  '{"member_id": "unknown"}'::jsonb, 'publishing to a member with a pending deletion is refused');
select is(jsonb_array_length(pg_temp.readj(6, 'select api.duties_leader_board()') #> '{departments,0,members}'), 0,
  'and they leave the department roster');

-- A member who leaves the department is no longer an eligible recipient.
create temp table nine as select pg_temp.duties(1, 'duties.publish_duty', null,
  pg_temp.duty(pg_temp.d(), 5, '{"duty_name": "Usher"}')) as r;
update app.duties_department_members set ended_at = now()
 where department_id = pg_temp.d() and member_id = pg_temp.mid(5);
select is(app.duties_assignment_reminder_check(jsonb_build_object(
            'source_id', (select r #>> '{data,assignment_id}' from nine),
            'source_revision', 1, 'recipient_member_id', pg_temp.mid(5))) ->> 'recipient_eligible',
  'false', 'after leaving the department the reminder''s recipient is no longer eligible');

-- Deletion ------------------------------------------------------------------------------------------
select is((select (r ->> 'remaining')::int > 0 from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'check')) r
            where r ->> 'module' = 'duties'), true, 'before erasure the check counts M''s Duties rows');
create temp table saved_def as
  select pg_catalog.pg_get_functiondef('app.duties_deletion_purge_rows(uuid)'::regprocedure) as d;
select ok((select d from saved_def) like '%delete from app.duties_department_members%',
  'the installed purge body is the rows file''s, not the stub');
create or replace function app.duties_deletion_purge_rows(p_member_id uuid)
returns integer language plpgsql set search_path = '' as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end; $$;
select throws_ok(format($$select app.duties_erase_member(jsonb_build_object(
    'member_id', %L, 'account_id', %L, 'deletion_id', gen_random_uuid(), 'phase', 'erase'))$$, pg_temp.mid(4), pg_temp.u(4)),
  'PCMD1', 'unavailable', 'without the rows file the erase step is unavailable');
do $$ begin execute (select d from pg_temp.saved_def); end $$;
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'the erase phase leaves nothing of M in Duties');
select is((select (member_id = '00000000-0000-0000-0000-000000000000')::text || '|' || coalesce(response_note, 'null')
                  || '|' || response
             from app.duties_assignments where assignment_id = pg_temp.asg()),
  'true|null|accepted', 'the assignment stays as an anonymous fact without the note');
select is((select count(*)::int from app.duties_department_members where member_id = pg_temp.mid(4)), 0,
  'M''s department membership is deleted');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(2), pg_temp.u(2), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'a leader''s publishing traces are anonymised too');
select is((select count(*)::int from app.cmd_receipts c
            where c.command like 'duties.%'
              and (c.result::text like '%SYNTHETIC 4.1 Member 4%' or c.result::text like '%SYNTHETIC 4.1 Member 2%'
                   or c.result::text like '%Happy to serve%')), 0,
  'no duties receipt holds a deleted member''s name or note');

-- Production marker: the Q4 gate closes Duties; once Q4 is approved, synthetic departments are
-- hidden. (Rolled back with the test.)
select app.platform_set_environment('production', 'pgtap 4.1');
select app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 4.1 production check');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 4.1 production check', 'pgtap');
select is(pg_temp.duties(1, 'duties.create_department', null, '{"name": "SYNTHETIC Closed"}') ->> 'code',
  'unavailable', 'with Q4 closed (production) Duties commands are unavailable');
select is(pg_temp.read(1, 'select api.duties_admin_overview()'), 'PT403|unavailable|unavailable',
  'and so are the reads');
select app.policy_approve('q4_personal_data', '{}'::jsonb, 'pgtap', 'pgtap 4.1 production check');
select is(jsonb_array_length(pg_temp.readj(1, 'select api.duties_admin_overview()') -> 'departments'), 0,
  'in production synthetic departments are hidden from the Admin');
select is(jsonb_array_length(pg_temp.readj(7, 'select api.duties_leader_board()') -> 'departments'), 0,
  'and from the Pastor''s board');

select * from finish();
rollback;
