-- Remind follow-up owners and supervisors on the task schedule (story 4.7; AD-2, AD-7, AD-8,
-- AD-9). Forward only: builds on 20261014110258_followups_registry.sql (story 4.6), whose file
-- is not edited; changed functions are replaced here with `create or replace` (same signatures,
-- so their privileges are kept).
--
--   * Two Follow-ups reminder sources (3.2 contracts), both keyed by the task id:
--       followups_task         the owner: `followup_assigned` (on assignment, enqueued now) and
--                              `followup_due` (at the actionable deadline: the due date while
--                              Open / In progress, the review date while Waiting);
--       followups_supervision  the supervisor: `followup_overdue`, once, one day after a missed
--                              deadline while the task is still active.
--     Fixed generic text and the deep link /followups/tasks/{source_id}; never a next action,
--     outcome, close reason, context or private note.
--   * The source revision of both is the task's `schedule_revision`. It moves only when the
--     actionable deadline moves (Waiting <-> not Waiting, a new review date), so notes and
--     outcomes never re-send anything, and a reminder of an old deadline goes out of date.
--   * The 3.3 calculation schedules both (`app.notifications_set_schedule`, schedule type
--     `task`): the owner's deadline reminders are the creator's (`reminders`, stored on the
--     task; null = the church default) and the supervisor's alert is one day after the
--     deadline. Past entries are never enqueued, so a supervisor is told once per deadline.
--   * Reassignment cancels the old owner's pending reminders (`reassigned`) and gives the new
--     owner an assignment notice and the schedule; a supervisor change moves the alert
--     (`supervisor_changed`). Done, Closed and a closing source event cancel everything
--     (`task_done`, `task_closed`, `source_resolved`, `source_cancelled`).
--   * Source-specific schedules (AD-7): a source owner registers, per purpose, its own owner
--     reminders, supervisor alerts and whether an assignment notice is sent
--     (app.followups_register_reminder_schedule). Tasks of that purpose follow it INSTEAD of the
--     generic schedule, and a creator's reminders are refused for them. The SYNTHETIC
--     `fixture_followup/synthetic_report_due` purpose proves the rule (missing cell reports,
--     epic 7, are the first real one).
--   * Owner decision on Q4 (owner scope, 2026-10-14): a task's owner is chosen from the task's
--     own group (the target's roster, as in 4.6) or from the current Pastors. Nobody else.
--     The Pastor role still grants no supervision or visibility of other tasks. The Q4
--     personal-data gate itself is unchanged (production stays inert).
--
-- Tasks opened before this migration get their reminders at their next deadline change,
-- reassignment or state change (no backfill: scheduling needs the Q2 policy, which production
-- does not have). No direct-contact route is registered: a reminder for an owner without a usable
-- login is recorded `unrouted` in Notifications (reminder health), and the supervisor still gets
-- the overdue alert.
--
-- Lock order (AD-2): Identity grants FOR SHARE (authorizer) -> receipt -> task FOR UPDATE ->
-- Notifications (schedules, jobs) last.
--
-- ASCII only; no destructive statements; no row deletions (no _rows file). No client grants.

-- ---------------------------------------------------------------------------------------------
-- Columns and the source-specific schedule registry
-- ---------------------------------------------------------------------------------------------

alter table app.followups_tasks
  add column schedule_revision bigint not null default 1 check (schedule_revision >= 1),
  add column reminders jsonb check (reminders is null or jsonb_typeof(reminders) = 'array');

comment on column app.followups_tasks.schedule_revision is
  'Story 4.7: the source revision of the task''s reminders; moves when the actionable deadline moves.';
comment on column app.followups_tasks.reminders is
  'Story 4.7: the creator''s reminder specs ({anchor: deadline, before|after}); null = the church default.';

create table app.followups_reminder_schedules (
  source_type text not null,
  purpose text not null,
  module text not null,
  owner_reminders jsonb not null check (jsonb_typeof(owner_reminders) = 'array'),
  supervisor_reminders jsonb not null check (jsonb_typeof(supervisor_reminders) = 'array'),
  on_assignment boolean not null,
  registered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (source_type, purpose),
  foreign key (source_type, purpose) references app.followups_purposes (source_type, purpose)
);

comment on table app.followups_reminder_schedules is
  'owner: followups. Source-specific task reminder schedules that replace the generic one (AD-7).';

alter table app.followups_reminder_schedules enable row level security;
revoke all on table app.followups_reminder_schedules from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Reminder specs
-- ---------------------------------------------------------------------------------------------

-- Error code of a task reminder spec list, or null: at most 6 specs {anchor: "deadline",
-- before|after: "<n> minutes|hours|days"}, each at most 90 days (the policy may narrow it).
create function app.followups_reminder_specs_error(p_specs jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select app.notifications_reminders_error(p_specs, 'task', 6, '90 days');
$$;

-- An optional `reminders` field: absent or null = the church default; otherwise a spec list.
create function app.followups_reminders_field(p_payload jsonb, inout errors jsonb, out value jsonb)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
begin
  if coalesce(jsonb_typeof(p_payload -> 'reminders'), 'null') = 'null' then
    return;
  end if;
  v_error := app.followups_reminder_specs_error(p_payload -> 'reminders');
  if v_error is not null then
    errors := errors || jsonb_build_object('reminders', v_error);
    return;
  end if;
  value := p_payload -> 'reminders';
end;
$$;

-- A source owner registers (or replaces) the reminder schedule of one of its purposes, in its
-- own migration. p_config (strict): owner (spec list for the owner's reminders), supervisor
-- (spec list for the supervisor's alerts, may be []), on_assignment (boolean: send the owner an
-- assignment notice). Tasks of the purpose then follow it instead of the generic schedule.
-- Refusals are migration-time programming errors (PCTR1).
create function app.followups_register_reminder_schedule(
  p_module text,
  p_source_type text,
  p_purpose text,
  p_config jsonb
) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if not exists (select 1 from app.followups_purposes p
                  where p.source_type = p_source_type and p.purpose = p_purpose) then
    perform app.contract_registration_fail(
      format('purpose %s of %s is not a Follow-ups purpose', p_purpose, p_source_type));
  end if;
  if jsonb_typeof(p_config) is distinct from 'object'
     or app.contract_unknown_keys(p_config, array['owner', 'supervisor', 'on_assignment']) <> '{}'::jsonb
     or not (p_config ? 'owner') or not (p_config ? 'supervisor') then
    perform app.contract_registration_fail('config needs exactly owner, supervisor and on_assignment');
  end if;
  if app.followups_reminder_specs_error(p_config -> 'owner') is not null
     or app.followups_reminder_specs_error(p_config -> 'supervisor') is not null then
    perform app.contract_registration_fail(
      'owner and supervisor must be lists of at most 6 {anchor: deadline, before|after} specs');
  end if;
  if jsonb_typeof(p_config -> 'on_assignment') is distinct from 'boolean' then
    perform app.contract_registration_fail('on_assignment must be a boolean');
  end if;
  insert into app.followups_reminder_schedules (source_type, purpose, module, owner_reminders,
                                                supervisor_reminders, on_assignment)
  values (p_source_type, p_purpose, p_module, p_config -> 'owner', p_config -> 'supervisor',
          (p_config ->> 'on_assignment')::boolean)
  on conflict (source_type, purpose) do update
     set owner_reminders = excluded.owner_reminders,
         supervisor_reminders = excluded.supervisor_reminders,
         on_assignment = excluded.on_assignment, updated_at = now();
end;
$$;

comment on function app.followups_register_reminder_schedule(text, text, text, jsonb) is
  'Story 4.7: a source owner registers a purpose-specific task reminder schedule (replaces the generic one).';

-- ---------------------------------------------------------------------------------------------
-- Reminder sources (3.2 contracts)
-- ---------------------------------------------------------------------------------------------

-- Source check of both reminder sources: current while the task is active at that
-- schedule_revision.
create function app.followups_reminder_source_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_task app.followups_tasks;
begin
  select t.* into v_task from app.followups_tasks t where t.task_id::text = p_source ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', app.followups_state_ok('active_state', v_task.task_state)
               and v_task.schedule_revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_task.schedule_revision);
end;
$$;

-- Reminder check (3.2): exactly {current, revision, actionable, recipient_eligible}.
--   actionable          the task is active (and, for the supervisor's alert, still overdue);
--   recipient_eligible  followups_task: the recipient is the task's owner now;
--                       followups_supervision: the recipient is the supervisor now and still
--                       holds the task's scope.
create function app.followups_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_task app.followups_tasks;
  v_active boolean;
begin
  select t.* into v_task from app.followups_tasks t where t.task_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  v_active := app.followups_state_ok('active_state', v_task.task_state);
  return jsonb_build_object(
    'current', v_active and v_task.schedule_revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_task.schedule_revision,
    'actionable', v_active and (p_key ->> 'reminder_kind' <> 'followup_overdue'
                                or app.followups_overdue(v_task)),
    'recipient_eligible', case p_key ->> 'source_type'
      when 'followups_task' then v_task.owner_member_id::text = p_key ->> 'recipient_member_id'
      when 'followups_supervision' then
        v_task.supervisor_member_id::text = p_key ->> 'recipient_member_id'
        and app.followups_holds_scope(v_task.supervisor_member_id, v_task)
      else false end);
end;
$$;

select app.contract_register_source_type(
  'followups', 'followups_task', 'app.followups_reminder_source_check(jsonb)'::regprocedure);
select app.contract_register_source_type(
  'followups', 'followups_supervision', 'app.followups_reminder_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('followups', 'followups_task', 'followup_assigned');
select app.contract_register_reminder_kind('followups', 'followups_task', 'followup_due');
select app.contract_register_reminder_kind('followups', 'followups_supervision', 'followup_overdue');
select app.contract_register_reminder_contract(
  'followups', 'followups_task', 'followup_assigned',
  'app.followups_reminder_check(jsonb)'::regprocedure,
  '{"title": "New follow-up task",
    "body": "A follow-up task was assigned to you. Open it to see the next action.",
    "link": "/followups/tasks/{source_id}"}'::jsonb);
select app.contract_register_reminder_contract(
  'followups', 'followups_task', 'followup_due',
  'app.followups_reminder_check(jsonb)'::regprocedure,
  '{"title": "Follow-up task due",
    "body": "A follow-up task is due. Open it to record progress or set a review date.",
    "link": "/followups/tasks/{source_id}"}'::jsonb);
select app.contract_register_reminder_contract(
  'followups', 'followups_supervision', 'followup_overdue',
  'app.followups_reminder_check(jsonb)'::regprocedure,
  '{"title": "Follow-up task overdue",
    "body": "A follow-up task you supervise is overdue. Open it to follow up with its owner.",
    "link": "/followups/tasks/{source_id}"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Scheduling (Notifications last in the lock order)
-- ---------------------------------------------------------------------------------------------

-- Cancels a task's pending reminders of one source type (or both when null), optionally for one
-- recipient, and ends the matching schedules.
create function app.followups_cancel_reminders(p_task_id uuid, p_source_type text,
                                               p_recipient uuid, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_type text;
begin
  for v_type in select x from unnest(array['followups_task', 'followups_supervision']) x
                 where p_source_type is null or x = p_source_type loop
    perform app.notifications_cancel(jsonb_strip_nulls(jsonb_build_object(
      'source_type', v_type, 'source_id', p_task_id, 'reason', p_reason,
      'recipient_member_id', p_recipient)));
  end loop;
end;
$$;

-- The reminder rules of a task: the purpose's registered source-specific schedule, or the
-- generic one (the creator's owner reminders or the church default, one supervisor alert a day
-- after the deadline, an assignment notice). {schedule: source|custom|default, owner (null =
-- the church default), supervisor, on_assignment}.
create function app.followups_reminder_rules(p_task app.followups_tasks)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('schedule', 'source', 'owner', r.owner_reminders,
                               'supervisor', r.supervisor_reminders,
                               'on_assignment', r.on_assignment)
       from app.followups_reminder_schedules r
      where r.source_type = p_task.source_type and r.purpose = p_task.purpose),
    jsonb_build_object('schedule', case when p_task.reminders is null then 'default' else 'custom' end,
                       'owner', p_task.reminders,
                       'supervisor', '[{"anchor": "deadline", "after": "1 day"}]'::jsonb,
                       'on_assignment', true));
$$;

-- (Re)plans an active task's reminders at its schedule_revision: the owner's schedule
-- (followups_task / followup_due), the supervisor's alert (followups_supervision /
-- followup_overdue) and, when p_assigned (a new task or a new owner) and the rules say so, one
-- assignment notice now. A recipient who is no longer an active member gets nothing (their
-- reminders are cancelled). Answers counts only.
create function app.followups_schedule_reminders(p_task_id uuid, p_assigned boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_task app.followups_tasks;
  v_rules jsonb;
  v_intent jsonb;
  v_owner jsonb;
  v_supervisor jsonb;
  v_assigned jsonb;
begin
  select t.* into v_task from app.followups_tasks t where t.task_id = p_task_id;
  if not found or not app.followups_state_ok('active_state', v_task.task_state) then
    return '{"scheduled": false}'::jsonb;
  end if;
  v_rules := app.followups_reminder_rules(v_task);
  v_intent := jsonb_build_object('due_at', app.cmd_utc(v_task.due_at), 'task_state', v_task.task_state)
              || case when v_task.task_state = 'waiting'
                      then jsonb_build_object('review_at', app.cmd_utc(v_task.review_at))
                      else '{}'::jsonb end;
  if app.followups_member_active(v_task.owner_member_id) then
    v_owner := app.notifications_set_schedule(jsonb_build_object(
      'source_type', 'followups_task', 'source_id', v_task.task_id,
      'source_revision', v_task.schedule_revision, 'recipient_member_id', v_task.owner_member_id,
      'schedule_type', 'task', 'intent', v_intent || jsonb_build_object('reminders', v_rules -> 'owner'),
      'kinds', '{"deadline": "followup_due"}'::jsonb, 'fresh', true));
    if p_assigned and (v_rules ->> 'on_assignment')::boolean then
      v_assigned := app.notifications_enqueue(jsonb_build_object(
        'source_type', 'followups_task', 'source_id', v_task.task_id,
        'source_revision', v_task.schedule_revision, 'recipient_member_id', v_task.owner_member_id,
        'reminder_kind', 'followup_assigned', 'scheduled_at', app.cmd_utc(now())));
    end if;
  else
    perform app.followups_cancel_reminders(v_task.task_id, 'followups_task', null, 'owner_inactive');
  end if;
  if jsonb_array_length(v_rules -> 'supervisor') > 0
     and app.followups_member_active(v_task.supervisor_member_id) then
    v_supervisor := app.notifications_set_schedule(jsonb_build_object(
      'source_type', 'followups_supervision', 'source_id', v_task.task_id,
      'source_revision', v_task.schedule_revision, 'recipient_member_id', v_task.supervisor_member_id,
      'schedule_type', 'task', 'intent', v_intent || jsonb_build_object('reminders', v_rules -> 'supervisor'),
      'kinds', '{"deadline": "followup_overdue"}'::jsonb, 'fresh', true));
  else
    perform app.followups_cancel_reminders(v_task.task_id, 'followups_supervision', null,
                                           'no_supervisor_alert');
  end if;
  return jsonb_build_object(
    'scheduled', true,
    'owner_entries', coalesce((v_owner ->> 'entries')::integer, 0),
    'supervisor_entries', coalesce((v_supervisor ->> 'entries')::integer, 0),
    'assigned', coalesce((v_assigned ->> 'created')::boolean, false));
end;
$$;

-- What the task's readers see of its reminders: the rules, without the policy.
create function app.followups_reminders_json(p_task app.followups_tasks)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.followups_reminder_rules(p_task);
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner decision Q4 (owner scope): the task's own group, plus the current Pastors
-- ---------------------------------------------------------------------------------------------

-- As in 4.6 (the target's roster through its owner's hook, plus the current holders of the
-- family's scope kinds), plus the members who hold the Pastor role now; all approved and not
-- under deletion. Used by create, reassign (Admin too), the owner operation and the candidate
-- lists of the supervision and Admin routing reads.
create or replace function app.followups_scope_roster(p_scope_kind text, p_scope_id uuid)
returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_proc regprocedure;
  v_answer jsonb;
  v_ids uuid[] := '{}';
  v_state text;
begin
  select f.roster_hook into v_hook from app.followups_scope_families f
   where f.scope_kind = p_scope_kind;
  v_proc := case when v_hook is not null then pg_catalog.to_regprocedure(v_hook) end;
  if v_proc is not null then
    begin
      execute format('select %s($1)', v_proc::regproc) into v_answer
        using jsonb_build_object('scope_kind', p_scope_kind, 'scope_id', p_scope_id);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      raise log 'followups roster hook failed: %', v_state;
      v_answer := null;
    end;
    if jsonb_typeof(v_answer) = 'object'
       and app.contract_unknown_keys(v_answer, array['member_ids']) = '{}'::jsonb
       and jsonb_typeof(v_answer -> 'member_ids') = 'array'
       and not exists (select 1 from jsonb_array_elements(v_answer -> 'member_ids') e
                        where app.contract_uuid_error(e) is not null) then
      select coalesce(array_agg((e #>> '{}')::uuid), '{}') into v_ids
        from jsonb_array_elements(v_answer -> 'member_ids') e;
    end if;
  end if;
  return (select coalesce(array_agg(distinct x order by x), '{}')
            from (select unnest(v_ids) as x
                  union
                  select g.member_id from app.identity_grants g
                   where g.revoked_at is null and g.scope_id = p_scope_id
                     and app.followups_family(g.scope_kind) = app.followups_family(p_scope_kind)
                  union
                  select g.member_id from app.identity_grants g
                   where g.revoked_at is null and g.role = 'pastor'
                     and app.identity_member_has_role(g.member_id, 'pastor')) y
           where app.followups_member_active(y.x));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner operations and commands (replaced; same signatures and privileges)
-- ---------------------------------------------------------------------------------------------

-- As in 4.6, plus `reminders` (optional creator specs; refused `fixed_by_source` when the
-- purpose registered its own schedule) and the task's reminders, scheduled last.
create or replace function app.followups_open_task(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_source_type text;
  v_source_id uuid;
  v_purpose text;
  v_owner uuid;
  v_supervisor uuid;
  v_scope_kind text;
  v_scope_id uuid;
  v_next text;
  v_due timestamptz;
  v_actor_member uuid;
  v_actor_account uuid;
  v_reminders jsonb;
  v_task uuid;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'purpose', 'owner_member_id', 'supervisor_member_id',
                'scope_kind', 'scope_id', 'next_action', 'due_at', 'actor_member_id',
                'actor_account_id', 'reminders']);
  select t.errors, t.value into v_errors, v_source_type
    from app.followups_token(p_input, 'source_type', true, v_errors) t;
  select t.errors, t.value into v_errors, v_purpose
    from app.followups_token(p_input, 'purpose', true, v_errors) t;
  select t.errors, t.value into v_errors, v_source_id
    from app.followups_uuid(p_input, 'source_id', true, v_errors) t;
  v_errors := v_errors || jsonb_strip_nulls(jsonb_build_object(
    'source_revision', app.contract_revision_error(p_input -> 'source_revision')));
  select t.errors, t.value into v_errors, v_owner
    from app.followups_uuid(p_input, 'owner_member_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_supervisor
    from app.followups_uuid(p_input, 'supervisor_member_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_scope_kind
    from app.followups_token(p_input, 'scope_kind', true, v_errors) t;
  select t.errors, t.value into v_errors, v_scope_id
    from app.followups_uuid(p_input, 'scope_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_next
    from app.followups_text(p_input, 'next_action', true, 200, false, v_errors) t;
  select t.errors, t.value into v_errors, v_due
    from app.followups_instant(p_input, 'due_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_actor_member
    from app.followups_uuid(p_input, 'actor_member_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_actor_account
    from app.followups_uuid(p_input, 'actor_account_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_reminders
    from app.followups_reminders_field(p_input, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  if v_reminders is not null and exists (
       select 1 from app.followups_reminder_schedules r
        where r.source_type = v_source_type and r.purpose = v_purpose) then
    perform app.cmd_fail('validation_failed', '{"reminders": "fixed_by_source"}');
  end if;
  v_task := app.followups_insert_task(v_source_type, v_source_id,
              (p_input ->> 'source_revision')::numeric::bigint, v_purpose, v_owner, v_supervisor,
              v_scope_kind, v_scope_id, v_next, v_due, v_actor_member, v_actor_account, 'source',
              false, null);
  update app.followups_tasks t set reminders = v_reminders where t.task_id = v_task;
  perform app.followups_schedule_reminders(v_task, true);
  return jsonb_build_object('task_id', v_task, 'revision', 1);
end;
$$;

-- As in 4.6; active tasks closed by the source event also lose every pending reminder.
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
  perform app.followups_require_open();
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

-- As in 4.6, plus `reminders` (the creator's owner reminders; null = the church default) and the
-- task's reminders, scheduled last.
create or replace function app.followups_create_task(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_source_type text;
  v_source_id uuid;
  v_purpose text;
  v_owner uuid;
  v_supervisor uuid;
  v_scope_kind text;
  v_scope_id uuid;
  v_next text;
  v_note text;
  v_due timestamptz;
  v_capacity text;
  v_task uuid;
  v_kinds text[];
  v_reminders jsonb;
begin
  select a.* into v_actor from app.followups_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['source_type', 'source_id',
                'source_revision', 'purpose', 'owner_member_id', 'supervisor_member_id',
                'scope_kind', 'scope_id', 'next_action', 'due_at', 'note', 'reminders']);
  select t.errors, t.value into v_errors, v_source_type
    from app.followups_token(p_payload, 'source_type', true, v_errors) t;
  select t.errors, t.value into v_errors, v_purpose
    from app.followups_token(p_payload, 'purpose', true, v_errors) t;
  select t.errors, t.value into v_errors, v_source_id
    from app.followups_uuid(p_payload, 'source_id', true, v_errors) t;
  v_errors := v_errors || jsonb_strip_nulls(jsonb_build_object(
    'source_revision', app.contract_revision_error(p_payload -> 'source_revision')));
  select t.errors, t.value into v_errors, v_owner
    from app.followups_uuid(p_payload, 'owner_member_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_supervisor
    from app.followups_uuid(p_payload, 'supervisor_member_id', false, v_errors) t;
  select t.errors, t.value into v_errors, v_scope_kind
    from app.followups_token(p_payload, 'scope_kind', true, v_errors) t;
  select t.errors, t.value into v_errors, v_scope_id
    from app.followups_uuid(p_payload, 'scope_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_next
    from app.followups_text(p_payload, 'next_action', true, 200, false, v_errors) t;
  select t.errors, t.value into v_errors, v_due
    from app.followups_instant(p_payload, 'due_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.followups_text(p_payload, 'note', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_reminders
    from app.followups_reminders_field(p_payload, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  v_kinds := app.followups_purpose_kinds(v_source_type, v_purpose);
  if cardinality(v_kinds) = 0 then
    perform app.cmd_fail('validation_failed', '{"purpose": "unregistered"}');
  elsif not (v_scope_kind = any (v_kinds)) then
    perform app.cmd_fail('validation_failed', '{"scope_kind": "not_allowed"}');
  end if;
  if app.followups_member_holds(v_actor.member_id, v_scope_kind, v_scope_id, v_kinds) then
    v_capacity := 'supervisor';
    v_supervisor := coalesce(v_supervisor, v_actor.member_id);
  elsif v_actor.is_admin then
    v_capacity := 'admin';
    if v_supervisor is null then
      perform app.cmd_fail('validation_failed', '{"supervisor_member_id": "required"}');
    end if;
    if v_note is not null then
      perform app.cmd_fail('validation_failed', '{"note": "not_allowed"}');
    end if;
  else
    perform app.cmd_fail('forbidden');
  end if;
  if v_reminders is not null and exists (
       select 1 from app.followups_reminder_schedules r
        where r.source_type = v_source_type and r.purpose = v_purpose) then
    perform app.cmd_fail('validation_failed', '{"reminders": "fixed_by_source"}');
  end if;
  v_task := app.followups_insert_task(v_source_type, v_source_id,
              (p_payload ->> 'source_revision')::numeric::bigint, v_purpose, v_owner, v_supervisor,
              v_scope_kind, v_scope_id, v_next, v_due, v_actor.member_id, v_actor.account_id,
              v_capacity, true, 'followups.create_task');
  update app.followups_tasks t set reminders = v_reminders where t.task_id = v_task;
  if v_note is not null then
    insert into app.followups_notes (task_id, body, author_member_id, author_account_id,
                                     on_behalf_of_member)
    values (v_task, v_note, v_actor.member_id, v_actor.account_id,
            case when v_owner <> v_actor.member_id then v_owner end);
    perform app.followups_activity_event(v_task, 'note_added', v_actor.member_id,
                                         v_actor.account_id, v_capacity,
                                         case when v_owner <> v_actor.member_id then v_owner end,
                                         'followups.create_task', null, null, null, null, null,
                                         null, null, 1);
  end if;
  perform app.followups_schedule_reminders(v_task, true);
  return app.followups_task_outcome(v_task);
end;
$$;

-- As in 4.6, plus the reminders: Done and Closed cancel every pending reminder; a moved
-- actionable deadline (into or out of Waiting, a new review date) moves schedule_revision and
-- re-plans (the review-date change itself stays recorded in the activity); other state changes
-- re-plan at the same revision (nothing changes); notes, outcomes and next actions leave the
-- reminders alone.
create or replace function app.followups_update_task(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_task_id uuid;
  v_task app.followups_tasks;
  v_purpose app.followups_purposes;
  v_status text;
  v_review timestamptz;
  v_reason text;
  v_outcome text;
  v_next text;
  v_note text;
  v_capacity text;
  v_behalf uuid;
  v_new_state text;
  v_new_review timestamptz;
  v_revision bigint;
  v_cmd constant text := 'followups.update_task';
begin
  select a.* into v_actor from app.followups_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['task_id', 'status', 'review_at',
                'close_reason', 'outcome', 'next_action', 'note']);
  select t.errors, t.value into v_errors, v_task_id
    from app.followups_uuid(p_payload, 'task_id', true, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'status'), 'null') <> 'null' then
    v_status := p_payload ->> 'status';
    if jsonb_typeof(p_payload -> 'status') <> 'string'
       or not app.followups_state_ok('task_state', v_status) then
      v_errors := v_errors || '{"status": "invalid"}';
      v_status := null;
    end if;
  end if;
  select t.errors, t.value into v_errors, v_review
    from app.followups_instant(p_payload, 'review_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.followups_text(p_payload, 'close_reason', false, 200, false, v_errors) t;
  select t.errors, t.value into v_errors, v_outcome
    from app.followups_token(p_payload, 'outcome', false, v_errors) t;
  select t.errors, t.value into v_errors, v_next
    from app.followups_text(p_payload, 'next_action', false, 200, false, v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.followups_text(p_payload, 'note', false, 1000, true, v_errors) t;
  if v_errors = '{}'::jsonb and v_status is null and v_review is null and v_reason is null
     and v_outcome is null and v_next is null and v_note is null then
    v_errors := '{"changes": "required"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  select t.* into v_task from app.followups_tasks t where t.task_id = v_task_id for update;
  v_capacity := case when found then app.followups_capacity(v_actor.member_id, v_task) end;
  if v_capacity is null then
    perform app.cmd_fail('not_found');
  elsif v_capacity = 'admin' then
    perform app.cmd_fail('forbidden');
  end if;
  if v_task.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_task.revision);
  end if;
  if not app.followups_state_ok('active_state', v_task.task_state) then
    perform app.cmd_fail('conflict', '{"task_id": "finished"}', v_task.revision);
  end if;
  select p.* into v_purpose from app.followups_purposes p
   where p.source_type = v_task.source_type and p.purpose = v_task.purpose;
  v_new_state := coalesce(v_status, v_task.task_state);
  v_errors := '{}'::jsonb;
  if v_status is not null and v_status = v_task.task_state
     and not (v_status = 'waiting' and v_review is not null) then
    v_errors := v_errors || '{"status": "unchanged"}';
  end if;
  if v_new_state = 'waiting' then
    if v_review is null and v_task.task_state <> 'waiting' then
      v_errors := v_errors || '{"review_at": "required"}';
    elsif v_review is not null and v_review <= now() then
      v_errors := v_errors || '{"review_at": "past"}';
    elsif v_review is not null and v_review > now() + interval '1 year' then
      v_errors := v_errors || '{"review_at": "out_of_range"}';
    elsif v_review is not null and v_review = v_task.review_at then
      v_errors := v_errors || '{"review_at": "unchanged"}';
    end if;
  elsif v_review is not null then
    v_errors := v_errors || '{"review_at": "not_waiting"}';
  end if;
  if v_new_state = 'closed' and v_reason is null then
    v_errors := v_errors || '{"close_reason": "required"}';
  elsif v_new_state <> 'closed' and v_reason is not null then
    v_errors := v_errors || '{"close_reason": "not_closing"}';
  end if;
  if v_outcome is not null and not (v_outcome = any (v_purpose.outcomes)) then
    v_errors := v_errors || '{"outcome": "unregistered"}';
  end if;
  if v_next is not null and v_next = v_task.next_action then
    v_errors := v_errors || '{"next_action": "unchanged"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_behalf := case when v_capacity = 'supervisor' then v_task.owner_member_id end;
  v_new_review := case when v_new_state = 'waiting' then coalesce(v_review, v_task.review_at) end;
  update app.followups_tasks t
     set task_state = v_new_state,
         review_at = v_new_review,
         finished_at = case when v_new_state in ('done', 'closed') then now() end,
         close_code = case when v_new_state = 'closed' then 'manual' end,
         close_reason = case when v_new_state = 'closed' then v_reason end,
         latest_outcome = coalesce(v_outcome, t.latest_outcome),
         next_action = coalesce(v_next, t.next_action),
         -- Story 4.7: the reminders' revision moves with the actionable deadline only.
         schedule_revision = t.schedule_revision
           + case when v_new_state in ('open', 'in_progress', 'waiting')
                       and v_new_review is distinct from v_task.review_at then 1 else 0 end,
         revision = t.revision + 1,
         updated_at = now()
   where t.task_id = v_task.task_id
  returning t.revision into v_revision;
  if v_outcome is not null then
    perform app.followups_activity_event(v_task.task_id, 'outcome_recorded', v_actor.member_id,
                                         v_actor.account_id, v_capacity, v_behalf, v_cmd, null,
                                         null, v_outcome, null, null, null, null, v_revision);
  end if;
  if v_next is not null then
    perform app.followups_activity_event(v_task.task_id, 'next_action_changed', v_actor.member_id,
                                         v_actor.account_id, v_capacity, v_behalf, v_cmd, null,
                                         null, null, null, null, null, null, v_revision);
  end if;
  if v_new_state <> v_task.task_state then
    perform app.followups_activity_event(v_task.task_id, 'status_changed', v_actor.member_id,
                                         v_actor.account_id, v_capacity, v_behalf, v_cmd,
                                         v_task.task_state, v_new_state, null, v_new_review, null,
                                         null, case when v_new_state = 'closed' then 'manual' end,
                                         v_revision);
  elsif v_new_review is distinct from v_task.review_at then
    perform app.followups_activity_event(v_task.task_id, 'review_date_set', v_actor.member_id,
                                         v_actor.account_id, v_capacity, v_behalf, v_cmd,
                                         v_task.task_state, v_new_state, null, v_new_review, null,
                                         null, null, v_revision);
  end if;
  if v_note is not null then
    insert into app.followups_notes (task_id, body, author_member_id, author_account_id,
                                     on_behalf_of_member)
    values (v_task.task_id, v_note, v_actor.member_id, v_actor.account_id, v_behalf);
    perform app.followups_activity_event(v_task.task_id, 'note_added', v_actor.member_id,
                                         v_actor.account_id, v_capacity, v_behalf, v_cmd, null,
                                         null, null, null, null, null, null, v_revision);
  end if;
  -- Notifications last (AD-2).
  if v_new_state in ('done', 'closed') then
    perform app.followups_cancel_reminders(v_task.task_id, null, null, 'task_' || v_new_state);
  elsif v_new_state <> v_task.task_state or v_new_review is distinct from v_task.review_at then
    perform app.followups_schedule_reminders(v_task.task_id, false);
  end if;
  return app.followups_task_outcome(v_task.task_id);
end;
$$;

-- As in 4.6, plus the reminders: a new owner's predecessor loses every pending reminder of the
-- task (`reassigned`) and the new owner gets the assignment notice and the schedule; a new
-- supervisor takes over the overdue alert (`supervisor_changed`).
create or replace function app.followups_reassign(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_task_id uuid;
  v_owner uuid;
  v_supervisor uuid;
  v_task app.followups_tasks;
  v_capacity text;
  v_revision bigint;
  v_cmd constant text := 'followups.reassign';
begin
  select a.* into v_actor from app.followups_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['task_id', 'owner_member_id',
                                                          'supervisor_member_id']);
  select t.errors, t.value into v_errors, v_task_id
    from app.followups_uuid(p_payload, 'task_id', true, v_errors) t;
  select t.errors, t.value into v_errors, v_owner
    from app.followups_uuid(p_payload, 'owner_member_id', false, v_errors) t;
  select t.errors, t.value into v_errors, v_supervisor
    from app.followups_uuid(p_payload, 'supervisor_member_id', false, v_errors) t;
  if v_errors = '{}'::jsonb and v_owner is null and v_supervisor is null then
    v_errors := '{"changes": "required"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  select t.* into v_task from app.followups_tasks t where t.task_id = v_task_id for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if app.followups_holds_scope(v_actor.member_id, v_task) then
    v_capacity := 'supervisor';
  elsif v_actor.is_admin then
    v_capacity := 'admin';
  elsif v_task.owner_member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden');
  else
    perform app.cmd_fail('not_found');
  end if;
  if v_task.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_task.revision);
  end if;
  if not app.followups_state_ok('active_state', v_task.task_state) then
    perform app.cmd_fail('conflict', '{"task_id": "finished"}', v_task.revision);
  end if;
  v_errors := '{}'::jsonb;
  if v_owner is not null then
    if v_owner = v_task.owner_member_id then
      v_errors := v_errors || '{"owner_member_id": "unchanged"}';
    elsif not app.followups_member_active(v_owner) then
      v_errors := v_errors || '{"owner_member_id": "unknown"}';
    elsif not (v_owner = any (app.followups_scope_roster(v_task.scope_kind, v_task.scope_id))) then
      v_errors := v_errors || '{"owner_member_id": "not_in_scope"}';
    end if;
  end if;
  if v_supervisor is not null then
    perform 1 from app.identity_grants g
     where g.member_id = v_supervisor and g.revoked_at is null for share;
    if v_supervisor = v_task.supervisor_member_id then
      v_errors := v_errors || '{"supervisor_member_id": "unchanged"}';
    elsif not app.followups_member_active(v_supervisor)
          or not app.followups_holds_scope(v_supervisor, v_task) then
      v_errors := v_errors || '{"supervisor_member_id": "not_in_scope"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  update app.followups_tasks t
     set owner_member_id = coalesce(v_owner, t.owner_member_id),
         supervisor_member_id = coalesce(v_supervisor, t.supervisor_member_id),
         revision = t.revision + 1, updated_at = now()
   where t.task_id = v_task.task_id
  returning t.revision into v_revision;
  if v_owner is not null then
    perform app.followups_activity_event(v_task.task_id, 'reassigned', v_actor.member_id,
                                         v_actor.account_id, v_capacity, null, v_cmd, null, null,
                                         null, null, v_task.owner_member_id, v_owner, null,
                                         v_revision);
  end if;
  if v_supervisor is not null then
    perform app.followups_activity_event(v_task.task_id, 'supervisor_changed', v_actor.member_id,
                                         v_actor.account_id, v_capacity, null, v_cmd, null, null,
                                         null, null, v_task.supervisor_member_id, v_supervisor,
                                         null, v_revision);
  end if;
  -- Notifications last (AD-2).
  if v_owner is not null then
    perform app.followups_cancel_reminders(v_task.task_id, 'followups_task',
                                           v_task.owner_member_id, 'reassigned');
  end if;
  if v_supervisor is not null then
    perform app.followups_cancel_reminders(v_task.task_id, 'followups_supervision',
                                           v_task.supervisor_member_id, 'supervisor_changed');
  end if;
  perform app.followups_schedule_reminders(v_task.task_id, v_owner is not null);
  return app.followups_task_outcome(v_task.task_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads (replaced; same signatures and privileges)
-- ---------------------------------------------------------------------------------------------

-- As in 4.6, plus `reminders` (the task's reminder rules: schedule source|custom|default, the
-- owner's specs (null = the church default), the supervisor's alert specs, on_assignment).
create or replace function app.followups_task_json(p_task_id uuid, p_viewer uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_task app.followups_tasks;
  v_capacity text;
  v_scope boolean;
  v_admin boolean;
begin
  select t.* into v_task from app.followups_tasks t where t.task_id = p_task_id;
  if not found then
    return null;
  end if;
  v_capacity := app.followups_capacity(p_viewer, v_task);
  v_scope := app.followups_holds_scope(p_viewer, v_task);
  v_admin := app.identity_member_has_role(p_viewer, 'admin');
  return app.followups_routing_json(p_task_id)
    - 'owner' - 'supervisor'
    || jsonb_build_object(
      'owner', app.followups_member_ref(v_task.owner_member_id, false),
      'supervisor', app.followups_member_ref(v_task.supervisor_member_id, false),
      'source_id', v_task.source_id,
      'context', app.followups_context(v_task, p_viewer),
      'next_action', v_task.next_action,
      'latest_outcome', v_task.latest_outcome,
      'outcomes', (select to_jsonb(p.outcomes) from app.followups_purposes p
                    where p.source_type = v_task.source_type and p.purpose = v_task.purpose),
      'close_code', v_task.close_code,
      'close_reason', v_task.close_reason,
      'capacity', v_capacity,
      'can_update', v_capacity in ('owner', 'supervisor')
                    and app.followups_state_ok('active_state', v_task.task_state),
      'can_reassign', (v_scope or v_admin)
                      and app.followups_state_ok('active_state', v_task.task_state),
      'reminders', app.followups_reminders_json(v_task));
end;
$$;

-- As in 4.6; each manual purpose also says whether its source fixed the reminders
-- (`fixed_reminders`: the create form then offers no reminder choice).
create or replace function app.followups_supervision()
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
  if not exists (select 1 from app.identity_grants g
                  where g.member_id = v_member and g.revoked_at is null
                    and exists (select 1 from app.followups_purposes p
                                 where g.scope_kind = any (p.scope_kinds))) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.followups_require_open_read();
  with mine as (
    select distinct g.scope_kind, g.scope_id from app.identity_grants g
     where g.member_id = v_member and g.revoked_at is null
       and exists (select 1 from app.followups_purposes p where g.scope_kind = any (p.scope_kinds))),
  ranked as (
    select t.task_id,
           row_number() over (order by (t.finished_at is not null),
                                       coalesce(t.review_at, t.due_at), t.finished_at desc,
                                       t.task_id) as rn
      from app.followups_tasks t
     where t.scope_id in (select s.scope_id from mine s)
       and app.followups_holds_scope(v_member, t)
       and (t.finished_at is null or t.finished_at > now() - interval '30 days')),
  families as (
    select distinct on (app.followups_family(s.scope_kind), s.scope_id) s.scope_kind, s.scope_id
      from mine s
     order by app.followups_family(s.scope_kind), s.scope_id, s.scope_kind)
  select jsonb_build_object(
    'scopes', coalesce((select jsonb_agg(app.followups_scope_json(f.scope_kind, f.scope_id, false)
                                         order by f.scope_kind, f.scope_id) from families f), '[]'::jsonb),
    'purposes', coalesce((
      select jsonb_agg(jsonb_build_object('source_type', p.source_type, 'purpose', p.purpose,
                                          'label', p.label, 'scope_kinds', to_jsonb(p.scope_kinds),
                                          'outcomes', to_jsonb(p.outcomes),
                                          'fixed_reminders', exists (
                                            select 1 from app.followups_reminder_schedules r
                                             where r.source_type = p.source_type
                                               and r.purpose = p.purpose))
                       order by p.source_type, p.purpose)
        from app.followups_purposes p
       where p.manual_create
         and exists (select 1 from mine s where s.scope_kind = any (p.scope_kinds))), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(app.followups_task_json(r.task_id, v_member) order by r.rn)
                         from ranked r where r.rn <= 200), '[]'::jsonb),
    'truncated', (select count(*) > 200 from ranked))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC source-specific schedule: fixture_followup/synthetic_report_due (owner: fixture)
-- ---------------------------------------------------------------------------------------------

-- Shaped like the missing-report rule (functional requirements, Follow-up tasks): remind the
-- owner at the deadline and two days later, no assignment notice and no supervisor alert. Not a
-- manual purpose: tasks are opened through app.followups_open_task, as a real source would.
select app.contract_register_purpose('fixture', 'fixture_followup', 'synthetic_report_due');
select app.followups_register_purpose(
  'fixture', 'fixture_followup', 'synthetic_report_due',
  '{"label": "SYNTHETIC report due",
    "scope_kinds": ["department_leader", "department_deputy", "cell_leader", "cell_assistant"],
    "outcomes": ["submitted", "no_longer_needed"],
    "on_source_resolved": "close", "on_source_cancelled": "close", "manual_create": false}'::jsonb,
  'app.fixture_followup_context(jsonb)'::regprocedure);
select app.followups_register_reminder_schedule(
  'fixture', 'fixture_followup', 'synthetic_report_due',
  '{"owner": [{"anchor": "deadline", "before": "0 minutes"}, {"anchor": "deadline", "after": "2 days"}],
    "supervisor": [], "on_assignment": false}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Privileges (no client grants)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.followups_reminder_specs_error(jsonb),
  app.followups_reminders_field(jsonb, jsonb),
  app.followups_register_reminder_schedule(text, text, text, jsonb),
  app.followups_reminder_source_check(jsonb),
  app.followups_reminder_check(jsonb),
  app.followups_cancel_reminders(uuid, text, uuid, text),
  app.followups_reminder_rules(app.followups_tasks),
  app.followups_schedule_reminders(uuid, boolean),
  app.followups_reminders_json(app.followups_tasks)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
