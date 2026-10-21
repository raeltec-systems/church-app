-- A cell's weekly meetings (story 5.1; epic 5 C1, C9; AD-1, AD-2, AD-9, AD-13, AD-14).
-- Admin-set weekly schedule with a private venue and map pin, stable meeting ids generated in
-- church time through the 3.3 calculation, one-meeting exceptions (move, cancel, reinstate) by
-- the cell's leader or an Admin, the staff meetings read (venue only with cell access) and the
-- next meeting on the member's own cell read. HTTP evidence with real phone sign-in:
-- tools/identity-e2e/cells-meetings.mjs. Every account, phone and name here is SYNTHETIC
-- (fictional range +1 202 555 0140-0159).
begin;
select plan(53);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000051' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000051' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (40 + n)::text $$;

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
create function pg_temp.cells(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                              p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cmd(p_claims, 'api.cells_command', p_command, p_expected, p_payload, p_request)
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
create function pg_temp.mine(n int) returns jsonb language sql as
$$ select pg_temp.readj(pg_temp.c(n), 'select api.cells_my_cell()') $$;

-- Fixtures. 1 Admin, 2 leader of Shikoswe, 3 assistant of Shikoswe, 4 member of Shikoswe,
-- 5 member of Estates, 6 leader of Estates, 7 an account without member access (a pending
-- applicant has no member link yet), 8 a plain member in no cell.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 8) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 8) n;

-- Structure, privileges and guards ----------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.cells_meeting_schedules', 'app.cells_meetings',
                             'app.cells_meeting_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the schedule, meeting and audit tables');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'cells_meeting_audit'),
  array['action', 'actor_account_id', 'actor_capacity', 'actor_member_id', 'cell_id',
        'command_request_id', 'created_at', 'event_id', 'meeting_id', 'revision_after'],
  'the meeting audit holds ids, codes and revisions only (no venue, names or times)');
select ok(not has_function_privilege('anon', 'api.cells_meetings()', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.cells_meetings()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_generate_meetings(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_set_schedule(uuid, bigint, jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_member_meetings(uuid)', 'EXECUTE'),
  'only the meetings read is client-callable; generation and handlers are server-only');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Environment, members, cells, roles and confirmed memberships ---------------------------------------
select app.platform_set_environment('local', 'pgtap 5.1');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 5.1 Member ' || n, 'pgtap 5.1') as member_id
  from (values (1), (2), (3), (4), (5), (6), (8)) v(n);
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
select pg_temp.grant_scope(6, 'cell_leader', pg_temp.es());

-- An Admin requests the cell for the member and confirms it (2.6 commands).
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
select pg_temp.place(5, pg_temp.es());
select is((select count(*)::int from app.cells_memberships
            where ended_at is null and member_id in (pg_temp.mid(4), pg_temp.mid(5))), 2,
  'members 4 (Shikoswe) and 5 (Estates) are confirmed');

-- The weekly schedule (Admin) -----------------------------------------------------------------------
-- Two days from today in church time, so the first meeting is always in the future.
create function pg_temp.wd() returns int language sql as
$$ select ((extract(isodow from (now() at time zone 'Africa/Lusaka')::date)::int + 1) % 7) + 1 $$;
create function pg_temp.sched(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('cell_id', pg_temp.sh(), 'weekday', pg_temp.wd(), 'start_time', '18:00',
                            'end_time', '19:30', 'venue', 'SYNTHETIC 12 Shikoswe Road',
                            'map_pin', '{"lat": -15.77123, "lng": 28.18456}'::jsonb) || p_extra
$$;

select is(pg_temp.cells(pg_temp.c(2), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched()) ->> 'code', 'forbidden', 'a cell leader cannot set the schedule (Admin with the cell)');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  jsonb_build_object('cell_id', pg_temp.sh(), 'weekday', 8, 'start_time', '25:00', 'end_time', '7pm',
                     'venue', '12 Real Road', 'map_pin', '{"lat": 120, "lng": 0}'::jsonb, 'extra', 1))
  -> 'field_errors',
  '{"weekday": "out_of_range", "start_time": "invalid", "end_time": "invalid", "venue": "invalid",
    "map_pin": "invalid", "extra": "unknown_field"}'::jsonb,
  'every field error at once; while Q4 is unapproved the venue is SYNTHETIC');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"end_time": "17:00"}')) -> 'field_errors', '{"end_time": "before_start"}'::jsonb,
  'the meeting ends after it starts');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched() - 'venue') -> 'field_errors', '{"venue": "required"}'::jsonb,
  'the first schedule needs a venue');
