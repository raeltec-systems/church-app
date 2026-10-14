-- Open the Follow-ups registry (story 4.6; AD-2, AD-5, AD-7, AD-14): purpose registration, one
-- task per source/purpose, owner and scope-holder commands with attributed updates, Admin
-- routing metadata only, private notes, the owner operations, replay recheck, the deletion hook
-- and the closed personal-data gate. HTTP evidence: tools/identity-e2e/followups.mjs. Every
-- account, phone and name here is SYNTHETIC (fictional range +44 7700 900210-900219).
begin;
select plan(143);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000046' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000046' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (210 + n)::text $$;
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
create function pg_temp.fu(n int, p_command text, p_expected bigint, p_payload jsonb,
                           p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  select api.followups_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', p_request,
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
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
create function pg_temp.at(p_offset interval) returns text language sql as
$$ select app.cmd_utc(date_trunc('second', now()) + p_offset) $$;
-- Scope D (a SYNTHETIC department) and E (a SYNTHETIC cell).
create function pg_temp.d() returns uuid language sql as $$ select '00000000-0000-4000-a000-0000000046d0'::uuid $$;
create function pg_temp.e() returns uuid language sql as $$ select '00000000-0000-4000-a000-0000000046e0'::uuid $$;
create function pg_temp.f() returns uuid language sql as $$ select '00000000-0000-4000-a000-0000000046f0'::uuid $$;
create function pg_temp.src(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-b000-0000000046' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.new_task(n int, p_owner uuid, p_src int, p_extra jsonb default '{}')
returns jsonb language sql as $$
  select pg_temp.fu(n, 'followups.create_task', null, jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', pg_temp.src(p_src), 'source_revision', 1,
    'purpose', 'synthetic_check_in', 'owner_member_id', p_owner,
    'scope_kind', 'department_leader', 'scope_id', pg_temp.d(),
    'next_action', 'SYNTHETIC: phone and check in', 'due_at', pg_temp.at('3 days')) || p_extra)
$$;
create function pg_temp.task(p_src int) returns app.followups_tasks language sql as
$$ select t.* from app.followups_tasks t where t.source_id = pg_temp.src(p_src) $$;

-- Accounts: 1 Admin; 2 leader L of D; 3 deputy P of D; 4 member M of D (app owner); 5 member O
-- of D (no role); 6 cell leader of E; 7 (no account) accountless member X of D; 8 Pastor;
-- 9 deputy of another department F (not a member of D); 10 cell assistant of E; 11 an Admin who
-- also leads D. D and F are SYNTHETIC Duties departments; D's members are M, O and X.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 11) n where n <> 7;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 11) n where n <> 7;
select app.platform_set_environment('local', 'pgtap 4.6');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.6 Member ' || n, 'pgtap 4.6')
  from generate_series(1, 11) n where n <> 7;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.6 Accountless', 'approved', true) returning member_id)
insert into m select 7, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(8), 'pastor', 'israel');
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator) values
  (pg_temp.mid(2), 'department_leader', pg_temp.d(), 'israel'),
  (pg_temp.mid(3), 'department_deputy', pg_temp.d(), 'israel'),
  (pg_temp.mid(6), 'cell_leader', pg_temp.e(), 'israel'),
  (pg_temp.mid(9), 'department_deputy', pg_temp.f(), 'israel'),
  (pg_temp.mid(10), 'cell_assistant', pg_temp.e(), 'israel'),
  (pg_temp.mid(11), 'department_leader', pg_temp.d(), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(11), 'admin', 'israel');
insert into app.duties_departments (department_id, name, is_synthetic, created_by_member, created_by_account)
values (pg_temp.d(), 'SYNTHETIC 4.6 Department D', true, pg_temp.mid(1), pg_temp.u(1)),
       (pg_temp.f(), 'SYNTHETIC 4.6 Department F', true, pg_temp.mid(1), pg_temp.u(1));
insert into app.duties_department_members (department_id, member_id, added_by_member, added_by_account)
select pg_temp.d(), pg_temp.mid(n), pg_temp.mid(1), pg_temp.u(1) from unnest(array[4, 5, 7]) n;

-- Structure, privileges and guards -------------------------------------------------------------
select is((select count(*)::int from information_schema.tables where table_schema = 'app'
            and table_name in ('followups_purposes', 'followups_tasks', 'followups_activity',
                               'followups_notes')), 4,
  'purpose, task, activity and note tables exist');
select ok(not exists (
  select 1 from unnest(array['app.followups_purposes', 'app.followups_tasks',
                             'app.followups_activity', 'app.followups_notes']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the Follow-ups tables (a direct table query is refused)');
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relname ~ '^followups_' and c.relkind = 'r'),
  'RLS is on for every Follow-ups table');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'followups_activity'),
  array['action', 'activity_id', 'actor_account_id', 'actor_capacity', 'actor_member_id', 'code',
        'command_request_id', 'environment', 'from_member', 'from_state', 'occurred_at',
        'on_behalf_of_member', 'outcome', 'review_at', 'revision_after', 'task_id', 'to_member',
        'to_state'],
  'the activity holds ids, codes, states and dates only (no names, notes or free text)');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname in ('app', 'api') and (p.proname ~ '^followups_' or p.proname ~ '^fixture_followup')
     and not (p.proname in ('followups_command', 'followups_my_tasks', 'followups_task',
                            'followups_supervision', 'followups_admin_routing')
              and r = 'authenticated')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'only the command and the four reads are client-executable, and only by authenticated');
