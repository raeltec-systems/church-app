-- Story 5.8: mark meetings held and record actual programme leaders with corrections (epic 5, C8).
-- Builds on 20261021111547_cells_absence_notices.sql.
--
--   * Once a meeting has started (and was not cancelled), the cell's leader or assistant records
--     whether it was held. A correction needs a reason; every value is kept with its actor and time.
--   * For a held meeting they record who actually led each programme part: a member of the cell, a
--     named guest or nobody. A change supersedes the earlier row (kept, with a reason). Nothing is
--     inferred from the plan: "as planned" is the leader's explicit choice.
--   * The plan (parts and assignees), every duty response and outcome and any attendance stay as
--     they are; nothing here writes them and nothing there writes these records.
--   * app.cells_meeting_reference(meeting_id) is the canonical meeting reference for later owners
--     (attendance, recaps, offerings): status and actual leaders, never notes or reasons.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

create table app.cells_meeting_records (
  meeting_id uuid primary key references app.cells_meetings (meeting_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  held boolean not null,
  revision bigint not null default 1 check (revision >= 1),
  recorded_by_member uuid not null,
  recorded_by_account uuid not null,
  recorded_at timestamptz not null default now(),
  updated_by_member uuid not null,
  updated_by_account uuid not null,
  updated_at timestamptz not null default now()
);

create index cells_meeting_records_cell on app.cells_meeting_records (cell_id);

comment on table app.cells_meeting_records is
  'owner: cells. Whether a meeting was held (story 5.8), recorded after it started by the cell''s '
  'leader or assistant. Never attendance, never a duty outcome.';

create table app.cells_meeting_record_history (
  history_id bigint generated always as identity primary key,
  meeting_id uuid not null,
  cell_id uuid not null,
  revision bigint not null check (revision >= 1),
  held boolean not null,
  reason text check (reason is null or length(reason) between 1 and 280),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  command_request_id uuid,
  created_at timestamptz not null default now()
);

create index cells_meeting_record_history_meeting on app.cells_meeting_record_history (meeting_id, history_id);
create index cells_meeting_record_history_actor on app.cells_meeting_record_history (actor_member_id);

comment on table app.cells_meeting_record_history is
  'owner: cells. Every held / not held value of a meeting record with its actor, time and the '
  'correction reason (story 5.8).';

create table app.cells_actual_leaders (
  actual_id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null references app.cells_meetings (meeting_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  part_id uuid not null references app.cells_programme_parts (part_id),
  leader_kind text not null check (leader_kind in ('member', 'guest', 'nobody')),
  member_id uuid,
  guest_name text check (guest_name is null or length(guest_name) between 1 and 80),
  planned_member_id uuid,
  reason text check (reason is null or length(reason) between 1 and 280),
  recorded_by_member uuid not null,
  recorded_by_account uuid not null,
  command_request_id uuid,
  recorded_at timestamptz not null default now(),
  superseded_at timestamptz,
  superseded_by uuid,
  check ((leader_kind = 'member') = (member_id is not null)),
  check ((leader_kind = 'guest') = (guest_name is not null)),
  check ((superseded_at is null) = (superseded_by is null))
);

create unique index cells_actual_leaders_current on app.cells_actual_leaders (part_id)
  where superseded_at is null;
create index cells_actual_leaders_meeting on app.cells_actual_leaders (meeting_id, recorded_at);
create index cells_actual_leaders_member on app.cells_actual_leaders (member_id);

comment on table app.cells_actual_leaders is
  'owner: cells. Who actually led a programme part of a held meeting (story 5.8): one current row '
  'per part, earlier rows kept as superseded corrections with a reason. Separate from the plan and '
  'from Duties.';

alter table app.cells_meeting_records enable row level security;
alter table app.cells_meeting_record_history enable row level security;
alter table app.cells_actual_leaders enable row level security;
revoke all on table app.cells_meeting_records, app.cells_meeting_record_history, app.cells_actual_leaders
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- Not recorded, held, not held or cancelled; scheduled while the meeting is ahead.
create function app.cells_meeting_status(p_meeting app.cells_meetings)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_meeting.meeting_state in ('cancelled', 'withdrawn') then p_meeting.meeting_state
    when r.held then 'held'
    when r.meeting_id is not null then 'not_held'
    when p_meeting.starts_at > now() then 'scheduled'
    else 'unrecorded' end
    from (select 1) x
    left join app.cells_meeting_records r on r.meeting_id = p_meeting.meeting_id;
$$;

create function app.cells_actual_leader_json(p_actual app.cells_actual_leaders, p_with_reason boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'actual_id', p_actual.actual_id,
    'part_id', p_actual.part_id,
    'kind', p_actual.leader_kind,
    'member_id', p_actual.member_id,
    'display_name', case when p_actual.leader_kind = 'member'
                         then coalesce((select im.display_name from app.identity_members im
                                         where im.member_id = p_actual.member_id), 'Removed member') end,
    'guest_name', p_actual.guest_name,
    'planned_member_id', p_actual.planned_member_id,
    'substitute', p_actual.leader_kind <> 'nobody'
                  and (p_actual.leader_kind = 'guest'
                       or p_actual.member_id is distinct from p_actual.planned_member_id),
    'recorded_at', app.cmd_utc(p_actual.recorded_at),
    'recorded_by', (select im.display_name from app.identity_members im
                     where im.member_id = p_actual.recorded_by_member))
  || case when p_with_reason then jsonb_build_object('reason', p_actual.reason) else '{}'::jsonb end;
$$;

-- The staff view of a meeting record: held, revision, every value with its reason, and each
-- part's current actual leader with its earlier rows (newest first).
create function app.cells_meeting_record_json(p_meeting_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'held', r.held,
    'revision', r.revision,
    'recorded_at', app.cmd_utc(r.recorded_at),
    'updated_at', app.cmd_utc(r.updated_at),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'revision', h.revision, 'held', h.held, 'reason', h.reason,
               'by', (select im.display_name from app.identity_members im where im.member_id = h.actor_member_id),
               'at', app.cmd_utc(h.created_at))
             order by h.history_id desc)
        from app.cells_meeting_record_history h where h.meeting_id = r.meeting_id), '[]'::jsonb),
    'actual', coalesce((
      select jsonb_agg(app.cells_actual_leader_json(a, true) || jsonb_build_object(
               'earlier', coalesce((
                 select jsonb_agg(app.cells_actual_leader_json(e, true) order by e.recorded_at desc, e.actual_id)
                   from app.cells_actual_leaders e
                  where e.part_id = a.part_id and e.superseded_at is not null), '[]'::jsonb))
             order by a.recorded_at, a.actual_id)
        from app.cells_actual_leaders a
       where a.meeting_id = r.meeting_id and a.superseded_at is null), '[]'::jsonb))
    from app.cells_meeting_records r where r.meeting_id = p_meeting_id;
