-- Respond from My duties with later decline and bulk acceptance (story 4.5; AD-2, AD-6). A
-- forward migration on the Duties owner (20261013220239_duties_department_tracer.sql,
-- 20261014001142_duties_revisions.sql, 20261014023442_duties_rota_series.sql and
-- 20261014052239_duties_overlaps.sql are not edited). It adds:
--
--   * "Can't make it anymore": duties.withdraw_acceptance {assignment_id, note?} with expected =
--     the assignment's revision. Only the assignee, only an accepted answer, only before the
--     reporting (or start) time. The assignment becomes `declined`; the time of the earlier
--     acceptance is kept (app.duties_assignments.prior_accepted_at), the response actor and time
--     are the withdrawal's and the note is the one given now. The assignment's pending jobs are
--     cancelled (`responded`). The leader board and the rota show it at once (`confirmed`
--     drops); the leader decline alert belongs to the coverage queue (entry 9).
--   * Bulk acceptance: duties.accept_many {assignments: [{assignment_id, revision}, ...]} with
--     expected = null (each item carries the revision the member saw), 1..50 distinct items.
--     All or nothing: an item that is superseded, cancelled, already answered, at another
--     revision or started refuses the whole command with `conflict`
--     {"assignments": "changed", "assignment:<id>": "<code>"}; an unknown item, someone else's or
--     a cell-owned one answers `not_found` (nothing is disclosed). The receipt's aggregate is the
--     first assignment (lock order), so a replay is rechecked against its assignee.
--   * Cell-owned assignments stay unreachable to members until entry 11 builds their member view:
--     duties.respond (replaced), duties.withdraw_acceptance and duties.accept_many all answer
--     `not_found` for an assignment of a cell-owned occurrence (fail closed). My duties stays
--     department-owned (4.4).
--   * My duties (app.duties_my_assignment_json replaced) adds the slot id (the calendar entry's
--     stable id), the owner kind, the earlier
--     acceptance of a withdrawn answer and the department's current leader and deputy names (no
--     phone: contact display waits on Q4 and entry 9). The leader projections (the 3-argument
--     app.duties_occurrence_json and the 2-argument app.duties_rota_occurrence_json, replaced)
--     add `prior_accepted_at`.
--
-- Overlaps (4.4): accepting creates no new commitment (a pending assignment already counts), and
-- a decline only removes one, so neither command runs the override gate or takes the per-member
-- advisory locks. A gate racing with a decline can at worst ask for a reason that is no longer
-- needed (fail closed); after a decline no override is carried on a material change, so the
-- leader is gated again.
--
-- Lock order (AD-2), as in 4.3/4.4: the actor's grant rows FOR SHARE (authorizer) -> command
-- receipt -> department FOR SHARE -> series FOR UPDATE -> occurrences (series date order) ->
-- member advisory locks and department membership FOR SHARE -> slots FOR UPDATE -> assignments
-- FOR UPDATE -> Notifications (cancel, enqueue), always last. duties.accept_many takes its
-- occurrences FOR SHARE in (series, series date, start, id) order, one-off duties after every
-- series date, and then its assignments FOR UPDATE in the same order, so it agrees with
-- duties.revise_series and duties.cancel_series (series date order) even after one date was
-- moved; duties.withdraw_acceptance, like duties.respond, checks ownership without a lock and
-- then locks only its assignment.
--
-- No destructive statements, no row deletions. No new client grant (both commands go through
-- api.duties_command).

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
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn')
    else false end;
$$;

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (stories 4.1-4.5). Later stories widen them by replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- The time of the member's earlier acceptance when they later said they can't make it.
alter table app.duties_assignments
  add column prior_accepted_at timestamptz,
  add constraint duties_assignments_prior_accepted
    check (prior_accepted_at is null or response = 'declined');

comment on column app.duties_assignments.prior_accepted_at is
  'Story 4.5: when the member had accepted before saying they can''t make it anymore.';

