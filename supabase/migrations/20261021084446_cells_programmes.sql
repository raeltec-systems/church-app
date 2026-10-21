-- Story 5.3: draft a meeting programme with validated parts and visible gaps (epic 5, C3).
-- Builds on 20261021073514_cells_meetings.sql and 20261021081026_cells_meeting_reminders.sql.
--
--   * One programme per meeting (app.cells_programmes): topic, scripture, study notes, state
--     (draft, cancelled; 5.4 adds published) and revision. Its date, time and venue are the
--     meeting's own.
--   * Ordered parts (app.cells_programme_parts): stable part ids, label, church-local start and
--     end on the meeting's date, optional assignee from the cell's confirmed roster (members
--     without a login included). Parts left out of a save are marked removed, never deleted.
--   * Commands (leader or assistant of the cell): cells.create_programme {meeting_id} (expected
--     null), cells.save_programme (replaces the draft's content at its revision; order, fit
--     inside the meeting and no overlap are validated per part), cells.cancel_programme.
--   * Read api.cells_programme(meeting_id): the leader, the assistant and Pastor oversight read
--     the draft with the roster; Admin alone reads state, revision and counts only; anyone else
--     is refused.
--   * Carries the 5.2 review fixes (5.2 is on staging): an empty reminder list means none,
--     planning locks the meeting, reads never fail on reminder planning, confirming a member
--     plans their reminders at once, and "Tell directly" lists current members only.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Programme states. Story 5.4 adds `published` by replacing this function (a CHECK calls it).
create function app.cells_programme_state_ok(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value in ('draft', 'cancelled');
$$;

create table app.cells_programmes (
  programme_id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null unique references app.cells_meetings (meeting_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  programme_state text not null default 'draft' check (app.cells_programme_state_ok(programme_state)),
  topic text check (topic is null or length(topic) between 1 and 120),
  scripture text check (scripture is null or length(scripture) between 1 and 120),
  study_notes text check (study_notes is null or length(study_notes) between 1 and 2000),
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  updated_by_member uuid not null,
  updated_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index cells_programmes_cell on app.cells_programmes (cell_id);

comment on table app.cells_programmes is
  'owner: cells. A meeting''s programme (story 5.3): topic, scripture, study notes, state and '
  'revision; its date, time and venue are the meeting''s.';

create table app.cells_programme_parts (
  part_id uuid primary key default gen_random_uuid(),
  programme_id uuid not null references app.cells_programmes (programme_id),
  position smallint not null check (position between 1 and 20),
  label text not null check (length(label) between 1 and 60),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  assignee_member_id uuid,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create unique index cells_programme_parts_live_position
  on app.cells_programme_parts (programme_id, position) where removed_at is null;
create index cells_programme_parts_assignee on app.cells_programme_parts (assignee_member_id)
  where assignee_member_id is not null;

comment on table app.cells_programme_parts is
  'owner: cells. An ordered part of a programme (story 5.3) with a stable part id; removed parts '
  'are kept with removed_at so later Duties links (5.4) stay stable.';

-- Programme audit actions. Later stories add actions by replacing this function (a CHECK calls
-- it), so no constraint is ever dropped.
create function app.cells_programme_audit_action_ok(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value in ('programme_created', 'programme_saved', 'programme_cancelled');
$$;

create table app.cells_programme_audit (
  event_id bigint generated always as identity primary key,
  action text not null check (app.cells_programme_audit_action_ok(action)),
  programme_id uuid not null,
  meeting_id uuid not null,
  cell_id uuid not null,
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  actor_capacity text not null check (actor_capacity in ('cell_leader', 'cell_assistant')),
  command_request_id uuid,
  revision_after bigint not null check (revision_after >= 1),
  created_at timestamptz not null default now()
);

create index cells_programme_audit_programme on app.cells_programme_audit (programme_id, event_id);

comment on table app.cells_programme_audit is
  'owner: cells. Content-free audit of programme changes (story 5.3): ids, codes, revisions and '
  'the actor''s capacity. No topic, notes, labels or names.';

alter table app.cells_programmes enable row level security;
alter table app.cells_programme_parts enable row level security;
alter table app.cells_programme_audit enable row level security;
revoke all on table app.cells_programmes, app.cells_programme_parts, app.cells_programme_audit
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- Leader or assistant of the cell: may draft its programmes. Returns the capacity or null.
create function app.cells_programme_capacity(p_member_id uuid, p_cell_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when app.identity_member_has_scope(p_member_id, 'cell_leader', p_cell_id) then 'cell_leader'
    when app.identity_member_has_scope(p_member_id, 'cell_assistant', p_cell_id) then 'cell_assistant'
  end;
$$;

-- A free-text field: absent or null is null; otherwise a string, trimmed, 1..p_max characters,
-- no control characters (study notes may hold line breaks), no format characters. Whitespace
-- runs are collapsed on single-line fields. Answers the error code or null, and the value.
create function app.cells_free_text(p_value jsonb, p_max integer, p_multiline boolean,
                                    out error text, out value text)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    error := 'invalid';
    return;
  end if;
  value := btrim(p_value #>> '{}');
  if not p_multiline then
    value := regexp_replace(value, '[[:space:]]+', ' ', 'g');
  end if;
  if value = '' then
    value := null;
    return;
  end if;
  if length(value) > p_max then
    error := 'too_long';
  elsif (not p_multiline and value ~ '[[:cntrl:]]')
        or (p_multiline and value ~ ('[' || chr(1) || '-' || chr(9) || chr(11) || '-' || chr(31)
                                     || chr(127) || ']'))
        or value ~ ('[' || chr(173) || chr(8203) || '-' || chr(8207) || chr(8234) || '-' || chr(8238)
                    || chr(8288) || '-' || chr(8292) || chr(8294) || '-' || chr(8303) || chr(65279) || ']') then
    error := 'invalid';
  end if;
  if error is not null then
    value := null;
  end if;
end;
$$;

create function app.cells_programme_audit_row(
  p_action text,
  p_programme app.cells_programmes,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.cells_programme_audit (action, programme_id, meeting_id, cell_id, actor_member_id,
                                         actor_account_id, actor_capacity, command_request_id,
                                         revision_after)
  values (p_action, p_programme.programme_id, p_programme.meeting_id, p_programme.cell_id,
          p_actor_member, p_actor_account, p_capacity,
          app.cmd_current_request_id(p_actor_account, p_command), p_revision);
$$;

-- The programme as its managers and Pastor oversight see it (p_full) or as an Admin-only reader
-- sees it (state, revision and counts only).
create function app.cells_programme_json(p_programme_id uuid, p_full boolean)
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
                                                      and cm.member_id = pt.assignee_member_id)) end)
               order by pt.position)
          from app.cells_programme_parts pt
         where pt.programme_id = p.programme_id and pt.removed_at is null), '[]'::jsonb),
      'gaps', (select count(*)::int from app.cells_programme_parts pt
                where pt.programme_id = p.programme_id and pt.removed_at is null
                  and pt.assignee_member_id is null))
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
                  and pt.assignee_member_id is null))
  end
    from app.cells_programmes p
   where p.programme_id = p_programme_id;
