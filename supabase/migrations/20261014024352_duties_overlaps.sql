-- Warn on overlapping duties and record reasoned overrides (story 4.4; AD-2, AD-6). A forward
-- migration on the Duties owner (20261013220239_duties_department_tracer.sql,
-- 20261014001142_duties_revisions.sql and 20261014023442_duties_rota_series.sql are not
-- edited). It adds:
--
--   * Owning scope: an occurrence is owned by exactly one department or one cell
--     (app.duties_occurrences.cell_id; department_id becomes nullable). No command creates a
--     cell-owned occurrence yet (entry 11 adds the Cells owner operations); tests and the local
--     E2E use a SYNTHETIC cell-owned fixture to prove the cell case of the conflict query.
--   * Commitments and busy time: a commitment is a current assignment the member has not
--     declined (pending or accepted) on a published occurrence of any owner. Its busy time is
--     [reporting time or start, end time) and, with no end time, two hours from the start
--     (app.duties_busy_range). Ranges are half-open: back-to-back duties do not overlap.
--   * The conflict query (app.duties_busy_items): a member's commitments overlapping a time
--     range, plus (when a department is given) the member's planned draft positions in that
--     department. Availability is never assumed: no conflict does not mean free.
--   * The candidates read api.duties_candidates (the department's leader, deputy or an Admin):
--     for a position (slot_id) or a prospective one-off duty (department_id and times), each
--     roster member's upcoming load (next 90 days: all owners, this department) and the
--     overlaps the viewer may see. A conflict in a department the viewer manages, or in a cell
--     the viewer leads or assists, shows the duty, position, times, place, state and answer;
--     any other shows only its owner kind and busy time. Instructions are never shown.
--   * The override gate: every command that creates an assignment with a new assignee or new
--     times (publish_duty, assign_slot, publish_drafts, revise_duty, revise_series) refuses an
--     overlap without `override_reason` (validation_failed {"member_id": "overlap",
--     "override_reason": "required"}); with one, the reason, the overlap count, the recorder
--     and the time are recorded with the assignment, which stays pending (the assignee still
--     chooses). A change that keeps the person and the times carries an earlier override
--     forward. Draft positions keep a planned reason on the slot; Publish N carries it into the
--     assignment and refuses an overlap without one, naming the date.
--   * Concurrent assignments of one member are serialised by a per-member transaction advisory
--     lock (app.duties_lock_members), so two leaders cannot both skip the warning.
--   * Projections: the leader board and the rota show each position's overlap count and the
--     recorded override (reason, count, recorder, time) to the department's managers and
--     Pastor oversight. My duties lists department-owned duties only until cell parts get a
--     member view.
--   * Deletion: an erased assignee's override reasons are cleared and override recorders are
--     anonymised (nil UUID); no new row deletions, so no new _rows file.
--
-- Lock order (AD-2), as in 4.3: the actor's grant rows FOR SHARE (authorizer) -> command
-- receipt -> department FOR SHARE -> series FOR UPDATE -> occurrences FOR UPDATE (series date
-- order) -> member advisory locks (member id order) and department membership FOR SHARE ->
-- slots FOR UPDATE -> assignments FOR UPDATE -> Notifications (cancel, enqueue), always last.
--
-- No destructive statements, no row deletions. New client grant: api.duties_candidates(...) and
-- its app body (authenticated only).

-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened)
-- ---------------------------------------------------------------------------------------------

create or replace function app.duties_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'department_state' then p_value in ('active')
    when 'occurrence_state' then p_value in ('draft', 'published', 'cancelled')
    when 'assignment_state' then p_value in ('current', 'superseded', 'cancelled')
    when 'assignment_end_reason' then p_value in ('revised', 'cancelled')
    when 'response' then p_value in ('pending', 'accepted', 'declined')
    when 'response_provenance' then p_value in ('member')
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member')
    when 'change_class' then p_value in ('published', 'material', 'notes', 'reference', 'cancelled')
    when 'slot_field' then p_value in ('duty_name', 'starts_at', 'ends_at', 'reporting_at',
                                       'location', 'member_id', 'instructions', 'topic',
                                       'scripture', 'event_ref', 'position_name')
    when 'series_every' then p_value in ('day', 'week', 'month')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override')
    else false end;
$$;

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (stories 4.1-4.4). Later stories widen them by replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Owning scope: exactly one department or one cell (AD-6). No foreign key across owners: the
-- Cells owner operations (entry 11) validate the cell.
alter table app.duties_occurrences add column cell_id uuid;
alter table app.duties_occurrences alter column department_id drop not null;
alter table app.duties_occurrences
  add constraint duties_occurrences_one_owner check ((department_id is null) <> (cell_id is null));

create index duties_occurrences_cell on app.duties_occurrences (cell_id, starts_at)
  where cell_id is not null;

-- The conflict query and the overlap counts read a member's current assignments.
create index duties_assignments_member_current on app.duties_assignments (member_id, slot_id)
  where assignment_state = 'current';

comment on column app.duties_occurrences.cell_id is
  'Story 4.4: the owning cell of a cell-owned occurrence (exactly one of department_id and '
  'cell_id is set). Created only through the Cells owner operations (entry 11).';

-- The recorded override of an overlap (story 4.4). override_at marks that one was recorded;
-- the reason is cleared when the assignee is erased.
alter table app.duties_assignments
  add column override_reason text
    check (override_reason is null or length(override_reason) between 1 and 280),
  add column override_overlaps integer
    check (override_overlaps is null or override_overlaps between 1 and 1000),
  add column override_by_member uuid,
  add column override_by_account uuid,
  add column override_at timestamptz,
  add constraint duties_assignments_override
    check (override_at is not null
           or (override_reason is null and override_overlaps is null
               and override_by_member is null and override_by_account is null));

comment on column app.duties_assignments.override_reason is
  'Story 4.4: why the assignment was made although it overlaps another commitment of the '
  'member (the leader''s words; shown to the department''s managers and Pastor, never to the '
  'member or another department).';

-- A planned (draft) position's override, carried into the assignment by Publish N.
alter table app.duties_slots
  add column draft_override_reason text
    check (draft_override_reason is null or length(draft_override_reason) between 1 and 280),
  add column draft_override_by_member uuid,
  add column draft_override_by_account uuid,
  add column draft_override_at timestamptz,
  add constraint duties_slots_draft_override
    check (draft_override_reason is null
           or (draft_member_id is not null and draft_override_at is not null));

-- Ended assignments are immutable (replaced: the override fields too; erasure may only clear
-- the reason and anonymise the recorder).
create or replace function app.duties_assignment_history_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if old.assignment_state = 'current' then
    return new;
  end if;
  if (new.assignment_id, new.slot_id, new.assignment_state, new.response, new.response_deadline,
      new.responded_at, new.response_provenance, new.revision, new.assigned_at,
      new.slot_revision, new.supersedes_assignment_id, new.ended_at, new.end_reason,
      new.override_overlaps, new.override_at)
     is distinct from
     (old.assignment_id, old.slot_id, old.assignment_state, old.response, old.response_deadline,
      old.responded_at, old.response_provenance, old.revision, old.assigned_at,
      old.slot_revision, old.supersedes_assignment_id, old.ended_at, old.end_reason,
      old.override_overlaps, old.override_at)
     or (new.member_id is distinct from old.member_id and new.member_id is distinct from v_nil)
     or (new.responded_by_member is distinct from old.responded_by_member
         and new.responded_by_member is distinct from v_nil)
     or (new.responded_by_account is distinct from old.responded_by_account
         and new.responded_by_account is distinct from v_nil)
     or (new.assigned_by_member is distinct from old.assigned_by_member
         and new.assigned_by_member is distinct from v_nil)
     or (new.assigned_by_account is distinct from old.assigned_by_account
         and new.assigned_by_account is distinct from v_nil)
     or (new.override_by_member is distinct from old.override_by_member
         and new.override_by_member is distinct from v_nil)
     or (new.override_by_account is distinct from old.override_by_account
         and new.override_by_account is distinct from v_nil)
     or (new.response_note is distinct from old.response_note and new.response_note is not null)
     or (new.override_reason is distinct from old.override_reason and new.override_reason is not null) then
    raise exception using errcode = 'P0001', message = 'ended duties assignments are immutable';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Busy time, commitments and the conflict query
-- ---------------------------------------------------------------------------------------------

-- The busy time of a duty: [reporting time or start, end time); two hours from the start when
-- there is no end time (an adjustable assumption, never "free").
create function app.duties_busy_range_of(p_starts timestamptz, p_ends timestamptz,
                                         p_reporting timestamptz)
returns tstzrange
language sql
stable
set search_path = ''
as $$
  select tstzrange(coalesce(p_reporting, p_starts), coalesce(p_ends, p_starts + interval '2 hours'),
                   '[)');
$$;

create function app.duties_busy_range(p_occurrence app.duties_occurrences)
returns tstzrange
language sql
stable
set search_path = ''
as $$
  select app.duties_busy_range_of(p_occurrence.starts_at, p_occurrence.ends_at,
                                  p_occurrence.reporting_at);
$$;

comment on function app.duties_busy_range_of(timestamptz, timestamptz, timestamptz) is
  'Story 4.4: the busy time of a duty, [reporting or start, end); start + 2 hours without an end.';

-- What a member is busy with during p_range, other than position p_exclude_slot: commitments
-- (current pending or accepted assignments on published occurrences of any owner) and, when
-- p_department is given, planned draft positions in that department. The nil (erased) member
-- has none. p_moving: an occurrence being moved to p_range (an edit preview), whose other
-- positions move with it and so always overlap.
create function app.duties_busy_items(p_member uuid, p_range tstzrange, p_exclude_slot uuid,
                                      p_department uuid, p_moving uuid)
returns table (kind text, slot_id uuid, occurrence_id uuid, response text, busy tstzrange)
language sql
stable
set search_path = ''
as $$
  select 'assignment', s.slot_id, o.occurrence_id, a.response,
         case when o.occurrence_id = p_moving then p_range else app.duties_busy_range(o) end
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and a.response in ('pending', 'accepted') and o.occurrence_state = 'published'
     and s.slot_id is distinct from p_exclude_slot
     and p_member is distinct from '00000000-0000-0000-0000-000000000000'::uuid
     and (o.occurrence_id = p_moving or app.duties_busy_range(o) && p_range)
  union all
  select 'draft', s.slot_id, o.occurrence_id, null,
         case when o.occurrence_id = p_moving then p_range else app.duties_busy_range(o) end
    from app.duties_slots s
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where p_department is not null and s.draft_member_id = p_member
     and o.occurrence_state = 'draft' and o.department_id = p_department
     and s.slot_id is distinct from p_exclude_slot
     and (o.occurrence_id = p_moving or app.duties_busy_range(o) && p_range);
$$;

comment on function app.duties_busy_items(uuid, tstzrange, uuid, uuid, uuid) is
  'Story 4.4: the conflict query: a member''s commitments (any owner) and, with a department, '
  'planned draft positions there, overlapping a range.';

