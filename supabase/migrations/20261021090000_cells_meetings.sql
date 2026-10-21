-- Story 5.1: a cell's weekly meetings (epic 5, requirements C1 and C9). Builds on
-- 20261007075946_cell_membership.sql (cells, leader/assistant scopes, private access rule) and
-- 20261008102121_notifications_scheduling.sql (the Q2 policy and the 3.3 church-local recurrence).
--
--   * One weekly schedule per cell (app.cells_meeting_schedules): ISO weekday, start and end time,
--     the private venue with an optional map pin, the first date, and the church zone and policy
--     version recorded from the Q2 policy (AD-9). Admin only: cells.set_schedule, expected =
--     the cell revision (aggregate cells_cell).
--   * Meetings (app.cells_meetings): one row per (cell, nominal church-local date) generated for
--     today plus 84 days by app.cells_generate_meetings through app.notifications_occurrences.
--     The row id is the stable meeting id: regeneration upserts by the key, re-times future
--     scheduled meetings in place, withdraws future scheduled dates the rule no longer produces
--     (`withdrawn`, hidden; revived with the same id), and never touches moved or cancelled
--     exceptions or anything that has started.
--   * Exceptions by the cell's leader or an Admin (an assistant reads only):
--     cells.move_meeting, cells.cancel_meeting, cells.reinstate_meeting (expected = the meeting
--     revision; aggregate cells_meeting with a real replay recheck).
--   * Reads: api.cells_meetings() (staff: leaders/assistants their cells with venue; Admin every
--     cell with venue_set only) and api.cells_my_cell() now answers `meetings` {next, cancelled}
--     for the member's own confirmed cell (app.cells_member_has_private_access).
--   * Content-free audit app.cells_meeting_audit; the Cells deletion hook now also anonymises the
--     actor ids of the new tables.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Meeting states. Story 5.8 adds `held` by replacing this function (a CHECK calls it).
create function app.cells_meeting_state_ok(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value in ('scheduled', 'moved', 'cancelled', 'withdrawn');
$$;

create table app.cells_meeting_schedules (
  cell_id uuid primary key references app.cells_cells (cell_id),
  weekday smallint not null check (weekday between 1 and 7),
  start_time time not null,
  end_time time not null,
  venue text not null check (venue = btrim(venue) and length(venue) between 1 and 120
                             and venue !~ '[[:cntrl:]]'),
  map_lat numeric(8, 5) check (map_lat between -90 and 90),
  map_lng numeric(8, 5) check (map_lng between -180 and 180),
  from_date date not null,
  zone text not null check (length(zone) between 1 and 64),
  policy_version integer not null,
  set_by_member uuid not null,
  set_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_time > start_time and end_time - start_time <= interval '6 hours'),
  check ((map_lat is null) = (map_lng is null))
);

comment on table app.cells_meeting_schedules is
  'owner: cells. A cell''s weekly meeting rule (story 5.1): weekday (ISO), church-local times, '
  'the private venue and optional map pin, and the zone and Q2 policy version it was set under.';

create table app.cells_meetings (
  meeting_id uuid primary key default gen_random_uuid(),
  cell_id uuid not null references app.cells_cells (cell_id),
  occurrence_date date not null,
  nominal_starts_at timestamptz not null,
  nominal_ends_at timestamptz not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  moved_venue text check (moved_venue is null or (moved_venue = btrim(moved_venue)
                                                  and length(moved_venue) between 1 and 120
                                                  and moved_venue !~ '[[:cntrl:]]')),
  meeting_state text not null default 'scheduled' check (app.cells_meeting_state_ok(meeting_state)),
  revision bigint not null default 1 check (revision >= 1),
  changed_by_member uuid,
  changed_by_account uuid,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cell_id, occurrence_date),
  check (ends_at > starts_at),
  check (nominal_ends_at > nominal_starts_at),
  check (meeting_state = 'moved' or moved_venue is null)
);

create index cells_meetings_cell_start on app.cells_meetings (cell_id, starts_at);

comment on table app.cells_meetings is
  'owner: cells. One meeting of a cell (story 5.1): the stable meeting id of the nominal '
  'church-local date (occurrence_date) its schedule produces, with its effective time and '
  'state. Later owners (programmes, attendance, recaps, offerings) reference meeting_id.';

comment on column app.cells_meetings.occurrence_date is
  'Story 5.1: the nominal church-local date (the occurrence key); unchanged by a move.';

