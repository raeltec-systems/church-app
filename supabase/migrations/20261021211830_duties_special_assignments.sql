-- Special assignments (owner decision 2026-10-21): a duty that belongs to no department and no
-- cell, such as a one-off church project, leading a service or a task from church leadership.
-- Only the Pastor role gives them; each has either a fixed date and time or a due date ("done
-- by", no start time). Plan: story-give-special-assignments-as-the-pastor-and-count-them-in-hi.
--
--   * A third owner kind on app.duties_occurrences: `special` (held by the Duties module for the
--     whole church, managed by the current Pastors). Exactly one of department_id, cell_id and
--     special is set (duties_occurrences_one_owner_kind replaces the two-owner check). A special
--     occurrence is always published and never in a series. No new table and no new module: the
--     Pastor role is read from Identity, a registered dependency.
--   * A due date (`due_on`) is stored as one instant in starts_at, the due moment: the due date at
--     18:00 church time (app.duties_due_moment), with no end and no reporting time. Every time
--     rule (answer-by, Short notice, reminders, started, outcomes) applies to it unchanged; it has
--     no busy time, so it never overlaps another duty.
--   * Commands (through api.duties_command): duties.give_special, duties.revise_special and
--     duties.cancel_special for a current Pastor; duties.record_outcome, duties.correct_outcome
--     and duties.confirm_by_leader accept a special assignment from a current Pastor.
--   * Reads: api.duties_special_assignments (Pastors); api.duties_candidates for a special
--     assignment (every active member, Pastors only); My duties and My duty history list special
--     assignments (history kind `special`, its outcome tracked).
--   * Unchanged: department and cell reads (board, rota, coverage, outcomes, Admin overview, a
--     leader's view of a member's history), leader alerts (department-only, as for cell parts),
--     lifecycle and erasure (owner-agnostic).
--
-- Replaced bodies are copied from their latest version with every earlier review fix; the changes
-- are marked "Special assignments". ASCII only, no backslashes, no row deletions.
-- owner-approved-cleanup: owner decision 2026-10-21 (special assignments are a third duty owner kind, memory special-assignments-decision): the two-owner check duties_occurrences_one_owner is replaced in the same statement by the three-owner check duties_occurrences_one_owner_kind; no data is removed.

-- ---------------------------------------------------------------------------------------------
-- The owner kind and the due date
-- ---------------------------------------------------------------------------------------------

alter table app.duties_occurrences
  add column special boolean not null default false,
  add column due_on date;

alter table app.duties_occurrences
  drop constraint duties_occurrences_one_owner,
  add constraint duties_occurrences_one_owner_kind
    check (num_nonnulls(department_id, cell_id) + case when special then 1 else 0 end = 1),
  add constraint duties_occurrences_special_shape
    check (not special or (occurrence_state <> 'draft' and series_id is null)),
  add constraint duties_occurrences_due_on
    check (due_on is null or (special and ends_at is null and reporting_at is null));

create index duties_occurrences_special on app.duties_occurrences (starts_at) where special;

comment on column app.duties_occurrences.special is
  'Special assignments: owned by the church (the Duties module), managed by the current Pastors.';
comment on column app.duties_occurrences.due_on is
  'Special assignments: the due date of a "done by" assignment (starts_at holds its due moment).';

-- The due moment of a due date: 18:00 church time on that date, so reminders and default
-- answer-by times land in the evening (there are no quiet hours), never at midnight.
create function app.duties_due_moment(p_due date)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (p_due + time '18:00') at time zone app.duties_church_zone();
$$;

comment on function app.duties_due_moment(date) is
  'Special assignments: the instant a due date ends for every time rule (18:00 church time).';

-- ---------------------------------------------------------------------------------------------
-- Vocabulary: the Pastor's capacity
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261015110202_duties_lifecycle.sql.) Special assignments: capacity
-- `pastor` (a current Pastor gives, changes, cancels, confirms and records outcomes).
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

-- ---------------------------------------------------------------------------------------------
-- Busy time: a due date has none
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261014052239_duties_overlaps.sql.) Special assignments: a due-date
-- assignment has no busy time (null), so it never overlaps anything and never needs an override.
create or replace function app.duties_busy_range(p_occurrence app.duties_occurrences)
returns tstzrange
language sql
stable
set search_path = ''
as $$
  select case when p_occurrence.due_on is null
              then app.duties_busy_range_of(p_occurrence.starts_at, p_occurrence.ends_at,
                                            p_occurrence.reporting_at) end;
$$;

-- (Replaced; copied from 20261014052239_duties_overlaps.sql.) Special assignments: due-date
-- assignments count nothing and are counted by nothing (as app.duties_busy_range).
create or replace function app.duties_overlap_counts(p_occurrences uuid[])
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
       and o.due_on is null
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
       and o.due_on is null
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

-- (Replaced; copied from 20261014052239_duties_overlaps.sql.) Special assignments: a special
-- assignment is shown in full to a current Pastor and otherwise as a busy time of kind
-- `special` (never its name, place or instructions).
create or replace function app.duties_conflicts_json(p_viewer uuid, p_member uuid, p_range tstzrange,
                                                     p_exclude_slot uuid, p_department uuid,
                                                     p_moving uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with items as (
    select b.kind, b.slot_id, b.response, b.busy, o.occurrence_id, o.department_id, o.cell_id,
           o.special, o.duty_name, o.occurrence_state, o.starts_at, o.ends_at, o.reporting_at,
           o.location,
           case when o.special then app.identity_member_has_role(p_viewer, 'pastor')
                when o.department_id is not null
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
                 'owner_kind', case when f.special then 'special'
                                    when f.cell_id is null then 'department' else 'cell' end,
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
                 'owner_kind', case when f.special then 'special'
                                    when f.cell_id is null then 'department' else 'cell' end,
                 'from', app.cmd_utc(lower(f.busy)),
                 'to', app.cmd_utc(upper(f.busy))) end
             order by lower(f.busy), f.occurrence_id, f.slot_id)
        from firsts f), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------------------------------
