-- Story 5.2: meeting reminders and change notices (epic 5, requirements C2 and C1). Builds on
-- 20261021073514_cells_meetings.sql and the Notifications seams of epic 3
-- (20261008090057 source contracts, 20261008102121 scheduling, 20261008135811 routing).
--
--   * Source `cells_meeting` (source id = meeting id, revision = meeting revision) with one
--     reminder kind and two notices, all with generic text and the `/my-cell` link:
--       cells_meeting_reminder   start-anchored, planned per confirmed member through
--                                app.notifications_set_schedule (an answered `response` schedule,
--                                so only start reminders exist and members may snooze them);
--       cells_meeting_changed    moved, brought back, or re-timed by a schedule change;
--       cells_meeting_cancelled  cancelled, or withdrawn by a schedule change.
--   * Reminders per cell (app.cells_meeting_schedules.reminders, null = the default of one
--     reminder 24 hours before the start): cells.set_meeting_reminders by the cell's leader or an
--     Admin, expected = the schedule's reminders_revision.
--   * Planning (app.cells_plan_meeting) runs in every meeting command, in set_schedule and, for
--     meetings or members not planned at the current revision, on every meetings read. Commands
--     fail closed when the Q2 policy is not usable; reads then skip planning.
--   * Direct-contact route: held and accountless members' needs land in
--     app.cells_meeting_contact_needs and are listed by name for the cell's leader and assistant.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Tables and columns
-- ---------------------------------------------------------------------------------------------

alter table app.cells_meeting_schedules
  add column reminders jsonb check (reminders is null or jsonb_typeof(reminders) = 'array'),
  add column reminders_revision bigint not null default 1 check (reminders_revision >= 1);

comment on column app.cells_meeting_schedules.reminders is
  'Story 5.2: the cell''s meeting reminders as [{"before": "<n> minutes|hours|days"}] (at most 3, '
  'at most 7 days); null = one reminder 24 hours before the start.';

alter table app.cells_meeting_audit drop constraint cells_meeting_audit_action_check;
alter table app.cells_meeting_audit add constraint cells_meeting_audit_action_check
  check (action in ('schedule_set', 'meeting_moved', 'meeting_cancelled', 'meeting_reinstated',
                    'reminders_set'));

create table app.cells_meeting_contact_needs (
  need_id uuid primary key,
  meeting_id uuid not null references app.cells_meetings (meeting_id),
  member_id uuid not null,
  source_revision bigint not null check (source_revision >= 1),
  reminder_kind text not null check (length(reminder_kind) between 1 and 63),
  scheduled_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index cells_meeting_contact_needs_meeting on app.cells_meeting_contact_needs (meeting_id, source_revision);

comment on table app.cells_meeting_contact_needs is
  'owner: cells. Story 5.2: meeting reminders and notices Notifications could not deliver in the '
  'app (held, in review or accountless member): the leader tells the member directly.';

alter table app.cells_meeting_contact_needs enable row level security;
revoke all on table app.cells_meeting_contact_needs from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Source registration (3.2 contracts, 3.5 route)
-- ---------------------------------------------------------------------------------------------

-- The source check: the meeting exists and is at that revision.
create function app.cells_meeting_source_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  select m.revision into v_revision from app.cells_meetings m
   where m.meeting_id::text = p_source ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_revision);
end;
$$;

-- The reminder check for every Cells meeting kind. Current: the meeting is at the job's
-- revision. Actionable: a reminder or change notice while the meeting is on and ahead; a
-- cancellation notice while its usual time is ahead. Eligible: the recipient is currently a
-- confirmed member of the meeting's cell.
create function app.cells_meeting_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_meeting app.cells_meetings;
  v_current boolean;
  v_kind text := p_key ->> 'reminder_kind';
begin
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  v_current := v_meeting.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_meeting.revision,
    'actionable', v_current and case
                    when v_kind = 'cells_meeting_cancelled'
                      then v_meeting.meeting_state in ('cancelled', 'withdrawn')
                           and v_meeting.nominal_starts_at > now()
                    else v_meeting.meeting_state in ('scheduled', 'moved') and v_meeting.starts_at > now()
                  end,
    'recipient_eligible', exists (select 1 from app.cells_memberships cm
                                   where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                                     and cm.member_id::text = p_key ->> 'recipient_member_id'));
end;
$$;