create function app.duties_overlap_count(p_member uuid, p_range tstzrange, p_exclude_slot uuid,
                                         p_department uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer from app.duties_busy_items(p_member, p_range, p_exclude_slot, p_department, null);
$$;

-- The overlaps of a member as p_viewer may see them (at most 10, earliest first) and their
-- count. Full detail for a department p_viewer manages or a cell p_viewer leads or assists;
-- otherwise only the owner kind and the busy time. Never instructions.
create function app.duties_conflicts_json(p_viewer uuid, p_member uuid, p_range tstzrange,
                                          p_exclude_slot uuid, p_department uuid, p_moving uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with items as (
    select b.kind, b.slot_id, b.response, b.busy, o.occurrence_id, o.department_id, o.cell_id,
           o.duty_name, o.occurrence_state, o.starts_at, o.ends_at, o.reporting_at, o.location,
           case when o.department_id is not null
                then app.duties_manage_capacity(p_viewer, o.department_id) is not null
                     -- A synthetic department is never named outside local and staging.
                     and (not d.is_synthetic
                          or app.platform_current_environment() in ('local', 'staging'))
                else app.identity_member_has_scope(p_viewer, 'cell_leader', o.cell_id)
                     or app.identity_member_has_scope(p_viewer, 'cell_assistant', o.cell_id) end
             as visible
      from app.duties_busy_items(p_member, p_range, p_exclude_slot, p_department, p_moving) b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      left join app.duties_departments d on d.department_id = o.department_id
  ), firsts as (
    select i.* from items i order by lower(i.busy), i.occurrence_id, i.slot_id limit 10
  )
  select jsonb_build_object(
    'count', (select count(*) from items),
    'items', coalesce((
      select jsonb_agg(case when f.visible then jsonb_build_object(
                 'visibility', 'full',
                 'owner_kind', case when f.cell_id is null then 'department' else 'cell' end,
                 'occurrence_id', f.occurrence_id,
                 'owner_name', (select d.name from app.duties_departments d
                                 where d.department_id = f.department_id),
                 'duty_name', f.duty_name,
                 'position_name', (select s.position_name from app.duties_slots s
                                    where s.slot_id = f.slot_id),
                 'state', f.occurrence_state,
                 'response', f.response,
                 'starts_at', app.cmd_utc(f.starts_at),
                 'ends_at', case when f.ends_at is not null then app.cmd_utc(f.ends_at) end,
                 'reporting_at', case when f.reporting_at is not null then app.cmd_utc(f.reporting_at) end,
                 'location', f.location,
                 'from', app.cmd_utc(lower(f.busy)),
                 'to', app.cmd_utc(upper(f.busy)))
               else jsonb_build_object(
                 'visibility', 'limited',
                 'owner_kind', case when f.cell_id is null then 'department' else 'cell' end,
                 'from', app.cmd_utc(lower(f.busy)),
                 'to', app.cmd_utc(upper(f.busy))) end
             order by lower(f.busy), f.occurrence_id, f.slot_id)
        from firsts f), '[]'::jsonb));
$$;

-- The member's upcoming load: current pending or accepted duties starting in the next 90 days,
-- all owners and in p_department.
create function app.duties_upcoming(p_member uuid, p_department uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'total', count(*),
           'here', count(*) filter (where o.department_id = p_department))
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and a.response in ('pending', 'accepted') and o.occurrence_state = 'published'
     and o.starts_at > now() and o.starts_at <= now() + interval '90 days';
$$;

-- Serialises everything that may create an assignment for these members (one transaction
-- advisory lock per member, in member id order; the membership step of the AD-2 order).
create function app.duties_lock_members(p_members uuid[])
returns void
language plpgsql
set search_path = ''
as $$
declare
  v uuid;
begin
  for v in select distinct m from unnest(coalesce(p_members, '{}'::uuid[])) m
            where m is not null order by m loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('app.duties_member ' || v::text, 0));
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The override gate
-- ---------------------------------------------------------------------------------------------

-- A new assignment (current, just written by this command): when it overlaps another
-- commitment of its member, p_reason is required (validation_failed {"member_id": "overlap",
-- "override_reason": "required"} merged with p_refusal) and is recorded with the assignment,
-- attributed to p_by_member/p_by_account at p_at, with a content-free audit row. A reason given
-- when nothing overlaps is not recorded. Returns the number of overlaps (0: none).
create function app.duties_overlap_gate(p_assignment_id uuid, p_reason text, p_by_member uuid,
                                        p_by_account uuid, p_at timestamptz,
                                        p_actor_member uuid, p_actor_account uuid,
                                        p_capacity text, p_command text, p_refusal jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occ app.duties_occurrences;
  v_count integer;
begin
  select a.* into v_assignment from app.duties_assignments a where a.assignment_id = p_assignment_id;
  select o.* into v_occ
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  v_count := app.duties_overlap_count(v_assignment.member_id, app.duties_busy_range(v_occ),
                                      v_assignment.slot_id, null);
  if v_count = 0 then
    return 0;
  end if;
  if p_reason is null then
    perform app.cmd_fail('validation_failed',
      '{"member_id": "overlap", "override_reason": "required"}'::jsonb || coalesce(p_refusal, '{}'::jsonb));
  end if;
  update app.duties_assignments a
     set override_reason = p_reason, override_overlaps = least(v_count, 1000),
         override_by_member = p_by_member, override_by_account = p_by_account, override_at = p_at
   where a.assignment_id = p_assignment_id;
  perform app.duties_audit_series_event('overlap_override', p_actor_member, p_actor_account,
                                        p_capacity, p_command, v_occ.department_id, v_occ.series_id,
                                        v_occ.occurrence_id, p_assignment_id, v_assignment.member_id,
                                        'overlap', v_assignment.revision);
  return v_count;
end;
$$;

-- Gates the assignments a change created (app.duties_apply_change's `created`), skipping those
-- that kept their person and times (their override was carried forward). Returns the number of
-- overrides recorded.
create function app.duties_gate_created(p_created jsonb, p_reason text, p_actor_member uuid,
                                        p_actor_account uuid, p_capacity text, p_command text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  x jsonb;
  v_recorded integer := 0;
begin
  for x in select e from jsonb_array_elements(coalesce(p_created, '[]'::jsonb)) e loop
    if not coalesce((x ->> 'carried')::boolean, false)
       and app.duties_overlap_gate((x ->> 'assignment_id')::uuid, p_reason, p_actor_member,
                                   p_actor_account, now(), p_actor_member, p_actor_account,
                                   p_capacity, p_command, null) > 0 then
      v_recorded := v_recorded + 1;
    end if;
  end loop;
  return v_recorded;
end;
$$;

-- The current assignees of an occurrence (for app.duties_lock_members).
create function app.duties_occurrence_members(p_occurrence_id uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(a.member_id order by a.member_id), '{}')
    from app.duties_slots s
    join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
   where s.occurrence_id = p_occurrence_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- The shared change engine (replaced, same signature): an assignment re-created for the same
-- person with unchanged times carries the earlier override forward; the answer lists every
-- assignment created as `created` [{assignment_id, carried}] for the caller's gate.
-- ---------------------------------------------------------------------------------------------

create or replace function app.duties_apply_change(
  p_old app.duties_occurrences,
  p_new app.duties_occurrences,
  p_target_slot uuid,
  p_member uuid,
  p_member_given boolean,
  p_deadline timestamptz,
  p_deadline_key text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_skip_unchanged boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_changed text[] := '{}';
  v_member_changed boolean := false;
  v_occ_material boolean;
  v_material boolean;
  v_notify boolean;
  v_window_changed boolean;
  v_carry boolean;
  v_class text;
  v_revision bigint;
  v_slot app.duties_slots;
  v_old app.duties_assignments;
  v_old_revision bigint;
  v_slot_revision bigint;
  v_slot_changed text[];
  v_is_target boolean;
  v_slot_material boolean;
  v_new_member uuid;
  v_current uuid;
  v_current_member uuid;
  v_current_revision bigint;
  v_current_deadline timestamptz;
  v_response text;
  v_superseded uuid;
  v_request uuid := app.cmd_current_request_id(p_actor_account, p_command);
  v_ops jsonb := '[]'::jsonb;
  v_created integer := 0;
  v_created_list jsonb := '[]'::jsonb;
  v_report jsonb;
  v_need_deadline boolean;
  v_start timestamptz := coalesce(p_new.reporting_at, p_new.starts_at);
  v_cur_target uuid;
  r record;
begin
  if p_member_given then
    select a.member_id into v_cur_target from app.duties_assignments a
     where a.slot_id = p_target_slot and a.assignment_state = 'current';
    v_member_changed := p_member is distinct from v_cur_target;
  end if;
  if p_new.duty_name is distinct from p_old.duty_name then
    v_changed := array_append(v_changed, 'duty_name');
  end if;
  if p_new.starts_at is distinct from p_old.starts_at then
    v_changed := array_append(v_changed, 'starts_at');
  end if;
  if p_new.ends_at is distinct from p_old.ends_at then
    v_changed := array_append(v_changed, 'ends_at');
  end if;
  if p_new.reporting_at is distinct from p_old.reporting_at then
    v_changed := array_append(v_changed, 'reporting_at');
  end if;
  if p_new.location is distinct from p_old.location then
    v_changed := array_append(v_changed, 'location');
  end if;
  if p_new.instructions is distinct from p_old.instructions then
    v_changed := array_append(v_changed, 'instructions');
  end if;
  if p_new.topic is distinct from p_old.topic then
    v_changed := array_append(v_changed, 'topic');
  end if;
  if p_new.scripture is distinct from p_old.scripture then
    v_changed := array_append(v_changed, 'scripture');
  end if;
  if p_new.event_ref is distinct from p_old.event_ref then
    v_changed := array_append(v_changed, 'event_ref');
  end if;
  v_window_changed := v_changed && array['starts_at', 'ends_at', 'reporting_at'];
  v_occ_material := exists (select 1 from unnest(v_changed) f
                             where app.duties_slot_field_class(f) = 'material');
  v_material := v_occ_material or v_member_changed;
  -- 4.2: an answer-by with a change that asks nobody again is refused (before "unchanged").
  if not v_material and p_deadline is not null and p_deadline_key = 'response_deadline' then
    perform app.cmd_fail('validation_failed', '{"response_deadline": "not_material"}');
  end if;
  if cardinality(v_changed) = 0 and not v_member_changed then
    if p_skip_unchanged then
      return null;
    end if;
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "unchanged"}');
  end if;
  v_notify := v_changed && array['instructions', 'topic', 'scripture'];
  -- A change of reference fields only (the linked event) is recorded as `reference`: no notice,
  -- and My duties does not report it as a details update.
  v_class := case when v_material then 'material' when v_notify then 'notes' else 'reference' end;

  -- A new pending assignment needs the leader's answer-by (entry 8 adds the 3.3 default).
  v_need_deadline := v_member_changed
    or (v_occ_material and exists (
          select 1 from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
           where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'));
  if v_need_deadline then
    if p_deadline is null then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key, 'required'));
    elsif p_deadline <= now() then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key,
        case when p_deadline_key = 'deadline_before' then 'passed' else 'past' end));
    elsif p_deadline > v_start then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key, 'after_start'));
    end if;
  end if;
  -- Who will be asked: a new assignee must serve in the department; a kept assignee who can no
  -- longer serve (erased, left, under deletion) needs reassignment first (fail closed).
  if v_member_changed and not app.duties_can_serve(p_member, p_old.department_id) then
    perform 1 from app.duties_department_members dm
     where dm.department_id = p_old.department_id and dm.member_id = p_member and dm.ended_at is null;
    if not found then
      perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
    end if;
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  if v_occ_material then
    for r in select a.member_id, s.slot_id from app.duties_slots s
               join app.duties_assignments a on a.slot_id = s.slot_id
              where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'
                and not (v_member_changed and s.slot_id = p_target_slot) loop
      perform 1 from app.duties_department_members dm
       where dm.department_id = p_old.department_id and dm.member_id = r.member_id
         and dm.ended_at is null for share;
      if not (found and app.duties_member_active(r.member_id)) then
        perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
      end if;
    end loop;
  end if;
  if v_member_changed then
    perform 1 from app.duties_department_members dm
     where dm.department_id = p_old.department_id and dm.member_id = p_member
       and dm.ended_at is null for share;
  end if;

  update app.duties_occurrences o
     set duty_name = p_new.duty_name, starts_at = p_new.starts_at, ends_at = p_new.ends_at,
         reporting_at = p_new.reporting_at, location = p_new.location,
         instructions = p_new.instructions, topic = p_new.topic, scripture = p_new.scripture,
         event_ref = p_new.event_ref, revision = o.revision + 1
   where o.occurrence_id = p_old.occurrence_id
  returning o.revision into v_revision;

  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_old.occurrence_id
                 order by s.position_no for update loop
    v_is_target := v_member_changed and v_slot.slot_id = p_target_slot;
    v_slot_changed := v_changed;
    if v_is_target then
      v_slot_changed := (select coalesce(array_agg(f order by array_position(
                            array['duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location',
                                  'member_id', 'instructions', 'topic', 'scripture', 'event_ref'], f)), '{}')
                           from unnest(array_append(v_changed, 'member_id')) f);
    end if;
    if cardinality(v_slot_changed) = 0 then
      continue;
    end if;
    v_slot_material := v_occ_material or v_is_target;
    update app.duties_slots s set revision = s.revision + 1 where s.slot_id = v_slot.slot_id
    returning s.revision into v_slot_revision;
    v_old := null;
    select a.* into v_old from app.duties_assignments a
     where a.slot_id = v_slot.slot_id and a.assignment_state = 'current' for update;
    v_current := null;
    v_current_member := null;
    v_current_revision := null;
    v_current_deadline := null;
    v_response := null;
    v_superseded := null;
    v_new_member := case when v_is_target then p_member else v_old.member_id end;
    if v_slot_material and v_old.assignment_id is not null then
      update app.duties_assignments a
         set assignment_state = 'superseded', ended_at = now(), end_reason = 'revised',
             revision = a.revision + 1
       where a.assignment_id = v_old.assignment_id
      returning a.revision into v_old_revision;
      v_superseded := v_old.assignment_id;
    end if;
    if v_slot_material and v_new_member is not null then
      -- Story 4.4: the same person at the same times, still pending or accepted, keeps the
      -- earlier override (no new check).
      -- A declined assignee asked again is a new commitment (checked like any other).
      v_carry := v_old.assignment_id is not null and v_new_member = v_old.member_id
                 and not v_window_changed and v_old.response in ('pending', 'accepted');
      insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                          assigned_by_account, slot_revision,
                                          supersedes_assignment_id, override_reason,
                                          override_overlaps, override_by_member,
                                          override_by_account, override_at)
      values (v_slot.slot_id, v_new_member, p_deadline, p_actor_member, p_actor_account,
              v_slot_revision, v_old.assignment_id,
              case when v_carry then v_old.override_reason end,
              case when v_carry then v_old.override_overlaps end,
              case when v_carry then v_old.override_by_member end,
              case when v_carry then v_old.override_by_account end,
              case when v_carry then v_old.override_at end)
      returning assignment_id, member_id, revision, response_deadline, response
           into v_current, v_current_member, v_current_revision, v_current_deadline, v_response;
      v_created := v_created + 1;
      v_created_list := v_created_list || jsonb_build_array(jsonb_build_object(
        'assignment_id', v_current, 'carried', v_carry));
    elsif not v_slot_material and v_old.assignment_id is not null then
      v_current := v_old.assignment_id;
      v_current_member := v_old.member_id;
      v_current_revision := v_old.revision;
      v_current_deadline := v_old.response_deadline;
      v_response := v_old.response;
    end if;
    insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                           occurrence_revision, change_class, changed_fields,
                                           duty_name, starts_at, ends_at, reporting_at, location,
                                           instructions, topic, scripture, event_ref, member_id,
                                           assignment_id, response_deadline, created_by_member,
                                           created_by_account, command_request_id)
    values (v_slot.slot_id, v_slot_revision, p_old.occurrence_id, v_revision,
            case when v_slot_material then 'material' else v_class end, v_slot_changed,
            p_new.duty_name, p_new.starts_at, p_new.ends_at, p_new.reporting_at, p_new.location,
            p_new.instructions, p_new.topic, p_new.scripture, p_new.event_ref, v_current_member,
            v_current, v_current_deadline, p_actor_member, p_actor_account, v_request);
    perform app.duties_audit_series_event('duty_revised', p_actor_member, p_actor_account,
                                          p_capacity, p_command, p_old.department_id,
                                          p_old.series_id, p_old.occurrence_id,
                                          coalesce(v_current, v_superseded), v_current_member,
                                          case when v_slot_material then 'material' else v_class end,
                                          v_revision);

    -- Notification work (run by the caller after every Duties row is written).
    if v_slot_material then
      if v_old.assignment_id is not null then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'cancel', 'source_id', v_old.assignment_id, 'reason', 'source_revised'));
      end if;
      if v_current is not null and app.duties_notice_recipient(v_current_member) then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_current, 'source_revision', 1,
            'recipient_member_id', v_current_member,
            'reminder_kind', case when v_current_member = v_old.member_id then 'duty_changed'
                                  else 'duty_assigned' end,
            'scheduled_at', app.cmd_utc(now()))));
      end if;
      if v_old.assignment_id is not null and v_current_member is distinct from v_old.member_id
         and v_old.member_id is distinct from v_nil
         and app.duties_notice_recipient(v_old.member_id) then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', false,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
            'source_revision', v_old_revision, 'recipient_member_id', v_old.member_id,
            'reminder_kind', 'duty_released', 'scheduled_at', app.cmd_utc(now()))));
      end if;
    elsif v_notify and v_current is not null and v_response in ('pending', 'accepted')
          and app.duties_notice_recipient(v_current_member) then
      v_ops := v_ops || jsonb_build_array(jsonb_build_object(
        'op', 'replace', 'source_id', v_current, 'source_revision', v_current_revision,
        'recipient', v_current_member));
    end if;

    if v_report is null or v_is_target then
      v_report := jsonb_build_object(
        'slot_id', v_slot.slot_id, 'slot_revision', v_slot_revision, 'assignment_id', v_current,
        'assignment_revision', v_current_revision, 'superseded_assignment_id', v_superseded,
        'response', v_response);
    end if;
  end loop;

  return coalesce(v_report, '{}'::jsonb) || jsonb_build_object(
    'revision', v_revision, 'change', v_class, 'assignments_created', v_created,
    'created', v_created_list, 'ops', v_ops);