create table app.cells_meeting_audit (
  event_id bigint generated always as identity primary key,
  action text not null check (action in ('schedule_set', 'meeting_moved', 'meeting_cancelled',
                                         'meeting_reinstated')),
  cell_id uuid not null,
  meeting_id uuid,
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  actor_capacity text not null check (actor_capacity in ('admin', 'cell_leader')),
  command_request_id uuid,
  revision_after bigint not null check (revision_after >= 1),
  created_at timestamptz not null default now()
);

create index cells_meeting_audit_cell on app.cells_meeting_audit (cell_id, event_id);

comment on table app.cells_meeting_audit is
  'owner: cells. Content-free audit of schedule and meeting changes (story 5.1): ids, codes, '
  'revisions and the actor''s capacity. No venue, names or times.';

alter table app.cells_meeting_schedules enable row level security;
alter table app.cells_meetings enable row level security;
alter table app.cells_meeting_audit enable row level security;
revoke all on table app.cells_meeting_schedules, app.cells_meetings, app.cells_meeting_audit
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Generation (the 3.3 church-local calculation)
-- ---------------------------------------------------------------------------------------------

-- Generates the cell's meetings for today plus 84 days in the schedule's zone. Idempotent: ids
-- are kept by (cell_id, occurrence_date). Returns the number of meetings created. Serialised per
-- cell by the schedule row lock. Runs inside a gated read or command only.
create function app.cells_generate_meetings(p_cell_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  s app.cells_meeting_schedules;
  v_today date;
  v_first date;
  v_until timestamptz;
  v_list jsonb;
  v_dates date[];
  v_created integer := 0;
  v_inserted boolean;
  x jsonb;
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
begin
  select * into s from app.cells_meeting_schedules where cell_id = p_cell_id for update;
  if not found then
    return 0;
  end if;
  v_today := (now() at time zone s.zone)::date;
  v_first := greatest(s.from_date, v_today);
  -- The first date on or after v_first that falls on the weekday (ISO, Monday = 1).
  v_first := v_first + ((s.weekday - extract(isodow from v_first)::integer + 7) % 7);
  v_until := ((v_today + 84) + s.start_time) at time zone s.zone;
  if ((v_first + s.start_time) at time zone s.zone) > v_until then
    v_list := '[]'::jsonb;
  else
    v_list := app.notifications_occurrences(
                jsonb_build_object('zone', s.zone),
                jsonb_build_object('local_start', to_char(v_first + s.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                   'every', 'week'),
                (v_first::timestamp) at time zone s.zone,
                v_until);
  end if;
  v_dates := '{}';
  for x in select e from jsonb_array_elements(v_list) e loop
    v_date := left(x ->> 'local', 10)::date;
    v_start := (x ->> 'starts_at')::timestamptz;
    v_end := (v_date + s.end_time) at time zone s.zone;
    v_dates := v_dates || v_date;
    insert into app.cells_meetings as m (cell_id, occurrence_date, nominal_starts_at, nominal_ends_at,
                                         starts_at, ends_at)
    values (p_cell_id, v_date, v_start, v_end, v_start, v_end)
    on conflict (cell_id, occurrence_date) do update
      set nominal_starts_at = excluded.nominal_starts_at,
          nominal_ends_at = excluded.nominal_ends_at,
          starts_at = case when m.meeting_state in ('scheduled', 'withdrawn') then excluded.starts_at
                           else m.starts_at end,
          ends_at = case when m.meeting_state in ('scheduled', 'withdrawn') then excluded.ends_at
                         else m.ends_at end,
          meeting_state = case when m.meeting_state = 'withdrawn' then 'scheduled'
                               else m.meeting_state end,
          revision = m.revision + 1,
          updated_at = now()
      -- Only a future meeting changes, and only when the rule moved it or brings it back.
      where m.starts_at > now()
        and (m.meeting_state = 'withdrawn'
             or (m.nominal_starts_at, m.nominal_ends_at)
                is distinct from (excluded.nominal_starts_at, excluded.nominal_ends_at))
    returning (m.xmax = 0) into v_inserted;
    if v_inserted then
      v_created := v_created + 1;
    end if;
  end loop;
  -- Future scheduled dates the rule no longer produces (a changed weekday or first date).
  update app.cells_meetings m
     set meeting_state = 'withdrawn', revision = m.revision + 1, updated_at = now()
   where m.cell_id = p_cell_id and m.meeting_state = 'scheduled' and m.starts_at > now()
     and not (m.occurrence_date = any (v_dates));
  return v_created;
end;
$$;

comment on function app.cells_generate_meetings(uuid) is
  'Story 5.1: (re)generates a cell''s meetings for today plus 84 days in church time; ids are '
  'stable by (cell_id, occurrence_date); exceptions and started meetings are never changed.';

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- Leader of the cell, or Admin: may change its meetings. Returns the capacity or null.
create function app.cells_meeting_capacity(p_member_id uuid, p_cell_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when app.identity_member_has_scope(p_member_id, 'cell_leader', p_cell_id) then 'cell_leader'
    when app.identity_member_has_role(p_member_id, 'admin') then 'admin'
  end;
$$;

-- A venue: collapsed whitespace, 1..120 characters, no control or format characters;
-- `SYNTHETIC ` first while Q4 is unapproved.
create function app.cells_venue(p_payload jsonb, p_key text, p_required boolean, inout errors jsonb,
                                out value text)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    return;
  end if;
  if jsonb_typeof(v) <> 'string' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := btrim(regexp_replace(v #>> '{}', '\s+', ' ', 'g'));
  if value = '' then
    errors := errors || jsonb_build_object(p_key, 'required');
    value := null;
  elsif length(value) > 120 or value ~ '[[:cntrl:]]'
        or value ~ '[­​-‏‪-‮⁠-⁤⁦-⁯﻿]'
        or (not app.policy_is_open('q4_personal_data') and value !~ '^SYNTHETIC ') then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

-- A church-local time of day `HH:MM` (24-hour); null when absent or malformed.
create function app.cells_clock(p_value jsonb)
returns time
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p_value) = 'string'
                   and (p_value #>> '{}') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then (p_value #>> '{}')::time end;
$$;

create function app.cells_meeting_audit_row(
  p_action text,
  p_cell_id uuid,
  p_meeting_id uuid,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.cells_meeting_audit (action, cell_id, meeting_id, actor_member_id, actor_account_id,
                                       actor_capacity, command_request_id, revision_after)
  values (p_action, p_cell_id, p_meeting_id, p_actor_member, p_actor_account, p_capacity,
          app.cmd_current_request_id(p_actor_account, p_command), p_revision);
$$;

-- One meeting as staff see it. p_private: the venue and pin (leader/assistant of the cell);
-- otherwise only whether the venue was moved.
create function app.cells_meeting_json(p_meeting_id uuid, p_private boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'meeting_id', m.meeting_id,
    'cell_id', m.cell_id,
    'occurrence_date', to_char(m.occurrence_date, 'YYYY-MM-DD'),
    'state', m.meeting_state,
    'starts_at', app.cmd_utc(m.starts_at),
    'ends_at', app.cmd_utc(m.ends_at),
    'nominal_starts_at', app.cmd_utc(m.nominal_starts_at),
    'nominal_ends_at', app.cmd_utc(m.nominal_ends_at),
    'venue_moved', m.moved_venue is not null,
    'venue', case when p_private then coalesce(m.moved_venue, s.venue) end,
    'map_pin', case when p_private and m.moved_venue is null and s.map_lat is not null
                    then jsonb_build_object('lat', s.map_lat, 'lng', s.map_lng) end,
    'revision', m.revision)
    from app.cells_meetings m
    left join app.cells_meeting_schedules s on s.cell_id = m.cell_id
   where m.meeting_id = p_meeting_id;
$$;

-- The command outcome of a meeting change: the actor's own staff view of it.
create function app.cells_meeting_outcome(p_meeting_id uuid, p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'cells_meeting',
    'aggregate_id', m.meeting_id,
    'revision', m.revision,
    'data', app.cells_meeting_json(m.meeting_id,
                                   app.cells_member_has_private_access(p_member_id, m.cell_id)))
    from app.cells_meetings m
   where m.meeting_id = p_meeting_id;
$$;

-- The schedule as staff see it (venue and pin only with private access).
create function app.cells_schedule_json(p_cell_id uuid, p_private boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'weekday', s.weekday,
    'start_time', to_char(s.start_time, 'HH24:MI'),
    'end_time', to_char(s.end_time, 'HH24:MI'),
    'from_date', to_char(s.from_date, 'YYYY-MM-DD'),
    'zone', s.zone,
    'policy_version', s.policy_version,
    'venue_set', true,
    'pin_set', s.map_lat is not null,
    'venue', case when p_private then s.venue end,
    'map_pin', case when p_private and s.map_lat is not null
                    then jsonb_build_object('lat', s.map_lat, 'lng', s.map_lng) end)
    from app.cells_meeting_schedules s
   where s.cell_id = p_cell_id;
$$;

-- The member's own cell meetings (My cell): the next meeting that is not cancelled, with its
-- venue and pin, and the cancelled meetings before it. Null when the member has no confirmed
-- cell or the cell has no schedule. Generates first.
create function app.cells_member_meetings(p_member_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cell uuid;
  v_next app.cells_meetings;
begin
  select m.cell_id into v_cell from app.cells_memberships m
   where m.member_id = p_member_id and m.ended_at is null;
  if v_cell is null or not app.cells_member_has_private_access(p_member_id, v_cell)
     or not exists (select 1 from app.cells_meeting_schedules s where s.cell_id = v_cell) then
    return null;
  end if;
  perform app.cells_generate_meetings(v_cell);
  select m.* into v_next from app.cells_meetings m
   where m.cell_id = v_cell and m.meeting_state in ('scheduled', 'moved') and m.ends_at > now()
   order by m.starts_at, m.meeting_id
   limit 1;
  return jsonb_build_object(
    'cell_id', v_cell,
    'next', case when v_next.meeting_id is not null
                 then app.cells_meeting_json(v_next.meeting_id, true) end,
    'cancelled', coalesce((
      select jsonb_agg(jsonb_build_object('meeting_id', m.meeting_id,
                                          'occurrence_date', to_char(m.occurrence_date, 'YYYY-MM-DD'),
                                          'nominal_starts_at', app.cmd_utc(m.nominal_starts_at))
                       order by m.nominal_starts_at, m.meeting_id)
        from app.cells_meetings m
       where m.cell_id = v_cell and m.meeting_state = 'cancelled' and m.nominal_starts_at > now()
         and (v_next.meeting_id is null or m.nominal_starts_at < v_next.starts_at)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- cells.set_schedule {cell_id, weekday, start_time, end_time, venue?, map_pin?, from_date?};
-- Admin only; expected = the cell revision. venue: required the first time, absent = keep.
-- map_pin: absent = keep, null = clear, {lat, lng} = set. from_date: default today (church).
create function app.cells_set_schedule(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_cell app.cells_cells;
  v_old app.cells_meeting_schedules;
  v_start time;
  v_end time;
  v_venue text;
  v_lat numeric;
  v_lng numeric;
  v_from date;
  v_policy jsonb;
  v_today date;
  v_revision bigint;
  v_pin jsonb := p_payload -> 'map_pin';
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
                array['cell_id', 'weekday', 'start_time', 'end_time', 'venue', 'map_pin', 'from_date']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  if not app.contract_integer_in(p_payload -> 'weekday', 1, 7) then
    v_errors := v_errors || '{"weekday": "out_of_range"}';
  end if;
  v_start := app.cells_clock(p_payload -> 'start_time');
  v_end := app.cells_clock(p_payload -> 'end_time');
  if v_start is null then
    v_errors := v_errors || '{"start_time": "invalid"}';
  end if;
  if v_end is null then
    v_errors := v_errors || '{"end_time": "invalid"}';
  elsif v_start is not null and v_end <= v_start then
    v_errors := v_errors || '{"end_time": "before_start"}';
  elsif v_start is not null and v_end - v_start > interval '6 hours' then
    v_errors := v_errors || '{"end_time": "too_long"}';
  end if;
  select t.errors, t.value into v_errors, v_venue from app.cells_venue(p_payload, 'venue', false, v_errors) t;
  if p_payload ? 'map_pin' and jsonb_typeof(v_pin) <> 'null' then
    if jsonb_typeof(v_pin) <> 'object'
       or app.contract_unknown_keys(v_pin, array['lat', 'lng']) <> '{}'::jsonb
       or jsonb_typeof(v_pin -> 'lat') <> 'number' or jsonb_typeof(v_pin -> 'lng') <> 'number'
       or (v_pin ->> 'lat')::numeric not between -90 and 90
       or (v_pin ->> 'lng')::numeric not between -180 and 180 then
      v_errors := v_errors || '{"map_pin": "invalid"}';
    else
      v_lat := round((v_pin ->> 'lat')::numeric, 5);
      v_lng := round((v_pin ->> 'lng')::numeric, 5);
    end if;
  end if;
  if p_payload ? 'from_date' then
    if jsonb_typeof(p_payload -> 'from_date') <> 'string'
       or app.contract_local_error(to_jsonb((p_payload ->> 'from_date') || 'T00:00:00')) is not null then
      v_errors := v_errors || '{"from_date": "invalid"}';
    else
      v_from := (p_payload ->> 'from_date')::date;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  -- The church zone and policy version (Q2). Closed in production: unavailable, nothing written.
  v_policy := app.notifications_policy();
  v_today := (now() at time zone (v_policy ->> 'zone'))::date;
  v_from := coalesce(v_from, v_today);
  if v_from > v_today + 366 then
    perform app.cmd_fail('validation_failed', '{"from_date": "out_of_range"}');
  end if;
  select c.* into v_cell from app.cells_cells c
   where c.cell_id = (p_payload ->> 'cell_id')::uuid for update;
  if not found or v_cell.cell_state <> 'active' then
    perform app.cmd_fail('not_found');
  end if;
  if v_cell.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_cell.revision);
  end if;
  select s.* into v_old from app.cells_meeting_schedules s where s.cell_id = v_cell.cell_id for update;
  if v_old.cell_id is null and v_venue is null then
    perform app.cmd_fail('validation_failed', '{"venue": "required"}');
  end if;
  insert into app.cells_meeting_schedules as s (cell_id, weekday, start_time, end_time, venue, map_lat,
                                                map_lng, from_date, zone, policy_version,
                                                set_by_member, set_by_account)
  -- The proposed row is complete (NOT NULL is checked before the conflict is resolved): an
  -- absent venue or pin keeps the current one.
  values (v_cell.cell_id, (p_payload ->> 'weekday')::numeric::smallint, v_start, v_end,
          coalesce(v_venue, v_old.venue),
          case when p_payload ? 'map_pin' then v_lat else v_old.map_lat end,
          case when p_payload ? 'map_pin' then v_lng else v_old.map_lng end,
          v_from, v_policy ->> 'zone', (v_policy ->> 'version')::integer,
          v_actor.member_id, v_actor.account_id)
  on conflict (cell_id) do update
    set weekday = excluded.weekday, start_time = excluded.start_time, end_time = excluded.end_time,
        venue = excluded.venue, map_lat = excluded.map_lat, map_lng = excluded.map_lng,
        from_date = excluded.from_date, zone = excluded.zone,
        policy_version = excluded.policy_version, set_by_member = excluded.set_by_member,
        set_by_account = excluded.set_by_account, updated_at = now();
  update app.cells_cells c set revision = c.revision + 1, updated_at = now()
   where c.cell_id = v_cell.cell_id
  returning c.revision into v_revision;
  perform app.cells_generate_meetings(v_cell.cell_id);
  perform app.cells_meeting_audit_row('schedule_set', v_cell.cell_id, null, v_actor.member_id,
                                      v_actor.account_id, 'admin', 'cells.set_schedule', v_revision);
  return app.cells_cell_outcome(v_cell.cell_id);
end;
$$;

-- Locks a meeting for a change by the cell's leader or an Admin and checks the revision.
create function app.cells_lock_meeting(p_payload jsonb, p_expected bigint, p_member_id uuid)
returns app.cells_meetings
language plpgsql
set search_path = ''
as $$
declare
  v_meeting app.cells_meetings;
begin
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = (p_payload ->> 'meeting_id')::uuid for update;
  if v_meeting.meeting_id is null or v_meeting.meeting_state = 'withdrawn' then
    perform app.cmd_fail('not_found');
  end if;
  if app.cells_meeting_capacity(p_member_id, v_meeting.cell_id) is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_meeting.revision <> p_expected then
    perform app.cmd_fail('conflict', null, v_meeting.revision);
  end if;
  return v_meeting;
end;
$$;

-- cells.move_meeting {meeting_id, starts_at, ends_at, venue?}; the cell's leader or an Admin;
-- expected = the meeting revision. venue: absent = keep, null = the regular venue, text = this
-- venue for this meeting only. The new start is in the future and within 30 days of the
-- nominal date; at most 6 hours long.
create function app.cells_move_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_starts timestamptz;
  v_ends timestamptz;
  v_venue text;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'starts_at', 'ends_at', 'venue']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if app.contract_instant_error(p_payload -> 'starts_at') is not null then
    v_errors := v_errors || jsonb_build_object('starts_at', app.contract_instant_error(p_payload -> 'starts_at'));
  else
    v_starts := (p_payload ->> 'starts_at')::timestamptz;
  end if;
  if app.contract_instant_error(p_payload -> 'ends_at') is not null then
    v_errors := v_errors || jsonb_build_object('ends_at', app.contract_instant_error(p_payload -> 'ends_at'));
  else
    v_ends := (p_payload ->> 'ends_at')::timestamptz;
  end if;
  if v_starts is not null and v_ends is not null then
    if v_ends <= v_starts then
      v_errors := v_errors || '{"ends_at": "before_start"}';
    elsif v_ends - v_starts > interval '6 hours' then
      v_errors := v_errors || '{"ends_at": "too_long"}';
    end if;
  end if;
  if v_starts is not null and v_starts <= now() then
    v_errors := v_errors || '{"starts_at": "past"}';
  end if;
  select t.errors, t.value into v_errors, v_venue from app.cells_venue(p_payload, 'venue', false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_meeting := app.cells_lock_meeting(p_payload, p_expected_revision, v_actor.member_id);
  v_capacity := app.cells_meeting_capacity(v_actor.member_id, v_meeting.cell_id);
  if v_meeting.meeting_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"meeting_id": "cancelled"}', v_meeting.revision);
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  if v_starts not between v_meeting.nominal_starts_at - interval '30 days'
                      and v_meeting.nominal_starts_at + interval '30 days' then
    perform app.cmd_fail('validation_failed', '{"starts_at": "out_of_range"}');
  end if;
  update app.cells_meetings m
     set meeting_state = 'moved', starts_at = v_starts, ends_at = v_ends,
         moved_venue = case when not (p_payload ? 'venue') then m.moved_venue else v_venue end,
         revision = m.revision + 1, changed_by_member = v_actor.member_id,
         changed_by_account = v_actor.account_id, changed_at = now(), updated_at = now()
   where m.meeting_id = v_meeting.meeting_id
  returning m.revision into v_revision;
  perform app.cells_meeting_audit_row('meeting_moved', v_meeting.cell_id,
                                      v_meeting.meeting_id, v_actor.member_id,
                                      v_actor.account_id, v_capacity, 'cells.move_meeting',
                                      v_revision);
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

-- cells.cancel_meeting {meeting_id}; the cell's leader or an Admin; expected = meeting revision.
create function app.cells_cancel_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_meeting := app.cells_lock_meeting(p_payload, p_expected_revision, v_actor.member_id);
  v_capacity := app.cells_meeting_capacity(v_actor.member_id, v_meeting.cell_id);
  if v_meeting.meeting_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"meeting_id": "cancelled"}', v_meeting.revision);
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  update app.cells_meetings m
     set meeting_state = 'cancelled', revision = m.revision + 1,
         changed_by_member = v_actor.member_id, changed_by_account = v_actor.account_id,
         changed_at = now(), updated_at = now()
   where m.meeting_id = v_meeting.meeting_id
  returning m.revision into v_revision;
  perform app.cells_meeting_audit_row('meeting_cancelled', v_meeting.cell_id,
                                      v_meeting.meeting_id, v_actor.member_id,
                                      v_actor.account_id, v_capacity, 'cells.cancel_meeting',
                                      v_revision);
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

-- cells.reinstate_meeting {meeting_id}; a cancelled meeting returns to its nominal time and the
-- regular venue. The cell's leader or an Admin; expected = meeting revision.
create function app.cells_reinstate_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_meeting := app.cells_lock_meeting(p_payload, p_expected_revision, v_actor.member_id);
  v_capacity := app.cells_meeting_capacity(v_actor.member_id, v_meeting.cell_id);
  if v_meeting.meeting_state <> 'cancelled' then
    perform app.cmd_fail('conflict', '{"meeting_id": "not_cancelled"}', v_meeting.revision);
  end if;
  if v_meeting.nominal_starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  update app.cells_meetings m
     set meeting_state = 'scheduled', starts_at = m.nominal_starts_at, ends_at = m.nominal_ends_at,
         moved_venue = null, revision = m.revision + 1, changed_by_member = v_actor.member_id,
         changed_by_account = v_actor.account_id, changed_at = now(), updated_at = now()
   where m.meeting_id = v_meeting.meeting_id
  returning m.revision into v_revision;
  perform app.cells_meeting_audit_row('meeting_reinstated', v_meeting.cell_id,
                                      v_meeting.meeting_id, v_actor.member_id,
                                      v_actor.account_id, v_capacity, 'cells.reinstate_meeting',
                                      v_revision);
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command entry point, authorizer and replay scope (replaced from 2.6)
-- ---------------------------------------------------------------------------------------------

create or replace function app.cells_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'cells.create_cell', 'cells.update_cell', 'cells.request_change', 'cells.confirm_request',
       'cells.decline_request', 'cells.cancel_request', 'cells.set_schedule', 'cells.move_meeting',
       'cells.cancel_meeting', 'cells.reinstate_meeting') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind in ('cell_leader', 'cell_assistant'))
     for share;
  return true;
end;
$$;

-- Replay recheck. Story 5.1: a meeting replay needs a current leader of its cell or an Admin.
create or replace function app.cells_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_cell uuid;
begin
  if p_aggregate_id is null then
    return false;
  end if;
  if p_aggregate_type = 'cells_cell' then
    return exists (select 1 from app.cells_cells c where c.cell_id = p_aggregate_id);
  elsif p_aggregate_type = 'cells_member_cell' then
    return exists (select 1 from app.cells_member_states s where s.member_id = p_aggregate_id);
  elsif p_aggregate_type = 'cells_meeting' then
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    select m.cell_id into v_cell from app.cells_meetings m where m.meeting_id = p_aggregate_id;
    return v_member is not null and v_cell is not null
       and app.cells_meeting_capacity(v_member, v_cell) is not null;
  end if;
  return false;
end;
$$;

create or replace function app.cells_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'cells.create_cell' then 'app.cells_create_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.update_cell' then 'app.cells_update_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.request_change' then 'app.cells_request_change(uuid, bigint, jsonb)'::regprocedure
      when 'cells.confirm_request' then 'app.cells_confirm_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.decline_request' then 'app.cells_decline_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_request' then 'app.cells_cancel_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.set_schedule' then 'app.cells_set_schedule(uuid, bigint, jsonb)'::regprocedure
      when 'cells.move_meeting' then 'app.cells_move_meeting(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_meeting' then 'app.cells_cancel_meeting(uuid, bigint, jsonb)'::regprocedure
      when 'cells.reinstate_meeting' then 'app.cells_reinstate_meeting(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell'
  );
end;
$$;

comment on function api.cells_command(jsonb) is
  'Stories 2.6 and 5.1: cell setup, membership requests, leader/Admin confirmation and atomic '
  'transfer (cells.create_cell, update_cell, request_change, confirm_request, decline_request, '
  'cancel_request), meeting schedules (set_schedule) and one-meeting exceptions (move_meeting, '
  'cancel_meeting, reinstate_meeting) through the 1.4 command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- Story 5.1: the member's own cell now also answers `meetings` (next meeting with venue, and
-- the cancelled meetings before it) for their confirmed cell.
create or replace function app.cells_my_cell()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  perform app.cells_sync_application_requests();
  perform app.identity_record_activity(v_link);
  return app.cells_member_json(v_member)
         || jsonb_build_object('meetings', app.cells_member_meetings(v_member));
end;
$$;

comment on function api.cells_my_cell() is
  'Stories 2.6 and 5.1: the signed-in member''s primary cell (safe label), open request, last '
  'decision and, for the confirmed cell, its next meeting with the private venue.';

-- Staff: the cells the caller may see with their schedule and meetings from today (church
-- time) for 12 weeks. Leaders and assistants: their cells with the venue. Admin: every cell,
-- the venue only where they also lead or assist it. `can_change`: leader or Admin.
create function app.cells_meetings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_admin boolean;
  v_cell uuid;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  if not v_admin and not exists (select 1 from app.identity_grants g
                                  where g.member_id = v_member and g.revoked_at is null
                                    and g.scope_kind in ('cell_leader', 'cell_assistant')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.cells_require_open_read();
  for v_cell in
    select c.cell_id from app.cells_cells c
      join app.cells_meeting_schedules s on s.cell_id = c.cell_id
     where c.cell_state = 'active'
       and (v_admin or app.cells_member_has_private_access(v_member, c.cell_id))
     order by c.cell_id
  loop
    perform app.cells_generate_meetings(v_cell);
  end loop;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object('cells', coalesce((
    select jsonb_agg(x.obj order by x.name, x.cell_id)
      from (
        select c.cell_id, c.name, jsonb_build_object(
                 'cell_id', c.cell_id,
                 'name', c.name,
                 'is_synthetic', c.is_synthetic,
                 'role', case
                           when app.identity_member_has_scope(v_member, 'cell_leader', c.cell_id) then 'leader'
                           when app.identity_member_has_scope(v_member, 'cell_assistant', c.cell_id) then 'assistant'
                           else 'admin' end,
                 'can_change', app.cells_meeting_capacity(v_member, c.cell_id) is not null,
                 'can_set_schedule', v_admin,
                 'cell_revision', case when v_admin then c.revision end,
                 'schedule', app.cells_schedule_json(
                               c.cell_id,
                               (app.identity_member_has_scope(v_member, 'cell_leader', c.cell_id)
                                or app.identity_member_has_scope(v_member, 'cell_assistant', c.cell_id))),
                 'meetings', coalesce((
                   select jsonb_agg(app.cells_meeting_json(
                                      m.meeting_id,
                                      (app.identity_member_has_scope(v_member, 'cell_leader', c.cell_id)
                                       or app.identity_member_has_scope(v_member, 'cell_assistant', c.cell_id)))
                                    order by m.starts_at, m.meeting_id)
                     from app.cells_meetings m
                    -- From the meeting that ended in the last day (today's, for the leader) to
                    -- the end of the generated window.
                    where m.cell_id = c.cell_id and m.meeting_state <> 'withdrawn'
                      and m.ends_at > now() - interval '1 day'
                      and m.nominal_starts_at < now() + interval '85 days'),
                   '[]'::jsonb)) as obj
          from app.cells_cells c
         where c.cell_state = 'active'
           and (not c.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
           and (v_admin
                or app.identity_member_has_scope(v_member, 'cell_leader', c.cell_id)
                or app.identity_member_has_scope(v_member, 'cell_assistant', c.cell_id))
      ) x), '[]'::jsonb));
end;
$$;

create function api.cells_meetings()
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.cells_meetings();
$$;

comment on function api.cells_meetings() is
  'Story 5.1: staff cell meetings: leaders/assistants their cells with venue; Admin every cell '
  'with schedule metadata (venue_set) only; the next 12 weeks of meetings with stable ids.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced from 2.11): the new tables' actor ids are anonymised too
-- ---------------------------------------------------------------------------------------------

create or replace function app.cells_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_left integer;
begin
  if p_input ->> 'phase' = 'erase' then
    perform app.cells_deletion_purge_rows(v_member);
    if v_account is not null then
      update app.cells_membership_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_memberships m set confirmed_by_account = v_nil
       where m.confirmed_by_account = v_account;
      update app.cells_membership_requests r set requested_by_account = v_nil
       where r.requested_by_account = v_account;
      update app.cells_membership_requests r set decided_by_account = v_nil
       where r.decided_by_account = v_account;
      update app.cells_meeting_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_meetings m set changed_by_account = v_nil
       where m.changed_by_account = v_account;
      update app.cells_meeting_schedules s set set_by_account = v_nil
       where s.set_by_account = v_account;
    end if;
    -- Story 5.1: meeting actors are attributed facts; the person is anonymised.
    update app.cells_meeting_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.cells_meetings m set changed_by_member = v_nil where m.changed_by_member = v_member;
    update app.cells_meeting_schedules s set set_by_member = v_nil where s.set_by_member = v_member;
  end if;
  select (select count(*) from app.cells_memberships m where m.member_id = v_member)
       + (select count(*) from app.cells_membership_requests r where r.member_id = v_member)
       + (select count(*) from app.cells_member_states s where s.member_id = v_member)
       + (select count(*) from app.cells_meeting_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_meetings m where m.changed_by_member = v_member)
       + (select count(*) from app.cells_meeting_schedules s where s.set_by_member = v_member)
       + case when v_account is null then 0 else
           (select count(*) from app.cells_membership_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_memberships m where m.confirmed_by_account = v_account)
         + (select count(*) from app.cells_membership_requests r
             where r.requested_by_account = v_account or r.decided_by_account = v_account)
         + (select count(*) from app.cells_meeting_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_meetings m where m.changed_by_account = v_account)
         + (select count(*) from app.cells_meeting_schedules s where s.set_by_account = v_account)
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

comment on function app.cells_erase_member(jsonb) is
  'Cells deletion hook (stories 2.11 and 5.1): erase or check the member''s Cells personal data; '
  'meeting schedule and meeting actors are anonymised.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_meeting_state_ok(text),
  app.cells_generate_meetings(uuid),
  app.cells_meeting_capacity(uuid, uuid),
  app.cells_venue(jsonb, text, boolean, jsonb),
  app.cells_clock(jsonb),
  app.cells_meeting_audit_row(text, uuid, uuid, uuid, uuid, text, text, bigint),
  app.cells_meeting_json(uuid, boolean),
  app.cells_meeting_outcome(uuid, uuid),
  app.cells_schedule_json(uuid, boolean),
  app.cells_member_meetings(uuid),
  app.cells_set_schedule(uuid, bigint, jsonb),
  app.cells_lock_meeting(jsonb, bigint, uuid),
  app.cells_in_scope(uuid, text, uuid),
  app.cells_move_meeting(uuid, bigint, jsonb),
  app.cells_cancel_meeting(uuid, bigint, jsonb),
  app.cells_reinstate_meeting(uuid, bigint, jsonb),
  app.cells_meetings(),
  api.cells_meetings()
  from public, anon, authenticated, service_role;

grant execute on function app.cells_meetings() to authenticated;
grant execute on function api.cells_meetings() to authenticated;

notify pgrst, 'reload schema';