-- Direct-contact route: idempotent on need_id; never locks the meeting.
create function app.cells_record_meeting_contact_need(p_need jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_need ->> 'source_type' is distinct from 'cells_meeting' then
    return;
  end if;
  insert into app.cells_meeting_contact_needs (need_id, meeting_id, member_id, source_revision,
                                               reminder_kind, scheduled_at)
  select (p_need ->> 'need_id')::uuid, m.meeting_id, (p_need ->> 'recipient_member_id')::uuid,
         (p_need ->> 'source_revision')::numeric::bigint, p_need ->> 'reminder_kind',
         (p_need ->> 'scheduled_at')::timestamptz
    from app.cells_meetings m
   where m.meeting_id = (p_need ->> 'source_id')::uuid
  on conflict (need_id) do nothing;
end;
$$;

select app.contract_register_source_type(
  'cells', 'cells_meeting', 'app.cells_meeting_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('cells', 'cells_meeting', 'cells_meeting_reminder');
select app.contract_register_reminder_contract(
  'cells', 'cells_meeting', 'cells_meeting_reminder',
  'app.cells_meeting_reminder_check(jsonb)'::regprocedure,
  '{"title": "Cell meeting coming up",
    "body": "Your cell meets soon. Open My cell for the time and place.",
    "link": "/my-cell"}'::jsonb);
select app.contract_register_reminder_kind('cells', 'cells_meeting', 'cells_meeting_changed');
select app.contract_register_reminder_contract(
  'cells', 'cells_meeting', 'cells_meeting_changed',
  'app.cells_meeting_reminder_check(jsonb)'::regprocedure,
  '{"title": "Cell meeting changed",
    "body": "A meeting of your cell has changed. Open My cell to see when and where it is now.",
    "link": "/my-cell"}'::jsonb);
select app.contract_register_reminder_kind('cells', 'cells_meeting', 'cells_meeting_cancelled');
select app.contract_register_reminder_contract(
  'cells', 'cells_meeting', 'cells_meeting_cancelled',
  'app.cells_meeting_reminder_check(jsonb)'::regprocedure,
  '{"title": "Cell meeting cancelled",
    "body": "A meeting of your cell is cancelled. Open My cell to see the next one.",
    "link": "/my-cell"}'::jsonb);
select app.contract_register_direct_contact_route('cells', 'cells_meeting', k,
                                                  'app.cells_record_meeting_contact_need(jsonb)'::regprocedure)
  from unnest(array['cells_meeting_reminder', 'cells_meeting_changed', 'cells_meeting_cancelled']) k;

-- ---------------------------------------------------------------------------------------------
-- Planning
-- ---------------------------------------------------------------------------------------------

-- Whether the Q2 scheduling policy is usable now (reads plan only then).
create function app.cells_reminders_available()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.notifications_policy_errors(app.policy_effective('q2_church_time') -> 'value') = '{}'::jsonb;
$$;

-- The 3.3 reminder specs of a cell: its own offsets, or one reminder 24 hours before the start.
create function app.cells_reminder_specs(p_reminders jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((select jsonb_agg(jsonb_build_object('anchor', 'starts_at', 'before', r ->> 'before'))
                     from jsonb_array_elements(p_reminders) r),
                  '[{"anchor": "starts_at", "before": "24 hours"}]'::jsonb);
$$;

-- Plans one meeting's reminders for the cell's current confirmed members, ends the schedules
-- of anyone who is no longer one, and with p_notice enqueues that notice to every member now.
-- Runs after the caller changed (and locked) the meeting; Notifications last (AD-2).
create function app.cells_plan_meeting(p_meeting_id uuid, p_notice text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_meeting app.cells_meetings;
  v_specs jsonb;
  v_member uuid;
  v_planned integer := 0;
  v_ended integer := 0;
  v_notices integer := 0;
  v_on boolean;
begin
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = p_meeting_id;
  if not found then
    return '{"planned": 0}'::jsonb;
  end if;
  select app.cells_reminder_specs(s.reminders) into v_specs
    from app.cells_meeting_schedules s where s.cell_id = v_meeting.cell_id;
  v_on := v_meeting.meeting_state in ('scheduled', 'moved') and v_meeting.starts_at > now();
  if not v_on then
    -- Nothing to remind: end every schedule of this meeting (its pending reminders go too).
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'cells_meeting', 'source_id', v_meeting.meeting_id,
      'reason', case when v_meeting.meeting_state in ('cancelled', 'withdrawn')
                     then 'source_cancelled' else 'source_expired' end));
  else
    -- The meeting is on (again): a cancellation notice still waiting is out of date.
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'cells_meeting', 'source_id', v_meeting.meeting_id,
      'reminder_kind', 'cells_meeting_cancelled', 'reason', 'source_revised'));
    for v_member in
      select cm.member_id from app.cells_memberships cm
       where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
       order by cm.member_id
    loop
      perform app.notifications_set_schedule(jsonb_build_object(
        'source_type', 'cells_meeting', 'source_id', v_meeting.meeting_id,
        'source_revision', v_meeting.revision, 'recipient_member_id', v_member,
        'schedule_type', 'response',
        'intent', jsonb_build_object('assigned_at', app.cmd_utc(least(now(), v_meeting.starts_at)),
                                     'starts_at', app.cmd_utc(v_meeting.starts_at),
                                     'responded', true, 'reminders', v_specs),
        'kinds', '{"starts_at": "cells_meeting_reminder"}'::jsonb,
        'fresh', false));
      v_planned := v_planned + 1;
    end loop;
  end if;
  -- Anyone with a live schedule who is no longer a confirmed member of the cell.
  for v_member in
    select distinct s.recipient_member_id from app.notifications_schedules s
     where s.source_type = 'cells_meeting' and s.source_id = v_meeting.meeting_id
       and s.schedule_state = 'active'
       and not exists (select 1 from app.cells_memberships cm
                        where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                          and cm.member_id = s.recipient_member_id)
     order by s.recipient_member_id
  loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'cells_meeting', 'source_id', v_meeting.meeting_id,
      'recipient_member_id', v_member, 'reason', 'not_recipient'));
    v_ended := v_ended + 1;
  end loop;
  if p_notice is not null then
    for v_member in
      select cm.member_id from app.cells_memberships cm
       where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
       order by cm.member_id
    loop
      perform app.notifications_enqueue(jsonb_build_object(
        'source_type', 'cells_meeting', 'source_id', v_meeting.meeting_id,
        'source_revision', v_meeting.revision, 'recipient_member_id', v_member,
        'reminder_kind', p_notice, 'scheduled_at', app.cmd_utc(now())));
      v_notices := v_notices + 1;
    end loop;
  end if;
  return jsonb_build_object('planned', v_planned, 'ended', v_ended, 'notices', v_notices);
