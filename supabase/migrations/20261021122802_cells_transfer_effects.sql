-- Story 5.9: apply cell transfer, removal and deletion to programmes and cell duties (epic 5, C9).
-- Builds on 20261021115855_cells_meeting_records.sql.
--
--   * A transfer (cells.confirm_request ending the member's old membership; the only membership
--     end, 2.6) now ends their old-cell work in the same transaction:
--       - the member leaves every future programme part of the old cell (draft and published): the
--         part becomes a gap and the published projection stops naming them; each such programme
--         takes a new revision (an open editor conflicts instead of saving them back);
--       - their current assignments on the old cell's future published parts end through Duties
--         (app.duties_owner_vacate_member, a Duties contract change: vacated, position unfilled,
--         jobs cancelled, duty_released to the member);
--       - their open Cannot attend notices in the old cell close (withdrawn, `left_cell`), with any
--         notice still waiting for the leaders cancelled and nothing announced;
--       - the old cell's leader and assistant get one generic notice per published programme that
--         lost a person ("A part needs someone", link /cells/meetings).
--     Old-cell reads were already refused at once (current membership); actual-leader records
--     (5.8) and started meetings are past facts and stay.
--   * Cells handover hook app.cells_report_handover: `cell_leader` (subject = cell, last
--     responsible) when the member is the last reachable leader or assistant of an active cell with
--     a published programme for a meeting ahead. cells.resolve_handover {cell_id} (Admin; cell
--     revision) resolves a recorded obligation once the cell has a reachable leader again. The
--     Admin cells read shows `handover_pending`.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

alter table app.cells_absence_notices
  add column withdrawn_reason text check (withdrawn_reason is null or withdrawn_reason = 'left_cell');

comment on column app.cells_absence_notices.withdrawn_reason is
  'Story 5.9: null when the member withdrew it (or it was erased); left_cell when a transfer closed it.';

-- ---------------------------------------------------------------------------------------------
-- Duties contract change: vacate a member's cell parts (called by Cells inside its transfer)
-- ---------------------------------------------------------------------------------------------