-- Authorization: scope on replay, the authorizer and the router
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021101314_duties_cell_confirmation.sql.) Special assignments: a
-- special occurrence is in scope for a current Pastor. Otherwise the 5.5 rules.
create or replace function app.duties_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_department uuid;
  v_cell uuid;
  v_special boolean;
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
    select o.department_id, o.cell_id, o.special into v_department, v_cell, v_special
      from app.duties_occurrences o
     where o.occurrence_id = p_aggregate_id for share;
    if v_special then
      return app.identity_member_has_role(v_member, 'pastor');
    end if;
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

-- (Replaced; copied from 20261021101314_duties_cell_confirmation.sql.) Special assignments: the
-- three special commands, and the actor's Pastor grant share-locked with the others (AD-2:
-- grants before any Duties row).
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
       'duties.remove_member', 'duties.resolve_handover',
       -- Special assignments (Pastor).
       'duties.give_special', 'duties.revise_special', 'duties.cancel_special') then
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
     and (g.role in ('admin', 'pastor')
          or g.scope_kind in ('department_leader', 'department_deputy', 'cell_leader', 'cell_assistant'))
     for share;
  perform app.duties_lock_people(app.duties_command_people(
    jsonb_build_object('payload', nullif(pg_catalog.current_setting('duties.command_payload', true), '')::jsonb),
    r.member_id));
  return true;
end;
$$;

-- (Replaced; copied from 20261015110202_duties_lifecycle.sql.) Special assignments: the three
-- special commands (give_special creates, so it takes no expected revision; revise_special and
-- cancel_special are keyed to the occurrence, so a replay rechecks that the actor is still a
-- Pastor).
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
      -- Special assignments: keyed to the occurrence (a replay rechecks that the actor is still a
      -- Pastor); expected = the occurrence revision (none to give one).
      when 'duties.give_special'
        then 'app.duties_give_special(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_special'
        then 'app.duties_revise_special(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_special'
        then 'app.duties_cancel_special(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
      and v_command is distinct from 'duties.accept_many'
      and v_command is distinct from 'duties.give_special'
  );
  perform pg_catalog.set_config('duties.command_payload', '', true);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- My duties and reminders
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261015035112_duties_owner_operations.sql.) Special assignments: owner
-- kind `special` (no department, no cell), the due date of a "done by" assignment, and the
-- church's current Pastors as the people the member talks to (the Pastor who gave it first).
create or replace function app.duties_my_assignment_json(p_assignment_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'assignment_id', a.assignment_id,
    'revision', a.revision,
    'occurrence_id', o.occurrence_id,
    'slot_id', a.slot_id,
    -- Story 4.11: a cell programme part (no department; the cell's leaders and assistants).
    -- Special assignments: `special` (no department, no cell; the Pastors).
    'owner_kind', case when o.cell_id is not null then 'cell'
                       when o.special then 'special' else 'department' end,
    'department_id', d.department_id,
    'department_name', d.name,
    'cell_id', o.cell_id,
    'duty_name', o.duty_name,
    'position_name', s.position_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    -- Special assignments: a "done by" date (starts_at is then its due moment).
    'due_on', o.due_on,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'response', a.response,
    'response_provenance', a.response_provenance,
    'confirmed_channel', a.confirmed_channel,
    'response_deadline', app.cmd_utc(a.response_deadline),
    'deadline_source', a.deadline_source,
    'short_notice', a.short_notice,
    'reminders', o.reminders,
    'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
    'prior_accepted_at', case when a.prior_accepted_at is not null
                              then app.cmd_utc(a.prior_accepted_at) end,
    'note', a.response_note,
    -- Story 4.10: the member's own completion outcome (with its note and corrections) once the
    -- duty has started on the current assignment; null while unrecorded.
    'outcome', case when a.assignment_state = 'current' and o.occurrence_state = 'published'
                    then app.duties_outcome_json(a.assignment_id, 20) end,
    'slot_revision', a.slot_revision,
    'changes', case when p.member_id = a.member_id
                    then to_jsonb(app.duties_changes_since(a.slot_id, a.slot_revision - 1, a.slot_revision)) end,
    'previous_response', case when p.member_id = a.member_id then p.response end,
    'previous_assignment_ids', app.duties_previous_assignment_ids(a.assignment_id),
    'notes_updated_at', (select app.cmd_utc(t.ts) from (
                           select app.duties_notes_updated_at(a.slot_id, a.slot_revision) as ts) t
                          where t.ts is not null),
    'leaders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'display_name', m.display_name,
               'role', case when g.role = 'pastor' then 'pastor'
                            else case g.scope_kind when 'department_leader' then 'leader'
                                                   when 'cell_leader' then 'leader'
                                                   when 'cell_assistant' then 'assistant'
                                                   else 'deputy' end end)
             order by (g.scope_kind in ('department_deputy', 'cell_assistant')),
                      case when o.special then g.member_id is distinct from o.created_by_member end,
                      m.display_name collate "C", g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
       where g.revoked_at is null
         and ((o.department_id is not null and g.scope_id = o.department_id
               and g.scope_kind in ('department_leader', 'department_deputy'))
              or (o.cell_id is not null and g.scope_id = o.cell_id
                  and g.scope_kind in ('cell_leader', 'cell_assistant'))
              or (o.special and g.role = 'pastor'))
         and m.membership_state = 'approved'
         and not exists (select 1 from app.identity_deletions dl where dl.member_id = m.member_id)),
      '[]'::jsonb))
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
    left join app.duties_departments d on d.department_id = o.department_id
    left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
   where a.assignment_id = p_assignment_id;