select ok(not has_function_privilege('authenticated', 'app.followups_open_task(jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.followups_source_event(jsonb)', 'EXECUTE'),
  'the owner operations are server-side only');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select a.handler from app.cmd_authorizers a where a.namespace = 'followups'),
  'app.followups_authorize_command(jsonb)', 'the followups authorizer is registered for followups.*');
select is((select handler from app.identity_deletion_hooks where module = 'followups'),
  'app.followups_erase_member(jsonb)', 'Follow-ups registered its deletion hook');
select is((select p.label || '|' || p.on_source_resolved || '|' || p.on_source_cancelled || '|'
                  || p.manual_create || '|' || array_to_string(p.outcomes, ',') || '|' || p.context_hook
             from app.followups_purposes p
            where p.source_type = 'fixture_followup' and p.purpose = 'synthetic_check_in'),
  'SYNTHETIC check-in|close|close|true|contacted,no_longer_needed,unreachable|app.fixture_followup_context(jsonb)',
  'the SYNTHETIC source registered its purpose, effects, outcomes and context hook');
select ok(exists (select 1 from app.contract_source_purposes
                   where source_type = 'fixture_followup' and purpose = 'synthetic_check_in'),
  'the purpose is also in the shared contract registry (1.5)');

-- Registration refusals (PCTR1) --------------------------------------------------------------
select throws_ok($$select app.followups_register_purpose('followups', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}')$$,
  'PCTR1', null, 'only the module that owns the source type may register its purposes');
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'not_registered',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}')$$,
  'PCTR1', null, 'a purpose must first be registered in the shared contract');
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "Call {name}", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}')$$,
  'PCTR1', null, 'the label is generic text (no placeholders)');
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["nope"], "on_source_resolved": "close", "on_source_cancelled": "keep"}')$$,
  'PCTR1', null, 'scope kinds must be registered Identity scope kinds');
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "complete_source", "on_source_cancelled": "keep"}')$$,
  'PCTR1', null, 'a lifecycle effect is close or keep (task completion never completes a source)');
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}',
    'app.followups_display_name(uuid)'::regprocedure)$$,
  'PCTR1', null, 'the context hook must be the source owner''s (jsonb) -> jsonb function');

