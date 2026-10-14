-- Work the coverage queue with contact attempts and leader confirmation (story 4.9; AD-2, AD-5,
-- AD-6, AD-7, AD-8). A forward migration on the Duties owner, with one Follow-ups owner operation
-- and one scoped Identity read (20261013220239 .. 20261014171038 are not edited). It adds:
--
--   * The coverage queue (`api.duties_coverage`): per department, the positions of published duties
--     that have not started in a window of church dates (today and the next six days by default,
--     at most 31 days; an optional department and duty-name filter), each with its state
--     (unfilled, awaiting, overdue, declined, changed, confirmed), the 4.8 Needs contact flag,
--     the open coverage case and its latest contact attempt, and per-department counts (required,
--     confirmed, unfilled, awaiting, overdue, declined, needs contact, conflicts, overdue
--     follow-ups). The department's leaders and deputies get the full view: the labelled 2.5
--     contact routes (through app.identity_scoped_contact_routes, behind the Q4 gate), attempt
--     notes, confirmation reasons and member notes. Admin (role alone) and Pastor get the
--     operational view of every department, with no contact route and no free text.
--   * duties.record_contact_attempt (leaders and deputies): a practical contact attempt with a
--     channel, an outcome, an optional practical note and the next follow-up date. The first
--     attempt of an assignment opens a coverage case (app.duties_coverage_cases) and its
--     Follow-ups task (source `duties_coverage_case`, purpose `coverage_follow_up`, owner and
--     supervisor = the recording leader, due = the next follow-up) through app.followups_open_task;
--     later attempts set that task Waiting with the next follow-up as its review date and the
--     outcome (new owner operation app.followups_source_review).
--   * duties.confirm_by_leader (leaders and deputies): Confirmed by leader on a pending
--     assignment, with the leader, the time, the channel and a required reason, kept distinct from
--     the member's own acceptance (response_provenance `leader`).
--   * duties.cancel_position (leaders, deputies, Admin): cancels one position of a published duty;
--     the last remaining position cancels the whole occurrence (one-off duties included).
--   * The coverage case closes with the assignment: accepted (by the member) or confirmed, and
--     superseded (reassignment, material change) close its task `source_resolved`; a cancellation
--     closes it `source_cancelled`. A later need opens a fresh case and task.
--   * The leaders' decline alert `duty_declined` (source `duties_coverage`, fresh key per decline
--     revision) when a member declines or withdraws an acceptance.
--   * Gates: every command and read needs the Q4 personal-data gate (production stays inert). With
--     the Q2 policy closed or invalid a confirmation and a contact attempt are still recorded; the
--     Follow-ups step and the reminder work are skipped and audited (`followup_skipped`,
--     `reminders_skipped`, code `policy_unavailable`).
--
-- Review fixes (independent review of 4.9, 2026-10-14; this migration was unmerged and unapplied,
-- so it is amended in place):
--   B1 the Confirmed by leader reason is shown on the leader board only to the department's
--      leaders and deputies (never to the Admin role alone or Pastor).
--   S1 closing a coverage case closes its Follow-ups task also with the Q2 policy invalid:
--      app.followups_source_event (replaced) needs only the Q4 gate (closing only removes work and
--      cancelling reminders needs no policy); the change engine passes its actor so any remaining
--      skip is audited.
--   S2 a leader cannot record contact or Confirmed by leader on their own assignment (`own`).
--   S3 the task's supervisor is another current, reachable leader or deputy of the department
--      (a leader first); the recorder only when nobody else holds the scope (a recorded fallback).
--   N1 coverage tasks follow a source-specific reminder schedule: the owner at the due or review
--      time (always before the duty), no supervisor alert, so nothing arrives after the service;
--      a case whose duty has started closes at its next touch.
--   N2/N3 an attempt whose case's task was finished by hand, or whose owner no longer holds the
--      department scope, closes that case and opens a fresh case and task for the recorder.
--   N4 duties_cancel_one (replaced) leaves already-cancelled positions alone.
--   N5 the queue builds its JSON only for the positions it lists; N8 `changed` counts once
--      (declined or changed); N9 an attempt on an erased assignee is `required_reassign`.
--
-- Replaced bodies (each copied from its latest version, keeping every earlier review fix; changes
-- are marked "Story 4.9"):
--   from 20261014171038 (4.8): duties_state_ok, duties_assignment_history_guard, duties_notify,
--     duties_apply_change, duties_plan_reminders, duties_after_answer, duties_respond,
--     duties_accept_many, duties_authorize_command, duties_command, duties_my_assignment_json,
--     duties_occurrence_json (3 arguments), duties_rota_occurrence_json;
--   from 20261014052239 (4.4): duties_erase_member, duties_deletion_remaining, duties_cancel_one;
--   from 20261014130535 (4.7, Follow-ups): followups_source_event (review S1: the Q4 gate only).
--
-- Lock order (AD-2): the actor's grant rows FOR SHARE (authorizer) -> command receipt ->
-- department FOR SHARE -> series FOR SHARE -> occurrence -> slots -> assignment FOR UPDATE ->
-- coverage case FOR UPDATE -> Follow-ups (its task, then its own reminders) -> Notifications
-- (cancel, enqueue, set_schedule), always last.
--
-- No destructive statements, no row deletions (no _rows file). One new client grant:
-- api.duties_coverage and its app body (authenticated only). ASCII only.


-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened: leader provenance, contact channels and outcomes, case close codes,
-- audit actions)
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
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn', 'reminders_set',
                                         'reminders_skipped', 'contact_attempt_recorded',
                                         'leader_confirmed', 'position_cancelled',
                                         'followup_skipped')
    else false end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- A cancelled position (story 4.9): no longer required, never assigned again.
alter table app.duties_slots
  add column cancelled_at timestamptz,
  add column cancelled_by_member uuid,
  add column cancelled_by_account uuid,
  add constraint duties_slots_cancelled
    check ((cancelled_at is null) = (cancelled_by_member is null)
           and (cancelled_at is null) = (cancelled_by_account is null));

comment on column app.duties_slots.cancelled_at is
  'Story 4.9: the position was cancelled (duties.cancel_position); it is no longer required.';

-- Confirmed by leader: the channel and the leader's reason (the leader and the time are the
-- response actor and time). The reason is cleared when the assignee is erased.
alter table app.duties_assignments
  add column confirmed_channel text
    check (confirmed_channel is null or app.duties_state_ok('contact_channel', confirmed_channel)),
  add column confirmed_reason text
    check (confirmed_reason is null or length(confirmed_reason) between 1 and 200),
  add constraint duties_assignments_leader_confirmed
    check ((response_provenance is not distinct from 'leader') = (confirmed_channel is not null)
           and (response_provenance is distinct from 'leader' or response = 'accepted')
           and (confirmed_reason is null or confirmed_channel is not null));