-- Ended assignments are immutable (replaced: prior_accepted_at too; erasure may only clear the
-- note and the override reason and anonymise people).
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
      new.override_overlaps, new.override_at, new.prior_accepted_at)
     is distinct from
     (old.assignment_id, old.slot_id, old.assignment_state, old.response, old.response_deadline,
      old.responded_at, old.response_provenance, old.revision, old.assigned_at,
      old.slot_revision, old.supersedes_assignment_id, old.ended_at, old.end_reason,
      old.override_overlaps, old.override_at, old.prior_accepted_at)
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
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- An answer to an assignment that is no longer current is refused: a superseded one with
-- `conflict` and the fields changed from the change that replaced it onwards (never the new
-- assignee or their ids; when the position is the member's again, the assignee did not change
-- for them), a cancelled one with {"assignment_id": "cancelled"}. Returns when it is current.
create function app.duties_refuse_ended(p_assignment app.duties_assignments, p_member uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_changes text[];
begin
  if p_assignment.assignment_state = 'superseded' then
    v_changes := app.duties_changes_since(p_assignment.slot_id,
      coalesce((select n.slot_revision - 1 from app.duties_assignments n
                 where n.supersedes_assignment_id = p_assignment.assignment_id),
               p_assignment.slot_revision), null);
    if exists (select 1 from app.duties_assignments c
                where c.slot_id = p_assignment.slot_id and c.assignment_state = 'current'
                  and c.member_id = p_member) then
      v_changes := array_remove(v_changes, 'member_id');
    end if;
    perform app.cmd_fail('conflict',
      '{"assignment_id": "superseded"}'::jsonb || app.duties_changes_errors(v_changes));
  end if;
  if p_assignment.assignment_state <> 'current' then
    perform app.cmd_fail('conflict', '{"assignment_id": "cancelled"}');
  end if;
end;
$$;

-- The occurrence of an assignment.
create function app.duties_assignment_occurrence(p_slot_id uuid)
returns app.duties_occurrences
language sql
stable
set search_path = ''
as $$
  select o.* from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = p_slot_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: respond (replaced), withdraw acceptance, accept many
-- ---------------------------------------------------------------------------------------------

-- duties.respond (replaced): as in 4.2, and an assignment of a cell-owned occurrence is not found
-- (members answer cell parts only once entry 11 builds their member view).
create or replace function app.duties_respond(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_note text;
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'response', 'note']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  if jsonb_typeof(p_payload -> 'response') is distinct from 'string' then
    v_errors := v_errors || jsonb_build_object('response',
                  case when p_payload ? 'response' then 'invalid' else 'required' end);
  elsif p_payload ->> 'response' not in ('accepted', 'declined') then
    v_errors := v_errors || '{"response": "invalid"}';
  end if;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 280, true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id = v_assignment_id for update;
  -- Someone else's assignment is not found (no disclosure).
  if not found or v_assignment.member_id <> v_actor.member_id then
    perform app.cmd_fail('not_found');
  end if;
  v_occurrence := app.duties_assignment_occurrence(v_assignment.slot_id);
  if v_occurrence.department_id is null then
    perform app.cmd_fail('not_found');
  end if;
  perform app.duties_refuse_ended(v_assignment, v_actor.member_id);
  if v_assignment.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_assignment.revision);
  end if;
  if v_assignment.response <> 'pending' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', v_assignment.revision);
  end if;
  if app.duties_occurrence_start(v_occurrence) <= now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "started"}');
  end if;
  update app.duties_assignments a
     set response = p_payload ->> 'response', responded_at = now(),
         responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
         response_provenance = 'member', response_note = v_note, revision = a.revision + 1
   where a.assignment_id = v_assignment.assignment_id
  returning a.revision into v_revision;
  perform app.duties_audit_event('response_recorded', v_actor.member_id, v_actor.account_id,
                                 'member', 'duties.respond', v_occurrence.department_id,
                                 v_occurrence.occurrence_id, v_assignment.assignment_id,
                                 v_assignment.member_id, p_payload ->> 'response', v_revision);
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment.assignment_id,
    'reason', 'responded'));
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    -- Ids and states only (the note stays out of the receipt); clients read My duties again.
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', p_payload ->> 'response'));
end;
$$;

