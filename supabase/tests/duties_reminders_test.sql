-- Set response deadlines and schedule creator-configured duty reminders (story 4.8; AD-2, AD-8,
-- AD-9), driven through the worker step (notifications.deliver_due): the 3.3 lead-time default
-- deadlines (a quarterly rota: 14 days; a mid-week assignment for Sunday: 48 hours; the same day:
-- Short notice), a creator's deadline and reminder offsets, the default reminders (24 hours
-- before and at the deadline, 24 hours before the start, the leaders' overdue alert), accept,
-- decline, later decline and bulk acceptance, reassignment (back to an earlier assignee too),
-- cancellation, held and accountless assignees on the leader's Needs contact list, no stale
-- reminder after any change, snooze, no quiet-hours deferral, duties.set_reminders for a date and
-- a series, reminders on create_series, a passed deadline re-planned without losing the leaders'
-- alert, generic contract text, privileges. HTTP evidence: tools/identity-e2e/duties-reminders.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900650-900669).
begin;
select plan(103);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000048' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000048' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (650 + n)::text $$;
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
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
-- A whole minute in the future, so instants survive the clients' second precision.
create function pg_temp.t(p_offset interval) returns timestamptz language sql as
$$ select date_trunc('minute', now()) + p_offset $$;
create function pg_temp.sunday(k int) returns date language sql as $$
  select ((now() at time zone 'Africa/Lusaka')::date + 4)
         + ((7 - extract(dow from (now() at time zone 'Africa/Lusaka')::date + 4)::int) % 7) + 7 * k
$$;
create function pg_temp.lt(p_date date, p_time text) returns timestamptz language sql as
$$ select (p_date + p_time::time) at time zone 'Africa/Lusaka' $$;

-- Accounts: 1 Admin; 2 leader L of D (also serves in D); 3 deputy P of D; 4 member M; 5 member O;
-- 6 member H (an account, later held); 7 Pastor; 8 accountless member X (no account); 9 a member
-- with no role.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n <> 8;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n <> 8;
select app.platform_set_environment('local', 'pgtap 4.8');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.8 Member ' || n, 'pgtap 4.8')
  from generate_series(1, 9) n where n <> 8;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 4.8 Accountless', 'approved', true) returning member_id)
insert into m select 8, member_id from ins;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.who(p uuid) returns text language sql as
$$ select coalesce((select m.n::text from m where m.member_id = p), '?') $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create function pg_temp.grant_scope(p_member int, p_kind text) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', pg_temp.d()))
$$;
select pg_temp.grant_scope(2, 'department_leader');
select pg_temp.grant_scope(3, 'department_deputy');
create function pg_temp.add(n int) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = pg_temp.d()),
    jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(n) from unnest(array[2, 4, 5, 6, 8]) n;

-- A one-off duty of D for p_member starting at p_start (no end), with p_extra; the answer.
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
-- An assignment's jobs in one state, "<m|l>:<kind>:<member n>:<hours from its deadline | now>",
-- m = the assignee's source (duties_assignment), l = the leaders' (duties_coverage).
create function pg_temp.jobs(p_id uuid, p_state text default 'pending') returns text language sql as $$
  select coalesce(string_agg(
           case j.source_type when 'duties_assignment' then 'm' else 'l' end || ':' || j.reminder_kind
           || ':' || pg_temp.who(j.recipient_member_id) || ':'
           || case when j.scheduled_at = now() then 'now'
                   else round(extract(epoch from j.scheduled_at - a.response_deadline) / 3600)::text end,
           ',' order by j.source_type, j.reminder_kind, pg_temp.who(j.recipient_member_id), j.scheduled_at), '-')
    from app.notifications_jobs j join app.duties_assignments a on a.assignment_id = j.source_id
   where j.source_id = p_id and j.job_state = p_state and j.snoozed_from_item_id is null
$$;
create function pg_temp.reasons(p_id uuid) returns text language sql as $$
  select coalesce(string_agg(distinct j.cancel_reason, ',' order by j.cancel_reason), '-')
    from app.notifications_jobs j where j.source_id = p_id and j.job_state = 'cancelled'
$$;
create function pg_temp.due_now(p_id uuid, p_kind text) returns int language sql as $$
  with t as (select j.job_id, row_number() over (order by j.scheduled_at desc, j.job_id) as rn
               from app.notifications_jobs j
              where j.source_id = p_id and j.job_state = 'pending' and j.reminder_kind = p_kind
                and j.snoozed_from_item_id is null),
       u as (update app.notifications_jobs j set scheduled_at = now() - t.rn * interval '1 second'
               from t where j.job_id = t.job_id returning 1)
  select count(*)::int from u
$$;
create function pg_temp.items(n int, p_kind text) returns int language sql as $$
  select count(*)::int from app.notifications_inbox_items i
   where i.recipient_member_id = pg_temp.mid(n) and i.reminder_kind = p_kind
