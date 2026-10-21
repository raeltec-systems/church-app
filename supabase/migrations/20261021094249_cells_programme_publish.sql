-- Story 5.4: preview and publish a safe programme that creates or links duty slots (epic 5, C4).
-- Builds on 20261021084446_cells_programmes.sql and 20261021093943_duties_owner_linkable.sql.
--
--   * A programme can be Published. Publishing calls the 4.11 Duties owner operations in the
--     command's own transaction: one cell-owned Duties occurrence per stable programme part with
--     one position (key `lead`), its assignee asked for an explicit response (Awaiting), or an
--     open position for an unassigned part; or a display link (key `department`) to an existing
--     department position, which is never cloned or changed. A republish puts the same state
--     again, so no slot is duplicated.
--   * A dedicated safe projection (app.cells_programme_projections) is written on publish: topic,
--     scripture, parts with their times, the named leader or the linked department. No study
--     notes, responses, notes or history. Members read it through api.cells_meeting_programme
--     (current confirmed members of the cell with an approved active account); the staff read
--     carries the same projection built from the draft as its preview.
--   * Drafts may name a department position to show (linked_slot_id), chosen from the new Duties
--     read app.duties_owner_linkable (the meeting's window).
--   * Cancelling a published programme cancels its cell-owned duties and ends its display links.
--   * Registers the `cells_programme_part` source (1.5) and its Duties `cell_part` role (4.11).
--   * While a programme is published, its meeting is not moved or cancelled through the meeting
--     commands (`conflict {"meeting_id": "programme_published"}`): cancel the programme first.
--     Reconciling published duties with a changed meeting is story 5.6.
--   * Carries the 5.3 review fixes (5.3 is on staging) and the 5.4 review fixes.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- 5.3 review fixes (see the 5.3 plan's Review Triage Log)
-- ---------------------------------------------------------------------------------------------

-- Fix 9 (low): study notes with Windows line endings are normalised, not refused.
create or replace function app.cells_free_text(p_value jsonb, p_max integer, p_multiline boolean,
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
  if p_multiline then
    value := replace(value, chr(13) || chr(10), chr(10));
  else
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

-- Fix 1 (medium): a draft's part times follow its meeting. When a meeting's start changes (a move,
-- a bring back or a re-timing by the schedule), a draft programme's live parts shift by the same
-- amount and its revision is bumped, so an open editor gets a conflict instead of saving stale
-- times. A published programme is left alone: its duties are reconciled through Duties (5.6).
-- Runs under the meeting row the updater already holds (meeting before programme).
create function app.cells_programme_follow_meeting()
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
   where p.meeting_id = new.meeting_id and p.programme_state = 'draft'
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

create trigger cells_meetings_programme_follow
  after update of starts_at on app.cells_meetings
  for each row execute function app.cells_programme_follow_meeting();

-- Fix 3 (medium): two concurrent creates answer conflict, not an internal error.
create or replace function app.cells_create_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  begin
    insert into app.cells_programmes (meeting_id, cell_id, created_by_member, created_by_account,
                                      updated_by_member, updated_by_account)
    values (v_meeting.meeting_id, v_meeting.cell_id, v_actor.member_id, v_actor.account_id,
            v_actor.member_id, v_actor.account_id)
    returning * into v_programme;
  exception when unique_violation then
    perform app.cmd_fail('conflict', '{"meeting_id": "exists"}');
  end;
  perform app.cells_programme_audit_row('programme_created', v_programme, v_actor.member_id,
                                        v_actor.account_id, v_capacity, 'cells.create_programme', 1);
  return app.cells_programme_outcome(v_programme.programme_id);
end;
$$;

-- Fix 4 (medium, partly): each meeting plans in its own sub-block, so one refusal loses only that
-- meeting's notice (logged), not every notice of the run. Otherwise 5.3's body.
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

-- Fix 5 (medium): the confirm-time sync never blocks a confirmation, and both cells are synced in
-- cell-id order (two crossing transfers lock their meetings in the same order). Otherwise 5.3's
-- body.
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
  v_sync uuid;
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
  -- Story 5.2 review fix 4, 5.3 review fix 5: meeting reminders follow the membership now
  -- (Notifications last), in cell-id order, and never block the confirmation.
  if app.cells_reminders_available() then
    begin
      for v_sync in
        select c from unnest(array[v_cell, v_old.cell_id]) c where c is not null order by c
      loop
        perform app.cells_sync_meeting_reminders(v_sync);
      end loop;
    exception when sqlstate 'PCMD1' then
      raise log 'cells meeting reminders not planned on a confirmation (sqlstate PCMD1)';
    end;
  end if;
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Story 5.4: published state, department links and the safe projection
-- ---------------------------------------------------------------------------------------------

create or replace function app.cells_programme_state_ok(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value in ('draft', 'published', 'cancelled');
$$;

create or replace function app.cells_programme_audit_action_ok(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value in ('programme_created', 'programme_saved', 'programme_cancelled',
                     'programme_published');
$$;

alter table app.cells_programmes
  add column published_revision bigint check (published_revision is null or published_revision >= 1),
  add column published_at timestamptz,
  add column published_by_member uuid,
  add column published_by_account uuid;

alter table app.cells_programme_parts
  add column linked_slot_id uuid,
  add column linked_label text check (linked_label is null or length(linked_label) between 1 and 200),
  add column duty_occurrence_id uuid;

alter table app.cells_programme_parts
  add constraint cells_programme_parts_one_lead
  check (linked_slot_id is null or assignee_member_id is null);

comment on column app.cells_programme_parts.linked_slot_id is
  'Story 5.4: a department position this part shows (a Duties display link; never cloned).';
comment on column app.cells_programme_parts.duty_occurrence_id is
  'Story 5.4: the cell-owned Duties occurrence published for this part (key lead).';

-- The safe projection members read (AD-5): written on publish, never derived on read.
create table app.cells_programme_projections (
  programme_id uuid primary key references app.cells_programmes (programme_id),
  meeting_id uuid not null unique references app.cells_meetings (meeting_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  revision bigint not null check (revision >= 1),
  body jsonb not null check (jsonb_typeof(body) = 'object'),
  published_at timestamptz not null,
  withdrawn_at timestamptz
);

create index cells_programme_projections_cell on app.cells_programme_projections (cell_id);

comment on table app.cells_programme_projections is
  'owner: cells. The member-safe published programme (story 5.4, AD-5): topic, scripture, parts '
  'with times and the named leader or linked department. No study notes, responses, notes or '
  'history.';

alter table app.cells_programme_projections enable row level security;
revoke all on table app.cells_programme_projections from public, anon, authenticated, service_role;

-- The member-safe body of a programme as it stands (the publish snapshot and the staff preview).
create function app.cells_programme_projection(p_programme_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'programme_id', p.programme_id,
    'meeting_id', p.meeting_id,
    'topic', p.topic,
    'scripture', p.scripture,
    'parts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'part_id', pt.part_id,
               'label', pt.label,
               'starts_at', app.cmd_utc(pt.starts_at),
               'ends_at', app.cmd_utc(pt.ends_at),
               'leader', (select im.display_name from app.identity_members im
                           where im.member_id = pt.assignee_member_id),
               'department', pt.linked_label)
             order by pt.position)
        from app.cells_programme_parts pt
       where pt.programme_id = p.programme_id and pt.removed_at is null), '[]'::jsonb))
    from app.cells_programmes p
   where p.programme_id = p_programme_id;
$$;

-- The programme as its managers and Pastor oversight see it (p_full) or as an Admin-only reader
-- sees it (state, revision and counts only). Story 5.4 adds the published revision and each
-- part's department link.
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

-- ---------------------------------------------------------------------------------------------
-- The programme part as a Duties source (1.5 and 4.11)
-- ---------------------------------------------------------------------------------------------

-- {current, revision}: a part's revision is its programme's revision (every save and publish
-- bumps it); a removed part is never current.
create function app.cells_programme_part_check(p_source jsonb)
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
     where pt.part_id::text = p_source ->> 'source_id' and pt.removed_at is null),
    '{"current": false, "revision": null}'::jsonb);