-- duties.withdraw_acceptance {assignment_id, note?}; expected = the assignment's revision.
-- "Can't make it anymore": only the assignee, only an accepted answer, before the duty starts.
create function app.duties_withdraw_acceptance(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_note text;
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'note']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 280, true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Ownership first, without a lock: someone else's, unknown or cell-owned is not found (no
  -- disclosure, and no lock taken on a row the actor may not touch). Then lock and re-check.
  if not exists (select 1 from app.duties_assignments a
                   join app.duties_slots s on s.slot_id = a.slot_id
                   join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
                  where a.assignment_id = v_assignment_id and a.member_id = v_actor.member_id
                    and o.department_id is not null) then
    perform app.cmd_fail('not_found');
  end if;
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id = v_assignment_id for update;
  if not found or v_assignment.member_id is distinct from v_actor.member_id then
    perform app.cmd_fail('not_found');
  end if;
  v_occurrence := app.duties_assignment_occurrence(v_assignment.slot_id);
  if v_occurrence.department_id is null then
    perform app.cmd_fail('not_found');
  end if;
  perform app.duties_refuse_ended(v_assignment, v_actor.member_id);
  if v_assignment.revision is distinct from p_expected_revision then
    perform app.cmd_fail('conflict', null, v_assignment.revision);
  end if;
  if v_assignment.response = 'pending' then
    perform app.cmd_fail('conflict', '{"assignment_id": "not_accepted"}', v_assignment.revision);
  end if;
  -- Only the member's own acceptance can be withdrawn here. An answer recorded any other way
  -- (a leader confirming on the member's behalf, entry 9) fails closed as already answered.
  if v_assignment.response <> 'accepted'
     or v_assignment.response_provenance is distinct from 'member' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', v_assignment.revision);
  end if;
  if app.duties_occurrence_start(v_occurrence) <= now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "started"}');
  end if;
  update app.duties_assignments a
     set response = 'declined', prior_accepted_at = a.responded_at, responded_at = now(),
         responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
         response_provenance = 'member', response_note = v_note, revision = a.revision + 1
   where a.assignment_id = v_assignment.assignment_id
  returning a.revision into v_revision;
  perform app.duties_audit_event('acceptance_withdrawn', v_actor.member_id, v_actor.account_id,
                                 'member', 'duties.withdraw_acceptance', v_occurrence.department_id,
                                 v_occurrence.occurrence_id, v_assignment.assignment_id,
                                 v_assignment.member_id, 'declined', v_revision);
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment.assignment_id,
    'reason', 'responded'));
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', 'declined', 'withdrawn', true));
end;
$$;

