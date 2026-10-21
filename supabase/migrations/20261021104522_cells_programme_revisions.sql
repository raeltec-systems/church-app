-- Story 5.6: publish material programme revisions atomically and flag department mismatches
-- (epic 5, C5 and C1). Builds on 20261021094249_cells_programme_publish.sql and
-- 20261021101323_cells_youre_on.sql.
--
--   * A published programme can be changed and published again. Saving keeps it Published (members
--     keep reading the last publish) and marks unpublished changes; publishing revises each part
--     through the 4.11 owner operations in one transaction: Duties decides what is material (time,
--     label, place, person: the person is asked again, a prior acceptance kept in history) and what
--     is notes-only (topic and scripture: answers kept); a part removed since the last publish is
--     cancelled through Duties (or its display link ended); a part cannot switch between a person
--     and a department duty once published (`parts.<i>: published_kind`; remove it and add another).
--   * A linked department duty is never changed: when its part's time or label, or the meeting's
--     time or venue, changed since the last publish, or the part is removed or the programme
--     cancelled, the department is flagged for review (duties_owner_flag_review) instead.
--   * A meeting move by the cell's leader shifts a published programme's parts like a draft's and
--     marks the change; the staff page says the meeting moved and the leader publishes the revision
--     (Admin alone still cannot move or cancel a meeting with a published programme; cancelling such
--     a meeting stays refused until the programme is cancelled).
--   * Members keep reading the last publish; the member read says when the meeting changed since.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

alter table app.cells_programmes
  add column published_starts_at timestamptz,
  add column published_ends_at timestamptz,
  add column published_venue text;

alter table app.cells_programme_parts
  add column published_label text,
  add column published_starts_at timestamptz,
  add column published_ends_at timestamptz,
  add column published_slot_id uuid,
  add column published_kind text check (published_kind is null or published_kind in ('owned', 'linked'));

comment on column app.cells_programme_parts.published_kind is
  'Story 5.6: how the part was last published (owned slot or department link); with the other '
  'published_* columns, what a revision is compared with.';

-- A removed part keeps answering its Duties source check, so its occurrence can be cancelled through
-- Duties when the revision that removed it is published. Only Cells' own commands call Duties for a
-- part, and never put a removed one.

create or replace function app.cells_programme_part_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object('current', p.revision = (p_source ->> 'source_revision')::numeric::bigint,
                              'revision', p.revision)
      from app.cells_programme_parts pt
      join app.cells_programmes p on p.programme_id = pt.programme_id
     where pt.part_id::text = p_source ->> 'source_id'),
    '{"current": false, "revision": null}'::jsonb);
$$;

-- A meeting's new start moves a draft's or a published programme's live parts (5.6: the published
-- one then has unpublished changes; its Duties occurrences move when the leader publishes).
create or replace function app.cells_programme_follow_meeting()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_programme uuid;
begin
  if new.starts_at is not distinct from old.starts_at then
    return null;
  end if;
  select p.programme_id into v_programme from app.cells_programmes p
   where p.meeting_id = new.meeting_id and p.programme_state in ('draft', 'published')
     for update;
  if v_programme is null then
    return null;
  end if;
  update app.cells_programme_parts pt
     set starts_at = pt.starts_at + (new.starts_at - old.starts_at),
         ends_at = pt.ends_at + (new.starts_at - old.starts_at),
         updated_at = now()
   where pt.programme_id = v_programme and pt.removed_at is null;
  update app.cells_programmes p set revision = p.revision + 1, updated_at = now()
   where p.programme_id = v_programme;
  return null;
end;
$$;

-- 5.6 review fix 2: a change of the meeting's end or venue (not its start) also marks a draft or
-- published programme as changed (revision bumped, so an open editor gets a conflict and a
-- published one shows the meeting changed). A start change is handled above.
create function app.cells_programme_note_meeting()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.starts_at is distinct from old.starts_at
     or (new.ends_at, new.moved_venue) is not distinct from (old.ends_at, old.moved_venue) then
    return null;
  end if;
  update app.cells_programmes p set revision = p.revision + 1, updated_at = now()
   where p.meeting_id = new.meeting_id and p.programme_state in ('draft', 'published');
  return null;
end;
$$;

create trigger cells_meetings_programme_note
  after update of ends_at, moved_venue on app.cells_meetings
  for each row execute function app.cells_programme_note_meeting();