$$;

-- (Replaced; copied from 20261015035112_duties_owner_operations.sql.)
-- Reminder check (3.2): exactly {current, revision, actionable, recipient_eligible}.
--   actionable          the response is still pending and the duty has not started;
--   recipient_eligible  the recipient is the assignee and still serves in the department.
-- Special assignments: a special assignment's member while an active member (no roster), as a
-- cell part's.
create or replace function app.duties_assignment_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
begin
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  return jsonb_build_object(
    'current', v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_assignment.revision,
    'actionable', v_assignment.assignment_state = 'current' and v_assignment.response = 'pending'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id'
                          and case when v_occurrence.department_id is null
                                   -- Story 4.11: a cell part's member, while an active member
                                   -- (Cells ends the parts of a member who leaves the cell).
                                   -- Special assignments: likewise (church-wide, no roster).
                                   then app.duties_member_active(v_assignment.member_id)
                                   else exists (select 1 from app.duties_department_members dm
                                                 where dm.department_id = v_occurrence.department_id
                                                   and dm.member_id = v_assignment.member_id
                                                   and dm.ended_at is null) end);
end;
$$;

-- (Replaced; copied from 20261015035112_duties_owner_operations.sql.)
-- duty_updated (notes-only change): current while the assignment is current at that revision;
-- actionable while the duty has not started and the member has not declined. Special
-- assignments: a special assignment's member while an active member, as a cell part's.
create or replace function app.duties_update_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
begin
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  return jsonb_build_object(
    'current', v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_assignment.revision,
    'actionable', v_assignment.assignment_state = 'current' and v_assignment.response <> 'declined'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id'
                          and case when v_occurrence.department_id is null
                                   -- Story 4.11: a cell part's member, while an active member.
                                   -- Special assignments: likewise.
                                   then app.duties_member_active(v_assignment.member_id)
                                   else exists (select 1 from app.duties_department_members dm
                                                 where dm.department_id = v_occurrence.department_id
                                                   and dm.member_id = v_assignment.member_id
                                                   and dm.ended_at is null) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The change engine: a special assignment has no roster; a due date is kept with the times
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261015035112_duties_owner_operations.sql.) Special assignments: a
-- special assignment, like a cell part, asks an active member (it has no roster), and the due
-- date is written with the other fields (a due-date change moves starts_at, so it is material).
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

-- ---------------------------------------------------------------------------------------------
-- Outcomes and Confirmed by the Pastor
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261015002121_duties_outcomes.sql.) Special assignments: the outcome of
-- a special assignment is recorded by a current Pastor (capacity `pastor`; anyone else, the
-- Admin role included: not_found), never their own; no department or series to lock. Otherwise
-- the 4.10 rules and lock order.
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
begin
  select o.department_id, o.series_id, o.occurrence_id, a.member_id, o.special
    into v_department, v_series, v_occurrence, v_assignee, v_special
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = p_assignment_id;
  if v_special then
    capacity := case when app.identity_member_has_role(p_actor_member, 'pastor') then 'pastor' end;
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