$$;
create function pg_temp.board_asg(n int, p_id uuid) returns jsonb language sql as $$
  select p -> 'assignment'
    from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_leader_board()') -> 'departments') dep,
         jsonb_array_elements(dep -> 'duties') du, jsonb_array_elements(du -> 'positions') p
   where p #>> '{assignment,assignment_id}' = p_id::text
$$;
create function pg_temp.mine(n int, p_id uuid) returns jsonb language sql as $$
  select x from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_my_duties()') -> 'assignments') x
   where x ->> 'assignment_id' = p_id::text
$$;

-- Contracts, the leaders' source and the direct-contact routes ---------------------------------------
select is((select string_agg(reminder_kind || '=' || title, '; ' order by source_type, reminder_kind)
             from app.contract_reminder_contracts
            where reminder_kind in ('duty_response_due', 'duty_starting', 'duty_response_overdue',
                                    'duty_short_notice')),
  'duty_response_due=Duty answer needed; duty_starting=Duty coming up; '
  || 'duty_response_overdue=Duty answer overdue; duty_short_notice=Short-notice duty',
  'the reminder contracts carry fixed generic titles');
select is((select string_agg(distinct link, ',') from app.contract_reminder_contracts
            where source_type = 'duties_coverage'), '/duties/leader',
  'the leaders'' alerts open the Duties board (which reads the duty again)');
select is((select string_agg(reminder_kind, ',' order by reminder_kind) from app.contract_direct_contact_routes
            where source_type = 'duties_assignment' and handler = 'app.duties_record_contact_need(jsonb)'),
  'duty_assigned,duty_cancelled,duty_changed,duty_released,duty_response_due,duty_starting,duty_updated',
  'every kind an assignee is sent has the Needs contact route');
select is((select count(*)::int from information_schema.columns where table_schema = 'app'
            and table_name = 'duties_contact_needs' and column_name in ('member_id', 'reason', 'note')), 0,
  'a contact need records no member, reason or note');
select is((select count(*)::int from information_schema.routine_privileges
            where routine_schema = 'app' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role')
              and routine_name in ('duties_coverage_source_check', 'duties_coverage_reminder_check',
                                   'duties_record_contact_need', 'duties_reminders_field',
                                   'duties_default_reminders', 'duties_reminder_specs',
                                   'duties_default_deadline', 'duties_alert_recipients',
                                   'duties_needs_contact', 'duties_plan_reminders', 'duties_after_answer',
                                   'duties_set_reminders', 'duties_create_series_with_reminders')), 0,
  'the new functions are not executable by any client role');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'app' and p.proname like 'duties_%'
                         and not coalesce(p.proconfig @> array['search_path=""'], false)),
  'every Duties function sets an empty search_path');
select is(app.notifications_policy() -> 'value' -> 'quiet_hours', 'null'::jsonb,
  'the Q2 policy has no quiet hours');