-- The 4.16 app.duties_vacate_member scoped to the given occurrences of one cell's own parts: the
-- member's current assignments on the cell's future published parts end (`superseded`,
-- `vacated`, no vacancy reason: Cells tells its leaders itself), their planned positions there are
-- cleared, jobs cancelled, coverage cases closed, and p_release sends `duty_released`. Same lock
-- order and set-based statements as the department version.
create function app.duties_vacate_cell_member(p_member uuid, p_cell uuid, p_occurrences uuid[],
                                              p_code text,
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
     and o.cell_id = p_cell and o.occurrence_id = any (p_occurrences);
  select coalesce(array_agg(distinct o.occurrence_id), '{}') into v_draft
    from app.duties_slots s
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.draft_member_id = p_member and o.occurrence_state = 'draft'
     and app.duties_occurrence_start(o) > now()
     and o.cell_id = p_cell and o.occurrence_id = any (p_occurrences);
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
     and o.cell_id = p_cell and o.occurrence_id = any (p_occurrences)
     and not (s.occurrence_id = any (v_all));
  if cardinality(v_more) > 0 then
    perform 1 from app.duties_occurrences o where o.occurrence_id = any (v_more)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
       for update;
    perform 1 from app.duties_slots s where s.occurrence_id = any (v_more)
     order by s.occurrence_id, s.position_no for update;
    v_all := v_all || v_more;
  end if;
  select coalesce(array_agg(x.assignment_id order by x.assignment_id), '{}') into v_ids
    from (select a.assignment_id
            from app.duties_assignments a
            join app.duties_slots s on s.slot_id = a.slot_id
            join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
           where a.member_id = p_member and a.assignment_state = 'current'
             and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
             and o.cell_id = p_cell and o.occurrence_id = any (p_occurrences)
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
                                            p_capacity, p_command, null, p_member);
  return jsonb_build_object('vacated', jsonb_array_length(v_ended), 'drafts_cleared', v_drafts,
                            'occurrence_ids', (select coalesce(jsonb_agg(distinct x ->> 'occurrence_id'), '[]'::jsonb)
                                                 from jsonb_array_elements(v_ended) x),
                            'leader_alerts', v_alerts, 'released', v_released,
                            'notices_skipped', (v_notified ->> 'skipped')::boolean);
end;
$$;

-- The Duties owner operation: {cell_id, member_id, occurrence_ids}. Ends the member's current
-- assignments on those of the cell's own published parts that have not started and clears their
-- planned positions there (the 4.12 vacate, scoped to one cell and to the occurrences its owner
-- names, so both sides agree on what is still ahead). Not client-executable; the caller is Cells' transfer, inside its own
-- transaction after its own rows are locked, with the transfer's actor (who need not lead the
-- old cell: the 4.11 session rule is replaced for this operation only). Answers counts.
create function app.duties_owner_vacate_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
begin
  if jsonb_typeof(p_input) is distinct from 'object'
     or app.contract_uuid_error(p_input -> 'cell_id') is not null
     or app.contract_uuid_error(p_input -> 'member_id') is not null
     or jsonb_typeof(p_input -> 'occurrence_ids') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements(p_input -> 'occurrence_ids') e
                 where app.contract_uuid_error(e) is not null) then
    perform app.cmd_fail('validation_failed', '{"input": "invalid"}');
  end if;
  select a.* into v_actor from app.duties_lifecycle_actor() a;
  return app.duties_vacate_cell_member((p_input ->> 'member_id')::uuid, (p_input ->> 'cell_id')::uuid,
                                       array(select (e #>> '{}')::uuid
                                               from jsonb_array_elements(p_input -> 'occurrence_ids') e),
                                       'cell_transferred', true, v_actor.member_id, v_actor.account_id,
                                       'lifecycle', 'cells.confirm_request');
end;
$$;

comment on function app.duties_owner_vacate_member(jsonb) is
  'Duties owner operation (story 5.9 contract change): Cells ends a transferred member''s future '
  'cell-part assignments of their old cell (vacated, duty_released) inside its transfer.';

-- ---------------------------------------------------------------------------------------------
-- Cells: the leaders' notice that a published part lost its person
-- ---------------------------------------------------------------------------------------------

create function app.cells_programme_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object('current', p.revision = (p_source ->> 'source_revision')::numeric::bigint,
                              'revision', p.revision)
      from app.cells_programmes p where p.programme_id::text = p_source ->> 'source_id'),
    '{"current": false, "revision": null}'::jsonb);
$$;

-- Current: the programme is at the job's revision. Actionable: it is published, its meeting is on
-- and ahead, and a part still has nobody. Eligible: the recipient leads or assists the cell.
create function app.cells_programme_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_programme app.cells_programmes;
  v_current boolean;
begin
  select p.* into v_programme from app.cells_programmes p where p.programme_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  v_current := v_programme.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_programme.revision,
    'actionable', v_current and v_programme.programme_state = 'published'
                  and exists (select 1 from app.cells_meetings m
                               where m.meeting_id = v_programme.meeting_id and m.starts_at > now()
                                 and m.meeting_state in ('scheduled', 'moved'))
                  and exists (select 1 from app.cells_programme_parts pt
                               where pt.programme_id = v_programme.programme_id and pt.removed_at is null
                                 and pt.assignee_member_id is null and pt.linked_slot_id is null),
    'recipient_eligible', app.cells_programme_capacity((p_key ->> 'recipient_member_id')::uuid,
                                                       v_programme.cell_id) is not null);
end;
$$;