-- (Replaced; copied from 20261021101314_duties_cell_confirmation.sql.) Special assignments: a
-- special assignment is confirmed directly by a current Pastor (capacity `pastor`; anyone else:
-- not_found), never their own, with the cell part's checks (no department or series to lock).
create or replace function app.duties_lock_for_confirm(p_actor_member uuid, p_assignment_id uuid,
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
  v_special boolean;
  v_lock record;
begin
  select o.department_id, o.cell_id, o.occurrence_id, a.member_id, o.special
    into v_department, v_cell, v_occurrence, v_assignee, v_special
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = p_assignment_id;
  if v_cell is null and not coalesce(v_special, false) then
    select l.* into v_lock from app.duties_lock_for_leader(p_actor_member, p_assignment_id,
                                                            p_expected_revision) l;
    assignment := v_lock.assignment;
    occurrence := v_lock.occurrence;
    capacity := v_lock.capacity;
    return;
  end if;
  capacity := case
    when v_special then case when app.identity_member_has_role(p_actor_member, 'pastor')
                             then 'pastor' end
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

-- ---------------------------------------------------------------------------------------------
-- The special commands
-- ---------------------------------------------------------------------------------------------

-- A special assignment's timing in a payload: either `starts_at` (with an optional `ends_at`) or
-- `due_on` (YYYY-MM-DD, a church date), never both. `given` is false when the payload names
-- none of the three (a change that keeps the timing); p_required refuses that. Errors:
-- starts_at required | past | out_of_range; ends_at before_start | with_due_on; due_on invalid |
-- past | out_of_range | with_starts_at. A due date returns its due moment as starts_at.
create function app.duties_special_timing(p_payload jsonb, p_required boolean, inout errors jsonb,
                                          out given boolean, out starts_at timestamptz,
                                          out ends_at timestamptz, out due_on date)
language plpgsql
set search_path = ''
as $$
declare
  v_starts boolean := coalesce(jsonb_typeof(p_payload -> 'starts_at'), 'null') <> 'null';
  v_due boolean := coalesce(jsonb_typeof(p_payload -> 'due_on'), 'null') <> 'null';
  v_text text;
begin
  given := p_payload ? 'starts_at' or p_payload ? 'due_on' or p_payload ? 'ends_at';
  if not given then
    if p_required then
      errors := errors || '{"starts_at": "required"}';
    end if;
    return;
  end if;
  if v_starts and v_due then
    errors := errors || '{"due_on": "with_starts_at"}';
    return;
  end if;
  if v_due then
    if coalesce(jsonb_typeof(p_payload -> 'ends_at'), 'null') <> 'null' then
      errors := errors || '{"ends_at": "with_due_on"}';
    end if;
    v_text := case when jsonb_typeof(p_payload -> 'due_on') = 'string' then p_payload ->> 'due_on' end;
    if v_text is null or v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      errors := errors || '{"due_on": "invalid"}';
      return;
    end if;
    begin
      due_on := v_text::date;
    exception when others then
      errors := errors || '{"due_on": "invalid"}';
      return;
    end;
    starts_at := app.duties_due_moment(due_on);
    if starts_at <= now() then
      errors := errors || '{"due_on": "past"}';
    elsif starts_at > now() + interval '2 years' then
      errors := errors || '{"due_on": "out_of_range"}';
    end if;
    return;
  end if;
  if not v_starts then
    -- An end time alone (or a null start) does not say when.
    errors := errors || '{"starts_at": "required"}';
    return;
  end if;
  select t.errors, t.value into errors, starts_at
    from app.duties_instant(p_payload, 'starts_at', true, errors) t;
  select t.errors, t.value into errors, ends_at
    from app.duties_instant(p_payload, 'ends_at', false, errors) t;
  if starts_at is not null then
    if starts_at <= now() then
      errors := errors || '{"starts_at": "past"}';
    elsif starts_at > now() + interval '2 years' then
      errors := errors || '{"starts_at": "out_of_range"}';
    end if;
    if ends_at is not null and ends_at <= starts_at then
      errors := errors || '{"ends_at": "before_start"}';
    end if;
  end if;
end;
$$;

-- Locks a special assignment's occurrence for a Pastor's change: a current Pastor only (anyone
-- else, and a department or cell duty or an unknown id: not_found, no disclosure), FOR UPDATE
-- (grants and the receipt are locked before, AD-2), at the expected revision (`conflict`), not
-- cancelled and not started (validation_failed occurrence_id cancelled | started).
create function app.duties_lock_special(p_actor_member uuid, p_occurrence_id uuid,
                                        p_expected_revision bigint,
                                        out occ app.duties_occurrences, out capacity text)
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.duties_occurrences o
                  where o.occurrence_id = p_occurrence_id and o.special) then
    perform app.cmd_fail('not_found');
  end if;
  capacity := case when app.identity_member_has_role(p_actor_member, 'pastor') then 'pastor' end;
  if capacity is null then
    perform app.cmd_fail('not_found');
  end if;
  select o.* into occ from app.duties_occurrences o where o.occurrence_id = p_occurrence_id for update;
  if occ.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, occ.revision);
  end if;
  if occ.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "cancelled"}');
  end if;
  if app.duties_occurrence_start(occ) <= now() then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "started"}');
  end if;
end;
$$;

-- duties.give_special {member_id, duty_name, starts_at + ends_at? | due_on, location?,
-- instructions?, response_deadline?, override_reason?}; no expected revision. A current Pastor
-- (anyone else: forbidden) gives an active member (not themselves: `own`) a special assignment:
-- one position, published at once, asked to accept or say they cannot by the Pastor's answer-by
-- time or the shared 3.3 lead-time default (Short notice when it has passed). A fixed time that
-- overlaps the member's other duties needs override_reason; a due date never overlaps. Answer:
-- ids, revisions, states and counts only (no names or text in the receipt).
create function app.duties_give_special(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
                                         command_request_id)
  values (v_slot, 1, v_occurrence, 1, 'published', v_name, v_timing.starts_at, v_timing.ends_at,
          v_location, v_instructions, v_member, v_assignment, v_deadline, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(p_actor, v_cmd));
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