-- A mid-week assignment for Sunday: the 48-hour default ----------------------------------------------
create temp table b as select pg_temp.pub('B', 4, pg_temp.t('4 days')) as r;
select is((select r #>> '{data,response}' from b), 'pending', 'a duty published without an answer-by');
select is((select (x.response_deadline = pg_temp.t('4 days') - interval '48 hours')::text || '|'
                  || x.deadline_source || '|' || x.short_notice from pg_temp.row(pg_temp.a('B')) x),
  'true|default|false', 'starting in 4 days, it takes the 48-hour default (stored, default, not short notice)');
select is(pg_temp.jobs(pg_temp.a('B')),
  'm:duty_assigned:4:now,m:duty_response_due:4:-24,m:duty_response_due:4:0,m:duty_starting:4:24,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'default reminders: 24 h before and at the deadline, 24 h before the start; leader and deputy at the deadline');
select is((select x ->> 'deadline_source' || '|' || (x ->> 'short_notice') || '|' || coalesce(x ->> 'reminders', 'null')
             from pg_temp.mine(4, pg_temp.a('B')) x),
  'default|false|null', 'My duties says the deadline is the default and the reminders are the defaults');

-- A quarterly rota: 14 days for dates 30 days or more ahead -------------------------------------------
create temp table q as select pg_temp.duties(2, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'Sunday service', 'every', 'week',
  'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'until_date', to_char(pg_temp.sunday(12), 'YYYY-MM-DD'),
  'start_time', '10:00', 'positions', jsonb_build_array('Preacher'))) as r;
create function pg_temp.sr() returns uuid language sql as $$ select (r #>> '{data,series_id}')::uuid from q $$;
create function pg_temp.so(k int) returns uuid language sql as $$
  select occurrence_id from app.duties_occurrences where series_id = pg_temp.sr()
   order by series_date offset k limit 1 $$;
create function pg_temp.sa(k int) returns uuid language sql as $$
  select a.assignment_id from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
   where s.occurrence_id = pg_temp.so(k) and a.assignment_state = 'current' $$;
create function pg_temp.plan(k int, n int) returns jsonb language sql as $$
  select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.so(k)), jsonb_build_object(
    'slot_id', (select slot_id from app.duties_slots where occurrence_id = pg_temp.so(k)), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.plan(k, 4) from unnest(array[0, 5, 12]) k;
select pg_temp.plan(k, 5) from unnest(array[1, 2]) k;
create temp table qp as select pg_temp.duties(2, 'duties.publish_drafts',
  (select revision from app.duties_series where series_id = pg_temp.sr()),
  '{"slot_count": 13}'::jsonb || jsonb_build_object('series_id', pg_temp.sr())) as r;
select is((select (r #>> '{data,assignments}') || '|' || (r #>> '{data,notices_queued}') from qp), '5|5',
  'Publish 13 draft slots without an answer-by lead time: 5 assignments, 5 notices');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
             join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
            where o.series_id = pg_temp.sr() and a.deadline_source = 'default' and not a.short_notice
              and a.response_deadline = o.starts_at - case when o.starts_at >= now() + interval '30 days'
                                                           then interval '14 days' else interval '48 hours' end),
  5, 'each date takes its own band: 14 days before when 30 days or more ahead, otherwise 48 hours');
select is((select count(*)::int from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
             join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
            where o.series_id = pg_temp.sr() and o.starts_at - a.response_deadline = interval '14 days'), 2,
  'the two dates a month or more ahead have the 14-day default (the quarterly band)');
select is(pg_temp.jobs(pg_temp.sa(12)),
  'm:duty_assigned:4:now,m:duty_response_due:4:-24,m:duty_response_due:4:0,m:duty_starting:4:312,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'the last Sunday: reminders around its 14-day deadline and one the day before the service');
create temp table give as select pg_temp.duties(2, 'duties.assign_slot', pg_temp.orev(pg_temp.so(3)), jsonb_build_object(
  'slot_id', (select slot_id from app.duties_slots where occurrence_id = pg_temp.so(3)), 'member_id', pg_temp.mid(5))) as r;
select is((select (r #>> '{data,state}') || '|' || x.deadline_source || '|'
                  || (x.response_deadline = (select o.starts_at - case when o.starts_at >= now() + interval '30 days'
                                                                       then interval '14 days' else interval '48 hours' end
                                               from app.duties_occurrences o where o.occurrence_id = pg_temp.so(3)))::text
             from give, pg_temp.row(pg_temp.sa(3)) x),
  'published|default|true', 'an unfilled published position given without an answer-by takes the default too');
select is((select r ->> 'code' from (select pg_temp.duties(2, 'duties.publish_drafts', 1, jsonb_build_object(
             'series_id', pg_temp.sr(), 'slot_count', 13, 'deadline_before', 'soon')) as r) x),
  'validation_failed', 'a malformed lead time is still refused');

-- The same day: Short notice --------------------------------------------------------------------------
create temp table c as select pg_temp.pub('C', 4, pg_temp.t('6 hours')) as r;
select is((select (x.response_deadline = now())::text || '|' || x.deadline_source || '|' || x.short_notice
             from pg_temp.row(pg_temp.a('C')) x),
  'true|default|true', 'starting in 6 hours the default has passed: Short notice, answer now');
select is(pg_temp.jobs(pg_temp.a('C')),
  'm:duty_assigned:4:now,l:duty_short_notice:2:now,l:duty_short_notice:3:now',
  'the member gets one item (the notice is the "respond now"); leader and deputy a short-notice alert now');
select is((select x ->> 'short_notice' from pg_temp.mine(4, pg_temp.a('C')) x), 'true',
  'My duties marks it Short notice');
select is(pg_temp.board_asg(2, pg_temp.a('C')) #> '{needs_contact,reasons}', '["short_notice"]'::jsonb,
  'the leader board flags it for direct contact');
select is((select (r ->> 'delivered')::int >= 3 from (select pg_temp.run() as r) x), true,
  'the worker delivers the short-notice items');
select is(pg_temp.items(2, 'duty_short_notice') || '|' || pg_temp.items(3, 'duty_short_notice') || '|'
          || pg_temp.items(4, 'duty_assigned'), '1|1|5',
  'leader and deputy each have one alert; M has the five new-duty items (B, three rota dates, C)');

-- A change at short notice: the change notice is the "respond now"
create temp table tt as select pg_temp.pub('T', 5, pg_temp.t('30 hours'), jsonb_build_object(
  'response_deadline', app.cmd_utc(pg_temp.t('20 hours')))) as r;
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('T')), jsonb_build_object(
            'occurrence_id', pg_temp.occ('T'), 'starts_at', app.cmd_utc(pg_temp.t('20 hours')))) #>> '{data,change}',
  'material', 'the leader moves duty T to 20 hours from now without an answer-by');
select is((select pg_temp.jobs(a.assignment_id) || '|' || a.short_notice from app.duties_assignments a
             join app.duties_slots s on s.slot_id = a.slot_id
            where s.occurrence_id = pg_temp.occ('T') and a.assignment_state = 'current'),
  'm:duty_changed:5:now,l:duty_short_notice:2:now,l:duty_short_notice:3:now|true',
  'Short notice again: one change notice for O, the leaders'' short-notice alert');

-- A creator's deadline and offsets ------------------------------------------------------------------
create temp table dc as select pg_temp.pub('D', 4, pg_temp.lt(pg_temp.sunday(2), '10:00'), jsonb_build_object(
  'response_deadline', app.cmd_utc(pg_temp.lt(pg_temp.sunday(2), '10:00') - interval '3 days'),
  'reminders', '[{"anchor": "response_deadline", "before": "2 days"}, {"anchor": "starts_at", "before": "2 hours"}]'::jsonb)) as r;
select is((select x.deadline_source || '|' || x.short_notice from pg_temp.row(pg_temp.a('D')) x), 'creator|false',
  'the creator''s deadline is stored as given');
select is(pg_temp.jobs(pg_temp.a('D')),
  'm:duty_assigned:4:now,m:duty_response_due:4:-48,m:duty_starting:4:70,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'the creator''s offsets replace the defaults; the leaders'' overdue alert stays');
select is((select x -> 'reminders' from pg_temp.mine(4, pg_temp.a('D')) x),
  '[{"anchor": "response_deadline", "before": "2 days"}, {"anchor": "starts_at", "before": "2 hours"}]'::jsonb,
  'My duties shows the creator''s reminders');
create temp table dn as select pg_temp.pub('N', 5, pg_temp.lt(pg_temp.sunday(2), '18:00'), '{"reminders": []}') as r;
select is(pg_temp.jobs(pg_temp.a('N')),
  'm:duty_assigned:5:now,l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'reminders [] means none for the member (the leaders'' alert is not a creator option)');
select is(pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
            'department_id', pg_temp.d(), 'member_id', pg_temp.mid(5), 'duty_name', 'Refused',
            'starts_at', app.cmd_utc(pg_temp.t('10 days')),
            'reminders', '[{"anchor": "deadline", "before": "1 day"}]'::jsonb)) -> 'field_errors',
  '{"reminders": "invalid"}'::jsonb, 'an unknown anchor is refused');
select is(pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
            'department_id', pg_temp.d(), 'member_id', pg_temp.mid(5), 'duty_name', 'Refused',
            'starts_at', app.cmd_utc(pg_temp.t('10 days')),
            'reminders', '[{"anchor": "starts_at", "before": "100 days"}]'::jsonb)) -> 'field_errors',
  '{"reminders": "out_of_range"}'::jsonb, 'an offset over the policy''s limit is refused');
