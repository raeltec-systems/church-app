-- Set response deadlines and schedule creator-configured duty reminders (story 4.8; AD-2, AD-6,
-- AD-8, AD-9). A forward migration on the Duties owner (20261013220239, 20261014001142,
-- 20261014023442, 20261014052239 and 20261014081513 are not edited). Owner decisions Q2
-- (owner-decisions-milestone-2.md): Africa/Lusaka, per-duty deadlines with lead-time defaults,
-- creator-configured reminders, member snooze, no quiet hours. It adds:
--
--   * Deadlines. `response_deadline` (publish_duty, assign_slot, revise_duty) and
--     `deadline_before` (publish_drafts, revise_series) become optional: without one, every new
--     assignment takes the shared 3.3 lead-time default (app.notifications_response_deadline,
--     assigned now, anchored on the reporting time or start). A default that has already passed
--     is Short notice: the deadline is the moment of assignment and app.duties_assignments
--     records `short_notice`. `deadline_source` says whose deadline it is (`creator`,
--     `default`). Stored deadlines are always passed to Notifications explicitly, so a later
--     policy re-plan never moves them. A creator's deadline keeps the 4.1-4.3 checks.
--   * Reminders configured by the creator: `reminders` on publish_duty and create_series (the
--     series value is copied to every generated date; null = the defaults) and the new command
--     duties.set_reminders for one date or a series from a date onwards. Specs are 3.3
--     `response` specs ({anchor: response_deadline|starts_at, before|after}). Defaults
--     (app.duties_default_reminders): the policy's response defaults (24 hours before and at the
--     deadline) and one pre-service reminder 24 hours before the reporting time or start.
--   * Scheduling (app.duties_plan_reminders, Notifications last): the assignee's schedule on
--     `duties_assignment` (kinds duty_response_due, duty_starting; on Short notice the new-duty or
--     change notice is the member's single "respond now" item) and, while the answer is pending,
--     one schedule per current department leader and deputy on the new source `duties_coverage`
--     (duty_response_overdue at the deadline, duty_short_notice now on Short notice). An
--     unanswered assignment re-planned after its deadline gives each leader who has no alert yet
--     one now. An acceptance stops the response reminders and the leaders' alerts and keeps the
--     pre-service reminders; a decline, a change (supersession) and a cancellation stop
--     everything. Every new assignment is a new source id (A -> B -> A included), so no returning
--     recipient collides with a cancelled logical key.
--   * Direct contact (3.5): app.duties_record_contact_need is the direct-contact route of every
--     member kind of `duties_assignment`, so a held or accountless assignee's notices and
--     reminders become needs on app.duties_contact_needs (idempotent on the need id; keyed to
--     the assignment, no member id, no reason). The leader board and the rota show
--     `needs_contact` ({reasons: short_notice | not_reached, since}) on a current assignment.
--   * Projections: deadline_source, short_notice and the occurrence's reminders in My duties, the
--     leader board and the rota.
--
-- Replaced bodies (each keeps every earlier review fix; changes are marked "Story 4.8"):
-- duties_state_ok, duties_assignment_history_guard, duties_notify, duties_apply_change,
-- duties_publish_duty, duties_publish_drafts, duties_revise_duty, duties_respond,
-- duties_withdraw_acceptance, duties_accept_many, duties_authorize_command, duties_command,
-- duties_my_assignment_json, duties_occurrence_json (3 arguments), duties_rota_occurrence_json.
--
-- Lock order (AD-2), as in 4.3-4.5: the actor's grant rows FOR SHARE (authorizer) -> command
-- receipt -> department FOR SHARE -> series FOR UPDATE -> occurrences (series date order) ->
-- member advisory locks and department membership FOR SHARE -> slots FOR UPDATE -> assignments
-- FOR UPDATE -> Notifications (cancel, enqueue, set_schedule), always last.
--
-- No destructive statements, no row deletions (no _rows file). No new client grant: both new
-- commands go through api.duties_command. ASCII only.


-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened: deadline_source; audit action reminders_set)
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
    when 'deadline_source' then p_value in ('creator', 'default')
    when 'series_every' then p_value in ('day', 'week', 'month')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn', 'reminders_set')
    else false end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Whose deadline an assignment has, and whether it was given at Short notice. Every assignment