-- (Replaced from 5.4.) A schedule change no longer withdraws a meeting whose programme is published.
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
      -- Only a future meeting changes, and only when the rule moved it or brings it back. A
      -- withdrawn meeting comes back when its new time is still ahead.
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
       -- 5.6 review fix 1: a meeting with a published programme is kept (its duties stay true);
       -- the leader cancels the programme, then the meeting.
       and not exists (select 1 from app.cells_programmes p
                        where p.meeting_id = m.meeting_id and p.programme_state = 'published')
    returning m.meeting_id)
  select coalesce(array_agg(w.meeting_id), '{}') into v_withdrawn from w;
  -- Reminders and notices follow when the Q2 policy is usable; a refusal never fails the caller
  -- and costs at most the one meeting it concerns.
  if app.cells_reminders_available() then
    foreach v_id in array v_changed || v_withdrawn loop
      begin
        perform app.cells_plan_meeting(
          v_id,
          (select case
                    when m.nominal_starts_at > now() + interval '14 days' then null
                    when m.meeting_state = 'withdrawn' then 'cells_meeting_cancelled'
                    when m.meeting_state = 'scheduled' then 'cells_meeting_changed'
                  end
             from app.cells_meetings m where m.meeting_id = v_id));
      exception when sqlstate 'PCMD1' then
        raise log 'cells meeting notice not planned for a meeting (sqlstate PCMD1)';
      end;
    end loop;
    begin
      perform app.cells_sync_meeting_reminders(p_cell_id);
    exception when sqlstate 'PCMD1' then
      raise log 'cells meeting reminders not planned for a cell (sqlstate PCMD1)';
    end;
  end if;
  return v_created;
end;
$$;

-- (Replaced from 5.4.) Moving is allowed for the cell's leader or assistant; see the header.
create or replace function app.cells_meeting_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  if coalesce(current_setting('cells.command', true), '') in ('cells.move_meeting', 'cells.cancel_meeting')
     and (new.starts_at, new.ends_at, new.meeting_state, new.moved_venue)
         is distinct from (old.starts_at, old.ends_at, old.meeting_state, old.moved_venue)
     and exists (select 1 from app.cells_programmes p
                  where p.meeting_id = new.meeting_id and p.programme_state = 'published') then
    -- Story 5.6: the cell's leader or assistant may move it (the programme follows and is
    -- published again by them); a cancellation, or anyone else, is still refused.
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    if new.meeting_state = 'cancelled'
       or app.cells_programme_capacity(v_member, new.cell_id) is null then
      perform app.cmd_fail('conflict', '{"meeting_id": "programme_published"}', old.revision);
    end if;
  end if;
  return new;
end;
$$;

-- (Replaced from 5.4.) Adds `unpublished_changes` and `meeting_changed` for a published programme.
create or replace function app.cells_programme_json(p_programme_id uuid, p_full boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_full then
    jsonb_build_object(
      'programme_id', p.programme_id,
      'meeting_id', p.meeting_id,
      'state', p.programme_state,
      'revision', p.revision,
      'published_revision', p.published_revision,
      'published_at', case when p.published_at is not null then app.cmd_utc(p.published_at) end,
      -- Story 5.6: changes not yet published, and whether the meeting moved since.
      'unpublished_changes', p.programme_state = 'published' and p.revision > p.published_revision,
      'meeting_changed', p.programme_state = 'published' and exists (
        select 1 from app.cells_meetings m
          left join app.cells_meeting_schedules s on s.cell_id = m.cell_id
         where m.meeting_id = p.meeting_id
           and (m.starts_at, m.ends_at, coalesce(m.moved_venue, s.venue))
               is distinct from (p.published_starts_at, p.published_ends_at, p.published_venue)),
      'topic', p.topic,
      'scripture', p.scripture,
      'study_notes', p.study_notes,
      'parts', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'part_id', pt.part_id,
                 'position', pt.position,
                 'label', pt.label,
                 'starts_at', app.cmd_utc(pt.starts_at),
                 'ends_at', app.cmd_utc(pt.ends_at),
                 'assignee', case when pt.assignee_member_id is not null then jsonb_build_object(
                                'member_id', pt.assignee_member_id,
                                'display_name', (select im.display_name from app.identity_members im
                                                  where im.member_id = pt.assignee_member_id),
                                'in_cell', exists (select 1 from app.cells_memberships cm
                                                    where cm.cell_id = p.cell_id and cm.ended_at is null
                                                      and cm.member_id = pt.assignee_member_id)) end,
                 'linked_slot_id', pt.linked_slot_id,
                 'linked_label', pt.linked_label)
               order by pt.position)
          from app.cells_programme_parts pt
         where pt.programme_id = p.programme_id and pt.removed_at is null), '[]'::jsonb),
      'gaps', (select count(*)::int from app.cells_programme_parts pt
                where pt.programme_id = p.programme_id and pt.removed_at is null
                  and pt.assignee_member_id is null and pt.linked_slot_id is null))
  else
    jsonb_build_object(
      'programme_id', p.programme_id,
      'meeting_id', p.meeting_id,
      'state', p.programme_state,
      'revision', p.revision,
      'part_count', (select count(*)::int from app.cells_programme_parts pt
                      where pt.programme_id = p.programme_id and pt.removed_at is null),
      'gaps', (select count(*)::int from app.cells_programme_parts pt
                where pt.programme_id = p.programme_id and pt.removed_at is null
                  and pt.assignee_member_id is null and pt.linked_slot_id is null))
  end
    from app.cells_programmes p
   where p.programme_id = p_programme_id;
$$;