-- Create -------------------------------------------------------------------------------------
create temp table k (key text primary key, v jsonb);
insert into k values ('a', pg_temp.new_task(2, pg_temp.mid(4), 1));
select is((select v #>> '{data,state}' || '|' || (v ->> 'revision') || '|' || (v #>> '{data,revision}') from k where key = 'a'),
  'open|1|1', 'the leader of D creates an Open task for an ordinary member');
select is((select string_agg(x, ',' order by x) from jsonb_object_keys((select v -> 'data' from k where key = 'a')) x),
  'revision,state,task_id', 'the answer holds ids, revision and state only (no text)');
select is((select count(*)::int from app.cmd_receipts where command like 'followups.%'
            and result::text like '%SYNTHETIC: phone%'), 0, 'receipts hold no next action text');
select is((select t.owner_member_id = pg_temp.mid(4) and t.supervisor_member_id = pg_temp.mid(2)
                  and t.task_state = 'open' and t.due_at > now() from app.followups_tasks t
            where t.source_id = pg_temp.src(1)), true,
  'owner M, supervisor the creating leader, Open, the due date stored');
select is(pg_temp.new_task(3, pg_temp.mid(5), 1) ->> 'code' || ':' || (pg_temp.new_task(3, pg_temp.mid(5), 1) #>> '{field_errors,purpose}'),
  'conflict:task_exists', 'a second task for the same source and purpose is refused');
select is(pg_temp.new_task(5, pg_temp.mid(4), 2) ->> 'code', 'forbidden', 'a member without the scope cannot create');
select is(pg_temp.new_task(6, pg_temp.mid(4), 2) ->> 'code', 'forbidden', 'another scope''s leader cannot create in D');
select is(pg_temp.new_task(8, pg_temp.mid(4), 2) ->> 'code', 'forbidden', 'the Pastor role alone gives nothing');
select is(pg_temp.new_task(1, pg_temp.mid(4), 2) #>> '{field_errors,supervisor_member_id}', 'required',
  'an Admin must name a supervisor');
select is(pg_temp.new_task(1, pg_temp.mid(4), 2, jsonb_build_object('supervisor_member_id', pg_temp.mid(5))) #>> '{field_errors,supervisor_member_id}',
  'not_in_scope', 'the supervisor must hold the task''s scope');
select is(pg_temp.new_task(1, pg_temp.mid(4), 2, jsonb_build_object('supervisor_member_id', pg_temp.mid(3), 'note', 'x')) #>> '{field_errors,note}',
  'not_allowed', 'an Admin adds no private note');
select is(pg_temp.new_task(9, pg_temp.mid(4), 2) ->> 'code', 'forbidden',
  'a deputy of another department cannot create in D');
select is(pg_temp.new_task(2, pg_temp.mid(9), 2) #>> '{field_errors,owner_member_id}', 'not_in_scope',
  'the owner must be on D''s roster (its members and leaders), not anyone in the church');
select is(pg_temp.new_task(2, pg_temp.mid(4), 2, '{"scope_kind": "fixture_care"}') #>> '{field_errors,scope_kind}', 'not_allowed',
  'a scope kind the purpose did not register is refused');
select is(pg_temp.new_task(2, gen_random_uuid(), 2) #>> '{field_errors,owner_member_id}', 'unknown',
  'the owner must be an approved member');
select is(pg_temp.new_task(2, pg_temp.mid(4), 2, jsonb_build_object('due_at', pg_temp.at('-1 hour'))) #>> '{field_errors,due_at}',
  'past', 'the due date is in the future');
select is(pg_temp.new_task(2, pg_temp.mid(4), 2, '{"source_revision": 2}') #>> '{field_errors,source_id}', 'not_current',
  'the source must be current through its owner''s check hook');
select is(pg_temp.new_task(2, pg_temp.mid(4), 2, '{"purpose": "other_purpose"}') #>> '{field_errors,purpose}', 'unregistered',
  'an unregistered purpose is refused');
select is(pg_temp.new_task(2, pg_temp.mid(4), 2, '{"next_action": "  "}') #>> '{field_errors,next_action}', 'required',
  'a next action is required');
insert into k values ('o', pg_temp.new_task(1, pg_temp.mid(5), 3, jsonb_build_object('supervisor_member_id', pg_temp.mid(3))));
select is((select v #>> '{data,state}' from k where key = 'o'), 'open', 'an Admin creates a task naming a supervisor in scope');
select is((select actor_capacity || '|' || to_member::text from app.followups_activity a
            where a.task_id = (pg_temp.task(3)).task_id and a.action = 'created'),
  'admin|' || pg_temp.mid(5)::text, 'the created activity is attributed (Admin) and names the owner');
insert into k values ('x', pg_temp.new_task(2, pg_temp.mid(7), 4, '{"note": "SYNTHETIC note: lives near the hall"}'));
select is((select v #>> '{data,state}' from k where key = 'x'), 'open', 'the leader creates a task for an accountless member');
select is((select count(*)::int from app.followups_notes n where n.task_id = (pg_temp.task(4)).task_id
             and n.on_behalf_of_member = pg_temp.mid(7)), 1, 'the creator''s note is a private note recorded for the owner');
insert into k values ('b', pg_temp.new_task(2, pg_temp.mid(4), 5));
insert into k values ('dd', pg_temp.new_task(2, pg_temp.mid(4), 6));

-- My follow-ups ------------------------------------------------------------------------------
select is((select jsonb_array_length(pg_temp.readj(4, 'select api.followups_my_tasks()') -> 'tasks')), 3,
  'M sees their three tasks in My follow-ups');
select is((select x ->> 'next_action' || '|' || (x #>> '{context,label}') || '|' || (x ->> 'capacity') || '|'
                  || (x ->> 'can_update') || '|' || (x ->> 'can_reassign') || '|' || (x #>> '{supervisor,display_name}')
             from jsonb_array_elements(pg_temp.readj(4, 'select api.followups_my_tasks()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(1)).task_id::text),
  'SYNTHETIC: phone and check in|SYNTHETIC check-in source|owner|true|false|SYNTHETIC 4.6 Member 2',
  'the owner sees the next action, the minimal source context and the supervisor, and may update but not reassign');
select is((select string_agg(x ->> 'task_id', ',') from jsonb_array_elements(
             pg_temp.readj(5, 'select api.followups_my_tasks()') -> 'tasks') x),
  (pg_temp.task(3)).task_id::text, 'O sees only their own task');

-- Lifecycle by the owner ---------------------------------------------------------------------
create function pg_temp.upd(n int, p_src int, p_payload jsonb, p_expected bigint default null,
                            p_request uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.fu(n, 'followups.update_task', coalesce(p_expected, (pg_temp.task(p_src)).revision),
                    jsonb_build_object('task_id', (pg_temp.task(p_src)).task_id) || p_payload, p_request)
$$;
select is(pg_temp.upd(4, 1, '{"status": "in_progress"}') #>> '{data,state}', 'in_progress', 'the owner starts the task');
select is(pg_temp.upd(4, 1, '{"status": "in_progress"}') #>> '{field_errors,status}', 'unchanged', 'the same state again is refused');
select is(pg_temp.upd(4, 1, '{"status": "waiting"}') #>> '{field_errors,review_at}', 'required',
  'Waiting needs a review date');
select is(pg_temp.upd(4, 1, jsonb_build_object('status', 'waiting', 'review_at', pg_temp.at('-1 day'))) #>> '{field_errors,review_at}',
  'past', 'the review date is in the future');
create temp table due as select (pg_temp.task(1)).due_at as due_at;
select is(pg_temp.upd(4, 1, jsonb_build_object('status', 'waiting', 'review_at', pg_temp.at('5 days'))) #>> '{data,state}',
  'waiting', 'the owner moves the task to Waiting with a review date');
select is((select (pg_temp.task(1)).due_at = due.due_at and (pg_temp.task(1)).review_at > (pg_temp.task(1)).due_at from due),
  true, 'Waiting keeps the original due date beside the later review date');
select is(pg_temp.upd(4, 1, jsonb_build_object('review_at', pg_temp.at('6 days'))) #>> '{data,state}', 'waiting',
  'the owner changes the review date while waiting');
select is((select count(*)::int from app.followups_activity a where a.task_id = (pg_temp.task(1)).task_id
             and a.action = 'review_date_set'), 1, 'the review-date change is recorded, not a silent reset');
select is(pg_temp.upd(4, 1, jsonb_build_object('review_at', pg_temp.at('6 days'))) #>> '{field_errors,review_at}',
  'unchanged', 'the same review date again is refused');
select is(pg_temp.upd(4, 1, '{"status": "in_progress", "review_at": "2099-01-01T00:00:00Z"}') #>> '{field_errors,review_at}',
  'not_waiting', 'a review date only goes with Waiting');
select is(pg_temp.upd(4, 1, '{"outcome": "visited"}') #>> '{field_errors,outcome}', 'unregistered',
  'an outcome the purpose did not register is refused');
select is(pg_temp.upd(4, 1, '{"outcome": "contacted", "note": "SYNTHETIC note: spoke on Sunday"}') #>> '{data,state}', 'waiting',
  'the owner records an outcome and a private note (the status stays)');
select is((select latest_outcome from app.followups_tasks t where t.source_id = pg_temp.src(1)), 'contacted',
  'the outcome is kept apart from the status');
select is(pg_temp.upd(4, 1, '{"close_reason": "x"}') #>> '{field_errors,close_reason}', 'not_closing',
  'a close reason only goes with Closed');
select is(pg_temp.upd(4, 1, '{"status": "in_progress"}', 1) ->> 'code' || ':' || (pg_temp.upd(4, 1, '{"status": "in_progress"}', 1) ->> 'current_revision'),
  'conflict:' || (pg_temp.task(1)).revision::text, 'a stale revision is refused with the current one');
select is(pg_temp.upd(1, 1, '{"status": "done"}') ->> 'code', 'forbidden', 'an Admin cannot work a task');
select is(pg_temp.upd(5, 1, '{"status": "done"}') ->> 'code', 'not_found', 'another member cannot see the task');
select is(pg_temp.upd(4, 1, '{"status": "done"}') #>> '{data,state}', 'done', 'the owner marks the task Done');
select is((select finished_at is not null and review_at is null from app.followups_tasks where source_id = pg_temp.src(1)), true,
  'Done finishes the task and clears the review date');
select is(pg_temp.upd(4, 1, '{"status": "in_progress"}') #>> '{field_errors,task_id}', 'finished',
  'a finished task cannot change');
select is(pg_temp.upd(4, 5, '{"status": "closed"}') #>> '{field_errors,close_reason}', 'required',
  'closing without a reason is refused');
select is(pg_temp.upd(4, 5, '{"status": "closed", "close_reason": "SYNTHETIC: no longer needed"}') #>> '{data,state}', 'closed',
  'the owner closes another task with a reason');
select is((select close_code || '|' || close_reason from app.followups_tasks where source_id = pg_temp.src(5)),
  'manual|SYNTHETIC: no longer needed', 'a manual close keeps its reason');
select is((select string_agg(a.action || ':' || a.actor_capacity, ',' order by a.activity_id)
             from app.followups_activity a where a.task_id = (pg_temp.task(1)).task_id),
  'created:supervisor,status_changed:owner,status_changed:owner,review_date_set:owner,outcome_recorded:owner,note_added:owner,status_changed:owner',
  'every step is attributed activity');

-- A scope holder records for an accountless owner ---------------------------------------------
select is(pg_temp.upd(3, 4, '{"outcome": "contacted", "note": "SYNTHETIC note: reached by phone"}') #>> '{data,state}', 'open',
  'the second leader of D records an update for the accountless owner');
select is((select string_agg(a.action || ':' || a.actor_capacity || ':' || (a.actor_member_id = pg_temp.mid(3)) || ':' || (a.on_behalf_of_member = pg_temp.mid(7)), ',' order by a.activity_id)
             from app.followups_activity a where a.task_id = (pg_temp.task(4)).task_id and a.action <> 'created'),
  'note_added:supervisor:false:true,outcome_recorded:supervisor:true:true,note_added:supervisor:true:true',
  'each update says who recorded it and for whom');
select is((select string_agg(x ->> 'on_behalf_of', ',') from jsonb_array_elements(
             pg_temp.readj(3, format('select api.followups_task(%L)', (pg_temp.task(4)).task_id)) -> 'notes') x),
  'SYNTHETIC 4.6 Accountless,SYNTHETIC 4.6 Accountless', 'the supervisor''s view shows the notes as recorded for the owner');

-- Reassign -----------------------------------------------------------------------------------
create function pg_temp.reassign(n int, p_src int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.fu(n, 'followups.reassign', (pg_temp.task(p_src)).revision,
                    jsonb_build_object('task_id', (pg_temp.task(p_src)).task_id) || p_payload)
$$;
select is(pg_temp.reassign(4, 6, jsonb_build_object('owner_member_id', pg_temp.mid(5))) ->> 'code', 'forbidden',
  'the owner cannot reassign');
select is(pg_temp.reassign(6, 6, jsonb_build_object('owner_member_id', pg_temp.mid(5))) ->> 'code', 'not_found',
  'another scope''s leader cannot see it');
select is(pg_temp.reassign(2, 6, jsonb_build_object('owner_member_id', pg_temp.mid(4))) #>> '{field_errors,owner_member_id}', 'unchanged',
  'reassigning to the same owner is refused');
select is(pg_temp.reassign(2, 6, jsonb_build_object('supervisor_member_id', pg_temp.mid(5))) #>> '{field_errors,supervisor_member_id}',
  'not_in_scope', 'a new supervisor must hold the scope');
select is(pg_temp.reassign(2, 6, jsonb_build_object('owner_member_id', pg_temp.mid(5))) #>> '{data,state}', 'open',
  'the leader reassigns the task to O');
select is((select a.from_member = pg_temp.mid(4) and a.to_member = pg_temp.mid(5) and a.actor_capacity = 'supervisor'
             from app.followups_activity a where a.task_id = (pg_temp.task(6)).task_id and a.action = 'reassigned'),
  true, 'the reassignment is recorded from M to O');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(4, 'select api.followups_my_tasks()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(6)).task_id::text), 0, 'the task left M''s My follow-ups');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(5, 'select api.followups_my_tasks()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(6)).task_id::text), 1, 'and is in O''s');
select is(pg_temp.reassign(1, 6, jsonb_build_object('supervisor_member_id', pg_temp.mid(3))) #>> '{data,state}', 'open',
  'an Admin changes the supervisor');
select is((select a.actor_capacity from app.followups_activity a where a.task_id = (pg_temp.task(6)).task_id
             and a.action = 'supervisor_changed'), 'admin', 'the Admin routing change is attributed');

-- Reads by capacity --------------------------------------------------------------------------
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(1, 'select api.followups_admin_routing()') -> 'tasks') x
            where x ?| array['next_action', 'context', 'notes', 'latest_outcome', 'close_reason', 'source_id']), 0,
  'Admin routing carries no next action, context, outcome, close reason, source id or notes');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(1, 'select api.followups_admin_routing()') -> 'tasks') x
            where x #>> '{owner,display_name}' is not null and x ? 'due_at' and x ? 'state'), 5,
  'Admin routing shows each task''s owner, state and due date');
select is((select v ->> 'view' || '|' || (v ? 'notes')::text || '|' || (v -> 'task' ? 'next_action')::text
             from (select pg_temp.readj(1, format('select api.followups_task(%L)', (pg_temp.task(4)).task_id)) as v) y),
  'routing|false|false', 'an Admin opening a task gets routing metadata only, never the private notes');
select is((select v ->> 'view' || '|' || jsonb_array_length(v -> 'notes') || '|' || jsonb_array_length(v -> 'activity')
             from (select pg_temp.readj(4, format('select api.followups_task(%L)', (pg_temp.task(1)).task_id)) as v) y),
  'full|1|7', 'the owner opens the task with its private note and activity');
select is(pg_temp.read(5, format('select api.followups_task(%L)', (pg_temp.task(1)).task_id)),
  'PT403|forbidden|not_granted', 'another member is refused without disclosure');
select is(pg_temp.read(8, format('select api.followups_task(%L)', (pg_temp.task(1)).task_id)),
  'PT403|forbidden|not_granted', 'the Pastor role alone sees nothing');
select is((select jsonb_array_length(v -> 'tasks') || '|' || jsonb_array_length(v -> 'purposes') || '|'
                  || jsonb_array_length(v -> 'scopes') || '|'
                  || (select x ->> 'account' from jsonb_array_elements(v #> '{scopes,0,candidates}') x
                       where x ->> 'member_id' = pg_temp.mid(7)::text)
             from (select pg_temp.readj(2, 'select api.followups_supervision()') as v) y),
  '5|1|1|no_login', 'the leader of D supervises the five D tasks, may create the SYNTHETIC purpose and sees who has no login');
select is((select string_agg(x ->> 'member_id', ',' order by x ->> 'member_id')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') #> '{scopes,0,candidates}') x),
  (select string_agg(v::text, ',' order by v::text) from unnest(array[pg_temp.mid(2), pg_temp.mid(3), pg_temp.mid(4),
     pg_temp.mid(5), pg_temp.mid(7), pg_temp.mid(8), pg_temp.mid(11)]) v),
  'the candidates are D''s members and leaders plus the Pastor (owner decision Q4, story 4.7); no other department''s deputy');
select is((select string_agg(x ->> 'task_id', ',' order by x ->> 'task_id')
             from jsonb_array_elements(pg_temp.readj(3, 'select api.followups_supervision()') -> 'tasks') x),
          (select string_agg(x ->> 'task_id', ',' order by x ->> 'task_id')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') -> 'tasks') x),
  'the deputy of D supervises exactly the leader''s tasks');
select is((select jsonb_array_length(v -> 'tasks') from (select pg_temp.readj(9, 'select api.followups_supervision()') as v) y),
  0, 'the deputy of another department supervises none of D''s tasks');
select is(pg_temp.upd(9, 4, '{"note": "SYNTHETIC: not mine"}') ->> 'code', 'not_found',
  'nor may they record on one');
select is((select jsonb_array_length(v -> 'tasks') || '|' || jsonb_array_length(v -> 'purposes')
             from (select pg_temp.readj(6, 'select api.followups_supervision()') as v) y),
  '0|1', 'the cell leader of E sees none of D''s tasks');
select is(pg_temp.read(5, 'select api.followups_supervision()'), 'PT403|forbidden|not_granted',
  'a member without a scope has no supervision view');
select is(pg_temp.read(4, 'select api.followups_admin_routing()'), 'PT403|forbidden|not_granted',
  'only an Admin has the routing view');

-- Overdue follows the due date, or the review date while Waiting --------------------------------
select is(pg_temp.upd(2, 4, jsonb_build_object('status', 'waiting', 'review_at', pg_temp.at('2 days'))) #>> '{data,state}', 'waiting',
  'the leader moves the accountless owner''s task to Waiting');
update app.followups_tasks set review_at = now() - interval '1 hour', due_at = now() + interval '1 day'
 where source_id = pg_temp.src(4);
select is((select x ->> 'overdue' || '|' || (x ->> 'due_passed')
             from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(4)).task_id::text),
  'true|false', 'a Waiting task is overdue at its review date while its due date is still ahead');

-- Context hook fail-closed --------------------------------------------------------------------
create function app.fixture_followup_bad_context(p_input jsonb) returns jsonb language sql stable
set search_path = '' as $$ select '{"label": "x", "phone": "0"}'::jsonb $$;
select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
  '{"label": "SYNTHETIC check-in", "scope_kinds": ["department_leader", "department_deputy", "cell_leader", "cell_assistant"],
    "outcomes": ["contacted", "unreachable", "no_longer_needed"], "on_source_resolved": "close",
    "on_source_cancelled": "keep", "manual_create": true}',
  'app.fixture_followup_bad_context(jsonb)'::regprocedure);
select is((select x -> 'context' from jsonb_array_elements(pg_temp.readj(4, 'select api.followups_my_tasks()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(1)).task_id::text), 'null'::jsonb,
  'a context hook answering more than a label shows no context (fail closed)');

-- Owner operations ---------------------------------------------------------------------------
select is((app.followups_open_task(jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', pg_temp.src(7), 'source_revision', 1,
    'purpose', 'synthetic_check_in', 'owner_member_id', pg_temp.mid(4),
    'supervisor_member_id', pg_temp.mid(2), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d(),
    'next_action', 'SYNTHETIC: owner operation', 'due_at', pg_temp.at('2 days'),
    'actor_member_id', pg_temp.mid(2), 'actor_account_id', pg_temp.u(2))) ->> 'revision'), '1',
  'a source owner opens a task through the owner operation');
select is((select actor_capacity from app.followups_activity where task_id = (pg_temp.task(7)).task_id),
  'source', 'its creation is attributed to the source''s command');
select throws_ok(format($$select app.followups_open_task(jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', %L, 'source_revision', 1,
    'purpose', 'synthetic_check_in', 'owner_member_id', %L, 'supervisor_member_id', %L,
    'scope_kind', 'department_leader', 'scope_id', %L, 'next_action', 'again',
    'due_at', %L, 'actor_member_id', %L, 'actor_account_id', %L))$$,
    pg_temp.src(7), pg_temp.mid(4), pg_temp.mid(2), pg_temp.d(), pg_temp.at('2 days'), pg_temp.mid(2), pg_temp.u(2)),
  'PCMD1', 'conflict', 'the owner operation also refuses a second task for the source and purpose');
select is(app.followups_source_event(jsonb_build_object('source_type', 'fixture_followup',
            'source_id', pg_temp.src(7), 'event', 'resolved')), '{"kept": 0, "closed": 1}'::jsonb,
  'a resolved source closes its task (registered effect close)');
select is((select task_state || '|' || close_code || '|' || coalesce(close_reason, '-') from app.followups_tasks
            where source_id = pg_temp.src(7)), 'closed|source_resolved|-', 'closed by the source, not by a person');
select is(app.followups_source_event(jsonb_build_object('source_type', 'fixture_followup',
            'source_id', pg_temp.src(4), 'event', 'cancelled')), '{"kept": 1, "closed": 0}'::jsonb,
  'a cancelled source keeps its task when the purpose registered keep');
select throws_ok($$select app.followups_source_event('{"source_type": "fixture_followup", "source_id": "00000000-0000-4000-b000-000000004601", "event": "completed"}')$$,
  'PCMD1', 'validation_failed', 'only resolved and cancelled are source events');

-- Replay and its recheck ---------------------------------------------------------------------
create temp table rq as select gen_random_uuid() as id;
select is(pg_temp.reassign(3, 3, '{}') #>> '{field_errors,changes}', 'required', 'a reassignment must change something');
insert into k values ('r1', pg_temp.fu(3, 'followups.update_task', (pg_temp.task(3)).revision,
  jsonb_build_object('task_id', (pg_temp.task(3)).task_id, 'next_action', 'SYNTHETIC: visit instead'), (select id from rq)));
select is((select v ->> 'revision' from k where key = 'r1'), '2', 'a scope holder changes the next action');
select is(pg_temp.fu(3, 'followups.update_task', 1,
  jsonb_build_object('task_id', (pg_temp.task(3)).task_id, 'next_action', 'SYNTHETIC: visit instead'), (select id from rq)),
  (select v from k where key = 'r1'), 'the same request replays the stored result');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where member_id = pg_temp.mid(3) and scope_kind = 'department_deputy';
select is(pg_temp.fu(3, 'followups.update_task', 1,
  jsonb_build_object('task_id', (pg_temp.task(3)).task_id, 'next_action', 'SYNTHETIC: visit instead'), (select id from rq)) ->> 'code',
  'forbidden', 'after the scope is revoked the replay is refused');
select is(pg_temp.upd(3, 4, '{"note": "SYNTHETIC note: again"}') ->> 'code', 'not_found',
  'a revoked leader can no longer act on the scope''s tasks');

-- Scope families both ways, Admin with a scope (review S1, N10) --------------------------------
-- (the deputy's grant was revoked above; the leader 2 and the Admin-leader 11 remain)
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator)
values (pg_temp.mid(3), 'department_deputy', pg_temp.d(), 'israel');
insert into k values ('dep', pg_temp.new_task(3, pg_temp.mid(5), 10, '{"scope_kind": "department_deputy"}'));
select is((select v #>> '{data,state}' from k where key = 'dep'), 'open', 'the deputy of D creates a task in the deputy scope');
select is(pg_temp.reassign(2, 10, jsonb_build_object('owner_member_id', pg_temp.mid(7))) #>> '{data,state}', 'open',
  'the leader of D reassigns the deputy''s task (one department family)');
select is(pg_temp.reassign(9, 10, jsonb_build_object('owner_member_id', pg_temp.mid(4))) ->> 'code', 'not_found',
  'another department''s deputy cannot');
select is(pg_temp.fu(6, 'followups.create_task', null, jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', pg_temp.src(11), 'source_revision', 1,
    'purpose', 'synthetic_check_in', 'owner_member_id', pg_temp.mid(10), 'scope_kind', 'cell_leader',
    'scope_id', pg_temp.e(), 'next_action', 'SYNTHETIC: cell visit', 'due_at', pg_temp.at('2 days'))) #>> '{data,state}',
  'open', 'the cell leader of E creates a task for the cell''s assistant');
select is(pg_temp.upd(10, 11, '{"status": "in_progress"}') #>> '{data,state}', 'in_progress',
  'the assistant works it as its owner');
select is(pg_temp.reassign(10, 11, jsonb_build_object('owner_member_id', pg_temp.mid(6))) #>> '{data,state}', 'in_progress',
  'and, holding the cell family scope, reassigns it to the cell leader');
select is((select x ->> 'capacity' from jsonb_array_elements(pg_temp.readj(10, 'select api.followups_supervision()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(11)).task_id::text), 'supervisor',
  'the assistant supervises the cell leader''s task');
select is((select v ->> 'view' || '|' || (v #>> '{task,capacity}')
             from (select pg_temp.readj(11, format('select api.followups_task(%L)', (pg_temp.task(4)).task_id)) as v) y),
  'full|supervisor', 'an Admin who also leads D sees D''s tasks in full, as a supervisor');
select is(pg_temp.upd(11, 4, '{"note": "SYNTHETIC: as leader"}') #>> '{data,state}', 'waiting',
  'and records on them (the scope capacity wins over Admin routing)');
select is(pg_temp.reassign(1, 4, jsonb_build_object('owner_member_id', pg_temp.mid(9))) #>> '{field_errors,owner_member_id}',
  'not_in_scope', 'an Admin reassigns only within the task''s scope roster (and the Pastors, story 4.7)');
select is((select string_agg(x ->> 'scope_id', ',') from jsonb_array_elements(
             pg_temp.readj(1, 'select api.followups_admin_routing()') -> 'scopes') x
            where x ->> 'scope_id' = pg_temp.d()::text and x ->> 'family' = 'department'
              and jsonb_array_length(x -> 'candidates') = 7), pg_temp.d()::text,
  'Admin routing carries each active task scope''s roster, not the whole church');

-- Registration hardening (review S3, N1) ------------------------------------------------------
select app.contract_register_purpose('duties', 'duties_assignment', 'pgtap_manual');
select throws_ok($$select app.followups_register_purpose('duties', 'duties_assignment', 'pgtap_manual',
    '{"label": "X", "scope_kinds": ["department_leader"], "on_source_resolved": "close",
      "on_source_cancelled": "keep", "manual_create": true}')$$,
  'PCTR1', 'manual_create is only for SYNTHETIC fixture_ sources',
  'a real source cannot allow hand-made tasks (no source-scope check yet)');
create function app.fixture_followup_volatile_context(p_input jsonb) returns jsonb language sql volatile
set search_path = '' as $$ select '{"label": "x"}'::jsonb $$;
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}',
    'app.fixture_followup_volatile_context(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a volatile context hook is refused');
create function app.fixture_followup_definer_context(p_input jsonb) returns jsonb language sql stable
security definer set search_path = '' as $$ select '{"label": "x"}'::jsonb $$;
select throws_ok($$select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"label": "X", "scope_kinds": ["cell_leader"], "on_source_resolved": "close", "on_source_cancelled": "keep"}',
    'app.fixture_followup_definer_context(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a SECURITY DEFINER context hook is refused');
select throws_ok($$select app.followups_register_scope_family('duties', 'cell_leader', 'cell',
    'app.duties_followups_roster(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'only the owner of a scope kind registers its family');
create function app.fixture_followup_raising_context(p_input jsonb) returns jsonb language plpgsql stable
set search_path = '' as $$ begin raise exception 'SYNTHETIC hook failure'; end $$;
select app.followups_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in',
  '{"label": "SYNTHETIC check-in", "scope_kinds": ["department_leader", "department_deputy", "cell_leader", "cell_assistant"],
    "outcomes": ["contacted", "unreachable", "no_longer_needed"], "on_source_resolved": "close",
    "on_source_cancelled": "keep", "manual_create": true}',
  'app.fixture_followup_raising_context(jsonb)'::regprocedure);
select is((select x -> 'context' from jsonb_array_elements(pg_temp.readj(4, 'select api.followups_my_tasks()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(1)).task_id::text), 'null'::jsonb,
  'a context hook that raises shows no context and the read still answers');

-- Deletion hook ------------------------------------------------------------------------------
insert into k values ('f', pg_temp.new_task(2, pg_temp.mid(4), 8, '{"note": "SYNTHETIC note: about M"}'));
select ok((select (r ->> 'remaining')::int > 0 from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'check')) r
            where r ->> 'module' = 'followups'), 'before erasure the check counts M''s Follow-ups rows');
select is((select r ->> 'remaining' from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'followups'), '0', 'erase leaves nothing of M');
select is((select count(*)::int from app.followups_notes n join app.followups_tasks t on t.task_id = n.task_id
            where t.source_id in (pg_temp.src(1), pg_temp.src(8)) and n.body is not null), 0,
  'the note text on M''s tasks is cleared');
select is((select task_state || '|' || (owner_member_id = '00000000-0000-0000-0000-000000000000')::text
             from app.followups_tasks where source_id = pg_temp.src(8)), 'open|true',
  'M''s active task stays active with an anonymous owner, for its scope to reassign');
select is((select x #>> '{owner,display_name}' from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(8)).task_id::text), null, 'the supervisor sees a former member');
select is((select r ->> 'remaining' from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'check')) r
            where r ->> 'module' = 'followups'), '0', 'the check answers 0');
select is((select r ->> 'remaining' from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(2), pg_temp.u(2), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'followups'), '0', 'erasing the supervising and creating leader leaves nothing of them');
select is((select (a ->> 'actor') || '|' || (select n ->> 'on_behalf_of' from jsonb_array_elements(v -> 'notes') n
                                              where n ->> 'author' = 'a former member' limit 1)
             from (select pg_temp.readj(11, format('select api.followups_task(%L)', (pg_temp.task(8)).task_id)) as v) y,
                  jsonb_array_elements(v -> 'activity') a
            where a ->> 'action' = 'created'),
  'a former member|a former member', 'activity and notes name an erased creator and owner as a former member');
select is((select x #>> '{supervisor,display_name}' from jsonb_array_elements(
             pg_temp.readj(11, 'select api.followups_supervision()') -> 'tasks') x
            where x ->> 'task_id' = (pg_temp.task(8)).task_id::text), null,
  'the erased supervisor shows as a former member; the task stays with D''s other leaders');
select is((select count(*)::int from app.followups_tasks t where t.source_type = 'fixture_followup'), 9,
  'no task row was removed');

-- The personal-data gate (production stays inert) -----------------------------------------------
select app.platform_set_environment('production', 'pgtap 4.6');
select is(pg_temp.new_task(11, pg_temp.mid(5), 9) ->> 'code', 'forbidden',
  'in production a SYNTHETIC account is no live member, so a create is refused forbidden');
select is((select count(*)::int from app.followups_tasks where source_id = pg_temp.src(9)), 0, 'and nothing is written');
select throws_ok($$select app.followups_source_event('{"source_type": "fixture_followup", "source_id": "00000000-0000-4000-b000-000000004604", "event": "resolved"}')$$,
  'PCMD1', 'unavailable', 'a source event is gated too');
select throws_ok($$select app.followups_require_open()$$, 'PCMD1', 'unavailable',
  'the Follow-ups personal-data gate is closed in production');
select is(pg_temp.read(5, 'select api.followups_my_tasks()'), 'PT403|unavailable|unavailable',
  'and so is My follow-ups');
select is((app.fixture_followup_source_check('{"source_type": "fixture_followup", "source_id": "00000000-0000-4000-b000-000000004601", "source_revision": 1}') ->> 'current'),
  'false', 'the SYNTHETIC source is never current in production');

select * from finish();
rollback;