-- duties.revise_special {occurrence_id, duty_name?, starts_at + ends_at? | due_on, location?,
-- instructions?, member_id?, response_deadline?, override_reason?}; expected = the occurrence
-- revision. A patch: absent keys keep their value; the timing is changed as a whole (starts_at
-- with ends_at, or due_on). Through the 4.2 change engine: a material change (name, timing,
-- place, assignee) asks the member again with a new answer-by time and keeps the earlier answer;
-- an instructions-only change keeps the answer and sends an update. Refusals: not_found (not a
-- current Pastor's special assignment), conflict (stale), occurrence_id cancelled | started |
-- unchanged, member_id own | unknown | required, override_reason required on an overlap.
create function app.duties_revise_special(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_reason text;
  v_deadline timestamptz;
  v_member uuid;
  v_timing record;
  v_slot uuid;
  v_change jsonb;
  v_notified jsonb;
  v_recorded integer;
  v_cmd constant text := 'duties.revise_special';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['occurrence_id', 'duty_name', 'starts_at', 'ends_at', 'due_on', 'location',
                      'instructions', 'member_id', 'response_deadline', 'override_reason']);
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
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'override_reason', false, 280, true, v_errors) t;
  if p_payload ? 'response_deadline' then
    select t.errors, t.value into v_errors, v_deadline
      from app.duties_instant(p_payload, 'response_deadline', true, v_errors) t;
  end if;
  if p_payload ? 'member_id' then
    select t.errors, t.value into v_errors, v_member
      from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  end if;
  select t.* into v_timing from app.duties_special_timing(p_payload, false, v_errors) t;
  v_errors := v_timing.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_special(v_actor.member_id, v_occurrence_id,
                                                       p_expected_revision) l;
  v_occ := v_lock.occ;
  if p_payload ? 'member_id' and v_member = v_actor.member_id then
    perform app.cmd_fail('validation_failed', '{"member_id": "own"}');
  end if;
  select min(s.slot_id::text)::uuid into v_slot from app.duties_slots s
   where s.occurrence_id = v_occurrence_id;
  v_new := v_occ;
  v_new.duty_name := case when p_payload ? 'duty_name' then v_name else v_occ.duty_name end;
  v_new.location := case when p_payload ? 'location' then v_location else v_occ.location end;
  v_new.instructions := case when p_payload ? 'instructions' then v_instructions
                             else v_occ.instructions end;
  if v_timing.given then
    v_new.starts_at := v_timing.starts_at;
    v_new.ends_at := v_timing.ends_at;
    v_new.due_on := v_timing.due_on;
  end if;
  -- Story 4.4: everyone this change may ask (the current assignee and a new one) is serialised.
  perform app.duties_lock_members(app.duties_occurrence_members(v_occurrence_id) || v_member);
  v_change := app.duties_apply_change(v_occ, v_new, v_slot, v_member, p_payload ? 'member_id',
                                      v_deadline, 'response_deadline', v_actor.member_id,
                                      v_actor.account_id, v_lock.capacity, v_cmd, false);
  v_recorded := app.duties_gate_created(v_change -> 'created', v_reason, v_actor.member_id,
                                        v_actor.account_id, v_lock.capacity, v_cmd);
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

-- duties.cancel_special {occurrence_id}; expected = the occurrence revision. A current Pastor
-- cancels a special assignment that has not started (the 4.3 cancellation: the assignment ends
-- `cancelled`, its jobs are cancelled and a member who had not declined gets duty_cancelled).
-- Refusals as duties.revise_special.
create function app.duties_cancel_special(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_occurrence_id uuid;
  v_lock record;
  v_result jsonb;
  v_notified jsonb;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['occurrence_id']);
  select t.errors, t.value into v_errors, v_occurrence_id
    from app.duties_uuid(p_payload, 'occurrence_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_special(v_actor.member_id, v_occurrence_id,
                                                       p_expected_revision) l;
  v_result := app.duties_cancel_one(v_lock.occ, v_actor.member_id, v_actor.account_id,
                                    v_lock.capacity, 'duties.cancel_special');
  v_notified := app.duties_notify(v_result -> 'ops');
  select o.revision into v_revision from app.duties_occurrences o where o.occurrence_id = v_occurrence_id;
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence_id, 'revision', v_revision,
    'data', jsonb_build_object('occurrence_id', v_occurrence_id, 'revision', v_revision,
                               'state', 'cancelled',
                               'assignments_cancelled', (v_result ->> 'assignments_cancelled')::integer,
                               'notices_queued', (v_notified ->> 'queued')::integer));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads: the Pastor's special assignments, candidates, My duty history
-- ---------------------------------------------------------------------------------------------

-- One special assignment for the Pastors' read: the duty and its timing, who gave it, its current
-- assignment (the member, their account label, answer and note, answer-by, Short notice, Needs
-- contact, the overlap override, the outcome with its trail and what may be recorded) or, when
-- nobody holds it, why it was vacated.
create function app.duties_special_json(p_occurrence_id uuid, p_viewer uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'revision', o.revision,
    'slot_id', s.slot_id,
    'duty_name', o.duty_name,
    'timing', case when o.due_on is not null then 'due' else 'time' end,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'due_on', o.due_on,
    'location', o.location,
    'instructions', o.instructions,
    'given_by', app.duties_display_name(o.created_by_member),
    'given_at', app.cmd_utc(o.published_at),
    'started', app.duties_occurrence_start(o) <= now(),
    'assignment', case when a.assignment_id is not null then jsonb_build_object(
      'assignment_id', a.assignment_id,
      'revision', a.revision,
      'member_id', a.member_id,
      'display_name', app.duties_display_name(a.member_id),
      'account', case when a.member_id = '00000000-0000-0000-0000-000000000000'::uuid then null
                      when app.identity_member_account_label(a.member_id) = 'no_login'
                        then 'no_login' else 'app_account' end,
      'own', a.member_id = p_viewer,
      'erased', a.member_id = '00000000-0000-0000-0000-000000000000'::uuid,
      'response', a.response,
      'response_provenance', a.response_provenance,
      'confirmed_channel', a.confirmed_channel,
      'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
      'prior_accepted_at', case when a.prior_accepted_at is not null
                                then app.cmd_utc(a.prior_accepted_at) end,
      'note', a.response_note,
      'response_deadline', app.cmd_utc(a.response_deadline),
      'deadline_source', a.deadline_source,
      'short_notice', a.short_notice,
      'needs_contact', app.duties_needs_contact(a, o),
      'override', app.duties_override_json(a),
      'outcome', app.duties_outcome_json(a.assignment_id, 20),
      'allowed', case when app.duties_occurrence_start(o) <= now() and a.member_id <> p_viewer
                           and a.member_id <> '00000000-0000-0000-0000-000000000000'::uuid
                      then app.duties_outcomes_allowed(a.response) else '[]'::jsonb end) end,
    'vacancy', case when a.assignment_id is null then (
      select jsonb_build_object('reason', v.vacancy_reason, 'since', app.cmd_utc(v.ended_at))
        from app.duties_assignments v
       where v.slot_id = s.slot_id and v.end_reason = 'vacated'
       order by v.ended_at desc, v.assignment_id desc
       limit 1) end)
    from app.duties_occurrences o
    join app.duties_slots s on s.occurrence_id = o.occurrence_id
    left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
   where o.occurrence_id = p_occurrence_id;