comment on column app.duties_assignments.confirmed_channel is
  'Story 4.9: Confirmed by leader: how the member confirmed (phone, message, in_person, other).';
comment on column app.duties_assignments.confirmed_reason is
  'Story 4.9: Confirmed by leader: the leader''s short reason (department leaders and deputies only).';

-- One coverage case per assignment and need: opened by the first contact attempt, closed with the
-- assignment (accepted, confirmed, superseded, cancelled). Its Follow-ups task is keyed by the
-- case id, so a later need gets a fresh case and task.
create table app.duties_coverage_cases (
  case_id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references app.duties_assignments (assignment_id) on delete cascade,
  department_id uuid not null,
  opened_at timestamptz not null default now(),
  opened_by_member uuid not null,
  opened_by_account uuid not null,
  task_id uuid,
  closed_at timestamptz,
  close_code text check (close_code is null or app.duties_state_ok('case_close', close_code)),
  check ((closed_at is null) = (close_code is null))
);

create unique index duties_coverage_cases_open
  on app.duties_coverage_cases (assignment_id) where closed_at is null;
create index duties_coverage_cases_assignment on app.duties_coverage_cases (assignment_id, opened_at);

comment on table app.duties_coverage_cases is
  'owner: duties. Story 4.9: one coverage follow-up per assignment and need (its Follow-ups task '
  'is keyed by case_id). Ids, codes and times only.';

-- Practical contact attempts (no pastoral or medical detail): who tried, how, what came of it, the
-- next follow-up. The note is shown to the department's leaders and deputies only and is cleared
-- when the assignee is erased.
create table app.duties_contact_attempts (
  attempt_id uuid primary key default gen_random_uuid(),
  case_id uuid not null references app.duties_coverage_cases (case_id) on delete cascade,
  assignment_id uuid not null references app.duties_assignments (assignment_id) on delete cascade,
  channel text not null check (app.duties_state_ok('contact_channel', channel)),
  outcome text not null check (app.duties_state_ok('contact_outcome', outcome)),
  note text check (note is null or length(note) between 1 and 280),
  next_follow_up_at timestamptz not null,
  recorded_by_member uuid not null,
  recorded_by_account uuid not null,
  recorded_at timestamptz not null default clock_timestamp()
);

create index duties_contact_attempts_case on app.duties_contact_attempts (case_id, recorded_at);
create index duties_contact_attempts_assignment on app.duties_contact_attempts (assignment_id);

comment on table app.duties_contact_attempts is
  'owner: duties. Story 4.9: practical contact attempts of a coverage case (the note is for the '
  'department''s leaders and deputies only).';

alter table app.duties_coverage_cases enable row level security;
alter table app.duties_contact_attempts enable row level security;
revoke all on table app.duties_coverage_cases from public, anon, authenticated, service_role;
revoke all on table app.duties_contact_attempts from public, anon, authenticated, service_role;

-- Attempts are immutable, except erasure clearing the note and anonymising the recorder.
create function app.duties_contact_attempt_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if (new.attempt_id, new.case_id, new.assignment_id, new.channel, new.outcome,
      new.next_follow_up_at, new.recorded_at)
     is distinct from
     (old.attempt_id, old.case_id, old.assignment_id, old.channel, old.outcome,
      old.next_follow_up_at, old.recorded_at)
     or (new.note is distinct from old.note and new.note is not null)
     or (new.recorded_by_member is distinct from old.recorded_by_member
         and new.recorded_by_member is distinct from v_nil)
     or (new.recorded_by_account is distinct from old.recorded_by_account
         and new.recorded_by_account is distinct from v_nil) then
    raise exception using errcode = 'P0001', message = 'duties contact attempts are immutable';
  end if;
  return new;
end;
$$;

create trigger duties_contact_attempts_immutable
  before update on app.duties_contact_attempts
  for each row execute function app.duties_contact_attempt_guard();


-- Ended assignments are immutable (replaced, story 4.9: the confirmation channel too; erasure may
-- also clear the confirmation reason).

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
      new.override_overlaps, new.override_at, new.prior_accepted_at, new.deadline_source,
      new.short_notice, new.confirmed_channel)
     is distinct from
     (old.assignment_id, old.slot_id, old.assignment_state, old.response, old.response_deadline,
      old.responded_at, old.response_provenance, old.revision, old.assigned_at,
      old.slot_revision, old.supersedes_assignment_id, old.ended_at, old.end_reason,
      old.override_overlaps, old.override_at, old.prior_accepted_at, old.deadline_source,
      old.short_notice, old.confirmed_channel)
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
     or (new.override_reason is distinct from old.override_reason and new.override_reason is not null)
     -- Story 4.9: only erasure may clear the leader's confirmation reason.
     or (new.confirmed_reason is distinct from old.confirmed_reason and new.confirmed_reason is not null) then
    raise exception using errcode = 'P0001', message = 'ended duties assignments are immutable';
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Identity: the scoped contact-route read (owner: identity)
-- ---------------------------------------------------------------------------------------------