-- made before 4.8 had the leader's deadline.
alter table app.duties_assignments
  add column deadline_source text not null default 'creator'
    check (app.duties_state_ok('deadline_source', deadline_source)),
  add column short_notice boolean not null default false,
  add constraint duties_assignments_short_notice
    check (not short_notice or deadline_source = 'default');

comment on column app.duties_assignments.deadline_source is
  'Story 4.8: `creator` (the leader set the answer-by) or `default` (the 3.3 lead-time default).';
comment on column app.duties_assignments.short_notice is
  'Story 4.8: the default deadline had already passed when the assignment was made: the member '
  'is asked to answer now and the leaders are alerted to contact them directly.';

-- The creator's member reminders (3.3 `response` specs); null = the defaults, [] = none.
alter table app.duties_occurrences
  add column reminders jsonb check (reminders is null or jsonb_typeof(reminders) = 'array');
alter table app.duties_series
  add column reminders jsonb check (reminders is null or jsonb_typeof(reminders) = 'array');

comment on column app.duties_occurrences.reminders is
  'Story 4.8: the member reminders the creator chose for this date (null: the defaults; []: none).';
comment on column app.duties_series.reminders is
  'Story 4.8: the member reminders the creator chose for the series, copied to its dates.';

-- The leader's Needs contact list: one row per direct-contact need Notifications routed to
-- Duties (3.5). Keyed to the assignment (its member is the recipient), never a reason or a
-- contact route; idempotent on the need id because the worker may retry.
create table app.duties_contact_needs (
  need_id uuid primary key,
  assignment_id uuid not null references app.duties_assignments (assignment_id) on delete cascade,
  source_revision bigint not null check (source_revision >= 1),
  reminder_kind text not null check (reminder_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  scheduled_at timestamptz not null,
  recorded_at timestamptz not null default clock_timestamp()
);

create index duties_contact_needs_assignment
  on app.duties_contact_needs (assignment_id, source_revision);

comment on table app.duties_contact_needs is
  'owner: duties. Story 4.8: reminders and notices that could not reach the assignee in the app '
  '(held, in review, accountless or deactivated), for the leader''s Needs contact list. Ids, '
  'kinds and times only; the reason is never recorded.';

alter table app.duties_contact_needs enable row level security;
revoke all on table app.duties_contact_needs from public, anon, authenticated, service_role;

-- Ended assignments are immutable (replaced: deadline_source and short_notice too; erasure may
-- only clear the note and the override reason and anonymise people).

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
      new.short_notice)
     is distinct from
     (old.assignment_id, old.slot_id, old.assignment_state, old.response, old.response_deadline,
      old.responded_at, old.response_provenance, old.revision, old.assigned_at,
      old.slot_revision, old.supersedes_assignment_id, old.ended_at, old.end_reason,
      old.override_overlaps, old.override_at, old.prior_accepted_at, old.deadline_source,
      old.short_notice)
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
-- Reminder kinds and sources (3.2 contracts), the leaders' source and the direct-contact route
-- ---------------------------------------------------------------------------------------------

-- The leaders' alert source `duties_coverage` (source id = the assignment id, revision = the
-- assignment's revision): current while the assignment is current at that revision and its
-- occurrence is published.
create function app.duties_coverage_source_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row record;
begin
  select a.revision, a.assignment_state, o.occurrence_state into v_row
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id::text = p_source ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_row.assignment_state = 'current' and v_row.occurrence_state = 'published'
               and v_row.revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision);
end;
$$;

-- duty_response_overdue and duty_short_notice: actionable while the answer is still pending and
-- the duty has not started; the recipient must still lead or deputise the duty's department
-- (and is never the assignee).
create function app.duties_coverage_reminder_check(p_key jsonb)
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
    'recipient_eligible', v_occurrence.department_id is not null
                          and v_assignment.member_id::text is distinct from p_key ->> 'recipient_member_id'
                          and (app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                             'department_leader', v_occurrence.department_id)
                               or app.identity_member_has_scope((p_key ->> 'recipient_member_id')::uuid,
                                                                'department_deputy', v_occurrence.department_id)));
end;
$$;