$$;

-- `api.duties_special_assignments()`: the special assignments of the church for a current Pastor
-- (anyone else: 403 not_granted): published ones that start (or are due) from 90 days ago on,
-- the upcoming first (soonest first), then the past (newest first), at most 500 (`truncated`);
-- and the active members they may be given to (themselves left out), by name, at most 1000
-- (`members_truncated`). Errors: 403 unavailable (gate closed).
create function app.duties_special_assignments()
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
  if not app.identity_member_has_role(v_member, 'pastor') then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  -- Story 4.4: an override about the viewer's own assignment hides its reason.
  perform pg_catalog.set_config('app.duties_viewer', v_member::text, true);
  with occ as (
    select o.occurrence_id, o.starts_at, app.duties_occurrence_start(o) <= now() as started
      from app.duties_occurrences o
     where o.special and o.occurrence_state = 'published'
       and o.starts_at > now() - interval '90 days'
  ), ranked as (
    select occ.*, row_number() over (order by occ.started,
                                              case when not occ.started then occ.starts_at end,
                                              occ.starts_at desc, occ.occurrence_id) as rn
      from occ
  ), people as (
    select m.member_id, m.display_name
      from app.identity_members m
     where m.membership_state = 'approved' and m.member_id <> v_member
       and not exists (select 1 from app.identity_deletions dl where dl.member_id = m.member_id)
  )
  select jsonb_build_object(
    'assignments', coalesce((select jsonb_agg(app.duties_special_json(r.occurrence_id, v_member)
                                              order by r.rn)
                               from ranked r where r.rn <= 500), '[]'::jsonb),
    'truncated', (select count(*) > 500 from occ),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'member_id', x.member_id,
               'display_name', x.display_name,
               'account', case when app.identity_member_account_label(x.member_id) = 'no_login'
                               then 'no_login' else 'app_account' end)
             order by x.display_name collate "C", x.member_id)
        from (select p.* from people p
               order by p.display_name collate "C", p.member_id limit 1000) x), '[]'::jsonb),
    'members_truncated', (select count(*) > 1000 from people))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_special_assignments()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_special_assignments();
$$;

comment on function app.duties_special_assignments() is
  'owner: duties. Special assignments: the church''s special assignments and the members they '
  'may be given to, for the current Pastors.';
comment on function api.duties_special_assignments() is
  'Special assignments (owner decision 2026-10-21): the special assignments of the last 90 days '
  'and ahead with their answers, overrides and outcomes, and the active members, for a current '
  'Pastor.';

-- (Replaced; copied from 20261014052239_duties_overlaps.sql.) Special assignments: a Pastor asks
-- for a special assignment's position (`slot_id`, at its own times or new ones) or for a
-- prospective one (`starts_at`, `ends_at?`, no department and no reporting time): every active
-- member (the Pastor left out, at most 1000, by name) with their account label, upcoming load
-- and overlaps as the Pastor may see them. A due date has no busy time (400 window). Anyone else:
-- 403 not_granted. Otherwise the 4.4 department rules.
create or replace function app.duties_candidates(p_slot_id uuid, p_department_id uuid,
                                                 p_starts_at timestamptz, p_ends_at timestamptz,
                                                 p_reporting_at timestamptz)
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
  v_special boolean := false;
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
      v_special := v_occ.special and v_occ.occurrence_state = 'published';
      v_range := case when p_starts_at is not null
                      then app.duties_busy_range_of(p_starts_at, p_ends_at, p_reporting_at)
                      else app.duties_busy_range(v_occ) end;
      select coalesce((select a.member_id from app.duties_assignments a
                        where a.slot_id = p_slot_id and a.assignment_state = 'current'),
                      (select s.draft_member_id from app.duties_slots s where s.slot_id = p_slot_id))
        into v_current;
    end if;
  elsif p_department_id is null and p_starts_at is not null then
    -- Special assignments: a prospective special assignment at a fixed time.
    v_special := true;
    v_range := app.duties_busy_range_of(p_starts_at, p_ends_at, p_reporting_at);
  else
    if p_department_id is null or p_starts_at is null then
      raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
    end if;
    v_department := p_department_id;
    v_range := app.duties_busy_range_of(p_starts_at, p_ends_at, p_reporting_at);
  end if;
  if v_special then
    if not app.identity_member_has_role(v_member, 'pastor') then
      raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
    end if;
    if v_range is null or p_reporting_at is not null then
      raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
    end if;
    select jsonb_build_object(
      'department_id', null,
      'slot_id', p_slot_id,
      'window', jsonb_build_object('from', app.cmd_utc(lower(v_range)), 'to', app.cmd_utc(upper(v_range))),
      'candidates', coalesce(jsonb_agg(jsonb_build_object(
          'member_id', x.member_id,
          'display_name', x.display_name,
          'account', case when app.identity_member_account_label(x.member_id) = 'no_login'
                          then 'no_login' else 'app_account' end,
          'current', x.member_id = v_current,
          'upcoming', app.duties_upcoming(x.member_id, null),
          'conflicts', app.duties_conflicts_json(v_member, x.member_id, v_range, p_slot_id, null,
                                                  case when p_starts_at is not null then v_occ.occurrence_id end))
        order by x.display_name collate "C", x.member_id), '[]'::jsonb))
      into v_result
      from (select m.member_id, m.display_name
              from app.identity_members m
             where m.membership_state = 'approved' and m.member_id <> v_member
               and not exists (select 1 from app.identity_deletions dl where dl.member_id = m.member_id)
             order by m.display_name collate "C", m.member_id
             limit 1000) x;
    perform app.identity_record_activity(v_link);
    return v_result;
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