-- The labelled 2.5 contact routes (`app.identity_contact_routes`; never a phone username, never a
-- hold or deletion reason) of p_member_ids, for a viewer who holds the scope (p_scope_kind,
-- p_scope_id) now: {"<member_id>": [{phone, belongs_to, holder_label}]}. Behind the Q4
-- personal-data gate (identity_applications_open: local, staging or Q4 approved); while
-- q4_personal_data itself is not approved only SYNTHETIC routes are returned (fail closed).
-- Members no longer approved or under deletion have none. The caller (a definer read of the
-- scope's owner) passes only members of the scope's target: Identity does not know rosters.
-- Not client-executable.
create function app.identity_scoped_contact_routes(p_viewer uuid, p_scope_kind text, p_scope_id uuid,
                                                   p_member_ids uuid[])
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case
    when p_viewer is null or p_scope_kind is null or p_scope_id is null
         or not app.identity_applications_open()
         or not app.identity_member_has_scope(p_viewer, p_scope_kind, p_scope_id)
      then '{}'::jsonb
    else coalesce((
      select jsonb_object_agg(x.member_id, x.routes)
        from (select r.member_id,
                     jsonb_agg(jsonb_build_object('phone', r.value, 'belongs_to', r.belongs_to,
                                                  'holder_label', r.holder_label)
                               order by r.created_at, r.route_id) as routes
                from app.identity_contact_routes r
                join app.identity_members m on m.member_id = r.member_id
               where r.member_id = any (p_member_ids) and r.ended_at is null
                 and m.membership_state = 'approved'
                 and not exists (select 1 from app.identity_deletions d where d.member_id = r.member_id)
                 and (r.is_synthetic or app.policy_is_open('q4_personal_data'))
               group by r.member_id) x), '{}'::jsonb)
  end;
$$;

comment on function app.identity_scoped_contact_routes(uuid, text, uuid, uuid[]) is
  'owner: identity. Story 4.9: labelled 2.5 contact routes for a viewer who holds the scope, '
  'behind the Q4 gate (SYNTHETIC routes only until q4_personal_data is approved).';


-- ---------------------------------------------------------------------------------------------
-- Follow-ups: a source's review of its open task (owner operation; owner: followups)
-- ---------------------------------------------------------------------------------------------

-- A source owner records progress on the active task of a source and purpose (inside its own
-- command, after locking its source): the task becomes Waiting with p_input.review_at as its
-- review date (future, at most a year away), optionally with a registered outcome; the
-- reminders follow the new review date (Notifications last, through the 4.7 scheduler). Input
-- (strict): source_type, source_id, purpose, review_at, outcome?, actor_member_id,
-- actor_account_id. Activity is recorded with capacity `source` (ids, states and dates only).
-- Answers {task_id, revision} or {task_id: null} when no task is active. Behind the Q4 and Q2
-- gates like every Follow-ups change (`unavailable` otherwise).
create function app.followups_source_review(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_source_type text;
  v_source_id uuid;
  v_purpose text;
  v_review timestamptz;
  v_outcome text;
  v_actor_member uuid;
  v_actor_account uuid;
  v_task app.followups_tasks;
  v_outcomes text[];
  v_revision bigint;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id', 'purpose',
                'review_at', 'outcome', 'actor_member_id', 'actor_account_id']);
  select t.errors, t.value into v_errors, v_source_type
    from app.followups_token(p_input, 'source_type', true, v_errors) t;
  select t.errors, t.value into v_errors, v_purpose
    from app.followups_token(p_input, 'purpose', true, v_errors) t;
  select t.errors, t.value into v_errors, v_source_id
    from app.followups_uuid(p_input, 'source_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_review
    from app.followups_instant(p_input, 'review_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_outcome
    from app.followups_token(p_input, 'outcome', false, v_errors) t;
  select t.errors, t.value into v_errors, v_actor_member
    from app.followups_uuid(p_input, 'actor_member_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_actor_account
    from app.followups_uuid(p_input, 'actor_account_id', true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  if v_review <= now() then
    perform app.cmd_fail('validation_failed', '{"review_at": "past"}');
  elsif v_review > now() + interval '1 year' then
    perform app.cmd_fail('validation_failed', '{"review_at": "out_of_range"}');
  end if;
  select p.outcomes into v_outcomes from app.followups_purposes p
   where p.source_type = v_source_type and p.purpose = v_purpose;
  if not found then
    perform app.cmd_fail('validation_failed', '{"purpose": "unregistered"}');
  end if;
  if v_outcome is not null and not (v_outcome = any (v_outcomes)) then
    perform app.cmd_fail('validation_failed', '{"outcome": "unregistered"}');
  end if;
  select t.* into v_task from app.followups_tasks t
   where t.source_type = v_source_type and t.source_id = v_source_id and t.purpose = v_purpose
     and app.followups_state_ok('active_state', t.task_state)
     for update;
  if not found then
    return jsonb_build_object('task_id', null, 'revision', null);
  end if;
  update app.followups_tasks t
     set task_state = 'waiting',
         review_at = v_review,
         latest_outcome = coalesce(v_outcome, t.latest_outcome),
         -- The reminders' revision moves with the actionable deadline only (4.7).
         schedule_revision = t.schedule_revision
           + case when v_review is distinct from v_task.review_at then 1 else 0 end,
         revision = t.revision + 1,
         updated_at = now()
   where t.task_id = v_task.task_id
  returning t.revision into v_revision;
  if v_outcome is not null then
    perform app.followups_activity_event(v_task.task_id, 'outcome_recorded', v_actor_member,
                                         v_actor_account, 'source', null, null, null, null,
                                         v_outcome, null, null, null, null, v_revision);
  end if;
  if v_task.task_state <> 'waiting' then
    perform app.followups_activity_event(v_task.task_id, 'status_changed', v_actor_member,
                                         v_actor_account, 'source', null, null, v_task.task_state,
                                         'waiting', null, v_review, null, null, null, v_revision);
  elsif v_review is distinct from v_task.review_at then
    perform app.followups_activity_event(v_task.task_id, 'review_date_set', v_actor_member,
                                         v_actor_account, 'source', null, null, 'waiting',
                                         'waiting', null, v_review, null, null, null, v_revision);
  end if;
  -- Notifications last (AD-2): the reminders follow the review date.
  if v_task.task_state <> 'waiting' or v_review is distinct from v_task.review_at then
    perform app.followups_schedule_reminders(v_task.task_id, false, v_actor_member);
  end if;
  return jsonb_build_object('task_id', v_task.task_id, 'revision', v_revision);
end;
$$;

-- Replaced (owner: followups; copied from 20261014130535, same signature and answers), story 4.9
-- review S1: the Q4 gate only (see above).
create or replace function app.followups_source_event(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_source_id uuid;
  v_event text;
  v_task record;
  v_closed integer := 0;
  v_kept integer := 0;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id', 'event'])
              || jsonb_strip_nulls(jsonb_build_object(
                   'source_type', app.contract_token_error(p_input -> 'source_type')));
  select t.errors, t.value into v_errors, v_source_id
    from app.followups_uuid(p_input, 'source_id', true, v_errors) t;
  v_event := p_input ->> 'event';
  if jsonb_typeof(p_input -> 'event') is distinct from 'string'
     or not app.followups_state_ok('source_event', v_event) then
    v_errors := v_errors || '{"event": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  -- Story 4.9 review S1: closing (or keeping) a source's tasks only removes work and cancelling
  -- their reminders needs no scheduling policy, so only the Q4 personal-data gate applies here; a
  -- source event is never lost to an invalid Q2 policy.
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  for v_task in
    select t.task_id, t.task_state, t.revision,
           case v_event when 'resolved' then p.on_source_resolved else p.on_source_cancelled end as effect
      from app.followups_tasks t
      join app.followups_purposes p on p.source_type = t.source_type and p.purpose = t.purpose
     where t.source_type = p_input ->> 'source_type' and t.source_id = v_source_id
       and app.followups_state_ok('active_state', t.task_state)
     order by t.task_id
       for update of t
  loop
    if v_task.effect = 'close' then
      update app.followups_tasks t
         set task_state = 'closed', review_at = null, finished_at = now(),
             close_code = 'source_' || v_event, revision = t.revision + 1, updated_at = now()
       where t.task_id = v_task.task_id;
      perform app.followups_activity_event(v_task.task_id, 'closed_by_source', null, null, 'source',
                                           null, null, v_task.task_state, 'closed', null, null,
                                           null, null, v_event, v_task.revision + 1);
      perform app.followups_cancel_reminders(v_task.task_id, null, null, 'source_' || v_event);
      v_closed := v_closed + 1;
    else
      v_kept := v_kept + 1;
    end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'kept', v_kept);
end;
$$;


comment on function app.followups_source_review(jsonb) is
  'Story 4.9 owner operation: a source sets its active task Waiting with a new review date and '
  'optional outcome (activity capacity source; reminders follow).';


-- ---------------------------------------------------------------------------------------------
-- The coverage case source (Follow-ups purpose) and the leaders' decline alert
-- ---------------------------------------------------------------------------------------------

-- `duties_coverage_case` (source id = the case id, revision 1): current while the case is open
-- and its assignment is current on a published duty.
create function app.duties_coverage_case_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'current', coalesce((
      select c.closed_at is null and a.assignment_state = 'current'
             and o.occurrence_state = 'published'
        from app.duties_coverage_cases c
        join app.duties_assignments a on a.assignment_id = c.assignment_id
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
       where c.case_id::text = p_source ->> 'source_id'), false)
      and (p_source ->> 'source_revision') = '1',
    'revision', 1);
$$;

-- The task's minimal context: the duty and its church date (no member, no note, no route).
create function app.duties_coverage_case_context(p_input jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('label',
           'Duty cover: ' || left(o.duty_name, 50) || ' on '
           || to_char(o.starts_at at time zone 'Africa/Lusaka', 'YYYY-MM-DD'))
    from app.duties_coverage_cases c
    join app.duties_assignments a on a.assignment_id = c.assignment_id
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where c.case_id::text = p_input ->> 'source_id';
$$;

select app.contract_register_source_type(
  'duties', 'duties_coverage_case', 'app.duties_coverage_case_source_check(jsonb)'::regprocedure);
select app.contract_register_purpose('duties', 'duties_coverage_case', 'coverage_follow_up');
select app.followups_register_purpose(
  'duties', 'duties_coverage_case', 'coverage_follow_up',
  '{"label": "Duty cover follow-up",
    "scope_kinds": ["department_leader", "department_deputy"],
    "outcomes": ["no_answer", "left_message", "will_answer", "cannot_serve", "other"],
    "on_source_resolved": "close", "on_source_cancelled": "close", "manual_create": false}',
  'app.duties_coverage_case_context(jsonb)'::regprocedure);
-- Review N1: the owner is reminded at the due or review time only (both always before the duty
-- starts); no supervisor alert (it would come a day after the deadline, possibly after the
-- service); no assignment notice (the owner recorded the attempt).
select app.followups_register_reminder_schedule('duties', 'duties_coverage_case', 'coverage_follow_up',
  '{"owner": [{"anchor": "deadline", "before": "0 minutes"}], "supervisor": [], "on_assignment": false}');

-- duty_declined: actionable while the assignment is current at that revision, declined and the
-- duty has not started; the recipient leads or deputises the department now, is reachable in
-- the app (a held or in-review leader is refused) and is not the assignee.
create function app.duties_decline_alert_check(p_key jsonb)
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
    'recipient_eligible', v_occurrence.department_id is not null
                          and v_assignment.member_id::text is distinct from p_key ->> 'recipient_member_id'
                          and (app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                             'department_leader', v_occurrence.department_id)
                               or app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                                'department_deputy', v_occurrence.department_id))
                          and app.duties_leader_reachable((p_key ->> 'recipient_member_id')::uuid));