select app.contract_register_source_type(
  'cells', 'cells_programme', 'app.cells_programme_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('cells', 'cells_programme', 'cells_part_vacated');
select app.contract_register_reminder_contract(
  'cells', 'cells_programme', 'cells_part_vacated',
  'app.cells_programme_reminder_check(jsonb)'::regprocedure,
  '{"title": "A part needs someone",
    "body": "A part of a published cell programme has nobody now. Open Cell meetings to plan it again.",
    "link": "/cells/meetings"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- The transfer's effects on the old cell
-- ---------------------------------------------------------------------------------------------

-- Called by cells.confirm_request after the old membership ended. Only meetings that have not
-- started count (review fix 2: the same cut-off on both sides). Lock order (AD-2): the meetings
-- (share), their programmes and parts (update), the member's notices (update and audit, review fix
-- 3 and 4), then Duties for exactly those meetings' part occurrences, then Notifications. Every Cells
-- row it writes after Duties is already locked. Answers counts.
create function app.cells_transfer_effects(p_member uuid, p_old_cell uuid, p_actor_member uuid,
                                           p_actor_account uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_meetings uuid[];
  v_programmes uuid[];
  v_occurrences uuid[];
  v_notices uuid[];
  v_cleared uuid[];
  v_unnamed uuid[];
  v_changed uuid[];
  v_published uuid[];
  v_duties jsonb;
  v_id uuid;
  v_leader uuid;
  v_told integer := 0;
  v_message text;
  v_programme app.cells_programmes;
begin
  select coalesce(array_agg(m.meeting_id order by m.meeting_id), '{}') into v_meetings
    from (select m.meeting_id from app.cells_meetings m
           where m.cell_id = p_old_cell and m.starts_at > now() and m.meeting_state <> 'withdrawn'
           order by m.meeting_id for share) m;
  select coalesce(array_agg(p.programme_id order by p.programme_id), '{}') into v_programmes
    from (select p.programme_id from app.cells_programmes p
           where p.meeting_id = any (v_meetings) and p.programme_state in ('draft', 'published')
           order by p.programme_id for update) p;
  select coalesce(array_agg(pt.duty_occurrence_id order by pt.part_id) filter (where pt.duty_occurrence_id is not null), '{}')
    into v_occurrences
    from (select pt.part_id, pt.duty_occurrence_id from app.cells_programme_parts pt
           where pt.programme_id = any (v_programmes)
           order by pt.programme_id, pt.part_id for update) pt;

  -- The member's open notices for meetings still ahead close (meetings that happened keep theirs),
  -- each with its audit row like any other change.
  with n as (
    update app.cells_absence_notices n
       set notice_state = 'withdrawn', withdrawn_reason = 'left_cell', withdrawn_at = now(),
           revision = n.revision + 1, updated_at = now()
     where n.member_id = p_member and n.notice_state = 'open' and n.meeting_id = any (v_meetings)
    returning n.*)
  , a as (
    insert into app.cells_absence_audit (action, notice_id, meeting_id, cell_id, actor_member_id,
                                         actor_account_id, command_request_id, revision_after)
    select 'notice_withdrawn', n.notice_id, n.meeting_id, n.cell_id, p_actor_member, p_actor_account,
           app.cmd_current_request_id(p_actor_account, 'cells.confirm_request'), n.revision
      from n
    returning notice_id)
  select coalesce(array_agg(a.notice_id order by a.notice_id), '{}') into v_notices from a;

  -- Duties: the member's assignments on those parts end; the answer names the occurrences ended.
  v_duties := app.duties_owner_vacate_member(jsonb_build_object(
    'cell_id', p_old_cell, 'member_id', p_member, 'occurrence_ids', to_jsonb(v_occurrences)));

  -- The plan: the member leaves every part they are planned for (draft text, published or not).
  with c as (
    update app.cells_programme_parts pt set assignee_member_id = null, updated_at = now()
     where pt.programme_id = any (v_programmes) and pt.removed_at is null and pt.assignee_member_id = p_member
    returning pt.programme_id)
  select coalesce(array_agg(distinct c.programme_id), '{}') into v_cleared from c;
  -- What members read: only the parts whose duty the member actually held (review fix 1), so a
  -- name published for someone else stays and the member's published name goes.
  select coalesce(array_agg(pt.part_id), '{}') into v_unnamed
    from app.cells_programme_parts pt
   where pt.programme_id = any (v_programmes)
     and pt.duty_occurrence_id::text in (select jsonb_array_elements_text(coalesce(v_duties -> 'occurrence_ids', '[]'::jsonb)));
  update app.cells_programme_projections pr
     set body = jsonb_set(pr.body, '{parts}', coalesce((
           select jsonb_agg(case when (t.e ->> 'part_id')::uuid = any (v_unnamed)
                                 then t.e || '{"leader": null}'::jsonb else t.e end order by t.o)
             from jsonb_array_elements(pr.body -> 'parts') with ordinality t(e, o)), '[]'::jsonb))
   where pr.withdrawn_at is null
     and pr.programme_id in (select pt.programme_id from app.cells_programme_parts pt where pt.part_id = any (v_unnamed));
  v_changed := array(select distinct x from unnest(v_cleared || array(
                       select pt.programme_id from app.cells_programme_parts pt where pt.part_id = any (v_unnamed))) x
                     order by x);
  update app.cells_programmes p set revision = p.revision + 1, updated_at = now()
   where p.programme_id = any (v_changed);
  v_published := array(select p.programme_id from app.cells_programmes p
                        where p.programme_id = any (v_changed) and p.programme_state = 'published'
                          and p.programme_id in (select pt.programme_id from app.cells_programme_parts pt
                                                  where pt.part_id = any (v_unnamed))
                        order by p.programme_id);

  -- Notifications last: the closed notices' waiting jobs are cancelled; the leaders are told about
  -- each published programme that lost its person.
  foreach v_id in array v_notices loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'cells_absence_notice', 'source_id', v_id, 'reason', 'source_cancelled'));
  end loop;
  begin
    foreach v_id in array v_published loop
      select p.* into v_programme from app.cells_programmes p where p.programme_id = v_id;
      perform app.notifications_cancel(jsonb_build_object(
        'source_type', 'cells_programme', 'source_id', v_id, 'reason', 'source_revised'));
      for v_leader in
        select distinct g.member_id from app.identity_grants g
         where g.revoked_at is null and g.scope_kind in ('cell_leader', 'cell_assistant')
           and g.scope_id = p_old_cell and g.member_id <> p_member
         order by g.member_id
      loop
        perform app.notifications_enqueue(jsonb_build_object(
          'source_type', 'cells_programme', 'source_id', v_id, 'source_revision', v_programme.revision,
          'recipient_member_id', v_leader, 'reminder_kind', 'cells_part_vacated',
          'scheduled_at', app.cmd_utc(now())));
        v_told := v_told + 1;
      end loop;
    end loop;
  exception when sqlstate 'PCMD1' then
    -- Without the Q2 policy no notice can be planned; the transfer itself never waits on it.
    get stacked diagnostics v_message = message_text;
    if v_message is distinct from 'unavailable' then
      raise;
    end if;
    v_told := 0;
  end;
  return jsonb_build_object('parts_cleared', cardinality(v_cleared), 'programmes', cardinality(v_changed),
                            'duties_vacated', coalesce((v_duties ->> 'vacated')::integer, 0),
                            'notices_closed', cardinality(v_notices), 'leaders_told', v_told);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Handover: the last leader of a cell with a published programme ahead
