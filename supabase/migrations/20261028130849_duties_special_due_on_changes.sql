-- Review finding F7 (2026-10-28): a special assignment's due date and timing mode are part of
-- change detection. Changing a "done by" assignment into an appointment at 18:00 church time on
-- the same date with no end (or the reverse) left starts_at and ends_at equal, so the 4.2 change
-- engine saw no change: alone it was refused as unchanged; with a notes change it went through as
-- notes, without asking the member again and without the overlap check.
--
--   * `due_on` is a slot field (app.duties_state_ok) of class material
--     (app.duties_slot_field_class).
--   * app.duties_apply_change (replaced from 20261021211830) compares due_on: a due date given,
--     removed or moved is material (the member answers again with a new answer-by time and gets
--     the duty_changed notice), and part of the time window, so an earlier overlap override is
--     not carried and a new appointment's overlap needs a reason (or is refused without one).
--   * Revision history: app.duties_slot_revisions gains a nullable due_on column, written by every
--     change and by duties.give_special (app.duties_give_special, replaced from 20261021211830)
--     for revision 1. Earlier rows keep null (their starts_at holds the due moment).
--   * Pure notes changes are unchanged (no due_on difference, class notes).
--
-- Replaced bodies are copied from their latest version; the changes are marked "Review finding
-- F7". No destructive statement, no row deletion. ASCII only, no backslashes.

-- (Replaced; copied from 20261021211830_duties_special_assignments.sql.)
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
    -- Special assignments: `pastor`.
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member',
                                     'cell_leader', 'cell_assistant', 'lifecycle', 'pastor')
    when 'change_class' then p_value in ('published', 'material', 'notes', 'reference', 'cancelled',
                                         'vacated')
    -- Review finding F7: `due_on`, a special assignment's due date or timing mode.
    when 'slot_field' then p_value in ('duty_name', 'starts_at', 'ends_at', 'reporting_at',
                                       'location', 'member_id', 'instructions', 'topic',
                                       'scripture', 'event_ref', 'position_name', 'due_on')
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