$$;

-- The canonical meeting reference for later owners (attendance, recaps, offerings): when the meeting
-- was, its status and the actual leaders of its parts (names only for members of the cell; no
-- reasons, notes or venue). Internal: owners call it inside their own authorised reads.
create function app.cells_meeting_reference(p_meeting_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'meeting_id', m.meeting_id,
    'cell_id', m.cell_id,
    'occurrence_date', to_char(m.occurrence_date, 'YYYY-MM-DD'),
    'starts_at', app.cmd_utc(m.starts_at),
    'ends_at', app.cmd_utc(m.ends_at),
    'status', app.cells_meeting_status(m),
    'record_revision', r.revision,
    'actual_leaders', case when r.held then coalesce((
      select jsonb_agg(jsonb_build_object(
               'part_id', a.part_id,
               'label', pt.label,
               'kind', a.leader_kind,
               -- An erased member is a removed person, never a member id to join on (review fix 6).
               'member_id', nullif(a.member_id, '00000000-0000-0000-0000-000000000000'::uuid),
               'removed', a.member_id = '00000000-0000-0000-0000-000000000000'::uuid,
               'guest_name', a.guest_name,
               'substitute', a.leader_kind <> 'nobody'
                             and (a.leader_kind = 'guest' or a.member_id is distinct from a.planned_member_id))
             order by pt.position)
        from app.cells_actual_leaders a
        join app.cells_programme_parts pt on pt.part_id = a.part_id
       where a.meeting_id = m.meeting_id and a.superseded_at is null), '[]'::jsonb)
      else '[]'::jsonb end)
    from app.cells_meetings m
    left join app.cells_meeting_records r on r.meeting_id = m.meeting_id
   where m.meeting_id = p_meeting_id;