-- ---------------------------------------------------------------------------------------------

-- Does the cell have a leader or assistant who is approved and reachable in the app now (other
-- than p_except)?
create function app.cells_has_reachable_leader(p_cell_id uuid, p_except uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_grants g
                  join app.identity_members m on m.member_id = g.member_id
                 where g.revoked_at is null and g.scope_id = p_cell_id
                   and g.scope_kind in ('cell_leader', 'cell_assistant')
                   and g.member_id is distinct from p_except
                   and m.membership_state = 'approved'
                   and not exists (select 1 from app.identity_deletions d where d.member_id = g.member_id)
                   and coalesce((select r.route = 'member' from app.notifications_recipient_route(g.member_id) r),
                                false));
$$;

create function app.cells_programme_ahead(p_cell_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.cells_programmes p
                   join app.cells_meetings m on m.meeting_id = p.meeting_id
                  where p.cell_id = p_cell_id and p.programme_state = 'published'
                    and m.starts_at > now() and m.meeting_state in ('scheduled', 'moved'));
$$;

create function app.cells_report_handover(p_event jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('obligations', coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'cell_leader', 'subject_id', x.cell_id, 'last_responsible', true)
           order by x.cell_id), '[]'::jsonb))
    from (
      select c.cell_id
        from app.cells_cells c
       where c.cell_state = 'active'
         and p_event ->> 'event' is distinct from 'scope_revoked'
         and exists (select 1 from app.identity_grants g
                      where g.member_id = (p_event ->> 'member_id')::uuid and g.revoked_at is null
                        and g.scope_id = c.cell_id and g.scope_kind in ('cell_leader', 'cell_assistant'))
         and app.cells_programme_ahead(c.cell_id)
         and not app.cells_has_reachable_leader(c.cell_id, (p_event ->> 'member_id')::uuid)
      union
      select c.cell_id
        from app.identity_revoked_scope() r
        join app.cells_cells c on c.cell_id = r.scope_id
       where p_event ->> 'event' = 'scope_revoked'
         and r.scope_kind in ('cell_leader', 'cell_assistant')
         and c.cell_state = 'active'
         and app.cells_programme_ahead(c.cell_id)
         and not app.cells_has_reachable_leader(c.cell_id, null)) x;