-- The direct-contact route of the assignee's kinds (3.5): the need goes on the leader's Needs
-- contact list. Idempotent on the need id; no lock on the assignment (the worker holds the job,
-- and commands lock the assignment before calling Notifications).
create function app.duties_record_contact_need(p_need jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_need ->> 'source_type' is distinct from 'duties_assignment' then
    return;
  end if;
  insert into app.duties_contact_needs (need_id, assignment_id, source_revision, reminder_kind,
                                        scheduled_at)
  select (p_need ->> 'need_id')::uuid, a.assignment_id, (p_need ->> 'source_revision')::numeric::bigint,
         p_need ->> 'reminder_kind', (p_need ->> 'scheduled_at')::timestamptz
    from app.duties_assignments a
   where a.assignment_id = (p_need ->> 'source_id')::uuid
  on conflict (need_id) do nothing;
end;
$$;

-- The assignee's reminders on `duties_assignment`.
select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_response_due');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_response_due',
  'app.duties_assignment_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty answer needed",
    "body": "One of your duties is waiting for your answer. Open it to accept or say you cannot make it.",
    "link": "/duties/assignments/{source_id}"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_starting');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_starting',
  'app.duties_update_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty coming up",
    "body": "One of your duties is coming up soon. Open it to see the details.",
    "link": "/duties/assignments/{source_id}"}'::jsonb);

-- The leaders' alerts on `duties_coverage`.
select app.contract_register_source_type(
  'duties', 'duties_coverage', 'app.duties_coverage_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('duties', 'duties_coverage', 'duty_response_overdue');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'duty_response_overdue',
  'app.duties_coverage_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty answer overdue",
    "body": "A duty in your department passed its answer-by time without an answer. Open Duties to follow it up.",
    "link": "/duties/leader"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_coverage', 'duty_short_notice');
select app.contract_register_reminder_contract(
  'duties', 'duties_coverage', 'duty_short_notice',
  'app.duties_coverage_reminder_check(jsonb)'::regprocedure,
  '{"title": "Short-notice duty",
    "body": "A duty in your department was given at short notice and needs an answer now. Contact the member directly.",
    "link": "/duties/leader"}'::jsonb);

-- Every kind an assignee may be sent routes a held or accountless assignee to Needs contact.
select app.contract_register_direct_contact_route('duties', 'duties_assignment', k,
                                                  'app.duties_record_contact_need(jsonb)'::regprocedure)
  from unnest(array['duty_assigned', 'duty_changed', 'duty_updated', 'duty_released',
                    'duty_cancelled', 'duty_response_due', 'duty_starting']) k;

-- ---------------------------------------------------------------------------------------------
-- Deadlines and reminder plans
-- ---------------------------------------------------------------------------------------------

-- The creator's `reminders` field: absent or null = the defaults (value null); otherwise 3.3
-- `response` specs within the Q2 policy's limits (`invalid` | `out_of_range`).
create function app.duties_reminders_field(p_payload jsonb, inout errors jsonb, out value jsonb)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> 'reminders';
  v_policy jsonb;
  v_error text;
begin
  if coalesce(jsonb_typeof(v), 'null') = 'null' then
    return;
  end if;
  v_policy := app.notifications_policy();
  v_error := app.notifications_reminders_error(
    v, 'response', (v_policy -> 'value' ->> 'max_reminders')::integer,
    v_policy -> 'value' ->> 'max_offset');
  if v_error is not null then
    errors := errors || jsonb_build_object('reminders', v_error);
    return;
  end if;
  value := v;
end;
$$;

-- The member reminders when the creator chose none: the policy's response defaults (24 hours
-- before and at the deadline in the Q2 fixture) and one pre-service reminder 24 hours before the
-- reporting time or start (an adjustable assumption kept in this one function), unless the
-- policy's defaults already have a start reminder.
create function app.duties_default_reminders(p_policy jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(p_policy -> 'value' -> 'default_reminders' -> 'response', '[]'::jsonb)
         || case when exists (
                   select 1 from jsonb_array_elements(
                            coalesce(p_policy -> 'value' -> 'default_reminders' -> 'response', '[]'::jsonb)) e
                    where e ->> 'anchor' = 'starts_at')
                 then '[]'::jsonb
                 else '[{"anchor": "starts_at", "before": "24 hours"}]'::jsonb end;
$$;

-- The specs to plan: the stored ones (null: the defaults) without any spec the current policy
-- no longer allows (an offset over max_offset, beyond max_reminders), so a narrower policy never
-- makes a command fail.
create function app.duties_reminder_specs(p_policy jsonb, p_stored jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_spec jsonb;
  v_out jsonb := '[]'::jsonb;
  v_max integer := (p_policy -> 'value' ->> 'max_reminders')::integer;
begin
  for v_spec in select e from jsonb_array_elements(
                  case when p_stored is null then app.duties_default_reminders(p_policy)
                       else p_stored end) e loop
    exit when jsonb_array_length(v_out) >= v_max;
    continue when app.notifications_reminders_error(jsonb_build_array(v_spec), 'response', 1,
                                                    p_policy -> 'value' ->> 'max_offset') is not null;
    v_out := v_out || jsonb_build_array(v_spec);
  end loop;
  return v_out;
end;
$$;

-- The 3.3 lead-time default deadline of an assignment made now for a duty starting (or
-- reporting) at p_start: {response_deadline, short_notice}. Short notice (the default has already
-- passed) gives the moment of assignment; a policy whose bands give nothing fails closed as
-- Short notice. Requires the Q2 policy (unavailable otherwise).
create function app.duties_default_deadline(p_start timestamptz)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := app.notifications_response_deadline(app.notifications_policy(), now(), p_start, null,
                                                 now());
begin
  return jsonb_build_object('response_deadline', v -> 'response_deadline',
                            'short_notice', coalesce((v ->> 'short_notice')::boolean, true));
end;
$$;

-- Who gets the leaders' alerts: the department's current leaders and deputies (live members),
-- never the assignee.
create function app.duties_alert_recipients(p_department_id uuid, p_exclude uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(x.member_id order by x.member_id), '{}')
    from (select distinct g.member_id
            from app.identity_grants g
           where g.scope_id = p_department_id and g.revoked_at is null
             and g.scope_kind in ('department_leader', 'department_deputy')
             and g.member_id is distinct from p_exclude
             and app.duties_member_active(g.member_id)) x;
$$;

-- Needs contact (the leader board and the rota): for a current assignment of a published duty
-- that has not started, {reasons: [short_notice, not_reached], since} or null. `short_notice`
-- while a Short-notice answer is pending; `not_reached` while a direct-contact need of the
-- assignment's current revision is still relevant (a response reminder or new-duty/change
-- notice while pending; a pre-service reminder or details update while not declined). Never why
-- the member was not reached.
create function app.duties_needs_contact(p_assignment app.duties_assignments,
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
                          and p_assignment.response <> 'declined'))) n
       where p_assignment.assignment_state = 'current'
         and p_occurrence.occurrence_state = 'published'
         and app.duties_occurrence_start(p_occurrence) > now()) x;
