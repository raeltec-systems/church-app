-- Story 5.5 (epic 5): a Duties contract change for cell programme parts. The 4.11 consumer guide
-- lists cell-scope "Confirmed by leader" as a change Duties makes, never a Cells-side workaround.
--
--   * duties.confirm_by_leader also accepts an assignment of a cell-owned occurrence when the
--     actor is a current leader or assistant of that cell (capacity cell_leader / cell_assistant):
--     the same attributed direct confirmation as 4.9 (channel and a short reason, provenance
--     `leader`), for a member without a login or one the leader reached by phone. Everything else
--     of the command is unchanged; a department duty is still confirmed only by its department.
--   * Contact attempts, the coverage queue, leader alerts and outcomes stay department-only.
--   * The authorizer also share-locks the actor's cell grants (AD-2: grants before Duties rows), and
--     a replay of a cell confirmation is rechecked against the cell scope.
--
-- No destructive statements and no row deletions. ASCII only.

-- The assignment a leader confirms, locked in the 4.9 order: a department duty through
-- app.duties_lock_for_leader (unchanged); a cell-owned duty when the actor leads or assists its cell
-- (anyone else: not_found; the Admin role and Pastor: not_found, as they hold no cell scope).
create function app.duties_lock_for_confirm(p_actor_member uuid, p_assignment_id uuid,
                                            p_expected_revision bigint,
                                            out assignment app.duties_assignments,
                                            out occurrence app.duties_occurrences,
                                            out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_department uuid;
  v_cell uuid;
  v_occurrence uuid;
  v_assignee uuid;
  v_lock record;
begin
  select o.department_id, o.cell_id, o.occurrence_id, a.member_id
    into v_department, v_cell, v_occurrence, v_assignee
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = p_assignment_id;
  if v_cell is null then
    select l.* into v_lock from app.duties_lock_for_leader(p_actor_member, p_assignment_id,
                                                            p_expected_revision) l;
    assignment := v_lock.assignment;
    occurrence := v_lock.occurrence;
    capacity := v_lock.capacity;
    return;
  end if;
  capacity := case
    when app.identity_member_has_scope(p_actor_member, 'cell_leader', v_cell) then 'cell_leader'
    when app.identity_member_has_scope(p_actor_member, 'cell_assistant', v_cell) then 'cell_assistant'
  end;
  if capacity is null then
    perform app.cmd_fail('not_found');
  end if;
  -- A leader answers their own part in My duties (as for departments, 4.9 review S2).
  if v_assignee = p_actor_member then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "own"}');
  end if;
  select o.* into occurrence from app.duties_occurrences o where o.occurrence_id = v_occurrence for share;
  select a.* into assignment from app.duties_assignments a where a.assignment_id = p_assignment_id for update;
  if assignment.assignment_state = 'superseded' then
    perform app.cmd_fail('conflict', '{"assignment_id": "superseded"}', assignment.revision);
  elsif assignment.assignment_state <> 'current' or occurrence.occurrence_state = 'cancelled' then
    perform app.cmd_fail('conflict', '{"assignment_id": "cancelled"}', assignment.revision);
  end if;
  if occurrence.occurrence_state <> 'published' then
    perform app.cmd_fail('not_found');
  end if;
  if assignment.revision is distinct from p_expected_revision then
    perform app.cmd_fail('conflict', null, assignment.revision);
  end if;
  if app.duties_occurrence_start(occurrence) <= now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "started"}');
  end if;
end;
$$;