-- duties.accept_many {assignments: [{assignment_id, revision}, ...]}; expected null. The member
-- accepts several listed pending duties together, all or nothing.
create function app.duties_accept_many(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_items jsonb := p_payload -> 'assignments';
  v_item jsonb;
  v_ids uuid[] := '{}';
  v_revs jsonb := '{}';
  v_found integer;
  v_row record;
  v_problems jsonb := '{}';
  v_code text;
  v_first uuid;
  v_first_revision bigint;
  v_done jsonb := '[]';
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignments']);
  if jsonb_typeof(v_items) is distinct from 'array' then
    v_errors := v_errors || jsonb_build_object('assignments',
                  case when p_payload ? 'assignments' then 'invalid' else 'required' end);
  elsif jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"assignments": "required"}';
  elsif jsonb_array_length(v_items) > 50 then
    v_errors := v_errors || '{"assignments": "too_many"}';
  else
    for v_item in select x from jsonb_array_elements(v_items) x loop
      -- Checked one step at a time (SQL does not promise the order of OR operands).
      v_code := null;
      if jsonb_typeof(v_item) is distinct from 'object' then
        v_code := 'invalid';
      elsif app.contract_unknown_keys(v_item, array['assignment_id', 'revision']) <> '{}'::jsonb
            or app.contract_uuid_error(v_item -> 'assignment_id') is not null
            or jsonb_typeof(v_item -> 'revision') is distinct from 'number' then
        v_code := 'invalid';
      elsif (v_item ->> 'revision')::numeric <> trunc((v_item ->> 'revision')::numeric)
            or (v_item ->> 'revision')::numeric not between 1 and 9007199254740991 then
        v_code := 'invalid';
      end if;
      if v_code is not null then
        v_errors := v_errors || '{"assignments": "invalid"}';
        exit;
      end if;
      if (v_item ->> 'assignment_id')::uuid = any(v_ids) then
        v_errors := v_errors || '{"assignments": "duplicate"}';
        exit;
      end if;
      v_ids := v_ids || (v_item ->> 'assignment_id')::uuid;
      v_revs := v_revs || jsonb_build_object(v_item ->> 'assignment_id',
                                             (v_item ->> 'revision')::numeric::bigint);
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Every item must be the member's own assignment of a department-owned occurrence; anything
  -- else is not found, without saying which (no disclosure).
  select count(*) into v_found
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = any(v_ids) and a.member_id = v_actor.member_id
     and o.department_id is not null;
  if v_found <> cardinality(v_ids) then
    perform app.cmd_fail('not_found');
  end if;
  -- AD-2: occurrences FOR SHARE, then the assignments FOR UPDATE, in one order: series, then
  -- series date (the order duties.revise_series and duties.cancel_series lock a series' dates
  -- in, which differs from start order once one date was moved by duties.revise_duty), then
  -- start and id. One-off duties (no series) come after every series date.
  perform 1 from app.duties_occurrences o
   where o.occurrence_id in (select s.occurrence_id from app.duties_assignments a
                               join app.duties_slots s on s.slot_id = a.slot_id
                              where a.assignment_id = any(v_ids))
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
     for share;
  perform 1 from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = any(v_ids)
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
            s.position_no, a.assignment_id
     for update of a;
  for v_row in
    select a.*, o.occurrence_id as occ_id, o.department_id as dept_id,
           app.duties_occurrence_start(o) as start_at
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.assignment_id = any(v_ids)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
              s.position_no, a.assignment_id
  loop
    if v_row.member_id is distinct from v_actor.member_id or v_row.dept_id is null then
      perform app.cmd_fail('not_found');
    end if;
    v_code := case
      when v_row.assignment_state = 'superseded' then 'superseded'
      when v_row.assignment_state <> 'current' then 'cancelled'
      when v_row.response <> 'pending' then 'responded'
      when v_row.revision is distinct from (v_revs ->> v_row.assignment_id::text)::bigint then 'stale'
      when v_row.start_at <= now() then 'started'
    end;
    if v_code is not null then
      v_problems := v_problems || jsonb_build_object('assignment:' || v_row.assignment_id, v_code);
    end if;
  end loop;
  if v_problems <> '{}'::jsonb then
    perform app.cmd_fail('conflict', '{"assignments": "changed"}'::jsonb || v_problems);
  end if;
  for v_row in
    select a.assignment_id, a.member_id, o.occurrence_id as occ_id, o.department_id as dept_id
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.assignment_id = any(v_ids)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
              s.position_no, a.assignment_id
  loop
    update app.duties_assignments a
       set response = 'accepted', responded_at = now(),
           responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
           response_provenance = 'member', response_note = null, revision = a.revision + 1
     where a.assignment_id = v_row.assignment_id
    returning a.revision into v_revision;
    perform app.duties_audit_event('response_recorded', v_actor.member_id, v_actor.account_id,
                                   'member', 'duties.accept_many', v_row.dept_id, v_row.occ_id,
                                   v_row.assignment_id, v_row.member_id, 'accepted', v_revision);
    if v_first is null then
      v_first := v_row.assignment_id;
      v_first_revision := v_revision;
    end if;
    v_done := v_done || jsonb_build_array(jsonb_build_object('assignment_id', v_row.assignment_id,
                                                             'revision', v_revision));
  end loop;
  -- Notifications last.
  for v_row in select x ->> 'assignment_id' as id from jsonb_array_elements(v_done) x loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_row.id, 'reason', 'responded'));
  end loop;
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_first,
    'revision', v_first_revision,
    'data', jsonb_build_object('response', 'accepted', 'count', jsonb_array_length(v_done),
                               'assignments', v_done));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command entry point and authorizer (replaced: the 4.5 commands)