select is(pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', 99, pg_temp.sched()) ->> 'code', 'conflict',
  'a stale cell revision is a conflict');
create temp table set1 as select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule',
  pg_temp.cell_rev(pg_temp.sh()), pg_temp.sched()) as r;
select is((select ((r #>> '{data,cell_id}')::uuid = pg_temp.sh())::text || '|' || (r ->> 'revision') from set1), 'true|2',
  'an Admin sets the weekly schedule; the cell revision moves');
select is((select zone || '|' || policy_version || '|' || to_char(start_time, 'HH24:MI') || '|' || weekday
             from app.cells_meeting_schedules where cell_id = pg_temp.sh()),
  'Africa/Lusaka|1|18:00|' || pg_temp.wd(), 'the schedule records the church zone and the Q2 policy version');
select ok((select count(*) from app.cells_meetings where cell_id = pg_temp.sh()) between 12 and 13
          and not exists (select 1 from app.cells_meetings where cell_id = pg_temp.sh()
                           and (extract(isodow from occurrence_date)::int <> pg_temp.wd()
                                or to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') <> '18:00'
                                or to_char(ends_at at time zone 'Africa/Lusaka', 'HH24:MI') <> '19:30')),
  'twelve weeks of meetings are generated on the weekday at 18:00-19:30 church time');
create temp table ids0 as select occurrence_date, meeting_id, revision from app.cells_meetings where cell_id = pg_temp.sh();

-- Regeneration keeps every id
select app.cells_generate_meetings(pg_temp.sh());
select pg_temp.staff(2);
select ok(not exists (select 1 from ids0 i
                       full join app.cells_meetings c on c.cell_id = pg_temp.sh() and c.occurrence_date = i.occurrence_date
                      where c.meeting_id is distinct from i.meeting_id or c.revision is distinct from i.revision),
  'regeneration (directly and on a read) keeps every meeting id and revision');

-- Staff read -------------------------------------------------------------------------------------
create function pg_temp.cell_in(p_read jsonb, p_cell uuid) returns jsonb language sql as
$$ select c from jsonb_array_elements(p_read -> 'cells') c where (c ->> 'cell_id')::uuid = p_cell $$;
select is((select pg_temp.cell_in(pg_temp.staff(2), pg_temp.sh()) #>> '{schedule,venue}'),
  'SYNTHETIC 12 Shikoswe Road', 'the leader reads the venue');
select is((select pg_temp.cell_in(pg_temp.staff(3), pg_temp.sh()) #>> '{meetings,0,venue}') || '|'
          || (select pg_temp.cell_in(pg_temp.staff(3), pg_temp.sh()) ->> 'can_change'),
  'SYNTHETIC 12 Shikoswe Road|false', 'the assistant reads the venue but cannot change meetings');
select is((select coalesce(x #>> '{schedule,venue}', 'null') || '|' || (x #>> '{schedule,venue_set}') || '|'
                  || (x #>> '{schedule,pin_set}') || '|' || coalesce(x #>> '{schedule,map_pin}', 'null') || '|'
                  || coalesce(x #>> '{meetings,0,venue}', 'null') || '|' || (x ->> 'can_change') || '|'
                  || (x ->> 'cell_revision')
             from (select pg_temp.cell_in(pg_temp.staff(1), pg_temp.sh()) as x) q),
  'null|true|true|null|null|true|2',
  'an Admin-only read shows that a venue and pin are set, never the venue or pin, and may change meetings');
select is((select string_agg(c ->> 'name', ',' order by c ->> 'name')
             from jsonb_array_elements(pg_temp.staff(6) -> 'cells') c),
  'SYNTHETIC Estates C5/C7 Cell', 'another cell''s leader sees only their own cell');
select ok(pg_temp.read(pg_temp.c(8), 'select api.cells_meetings()') like 'PT403|forbidden|not_granted%',
  'a member without a cell scope or Admin is refused the staff read');

-- My cell: the next meeting for confirmed members only -------------------------------------------
create function pg_temp.first_id() returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date limit 1 $$;
create function pg_temp.nth_id(k int) returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = pg_temp.sh() order by occurrence_date offset k limit 1 $$;
select is((select (x #>> '{meetings,next,meeting_id}')::uuid = pg_temp.first_id()
                  and x #>> '{meetings,next,venue}' = 'SYNTHETIC 12 Shikoswe Road'
                  and (x #>> '{meetings,next,map_pin,lat}')::numeric = -15.77123
                  and x #>> '{meetings,next,state}' = 'scheduled'
             from (select pg_temp.mine(4) as x) q), true,
  'a confirmed member reads the next meeting with its venue and pin on My cell');
select ok(pg_temp.mine(5) -> 'meetings' = 'null'::jsonb
          and pg_temp.mine(5)::text not like '%Shikoswe Road%',
  'a member of Estates (no schedule) reads no meeting and no Shikoswe venue');
select ok(pg_temp.read(pg_temp.c(7), 'select api.cells_my_cell()') not like 'ok %',
  'an account without member access (a pending applicant) is refused My cell');
select ok(pg_temp.mine(1) -> 'meetings' = 'null'::jsonb and pg_temp.mine(1)::text not like '%Shikoswe Road%',
  'Admin-only access sees no venue on My cell');
select ok(pg_temp.mine(8) -> 'meetings' = 'null'::jsonb, 'a member in no cell has no meetings');

-- Exceptions: move, cancel, reinstate --------------------------------------------------------------
create function pg_temp.rev(p_meeting uuid) returns bigint language sql as
$$ select revision from app.cells_meetings where meeting_id = p_meeting $$;
create function pg_temp.mv(n int, p_meeting uuid, p_shift interval, p_venue jsonb default null,
                           p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.move_meeting', pg_temp.rev(p_meeting),
    jsonb_build_object('meeting_id', p_meeting,
      'starts_at', app.cmd_utc((select nominal_starts_at from app.cells_meetings where meeting_id = p_meeting) + p_shift),
      'ends_at', app.cmd_utc((select nominal_ends_at from app.cells_meetings where meeting_id = p_meeting) + p_shift))
    || coalesce(jsonb_build_object('venue', p_venue), '{}'::jsonb), p_request)
$$;
select is(pg_temp.mv(3, pg_temp.nth_id(1), interval '1 day') ->> 'code', 'forbidden',
  'an assistant cannot move a meeting');
select is(pg_temp.mv(6, pg_temp.nth_id(1), interval '1 day') ->> 'code', 'forbidden',
  'another cell''s leader cannot move it');
select is(pg_temp.mv(4, pg_temp.nth_id(1), interval '1 day') ->> 'code', 'forbidden',
  'a member cannot move it');
select is(pg_temp.mv(2, pg_temp.nth_id(1), interval '40 days') -> 'field_errors',
  '{"starts_at": "out_of_range"}'::jsonb, 'a move stays within 30 days of the nominal date');
select is(pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', pg_temp.rev(pg_temp.nth_id(1)),
  jsonb_build_object('meeting_id', pg_temp.nth_id(1), 'starts_at', '2020-01-01T10:00:00Z',
                     'ends_at', '2020-01-01T09:00:00Z')) -> 'field_errors',
  '{"starts_at": "past", "ends_at": "before_start"}'::jsonb, 'a move into the past or ending first is refused');
create temp table moved as select pg_temp.nth_id(1) as id;
-- The exact move request (kept for the replays below).
create temp table mvreq as
select pg_temp.rev((select id from moved)) as expected,
       jsonb_build_object('meeting_id', (select id from moved),
         'starts_at', app.cmd_utc(nominal_starts_at + interval '1 day'),
         'ends_at', app.cmd_utc(nominal_ends_at + interval '1 day'),
         'venue', 'SYNTHETIC Church hall') as payload
  from app.cells_meetings where meeting_id = (select id from moved);
create function pg_temp.mv_again(n int) returns jsonb language sql as $$
  select pg_temp.cells(pg_temp.c(n), 'cells.move_meeting', (select expected from mvreq),
                       (select payload from mvreq), '00000000-0000-4000-a000-000000005101')
$$;
create temp table mv1 as select pg_temp.mv_again(2) as r;
select is((select ((r #>> '{data,meeting_id}')::uuid = (select id from moved))::text || '|' || (r #>> '{data,state}') || '|' || (r #>> '{data,venue}')
                  || '|' || (r #>> '{data,venue_moved}') || '|' || (r ->> 'revision') from mv1),
  'true|moved|SYNTHETIC Church hall|true|2',
  'the leader moves one meeting to another day and venue; it keeps its id');
select is((select starts_at - nominal_starts_at from app.cells_meetings where meeting_id = (select id from moved)),
  interval '1 day', 'the moved meeting keeps its nominal key and time alongside the new time');
select is(pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', 1,
  jsonb_build_object('meeting_id', (select id from moved), 'starts_at', '2099-01-01T10:00:00Z',
                     'ends_at', '2099-01-01T11:00:00Z')) ->> 'code', 'conflict',
  'a move under a stale meeting revision is a conflict');
select is(pg_temp.mv_again(2) = (select r from mv1), true, 'a replay of the move answers its stored result');

create temp table cancelled as select pg_temp.nth_id(2) as id;
select is(pg_temp.cells(pg_temp.c(1), 'cells.cancel_meeting', pg_temp.rev((select id from cancelled)),
  jsonb_build_object('meeting_id', (select id from cancelled))) #>> '{data,state}', 'cancelled',
  'an Admin cancels one meeting');
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev((select id from cancelled)),
  jsonb_build_object('meeting_id', (select id from cancelled))) #>> '{field_errors,meeting_id}', 'cancelled',
  'a cancelled meeting cannot be cancelled again');
select is(pg_temp.mv(2, (select id from cancelled), interval '1 hour') #>> '{field_errors,meeting_id}', 'cancelled',
  'a cancelled meeting cannot be moved');

-- Regeneration again: exceptions keep their ids and state
select app.cells_generate_meetings(pg_temp.sh());
select ok((select meeting_state from app.cells_meetings where meeting_id = (select id from moved)) = 'moved'
          and (select meeting_state from app.cells_meetings where meeting_id = (select id from cancelled)) = 'cancelled'
          and not exists (select 1 from ids0 i join app.cells_meetings c using (occurrence_date)
                           where c.cell_id = pg_temp.sh() and c.meeting_id <> i.meeting_id),
  'regeneration keeps the moved and the cancelled meetings and every id');

-- My cell reflects the exceptions: make the first meeting cancelled too, so the next is the moved one
select pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev(pg_temp.first_id()),
  jsonb_build_object('meeting_id', pg_temp.first_id()));
select is((select (x #>> '{meetings,next,meeting_id}')::uuid = (select id from moved)
                  and x #>> '{meetings,next,state}' = 'moved'
                  and x #>> '{meetings,next,venue}' = 'SYNTHETIC Church hall'
                  and x #> '{meetings,next,map_pin}' = 'null'::jsonb
                  and jsonb_array_length(x #> '{meetings,cancelled}') = 1
                  and (x #>> '{meetings,cancelled,0,meeting_id}')::uuid = pg_temp.first_id()
             from (select pg_temp.mine(4) as x) q), true,
  'My cell shows the moved meeting next (its venue, no pin) and the cancelled one before it');

select is(pg_temp.cells(pg_temp.c(2), 'cells.reinstate_meeting', pg_temp.rev(pg_temp.first_id()),
  jsonb_build_object('meeting_id', pg_temp.first_id())) #>> '{data,state}', 'scheduled',
  'the leader reinstates a cancelled meeting');
select is(pg_temp.cells(pg_temp.c(2), 'cells.reinstate_meeting', pg_temp.rev(pg_temp.first_id()),
  jsonb_build_object('meeting_id', pg_temp.first_id())) #>> '{field_errors,meeting_id}', 'not_cancelled',
  'only a cancelled meeting is reinstated');

-- A meeting that has started is not changed
update app.cells_meetings set starts_at = now() - interval '1 hour', ends_at = now() + interval '30 minutes',
                              nominal_starts_at = now() - interval '1 hour', nominal_ends_at = now() + interval '30 minutes'
 where meeting_id = pg_temp.first_id();
select is(pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev(pg_temp.first_id()),
  jsonb_build_object('meeting_id', pg_temp.first_id())) #>> '{field_errors,meeting_id}', 'started',
  'a meeting that has started cannot be cancelled or moved');

-- Schedule changes: re-time in place, withdraw and revive by date ----------------------------------
create temp table later as select pg_temp.nth_id(4) as id, occurrence_date from app.cells_meetings
 where meeting_id = pg_temp.nth_id(4);
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched('{"start_time": "17:30"}') - 'venue' - 'map_pin');
select is((select to_char(starts_at at time zone 'Africa/Lusaka', 'HH24:MI') || '|' || meeting_state
             from app.cells_meetings where meeting_id = (select id from later)),
  '17:30|scheduled', 'a new start time re-times future scheduled meetings in place (same id)');
select is((select venue || '|' || (map_lat is not null)::text from app.cells_meeting_schedules where cell_id = pg_temp.sh()),
  'SYNTHETIC 12 Shikoswe Road|true', 'an absent venue and pin keep the current ones');
select is((select meeting_state || '|' || to_char(starts_at - nominal_starts_at, 'DD')
             from app.cells_meetings where meeting_id = (select id from moved)),
  'moved|01', 'the moved exception is untouched by the schedule change');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  pg_temp.sched(jsonb_build_object('weekday', (pg_temp.wd() % 7) + 1)) - 'venue');
select is((select meeting_state from app.cells_meetings where meeting_id = (select id from later)), 'withdrawn',
  'a new weekday withdraws the old future dates (hidden, never deleted)');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.cell_in(pg_temp.staff(2), pg_temp.sh()) -> 'meetings') x
                       where (x ->> 'meeting_id')::uuid = (select id from later)),
  'withdrawn meetings are not listed');
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()), pg_temp.sched() - 'venue');
select is((select meeting_id = (select id from later) and meeting_state = 'scheduled'
             from app.cells_meetings where cell_id = pg_temp.sh()
              and occurrence_date = (select occurrence_date from later)), true,
  'the original weekday brings the same meeting ids back');

-- Audit, replay recheck and deletion --------------------------------------------------------------
select is((select string_agg(distinct action, ',' order by action) from app.cells_meeting_audit
            where cell_id = pg_temp.sh()),
  'meeting_cancelled,meeting_moved,meeting_reinstated,schedule_set', 'schedule and meeting changes are audited');
-- The leader loses the scope: a replay of their move is refused.
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'cell_leader', 'scope_id', pg_temp.sh()));
select is(pg_temp.mv_again(2) ->> 'code', 'forbidden',
  'a revoked leader''s replay is refused (real replay recheck)');
select is((app.cells_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(2),
                                                     'account_id', pg_temp.u(2))) ->> 'remaining')::int, 0,
  'the deletion hook anonymises the leader''s meeting actions and answers zero');
select ok(not exists (select 1 from app.cells_meeting_audit where actor_member_id = pg_temp.mid(2)
                                                            or actor_account_id = pg_temp.u(2))
          and not exists (select 1 from app.cells_meetings where changed_by_member = pg_temp.mid(2)),
  'no meeting row keeps the erased actor');

select * from finish();
rollback;
