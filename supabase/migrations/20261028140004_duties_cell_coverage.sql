-- Coverage for cells (owner decision 2026-10-28): a cell's leader and assistant get the coverage
-- features a department's leaders and deputies have, for the cell's programme parts (Duties
-- occurrences owned by the cell). The shared 4.9/4.10 coverage queue is extended, not copied.
-- This changes the 5.5 contract (20261021101314_duties_cell_confirmation.sql), which kept contact
-- attempts, the coverage queue, leader alerts and outcomes department-only.
--
--   * Contact attempts: duties.record_contact_attempt accepts a cell part's assignment from a
--     current leader or assistant of its cell (the 5.5 cell lock, app.duties_lock_for_confirm).
--     The first attempt opens a coverage case (app.duties_coverage_cases gains cell_id: exactly
--     one of department_id and cell_id) and its Follow-ups task in the cell scope (the
--     coverage_follow_up purpose now also registers cell_leader and cell_assistant), supervised by
--     the cell's other leader or assistant (a leader first). Confirmed by leader and the member's
--     own answer close the case as for a department.
--   * The coverage queue: api.duties_coverage answers `cells` next to `departments`, the cells the
--     caller leads or assists (never by the Admin role or Pastor), each with its open programme
--     parts as positions, the same counts, statuses, follow-ups and labelled contact routes (2.5,
--     through app.identity_scoped_contact_routes in the cell scope). A cell has no roster to
--     reassign from here (can_manage false): reassignment stays in the cell's programme.
--   * Leader alerts: a cell part's overdue, short-notice and decline alerts go to the cell's
--     leader and assistant the app can reach, as their own kinds (cell_part_response_overdue,
--     cell_part_short_notice, cell_part_declined) that open Coverage.
--   * Outcomes: duties.record_outcome and duties.correct_outcome accept a started cell part from
--     its cell's leader or assistant (never their own); api.duties_outcomes answers `cells`.
--   * Module boundaries: Duties reads no Cells table. A cell's leaders are Identity grants on the
--     occurrence's own cell_id (a registered dependency); names of cells are composed by the
--     client from its Cells reads.
--
-- Replaced bodies are copied from their latest version with every earlier fix; the changes are
-- marked "Coverage for cells". No row deletion. ASCII only, no backslashes.
-- owner-approved-cleanup: owner decision 2026-10-28 (coverage for cells): the coverage case's department_id becomes nullable and the case is owned by exactly one department or cell (duties_coverage_cases_one_owner); no data is removed.

alter table app.duties_coverage_cases
  add column cell_id uuid,
  alter column department_id drop not null,
  add constraint duties_coverage_cases_one_owner check (num_nonnulls(department_id, cell_id) = 1);

comment on column app.duties_coverage_cases.cell_id is
  'Coverage for cells: the cell whose programme part the case is about (department_id null).';

-- The capacity in which a member leads a cell (its leader first), or null.
create function app.duties_cell_capacity(p_member uuid, p_cell_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_member is null or p_cell_id is null then null
    when app.identity_member_has_scope(p_member, 'cell_leader', p_cell_id) then 'cell_leader'
    when app.identity_member_has_scope(p_member, 'cell_assistant', p_cell_id) then 'cell_assistant'
  end;
$$;

comment on function app.duties_cell_capacity(uuid, uuid) is
  'Coverage for cells: cell_leader or cell_assistant when the member holds that scope on the cell.';

-- The capacity in which a member looks after a duty's coverage: the department's leader or deputy
-- (scope, never the Admin role), or the cell's leader or assistant; null otherwise.
create function app.duties_owner_capacity(p_member uuid, p_occurrence app.duties_occurrences)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_member is null then null
    when p_occurrence.department_id is not null then case
      when app.identity_member_has_scope(p_member, 'department_leader', p_occurrence.department_id)
        then 'department_leader'
      when app.identity_member_has_scope(p_member, 'department_deputy', p_occurrence.department_id)
        then 'department_deputy' end
    when p_occurrence.cell_id is not null then app.duties_cell_capacity(p_member, p_occurrence.cell_id)
  end;
$$;

comment on function app.duties_owner_capacity(uuid, app.duties_occurrences) is
  'Coverage for cells: the scope in which a member looks after a duty''s coverage (department '
  'leader or deputy, cell leader or assistant), or null.';

-- (Replaced; copied from 20261014171038_duties_reminders.sql.) Coverage for cells: the owner id is a department or a
-- cell (scope ids are distinct uuids); a cell's leader and assistant are alerted as a department's
-- leaders and deputies are.
create or replace function app.duties_alert_recipients(p_department_id uuid, p_exclude uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(x.member_id order by x.member_id), '{}')
    from (select distinct g.member_id
            from app.identity_grants g
           where g.scope_id = p_department_id and g.revoked_at is null
             and g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader',
                                  'cell_assistant')
             and g.member_id is distinct from p_exclude
             and app.duties_member_active(g.member_id)
             and app.duties_leader_reachable(g.member_id)) x;
$$;