-- ---------------------------------------------------------------------------------------------

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
       'duties.withdraw_acceptance', 'duties.accept_many') then
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
     and (g.role = 'admin' or g.scope_kind in ('department_leader', 'department_deputy'))
     for share;
  return true;
end;
$$;

create or replace function app.duties_command(p_envelope jsonb)
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
      when 'duties.create_department'
        then 'app.duties_create_department(uuid, bigint, jsonb)'::regprocedure
      when 'duties.add_member' then 'app.duties_add_member(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_duty' then 'app.duties_publish_duty(uuid, bigint, jsonb)'::regprocedure
      when 'duties.respond' then 'app.duties_respond(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_duty' then 'app.duties_revise_duty(uuid, bigint, jsonb)'::regprocedure
      when 'duties.create_series' then 'app.duties_create_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.assign_slot' then 'app.duties_assign_slot(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_drafts' then 'app.duties_publish_drafts(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_series' then 'app.duties_revise_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_occurrence'
        then 'app.duties_cancel_occurrence(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_series' then 'app.duties_cancel_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.withdraw_acceptance'
        then 'app.duties_withdraw_acceptance(uuid, bigint, jsonb)'::regprocedure
      when 'duties.accept_many' then 'app.duties_accept_many(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
      and v_command is distinct from 'duties.accept_many'
  );
end;
$$;

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.5: departments, publishing and revising duties, the assignee''s answer '
  '(respond, withdraw_acceptance, accept_many) and rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Projections (replaced)
-- ---------------------------------------------------------------------------------------------

-- One assignment as its member sees it (4.3, plus the slot id (a stable calendar entry id across
-- revisions), the owner kind, the earlier acceptance of a
-- withdrawn answer and the department's current leader and deputy names). Department-owned only
-- (the inner join), as My duties lists.
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
    'owner_kind', 'department',
    'department_id', d.department_id,
    'department_name', d.name,
    'duty_name', o.duty_name,
    'position_name', s.position_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'response', a.response,
    'response_deadline', app.cmd_utc(a.response_deadline),
    'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
    'prior_accepted_at', case when a.prior_accepted_at is not null
                              then app.cmd_utc(a.prior_accepted_at) end,
    'note', a.response_note,
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
               'role', case g.scope_kind when 'department_leader' then 'leader' else 'deputy' end)
             order by (g.scope_kind = 'department_deputy'), m.display_name collate "C", g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
       where g.scope_id = d.department_id and g.revoked_at is null
         and g.scope_kind in ('department_leader', 'department_deputy')
         and m.membership_state = 'approved'
         and not exists (select 1 from app.identity_deletions dl where dl.member_id = m.member_id)),
      '[]'::jsonb))
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
    join app.duties_departments d on d.department_id = o.department_id
    left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
   where a.assignment_id = p_assignment_id;
$$;

-- The leader board's occurrence (4.4, plus `prior_accepted_at` on the position's assignment and
-- its history).
create or replace function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean, p_counts jsonb)
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
                          'prior_accepted_at', case when a.prior_accepted_at is not null
                                                    then app.cmd_utc(a.prior_accepted_at) end,
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
                                  'prior_accepted_at', case when a.prior_accepted_at is not null
                                                            then app.cmd_utc(a.prior_accepted_at) end,
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

-- The rota's occurrence (4.4, plus `prior_accepted_at` on the position's assignment).
create or replace function app.duties_rota_occurrence_json(p_occurrence_id uuid, p_counts jsonb)
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
                          'prior_accepted_at', case when a.prior_accepted_at is not null
                                                    then app.cmd_utc(a.prior_accepted_at) end,
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

-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_refuse_ended(app.duties_assignments, uuid),
  app.duties_assignment_occurrence(uuid),
  app.duties_withdraw_acceptance(uuid, bigint, jsonb),
  app.duties_accept_many(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
