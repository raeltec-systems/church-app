-- Epic 6 entry 19 (K12, K5): the member's own cell meetings for the Calendar's My cell overlay,
-- a Cells contract change (api.cells_my_meetings) that leaves api.cells_my_cell unchanged. Only
-- the caller's own confirmed cell, only meetings that have not ended and start within 31 days,
-- the cancelled state shown, no venue. Guests have no EXECUTE; an account without member access
-- is refused. HTTP evidence with real phone sign-in: tools/identity-e2e/calendar-overlays.mjs.
-- Every account, phone and name here is SYNTHETIC (fictional range +1 202 555 0160-0169).
begin;
select plan(21);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000006119' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000006119' || lpad(n::text, 2, '0'))::uuid $$;
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
create function pg_temp.read(p_claims jsonb, p_sql text, p_role text default 'authenticated')
returns text language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  execute format('set local role %I', p_role);
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
create function pg_temp.mine(n int) returns jsonb language sql as
$$ select pg_temp.readj(pg_temp.c(n), 'select api.cells_my_meetings()') $$;
create function pg_temp.ids(p jsonb) returns uuid[] language sql as
$$ select coalesce(array_agg((x ->> 'meeting_id')::uuid order by ord), '{}')
     from jsonb_array_elements(p -> 'meetings') with ordinality t(x, ord) $$;

-- Fixtures. 1 Admin, 2 leader of Shikoswe (not a member of it), 4 member of Shikoswe, 5 member
-- of Estates, 6 member of Estates whose membership ends, 7 an account without member access (a
-- pending applicant has no member link yet), 8 a plain member in no cell.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 8) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 8) n;

-- Structure and privileges ---------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'api.cells_my_meetings()', 'EXECUTE')
          and not has_function_privilege('anon', 'app.cells_my_meetings()', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.cells_my_meetings()', 'EXECUTE')
          and not has_function_privilege('service_role', 'api.cells_my_meetings()', 'EXECUTE'),
  'guests cannot execute the new read; signed-in callers can (Identity decides who passes)');
select ok((select prosecdef from pg_proc where oid = 'app.cells_my_meetings()'::regprocedure)
          and not (select prosecdef from pg_proc where oid = 'api.cells_my_meetings()'::regprocedure),
  'the app function runs as its owner; the api wrapper as the caller');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is(app.contract_function_module('app.cells_my_meetings()'::regprocedure), 'cells',
  'the new read is owned by Cells');

-- Environment, members, cells, roles and confirmed memberships ---------------------------------------
select app.platform_set_environment('local', 'pgtap 6.19');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 6.19 Member ' || n, 'pgtap 6.19') as member_id
  from (values (1), (2), (4), (5), (6), (8)) v(n);
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

select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(2)),
  jsonb_build_object('member_id', pg_temp.mid(2), 'scope_kind', 'cell_leader', 'scope_id', pg_temp.sh()));

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
select pg_temp.place(6, pg_temp.es());

-- Before any schedule: no meetings, and an honest null cell.
select is(pg_temp.mine(4), jsonb_build_object('cell_id', null, 'from', pg_temp.mine(4) -> 'from',
  'until', pg_temp.mine(4) -> 'until', 'meetings', '[]'::jsonb),
  'a confirmed member whose cell has no schedule reads no cell and no meetings');

-- Weekly schedules for both cells, two days from today in church time.
create function pg_temp.wd() returns int language sql as
$$ select ((extract(isodow from (now() at time zone 'Africa/Lusaka')::date)::int + 1) % 7) + 1 $$;
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.sh()),
  jsonb_build_object('cell_id', pg_temp.sh(), 'weekday', pg_temp.wd(), 'start_time', '18:00',
                     'end_time', '19:30', 'venue', 'SYNTHETIC 12 Shikoswe Road',
                     'map_pin', '{"lat": -15.77123, "lng": 28.18456}'::jsonb));
select pg_temp.cells(pg_temp.c(1), 'cells.set_schedule', pg_temp.cell_rev(pg_temp.es()),
  jsonb_build_object('cell_id', pg_temp.es(), 'weekday', pg_temp.wd(), 'start_time', '17:00',
                     'end_time', '18:00', 'venue', 'SYNTHETIC 7 Estates Close'));

create function pg_temp.nth(p_cell uuid, k int) returns uuid language sql as
$$ select meeting_id from app.cells_meetings where cell_id = p_cell order by occurrence_date offset k limit 1 $$;
create function pg_temp.rev(p_meeting uuid) returns bigint language sql as
$$ select revision from app.cells_meetings where meeting_id = p_meeting $$;

