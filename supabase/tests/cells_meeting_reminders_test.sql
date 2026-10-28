-- Meeting reminders and change notices (story 5.2; epic 5 C2, C1; AD-2, AD-8, AD-9, AD-14), and
-- the 5.1 review fixes carried by the 5.2 migration. The `cells_meeting` source with generic
-- text, start reminders per confirmed member through the 3.3 calculation, the cell's reminders
-- set by its leader or an Admin, notices on move, cancel and bring back in the same
-- transaction, the transfer and direct-contact cases, and the deletion hook. Worker delivery,
-- snooze and the inbox over HTTP: tools/identity-e2e/cells-meeting-reminders.mjs. Every account,
-- phone and name here is SYNTHETIC (fictional range +1 202 555 0160-0169).
begin;
select plan(70);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000052' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000052' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (60 + n)::text $$;
create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.cmd(p_claims jsonb, p_fn text, p_command text, p_expected bigint,
                            p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb language plpgsql as $$
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
create function pg_temp.cells(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$
  select pg_temp.cmd(p_claims, 'api.cells_command', p_command, p_expected, p_payload)
$$;
create function pg_temp.read(p_claims jsonb, p_sql text) returns text language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
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
create function pg_temp.readj(p_claims jsonb, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(p_claims, p_sql), 4)::jsonb $$;
create function pg_temp.staff(n int) returns jsonb language sql as
$$ select pg_temp.readj(pg_temp.c(n), 'select api.cells_meetings()') $$;

-- Fixtures. 1 Admin, 2 leader of Shikoswe, 3 assistant of Shikoswe, 4 member of Shikoswe,
-- 5 member of Estates (and later moved into Shikoswe and out again), 6 an accountless member of
-- Shikoswe (no login).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 5) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 5) n;

-- Registration ----------------------------------------------------------------------------------
select is((select string_agg(k.reminder_kind, ',' order by k.reminder_kind) from app.contract_reminder_kinds k
            where k.source_type = 'cells_meeting'),
  'cells_meeting_cancelled,cells_meeting_changed,cells_meeting_reminder',
  'Cells registers the meeting source with one reminder and two notices');
select is((select count(*)::int from app.contract_reminder_contracts c
            where c.source_type = 'cells_meeting' and c.link = '/my-cell'
              and c.title !~ '[0-9]' and c.body !~* '(road|street|hall|SYNTHETIC)'), 3,
  'every contract has generic text (no venue, no time) and opens My cell');
select is((select count(*)::int from app.contract_direct_contact_routes r where r.source_type = 'cells_meeting'), 3,
  'every meeting kind routes held and accountless members to the leader');
select ok(not exists (
  select 1 from unnest(array['app.cells_meeting_contact_needs']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not has_function_privilege('authenticated', 'app.cells_plan_meeting(uuid, text)', 'EXECUTE'),
  'the contact-needs table and the planning functions are server-only');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Environment, members, cells, roles and confirmed memberships ---------------------------------------
select app.platform_set_environment('local', 'pgtap 5.2');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.2 Member ' || n, 'pgtap 5.2') as member_id
  from generate_series(1, 5) n;
with x as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 5.2 Accountless', 'approved', true) returning member_id)
insert into m select 6, member_id from x;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

create temp table cs as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC Shikoswe Cell", "signup_label": "SYNTHETIC Shikoswe", "broad_area": "SYNTHETIC Kafue East"}') as r;
create temp table ce as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC Estates C5/C7 Cell", "signup_label": "SYNTHETIC Estates", "broad_area": "SYNTHETIC Estates"}') as r;
create function pg_temp.sh() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cs $$;
create function pg_temp.es() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from ce $$;
create function pg_temp.cell_rev(p_cell uuid) returns bigint language sql as
$$ select revision from app.cells_cells where cell_id = p_cell $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_cell uuid) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_cell))
$$;
select pg_temp.grant_scope(2, 'cell_leader', pg_temp.sh());
select pg_temp.grant_scope(3, 'cell_assistant', pg_temp.sh());
create function pg_temp.place(p_member int, p_cell uuid) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.cells(pg_temp.c(1), 'cells.request_change',
         coalesce((select revision from app.cells_member_states where member_id = pg_temp.mid(p_member)), 1),
         jsonb_build_object('member_id', pg_temp.mid(p_member), 'cell_id', p_cell,
                            'cell_revision', app.cells_option_revision(p_cell)));
  return pg_temp.cells(pg_temp.c(1), 'cells.confirm_request',
           (select revision from app.cells_member_states where member_id = pg_temp.mid(p_member)),
           jsonb_build_object('request_id', r #>> '{data,open_request,request_id}'));
end;
$$;
select pg_temp.place(4, pg_temp.sh());
select pg_temp.place(6, pg_temp.sh());
select pg_temp.place(5, pg_temp.es());

-- Normal week ---------------------------------------------------------------------------------------
create function pg_temp.wd() returns int language sql as
$$ select ((extract(isodow from (now() at time zone 'Africa/Lusaka')::date)::int + 1) % 7) + 1 $$;
create function pg_temp.sched(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('cell_id', pg_temp.sh(), 'weekday', pg_temp.wd(), 'start_time', '18:00',
                            'end_time', '19:30', 'venue', 'SYNTHETIC 12 Shikoswe Road') || p_extra
$$;
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"map_pin": {"lng": 28}}')) -> 'field_errors', '{"map_pin": "invalid"}'::jsonb,
  '5.1 review fix: a pin without lat is validation_failed, not an error');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"map_pin": {}}')) -> 'field_errors', '{"map_pin": "invalid"}'::jsonb,
  '5.1 review fix: an empty pin is invalid');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()), pg_temp.sched());

