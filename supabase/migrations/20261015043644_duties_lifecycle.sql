-- Story 4.12: apply membership lifecycle and handover to Duties and Follow-ups (AD-2, AD-6, AD-7,
-- AD-14; identity-access.md stories 2.10 and 2.11).
--
-- What this adds:
--   * Duties lifecycle hook `app.duties_on_member_lifecycle` (Identity's transaction):
--       membership_deactivated, deletion_requested: every current assignment of the member on a
--         published occurrence that has not started (department duties and cell parts, any answer)
--         ends (`superseded`, end reason `vacated`); the position is left unfilled; the member's jobs
--         and the leaders' alerts of that assignment are cancelled and its coverage case closes
--         (`superseded`, its Follow-ups task resolved); the member's planned draft positions are
--         cleared. The member gets no notice. Past and started duties, answers, outcomes and history
--         are kept; department membership rows are kept (a restoration restores no assignment).
--       access_hold_applied: duties are kept; each current, not declined assignment of a published
--         duty that has not started gets a Needs contact entry at once (kind `access_hold`, shown as
--         `not_reached` while the member still cannot be reached in the app). No leader alert.
--       scope_revoked: the removed leader's pending leader alerts of departments they no longer
--         lead or deputise are cancelled (authority itself is checked on current grants at every
--         command and replay, so it already ends at once).
--   * `duties.remove_member {department_id, member_id}` (Admin; expected = department revision):
--     the membership ends (attributed), the member's current assignments of the department's future
--     published duties end (`vacated`) with `duty_released` to the member, and their draft plans
--     there are cleared.
--   * The leaders' vacancy notice `duties_coverage` / `duty_vacated` ("Positions need cover"): one
--     per department and change (not one per position), sent now to each reachable leader and
--     deputy of the department (never the member) when the change ended at least one position the
--     member had not declined; keyed by the soonest such ended assignment at its ended revision
--     (fresh keys); delivered while any position the change ended there is still unfilled, not
--     cancelled and not started. The coverage
--     queue shows `vacated: {since}` (and a `vacated` count); the board shows the ended assignment in
--     the position's history with end reason `vacated`. One generic flag: no hold, deactivation,
--     deletion or removal reason is ever disclosed.
--   * Duties handover hook `app.duties_report_handover`: `department_leader` (subject = department,
--     last_responsible) when the member leads or deputises an active department and no other
--     approved, reachable member holds its leader or deputy scope. `duties.resolve_handover
--     {department_id}` (Admin; expected = department revision) resolves the department's pending
--     obligations once it has a reachable leader or deputy again.
--   * Follow-ups lifecycle hook `app.followups_on_member_lifecycle` and handover hook
--     `app.followups_report_handover` (`followup_task` per active task the member owns,
--     last_responsible when nobody else may own it): the Q4 owner-scope rule picks the new owner
--     (the task's supervisor, other holders of its scope, live Pastors, then other members of its
--     own group); supervision moves to another holder of the task's scope. A trigger resolves a
--     task's pending obligation when its owner changes or it finishes.
--   * Gates: ending work never needs Q2: with the policy unavailable the notices and task reminders
--     are skipped and audited (`reminders_skipped`, code `policy_unavailable`). Hooks run whatever
--     the Q4 gate (they only reduce processing); erasure follows Identity's
--     `identity_deletion_retention` gate.
--
-- Replaced bodies (each copied from its latest version, keeping every earlier review fix; changes
-- are marked "Story 4.12"):
--   from 20261015035112 (4.11): duties_state_ok, duties_authorize_command, duties_command,
--     duties_deletion_remaining, duties_erase_member (the 4.10 S1 lock-first order kept).
--   from 20261014212507 (4.9): duties_coverage.
--   from 20261014171038 (4.8): duties_needs_contact, duties_coverage_source_check.
--   from 20261014130535 (4.7): followups_state_ok.
--   from 20261013220239 (4.1): duties_department_json.
--
-- Lock order (AD-2): Identity rows (the lifecycle command's, or the Admin's grants) -> Duties
-- departments -> series -> occurrences -> slots -> member advisory lock -> department membership ->
-- assignments -> coverage cases -> Follow-ups tasks -> Notifications last.
--
-- No destructive statements, no row deletions (no _rows file). No new client grant (both commands
-- go through api.duties_command). ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened: the vacated end reason and change, the lifecycle capacity, audit actions)
-- ---------------------------------------------------------------------------------------------

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.)
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
    -- Story 4.12: `vacated` = the member left (deactivation, deletion, removal from the department).
    when 'assignment_end_reason' then p_value in ('revised', 'cancelled', 'vacated')
    when 'response' then p_value in ('pending', 'accepted', 'declined')
    -- Story 4.9: `leader` = Confirmed by leader (a phone or in-person confirmation).
    when 'response_provenance' then p_value in ('member', 'leader')
    -- Story 4.11: a cell's leader or assistant acting through an owner operation.
    -- Story 4.12: `lifecycle` = an Identity lifecycle change applied by the Duties hook.
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member',
                                     'cell_leader', 'cell_assistant', 'lifecycle')
    when 'change_class' then p_value in ('published', 'material', 'notes', 'reference', 'cancelled',
                                         'vacated')
    when 'slot_field' then p_value in ('duty_name', 'starts_at', 'ends_at', 'reporting_at',
                                       'location', 'member_id', 'instructions', 'topic',
                                       'scripture', 'event_ref', 'position_name')
    when 'deadline_source' then p_value in ('creator', 'default')
    when 'series_every' then p_value in ('day', 'week', 'month')
    -- Story 4.9: how a leader reached (or tried to reach) a member, and what came of it.
    when 'contact_channel' then p_value in ('phone', 'message', 'in_person', 'other')
    when 'contact_outcome' then p_value in ('no_answer', 'left_message', 'will_answer',
                                            'cannot_serve', 'other')
    when 'case_close' then p_value in ('accepted', 'confirmed', 'superseded', 'cancelled',
                                       'replaced', 'started')
    -- Story 4.10: what the leader recorded after the duty.
    when 'completion_outcome' then p_value in ('completed', 'excused', 'no_show')
    -- Story 4.11: owner links and owner-review flags.
    when 'link_kind' then p_value in ('owned', 'linked')
    when 'link_role' then p_value in ('cell_part', 'event')
    when 'review_field' then p_value in ('time', 'place', 'label', 'assignee', 'cancelled')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn', 'reminders_set',
                                         'reminders_skipped', 'contact_attempt_recorded',
                                         'leader_confirmed', 'position_cancelled',
                                         'followup_skipped', 'outcome_recorded',
                                         'outcome_corrected',
                                         -- Story 4.11.
                                         'part_created', 'part_revised', 'part_cancelled',
                                         'duty_linked', 'duty_unlinked', 'review_flagged',
                                         'review_cleared',
                                         -- Story 4.12.
                                         'assignment_vacated', 'draft_cleared', 'member_removed',
                                         'handover_resolved')
    else false end;
$$;

-- (Replaced, story 4.12; copied from 20261014130535_followups_reminders.sql.) Story 4.12:
-- `reminders_skipped` records a lifecycle handover whose reminders could not be planned (Q2
-- policy unavailable).
create or replace function app.followups_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'task_state' then p_value in ('open', 'in_progress', 'waiting', 'done', 'closed')
    when 'active_state' then p_value in ('open', 'in_progress', 'waiting')
    when 'effect' then p_value in ('close', 'keep')
    when 'source_event' then p_value in ('resolved', 'cancelled')
    when 'close_code' then p_value in ('manual', 'source_resolved', 'source_cancelled')
    when 'capacity' then p_value in ('owner', 'supervisor', 'admin', 'source')
    when 'notes_access' then p_value in ('practical')
    when 'activity' then p_value in ('created', 'status_changed', 'review_date_set',
                                     'outcome_recorded', 'next_action_changed', 'note_added',
                                     'reassigned', 'supervisor_changed', 'closed_by_source',
                                     'reminders_adjusted', 'reminders_skipped')
    else false end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables: who ended a department membership
-- ---------------------------------------------------------------------------------------------

alter table app.duties_department_members
  add column ended_by_member uuid,
  add column ended_by_account uuid,
  add constraint duties_department_members_ended_by
    check (ended_at is not null or (ended_by_member is null and ended_by_account is null));

comment on column app.duties_department_members.ended_by_member is
  'Story 4.12: the Admin who removed the member from the department (nil UUID once erased).';

-- ---------------------------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------------------------

-- The person behind a lifecycle change: the session's account and the member it is (or was)
-- linked to; the nil UUID for both when there is no session (an operator or a restore replay).
create function app.duties_lifecycle_actor(out member_id uuid, out account_id uuid)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  begin
    account_id := auth.uid();
  exception when others then
    account_id := null;
  end;
  if account_id is not null then
    select l.member_id into member_id from app.identity_account_links l
     where l.auth_user_id = account_id
     order by l.created_at desc, l.link_id
     limit 1;
  end if;
  if member_id is null or account_id is null then
    member_id := v_nil;
    account_id := v_nil;
  end if;
end;
$$;

-- When an unfilled position was left by a member who could no longer serve: the end time of its
-- latest assignment when that assignment ended `vacated` and nobody holds the position now.
create function app.duties_vacated_since(p_slot_id uuid)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select x.ended_at
    from (select a.ended_at, a.end_reason
            from app.duties_assignments a
           where a.slot_id = p_slot_id and a.assignment_state <> 'current'
           order by a.ended_at desc nulls last, a.assignment_id desc
           limit 1) x
   where x.end_reason = 'vacated'
     and not exists (select 1 from app.duties_assignments c
                      where c.slot_id = p_slot_id and c.assignment_state = 'current');
$$;

