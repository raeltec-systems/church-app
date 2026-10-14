-- Record duty completion outcomes and keep assignment history (story 4.10; AD-2, AD-5, AD-6,
-- AD-7). A forward migration on the Duties owner (20261013220239 .. 20261014212507 are not
-- edited). It adds:
--
--   * The outcome log (app.duties_outcomes): after a duty the department's leader or deputy
--     records Completed, Excused or No-show with an optional short note (duties.record_outcome);
--     a correction (duties.correct_outcome) appends a new revision that names the one it replaces,
--     with a required reason, so every earlier value, its actor, time and note are kept. No time
--     limit, no clearing back to Unrecorded. The log is append-only (only erasure may clear its
--     text and anonymise its actors).
--   * Response, coverage and completion stay separate: an outcome never changes the assignment
--     row or its revision; nothing records an outcome when time passes (reads say `unrecorded`);
--     only the current assignment of a published duty that has started may have one; a
--     superseded or cancelled assignment (a cancelled position or duty included) has none; No-show
--     only for an accepted assignment (member or Confirmed by leader), never for a declined or
--     unanswered one; a leader never records their own (`own`).
--   * api.duties_outcomes(from_date?, to_date?, department_id?, duty?): the started duties of the
--     departments the caller leads or deputises (church dates, default the last 14 days, at most
--     31, never after today) with each position's response and outcome or `unrecorded`, its
--     correction trail and what may be recorded; per-department counts; at most 1000 positions.
--   * api.duties_member_history(member_id?, before_at?, before_id?): one member's assignments
--     (one row per position held, newest first, 100 per page) with responses and outcomes and a
--     12-month summary, for the member themselves (every department) and for the current leaders
--     and deputies of the member's department (that department only). No figures about more than
--     one member are ever returned (no ranking).
--   * My duties shows the member's own outcome (duties_my_assignment_json).
--   * Privacy: outcomes, notes, correction reasons and history are for the member and the
--     department's leaders and deputies only; the Admin role alone, Pastor, other departments'
--     leaders and other members get nothing (403 not_granted on the reads; not_found / forbidden
--     on the commands). The board, rota, coverage queue and Admin overview are unchanged. Audit
--     rows hold codes only; no notification is sent.
--   * Gates: the Q4 personal-data gate (production stays inert); no scheduling, so the Q2 policy
--     is not needed.
--
-- Replaced bodies (each copied from its latest version, keeping every earlier review fix; changes
-- are marked "Story 4.10"):
--   from 20261014212507 (4.9): duties_state_ok, duties_authorize_command, duties_command,
--     duties_my_assignment_json, duties_deletion_remaining, duties_erase_member.
--
-- Lock order (AD-2): the actor's grant rows FOR SHARE (authorizer) -> command receipt ->
-- department FOR SHARE -> series FOR SHARE -> occurrence FOR SHARE -> assignment FOR UPDATE ->
-- outcome log (insert). No Follow-ups, no Notifications.
--
-- No destructive statements, no row deletions (no _rows file). New client grants: the two reads
-- (api and app bodies, authenticated only). ASCII only.


-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened: completion outcomes, audit actions)
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
    -- Story 4.9: `leader` = Confirmed by leader (a phone or in-person confirmation).
    when 'response_provenance' then p_value in ('member', 'leader')
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member')
    when 'change_class' then p_value in ('published', 'material', 'notes', 'reference', 'cancelled')
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
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn', 'reminders_set',
                                         'reminders_skipped', 'contact_attempt_recorded',
                                         'leader_confirmed', 'position_cancelled',
                                         'followup_skipped', 'outcome_recorded',
                                         'outcome_corrected')
    else false end;
$$;


-- ---------------------------------------------------------------------------------------------
-- The outcome log
-- ---------------------------------------------------------------------------------------------