end;
$$;

-- (Replaced, story 4.4: the planned reasons of a cancelled draft are cleared with its people.)
-- Ends one occurrence that the caller locked (draft or published, not started): the occurrence
-- and every current assignment become `cancelled`, a `cancelled` slot revision is recorded for
-- each position of a published occurrence. Returns {assignments_cancelled, ops}: the caller runs
-- ops LAST (pending jobs of every assignment of the occurrence cancelled `source_cancelled`,
-- then one `duty_cancelled` notice per pending or accepted assignee).
create or replace function app.duties_cancel_one(p_occ app.duties_occurrences, p_actor_member uuid,
                                      p_actor_account uuid, p_capacity text, p_command text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
  v_slot app.duties_slots;
  v_old app.duties_assignments;
  v_slot_revision bigint;
  v_end_revision bigint;
  v_cancels jsonb := '[]'::jsonb;
  v_notices jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_request uuid := app.cmd_current_request_id(p_actor_account, p_command);
  v_id uuid;
begin
  update app.duties_occurrences o
     set occurrence_state = 'cancelled', revision = o.revision + 1
   where o.occurrence_id = p_occ.occurrence_id
  returning o.revision into v_revision;
  if p_occ.occurrence_state <> 'published' then
    -- A cancelled draft keeps no planned people, nor their planned reasons (story 4.4).
    update app.duties_slots s
       set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
           draft_override_by_account = null, draft_override_at = null
     where s.occurrence_id = p_occ.occurrence_id
       and (s.draft_member_id is not null or s.draft_override_reason is not null);
    perform app.duties_audit_series_event('occurrence_cancelled', p_actor_member, p_actor_account,
                                          p_capacity, p_command, p_occ.department_id, p_occ.series_id,
                                          p_occ.occurrence_id, null, null, p_occ.occurrence_state,
                                          v_revision);
    return jsonb_build_object('assignments_cancelled', 0, 'ops', '[]'::jsonb);
  end if;
  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_occ.occurrence_id
                 order by s.position_no for update loop
    update app.duties_slots s set revision = s.revision + 1 where s.slot_id = v_slot.slot_id
    returning s.revision into v_slot_revision;
    v_old := null;
    select a.* into v_old from app.duties_assignments a
     where a.slot_id = v_slot.slot_id and a.assignment_state = 'current' for update;
    if v_old.assignment_id is not null then
      update app.duties_assignments a
         set assignment_state = 'cancelled', ended_at = now(), end_reason = 'cancelled',
             revision = a.revision + 1
       where a.assignment_id = v_old.assignment_id
      returning a.revision into v_end_revision;
      v_count := v_count + 1;
      if v_old.response in ('pending', 'accepted') and app.duties_notice_recipient(v_old.member_id) then
        v_notices := v_notices || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
            'source_revision', v_end_revision, 'recipient_member_id', v_old.member_id,
            'reminder_kind', 'duty_cancelled', 'scheduled_at', app.cmd_utc(now()))));
      end if;
    end if;
    insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                           occurrence_revision, change_class, changed_fields,
                                           duty_name, starts_at, ends_at, reporting_at, location,
                                           instructions, topic, scripture, event_ref, member_id,
                                           assignment_id, response_deadline, created_by_member,
                                           created_by_account, command_request_id)
    values (v_slot.slot_id, v_slot_revision, p_occ.occurrence_id, v_revision, 'cancelled', '{}',
            p_occ.duty_name, p_occ.starts_at, p_occ.ends_at, p_occ.reporting_at, p_occ.location,
            p_occ.instructions, p_occ.topic, p_occ.scripture, p_occ.event_ref, null, null, null,
            p_actor_member, p_actor_account, v_request);
    perform app.duties_audit_series_event('occurrence_cancelled', p_actor_member, p_actor_account,
                                          p_capacity, p_command, p_occ.department_id, p_occ.series_id,
                                          p_occ.occurrence_id, v_old.assignment_id, v_old.member_id,
                                          p_occ.occurrence_state, v_revision);
    -- Every pending job of the position's assignments (current, superseded) ends with it.
    for v_id in select a.assignment_id from app.duties_assignments a where a.slot_id = v_slot.slot_id loop
      v_cancels := v_cancels || jsonb_build_array(jsonb_build_object(
        'op', 'cancel', 'source_id', v_id, 'reason', 'source_cancelled'));
    end loop;
  end loop;
  return jsonb_build_object('assignments_cancelled', v_count, 'ops', v_cancels || v_notices);
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Commands: publish a one-off duty (replaced: the override gate)
-- ---------------------------------------------------------------------------------------------