-- Duties' own notification step with the Q2 guard: cancellations always run; the enqueues are
-- skipped and audited (`reminders_skipped`, code `policy_unavailable`) when the Q2 policy is
-- unavailable. Returns {queued, skipped}.
create function app.duties_lifecycle_notify(p_cancels jsonb, p_enqueues jsonb, p_actor_member uuid,
                                            p_actor_account uuid, p_capacity text, p_command text,
                                            p_department uuid, p_member uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_notified jsonb;
  v_message text;
begin
  -- The actor for app.duties_notify (coverage cases closing through Follow-ups).
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  if jsonb_array_length(coalesce(p_cancels, '[]'::jsonb)) > 0 then
    perform app.duties_notify(p_cancels);
  end if;
  if jsonb_array_length(coalesce(p_enqueues, '[]'::jsonb)) = 0 then
    return '{"queued": 0, "skipped": false}'::jsonb;
  end if;
  begin
    v_notified := app.duties_notify(p_enqueues);
  exception when sqlstate 'PCMD1' then
    get stacked diagnostics v_message = message_text;
    if v_message is distinct from 'unavailable' then
      raise;
    end if;
    perform app.duties_audit_event('reminders_skipped', p_actor_member, p_actor_account, p_capacity,
                                   p_command, p_department, null, null, p_member,
                                   'policy_unavailable', null);
    return '{"queued": 0, "skipped": true}'::jsonb;
  end;
  return jsonb_build_object('queued', coalesce((v_notified ->> 'queued')::integer, 0), 'skipped', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Ending a member's future work (deactivation, deletion, removal from a department)
-- ---------------------------------------------------------------------------------------------

-- Ends every current assignment of p_member on a published occurrence that has not started (of
-- p_department only when given), clears the member's planned draft positions there and, for a
-- removal (p_department given), ends the membership row. Each ended position is left unfilled
-- (`superseded`, end reason `vacated`, a `vacated` slot revision), its jobs and alerts are
-- cancelled and its coverage case closes; the leaders get one `duty_vacated` per department
-- unless the member had declined every ended position there; p_release sends `duty_released` to
-- the member. Set-based (review S1): one statement per table, and Notifications are called only
-- for assignments that have pending jobs or active schedules. Lock order: departments, series,
-- occurrences, slots, the member's advisory lock, the membership row, assignments, then
-- Follow-ups and Notifications (review N5: an occurrence found again under the member's lock is
-- locked before any assignment). Answers counts only.
create function app.duties_vacate_member(p_member uuid, p_department uuid, p_code text,
                                         p_release boolean, p_actor_member uuid,
                                         p_actor_account uuid, p_capacity text, p_command text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_occ uuid[];
  v_draft uuid[];
  v_all uuid[];
  v_more uuid[];
  v_ids uuid[];
  v_ended jsonb;
  v_jobs uuid[];
  v_cancels jsonb := '[]'::jsonb;
  v_enqueues jsonb := '[]'::jsonb;
  v_first record;
  v_leader uuid;
  v_alerts integer := 0;
  v_released integer := 0;
  v_drafts integer := 0;
  v_membership uuid;
  v_request uuid := case when p_command is not null
                         then app.cmd_current_request_id(p_actor_account, p_command) end;
  v_notified jsonb;
begin
  select coalesce(array_agg(distinct o.occurrence_id), '{}') into v_occ
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department);
  select coalesce(array_agg(distinct o.occurrence_id), '{}') into v_draft
    from app.duties_slots s
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.draft_member_id = p_member and o.occurrence_state = 'draft'
     and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department);
  v_all := v_occ || v_draft;

  -- Lock first, in the commands' AD-2 order (as the 4.10 S1 erase).
  perform 1 from app.duties_departments d
   where d.department_id in (select o.department_id from app.duties_occurrences o
                              where o.occurrence_id = any (v_all))
   order by d.department_id for share;
  perform 1 from app.duties_series r
   where r.series_id in (select o.series_id from app.duties_occurrences o
                          where o.occurrence_id = any (v_all))
   order by r.series_id for share;
  perform 1 from app.duties_occurrences o where o.occurrence_id = any (v_all)
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
     for update;
  perform 1 from app.duties_slots s where s.occurrence_id = any (v_all)
   order by s.occurrence_id, s.position_no for update;
  perform app.duties_lock_members(array[p_member]);
  -- Review N5: an assignment committed while we waited (a removal; a lifecycle change holds the
  -- member row, so none can appear) has its occurrence and slots locked before any assignment.
  select coalesce(array_agg(distinct s.occurrence_id), '{}') into v_more
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department)
     and not (s.occurrence_id = any (v_all));
  if cardinality(v_more) > 0 then
    perform 1 from app.duties_occurrences o where o.occurrence_id = any (v_more)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
       for update;
    perform 1 from app.duties_slots s where s.occurrence_id = any (v_more)
     order by s.occurrence_id, s.position_no for update;
    v_all := v_all || v_more;
  end if;
  if p_department is not null then
    select dm.membership_id into v_membership from app.duties_department_members dm
     where dm.department_id = p_department and dm.member_id = p_member and dm.ended_at is null
       for update;
    if v_membership is null then
      perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
    end if;
    update app.duties_department_members dm
       set ended_at = now(), ended_by_member = p_actor_member, ended_by_account = p_actor_account
     where dm.membership_id = v_membership;
  end if;
  select coalesce(array_agg(x.assignment_id order by x.assignment_id), '{}') into v_ids
    from (select a.assignment_id
            from app.duties_assignments a
            join app.duties_slots s on s.slot_id = a.slot_id
            join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
           where a.member_id = p_member and a.assignment_state = 'current'
             and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
             and (p_department is null or o.department_id = p_department)
           order by a.assignment_id
             for update of a) x;

  -- One statement per table.
  with e as (
    update app.duties_assignments a
       set assignment_state = 'superseded', ended_at = now(), end_reason = 'vacated',
           revision = a.revision + 1
     where a.assignment_id = any (v_ids)
    returning a.assignment_id, a.slot_id, a.revision, a.response)
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignment_id', e.assignment_id, 'slot_id', e.slot_id, 'revision', e.revision,
           'response', e.response, 'occurrence_id', s.occurrence_id, 'department_id', o.department_id,
           'series_id', o.series_id, 'starts_at', o.starts_at) order by e.assignment_id), '[]'::jsonb)
    into v_ended
    from e
    join app.duties_slots s on s.slot_id = e.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id;
  update app.duties_occurrences o set revision = o.revision + 1
   where o.occurrence_id in (select (x ->> 'occurrence_id')::uuid from jsonb_array_elements(v_ended) x)
      or o.occurrence_id in (select s.occurrence_id from app.duties_slots s
                              where s.draft_member_id = p_member and s.occurrence_id = any (v_draft));
  with sr as (
    update app.duties_slots s set revision = s.revision + 1
     where s.slot_id in (select (x ->> 'slot_id')::uuid from jsonb_array_elements(v_ended) x)
    returning s.slot_id, s.revision, s.occurrence_id)
  insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id, occurrence_revision,
                                         change_class, changed_fields, duty_name, starts_at, ends_at,
                                         reporting_at, location, instructions, topic, scripture,
                                         event_ref, member_id, assignment_id, response_deadline,
                                         created_by_member, created_by_account, command_request_id)
  select sr.slot_id, sr.revision, o.occurrence_id, o.revision, 'vacated', array['member_id'],
         o.duty_name, o.starts_at, o.ends_at, o.reporting_at, o.location, o.instructions, o.topic,
         o.scripture, o.event_ref, null, null, null, p_actor_member, p_actor_account, v_request
    from sr join app.duties_occurrences o on o.occurrence_id = sr.occurrence_id;
  insert into app.duties_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                command_request_id, department_id, series_id, occurrence_id,
                                assignment_id, member_id, code, revision_after)
  select 'assignment_vacated', p_actor_member, p_actor_account, p_capacity, v_request,
         (x ->> 'department_id')::uuid, (x ->> 'series_id')::uuid, (x ->> 'occurrence_id')::uuid,
         (x ->> 'assignment_id')::uuid, p_member, p_code, (x ->> 'revision')::bigint
    from jsonb_array_elements(v_ended) x;
  -- The member's planned (draft) positions become unplanned, with their planned reason.
  with d as (
    update app.duties_slots s
       set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
           draft_override_by_account = null, draft_override_at = null
     where s.draft_member_id = p_member and s.occurrence_id = any (v_draft)
    returning s.occurrence_id)
  insert into app.duties_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                command_request_id, department_id, series_id, occurrence_id,
                                member_id, code)
  select 'draft_cleared', p_actor_member, p_actor_account, p_capacity, v_request, o.department_id,
         o.series_id, o.occurrence_id, p_member, p_code
    from d join app.duties_occurrences o on o.occurrence_id = d.occurrence_id;
  get diagnostics v_drafts = row_count;

  -- Follow-ups: the open coverage cases close `superseded` (their tasks resolved).
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  perform app.duties_close_cases(v_ids, 'superseded', p_actor_member, p_actor_account, p_capacity,
                                 p_command);
  -- Notifications last: cancellations only where something is pending.
  select coalesce(array_agg(distinct y.id order by y.id), '{}') into v_jobs
    from (select j.source_id as id from app.notifications_jobs j
           where j.source_type in ('duties_assignment', 'duties_coverage')
             and j.source_id = any (v_ids) and j.job_state = 'pending'
          union
          select sc.source_id from app.notifications_schedules sc
           where sc.source_type = 'duties_assignment' and sc.source_id = any (v_ids)
             and sc.schedule_state = 'active') y;
  select coalesce(jsonb_agg(jsonb_build_object('op', 'cancel', 'source_id', x, 'reason', 'source_revised')
                            order by x), '[]'::jsonb)
    into v_cancels from unnest(v_jobs) x;
  if p_release and app.duties_notice_recipient(p_member) then
    select coalesce(jsonb_agg(jsonb_build_object('op', 'enqueue', 'counts', true,
             'key', jsonb_build_object(
               'source_type', 'duties_assignment', 'source_id', x ->> 'assignment_id',
               'source_revision', (x ->> 'revision')::bigint, 'recipient_member_id', p_member,
               'reminder_kind', 'duty_released', 'scheduled_at', app.cmd_utc(now())))), '[]'::jsonb),
           count(*)
      into v_enqueues, v_released
      from jsonb_array_elements(v_ended) x
     where x ->> 'response' in ('pending', 'accepted');
  end if;
  -- One leaders' notice per department and change, keyed by the soonest ended position the
  -- member had not declined (cell parts get no leader alert: a later contract change).
  for v_first in
    select distinct on (x ->> 'department_id') (x ->> 'department_id')::uuid as department_id,
           x ->> 'assignment_id' as assignment_id, (x ->> 'revision')::bigint as revision
      from jsonb_array_elements(v_ended) x
     where x ->> 'department_id' is not null and x ->> 'response' <> 'declined'
     order by x ->> 'department_id', (x ->> 'starts_at')::timestamptz, x ->> 'assignment_id'
  loop
    foreach v_leader in array app.duties_alert_recipients(v_first.department_id, p_member) loop
      v_enqueues := v_enqueues || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', false,
        'key', jsonb_build_object(
          'source_type', 'duties_coverage', 'source_id', v_first.assignment_id,
          'source_revision', v_first.revision, 'recipient_member_id', v_leader,
          'reminder_kind', 'duty_vacated', 'scheduled_at', app.cmd_utc(now()))));
      v_alerts := v_alerts + 1;
    end loop;
  end loop;
  v_notified := app.duties_lifecycle_notify(v_cancels, v_enqueues, p_actor_member, p_actor_account,
                                            p_capacity, p_command, p_department, p_member);
  return jsonb_build_object('vacated', jsonb_array_length(v_ended), 'drafts_cleared', v_drafts,
                            'leader_alerts', v_alerts, 'released', v_released,
                            'notices_skipped', (v_notified ->> 'skipped')::boolean);
end;
$$;

-- A login (or security) hold: each current, not declined assignment of a published duty that has
-- not started is put on the leaders' Needs contact list at once (kind `access_hold`, once per
-- assignment revision). The reason is never recorded.
create function app.duties_hold_contact(p_member uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into app.duties_contact_needs (need_id, assignment_id, source_revision, reminder_kind,
                                        scheduled_at)
  select gen_random_uuid(), a.assignment_id, a.revision, 'access_hold', now()
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current' and a.response <> 'declined'
     and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
     and not exists (select 1 from app.duties_contact_needs c
                      where c.assignment_id = a.assignment_id and c.source_revision = a.revision
                        and c.reminder_kind = 'access_hold');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- A removed leader or deputy: their pending leader alerts of every department they no longer lead
-- or deputise end (`not_recipient`). Review N6: the pending alerts are found in one query (the
-- recipient's pending `duties_coverage` jobs of those departments' duties that have not started);
-- the Notifications API then cancels each one found (usually none or a few).
create function app.duties_scope_revoked(p_member uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
begin
  for v_id in
    select distinct j.source_id
      from app.notifications_jobs j
      join app.duties_assignments a on a.assignment_id = j.source_id
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where j.source_type = 'duties_coverage' and j.job_state = 'pending'
       and j.recipient_member_id = p_member
       and o.department_id is not null
       and not exists (select 1 from app.identity_grants g
                        where g.member_id = p_member and g.revoked_at is null
                          and g.scope_id = o.department_id
                          and g.scope_kind in ('department_leader', 'department_deputy'))
     order by j.source_id
  loop
    v_count := v_count + (app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_id, 'reason', 'not_recipient',
      'recipient_member_id', p_member)) ->> 'cancelled')::integer;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Duties lifecycle and handover hooks (AD-14), registered below
-- ---------------------------------------------------------------------------------------------

-- Runs inside Identity's lifecycle transaction (a raise rolls the whole change back).
create function app.duties_on_member_lifecycle(p_event jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_event ->> 'member_id')::uuid;
  v_actor record;
begin
  case p_event ->> 'event'
    when 'membership_deactivated', 'deletion_requested' then
      select a.* into v_actor from app.duties_lifecycle_actor() a;
      perform app.duties_vacate_member(v_member, null, 'member_left', false, v_actor.member_id,
                                       v_actor.account_id, 'lifecycle', null);
    when 'access_hold_applied' then
      perform app.duties_hold_contact(v_member);
    when 'scope_revoked' then
      perform app.duties_scope_revoked(v_member);
    else
      null;
  end case;
end;
$$;

comment on function app.duties_on_member_lifecycle(jsonb) is
  'Duties lifecycle hook (story 4.12): deactivation and deletion end future assignments '
  '(vacancies flagged, jobs cancelled, leaders told), a hold routes contact to the leaders, a '
  'revoked scope ends that leader''s alerts.';

select app.contract_register_lifecycle_hook('duties', e,
         'app.duties_on_member_lifecycle(jsonb)'::regprocedure)
  from unnest(array['membership_deactivated', 'deletion_requested', 'access_hold_applied',
                    'scope_revoked']) e;