$$;

-- Plans an assignment's reminders (Notifications last: callers run it after every Duties row is
-- written, through app.duties_notify's `plan` op or after an answer). Nothing for an assignment
-- that is not current, a duty that is not published, has started or is cell-owned (entry 11).
--   * The assignee (not an erased member, not declined): one 3.3 `response` schedule on
--     `duties_assignment` with the stored deadline, `responded` once answered, the creator's
--     specs or the defaults; p_fresh for a new assignment (a Short-notice plan then asks for an
--     answer now with p_notice, the notice this command queued, so the member gets one item).
--   * While the answer is pending, each current leader and deputy: a schedule on
--     `duties_coverage` with one alert at the deadline (duty_response_overdue), or now on Short
--     notice (duty_short_notice). Leaders no longer in the list lose theirs (`not_recipient`).
--     When the deadline has passed and a leader has no alert at this revision yet (a re-plan
--     after the deadline), one alert is queued now: a passed deadline never silently drops it.
-- Returns counts.
create function app.duties_plan_reminders(p_assignment_id uuid, p_fresh boolean, p_notice text)
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
      'kinds', jsonb_build_object('response_deadline', 'duty_response_due',
                                  'starts_at', 'duty_starting',
                                  'respond_now', coalesce(p_notice, 'duty_response_due')),
      'fresh', p_fresh));
  end if;

  if v_a.response = 'pending' then
    v_leaders := app.duties_alert_recipients(v_o.department_id, v_a.member_id);
  end if;
  for v_leader in select s.recipient_member_id from app.notifications_schedules s
                   where s.source_type = 'duties_coverage' and s.source_id = v_a.assignment_id
                     and s.schedule_state = 'active'
                     and not (s.recipient_member_id = any (v_leaders))
                   order by s.recipient_member_id loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient'));
  end loop;
  foreach v_leader in array v_leaders loop
    perform app.notifications_set_schedule(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_leader,
      'schedule_type', 'response',
      'intent', v_intent || jsonb_build_object(
                  'reminders', '[{"anchor": "response_deadline", "before": "0 minutes"}]'::jsonb),
      'kinds', '{"response_deadline": "duty_response_overdue", "respond_now": "duty_short_notice"}'::jsonb,
      'fresh', p_fresh));
    v_alerts := v_alerts + 1;
    if v_a.response_deadline <= now()
       and not exists (select 1 from app.notifications_jobs j
                        where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                          and j.recipient_member_id = v_leader
                          and j.source_revision = v_a.revision
                          and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice')
                          and j.job_state <> 'cancelled') then
      v_job := app.notifications_enqueue(jsonb_build_object(
        'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
        'source_revision', v_a.revision, 'recipient_member_id', v_leader,
        'reminder_kind', 'duty_response_overdue', 'scheduled_at', app.cmd_utc(now())));
      if coalesce((v_job ->> 'created')::boolean, false) then
        v_late := v_late + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('planned', true,
                            'member_entries', coalesce((v_member ->> 'entries')::integer, 0),
                            'leaders', v_alerts, 'late_alerts', v_late);