$$;

revoke all on function app.cells_programme_part_check(jsonb) from public, anon, authenticated, service_role;

select app.contract_register_source_type(
  'cells', 'cells_programme_part', 'app.cells_programme_part_check(jsonb)'::regprocedure);
select app.duties_register_link_source('cells', 'cells_programme_part', 'cell_part');

-- The source reference of a part at a programme revision.
create function app.cells_part_ref(p_part_id uuid, p_revision bigint, p_cell_id uuid)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('source_type', 'cells_programme_part', 'source_id', p_part_id,
                            'source_revision', p_revision, 'cell_id', p_cell_id);
$$;

-- The department positions a part may show, for a meeting (the Duties contract read).
create function app.cells_linkable(p_meeting app.cells_meetings)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.duties_owner_linkable(jsonb_build_object(
    'cell_id', p_meeting.cell_id, 'starts_at', app.cmd_utc(p_meeting.starts_at),
    'ends_at', app.cmd_utc(p_meeting.ends_at)));
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- cells.save_programme (replaced from 5.3): parts may name a department position to show
-- (`linked_slot_id`, one of the meeting's linkable positions; not with an assignee). 5.3 review
-- fixes 2 (after-midnight parts), 6 (a removed part never returns) and 7 (meeting locked first).
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
  if v_programme.programme_state <> 'draft' then
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

-- The Duties side of one part (publish and republish): a display link for a department position,
-- otherwise the cell-owned occurrence with one position (`lead`) for the assignee or open.
create function app.cells_publish_part(p_part app.cells_programme_parts, p_programme app.cells_programmes,
                                       p_venue text, p_override_reason text)
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
  if p_part.linked_slot_id is not null then
    select e into v_link from jsonb_array_elements(v_existing -> 'positions') e
     where e ->> 'kind' = 'linked' and e ->> 'position_key' = 'department';
    if v_link is not null and (v_link ->> 'slot_id')::uuid = p_part.linked_slot_id then
      return jsonb_build_object('part_id', p_part.part_id, 'kind', 'linked', 'changed', false,
                                'slot_id', p_part.linked_slot_id);
    end if;
    if v_link is not null then
      perform app.duties_owner_unlink(v_ref || '{"position_key": "department"}'::jsonb);
    end if;
    v_result := app.duties_owner_link_duty(v_ref || jsonb_build_object(
                  'position_key', 'department', 'slot_id', p_part.linked_slot_id));
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
  return jsonb_build_object('part_id', p_part.part_id, 'kind', 'owned',
                            'changed', coalesce((v_result ->> 'created')::boolean, false)
                                       or coalesce((v_result ->> 'changed')::boolean, false),
                            'occurrence_id', v_result -> 'occurrence_id',
                            'positions', v_result -> 'positions');
end;
$$;

-- cells.publish_programme {programme_id}; the leader or assistant; expected = the programme
-- revision. A draft (or an already published programme, which republishes the same state) becomes
-- Published: each live part reaches Duties in this transaction (cell-owned slot or display link)
-- and the member-safe projection is written. Every assignee must still be in the cell. A Duties
-- refusal of one part is answered under that part (`parts.<index>.<field>`, e.g. an overlap with
-- the assignee's other duties: `parts.1.member_id: overlap`); `override_reason` (optional, as
-- Duties takes it) keeps such overlaps knowingly.
create function app.cells_publish_programme(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
begin
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
  for v_part in
    select pt.* from app.cells_programme_parts pt
     where pt.programme_id = v_programme.programme_id and pt.removed_at is null
     order by pt.position
  loop
    begin
      v_results := v_results || jsonb_build_array(
                     app.cells_publish_part(v_part, v_programme, v_venue, v_reason.value));
    exception when sqlstate 'PCMD1' then
      get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
      -- 5.4 review fixes 3 and 6: a department position that is gone is answered on its part; a
      -- Duties conflict (changed meanwhile) carries the programme's revision, not the duty's.
      if v_msg = 'not_found' and v_part.linked_slot_id is not null then
        perform app.cmd_fail('validation_failed', jsonb_build_object(
          'parts.' || (v_part.position - 1) || '.linked_slot_id', 'link_unavailable'));
      elsif v_msg = 'conflict' then
        perform app.cmd_fail('conflict', null, v_before);
      elsif v_msg <> 'validation_failed' then
        raise;
      end if;
      perform app.cmd_fail('validation_failed', coalesce((
        select jsonb_object_agg('parts.' || (v_part.position - 1) || '.' || e.key, e.value)
          from jsonb_each(v_detail::jsonb -> 'field_errors') e),
        jsonb_build_object('parts.' || (v_part.position - 1), 'refused')));
    end;
  end loop;
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

-- cells.cancel_programme (replaced from 5.3): a published programme's cell-owned duties are
-- cancelled (their assignees told by Duties) and its display links ended; members no longer read
-- it. People are locked first, as for publish.
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
      select pt.* from app.cells_programme_parts pt
       where pt.programme_id = (v_lock.programme).programme_id and pt.removed_at is null
       order by pt.position
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

-- ---------------------------------------------------------------------------------------------
-- Entry point and authorizer (replaced from 5.3)
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
       'cells.create_programme', 'cells.save_programme', 'cells.cancel_programme',
       'cells.publish_programme') then
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
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell' and v_command is distinct from 'cells.create_programme'
  );
  perform set_config('cells.command', '', true);
  return v_result;