-- Read only (it runs before Identity decides): the active departments the member leads or
-- deputises where nobody else approved and reachable in the app holds the leader or deputy scope.
create function app.duties_report_handover(p_event jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('obligations', coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'department_leader', 'subject_id', d.department_id, 'last_responsible', true)
           order by d.department_id), '[]'::jsonb))
    from app.duties_departments d
   where d.department_state = 'active'
     and exists (select 1 from app.identity_grants g
                  where g.member_id = (p_event ->> 'member_id')::uuid and g.revoked_at is null
                    and g.scope_id = d.department_id
                    and g.scope_kind in ('department_leader', 'department_deputy'))
     and not exists (select 1 from app.identity_grants g
                      where g.member_id <> (p_event ->> 'member_id')::uuid and g.revoked_at is null
                        and g.scope_id = d.department_id
                        and g.scope_kind in ('department_leader', 'department_deputy')
                        and app.duties_member_active(g.member_id)
                        and app.duties_leader_reachable(g.member_id));
$$;

comment on function app.duties_report_handover(jsonb) is
  'Duties handover hook (story 4.12): the last reachable leader or deputy of an active department.';

select app.identity_register_handover_hook('duties', 'app.duties_report_handover(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- The leaders' vacancy notice (3.2 contract on `duties_coverage`)
-- ---------------------------------------------------------------------------------------------

-- duty_vacated (one per department and lifecycle change, keyed by the soonest position it ended):
-- current while that assignment ended `vacated` at that revision;
-- actionable while any position the same change ended in that department (same member, same end
-- time) is still unfilled, not cancelled and has not started; the recipient leads or deputises the
-- department now, is reachable in the app and is not the member.
create function app.duties_vacancy_alert_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
  v_current boolean;
begin
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  -- Review N1: current is the ended assignment at that revision; whether anything still needs
  -- cover (published, not cancelled, not started, unfilled) is for actionable.
  v_current := v_assignment.assignment_state = 'superseded'
               and v_assignment.end_reason = 'vacated'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_assignment.revision,
    'actionable', v_current and exists (
      select 1
        from app.duties_assignments g
        join app.duties_slots s on s.slot_id = g.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
       where g.member_id = v_assignment.member_id and g.end_reason = 'vacated'
         and g.ended_at = v_assignment.ended_at
         and o.department_id = v_occurrence.department_id
         and o.occurrence_state = 'published' and s.cancelled_at is null
         and app.duties_occurrence_start(o) > now()
         and not exists (select 1 from app.duties_assignments c
                          where c.slot_id = s.slot_id and c.assignment_state = 'current')),
    'recipient_eligible', v_occurrence.department_id is not null
                          and v_assignment.member_id::text is distinct from p_key ->> 'recipient_member_id'
                          and (app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                             'department_leader', v_occurrence.department_id)
                               or app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                                'department_deputy', v_occurrence.department_id))
                          and app.duties_leader_reachable((p_key ->> 'recipient_member_id')::uuid));
end;
$$;

-- (Replaced, story 4.12; copied from 20261014171038_duties_reminders.sql.) The leaders' alert
-- source `duties_coverage`: current while the assignment is current at that revision and its
-- occurrence is published; story 4.12: also while an assignment that ended `vacated` is at that
-- revision and its occurrence is published (the vacancy notice's source). Each kind's own check
-- still decides delivery.
create or replace function app.duties_coverage_source_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row record;
begin
  select a.revision, a.assignment_state, a.end_reason, o.occurrence_state into v_row
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id::text = p_source ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_row.revision = (p_source ->> 'source_revision')::numeric::bigint
               and ((v_row.assignment_state = 'current' and v_row.occurrence_state = 'published')
                    -- Story 4.12 (review N1): the vacancy notice's source, whatever the duty's state.
                    or (v_row.assignment_state = 'superseded' and v_row.end_reason = 'vacated')),
    'revision', v_row.revision);
end;
$$;

select app.contract_register_reminder_kind('duties', 'duties_coverage', 'duty_vacated');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'duty_vacated',
  'app.duties_vacancy_alert_check(jsonb)'::regprocedure,
  '{"title": "Positions need cover",
    "body": "One or more positions in your department no longer have anyone assigned. Open Coverage to find cover.",
    "link": "/duties/coverage"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Commands: remove a member from a department, resolve a department's handover
-- ---------------------------------------------------------------------------------------------

-- duties.remove_member {department_id, member_id}; expected = the department revision. Admin.
create function app.duties_remove_member(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_department_id uuid;
  v_member uuid;
  v_department app.duties_departments;
  v_result jsonb;
  v_revision bigint;
  v_cmd constant text := 'duties.remove_member';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['department_id', 'member_id']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select d.* into v_department from app.duties_departments d
   where d.department_id = v_department_id for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_department.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_department.revision);
  end if;
  if not exists (select 1 from app.duties_department_members dm
                  where dm.department_id = v_department_id and dm.member_id = v_member
                    and dm.ended_at is null) then
    perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
  end if;
  v_result := app.duties_vacate_member(v_member, v_department_id, 'removed', true,
                                       v_actor.member_id, v_actor.account_id, 'admin', v_cmd);
  update app.duties_departments d
     set revision = d.revision + 1, updated_at = now()
   where d.department_id = v_department_id
  returning d.revision into v_revision;
  perform app.duties_audit_event('member_removed', v_actor.member_id, v_actor.account_id, 'admin',
                                 v_cmd, v_department_id, null, null, v_member, null, v_revision);
  return jsonb_build_object(
    'aggregate_type', 'duties_department', 'aggregate_id', v_department_id, 'revision', v_revision,
    'data', jsonb_build_object('department_id', v_department_id, 'revision', v_revision,
                               'vacated', (v_result ->> 'vacated')::integer,
                               'drafts_cleared', (v_result ->> 'drafts_cleared')::integer,
                               'notices_skipped', (v_result ->> 'notices_skipped')::boolean));
end;
$$;

-- Pending department handovers (Duties' obligations whose subject is the department).
create function app.duties_pending_handovers(p_department_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('obligation_id', o.obligation_id,
                                               'recorded_at', app.cmd_utc(o.recorded_at))
                            order by o.recorded_at, o.obligation_id), '[]'::jsonb)
    from app.identity_handover_obligations o
   where o.owner_module = 'duties' and o.obligation_kind = 'department_leader'
     and o.subject_id = p_department_id and o.obligation_state = 'pending';
$$;

-- Does the department have a leader or deputy who is approved and reachable in the app now?
create function app.duties_has_reachable_leader(p_department_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_grants g
                  where g.revoked_at is null and g.scope_id = p_department_id
                    and g.scope_kind in ('department_leader', 'department_deputy')
                    and app.duties_member_active(g.member_id)
                    and app.duties_leader_reachable(g.member_id));
$$;

-- duties.resolve_handover {department_id}; expected = the department revision. Admin. Resolves
-- the department's pending `department_leader` obligations once it has a reachable leader or
-- deputy again.
create function app.duties_resolve_handover(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_department_id uuid;
  v_department app.duties_departments;
  v_id uuid;
  v_resolved integer := 0;
  v_revision bigint;
  v_cmd constant text := 'duties.resolve_handover';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['department_id']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Identity before Duties (AD-2): the department's leader and deputy grants stay put while we
  -- decide.
  perform 1 from app.identity_grants g
   where g.revoked_at is null and g.scope_id = v_department_id
     and g.scope_kind in ('department_leader', 'department_deputy')
   order by g.grant_id for share;
  select d.* into v_department from app.duties_departments d
   where d.department_id = v_department_id for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_department.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_department.revision);
  end if;
  if not exists (select 1 from app.identity_handover_obligations o
                  where o.owner_module = 'duties' and o.obligation_kind = 'department_leader'
                    and o.subject_id = v_department_id and o.obligation_state = 'pending') then
    perform app.cmd_fail('validation_failed', '{"department_id": "no_handover"}');
  end if;
  if not app.duties_has_reachable_leader(v_department_id) then
    perform app.cmd_fail('conflict', '{"department_id": "leader_required"}', v_department.revision);
  end if;
  for v_id in select o.obligation_id from app.identity_handover_obligations o
               where o.owner_module = 'duties' and o.obligation_kind = 'department_leader'
                 and o.subject_id = v_department_id and o.obligation_state = 'pending'
               order by o.obligation_id loop
    if app.identity_resolve_handover_obligation('duties', v_id, 'handed_over') then
      v_resolved := v_resolved + 1;
    end if;
  end loop;
  update app.duties_departments d
     set revision = d.revision + 1, updated_at = now()
   where d.department_id = v_department_id
  returning d.revision into v_revision;
  perform app.duties_audit_event('handover_resolved', v_actor.member_id, v_actor.account_id, 'admin',
                                 v_cmd, v_department_id, null, null, null, null, v_revision);
  return jsonb_build_object(
    'aggregate_type', 'duties_department', 'aggregate_id', v_department_id, 'revision', v_revision,
    'data', jsonb_build_object('department_id', v_department_id, 'revision', v_revision,
                               'resolved', v_resolved));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Review S2 (AD-2, Identity first): the members a command may notify are share-locked first
-- ---------------------------------------------------------------------------------------------