$$;

create function app.cells_programme_outcome(p_programme_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'cells_programme',
    'aggregate_id', p.programme_id,
    'revision', p.revision,
    'data', app.cells_programme_json(p.programme_id, true))
    from app.cells_programmes p
   where p.programme_id = p_programme_id;
$$;

-- Locks a programme for a change by the leader or assistant of its cell and checks the revision.
create function app.cells_lock_programme(p_payload jsonb, p_expected bigint, p_member_id uuid,
                                         out programme app.cells_programmes, out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_programme app.cells_programmes;
begin
  select p.* into v_programme from app.cells_programmes p
   where p.programme_id = (p_payload ->> 'programme_id')::uuid for update;
  if v_programme.programme_id is null then
    perform app.cmd_fail('not_found');
  end if;
  capacity := app.cells_programme_capacity(p_member_id, v_programme.cell_id);
  if capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_programme.revision <> p_expected then
    perform app.cmd_fail('conflict', null, v_programme.revision);
  end if;
  programme := v_programme;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- cells.create_programme {meeting_id}; the cell's leader or assistant; expected null. The meeting
-- must be on and ahead, and have no programme yet.
create function app.cells_create_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_programme app.cells_programmes;
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
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = (p_payload ->> 'meeting_id')::uuid for share;
  if v_meeting.meeting_id is null or v_meeting.meeting_state = 'withdrawn' then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.cells_programme_capacity(v_actor.member_id, v_meeting.cell_id);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_meeting.meeting_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  if exists (select 1 from app.cells_programmes p where p.meeting_id = v_meeting.meeting_id) then
    perform app.cmd_fail('conflict', '{"meeting_id": "exists"}');
  end if;
  insert into app.cells_programmes (meeting_id, cell_id, created_by_member, created_by_account,
                                    updated_by_member, updated_by_account)
  values (v_meeting.meeting_id, v_meeting.cell_id, v_actor.member_id, v_actor.account_id,
          v_actor.member_id, v_actor.account_id)
  returning * into v_programme;
  perform app.cells_programme_audit_row('programme_created', v_programme, v_actor.member_id,
                                        v_actor.account_id, v_capacity, 'cells.create_programme', 1);
  return app.cells_programme_outcome(v_programme.programme_id);
end;
$$;

-- cells.save_programme {programme_id, topic?, scripture?, study_notes?, parts: [{part_id?, label,
-- start_time "HH:MM", end_time "HH:MM" | duration_minutes, assignee_member_id?}]}; the leader
-- or assistant; expected = the programme revision; a draft only. Replaces the content: parts keep
-- their ids when sent back, new ones get ids, the rest are marked removed. Part times are
-- church-local on the meeting's date. Field errors per part are keyed `parts.<index>`.
create function app.cells_save_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_lock record;
  v_programme app.cells_programmes;
  v_meeting app.cells_meetings;
  v_zone text;
  v_date date;
  v_topic record;
  v_scripture record;
  v_notes record;
  v_parts jsonb := p_payload -> 'parts';
  v_rows jsonb := '[]'::jsonb;
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
  select l.programme, l.capacity into v_lock
    from app.cells_lock_programme(p_payload, p_expected_revision, v_actor.member_id) l;
  v_programme := v_lock.programme;
  if v_programme.programme_state <> 'draft' then
    perform app.cmd_fail('conflict', '{"programme_id": "not_draft"}', v_programme.revision);
  end if;
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = v_programme.meeting_id for share;
  if v_meeting.meeting_state in ('cancelled', 'withdrawn') then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  select coalesce((select s.zone from app.cells_meeting_schedules s where s.cell_id = v_meeting.cell_id),
                  'Africa/Lusaka') into v_zone;
  v_date := (v_meeting.starts_at at time zone v_zone)::date;
  -- Validate every part; collect the rows to write.
  for x in select e from jsonb_array_elements(v_parts) e loop
    v_code := null;
    v_part_id := null;
    v_assignee := null;
    if jsonb_typeof(x) <> 'object'
       or app.contract_unknown_keys(x, array['part_id', 'label', 'start_time', 'end_time',
                                             'duration_minutes', 'assignee_member_id']) <> '{}'::jsonb then
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
      v_starts := (v_date + v_start) at time zone v_zone;
      v_ends := case when x ? 'end_time' then (v_date + app.cells_clock(x -> 'end_time')) at time zone v_zone
                     else v_starts + make_interval(mins => (x ->> 'duration_minutes')::numeric::integer) end;
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
                           where pt.part_id = v_part_id and pt.programme_id = v_programme.programme_id) then
          v_code := 'part_unknown';
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
                  'starts_at', v_starts, 'ends_at', v_ends, 'assignee', v_assignee));
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
             assignee_member_id = (r ->> 'assignee')::uuid, updated_at = now()
       where pt.part_id = (r ->> 'part_id')::uuid;
    else
      insert into app.cells_programme_parts (programme_id, position, label, starts_at, ends_at,
                                             assignee_member_id)
      values (v_programme.programme_id, (r ->> 'position')::smallint, r ->> 'label',
              (r ->> 'starts_at')::timestamptz, (r ->> 'ends_at')::timestamptz, (r ->> 'assignee')::uuid);
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