-- duties.publish_duty (replaced): as in 4.2, plus override_reason? (1..280): required when the
-- assignee has an overlapping commitment, then recorded with the assignment.
create or replace function app.duties_publish_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_department_id uuid;
  v_member uuid;
  v_name text;
  v_location text;
  v_instructions text;
  v_reason text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_deadline timestamptz;
  v_capacity text;
  v_occurrence uuid;
  v_slot uuid;
  v_assignment uuid;
  v_overlaps integer;
  v_job jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['department_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'member_id', 'response_deadline',
                      'override_reason']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  select t.errors, t.value into v_errors, v_location
    from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_instructions
    from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  select t.errors, t.value into v_errors, v_starts
    from app.duties_instant(p_payload, 'starts_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_ends
    from app.duties_instant(p_payload, 'ends_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reporting
    from app.duties_instant(p_payload, 'reporting_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_payload, 'response_deadline', true, v_errors) t;
  if v_starts is not null then
    if v_starts <= now() then
      v_errors := v_errors || '{"starts_at": "past"}';
    elsif v_starts > now() + interval '2 years' then
      v_errors := v_errors || '{"starts_at": "out_of_range"}';
    end if;
    if v_ends is not null and v_ends <= v_starts then
      v_errors := v_errors || '{"ends_at": "before_start"}';
    end if;
    if v_reporting is not null and v_reporting > v_starts then
      v_errors := v_errors || '{"reporting_at": "after_start"}';
    elsif v_reporting is not null and v_reporting <= now() then
      v_errors := v_errors || '{"reporting_at": "past"}';
    end if;
    -- The deadline is the leader's (4.1 has no default) and never later than the start.
    if v_deadline is not null and v_deadline <= now() then
      v_errors := v_errors || '{"response_deadline": "past"}';
    elsif v_deadline is not null and v_deadline > coalesce(v_reporting, v_starts) then
      v_errors := v_errors || '{"response_deadline": "after_start"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  perform 1 from app.duties_departments d
   where d.department_id = v_department_id and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.duties_manage_capacity(v_actor.member_id, v_department_id);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  -- Story 4.4: the member's assignments are serialised before the overlap check.
  perform app.duties_lock_members(array[v_member]);
  perform 1 from app.duties_department_members dm
   where dm.department_id = v_department_id and dm.member_id = v_member and dm.ended_at is null
     for share;
  if not found then
    perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
  end if;
  if not app.duties_member_active(v_member) then
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, reporting_at,
                                      location, instructions, created_by_member,
                                      created_by_account)
  values (v_department_id, v_name, v_starts, v_ends, v_reporting, v_location, v_instructions,
          v_actor.member_id, v_actor.account_id)
  returning occurrence_id into v_occurrence;
  insert into app.duties_slots (occurrence_id, position_no) values (v_occurrence, 1)
  returning slot_id into v_slot;
  insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                      assigned_by_account)
  values (v_slot, v_member, v_deadline, v_actor.member_id, v_actor.account_id)
  returning assignment_id into v_assignment;
  -- Story 4.2: slot revision 1 records what was published.
  insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                         occurrence_revision, change_class, duty_name, starts_at,
                                         ends_at, reporting_at, location, instructions, member_id,
                                         assignment_id, response_deadline, created_by_member,
                                         created_by_account, command_request_id)
  values (v_slot, 1, v_occurrence, 1, 'published', v_name, v_starts, v_ends, v_reporting,
          v_location, v_instructions, v_member, v_assignment, v_deadline, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(p_actor, 'duties.publish_duty'));
  perform app.duties_audit_event('duty_published', v_actor.member_id, v_actor.account_id,
                                 v_capacity, 'duties.publish_duty', v_department_id, v_occurrence,
                                 v_assignment, v_member, null, 1);
  -- Story 4.4: an overlap needs the reason (everything above rolls back without one).
  v_overlaps := app.duties_overlap_gate(v_assignment, v_reason, v_actor.member_id,
                                        v_actor.account_id, now(), v_actor.member_id,
                                        v_actor.account_id, v_capacity, 'duties.publish_duty', null);
  -- Notifications last (AD-2). Q2 closed in production -> unavailable, and everything rolls back.
  v_job := app.notifications_enqueue(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
    'recipient_member_id', v_member, 'reminder_kind', 'duty_assigned',
    'scheduled_at', app.cmd_utc(now())));
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', 1,
    -- Ids, states and counts only (no names or text in the receipt); clients read the board again.
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence, 'department_id', v_department_id, 'revision', 1,
              'slot_id', v_slot, 'assignment_id', v_assignment, 'assignment_revision', 1,
              'response', 'pending',
              'notice_queued', coalesce((v_job ->> 'created')::boolean, false),
              'override_recorded', v_overlaps > 0));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: positions and publishing (replaced: the override gate)
-- ---------------------------------------------------------------------------------------------

-- duties.assign_slot (replaced) {slot_id, member_id, response_deadline?, override_reason?}.
-- A draft position: the planned person; an overlap with the person's commitments or other
-- planned positions of the department needs override_reason, kept on the slot (the same person
-- with a new reason updates it). A published position: as in 4.3, gated like publish_duty.
create or replace function app.duties_assign_slot(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_slot_id uuid;
  v_member uuid;
  v_deadline timestamptz;
  v_reason text;
  v_occurrence uuid;
  v_lock record;
  v_occ app.duties_occurrences;
  v_slot app.duties_slots;
  v_revision bigint;
  v_change jsonb;
  v_notified jsonb;
  v_overlaps integer := 0;
  v_recorded integer;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['slot_id', 'member_id', 'response_deadline', 'override_reason']);
  select t.errors, t.value into v_errors, v_slot_id from app.duties_uuid(p_payload, 'slot_id', v_errors) t;
  if not p_payload ? 'member_id' then
    v_errors := v_errors || '{"member_id": "required"}';
  elsif jsonb_typeof(p_payload -> 'member_id') <> 'null' then
    select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_payload, 'response_deadline', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.occurrence_id into v_occurrence from app.duties_slots s where s.slot_id = v_slot_id;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  select l.* into v_lock from app.duties_lock_occurrence(v_actor.member_id, v_occurrence, p_expected_revision) l;
  v_occ := v_lock.occ;
  perform app.duties_lock_members(array[v_member]);
  if v_occ.occurrence_state = 'draft' then
    if p_payload ? 'response_deadline' and v_deadline is not null then
      perform app.cmd_fail('validation_failed', '{"response_deadline": "draft"}');
    end if;
    if v_member is not null and not app.duties_can_serve(v_member, v_occ.department_id) then
      perform 1 from app.duties_department_members dm
       where dm.department_id = v_occ.department_id and dm.member_id = v_member and dm.ended_at is null;
      if not found then
        perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
      end if;
      perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
    end if;
    if v_member is not null then
      perform 1 from app.duties_department_members dm
       where dm.department_id = v_occ.department_id and dm.member_id = v_member
         and dm.ended_at is null for share;
      v_overlaps := app.duties_overlap_count(v_member, app.duties_busy_range(v_occ), v_slot_id,
                                             v_occ.department_id);
    end if;
    select s.* into v_slot from app.duties_slots s where s.slot_id = v_slot_id for update;
    if v_overlaps > 0 and v_reason is null then
      -- The same person planned with a recorded reason is unchanged; otherwise the reason is
      -- required.
      if v_slot.draft_member_id is not distinct from v_member and v_slot.draft_override_reason is not null then
        perform app.cmd_fail('validation_failed', '{"slot_id": "unchanged"}');
      end if;
      perform app.cmd_fail('validation_failed', '{"member_id": "overlap", "override_reason": "required"}');
    end if;
    if v_slot.draft_member_id is not distinct from v_member
       and (v_overlaps = 0 or v_slot.draft_override_reason is not distinct from v_reason) then
      perform app.cmd_fail('validation_failed', '{"slot_id": "unchanged"}');
    end if;
    update app.duties_slots s
       set draft_member_id = v_member,
           draft_override_reason = case when v_overlaps > 0 then v_reason end,
           draft_override_by_member = case when v_overlaps > 0 then v_actor.member_id end,
           draft_override_by_account = case when v_overlaps > 0 then v_actor.account_id end,
           draft_override_at = case when v_overlaps > 0 then now() end
     where s.slot_id = v_slot_id;
    update app.duties_occurrences o set revision = o.revision + 1
     where o.occurrence_id = v_occ.occurrence_id returning o.revision into v_revision;
    perform app.duties_audit_series_event('draft_assigned', v_actor.member_id, v_actor.account_id,
                                          v_lock.capacity, 'duties.assign_slot', v_occ.department_id,
                                          v_occ.series_id, v_occ.occurrence_id, null, v_member,
                                          case when v_overlaps > 0 then 'overlap' end, v_revision);
    return jsonb_build_object(
      'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occ.occurrence_id,
      'revision', v_revision,
      'data', jsonb_build_object('occurrence_id', v_occ.occurrence_id, 'revision', v_revision,
                                 'slot_id', v_slot_id, 'state', 'draft',
                                 'draft_assigned', v_member is not null,
                                 'override_recorded', v_overlaps > 0));
  end if;
  if v_member is null then
    perform app.cmd_fail('validation_failed', '{"member_id": "required"}');
  end if;
  v_change := app.duties_apply_change(v_occ, v_occ, v_slot_id, v_member, true, v_deadline,
                                      'response_deadline', v_actor.member_id, v_actor.account_id,
                                      v_lock.capacity, 'duties.assign_slot', false);
  v_recorded := app.duties_gate_created(v_change -> 'created', v_reason, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity, 'duties.assign_slot');
  v_notified := app.duties_notify(v_change -> 'ops');
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occ.occurrence_id,
    'revision', (v_change ->> 'revision')::bigint,
    'data', jsonb_build_object(
              'occurrence_id', v_occ.occurrence_id, 'revision', (v_change ->> 'revision')::bigint,
              'slot_id', v_slot_id, 'state', 'published', 'slot_revision', v_change -> 'slot_revision',
              'assignment_id', v_change -> 'assignment_id',
              'assignment_revision', v_change -> 'assignment_revision',
              'superseded_assignment_id', v_change -> 'superseded_assignment_id',
              'response', v_change -> 'response',
              'notice_queued', (v_notified ->> 'queued')::integer > 0,
              'override_recorded', v_recorded > 0));
end;
$$;