end;
$$;

-- Plans the cell's future meetings that are not planned at their current revision for every
-- current confirmed member, or that still remind someone who left. Returns the meetings planned.
create function app.cells_sync_meeting_reminders(p_cell_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_meeting uuid;
  v_count integer := 0;
begin
  for v_meeting in
    select m.meeting_id from app.cells_meetings m
     where m.cell_id = p_cell_id and m.meeting_state in ('scheduled', 'moved') and m.starts_at > now()
       and (exists (select 1 from app.cells_memberships cm
                     where cm.cell_id = m.cell_id and cm.ended_at is null
                       and not exists (select 1 from app.notifications_schedules s
                                        where s.source_type = 'cells_meeting'
                                          and s.source_id = m.meeting_id
                                          and s.recipient_member_id = cm.member_id
                                          and s.source_revision = m.revision
                                          and s.schedule_state = 'active')
                       and not exists (select 1 from app.identity_deletions d
                                        where d.member_id = cm.member_id))
            or exists (select 1 from app.notifications_schedules s
                        where s.source_type = 'cells_meeting' and s.source_id = m.meeting_id
                          and s.schedule_state = 'active'
                          and not exists (select 1 from app.cells_memberships cm
                                           where cm.cell_id = m.cell_id and cm.ended_at is null
                                             and cm.member_id = s.recipient_member_id)))
     order by m.starts_at, m.meeting_id
  loop
    perform app.cells_plan_meeting(v_meeting, null);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Generation (replaced from 5.1): re-timed and withdrawn meetings are re-planned, with a notice
-- for those in the next 14 days, and missing plans are filled in. Ids are unchanged.
-- ---------------------------------------------------------------------------------------------

create or replace function app.cells_generate_meetings(p_cell_id uuid)
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
  v_changed uuid[] := '{}';
  v_withdrawn uuid[] := '{}';
  v_id uuid;
  x jsonb;
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
  v_plan boolean;
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
    v_id := null;
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
      -- 5.1 review fix: a withdrawn meeting comes back when its NEW time is still ahead.
      where (m.meeting_state = 'withdrawn' and excluded.starts_at > now())
         or (m.meeting_state <> 'withdrawn' and m.starts_at > now()
             and (m.nominal_starts_at, m.nominal_ends_at)
                 is distinct from (excluded.nominal_starts_at, excluded.nominal_ends_at))
    returning (m.xmax = 0), m.meeting_id into v_inserted, v_id;
    if v_inserted then
      v_created := v_created + 1;
    elsif v_id is not null then
      v_changed := v_changed || v_id;
    end if;
  end loop;
  -- Future scheduled dates the rule no longer produces (a changed weekday or first date).
  with w as (
    update app.cells_meetings m
       set meeting_state = 'withdrawn', revision = m.revision + 1, updated_at = now()
     where m.cell_id = p_cell_id and m.meeting_state = 'scheduled' and m.starts_at > now()
       and not (m.occurrence_date = any (v_dates))
    returning m.meeting_id)
  select coalesce(array_agg(w.meeting_id), '{}') into v_withdrawn from w;
  -- Story 5.2: reminders and notices follow, when the Q2 policy is usable.
  v_plan := app.cells_reminders_available();
  if v_plan then
    foreach v_id in array v_changed || v_withdrawn loop
      perform app.cells_plan_meeting(
        v_id,
        (select case
                  when m.nominal_starts_at > now() + interval '14 days' then null
                  when m.meeting_state = 'withdrawn' then 'cells_meeting_cancelled'
                  when m.meeting_state = 'scheduled' then 'cells_meeting_changed'
                end
           from app.cells_meetings m where m.meeting_id = v_id));
    end loop;
    perform app.cells_sync_meeting_reminders(p_cell_id);
  end if;
  return v_created;
end;
$$;

comment on function app.cells_generate_meetings(uuid) is
  'Stories 5.1 and 5.2: (re)generates a cell''s meetings for today plus 84 days in church time '
  '(ids stable by cell and date; exceptions and started meetings never changed), then re-plans '
  'reminders for changed meetings and fills in missing plans when the Q2 policy is usable.';

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- cells.set_meeting_reminders {cell_id, reminders: [{before}] | null}; the cell's leader or an
-- Admin; expected = the schedule's reminders_revision. Re-plans the cell's future meetings.
create function app.cells_set_meeting_reminders(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_schedule app.cells_meeting_schedules;
  v_capacity text;
  v_reminders jsonb := p_payload -> 'reminders';
  v_meeting uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['cell_id', 'reminders']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  if not (p_payload ? 'reminders') then
    v_errors := v_errors || '{"reminders": "required"}';
  elsif jsonb_typeof(v_reminders) = 'null' then
    v_reminders := null;
  elsif jsonb_typeof(v_reminders) <> 'array' or jsonb_array_length(v_reminders) > 3
        or exists (select 1 from jsonb_array_elements(v_reminders) r
                    where jsonb_typeof(r) <> 'object'
                       or app.contract_unknown_keys(r, array['before']) <> '{}'::jsonb
                       or app.notifications_duration_error(r -> 'before') is not null) then
    v_errors := v_errors || '{"reminders": "invalid"}';
  elsif exists (select 1 from jsonb_array_elements(v_reminders) r
                 where app.notifications_duration_minutes(r ->> 'before') > 7 * 1440)
        or (select count(distinct app.notifications_duration_minutes(r ->> 'before'))
              from jsonb_array_elements(v_reminders) r) <> jsonb_array_length(v_reminders) then
    v_errors := v_errors || '{"reminders": "out_of_range"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select s.* into v_schedule from app.cells_meeting_schedules s
   where s.cell_id = (p_payload ->> 'cell_id')::uuid for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.cells_meeting_capacity(v_actor.member_id, v_schedule.cell_id);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_schedule.reminders_revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_schedule.reminders_revision);
  end if;
  -- An empty list is "no reminders"; store it as given.
  update app.cells_meeting_schedules s
     set reminders = v_reminders, reminders_revision = s.reminders_revision + 1, updated_at = now()
   where s.cell_id = v_schedule.cell_id
  returning s.reminders_revision into v_revision;
  -- Fail closed (unavailable) when the Q2 policy is not usable: nothing is written.
  perform app.notifications_policy();
  for v_meeting in
    select m.meeting_id from app.cells_meetings m
     where m.cell_id = v_schedule.cell_id and m.meeting_state in ('scheduled', 'moved')
       and m.starts_at > now()
     order by m.starts_at
  loop
    perform app.cells_plan_meeting(v_meeting, null);
  end loop;
  perform app.cells_meeting_audit_row('reminders_set', v_schedule.cell_id, null, v_actor.member_id,
                                      v_actor.account_id, v_capacity, 'cells.set_meeting_reminders',
                                      v_revision);
  return jsonb_build_object(
    'aggregate_type', 'cells_meeting_reminders',
    'aggregate_id', v_schedule.cell_id,
    'revision', v_revision,
    'data', jsonb_build_object('cell_id', v_schedule.cell_id, 'reminders', v_reminders,
                               'reminders_revision', v_revision));
end;
$$;

-- cells.set_schedule (replaced from 5.1). 5.1 review fix (medium): a pin without `lat` or `lng`
-- is `validation_failed {"map_pin": "invalid"}` (the 5.1 check let a missing key through as
-- unknown); `{}` is invalid too. Otherwise 5.1's body.
create or replace function app.cells_set_schedule(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
       or jsonb_typeof(v_pin -> 'lat') is distinct from 'number'
       or jsonb_typeof(v_pin -> 'lng') is distinct from 'number'
       or not ((v_pin ->> 'lat')::numeric between -90 and 90)
       or not ((v_pin ->> 'lng')::numeric between -180 and 180) then
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

-- The three meeting changes (replaced from 5.1) now re-plan reminders and send their notice in
-- the same transaction. Bodies are 5.1's with the planning call added before the outcome.
create or replace function app.cells_move_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  perform app.cells_plan_meeting(v_meeting.meeting_id, 'cells_meeting_changed');
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

create or replace function app.cells_cancel_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  -- 5.1 review fix (high): a moved venue belongs to a moved meeting only (table check); a
  -- reinstated meeting returns to the usual venue anyway.
  update app.cells_meetings m
     set meeting_state = 'cancelled', revision = m.revision + 1, moved_venue = null,
         changed_by_member = v_actor.member_id, changed_by_account = v_actor.account_id,
         changed_at = now(), updated_at = now()
   where m.meeting_id = v_meeting.meeting_id
  returning m.revision into v_revision;
  perform app.cells_meeting_audit_row('meeting_cancelled', v_meeting.cell_id,
                                      v_meeting.meeting_id, v_actor.member_id,
                                      v_actor.account_id, v_capacity, 'cells.cancel_meeting',
                                      v_revision);
  perform app.cells_plan_meeting(v_meeting.meeting_id, 'cells_meeting_cancelled');
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

create or replace function app.cells_reinstate_meeting(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  perform app.cells_plan_meeting(v_meeting.meeting_id, 'cells_meeting_changed');
  return app.cells_meeting_outcome(v_meeting.meeting_id, v_actor.member_id);
end;
$$;

-- Authorizer and dispatch (replaced): cells.set_meeting_reminders added.
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
       'cells.cancel_meeting', 'cells.reinstate_meeting', 'cells.set_meeting_reminders') then
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

-- Replay recheck (replaced): the reminders aggregate needs a current leader of the cell or an
-- Admin, like a meeting.
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
  elsif p_aggregate_type in ('cells_meeting', 'cells_meeting_reminders') then
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    if p_aggregate_type = 'cells_meeting' then
      select m.cell_id into v_cell from app.cells_meetings m where m.meeting_id = p_aggregate_id;
    else
      select s.cell_id into v_cell from app.cells_meeting_schedules s where s.cell_id = p_aggregate_id;
    end if;
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
      when 'cells.set_meeting_reminders' then 'app.cells_set_meeting_reminders(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell'
  );
end;
$$;

comment on function api.cells_command(jsonb) is
  'Stories 2.6, 5.1 and 5.2: cell setup, membership requests, leader/Admin confirmation and '
  'atomic transfer, meeting schedules, one-meeting exceptions (move, cancel, reinstate, each with '
  'its change notice) and the cell''s meeting reminders (set_meeting_reminders) through the 1.4 '
  'command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads (replaced from 5.1)
-- ---------------------------------------------------------------------------------------------

-- The schedule as staff see it, now with the cell's reminders and their revision.
create or replace function app.cells_schedule_json(p_cell_id uuid, p_private boolean)
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
                    then jsonb_build_object('lat', s.map_lat, 'lng', s.map_lng) end,
    'reminders', coalesce(s.reminders, '[{"before": "24 hours"}]'::jsonb),
    'reminders_default', s.reminders is null,
    'reminders_revision', s.reminders_revision)
    from app.cells_meeting_schedules s
   where s.cell_id = p_cell_id;