-- cells.cancel_programme {programme_id}; the leader or assistant; expected = programme revision.
-- A draft becomes cancelled and read-only.
create function app.cells_cancel_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_lock record;
  v_revision bigint;
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
  perform app.cells_programme_audit_row('programme_cancelled', v_lock.programme, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity,
                                        'cells.cancel_programme', v_revision);
  return app.cells_programme_outcome((v_lock.programme).programme_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Entry point, authorizer and replay scope (replaced from 5.2)
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
       'cells.cancel_meeting', 'cells.reinstate_meeting', 'cells.set_meeting_reminders',
       'cells.create_programme', 'cells.save_programme', 'cells.cancel_programme') then
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
  elsif p_aggregate_type in ('cells_meeting', 'cells_meeting_reminders', 'cells_programme') then
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    if p_aggregate_type = 'cells_meeting' then
      select m.cell_id into v_cell from app.cells_meetings m where m.meeting_id = p_aggregate_id;
    elsif p_aggregate_type = 'cells_meeting_reminders' then
      select s.cell_id into v_cell from app.cells_meeting_schedules s where s.cell_id = p_aggregate_id;
    else
      -- Story 5.3: a programme replay needs a current leader or assistant of its cell.
      select p.cell_id into v_cell from app.cells_programmes p where p.programme_id = p_aggregate_id;
      return v_member is not null and v_cell is not null
         and app.cells_programme_capacity(v_member, v_cell) is not null;
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
      when 'cells.create_programme' then 'app.cells_create_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.save_programme' then 'app.cells_save_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_programme' then 'app.cells_cancel_programme(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell' and v_command is distinct from 'cells.create_programme'
  );