create function pg_temp.first_id() returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date limit 1 $$;
create function pg_temp.nth_id(k int) returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date offset k limit 1 $$;
create function pg_temp.jobs(p_meeting uuid, p_kind text, p_state text default 'pending') returns int language sql as $$
  select count(*)::int from app.notifications_jobs j
   where j.source_type = 'cells_meeting' and j.source_id = p_meeting and j.reminder_kind = p_kind
     and j.job_state = p_state
$$;
create function pg_temp.reminder_at(p_meeting uuid, p_member int) returns timestamptz language sql as $$
  select j.scheduled_at from app.notifications_jobs j
   where j.source_type = 'cells_meeting' and j.source_id = p_meeting and j.reminder_kind = 'cells_meeting_reminder'
     and j.job_state = 'pending' and j.recipient_member_id = pg_temp.mid(p_member)
$$;
select is(pg_temp.jobs(pg_temp.first_id(), 'cells_meeting_reminder'), 2,
  'normal week: one reminder per confirmed member (with and without a login)');
select is(pg_temp.reminder_at(pg_temp.first_id(), 4),
  (select starts_at - interval '24 hours' from app.cells_meetings where meeting_id = pg_temp.first_id()),
  'the default reminder is 24 hours before the start');
select is((select count(distinct j.recipient_member_id)::int from app.notifications_jobs j
            where j.source_type = 'cells_meeting' and j.job_state = 'pending'
              and j.recipient_member_id in (pg_temp.mid(2), pg_temp.mid(3), pg_temp.mid(5))), 0,
  'the leader and assistant (not members) and the other cell''s member get no Shikoswe reminder');
select ok((select count(distinct j.source_id) from app.notifications_jobs j
            where j.source_type = 'cells_meeting' and j.reminder_kind = 'cells_meeting_reminder'
              and j.job_state = 'pending') >= 12,
  'every generated meeting is planned');
select is(app.notifications_response_kinds('{"starts_at": "cells_meeting_reminder"}'::jsonb), '{}'::text[],
  'the meeting reminder is not a response kind, so members can snooze it');