-- duties.publish_drafts (replaced): as in 4.3; each planned person who overlaps another
-- commitment (including another position published in the same request) needs the reason
-- planned on the slot, which is recorded with the assignment (attributed to whoever planned
-- it); without one the publish is refused naming the date
-- ({"member_id": "overlap", "override_reason": "required", "occurrence:<id>": "overlap"}).
create or replace function app.duties_publish_drafts(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_series_id uuid;
  v_lead text;
  v_lock record;
  v_series app.duties_series;
  v_occ app.duties_occurrences;
  v_slot app.duties_slots;
  v_count integer;
  v_deadline timestamptz;
  v_assignment uuid;
  v_revision bigint;
  v_ops jsonb := '[]'::jsonb;
  v_gates jsonb := '[]'::jsonb;
  v_occurrences integer := 0;
  v_assignments integer := 0;
  v_overrides integer := 0;
  v_notified jsonb;
  v_request uuid;
  v_unavailable uuid;
  x jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['series_id', 'slot_count', 'deadline_before']);
  select t.errors, t.value into v_errors, v_series_id from app.duties_uuid(p_payload, 'series_id', v_errors) t;
  if not app.contract_integer_in(p_payload -> 'slot_count', 1, 600) then
    v_errors := v_errors || jsonb_build_object('slot_count',
                  case when p_payload ? 'slot_count' then 'invalid' else 'required' end);
  end if;
  select t.errors, t.value into v_errors, v_lead
    from app.duties_lead(p_payload, 'deadline_before', true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_series(v_actor.member_id, v_series_id, p_expected_revision) l;
  v_series := v_lock.series;
  -- Lock the drafts (series date order), then count their positions.
  perform 1 from app.duties_occurrences o
   where o.series_id = v_series_id and o.occurrence_state = 'draft'
   order by o.series_date for update;
  select count(*)::integer into v_count
    from app.duties_occurrences o join app.duties_slots s on s.occurrence_id = o.occurrence_id
   where o.series_id = v_series_id and o.occurrence_state = 'draft'
     and app.duties_occurrence_start(o) > now();
  if v_count = 0 then
    perform app.cmd_fail('validation_failed', '{"series_id": "no_drafts"}');
  end if;
  if v_count <> (p_payload ->> 'slot_count')::integer then
    perform app.cmd_fail('conflict', '{"slot_count": "changed"}', v_series.revision);
  end if;
  -- The planned people are locked (story 4.4: member advisory locks, then memberships FOR
  -- SHARE), then everything is checked before anything is written.
  perform app.duties_lock_members(array(
    select s.draft_member_id from app.duties_occurrences o
      join app.duties_slots s on s.occurrence_id = o.occurrence_id
     where o.series_id = v_series_id and o.occurrence_state = 'draft'
       and s.draft_member_id is not null));
  perform 1 from app.duties_department_members dm
   where dm.department_id = v_series.department_id and dm.ended_at is null
     and dm.member_id in (select s.draft_member_id from app.duties_occurrences o
                            join app.duties_slots s on s.occurrence_id = o.occurrence_id
                           where o.series_id = v_series_id and o.occurrence_state = 'draft')
   order by dm.member_id for share;
  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.occurrence_state = 'draft'
                  and app.duties_occurrence_start(o) > now()
                order by o.series_date loop
    if app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone) <= now() then
      perform app.cmd_fail('validation_failed', jsonb_build_object(
        'deadline_before', 'passed', 'occurrence:' || v_occ.occurrence_id, 'passed'));
    end if;
    select s.draft_member_id into v_unavailable from app.duties_slots s
     where s.occurrence_id = v_occ.occurrence_id and s.draft_member_id is not null
       and not app.duties_can_serve(s.draft_member_id, v_series.department_id)
     order by s.position_no limit 1;
    if v_unavailable is not null then
      perform app.cmd_fail('validation_failed', jsonb_build_object(
        'member_id', 'unavailable', 'occurrence:' || v_occ.occurrence_id, 'unavailable'));
    end if;
  end loop;

  v_request := app.cmd_current_request_id(v_actor.account_id, 'duties.publish_drafts');
  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.occurrence_state = 'draft'
                  and app.duties_occurrence_start(o) > now()
                order by o.series_date loop
    v_deadline := app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone);
    update app.duties_occurrences o
       set occurrence_state = 'published', published_at = now(), revision = o.revision + 1
     where o.occurrence_id = v_occ.occurrence_id
    returning o.revision into v_revision;
    v_occurrences := v_occurrences + 1;
    for v_slot in select s.* from app.duties_slots s where s.occurrence_id = v_occ.occurrence_id
                   order by s.position_no for update loop
      v_assignment := null;
      if v_slot.draft_member_id is not null then
        insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                            assigned_by_account)
        values (v_slot.slot_id, v_slot.draft_member_id, v_deadline, v_actor.member_id,
                v_actor.account_id)
        returning assignment_id into v_assignment;
        v_assignments := v_assignments + 1;
        v_gates := v_gates || jsonb_build_array(jsonb_build_object(
          'assignment_id', v_assignment, 'occurrence_id', v_occ.occurrence_id,
          'reason', v_slot.draft_override_reason, 'by_member', v_slot.draft_override_by_member,
          'by_account', v_slot.draft_override_by_account, 'at', v_slot.draft_override_at));
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
            'recipient_member_id', v_slot.draft_member_id, 'reminder_kind', 'duty_assigned',
            'scheduled_at', app.cmd_utc(now()))));
      end if;
      update app.duties_slots s
         set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
             draft_override_by_account = null, draft_override_at = null
       where s.slot_id = v_slot.slot_id;
      insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                             occurrence_revision, change_class, duty_name,
                                             starts_at, ends_at, reporting_at, location,
                                             instructions, topic, scripture, event_ref, member_id,
                                             assignment_id, response_deadline, created_by_member,
                                             created_by_account, command_request_id)
      values (v_slot.slot_id, 1, v_occ.occurrence_id, v_revision, 'published', v_occ.duty_name,
              v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at, v_occ.location,
              v_occ.instructions, v_occ.topic, v_occ.scripture, v_occ.event_ref,
              v_slot.draft_member_id, v_assignment,
              case when v_assignment is not null then v_deadline end, v_actor.member_id,
              v_actor.account_id, v_request);
      perform app.duties_audit_series_event('duty_published', v_actor.member_id, v_actor.account_id,
                                            v_lock.capacity, 'duties.publish_drafts',
                                            v_series.department_id, v_series_id, v_occ.occurrence_id,
                                            v_assignment, v_slot.draft_member_id,
                                            case when v_assignment is null then 'unfilled' end,
                                            v_revision);
    end loop;
  end loop;
  -- Story 4.4: every new assignment is gated once all of them exist (two positions of one
  -- person in this publish overlap each other), with the reason planned on its slot.
  for x in select e from jsonb_array_elements(v_gates) e loop
    if app.duties_overlap_gate((x ->> 'assignment_id')::uuid, x ->> 'reason',
                               (x ->> 'by_member')::uuid, (x ->> 'by_account')::uuid,
                               (x ->> 'at')::timestamptz, v_actor.member_id, v_actor.account_id,
                               v_lock.capacity, 'duties.publish_drafts',
                               jsonb_build_object('occurrence:' || (x ->> 'occurrence_id'), 'overlap')) > 0 then
      v_overrides := v_overrides + 1;
    end if;
  end loop;
  update app.duties_series r set revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id returning r.revision into v_revision;
  -- Notifications last (AD-2). Q2 closed in production -> unavailable, and everything rolls back.
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'occurrences', v_occurrences, 'slots', v_count,
                               'assignments', v_assignments,
                               'notices_queued', (v_notified ->> 'queued')::integer,
                               'overrides', v_overrides));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: this occurrence and this and future (replaced: the override gate)
-- ---------------------------------------------------------------------------------------------

-- duties.revise_duty (replaced): as in 4.3, plus override_reason?: a change that gives the
-- position to someone new or moves the times of an assignee into an overlap needs it. A draft
-- is edited in place without a check (Publish N checks).
create or replace function app.duties_revise_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_occurrence_id uuid;
  v_lock record;
  v_occ app.duties_occurrences;
  v_new app.duties_occurrences;
  v_name text;
  v_location text;
  v_instructions text;
  v_topic text;
  v_scripture text;
  v_reason text;
  v_event uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_deadline timestamptz;
  v_member uuid;
  v_slots integer;
  v_slot uuid;
  v_change jsonb;
  v_notified jsonb;
  v_revision bigint;
  v_recorded integer;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['occurrence_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'topic', 'scripture', 'event_ref', 'member_id',
                      'response_deadline', 'override_reason']);
  select t.errors, t.value into v_errors, v_occurrence_id
    from app.duties_uuid(p_payload, 'occurrence_id', v_errors) t;
  if p_payload ? 'duty_name' then
    select t.errors, t.value into v_errors, v_name
      from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  end if;
  if p_payload ? 'location' then
    select t.errors, t.value into v_errors, v_location
      from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  end if;
  if p_payload ? 'instructions' then
    select t.errors, t.value into v_errors, v_instructions
      from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  end if;
  if p_payload ? 'topic' then
    select t.errors, t.value into v_errors, v_topic
      from app.duties_text(p_payload, 'topic', false, 120, false, v_errors) t;
  end if;
  if p_payload ? 'scripture' then
    select t.errors, t.value into v_errors, v_scripture
      from app.duties_text(p_payload, 'scripture', false, 120, false, v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'event_ref'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_event from app.duties_uuid(p_payload, 'event_ref', v_errors) t;
  end if;
  if p_payload ? 'starts_at' then
    select t.errors, t.value into v_errors, v_starts
      from app.duties_instant(p_payload, 'starts_at', true, v_errors) t;
  end if;
  if p_payload ? 'ends_at' then
    select t.errors, t.value into v_errors, v_ends
      from app.duties_instant(p_payload, 'ends_at', false, v_errors) t;
  end if;
  if p_payload ? 'reporting_at' then
    select t.errors, t.value into v_errors, v_reporting
      from app.duties_instant(p_payload, 'reporting_at', false, v_errors) t;
  end if;
  if p_payload ? 'response_deadline' then
    select t.errors, t.value into v_errors, v_deadline
      from app.duties_instant(p_payload, 'response_deadline', true, v_errors) t;
  end if;
  if p_payload ? 'member_id' then
    select t.errors, t.value into v_errors, v_member
      from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_occurrence(v_actor.member_id, v_occurrence_id, p_expected_revision) l;
  v_occ := v_lock.occ;
  select count(*)::integer, min(s.slot_id::text)::uuid into v_slots, v_slot
    from app.duties_slots s where s.occurrence_id = v_occurrence_id;
  if p_payload ? 'member_id' and (v_slots <> 1 or v_occ.occurrence_state <> 'published') then
    -- One assignee per occurrence only for a one-position published duty (duties.assign_slot
    -- gives a position of a rota to someone).
    perform app.cmd_fail('validation_failed', '{"member_id": "unsupported"}');
  end if;
  v_new := v_occ;
  v_new.duty_name := case when p_payload ? 'duty_name' then v_name else v_occ.duty_name end;
  v_new.starts_at := case when p_payload ? 'starts_at' then v_starts else v_occ.starts_at end;
  v_new.ends_at := case when p_payload ? 'ends_at' then v_ends else v_occ.ends_at end;
  v_new.reporting_at := case when p_payload ? 'reporting_at' then v_reporting else v_occ.reporting_at end;
  v_new.location := case when p_payload ? 'location' then v_location else v_occ.location end;
  v_new.instructions := case when p_payload ? 'instructions' then v_instructions else v_occ.instructions end;
  v_new.topic := case when p_payload ? 'topic' then v_topic else v_occ.topic end;
  v_new.scripture := case when p_payload ? 'scripture' then v_scripture else v_occ.scripture end;
  v_new.event_ref := case when p_payload ? 'event_ref' then v_event else v_occ.event_ref end;
  if (v_new.starts_at, v_new.ends_at, v_new.reporting_at)
     is distinct from (v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at) then
    v_errors := app.duties_times_errors(v_new.starts_at, v_new.ends_at, v_new.reporting_at,
                                        array['starts_at', 'ends_at', 'reporting_at']);
    -- As in 4.2: a time change of a published duty is material, so its answer-by is reported
    -- with the time errors.
    if v_errors <> '{}'::jsonb and v_occ.occurrence_state = 'published' then
      if not p_payload ? 'response_deadline' then
        v_errors := v_errors || '{"response_deadline": "required"}';
      elsif v_deadline <= now() then
        v_errors := v_errors || '{"response_deadline": "past"}';
      elsif v_deadline > coalesce(v_new.reporting_at, v_new.starts_at) then
        v_errors := v_errors || '{"response_deadline": "after_start"}';
      end if;
    end if;
    if v_errors <> '{}'::jsonb then
      perform app.cmd_fail('validation_failed', v_errors);
    end if;
  end if;

  if v_occ.occurrence_state = 'draft' then
    if p_payload ? 'response_deadline' then
      perform app.cmd_fail('validation_failed', '{"response_deadline": "draft"}');
    end if;
    if (v_new.duty_name, v_new.starts_at, v_new.ends_at, v_new.reporting_at, v_new.location,
        v_new.instructions, v_new.topic, v_new.scripture, v_new.event_ref)
       is not distinct from
       (v_occ.duty_name, v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at, v_occ.location,
        v_occ.instructions, v_occ.topic, v_occ.scripture, v_occ.event_ref) then
      perform app.cmd_fail('validation_failed', '{"occurrence_id": "unchanged"}');
    end if;
    update app.duties_occurrences o
       set duty_name = v_new.duty_name, starts_at = v_new.starts_at, ends_at = v_new.ends_at,
           reporting_at = v_new.reporting_at, location = v_new.location,
           instructions = v_new.instructions, topic = v_new.topic, scripture = v_new.scripture,
           event_ref = v_new.event_ref, revision = o.revision + 1
     where o.occurrence_id = v_occurrence_id
    returning o.revision into v_revision;
    perform app.duties_audit_series_event('draft_revised', v_actor.member_id, v_actor.account_id,
                                          v_lock.capacity, 'duties.revise_duty', v_occ.department_id,
                                          v_occ.series_id, v_occurrence_id, null, null, null, v_revision);
    return jsonb_build_object(
      'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence_id, 'revision', v_revision,
      'data', jsonb_build_object('occurrence_id', v_occurrence_id, 'revision', v_revision,
                                 'change', 'draft'));
  end if;

  -- Story 4.4: everyone this change may ask (current assignees and a new one) is serialised.
  perform app.duties_lock_members(app.duties_occurrence_members(v_occurrence_id) || v_member);
  v_change := app.duties_apply_change(v_occ, v_new, v_slot, v_member, p_payload ? 'member_id',
                                      v_deadline, 'response_deadline', v_actor.member_id,
                                      v_actor.account_id, v_lock.capacity, 'duties.revise_duty', false);
  v_recorded := app.duties_gate_created(v_change -> 'created', v_reason, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity, 'duties.revise_duty');
  v_notified := app.duties_notify(v_change -> 'ops');
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence_id,
    'revision', (v_change ->> 'revision')::bigint,
    -- Ids, revisions, states and counts only (no names or text in the receipt).
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence_id, 'revision', (v_change ->> 'revision')::bigint,
              'change', v_change ->> 'change', 'slot_id', v_change -> 'slot_id',
              'slot_revision', v_change -> 'slot_revision', 'assignment_id', v_change -> 'assignment_id',
              'assignment_revision', v_change -> 'assignment_revision',
              'superseded_assignment_id', v_change -> 'superseded_assignment_id',
              'response', v_change -> 'response',
              'notice_queued', (v_notified ->> 'queued')::integer > 0,
              'overrides', v_recorded));