-- (Replaced; copied from 20261014212507_duties_coverage.sql.) Coverage for cells: a cell's other leader or assistant
-- supervises (a leader first), as in a department.
create or replace function app.duties_coverage_supervisor(p_department_id uuid, p_actor uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select g.member_id
    from app.identity_grants g
   where g.scope_id = p_department_id and g.revoked_at is null
     and g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader', 'cell_assistant')
     and g.member_id is distinct from p_actor
     and app.duties_member_active(g.member_id)
     and app.duties_leader_reachable(g.member_id)
   order by (g.scope_kind in ('department_deputy', 'cell_assistant')), g.member_id
   limit 1;
$$;

-- (Replaced; copied from 20261014212507_duties_coverage.sql.) Coverage for cells: the owner is a department or a cell.
create or replace function app.duties_close_started_cases(p_department_id uuid, p_actor_member uuid,
                                               p_actor_account uuid, p_capacity text, p_command text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(c.assignment_id order by c.assignment_id), '{}') into v_ids
    from app.duties_coverage_cases c
    join app.duties_assignments a on a.assignment_id = c.assignment_id
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where coalesce(c.department_id, c.cell_id) = p_department_id and c.closed_at is null
     and app.duties_occurrence_start(o) <= now();
  if cardinality(v_ids) = 0 then
    return 0;
  end if;
  perform 1 from app.duties_coverage_cases c
   where c.assignment_id = any (v_ids) and c.closed_at is null
   order by c.assignment_id for update skip locked;
  return app.duties_close_cases(v_ids, 'started', p_actor_member, p_actor_account, p_capacity,
                                p_command);
end;
$$;

-- (Replaced; copied from 20261014171038_duties_reminders.sql.) Coverage for cells: the recipient leads the duty's
-- department or cell now.
create or replace function app.duties_coverage_reminder_check(p_key jsonb)
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
  v_current := v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_assignment.revision,
    'actionable', v_current and v_assignment.response = 'pending'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    -- Coverage for cells: a cell's leader or assistant for a cell programme part.
    'recipient_eligible', app.duties_owner_capacity((p_key ->> 'recipient_member_id')::uuid,
                                                    v_occurrence) is not null
                          and v_assignment.member_id::text is distinct from p_key ->> 'recipient_member_id'
                          -- Review fix 2: a held or in-review leader is not alerted (an alert is
                          -- never a direct-contact need).
                          and app.duties_leader_reachable((p_key ->> 'recipient_member_id')::uuid));
end;
$$;

-- (Replaced; copied from 20261014212507_duties_coverage.sql.) Coverage for cells: as the check above.
create or replace function app.duties_decline_alert_check(p_key jsonb)
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
  v_current := v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_assignment.revision,
    'actionable', v_current and v_assignment.response = 'declined'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    -- Coverage for cells: a cell's leader or assistant for a cell programme part.
    'recipient_eligible', app.duties_owner_capacity((p_key ->> 'recipient_member_id')::uuid,
                                                    v_occurrence) is not null
                          and v_assignment.member_id::text is distinct from p_key ->> 'recipient_member_id'
                          and app.duties_leader_reachable((p_key ->> 'recipient_member_id')::uuid));
end;
$$;

-- (Replaced; copied from 20261015035112_duties_owner_operations.sql.) Coverage for cells: the leaders' overdue and
-- short-notice alerts for a cell part go to its cell's leader and assistant.
create or replace function app.duties_plan_reminders(p_assignment_id uuid, p_fresh boolean, p_notice text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_a app.duties_assignments;
  v_o app.duties_occurrences;
  v_policy jsonb;
  v_start timestamptz;
  v_intent jsonb;
  v_leaders uuid[] := '{}';
  v_leader uuid;
  v_member jsonb;
  v_alerts integer := 0;
  v_late integer := 0;
  v_job jsonb;
begin
  select a.* into v_a from app.duties_assignments a where a.assignment_id = p_assignment_id;
  if not found or v_a.assignment_state <> 'current' then
    return '{"planned": false}'::jsonb;
  end if;
  v_o := app.duties_assignment_occurrence(v_a.slot_id);
  v_start := app.duties_occurrence_start(v_o);
  -- Story 4.11: a cell programme part plans its member's reminders too.
  if v_o.occurrence_state <> 'published' or v_start <= now() then
    return '{"planned": false}'::jsonb;
  end if;
  v_policy := app.notifications_policy();
  v_intent := jsonb_build_object(
    'assigned_at', app.cmd_utc(least(v_a.assigned_at, v_a.response_deadline)),
    'starts_at', app.cmd_utc(v_start),
    'response_deadline', app.cmd_utc(v_a.response_deadline),
    'responded', v_a.response <> 'pending');
  if v_a.response <> 'declined' and app.duties_notice_recipient(v_a.member_id) then
    v_member := app.notifications_set_schedule(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_a.member_id,
      'schedule_type', 'response',
      'intent', v_intent || jsonb_build_object('reminders',
                                               app.duties_reminder_specs(v_policy, v_o.reminders)),
      -- Review fix 6: before the member answers, the pre-service reminder asks for the answer
      -- (duty_response_due); after an acceptance it is `duty_starting`.
      'kinds', jsonb_build_object('response_deadline', 'duty_response_due',
                                  'starts_at', case when v_a.response = 'pending'
                                                    then 'duty_response_due' else 'duty_starting' end,
                                  'respond_now', coalesce(p_notice, 'duty_response_due')),
      'fresh', p_fresh));
  end if;

  -- Coverage for cells (owner decision 2026-10-28): a cell part's leader and assistant are
  -- alerted as a department's leaders and deputies are (their own kinds, opening Coverage).
  if v_a.response = 'pending' and coalesce(v_o.department_id, v_o.cell_id) is not null then
    v_leaders := app.duties_alert_recipients(coalesce(v_o.department_id, v_o.cell_id), v_a.member_id);
  end if;
  -- Leaders no longer in the list (or an answered assignment) lose their pending alert.
  -- Story 4.9: only the overdue and short-notice alerts (a decline alert is not re-planned).
  for v_leader in select distinct j.recipient_member_id from app.notifications_jobs j
                   where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                     and j.job_state = 'pending'
                     and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice',
                                             'cell_part_response_overdue', 'cell_part_short_notice')
                     and not (j.recipient_member_id = any (v_leaders))
                   order by j.recipient_member_id loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient',
      'reminder_kind', k.kind))
       from unnest(array['duty_response_overdue', 'duty_short_notice', 'cell_part_response_overdue',
                         'cell_part_short_notice']) k(kind);
  end loop;
  -- Review fix 1: one alert job per leader, enqueued directly (a fixed rule on a stored
  -- deadline needs no schedule): `duty_short_notice` now on Short notice, otherwise
  -- `duty_response_overdue` at the deadline, or now when the deadline has already passed and
  -- this leader has no live alert at this revision (a passed deadline never drops it).
  foreach v_leader in array v_leaders loop
    v_alerts := v_alerts + 1;
    continue when exists (select 1 from app.notifications_jobs j
                           where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                             and j.recipient_member_id = v_leader
                             and j.source_revision = v_a.revision
                             and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice',
                                                     'cell_part_response_overdue',
                                                     'cell_part_short_notice')
                             and j.job_state <> 'cancelled');
    v_job := app.notifications_enqueue(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_leader,
      'reminder_kind', case when v_o.cell_id is not null and v_a.short_notice then 'cell_part_short_notice'
                            when v_o.cell_id is not null then 'cell_part_response_overdue'
                            when v_a.short_notice then 'duty_short_notice'
                            else 'duty_response_overdue' end,
      'scheduled_at', app.cmd_utc(greatest(v_a.response_deadline, now()))));
    if coalesce((v_job ->> 'created')::boolean, false) and v_a.response_deadline <= now()
       and not (p_fresh and v_a.short_notice) then
      v_late := v_late + 1;
    end if;
  end loop;
  return jsonb_build_object('planned', true,
                            'member_entries', coalesce((v_member ->> 'entries')::integer, 0),
                            'leaders', v_alerts, 'late_alerts', v_late);