-- Leader-changed reminders ----------------------------------------------------------------------------
create function pg_temp.rrev() returns bigint language sql as
$$ select reminders_revision from app.cells_meeting_schedules where cell_id = pg_temp.sh() $$;
select is(pg_temp.cells(pg_temp.c(3), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[{"before": "2 hours"}]'::jsonb)) ->> 'code',
  'forbidden', 'the assistant cannot change the reminders');
select is(pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[{"before": "8 days"}]'::jsonb)) -> 'field_errors',
  '{"reminders": "out_of_range"}'::jsonb, 'a reminder more than 7 days ahead is refused');
select is(pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[{"after": "2 hours"}]'::jsonb)) -> 'field_errors',
  '{"reminders": "invalid"}'::jsonb, 'a reminder after the start is refused');
select is(pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', 9,
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[{"before": "2 hours"}]'::jsonb)) ->> 'code',
  'conflict', 'a stale reminders revision is a conflict');
select is((pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[{"before": "2 hours"}]'::jsonb))) #>> '{data,reminders_revision}',
  '2', 'the leader changes the cell''s reminders');
select is(pg_temp.reminder_at(pg_temp.first_id(), 4),
  (select starts_at - interval '2 hours' from app.cells_meetings where meeting_id = pg_temp.first_id()),
  'the members'' reminders move to 2 hours before');
select is(pg_temp.jobs(pg_temp.first_id(), 'cells_meeting_reminder', 'cancelled'), 2,
  'the old 24-hour reminders are cancelled');
select is((select x #>> '{schedule,reminders,0,before}' || '|' || (x #>> '{schedule,reminders_default}')
             from (select c from jsonb_array_elements(pg_temp.staff(2) -> 'cells') c
                    where (c ->> 'cell_id')::uuid = pg_temp.sh()) q(x)),
  '2 hours|false', 'the staff read shows the cell''s reminders');

-- Move: new reminders and a notice in the same transaction ------------------------------------------
create function pg_temp.rev(p_meeting uuid) returns bigint language sql as
$$ select revision from app.cells_meetings where meeting_id = p_meeting $$;
create temp table moved as select pg_temp.nth_id(1) as id;
create temp table mv as select pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', pg_temp.rev((select id from moved)),
  jsonb_build_object('meeting_id', (select id from moved),
    'starts_at', app.cmd_utc((select nominal_starts_at + interval '1 day' from app.cells_meetings where meeting_id = (select id from moved))),
    'ends_at', app.cmd_utc((select nominal_ends_at + interval '1 day' from app.cells_meetings where meeting_id = (select id from moved))),
    'venue', 'SYNTHETIC Church hall')) as r;
select is((select r #>> '{data,state}' from mv), 'moved', 'the leader moves a meeting');
select is(pg_temp.reminder_at((select id from moved), 4),
  (select starts_at - interval '2 hours' from app.cells_meetings where meeting_id = (select id from moved)),
  'its reminder follows the new time');
select ok(not exists (select 1 from app.notifications_jobs j
                       where j.source_type = 'cells_meeting' and j.source_id = (select id from moved)
                         and j.reminder_kind = 'cells_meeting_reminder' and j.job_state = 'pending'
                         and j.scheduled_at = (select nominal_starts_at - interval '2 hours'
                                                 from app.cells_meetings where meeting_id = (select id from moved))),
  'no reminder is left for the moved-away time');
select is(pg_temp.jobs((select id from moved), 'cells_meeting_changed'), 2,
  'every confirmed member gets one change notice, due now');

-- Cancel (the 5.1 review fix: a moved meeting with its own venue can be cancelled) -------------
create temp table cx as select pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev((select id from moved)),
  jsonb_build_object('meeting_id', (select id from moved))) as r;
select is((select r #>> '{data,state}' || '|' || (r #>> '{data,venue_moved}') from cx), 'cancelled|false',
  '5.1 review fix: a meeting moved to another venue can be cancelled');
select is(pg_temp.jobs((select id from moved), 'cells_meeting_reminder'), 0,
  'a cancelled meeting has no reminder left');
select is(pg_temp.jobs((select id from moved), 'cells_meeting_cancelled'), 2,
  'every confirmed member gets one cancellation notice');
select is((select string_agg(distinct j.cancel_reason, ',') from app.notifications_jobs j
            where j.source_type = 'cells_meeting' and j.source_id = (select id from moved)
              and j.reminder_kind = 'cells_meeting_reminder' and j.job_state = 'cancelled'),
  'rescheduled,source_cancelled', 'the moved-away reminders were rescheduled and the rest cancelled as source_cancelled');

-- Bring back -------------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(2), 'cells.reinstate_meeting', pg_temp.rev((select id from moved)),
  jsonb_build_object('meeting_id', (select id from moved))) #>> '{data,state}', 'scheduled',
  'the leader brings it back');
select ok(pg_temp.jobs((select id from moved), 'cells_meeting_reminder') = 2
          and pg_temp.jobs((select id from moved), 'cells_meeting_changed') = 2
          and pg_temp.jobs((select id from moved), 'cells_meeting_cancelled') = 0,
  'reminders are planned again, a change notice goes out and the waiting cancellation notice is withdrawn');

-- The reminder check -----------------------------------------------------------------------------
create function pg_temp.check(p_meeting uuid, p_member int, p_kind text) returns jsonb language sql as $$
  select app.cells_meeting_reminder_check(jsonb_build_object(
    'source_type', 'cells_meeting', 'source_id', p_meeting, 'source_revision', pg_temp.rev(p_meeting),
    'recipient_member_id', pg_temp.mid(p_member), 'reminder_kind', p_kind,
    'scheduled_at', app.cmd_utc(now())))
$$;
select is(pg_temp.check(pg_temp.first_id(), 4, 'cells_meeting_reminder'),
  '{"current": true, "revision": 1, "actionable": true, "recipient_eligible": true}'::jsonb,
  'a confirmed member''s reminder is current, actionable and eligible');
select is(pg_temp.check(pg_temp.first_id(), 5, 'cells_meeting_reminder') ->> 'recipient_eligible', 'false',
  'a member of another cell is not eligible');

-- Transfer out ------------------------------------------------------------------------------------
select pg_temp.place(4, pg_temp.es());
select is(pg_temp.check(pg_temp.first_id(), 4, 'cells_meeting_reminder') ->> 'recipient_eligible', 'false',
  'after a transfer out the reminder is no longer eligible (the worker ends it)');
select pg_temp.staff(2);
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'cells_meeting' and j.recipient_member_id = pg_temp.mid(4)
              and j.reminder_kind = 'cells_meeting_reminder' and j.job_state = 'pending'), 0,
  'the next sync ends the transferred member''s Shikoswe reminders');