-- Key-share locks on the given Identity member rows, in member-id order. A lifecycle change holds
-- its member's row FOR UPDATE and then locks that member's duties; a command that may queue a
-- notice to that member takes this lock before any Duties row, so one waits for the other and they
-- never deadlock (Identity's own FOR UPDATE is unchanged).
create function app.duties_lock_people(p_members uuid[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- PERFORM reads every row (a SQL function's final SELECT would stop at the first one).
  perform 1 from app.identity_members m
   where m.member_id = any (p_members)
   order by m.member_id
     for key share;
end;
$$;

-- A payload value as a uuid, or null when it is not one (never an error: the handler refuses it).
create function app.duties_jsonb_uuid(p_value jsonb)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if app.contract_uuid_error(p_value) is null then
    return (p_value #>> '{}')::uuid;
  end if;
  return null;
end;
$$;

-- The members a Duties command may notify or alert, from its payload (read without locks, before
-- any Duties row): the actor, a named member, every current assignee and planned member of the
-- occurrences it names (directly, through a slot, assignment, assignments, series or review
-- flag), and the current leaders and deputies of their departments (or of a named department).
create function app.duties_command_people(p_request jsonb, p_actor uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  with pl as (
    select case when jsonb_typeof(p_request -> 'payload') = 'object' then p_request -> 'payload'
                else '{}'::jsonb end as p
  ), ids as (
    select app.duties_jsonb_uuid(pl.p -> 'occurrence_id') as occurrence_id,
           app.duties_jsonb_uuid(pl.p -> 'from_occurrence_id') as from_occurrence_id,
           app.duties_jsonb_uuid(pl.p -> 'slot_id') as slot_id,
           app.duties_jsonb_uuid(pl.p -> 'assignment_id') as assignment_id,
           app.duties_jsonb_uuid(pl.p -> 'series_id') as series_id,
           app.duties_jsonb_uuid(pl.p -> 'flag_id') as flag_id,
           app.duties_jsonb_uuid(pl.p -> 'department_id') as department_id,
           app.duties_jsonb_uuid(pl.p -> 'member_id') as member_id,
           array(select app.duties_jsonb_uuid(e -> 'assignment_id')
                   from jsonb_array_elements(case when jsonb_typeof(pl.p -> 'assignments') = 'array'
                                                  then pl.p -> 'assignments' else '[]'::jsonb end) e
                  where jsonb_typeof(e) = 'object') as assignment_ids
      from pl
  ), occ as (
    select ids.occurrence_id as o from ids
    union
    select ids.from_occurrence_id from ids
    union
    select s.occurrence_id from ids join app.duties_slots s on s.slot_id = ids.slot_id
    union
    select s.occurrence_id from ids
      join app.duties_assignments a on a.assignment_id = ids.assignment_id or a.assignment_id = any (ids.assignment_ids)
      join app.duties_slots s on s.slot_id = a.slot_id
    union
    select o.occurrence_id from ids join app.duties_occurrences o on o.series_id = ids.series_id
     where o.occurrence_state <> 'cancelled' and app.duties_occurrence_start(o) > now()
    union
    select f.occurrence_id from ids join app.duties_review_flags f on f.flag_id = ids.flag_id
  ), dep as (
    select ids.department_id as d from ids
    union
    select o.department_id from occ join app.duties_occurrences o on o.occurrence_id = occ.o
  )
  select coalesce(array_agg(distinct x.m order by x.m), '{}')
    from (
      select p_actor as m
      union all
      select ids.member_id from ids
      union all
      select a.member_id from occ
        join app.duties_slots s on s.occurrence_id = occ.o
        join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
      union all
      select s.draft_member_id from occ join app.duties_slots s on s.occurrence_id = occ.o
      union all
      select g.member_id from dep join app.identity_grants g
          on g.scope_id = dep.d and g.revoked_at is null
         and g.scope_kind in ('department_leader', 'department_deputy')) x
   where x.m is not null;
$$;

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.) Review S2: the
-- people a cell part's owner operation may notify (the actor and the current assignees of the
-- cell's duties that have not started) are share-locked before any Duties row.
create or replace function app.duties_owner_session(p_cell_id uuid, OUT member_id uuid, OUT account_id uuid,
                                         OUT capacity text)
returns record
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome is null or r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    perform app.cmd_fail('forbidden');
  end if;
  member_id := r.member_id;
  select l.auth_user_id into account_id from app.identity_account_links l
   where l.link_id = r.link_id and l.member_id = r.member_id and l.link_state = 'active';
  if account_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  capacity := 'member';
  if p_cell_id is not null then
    capacity := case
      when app.identity_member_has_scope(member_id, 'cell_leader', p_cell_id) then 'cell_leader'
      when app.identity_member_has_scope(member_id, 'cell_assistant', p_cell_id) then 'cell_assistant'
    end;
    if capacity is null then
      perform app.cmd_fail('forbidden');
    end if;
  end if;
  -- Story 4.12 review S2.
  perform app.duties_lock_people(array(
    select member_id
    union
    select a.member_id
      from app.duties_occurrences o
      join app.duties_slots s on s.occurrence_id = o.occurrence_id
      join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
     where p_cell_id is not null and o.cell_id = p_cell_id
       and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()));
end;
$$;



-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.) Review S2: the
-- members a part names are share-locked here (put_part parses them before any Duties row).
create or replace function app.duties_owner_positions(p_input jsonb, OUT errors jsonb, OUT keys text[],
                                           OUT names text[], OUT members uuid[])
returns record
language plpgsql
set search_path = ''
as $$
declare
  v_items jsonb := p_input -> 'positions';
  v_item jsonb;
  v_key text;
  v_errs jsonb;
  v_name text;
  v_member uuid;
begin
  errors := '{}'::jsonb;
  keys := '{}';
  names := '{}';
  members := '{}';
  if jsonb_typeof(v_items) is distinct from 'array' then
    errors := jsonb_build_object('positions',
                case when coalesce(jsonb_typeof(v_items), 'null') = 'null' then 'required' else 'invalid' end);
    return;
  end if;
  if jsonb_array_length(v_items) not between 1 and 10 then
    errors := '{"positions": "out_of_range"}';
    return;
  end if;
  for v_item in select x from jsonb_array_elements(v_items) x loop
    if jsonb_typeof(v_item) is distinct from 'object'
       or app.contract_unknown_keys(v_item, array['position_key', 'position_name', 'member_id']) <> '{}'::jsonb
       or app.duties_position_key_error(v_item -> 'position_key') is not null then
      errors := '{"positions": "invalid"}';
      return;
    end if;
    v_key := v_item ->> 'position_key';
    if v_key = any (keys) then
      errors := '{"positions": "duplicate"}';
      return;
    end if;
    select t.errors, t.value into v_errs, v_name
      from app.duties_text(v_item, 'position_name', false, 60, false, '{}'::jsonb) t;
    v_member := null;
    if coalesce(jsonb_typeof(v_item -> 'member_id'), 'null') <> 'null' then
      if app.contract_uuid_error(v_item -> 'member_id') is not null then
        v_errs := v_errs || '{"member_id": "invalid"}';
      else
        v_member := (v_item ->> 'member_id')::uuid;
      end if;
    end if;
    if v_errs <> '{}'::jsonb then
      errors := errors || jsonb_build_object('position:' || v_key, 'invalid');
    end if;
    keys := keys || v_key;
    names := names || v_name;
    members := members || v_member;
  end loop;
  if errors = '{}'::jsonb
     and (select count(distinct lower(n)) from unnest(names) n where n is not null)
         <> (select count(*) from unnest(names) n where n is not null) then
    errors := '{"positions": "duplicate_name"}';
  end if;
  -- Story 4.12 review S2: the members the part names, share-locked before any Duties row.
  perform app.duties_lock_people(members);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Replaced: the command entry point and authorizer (two new commands)
-- ---------------------------------------------------------------------------------------------

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.)
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
     and (g.role = 'admin' or g.scope_kind in ('department_leader', 'department_deputy'))
     for share;
  perform app.duties_lock_people(app.duties_command_people(
    jsonb_build_object('payload', nullif(pg_catalog.current_setting('duties.command_payload', true), '')::jsonb),
    r.member_id));
  return true;
end;
$$;

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.)
create or replace function app.duties_command(p_envelope jsonb)
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
  -- Story 4.12 review S2: the authorizer sees only the actor and the command, so the payload is
  -- handed to it (transaction-local, cleared after) to share-lock the members it may notify.
  perform pg_catalog.set_config('duties.command_payload',
    case when jsonb_typeof(p_envelope) = 'object' then coalesce(p_envelope -> 'payload', 'null'::jsonb)::text
         else 'null' end, true);
  v_result := app.cmd_execute(
    p_envelope,
    case v_command
      when 'duties.create_department'
        then 'app.duties_create_department(uuid, bigint, jsonb)'::regprocedure
      when 'duties.add_member' then 'app.duties_add_member(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_duty' then 'app.duties_publish_duty(uuid, bigint, jsonb)'::regprocedure
      when 'duties.respond' then 'app.duties_respond(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_duty' then 'app.duties_revise_duty(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.8: creating a series also takes the creator's reminders.
      when 'duties.create_series'
        then 'app.duties_create_series_with_reminders(uuid, bigint, jsonb)'::regprocedure
      when 'duties.assign_slot' then 'app.duties_assign_slot(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_drafts' then 'app.duties_publish_drafts(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_series' then 'app.duties_revise_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_occurrence'
        then 'app.duties_cancel_occurrence(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_series' then 'app.duties_cancel_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.withdraw_acceptance'
        then 'app.duties_withdraw_acceptance(uuid, bigint, jsonb)'::regprocedure
      when 'duties.accept_many' then 'app.duties_accept_many(uuid, bigint, jsonb)'::regprocedure
      when 'duties.set_reminders' then 'app.duties_set_reminders(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.9: the coverage work (answers are keyed to the occurrence, so a replay rechecks
      -- that the actor still manages its department).
      when 'duties.record_contact_attempt'
        then 'app.duties_record_contact_attempt(uuid, bigint, jsonb)'::regprocedure
      when 'duties.confirm_by_leader'
        then 'app.duties_confirm_by_leader(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_position'
        then 'app.duties_cancel_position(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.10: completion outcomes (keyed to the occurrence, as 4.9).
      when 'duties.record_outcome'
        then 'app.duties_record_outcome(uuid, bigint, jsonb)'::regprocedure
      when 'duties.correct_outcome'
        then 'app.duties_correct_outcome(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.11: keyed to the occurrence (a replay rechecks that the actor still manages its
      -- department); expected = the flag revision.
      when 'duties.clear_review'
        then 'app.duties_clear_review(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.12: keyed to the department (a replay rechecks that the actor is still an Admin);
      -- expected = the department revision.
      when 'duties.remove_member'
        then 'app.duties_remove_member(uuid, bigint, jsonb)'::regprocedure
      when 'duties.resolve_handover'
        then 'app.duties_resolve_handover(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
      and v_command is distinct from 'duties.accept_many'
  );
  perform pg_catalog.set_config('duties.command_payload', '', true);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Replaced reads: the Admin's department view, Needs contact, the coverage queue
-- ---------------------------------------------------------------------------------------------