end;
$$;

comment on function api.cells_command(jsonb) is
  'Stories 2.6, 5.1, 5.2 and 5.3: cell setup and membership, meeting schedules and exceptions with '
  'their notices, meeting reminders, and programme drafts (create_programme, save_programme, '
  'cancel_programme) through the 1.4 command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Read
-- ---------------------------------------------------------------------------------------------

-- api.cells_programme(meeting_id): the meeting and its programme. The cell's leader and assistant
-- (can_edit) and Pastor oversight read the full draft and the cell's confirmed roster; an
-- Admin-only reader reads state, revision and counts; anyone else is refused (403 not_granted).
create function app.cells_programme(p_meeting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_full boolean;
  v_programme uuid;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = p_meeting_id and m.meeting_state <> 'withdrawn';
  v_capacity := app.cells_programme_capacity(v_member, v_meeting.cell_id);
  v_full := v_capacity is not null or app.identity_member_has_role(v_member, 'pastor');
  if v_meeting.meeting_id is null
     or not (v_full or app.identity_member_has_role(v_member, 'admin')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select p.programme_id into v_programme from app.cells_programmes p where p.meeting_id = p_meeting_id;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, v_capacity is not null),
    'cell_name', (select c.name from app.cells_cells c where c.cell_id = v_meeting.cell_id),
    'view', case when v_full then 'full' else 'metadata' end,
    'can_edit', v_capacity is not null,
    'programme', case when v_programme is not null then app.cells_programme_json(v_programme, v_full) end,
    'roster', case when v_full then coalesce((
      select jsonb_agg(jsonb_build_object('member_id', cm.member_id, 'display_name', im.display_name,
                                          'account', app.identity_member_account_label(cm.member_id))
                       order by im.display_name collate "C", cm.member_id)
        from app.cells_memberships cm
        join app.identity_members im on im.member_id = cm.member_id
       where cm.cell_id = v_meeting.cell_id and cm.ended_at is null), '[]'::jsonb)
      else '[]'::jsonb end);
end;
$$;