end;
$$;

select app.contract_register_reminder_kind('duties', 'duties_coverage', 'duty_declined');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'duty_declined',
  'app.duties_decline_alert_check(jsonb)'::regprocedure,
  '{"title": "Duty declined",
    "body": "A member cannot make a duty in your department. Open Coverage to find cover.",
    "link": "/duties/coverage"}'::jsonb);


-- ---------------------------------------------------------------------------------------------
-- Coverage cases: closing with the assignment (Follow-ups after Duties, before Notifications)
-- ---------------------------------------------------------------------------------------------

-- Closes the open coverage case of each assignment (p_code: accepted, confirmed, superseded,
-- cancelled) and applies the Follow-ups source event to its task (`resolved`, or `cancelled` for
-- a cancellation). With the Q2/Q4 policy unavailable the case still closes and the skipped
-- Follow-ups step is audited (`followup_skipped`, code `policy_unavailable`); the task's reminders
-- then stop at delivery, because its source is no longer current. Returns how many cases closed.
create function app.duties_close_cases(p_assignment_ids uuid[], p_code text, p_actor_member uuid,
                                       p_actor_account uuid, p_capacity text, p_command text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_case record;
  v_count integer := 0;
  v_message text;
begin
  for v_case in
    select c.case_id, c.assignment_id, c.department_id, c.task_id
      from app.duties_coverage_cases c
     where c.assignment_id = any (p_assignment_ids) and c.closed_at is null
     order by c.assignment_id
       for update
  loop
    update app.duties_coverage_cases c set closed_at = now(), close_code = p_code
     where c.case_id = v_case.case_id;
    v_count := v_count + 1;
    if v_case.task_id is not null then
      begin
        perform app.followups_source_event(jsonb_build_object(
          'source_type', 'duties_coverage_case', 'source_id', v_case.case_id,
          'event', case when p_code = 'cancelled' then 'cancelled' else 'resolved' end));
      exception when sqlstate 'PCMD1' then
        get stacked diagnostics v_message = message_text;
        if v_message is distinct from 'unavailable' then
          raise;
        end if;
        if p_actor_member is not null and p_actor_account is not null and p_capacity is not null then
          perform app.duties_audit_event('followup_skipped', p_actor_member, p_actor_account,
                                         p_capacity, p_command, v_case.department_id, null,
                                         v_case.assignment_id, null, 'policy_unavailable', null);
        else
          -- A change's notification runner has no actor here; that command needs the policy for
          -- its own notices, so it fails before committing anyway.
          raise log 'duties coverage case % closed without its Follow-ups step (policy unavailable)',
            v_case.case_id;
        end if;
      end;
    end if;
  end loop;
  return v_count;
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Replaced: the reminder plan (4.8), the after-answer step, the notification runner
-- ---------------------------------------------------------------------------------------------

-- As in 4.8 (review fixes 1, 2, 6 kept); story 4.9: the loop that cancels the alerts of leaders no
-- longer in the list only touches the overdue and short-notice alerts, so a pending decline
-- alert is never cancelled by a re-plan.
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
  if v_o.occurrence_state <> 'published' or v_o.department_id is null or v_start <= now() then
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

  if v_a.response = 'pending' then
    v_leaders := app.duties_alert_recipients(v_o.department_id, v_a.member_id);
  end if;
  -- Leaders no longer in the list (or an answered assignment) lose their pending alert.
  -- Story 4.9: only the overdue and short-notice alerts (a decline alert is not re-planned).
  for v_leader in select distinct j.recipient_member_id from app.notifications_jobs j
                   where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                     and j.job_state = 'pending'
                     and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice')
                     and not (j.recipient_member_id = any (v_leaders))
                   order by j.recipient_member_id loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient',
      'reminder_kind', 'duty_response_overdue'));
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient',
      'reminder_kind', 'duty_short_notice'));
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
                             and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice')
                             and j.job_state <> 'cancelled');
    v_job := app.notifications_enqueue(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_leader,
      'reminder_kind', case when v_a.short_notice then 'duty_short_notice' else 'duty_response_overdue' end,
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

-- After the assignee answered, or a leader confirmed (respond, withdraw_acceptance, accept_many,
-- confirm_by_leader; their own cancel of the assignment's jobs has run): as in 4.8 (review fix 4
-- kept: an answer is always recorded; with the Q2 policy unavailable the reminder work is skipped
-- and audited `reminders_skipped`). Story 4.9: a decline enqueues one `duty_declined` alert now
-- for each current leader and deputy the app can reach (keyed by the declined revision, so every
-- decline is a fresh key), and the audit's capacity is the actor's (a leader confirming).
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
                     else coalesce(app.duties_manage_capacity(p_actor_member, v_o.department_id),
                                   'member') end;
  begin
    if v_a.response = 'accepted' then
      perform app.duties_plan_reminders(p_assignment_id, false, null);
    elsif v_o.department_id is not null and app.duties_occurrence_start(v_o) > now() then
      -- Story 4.9: the leaders' decline alert.
      foreach v_leader in array app.duties_alert_recipients(v_o.department_id, v_a.member_id) loop
        perform app.notifications_enqueue(jsonb_build_object(
          'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
          'source_revision', v_a.revision, 'recipient_member_id', v_leader,
          'reminder_kind', 'duty_declined', 'scheduled_at', app.cmd_utc(now())));
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

-- Runs the notification work a Duties change produced, after every Duties row is written
-- (Notifications last, AD-2). As in 4.8; story 4.9: first (Follow-ups before Notifications) the
-- open coverage cases of every assignment whose jobs are cancelled for a change or a cancellation
-- close, with their Follow-ups tasks (`superseded` -> resolved, `cancelled` -> cancelled).
create or replace function app.duties_notify(p_ops jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_op jsonb;
  v_job jsonb;
  v_queued integer := 0;
  v_created integer := 0;
  v_kind text;
  v_k text;
  v_cancelled integer;
  v_revised uuid[];
  v_ended uuid[];
  -- Review S1: the actor of the change (set by the change engine and the cancellations), so a
  -- skipped Follow-ups step is audited.
  v_actor jsonb := nullif(pg_catalog.current_setting('app.duties_actor', true), '')::jsonb;
begin
  -- Story 4.9: coverage cases close with their assignment (Follow-ups, before Notifications).
  select coalesce(array_agg(distinct (x ->> 'source_id')::uuid) filter (where x ->> 'reason' = 'source_revised'), '{}'),
         coalesce(array_agg(distinct (x ->> 'source_id')::uuid) filter (where x ->> 'reason' = 'source_cancelled'), '{}')
    into v_revised, v_ended
    from jsonb_array_elements(coalesce(p_ops, '[]'::jsonb)) x
   where x ->> 'op' = 'cancel';
  if cardinality(v_revised) > 0 then
    perform app.duties_close_cases(v_revised, 'superseded', (v_actor ->> 'member')::uuid,
                                   (v_actor ->> 'account')::uuid, v_actor ->> 'capacity',
                                   v_actor ->> 'command');
  end if;
  if cardinality(v_ended) > 0 then
    perform app.duties_close_cases(v_ended, 'cancelled', (v_actor ->> 'member')::uuid,
                                   (v_actor ->> 'account')::uuid, v_actor ->> 'capacity',
                                   v_actor ->> 'command');
  end if;
  for v_op in select x from jsonb_array_elements(coalesce(p_ops, '[]'::jsonb)) x loop
    if v_op ->> 'op' = 'cancel' then
      perform app.notifications_cancel(jsonb_build_object(
        'source_type', 'duties_assignment', 'source_id', v_op ->> 'source_id',
        'reason', v_op ->> 'reason'));
      -- Story 4.8: the leaders' alert about the assignment ends with it.
      perform app.notifications_cancel(jsonb_build_object(
        'source_type', 'duties_coverage', 'source_id', v_op ->> 'source_id',
        'reason', v_op ->> 'reason'));
    elsif v_op ->> 'op' = 'plan' then
      perform app.duties_plan_reminders((v_op ->> 'assignment_id')::uuid,
                                        coalesce((v_op ->> 'fresh')::boolean, false),
                                        v_op ->> 'notice');
    elsif v_op ->> 'op' = 'enqueue' then
      v_job := app.notifications_enqueue(v_op -> 'key');
      if coalesce((v_job ->> 'created')::boolean, false) then
        v_created := v_created + 1;
        if coalesce((v_op ->> 'counts')::boolean, true) then
          v_queued := v_queued + 1;
        end if;
      end if;
    elsif v_op ->> 'op' = 'replace' then
      v_kind := null;
      foreach v_k in array array['duty_assigned', 'duty_changed', 'duty_updated'] loop
        v_cancelled := (app.notifications_cancel(jsonb_build_object(
          'source_type', 'duties_assignment', 'source_id', v_op ->> 'source_id',
          'reason', 'replaced', 'reminder_kind', v_k)) ->> 'cancelled')::integer;
        if v_cancelled > 0 and v_kind is null then
          v_kind := v_k;
        end if;
      end loop;
      -- The clock time keeps the new job's logical key distinct from the replaced one.
      v_job := app.notifications_enqueue(jsonb_build_object(
        'source_type', 'duties_assignment', 'source_id', v_op ->> 'source_id',
        'source_revision', (v_op ->> 'source_revision')::bigint,
        'recipient_member_id', v_op ->> 'recipient', 'reminder_kind', coalesce(v_kind, 'duty_updated'),
        'scheduled_at', app.cmd_utc(clock_timestamp())));
      if coalesce((v_job ->> 'created')::boolean, false) then
        v_created := v_created + 1;
        v_queued := v_queued + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('queued', v_queued, 'created', v_created);
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- The shared change engine (replaced, same signature; story 4.9): a cancelled position is never
-- changed or given again (`{"slot_id": "cancelled"}` when it is the target). Everything else as in
-- 4.8.
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
  v_need_deadline := v_member_changed
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
-- Member answers (replaced; story 4.9: an acceptance closes the assignment's open coverage case
-- and its Follow-ups task before the Notifications work)
-- ---------------------------------------------------------------------------------------------

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
  -- Story 4.9: an acceptance resolves the coverage case (Follow-ups, before Notifications); a
  -- decline keeps it open (the position still needs cover).
  if p_payload ->> 'response' = 'accepted' then
    perform app.duties_close_cases(array[v_assignment.assignment_id], 'accepted', v_actor.member_id,
                                   v_actor.account_id, 'member', 'duties.respond');
  end if;
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment.assignment_id,
    'reason', 'responded'));
  -- Story 4.8: the leaders' alert stops; an acceptance keeps its pre-service reminders.
  -- Story 4.9: a decline alerts the leaders.
  perform app.duties_after_answer(v_assignment.assignment_id, v_actor.member_id, v_actor.account_id,
                                  'duties.respond');
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    -- Ids and states only (the note stays out of the receipt); clients read My duties again.
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', p_payload ->> 'response'));
end;
$$;


