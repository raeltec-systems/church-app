-- Follow-up review finding F8 (2026-10-28): moved meetings missed venue-change notices.
-- app.cells_set_schedule (replaced from 20261028130929) changes the schedule's place, runs
-- generation, then notices meetings that show the schedule's place. Two cases were missed:
--
--   * A combined time and venue edit: generation revises a moved meeting's nominal fields
--     (it keeps its own time) without a notice, and the place fallback skipped any meeting
--     generation had revised. The fallback now notices such a moved meeting at the revision
--     generation gave it (no second revision); a scheduled meeting generation re-timed keeps
--     generation's one notice.
--   * Eligibility tested the nominal start: a meeting nominally 20 days away but moved to
--     tomorrow got no notice. The 14-day window now uses the meeting's effective start.
--
-- Notices stay keyed by revision (never sent twice); meetings with their own venue, past,
-- cancelled and withdrawn meetings are still left alone; a planning refusal (PCMD1) is logged
-- and skipped. app.cells_generate_meetings is unchanged.
--
-- No table, no destructive statement, no row deletion. ASCII only, no backslashes.

-- (Replaced; copied from 20261028130929_cells_schedule_place_notices.sql.) The changes are
-- marked "Review finding F8 (follow-up)" and "Follow-up review finding F8".
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
  -- Review finding F8: whether the place changed, and each future meeting's revision before
  -- generation (a meeting the generator re-times gets its notice there, never twice).
  v_new app.cells_meeting_schedules;
  v_place_changed boolean := false;
  v_before jsonb;
  v_id uuid;
  -- Follow-up review finding F8: whether the place fallback must move the revision itself.
  v_bump boolean;
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
  select s.* into v_new from app.cells_meeting_schedules s where s.cell_id = v_cell.cell_id;
  v_place_changed := v_old.cell_id is not null
    and (v_new.venue, v_new.map_lat, v_new.map_lng) is distinct from (v_old.venue, v_old.map_lat, v_old.map_lng);
  if v_place_changed then
    select coalesce(jsonb_object_agg(m.meeting_id::text, m.revision), '{}'::jsonb) into v_before
      from app.cells_meetings m
     where m.cell_id = v_cell.cell_id and m.meeting_state in ('scheduled', 'moved')
       and m.starts_at > now();
  end if;
  perform app.cells_generate_meetings(v_cell.cell_id);
  -- Review finding F8 (follow-up): a venue or map pin change is a meeting change for every
  -- future scheduled or moved meeting that shows the schedule's place (no venue override of its
  -- own; the pin is shown only then). A meeting generation did not revise gets a new revision
  -- here. A moved meeting generation did revise (its nominal fields only; it keeps its own time)
  -- got no notice there, so it gets its notice at that revision. A scheduled meeting generation
  -- re-timed already had its one notice there. Within the next 14 days of the meeting's
  -- effective start (not its nominal one), each confirmed member gets one cells_meeting_changed
  -- notice keyed by the revision, so it is never sent twice. Past, cancelled, withdrawn and
  -- overridden meetings are left alone. As in generation, a planning refusal never fails the
  -- command.
  if v_place_changed then
    for v_id, v_bump in
      select m.meeting_id, (v_before ->> m.meeting_id::text)::bigint = m.revision
        from app.cells_meetings m
       where m.cell_id = v_cell.cell_id and m.meeting_state in ('scheduled', 'moved')
         and m.starts_at > now() and m.moved_venue is null
         and v_before ? m.meeting_id::text
         and ((v_before ->> m.meeting_id::text)::bigint = m.revision or m.meeting_state = 'moved')
       order by m.starts_at, m.meeting_id
    loop
      if v_bump then
        update app.cells_meetings m set revision = m.revision + 1, updated_at = now()
         where m.meeting_id = v_id;
      end if;
      if app.cells_reminders_available() then
        begin
          perform app.cells_plan_meeting(
            v_id,
            (select case when m.starts_at > now() + interval '14 days' then null
                         else 'cells_meeting_changed' end
               from app.cells_meetings m where m.meeting_id = v_id));
        exception when sqlstate 'PCMD1' then
          raise log 'cells meeting notice not planned for a meeting (sqlstate PCMD1)';
        end;
      end if;
    end loop;
  end if;
  perform app.cells_meeting_audit_row('schedule_set', v_cell.cell_id, null, v_actor.member_id,
                                      v_actor.account_id, 'admin', 'cells.set_schedule', v_revision);
  return app.cells_cell_outcome(v_cell.cell_id);
end;
$$;