-- Direct contact --------------------------------------------------------------------------------
select app.cells_record_meeting_contact_need(jsonb_build_object(
  'need_id', '00000000-0000-4000-a000-000000005201', 'source_type', 'cells_meeting',
  'source_id', pg_temp.first_id(), 'source_revision', pg_temp.rev(pg_temp.first_id()),
  'recipient_member_id', pg_temp.mid(6), 'reminder_kind', 'cells_meeting_reminder',
  'scheduled_at', app.cmd_utc(now())));
select app.cells_record_meeting_contact_need(jsonb_build_object(
  'need_id', '00000000-0000-4000-a000-000000005201', 'source_type', 'cells_meeting',
  'source_id', pg_temp.first_id(), 'source_revision', pg_temp.rev(pg_temp.first_id()),
  'recipient_member_id', pg_temp.mid(6), 'reminder_kind', 'cells_meeting_reminder',
  'scheduled_at', app.cmd_utc(now())));
create function pg_temp.needs(n int) returns jsonb language sql as $$
  select x -> 'contact_needs' from jsonb_array_elements(pg_temp.staff(n) -> 'cells') c,
         jsonb_array_elements(c -> 'meetings') x
   where (x ->> 'meeting_id')::uuid = pg_temp.first_id()
$$;
select is((select n ->> 'display_name' from jsonb_array_elements(pg_temp.needs(2)) n),
  'SYNTHETIC 5.2 Accountless', 'the accountless member''s need is recorded once and named for the leader');
select is(jsonb_array_length(pg_temp.needs(1)), 0, 'an Admin-only reader sees no names to contact');

-- Payload and deletion ------------------------------------------------------------------------------
select ok(not exists (select 1 from app.notifications_jobs j
                       where j.source_type = 'cells_meeting'
                         and (j.cancel_reason ~* 'road|hall|synthetic' or j.reminder_kind ~* 'road|hall')),
  'jobs carry ids, kinds and instants only');
select is((app.cells_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(6),
                                                     'account_id', null)) ->> 'remaining')::int, 0,
  'the deletion hook anonymises the member''s contact needs (and their membership) and answers zero');
select is((select count(*)::int from app.cells_meeting_contact_needs where member_id = pg_temp.mid(6)), 0,
  'no contact need keeps the erased member');

-- 5.2 review fixes (shipped in the 5.3 migration) --------------------------------------------
select pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', '[]'::jsonb));
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'cells_meeting' and j.reminder_kind = 'cells_meeting_reminder'
              and j.job_state = 'pending' and j.snoozed_from_item_id is null), 0,
  'review fix 1: an empty reminder list means no reminders at all');