end;
$$;

-- 5.4 review fix 2: a meeting whose programme is published is not moved or cancelled by the
-- meeting commands (its duties would keep the old time). Generation (a schedule change or a read)
-- is not refused: that reconciliation is story 5.6.
create function app.cells_meeting_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(current_setting('cells.command', true), '') in ('cells.move_meeting', 'cells.cancel_meeting')
     and (new.starts_at, new.ends_at, new.meeting_state, new.moved_venue)
         is distinct from (old.starts_at, old.ends_at, old.meeting_state, old.moved_venue)
     and exists (select 1 from app.cells_programmes p
                  where p.meeting_id = new.meeting_id and p.programme_state = 'published') then
    perform app.cmd_fail('conflict', '{"meeting_id": "programme_published"}', old.revision);
  end if;
  return new;
end;
$$;

create trigger cells_meetings_published_guard
  before update on app.cells_meetings
  for each row execute function app.cells_meeting_guard();

comment on function api.cells_command(jsonb) is
  'Stories 2.6 and 5.1-5.4: cell setup and membership, meeting schedules and exceptions with '
  'their notices, meeting reminders, and programmes (create, save, publish and cancel) through '
  'the 1.4 command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- api.cells_programme(meeting_id) (replaced from 5.3). Adds, for the full view: `preview` (the