create or replace function app.duties_accept_many(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  -- Story 4.9: the accepted dates' coverage cases close (Follow-ups, before Notifications).
  perform app.duties_close_cases(v_ids, 'accepted', v_actor.member_id, v_actor.account_id, 'member',
                                 'duties.accept_many');
  -- Notifications last.
  for v_row in select x ->> 'assignment_id' as id from jsonb_array_elements(v_done) x loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_row.id, 'reason', 'responded'));
    -- Story 4.8: the leaders' alert stops; the pre-service reminders are planned again.
    perform app.duties_after_answer(v_row.id::uuid, v_actor.member_id, v_actor.account_id,
                                    'duties.accept_many');
  end loop;
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_first,
    'revision', v_first_revision,
    'data', jsonb_build_object('response', 'accepted', 'count', jsonb_array_length(v_done),
                               'assignments', v_done));
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Cancelling one occurrence (replaced; copied from 20261014052239, story 4.9 review N4 and S1)
-- ---------------------------------------------------------------------------------------------

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
  -- Story 4.9 review S1: the cancellation's actor for app.duties_notify.
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
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
  -- Story 4.9 review N4: a position cancelled before keeps its own cancelled revision.
  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_occ.occurrence_id
                   and s.cancelled_at is null
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
-- Leader commands on one assignment (story 4.9)
-- ---------------------------------------------------------------------------------------------