end;
$$;

-- After the assignee answered (respond, withdraw_acceptance, accept_many; their own cancel of
-- the assignment's jobs has run): the leaders' alerts stop, and an acceptance plans its
-- pre-service reminders again at the new revision (a decline keeps nothing).
create function app.duties_after_answer(p_assignment_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_coverage', 'source_id', p_assignment_id, 'reason', 'responded'));
  if exists (select 1 from app.duties_assignments a
              where a.assignment_id = p_assignment_id and a.assignment_state = 'current'
                and a.response = 'accepted') then
    perform app.duties_plan_reminders(p_assignment_id, false, null);
  end if;
end;
$$;

-- Runs the notification work a Duties change produced, in order, after every Duties row is
-- written (Notifications last, AD-2). Replaced (story 4.8): `cancel` also ends the leaders'
-- alerts of the assignment, and the new op
--   {"op": "plan", "assignment_id", "fresh", "notice"}  app.duties_plan_reminders.

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
begin
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
-- The shared change engine (replaced, same signature; story 4.8): without the leader's answer-by
-- (p_deadline null) each new pending assignment takes the 3.3 lead-time default (Short notice
-- when it has passed) and records deadline_source and short_notice; every new current
-- assignment gets a `plan` op after its notice. Everything else as in 4.4.
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
-- Commands (replaced; story 4.8)
-- ---------------------------------------------------------------------------------------------

-- duties.publish_duty: as in 4.4, plus `reminders` (null = the defaults) and an optional
-- `response_deadline` (without one the 3.3 lead-time default; Short notice when it has passed);
-- the notice and the reminder plan run through app.duties_notify, last.

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
  v_reminders jsonb;
  v_default jsonb;
  v_source text := 'creator';
  v_short boolean := false;
  v_notified jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['department_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'member_id', 'response_deadline',
                      'override_reason', 'reminders']);
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
    from app.duties_instant(p_payload, 'response_deadline', false, v_errors) t;
  -- Story 4.8: the creator's reminders (absent or null: the defaults).
  select t.errors, t.value into v_errors, v_reminders
    from app.duties_reminders_field(p_payload, v_errors) t;
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
    -- A leader's deadline is never in the past or later than the start (story 4.8: without one
    -- the 3.3 lead-time default applies).
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
  if v_deadline is null then
    v_default := app.duties_default_deadline(coalesce(v_reporting, v_starts));
    v_deadline := (v_default ->> 'response_deadline')::timestamptz;
    v_source := 'default';
    v_short := (v_default ->> 'short_notice')::boolean;
  end if;
  insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, reporting_at,
                                      location, instructions, created_by_member,
                                      created_by_account, reminders)
  values (v_department_id, v_name, v_starts, v_ends, v_reporting, v_location, v_instructions,
          v_actor.member_id, v_actor.account_id, v_reminders)
  returning occurrence_id into v_occurrence;
  insert into app.duties_slots (occurrence_id, position_no) values (v_occurrence, 1)
  returning slot_id into v_slot;
  insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                      assigned_by_account, deadline_source, short_notice)
  values (v_slot, v_member, v_deadline, v_actor.member_id, v_actor.account_id, v_source, v_short)
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
  -- Story 4.8: the new-duty notice, then the reminders and the leaders' alert (on Short notice
  -- the notice is the member's "respond now").
  v_notified := app.duties_notify(jsonb_build_array(
    jsonb_build_object('op', 'enqueue', 'counts', true, 'key', jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
      'recipient_member_id', v_member, 'reminder_kind', 'duty_assigned',
      'scheduled_at', app.cmd_utc(now()))),
    jsonb_build_object('op', 'plan', 'assignment_id', v_assignment, 'fresh', true,
                       'notice', 'duty_assigned')));
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', 1,
    -- Ids, states and counts only (no names or text in the receipt); clients read the board again.
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence, 'department_id', v_department_id, 'revision', 1,
              'slot_id', v_slot, 'assignment_id', v_assignment, 'assignment_revision', 1,
              'response', 'pending',
              'notice_queued', (v_notified ->> 'queued')::integer > 0,
              'override_recorded', v_overlaps > 0));