-- cells.save_programme (replaced from 5.4): a published programme is saved too (see the header);
-- a published part keeps its kind. Otherwise 5.4's body.
create or replace function app.cells_save_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_lock record;
  v_peek uuid;
  v_programme app.cells_programmes;
  v_meeting app.cells_meetings;
  v_zone text;
  v_date date;
  v_meeting_start time;
  v_crosses boolean;
  v_topic record;
  v_scripture record;
  v_notes record;
  v_parts jsonb := p_payload -> 'parts';
  v_rows jsonb := '[]'::jsonb;
  v_linkable jsonb;
  v_linked jsonb;
  x jsonb;
  i integer := 0;
  v_label record;
  v_start time;
  v_end time;
  v_starts timestamptz;
  v_ends timestamptz;
  v_prev_start timestamptz;
  v_prev_end timestamptz;
  v_seen uuid[] := '{}';
  v_part_id uuid;
  v_assignee uuid;
  v_slot uuid;
  v_slot_label text;
  v_kind text;
  v_code text;
  v_revision bigint;
  r jsonb;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['programme_id', 'topic', 'scripture', 'study_notes', 'parts']);
  if app.contract_uuid_error(p_payload -> 'programme_id') is not null then
    v_errors := v_errors || jsonb_build_object('programme_id', app.contract_uuid_error(p_payload -> 'programme_id'));
  end if;
  select * into v_topic from app.cells_free_text(p_payload -> 'topic', 120, false);
  select * into v_scripture from app.cells_free_text(p_payload -> 'scripture', 120, false);
  select * into v_notes from app.cells_free_text(p_payload -> 'study_notes', 2000, true);
  v_errors := v_errors || jsonb_strip_nulls(jsonb_build_object(
                'topic', v_topic.error, 'scripture', v_scripture.error, 'study_notes', v_notes.error));
  if jsonb_typeof(v_parts) is distinct from 'array' then
    v_errors := v_errors || jsonb_build_object('parts', case when v_parts is null then 'required' else 'invalid' end);
  elsif jsonb_array_length(v_parts) > 20 then
    v_errors := v_errors || '{"parts": "too_many"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  -- Meeting before programme (as create and the meeting commands lock them).
  select p.meeting_id into v_peek from app.cells_programmes p
   where p.programme_id = (p_payload ->> 'programme_id')::uuid;
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = v_peek for share;
  select l.programme, l.capacity into v_lock
    from app.cells_lock_programme(p_payload, p_expected_revision, v_actor.member_id) l;
  v_programme := v_lock.programme;
  -- Story 5.6: a published programme is changed too (members keep the last publish until the
  -- leader publishes again); a cancelled one is not.
  if v_programme.programme_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"programme_id": "not_draft"}', v_programme.revision);
  end if;
  if v_meeting.meeting_state in ('cancelled', 'withdrawn') then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  select coalesce((select s.zone from app.cells_meeting_schedules s where s.cell_id = v_meeting.cell_id),
                  'Africa/Lusaka') into v_zone;
  v_date := (v_meeting.starts_at at time zone v_zone)::date;
  v_meeting_start := (v_meeting.starts_at at time zone v_zone)::time;
  v_crosses := (v_meeting.ends_at at time zone v_zone)::date > v_date;
  -- Validate every part; collect the rows to write.
  for x in select e from jsonb_array_elements(v_parts) e loop
    v_code := null;
    v_part_id := null;
    v_assignee := null;
    v_slot := null;
    v_slot_label := null;
    v_kind := null;
    if jsonb_typeof(x) <> 'object'
       or app.contract_unknown_keys(x, array['part_id', 'label', 'start_time', 'end_time',
                                             'duration_minutes', 'assignee_member_id',
                                             'linked_slot_id']) <> '{}'::jsonb then
      v_code := 'invalid';
    end if;
    if v_code is null then
      select * into v_label from app.cells_free_text(x -> 'label', 60, false);
      v_start := app.cells_clock(x -> 'start_time');
      if v_label.error is not null then
        v_code := 'label_' || v_label.error;
      elsif v_label.value is null then
        v_code := 'label_required';
      elsif v_start is null then
        v_code := 'start_invalid';
      elsif (x ? 'end_time') = (x ? 'duration_minutes') then
        v_code := 'end_or_duration';
      elsif x ? 'end_time' and app.cells_clock(x -> 'end_time') is null then
        v_code := 'end_invalid';
      elsif x ? 'duration_minutes' and not app.contract_integer_in(x -> 'duration_minutes', 1, 360) then
        v_code := 'duration_invalid';
      end if;
    end if;
    if v_code is null then
      -- A time before the meeting's local start belongs to the next day when the meeting runs
      -- past midnight (fix 2).
      v_starts := (v_date + v_start + case when v_crosses and v_start < v_meeting_start
                                           then interval '1 day' else interval '0' end) at time zone v_zone;
      if x ? 'end_time' then
        v_end := app.cells_clock(x -> 'end_time');
        v_ends := (v_date + v_end + case when v_crosses and v_end < v_meeting_start
                                         then interval '1 day' else interval '0' end) at time zone v_zone;
      else
        v_ends := v_starts + make_interval(mins => (x ->> 'duration_minutes')::numeric::integer);
      end if;
      if v_ends <= v_starts then
        v_code := 'end_before_start';
      elsif v_starts < v_meeting.starts_at or v_ends > v_meeting.ends_at then
        v_code := 'outside_meeting';
      elsif v_prev_start is not null and v_starts < v_prev_start then
        v_code := 'out_of_order';
      elsif v_prev_end is not null and v_starts < v_prev_end then
        v_code := 'overlap';
      end if;
    end if;
    if v_code is null and x ? 'part_id' and jsonb_typeof(x -> 'part_id') <> 'null' then
      if app.contract_uuid_error(x -> 'part_id') is not null then
        v_code := 'part_unknown';
      else
        v_part_id := (x ->> 'part_id')::uuid;
        if v_part_id = any (v_seen) then
          v_code := 'part_duplicate';
        elsif not exists (select 1 from app.cells_programme_parts pt
                           where pt.part_id = v_part_id and pt.programme_id = v_programme.programme_id
                             and pt.removed_at is null) then
          v_code := 'part_unknown';
        else
          select pt.published_kind into v_kind from app.cells_programme_parts pt
           where pt.part_id = v_part_id;
        end if;
      end if;
    end if;
    if v_code is null and x ? 'assignee_member_id' and jsonb_typeof(x -> 'assignee_member_id') <> 'null' then
      if app.contract_uuid_error(x -> 'assignee_member_id') is not null then
        v_code := 'assignee_not_in_cell';
      else
        v_assignee := (x ->> 'assignee_member_id')::uuid;
        if not exists (select 1 from app.cells_memberships cm
                        where cm.cell_id = v_programme.cell_id and cm.ended_at is null
                          and cm.member_id = v_assignee) then
          v_code := 'assignee_not_in_cell';
        end if;
      end if;
    end if;
    if v_code is null and x ? 'linked_slot_id' and jsonb_typeof(x -> 'linked_slot_id') <> 'null' then
      if v_assignee is not null then
        v_code := 'assignee_and_link';
      elsif app.contract_uuid_error(x -> 'linked_slot_id') is not null then
        v_code := 'link_unavailable';
      else
        v_slot := (x ->> 'linked_slot_id')::uuid;
        if v_linkable is null then
          v_linkable := app.cells_linkable(v_meeting);
        end if;
        select e into v_linked from jsonb_array_elements(v_linkable) e
         where (e ->> 'slot_id')::uuid = v_slot;
        if v_linked is null then
          v_code := 'link_unavailable';
        else
          v_slot_label := left(coalesce(v_linked ->> 'department_name', 'Department') || ': '
                               || (v_linked ->> 'duty_name')
                               || coalesce(' (' || (v_linked ->> 'position_name') || ')', ''), 200);
        end if;
      end if;
    end if;
    -- Story 5.6: a published part keeps its kind (a person's slot or a department link).
    if v_code is null and v_kind is not null
       and (v_kind = 'linked') <> (v_slot is not null) then
      v_code := 'published_kind';
    end if;
    if v_code is not null then
      v_errors := v_errors || jsonb_build_object('parts.' || i, v_code);
    else
      v_prev_start := v_starts;
      v_prev_end := v_ends;
      if v_part_id is not null then
        v_seen := v_seen || v_part_id;
      end if;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
                  'part_id', v_part_id, 'position', i + 1, 'label', v_label.value,
                  'starts_at', v_starts, 'ends_at', v_ends, 'assignee', v_assignee,
                  'slot', v_slot, 'slot_label', v_slot_label));
    end if;
    i := i + 1;
  end loop;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  -- Write: every live part is set aside first (positions free), then the sent parts are written
  -- back in order; parts not sent stay removed.
  update app.cells_programme_parts pt set removed_at = now(), updated_at = now()
   where pt.programme_id = v_programme.programme_id and pt.removed_at is null;
  for r in select e from jsonb_array_elements(v_rows) e loop
    if r ->> 'part_id' is not null then
      update app.cells_programme_parts pt
         set removed_at = null, position = (r ->> 'position')::smallint, label = r ->> 'label',
             starts_at = (r ->> 'starts_at')::timestamptz, ends_at = (r ->> 'ends_at')::timestamptz,
             assignee_member_id = (r ->> 'assignee')::uuid,
             linked_slot_id = (r ->> 'slot')::uuid, linked_label = r ->> 'slot_label',
             updated_at = now()
       where pt.part_id = (r ->> 'part_id')::uuid;
    else
      insert into app.cells_programme_parts (programme_id, position, label, starts_at, ends_at,
                                             assignee_member_id, linked_slot_id, linked_label)
      values (v_programme.programme_id, (r ->> 'position')::smallint, r ->> 'label',
              (r ->> 'starts_at')::timestamptz, (r ->> 'ends_at')::timestamptz, (r ->> 'assignee')::uuid,
              (r ->> 'slot')::uuid, r ->> 'slot_label');
    end if;
  end loop;
  update app.cells_programmes p
     set topic = v_topic.value, scripture = v_scripture.value, study_notes = v_notes.value,
         revision = p.revision + 1, updated_by_member = v_actor.member_id,
         updated_by_account = v_actor.account_id, updated_at = now()
   where p.programme_id = v_programme.programme_id
  returning p.revision into v_revision;
  perform app.cells_programme_audit_row('programme_saved', v_programme, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity, 'cells.save_programme',
                                        v_revision);
  return app.cells_programme_outcome(v_programme.programme_id);