$$;

create function app.cells_record_outcome(p_meeting_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('aggregate_type', 'cells_meeting_record', 'aggregate_id', r.meeting_id,
                            'revision', r.revision, 'data', app.cells_meeting_record_json(r.meeting_id))
    from app.cells_meeting_records r where r.meeting_id = p_meeting_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands (the cell's leader or assistant)
-- ---------------------------------------------------------------------------------------------

-- The meeting (share) for a record command: it exists, the actor leads or assists its cell, it has
-- started and was not cancelled.
create function app.cells_record_meeting(p_payload jsonb, p_member_id uuid)
returns app.cells_meetings
language plpgsql
set search_path = ''
as $$
declare
  v_meeting app.cells_meetings;
begin
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = (p_payload ->> 'meeting_id')::uuid for share;
  if v_meeting.meeting_id is null or v_meeting.meeting_state = 'withdrawn' then
    perform app.cmd_fail('not_found');
  end if;
  if app.cells_programme_capacity(p_member_id, v_meeting.cell_id) is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_meeting.meeting_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at > now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "not_started"}');
  end if;
  return v_meeting;
end;
$$;

-- The record row for a correction (update), at the expected revision.
create function app.cells_lock_record(p_meeting_id uuid, p_expected bigint)
returns app.cells_meeting_records
language plpgsql
set search_path = ''
as $$
declare
  v_record app.cells_meeting_records;
begin
  select r.* into v_record from app.cells_meeting_records r where r.meeting_id = p_meeting_id for update;
  if v_record.meeting_id is null then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "not_recorded"}');
  end if;
  if v_record.revision <> p_expected then
    perform app.cmd_fail('conflict', null, v_record.revision);
  end if;
  return v_record;
end;
$$;

-- cells.record_meeting_held {meeting_id, held}; expected = null. A second record:
-- conflict {"meeting_id": "recorded"} (correct it with cells.correct_meeting_held).
create function app.cells_record_meeting_held(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'held']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if jsonb_typeof(p_payload -> 'held') is distinct from 'boolean' then
    v_errors := v_errors || '{"held": "required"}'::jsonb;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_meeting := app.cells_record_meeting(p_payload, v_actor.member_id);
  if exists (select 1 from app.cells_meeting_records r where r.meeting_id = v_meeting.meeting_id) then
    perform app.cmd_fail('conflict', '{"meeting_id": "recorded"}');
  end if;
  begin
    insert into app.cells_meeting_records (meeting_id, cell_id, held, recorded_by_member, recorded_by_account,
                                           updated_by_member, updated_by_account)
    values (v_meeting.meeting_id, v_meeting.cell_id, (p_payload ->> 'held')::boolean, v_actor.member_id,
            v_actor.account_id, v_actor.member_id, v_actor.account_id);
  exception when unique_violation then
    perform app.cmd_fail('conflict', '{"meeting_id": "recorded"}');
  end;
  insert into app.cells_meeting_record_history (meeting_id, cell_id, revision, held, actor_member_id,
                                                actor_account_id, command_request_id)
  values (v_meeting.meeting_id, v_meeting.cell_id, 1, (p_payload ->> 'held')::boolean, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(v_actor.account_id, 'cells.record_meeting_held'));
  return app.cells_record_outcome(v_meeting.meeting_id);
end;
$$;

-- cells.correct_meeting_held {meeting_id, held, reason}; expected = the record revision. The earlier
-- value stays in the history. Actual leaders are kept (they read only while held).
create function app.cells_correct_meeting_held(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_reason record;
  v_meeting app.cells_meetings;
  v_record app.cells_meeting_records;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'held', 'reason']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if jsonb_typeof(p_payload -> 'held') is distinct from 'boolean' then
    v_errors := v_errors || '{"held": "required"}'::jsonb;
  end if;
  select * into v_reason from app.cells_free_text(p_payload -> 'reason', 280, false);
  if v_reason.error is not null then
    v_errors := v_errors || jsonb_build_object('reason', v_reason.error);
  elsif v_reason.value is null then
    v_errors := v_errors || '{"reason": "required"}'::jsonb;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_meeting := app.cells_record_meeting(p_payload, v_actor.member_id);
  v_record := app.cells_lock_record(v_meeting.meeting_id, p_expected_revision);
  if v_record.held = (p_payload ->> 'held')::boolean then
    perform app.cmd_fail('validation_failed', '{"held": "unchanged"}');
  end if;
  update app.cells_meeting_records r
     set held = (p_payload ->> 'held')::boolean, revision = r.revision + 1,
         updated_by_member = v_actor.member_id, updated_by_account = v_actor.account_id, updated_at = now()
   where r.meeting_id = v_record.meeting_id
  returning * into v_record;
  insert into app.cells_meeting_record_history (meeting_id, cell_id, revision, held, reason, actor_member_id,
                                                actor_account_id, command_request_id)
  values (v_record.meeting_id, v_record.cell_id, v_record.revision, v_record.held, v_reason.value,
          v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(v_actor.account_id, 'cells.correct_meeting_held'));
  return app.cells_record_outcome(v_record.meeting_id);