select is(pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
            'department_id', pg_temp.d(), 'member_id', pg_temp.mid(5), 'duty_name', 'Refused',
            'starts_at', app.cmd_utc(pg_temp.t('10 days')),
            'reminders', (select jsonb_agg(jsonb_build_object('anchor', 'starts_at', 'before', g || ' hours'))
                            from generate_series(1, 7) g))) -> 'field_errors',
  '{"reminders": "out_of_range"}'::jsonb, 'more reminders than the policy allows are refused');
select is(pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
            'department_id', pg_temp.d(), 'member_id', pg_temp.mid(5), 'duty_name', 'Refused',
            'starts_at', app.cmd_utc(pg_temp.t('10 days')),
            'response_deadline', app.cmd_utc(pg_temp.t('-1 hour')))) -> 'field_errors',
  '{"response_deadline": "past"}'::jsonb, 'a creator''s deadline in the past is still refused (never Short notice)');
select is((select count(*)::int from app.duties_occurrences where duty_name = 'Refused'), 0, 'refusals wrote nothing');

-- No quiet hours: a reminder at 23:30 church time stays at 23:30 ---------------------------------------
create temp table late as select pg_temp.pub('L', 5, pg_temp.lt(pg_temp.sunday(3), '18:00'), jsonb_build_object(
  'response_deadline', app.cmd_utc(pg_temp.lt(pg_temp.sunday(3) - 1, '23:30')),
  'reminders', '[{"anchor": "response_deadline", "before": "0 minutes"}]'::jsonb)) as r;
select is((select string_agg(to_char(j.scheduled_at at time zone 'Africa/Lusaka', 'HH24:MI'), ',')
             from app.notifications_jobs j where j.source_id = pg_temp.a('L') and j.reminder_kind = 'duty_response_due'),
  '23:30', 'a late-evening reminder is not deferred (no quiet hours)');