select pg_temp.cells(pg_temp.c(2), 'cells.set_meeting_reminders', pg_temp.rrev(),
  jsonb_build_object('cell_id', pg_temp.sh(), 'reminders', null));
select is(pg_temp.reminder_at(pg_temp.nth_id(3), 5), null,
  'member 5 (in Estates) has no Shikoswe reminder before joining');
select pg_temp.place(5, pg_temp.sh());
select is(pg_temp.reminder_at(pg_temp.nth_id(3), 5),
  (select starts_at - interval '24 hours' from app.cells_meetings where meeting_id = pg_temp.nth_id(3)),
  'review fix 4: confirming a member plans their reminders at once, back on the usual 24 hours');
select is(app.cells_reminders_available(), true, 'the probe answers true while the Q2 fixture is usable');

-- Review finding F8: a venue-only or map-pin-only schedule change is a meeting change ----------------
-- Member 5 is the cell's confirmed member now; meeting 0 is two days ahead (inside the 14-day notice
-- window), meeting 2 sixteen days ahead (outside it); meeting 4 gets a venue of its own.
select pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', pg_temp.rev(pg_temp.nth_id(4)),
  jsonb_build_object('meeting_id', pg_temp.nth_id(4),
    'starts_at', app.cmd_utc((select nominal_starts_at from app.cells_meetings where meeting_id = pg_temp.nth_id(4))),
    'ends_at', app.cmd_utc((select nominal_ends_at from app.cells_meetings where meeting_id = pg_temp.nth_id(4))),
    'venue', 'SYNTHETIC Church hall'));
create function pg_temp.changed_now(p_meeting uuid) returns int language sql as $$
  select count(*)::int from app.notifications_jobs j
   where j.source_type = 'cells_meeting' and j.source_id = p_meeting and j.reminder_kind = 'cells_meeting_changed'
     and j.source_revision = pg_temp.rev(p_meeting) and j.recipient_member_id = pg_temp.mid(5)
$$;
create temp table f8 as select pg_temp.rev(pg_temp.nth_id(0)) as r0, pg_temp.rev(pg_temp.nth_id(2)) as r2,
                               pg_temp.rev(pg_temp.nth_id(4)) as r4,
                               pg_temp.reminder_at(pg_temp.nth_id(0), 5) as reminded;
select isnt((select reminded from f8), null, 'F8 setup: member 5 has a reminder for the next meeting');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 14 Kafue Road"}')) ->> 'code', null, 'F8: the Admin changes only the venue');
select is((select pg_temp.rev(pg_temp.nth_id(0)) - r0 from f8) || '|' || pg_temp.changed_now(pg_temp.nth_id(0)),
  '1|1', 'F8: the next meeting is revised and its member gets one change notice');
select is(app.cells_meeting_json(pg_temp.nth_id(0), true) ->> 'venue', 'SYNTHETIC 14 Kafue Road',
  'F8: ... and the read shows the new place');
select is((select pg_temp.rev(pg_temp.nth_id(2)) - r2 from f8) || '|' || pg_temp.changed_now(pg_temp.nth_id(2)),
  '1|0', 'F8: a meeting beyond the notice window is revised (reminders re-planned) without a notice');
select is((select pg_temp.rev(pg_temp.nth_id(4)) - r4 from f8), 0::bigint,
  'F8: a meeting with its own venue is not affected');
delete from f8;
insert into f8 select pg_temp.rev(pg_temp.nth_id(0)), pg_temp.rev(pg_temp.nth_id(2)), pg_temp.rev(pg_temp.nth_id(4)), null;
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 14 Kafue Road", "map_pin": {"lat": -15.77, "lng": 28.18}}'));
select is((select pg_temp.rev(pg_temp.nth_id(0)) - r0 from f8) || '|' || pg_temp.changed_now(pg_temp.nth_id(0))
          || '|' || (select pg_temp.rev(pg_temp.nth_id(4)) - r4 from f8),
  '1|1|0', 'F8: a map-pin-only change does the same (not for the meeting with its own venue)');