create function api.cells_programme(meeting_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_programme(meeting_id);
$$;

comment on function api.cells_programme(uuid) is
  'Story 5.3: a meeting''s programme draft for the cell''s leader and assistant (editable) and '
  'Pastor oversight (read), with the confirmed roster; metadata only for an Admin-only reader.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced from 5.2): programme assignees cleared, actors anonymised
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
      update app.cells_reminders_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_programmes p set created_by_account = v_nil where p.created_by_account = v_account;
      update app.cells_programmes p set updated_by_account = v_nil where p.updated_by_account = v_account;
      update app.cells_programme_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
    end if;
    -- Story 5.1: meeting actors are attributed facts; the person is anonymised.
    update app.cells_meeting_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.cells_meetings m set changed_by_member = v_nil where m.changed_by_member = v_member;
    update app.cells_meeting_schedules s set set_by_member = v_nil where s.set_by_member = v_member;
    update app.cells_reminders_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.2: a contact need is kept as an anonymous fact.
    update app.cells_meeting_contact_needs n set member_id = v_nil where n.member_id = v_member;
    -- Story 5.3: a part the member was planned for becomes a gap; programme actors anonymised.
    update app.cells_programme_parts pt set assignee_member_id = null, updated_at = now()
     where pt.assignee_member_id = v_member;
    update app.cells_programmes p set created_by_member = v_nil where p.created_by_member = v_member;
    update app.cells_programmes p set updated_by_member = v_nil where p.updated_by_member = v_member;
    update app.cells_programme_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
  end if;
  select (select count(*) from app.cells_memberships m where m.member_id = v_member)
       + (select count(*) from app.cells_membership_requests r where r.member_id = v_member)
       + (select count(*) from app.cells_member_states s where s.member_id = v_member)
       + (select count(*) from app.cells_meeting_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_meetings m where m.changed_by_member = v_member)
       + (select count(*) from app.cells_meeting_schedules s where s.set_by_member = v_member)
       + (select count(*) from app.cells_meeting_contact_needs n where n.member_id = v_member)
       + (select count(*) from app.cells_reminders_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_programme_parts pt where pt.assignee_member_id = v_member)
       + (select count(*) from app.cells_programmes p
           where p.created_by_member = v_member or p.updated_by_member = v_member)
       + (select count(*) from app.cells_programme_audit a where a.actor_member_id = v_member)
       + case when v_account is null then 0 else
           (select count(*) from app.cells_membership_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_memberships m where m.confirmed_by_account = v_account)
         + (select count(*) from app.cells_membership_requests r
             where r.requested_by_account = v_account or r.decided_by_account = v_account)
         + (select count(*) from app.cells_meeting_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_meetings m where m.changed_by_account = v_account)
         + (select count(*) from app.cells_meeting_schedules s where s.set_by_account = v_account)
         + (select count(*) from app.cells_reminders_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_programmes p
             where p.created_by_account = v_account or p.updated_by_account = v_account)
         + (select count(*) from app.cells_programme_audit a where a.actor_account_id = v_account)
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

comment on function app.cells_erase_member(jsonb) is
  'Cells deletion hook (stories 2.11 and 5.1-5.3): erase or check the member''s Cells personal '
  'data; meeting and programme actors and contact needs anonymised, programme parts made gaps.';

-- ---------------------------------------------------------------------------------------------
-- 5.2 review fixes (5.2 is on staging, so they ship here). See the 5.2 plan's Review Triage Log.
-- ---------------------------------------------------------------------------------------------

-- Fix 3 (medium): the probe never raises; an unusable or closed Q2 gate is just "not available".
create or replace function app.cells_reminders_available()
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  return app.notifications_policy_errors(app.policy_effective('q2_church_time') -> 'value') = '{}'::jsonb;
exception when sqlstate 'PCMD1' then
  return false;
end;
$$;

-- Fix 1 (high): an empty list means no reminders (jsonb_agg over no rows is null, which fell back
-- to the default); only null means the default.
create or replace function app.cells_reminder_specs(p_reminders jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_reminders is null then '[{"anchor": "starts_at", "before": "24 hours"}]'::jsonb
    else coalesce((select jsonb_agg(jsonb_build_object('anchor', 'starts_at', 'before', r ->> 'before'))
                     from jsonb_array_elements(p_reminders) r), '[]'::jsonb)
  end;
$$;

-- Fix 2 (medium): planning locks the meeting (no key update) before any Notifications call, so a
-- read's sync and a concurrent move are serialised and the plan is always for the committed
-- revision. Cells before Notifications (AD-2). Otherwise 5.2's body.
create or replace function app.cells_plan_meeting(p_meeting_id uuid, p_notice text)
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
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = p_meeting_id
     for no key update;
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

-- Fix 3 (medium): reads never fail because of reminder planning. Generation keeps 5.2's body;
-- its planning step runs in a sub-block that logs and skips a command-kernel refusal (PCMD1).
-- The meetings it generated are kept either way.
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
    returning m.meeting_id)
  select coalesce(array_agg(w.meeting_id), '{}') into v_withdrawn from w;
  -- Reminders and notices follow when the Q2 policy is usable; a refusal never fails the caller.
  if app.cells_reminders_available() then
    begin
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
    exception when sqlstate 'PCMD1' then
      raise log 'cells meeting reminders not planned for a cell (sqlstate PCMD1)';
    end;
  end if;
  return v_created;
end;
$$;

-- Fix 4 (medium): confirming a member (and a transfer) plans their meeting reminders at once in
-- the new cell and ends them in the old one, without waiting for someone to read. Skipped while
-- the Q2 policy is not usable (a confirmation is never blocked by reminders). Otherwise 2.6's body.
create or replace function app.cells_confirm_request(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_request app.cells_membership_requests;
  v_capacity text;
  v_cell uuid;
  v_old record;
  v_membership uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if app.contract_uuid_error(p_payload -> 'cell_id', true) is not null then
    perform app.cmd_fail('validation_failed',
      jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id', true)));
  end if;
  v_request := app.cells_lock_open_request(p_payload, array['request_id', 'cell_id'],
                                           p_expected_revision);
  v_capacity := app.cells_decider(v_actor.member_id, v_actor.is_admin, v_request);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  -- Separation of duty: nobody confirms their own cell membership.
  if v_request.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  v_cell := coalesce((p_payload ->> 'cell_id')::uuid, v_request.requested_cell_id);
  if v_cell is null then
    perform app.cmd_fail('validation_failed', '{"cell_id": "required"}');
  end if;
  if v_capacity = 'cell_leader' and v_cell <> v_request.requested_cell_id then
    perform app.cmd_fail('forbidden', '{"cell_id": "unsupported"}');
  end if;
  perform 1 from app.cells_cells c where c.cell_id = v_cell and c.cell_state = 'active' for share;
  if not found then
    perform app.cmd_fail('validation_failed', '{"cell_id": "invalid"}');
  end if;
  select m.membership_id, m.cell_id into v_old
    from app.cells_memberships m
   where m.member_id = v_request.member_id and m.ended_at is null
     for update;
  if v_old.cell_id = v_cell then
    perform app.cmd_fail('validation_failed', '{"cell_id": "current"}');
  end if;
  -- End the old primary membership first (one current primary per member).
  if v_old.membership_id is not null then
    update app.cells_memberships m
       set ended_at = now(), end_reason = 'transferred', ended_by_request = v_request.request_id
     where m.membership_id = v_old.membership_id;
  end if;
  insert into app.cells_memberships (member_id, cell_id, request_id, confirmed_by_member,
                                     confirmed_by_account, confirmed_as)
  values (v_request.member_id, v_cell, v_request.request_id, v_actor.member_id, v_actor.account_id,
          v_capacity)
  returning membership_id into v_membership;
  update app.cells_membership_requests r
     set request_state = 'confirmed', decided_at = now(), updated_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decided_as = v_capacity, resulting_membership_id = v_membership
   where r.request_id = v_request.request_id;
  v_revision := app.cells_bump_member(v_request.member_id);
  perform app.cells_audit('request_confirmed', v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request',
                          v_request.member_id, v_cell, v_old.cell_id, v_request.request_id,
                          v_membership, null, v_revision);
  perform app.cells_audit(case when v_old.membership_id is null then 'membership_started'
                               else 'membership_transferred' end, v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request', v_request.member_id,
                          v_cell, v_old.cell_id, v_request.request_id, v_membership, null,
                          v_revision);
  if v_old.membership_id is not null then
    -- AD-14: registered owners (duties, chat, follow-ups, programmes ...) move or end their
    -- old-cell obligations inside this transaction; one failing hook rolls the transfer back.
    perform app.contract_dispatch_lifecycle(jsonb_build_object(
      'event', 'cell_transferred',
      'member_id', v_request.member_id,
      'occurred_at', app.cmd_utc(now()),
      'identity_revision', v_revision));
  end if;
  -- Story 5.2 review fix 4: meeting reminders follow the membership now (Notifications last).
  if app.cells_reminders_available() then
    perform app.cells_sync_meeting_reminders(v_cell);
    if v_old.cell_id is not null then
      perform app.cells_sync_meeting_reminders(v_old.cell_id);
    end if;
  end if;
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- Fix 7 (low): "Tell directly" lists current members of the cell only.
create or replace function app.cells_meeting_contact_json(p_meeting_id uuid)
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
         and exists (select 1 from app.cells_memberships cm
                      where cm.cell_id = m.cell_id and cm.ended_at is null
                        and cm.member_id = n.member_id)
       group by n.member_id, im.display_name
    ) x;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_programme_state_ok(text),
  app.cells_programme_audit_action_ok(text),
  app.cells_programme_capacity(uuid, uuid),
  app.cells_free_text(jsonb, integer, boolean),
  app.cells_programme_audit_row(text, app.cells_programmes, uuid, uuid, text, text, bigint),
  app.cells_programme_json(uuid, boolean),
  app.cells_programme_outcome(uuid),
  app.cells_lock_programme(jsonb, bigint, uuid),
  app.cells_create_programme(uuid, bigint, jsonb),
  app.cells_save_programme(uuid, bigint, jsonb),
  app.cells_cancel_programme(uuid, bigint, jsonb),
  app.cells_programme(uuid),
  api.cells_programme(uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.cells_programme(uuid) to authenticated;
grant execute on function api.cells_programme(uuid) to authenticated;

notify pgrst, 'reload schema';