-- (Replaced; copied from 20261014023442_duties_rota_series.sql.) Review finding F7: due_on is
-- material.
create or replace function app.duties_slot_field_class(p_field text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_field in ('duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id',
                     'position_name', 'due_on')
      then 'material'
    when p_field in ('instructions', 'topic', 'scripture') then 'notes'
    when p_field = 'event_ref' then 'reference'
    when p_field = 'response_deadline' then 'assignment'
  end;
$$;

alter table app.duties_slot_revisions add column due_on date;

comment on column app.duties_slot_revisions.due_on is
  'Review finding F7: the due date of a special assignment at this revision (null: a fixed time, '
  'or a row written before this column).';

-- (Replaced; copied from 20261021211830_duties_special_assignments.sql.) Review finding F7: the
-- due date is compared, recorded and part of the window.
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
  -- Story 4.8: the deadline every new assignment of this change takes, where it came from and
  -- whether it is Short notice.
  v_deadline timestamptz := p_deadline;
  v_deadline_source text := 'creator';
  v_short boolean := false;
  v_default jsonb;
  v_notice text;
  r record;
begin
  -- Story 4.9 review S1: the change's actor for app.duties_notify.
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  if p_member_given then
    -- Story 4.9: a cancelled position is never given again.
    if exists (select 1 from app.duties_slots s
                where s.slot_id = p_target_slot and s.cancelled_at is not null) then
      perform app.cmd_fail('validation_failed', '{"slot_id": "cancelled"}');
    end if;
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
  -- Review finding F7: a due date given, removed or moved is a change of its own, even when the
  -- due moment equals the old start (a deadline that becomes an appointment at 18:00 the same day,
  -- or the reverse): the obligation changed, so it is material and part of the window.
  if p_new.due_on is distinct from p_old.due_on then
    v_changed := array_append(v_changed, 'due_on');
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
  v_window_changed := v_changed && array['starts_at', 'due_on', 'ends_at', 'reporting_at'];
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

  -- A new pending assignment takes the leader's answer-by, or (story 4.8) without one the shared
  -- 3.3 lead-time default for an assignment made now: Short notice when that has already passed.
  -- Story 4.11: releasing a cell part's member (no new member) asks nobody.
  v_need_deadline := (v_member_changed and (p_member is not null or p_old.cell_id is null))
    or (v_occ_material and exists (
          select 1 from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
           where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'));
  if v_need_deadline then
    if p_deadline is null then
      v_default := app.duties_default_deadline(v_start);
      v_deadline := (v_default ->> 'response_deadline')::timestamptz;
      v_deadline_source := 'default';
      v_short := (v_default ->> 'short_notice')::boolean;
    elsif p_deadline <= now() then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key,
        case when p_deadline_key = 'deadline_before' then 'passed' else 'past' end));
    elsif p_deadline >= v_start then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key, 'after_start'));
    end if;
  end if;
  -- Who will be asked: a new assignee must serve in the department; a kept assignee who can no
  -- longer serve (erased, left, under deletion) needs reassignment first (fail closed).
  if v_member_changed and p_old.department_id is null then
    -- Story 4.11: a cell part asks an active member (the cell's roster is its owner's check, in
    -- the caller's transaction); no member leaves a visible gap. Special assignments: a special
    -- assignment asks an active member (it has no roster).
    if p_member is not null and not app.duties_member_active(p_member) then
      perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
    end if;
  elsif v_member_changed and not app.duties_can_serve(p_member, p_old.department_id) then
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
      if p_old.department_id is null then
        -- Story 4.11: a kept cell part member must still be an active member. Special
        -- assignments: likewise.
        if not app.duties_member_active(r.member_id) then
          perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
        end if;
      else
        perform 1 from app.duties_department_members dm
         where dm.department_id = p_old.department_id and dm.member_id = r.member_id
           and dm.ended_at is null for share;
        if not (found and app.duties_member_active(r.member_id)) then
          perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
        end if;
      end if;
    end loop;
  end if;
  if v_member_changed and p_old.department_id is not null then
    perform 1 from app.duties_department_members dm
     where dm.department_id = p_old.department_id and dm.member_id = p_member
       and dm.ended_at is null for share;
  end if;

  update app.duties_occurrences o
     set duty_name = p_new.duty_name, starts_at = p_new.starts_at, ends_at = p_new.ends_at,
         reporting_at = p_new.reporting_at, location = p_new.location,
         instructions = p_new.instructions, topic = p_new.topic, scripture = p_new.scripture,
         event_ref = p_new.event_ref, due_on = p_new.due_on, revision = o.revision + 1
   where o.occurrence_id = p_old.occurrence_id
  returning o.revision into v_revision;

  -- Story 4.9: cancelled positions are left as they are (no revision, no assignment).
  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_old.occurrence_id
                   and s.cancelled_at is null
                 order by s.position_no for update loop
    v_is_target := v_member_changed and v_slot.slot_id = p_target_slot;
    v_slot_changed := v_changed;
    if v_is_target then
      v_slot_changed := (select coalesce(array_agg(f order by array_position(
                            array['duty_name', 'starts_at', 'due_on', 'ends_at', 'reporting_at',
                                  'location', 'member_id', 'instructions', 'topic', 'scripture',
                                  'event_ref'], f)), '{}')
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
                                          override_by_account, override_at, deadline_source,
                                          short_notice)
      values (v_slot.slot_id, v_new_member, v_deadline, p_actor_member, p_actor_account,
              v_slot_revision, v_old.assignment_id,
              case when v_carry then v_old.override_reason end,
              case when v_carry then v_old.override_overlaps end,
              case when v_carry then v_old.override_by_member end,
              case when v_carry then v_old.override_by_account end,
              case when v_carry then v_old.override_at end, v_deadline_source, v_short)
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
                                           created_by_account, command_request_id, due_on)
    values (v_slot.slot_id, v_slot_revision, p_old.occurrence_id, v_revision,
            case when v_slot_material then 'material' else v_class end, v_slot_changed,
            p_new.duty_name, p_new.starts_at, p_new.ends_at, p_new.reporting_at, p_new.location,
            p_new.instructions, p_new.topic, p_new.scripture, p_new.event_ref, v_current_member,
            v_current, v_current_deadline, p_actor_member, p_actor_account, v_request,
            p_new.due_on);
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
      v_notice := null;
      if v_current is not null and app.duties_notice_recipient(v_current_member) then
        v_notice := case when v_current_member = v_old.member_id then 'duty_changed'
                         else 'duty_assigned' end;
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_current, 'source_revision', 1,
            'recipient_member_id', v_current_member,
            'reminder_kind', v_notice,
            'scheduled_at', app.cmd_utc(now()))));
      end if;
      -- Story 4.8: the new assignment's reminders and its leaders' alert (a fresh plan; on Short
      -- notice the notice above is the member's "respond now").
      if v_current is not null then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'plan', 'assignment_id', v_current, 'fresh', true, 'notice', v_notice));
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