end;
$$;

-- cells.record_actual_leaders {meeting_id, parts: [{part_id, leader, reason?}]}; expected = the
-- record revision; the record says held. leader is {"member_id": <a current member of the cell>},
-- {"name": <a guest, 1-80>} or null (nobody led it). A part whose current row differs is corrected:
-- the reason is required and the earlier row is kept as superseded. An identical value adds nothing.
-- Parts not listed are unchanged.
create function app.cells_record_actual_leaders(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
  v_record app.cells_meeting_records;
  v_programme app.cells_programmes;
  v_part app.cells_programme_parts;
  v_current app.cells_actual_leaders;
  v_new app.cells_actual_leaders;
  v_entry jsonb;
  v_leader jsonb;
  v_text record;
  v_kind text;
  v_member uuid;
  v_guest text;
  v_reason text;
  v_seen uuid[] := array[]::uuid[];
  v_changed integer := 0;
  v_request uuid;
  i integer;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'parts']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if jsonb_typeof(p_payload -> 'parts') is distinct from 'array' then
    v_errors := v_errors || '{"parts": "required"}'::jsonb;
  elsif jsonb_array_length(p_payload -> 'parts') not between 1 and 20 then
    v_errors := v_errors || '{"parts": "count"}'::jsonb;
  else
    for i in 0 .. jsonb_array_length(p_payload -> 'parts') - 1 loop
      v_entry := p_payload -> 'parts' -> i;
      if jsonb_typeof(v_entry) is distinct from 'object' then
        v_errors := v_errors || jsonb_build_object('parts.' || i, 'invalid');
        continue;
      end if;
      v_errors := v_errors || coalesce((
        select jsonb_object_agg('parts.' || i || '.' || k, 'unknown_field')
          from jsonb_object_keys(v_entry) k where k <> all (array['part_id', 'leader', 'reason'])), '{}'::jsonb);
      if app.contract_uuid_error(v_entry -> 'part_id') is not null then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id',
                                                   app.contract_uuid_error(v_entry -> 'part_id'));
      elsif (v_entry ->> 'part_id')::uuid = any (v_seen) then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id', 'duplicate');
      else
        v_seen := v_seen || (v_entry ->> 'part_id')::uuid;
      end if;
      if not (v_entry ? 'leader') then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.leader', 'required');
      else
        v_leader := v_entry -> 'leader';
        if jsonb_typeof(v_leader) = 'null' then
          null;
        elsif jsonb_typeof(v_leader) is distinct from 'object'
              or (select count(*) from jsonb_object_keys(v_leader)) <> 1
              or not (v_leader ? 'member_id' or v_leader ? 'name') then
          v_errors := v_errors || jsonb_build_object('parts.' || i || '.leader', 'invalid');
        elsif v_leader ? 'member_id' and app.contract_uuid_error(v_leader -> 'member_id') is not null then
          v_errors := v_errors || jsonb_build_object('parts.' || i || '.member_id',
                                                     app.contract_uuid_error(v_leader -> 'member_id'));
        elsif v_leader ? 'name' then
          select * into v_text from app.cells_free_text(v_leader -> 'name', 80, false);
          if v_text.error is not null or v_text.value is null then
            v_errors := v_errors || jsonb_build_object('parts.' || i || '.name', coalesce(v_text.error, 'required'));
          end if;
        end if;
      end if;
      select * into v_text from app.cells_free_text(v_entry -> 'reason', 280, false);
      if v_text.error is not null then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.reason', v_text.error);
      end if;
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  -- Meeting, then the record, then the programme (AD-2 order within Cells).
  v_meeting := app.cells_record_meeting(p_payload, v_actor.member_id);
  v_record := app.cells_lock_record(v_meeting.meeting_id, p_expected_revision);
  if not v_record.held then
    perform app.cmd_fail('validation_failed', '{"held": "not_held"}');
  end if;
  select p.* into v_programme from app.cells_programmes p where p.meeting_id = v_meeting.meeting_id for share;
  if v_programme.programme_id is null or v_programme.programme_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "no_programme"}');
  end if;
  v_request := app.cmd_current_request_id(v_actor.account_id, 'cells.record_actual_leaders');
  for i in 0 .. jsonb_array_length(p_payload -> 'parts') - 1 loop
    v_entry := p_payload -> 'parts' -> i;
    select pt.* into v_part from app.cells_programme_parts pt
     where pt.part_id = (v_entry ->> 'part_id')::uuid and pt.programme_id = v_programme.programme_id
       and pt.removed_at is null;
    if v_part.part_id is null then
      v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id', 'not_found');
      continue;
    end if;
    v_leader := v_entry -> 'leader';
    v_member := null;
    v_guest := null;
    if jsonb_typeof(v_leader) = 'null' then
      v_kind := 'nobody';
    elsif v_leader ? 'member_id' then
      v_kind := 'member';
      v_member := (v_leader ->> 'member_id')::uuid;
      perform 1 from app.cells_memberships cm
       where cm.cell_id = v_meeting.cell_id and cm.ended_at is null and cm.member_id = v_member
         for key share;
      if not found then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.member_id', 'not_in_cell');
        continue;
      end if;
    else
      v_kind := 'guest';
      select t.value into v_guest from app.cells_free_text(v_leader -> 'name', 80, false) t;
    end if;
    select t.value into v_reason from app.cells_free_text(v_entry -> 'reason', 280, false) t;
    select a.* into v_current from app.cells_actual_leaders a
     where a.part_id = v_part.part_id and a.superseded_at is null for update;
    if v_current.actual_id is not null
       and v_current.leader_kind = v_kind and v_current.member_id is not distinct from v_member
       and v_current.guest_name is not distinct from v_guest then
      continue;
    end if;
    if v_current.actual_id is not null and v_reason is null then
      v_errors := v_errors || jsonb_build_object('parts.' || i || '.reason', 'required');
      continue;
    end if;
    if v_errors <> '{}'::jsonb then
      continue;
    end if;
    v_new := null;
    if v_current.actual_id is not null then
      update app.cells_actual_leaders a set superseded_at = now(), superseded_by = gen_random_uuid()
       where a.actual_id = v_current.actual_id
      returning a.superseded_by into v_new.actual_id;
    end if;
    insert into app.cells_actual_leaders (actual_id, meeting_id, cell_id, part_id, leader_kind, member_id,
                                          guest_name, planned_member_id, reason, recorded_by_member,
                                          recorded_by_account, command_request_id)
    values (coalesce(v_new.actual_id, gen_random_uuid()), v_meeting.meeting_id, v_meeting.cell_id,
            v_part.part_id, v_kind, v_member, v_guest, v_part.assignee_member_id,
            case when v_current.actual_id is not null then v_reason end,
            v_actor.member_id, v_actor.account_id, v_request);
    v_changed := v_changed + 1;
  end loop;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if v_changed > 0 then
    update app.cells_meeting_records r
       set revision = r.revision + 1, updated_by_member = v_actor.member_id,
           updated_by_account = v_actor.account_id, updated_at = now()
     where r.meeting_id = v_record.meeting_id;
  end if;
  return jsonb_set(app.cells_record_outcome(v_record.meeting_id), '{data,changed}', to_jsonb(v_changed));