-- Locks a current assignment for a leader's coverage command, in the AD-2 order (department,
-- series and occurrence FOR SHARE, then the assignment FOR UPDATE), after checking without a
-- lock that the actor leads or deputises its department (anything else, a cell-owned or unknown
-- assignment: not_found; Admin role alone and Pastor: forbidden). Refuses an ended assignment
-- (`conflict {"assignment_id": "superseded" | "cancelled"}`), a stale revision (`conflict` with
-- the current revision), a duty that is not published (`not_found`) or has started
-- (`validation_failed {"assignment_id": "started"}`).
create function app.duties_lock_for_leader(p_actor_member uuid, p_assignment_id uuid,
                                           p_expected_revision bigint,
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
  capacity := app.duties_manage_capacity(p_actor_member, v_department);
  if capacity is null then
    perform app.cmd_fail('not_found');
  elsif capacity = 'admin' then
    -- The Admin role alone does not hold the department's scope (no contact work, no task).
    perform app.cmd_fail('forbidden');
  end if;
  -- Review S2: a leader answers their own duty in My duties (never as a contact or a leader
  -- confirmation of themselves).
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

-- Review S3: the supervisor of a coverage task recorded by p_actor: another current leader or
-- deputy of the department whom the app can reach (a leader first, then by member id); null when
-- nobody else holds the scope (the recorder then supervises, a recorded fallback).
create function app.duties_coverage_supervisor(p_department_id uuid, p_actor uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select g.member_id
    from app.identity_grants g
   where g.scope_id = p_department_id and g.revoked_at is null
     and g.scope_kind in ('department_leader', 'department_deputy')
     and g.member_id is distinct from p_actor
     and app.duties_member_active(g.member_id)
     and app.duties_leader_reachable(g.member_id)
   order by (g.scope_kind = 'department_deputy'), g.member_id
   limit 1;
$$;

-- A single token from a fixed vocabulary (required).
create function app.duties_code(p_payload jsonb, p_key text, p_kind text, inout errors jsonb, out value text)
language plpgsql
set search_path = ''
as $$
begin
  if jsonb_typeof(p_payload -> p_key) is distinct from 'string' then
    errors := errors || jsonb_build_object(p_key,
                case when coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null'
                     then 'required' else 'invalid' end);
  elsif not app.duties_state_ok(p_kind, p_payload ->> p_key) then
    errors := errors || jsonb_build_object(p_key, 'invalid');
  else
    value := p_payload ->> p_key;
  end if;
end;
$$;

-- Review N1: the lazy close. Open coverage cases of the department whose duty has started close
-- (`started`) with their tasks at a leader's next coverage command there (a case is about getting
-- an answer or cover before the duty; after it, completion is entry 10). Cases locked by another
-- command are left for the next touch (skip locked: no lock waits). Their reminders already
-- stopped (the owner is reminded only before the duty; review N1 schedule).
create function app.duties_close_started_cases(p_department_id uuid, p_actor_member uuid,
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
   where c.department_id = p_department_id and c.closed_at is null
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

-- duties.record_contact_attempt {assignment_id, channel, outcome, note?, next_follow_up_at};
-- expected = the assignment revision (an attempt does not change it). The department's leader
-- or deputy, on a current pending or declined assignment of a published duty that has not
-- started. The first attempt opens the coverage case and its Follow-ups task (owner and
-- supervisor: the recording leader; scope: their department scope; due: the next follow-up);
-- later attempts on the open case set the task Waiting with the next follow-up as the review date
-- and the outcome. With the Q2/Q4 policy unavailable for Follow-ups the attempt is still
-- recorded and the skipped step audited. Answer: ids, codes and states only (no note).
create function app.duties_record_contact_attempt(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select l.* into v_lock from app.duties_lock_for_leader(v_actor.member_id, v_assignment_id,
                                                          p_expected_revision) l;
  if (v_lock.assignment).response = 'accepted' then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "confirmed"}');
  end if;
  -- Review N9: an erased or departed assignee is reassigned, not contacted.
  if (v_lock.assignment).member_id = '00000000-0000-0000-0000-000000000000'::uuid
     or not app.duties_can_serve((v_lock.assignment).member_id, (v_lock.occurrence).department_id) then
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
       or not (app.identity_member_has_scope(v_task_row.owner_member_id, 'department_leader',
                                             (v_lock.occurrence).department_id)
               or app.identity_member_has_scope(v_task_row.owner_member_id, 'department_deputy',
                                                (v_lock.occurrence).department_id)) then
      update app.duties_coverage_cases c set closed_at = now(), close_code = 'replaced'
       where c.case_id = v_case.case_id;
      v_old_case := v_case.case_id;
      v_case := null;
    end if;
  end if;
  if v_case.case_id is null then
    insert into app.duties_coverage_cases (assignment_id, department_id, opened_by_member,
                                           opened_by_account)
    values (v_assignment_id, (v_lock.occurrence).department_id, v_actor.member_id, v_actor.account_id)
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
  perform app.duties_close_started_cases((v_lock.occurrence).department_id, v_actor.member_id,
                                         v_actor.account_id, v_lock.capacity, v_cmd);
  v_supervisor := app.duties_coverage_supervisor((v_lock.occurrence).department_id, v_actor.member_id);
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
                           when app.identity_member_has_scope(v_supervisor, 'department_leader',
                                                              (v_lock.occurrence).department_id)
                             then 'department_leader' else 'department_deputy' end,
        'scope_id', (v_lock.occurrence).department_id,
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

-- duties.confirm_by_leader {assignment_id, channel, reason}; expected = the assignment revision.
-- The department's leader or deputy records Confirmed by leader on a current pending assignment
-- (a member who confirmed by phone or in person, also one without a login): accepted, provenance
-- `leader`, the leader as the response actor, the time, the channel and the required reason
-- (1-200). Kept distinct from the member's own acceptance everywhere; the member cannot withdraw
-- it (4.5). The coverage case and task close (`confirmed`, Follow-ups resolved), then the
-- response reminders and the leaders' alerts stop and the pre-service reminders are planned
-- (skipped and audited when the Q2 policy is unavailable: the confirmation is always recorded).
create function app.duties_confirm_by_leader(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select l.* into v_lock from app.duties_lock_for_leader(v_actor.member_id, v_assignment_id,
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
  -- Follow-ups before Notifications.
  perform app.duties_close_started_cases((v_lock.occurrence).department_id, v_actor.member_id,
                                         v_actor.account_id, v_lock.capacity, v_cmd);
  perform app.duties_close_cases(array[v_assignment_id], 'confirmed', v_actor.member_id,
                                 v_actor.account_id, v_lock.capacity, v_cmd);
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

-- duties.cancel_position {slot_id}; expected = the occurrence revision. The department's leader or
-- deputy, or an Admin (not Pastor). A position of a published duty that has not started: when it
-- is the last remaining position the whole occurrence is cancelled (as cancel_occurrence does,
-- one-off duties included); otherwise the position is cancelled: its current assignment ends
-- `cancelled` (answer kept), a `cancelled` slot revision is recorded, the assignee who was
-- waiting or had accepted gets the `duty_cancelled` notice, every pending job of the position's
-- assignments ends, and its coverage case closes. Answer: ids, revisions and counts only.
create function app.duties_cancel_position(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_slot_id uuid;
  v_occurrence uuid;
  v_lock record;
  v_occ app.duties_occurrences;
  v_slot app.duties_slots;
  v_left integer;
  v_result jsonb;
  v_notified jsonb;
  v_revision bigint;
  v_slot_revision bigint;
  v_end_revision bigint;
  v_old app.duties_assignments;
  v_ops jsonb := '[]'::jsonb;
  v_id uuid;
  v_cmd constant text := 'duties.cancel_position';
  v_request uuid;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['slot_id']);
  select t.errors, t.value into v_errors, v_slot_id from app.duties_uuid(p_payload, 'slot_id', v_errors) t;
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
  if v_occ.occurrence_state <> 'published' then
    -- A draft date's positions are planned on the Rota page (cancel the date there).
    perform app.cmd_fail('validation_failed', '{"slot_id": "draft"}');
  end if;
  perform 1 from app.duties_slots s where s.occurrence_id = v_occurrence order by s.position_no for update;
  select s.* into v_slot from app.duties_slots s where s.slot_id = v_slot_id;
  if v_slot.cancelled_at is not null then
    perform app.cmd_fail('validation_failed', '{"slot_id": "cancelled"}');
  end if;
  select count(*) into v_left from app.duties_slots s
   where s.occurrence_id = v_occurrence and s.cancelled_at is null;
  if v_left <= 1 then
    -- The last position: the whole duty is cancelled (one-off duties included).
    v_result := app.duties_cancel_one(v_occ, v_actor.member_id, v_actor.account_id, v_lock.capacity, v_cmd);
    v_notified := app.duties_notify(v_result -> 'ops');
    select o.revision into v_revision from app.duties_occurrences o where o.occurrence_id = v_occurrence;
    return jsonb_build_object(
      'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', v_revision,
      'data', jsonb_build_object('occurrence_id', v_occurrence, 'revision', v_revision,
                                 'slot_id', v_slot_id, 'cancelled', 'occurrence',
                                 'assignments_cancelled', (v_result ->> 'assignments_cancelled')::integer,
                                 'notices_queued', (v_notified ->> 'queued')::integer));
  end if;
  v_request := app.cmd_current_request_id(v_actor.account_id, v_cmd);
  -- Review S1: the actor for app.duties_notify.
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', v_actor.member_id, 'account', v_actor.account_id, 'capacity', v_lock.capacity,
    'command', v_cmd)::text, true);
  update app.duties_occurrences o set revision = o.revision + 1
   where o.occurrence_id = v_occurrence returning o.revision into v_revision;
  update app.duties_slots s
     set cancelled_at = now(), cancelled_by_member = v_actor.member_id,
         cancelled_by_account = v_actor.account_id, revision = s.revision + 1
   where s.slot_id = v_slot_id
  returning s.revision into v_slot_revision;
  select a.* into v_old from app.duties_assignments a
   where a.slot_id = v_slot_id and a.assignment_state = 'current' for update;
  if v_old.assignment_id is not null then
    update app.duties_assignments a
       set assignment_state = 'cancelled', ended_at = now(), end_reason = 'cancelled',
           revision = a.revision + 1
     where a.assignment_id = v_old.assignment_id
    returning a.revision into v_end_revision;
    if v_old.response in ('pending', 'accepted') and app.duties_notice_recipient(v_old.member_id) then
      v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
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
  values (v_slot_id, v_slot_revision, v_occurrence, v_revision, 'cancelled', '{}',
          v_occ.duty_name, v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at, v_occ.location,
          v_occ.instructions, v_occ.topic, v_occ.scripture, v_occ.event_ref, null, null, null,
          v_actor.member_id, v_actor.account_id, v_request);
  perform app.duties_audit_series_event('position_cancelled', v_actor.member_id, v_actor.account_id,
                                        v_lock.capacity, v_cmd, v_occ.department_id, v_occ.series_id,
                                        v_occurrence, v_old.assignment_id, v_old.member_id, null,
                                        v_revision);
  -- Every pending job of the position's assignments (current, superseded) ends with it.
  for v_id in select a.assignment_id from app.duties_assignments a where a.slot_id = v_slot_id
               order by a.assignment_id loop
    v_ops := jsonb_build_array(jsonb_build_object('op', 'cancel', 'source_id', v_id,
                                                  'reason', 'source_cancelled')) || v_ops;
  end loop;
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', v_revision,
    'data', jsonb_build_object('occurrence_id', v_occurrence, 'revision', v_revision,
                               'slot_id', v_slot_id, 'cancelled', 'position',
                               'assignments_cancelled', case when v_old.assignment_id is null then 0 else 1 end,
                               'notices_queued', (v_notified ->> 'queued')::integer));
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Command entry point and authorizer (replaced: the three coverage commands)
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
       'duties.record_contact_attempt', 'duties.confirm_by_leader', 'duties.cancel_position') then
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
  'Stories 4.1-4.9: departments, publishing and revising duties, the assignee''s answer '
  '(respond, withdraw_acceptance, accept_many), rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series), reminders (set_reminders) '
  'and coverage (record_contact_attempt, confirm_by_leader, cancel_position) through the 1.4 '
  'envelope.';