delete from f8;
insert into f8 select pg_temp.rev(pg_temp.nth_id(0)), pg_temp.rev(pg_temp.nth_id(2)), pg_temp.rev(pg_temp.nth_id(4)), null;
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 14 Kafue Road", "map_pin": {"lat": -15.77, "lng": 28.18}}'));
select is((select pg_temp.rev(pg_temp.nth_id(0)) - r0 from f8)
          + (select count(*) from app.notifications_jobs j where j.source_type = 'cells_meeting'
              and j.source_id = pg_temp.nth_id(0) and j.reminder_kind = 'cells_meeting_changed'
              and j.recipient_member_id = pg_temp.mid(5)), 2::bigint,
  'F8: the same place again changes nothing and sends no further notice (two notices in all)');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 16 Kafue Road", "start_time": "18:30", "end_time": "20:00"}'));
select is((select count(*)::int from app.notifications_jobs j where j.source_type = 'cells_meeting'
            and j.source_id = pg_temp.nth_id(0) and j.reminder_kind = 'cells_meeting_changed'
            and j.recipient_member_id = pg_temp.mid(5)) || '|' || pg_temp.changed_now(pg_temp.nth_id(0)), '3|1',
  'F8: a time and place change in one command sends one notice at one revision');

-- Follow-up review finding F8: moved meetings that show the schedule's place ------------------------
-- (1) Meeting 1 (nine days ahead) is moved a day later without a venue of its own, then the normal
-- time and venue change together: generation revises its nominal fields only (a moved meeting
-- keeps its own time), so the place fallback must notice it. (2) Meeting 3 (nominally 23 days
-- ahead) is moved to tomorrow without a venue: its effective start is inside the 14-day window.
-- Meeting 2 (16 days) is moved inside the window and cancelled; meeting 4 has its own venue.
create function pg_temp.changed_all(p_meeting uuid) returns int language sql as $$
  select count(*)::int from app.notifications_jobs j
   where j.source_type = 'cells_meeting' and j.source_id = p_meeting and j.reminder_kind = 'cells_meeting_changed'
     and j.recipient_member_id = pg_temp.mid(5)
$$;
create function pg_temp.move_plain(p_meeting uuid, p_starts timestamptz) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', pg_temp.rev(p_meeting),
    jsonb_build_object('meeting_id', p_meeting, 'starts_at', app.cmd_utc(p_starts),
                       'ends_at', app.cmd_utc(p_starts + interval '90 minutes')))
$$;
select pg_temp.move_plain(pg_temp.nth_id(1),
  (select nominal_starts_at + interval '1 day' from app.cells_meetings where meeting_id = pg_temp.nth_id(1)));
select pg_temp.move_plain(pg_temp.nth_id(3), date_trunc('minute', now()) + interval '1 day');
select pg_temp.move_plain(pg_temp.nth_id(2), date_trunc('minute', now()) + interval '10 days');
select pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev(pg_temp.nth_id(2)),
  jsonb_build_object('meeting_id', pg_temp.nth_id(2)));
select is((select string_agg(m.meeting_state || ':' || (m.moved_venue is null)::text || ':'
                             || (m.starts_at < now() + interval '14 days')::text, ',' order by m.occurrence_date)
             from app.cells_meetings m where m.meeting_id in (pg_temp.nth_id(1), pg_temp.nth_id(2), pg_temp.nth_id(3))),
  'moved:true:true,cancelled:true:true,moved:true:true',
  'F8 follow-up setup: meetings 1 and 3 are moved inside the window with no venue of their own, 2 is cancelled');
select ok((select nominal_starts_at > now() + interval '14 days' from app.cells_meetings where meeting_id = pg_temp.nth_id(3)),
  'F8 follow-up setup: meeting 3 is nominally outside the notice window');
create temp table f8m as
select k, pg_temp.nth_id(k) as id, pg_temp.rev(pg_temp.nth_id(k)) as rev, pg_temp.changed_all(pg_temp.nth_id(k)) as total,
       (select starts_at from app.cells_meetings where meeting_id = pg_temp.nth_id(k)) as starts
  from unnest(array[1, 2, 3, 4]) k;
create function pg_temp.f8_delta() returns text language sql as $$
  select string_agg(f.k || ':' || (pg_temp.rev(f.id) - f.rev) || '/' || (pg_temp.changed_all(f.id) - f.total)
                    || '/' || pg_temp.changed_now(f.id), ',' order by f.k) from f8m f
$$;
create function pg_temp.f8_reset() returns void language sql as $$
  update f8m f set rev = pg_temp.rev(f.id), total = pg_temp.changed_all(f.id)
$$;