-- (Replaced, story 4.12; copied from 20261013220239_duties_department_tracer.sql.) Story 4.12:
-- `handovers` (the department's pending handover obligations: ids and times only) and
-- `needs_leader` (no approved leader or deputy the app can reach).
create or replace function app.duties_department_json(p_department_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'department_id', d.department_id,
    'name', d.name,
    'department_state', d.department_state,
    'is_synthetic', d.is_synthetic,
    'revision', d.revision,
    'leaders', app.duties_staff_list(d.department_id, 'department_leader'),
    'deputies', app.duties_staff_list(d.department_id, 'department_deputy'),
    'members', app.duties_roster(d.department_id, true),
    -- Story 4.12.
    'handovers', app.duties_pending_handovers(d.department_id),
    'needs_leader', not app.duties_has_reachable_leader(d.department_id))
    from app.duties_departments d
   where d.department_id = p_department_id;
$$;

-- (Replaced, story 4.12; copied from 20261014171038_duties_reminders.sql.) Story 4.12: a hold's
-- `access_hold` entry counts as `not_reached` while the member is not declined and still cannot be
-- reached in the app (a released hold clears it).
create or replace function app.duties_needs_contact(p_assignment app.duties_assignments,
                                                    p_occurrence app.duties_occurrences)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when x.reasons <> '{}' then jsonb_build_object(
                'reasons', to_jsonb(x.reasons), 'since', app.cmd_utc(x.since)) end
    from (
      select array_remove(array[
               case when p_assignment.short_notice and p_assignment.response = 'pending'
                    then 'short_notice' end,
               case when n.first_at is not null then 'not_reached' end], null) as reasons,
             least(case when p_assignment.short_notice and p_assignment.response = 'pending'
                        then p_assignment.assigned_at end, n.first_at) as since
        from (select min(c.recorded_at) as first_at
                from app.duties_contact_needs c
               where c.assignment_id = p_assignment.assignment_id
                 and c.source_revision = p_assignment.revision
                 and ((c.reminder_kind in ('duty_assigned', 'duty_changed', 'duty_response_due')
                       and p_assignment.response = 'pending')
                      or (c.reminder_kind in ('duty_starting', 'duty_updated')
                          and p_assignment.response <> 'declined')
                      -- Story 4.12.
                      or (c.reminder_kind = 'access_hold' and p_assignment.response <> 'declined'
                          and not app.duties_leader_reachable(p_assignment.member_id)))) n
       where p_assignment.assignment_state = 'current'
         and p_occurrence.occurrence_state = 'published'
         and app.duties_occurrence_start(p_occurrence) > now()) x;
$$;

-- (Replaced, story 4.12; copied from 20261014212507_duties_coverage.sql.) Story 4.12: an unfilled
-- position left by a member who could no longer serve carries `vacated: {since}`, and each
-- department counts them (`vacated`). Never why.
create or replace function app.duties_coverage(p_from date, p_to date, p_department_id uuid, p_duty text)
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
  v_zone text;
  v_today date;
  v_from date;
  v_to date;
  v_lo timestamptz;
  v_hi timestamptz;
  v_duty text := nullif(btrim(coalesce(p_duty, '')), '');
  v_departments uuid[];
  v_counts jsonb;
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
  begin
    v_zone := app.policy_effective('q2_church_time') -> 'value' ->> 'zone';
  exception when sqlstate 'PCMD1' then
    v_zone := null;
  end;
  if v_zone is null or not app.notifications_zone_known(v_zone) then
    -- Church time is Africa/Lusaka (owner decision Q2) when no valid policy zone is in force.
    v_zone := 'Africa/Lusaka';
  end if;
  v_today := (now() at time zone v_zone)::date;
  v_from := coalesce(p_from, v_today);
  v_to := coalesce(p_to, v_from + 6);
  if v_to < v_from or v_to - v_from > 30 or v_from < v_today - 1 or v_from > v_today + 731 then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
  end if;
  if v_duty is not null and (length(v_duty) > 80 or v_duty ~ '[[:cntrl:]]') then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'duty';
  end if;
  v_lo := v_from::timestamp at time zone v_zone;
  v_hi := (v_to + 1)::timestamp at time zone v_zone;
  -- The departments the caller may see: those they lead or deputise, every department for an
  -- Admin (who may manage) and for Pastor oversight. Synthetic departments only in local/staging.
  select coalesce(array_agg(d.department_id), '{}') into v_departments
    from app.duties_departments d
   where (p_department_id is null or d.department_id = p_department_id)
     and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
     and (v_pastor or app.duties_manage_capacity(v_member, d.department_id) is not null);
  if p_department_id is not null and cardinality(v_departments) = 0 then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  -- The window's overlap counts, computed once (set-based, 4.4).
  v_counts := app.duties_overlap_counts(array(
    select o.occurrence_id from app.duties_occurrences o
     where o.department_id = any (v_departments) and o.occurrence_state = 'published'
       and o.starts_at >= v_lo and o.starts_at < v_hi and app.duties_occurrence_start(o) > now()));

  with cd as (
    -- How the caller sees each department: `full` for its leaders and deputies (scope_kind set),
    -- `operational` for Admin (role alone) and Pastor.
    select d.department_id, d.name,
           case when app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
                  then 'department_leader'
                when app.identity_member_has_scope(v_member, 'department_deputy', d.department_id)
                  then 'department_deputy' end as scope_kind,
           app.duties_manage_capacity(v_member, d.department_id) is not null as can_manage
      from app.duties_departments d
     where d.department_id = any (v_departments)
  ), base as (
    -- Review N5: every position's state (for the counts); the JSON is built below only for the
    -- positions listed (rn <= 1000).
    select o.department_id, o.occurrence_id, o.starts_at, s.slot_id, s.position_no,
           a.assignment_id, a.member_id, c.case_id, l.attempt_id, cd.scope_kind, x.status,
           x.needs_contact, coalesce((v_counts ->> s.slot_id::text)::integer, 0) as overlaps,
           c.case_id is not null and l.next_follow_up_at <= now() as follow_up_overdue,
           -- Story 4.12: when the member who held the position could no longer serve.
           x.vacated_since,
           row_number() over (order by o.starts_at, o.occurrence_id, s.position_no) as rn
      from cd
      join app.duties_occurrences o on o.department_id = cd.department_id
      join app.duties_slots s on s.occurrence_id = o.occurrence_id and s.cancelled_at is null
      left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
      left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
      left join app.duties_coverage_cases c on c.assignment_id = a.assignment_id and c.closed_at is null
      left join lateral (select t.* from app.duties_contact_attempts t where t.case_id = c.case_id
                          order by t.recorded_at desc, t.attempt_id limit 1) l on true
      cross join lateral (select
          case when a.assignment_id is null then 'unfilled'
               when a.response = 'accepted' then 'confirmed'
               when a.response = 'declined' then 'declined'
               when a.response_deadline <= now() then 'overdue'
               when p.member_id = a.member_id then 'changed'
               else 'awaiting' end as status,
          case when a.assignment_id is not null then app.duties_needs_contact(a, o) end as needs_contact,
          case when a.assignment_id is null then app.duties_vacated_since(s.slot_id) end as vacated_since) x
     where o.occurrence_state = 'published' and o.starts_at >= v_lo and o.starts_at < v_hi
       and app.duties_occurrence_start(o) > now()
       and (v_duty is null or position(lower(v_duty) in lower(o.duty_name)) > 0)
  ), pos as (
    select b.department_id, b.member_id, b.status, b.rn,
           jsonb_build_object(
             'slot_id', s.slot_id,
             'position_no', s.position_no,
             'position_name', s.position_name,
             'occurrence_id', o.occurrence_id,
             'occurrence_revision', o.revision,
             'series_id', o.series_id,
             'duty_name', o.duty_name,
             'starts_at', app.cmd_utc(o.starts_at),
             'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
             'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
             'location', o.location,
             'positions_left', (select count(*) from app.duties_slots s2
                                 where s2.occurrence_id = o.occurrence_id and s2.cancelled_at is null),
             'status', b.status,
             'needs_contact', b.needs_contact,
             -- Story 4.12.
             'vacated', case when b.vacated_since is not null
                             then jsonb_build_object('since', app.cmd_utc(b.vacated_since)) end,
             'overlaps', coalesce((v_counts ->> s.slot_id::text)::integer, 0),
             'assignment', case when a.assignment_id is not null then jsonb_build_object(
               'assignment_id', a.assignment_id,
               'revision', a.revision,
               'member_id', a.member_id,
               'display_name', app.duties_display_name(a.member_id),
               'account', case when app.identity_member_account_label(a.member_id) = 'no_login'
                               then 'no_login' else 'app_account' end,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'response_deadline', app.cmd_utc(a.response_deadline),
               'deadline_source', a.deadline_source,
               'short_notice', a.short_notice,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               'prior_accepted_at', case when a.prior_accepted_at is not null
                                         then app.cmd_utc(a.prior_accepted_at) end,
               'note', case when b.scope_kind is not null then a.response_note end,
               'confirmation', case when a.response_provenance = 'leader' then jsonb_build_object(
                                 'by', app.duties_display_name(a.responded_by_member),
                                 'at', app.cmd_utc(a.responded_at),
                                 'channel', a.confirmed_channel,
                                 'reason', case when b.scope_kind is not null then a.confirmed_reason end) end,
               'changes', case when b.status = 'changed'
                               then to_jsonb(app.duties_changes_since(s.slot_id, a.slot_revision - 1,
                                                                       a.slot_revision)) end) end,
             'follow_up', case when c.case_id is not null then jsonb_build_object(
               'case_id', c.case_id,
               'task_id', case when b.scope_kind is not null then c.task_id end,
               'opened_at', app.cmd_utc(c.opened_at),
               'attempts', (select count(*) from app.duties_contact_attempts t where t.case_id = c.case_id),
               'next_follow_up_at', app.cmd_utc(l.next_follow_up_at),
               'overdue', l.next_follow_up_at <= now(),
               'last_attempt', jsonb_build_object(
                 'at', app.cmd_utc(l.recorded_at),
                 'by', app.duties_display_name(l.recorded_by_member),
                 'channel', l.channel,
                 'outcome', l.outcome,
                 'note', case when b.scope_kind is not null then l.note end)) end) as obj
      from base b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      join app.duties_slots s on s.slot_id = b.slot_id
      left join app.duties_assignments a on a.assignment_id = b.assignment_id
      left join app.duties_coverage_cases c on c.case_id = b.case_id
      left join app.duties_contact_attempts l on l.attempt_id = b.attempt_id
     where b.rn <= 1000
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', to_char(v_from, 'YYYY-MM-DD'), 'to', to_char(v_to, 'YYYY-MM-DD'),
                                 'zone', v_zone),
    'duty', v_duty,
    -- At most 1000 positions are listed (soonest first); the counts always cover every one.
    'truncated', (select count(*) > 1000 from base),
    'departments', coalesce((
      select jsonb_agg(jsonb_build_object(
          'department_id', cd.department_id,
          'name', cd.name,
          'view', case when cd.scope_kind is not null then 'full' else 'operational' end,
          'can_manage', cd.can_manage,
          'can_contact', cd.scope_kind is not null,
          'members', case when cd.can_manage then app.duties_roster(cd.department_id, false)
                          else '[]'::jsonb end,
          'counts', (select jsonb_build_object(
                       'required', count(*),
                       'confirmed', count(*) filter (where r.status = 'confirmed'),
                       'unfilled', count(*) filter (where r.status = 'unfilled'),
                       -- Review N8: `changed` counts once, under declined or changed.
                       'awaiting', count(*) filter (where r.status = 'awaiting'),
                       'overdue', count(*) filter (where r.status = 'overdue'),
                       'declined', count(*) filter (where r.status in ('declined', 'changed')),
                       'needs_contact', count(*) filter (where r.needs_contact is not null),
                       'conflicts', count(*) filter (where r.overlaps > 0 and r.status <> 'unfilled'),
                       'overdue_follow_ups', count(*) filter (where r.follow_up_overdue),
                       -- Story 4.12: unfilled positions left by a member who could no longer serve.
                       'vacated', count(*) filter (where r.vacated_since is not null))
                       from base r where r.department_id = cd.department_id),
          -- Contact routes through the scoped Identity read: the department's leaders and
          -- deputies only, for members whose position is not yet confirmed.
          'contact_routes', case when cd.scope_kind is not null then
              app.identity_scoped_contact_routes(v_member, cd.scope_kind, cd.department_id, array(
                select distinct r.member_id from base r
                 where r.department_id = cd.department_id and r.member_id is not null
                   and r.status <> 'confirmed' and r.rn <= 1000))
            else '{}'::jsonb end,
          'positions', coalesce((
            select jsonb_agg(r.obj order by r.rn) from pos r
             where r.department_id = cd.department_id and r.rn <= 1000), '[]'::jsonb))
        order by cd.name, cd.department_id)
        from cd), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Replaced: the Duties deletion hook (who ended a membership)
-- ---------------------------------------------------------------------------------------------

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql.) Story 4.12:
-- department memberships the member (or the account) ended.
create or replace function app.duties_deletion_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.duties_department_members dm
            where dm.member_id = p_member_id or dm.added_by_member = p_member_id
               or dm.added_by_account = p_account_id
               -- Story 4.12.
               or dm.ended_by_member = p_member_id or dm.ended_by_account = p_account_id)
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
               or s.draft_override_by_account = p_account_id
               or s.cancelled_by_member = p_member_id or s.cancelled_by_account = p_account_id)
        + (select count(*) from app.duties_slot_revisions r
            where r.member_id = p_member_id or r.created_by_member = p_member_id
               or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_audit au
            where au.actor_member_id = p_member_id or au.member_id = p_member_id
               or au.actor_account_id = p_account_id)
        -- Story 4.9.
        + (select count(*) from app.duties_coverage_cases c
            where c.opened_by_member = p_member_id or c.opened_by_account = p_account_id)
        + (select count(*) from app.duties_contact_attempts t
            where t.recorded_by_member = p_member_id or t.recorded_by_account = p_account_id)
        -- Story 4.10: outcomes they recorded, and text about their own duties.
        + (select count(*) from app.duties_outcomes x
            where x.recorded_by_member = p_member_id or x.recorded_by_account = p_account_id)
        + (select count(*) from app.duties_outcomes x
             join app.duties_assignments a on a.assignment_id = x.assignment_id
            where a.member_id = p_member_id
              and (x.note is not null or x.correction_reason is not null))
        -- Story 4.11: links they made or ended, and owner-review flags they raised or cleared.
        + (select count(*) from app.duties_part_links l
            where l.linked_by_member = p_member_id or l.linked_by_account = p_account_id
               or l.ended_by_member = p_member_id or l.ended_by_account = p_account_id)
        + (select count(*) from app.duties_review_flags f
            where f.flagged_by_member = p_member_id or f.flagged_by_account = p_account_id
               or f.cleared_by_member = p_member_id or f.cleared_by_account = p_account_id))::integer;
$$;