-- duties.confirm_by_leader (replaced from 4.9): the lock above instead of the department-only one.
-- A cell confirmation has no coverage case to close (cases are department-only). Otherwise 4.9's
-- body.
create or replace function app.duties_confirm_by_leader(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_channel text;
  v_reason text;
  v_lock record;
  v_revision bigint;
  v_cmd constant text := 'duties.confirm_by_leader';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'channel', 'reason']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_channel
    from app.duties_code(p_payload, 'channel', 'contact_channel', v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'reason', true, 200, false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_for_confirm(v_actor.member_id, v_assignment_id,
                                                           p_expected_revision) l;
  if (v_lock.assignment).response = 'accepted' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', (v_lock.assignment).revision);
  elsif (v_lock.assignment).response = 'declined' then
    -- A decline is replaced (reassign), not overwritten (fail closed).
    perform app.cmd_fail('conflict', '{"assignment_id": "declined"}', (v_lock.assignment).revision);
  end if;
  if (v_lock.assignment).member_id = '00000000-0000-0000-0000-000000000000'::uuid
     or not app.duties_member_active((v_lock.assignment).member_id) then
    perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
  end if;
  update app.duties_assignments a
     set response = 'accepted', responded_at = now(),
         responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
         response_provenance = 'leader', response_note = null, confirmed_channel = v_channel,
         confirmed_reason = v_reason, revision = a.revision + 1
   where a.assignment_id = v_assignment_id
  returning a.revision into v_revision;
  perform app.duties_audit_event('leader_confirmed', v_actor.member_id, v_actor.account_id,
                                 v_lock.capacity, v_cmd, (v_lock.occurrence).department_id,
                                 (v_lock.occurrence).occurrence_id, v_assignment_id,
                                 (v_lock.assignment).member_id, v_channel, v_revision);
  -- Follow-ups before Notifications (department duties only have coverage cases).
  if (v_lock.occurrence).department_id is not null then
    perform app.duties_close_started_cases((v_lock.occurrence).department_id, v_actor.member_id,
                                           v_actor.account_id, v_lock.capacity, v_cmd);
    perform app.duties_close_cases(array[v_assignment_id], 'confirmed', v_actor.member_id,
                                   v_actor.account_id, v_lock.capacity, v_cmd);
  end if;
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment_id, 'reason', 'responded'));
  perform app.duties_after_answer(v_assignment_id, v_actor.member_id, v_actor.account_id, v_cmd);
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', (v_lock.occurrence).occurrence_id,
    'revision', (v_lock.occurrence).revision,
    'data', jsonb_build_object('assignment_id', v_assignment_id, 'revision', v_revision,
                               'response', 'accepted', 'provenance', 'leader'));
end;
$$;

-- Replay scope (replaced from 4.3): a cell-owned occurrence is in scope for a current leader or
-- assistant of its cell (the cell confirmation above); otherwise 4.3's rules.
create or replace function app.duties_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_department uuid;
  v_cell uuid;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null or p_aggregate_id is null then
    return false;
  end if;
  if p_aggregate_type = 'duties_department' then
    return exists (select 1 from app.duties_departments d where d.department_id = p_aggregate_id)
       and app.identity_member_has_role(v_member, 'admin');
  elsif p_aggregate_type = 'duties_occurrence' then
    select o.department_id, o.cell_id into v_department, v_cell from app.duties_occurrences o
     where o.occurrence_id = p_aggregate_id for share;
    if v_department is null and v_cell is not null then
      return app.identity_member_has_scope(v_member, 'cell_leader', v_cell)
          or app.identity_member_has_scope(v_member, 'cell_assistant', v_cell);
    end if;
    return v_department is not null
       and app.duties_manage_capacity(v_member, v_department) is not null;
  elsif p_aggregate_type = 'duties_series' then
    select r.department_id into v_department from app.duties_series r
     where r.series_id = p_aggregate_id for share;
    return v_department is not null
       and app.duties_manage_capacity(v_member, v_department) is not null;
  elsif p_aggregate_type = 'duties_assignment' then
    return exists (select 1 from app.duties_assignments a
                    where a.assignment_id = p_aggregate_id and a.member_id = v_member);
  end if;
  return false;
end;
$$;

-- The authorizer (replaced from 4.12): the actor's cell grants are share-locked with the others
-- (AD-2: grants before any Duties row). Otherwise 4.12's body.
create or replace function app.duties_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'duties.create_department', 'duties.add_member', 'duties.publish_duty', 'duties.respond',
       'duties.revise_duty', 'duties.create_series', 'duties.assign_slot', 'duties.publish_drafts',
       'duties.revise_series', 'duties.cancel_occurrence', 'duties.cancel_series',
       'duties.withdraw_acceptance', 'duties.accept_many', 'duties.set_reminders',
       'duties.record_contact_attempt', 'duties.confirm_by_leader', 'duties.cancel_position',
       -- Story 4.10.
       'duties.record_outcome', 'duties.correct_outcome',
       -- Story 4.11: the department reviews an owner-review mismatch.
       'duties.clear_review',
       -- Story 4.12: membership and handover (Admin).
       'duties.remove_member', 'duties.resolve_handover') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  -- Story 4.12 review S2 (N9 order): the actor's member row first (as Identity: member, then
  -- grants), then the actor's grants, then the other members this command may notify, all
  -- before any Duties row.
  perform app.duties_lock_people(array[r.member_id]);
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin'
          or g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader', 'cell_assistant'))
     for share;
  perform app.duties_lock_people(app.duties_command_people(
    jsonb_build_object('payload', nullif(pg_catalog.current_setting('duties.command_payload', true), '')::jsonb),
    r.member_id));
  return true;
end;
$$;

revoke all on function app.duties_lock_for_confirm(uuid, uuid, bigint)
  from public, anon, authenticated, service_role;