-- Exceptions: the second Shikoswe meeting moves a day later to another venue, the third is cancelled.
select pg_temp.cells(pg_temp.c(2), 'cells.move_meeting', pg_temp.rev(pg_temp.nth(pg_temp.sh(), 1)),
  jsonb_build_object('meeting_id', pg_temp.nth(pg_temp.sh(), 1),
    'starts_at', app.cmd_utc((select nominal_starts_at + interval '1 day' from app.cells_meetings where meeting_id = pg_temp.nth(pg_temp.sh(), 1))),
    'ends_at', app.cmd_utc((select nominal_ends_at + interval '1 day' from app.cells_meetings where meeting_id = pg_temp.nth(pg_temp.sh(), 1))),
    'venue', 'SYNTHETIC Church hall'));
select pg_temp.cells(pg_temp.c(2), 'cells.cancel_meeting', pg_temp.rev(pg_temp.nth(pg_temp.sh(), 2)),
  jsonb_build_object('meeting_id', pg_temp.nth(pg_temp.sh(), 2)));

-- The confirmed member's own meetings ------------------------------------------------------------------
create temp table mine4 as select pg_temp.mine(4) as x;
select is((select (x ->> 'cell_id')::uuid from mine4), pg_temp.sh(), 'a confirmed member reads their own cell');
select is((select pg_temp.ids(x) from mine4),
  (select coalesce(array_agg(meeting_id order by starts_at, meeting_id), '{}') from app.cells_meetings
    where cell_id = pg_temp.sh() and meeting_state in ('scheduled', 'moved', 'cancelled')
      and ends_at > now() and starts_at < now() + interval '31 days'),
  'exactly the cell''s meetings that have not ended and start within 31 days, soonest first');
select ok((select jsonb_array_length(x -> 'meetings') between 4 and 5 from mine4)
          and exists (select 1 from app.cells_meetings where cell_id = pg_temp.sh()
                       and starts_at >= now() + interval '31 days' and meeting_state = 'scheduled'),
  'the window is bounded: later generated meetings are left out');
select is((select string_agg(distinct k, ',' order by k)
             from mine4, jsonb_array_elements(x -> 'meetings') e, jsonb_object_keys(e) k),
  'ends_at,meeting_id,occurrence_date,starts_at,state',
  'each meeting carries only its id, date, state and times');
select ok((select x::text not like '%Shikoswe Road%' and x::text not like '%Church hall%'
                  and x::text not like '%lat%' from mine4),
  'no venue or map pin travels on the overlay read');
select is((select e ->> 'state' from mine4, jsonb_array_elements(x -> 'meetings') e
            where (e ->> 'meeting_id')::uuid = pg_temp.nth(pg_temp.sh(), 2)), 'cancelled',
  'a cancelled meeting is listed and marked cancelled');
select is((select (e ->> 'state') || '|' || ((e ->> 'starts_at')::timestamptz
                   = (select starts_at from app.cells_meetings where meeting_id = pg_temp.nth(pg_temp.sh(), 1)))::text
             from mine4, jsonb_array_elements(x -> 'meetings') e
            where (e ->> 'meeting_id')::uuid = pg_temp.nth(pg_temp.sh(), 1)), 'moved|true',
  'a moved meeting is listed at its new time');

-- Nobody sees another cell's meetings ----------------------------------------------------------------
select ok((pg_temp.mine(5) ->> 'cell_id')::uuid = pg_temp.es()
          and jsonb_array_length(pg_temp.mine(5) -> 'meetings') >= 4
          and not (pg_temp.ids(pg_temp.mine(5)) && (select array_agg(meeting_id) from app.cells_meetings
                                                       where cell_id = pg_temp.sh())),
  'a member of Estates reads only Estates meetings, never a Shikoswe one');
select ok(pg_temp.mine(2) ->> 'cell_id' is null and pg_temp.mine(2) -> 'meetings' = '[]'::jsonb,
  'a leader of a cell who is not its member reads no meetings (own confirmed cell only)');
select ok(pg_temp.mine(1) ->> 'cell_id' is null and pg_temp.mine(1) -> 'meetings' = '[]'::jsonb
          and pg_temp.mine(8) ->> 'cell_id' is null,
  'Admin-only access and a member in no cell read no meetings');
update app.cells_memberships set ended_at = now() where member_id = pg_temp.mid(6) and ended_at is null;
select ok(pg_temp.mine(6) ->> 'cell_id' is null and pg_temp.mine(6) -> 'meetings' = '[]'::jsonb,
  'a member whose cell membership ended reads no meetings');

-- Refusals ---------------------------------------------------------------------------------------------
select ok(pg_temp.read(pg_temp.c(7), 'select api.cells_my_meetings()') like 'PT40%',
  'an account without member access (a pending applicant) is refused');
select ok(pg_temp.read('{}'::jsonb, 'select api.cells_my_meetings()', 'anon') like '42501|%',
  'a guest (anon) is refused: no EXECUTE');

-- api.cells_my_cell is unchanged -----------------------------------------------------------------------
select ok((select x #> '{meetings,next}' is not null and x #>> '{meetings,next,venue}' is not null
             from (select pg_temp.readj(pg_temp.c(4), 'select api.cells_my_cell()') as x) q),
  'My cell still answers its next meeting with the venue (unchanged)');

select * from finish();
rollback;