-- member-safe projection of the programme as it stands) and `published` (what members read now);
-- for the cell's leader and assistant: `linkable` (department positions a draft part may show)
-- and `duties` (each published part's Duties state: the response of its owned position, or its
-- display link). Pastor oversight gets no Duties state (Duties answers only the cell's managers).
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

-- api.cells_meeting_programme(meeting_id): a meeting's published programme for the members of its
-- cell. Only a current confirmed member of the meeting's cell with an approved active account
-- reads it (anyone else, the cell's leader included when not a member, is refused 403
-- not_granted: managers use api.cells_programme). Answers the meeting with its private venue and
-- the safe projection (null while nothing is published).
create function app.cells_meeting_programme(p_meeting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_meeting app.cells_meetings;
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
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, true),
    'programme', (select pr.body || jsonb_build_object('revision', pr.revision,
                                                       'published_at', app.cmd_utc(pr.published_at))
                    from app.cells_programme_projections pr
                   where pr.meeting_id = v_meeting.meeting_id and pr.withdrawn_at is null));
end;
$$;

create function api.cells_meeting_programme(meeting_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_meeting_programme(meeting_id);
$$;

comment on function api.cells_meeting_programme(uuid) is
  'Story 5.4: a meeting''s published programme (member-safe projection) for the current confirmed '
  'members of its cell, with the private venue. No study notes, responses, notes or history.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced from 5.3): publishers anonymised, names left out of projections
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
    end if;
    -- Story 5.1: meeting actors are attributed facts; the person is anonymised.
    update app.cells_meeting_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.cells_meetings m set changed_by_member = v_nil where m.changed_by_member = v_member;
    update app.cells_meeting_schedules s set set_by_member = v_nil where s.set_by_member = v_member;
    update app.cells_reminders_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.2: a contact need is kept as an anonymous fact.
    update app.cells_meeting_contact_needs n set member_id = v_nil where n.member_id = v_member;
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
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

comment on function app.cells_erase_member(jsonb) is
  'Cells deletion hook (stories 2.11 and 5.1-5.4): erase or check the member''s Cells personal '
  'data; meeting and programme actors and contact needs anonymised, programme parts made gaps, '
  'names left out of published projections.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_programme_follow_meeting(),
  app.cells_meeting_guard(),
  app.cells_programme_projection(uuid),
  app.cells_part_ref(uuid, bigint, uuid),
  app.cells_linkable(app.cells_meetings),
  app.cells_publish_part(app.cells_programme_parts, app.cells_programmes, text, text),
  app.cells_publish_programme(uuid, bigint, jsonb),
  app.cells_meeting_programme(uuid),
  api.cells_meeting_programme(uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.cells_meeting_programme(uuid) to authenticated;
grant execute on function api.cells_meeting_programme(uuid) to authenticated;

notify pgrst, 'reload schema';
