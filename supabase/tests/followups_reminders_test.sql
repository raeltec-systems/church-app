-- Remind follow-up owners and supervisors on the task schedule (story 4.7; AD-2, AD-7, AD-8,
-- AD-9), driven through the worker step (notifications.deliver_due): one reminder per logical
-- key, the assignment notice, the deadline reminder, one supervisor alert per missed deadline, a
-- recorded review-date change that moves the reminders, no old-owner reminder after
-- reassignment, nothing after Done or Closed, creator-configured reminders, snooze, the deep
-- link, generic text only, a registered SYNTHETIC source-specific schedule replacing the generic
-- one, and the owner decision on Q4 (owners from the task's own group and the Pastors). HTTP
-- evidence: tools/identity-e2e/followups-reminders.mjs. Every account, phone and name here is
-- SYNTHETIC (fictional range +44 7700 900360-900369).
begin;
select plan(91);
create temp table m (n int, member_id uuid);
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000047' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000047' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (360 + n)::text $$;
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
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.at(p_offset interval) returns text language sql as
$$ select app.cmd_utc(date_trunc('second', now()) + p_offset) $$;
create function pg_temp.d() returns uuid language sql as $$ select '00000000-0000-4000-a000-0000000047d0'::uuid $$;
create function pg_temp.src(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-b000-0000000047' || lpad(n::text, 2, '0'))::uuid $$;
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
create function pg_temp.upd(n int, p_src int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.fu(n, 'followups.update_task', (pg_temp.task(p_src)).revision,
                    jsonb_build_object('task_id', (pg_temp.task(p_src)).task_id) || p_payload)
$$;
create function pg_temp.reassign(n int, p_src int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.fu(n, 'followups.reassign', (pg_temp.task(p_src)).revision,
                    jsonb_build_object('task_id', (pg_temp.task(p_src)).task_id) || p_payload)
$$;
-- A member's number in this suite (or '?').
create function pg_temp.who(p_member uuid) returns text language sql as
$$ select coalesce((select m.n::text from m where m.member_id = p_member), '?') $$;
-- The task's jobs in one state: "<owner|sup>:<kind>:<member n>:<hours from the task's deadline>".
create function pg_temp.jobs(p_src int, p_state text default 'pending') returns text language sql as $$
  select coalesce(string_agg(
           case j.source_type when 'followups_task' then 'owner' else 'sup' end || ':' || j.reminder_kind
           || ':' || pg_temp.who(j.recipient_member_id) || ':'
           || case when j.reminder_kind = 'followup_assigned' then 'now'
                   else round(extract(epoch from j.scheduled_at - coalesce(t.review_at, t.due_at)) / 3600)::text end,
           ',' order by j.source_type desc, j.reminder_kind, j.scheduled_at), '-')
    from app.notifications_jobs j join app.followups_tasks t on t.task_id = j.source_id
   where t.source_id = pg_temp.src(p_src) and j.job_state = p_state and j.snoozed_from_item_id is null
$$;
-- The reasons the task's cancelled jobs carry.
create function pg_temp.cancelled(p_src int) returns text language sql as $$
  select coalesce(string_agg(distinct j.cancel_reason, ',' order by j.cancel_reason), '-')
    from app.notifications_jobs j join app.followups_tasks t on t.task_id = j.source_id
   where t.source_id = pg_temp.src(p_src) and j.job_state = 'cancelled'
$$;
-- Make the task's pending jobs of one kind due now (the worker then takes them).
create function pg_temp.due_now(p_src int, p_kind text) returns int language sql as $$
  with u as (update app.notifications_jobs j set scheduled_at = now() - interval '1 second'
              from app.followups_tasks t
             where t.task_id = j.source_id and t.source_id = pg_temp.src(p_src)
               and j.job_state = 'pending' and j.reminder_kind = p_kind returning 1)
  select count(*)::int from u
$$;
-- A member's inbox items of the task's reminder kinds.
create function pg_temp.items(n int, p_kind text) returns int language sql as $$
  select count(*)::int from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id
   where i.recipient_member_id = pg_temp.mid(n) and j.reminder_kind = p_kind
     and j.source_type in ('followups_task', 'followups_supervision')
$$;
create function pg_temp.item(n int, p_src int, p_kind text) returns uuid language sql as $$
  select i.item_id from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id
    join app.followups_tasks t on t.task_id = j.source_id
   where i.recipient_member_id = pg_temp.mid(n) and j.reminder_kind = p_kind
     and t.source_id = pg_temp.src(p_src)
   order by i.delivered_at desc limit 1
$$;

-- Accounts: 1 Admin; 2 leader L of D; 3 deputy P of D; 4 member M of D; 5 member O of D;
-- 6 (no account) accountless member X of D; 7 Pastor (not in D); 8 member Y outside D (no
-- role); 9 a former Pastor (role revoked). D is the SYNTHETIC department; its members are M, O
-- and X.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n <> 6;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n <> 6;
select app.platform_set_environment('local', 'pgtap 4.7');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.7 Member ' || n, 'pgtap 4.7')
  from generate_series(1, 9) n where n <> 6;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.7 Accountless', 'approved', true) returning member_id)
insert into m select 6, member_id from ins;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values
  (pg_temp.mid(7), 'pastor', 'israel'), (pg_temp.mid(9), 'pastor', 'israel');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where member_id = pg_temp.mid(9) and role = 'pastor';
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator) values
  (pg_temp.mid(2), 'department_leader', pg_temp.d(), 'israel'),
  (pg_temp.mid(3), 'department_deputy', pg_temp.d(), 'israel');
insert into app.duties_departments (department_id, name, is_synthetic, created_by_member, created_by_account)
values (pg_temp.d(), 'SYNTHETIC 4.7 Preaching Rota', true, pg_temp.mid(1), pg_temp.u(1));
insert into app.duties_department_members (department_id, member_id, added_by_member, added_by_account)
select pg_temp.d(), pg_temp.mid(n), pg_temp.mid(1), pg_temp.u(1) from unnest(array[4, 5, 6]) n;

-- Structure and contracts ----------------------------------------------------------------------
select is((select string_agg(source_type || ':' || reminder_kind || ':' || (contract ->> 'link'), ','
                             order by source_type, reminder_kind)
             from (select c.source_type, c.reminder_kind,
                          jsonb_build_object('link', c.link) as contract
                     from app.contract_reminder_contracts c
                    where c.source_type in ('followups_task', 'followups_supervision')) x),
  'followups_supervision:followup_overdue:/followups/tasks/{source_id},'
  'followups_task:followup_assigned:/followups/tasks/{source_id},'
  'followups_task:followup_due:/followups/tasks/{source_id}',
  'three reminder kinds on two Follow-ups sources, each deep-linking to the task');
select is((select string_agg(c.title || ' / ' || c.body, ' | ' order by c.reminder_kind)
             from app.contract_reminder_contracts c
            where c.source_type in ('followups_task', 'followups_supervision')),
  'New follow-up task / A follow-up task was assigned to you. Open it to see the next action. | '
  'Follow-up task due / A follow-up task is due. Open it to record progress or set a review date. | '
  'Follow-up task overdue / A follow-up task you supervise is overdue. Open it to follow up with its owner.',
  'the titles and bodies are fixed generic text');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname in ('app', 'api') and p.proname ~ '^followups_'
     and not (p.proname in ('followups_command', 'followups_my_tasks', 'followups_task',
                            'followups_supervision', 'followups_admin_routing')
              and r = 'authenticated')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'no new client entry point: the reminder functions are server-side only');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.followups_reminder_schedules', p)),
  'no client role has any privilege on the schedule registry');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select string_agg(purpose || ':' || on_assignment || ':' || owner_reminders::text || ':'
                             || supervisor_reminders::text, ',')
             from app.followups_reminder_schedules),
  'synthetic_report_due:false:'
  || '[{"anchor": "deadline", "before": "0 minutes"}, {"after": "2 days", "anchor": "deadline"}]:[]',
  'the SYNTHETIC source registered its own schedule for synthetic_report_due') ;