end;
$$;


-- duties.publish_drafts: as in 4.4, with `deadline_before` optional: without it each date's
-- assignments take that date's 3.3 lead-time default (Short notice when it has passed; with it
-- a passed answer-by is still refused, naming the date); each new assignment is planned.

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
  v_default jsonb;
  v_source text;
  v_short boolean;
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
    from app.duties_lead(p_payload, 'deadline_before', false, v_errors) t;
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
    if v_lead is not null
       and app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone) <= now() then
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
    -- Story 4.8: the leader's lead time, or the 3.3 lead-time default of each date (Short notice
    -- when that has already passed).
    if v_lead is not null then
      v_deadline := app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone);
      v_source := 'creator';
      v_short := false;
    else
      v_default := app.duties_default_deadline(app.duties_occurrence_start(v_occ));
      v_deadline := (v_default ->> 'response_deadline')::timestamptz;
      v_source := 'default';
      v_short := (v_default ->> 'short_notice')::boolean;
    end if;
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
                                            assigned_by_account, deadline_source, short_notice)
        values (v_slot.slot_id, v_slot.draft_member_id, v_deadline, v_actor.member_id,
                v_actor.account_id, v_source, v_short)
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
            'scheduled_at', app.cmd_utc(now()))),
          jsonb_build_object('op', 'plan', 'assignment_id', v_assignment, 'fresh', true,
                             'notice', 'duty_assigned'));
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


-- duties.revise_duty: as in 4.4; a material change without `response_deadline` takes the 3.3
-- default (the change engine), so a time error is no longer reported with a missing answer-by.

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
    -- As in 4.2: a time change of a published duty is material, so a given answer-by is
    -- reported with the time errors (story 4.8: without one the 3.3 default applies).
    if v_errors <> '{}'::jsonb and v_occ.occurrence_state = 'published' and v_deadline is not null then
      if v_deadline <= now() then
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


-- duties.respond: as in 4.5, then (story 4.8) the leaders' alerts stop and an acceptance keeps
-- its pre-service reminders (app.duties_after_answer).

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
  -- Story 4.8: the leaders' alert stops; an acceptance keeps its pre-service reminders.
  perform app.duties_after_answer(v_assignment.assignment_id);
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    -- Ids and states only (the note stays out of the receipt); clients read My duties again.
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', p_payload ->> 'response'));
end;
$$;


-- duties.withdraw_acceptance: as in 4.5, then the leaders' alerts stop (a decline keeps no
-- reminder).

create or replace function app.duties_withdraw_acceptance(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  -- Story 4.8: the leaders' alert stops; an acceptance keeps its pre-service reminders.
  perform app.duties_after_answer(v_assignment.assignment_id);
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', 'declined', 'withdrawn', true));
end;
$$;


-- duties.accept_many: as in 4.5, then each accepted date keeps its pre-service reminders.

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
  -- Notifications last.
  for v_row in select x ->> 'assignment_id' as id from jsonb_array_elements(v_done) x loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_row.id, 'reason', 'responded'));
    -- Story 4.8: the leaders' alert stops; the pre-service reminders are planned again.
    perform app.duties_after_answer(v_row.id::uuid);
  end loop;
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_first,
    'revision', v_first_revision,
    'data', jsonb_build_object('response', 'accepted', 'count', jsonb_array_length(v_done),
                               'assignments', v_done));
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Commands: reminders chosen by the creator
-- ---------------------------------------------------------------------------------------------