-- ---------------------------------------------------------------------------------------------
-- Projections (replaced; story 4.9 adds the response provenance, Confirmed by leader and
-- cancelled positions)
-- ---------------------------------------------------------------------------------------------

-- One assignment as its member sees it (4.8, plus response_provenance and the confirmation
-- channel: "Confirmed by your leader"; never the leader's reason).

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


-- The leader board's occurrence (4.8, plus `cancelled` per position, the current answer's
-- response_provenance and, for a leader confirmation, `confirmation` {by, at, channel, reason};
-- the reason only with notes, i.e. for the department's managers).

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
    'reminders', o.reminders,
    'state', o.occurrence_state,
    'revision', o.revision,
    'published_at', app.cmd_utc(o.published_at),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               -- Story 4.9: a cancelled position (no longer required).
               'cancelled', s.cancelled_at is not null,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_provenance', a.response_provenance,
                          'confirmation', case when a.response_provenance = 'leader' then jsonb_build_object(
                                            'by', app.duties_display_name(a.responded_by_member),
                                            'at', app.cmd_utc(a.responded_at),
                                            'channel', a.confirmed_channel,
                                            -- Review B1: the department's leaders and
                                            -- deputies only (never the Admin role alone).
                                            'reason', case when p_with_notes
                                                            and app.duties_manage_capacity(
                                                                  nullif(pg_catalog.current_setting('app.duties_viewer', true), '')::uuid,
                                                                  o.department_id)
                                                                in ('department_leader', 'department_deputy')
                                                           then a.confirmed_reason end) end,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'deadline_source', a.deadline_source,
                          'short_notice', a.short_notice,
                          'needs_contact', app.duties_needs_contact(a, o),
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


-- The rota's occurrence (4.8, plus `cancelled` per position, cancelled positions left out of
-- `required`, and the current answer's response_provenance).

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
    'reminders', o.reminders,
    'started', app.duties_occurrence_start(o) <= now(),
    -- Story 4.9: a cancelled position is no longer required.
    'required', (select count(*) from app.duties_slots s
                  where s.occurrence_id = o.occurrence_id and s.cancelled_at is null),
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
               'cancelled', s.cancelled_at is not null,
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
                          'response_provenance', a.response_provenance,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'deadline_source', a.deadline_source,
                          'short_notice', a.short_notice,
                          'needs_contact', app.duties_needs_contact(a, o),
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
-- The coverage queue (story 4.9)
-- ---------------------------------------------------------------------------------------------

-- `api.duties_coverage(from_date, to_date, department_id, duty)`: see the header. Set-based: one
-- query for the positions (with the open case and its latest attempt by index), the overlap
-- counts once for the window, the contact routes once per fully visible department. Errors:
-- 403 not_granted (no department scope, Admin or Pastor; or a department filter the caller may
-- not see), 403 unavailable (Q4 gate), 400 validation_failed (window or duty filter).
create function app.duties_coverage(p_from date, p_to date, p_department_id uuid, p_duty text)
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
          case when a.assignment_id is not null then app.duties_needs_contact(a, o) end as needs_contact) x
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
                       'overdue_follow_ups', count(*) filter (where r.follow_up_overdue))
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