-- Registration refusals (PCTR1) ------------------------------------------------------------------
select throws_ok($$select app.followups_register_reminder_schedule('followups', 'fixture_followup',
    'synthetic_check_in', '{"owner": [], "supervisor": [], "on_assignment": true}')$$,
  'PCTR1', null, 'only the source''s owner registers its schedule');
select throws_ok($$select app.followups_register_reminder_schedule('fixture', 'fixture_followup',
    'synthetic_check_in', '{"owner": [{"anchor": "starts_at", "before": "1 hour"}], "supervisor": [], "on_assignment": true}')$$,
  'PCTR1', null, 'specs anchor on the task deadline');
select throws_ok($$select app.followups_register_reminder_schedule('fixture', 'fixture_followup',
    'synthetic_check_in', '{"owner": [], "on_assignment": true}')$$,
  'PCTR1', null, 'the config names owner, supervisor and on_assignment');

-- Create: the generic schedule -------------------------------------------------------------------
select is(pg_temp.new_task(2, pg_temp.mid(4), 1) #>> '{data,state}', 'open', 'the leader creates a task for M');
select is(pg_temp.jobs(1),
  'owner:followup_assigned:4:now,owner:followup_due:4:0,sup:followup_overdue:2:24',
  'M gets an assignment notice and a reminder at the deadline; L an alert a day after it');
select is((select schedule_revision || '|' || coalesce(reminders::text, 'null') from app.followups_tasks
            where source_id = pg_temp.src(1)), '1|null', 'reminders start at revision 1 with the church default');
select is((select v #>> '{reminders,schedule}' || '|' || coalesce(v #>> '{reminders,owner}', 'null') || '|'
                  || (v #>> '{reminders,supervisor}') || '|' || (v #>> '{reminders,on_assignment}')
             from (select pg_temp.readj(4, format('select api.followups_task(%L)', (pg_temp.task(1)).task_id)) -> 'task' as v) y),
  'default|null|[{"after": "1 day", "anchor": "deadline"}]|true', 'the owner sees which reminders apply');

-- Worker: the assignment notice --------------------------------------------------------------------
select is(pg_temp.run() ->> 'delivered', '1', 'the worker delivers the assignment notice');
select is(pg_temp.run() ->> 'delivered', '0', 'a second run delivers nothing (one item per logical key)');
select is(pg_temp.items(4, 'followup_assigned'), 1, 'M has one assignment item');
select is((select v ->> 'state' || '|' || (v ->> 'target') || '|' || (v ->> 'title')
             from (select pg_temp.readj(4, format('select api.notifications_open_item(%L)',
                     pg_temp.item(4, 1, 'followup_assigned'))) as v) y),
  'current|/followups/tasks/' || (pg_temp.task(1)).task_id || '|New follow-up task',
  'opening it is current and deep-links to the task');
select ok((select v::text !~ 'SYNTHETIC: phone' and v::text !~ 'SYNTHETIC 4.7'
             from (select pg_temp.readj(4, 'select api.notifications_my_inbox()') as v) y),
  'the inbox carries no next action and no names');

-- A missed deadline: the owner's reminder, then exactly one supervisor alert -------------------------
update app.followups_tasks set due_at = now() - interval '25 hours' where source_id = pg_temp.src(1);
select is(pg_temp.due_now(1, 'followup_due') + pg_temp.due_now(1, 'followup_overdue'), 2,
  'the deadline and the day after it have passed (time moved in the test)');
select is(pg_temp.run() ->> 'delivered', '2', 'the worker delivers M''s due reminder and L''s overdue alert');
select is(pg_temp.items(2, 'followup_overdue') || '|' || pg_temp.items(4, 'followup_due'), '1|1',
  'one alert to the supervisor and one reminder to the owner');
select is(pg_temp.upd(4, 1, '{"status": "in_progress"}') #>> '{data,state}', 'in_progress',
  'M marks the task in progress (the deadline does not move)');
select is((select count(*)::int from app.notifications_jobs j where j.source_id = (pg_temp.task(1)).task_id
            and j.reminder_kind = 'followup_overdue'), 1, 're-planning never creates a second alert for that deadline');
select is(pg_temp.run() ->> 'delivered', '0', 'and the worker sends nothing more');
select is((select v ->> 'scheduled_at' is not null from (select app.notifications_snooze_item(
             pg_temp.mid(4), pg_temp.item(4, 1, 'followup_due'), '1 hour') as v) y), true,
  'M snoozes the due reminder for an hour');

-- Waiting with a review date: recorded, and the reminders move -----------------------------------------
select is(pg_temp.upd(4, 1, jsonb_build_object('status', 'waiting', 'review_at', pg_temp.at('2 days'))) #>> '{data,state}',
  'waiting', 'M moves the task to Waiting with a review date');
select is((select schedule_revision || '|' || (due_at < now()) from app.followups_tasks
            where source_id = pg_temp.src(1)), '2|true', 'the reminders move to revision 2; the original due date stays');
select is(pg_temp.jobs(1), 'owner:followup_due:4:0,sup:followup_overdue:2:24',
  'the reminder now follows the review date, and the supervisor alert a day after it');
select is(pg_temp.cancelled(1), 'source_revised', 'M''s pending snooze of the old deadline is cancelled');
select is((select string_agg(a.action, ',' order by a.activity_id) from app.followups_activity a
            where a.task_id = (pg_temp.task(1)).task_id and a.review_at is not null),
  'status_changed', 'the move to Waiting records the review date');
select is(pg_temp.upd(4, 1, jsonb_build_object('review_at', pg_temp.at('4 days'))) ->> 'revision', '4',
  'M changes the review date');
select is((select a.action || '|' || (a.review_at = date_trunc('second', now()) + interval '4 days') from app.followups_activity a
            where a.task_id = (pg_temp.task(1)).task_id order by a.activity_id desc limit 1),
  'review_date_set|true', 'the review-date change is recorded, not a silent reset');
select is((select schedule_revision from app.followups_tasks where source_id = pg_temp.src(1)), 3::bigint,
  'and moves the reminders again');
select is(pg_temp.jobs(1), 'owner:followup_due:4:0,sup:followup_overdue:2:24', 'one reminder and one alert for the new date');
select is(pg_temp.cancelled(1), 'rescheduled,source_revised', 'the old date''s reminders were cancelled, not sent');
select is((select pg_temp.readj(4, format('select api.notifications_open_item(%L)', pg_temp.item(4, 1, 'followup_due'))) ->> 'state'),
  'superseded', 'the reminder of the old deadline opens out of date');
select is((select pg_temp.upd(4, 1, '{"note": "SYNTHETIC: left a message", "outcome": "unreachable"}') #>> '{data,state}'),
  'waiting', 'a note and an outcome are recorded');
select is((select schedule_revision from app.followups_tasks where source_id = pg_temp.src(1)), 3::bigint,
  'and leave the reminders alone');

-- Reassignment: the old owner's reminders go, the new owner's come ------------------------------------
select is(pg_temp.reassign(2, 1, jsonb_build_object('owner_member_id', pg_temp.mid(5))) #>> '{data,state}', 'waiting',
  'L reassigns the task to O');
select is(pg_temp.jobs(1), 'owner:followup_assigned:5:now,owner:followup_due:5:0,sup:followup_overdue:2:24',
  'O gets the assignment notice and the reminder; M has nothing pending');
select ok(pg_temp.cancelled(1) ~ 'reassigned', 'M''s pending reminder was cancelled `reassigned`');
select is(pg_temp.run() ->> 'delivered', '1', 'the worker delivers O''s assignment notice');
select is(pg_temp.items(5, 'followup_assigned') || '|' || pg_temp.items(4, 'followup_assigned'), '1|1',
  'O has the notice; M has only the one from before');
select is(pg_temp.readj(4, format('select api.notifications_open_item(%L)', pg_temp.item(4, 1, 'followup_assigned'))) ->> 'state',
  'superseded', 'M''s old notice opens out of date (no longer their task)');
-- A pending job of the old owner that escaped cancellation is still refused by the recheck.
insert into app.notifications_jobs (source_type, source_id, source_revision, recipient_member_id, reminder_kind,
                                    scheduled_at, policy_source, policy_digest, policy_version)
select 'followups_task', t.task_id, t.schedule_revision, pg_temp.mid(4), 'followup_due', now() - interval '2 seconds',
       'fixture', repeat('0', 64), 1 from app.followups_tasks t where t.source_id = pg_temp.src(1);
select is(pg_temp.run() ->> 'ineligible', '1', 'a stray old-owner job is ineligible at the worker');
select is(pg_temp.items(4, 'followup_due'), 1, 'and M gets no new reminder');

-- A new supervisor takes over the alert --------------------------------------------------------------
select is(pg_temp.reassign(2, 1, jsonb_build_object('supervisor_member_id', pg_temp.mid(3))) #>> '{data,state}', 'waiting',
  'L hands the supervision to the deputy P');
select is(pg_temp.jobs(1), 'owner:followup_due:5:0,sup:followup_overdue:3:24',
  'the alert now goes to P (O''s notice was already delivered)');
select ok(pg_temp.cancelled(1) ~ 'supervisor_changed', 'L''s alert was cancelled `supervisor_changed`');

-- Done: nothing is sent after it ---------------------------------------------------------------------
select is(pg_temp.upd(5, 1, '{"status": "done"}') #>> '{data,state}', 'done', 'O marks the task Done');
select is(pg_temp.jobs(1), '-', 'no reminder of the task is pending');
select ok(pg_temp.cancelled(1) ~ 'task_done', 'they were cancelled `task_done`');
select is((select app.followups_reminder_check(jsonb_build_object(
             'source_type', 'followups_task', 'source_id', t.task_id, 'source_revision', t.schedule_revision,
             'recipient_member_id', t.owner_member_id, 'reminder_kind', 'followup_due',
             'scheduled_at', app.cmd_utc(now()))) ->> 'current'
             from app.followups_tasks t where t.source_id = pg_temp.src(1)), 'false',
  'the source is no longer current, so nothing could be delivered either');
select is(pg_temp.run() ->> 'delivered', '0', 'the worker sends nothing after Done');

-- Closed, and a closing source event ---------------------------------------------------------------
select is(pg_temp.new_task(2, pg_temp.mid(4), 2) #>> '{data,state}', 'open', 'a second task for M');
select is(pg_temp.upd(4, 2, '{"status": "closed", "close_reason": "SYNTHETIC: no longer needed"}') #>> '{data,state}',
  'closed', 'M closes it');
select is(pg_temp.jobs(2) || '|' || pg_temp.cancelled(2), '-|task_closed', 'Closed cancels every reminder');
select is(pg_temp.new_task(2, pg_temp.mid(4), 3) #>> '{data,state}', 'open', 'a third task for M');
select is((app.followups_source_event(jsonb_build_object('source_type', 'fixture_followup',
             'source_id', pg_temp.src(3), 'event', 'resolved')) ->> 'closed'), '1', 'its source resolves it');
select is(pg_temp.jobs(3) || '|' || pg_temp.cancelled(3), '-|source_resolved', 'and its reminders go with it');

-- Creator-configured reminders ---------------------------------------------------------------------
select is(pg_temp.new_task(2, pg_temp.mid(4), 4, '{"reminders": [{"anchor": "deadline", "before": "24 hours"},
                                                                {"anchor": "deadline", "before": "0 minutes"}]}') #>> '{data,state}',
  'open', 'the creator sets reminders 24 hours before and at the deadline');
select is(pg_temp.jobs(4),
  'owner:followup_assigned:4:now,owner:followup_due:4:-24,owner:followup_due:4:0,sup:followup_overdue:2:24',
  'the owner gets both; the supervisor alert is unchanged');
select is(pg_temp.new_task(2, pg_temp.mid(4), 5, '{"reminders": []}') #>> '{data,state}', 'open',
  'reminders can be switched off');
select is(pg_temp.jobs(5), 'owner:followup_assigned:4:now,sup:followup_overdue:2:24',
  'then only the assignment notice and the supervisor alert remain');
select is(pg_temp.new_task(2, pg_temp.mid(4), 6, '{"reminders": [{"anchor": "deadline", "before": "1 hour", "body": "x"}]}') ->> 'field_errors',
  '{"reminders": "invalid"}', 'a malformed reminder is refused');
select is((select pg_temp.readj(2, format('select api.followups_task(%L)', (pg_temp.task(4)).task_id)) #>> '{task,reminders,schedule}'),
  'custom', 'the task says its reminders were chosen by its creator');

-- The registered SYNTHETIC source-specific schedule replaces the generic one ----------------------------
create function pg_temp.open_report(p_src int, p_extra jsonb default '{}') returns jsonb language sql as $$
  select app.followups_open_task(jsonb_build_object(
    'source_type', 'fixture_followup', 'source_id', pg_temp.src(p_src), 'source_revision', 1,
    'purpose', 'synthetic_report_due', 'owner_member_id', pg_temp.mid(4),
    'supervisor_member_id', pg_temp.mid(2), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d(),
    'next_action', 'SYNTHETIC: submit the report', 'due_at', pg_temp.at('1 day'),
    'actor_member_id', pg_temp.mid(2), 'actor_account_id', pg_temp.u(2)) || p_extra)
$$;
select is(pg_temp.open_report(7) ->> 'revision', '1', 'the SYNTHETIC source opens a report task');
select is(pg_temp.jobs(7), 'owner:followup_due:4:0,owner:followup_due:4:48',
  'it follows the source''s schedule: at the deadline and two days later, no notice, no supervisor alert');
select is(pg_temp.readj(4, format('select api.followups_task(%L)', (pg_temp.task(7)).task_id)) #>> '{task,reminders,schedule}',
  'source', 'the task says its source fixed the reminders');
select throws_ok($$select pg_temp.open_report(8, '{"reminders": []}')$$, 'PCMD1', null,
  'a creator''s reminders are refused for it');
-- Registering a schedule for the check-in purpose replaces its generic schedule for new tasks.
select lives_ok($$select app.followups_register_reminder_schedule('fixture', 'fixture_followup', 'synthetic_check_in',
    '{"owner": [{"anchor": "deadline", "after": "1 hour"}], "supervisor": [{"anchor": "deadline", "after": "2 days"}],
      "on_assignment": false}')$$, 'the SYNTHETIC source registers a schedule for its check-in purpose');
select is(pg_temp.new_task(2, pg_temp.mid(4), 10) #>> '{data,state}', 'open', 'a new check-in task');
select is(pg_temp.jobs(10), 'owner:followup_due:4:1,sup:followup_overdue:2:48',
  'it follows the registered schedule instead of the generic one');
select is(pg_temp.new_task(2, pg_temp.mid(4), 11, '{"reminders": []}') ->> 'field_errors',
  '{"reminders": "fixed_by_source"}', 'and the create command refuses creator reminders for it');
select is((select x ->> 'fixed_reminders' from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') -> 'purposes') x
            where x ->> 'purpose' = 'synthetic_check_in'), 'true', 'the create form is told the reminders are fixed');

-- An accountless owner: no inbox item, the need is recorded for direct contact -------------------------
select is(pg_temp.reassign(2, 10, jsonb_build_object('owner_member_id', pg_temp.mid(6))) #>> '{data,state}', 'open',
  'L reassigns a task to the accountless member X');
select is(pg_temp.due_now(10, 'followup_due'), 1, 'X''s reminder is due');
select is(pg_temp.run() ->> 'ineligible', '1', 'the worker cannot deliver it to an account');
select is((select n.route_state from app.notifications_direct_contact_needs n
            join app.notifications_jobs j on j.job_id = n.job_id
           where j.source_id = (pg_temp.task(10)).task_id), 'unrouted',
  'the need is recorded (no direct-contact route yet); the supervisor alert still follows');

-- Owner decision Q4: owners from the task's own group and the current Pastors ------------------------
select is(pg_temp.new_task(2, pg_temp.mid(7), 12) #>> '{data,state}', 'open', 'a Pastor outside D may own a task of D');
select is(pg_temp.jobs(12), 'owner:followup_due:7:1,sup:followup_overdue:2:48',
  'the Pastor gets the owner''s reminders');
select is((select x ->> 'capacity' from jsonb_array_elements(pg_temp.readj(7, 'select api.followups_my_tasks()') -> 'tasks') x),
  'owner', 'the task is in the Pastor''s My follow-ups, with the owner''s rights only');
select is(pg_temp.read(7, format('select api.followups_task(%L)', (pg_temp.task(4)).task_id)),
  'PT403|forbidden|not_granted', 'the Pastor role still shows no other task');
select is(pg_temp.read(7, 'select api.followups_supervision()'), 'PT403|forbidden|not_granted',
  'and gives no supervision view');
select is(pg_temp.new_task(2, pg_temp.mid(8), 13) #>> '{field_errors,owner_member_id}', 'not_in_scope',
  'a member outside D who is not a Pastor is still refused');
select is(pg_temp.new_task(2, pg_temp.mid(9), 14) #>> '{field_errors,owner_member_id}', 'not_in_scope',
  'a former Pastor is refused');
select is(pg_temp.reassign(1, 4, jsonb_build_object('owner_member_id', pg_temp.mid(8))) #>> '{field_errors,owner_member_id}',
  'not_in_scope', 'an Admin cannot reassign to a non-Pastor outsider either');
select is(pg_temp.reassign(1, 4, jsonb_build_object('owner_member_id', pg_temp.mid(7))) #>> '{data,state}',
  'open', 'but may reassign to a Pastor');
select ok((select bool_and(x ->> 'member_id' <> pg_temp.mid(8)::text and x ->> 'member_id' <> pg_temp.mid(9)::text)
             and bool_or(x ->> 'member_id' = pg_temp.mid(7)::text)
             from jsonb_array_elements(pg_temp.readj(2, 'select api.followups_supervision()') #> '{scopes,0,candidates}') x),
  'the candidate list offers the Pastor and no other outsider');

select * from finish();
rollback;