-- duties.set_reminders: the member reminders of one date, {occurrence_id, reminders} with
-- expected = the occurrence revision, or of a series from a date onwards, {series_id,
-- from_occurrence_id, reminders} with expected = the series revision (the series template and
-- every later date that has not started and is not cancelled; earlier and started dates keep
-- theirs). `reminders`: null = the defaults, [] = none, or 3.3 `response` specs. The
-- department's leader or deputy, or an Admin. Nobody is asked again: each current assignment of
-- a changed published date is re-planned at its revision (a pending snooze survives; Short
-- notice is not asked again). Answer: ids, revisions and counts only.
create function app.duties_set_reminders(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_occurrence_id uuid;
  v_series_id uuid;
  v_anchor_id uuid;
  v_reminders jsonb;
  v_lock record;
  v_occ app.duties_occurrences;
  v_anchor app.duties_occurrences;
  v_series app.duties_series;
  v_revision bigint;
  v_ops jsonb := '[]'::jsonb;
  v_changed integer := 0;
  v_replanned integer := 0;
  v_id uuid;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['occurrence_id', 'series_id', 'from_occurrence_id', 'reminders']);
  if p_payload ? 'series_id' then
    select t.errors, t.value into v_errors, v_series_id
      from app.duties_uuid(p_payload, 'series_id', v_errors) t;
    select t.errors, t.value into v_errors, v_anchor_id
      from app.duties_uuid(p_payload, 'from_occurrence_id', v_errors) t;
    if p_payload ? 'occurrence_id' then
      v_errors := v_errors || '{"occurrence_id": "invalid"}';
    end if;
  else
    select t.errors, t.value into v_errors, v_occurrence_id
      from app.duties_uuid(p_payload, 'occurrence_id', v_errors) t;
    if p_payload ? 'from_occurrence_id' then
      v_errors := v_errors || '{"from_occurrence_id": "invalid"}';
    end if;
  end if;
  if not p_payload ? 'reminders' then
    v_errors := v_errors || '{"reminders": "required"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select t.errors, t.value into v_errors, v_reminders from app.duties_reminders_field(p_payload, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  if v_series_id is null then
    -- One date (a one-off duty or a date of a series): draft or published, not started, not
    -- cancelled (app.duties_lock_occurrence).
    select l.* into v_lock
      from app.duties_lock_occurrence(v_actor.member_id, v_occurrence_id, p_expected_revision) l;
    v_occ := v_lock.occ;
    if v_occ.reminders is not distinct from v_reminders then
      perform app.cmd_fail('validation_failed', '{"occurrence_id": "unchanged"}');
    end if;
    update app.duties_occurrences o set reminders = v_reminders, revision = o.revision + 1
     where o.occurrence_id = v_occ.occurrence_id
    returning o.revision into v_revision;
    if v_occ.occurrence_state = 'published' then
      for v_id in select a.assignment_id from app.duties_slots s
                    join app.duties_assignments a on a.slot_id = s.slot_id
                   where s.occurrence_id = v_occ.occurrence_id and a.assignment_state = 'current'
                   order by s.position_no
                     for update of a loop
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'plan', 'assignment_id', v_id, 'fresh', false));
        v_replanned := v_replanned + 1;
      end loop;
    end if;
    perform app.duties_audit_series_event('reminders_set', v_actor.member_id, v_actor.account_id,
                                          v_lock.capacity, 'duties.set_reminders',
                                          v_occ.department_id, v_occ.series_id, v_occ.occurrence_id,
                                          null, null, 'occurrence', v_revision);
    -- Notifications last (AD-2).
    perform app.duties_notify(v_ops);
    return jsonb_build_object(
      'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occ.occurrence_id,
      'revision', v_revision,
      'data', jsonb_build_object('occurrence_id', v_occ.occurrence_id, 'revision', v_revision,
                                 'occurrences', 1, 'replanned', v_replanned));
  end if;

  -- A series from a date onwards (the lock order of duties.revise_series).
  select l.* into v_lock from app.duties_lock_series(v_actor.member_id, v_series_id, p_expected_revision) l;
  v_series := v_lock.series;
  select o.* into v_anchor from app.duties_occurrences o
   where o.occurrence_id = v_anchor_id and o.series_id = v_series_id;
  if not found then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "not_in_series"}');
  elsif v_anchor.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "cancelled"}');
  elsif app.duties_occurrence_start(v_anchor) <= now() then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "started"}');
  end if;
  perform 1 from app.duties_occurrences o
   where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
     and o.occurrence_state <> 'cancelled'
   order by o.series_date for update;
  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
                  and o.occurrence_state <> 'cancelled' and app.duties_occurrence_start(o) > now()
                  and o.reminders is distinct from v_reminders
                order by o.series_date loop
    update app.duties_occurrences o set reminders = v_reminders, revision = o.revision + 1
     where o.occurrence_id = v_occ.occurrence_id;
    v_changed := v_changed + 1;
    if v_occ.occurrence_state = 'published' then
      for v_id in select a.assignment_id from app.duties_slots s
                    join app.duties_assignments a on a.slot_id = s.slot_id
                   where s.occurrence_id = v_occ.occurrence_id and a.assignment_state = 'current'
                   order by s.position_no
                     for update of a loop
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'plan', 'assignment_id', v_id, 'fresh', false));
        v_replanned := v_replanned + 1;
      end loop;
    end if;
  end loop;
  if v_changed = 0 and v_series.reminders is not distinct from v_reminders then
    perform app.cmd_fail('validation_failed', '{"series_id": "unchanged"}');
  end if;
  update app.duties_series r set reminders = v_reminders, revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id
  returning r.revision into v_revision;
  perform app.duties_audit_series_event('reminders_set', v_actor.member_id, v_actor.account_id,
                                        v_lock.capacity, 'duties.set_reminders',
                                        v_series.department_id, v_series_id, v_anchor_id, null, null,
                                        'series', v_revision);
  perform app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'from_occurrence_id', v_anchor_id, 'occurrences', v_changed,
                               'replanned', v_replanned));