-- (Replaced, story 4.12; copied from 20261015035112_duties_owner_operations.sql, the 4.10 review S1
-- lock order kept.) Story 4.12: who ended another member's department membership is anonymised.
create or replace function app.duties_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_assignments uuid[];
begin
  if p_input ->> 'phase' = 'erase' then
    -- Review S1 (story 4.10): lock first, in the commands' AD-2 order (departments, series,
    -- occurrences, then assignments, FOR UPDATE), so an outcome or contact attempt in flight
    -- either commits before the text below is cleared or waits and then sees the member erased.
    perform 1 from app.duties_departments d where d.created_by_member = v_member
     order by d.department_id for update;
    perform 1 from app.duties_series r where r.created_by_member = v_member
     order by r.series_id for update;
    perform 1 from app.duties_occurrences o
     where o.created_by_member = v_member
        or o.occurrence_id in (select s.occurrence_id from app.duties_assignments a
                                 join app.duties_slots s on s.slot_id = a.slot_id
                                where a.member_id = v_member)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
       for update;
    select coalesce(array_agg(x.assignment_id), '{}') into v_assignments
      from (select a.assignment_id from app.duties_assignments a
             where a.member_id = v_member order by a.assignment_id for update) x;
    perform app.duties_deletion_purge_rows(v_member);
    update app.duties_department_members dm set added_by_member = v_nil
     where dm.added_by_member = v_member;
    -- Story 4.12: who removed another member from a department.
    update app.duties_department_members dm set ended_by_member = v_nil
     where dm.ended_by_member = v_member;
    -- Story 4.9: the leaders' practical notes about the erased assignee go with them (before the
    -- assignee is anonymised below).
    update app.duties_contact_attempts t set note = null
     where t.note is not null and t.assignment_id = any (v_assignments);
    -- Story 4.10: the outcome notes and correction reasons about the erased assignee go with them
    -- (the outcome values stay, attached to the anonymised assignment).
    update app.duties_outcomes x set note = null, correction_reason = null
     where (x.note is not null or x.correction_reason is not null)
       and x.assignment_id = any (v_assignments);
    -- The leader's words about the erased assignee go with them (stories 4.4, 4.9).
    update app.duties_assignments a set member_id = v_nil, response_note = null, override_reason = null,
                                        confirmed_reason = null
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
    update app.duties_slots s set cancelled_by_member = v_nil where s.cancelled_by_member = v_member;
    update app.duties_slot_revisions r set member_id = v_nil where r.member_id = v_member;
    update app.duties_slot_revisions r set created_by_member = v_nil
     where r.created_by_member = v_member;
    update app.duties_audit au set actor_member_id = v_nil where au.actor_member_id = v_member;
    update app.duties_audit au set member_id = v_nil where au.member_id = v_member;
    update app.duties_coverage_cases c set opened_by_member = v_nil where c.opened_by_member = v_member;
    update app.duties_contact_attempts t set recorded_by_member = v_nil
     where t.recorded_by_member = v_member;
    update app.duties_outcomes x set recorded_by_member = v_nil where x.recorded_by_member = v_member;
    -- Story 4.11: who linked or unlinked a part position, and who raised or cleared a review.
    update app.duties_part_links l set linked_by_member = v_nil where l.linked_by_member = v_member;
    update app.duties_part_links l set ended_by_member = v_nil where l.ended_by_member = v_member;
    update app.duties_review_flags f set flagged_by_member = v_nil where f.flagged_by_member = v_member;
    update app.duties_review_flags f set cleared_by_member = v_nil where f.cleared_by_member = v_member;
    if v_account is not null then
      update app.duties_department_members dm set added_by_account = v_nil
       where dm.added_by_account = v_account;
      -- Story 4.12.
      update app.duties_department_members dm set ended_by_account = v_nil
       where dm.ended_by_account = v_account;
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
      update app.duties_slots s set cancelled_by_account = v_nil
       where s.cancelled_by_account = v_account;
      update app.duties_slot_revisions r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
      update app.duties_coverage_cases c set opened_by_account = v_nil
       where c.opened_by_account = v_account;
      update app.duties_contact_attempts t set recorded_by_account = v_nil
       where t.recorded_by_account = v_account;
      update app.duties_outcomes x set recorded_by_account = v_nil
       where x.recorded_by_account = v_account;
      -- Story 4.11.
      update app.duties_part_links l set linked_by_account = v_nil
       where l.linked_by_account = v_account;
      update app.duties_part_links l set ended_by_account = v_nil
       where l.ended_by_account = v_account;
      update app.duties_review_flags f set flagged_by_account = v_nil
       where f.flagged_by_account = v_account;
      update app.duties_review_flags f set cleared_by_account = v_nil
       where f.cleared_by_account = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1-4.12): erase or check the member''s Duties personal data.';

-- ---------------------------------------------------------------------------------------------
-- Follow-ups: handover of open tasks and supervision (Q4 owner-scope rule), set-based
-- ---------------------------------------------------------------------------------------------

-- Can Notifications reach the member in the app now (a live, reviewed link, no hold)?
create function app.followups_reachable(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select r.route = 'member' from app.notifications_recipient_route(p_member_id) r), false);
$$;

-- The handover plan for every active task p_member owns or supervises, computed set-based (one
-- roster per distinct scope, reachability once per person):
--   owner_due        the member must stop owning it (p_leaving: deactivation or deletion; else
--                    they are no longer in the task's group);
--   owner_to         the first candidate of owner decision Q4 (the task's own group or a current
--                    Pastor) the app can reach (review S3): its supervisor (holding the task's
--                    scope), then another holder of its scope (the purpose's kinds in order), then
--                    a Pastor, then another member of its group; null = nobody may take it;
--   supervisor_due   the member must stop supervising it (p_leaving, or they no longer hold its
--                    scope), or its supervisor becomes its owner (review N3);
--   supervisor_to    another active holder of its scope (reachable first), else the final owner
--                    when they hold the scope (self-supervision, the 4.9 fallback); null = nobody.
create function app.followups_handover_plan(p_member uuid, p_leaving boolean)
returns table (task_id uuid, owner_from uuid, owner_to uuid, owner_due boolean,
               supervisor_from uuid, supervisor_to uuid, supervisor_due boolean, sort_at timestamptz)
language plpgsql
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_rosters jsonb := '{}'::jsonb;
  v_reach jsonb;
  v_scope record;
begin
  for v_scope in
    select distinct t.scope_kind, t.scope_id from app.followups_tasks t
     where (t.owner_member_id = p_member or t.supervisor_member_id = p_member)
       and app.followups_state_ok('active_state', t.task_state)
  loop
    v_rosters := v_rosters || jsonb_build_object(v_scope.scope_kind || '|' || v_scope.scope_id,
                   to_jsonb(app.followups_scope_roster(v_scope.scope_kind, v_scope.scope_id)));
  end loop;
  select coalesce(jsonb_object_agg(y.m::text, app.followups_reachable(y.m)), '{}'::jsonb) into v_reach
    from (select distinct (e #>> '{}')::uuid as m
            from jsonb_each(v_rosters) r, jsonb_array_elements(r.value) e) y;
  -- The candidates depend only on the task's owner, supervisor, scope and purpose, so they are
  -- chosen once per distinct combination (usually a handful) and joined back to the tasks.
  return query
  with t as materialized (
    select g.owner_member_id, g.supervisor_member_id, g.scope_kind, g.scope_id, g.source_type, g.purpose,
           app.followups_purpose_kinds(g.source_type, g.purpose) as kinds,
           array(select (e #>> '{}')::uuid
                   from jsonb_array_elements(v_rosters -> (g.scope_kind || '|' || g.scope_id)) e) as roster
      from (select distinct t.owner_member_id, t.supervisor_member_id, t.scope_kind, t.scope_id,
                            t.source_type, t.purpose
              from app.followups_tasks t
             where (t.owner_member_id = p_member or t.supervisor_member_id = p_member)
               and app.followups_state_ok('active_state', t.task_state)) g
  ), o as (
    select t.*,
           t.owner_member_id = p_member
             and (p_leaving or not (p_member = any (t.roster))) as o_due,
           t.supervisor_member_id = p_member
             and (p_leaving or not app.followups_member_holds(p_member, t.scope_kind, t.scope_id, t.kinds))
             as s_gone
      from t
  ), c as (
    select o.*,
           case when o.o_due then (
             select x.m from (
               select o.supervisor_member_id as m, 0 as tier, 0 as k, null::timestamptz as g
                where o.supervisor_member_id <> p_member and o.supervisor_member_id = any (o.roster)
                  and app.followups_member_holds(o.supervisor_member_id, o.scope_kind, o.scope_id, o.kinds)
               union all
               select gr.member_id, 1, array_position(o.kinds, gr.scope_kind), gr.granted_at
                 from app.identity_grants gr
                where gr.revoked_at is null and gr.scope_id = o.scope_id and gr.scope_kind = any (o.kinds)
                  and app.followups_family(gr.scope_kind) = app.followups_family(o.scope_kind)
                  and gr.member_id <> p_member and gr.member_id = any (o.roster)
               union all
               select gr.member_id, 2, 0, gr.granted_at
                 from app.identity_grants gr
                where gr.revoked_at is null and gr.role = 'pastor' and gr.member_id <> p_member
                  and gr.member_id = any (o.roster)
               union all
               select r.m, 3, 0, null::timestamptz from unnest(o.roster) r(m) where r.m <> p_member) x
              where coalesce((v_reach ->> x.m::text)::boolean, false)
              order by x.tier, x.k, x.g nulls last, x.m
              limit 1) end as o_to
      from o
  ), s as (
    select c.*,
           coalesce(case when c.o_due then c.o_to end, c.owner_member_id) as o_final
      from c
  ), pl as materialized (
    select s.*,
           s.s_gone or (s.o_due and s.o_to = s.supervisor_member_id) as s_due,
           case when s.s_gone or (s.o_due and s.o_to = s.supervisor_member_id) then (
             select y.m from (
               select gr.member_id as m, 0 as tier,
                      coalesce((v_reach ->> gr.member_id::text)::boolean, app.followups_reachable(gr.member_id)) as reach,
                      array_position(s.kinds, gr.scope_kind) as k, gr.granted_at as g
                 from app.identity_grants gr
                where gr.revoked_at is null and gr.scope_id = s.scope_id and gr.scope_kind = any (s.kinds)
                  and app.followups_family(gr.scope_kind) = app.followups_family(s.scope_kind)
                  and gr.member_id <> p_member and gr.member_id <> s.o_final
                  and app.followups_member_active(gr.member_id)
               union all
               select s.o_final, 1, true, 0, null::timestamptz
                where s.o_final <> p_member
                  and app.followups_member_holds(s.o_final, s.scope_kind, s.scope_id, s.kinds)) y
              order by y.tier, y.reach desc, y.k, y.g nulls last, y.m
              limit 1) end as s_to
      from s
  )
  select tk.task_id, tk.owner_member_id, pl.o_to, pl.o_due, tk.supervisor_member_id, pl.s_to, pl.s_due,
         coalesce(tk.review_at, tk.due_at)
    from app.followups_tasks tk
    join pl on pl.owner_member_id = tk.owner_member_id
           and pl.supervisor_member_id is not distinct from tk.supervisor_member_id
           and pl.scope_kind = tk.scope_kind and pl.scope_id = tk.scope_id
           and pl.source_type = tk.source_type and pl.purpose = tk.purpose
   where (tk.owner_member_id = p_member or tk.supervisor_member_id = p_member)
     and app.followups_state_ok('active_state', tk.task_state);
end;
$$;

-- Hands over at most p_limit tasks of the plan (soonest due or review date first), set-based: one
-- update of owners and supervisors (a new schedule revision: fresh logical keys), one insert per
-- activity kind (capacity `source`, no person, code `handover`), then per task the old recipients'
-- reminders are cancelled and the task's reminders planned again (the Notifications API is per
-- task; with the Q2 policy unavailable they are skipped and recorded `reminders_skipped`).
-- Tasks left over keep their owner and supervisor (their handover obligations stay pending,
-- visible to Admin; `followups.complete_handover` continues). Answers {handed_over, remaining}.
create function app.followups_handover_member(p_member uuid, p_leaving boolean, p_limit integer)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_rows jsonb;
  v_sel jsonb;
  v_changed jsonb;
  v_total integer;
  v_done integer := 0;
  v_task jsonb;
  v_ready boolean;
  v_try integer;
begin
  -- Review S5: the people chosen are share-locked (member-id order) and checked again; a person
  -- deactivated or put on hold meanwhile (the lock waited for that change) makes the plan be
  -- computed again; after three tries the rows naming such a person are left for later.
  for v_try in 1 .. 3 loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'task_id', p.task_id,
             'owner_from', p.owner_from,
             'owner_to', case when p.owner_due then p.owner_to end,
             'supervisor_from', p.supervisor_from,
             'supervisor_to', case when p.supervisor_due and p.supervisor_to <> p.supervisor_from
                                   then p.supervisor_to end)
             order by p.sort_at, p.task_id), '[]'::jsonb)
      into v_rows
      from app.followups_handover_plan(p_member, p_leaving) p
     where (p.owner_due and p.owner_to is not null)
        or (p.supervisor_due and p.supervisor_to is not null and p.supervisor_to <> p.supervisor_from);
    v_total := jsonb_array_length(v_rows);
    if v_total = 0 then
      return '{"handed_over": 0, "remaining": 0}'::jsonb;
    end if;
    select coalesce(jsonb_agg(r.x order by r.n), '[]'::jsonb) into v_sel
      from jsonb_array_elements(v_rows) with ordinality as r(x, n)
     where r.n <= p_limit;
    perform app.followups_lock_people(array(
      select distinct (x ->> k)::uuid from jsonb_array_elements(v_sel) x,
             unnest(array['owner_to', 'supervisor_to']) k
       where x ->> k is not null));
    exit when not exists (
      select 1 from jsonb_array_elements(v_sel) x
       where (x ->> 'owner_to' is not null
              and not (app.followups_member_active((x ->> 'owner_to')::uuid)
                       and app.followups_reachable((x ->> 'owner_to')::uuid)))
          or (x ->> 'supervisor_to' is not null
              and not app.followups_member_active((x ->> 'supervisor_to')::uuid)));
    if v_try = 3 then
      select coalesce(jsonb_agg(x order by n), '[]'::jsonb) into v_sel
        from jsonb_array_elements(v_sel) with ordinality as r(x, n)
       where (x ->> 'owner_to' is null
              or (app.followups_member_active((x ->> 'owner_to')::uuid)
                  and app.followups_reachable((x ->> 'owner_to')::uuid)))
         and (x ->> 'supervisor_to' is null
              or app.followups_member_active((x ->> 'supervisor_to')::uuid));
    end if;
  end loop;
  -- Identity before Follow-ups (AD-2): a Pastor chosen as owner keeps their grant meanwhile.
  perform 1 from app.identity_grants g
   where g.member_id in (select (x ->> 'owner_to')::uuid from jsonb_array_elements(v_sel) x)
     and g.role = 'pastor' and g.revoked_at is null
   order by g.grant_id for share;
  perform 1 from app.followups_tasks t
   where t.task_id in (select (x ->> 'task_id')::uuid from jsonb_array_elements(v_sel) x)
   order by t.task_id for update;
  -- One update; only what is still as planned changes (a concurrent command may have moved it).
  with w as (
    select (x ->> 'task_id')::uuid as task_id, (x ->> 'owner_from')::uuid as owner_from,
           (x ->> 'owner_to')::uuid as owner_to, (x ->> 'supervisor_from')::uuid as supervisor_from,
           (x ->> 'supervisor_to')::uuid as supervisor_to
      from jsonb_array_elements(v_sel) x
  ), u as (
    update app.followups_tasks t
       set owner_member_id = coalesce(w.owner_to, t.owner_member_id),
           supervisor_member_id = coalesce(w.supervisor_to, t.supervisor_member_id),
           schedule_revision = t.schedule_revision + 1,
           revision = t.revision + 1, updated_at = now()
      from w
     where t.task_id = w.task_id and app.followups_state_ok('active_state', t.task_state)
       and t.owner_member_id = w.owner_from and t.supervisor_member_id = w.supervisor_from
    returning t.task_id, t.revision)
  select coalesce(jsonb_agg(jsonb_build_object(
           'task_id', w.task_id, 'owner_from', w.owner_from, 'owner_to', w.owner_to,
           'supervisor_from', w.supervisor_from, 'supervisor_to', w.supervisor_to,
           'revision', u.revision) order by w.task_id), '[]'::jsonb)
    into v_changed
    from u join w on w.task_id = u.task_id;
  -- One insert for the content-free activity (capacity `source`, no person, code `handover`).
  insert into app.followups_activity (task_id, action, actor_capacity, from_member, to_member, code,
                                      revision_after)
  select (x ->> 'task_id')::uuid, 'reassigned', 'source', (x ->> 'owner_from')::uuid,
         (x ->> 'owner_to')::uuid, 'handover', (x ->> 'revision')::bigint
    from jsonb_array_elements(v_changed) x where x ->> 'owner_to' is not null
  union all
  select (x ->> 'task_id')::uuid, 'supervisor_changed', 'source', (x ->> 'supervisor_from')::uuid,
         (x ->> 'supervisor_to')::uuid, 'handover', (x ->> 'revision')::bigint
    from jsonb_array_elements(v_changed) x where x ->> 'supervisor_to' is not null;
  -- Notifications last: the Notifications API cancels and plans per task.
  v_ready := app.followups_reminders_ready();
  for v_task in select x from jsonb_array_elements(v_changed) x loop
    if v_task ->> 'owner_to' is not null then
      perform app.followups_cancel_reminders((v_task ->> 'task_id')::uuid, 'followups_task',
                                             (v_task ->> 'owner_from')::uuid, 'reassigned');
    end if;
    if v_task ->> 'supervisor_to' is not null then
      perform app.followups_cancel_reminders((v_task ->> 'task_id')::uuid, 'followups_supervision',
                                             (v_task ->> 'supervisor_from')::uuid, 'supervisor_changed');
    end if;
    if v_ready then
      perform app.followups_schedule_reminders((v_task ->> 'task_id')::uuid,
                                               v_task ->> 'owner_to' is not null, null);
    end if;
    v_done := v_done + 1;
  end loop;
  if not v_ready then
    insert into app.followups_activity (task_id, action, actor_capacity, code, revision_after)
    select (x ->> 'task_id')::uuid, 'reminders_skipped', 'source', 'policy_unavailable',
           (x ->> 'revision')::bigint
      from jsonb_array_elements(v_changed) x;
  end if;
  return jsonb_build_object('handed_over', v_done, 'remaining', v_total - v_done);