end;
$$;

-- (Replaced; copied from 20261014212507_duties_coverage.sql.) Coverage for cells: a cell part's decline alerts its
-- cell's leader and assistant.
create or replace function app.duties_after_answer(p_assignment_id uuid, p_actor_member uuid,
                                                   p_actor_account uuid, p_command text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_message text;
  v_a app.duties_assignments;
  v_o app.duties_occurrences;
  v_leader uuid;
  v_capacity text;
begin
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_coverage', 'source_id', p_assignment_id, 'reason', 'responded'));
  select a.* into v_a from app.duties_assignments a
   where a.assignment_id = p_assignment_id and a.assignment_state = 'current'
     and a.response in ('accepted', 'declined');
  if not found then
    return;
  end if;
  v_o := app.duties_assignment_occurrence(v_a.slot_id);
  v_capacity := case when p_actor_member = v_a.member_id then 'member'
                     else coalesce(app.duties_owner_capacity(p_actor_member, v_o), 'member') end;
  begin
    if v_a.response = 'accepted' then
      perform app.duties_plan_reminders(p_assignment_id, false, null);
    elsif coalesce(v_o.department_id, v_o.cell_id) is not null and app.duties_occurrence_start(v_o) > now() then
      -- Story 4.9: the leaders' decline alert. Coverage for cells: a cell's leader and assistant.
      foreach v_leader in array app.duties_alert_recipients(coalesce(v_o.department_id, v_o.cell_id),
                                                            v_a.member_id) loop
        perform app.notifications_enqueue(jsonb_build_object(
          'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
          'source_revision', v_a.revision, 'recipient_member_id', v_leader,
          'reminder_kind', case when v_o.cell_id is not null then 'cell_part_declined'
                                else 'duty_declined' end,
          'scheduled_at', app.cmd_utc(now())));
      end loop;
    end if;
  exception when sqlstate 'PCMD1' then
    get stacked diagnostics v_message = message_text;
    if v_message is distinct from 'unavailable' then
      raise;
    end if;
    perform app.duties_audit_event('reminders_skipped', p_actor_member, p_actor_account, v_capacity,
                                   p_command, v_o.department_id, v_o.occurrence_id,
                                   p_assignment_id, v_a.member_id, 'policy_unavailable', v_a.revision);
  end;
end;
$$;

-- (Replaced; copied from 20261014212507_duties_coverage.sql.) Coverage for cells: a cell programme part's leader or
-- assistant records contact attempts, opening the coverage case and its Follow-ups task in the
-- cell scope (supervised by the cell's other leader or assistant).
create or replace function app.duties_record_contact_attempt(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_channel text;
  v_outcome text;
  v_note text;
  v_next timestamptz;
  v_lock record;
  v_case app.duties_coverage_cases;
  v_attempt uuid;
  v_task jsonb;
  v_followup text := 'none';
  v_message text;
  v_supervisor uuid;
  v_old_case uuid;
  v_task_row app.followups_tasks;
  v_cmd constant text := 'duties.record_contact_attempt';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'channel', 'outcome',
                'note', 'next_follow_up_at']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_channel
    from app.duties_code(p_payload, 'channel', 'contact_channel', v_errors) t;
  select t.errors, t.value into v_errors, v_outcome
    from app.duties_code(p_payload, 'outcome', 'contact_outcome', v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 280, true, v_errors) t;
  select t.errors, t.value into v_errors, v_next
    from app.duties_instant(p_payload, 'next_follow_up_at', true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Coverage for cells: a cell programme part through the cell lock (its leader or assistant); a
  -- special assignment has no coverage queue (not_found).
  if exists (select 1 from app.duties_assignments a
               join app.duties_slots s on s.slot_id = a.slot_id
               join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
              where a.assignment_id = v_assignment_id and o.special) then
    perform app.cmd_fail('not_found');
  end if;
  select l.* into v_lock from app.duties_lock_for_confirm(v_actor.member_id, v_assignment_id,
                                                           p_expected_revision) l;
  if (v_lock.assignment).response = 'accepted' then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "confirmed"}');
  end if;
  -- Review N9: an erased or departed assignee is reassigned, not contacted.
  if (v_lock.assignment).member_id = '00000000-0000-0000-0000-000000000000'::uuid
     or ((v_lock.occurrence).department_id is not null
         and not app.duties_can_serve((v_lock.assignment).member_id, (v_lock.occurrence).department_id))
     or ((v_lock.occurrence).cell_id is not null
         and not app.duties_member_active((v_lock.assignment).member_id)) then
    perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
  end if;
  if v_next <= now() then
    perform app.cmd_fail('validation_failed', '{"next_follow_up_at": "past"}');
  elsif v_next >= app.duties_occurrence_start(v_lock.occurrence) then
    perform app.cmd_fail('validation_failed', '{"next_follow_up_at": "after_start"}');
  elsif v_next > now() + interval '1 year' then
    perform app.cmd_fail('validation_failed', '{"next_follow_up_at": "out_of_range"}');
  end if;
  -- The open case (after the assignment, AD-2), or a new one.
  select c.* into v_case from app.duties_coverage_cases c
   where c.assignment_id = v_assignment_id and c.closed_at is null for update;
  -- Review N2/N3: a case whose task was finished by hand, or whose task owner no longer holds the
  -- department's scope, is replaced: it closes (`replaced`, its task too below) and a fresh case
  -- and task are opened for the recorder (a new source id, so no uniqueness refusal).
  if found and v_case.task_id is not null then
    select t.* into v_task_row from app.followups_tasks t where t.task_id = v_case.task_id;
    if not app.followups_state_ok('active_state', v_task_row.task_state)
       or app.duties_owner_capacity(v_task_row.owner_member_id, v_lock.occurrence) is null then
      update app.duties_coverage_cases c set closed_at = now(), close_code = 'replaced'
       where c.case_id = v_case.case_id;
      v_old_case := v_case.case_id;
      v_case := null;
    end if;
  end if;
  if v_case.case_id is null then
    insert into app.duties_coverage_cases (assignment_id, department_id, cell_id, opened_by_member,
                                           opened_by_account)
    values (v_assignment_id, (v_lock.occurrence).department_id, (v_lock.occurrence).cell_id,
            v_actor.member_id, v_actor.account_id)
    returning * into v_case;
  end if;
  insert into app.duties_contact_attempts (case_id, assignment_id, channel, outcome, note,
                                           next_follow_up_at, recorded_by_member,
                                           recorded_by_account)
  values (v_case.case_id, v_assignment_id, v_channel, v_outcome, v_note, v_next,
          v_actor.member_id, v_actor.account_id)
  returning attempt_id into v_attempt;
  perform app.duties_audit_event('contact_attempt_recorded', v_actor.member_id, v_actor.account_id,
                                 v_lock.capacity, v_cmd, (v_lock.occurrence).department_id,
                                 (v_lock.occurrence).occurrence_id, v_assignment_id,
                                 (v_lock.assignment).member_id, v_outcome,
                                 (v_lock.assignment).revision);
  -- Follow-ups (after every Duties row, before Notifications; its own reminder work runs inside).
  perform app.duties_close_started_cases(
    coalesce((v_lock.occurrence).department_id, (v_lock.occurrence).cell_id), v_actor.member_id,
    v_actor.account_id, v_lock.capacity, v_cmd);
  v_supervisor := app.duties_coverage_supervisor(
    coalesce((v_lock.occurrence).department_id, (v_lock.occurrence).cell_id), v_actor.member_id);
  if v_old_case is not null then
    -- The replaced case's task, if still active, closes (Q4 gate only, review S1).
    perform app.followups_source_event(jsonb_build_object(
      'source_type', 'duties_coverage_case', 'source_id', v_old_case, 'event', 'resolved'));
  end if;
  begin
    if v_case.task_id is null then
      v_task := app.followups_open_task(jsonb_build_object(
        'source_type', 'duties_coverage_case', 'source_id', v_case.case_id, 'source_revision', 1,
        'purpose', 'coverage_follow_up', 'owner_member_id', v_actor.member_id,
        'supervisor_member_id', coalesce(v_supervisor, v_actor.member_id),
        -- The task's scope is the supervisor's (a leader may supervise a deputy's task: same
        -- department family).
        'scope_kind', case when v_supervisor is null then v_lock.capacity
                           else app.duties_owner_capacity(v_supervisor, v_lock.occurrence) end,
        'scope_id', coalesce((v_lock.occurrence).department_id, (v_lock.occurrence).cell_id),
        'next_action', 'Follow up a duty position that needs an answer or cover.',
        'due_at', app.cmd_utc(v_next), 'actor_member_id', v_actor.member_id,
        'actor_account_id', v_actor.account_id));
      update app.duties_coverage_cases c set task_id = (v_task ->> 'task_id')::uuid
       where c.case_id = v_case.case_id;
      v_case.task_id := (v_task ->> 'task_id')::uuid;
      v_followup := 'opened';
    else
      v_task := app.followups_source_review(jsonb_build_object(
        'source_type', 'duties_coverage_case', 'source_id', v_case.case_id,
        'purpose', 'coverage_follow_up', 'review_at', app.cmd_utc(v_next), 'outcome', v_outcome,
        'actor_member_id', v_actor.member_id, 'actor_account_id', v_actor.account_id));
      v_followup := case when v_task ->> 'task_id' is null then 'finished' else 'updated' end;
    end if;
  exception when sqlstate 'PCMD1' then
    get stacked diagnostics v_message = message_text;
    if v_message is distinct from 'unavailable' then
      raise;
    end if;
    v_followup := 'skipped';
    perform app.duties_audit_event('followup_skipped', v_actor.member_id, v_actor.account_id,
                                   v_lock.capacity, v_cmd, (v_lock.occurrence).department_id,
                                   (v_lock.occurrence).occurrence_id, v_assignment_id,
                                   (v_lock.assignment).member_id, 'policy_unavailable', null);
  end;
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', (v_lock.occurrence).occurrence_id,
    'revision', (v_lock.occurrence).revision,
    'data', jsonb_build_object('assignment_id', v_assignment_id,
                               'revision', (v_lock.assignment).revision,
                               'case_id', v_case.case_id, 'attempt_id', v_attempt,
                               'task_id', v_case.task_id, 'followup', v_followup,
                               'replaced_case', v_old_case is not null,
                               'supervisor_fallback', v_supervisor is null));
end;
$$;

-- (Replaced; copied from 20261021101314_duties_cell_confirmation.sql.) Coverage for cells: a confirmation closes a cell
-- part's coverage case.
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
  -- Follow-ups before Notifications. Coverage for cells: a cell part's case closes too.
  if coalesce((v_lock.occurrence).department_id, (v_lock.occurrence).cell_id) is not null then
    perform app.duties_close_started_cases(
      coalesce((v_lock.occurrence).department_id, (v_lock.occurrence).cell_id), v_actor.member_id,
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

-- (Replaced; copied from 20261021211830_duties_special_assignments.sql.) Coverage for cells: a cell programme part's
-- outcome is recorded and corrected by its cell's leader or assistant.
create or replace function app.duties_lock_for_outcome(p_actor_member uuid, p_assignment_id uuid,
                                                       out assignment app.duties_assignments,
                                                       out occurrence app.duties_occurrences,
                                                       out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_department uuid;
  v_series uuid;
  v_occurrence uuid;
  v_assignee uuid;
  v_slot_cancelled boolean;
  v_special boolean;
  v_cell uuid;
begin
  select o.department_id, o.series_id, o.occurrence_id, a.member_id, o.special, o.cell_id
    into v_department, v_series, v_occurrence, v_assignee, v_special, v_cell
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = p_assignment_id;
  if v_special then
    capacity := case when app.identity_member_has_role(p_actor_member, 'pastor') then 'pastor' end;
    if capacity is null then
      perform app.cmd_fail('not_found');
    end if;
  elsif v_department is null and v_cell is not null then
    -- Coverage for cells: a cell part's outcome is recorded by its cell's leader or assistant.
    capacity := app.duties_cell_capacity(p_actor_member, v_cell);
    if capacity is null then
      perform app.cmd_fail('not_found');
    end if;
  else
    if v_department is null then
      perform app.cmd_fail('not_found');
    end if;
    capacity := case
      when app.identity_member_has_scope(p_actor_member, 'department_leader', v_department)
        then 'department_leader'
      when app.identity_member_has_scope(p_actor_member, 'department_deputy', v_department)
        then 'department_deputy' end;
    if capacity is null then
      if app.identity_member_has_role(p_actor_member, 'admin') then
        -- The Admin role alone does not hold the department's scope (outcomes are the leaders').
        perform app.cmd_fail('forbidden');
      end if;
      perform app.cmd_fail('not_found');
    end if;
  end if;
  -- A leader never grades their own duty (nor a Pastor their own special assignment).
  if v_assignee = p_actor_member then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "own"}');
  end if;
  if v_department is not null then
    perform 1 from app.duties_departments d
     where d.department_id = v_department and d.department_state = 'active' for share;
  end if;
  if v_series is not null then
    perform 1 from app.duties_series r where r.series_id = v_series for share;
  end if;
  select o.* into occurrence from app.duties_occurrences o where o.occurrence_id = v_occurrence for share;
  select a.* into assignment from app.duties_assignments a where a.assignment_id = p_assignment_id for update;
  select s.cancelled_at is not null into v_slot_cancelled from app.duties_slots s
   where s.slot_id = assignment.slot_id;
  if assignment.assignment_state = 'superseded' then
    perform app.cmd_fail('conflict', '{"assignment_id": "superseded"}', assignment.revision);
  elsif assignment.assignment_state <> 'current' or occurrence.occurrence_state = 'cancelled'
        or v_slot_cancelled then
    -- A cancelled accepted duty has no outcome.
    perform app.cmd_fail('conflict', '{"assignment_id": "cancelled"}', assignment.revision);
  end if;
  if occurrence.occurrence_state <> 'published' then
    perform app.cmd_fail('not_found');
  end if;
  if app.duties_occurrence_start(occurrence) > now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "not_started"}');
  end if;
  if assignment.member_id = '00000000-0000-0000-0000-000000000000'::uuid then
    perform app.cmd_fail('validation_failed', '{"member_id": "erased"}');
  elsif not app.duties_member_active(assignment.member_id) then
    -- Review S1: no new outcome text about a member who left the church or is under deletion.
    perform app.cmd_fail('validation_failed', '{"member_id": "inactive"}');
  end if;