end;
$$;

-- What a part published now is compared with next time.
create function app.cells_mark_published(p_part app.cells_programme_parts, p_kind text)
returns void
language sql
set search_path = ''
as $$
  update app.cells_programme_parts pt
     set published_kind = p_kind, published_label = p_part.label,
         published_starts_at = p_part.starts_at, published_ends_at = p_part.ends_at,
         published_slot_id = p_part.linked_slot_id
   where pt.part_id = p_part.part_id;
$$;

-- The Duties side of one part (replaced from 5.4 with a new argument, so a new function): a part
-- removed since the last publish ends; a department link flags its department when `p_changed`
-- (time, label, place) is not empty; otherwise 5.4's put or link.
create function app.cells_publish_part(p_part app.cells_programme_parts, p_programme app.cells_programmes,
                                       p_venue text, p_override_reason text, p_changed text[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ref jsonb := app.cells_part_ref(p_part.part_id, p_programme.revision, p_programme.cell_id);
  v_existing jsonb;
  v_link jsonb;
  v_result jsonb;
begin
  v_existing := app.duties_owner_part(v_ref);
  -- Story 5.6: a part removed since the last publish ends in Duties: its slot cancelled, or its
  -- department told and the display link ended.
  if p_part.removed_at is not null then
    if p_part.published_kind = 'owned' and jsonb_typeof(v_existing -> 'occurrence') = 'object'
       and v_existing #>> '{occurrence,state}' <> 'cancelled' then
      perform app.duties_owner_cancel_part(v_ref || jsonb_build_object(
        'expected_revision', v_existing #> '{occurrence,revision}'));
    elsif exists (select 1 from jsonb_array_elements(v_existing -> 'positions') e
                   where e ->> 'kind' = 'linked') then
      perform app.duties_owner_flag_review(v_ref || '{"changed": ["cancelled"]}'::jsonb);
      perform app.duties_owner_unlink(v_ref || '{"position_key": "department"}'::jsonb);
    end if;
    update app.cells_programme_parts pt set published_kind = null where pt.part_id = p_part.part_id;
    return jsonb_build_object('part_id', p_part.part_id, 'kind', 'removed', 'changed', true);
  end if;
  if p_part.linked_slot_id is not null then
    select e into v_link from jsonb_array_elements(v_existing -> 'positions') e
     where e ->> 'kind' = 'linked' and e ->> 'position_key' = 'department';
    if v_link is not null and (v_link ->> 'slot_id')::uuid = p_part.linked_slot_id then
      -- Story 5.6: the same department duty, but its part or the meeting changed since the last
      -- publish: its department reviews it (the duty itself is never changed).
      if p_changed <> '{}' then
        perform app.duties_owner_flag_review(v_ref || jsonb_build_object('changed', to_jsonb(p_changed)));
      end if;
      perform app.cells_mark_published(p_part, 'linked');
      return jsonb_build_object('part_id', p_part.part_id, 'kind', 'linked',
                                'changed', p_changed <> '{}', 'flagged', to_jsonb(p_changed),
                                'slot_id', p_part.linked_slot_id);
    end if;
    if v_link is not null then
      -- Another department duty now: the old one is told the part no longer shows it.
      perform app.duties_owner_flag_review(v_ref || '{"changed": ["cancelled"]}'::jsonb);
      perform app.duties_owner_unlink(v_ref || '{"position_key": "department"}'::jsonb);
    end if;
    v_result := app.duties_owner_link_duty(v_ref || jsonb_build_object(
                  'position_key', 'department', 'slot_id', p_part.linked_slot_id));
    perform app.cells_mark_published(p_part, 'linked');
    return jsonb_build_object('part_id', p_part.part_id, 'kind', 'linked', 'changed', true,
                              'slot_id', p_part.linked_slot_id);
  end if;
  v_result := app.duties_owner_put_part(v_ref || jsonb_build_object(
    'expected_revision', v_existing #> '{occurrence,revision}',
    'duty_name', p_part.label,
    'starts_at', app.cmd_utc(p_part.starts_at),
    'ends_at', app.cmd_utc(p_part.ends_at),
    'location', p_venue,
    'topic', p_programme.topic,
    'scripture', p_programme.scripture,
    'override_reason', p_override_reason,
    'positions', jsonb_build_array(jsonb_build_object(
                   'position_key', 'lead', 'member_id', p_part.assignee_member_id))));
  update app.cells_programme_parts pt
     set duty_occurrence_id = (v_result ->> 'occurrence_id')::uuid
   where pt.part_id = p_part.part_id and pt.duty_occurrence_id is distinct from (v_result ->> 'occurrence_id')::uuid;
  perform app.cells_mark_published(p_part, 'owned');
  return jsonb_build_object('part_id', p_part.part_id, 'kind', 'owned',
                            'changed', coalesce((v_result ->> 'created')::boolean, false)
                                       or coalesce((v_result ->> 'changed')::boolean, false),
                            'occurrence_id', v_result -> 'occurrence_id',
                            'positions', v_result -> 'positions');
end;
$$;

-- The key a part's refusal is reported under: `parts.<index>` for a live part, `removed_parts.<id>`
-- for one removed since the last publish (5.6 review fix 4).
create function app.cells_part_key(p_part app.cells_programme_parts)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_part.removed_at is null then 'parts.' || (p_part.position - 1)
              else 'removed_parts.' || p_part.part_id end;
$$;


-- cells.publish_programme (replaced from 5.4): also publishes a revision (see the header).
create or replace function app.cells_publish_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_peek app.cells_programmes;
  v_meeting app.cells_meetings;
  v_lock record;
  v_programme app.cells_programmes;
  v_part app.cells_programme_parts;
  v_venue text;
  v_results jsonb := '[]'::jsonb;
  v_out jsonb;
  v_reason record;
  v_msg text;
  v_detail text;
  v_before bigint;
  v_meeting_changed text[];
  v_changed text[];
begin
  -- (5.6 review fix 4: a refusal of a part removed since the last publish is keyed by its id.)
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['programme_id', 'override_reason']);
  select * into v_reason from app.cells_free_text(p_payload -> 'override_reason', 280, false);
  if v_reason.error is not null then
    v_errors := v_errors || jsonb_build_object('override_reason', v_reason.error);
  end if;
  if app.contract_uuid_error(p_payload -> 'programme_id') is not null then
    v_errors := v_errors || jsonb_build_object('programme_id', app.contract_uuid_error(p_payload -> 'programme_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select p.* into v_peek from app.cells_programmes p
   where p.programme_id = (p_payload ->> 'programme_id')::uuid;
  if v_peek.programme_id is null then
    perform app.cmd_fail('not_found');
  end if;
  -- AD-2, people first (duties.md, review S2): the Duties session share-locks the actor and the
  -- cell's current assignees (and refuses anyone but the cell's leader or assistant); the parts'
  -- assignees are locked too. Only then Cells' own rows: the meeting, then the programme.
  perform 1 from app.duties_owner_session(v_peek.cell_id);
  perform app.duties_lock_people(array(
    select pt.assignee_member_id from app.cells_programme_parts pt
     where pt.programme_id = v_peek.programme_id and pt.removed_at is null
       and pt.assignee_member_id is not null));
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = v_peek.meeting_id for share;
  select l.programme, l.capacity into v_lock
    from app.cells_lock_programme(p_payload, p_expected_revision, v_actor.member_id) l;
  v_programme := v_lock.programme;
  v_before := v_programme.revision;
  if v_programme.programme_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"programme_id": "cancelled"}', v_programme.revision);
  end if;
  if v_meeting.meeting_state in ('cancelled', 'withdrawn') then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  if not exists (select 1 from app.cells_programme_parts pt
                  where pt.programme_id = v_programme.programme_id and pt.removed_at is null) then
    perform app.cmd_fail('validation_failed', '{"parts": "required"}');
  end if;
  -- A part outside the meeting (it was shortened since the last save), or an assignee who left
  -- the cell, is refused on its part (5.4 review fix 5).
  select coalesce(jsonb_object_agg('parts.' || (pt.position - 1),
                    case when pt.starts_at < v_meeting.starts_at or pt.ends_at > v_meeting.ends_at
                         then 'outside_meeting' else 'assignee_not_in_cell' end), '{}'::jsonb)
    into v_errors
    from app.cells_programme_parts pt
   where pt.programme_id = v_programme.programme_id and pt.removed_at is null
     and (pt.starts_at < v_meeting.starts_at or pt.ends_at > v_meeting.ends_at
          or (pt.assignee_member_id is not null
              and not exists (select 1 from app.cells_memberships cm
                               where cm.cell_id = v_programme.cell_id and cm.ended_at is null
                                 and cm.member_id = pt.assignee_member_id)));
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  update app.cells_programmes p
     set programme_state = 'published', revision = p.revision + 1,
         published_revision = p.revision + 1, published_at = now(),
         published_by_member = v_actor.member_id, published_by_account = v_actor.account_id,
         updated_by_member = v_actor.member_id, updated_by_account = v_actor.account_id,
         updated_at = now()
   where p.programme_id = v_programme.programme_id
  returning * into v_programme;
  v_venue := coalesce(v_meeting.moved_venue,
                      (select s.venue from app.cells_meeting_schedules s where s.cell_id = v_meeting.cell_id));
  -- Story 5.6: what changed for every linked department duty since the last publish.
  v_meeting_changed := array_remove(array[
    case when (v_meeting.starts_at, v_meeting.ends_at) is distinct from
              (v_programme.published_starts_at, v_programme.published_ends_at)
              and v_programme.published_starts_at is not null then 'time' end,
    case when v_venue is distinct from v_programme.published_venue
              and v_programme.published_starts_at is not null then 'place' end], null);
  -- Live parts in order, then the parts removed since the last publish (they end in Duties).
  for v_part in
    select pt.* from app.cells_programme_parts pt
     where pt.programme_id = v_programme.programme_id
       and (pt.removed_at is null or pt.published_kind is not null)
     order by (pt.removed_at is not null), pt.position, pt.part_id
  loop
    v_changed := array(select distinct c from unnest(v_meeting_changed || array_remove(array[
                   case when v_part.published_kind = 'linked'
                             and (v_part.starts_at, v_part.ends_at)
                                 is distinct from (v_part.published_starts_at, v_part.published_ends_at)
                        then 'time' end,
                   case when v_part.published_kind = 'linked' and v_part.label is distinct from v_part.published_label
                        then 'label' end], null)) c order by c);
    begin
      v_results := v_results || jsonb_build_array(
                     app.cells_publish_part(v_part, v_programme, v_venue, v_reason.value, v_changed));
    exception when sqlstate 'PCMD1' then
      get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
      -- 5.4 review fixes 3 and 6: a department position that is gone is answered on its part; a
      -- Duties conflict (changed meanwhile) carries the programme's revision, not the duty's.
      if v_msg = 'not_found' and v_part.linked_slot_id is not null then
        perform app.cmd_fail('validation_failed', jsonb_build_object(
          app.cells_part_key(v_part) || '.linked_slot_id', 'link_unavailable'));
      elsif v_msg = 'conflict' then
        perform app.cmd_fail('conflict', null, v_before);
      elsif v_msg <> 'validation_failed' then
        raise;
      end if;
      perform app.cmd_fail('validation_failed', coalesce((
        select jsonb_object_agg(app.cells_part_key(v_part) || '.' || e.key, e.value)
          from jsonb_each(v_detail::jsonb -> 'field_errors') e),
        jsonb_build_object(app.cells_part_key(v_part), 'refused')));
    end;
  end loop;
  update app.cells_programmes p
     set published_starts_at = v_meeting.starts_at, published_ends_at = v_meeting.ends_at,
         published_venue = v_venue
   where p.programme_id = v_programme.programme_id;
  insert into app.cells_programme_projections as pr (programme_id, meeting_id, cell_id, revision, body,
                                                     published_at)
  values (v_programme.programme_id, v_programme.meeting_id, v_programme.cell_id, v_programme.revision,
          app.cells_programme_projection(v_programme.programme_id), v_programme.published_at)
  on conflict (programme_id) do update
    set revision = excluded.revision, body = excluded.body, published_at = excluded.published_at,
        withdrawn_at = null;
  perform app.cells_programme_audit_row('programme_published', v_programme, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity,
                                        'cells.publish_programme', v_programme.revision);
  v_out := app.cells_programme_outcome(v_programme.programme_id);
  return jsonb_set(v_out, '{data,duties}', v_results);
end;
$$;

-- cells.cancel_programme (replaced from 5.4): a linked department duty is flagged for its
-- department's review before its display link ends. Otherwise 5.4's body.
create or replace function app.cells_cancel_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_peek app.cells_programmes;
  v_lock record;
  v_revision bigint;
  v_part app.cells_programme_parts;
  v_ref jsonb;
  v_existing jsonb;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['programme_id']);
  if app.contract_uuid_error(p_payload -> 'programme_id') is not null then
    v_errors := v_errors || jsonb_build_object('programme_id', app.contract_uuid_error(p_payload -> 'programme_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select p.* into v_peek from app.cells_programmes p
   where p.programme_id = (p_payload ->> 'programme_id')::uuid;
  if v_peek.programme_id is not null and v_peek.programme_state = 'published' then
    perform 1 from app.duties_owner_session(v_peek.cell_id);
  end if;
  select l.programme, l.capacity into v_lock
    from app.cells_lock_programme(p_payload, p_expected_revision, v_actor.member_id) l;
  if (v_lock.programme).programme_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"programme_id": "cancelled"}', (v_lock.programme).revision);
  end if;
  update app.cells_programmes p
     set programme_state = 'cancelled', revision = p.revision + 1,
         updated_by_member = v_actor.member_id, updated_by_account = v_actor.account_id,
         updated_at = now()
   where p.programme_id = (v_lock.programme).programme_id
  returning p.revision into v_revision;
  if (v_lock.programme).programme_state = 'published' then
    if v_peek.programme_state is distinct from 'published' then
      -- Published by someone else between the first read and the lock: lock people now.
      perform 1 from app.duties_owner_session((v_lock.programme).cell_id);
    end if;
    for v_part in
      -- Story 5.6: parts removed since the last publish still have their Duties side.
      select pt.* from app.cells_programme_parts pt
       where pt.programme_id = (v_lock.programme).programme_id
         and (pt.removed_at is null or pt.published_kind is not null)
       order by pt.position, pt.part_id
    loop
      v_ref := app.cells_part_ref(v_part.part_id, v_revision, (v_lock.programme).cell_id);
      v_existing := app.duties_owner_part(v_ref);
      if v_existing -> 'occurrence' is not null and jsonb_typeof(v_existing -> 'occurrence') = 'object'
         and v_existing #>> '{occurrence,state}' <> 'cancelled' then
        if (v_existing #>> '{occurrence,started}')::boolean then
          perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
        end if;
        perform app.duties_owner_cancel_part(v_ref || jsonb_build_object(
          'expected_revision', v_existing #> '{occurrence,revision}'));
      elsif exists (select 1 from jsonb_array_elements(v_existing -> 'positions') e
                     where e ->> 'kind' = 'linked') then
        -- Story 5.6: the department is told the programme no longer shows its duty.
        perform app.duties_owner_flag_review(v_ref || '{"changed": ["cancelled"]}'::jsonb);
        perform app.duties_owner_unlink(v_ref || '{"position_key": "department"}'::jsonb);
      end if;
    end loop;
    update app.cells_programme_projections pr set withdrawn_at = now()
     where pr.programme_id = (v_lock.programme).programme_id and pr.withdrawn_at is null;
  end if;
  perform app.cells_programme_audit_row('programme_cancelled', v_lock.programme, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity,
                                        'cells.cancel_programme', v_revision);
  return app.cells_programme_outcome((v_lock.programme).programme_id);
end;
$$;

-- api.cells_meeting_programme (replaced from 5.5): says when the meeting moved since the publish.
create or replace function app.cells_meeting_programme(p_meeting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_meeting app.cells_meetings;
  v_projection app.cells_programme_projections;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = p_meeting_id and m.meeting_state <> 'withdrawn';
  if v_meeting.meeting_id is null
     or not exists (select 1 from app.cells_memberships cm
                     where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                       and cm.member_id = v_member) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select pr.* into v_projection from app.cells_programme_projections pr
   where pr.meeting_id = v_meeting.meeting_id and pr.withdrawn_at is null;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, true),
    'programme', case when v_projection.programme_id is not null then
                   v_projection.body || jsonb_build_object(
                     'revision', v_projection.revision,
                     'published_at', app.cmd_utc(v_projection.published_at),
                     -- Story 5.6: the meeting moved since this was published (the leader
                     -- publishes the revision).
                     'meeting_changed', exists (
                       select 1 from app.cells_programmes p
                         left join app.cells_meeting_schedules s on s.cell_id = v_meeting.cell_id
                        where p.programme_id = v_projection.programme_id
                          and (p.published_starts_at, p.published_ends_at, p.published_venue)
                              is distinct from (v_meeting.starts_at, v_meeting.ends_at,
                                                coalesce(v_meeting.moved_venue, s.venue)))) end,
    -- Story 5.5: the reader's own parts of what is published (named in the projection), with
    -- their Duties occurrence.
    'yours', case when v_projection.programme_id is not null then coalesce((
      select jsonb_agg(jsonb_build_object('part_id', pt.part_id,
                                          'occurrence_id', pt.duty_occurrence_id)
                       order by pt.position)
        from app.cells_programme_parts pt
       where pt.programme_id = v_projection.programme_id and pt.removed_at is null
         and pt.assignee_member_id = v_member and pt.duty_occurrence_id is not null
         and exists (select 1 from jsonb_array_elements(v_projection.body -> 'parts') e
                      where (e ->> 'part_id')::uuid = pt.part_id)), '[]'::jsonb)
      else '[]'::jsonb end);
end;
$$;

-- Programmes published before this story: their published snapshot is what is live now.
update app.cells_programmes p
   set published_starts_at = m.starts_at, published_ends_at = m.ends_at,
       published_venue = coalesce(m.moved_venue, s.venue)
  from app.cells_meetings m
  left join app.cells_meeting_schedules s on s.cell_id = m.cell_id
 where m.meeting_id = p.meeting_id and p.programme_state = 'published' and p.published_starts_at is null;
update app.cells_programme_parts pt
   set published_kind = case when pt.linked_slot_id is not null then 'linked' else 'owned' end,
       published_label = pt.label, published_starts_at = pt.starts_at, published_ends_at = pt.ends_at,
       published_slot_id = pt.linked_slot_id
  from app.cells_programmes p
 where p.programme_id = pt.programme_id and p.programme_state = 'published' and pt.removed_at is null
   and pt.published_kind is null;

comment on function app.cells_publish_part(app.cells_programme_parts, app.cells_programmes, text, text) is
  'Superseded by the five-argument app.cells_publish_part (story 5.6); kept only because migrations '
  'never drop. Do not call: it neither ends removed parts nor flags departments.';

revoke all on function
  app.cells_programme_note_meeting(),
  app.cells_part_key(app.cells_programme_parts),
  app.cells_mark_published(app.cells_programme_parts, text),
  app.cells_publish_part(app.cells_programme_parts, app.cells_programmes, text, text, text[])
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