-- (Replaced; copied from 20261021211830_duties_special_assignments.sql.) Review finding F7:
-- revision 1 records the due date.
create or replace function app.duties_give_special(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_member uuid;
  v_name text;
  v_location text;
  v_instructions text;
  v_reason text;
  v_deadline timestamptz;
  v_timing record;
  v_occurrence uuid;
  v_slot uuid;
  v_assignment uuid;
  v_overlaps integer;
  v_default jsonb;
  v_source text := 'creator';
  v_short boolean := false;
  v_notified jsonb;
  v_cmd constant text := 'duties.give_special';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['member_id', 'duty_name', 'starts_at', 'ends_at', 'due_on', 'location',
                      'instructions', 'response_deadline', 'override_reason']);
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  select t.errors, t.value into v_errors, v_location
    from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_instructions
    from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_payload, 'response_deadline', false, v_errors) t;
  select t.* into v_timing from app.duties_special_timing(p_payload, true, v_errors) t;
  v_errors := v_timing.errors;
  if v_timing.starts_at is not null and v_deadline is not null then
    -- A Pastor's answer-by is never in the past or at or after the start (the due moment).
    if v_deadline <= now() then
      v_errors := v_errors || '{"response_deadline": "past"}';
    elsif v_deadline >= v_timing.starts_at then
      v_errors := v_errors || '{"response_deadline": "after_start"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  if not app.identity_member_has_role(v_actor.member_id, 'pastor') then
    perform app.cmd_fail('forbidden');
  end if;
  if v_member = v_actor.member_id then
    perform app.cmd_fail('validation_failed', '{"member_id": "own"}');
  end if;
  -- Story 4.4: the member's assignments are serialised before the overlap check.
  perform app.duties_lock_members(array[v_member]);
  if v_member = '00000000-0000-0000-0000-000000000000'::uuid
     or not app.duties_member_active(v_member) then
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  if v_deadline is null then
    v_default := app.duties_default_deadline(v_timing.starts_at);
    v_deadline := (v_default ->> 'response_deadline')::timestamptz;
    v_source := 'default';
    v_short := (v_default ->> 'short_notice')::boolean;
  end if;
  insert into app.duties_occurrences (special, duty_name, starts_at, ends_at, due_on, location,
                                      instructions, created_by_member, created_by_account)
  values (true, v_name, v_timing.starts_at, v_timing.ends_at, v_timing.due_on, v_location,
          v_instructions, v_actor.member_id, v_actor.account_id)
  returning occurrence_id into v_occurrence;
  insert into app.duties_slots (occurrence_id, position_no) values (v_occurrence, 1)
  returning slot_id into v_slot;
  insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                      assigned_by_account, deadline_source, short_notice)
  values (v_slot, v_member, v_deadline, v_actor.member_id, v_actor.account_id, v_source, v_short)
  returning assignment_id into v_assignment;
  -- Story 4.2: slot revision 1 records what was given.
  insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                         occurrence_revision, change_class, duty_name, starts_at,
                                         ends_at, location, instructions, member_id, assignment_id,
                                         response_deadline, created_by_member, created_by_account,
                                         command_request_id, due_on)
  values (v_slot, 1, v_occurrence, 1, 'published', v_name, v_timing.starts_at, v_timing.ends_at,
          v_location, v_instructions, v_member, v_assignment, v_deadline, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(p_actor, v_cmd), v_timing.due_on);
  perform app.duties_audit_event('duty_published', v_actor.member_id, v_actor.account_id,
                                 'pastor', v_cmd, null, v_occurrence, v_assignment, v_member,
                                 'special', 1);
  -- Story 4.4: an overlap needs the reason (everything above rolls back without one).
  v_overlaps := app.duties_overlap_gate(v_assignment, v_reason, v_actor.member_id,
                                        v_actor.account_id, now(), v_actor.member_id,
                                        v_actor.account_id, 'pastor', v_cmd, null);
  -- Notifications last (AD-2): the new-duty notice, then the member's reminders (no leader
  -- alert: leader alerts are department-only).
  v_notified := app.duties_notify(jsonb_build_array(
    jsonb_build_object('op', 'enqueue', 'counts', true, 'key', jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
      'recipient_member_id', v_member, 'reminder_kind', 'duty_assigned',
      'scheduled_at', app.cmd_utc(now()))),
    jsonb_build_object('op', 'plan', 'assignment_id', v_assignment, 'fresh', true,
                       'notice', 'duty_assigned')));
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', 1,
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence, 'revision', 1, 'slot_id', v_slot,
              'assignment_id', v_assignment, 'assignment_revision', 1, 'response', 'pending',
              'timing', case when v_timing.due_on is not null then 'due' else 'time' end,
              'notice_queued', (v_notified ->> 'queued')::integer > 0,
              'override_recorded', v_overlaps > 0));
end;
$$;