end;
$$;

-- (Replaced; copied from 20261015190139_duties_owner_decisions.sql.) Coverage for cells: `cells`, the cells the caller
-- leads or assists, with their programme parts as positions (the same shape as a department).
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
                        and g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader',
                                             'cell_assistant')) then
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
           -- Story 4.16: why, for the department's leaders and deputies only.
           x.vacancy_reason,
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
          case when a.assignment_id is null then app.duties_vacated_since(s.slot_id) end as vacated_since,
          case when a.assignment_id is null and cd.scope_kind is not null
               then app.duties_vacancy_reason(s.slot_id) end as vacancy_reason) x
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
                             then jsonb_build_object('since', app.cmd_utc(b.vacated_since),
                                                     -- Story 4.16: null unless the caller leads or
                                                     -- deputises the department.
                                                     'reason', b.vacancy_reason) end,
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
        from cd), '[]'::jsonb),
    -- Coverage for cells: the cells the caller leads or assists (never by a role), unless the
    -- read is filtered to one department.
    'cells', case when p_department_id is null
                  then app.duties_cell_coverage_json(v_member, v_lo, v_hi, v_duty)
                  else '[]'::jsonb end)
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- (Replaced; copied from 20261015002121_duties_outcomes.sql.) Coverage for cells: `cells`, the started programme
-- parts of the cells the caller leads or assists.
create or replace function app.duties_outcomes(p_from date, p_to date, p_department_id uuid, p_duty text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_zone text;
  v_today date;
  v_from date;
  v_to date;
  v_lo timestamptz;
  v_hi timestamptz;
  v_duty text := nullif(btrim(coalesce(p_duty, '')), '');
  v_departments uuid[];
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  -- Review N5: the Q4 gate first.
  perform app.duties_require_open_read();
  if not exists (select 1 from app.identity_grants g
                  where g.member_id = v_member and g.revoked_at is null
                    and g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader',
                                         'cell_assistant')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  v_zone := app.duties_church_zone();
  v_today := (now() at time zone v_zone)::date;
  v_to := coalesce(p_to, v_today);
  v_from := coalesce(p_from, v_to - 13);
  -- No time limit for corrections (ticket unknown): any past window of at most 31 days.
  if v_to < v_from or v_to - v_from > 30 or v_to > v_today or v_from < date '2000-01-01' then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
  end if;
  if v_duty is not null and (length(v_duty) > 80 or v_duty ~ '[[:cntrl:]]') then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'duty';
  end if;
  v_lo := v_from::timestamp at time zone v_zone;
  v_hi := (v_to + 1)::timestamp at time zone v_zone;
  -- Only departments whose scope the caller holds (never through the Admin role or Pastor).
  select coalesce(array_agg(d.department_id), '{}') into v_departments
    from app.duties_departments d
   where (p_department_id is null or d.department_id = p_department_id)
     and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
     and (app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
          or app.identity_member_has_scope(v_member, 'department_deputy', d.department_id));
  -- Coverage for cells: a caller who only leads or assists a cell reads its cells.
  if cardinality(v_departments) = 0
     and (p_department_id is not null
          or not exists (select 1 from app.identity_grants g
                          where g.member_id = v_member and g.revoked_at is null
                            and g.scope_kind in ('cell_leader', 'cell_assistant'))) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;

  with base as (
    select o.department_id, o.occurrence_id, s.slot_id, a.assignment_id, a.response,
           x.outcome,
           row_number() over (order by o.starts_at desc, o.occurrence_id, s.position_no) as rn
      from app.duties_occurrences o
      join app.duties_slots s on s.occurrence_id = o.occurrence_id and s.cancelled_at is null
      left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
      left join lateral (select y.outcome from app.duties_outcomes y
                          where y.assignment_id = a.assignment_id
                          order by y.revision desc limit 1) x on true
     where o.department_id = any (v_departments) and o.occurrence_state = 'published'
       and o.starts_at >= v_lo and o.starts_at < v_hi
       and app.duties_occurrence_start(o) <= now()
       and (v_duty is null or position(lower(v_duty) in lower(o.duty_name)) > 0)
  ), pos as (
    select b.department_id, b.rn, jsonb_build_object(
             'slot_id', s.slot_id,
             'position_no', s.position_no,
             'position_name', s.position_name,
             'occurrence_id', o.occurrence_id,
             'duty_name', o.duty_name,
             'starts_at', app.cmd_utc(o.starts_at),
             'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
             'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
             'location', o.location,
             'assignment', case when a.assignment_id is not null then jsonb_build_object(
               'assignment_id', a.assignment_id,
               'revision', a.revision,
               'member_id', a.member_id,
               'display_name', app.duties_display_name(a.member_id),
               'own', a.member_id = v_member,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               -- Completion is separate from the response: `unrecorded` until a leader records it.
               'outcome_state', coalesce(b.outcome, 'unrecorded'),
               'outcome', app.duties_outcome_json(a.assignment_id, 20),
               'allowed', app.duties_outcomes_allowed(a.response)) end) as obj
      from base b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      join app.duties_slots s on s.slot_id = b.slot_id
      left join app.duties_assignments a on a.assignment_id = b.assignment_id
     where b.rn <= 1000
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', to_char(v_from, 'YYYY-MM-DD'), 'to', to_char(v_to, 'YYYY-MM-DD'),
                                 'zone', v_zone),
    'duty', v_duty,
    -- At most 1000 positions are listed (latest first); the counts always cover every one.
    'truncated', (select count(*) > 1000 from base),
    'departments', coalesce((
      select jsonb_agg(jsonb_build_object(
          'department_id', d.department_id,
          'name', d.name,
          'capacity', case when app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
                           then 'department_leader' else 'department_deputy' end,
          -- Department totals only (never per member: no ranking).
          'counts', (select jsonb_build_object(
                       'positions', count(*),
                       'unfilled', count(*) filter (where r.assignment_id is null),
                       'unrecorded', count(*) filter (where r.assignment_id is not null and r.outcome is null),
                       'completed', count(*) filter (where r.outcome = 'completed'),
                       'excused', count(*) filter (where r.outcome = 'excused'),
                       'no_show', count(*) filter (where r.outcome = 'no_show'))
                       from base r where r.department_id = d.department_id),
          'positions', coalesce((
            select jsonb_agg(p.obj order by p.rn) from pos p where p.department_id = d.department_id),
            '[]'::jsonb))
        order by d.name, d.department_id)
        from app.duties_departments d where d.department_id = any (v_departments)), '[]'::jsonb),
    -- Coverage for cells: the started programme parts of the cells the caller leads or assists.
    'cells', case when p_department_id is null
                  then app.duties_cell_outcomes_json(v_member, v_lo, v_hi, v_duty)
                  else '[]'::jsonb end)
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Coverage for cells: the cells' part of the coverage and outcomes reads
-- ---------------------------------------------------------------------------------------------