end;
$$;

-- Obligations of the member that need nothing more (the task finished, or the person was already
-- replaced) are resolved.
create function app.followups_resolve_obligations(p_member uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_o record;
  v_count integer := 0;
begin
  for v_o in
    select o.obligation_id,
           t.task_id is null or not app.followups_state_ok('active_state', t.task_state) as gone,
           case o.obligation_kind
             when 'followup_task' then t.owner_member_id <> p_member
             else t.supervisor_member_id <> p_member end as handed
      from app.identity_handover_obligations o
      left join app.followups_tasks t on t.task_id = o.subject_id
     where o.member_id = p_member and o.owner_module = 'followups'
       and o.obligation_kind in ('followup_task', 'followup_supervision')
       and o.obligation_state = 'pending'
     order by o.obligation_id
  loop
    if v_o.gone then
      perform app.identity_resolve_handover_obligation('followups', v_o.obligation_id, 'no_longer_needed');
      v_count := v_count + 1;
    elsif v_o.handed then
      perform app.identity_resolve_handover_obligation('followups', v_o.obligation_id, 'handed_over');
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- Runs inside Identity's lifecycle transaction (after Duties, before Notifications). Review S1: at
-- most 25 tasks are handed over per lifecycle change of a member (one budget for the transaction,
-- shared by the change's events, e.g. a deactivation and the scope revocations it causes): the
-- Notifications API cancels and plans a task's reminders per task, about 15-20 ms each. The rest
-- keep their pending handover obligations, visible to Admin, and `followups.complete_handover`
-- continues (100 per step).
create function app.followups_on_member_lifecycle(p_event jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_event ->> 'member_id')::uuid;
  v_setting text := current_setting('followups.handover_budget', true);
  v_budget integer := 25;
  v_result jsonb;
  v_task uuid;
begin
  if v_setting like v_member::text || ':%' then
    v_budget := split_part(v_setting, ':', 2)::integer;
  end if;
  if v_budget > 0 and p_event ->> 'event' in ('membership_deactivated', 'deletion_requested', 'scope_revoked') then
    v_result := app.followups_handover_member(v_member, p_event ->> 'event' <> 'scope_revoked', v_budget);
    v_budget := v_budget - (v_result ->> 'handed_over')::integer;
    perform set_config('followups.handover_budget', v_member::text || ':' || v_budget::text, true);
  end if;
  -- Review N12: a member who left gets no more reminders for the tasks still waiting for a new
  -- owner or supervisor (they are planned again for whoever takes them over).
  if p_event ->> 'event' in ('membership_deactivated', 'deletion_requested') then
    for v_task in
      select t.task_id from app.followups_tasks t
       where t.owner_member_id = v_member and app.followups_state_ok('active_state', t.task_state)
       order by t.task_id
    loop
      perform app.followups_cancel_reminders(v_task, 'followups_task', v_member, 'owner_inactive');
    end loop;
    for v_task in
      select t.task_id from app.followups_tasks t
       where t.supervisor_member_id = v_member and app.followups_state_ok('active_state', t.task_state)
       order by t.task_id
    loop
      perform app.followups_cancel_reminders(v_task, 'followups_supervision', v_member,
                                             'no_supervisor_alert');
    end loop;
  end if;
  perform app.followups_resolve_obligations(v_member);
end;
$$;

comment on function app.followups_on_member_lifecycle(jsonb) is
  'Follow-ups lifecycle hook (story 4.12): hand open tasks and supervision over under the Q4 '
  'owner-scope rule when the member leaves or loses the task''s scope (at most 25 per change).';

select app.contract_register_lifecycle_hook('followups', e,
         'app.followups_on_member_lifecycle(jsonb)'::regprocedure)
  from unnest(array['membership_deactivated', 'deletion_requested', 'scope_revoked']) e;

-- Read only (it runs before Identity decides), set-based: `followup_task` per active task the
-- member owns (last responsible when nobody the app can reach may own it), and
-- `followup_supervision` per task they supervise that nobody else can (never last responsible:
-- a supervision gap never blocks a lifecycle change; it stays pending for an Admin).
create function app.followups_report_handover(p_event jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  with p as (select * from app.followups_handover_plan((p_event ->> 'member_id')::uuid, true))
  select jsonb_build_object('obligations', coalesce(jsonb_agg(x.o order by x.kind, x.task_id), '[]'::jsonb))
    from (
      select 1 as kind, p.task_id,
             jsonb_build_object('kind', 'followup_task', 'subject_id', p.task_id,
                                'last_responsible', p.owner_to is null) as o
        from p where p.owner_due
      union all
      select 2, p.task_id,
             jsonb_build_object('kind', 'followup_supervision', 'subject_id', p.task_id,
                                'last_responsible', false)
        from p
       where p.supervisor_due and p.supervisor_from = (p_event ->> 'member_id')::uuid
         and p.supervisor_to is null) x;
$$;

comment on function app.followups_report_handover(jsonb) is
  'Follow-ups handover hook (story 4.12): the member''s open tasks (last responsible when nobody '
  'else may own them) and the supervision nobody else can take.';

select app.identity_register_handover_hook('followups',
         'app.followups_report_handover(jsonb)'::regprocedure);

-- A task's pending obligations are resolved when its owner (`followup_task`) or its supervisor
-- (`followup_supervision`) changes (handed over), or it finishes (no longer needed), whichever
-- command or hook did it.
create function app.followups_task_handover_sync()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_o record;
  v_finished boolean := app.followups_state_ok('active_state', old.task_state)
                        and not app.followups_state_ok('active_state', new.task_state);
begin
  for v_o in
    select o.obligation_id, o.obligation_kind from app.identity_handover_obligations o
     where o.owner_module = 'followups' and o.subject_id = new.task_id
       and o.obligation_state = 'pending'
       and ((o.obligation_kind = 'followup_task' and o.member_id = old.owner_member_id
             and (v_finished or new.owner_member_id is distinct from old.owner_member_id))
         or (o.obligation_kind = 'followup_supervision' and o.member_id = old.supervisor_member_id
             and (v_finished or new.supervisor_member_id is distinct from old.supervisor_member_id)))
     order by o.obligation_id
  loop
    perform app.identity_resolve_handover_obligation('followups', v_o.obligation_id,
      case when v_finished then 'no_longer_needed' else 'handed_over' end);
  end loop;
  return null;
end;
$$;

create trigger followups_tasks_handover_sync
  after update of owner_member_id, supervisor_member_id, task_state on app.followups_tasks
  for each row execute function app.followups_task_handover_sync();

-- followups.complete_handover {member_id} (Admin; expected null): hands over the next 100 open
-- tasks and supervisions the member may no longer hold, as the lifecycle hooks do: every one of a
-- member who left (deactivated or being deleted), and, for an active member (review B1), those
-- whose group they are no longer in or whose scope they no longer hold (for example after a
-- revoked scope whose hook reached its cap). Refusals: `forbidden` (not Admin), `not_found`.
-- Answer {member_id, handed_over, remaining}.
create function app.followups_complete_handover(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_member uuid;
  v_result jsonb;
begin
  select a.* into v_actor from app.followups_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['member_id']);
  select t.errors, t.value into v_errors, v_member
    from app.followups_uuid(p_payload, 'member_id', true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  if not exists (select 1 from app.identity_members m where m.member_id = v_member) then
    perform app.cmd_fail('not_found');
  end if;
  v_result := app.followups_handover_member(v_member, not app.followups_member_active(v_member), 100);
  perform app.followups_resolve_obligations(v_member);
  return jsonb_build_object(
    'aggregate_type', 'followups_handover', 'aggregate_id', v_member, 'revision', 1,
    'data', jsonb_build_object('member_id', v_member,
                               'handed_over', (v_result ->> 'handed_over')::integer,
                               'remaining', (v_result ->> 'remaining')::integer));
end;
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql.) Story 4.12: the
-- Admin's `followups.complete_handover` (aggregate `followups_handover`, the member: a replay
-- rechecks that the actor is still an Admin).
create or replace function app.followups_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_task app.followups_tasks;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null or p_aggregate_id is null then
    return false;
  end if;
  -- Story 4.12.
  if p_aggregate_type = 'followups_handover' then
    return app.identity_member_has_role(v_member, 'admin');
  end if;
  if p_aggregate_type <> 'followups_task' then
    return false;
  end if;
  select t.* into v_task from app.followups_tasks t where t.task_id = p_aggregate_id for share;
  if not found then
    return false;
  end if;
  return app.followups_capacity(v_member, v_task) is not null;
end;
$$;

-- Story 4.12 review S2 (AD-2, Identity first): the members a Follow-ups command may notify (the
-- actor, the task's owner and supervisor, a named owner or supervisor) are share-locked on their
-- Identity member rows, in member-id order, before any Follow-ups row, so a lifecycle change of
-- one of them (which holds the member row FOR UPDATE and then locks their tasks) waits or is
-- waited for, never deadlocks.
create function app.followups_lock_people(p_members uuid[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- PERFORM reads every row (a SQL function's final SELECT would stop at the first one).
  perform 1 from app.identity_members m
   where m.member_id = any (p_members)
   order by m.member_id
     for key share;
end;
$$;

-- A payload value as a uuid, or null when it is not one (never an error: the handler refuses it).
create function app.followups_jsonb_uuid(p_value jsonb)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if app.contract_uuid_error(p_value) is null then
    return (p_value #>> '{}')::uuid;
  end if;
  return null;
end;
$$;

create function app.followups_command_people(p_request jsonb, p_actor uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct x.m order by x.m), '{}')
    from (
      select p_actor as m
      union all
      select app.followups_jsonb_uuid(p_request #> array['payload', k])
        from unnest(array['owner_member_id', 'supervisor_member_id', 'member_id']) k
      union all
      select unnest(array[t.owner_member_id, t.supervisor_member_id])
        from app.followups_tasks t
       where t.task_id = app.followups_jsonb_uuid(p_request #> '{payload,task_id}')) x
   where x.m is not null;
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql, review N5 kept.)
-- Story 4.12: `followups.complete_handover`, and the members the command may notify are
-- share-locked first (review S2).
create or replace function app.followups_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_payload jsonb;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'followups.create_task', 'followups.update_task', 'followups.reassign',
       -- Story 4.12.
       'followups.complete_handover') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  v_payload := nullif(pg_catalog.current_setting('followups.command_payload', true), '')::jsonb;
  -- Story 4.12 review S2 (N9 order): the actor's member row first (as Identity: member, then
  -- grants), then the actor's grants, then the other members this command may notify.
  perform app.followups_lock_people(array[r.member_id]);
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind is not null)
     for share;
  perform app.followups_lock_people(app.followups_command_people(
    jsonb_build_object('payload', v_payload), r.member_id));
  -- Review N5: a named supervisor's grants too, before the receipt (AD-2 lock order). Story
  -- 4.12 review N10: read from the payload the dispatcher hands over (the 1.4 seam passes no
  -- payload, so the 4.6 check never fired).
  if app.followups_jsonb_uuid(v_payload -> 'supervisor_member_id') is not null then
    perform 1 from app.identity_grants g
     where g.member_id = app.followups_jsonb_uuid(v_payload -> 'supervisor_member_id')
       and g.revoked_at is null
     order by g.grant_id
       for share;
  end if;
  return true;
end;
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql.) Story 4.12:
-- `followups.complete_handover` (expected null).
create or replace function app.followups_command(p_envelope jsonb)
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
  -- Story 4.12 review S2: the authorizer sees only the actor and the command, so the payload is
  -- handed to it (transaction-local, cleared after) to share-lock the members it may notify.
  perform pg_catalog.set_config('followups.command_payload',
    case when jsonb_typeof(p_envelope) = 'object' then coalesce(p_envelope -> 'payload', 'null'::jsonb)::text
         else 'null' end, true);
  v_result := app.cmd_execute(
    p_envelope,
    case v_command
      when 'followups.create_task' then 'app.followups_create_task(uuid, bigint, jsonb)'::regprocedure
      when 'followups.update_task' then 'app.followups_update_task(uuid, bigint, jsonb)'::regprocedure
      when 'followups.reassign' then 'app.followups_reassign(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.12.
      when 'followups.complete_handover'
        then 'app.followups_complete_handover(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.followups_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'followups.create_task'
      and v_command is distinct from 'followups.complete_handover'
  );
  perform pg_catalog.set_config('followups.command_payload', '', true);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Review B1: owner authority is live, and what waits for a new owner or supervisor is visible
-- ---------------------------------------------------------------------------------------------

-- Is the member in the task's group now (the roster of the owner decision Q4 rule: the target's
-- members through its owner's roster hook, the holders of the family's scope kinds and the live
-- Pastors, all active)? An accountless member of the group is in it.
create function app.followups_in_group(p_member_id uuid, p_task app.followups_tasks)
returns boolean
language sql
set search_path = ''
as $$
  select p_member_id is not null
     and p_member_id = any (app.followups_scope_roster(p_task.scope_kind, p_task.scope_id));
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql.) Review B1: owner
-- capacity needs the owner to be in the task's group now; an owner who left the group (a revoked
-- scope, a removal) or lost the Pastor role loses it at once, whether or not the task was handed
-- over yet. Supervisor and Admin capacities are unchanged.
create or replace function app.followups_capacity(p_member_id uuid, p_task app.followups_tasks)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_member_id is null then null
    when p_task.owner_member_id = p_member_id and app.followups_in_group(p_member_id, p_task)
      then 'owner'
    when app.followups_holds_scope(p_member_id, p_task) then 'supervisor'
    when app.identity_member_has_role(p_member_id, 'admin') then 'admin'
  end;
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql.) Review B1: only the
-- tasks whose group the member is still in (one roster per scope).
create or replace function app.followups_my_tasks()
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
  perform app.followups_require_open_read();
  with scopes as materialized (
    select s.scope_kind, s.scope_id,
           v_member = any (app.followups_scope_roster(s.scope_kind, s.scope_id)) as in_group
      from (select distinct t.scope_kind, t.scope_id from app.followups_tasks t
             where t.owner_member_id = v_member) s
  ), ranked as (
    select t.task_id,
           row_number() over (order by (t.finished_at is not null),
                                       coalesce(t.review_at, t.due_at), t.finished_at desc,
                                       t.task_id) as rn
      from app.followups_tasks t
      join scopes s on s.scope_kind = t.scope_kind and s.scope_id = t.scope_id and s.in_group
     where t.owner_member_id = v_member
       and (t.finished_at is null or t.finished_at > now() - interval '30 days'))
  select jsonb_build_object(
           'member_id', v_member,
           'tasks', coalesce(jsonb_agg(app.followups_task_json(r.task_id, v_member) order by r.rn)
                             filter (where r.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked r;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- What waits for a new owner or supervisor, per member (review B1): every active task whose
-- owner is no longer in its group (`followup_task`) or whose supervisor no longer holds its scope
-- or left (`followup_supervision`), the same kinds as the handover obligations Identity records
-- for a deactivation or deletion. A revoked scope records no Identity obligation (Identity's
-- obligations belong to a deactivation or deletion), so this is where the Admin sees what such a
-- change could not hand over within its cap. Erased (former) members are left out: their tasks
-- are reassigned one by one, as in 4.6. One roster per scope.
create function app.followups_pending_handovers()
returns table (member_id uuid, obligation_kind text, task_id uuid)
language sql
set search_path = ''
as $$
  with t as materialized (
    select t.task_id, t.owner_member_id, t.supervisor_member_id, t.scope_kind, t.scope_id,
           t.source_type, t.purpose
      from app.followups_tasks t
     where app.followups_state_ok('active_state', t.task_state)
  ), r as materialized (
    select s.scope_kind, s.scope_id, app.followups_scope_roster(s.scope_kind, s.scope_id) as roster
      from (select distinct t.scope_kind, t.scope_id from t) s
  )
  select t.owner_member_id, 'followup_task', t.task_id
    from t join r on r.scope_kind = t.scope_kind and r.scope_id = t.scope_id
   where not (t.owner_member_id = any (r.roster))
     and t.owner_member_id <> '00000000-0000-0000-0000-000000000000'::uuid
  union all
  select t.supervisor_member_id, 'followup_supervision', t.task_id
    from t
   where t.supervisor_member_id is not null
     and t.supervisor_member_id <> '00000000-0000-0000-0000-000000000000'::uuid
     and (not app.followups_member_active(t.supervisor_member_id)
          or not app.followups_member_holds(t.supervisor_member_id, t.scope_kind, t.scope_id,
                                            app.followups_purpose_kinds(t.source_type, t.purpose)));
$$;

-- (Replaced, story 4.12; copied from 20261014110258_followups_registry.sql.) Review B1: adds
-- `handovers`, per member with anything waiting for a new owner or supervisor ({member_id,
-- display_name, membership_state, tasks, supervisions}); the Admin continues each with
-- `followups.complete_handover`. Routing metadata only, as before.
create or replace function app.followups_admin_routing()
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
  select g.member_id, g.link_id into v_member, v_link from app.identity_require_grant('admin', null, null) g;
  perform app.followups_require_open_read();
  with ranked as (
    select t.task_id,
           row_number() over (order by (t.finished_at is not null),
                                       coalesce(t.review_at, t.due_at), t.finished_at desc,
                                       t.task_id) as rn
      from app.followups_tasks t
     where t.finished_at is null or t.finished_at > now() - interval '30 days'),
  -- Review S2: an Admin reassigns within each active task's scope (its roster), not the roster
  -- of the whole church.
  families as (
    select distinct on (app.followups_family(t.scope_kind), t.scope_id) t.scope_kind, t.scope_id
      from app.followups_tasks t join ranked r on r.task_id = t.task_id
     where r.rn <= 500 and t.finished_at is null
     order by app.followups_family(t.scope_kind), t.scope_id, t.scope_kind),
  waiting as (
    select h.member_id,
           count(*) filter (where h.obligation_kind = 'followup_task')::integer as tasks,
           count(*) filter (where h.obligation_kind = 'followup_supervision')::integer as supervisions
      from app.followups_pending_handovers() h
     group by h.member_id)
  select jsonb_build_object(
    'tasks', coalesce((select jsonb_agg(app.followups_routing_json(r.task_id) order by r.rn)
                         from ranked r where r.rn <= 500), '[]'::jsonb),
    'truncated', (select count(*) > 500 from ranked),
    'scopes', coalesce((select jsonb_agg(app.followups_scope_json(f.scope_kind, f.scope_id, true)
                                         order by f.scope_kind, f.scope_id) from families f), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object(
                             'member_id', w.member_id,
                             'display_name', app.followups_display_name(w.member_id),
                             'membership_state', case
                               when exists (select 1 from app.identity_deletions d
                                             where d.member_id = w.member_id) then 'deleting'
                               else (select m.membership_state from app.identity_members m
                                      where m.member_id = w.member_id) end,
                             'tasks', w.tasks,
                             'supervisions', w.supervisions)
                           order by app.followups_display_name(w.member_id), w.member_id)
                             from waiting w), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing new is client-executable
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_lock_people(uuid[]),
  app.duties_jsonb_uuid(jsonb),
  app.followups_jsonb_uuid(jsonb),
  app.followups_lock_people(uuid[]),
  app.followups_in_group(uuid, app.followups_tasks),
  app.followups_pending_handovers(),
  app.duties_command_people(jsonb, uuid),
  app.duties_lifecycle_actor(),
  app.duties_vacated_since(uuid),
  app.duties_lifecycle_notify(jsonb, jsonb, uuid, uuid, text, text, uuid, uuid),
  app.duties_vacate_member(uuid, uuid, text, boolean, uuid, uuid, text, text),
  app.duties_hold_contact(uuid),
  app.duties_scope_revoked(uuid),
  app.duties_on_member_lifecycle(jsonb),
  app.duties_report_handover(jsonb),
  app.duties_vacancy_alert_check(jsonb),
  app.duties_remove_member(uuid, bigint, jsonb),
  app.duties_pending_handovers(uuid),
  app.duties_has_reachable_leader(uuid),
  app.duties_resolve_handover(uuid, bigint, jsonb),
  app.followups_reachable(uuid),
  app.followups_handover_plan(uuid, boolean),
  app.followups_handover_member(uuid, boolean, integer),
  app.followups_resolve_obligations(uuid),
  app.followups_on_member_lifecycle(jsonb),
  app.followups_report_handover(jsonb),
  app.followups_task_handover_sync(),
  app.followups_complete_handover(uuid, bigint, jsonb),
  app.followups_command_people(jsonb, uuid)
  from public, anon, authenticated, service_role;