end;
$$;


-- Entry point, authorizer and replay scope (replaced from 5.7).
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
       'cells.create_programme', 'cells.save_programme', 'cells.cancel_programme',
       'cells.publish_programme', 'cells.send_cannot_attend', 'cells.change_cannot_attend',
       'cells.withdraw_cannot_attend', 'cells.record_meeting_held', 'cells.correct_meeting_held',
       'cells.record_actual_leaders') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  -- 5.4 review fix 4 (AD-2, as Identity locks): the actor's member row, then its grants. Publish
  -- and cancel later share-lock people through Duties; a lifecycle change holding the member row
  -- then waits here instead of deadlocking.
  perform 1 from app.identity_members m where m.member_id = r.member_id for key share;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind in ('cell_leader', 'cell_assistant'))
     for share;
  return true;
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
  v_result jsonb;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  -- The running command, for app.cells_meeting_guard (transaction-local, cleared after).
  perform set_config('cells.command', coalesce(v_command, ''), true);
  v_result := app.cmd_execute(
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
      when 'cells.publish_programme' then 'app.cells_publish_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.send_cannot_attend' then 'app.cells_send_cannot_attend(uuid, bigint, jsonb)'::regprocedure
      when 'cells.change_cannot_attend' then 'app.cells_change_cannot_attend(uuid, bigint, jsonb)'::regprocedure
      when 'cells.withdraw_cannot_attend' then 'app.cells_withdraw_cannot_attend(uuid, bigint, jsonb)'::regprocedure
      when 'cells.record_meeting_held' then 'app.cells_record_meeting_held(uuid, bigint, jsonb)'::regprocedure
      when 'cells.correct_meeting_held' then 'app.cells_correct_meeting_held(uuid, bigint, jsonb)'::regprocedure
      when 'cells.record_actual_leaders' then 'app.cells_record_actual_leaders(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell' and v_command is distinct from 'cells.create_programme'
      and v_command is distinct from 'cells.send_cannot_attend'
      and v_command is distinct from 'cells.record_meeting_held'
  );
  perform set_config('cells.command', '', true);
  return v_result;
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
  elsif p_aggregate_type = 'cells_absence_notice' then
    -- Story 5.7: a notice's replay is for the member who sent it.
    return exists (select 1 from app.cells_absence_notices n
                     join app.identity_evaluate_grant(null, null, null) e on e.outcome = 'granted'
                    where n.notice_id = p_aggregate_id and n.member_id = e.member_id);
  elsif p_aggregate_type = 'cells_meeting_record' then
    -- Story 5.8: a meeting record's replay needs a current leader or assistant of its cell.
    return exists (select 1 from app.cells_meeting_records r
                     join app.identity_evaluate_grant(null, null, null) e on e.outcome = 'granted'
                    where r.meeting_id = p_aggregate_id
                      and app.cells_programme_capacity(e.member_id, r.cell_id) is not null);
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