$$;

-- A meeting's members to tell directly (the cell's leader and assistant only): distinct members
-- with a need at the meeting's current revision.
create function app.cells_meeting_contact_json(p_meeting_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', x.member_id, 'display_name', x.display_name,
                                               'kinds', x.kinds)
                            order by x.display_name, x.member_id), '[]'::jsonb)
    from (
      select n.member_id, im.display_name,
             jsonb_agg(distinct n.reminder_kind) as kinds
        from app.cells_meeting_contact_needs n
        join app.cells_meetings m on m.meeting_id = n.meeting_id and m.revision = n.source_revision
        join app.identity_members im on im.member_id = n.member_id
       where n.meeting_id = p_meeting_id
       group by n.member_id, im.display_name
    ) x;
$$;

create or replace function app.cells_meetings()
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
                 'schedule', app.cells_schedule_json(c.cell_id, p.private),
                 'meetings', coalesce((
                   select jsonb_agg(app.cells_meeting_json(m.meeting_id, p.private)
                                    || jsonb_build_object('contact_needs',
                                         case when p.private then app.cells_meeting_contact_json(m.meeting_id)
                                              else '[]'::jsonb end)
                                    order by m.starts_at, m.meeting_id)
                     from app.cells_meetings m
                    -- From the meeting that ended in the last day (today's, for the leader) to
                    -- the end of the generated window.
                    where m.cell_id = c.cell_id and m.meeting_state <> 'withdrawn'
                      and m.ends_at > now() - interval '1 day'
                      and m.nominal_starts_at < now() + interval '85 days'),
                   '[]'::jsonb)) as obj
          from app.cells_cells c
          cross join lateral (
            select app.identity_member_has_scope(v_member, 'cell_leader', c.cell_id)
                   or app.identity_member_has_scope(v_member, 'cell_assistant', c.cell_id) as private) p
         where c.cell_state = 'active'
           and (not c.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
           and (v_admin or p.private)
      ) x), '[]'::jsonb));