-- Accept: response reminders and leader alerts stop; the pre-service reminder stays --------------------
select is(pg_temp.answer(4, pg_temp.a('D'), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty D');
select is(pg_temp.jobs(pg_temp.a('D')), 'm:duty_starting:4:70',
  'only the pre-service reminder is left, at the new revision');
select is((select string_agg(distinct j.source_revision::text, ',') from app.notifications_jobs j
            where j.source_id = pg_temp.a('D') and j.job_state = 'pending'), '2', 'keyed to the answered revision');
select is(pg_temp.reasons(pg_temp.a('D')), 'responded', 'everything else was cancelled as responded');
select is(pg_temp.due_now(pg_temp.a('D'), 'duty_starting'), 1, 'the service is near (made due)');
select pg_temp.run();
select is(pg_temp.items(4, 'duty_starting'), 1, 'the accepted member gets the pre-service reminder');

-- Decline: everything stops ----------------------------------------------------------------------------
select is(pg_temp.answer(4, pg_temp.a('B'), 'declined') #>> '{data,response}', 'declined', 'M declines duty B');
select is(pg_temp.jobs(pg_temp.a('B')), '-', 'no reminder and no leader alert is left after a decline');

-- Later decline and bulk acceptance -------------------------------------------------------------------
select is(pg_temp.duties(4, 'duties.withdraw_acceptance', pg_temp.rev(pg_temp.a('D')),
            jsonb_build_object('assignment_id', pg_temp.a('D'))) #>> '{data,response}', 'declined',
  'M can''t make duty D anymore');
select is(pg_temp.jobs(pg_temp.a('D')), '-', 'the pre-service reminder stops too');
create temp table bulk as select pg_temp.duties(5, 'duties.accept_many', null, jsonb_build_object(
  'assignments', jsonb_build_array(
    jsonb_build_object('assignment_id', pg_temp.sa(1), 'revision', pg_temp.rev(pg_temp.sa(1))),
    jsonb_build_object('assignment_id', pg_temp.sa(2), 'revision', pg_temp.rev(pg_temp.sa(2)))))) as r;
select is((select r #>> '{data,count}' from bulk), '2', 'O accepts two dates together');
select is(pg_temp.jobs(pg_temp.sa(1)) || ' / ' || pg_temp.jobs(pg_temp.sa(2)),
  'm:duty_starting:5:24 / m:duty_starting:5:24', 'each keeps only its pre-service reminder');

-- Reassign A -> B -> A: fresh reminders every time ---------------------------------------------------
create temp table r0 as select pg_temp.pub('R', 4, pg_temp.t('10 days')) as r;
create temp table chain (step int, assignment_id uuid);
insert into chain values (0, pg_temp.a('R'));
create function pg_temp.give(n int) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('R')),
                      jsonb_build_object('occurrence_id', pg_temp.occ('R'), 'member_id', pg_temp.mid(n)));
  insert into chain values ((select max(step) + 1 from chain), (r #>> '{data,assignment_id}')::uuid);
  return r;
end;
$$;
create function pg_temp.step(k int) returns uuid language sql as $$ select assignment_id from chain where step = k $$;
select is(pg_temp.give(5) #>> '{data,change}', 'material', 'the duty goes to O (no answer-by: the default)');
select is(pg_temp.jobs(pg_temp.step(0)), 'm:duty_released:4:now', 'M''s old assignment keeps only the released notice');
select is(pg_temp.jobs(pg_temp.step(1)),
  'm:duty_assigned:5:now,m:duty_response_due:5:-24,m:duty_response_due:5:0,m:duty_starting:5:24,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0', 'O gets a fresh schedule');
select is(pg_temp.give(4) #>> '{data,change}', 'material', 'and back to M');
select is(pg_temp.jobs(pg_temp.step(1)), 'm:duty_released:5:now', 'O''s assignment keeps only the released notice');
select is(pg_temp.jobs(pg_temp.step(2)),
  'm:duty_assigned:4:now,m:duty_response_due:4:-24,m:duty_response_due:4:0,m:duty_starting:4:24,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'M is back with every reminder (a new source id: nothing collides with the cancelled keys)');
select is((select count(distinct source_id)::int from app.notifications_jobs
            where source_id in (select assignment_id from chain) and reminder_kind = 'duty_response_overdue'), 3,
  'each of the three assignments had its own leader alerts');

-- Cancel: nothing pending but the cancellation notice ------------------------------------------------
select is(pg_temp.duties(2, 'duties.cancel_occurrence', pg_temp.orev(pg_temp.so(5)),
            jsonb_build_object('occurrence_id', pg_temp.so(5))) ->> 'code', null, 'the leader cancels a rota date');
select is((select string_agg(j.source_type || ':' || j.reminder_kind, ',') from app.notifications_jobs j
            join app.duties_assignments a on a.assignment_id = j.source_id
            join app.duties_slots s on s.slot_id = a.slot_id
           where s.occurrence_id = pg_temp.so(5) and j.job_state = 'pending'),
  'duties_assignment:duty_cancelled', 'only the cancellation notice is pending');
select is((select count(*)::int from app.notifications_schedules sc
            join app.duties_assignments a on a.assignment_id = sc.source_id
            join app.duties_slots s on s.slot_id = a.slot_id
           where s.occurrence_id = pg_temp.so(5) and sc.schedule_state = 'active'), 0,
  'its schedules ended (a later re-plan cannot revive them)');

-- Held and accountless assignees reach Needs contact --------------------------------------------------
create temp table hx as select pg_temp.pub('X', 8, pg_temp.t('9 days')) as r;
create temp table hh as select pg_temp.pub('H', 6, pg_temp.t('9 days 2 hours')) as r;
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(6),
            jsonb_build_object('member_id', pg_temp.mid(6), 'reason_code', 'security_concern')) ->> 'code',
  null, 'the Admin places a hold on H');
select pg_temp.run();
select is((select string_agg(j.job_state || ':' || j.finish_reason, ',' order by j.recipient_member_id)
             from app.notifications_jobs j where j.source_id in (pg_temp.a('X'), pg_temp.a('H'))
              and j.reminder_kind = 'duty_assigned'),
  (select string_agg('ineligible:direct_contact', ',') from generate_series(1, 2)),
  'neither the accountless nor the held assignee gets an inbox item: both are direct-contact needs');
select is(pg_temp.items(6, 'duty_assigned') + pg_temp.items(8, 'duty_assigned'), 0, 'no inbox item for either');
select is((select count(*)::int from app.duties_contact_needs where assignment_id in (pg_temp.a('X'), pg_temp.a('H'))), 2,
  'both needs are on the Duties list');
select is((select count(*)::int from app.notifications_direct_contact_needs
            where source_id in (pg_temp.a('X'), pg_temp.a('H')) and route_state = 'routed'), 2,
  'Notifications records them as routed (not unrouted in Reminder health)');
select is(pg_temp.board_asg(2, pg_temp.a('X')) #> '{needs_contact,reasons}', '["not_reached"]'::jsonb,
  'the board shows the accountless assignee as Needs contact');
select is(pg_temp.board_asg(3, pg_temp.a('H')) #> '{needs_contact,reasons}', '["not_reached"]'::jsonb,
  'and the held one, without saying why');
select is(pg_temp.due_now(pg_temp.a('X'), 'duty_response_due'), 2, 'X''s response reminders fall due');
select pg_temp.run();
select is((select count(*)::int from app.duties_contact_needs where assignment_id = pg_temp.a('X')), 3,
  'each reminder that cannot reach X is a need too (idempotent per need)');
select is(app.duties_record_contact_need((select jsonb_build_object(
            'need_id', need_id, 'source_type', 'duties_assignment', 'source_id', assignment_id,
            'source_revision', source_revision, 'recipient_member_id', pg_temp.mid(8),
            'reminder_kind', reminder_kind, 'scheduled_at', scheduled_at)
             from app.duties_contact_needs where assignment_id = pg_temp.a('X') limit 1))::text, '',
  'a retried need is recorded once');
select is((select count(*)::int from app.duties_contact_needs where assignment_id = pg_temp.a('X')), 3, 'still three');
select is(pg_temp.board_asg(2, pg_temp.a('B')) -> 'needs_contact', 'null'::jsonb, 'an app member who answered needs no contact');

-- The leader is never alerted about their own duty ------------------------------------------------------
create temp table own as select pg_temp.pub('O', 2, pg_temp.t('12 days')) as r;
select is((select string_agg(distinct pg_temp.who(recipient_member_id), ',') from app.notifications_jobs
            where source_type = 'duties_coverage' and source_id = pg_temp.a('O')), '3',
  'a duty given to the leader alerts only the deputy');

-- Snooze: honoured, and stopped by the answer ------------------------------------------------------------
create temp table sz as select pg_temp.pub('S', 4, pg_temp.t('8 days')) as r;
select is(pg_temp.due_now(pg_temp.a('S'), 'duty_response_due'), 2, 'S''s response reminders fall due');
select pg_temp.run();
create temp table it as select i.item_id from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
  where j.source_id = pg_temp.a('S') and j.reminder_kind = 'duty_response_due' order by i.delivered_at limit 1;
select is(pg_temp.call(4, 'notifications_command', 'notifications.snooze_item', null,
            jsonb_build_object('item_id', (select item_id from it), 'choice', '1 hour')) ->> 'code', null,
  'M snoozes the reminder for an hour');
select is((select to_char(j.scheduled_at - now(), 'HH24:MI') from app.notifications_jobs j
            where j.snoozed_from_item_id = (select item_id from it) and j.job_state = 'pending'), '01:00',
  'only M''s copy comes back in an hour');
update app.notifications_jobs set scheduled_at = now() - interval '10 seconds'
 where snoozed_from_item_id = (select item_id from it) and job_state = 'pending';
select pg_temp.run();
select is((select count(*)::int from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
            where j.source_id = pg_temp.a('S') and j.reminder_kind = 'duty_response_due'), 3,
  'the snoozed reminder is delivered again');
create temp table it2 as select i.item_id from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
  where j.source_id = pg_temp.a('S') and j.snoozed_from_item_id is not null;
select is(pg_temp.call(4, 'notifications_command', 'notifications.snooze_item', null,
            jsonb_build_object('item_id', (select item_id from it2), 'choice', '2 days')) ->> 'code', null,
  'M snoozes it again for two days');
select is(pg_temp.answer(4, pg_temp.a('S'), 'accepted') #>> '{data,response}', 'accepted', 'then M accepts');
select is((select string_agg(j.job_state || ':' || coalesce(j.cancel_reason, '-'), ',') from app.notifications_jobs j
            where j.snoozed_from_item_id = (select item_id from it2)), 'cancelled:responded',
  'the pending snooze stops with the answer');

-- duties.set_reminders: one date ---------------------------------------------------------------------
create temp table sr1 as select pg_temp.duties(2, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('N')),
  jsonb_build_object('occurrence_id', pg_temp.occ('N'), 'reminders', null)) as r;
select is((select r #>> '{data,replanned}' from sr1), '1', 'the leader sets duty N back to the default reminders');
select is(pg_temp.jobs(pg_temp.a('N')),
  'm:duty_response_due:5:-24,m:duty_response_due:5:0,m:duty_starting:5:24,'
  || 'l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'O''s reminders are re-planned without asking O again (the delivered notice is not sent again)');
select is((pg_temp.row(pg_temp.a('N'))).revision, 1::bigint, 'the assignment revision did not move');
select is(pg_temp.duties(2, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('N')),
            jsonb_build_object('occurrence_id', pg_temp.occ('N'), 'reminders', null)) -> 'field_errors',
  '{"occurrence_id": "unchanged"}'::jsonb, 'the same reminders again is no change');
select is(pg_temp.duties(4, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('N')),
            jsonb_build_object('occurrence_id', pg_temp.occ('N'), 'reminders', '[]'::jsonb)) ->> 'code',
  'forbidden', 'a member cannot set reminders');
select is(pg_temp.duties(7, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('N')),
            jsonb_build_object('occurrence_id', pg_temp.occ('N'), 'reminders', '[]'::jsonb)) ->> 'code',
  'forbidden', 'nor can the Pastor');
select is(pg_temp.duties(2, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('N')),
            jsonb_build_object('occurrence_id', pg_temp.occ('N'))) -> 'field_errors',
  '{"reminders": "required"}'::jsonb, 'the reminders key is required (null for the defaults)');

-- duties.set_reminders: a series from a date onwards --------------------------------------------------
create temp table sr2 as select pg_temp.duties(2, 'duties.set_reminders',
  (select revision from app.duties_series where series_id = pg_temp.sr()),
  jsonb_build_object('series_id', pg_temp.sr(), 'from_occurrence_id', pg_temp.so(6),
                     'reminders', '[{"anchor": "starts_at", "before": "2 hours"}]'::jsonb)) as r;
select is((select (r #>> '{data,occurrences}') || '|' || (r #>> '{data,replanned}') from sr2), '7|1',
  'this and later dates: 7 dates changed, the one published assignment among them re-planned');
select is(pg_temp.jobs(pg_temp.sa(12)),
  'm:duty_starting:4:334,l:duty_response_overdue:2:0,l:duty_response_overdue:3:0',
  'the last Sunday now reminds M 2 hours before the start only; the leaders'' alert is unchanged');
select is((select count(*)::int from app.duties_occurrences where series_id = pg_temp.sr() and reminders is null), 6,
  'the six earlier dates keep the defaults');
select is((select reminders from app.duties_series where series_id = pg_temp.sr()),
  '[{"anchor": "starts_at", "before": "2 hours"}]'::jsonb, 'the series template records them');

-- create_series takes reminders and copies them to every date --------------------------------------
create temp table q2 as select pg_temp.duties(3, 'duties.create_series', null, jsonb_build_object(
  'department_id', pg_temp.d(), 'duty_name', 'Evening prayer', 'every', 'week',
  'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'until_date', to_char(pg_temp.sunday(3), 'YYYY-MM-DD'),
  'start_time', '18:00', 'positions', jsonb_build_array('Leader'), 'reminders', '[]'::jsonb)) as r;
select is((select count(*)::int from app.duties_occurrences
            where series_id = (select (r #>> '{data,series_id}')::uuid from q2) and reminders = '[]'::jsonb), 4,
  'the deputy creates a rota with no member reminders on every date');
select is(pg_temp.duties(3, 'duties.create_series', null, jsonb_build_object(
            'department_id', pg_temp.d(), 'duty_name', 'Evening prayer', 'every', 'week',
            'from_date', to_char(pg_temp.sunday(0), 'YYYY-MM-DD'), 'until_date', to_char(pg_temp.sunday(3), 'YYYY-MM-DD'),
            'start_time', '18:00', 'positions', jsonb_build_array('Leader'), 'reminders', '{}'::jsonb)) -> 'field_errors',
  '{"reminders": "invalid"}'::jsonb, 'malformed series reminders are refused');

-- A deadline passed before a re-plan: the leaders' alert is not lost ---------------------------------
create temp table lp as select pg_temp.pub('P', 5, pg_temp.t('11 days'), jsonb_build_object(
  'response_deadline', app.cmd_utc(pg_temp.t('5 days')))) as r;
-- Time passes beyond the deadline before the alert ran, and the alert job was lost (a test-only
-- stand-in for an operator re-plan that moved it into the past).
update app.duties_assignments set response_deadline = now() - interval '1 hour' where assignment_id = pg_temp.a('P');
update app.notifications_jobs set job_state = 'cancelled', finished_at = now(), cancel_reason = 'rescheduled'
 where source_id = pg_temp.a('P') and source_type = 'duties_coverage' and job_state = 'pending';
select is(pg_temp.duties(2, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('P')),
            jsonb_build_object('occurrence_id', pg_temp.occ('P'), 'reminders', '[]'::jsonb)) ->> 'code', null,
  'the leader changes the reminders after the deadline has passed');
select is((select string_agg(pg_temp.who(recipient_member_id) || ':' || reminder_kind, ',' order by pg_temp.who(recipient_member_id))
             from app.notifications_jobs where source_id = pg_temp.a('P') and source_type = 'duties_coverage'
              and job_state = 'pending' and scheduled_at = now()),
  '2:duty_response_overdue,3:duty_response_overdue', 'each leader gets the missed overdue alert now');
select is(pg_temp.duties(2, 'duties.set_reminders', pg_temp.orev(pg_temp.occ('P')),
            jsonb_build_object('occurrence_id', pg_temp.occ('P'), 'reminders', null)) ->> 'code', null,
  'another re-plan');
select is((select count(*)::int from app.notifications_jobs where source_id = pg_temp.a('P')
            and source_type = 'duties_coverage' and job_state = 'pending'), 2, 'adds no second alert');

-- Leader alerts are delivered at the deadline; revoked leaders are not alerted ------------------------
select is(pg_temp.due_now(pg_temp.a('N'), 'duty_response_overdue'), 2, 'duty N''s deadline passes unanswered');
select pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(3)),
  jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'department_deputy', 'scope_id', pg_temp.d()));
select pg_temp.run();
select is((select string_agg(pg_temp.who(recipient_member_id) || ':' || job_state, ',' order by pg_temp.who(recipient_member_id))
             from app.notifications_jobs where source_id = pg_temp.a('N') and reminder_kind = 'duty_response_overdue'),
  '2:delivered,3:ineligible', 'the leader is alerted; the former deputy is not');

-- No stale reminder after any change -----------------------------------------------------------------
select is((select count(*)::int from app.notifications_jobs j join app.duties_assignments a on a.assignment_id = j.source_id
            where j.job_state = 'pending'
              and j.reminder_kind in ('duty_response_due', 'duty_starting', 'duty_response_overdue', 'duty_short_notice')
              and (a.assignment_state <> 'current' or j.source_revision <> a.revision or a.response = 'declined'
                   or (j.reminder_kind <> 'duty_starting' and a.response <> 'pending'))), 0,
  'no pending reminder or alert belongs to an ended, re-revised, declined or answered assignment');
select is((select count(*)::int from app.notifications_jobs j
            where j.job_state = 'pending' and j.source_type = 'duties_coverage'
              and not exists (select 1 from app.duties_assignments a where a.assignment_id = j.source_id
                                and a.response = 'pending' and a.assignment_state = 'current')), 0,
  'no leader alert waits on an answered or ended assignment');
select is((select count(*)::int from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
            where j.source_type in ('duties_assignment', 'duties_coverage')
              and j.reminder_kind in ('duty_response_due', 'duty_starting', 'duty_response_overdue', 'duty_short_notice')
              and (select count(*) from app.contract_reminder_contracts rc
                    where rc.source_type = j.source_type and rc.reminder_kind = j.reminder_kind) <> 1), 0,
  'every delivered duty reminder has exactly one generic contract');

-- History guard and vocabulary ------------------------------------------------------------------------
select throws_ok(format('update app.duties_assignments set short_notice = true, deadline_source = %L where assignment_id = %L',
                        'default', pg_temp.step(0)),
  'P0001', 'ended duties assignments are immutable', 'an ended assignment''s deadline facts cannot change');
select throws_ok(format('update app.duties_assignments set short_notice = true where assignment_id = %L', pg_temp.a('D')),
  '23514', null, 'Short notice is only ever a default deadline');
select ok(app.duties_state_ok('audit_action', 'reminders_set') and app.duties_state_ok('audit_action', 'acceptance_withdrawn')
          and app.duties_state_ok('deadline_source', 'default') and not app.duties_state_ok('deadline_source', 'leader'),
  'the vocabularies gain reminders_set and the deadline sources and keep the 4.5 actions');
select is((select count(*)::int from app.duties_audit where action = 'reminders_set'), 4,
  'every reminder change is audited (ids and codes only)');

select * from finish();
rollback;