$$;

comment on function app.cells_report_handover(jsonb) is
  'Cells handover hook (story 5.9): the last reachable leader or assistant of an active cell with a '
  'published programme for a meeting ahead.';

select app.identity_register_handover_hook('cells', 'app.cells_report_handover(jsonb)'::regprocedure);

create function app.cells_handover_pending(p_cell_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_handover_obligations o
                  where o.owner_module = 'cells' and o.obligation_kind = 'cell_leader'
                    and o.subject_id = p_cell_id and o.obligation_state = 'pending');
$$;

-- cells.resolve_handover {cell_id}; expected = the cell revision. Admin. Resolves the cell's
-- pending `cell_leader` obligations once it has a reachable leader or assistant again.
create function app.cells_resolve_handover(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_cell app.cells_cells;
  v_id uuid;
  v_resolved integer := 0;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['cell_id']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  -- Identity before Cells (AD-2): the cell's leader and assistant grants stay put while we decide.
  perform 1 from app.identity_grants g
   where g.revoked_at is null and g.scope_id = (p_payload ->> 'cell_id')::uuid
     and g.scope_kind in ('cell_leader', 'cell_assistant')
   order by g.grant_id for share;
  select c.* into v_cell from app.cells_cells c where c.cell_id = (p_payload ->> 'cell_id')::uuid for update;
  if v_cell.cell_id is null then
    perform app.cmd_fail('not_found');
  end if;
  if v_cell.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_cell.revision);
  end if;
  if not app.cells_handover_pending(v_cell.cell_id) then
    perform app.cmd_fail('validation_failed', '{"cell_id": "no_handover"}');
  end if;
  if not app.cells_has_reachable_leader(v_cell.cell_id, null) then
    perform app.cmd_fail('conflict', '{"cell_id": "leader_required"}', v_cell.revision);
  end if;
  for v_id in select o.obligation_id from app.identity_handover_obligations o
               where o.owner_module = 'cells' and o.obligation_kind = 'cell_leader'
                 and o.subject_id = v_cell.cell_id and o.obligation_state = 'pending'
               order by o.obligation_id loop
    if app.identity_resolve_handover_obligation('cells', v_id, 'handed_over') then
      v_resolved := v_resolved + 1;
    end if;
  end loop;
  update app.cells_cells c set revision = c.revision + 1, updated_at = now()
   where c.cell_id = v_cell.cell_id
  returning c.* into v_cell;
  return jsonb_set(app.cells_cell_outcome(v_cell.cell_id), '{data,resolved}', to_jsonb(v_resolved));