-- One row per recorded value of an assignment's completion outcome: revision 1 is the first
-- record, each later revision a correction of the one before (supersedes_outcome_id, a required
-- reason). The current outcome is the highest revision. The note and the correction reason are
-- shown only to the member and the department's leaders and deputies, and are cleared when the
-- assignee is erased.
create table app.duties_outcomes (
  outcome_id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references app.duties_assignments (assignment_id) on delete cascade,
  revision bigint not null check (revision >= 1),
  outcome text not null check (app.duties_state_ok('completion_outcome', outcome)),
  note text check (note is null or length(note) between 1 and 200),
  supersedes_outcome_id uuid references app.duties_outcomes (outcome_id),
  correction_reason text check (correction_reason is null or length(correction_reason) between 1 and 200),
  recorded_by_member uuid not null,
  recorded_by_account uuid not null,
  recorded_at timestamptz not null default clock_timestamp(),
  unique (assignment_id, revision),
  check ((revision = 1) = (supersedes_outcome_id is null))
);

create unique index duties_outcomes_supersedes on app.duties_outcomes (supersedes_outcome_id)
  where supersedes_outcome_id is not null;
create index duties_outcomes_recorder on app.duties_outcomes (recorded_by_member);

comment on table app.duties_outcomes is
  'owner: duties. Story 4.10: append-only completion outcomes of assignments (Completed, Excused, '
  'No-show) with attributed corrections; notes for the member and the department''s leaders and '
  'deputies only.';

alter table app.duties_outcomes enable row level security;
revoke all on table app.duties_outcomes from public, anon, authenticated, service_role;

-- Outcomes are append-only: a row never changes, except erasure clearing its note or correction
-- reason and anonymising its recorder.
create function app.duties_outcome_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if (new.outcome_id, new.assignment_id, new.revision, new.outcome, new.supersedes_outcome_id,
      new.recorded_at)
     is distinct from
     (old.outcome_id, old.assignment_id, old.revision, old.outcome, old.supersedes_outcome_id,
      old.recorded_at)
     or (new.note is distinct from old.note and new.note is not null)
     or (new.correction_reason is distinct from old.correction_reason
         and new.correction_reason is not null)
     or (new.recorded_by_member is distinct from old.recorded_by_member
         and new.recorded_by_member is distinct from v_nil)
     or (new.recorded_by_account is distinct from old.recorded_by_account
         and new.recorded_by_account is distinct from v_nil) then
    raise exception using errcode = 'P0001', message = 'duties outcomes are append-only';
  end if;
  return new;
end;
$$;

create trigger duties_outcomes_append_only
  before update on app.duties_outcomes
  for each row execute function app.duties_outcome_guard();


-- ---------------------------------------------------------------------------------------------
-- Projection helpers
-- ---------------------------------------------------------------------------------------------

-- The outcome values an assignment may take: No-show only after an acceptance (by the member or
-- Confirmed by leader); a declined or unanswered assignment never becomes a No-show.
create function app.duties_outcomes_allowed(p_response text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p_response = 'accepted' then '["completed", "excused", "no_show"]'::jsonb
              else '["completed", "excused"]'::jsonb end;
$$;

-- An assignment's outcome trail, newest first (at most p_limit revisions): each value, its note,
-- the correction reason, who recorded it and when. Callers decide who may read it.
create function app.duties_outcome_trail(p_assignment_id uuid, p_limit integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'revision', x.revision,
           'outcome', x.outcome,
           'note', x.note,
           'reason', x.correction_reason,
           'by', app.duties_display_name(x.recorded_by_member),
           'at', app.cmd_utc(x.recorded_at)) order by x.revision desc), '[]'::jsonb)
    from (select o.* from app.duties_outcomes o where o.assignment_id = p_assignment_id
           order by o.revision desc limit p_limit) x;
$$;

-- The current outcome of an assignment as its readers (the member, the department's leaders and
-- deputies) see it: {outcome, revision, note, recorded_at, recorded_by, corrected, trail}, or
-- null when none was recorded.
create function app.duties_outcome_json(p_assignment_id uuid, p_trail integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'outcome', o.outcome,
           'revision', o.revision,
           'note', o.note,
           'recorded_at', app.cmd_utc(o.recorded_at),
           'recorded_by', app.duties_display_name(o.recorded_by_member),
           'corrected', o.revision > 1,
           'trail', case when p_trail > 0 then app.duties_outcome_trail(p_assignment_id, p_trail)
                         else '[]'::jsonb end)
    from app.duties_outcomes o
   where o.assignment_id = p_assignment_id
   order by o.revision desc
   limit 1;