-- The coverage queue's `cells`: for each cell the member leads or assists now (by scope, never a
-- role), its published programme parts that start in [p_lo, p_hi) and have not started (an
-- optional duty-name filter), with the department queue's position shape, counts and labelled
-- contact routes (members whose part is not yet confirmed). At most 1000 positions per cell.
-- Called by app.duties_coverage only (security definer there).
create function app.duties_cell_coverage_json(p_member uuid, p_lo timestamptz, p_hi timestamptz,
                                              p_duty text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cells uuid[];
  v_counts jsonb;
  v_result jsonb;
begin
  select coalesce(array_agg(distinct g.scope_id), '{}') into v_cells
    from app.identity_grants g
   where g.member_id = p_member and g.revoked_at is null
     and g.scope_kind in ('cell_leader', 'cell_assistant');
  if cardinality(v_cells) = 0 then
    return '[]'::jsonb;
  end if;
  v_counts := app.duties_overlap_counts(array(
    select o.occurrence_id from app.duties_occurrences o
     where o.cell_id = any (v_cells) and o.occurrence_state = 'published'
       and o.starts_at >= p_lo and o.starts_at < p_hi and app.duties_occurrence_start(o) > now()));
  with cc as (
    select c.cell_id, app.duties_cell_capacity(p_member, c.cell_id) as scope_kind
      from unnest(v_cells) c(cell_id)
  ), base as (
    select o.cell_id, o.occurrence_id, s.slot_id, a.assignment_id, a.member_id, c.case_id,
           l.attempt_id, cc.scope_kind, x.status, x.needs_contact,
           coalesce((v_counts ->> s.slot_id::text)::integer, 0) as overlaps,
           c.case_id is not null and l.next_follow_up_at <= now() as follow_up_overdue,
           x.vacated_since, x.vacancy_reason,
           row_number() over (partition by o.cell_id
                              order by o.starts_at, o.occurrence_id, s.position_no) as rn
      from cc
      join app.duties_occurrences o on o.cell_id = cc.cell_id
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
          case when a.assignment_id is null then app.duties_vacated_since(s.slot_id) end as vacated_since,
          case when a.assignment_id is null then app.duties_vacancy_reason(s.slot_id) end as vacancy_reason) x
     where o.occurrence_state = 'published' and o.starts_at >= p_lo and o.starts_at < p_hi
       and app.duties_occurrence_start(o) > now()
       and (p_duty is null or position(lower(p_duty) in lower(o.duty_name)) > 0)
  ), pos as (
    select b.cell_id, b.rn,
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
             'vacated', case when b.vacated_since is not null
                             then jsonb_build_object('since', app.cmd_utc(b.vacated_since),
                                                     'reason', b.vacancy_reason) end,
             'overlaps', b.overlaps,
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
               'note', a.response_note,
               'confirmation', case when a.response_provenance = 'leader' then jsonb_build_object(
                                 'by', app.duties_display_name(a.responded_by_member),
                                 'at', app.cmd_utc(a.responded_at),
                                 'channel', a.confirmed_channel,
                                 'reason', a.confirmed_reason) end,
               'changes', case when b.status = 'changed'
                               then to_jsonb(app.duties_changes_since(s.slot_id, a.slot_revision - 1,
                                                                       a.slot_revision)) end) end,
             'follow_up', case when c.case_id is not null then jsonb_build_object(
               'case_id', c.case_id,
               'task_id', c.task_id,
               'opened_at', app.cmd_utc(c.opened_at),
               'attempts', (select count(*) from app.duties_contact_attempts t where t.case_id = c.case_id),
               'next_follow_up_at', app.cmd_utc(l.next_follow_up_at),
               'overdue', l.next_follow_up_at <= now(),
               'last_attempt', jsonb_build_object(
                 'at', app.cmd_utc(l.recorded_at),
                 'by', app.duties_display_name(l.recorded_by_member),
                 'channel', l.channel,
                 'outcome', l.outcome,
                 'note', l.note)) end) as obj
      from base b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      join app.duties_slots s on s.slot_id = b.slot_id
      left join app.duties_assignments a on a.assignment_id = b.assignment_id
      left join app.duties_coverage_cases c on c.case_id = b.case_id
      left join app.duties_contact_attempts l on l.attempt_id = b.attempt_id
     where b.rn <= 1000
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'cell_id', cc.cell_id,
      'capacity', cc.scope_kind,
      'view', 'full',
      'can_manage', false,
      'can_contact', true,
      'truncated', (select count(*) > 1000 from base r where r.cell_id = cc.cell_id),
      'counts', (select jsonb_build_object(
                   'required', count(*),
                   'confirmed', count(*) filter (where r.status = 'confirmed'),
                   'unfilled', count(*) filter (where r.status = 'unfilled'),
                   'awaiting', count(*) filter (where r.status = 'awaiting'),
                   'overdue', count(*) filter (where r.status = 'overdue'),
                   'declined', count(*) filter (where r.status in ('declined', 'changed')),
                   'needs_contact', count(*) filter (where r.needs_contact is not null),
                   'conflicts', count(*) filter (where r.overlaps > 0 and r.status <> 'unfilled'),
                   'overdue_follow_ups', count(*) filter (where r.follow_up_overdue),
                   'vacated', count(*) filter (where r.vacated_since is not null))
                   from base r where r.cell_id = cc.cell_id),
      'contact_routes', app.identity_scoped_contact_routes(p_member, cc.scope_kind, cc.cell_id, array(
          select distinct r.member_id from base r
           where r.cell_id = cc.cell_id and r.member_id is not null
             and r.status <> 'confirmed' and r.rn <= 1000)),
      'positions', coalesce((select jsonb_agg(r.obj order by r.rn) from pos r
                              where r.cell_id = cc.cell_id), '[]'::jsonb))
      order by cc.cell_id), '[]'::jsonb)
    into v_result
    from cc;
  return v_result;