end;
$$;


-- cells.confirm_request (replaced from 5.4): the transfer ends old-cell work.
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
  -- Story 5.9 review fix 5 (AD-2): the member the transfer may end work of, Identity first.
  if app.contract_uuid_error(p_payload -> 'request_id') is null then
    perform 1 from app.identity_members im
     where im.member_id = (select r.member_id from app.cells_membership_requests r
                            where r.request_id = (p_payload ->> 'request_id')::uuid)
       for key share;
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
  -- Story 5.9: the member's old-cell programme parts, cell duties and notices end now, and the old
  -- cell's leaders are told (Cells and Duties rows, then Notifications).
  if v_old.membership_id is not null then
    perform app.cells_transfer_effects(v_request.member_id, v_old.cell_id, v_actor.member_id,
                                       v_actor.account_id);
  end if;
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

-- The cell as Admin reads it (replaced from 2.6): adds `handover_pending`.
create or replace function app.cells_cell_json(p_cell_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'cell_id', c.cell_id,
    'name', c.name,
    'broad_area', c.broad_area,
    'signup_label', o.label,
    'listed', coalesce(o.listed, false),
    -- The sign-up option revision while it is offered (cell_revision of cells.request_change).
    'signup_revision', app.cells_option_revision(c.cell_id),
    'cell_state', c.cell_state,
    'is_synthetic', c.is_synthetic,
    'revision', c.revision,
    'leaders', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', g.member_id, 'display_name', m.display_name,
                                          'grants_revision', gs.revision)
                       order by m.display_name, g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
        join app.identity_grant_sets gs on gs.member_id = g.member_id
       where g.scope_kind = 'cell_leader' and g.scope_id = c.cell_id and g.revoked_at is null),
      '[]'::jsonb),
    'assistants', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', g.member_id, 'display_name', m.display_name,
                                          'grants_revision', gs.revision)
                       order by m.display_name, g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
        join app.identity_grant_sets gs on gs.member_id = g.member_id
       where g.scope_kind = 'cell_assistant' and g.scope_id = c.cell_id and g.revoked_at is null),
      '[]'::jsonb),
    'member_count', (select count(*)::int from app.cells_memberships cm
                      where cm.cell_id = c.cell_id and cm.ended_at is null),
    -- Story 5.9: a recorded handover (the cell's last leader left with a programme ahead).
    'handover_pending', app.cells_handover_pending(c.cell_id))
    from app.cells_cells c
    left join app.cells_signup_options o on o.cell_id = c.cell_id
   where c.cell_id = p_cell_id;
$$;

-- Entry point and authorizer (replaced from 5.8).
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
       'cells.record_actual_leaders', 'cells.resolve_handover') then
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
      when 'cells.resolve_handover' then 'app.cells_resolve_handover(uuid, bigint, jsonb)'::regprocedure
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

comment on function api.cells_command(jsonb) is
  'Stories 2.6 and 5.1-5.9: cell setup and membership (a transfer ends old-cell programme parts, '
  'cell duties and notices), meeting schedules and exceptions with their notices, meeting '
  'reminders, programmes, Cannot attend notices, meeting records and cell handovers through the '
  '1.4 command envelope.';

revoke all on function
  app.duties_vacate_cell_member(uuid, uuid, uuid[], text, boolean, uuid, uuid, text, text),
  app.duties_owner_vacate_member(jsonb),
  app.cells_programme_source_check(jsonb),
  app.cells_programme_reminder_check(jsonb),
  app.cells_transfer_effects(uuid, uuid, uuid, uuid),
  app.cells_has_reachable_leader(uuid, uuid),
  app.cells_programme_ahead(uuid),
  app.cells_report_handover(jsonb),
  app.cells_handover_pending(uuid),
  app.cells_resolve_handover(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