comment on function api.duties_candidates(uuid, uuid, timestamptz, timestamptz, timestamptz) is
  'Story 4.4: for a position or a prospective one-off duty, each roster member''s upcoming load '
  'and the overlapping duties the caller may see (managers of the department only). Special '
  'assignments: for a Pastor, every active member for a special assignment at a fixed time.';

-- (Replaced; copied from 20261021195642_duties_history_all_kinds.sql.) Special assignments: kind
-- `special` (filter value and `kinds.special`); its outcome is tracked, so the outcome figures of
-- the summary count department duties and special assignments (cell parts stay not_tracked);
-- entries carry `due_on`. A leader reading a member's history still sees their departments only.
create or replace function app.duties_member_history(p_member_id uuid, p_before_at timestamptz,
                                                     p_before_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_target uuid;
  v_self boolean;
  v_departments uuid[];
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_target := coalesce(p_member_id, v_member);
  v_self := v_target = v_member;
  perform app.duties_require_open_read();
  if (p_before_at is null) <> (p_before_id is null) then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'cursor';
  end if;
  if p_kind is not null and p_kind not in ('department', 'cell', 'special') then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'kind';
  end if;
  if not v_self then
    -- The departments the caller leads or deputises now in which the member serves or served.
    select coalesce(array_agg(d.department_id), '{}') into v_departments
      from app.duties_departments d
     where (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
       and (app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
            or app.identity_member_has_scope(v_member, 'department_deputy', d.department_id))
       and exists (select 1 from app.duties_department_members dm
                    where dm.department_id = d.department_id and dm.member_id = v_target);
    if cardinality(v_departments) = 0 then
      raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
    end if;
  end if;

  with held as (
    -- The member's assignments the reader may see, one row per position held: the latest
    -- revision of this person on the slot. Another reader sees department duties only.
    select a.assignment_id, a.assignment_state, a.response, a.response_provenance, o.occurrence_id,
           o.department_id, o.cell_id,
           case when o.department_id is not null then 'department'
                when o.special then 'special' else 'cell' end as owner_kind,
           o.starts_at, o.occurrence_state,
           app.duties_occurrence_start(o) <= now() as started,
           x.outcome
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
      left join lateral (select y.outcome from app.duties_outcomes y
                          where y.assignment_id = a.assignment_id
                          order by y.revision desc limit 1) x on true
     where a.member_id = v_target
       and o.occurrence_state <> 'draft'
       and (v_self or o.department_id = any (v_departments))
       and not exists (select 1 from app.duties_assignments n
                        where n.supersedes_assignment_id = a.assignment_id and n.member_id = a.member_id)
  ), shown as (
    select h.* from held h where p_kind is null or h.owner_kind = p_kind
  ), page as (
    select h.* from shown h
     where p_before_at is null or (h.starts_at, h.assignment_id) < (p_before_at, p_before_id)
     order by h.starts_at desc, h.assignment_id desc
     limit 101
  ), live as (
    -- A position counts as held when its assignment is current on a published duty.
    select h.*, h.assignment_state = 'current' and h.occurrence_state = 'published' as is_live
      from shown h
  )
  select jsonb_build_object(
    'member', jsonb_build_object('member_id', v_target,
                                 'display_name', app.duties_display_name(v_target)),
    'self', v_self,
    'kind', p_kind,
    'kinds', (select jsonb_build_object(
                'department', count(*) filter (where h.owner_kind = 'department'),
                'cell', count(*) filter (where h.owner_kind = 'cell'),
                'special', count(*) filter (where h.owner_kind = 'special'))
                from held h),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('department_id', d.department_id,
                                                                  'name', d.name)
                                              order by d.name, d.department_id)
                               from app.duties_departments d
                              where d.department_id in (select h.department_id from held h)), '[]'::jsonb),
    -- One member's own figures (never compared with anyone else). Outcomes are kept for
    -- department duties and special assignments (not for cell parts).
    'summary', (select jsonb_build_object(
                  'since', app.cmd_utc(now() - interval '365 days'),
                  'held', count(*) filter (where l.is_live and l.started),
                  'accepted', count(*) filter (where l.is_live and l.started and l.response = 'accepted'
                                               and l.response_provenance = 'member'),
                  'confirmed_by_leader', count(*) filter (where l.is_live and l.started
                                                          and l.response_provenance = 'leader'),
                  'declined', count(*) filter (where l.is_live and l.started and l.response = 'declined'),
                  'unanswered', count(*) filter (where l.is_live and l.started and l.response = 'pending'),
                  'completed', count(*) filter (where l.is_live and l.started and l.owner_kind <> 'cell'
                                                and l.outcome = 'completed'),
                  'excused', count(*) filter (where l.is_live and l.started and l.owner_kind <> 'cell'
                                              and l.outcome = 'excused'),
                  'no_show', count(*) filter (where l.is_live and l.started and l.owner_kind <> 'cell'
                                              and l.outcome = 'no_show'),
                  'unrecorded', count(*) filter (where l.is_live and l.started and l.owner_kind <> 'cell'
                                                 and l.outcome is null),
                  'ended', count(*) filter (where not l.is_live))
                  from live l
                 where l.starts_at >= now() - interval '365 days' and (l.started or not l.is_live)),
    'upcoming', (select count(*) from live l where l.is_live and not l.started),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'assignment_id', p.assignment_id,
               'occurrence_id', p.occurrence_id,
               'owner_kind', p.owner_kind,
               'department_id', p.department_id,
               'department_name', d.name,
               'cell_id', p.cell_id,
               'duty_name', o.duty_name,
               'position_name', s.position_name,
               'starts_at', app.cmd_utc(o.starts_at),
               'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
               -- Special assignments: a "done by" date (starts_at is then its due moment).
               'due_on', o.due_on,
               'started', p.started,
               -- current, reassigned (another person holds the position now) or cancelled.
               'state', case when p.assignment_state = 'current' and p.occurrence_state = 'published'
                               then 'current'
                             when p.assignment_state = 'superseded' then 'reassigned'
                             else 'cancelled' end,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               'outcome_state', case
                 when not (p.assignment_state = 'current' and p.occurrence_state = 'published') then 'none'
                 when not p.started then 'upcoming'
                 when p.owner_kind = 'cell' then 'not_tracked'
                 else coalesce(p.outcome, 'unrecorded') end,
               'outcome', case when p.owner_kind <> 'cell' and p.assignment_state = 'current'
                                    and p.occurrence_state = 'published'
                               then app.duties_outcome_json(p.assignment_id, 20) end)
             order by p.starts_at desc, p.assignment_id desc)
        from (select * from page order by starts_at desc, assignment_id desc limit 100) p
        join app.duties_assignments a on a.assignment_id = p.assignment_id
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
        left join app.duties_departments d on d.department_id = p.department_id), '[]'::jsonb),
    'has_more', (select count(*) > 100 from page))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