$$;


-- ---------------------------------------------------------------------------------------------
-- The outcome commands
-- ---------------------------------------------------------------------------------------------

-- Locks an assignment for an outcome command in the AD-2 order (department, series and
-- occurrence FOR SHARE, then the assignment FOR UPDATE, which also serialises the outcome log of
-- that assignment), after checking without a lock that the actor leads or deputises its
-- department now (the Admin role alone: forbidden; anyone else, a cell-owned or unknown
-- assignment: not_found). Refuses the actor's own assignment (`own`), an ended assignment
-- (`conflict superseded | cancelled`, a cancelled position or duty included), a draft
-- (`not_found`), a duty that has not started (`not_started`) and an erased assignee (`erased`).
create function app.duties_lock_for_outcome(p_actor_member uuid, p_assignment_id uuid,
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
begin
  select o.department_id, o.series_id, o.occurrence_id, a.member_id
    into v_department, v_series, v_occurrence, v_assignee
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = p_assignment_id;
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
  -- A leader never grades their own duty.
  if v_assignee = p_actor_member then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "own"}');
  end if;
  perform 1 from app.duties_departments d
   where d.department_id = v_department and d.department_state = 'active' for share;
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
  end if;
end;
$$;

-- duties.record_outcome {assignment_id, outcome, note?}; expected = the assignment revision (the
-- answer the leader saw; an outcome never changes it). The first outcome of the current
-- assignment of a started duty (`conflict {"assignment_id": "recorded"}` once one exists: correct
-- it instead). No-show needs an acceptance (`{"outcome": "not_accepted"}`). Answer: ids, codes and
-- revisions only (no note).
create function app.duties_record_outcome(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_outcome text;
  v_note text;
  v_lock record;
  v_cmd constant text := 'duties.record_outcome';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'outcome', 'note']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_outcome
    from app.duties_code(p_payload, 'outcome', 'completion_outcome', v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 200, false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_for_outcome(v_actor.member_id, v_assignment_id) l;
  if (v_lock.assignment).revision is distinct from p_expected_revision then
    perform app.cmd_fail('conflict', null, (v_lock.assignment).revision);
  end if;
  if exists (select 1 from app.duties_outcomes o where o.assignment_id = v_assignment_id) then
    perform app.cmd_fail('conflict', '{"assignment_id": "recorded"}');
  end if;
  if v_outcome = 'no_show' and (v_lock.assignment).response <> 'accepted' then
    perform app.cmd_fail('validation_failed', '{"outcome": "not_accepted"}');
  end if;
  insert into app.duties_outcomes (assignment_id, revision, outcome, note, recorded_by_member,
                                   recorded_by_account)
  values (v_assignment_id, 1, v_outcome, v_note, v_actor.member_id, v_actor.account_id);
  perform app.duties_audit_event('outcome_recorded', v_actor.member_id, v_actor.account_id,
                                 v_lock.capacity, v_cmd, (v_lock.occurrence).department_id,
                                 (v_lock.occurrence).occurrence_id, v_assignment_id,
                                 (v_lock.assignment).member_id, v_outcome, 1);
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', (v_lock.occurrence).occurrence_id,
    'revision', (v_lock.occurrence).revision,
    'data', jsonb_build_object('assignment_id', v_assignment_id, 'outcome', v_outcome,
                               'outcome_revision', 1));
end;
$$;