end;
$$;

comment on function app.duties_cell_coverage_json(uuid, timestamptz, timestamptz, text) is
  'Coverage for cells: the coverage queue of the cells the member leads or assists.';

-- The outcomes read's `cells`: for each cell the member leads or assists now, its started
-- published programme parts in [p_lo, p_hi) (latest first, at most 1000 per cell) with each
-- position's response and outcome, and the cell's totals (never per member).
create function app.duties_cell_outcomes_json(p_member uuid, p_lo timestamptz, p_hi timestamptz,
                                              p_duty text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with cc as (
    select distinct g.scope_id as cell_id
      from app.identity_grants g
     where g.member_id = p_member and g.revoked_at is null
       and g.scope_kind in ('cell_leader', 'cell_assistant')
  ), base as (
    select o.cell_id, o.occurrence_id, s.slot_id, a.assignment_id, a.response, x.outcome,
           row_number() over (partition by o.cell_id
                              order by o.starts_at desc, o.occurrence_id, s.position_no) as rn
      from cc
      join app.duties_occurrences o on o.cell_id = cc.cell_id
      join app.duties_slots s on s.occurrence_id = o.occurrence_id and s.cancelled_at is null
      left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
      left join lateral (select y.outcome from app.duties_outcomes y
                          where y.assignment_id = a.assignment_id
                          order by y.revision desc limit 1) x on true
     where o.occurrence_state = 'published'
       and o.starts_at >= p_lo and o.starts_at < p_hi
       and app.duties_occurrence_start(o) <= now()
       and (p_duty is null or position(lower(p_duty) in lower(o.duty_name)) > 0)
  ), pos as (
    select b.cell_id, b.rn, jsonb_build_object(
             'slot_id', s.slot_id,
             'position_no', s.position_no,
             'position_name', s.position_name,
             'occurrence_id', o.occurrence_id,
             'duty_name', o.duty_name,
             'starts_at', app.cmd_utc(o.starts_at),
             'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
             'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
             'location', o.location,
             'assignment', case when a.assignment_id is not null then jsonb_build_object(
               'assignment_id', a.assignment_id,
               'revision', a.revision,
               'member_id', a.member_id,
               'display_name', app.duties_display_name(a.member_id),
               'own', a.member_id = p_member,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               'outcome_state', coalesce(b.outcome, 'unrecorded'),
               'outcome', app.duties_outcome_json(a.assignment_id, 20),
               'allowed', app.duties_outcomes_allowed(a.response)) end) as obj
      from base b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      join app.duties_slots s on s.slot_id = b.slot_id
      left join app.duties_assignments a on a.assignment_id = b.assignment_id
     where b.rn <= 1000
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'cell_id', cc.cell_id,
      'capacity', app.duties_cell_capacity(p_member, cc.cell_id),
      'counts', (select jsonb_build_object(
                   'positions', count(*),
                   'unfilled', count(*) filter (where r.assignment_id is null),
                   'unrecorded', count(*) filter (where r.assignment_id is not null and r.outcome is null),
                   'completed', count(*) filter (where r.outcome = 'completed'),
                   'excused', count(*) filter (where r.outcome = 'excused'),
                   'no_show', count(*) filter (where r.outcome = 'no_show'))
                   from base r where r.cell_id = cc.cell_id),
      'positions', coalesce((select jsonb_agg(p.obj order by p.rn) from pos p
                              where p.cell_id = cc.cell_id), '[]'::jsonb))
      order by cc.cell_id), '[]'::jsonb)
    from cc;