comment on function api.cells_command(jsonb) is
  'Stories 2.6 and 5.1-5.8: cell setup and membership, meeting schedules and exceptions with '
  'their notices, meeting reminders, programmes (create, save, publish and cancel), Cannot '
  'attend notices (send, change, withdraw) and meeting records (held, corrections, actual '
  'leaders) through the 1.4 command envelope.';


-- api.cells_programme (replaced from 5.7): adds the meeting record.
create or replace function app.cells_programme(p_meeting_id uuid)
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
  v_programme app.cells_programmes;
  v_duties jsonb := '[]'::jsonb;
  v_part app.cells_programme_parts;
  v_linkable jsonb;
  v_owner jsonb;
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
  select p.* into v_programme from app.cells_programmes p where p.meeting_id = p_meeting_id;
  if v_capacity is not null then
    if v_programme.programme_state = 'published' then
      for v_part in
        select pt.* from app.cells_programme_parts pt
         where pt.programme_id = v_programme.programme_id and pt.removed_at is null
         order by pt.position
      loop
        v_owner := app.duties_owner_part(jsonb_build_object(
          'source_type', 'cells_programme_part', 'source_id', v_part.part_id,
          'cell_id', v_programme.cell_id));
        v_duties := v_duties || jsonb_build_array(jsonb_build_object(
          'part_id', v_part.part_id,
          'occurrence_state', v_owner #> '{occurrence,state}',
          'positions', v_owner -> 'positions'));
      end loop;
    end if;
    if (v_programme.programme_id is null or v_programme.programme_state = 'draft')
       and v_meeting.meeting_state in ('scheduled', 'moved') and v_meeting.starts_at > now() then
      v_linkable := app.cells_linkable(v_meeting);
    end if;
  end if;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, v_capacity is not null),
    'cell_name', (select c.name from app.cells_cells c where c.cell_id = v_meeting.cell_id),
    'view', case when v_full then 'full' else 'metadata' end,
    'can_edit', v_capacity is not null,
    'programme', case when v_programme.programme_id is not null
                      then app.cells_programme_json(v_programme.programme_id, v_full) end,
    'preview', case when v_full and v_programme.programme_id is not null
                    then app.cells_programme_projection(v_programme.programme_id) end,
    'published', case when v_full then (
                   select pr.body || jsonb_build_object('revision', pr.revision,
                                                        'published_at', app.cmd_utc(pr.published_at))
                     from app.cells_programme_projections pr
                    where pr.programme_id = v_programme.programme_id and pr.withdrawn_at is null) end,
    'duties', case when v_capacity is not null then v_duties else '[]'::jsonb end,
    'linkable', coalesce(v_linkable, '[]'::jsonb),
    -- Story 5.8: whether the meeting was held and who actually led each part (leader, assistant
    -- and Pastor oversight read; the leader and assistant record once the meeting has started).
    'status', app.cells_meeting_status(v_meeting),
    'record', case when v_full then app.cells_meeting_record_json(v_meeting.meeting_id) end,
    'can_record', v_capacity is not null and v_meeting.meeting_state in ('scheduled', 'moved')
                  and v_meeting.starts_at <= now(),
    -- Story 5.7: open Cannot attend notices, for the cell's leader and assistant only, with the
    -- parts their senders hold (a coverage warning).
    'absences', case when v_capacity is not null then coalesce((
      select jsonb_agg(jsonb_build_object(
               'notice_id', n.notice_id, 'member_id', n.member_id, 'display_name', im.display_name,
               'note', n.note, 'sent_at', app.cmd_utc(n.sent_at), 'updated_at', app.cmd_utc(n.updated_at),
               'part_ids', coalesce((select jsonb_agg(pt.part_id order by pt.position)
                                       from app.cells_programme_parts pt
                                      where pt.programme_id = v_programme.programme_id
                                        and pt.removed_at is null and pt.assignee_member_id = n.member_id),
                                    '[]'::jsonb))
             order by n.sent_at, n.notice_id)
        from app.cells_absence_notices n
        left join app.identity_members im on im.member_id = n.member_id
       where n.meeting_id = v_meeting.meeting_id and n.notice_state = 'open'
         and exists (select 1 from app.cells_memberships cm
                      where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                        and cm.member_id = n.member_id)), '[]'::jsonb)
      else '[]'::jsonb end,
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