-- duties.correct_outcome {assignment_id, outcome, note?, reason}; expected = the current outcome
-- revision. Appends the next revision (naming the one it replaces) with the required reason
-- (1-200); the earlier value, note, actor and time stay in the log. Refused without an outcome
-- (`unrecorded`), at a stale revision (`conflict` with the current outcome revision), when
-- nothing changes (`{"outcome": "unchanged"}`) and for a No-show without an acceptance.
create function app.duties_correct_outcome(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_outcome text;
  v_note text;
  v_reason text;
  v_lock record;
  v_current app.duties_outcomes;
  v_cmd constant text := 'duties.correct_outcome';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'outcome', 'note', 'reason']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_outcome
    from app.duties_code(p_payload, 'outcome', 'completion_outcome', v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 200, false, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_payload, 'reason', true, 200, false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_for_outcome(v_actor.member_id, v_assignment_id) l;
  -- The log of this assignment is serialised by the assignment lock above.
  select o.* into v_current from app.duties_outcomes o
   where o.assignment_id = v_assignment_id order by o.revision desc limit 1;
  if not found then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "unrecorded"}');
  end if;
  if v_current.revision is distinct from p_expected_revision then
    perform app.cmd_fail('conflict', null, v_current.revision);
  end if;
  if v_current.outcome = v_outcome and v_current.note is not distinct from v_note then
    perform app.cmd_fail('validation_failed', '{"outcome": "unchanged"}');
  end if;
  if v_outcome = 'no_show' and (v_lock.assignment).response <> 'accepted' then
    perform app.cmd_fail('validation_failed', '{"outcome": "not_accepted"}');
  end if;
  insert into app.duties_outcomes (assignment_id, revision, outcome, note, supersedes_outcome_id,
                                   correction_reason, recorded_by_member, recorded_by_account)
  values (v_assignment_id, v_current.revision + 1, v_outcome, v_note, v_current.outcome_id,
          v_reason, v_actor.member_id, v_actor.account_id);
  perform app.duties_audit_event('outcome_corrected', v_actor.member_id, v_actor.account_id,
                                 v_lock.capacity, v_cmd, (v_lock.occurrence).department_id,
                                 (v_lock.occurrence).occurrence_id, v_assignment_id,
                                 (v_lock.assignment).member_id, v_outcome, v_current.revision + 1);
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', (v_lock.occurrence).occurrence_id,
    'revision', (v_lock.occurrence).revision,
    'data', jsonb_build_object('assignment_id', v_assignment_id, 'outcome', v_outcome,
                               'outcome_revision', v_current.revision + 1,
                               'previous_outcome', v_current.outcome));
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Command entry point and authorizer (replaced: the two outcome commands)
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
       'duties.withdraw_acceptance', 'duties.accept_many', 'duties.set_reminders',
       'duties.record_contact_attempt', 'duties.confirm_by_leader', 'duties.cancel_position',
       -- Story 4.10.
       'duties.record_outcome', 'duties.correct_outcome') then
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
  'Stories 4.1-4.10: departments, publishing and revising duties, the assignee''s answer '
  '(respond, withdraw_acceptance, accept_many), rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series), reminders (set_reminders), '
  'coverage (record_contact_attempt, confirm_by_leader, cancel_position) and completion '
  '(record_outcome, correct_outcome) through the 1.4 envelope.';


-- ---------------------------------------------------------------------------------------------
-- The outcomes read (story 4.10)
-- ---------------------------------------------------------------------------------------------

-- Church time (Africa/Lusaka, owner decision Q2, when no valid policy zone is in force).
create function app.duties_church_zone()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_zone text;
begin
  begin
    v_zone := app.policy_effective('q2_church_time') -> 'value' ->> 'zone';
  exception when sqlstate 'PCMD1' then
    v_zone := null;
  end;
  if v_zone is null or not app.notifications_zone_known(v_zone) then
    v_zone := 'Africa/Lusaka';
  end if;
  return v_zone;
end;
$$;