$$;

comment on function app.duties_cell_outcomes_json(uuid, timestamptz, timestamptz, text) is
  'Coverage for cells: the outcomes of the started programme parts of the member''s cells.';

-- ---------------------------------------------------------------------------------------------
-- Coverage for cells: registrations
-- ---------------------------------------------------------------------------------------------

-- The coverage follow-up purpose also in a cell's scope (its leader and assistant supervise each
-- other's tasks: the registered `cell` family).
select app.followups_register_purpose(
  'duties', 'duties_coverage_case', 'coverage_follow_up',
  '{"label": "Duty cover follow-up",
    "scope_kinds": ["department_leader", "department_deputy", "cell_leader", "cell_assistant"],
    "outcomes": ["no_answer", "left_message", "will_answer", "cannot_serve", "other"],
    "on_source_resolved": "close", "on_source_cancelled": "close", "manual_create": false}',
  'app.duties_coverage_case_context(jsonb)'::regprocedure);

-- The cell leaders' alerts: the same checks, generic text, opening Coverage.
select app.contract_register_reminder_kind('duties', 'duties_coverage', 'cell_part_response_overdue');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'cell_part_response_overdue',
  'app.duties_coverage_reminder_check(jsonb)'::regprocedure,
  '{"title": "Cell part answer overdue",
    "body": "A part in your cell''s programme passed its answer-by time without an answer. Open Coverage to follow it up.",
    "link": "/duties/coverage"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_coverage', 'cell_part_short_notice');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'cell_part_short_notice',
  'app.duties_coverage_reminder_check(jsonb)'::regprocedure,
  '{"title": "Short-notice cell part",
    "body": "A part in your cell''s programme was given at short notice and needs an answer now. Contact the member directly.",
    "link": "/duties/coverage"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_coverage', 'cell_part_declined');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'cell_part_declined',
  'app.duties_decline_alert_check(jsonb)'::regprocedure,
  '{"title": "Cell part declined",
    "body": "A member cannot take their part in your cell''s programme. Open Coverage to find cover.",
    "link": "/duties/coverage"}'::jsonb);

revoke all on function
  app.duties_cell_capacity(uuid, uuid),
  app.duties_owner_capacity(uuid, app.duties_occurrences),
  app.duties_cell_coverage_json(uuid, timestamptz, timestamptz, text),
  app.duties_cell_outcomes_json(uuid, timestamptz, timestamptz, text)
  from public, anon, authenticated, service_role;

comment on function api.duties_coverage(date, date, uuid, text) is
  'Story 4.9: the coverage queue of the departments the caller leads or deputises (Admin and '
  'Pastor: every department, operational view) and, coverage for cells, of the cells the caller '
  'leads or assists.';
comment on function api.duties_outcomes(date, date, uuid, text) is
  'Story 4.10: the started duties of the departments the caller leads or deputises and, coverage '
  'for cells, of the cells the caller leads or assists, with each position''s response and '
  'completion outcome or unrecorded, its correction trail and counts.';

notify pgrst, 'reload schema';