comment on function app.duties_member_history(uuid, timestamptz, uuid, text) is
  'owner: duties. One member''s assignment history: department duties, cell programme parts and '
  'special assignments for the member, department duties only for their leaders and deputies; '
  'filter by kind.';
comment on function api.duties_member_history(uuid, timestamptz, uuid, text) is
  'Story 4.10, extended 2026-10-21: one member''s assignment history (responses, completion '
  'outcomes, corrections) and their own 12-month summary, every duty kind (department, cell, '
  'special) for the member, department duties for their department''s leaders and deputies; '
  'filter by kind.';

-- ---------------------------------------------------------------------------------------------
-- Comments and privileges
-- ---------------------------------------------------------------------------------------------

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.12: departments (create_department, add_member, remove_member, '
  'resolve_handover), publishing and revising duties (publish_duty, revise_duty), the assignee''s '
  'answer (respond, withdraw_acceptance, accept_many), rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series), reminders (set_reminders), '
  'coverage (record_contact_attempt, confirm_by_leader, cancel_position), completion '
  '(record_outcome, correct_outcome) and owner reviews (clear_review); special assignments '
  '(give_special, revise_special, cancel_special; Pastor) through the 1.4 envelope.';

comment on function app.duties_special_timing(jsonb, boolean, jsonb) is
  'Special assignments: reads a fixed time (starts_at, ends_at) or a due date (due_on).';
comment on function app.duties_lock_special(uuid, uuid, bigint) is
  'Special assignments: locks a special occurrence for a current Pastor''s change.';
comment on function app.duties_give_special(uuid, bigint, jsonb) is
  'Special assignments: duties.give_special (a current Pastor gives an active member one).';
comment on function app.duties_revise_special(uuid, bigint, jsonb) is
  'Special assignments: duties.revise_special (the 4.2 change engine).';
comment on function app.duties_cancel_special(uuid, bigint, jsonb) is
  'Special assignments: duties.cancel_special (the 4.3 cancellation).';
comment on function app.duties_special_json(uuid, uuid) is
  'Special assignments: one special assignment as the Pastors read it.';

revoke all on function
  app.duties_due_moment(date),
  app.duties_special_timing(jsonb, boolean, jsonb),
  app.duties_lock_special(uuid, uuid, bigint),
  app.duties_give_special(uuid, bigint, jsonb),
  app.duties_revise_special(uuid, bigint, jsonb),
  app.duties_cancel_special(uuid, bigint, jsonb),
  app.duties_special_json(uuid, uuid),
  app.duties_special_assignments(),
  api.duties_special_assignments()
  from public, anon, authenticated, service_role;
grant execute on function app.duties_special_assignments() to authenticated;
grant execute on function api.duties_special_assignments() to authenticated;

notify pgrst, 'reload schema';