-- (1) Combined time and venue edit.
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 18 Kafue Road", "start_time": "19:00", "end_time": "20:30"}')) ->> 'code',
  null, 'F8 follow-up: the Admin changes the normal time and venue together');
select is((select split_part(pg_temp.f8_delta(), ',', 1)), '1:1/1/1',
  'F8 follow-up (1): the moved meeting with the schedule''s place gets one change notice at its new revision');
select is((select m.starts_at = f.starts from app.cells_meetings m join f8m f on f.id = m.meeting_id where f.k = 1)
          and app.cells_meeting_json(pg_temp.nth_id(1), true) ->> 'venue' = 'SYNTHETIC 18 Kafue Road', true,
  'F8 follow-up (1): ... it keeps its own time and shows the new place');
select is((select split_part(pg_temp.f8_delta(), ',', 2) || ',' || split_part(pg_temp.f8_delta(), ',', 4)),
  '2:1/0/0,4:1/0/0',
  'F8 follow-up (1): the cancelled meeting and the one with its own venue get no notice (only their nominal times move)');

-- (2) Venue-only edit; the moved meeting is judged by its effective start.
select pg_temp.f8_reset();
create temp table f8req as select gen_random_uuid() as id, pg_temp.cell_rev(pg_temp.sh()) as exp;
create temp table f8r as select pg_temp.cmd(pg_temp.c(1), 'api.cells_command', 'cells.set_schedule',
  (select exp from f8req),
  pg_temp.sched('{"venue": "SYNTHETIC 20 Kafue Road", "start_time": "19:00", "end_time": "20:30"}'),
  (select id from f8req)) as r;
select is((select r ->> 'code' from f8r), null, 'F8 follow-up: the Admin changes only the venue');
select is((select split_part(pg_temp.f8_delta(), ',', 3)), '3:1/1/1',
  'F8 follow-up (2): the meeting moved to tomorrow (nominally 23 days ahead) gets one change notice');
select is((select split_part(pg_temp.f8_delta(), ',', 1)), '1:1/1/1',
  'F8 follow-up (2): the other moved meeting gets one notice for the venue-only change too');
select is((select split_part(pg_temp.f8_delta(), ',', 2) || ',' || split_part(pg_temp.f8_delta(), ',', 4)),
  '2:0/0/0,4:0/0/0', 'F8 follow-up (2): the cancelled and overridden meetings are untouched');

-- Replay and repeated edits.
select pg_temp.f8_reset();
select is(pg_temp.cmd(pg_temp.c(1), 'api.cells_command', 'cells.set_schedule',
  (select exp from f8req),
  pg_temp.sched('{"venue": "SYNTHETIC 20 Kafue Road", "start_time": "19:00", "end_time": "20:30"}'),
  (select id from f8req)) = (select r from f8r), true, 'F8 follow-up: a replay of the venue change answers its stored result');
select is(pg_temp.f8_delta(), '1:0/0/1,2:0/0/0,3:0/0/1,4:0/0/0',
  'F8 follow-up: ... and revises nothing and sends no further notice');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 20 Kafue Road", "start_time": "19:00", "end_time": "20:30"}'));
select is(pg_temp.f8_delta(), '1:0/0/1,2:0/0/0,3:0/0/1,4:0/0/0',
  'F8 follow-up: the same schedule again changes nothing for the moved meetings');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 18 Kafue Road", "start_time": "18:30", "end_time": "20:00"}'));
select is(pg_temp.f8_delta(), '1:1/1/1,2:1/0/0,3:1/1/1,4:1/0/0',
  'F8 follow-up: a further time and venue change sends each moved meeting exactly one more notice');
select app.cells_plan_meeting(pg_temp.nth_id(3), 'cells_meeting_changed');
select is(pg_temp.f8_delta(), '1:1/1/1,2:1/0/0,3:1/1/1,4:1/0/0',
  'F8 follow-up: re-planning the same revision does not send a second notice (revision dedup)');
select pg_temp.f8_reset();
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"venue": "SYNTHETIC 18 Kafue Road", "start_time": "19:30", "end_time": "21:00"}'));
select is(pg_temp.f8_delta(), '1:1/0/0,2:1/0/0,3:1/0/0,4:1/0/0',
  'F8 follow-up: a time-only change leaves the moved meetings'' own times, so they get no notice');

select * from finish();
rollback;