-- api.cells_meetings (replaced from 5.2): adds `recent`.
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
                   '[]'::jsonb),
                 -- Story 5.8: meetings that started in the last four weeks, newest first, with
                 -- whether they were recorded as held.
                 'recent', coalesce((
                   select jsonb_agg(app.cells_meeting_json(m.meeting_id, p.private)
                                    || jsonb_build_object('status', app.cells_meeting_status(m))
                                    order by m.starts_at desc, m.meeting_id)
                     from app.cells_meetings m
                    where m.cell_id = c.cell_id and m.meeting_state <> 'withdrawn'
                      and m.starts_at <= now() and m.starts_at > now() - interval '28 days'),
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

-- Deletion hook (replaced from 5.7): meeting records and actual leaders anonymised.
create or replace function app.cells_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_parts uuid[];
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
      update app.cells_programmes p set published_by_account = v_nil where p.published_by_account = v_account;
      update app.cells_programme_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
      update app.cells_absence_notices n set sent_by_account = v_nil where n.sent_by_account = v_account;
      update app.cells_absence_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
      update app.cells_meeting_records r set recorded_by_account = v_nil where r.recorded_by_account = v_account;
      update app.cells_meeting_records r set updated_by_account = v_nil where r.updated_by_account = v_account;
      update app.cells_meeting_record_history h set actor_account_id = v_nil where h.actor_account_id = v_account;
      update app.cells_actual_leaders a set recorded_by_account = v_nil where a.recorded_by_account = v_account;
    end if;
    -- Story 5.1: meeting actors are attributed facts; the person is anonymised.
    update app.cells_meeting_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.cells_meetings m set changed_by_member = v_nil where m.changed_by_member = v_member;
    update app.cells_meeting_schedules s set set_by_member = v_nil where s.set_by_member = v_member;
    update app.cells_reminders_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.2: a contact need is kept as an anonymous fact.
    update app.cells_meeting_contact_needs n set member_id = v_nil where n.member_id = v_member;
    -- Story 5.7: the member's notices keep no person and no note.
    update app.cells_absence_notices n
       set member_id = v_nil, note = null, notice_state = 'withdrawn',
           withdrawn_at = coalesce(n.withdrawn_at, now())
     where n.member_id = v_member;
    update app.cells_absence_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.8: who recorded and who led stay as anonymous facts; the reasons the member wrote go
    -- (free text may name people; review fix 5).
    update app.cells_meeting_record_history h set reason = null
     where h.actor_member_id = v_member and h.reason is not null;
    update app.cells_actual_leaders a set reason = null
     where a.recorded_by_member = v_member and a.reason is not null;
    update app.cells_meeting_records r set recorded_by_member = v_nil where r.recorded_by_member = v_member;
    update app.cells_meeting_records r set updated_by_member = v_nil where r.updated_by_member = v_member;
    update app.cells_meeting_record_history h set actor_member_id = v_nil where h.actor_member_id = v_member;
    update app.cells_actual_leaders a set recorded_by_member = v_nil where a.recorded_by_member = v_member;
    update app.cells_actual_leaders a set member_id = v_nil where a.member_id = v_member;
    update app.cells_actual_leaders a set planned_member_id = v_nil where a.planned_member_id = v_member;
    -- Story 5.4: the member's name leaves every published projection (their parts read as open).
    v_parts := array(select pt.part_id from app.cells_programme_parts pt
                      where pt.assignee_member_id = v_member);
    update app.cells_programme_projections pr
       set body = jsonb_set(pr.body, '{parts}', coalesce((
             select jsonb_agg(case when (t.e ->> 'part_id')::uuid = any (v_parts)
                                   then t.e || '{"leader": null}'::jsonb else t.e end order by t.o)
               from jsonb_array_elements(pr.body -> 'parts') with ordinality t(e, o)), '[]'::jsonb))
     where pr.programme_id in (select pt.programme_id from app.cells_programme_parts pt
                                where pt.part_id = any (v_parts));
    -- Story 5.3: a part the member was planned for becomes a gap; programme actors anonymised.
    update app.cells_programme_parts pt set assignee_member_id = null, updated_at = now()
     where pt.assignee_member_id = v_member;
    update app.cells_programmes p set created_by_member = v_nil where p.created_by_member = v_member;
    update app.cells_programmes p set updated_by_member = v_nil where p.updated_by_member = v_member;
    update app.cells_programmes p set published_by_member = v_nil where p.published_by_member = v_member;
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
           where p.created_by_member = v_member or p.updated_by_member = v_member
              or p.published_by_member = v_member)
       + (select count(*) from app.cells_programme_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_absence_notices n where n.member_id = v_member)
       + (select count(*) from app.cells_absence_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_meeting_records r
           where r.recorded_by_member = v_member or r.updated_by_member = v_member)
       + (select count(*) from app.cells_meeting_record_history h where h.actor_member_id = v_member)
       + (select count(*) from app.cells_actual_leaders a
           where a.recorded_by_member = v_member or a.member_id = v_member or a.planned_member_id = v_member)
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
             where p.created_by_account = v_account or p.updated_by_account = v_account
                or p.published_by_account = v_account)
         + (select count(*) from app.cells_programme_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_absence_notices n where n.sent_by_account = v_account)
         + (select count(*) from app.cells_absence_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_meeting_records r
             where r.recorded_by_account = v_account or r.updated_by_account = v_account)
         + (select count(*) from app.cells_meeting_record_history h where h.actor_account_id = v_account)
         + (select count(*) from app.cells_actual_leaders a where a.recorded_by_account = v_account)
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

revoke all on function
  app.cells_meeting_status(app.cells_meetings),
  app.cells_actual_leader_json(app.cells_actual_leaders, boolean),
  app.cells_meeting_record_json(uuid),
  app.cells_meeting_reference(uuid),
  app.cells_record_outcome(uuid),
  app.cells_record_meeting(jsonb, uuid),
  app.cells_lock_record(uuid, bigint),
  app.cells_record_meeting_held(uuid, bigint, jsonb),
  app.cells_correct_meeting_held(uuid, bigint, jsonb),
  app.cells_record_actual_leaders(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