create function api.duties_coverage(from_date date default null, to_date date default null,
                                    department_id uuid default null, duty text default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_coverage($1, $2, $3, $4);
$$;

comment on function api.duties_coverage(date, date, uuid, text) is
  'Story 4.9: the coverage queue: positions of published duties in a window of church dates '
  '(default the next seven days) with their state, Needs contact, follow-up and counts; full '
  'view (contact routes, notes) for the department''s leaders and deputies, operational view '
  'for Admin and Pastor.';


-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced: confirmation reasons, contact attempts, coverage cases and cancelled
-- positions; no new row deletions)
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
            where t.recorded_by_member = p_member_id or t.recorded_by_account = p_account_id))::integer;
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
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1-4.9): erase or check the member''s Duties personal data.';


-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_contact_attempt_guard(),
  app.identity_scoped_contact_routes(uuid, text, uuid, uuid[]),
  app.followups_source_review(jsonb),
  app.duties_coverage_case_source_check(jsonb),
  app.duties_coverage_case_context(jsonb),
  app.duties_decline_alert_check(jsonb),
  app.duties_close_cases(uuid[], text, uuid, uuid, text, text),
  app.duties_coverage_supervisor(uuid, uuid),
  app.duties_close_started_cases(uuid, uuid, uuid, text, text),
  app.duties_lock_for_leader(uuid, uuid, bigint),
  app.duties_code(jsonb, text, text, jsonb),
  app.duties_record_contact_attempt(uuid, bigint, jsonb),
  app.duties_confirm_by_leader(uuid, bigint, jsonb),
  app.duties_cancel_position(uuid, bigint, jsonb),
  app.duties_coverage(date, date, uuid, text),
  api.duties_coverage(date, date, uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function app.duties_coverage(date, date, uuid, text) to authenticated;
grant execute on function api.duties_coverage(date, date, uuid, text) to authenticated;

notify pgrst, 'reload schema';