end;
$$;

comment on function api.cells_meetings() is
  'Stories 5.1 and 5.2: staff cell meetings: leaders/assistants their cells with venue and the '
  'members to tell directly; Admin every cell with schedule metadata (venue_set) only; the next '
  '12 weeks with stable ids; the cell''s reminders.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced): contact needs keep no member id
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
    -- Story 5.2: a contact need is kept as an anonymous fact.
    update app.cells_meeting_contact_needs n set member_id = v_nil where n.member_id = v_member;
  end if;
  select (select count(*) from app.cells_memberships m where m.member_id = v_member)
       + (select count(*) from app.cells_membership_requests r where r.member_id = v_member)
       + (select count(*) from app.cells_member_states s where s.member_id = v_member)
       + (select count(*) from app.cells_meeting_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_meetings m where m.changed_by_member = v_member)
       + (select count(*) from app.cells_meeting_schedules s where s.set_by_member = v_member)
       + (select count(*) from app.cells_meeting_contact_needs n where n.member_id = v_member)
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
  'Cells deletion hook (stories 2.11, 5.1 and 5.2): erase or check the member''s Cells personal '
  'data; meeting schedule and meeting actors and meeting contact needs are anonymised.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_meeting_source_check(jsonb),
  app.cells_meeting_reminder_check(jsonb),
  app.cells_record_meeting_contact_need(jsonb),
  app.cells_reminders_available(),
  app.cells_reminder_specs(jsonb),
  app.cells_plan_meeting(uuid, text),
  app.cells_sync_meeting_reminders(uuid),
  app.cells_set_meeting_reminders(uuid, bigint, jsonb),
  app.cells_meeting_contact_json(uuid)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