-- `api.duties_outcomes(from_date, to_date, department_id, duty)`: see the header. Only the
-- departments the caller leads or deputises now (the Admin role alone, Pastor and members: 403
-- not_granted; a department filter the caller does not lead: the same). Set-based: one query for
-- the positions with each current outcome by index; the JSON (with the trail) only for the
-- positions listed. Errors: 403 unavailable (Q4 gate), 400 validation_failed (window, duty).
create function app.duties_outcomes(p_from date, p_to date, p_department_id uuid, p_duty text)
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
  if not exists (select 1 from app.identity_grants g
                  where g.member_id = v_member and g.revoked_at is null
                    and g.scope_kind in ('department_leader', 'department_deputy')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.duties_require_open_read();
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
  if cardinality(v_departments) = 0 then
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
        from app.duties_departments d where d.department_id = any (v_departments)), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_outcomes(from_date date default null, to_date date default null,
                                    department_id uuid default null, duty text default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_outcomes($1, $2, $3, $4);
$$;

comment on function api.duties_outcomes(date, date, uuid, text) is
  'Story 4.10: the started duties of the departments the caller leads or deputises (church '
  'dates, default the last 14 days) with each position''s response and completion outcome or '
  'unrecorded, its correction trail and department counts.';


-- ---------------------------------------------------------------------------------------------
-- A member's assignment history (story 4.10)
-- ---------------------------------------------------------------------------------------------

-- `api.duties_member_history(member_id, before_at, before_id)`: the caller's own history (no
-- member_id, or their own; every department) or, for a current leader or deputy, the history of
-- a member who is or was in a department they lead or deputise (that department's assignments
-- only). Anything else (the Admin role alone, Pastor, another department's leader, another
-- member, an unknown member): 403 not_granted, the same answer (no disclosure). One row per
-- position held (a material revision of the same person is the same row; the latest revision is
-- shown), newest first, 100 per page (`before_at` and `before_id` together: the last row's start
-- and assignment id). The summary covers the visible departments: past duties of the last 365
-- days (held, accepted, confirmed by leader, declined, unanswered, completed, excused, no-show,
-- unrecorded, ended), upcoming duties. Errors: 400 validation_failed (cursor), 403 unavailable.
create function app.duties_member_history(p_member_id uuid, p_before_at timestamptz, p_before_id uuid)
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
  if (p_before_at is null) <> (p_before_id is null) then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'cursor';
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
  perform app.duties_require_open_read();

  with held as (
    -- The member's assignments, one row per position held: the latest revision of this person on
    -- the slot (a material change re-asks the same person on a new row).
    select a.assignment_id, a.assignment_state, a.response, a.response_provenance, o.occurrence_id,
           o.department_id, o.starts_at, o.occurrence_state,
           app.duties_occurrence_start(o) <= now() as started,
           x.outcome
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
      left join lateral (select y.outcome from app.duties_outcomes y
                          where y.assignment_id = a.assignment_id
                          order by y.revision desc limit 1) x on true
     where a.member_id = v_target
       and o.department_id is not null
       and o.occurrence_state <> 'draft'
       and (v_self or o.department_id = any (v_departments))
       and not exists (select 1 from app.duties_assignments n
                        where n.supersedes_assignment_id = a.assignment_id and n.member_id = a.member_id)
  ), page as (
    select h.* from held h
     where p_before_at is null or (h.starts_at, h.assignment_id) < (p_before_at, p_before_id)
     order by h.starts_at desc, h.assignment_id desc
     limit 101
  ), live as (
    -- A position counts as held when its assignment is current on a published duty.
    select h.*, h.assignment_state = 'current' and h.occurrence_state = 'published' as is_live
      from held h
  )
  select jsonb_build_object(
    'member', jsonb_build_object('member_id', v_target,
                                 'display_name', app.duties_display_name(v_target)),
    'self', v_self,
    'departments', coalesce((select jsonb_agg(jsonb_build_object('department_id', d.department_id,
                                                                  'name', d.name)
                                              order by d.name, d.department_id)
                               from app.duties_departments d
                              where d.department_id in (select h.department_id from held h)), '[]'::jsonb),
    -- One member's own figures (never compared with anyone else).
    'summary', (select jsonb_build_object(
                  'since', app.cmd_utc(now() - interval '365 days'),
                  'held', count(*) filter (where l.is_live and l.started),
                  'accepted', count(*) filter (where l.is_live and l.started and l.response = 'accepted'
                                               and l.response_provenance = 'member'),
                  'confirmed_by_leader', count(*) filter (where l.is_live and l.started
                                                          and l.response_provenance = 'leader'),
                  'declined', count(*) filter (where l.is_live and l.started and l.response = 'declined'),
                  'unanswered', count(*) filter (where l.is_live and l.started and l.response = 'pending'),
                  'completed', count(*) filter (where l.is_live and l.started and l.outcome = 'completed'),
                  'excused', count(*) filter (where l.is_live and l.started and l.outcome = 'excused'),
                  'no_show', count(*) filter (where l.is_live and l.started and l.outcome = 'no_show'),
                  'unrecorded', count(*) filter (where l.is_live and l.started and l.outcome is null),
                  'ended', count(*) filter (where not l.is_live))
                  from live l
                 where l.starts_at >= now() - interval '365 days' and (l.started or not l.is_live)),
    'upcoming', (select count(*) from live l where l.is_live and not l.started),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'assignment_id', p.assignment_id,
               'occurrence_id', p.occurrence_id,
               'department_id', p.department_id,
               'department_name', d.name,
               'duty_name', o.duty_name,
               'position_name', s.position_name,
               'starts_at', app.cmd_utc(o.starts_at),
               'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
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
                 else coalesce(p.outcome, 'unrecorded') end,
               'outcome', case when p.assignment_state = 'current' and p.occurrence_state = 'published'
                               then app.duties_outcome_json(p.assignment_id, 20) end)
             order by p.starts_at desc, p.assignment_id desc)
        from (select * from page order by starts_at desc, assignment_id desc limit 100) p
        join app.duties_assignments a on a.assignment_id = p.assignment_id
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
        join app.duties_departments d on d.department_id = p.department_id), '[]'::jsonb),
    'has_more', (select count(*) > 100 from page))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_member_history(member_id uuid default null,
                                          before_at timestamptz default null,
                                          before_id uuid default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_member_history($1, $2, $3);
$$;

comment on function api.duties_member_history(uuid, timestamptz, uuid) is
  'Story 4.10: one member''s assignment history (responses, completion outcomes, corrections) '
  'and their own 12-month summary, for the member and their department''s leaders and deputies.';


-- ---------------------------------------------------------------------------------------------
-- My duties (replaced; copied from 20261014212507, story 4.10 adds the member's own outcome)
-- ---------------------------------------------------------------------------------------------

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


-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced; copied from 20261014212507, story 4.10: outcome notes, correction
-- reasons and recorders; no new row deletions)
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
              and (x.note is not null or x.correction_reason is not null)))::integer;
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
    -- Story 4.9: the leaders' practical notes about the erased assignee go with them (before the
    -- assignee is anonymised below).
    update app.duties_contact_attempts t set note = null
     where t.note is not null
       and t.assignment_id in (select a.assignment_id from app.duties_assignments a
                                where a.member_id = v_member);
    -- Story 4.10: the outcome notes and correction reasons about the erased assignee go with them
    -- (the outcome values stay, attached to the anonymised assignment).
    update app.duties_outcomes x set note = null, correction_reason = null
     where (x.note is not null or x.correction_reason is not null)
       and x.assignment_id in (select a.assignment_id from app.duties_assignments a
                                where a.member_id = v_member);
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
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_outcome_guard(),
  app.duties_outcomes_allowed(text),
  app.duties_outcome_trail(uuid, integer),
  app.duties_outcome_json(uuid, integer),
  app.duties_lock_for_outcome(uuid, uuid),
  app.duties_record_outcome(uuid, bigint, jsonb),
  app.duties_correct_outcome(uuid, bigint, jsonb),
  app.duties_church_zone(),
  app.duties_outcomes(date, date, uuid, text),
  api.duties_outcomes(date, date, uuid, text),
  app.duties_member_history(uuid, timestamptz, uuid),
  api.duties_member_history(uuid, timestamptz, uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.duties_outcomes(date, date, uuid, text) to authenticated;
grant execute on function api.duties_outcomes(date, date, uuid, text) to authenticated;
grant execute on function app.duties_member_history(uuid, timestamptz, uuid) to authenticated;
grant execute on function api.duties_member_history(uuid, timestamptz, uuid) to authenticated;

notify pgrst, 'reload schema';