end;
$$;

-- duties.create_series (story 4.8): as in 4.3, plus `reminders` (null = the defaults): stored
-- on the series and copied to every generated date. The 4.3 command does the rest unchanged.
create function app.duties_create_series_with_reminders(p_actor uuid, p_expected_revision bigint,
                                                        p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_reminders jsonb;
  v_result jsonb;
  v_series uuid;
begin
  if jsonb_typeof(p_payload) = 'object' and p_payload ? 'reminders' then
    select t.errors, t.value into v_errors, v_reminders
      from app.duties_reminders_field(p_payload, v_errors) t;
    if v_errors <> '{}'::jsonb then
      perform app.cmd_fail('validation_failed', v_errors);
    end if;
  end if;
  v_result := app.duties_create_series(p_actor, p_expected_revision,
                                       case when jsonb_typeof(p_payload) = 'object'
                                            then p_payload - 'reminders' else p_payload end);
  if v_reminders is not null then
    v_series := (v_result ->> 'aggregate_id')::uuid;
    update app.duties_series r set reminders = v_reminders where r.series_id = v_series;
    update app.duties_occurrences o set reminders = v_reminders where o.series_id = v_series;
  end if;
  return v_result;
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Command entry point and authorizer (replaced: duties.set_reminders; create_series takes
-- reminders)
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
       'duties.withdraw_acceptance', 'duties.accept_many', 'duties.set_reminders') then
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
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
      and v_command is distinct from 'duties.accept_many'
  );
end;
$$;


-- ---------------------------------------------------------------------------------------------
-- Projections (replaced; story 4.8 adds deadline_source, short_notice, the occurrence's
-- reminders and, for the department's readers, needs_contact)
-- ---------------------------------------------------------------------------------------------

-- One assignment as its member sees it (4.5, plus deadline_source, short_notice and reminders).

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


-- The leader board's occurrence (4.5, plus reminders, deadline_source, short_notice and
-- needs_contact).

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
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
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


-- The rota's occurrence (4.5, plus reminders, deadline_source, short_notice and needs_contact).

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


comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.8: departments, publishing and revising duties, the assignee''s answer '
  '(respond, withdraw_acceptance, accept_many), rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series) and reminders '
  '(set_reminders) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_coverage_source_check(jsonb),
  app.duties_coverage_reminder_check(jsonb),
  app.duties_record_contact_need(jsonb),
  app.duties_reminders_field(jsonb, jsonb),
  app.duties_default_reminders(jsonb),
  app.duties_reminder_specs(jsonb, jsonb),
  app.duties_default_deadline(timestamptz),
  app.duties_alert_recipients(uuid, uuid),
  app.duties_needs_contact(app.duties_assignments, app.duties_occurrences),
  app.duties_plan_reminders(uuid, boolean, text),
  app.duties_after_answer(uuid),
  app.duties_set_reminders(uuid, bigint, jsonb),
  app.duties_create_series_with_reminders(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