end;
$$;

-- duties.revise_series (replaced): as in 4.3, plus override_reason?: new times that move an
-- assignee into an overlap need it (one reason for the whole change); the refusal names the
-- first date that needs it.
create or replace function app.duties_revise_series(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_series_id uuid;
  v_anchor_id uuid;
  v_lock record;
  v_series app.duties_series;
  v_anchor app.duties_occurrences;
  v_occ app.duties_occurrences;
  v_new app.duties_occurrences;
  v_name text;
  v_location text;
  v_instructions text;
  v_topic text;
  v_scripture text;
  v_reason text;
  v_event uuid;
  v_start time;
  v_end time;
  v_reporting time;
  v_lead text;
  v_date date;
  v_start_t time;
  v_deadline timestamptz;
  v_change jsonb;
  v_ops jsonb := '[]'::jsonb;
  v_notified jsonb;
  v_changed integer := 0;
  v_drafts integer := 0;
  v_material integer := 0;
  v_created integer := 0;
  v_overrides integer := 0;
  v_revision bigint;
  v_capacity text;
  v_fail_code text;
  v_fail_detail text;
  v_fail_errors jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['series_id', 'from_occurrence_id', 'duty_name', 'start_time', 'end_time',
                      'reporting_time', 'location', 'instructions', 'topic', 'scripture',
                      'event_ref', 'deadline_before', 'override_reason']);
  select t.errors, t.value into v_errors, v_series_id from app.duties_uuid(p_payload, 'series_id', v_errors) t;
  select t.errors, t.value into v_errors, v_anchor_id
    from app.duties_uuid(p_payload, 'from_occurrence_id', v_errors) t;
  if p_payload ? 'duty_name' then
    select t.errors, t.value into v_errors, v_name
      from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  end if;
  if p_payload ? 'location' then
    select t.errors, t.value into v_errors, v_location
      from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  end if;
  if p_payload ? 'instructions' then
    select t.errors, t.value into v_errors, v_instructions
      from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  end if;
  if p_payload ? 'topic' then
    select t.errors, t.value into v_errors, v_topic
      from app.duties_text(p_payload, 'topic', false, 120, false, v_errors) t;
  end if;
  if p_payload ? 'scripture' then
    select t.errors, t.value into v_errors, v_scripture
      from app.duties_text(p_payload, 'scripture', false, 120, false, v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'event_ref'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_event from app.duties_uuid(p_payload, 'event_ref', v_errors) t;
  end if;
  if p_payload ? 'start_time' then
    select t.errors, t.value into v_errors, v_start
      from app.duties_local_time(p_payload, 'start_time', true, v_errors) t;
  end if;
  if p_payload ? 'end_time' then
    select t.errors, t.value into v_errors, v_end
      from app.duties_local_time(p_payload, 'end_time', false, v_errors) t;
  end if;
  if p_payload ? 'reporting_time' then
    select t.errors, t.value into v_errors, v_reporting
      from app.duties_local_time(p_payload, 'reporting_time', false, v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_lead
    from app.duties_lead(p_payload, 'deadline_before', false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_series(v_actor.member_id, v_series_id, p_expected_revision) l;
  v_series := v_lock.series;
  v_capacity := v_lock.capacity;
  select o.* into v_anchor from app.duties_occurrences o
   where o.occurrence_id = v_anchor_id and o.series_id = v_series_id;
  if not found then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "not_in_series"}');
  elsif v_anchor.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "cancelled"}');
  elsif app.duties_occurrence_start(v_anchor) <= now() then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "started"}');
  end if;
  -- The series keeps a reporting time no later than its start time.
  if coalesce(case when p_payload ? 'reporting_time' then v_reporting else v_series.reporting_time end,
              '00:00'::time)
     > coalesce(case when p_payload ? 'start_time' then v_start else v_series.start_time end, '23:59'::time) then
    perform app.cmd_fail('validation_failed', '{"reporting_time": "after_start"}');
  end if;
  -- Lock every target occurrence up front, in series date order (AD-2 lock order).
  perform 1 from app.duties_occurrences o
   where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
     and o.occurrence_state <> 'cancelled'
   order by o.series_date for update;
  -- Story 4.4: then everyone those dates may ask again (member advisory locks, id order).
  perform app.duties_lock_members(array(
    select a.member_id from app.duties_occurrences o
      join app.duties_slots s on s.occurrence_id = o.occurrence_id
      join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
     where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
       and o.occurrence_state = 'published'));

  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
                  and o.occurrence_state <> 'cancelled' and app.duties_occurrence_start(o) > now()
                order by o.series_date loop
    -- The occurrence's own church-local date (an occurrence moved on its own keeps its date).
    v_date := (v_occ.starts_at at time zone v_series.zone)::date;
    v_new := v_occ;
    if p_payload ? 'duty_name' then v_new.duty_name := v_name; end if;
    if p_payload ? 'location' then v_new.location := v_location; end if;
    if p_payload ? 'instructions' then v_new.instructions := v_instructions; end if;
    if p_payload ? 'topic' then v_new.topic := v_topic; end if;
    if p_payload ? 'scripture' then v_new.scripture := v_scripture; end if;
    if p_payload ? 'event_ref' then v_new.event_ref := v_event; end if;
    if p_payload ? 'start_time' then
      v_new.starts_at := app.duties_wall(v_date, v_start, v_series.zone);
    end if;
    v_start_t := (v_new.starts_at at time zone v_series.zone)::time;
    if p_payload ? 'reporting_time' then
      v_new.reporting_at := case when v_reporting is not null
                                 then app.duties_wall(v_date, v_reporting, v_series.zone) end;
    end if;
    if p_payload ? 'end_time' then
      v_new.ends_at := case when v_end is not null
                            then app.duties_wall(v_date + case when v_end <= v_start_t then 1 else 0 end,
                                                 v_end, v_series.zone) end;
    end if;
    if (v_new.starts_at, v_new.ends_at, v_new.reporting_at)
       is distinct from (v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at) then
      v_errors := app.duties_times_errors(v_new.starts_at, v_new.ends_at, v_new.reporting_at,
                                          array['start_time', 'end_time', 'reporting_time']);
      if v_errors <> '{}'::jsonb then
        -- The date that cannot take the change is named (ids only).
        perform app.cmd_fail('validation_failed', v_errors || jsonb_build_object(
          'occurrence:' || v_occ.occurrence_id, (select e.value #>> '{}' from jsonb_each(v_errors) e limit 1)));
      end if;
    end if;
    if v_occ.occurrence_state = 'draft' then
      if (v_new.duty_name, v_new.starts_at, v_new.ends_at, v_new.reporting_at, v_new.location,
          v_new.instructions, v_new.topic, v_new.scripture, v_new.event_ref)
         is distinct from
         (v_occ.duty_name, v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at, v_occ.location,
          v_occ.instructions, v_occ.topic, v_occ.scripture, v_occ.event_ref) then
        update app.duties_occurrences o
           set duty_name = v_new.duty_name, starts_at = v_new.starts_at, ends_at = v_new.ends_at,
               reporting_at = v_new.reporting_at, location = v_new.location,
               instructions = v_new.instructions, topic = v_new.topic,
               scripture = v_new.scripture, event_ref = v_new.event_ref, revision = o.revision + 1
         where o.occurrence_id = v_occ.occurrence_id;
        v_changed := v_changed + 1;
        v_drafts := v_drafts + 1;
      end if;
      continue;
    end if;
    v_deadline := case when v_lead is not null
                       then app.notifications_shift(coalesce(v_new.reporting_at, v_new.starts_at),
                                                    v_lead, -1, v_series.zone) end;
    begin
      v_change := app.duties_apply_change(v_occ, v_new, null, null, false, v_deadline,
                                          'deadline_before', v_actor.member_id, v_actor.account_id,
                                          v_capacity, 'duties.revise_series', true);
      if v_change is not null then
        v_overrides := v_overrides + app.duties_gate_created(
          v_change -> 'created', v_reason, v_actor.member_id, v_actor.account_id, v_capacity,
          'duties.revise_series');
      end if;
    exception when sqlstate 'PCMD1' then
      -- A refusal for one date (an assignee who can no longer serve, an answer-by that has
      -- passed, an overlap without a reason) names that date (ids only) so the leader can fix it.
      get stacked diagnostics v_fail_code = message_text, v_fail_detail = pg_exception_detail;
      v_fail_errors := coalesce(v_fail_detail::jsonb -> 'field_errors', '{}'::jsonb);
      if v_fail_code = 'validation_failed' and v_fail_errors <> '{}'::jsonb then
        perform app.cmd_fail('validation_failed', v_fail_errors || jsonb_build_object(
          'occurrence:' || v_occ.occurrence_id,
          (select e.value #>> '{}' from jsonb_each(v_fail_errors) e limit 1)));
      end if;
      raise;
    end;
    if v_change is not null then
      v_changed := v_changed + 1;
      if v_change ->> 'change' = 'material' then
        v_material := v_material + 1;
      end if;
      v_created := v_created + (v_change ->> 'assignments_created')::integer;
      v_ops := v_ops || (v_change -> 'ops');
    end if;
  end loop;
  if v_changed = 0 then
    perform app.cmd_fail('validation_failed', '{"series_id": "unchanged"}');
  end if;
  update app.duties_series r
     set duty_name = case when p_payload ? 'duty_name' then v_name else r.duty_name end,
         start_time = case when p_payload ? 'start_time' then v_start else r.start_time end,
         end_time = case when p_payload ? 'end_time' then v_end else r.end_time end,
         reporting_time = case when p_payload ? 'reporting_time' then v_reporting else r.reporting_time end,
         location = case when p_payload ? 'location' then v_location else r.location end,
         instructions = case when p_payload ? 'instructions' then v_instructions else r.instructions end,
         topic = case when p_payload ? 'topic' then v_topic else r.topic end,
         scripture = case when p_payload ? 'scripture' then v_scripture else r.scripture end,
         event_ref = case when p_payload ? 'event_ref' then v_event else r.event_ref end,
         revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id
  returning r.revision into v_revision;
  perform app.duties_audit_series_event('series_revised', v_actor.member_id, v_actor.account_id,
                                        v_capacity, 'duties.revise_series', v_series.department_id,
                                        v_series_id, v_anchor_id, null, null, null, v_revision);
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'from_occurrence_id', v_anchor_id, 'occurrences', v_changed,
                               'drafts', v_drafts, 'material', v_material,
                               'assignments', v_created,
                               'notices_queued', (v_notified ->> 'queued')::integer,
                               'overrides', v_overrides));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Projections (replaced: overlap counts and recorded overrides for the department's readers)
-- ---------------------------------------------------------------------------------------------

-- The recorded override of an assignment (null when none). The reason is hidden when the
-- assignee is the viewer (app.duties_viewer, set by the board and rota reads): a leader never
-- reads what another leader wrote about them.
create function app.duties_override_json(p_assignment app.duties_assignments)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_assignment.override_at is not null then jsonb_build_object(
    'reason', case when p_assignment.member_id::text
                        is distinct from pg_catalog.current_setting('app.duties_viewer', true)
                   then p_assignment.override_reason end,
    'overlaps', p_assignment.override_overlaps,
    'at', app.cmd_utc(p_assignment.override_at),
    'by', app.duties_display_name(p_assignment.override_by_member)) end;
$$;

-- How many other commitments (and planned positions of the same department) overlap each
-- position of the given occurrences, computed once, set-based (the per-position conflict
-- query was too slow for a full rota): {slot_id: count} for positions with a count above 0.
-- Cancelled and past occurrences count nothing. Same rules as app.duties_busy_items.
create function app.duties_overlap_counts(p_occurrences uuid[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  with pos as (
    select s.slot_id, o.department_id,
           case when o.occurrence_state = 'draft' then s.draft_member_id else a.member_id end as member_id,
           tstzrange(coalesce(o.reporting_at, o.starts_at),
                     coalesce(o.ends_at, o.starts_at + interval '2 hours'), '[)') as busy
      from app.duties_occurrences o
      join app.duties_slots s on s.occurrence_id = o.occurrence_id
      left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
     where o.occurrence_id = any (p_occurrences) and o.occurrence_state <> 'cancelled'
       and coalesce(o.ends_at, o.starts_at + interval '2 hours') > now()
  ), people as (
    select distinct p.member_id from pos p
     where p.member_id is not null
       and p.member_id <> '00000000-0000-0000-0000-000000000000'::uuid
  ), items as (
    select a.member_id, s.slot_id, null::uuid as department_id,
           tstzrange(coalesce(o.reporting_at, o.starts_at),
                     coalesce(o.ends_at, o.starts_at + interval '2 hours'), '[)') as busy
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.member_id in (select member_id from people) and a.assignment_state = 'current'
       and a.response in ('pending', 'accepted') and o.occurrence_state = 'published'
    union all
    select s.draft_member_id, s.slot_id, o.department_id,
           tstzrange(coalesce(o.reporting_at, o.starts_at),
                     coalesce(o.ends_at, o.starts_at + interval '2 hours'), '[)')
      from app.duties_slots s
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where s.draft_member_id in (select member_id from people) and o.occurrence_state = 'draft'
  )
  select coalesce(jsonb_object_agg(x.slot_id, x.n), '{}'::jsonb)
    from (select p.slot_id, count(*) as n
            from pos p
            join items i on i.member_id = p.member_id and i.slot_id <> p.slot_id and i.busy && p.busy
                        and (i.department_id is null or i.department_id = p.department_id)
           group by p.slot_id) x;
$$;

create function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean, p_counts jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'department_id', o.department_id,
    'series_id', o.series_id,
    'duty_name', o.duty_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'event_ref', o.event_ref,
    'state', o.occurrence_state,
    'revision', o.revision,
    'published_at', app.cmd_utc(o.published_at),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'responded_at', case when a.responded_at is not null
                                               then app.cmd_utc(a.responded_at) end,
                          'note', case when p_with_notes then a.response_note end,
                          'revision', a.revision,
                          'slot_revision', a.slot_revision,
                          'changes', case when a.supersedes_assignment_id is not null
                                          then to_jsonb(app.duties_changes_since(
                                                 s.slot_id, a.slot_revision - 1, a.slot_revision)) end,
                          'notes_updated_at', (select app.cmd_utc(t.ts) from (
                                                 select app.duties_notes_updated_at(s.slot_id, a.slot_revision) as ts) t
                                                where t.ts is not null),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override', app.duties_override_json(a))
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'),
               'history', coalesce((
                 select jsonb_agg(h.obj order by h.ended_at desc, h.assignment_id)
                   from (select a.assignment_id, a.ended_at, jsonb_build_object(
                                  'assignment_id', a.assignment_id,
                                  'member_id', a.member_id,
                                  'display_name', app.duties_display_name(a.member_id),
                                  'state', a.assignment_state,
                                  'end_reason', a.end_reason,
                                  'ended_at', app.cmd_utc(a.ended_at),
                                  'response', a.response,
                                  'responded_at', case when a.responded_at is not null
                                                       then app.cmd_utc(a.responded_at) end,
                                  'response_provenance', a.response_provenance,
                                  'note', case when p_with_notes then a.response_note end,
                                  'slot_revision', a.slot_revision) as obj
                           from app.duties_assignments a
                          where a.slot_id = s.slot_id and a.assignment_state <> 'current'
                          order by a.ended_at desc, a.assignment_id
                          limit 20) h), '[]'::jsonb))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

create function app.duties_rota_occurrence_json(p_occurrence_id uuid, p_counts jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'series_date', to_char(o.series_date, 'YYYY-MM-DD'),
    'state', o.occurrence_state,
    'revision', o.revision,
    'duty_name', o.duty_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'event_ref', o.event_ref,
    'started', app.duties_occurrence_start(o) <= now(),
    'required', (select count(*) from app.duties_slots s where s.occurrence_id = o.occurrence_id),
    'confirmed', (select count(*) from app.duties_slots s
                    join app.duties_assignments a on a.slot_id = s.slot_id
                   where s.occurrence_id = o.occurrence_id and a.assignment_state = 'current'
                     and a.response = 'accepted'),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               'draft', case when s.draft_member_id is not null then jsonb_build_object(
                          'member_id', s.draft_member_id,
                          'display_name', app.duties_display_name(s.draft_member_id),
                          'available', app.duties_can_serve(s.draft_member_id, o.department_id),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override_reason', case when s.draft_member_id::text is distinct from
                                                          pg_catalog.current_setting('app.duties_viewer', true)
                                                  then s.draft_override_reason end) end,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'revision', a.revision,
                          'available', app.duties_can_serve(a.member_id, o.department_id),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override', app.duties_override_json(a))
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;


-- The 4.1-4.3 one-occurrence projections (replaced): the same, with that occurrence's counts.
create or replace function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.duties_occurrence_json(p_occurrence_id, p_with_notes,
                                    app.duties_overlap_counts(array[p_occurrence_id]));
$$;

create or replace function app.duties_rota_occurrence_json(p_occurrence_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.duties_rota_occurrence_json(p_occurrence_id, app.duties_overlap_counts(array[p_occurrence_id]));
$$;

-- A series on the rota (replaced): the counts of all its occurrences are computed once.
create or replace function app.duties_series_json(p_series_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'series_id', r.series_id,
    'department_id', r.department_id,
    'duty_name', r.duty_name,
    'every', r.every,
    'interval', r.every_interval,
    'from_date', to_char(r.from_date, 'YYYY-MM-DD'),
    'until_date', to_char(r.until_date, 'YYYY-MM-DD'),
    'start_time', to_char(r.start_time, 'HH24:MI'),
    'end_time', to_char(r.end_time, 'HH24:MI'),
    'reporting_time', to_char(r.reporting_time, 'HH24:MI'),
    'location', r.location,
    'instructions', r.instructions,
    'topic', r.topic,
    'scripture', r.scripture,
    'event_ref', r.event_ref,
    'positions', to_jsonb(r.positions),
    'zone', r.zone,
    'revision', r.revision,
    'draft_slots', (select count(*) from app.duties_occurrences o
                      join app.duties_slots s on s.occurrence_id = o.occurrence_id
                     where o.series_id = r.series_id and o.occurrence_state = 'draft'
                       and app.duties_occurrence_start(o) > now()),
    'occurrences', coalesce((
      -- The counts are an init plan of this subquery: computed once per series.
      select jsonb_agg(app.duties_rota_occurrence_json(o.occurrence_id, (
                         select app.duties_overlap_counts(array(
                                  select o2.occurrence_id from app.duties_occurrences o2
                                   where o2.series_id = r.series_id))))
                       order by o.series_date, o.occurrence_id)
        from app.duties_occurrences o
       where o.series_id = r.series_id), '[]'::jsonb))
    from app.duties_series r
   where r.series_id = p_series_id;
$$;

-- The board and the rota (replaced, story 4.4): as in 4.3, and they name the viewer for
-- app.duties_override_json.
create or replace function app.duties_leader_board()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_admin boolean;
  v_pastor boolean;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  v_pastor := app.identity_member_has_role(v_member, 'pastor');
  if not v_admin and not v_pastor
     and not exists (select 1 from app.identity_grants g
                      where g.member_id = v_member and g.revoked_at is null
                        and g.scope_kind in ('department_leader', 'department_deputy')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.duties_require_open_read();
  -- Story 4.4: an override about the viewer's own assignment hides its reason.
  perform pg_catalog.set_config('app.duties_viewer', v_member::text, true);
  select jsonb_build_object('departments', coalesce(jsonb_agg(x.obj order by x.name, x.department_id),
                                                    '[]'::jsonb))
    into v_result
    from (
      select d.department_id, d.name, c.capacity, jsonb_build_object(
               'department_id', d.department_id,
               'name', d.name,
               'capacity', coalesce(c.capacity, 'pastor'),
               'can_publish', c.capacity is not null,
               'members', app.duties_roster(d.department_id, false),
               'duties', coalesce((
                 -- Story 4.4: the overlap counts of these duties, an init plan computed once.
                 select jsonb_agg(app.duties_occurrence_json(o.occurrence_id, c.capacity is not null, (
                                    select app.duties_overlap_counts(array(
                                             select o4.occurrence_id from app.duties_occurrences o4
                                              where o4.department_id = d.department_id
                                                and o4.occurrence_state = 'published'
                                                and o4.starts_at > now() - interval '30 days'
                                              order by o4.starts_at limit 200))))
                                  order by o.starts_at, o.occurrence_id)
                   from (select o2.occurrence_id, o2.starts_at from app.duties_occurrences o2
                          where o2.department_id = d.department_id
                            and o2.occurrence_state = 'published'
                            and o2.starts_at > now() - interval '30 days'
                          order by o2.starts_at limit 200) o), '[]'::jsonb),
               'duties_truncated', (select count(*) > 200 from app.duties_occurrences o3
                                     where o3.department_id = d.department_id
                                       and o3.occurrence_state = 'published'
                                       and o3.starts_at > now() - interval '30 days')) as obj
        from app.duties_departments d
        cross join lateral (select app.duties_manage_capacity(v_member, d.department_id) as capacity) c
       where (c.capacity is not null or v_pastor)
         and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create or replace function app.duties_rota()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_admin boolean;
  v_pastor boolean;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  v_pastor := app.identity_member_has_role(v_member, 'pastor');
  if not v_admin and not v_pastor
     and not exists (select 1 from app.identity_grants g
                      where g.member_id = v_member and g.revoked_at is null
                        and g.scope_kind in ('department_leader', 'department_deputy')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.duties_require_open_read();
  -- Story 4.4: an override about the viewer's own assignment hides its reason.
  perform pg_catalog.set_config('app.duties_viewer', v_member::text, true);
  select jsonb_build_object('departments', coalesce(jsonb_agg(x.obj order by x.name, x.department_id),
                                                    '[]'::jsonb))
    into v_result
    from (
      select d.department_id, d.name, jsonb_build_object(
               'department_id', d.department_id,
               'name', d.name,
               'capacity', coalesce(c.capacity, 'pastor'),
               'can_manage', c.capacity is not null,
               'members', app.duties_roster(d.department_id, false),
               'series', coalesce((
                 select jsonb_agg(app.duties_series_json(r.series_id) order by r.from_date, r.series_id)
                   from (select r2.series_id, r2.from_date from app.duties_series r2
                          where r2.department_id = d.department_id
                            and r2.until_date >= (now() at time zone r2.zone)::date - 30
                          order by r2.from_date, r2.series_id limit 50) r), '[]'::jsonb),
               'series_truncated', (select count(*) > 50 from app.duties_series r3
                                     where r3.department_id = d.department_id
                                       and r3.until_date >= (now() at time zone r3.zone)::date - 30)) as obj
        from app.duties_departments d
        cross join lateral (select app.duties_manage_capacity(v_member, d.department_id) as capacity) c
       where (c.capacity is not null or v_pastor)
         and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- My duties (replaced): department-owned duties only until cell-owned parts get their member
-- view (entries 5 and 11); otherwise as in 4.1.
create or replace function app.duties_my_duties()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.duties_require_open_read();
  with ranked as (
    select a.assignment_id, o.starts_at,
           row_number() over (order by (o.starts_at <= now()),
                                       case when o.starts_at > now() then o.starts_at end,
                                       o.starts_at desc, a.assignment_id) as rn
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.member_id = v_member and a.assignment_state = 'current'
       and o.occurrence_state = 'published' and o.department_id is not null
       and o.starts_at > now() - interval '90 days')
  select jsonb_build_object(
           'member_id', v_member,
           'assignments', coalesce(jsonb_agg(app.duties_my_assignment_json(r.assignment_id)
                                             order by r.rn) filter (where r.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked r;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The candidates read
-- ---------------------------------------------------------------------------------------------

-- api.duties_candidates(slot_id), (slot_id, starts_at, ends_at?, reporting_at?) for the position
-- at new times, or (department_id, starts_at, ends_at?, reporting_at?): the department's leader,
-- deputy or an Admin (anyone else, Pastor included: 403 not_granted; an
-- unknown or cell-owned position answers the same, nothing is disclosed). For the position's
-- (or the prospective duty's) busy time: the window, and each current active roster member
-- with their account label (`app_account` / `no_login`), whether they hold or are planned for
-- the position (`current`), their upcoming load {total, here} and their overlaps as the caller
-- may see them {count, items (at most 10)}. A malformed request: 400 validation_failed.
create function app.duties_candidates(p_slot_id uuid, p_department_id uuid, p_starts_at timestamptz,
                                      p_ends_at timestamptz, p_reporting_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_occ app.duties_occurrences;
  v_department uuid;
  v_range tstzrange;
  v_current uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.duties_require_open_read();
  if p_starts_at is not null
     and ((p_ends_at is not null and p_ends_at <= p_starts_at)
          or (p_reporting_at is not null and p_reporting_at > p_starts_at)) then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
  end if;
  if p_slot_id is not null then
    -- The position (at its own times, or at the new times of an edit), never with a department.
    if p_department_id is not null
       or (p_starts_at is null and (p_ends_at is not null or p_reporting_at is not null)) then
      raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'slot_or_window';
    end if;
    select o.* into v_occ
      from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where s.slot_id = p_slot_id;
    if found then
      v_department := v_occ.department_id;
      v_range := case when p_starts_at is not null
                      then app.duties_busy_range_of(p_starts_at, p_ends_at, p_reporting_at)
                      else app.duties_busy_range(v_occ) end;
      select coalesce((select a.member_id from app.duties_assignments a
                        where a.slot_id = p_slot_id and a.assignment_state = 'current'),
                      (select s.draft_member_id from app.duties_slots s where s.slot_id = p_slot_id))
        into v_current;
    end if;
  else
    if p_department_id is null or p_starts_at is null then
      raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
    end if;
    v_department := p_department_id;
    v_range := app.duties_busy_range_of(p_starts_at, p_ends_at, p_reporting_at);
  end if;
  if v_department is null
     or not exists (select 1 from app.duties_departments d
                     where d.department_id = v_department and d.department_state = 'active'
                       and (not d.is_synthetic
                            or app.platform_current_environment() in ('local', 'staging')))
     or app.duties_manage_capacity(v_member, v_department) is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select jsonb_build_object(
    'department_id', v_department,
    'slot_id', p_slot_id,
    'window', jsonb_build_object('from', app.cmd_utc(lower(v_range)), 'to', app.cmd_utc(upper(v_range))),
    'candidates', coalesce(jsonb_agg(jsonb_build_object(
        'member_id', dm.member_id,
        'display_name', m.display_name,
        'account', case when app.identity_member_account_label(dm.member_id) = 'no_login'
                        then 'no_login' else 'app_account' end,
        'current', dm.member_id = v_current,
        'upcoming', app.duties_upcoming(dm.member_id, v_department),
        'conflicts', app.duties_conflicts_json(v_member, dm.member_id, v_range, p_slot_id, v_department,
                                                case when p_starts_at is not null then v_occ.occurrence_id end))
      order by m.display_name, dm.member_id), '[]'::jsonb))
    into v_result
    from app.duties_department_members dm
    join app.identity_members m on m.member_id = dm.member_id
   where dm.department_id = v_department and dm.ended_at is null
     and app.duties_member_active(dm.member_id);
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_candidates(slot_id uuid default null, department_id uuid default null,
                                      starts_at timestamptz default null,
                                      ends_at timestamptz default null,
                                      reporting_at timestamptz default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_candidates($1, $2, $3, $4, $5);
$$;

comment on function api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz) is
  'Story 4.4: for a position or a prospective one-off duty, each roster member''s upcoming load '
  'and the overlapping duties the caller may see (managers of the department only).';

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.4: departments, publishing and revising duties, the assignee''s answer, rota '
  'series (create_series, assign_slot, publish_drafts, revise_series, cancel_occurrence, '
  'cancel_series) through the 1.4 envelope; overlapping assignments need override_reason.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced: override reasons and recorders; no new row deletions)
-- ---------------------------------------------------------------------------------------------

create or replace function app.duties_deletion_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.duties_department_members dm
            where dm.member_id = p_member_id or dm.added_by_member = p_member_id
               or dm.added_by_account = p_account_id)
        + (select count(*) from app.duties_assignments a
            where a.member_id = p_member_id or a.responded_by_member = p_member_id
               or a.assigned_by_member = p_member_id or a.responded_by_account = p_account_id
               or a.assigned_by_account = p_account_id or a.override_by_member = p_member_id
               or a.override_by_account = p_account_id)
        + (select count(*) from app.duties_occurrences o
            where o.created_by_member = p_member_id or o.created_by_account = p_account_id)
        + (select count(*) from app.duties_departments d
            where d.created_by_member = p_member_id or d.created_by_account = p_account_id)
        + (select count(*) from app.duties_series r
            where r.created_by_member = p_member_id or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_slots s
            where s.draft_member_id = p_member_id or s.draft_override_by_member = p_member_id
               or s.draft_override_by_account = p_account_id)
        + (select count(*) from app.duties_slot_revisions r
            where r.member_id = p_member_id or r.created_by_member = p_member_id
               or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_audit au
            where au.actor_member_id = p_member_id or au.member_id = p_member_id
               or au.actor_account_id = p_account_id))::integer;
$$;

create or replace function app.duties_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    perform app.duties_deletion_purge_rows(v_member);
    update app.duties_department_members dm set added_by_member = v_nil
     where dm.added_by_member = v_member;
    -- The leader's words about the erased assignee go with them (story 4.4).
    update app.duties_assignments a set member_id = v_nil, response_note = null, override_reason = null
     where a.member_id = v_member;
    update app.duties_assignments a set responded_by_member = v_nil
     where a.responded_by_member = v_member;
    update app.duties_assignments a set assigned_by_member = v_nil
     where a.assigned_by_member = v_member;
    update app.duties_assignments a set override_by_member = v_nil
     where a.override_by_member = v_member;
    update app.duties_occurrences o set created_by_member = v_nil where o.created_by_member = v_member;
    update app.duties_departments d set created_by_member = v_nil where d.created_by_member = v_member;
    update app.duties_series r set created_by_member = v_nil where r.created_by_member = v_member;
    -- A planned (draft) position of the member becomes unassigned, with its planned reason.
    update app.duties_slots s
       set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
           draft_override_by_account = null, draft_override_at = null
     where s.draft_member_id = v_member;
    update app.duties_slots s set draft_override_by_member = v_nil
     where s.draft_override_by_member = v_member;
    update app.duties_slot_revisions r set member_id = v_nil where r.member_id = v_member;
    update app.duties_slot_revisions r set created_by_member = v_nil
     where r.created_by_member = v_member;
    update app.duties_audit au set actor_member_id = v_nil where au.actor_member_id = v_member;
    update app.duties_audit au set member_id = v_nil where au.member_id = v_member;
    if v_account is not null then
      update app.duties_department_members dm set added_by_account = v_nil
       where dm.added_by_account = v_account;
      update app.duties_assignments a set responded_by_account = v_nil
       where a.responded_by_account = v_account;
      update app.duties_assignments a set assigned_by_account = v_nil
       where a.assigned_by_account = v_account;
      update app.duties_assignments a set override_by_account = v_nil
       where a.override_by_account = v_account;
      update app.duties_occurrences o set created_by_account = v_nil
       where o.created_by_account = v_account;
      update app.duties_departments d set created_by_account = v_nil
       where d.created_by_account = v_account;
      update app.duties_series r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_slots s set draft_override_by_account = v_nil
       where s.draft_override_by_account = v_account;
      update app.duties_slot_revisions r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1-4.4): erase or check the member''s Duties personal data.';

-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_busy_range_of(timestamptz, timestamptz, timestamptz),
  app.duties_busy_range(app.duties_occurrences),
  app.duties_busy_items(uuid, tstzrange, uuid, uuid, uuid),
  app.duties_overlap_count(uuid, tstzrange, uuid, uuid),
  app.duties_conflicts_json(uuid, uuid, tstzrange, uuid, uuid, uuid),
  app.duties_upcoming(uuid, uuid),
  app.duties_lock_members(uuid[]),
  app.duties_overlap_gate(uuid, text, uuid, uuid, timestamptz, uuid, uuid, text, text, jsonb),
  app.duties_gate_created(jsonb, text, uuid, uuid, text, text),
  app.duties_occurrence_members(uuid),
  app.duties_override_json(app.duties_assignments),
  app.duties_overlap_counts(uuid[]),
  app.duties_occurrence_json(uuid, boolean, jsonb),
  app.duties_rota_occurrence_json(uuid, jsonb),
  app.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz),
  api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function app.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)
  to authenticated;
grant execute on function api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz)
  to authenticated;

notify pgrst, 'reload schema';
