-- Generate recurring multi-position rotas with drafts and series edits (story 4.3; AD-2, AD-6,
-- AD-9). A forward migration on the Duties owner (20261013220239_duties_department_tracer.sql and
-- 20261014001142_duties_revisions.sql are not edited). It adds:
--
--   * Rota series (app.duties_series): a Duties-owned standalone recurrence (every N days, weeks
--     or months between two church-local dates, at church-local times) with named positions.
--     The occurrences are expanded ONCE at creation by the shared 3.3 calculation
--     (app.notifications_occurrences under the Q2 policy zone, so church-local dates hold across
--     the UTC date boundary), bounded (at most 60 occurrences, 10 positions, 366 days, future
--     starts only) and idempotent (one occurrence per series and church-local date).
--   * Drafts: occurrences in state `draft` with one slot per named position and an optional
--     draft assignee on the slot (app.duties_slots.draft_member_id). Drafts have no assignment
--     rows and no jobs, so My duties, reminders and the 4.1/4.2 leader board never see them; the
--     department's leader, deputy, Admin and Pastor (read only) see them in api.duties_rota.
--   * Commands (1.4 envelope, `duties` authorizer):
--       duties.create_series     expected null; generates the draft occurrences;
--       duties.assign_slot       expected = occurrence revision; a draft: set or clear the draft
--                                assignee; published: give the position to a member with an
--                                answer-by (supersedes any current assignment by the 4.2 rules);
--       duties.publish_drafts    expected = series revision; "Publish N draft slots": every
--                                not-started draft of the series, N must match, each assignment's
--                                deadline = (reporting or start) - deadline_before in church time;
--       duties.revise_duty       (replaced) "this occurrence": every position together; drafts
--                                are edited in place without notices; topic, scripture, event_ref;
--       duties.revise_series     expected = series revision; "this and future" from an anchor
--                                occurrence, church-local times; started occurrences unchanged;
--       duties.cancel_occurrence expected = occurrence revision (a series occurrence);
--       duties.cancel_series     expected = series revision; this and future.
--     Cancelling a published occurrence ends its current assignments (`cancelled`), cancels the
--     occurrence's pending jobs (`source_cancelled`), records a `cancelled` slot revision and
--     sends a generic `duty_cancelled` notice to pending or accepted assignees.
--   * Field classes (app.duties_slot_field_class): topic and scripture are notes (update notice);
--     event_ref (an opaque linked-event id until Content exists) is a reference (recorded, no
--     notice); position_name is material and fixed at creation.
--   * One shared change engine (app.duties_apply_change) used by revise_duty, revise_series and
--     assign_slot; it returns its notification work, which callers run last (AD-2 lock order).
--   * The read api.duties_rota (managers and Pastor): series, occurrences (draft, published,
--     cancelled), positions, draft assignees, current assignments, `confirmed` of `required`.
--   * Deletion: draft assignees are cleared and series creators anonymised (nil UUID); no new
--     row deletions, so no new _rows file.
--
-- Lock order (AD-2): the actor's grant rows FOR SHARE (authorizer) -> command receipt ->
-- department FOR SHARE -> series FOR UPDATE -> occurrences FOR UPDATE (series date order) ->
-- department membership FOR SHARE -> slots FOR UPDATE -> assignments FOR UPDATE ->
-- Notifications (cancel, enqueue), always last.
--
-- No destructive statements, no row deletions. New client grant: api.duties_rota() and its app
-- body (authenticated only).

-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened) and field classes
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
                                         'occurrence_cancelled')
    else false end;
$$;

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (stories 4.1-4.3). Later stories widen them by replacing this function.';

create or replace function app.duties_slot_field_class(p_field text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_field in ('duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id',
                     'position_name')
      then 'material'
    when p_field in ('instructions', 'topic', 'scripture') then 'notes'
    when p_field = 'event_ref' then 'reference'
    when p_field = 'response_deadline' then 'assignment'
  end;
$$;

comment on function app.duties_slot_field_class(text) is
  'Stories 4.2-4.3: material, notes or reference classification of each revisable slot field '
  '(position_name is material and fixed at creation in 4.3).';

-- Position names of a series: 1..10 distinct (case-insensitive) single-line names of 1..60.
create function app.duties_positions_ok(p_positions text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_positions is not null and cardinality(p_positions) between 1 and 10
     and not exists (select 1 from unnest(p_positions) n
                      where n is null or length(n) not between 1 and 60)
     and (select count(distinct lower(n)) from unnest(p_positions) n) = cardinality(p_positions);
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- One rota series: the church-local recurrence intent (AD-9: zone and policy version recorded).
create table app.duties_series (
  series_id uuid primary key default gen_random_uuid(),
  department_id uuid not null references app.duties_departments (department_id),
  duty_name text not null check (length(duty_name) between 1 and 80),
  every text not null check (app.duties_state_ok('series_every', every)),
  every_interval integer not null default 1 check (every_interval between 1 and 52),
  from_date date not null,
  until_date date not null,
  start_time time not null,
  end_time time,
  reporting_time time,
  location text check (location is null or length(location) between 1 and 120),
  instructions text check (instructions is null or length(instructions) between 1 and 1000),
  topic text check (topic is null or length(topic) between 1 and 120),
  scripture text check (scripture is null or length(scripture) between 1 and 120),
  event_ref uuid,
  positions text[] not null check (app.duties_positions_ok(positions)),
  exceptions date[] not null default '{}' check (cardinality(exceptions) <= 366),
  zone text not null check (length(zone) between 1 and 64),
  policy_version integer not null,
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (until_date >= from_date and until_date <= from_date + 366),
  check (reporting_time is null or reporting_time <= start_time)
);

create index duties_series_department on app.duties_series (department_id, from_date);

comment on table app.duties_series is
  'owner: duties. A rota series (story 4.3): church-local recurrence intent and named positions; '
  'its occurrences are generated once as drafts.';

alter table app.duties_series enable row level security;
revoke all on table app.duties_series from public, anon, authenticated, service_role;

alter table app.duties_occurrences
  add column series_id uuid references app.duties_series (series_id),
  add column series_date date,
  add column topic text check (topic is null or length(topic) between 1 and 120),
  add column scripture text check (scripture is null or length(scripture) between 1 and 120),
  add column event_ref uuid,
  add constraint duties_occurrences_series_date check ((series_id is null) = (series_date is null));

create unique index duties_occurrences_series_date
  on app.duties_occurrences (series_id, series_date) where series_id is not null;

comment on column app.duties_occurrences.series_date is
  'Story 4.3: the church-local date the series generated this occurrence for (its key).';

alter table app.duties_slots
  add column position_name text check (position_name is null or length(position_name) between 1 and 60),
  add column draft_member_id uuid;

create index duties_slots_draft_member on app.duties_slots (draft_member_id)
  where draft_member_id is not null;

comment on column app.duties_slots.draft_member_id is
  'Story 4.3: the planned assignee of a draft position (no assignment, no notice until published).';

alter table app.duties_slot_revisions
  add column topic text check (topic is null or length(topic) between 1 and 120),
  add column scripture text check (scripture is null or length(scripture) between 1 and 120),
  add column event_ref uuid;

alter table app.duties_audit add column series_id uuid;

-- Immutable slot revisions (replaced: the new snapshot columns are covered too).
create or replace function app.duties_slot_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if (new.slot_id, new.slot_revision, new.occurrence_id, new.occurrence_revision, new.change_class,
      new.changed_fields, new.duty_name, new.starts_at, new.ends_at, new.reporting_at, new.location,
      new.instructions, new.topic, new.scripture, new.event_ref, new.assignment_id,
      new.response_deadline, new.command_request_id, new.created_at)
     is distinct from
     (old.slot_id, old.slot_revision, old.occurrence_id, old.occurrence_revision, old.change_class,
      old.changed_fields, old.duty_name, old.starts_at, old.ends_at, old.reporting_at, old.location,
      old.instructions, old.topic, old.scripture, old.event_ref, old.assignment_id,
      old.response_deadline, old.command_request_id, old.created_at)
     or (new.member_id is distinct from old.member_id and new.member_id is distinct from v_nil)
     or (new.created_by_member is distinct from old.created_by_member
         and new.created_by_member is distinct from v_nil)
     or (new.created_by_account is distinct from old.created_by_account
         and new.created_by_account is distinct from v_nil) then
    raise exception using errcode = 'P0001', message = 'duties slot revisions are immutable';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- A church-local wall time "HH:MM".
create function app.duties_local_time(p_payload jsonb, p_key text, p_required boolean,
                                      inout errors jsonb, out value time)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    return;
  end if;
  if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := (v #>> '{}')::time;
end;
$$;

-- A church-local date "YYYY-MM-DD".
create function app.duties_local_date(p_payload jsonb, p_key text, inout errors jsonb, out value date)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    errors := errors || jsonb_build_object(p_key, 'required');
    return;
  end if;
  if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     or app.contract_local_error(to_jsonb((v #>> '{}') || 'T00:00:00')) is not null then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := (v #>> '{}')::date;
end;
$$;

-- A lead time before the (reporting) start: "<n> minutes|hours|days", at most 90 days.
create function app.duties_lead(p_payload jsonb, p_key text, p_required boolean,
                                inout errors jsonb, out value text)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
  v_error text;
begin
  if not p_required and coalesce(jsonb_typeof(v), 'null') = 'null' then
    return;
  end if;
  v_error := app.notifications_duration_error(v);
  if v_error is null and app.notifications_duration_minutes(v #>> '{}') > 90 * 1440 then
    v_error := 'out_of_range';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object(p_key, v_error);
    return;
  end if;
  value := v #>> '{}';
end;
$$;

-- The UTC instant of a church-local date and time in p_zone.
create function app.duties_wall(p_date date, p_time time, p_zone text)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (p_date + p_time) at time zone p_zone;
$$;

-- Can the member serve in the department now (a current member, approved, not under deletion)?
create function app.duties_can_serve(p_member_id uuid, p_department_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_member_id is not null
     and exists (select 1 from app.duties_department_members dm
                  where dm.department_id = p_department_id and dm.member_id = p_member_id
                    and dm.ended_at is null)
     and app.duties_member_active(p_member_id);
$$;

create function app.duties_audit_series_event(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_department uuid,
  p_series uuid,
  p_occurrence uuid,
  p_assignment uuid,
  p_member uuid,
  p_code text,
  p_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.duties_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                command_request_id, department_id, series_id, occurrence_id,
                                assignment_id, member_id, code, revision_after)
  values (p_action, p_actor_member, p_actor_account, p_capacity,
          app.cmd_current_request_id(p_actor_account, p_command), p_department, p_series,
          p_occurrence, p_assignment, p_member, p_code, p_revision);
$$;

-- The fields changed on a slot after revision p_after (replaced: the 4.3 fields in order).
create or replace function app.duties_changes_since(p_slot_id uuid, p_after bigint, p_upto bigint)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(x.f order by array_position(
           array['duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id',
                 'instructions', 'topic', 'scripture', 'event_ref', 'position_name'], x.f)), '{}')
    from (select distinct f
            from app.duties_slot_revisions r cross join unnest(r.changed_fields) f
           where r.slot_id = p_slot_id and r.slot_revision > p_after
             and (p_upto is null or r.slot_revision <= p_upto)) x;
$$;

-- Runs the notification work a Duties change produced, in order, after every Duties row is
-- written (Notifications last, AD-2). Ops:
--   {"op": "cancel", "source_id", "reason"}                         pending jobs of a source;
--   {"op": "enqueue", "key": {...}, "counts": bool}                 one job;
--   {"op": "replace", "source_id", "source_revision", "recipient"}  4.2 notes rule: any unsent
--        notice of the assignment is cancelled `replaced` and sent once as the most telling kind.
-- Returns {queued: jobs created by counting ops, created: all jobs created}.
create function app.duties_notify(p_ops jsonb)
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
-- The shared change engine (published occurrences)
-- ---------------------------------------------------------------------------------------------

-- Applies a change to a PUBLISHED occurrence that the caller has locked FOR UPDATE and whose
-- new times it has validated (not started). p_old is the row as locked, p_new the same row with
-- the new field values. When p_member_given, p_target_slot's position goes to p_member (non
-- null). Every position takes occurrence-wide changes together; a material change supersedes
-- each current assignment with a new pending one (4.2 rules); a notes change keeps the answers
-- and sends one update notice when instructions, topic or scripture changed (event_ref is a
-- reference: recorded, no notice). Deadline errors are reported under p_deadline_key
-- (`response_deadline`: required | past | after_start; `deadline_before`: required | passed).
-- Unchanged: null when p_skip_unchanged, else validation_failed {"occurrence_id": "unchanged"}.
-- Returns {revision, change, slot_id, slot_revision, assignment_id, assignment_revision,
-- superseded_assignment_id, response, assignments_created, ops} (the reported position is the
-- target slot, or position 1); the caller runs ops with app.duties_notify LAST.
create function app.duties_apply_change(
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
  v_report jsonb;
  v_need_deadline boolean;
  v_start timestamptz := coalesce(p_new.reporting_at, p_new.starts_at);
  v_cur_target uuid;
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

  -- A new pending assignment needs the leader's answer-by (entry 8 adds the 3.3 default).
  v_need_deadline := v_member_changed
    or (v_occ_material and exists (
          select 1 from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
           where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'));
  if v_need_deadline then
    if p_deadline is null then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key, 'required'));
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
      insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                          assigned_by_account, slot_revision,
                                          supersedes_assignment_id)
      values (v_slot.slot_id, v_new_member, p_deadline, p_actor_member, p_actor_account,
              v_slot_revision, v_old.assignment_id)
      returning assignment_id, member_id, revision, response_deadline, response
           into v_current, v_current_member, v_current_revision, v_current_deadline, v_response;
      v_created := v_created + 1;
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
      if v_current is not null and app.duties_notice_recipient(v_current_member) then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_current, 'source_revision', 1,
            'recipient_member_id', v_current_member,
            'reminder_kind', case when v_current_member = v_old.member_id then 'duty_changed'
                                  else 'duty_assigned' end,
            'scheduled_at', app.cmd_utc(now()))));
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
    'revision', v_revision, 'change', v_class, 'assignments_created', v_created, 'ops', v_ops);
end;
$$;

-- Validates an occurrence's new times (shared by revise_duty and revise_series). Keys follow
-- p_keys: {starts, ends, reporting} -> payload key names.
create function app.duties_times_errors(p_starts timestamptz, p_ends timestamptz,
                                        p_reporting timestamptz, p_keys text[])
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  e jsonb := '{}'::jsonb;
begin
  if p_starts is null then
    return jsonb_build_object(p_keys[1], 'required');
  end if;
  if p_starts <= now() then
    e := e || jsonb_build_object(p_keys[1], 'past');
  elsif p_starts > now() + interval '2 years' then
    e := e || jsonb_build_object(p_keys[1], 'out_of_range');
  end if;
  if p_ends is not null and p_ends <= p_starts then
    e := e || jsonb_build_object(p_keys[2], 'before_start');
  end if;
  if p_reporting is not null and p_reporting > p_starts then
    e := e || jsonb_build_object(p_keys[3], 'after_start');
  elsif p_reporting is not null and p_reporting <= now() then
    e := e || jsonb_build_object(p_keys[3], 'past');
  end if;
  return e;
end;
$$;

-- Ends one occurrence that the caller locked (draft or published, not started): the occurrence
-- and every current assignment become `cancelled`, a `cancelled` slot revision is recorded for
-- each position of a published occurrence. Returns {assignments_cancelled, ops}: the caller runs
-- ops LAST (pending jobs of every assignment of the occurrence cancelled `source_cancelled`,
-- then one `duty_cancelled` notice per pending or accepted assignee).
create function app.duties_cancel_one(p_occ app.duties_occurrences, p_actor_member uuid,
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
  update app.duties_occurrences o
     set occurrence_state = 'cancelled', revision = o.revision + 1
   where o.occurrence_id = p_occ.occurrence_id
  returning o.revision into v_revision;
  if p_occ.occurrence_state <> 'published' then
    -- A cancelled draft keeps no planned people.
    update app.duties_slots s set draft_member_id = null
     where s.occurrence_id = p_occ.occurrence_id and s.draft_member_id is not null;
    perform app.duties_audit_series_event('occurrence_cancelled', p_actor_member, p_actor_account,
                                          p_capacity, p_command, p_occ.department_id, p_occ.series_id,
                                          p_occ.occurrence_id, null, null, p_occ.occurrence_state,
                                          v_revision);
    return jsonb_build_object('assignments_cancelled', 0, 'ops', '[]'::jsonb);
  end if;
  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_occ.occurrence_id
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
-- Projections (replaced: positions, topic, scripture, linked event; the board lists published
-- duties only, drafts and cancelled occurrences are read through api.duties_rota)
-- ---------------------------------------------------------------------------------------------

create or replace function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean)
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
                          'note', case when p_with_notes then a.response_note end,
                          'revision', a.revision,
                          'slot_revision', a.slot_revision,
                          'changes', case when a.supersedes_assignment_id is not null
                                          then to_jsonb(app.duties_changes_since(
                                                 s.slot_id, a.slot_revision - 1, a.slot_revision)) end,
                          'notes_updated_at', (select app.cmd_utc(t.ts) from (
                                                 select app.duties_notes_updated_at(s.slot_id, a.slot_revision) as ts) t
                                                where t.ts is not null))
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
    'note', a.response_note,
    'slot_revision', a.slot_revision,
    'changes', case when p.member_id = a.member_id
                    then to_jsonb(app.duties_changes_since(a.slot_id, a.slot_revision - 1, a.slot_revision)) end,
    'previous_response', case when p.member_id = a.member_id then p.response end,
    'previous_assignment_ids', app.duties_previous_assignment_ids(a.assignment_id),
    'notes_updated_at', (select app.cmd_utc(t.ts) from (
                           select app.duties_notes_updated_at(a.slot_id, a.slot_revision) as ts) t
                          where t.ts is not null))
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
    join app.duties_departments d on d.department_id = o.department_id
    left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
   where a.assignment_id = p_assignment_id;
$$;

create or replace function app.duties_leader_board()
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
  select jsonb_build_object('departments', coalesce(jsonb_agg(x.obj order by x.name, x.department_id),
                                                    '[]'::jsonb))
    into v_result
    from (
      select d.department_id, d.name, c.capacity, jsonb_build_object(
               'department_id', d.department_id,
               'name', d.name,
               'capacity', coalesce(c.capacity, 'pastor'),
               'can_publish', c.capacity is not null,
               'members', app.duties_roster(d.department_id, false),
               'duties', coalesce((
                 select jsonb_agg(app.duties_occurrence_json(o.occurrence_id, c.capacity is not null)
                                  order by o.starts_at, o.occurrence_id)
                   from (select o2.occurrence_id, o2.starts_at from app.duties_occurrences o2
                          where o2.department_id = d.department_id
                            and o2.occurrence_state = 'published'
                            and o2.starts_at > now() - interval '30 days'
                          order by o2.starts_at limit 200) o), '[]'::jsonb),
               'duties_truncated', (select count(*) > 200 from app.duties_occurrences o3
                                     where o3.department_id = d.department_id
                                       and o3.occurrence_state = 'published'
                                       and o3.starts_at > now() - interval '30 days')) as obj
        from app.duties_departments d
        cross join lateral (select app.duties_manage_capacity(v_member, d.department_id) as capacity) c
       where (c.capacity is not null or v_pastor)
         and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- One occurrence on the rota grid (no member notes): positions with the draft assignee or the
-- current assignment and whether that person can still serve; `confirmed` of `required` counts
-- current accepted positions over all positions.
create function app.duties_rota_occurrence_json(p_occurrence_id uuid)
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
                          'available', app.duties_can_serve(s.draft_member_id, o.department_id)) end,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'revision', a.revision,
                          'available', app.duties_can_serve(a.member_id, o.department_id))
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

create function app.duties_series_json(p_series_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'series_id', r.series_id,
    'department_id', r.department_id,
    'duty_name', r.duty_name,
    'every', r.every,
    'interval', r.every_interval,
    'from_date', to_char(r.from_date, 'YYYY-MM-DD'),
    'until_date', to_char(r.until_date, 'YYYY-MM-DD'),
    'start_time', to_char(r.start_time, 'HH24:MI'),
    'end_time', to_char(r.end_time, 'HH24:MI'),
    'reporting_time', to_char(r.reporting_time, 'HH24:MI'),
    'location', r.location,
    'instructions', r.instructions,
    'topic', r.topic,
    'scripture', r.scripture,
    'event_ref', r.event_ref,
    'positions', to_jsonb(r.positions),
    'zone', r.zone,
    'revision', r.revision,
    'draft_slots', (select count(*) from app.duties_occurrences o
                      join app.duties_slots s on s.occurrence_id = o.occurrence_id
                     where o.series_id = r.series_id and o.occurrence_state = 'draft'
                       and app.duties_occurrence_start(o) > now()),
    'occurrences', coalesce((
      select jsonb_agg(app.duties_rota_occurrence_json(o.occurrence_id)
                       order by o.series_date, o.occurrence_id)
        from app.duties_occurrences o where o.series_id = r.series_id), '[]'::jsonb))
    from app.duties_series r
   where r.series_id = p_series_id;
$$;

-- The rota grid: the departments the caller leads or deputises (Admin: all, may manage; Pastor:
-- all, read only), each with its roster (`app_account` / `no_login` only) and its series that
-- end 30 days ago or later (at most 50, `series_truncated`), drafts and cancelled occurrences
-- included. No member notes.
create function app.duties_rota()
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
  select jsonb_build_object('departments', coalesce(jsonb_agg(x.obj order by x.name, x.department_id),
                                                    '[]'::jsonb))
    into v_result
    from (
      select d.department_id, d.name, jsonb_build_object(
               'department_id', d.department_id,
               'name', d.name,
               'capacity', coalesce(c.capacity, 'pastor'),
               'can_manage', c.capacity is not null,
               'members', app.duties_roster(d.department_id, false),
               'series', coalesce((
                 select jsonb_agg(app.duties_series_json(r.series_id) order by r.from_date, r.series_id)
                   from (select r2.series_id, r2.from_date from app.duties_series r2
                          where r2.department_id = d.department_id
                            and r2.until_date >= (now() at time zone r2.zone)::date - 30
                          order by r2.from_date, r2.series_id limit 50) r), '[]'::jsonb),
               'series_truncated', (select count(*) > 50 from app.duties_series r3
                                     where r3.department_id = d.department_id
                                       and r3.until_date >= (now() at time zone r3.zone)::date - 30)) as obj
        from app.duties_departments d
        cross join lateral (select app.duties_manage_capacity(v_member, d.department_id) as capacity) c
       where (c.capacity is not null or v_pastor)
         and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_rota()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_rota();
$$;

comment on function api.duties_rota() is
  'Story 4.3: rota series with draft, published and cancelled occurrences, positions, draft '
  'assignees and confirmed-of-required counts for the departments the caller manages (Pastor: '
  'read only).';

-- ---------------------------------------------------------------------------------------------
-- Reminder source: cancellation notice (3.2 contract)
-- ---------------------------------------------------------------------------------------------

-- Source check (replaced): current or superseded at its revision while the occurrence is
-- published (4.2), and a cancelled assignment at its final revision (it never changes again), so
-- the cancellation notice can be keyed to it.
create or replace function app.duties_assignment_source_check(p_source jsonb)
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
    return '{"current": false}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', ((v_row.assignment_state in ('current', 'superseded')
                 and v_row.occurrence_state = 'published')
                or (v_row.assignment_state = 'cancelled' and v_row.end_reason = 'cancelled'))
               and v_row.revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision);
end;
$$;

-- duty_cancelled: current while this cancelled assignment is at that revision; actionable until
-- the duty would have started; only its member is eligible.
create function app.duties_cancelled_reminder_check(p_key jsonb)
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
    'current', v_assignment.assignment_state = 'cancelled' and v_assignment.end_reason = 'cancelled'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_assignment.revision,
    'actionable', app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id');
end;
$$;

select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_cancelled');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_cancelled',
  'app.duties_cancelled_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty cancelled",
    "body": "One of your duties was cancelled. Open My duties to see what is still yours.",
    "link": "/duties"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Commands: create a series (drafts)
-- ---------------------------------------------------------------------------------------------

-- duties.create_series {department_id, duty_name, every: day|week|month, interval?, from_date,
-- until_date, start_time, end_time?, reporting_time?, location?, instructions?, topic?,
-- scripture?, event_ref?, positions: [name, ...], exceptions?: [date, ...]}; expected null. The
-- department's leader or deputy, or an Admin. Dates and times are church-local (Q2 zone); the
-- occurrences are expanded by the shared 3.3 calculation and created as drafts (no assignment,
-- no notice). An end time at or before the start time ends on the next day.
create function app.duties_create_series(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_department_id uuid;
  v_name text;
  v_location text;
  v_instructions text;
  v_topic text;
  v_scripture text;
  v_event uuid;
  v_from date;
  v_until date;
  v_start time;
  v_end time;
  v_reporting time;
  v_interval integer := 1;
  v_positions text[];
  v_exceptions date[] := '{}';
  v_capacity text;
  v_policy jsonb;
  v_zone text;
  v_today date;
  v_list jsonb;
  v_series uuid;
  v_occurrence uuid;
  v_date date;
  v_starts timestamptz;
  v_count integer := 0;
  x jsonb;
  i integer;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['department_id', 'duty_name', 'every', 'interval', 'from_date', 'until_date',
                      'start_time', 'end_time', 'reporting_time', 'location', 'instructions',
                      'topic', 'scripture', 'event_ref', 'positions', 'exceptions']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  select t.errors, t.value into v_errors, v_location
    from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_instructions
    from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_topic
    from app.duties_text(p_payload, 'topic', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_scripture
    from app.duties_text(p_payload, 'scripture', false, 120, false, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'event_ref'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_event from app.duties_uuid(p_payload, 'event_ref', v_errors) t;
  end if;
  if jsonb_typeof(p_payload -> 'every') is distinct from 'string'
     or not app.duties_state_ok('series_every', p_payload ->> 'every') then
    v_errors := v_errors || jsonb_build_object('every',
                  case when p_payload ? 'every' then 'invalid' else 'required' end);
  end if;
  if p_payload ? 'interval' then
    if app.contract_integer_in(p_payload -> 'interval', 1, 52) then
      v_interval := (p_payload ->> 'interval')::integer;
    else
      v_errors := v_errors || '{"interval": "out_of_range"}';
    end if;
  end if;
  select t.errors, t.value into v_errors, v_from from app.duties_local_date(p_payload, 'from_date', v_errors) t;
  select t.errors, t.value into v_errors, v_until from app.duties_local_date(p_payload, 'until_date', v_errors) t;
  select t.errors, t.value into v_errors, v_start
    from app.duties_local_time(p_payload, 'start_time', true, v_errors) t;
  select t.errors, t.value into v_errors, v_end
    from app.duties_local_time(p_payload, 'end_time', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reporting
    from app.duties_local_time(p_payload, 'reporting_time', false, v_errors) t;
  if v_start is not null and v_reporting is not null and v_reporting > v_start then
    v_errors := v_errors || '{"reporting_time": "after_start"}';
  end if;
  -- Positions: 1..10 distinct single-line names.
  if jsonb_typeof(p_payload -> 'positions') is distinct from 'array'
     or jsonb_array_length(p_payload -> 'positions') = 0 then
    v_errors := v_errors || jsonb_build_object('positions',
                  case when p_payload ? 'positions' and jsonb_typeof(p_payload -> 'positions') <> 'array'
                       then 'invalid' else 'required' end);
  elsif jsonb_array_length(p_payload -> 'positions') > 10 then
    v_errors := v_errors || '{"positions": "too_many"}';
  else
    v_positions := '{}';
    for x in select e from jsonb_array_elements(p_payload -> 'positions') e loop
      declare
        v_pe jsonb := '{}'::jsonb;
        v_pn text;
      begin
        select t.errors, t.value into v_pe, v_pn
          from app.duties_text(jsonb_build_object('p', x), 'p', true, 60, false, v_pe) t;
        if v_pe <> '{}'::jsonb then
          v_positions := null;
          exit;
        end if;
        v_positions := array_append(v_positions, v_pn);
      end;
    end loop;
    if v_positions is null then
      v_errors := v_errors || '{"positions": "invalid"}';
    elsif not app.duties_positions_ok(v_positions) then
      v_errors := v_errors || '{"positions": "duplicate"}';
    end if;
  end if;
  if p_payload ? 'exceptions' then
    if jsonb_typeof(p_payload -> 'exceptions') <> 'array'
       or jsonb_array_length(p_payload -> 'exceptions') > 366 then
      v_errors := v_errors || '{"exceptions": "invalid"}';
    else
      for i in 0 .. jsonb_array_length(p_payload -> 'exceptions') - 1 loop
        declare
          v_xe jsonb := '{}'::jsonb;
          v_xd date;
        begin
          select t.errors, t.value into v_xe, v_xd
            from app.duties_local_date(jsonb_build_object('d', p_payload -> 'exceptions' -> i), 'd', v_xe) t;
          if v_xe <> '{}'::jsonb then
            v_errors := v_errors || '{"exceptions": "invalid"}';
            exit;
          end if;
          v_exceptions := array_append(v_exceptions, v_xd);
        end;
      end loop;
    end if;
  end if;
  if v_from is not null and v_until is not null then
    if v_until < v_from then
      v_errors := v_errors || '{"until_date": "before_from"}';
    elsif v_until > v_from + 366 then
      v_errors := v_errors || '{"until_date": "out_of_range"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- The church zone and policy version (Q2). Closed in production: unavailable, nothing written.
  v_policy := app.notifications_policy();
  v_zone := v_policy ->> 'zone';
  v_today := (now() at time zone v_zone)::date;
  if v_until < v_today then
    perform app.cmd_fail('validation_failed', '{"until_date": "past"}');
  elsif v_from > v_today + 731 then
    perform app.cmd_fail('validation_failed', '{"from_date": "out_of_range"}');
  end if;
  perform 1 from app.duties_departments d
   where d.department_id = v_department_id and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.duties_manage_capacity(v_actor.member_id, v_department_id);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  -- The shared church-local recurrence (exception dates skipped); future starts only.
  v_list := app.notifications_occurrences(v_policy,
              jsonb_build_object('local_start', to_char(v_from + v_start, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                 'every', p_payload ->> 'every', 'interval', v_interval,
                                 'exceptions', to_jsonb(array(select to_char(e, 'YYYY-MM-DD')
                                                               from unnest(v_exceptions) e))),
              -- The window starts at the first date (or now, when later): at most 367 days, so
              -- the shared calculation's 400-day bound is never reached by a valid series.
              greatest(now(), app.duties_wall(v_from, '00:00', v_zone)),
              app.duties_wall(v_until, v_start, v_zone));
  select coalesce(jsonb_agg(e order by e ->> 'starts_at'), '[]'::jsonb) into v_list
    from jsonb_array_elements(v_list) e
   where app.duties_wall(left(e ->> 'local', 10)::date, coalesce(v_reporting, v_start), v_zone) > now();
  if jsonb_array_length(v_list) = 0 then
    perform app.cmd_fail('validation_failed', '{"from_date": "no_occurrences"}');
  elsif jsonb_array_length(v_list) > 60 then
    perform app.cmd_fail('validation_failed', '{"until_date": "too_many"}');
  end if;
  insert into app.duties_series (department_id, duty_name, every, every_interval, from_date,
                                 until_date, start_time, end_time, reporting_time, location,
                                 instructions, topic, scripture, event_ref, positions, exceptions,
                                 zone, policy_version, created_by_member, created_by_account)
  values (v_department_id, v_name, p_payload ->> 'every', v_interval, v_from, v_until, v_start,
          v_end, v_reporting, v_location, v_instructions, v_topic, v_scripture, v_event,
          v_positions, v_exceptions, v_zone, (v_policy ->> 'version')::integer, v_actor.member_id,
          v_actor.account_id)
  returning series_id into v_series;
  for x in select e from jsonb_array_elements(v_list) e loop
    v_date := left(x ->> 'local', 10)::date;
    v_starts := (x ->> 'starts_at')::timestamptz;
    v_occurrence := null;
    insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, reporting_at,
                                        location, instructions, topic, scripture, event_ref,
                                        occurrence_state, series_id, series_date,
                                        created_by_member, created_by_account)
    values (v_department_id, v_name, v_starts,
            case when v_end is not null
                 then app.duties_wall(v_date + case when v_end <= v_start then 1 else 0 end, v_end, v_zone) end,
            case when v_reporting is not null then app.duties_wall(v_date, v_reporting, v_zone) end,
            v_location, v_instructions, v_topic, v_scripture, v_event, 'draft', v_series, v_date,
            v_actor.member_id, v_actor.account_id)
    on conflict (series_id, series_date) where series_id is not null do nothing
    returning occurrence_id into v_occurrence;
    if v_occurrence is not null then
      insert into app.duties_slots (occurrence_id, position_no, position_name)
      select v_occurrence, p.n, p.name from unnest(v_positions) with ordinality p(name, n);
      v_count := v_count + 1;
    end if;
  end loop;
  perform app.duties_audit_series_event('series_created', v_actor.member_id, v_actor.account_id,
                                        v_capacity, 'duties.create_series', v_department_id, v_series,
                                        null, null, null, null, 1);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series, 'revision', 1,
    -- Ids, revisions and counts only; clients read the rota again.
    'data', jsonb_build_object('series_id', v_series, 'department_id', v_department_id,
                               'revision', 1, 'occurrences', v_count,
                               'draft_slots', v_count * cardinality(v_positions)));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: positions and publishing
-- ---------------------------------------------------------------------------------------------

-- Locks a series occurrence's department, checks the manager and locks the occurrence (the
-- shared prologue of the occurrence commands). Returns the locked row and the capacity.
create function app.duties_lock_occurrence(p_actor_member uuid, p_occurrence_id uuid,
                                           p_expected_revision bigint,
                                           out occ app.duties_occurrences, out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_department uuid;
begin
  select o.department_id into v_department from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  perform 1 from app.duties_departments d
   where d.department_id = v_department and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  capacity := app.duties_manage_capacity(p_actor_member, v_department);
  if capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if (select o.series_id from app.duties_occurrences o where o.occurrence_id = p_occurrence_id) is not null then
    perform 1 from app.duties_series r
     where r.series_id = (select o.series_id from app.duties_occurrences o
                           where o.occurrence_id = p_occurrence_id) for share;
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

-- duties.assign_slot {slot_id, member_id, response_deadline?}; expected = the occurrence
-- revision. A draft position: member_id (or null to clear) is the planned assignee; no
-- assignment, no notice. A published position: member_id (required) is asked with the answer-by
-- response_deadline; a current assignment of someone else is superseded (4.2 rules: their answer
-- kept, their jobs cancelled, a released notice).
create function app.duties_assign_slot(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_slot_id uuid;
  v_member uuid;
  v_deadline timestamptz;
  v_occurrence uuid;
  v_lock record;
  v_occ app.duties_occurrences;
  v_slot app.duties_slots;
  v_revision bigint;
  v_change jsonb;
  v_notified jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['slot_id', 'member_id', 'response_deadline']);
  select t.errors, t.value into v_errors, v_slot_id from app.duties_uuid(p_payload, 'slot_id', v_errors) t;
  if not p_payload ? 'member_id' then
    v_errors := v_errors || '{"member_id": "required"}';
  elsif jsonb_typeof(p_payload -> 'member_id') <> 'null' then
    select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_payload, 'response_deadline', false, v_errors) t;
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
  if v_occ.occurrence_state = 'draft' then
    if p_payload ? 'response_deadline' and v_deadline is not null then
      perform app.cmd_fail('validation_failed', '{"response_deadline": "draft"}');
    end if;
    if v_member is not null and not app.duties_can_serve(v_member, v_occ.department_id) then
      perform 1 from app.duties_department_members dm
       where dm.department_id = v_occ.department_id and dm.member_id = v_member and dm.ended_at is null;
      if not found then
        perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
      end if;
      perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
    end if;
    if v_member is not null then
      perform 1 from app.duties_department_members dm
       where dm.department_id = v_occ.department_id and dm.member_id = v_member
         and dm.ended_at is null for share;
    end if;
    select s.* into v_slot from app.duties_slots s where s.slot_id = v_slot_id for update;
    if v_slot.draft_member_id is not distinct from v_member then
      perform app.cmd_fail('validation_failed', '{"slot_id": "unchanged"}');
    end if;
    update app.duties_slots s set draft_member_id = v_member where s.slot_id = v_slot_id;
    update app.duties_occurrences o set revision = o.revision + 1
     where o.occurrence_id = v_occ.occurrence_id returning o.revision into v_revision;
    perform app.duties_audit_series_event('draft_assigned', v_actor.member_id, v_actor.account_id,
                                          v_lock.capacity, 'duties.assign_slot', v_occ.department_id,
                                          v_occ.series_id, v_occ.occurrence_id, null, v_member, null,
                                          v_revision);
    return jsonb_build_object(
      'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occ.occurrence_id,
      'revision', v_revision,
      'data', jsonb_build_object('occurrence_id', v_occ.occurrence_id, 'revision', v_revision,
                                 'slot_id', v_slot_id, 'state', 'draft',
                                 'draft_assigned', v_member is not null));
  end if;
  if v_member is null then
    perform app.cmd_fail('validation_failed', '{"member_id": "required"}');
  end if;
  v_change := app.duties_apply_change(v_occ, v_occ, v_slot_id, v_member, true, v_deadline,
                                      'response_deadline', v_actor.member_id, v_actor.account_id,
                                      v_lock.capacity, 'duties.assign_slot', false);
  v_notified := app.duties_notify(v_change -> 'ops');
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occ.occurrence_id,
    'revision', (v_change ->> 'revision')::bigint,
    'data', jsonb_build_object(
              'occurrence_id', v_occ.occurrence_id, 'revision', (v_change ->> 'revision')::bigint,
              'slot_id', v_slot_id, 'state', 'published', 'slot_revision', v_change -> 'slot_revision',
              'assignment_id', v_change -> 'assignment_id',
              'assignment_revision', v_change -> 'assignment_revision',
              'superseded_assignment_id', v_change -> 'superseded_assignment_id',
              'response', v_change -> 'response',
              'notice_queued', (v_notified ->> 'queued')::integer > 0));
end;
$$;

-- Locks a series for a series command: department FOR SHARE, the manager, the series FOR UPDATE
-- and its revision.
create function app.duties_lock_series(p_actor_member uuid, p_series_id uuid, p_expected_revision bigint,
                                       out series app.duties_series, out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_department uuid;
begin
  select r.department_id into v_department from app.duties_series r where r.series_id = p_series_id;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  perform 1 from app.duties_departments d
   where d.department_id = v_department and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  capacity := app.duties_manage_capacity(p_actor_member, v_department);
  if capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  select r.* into series from app.duties_series r where r.series_id = p_series_id for update;
  if series.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, series.revision);
  end if;
end;
$$;

-- duties.publish_drafts {series_id, slot_count, deadline_before}; expected = the series
-- revision. "Publish N draft slots": every draft occurrence of the series that has not started
-- is published; slot_count must be that number of positions (`conflict {"slot_count":
-- "changed"}` otherwise). Each planned assignee gets a pending assignment with the answer-by
-- (reporting or start) - deadline_before in church time and one new-duty notice; positions
-- without one publish unfilled. All or nothing.
create function app.duties_publish_drafts(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_occurrences integer := 0;
  v_assignments integer := 0;
  v_notified jsonb;
  v_request uuid;
  v_unavailable uuid;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['series_id', 'slot_count', 'deadline_before']);
  select t.errors, t.value into v_errors, v_series_id from app.duties_uuid(p_payload, 'series_id', v_errors) t;
  if not app.contract_integer_in(p_payload -> 'slot_count', 1, 600) then
    v_errors := v_errors || jsonb_build_object('slot_count',
                  case when p_payload ? 'slot_count' then 'invalid' else 'required' end);
  end if;
  select t.errors, t.value into v_errors, v_lead
    from app.duties_lead(p_payload, 'deadline_before', true, v_errors) t;
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
  -- The planned people's memberships are share-locked first, then everything is checked
  -- before anything is written.
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
    if app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone) <= now() then
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
    v_deadline := app.notifications_shift(app.duties_occurrence_start(v_occ), v_lead, -1, v_series.zone);
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
                                            assigned_by_account)
        values (v_slot.slot_id, v_slot.draft_member_id, v_deadline, v_actor.member_id,
                v_actor.account_id)
        returning assignment_id into v_assignment;
        v_assignments := v_assignments + 1;
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
            'recipient_member_id', v_slot.draft_member_id, 'reminder_kind', 'duty_assigned',
            'scheduled_at', app.cmd_utc(now()))));
      end if;
      update app.duties_slots s set draft_member_id = null where s.slot_id = v_slot.slot_id;
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
  update app.duties_series r set revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id returning r.revision into v_revision;
  -- Notifications last (AD-2). Q2 closed in production -> unavailable, and everything rolls back.
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'occurrences', v_occurrences, 'slots', v_count,
                               'assignments', v_assignments,
                               'notices_queued', (v_notified ->> 'queued')::integer));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: this occurrence (revise_duty, replaced) and this and future (revise_series)
-- ---------------------------------------------------------------------------------------------

-- duties.revise_duty (replaced) {occurrence_id, duty_name?, starts_at?, ends_at?, reporting_at?,
-- location?, instructions?, topic?, scripture?, event_ref?, member_id?, response_deadline?};
-- expected = the occurrence revision. "This occurrence": every position changes together
-- (4.2 rules per position); member_id only for a one-position published duty. A draft is
-- edited in place (no revision rows, no notice; no answer-by).
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
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['occurrence_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'topic', 'scripture', 'event_ref', 'member_id',
                      'response_deadline']);
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
    -- As in 4.2: a time change of a published duty is material, so its answer-by is reported
    -- with the time errors.
    if v_errors <> '{}'::jsonb and v_occ.occurrence_state = 'published' then
      if not p_payload ? 'response_deadline' then
        v_errors := v_errors || '{"response_deadline": "required"}';
      elsif v_deadline <= now() then
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

  v_change := app.duties_apply_change(v_occ, v_new, v_slot, v_member, p_payload ? 'member_id',
                                      v_deadline, 'response_deadline', v_actor.member_id,
                                      v_actor.account_id, v_lock.capacity, 'duties.revise_duty', false);
  v_notified := app.duties_notify(v_change -> 'ops');
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence_id,
    'revision', (v_change ->> 'revision')::bigint,
    -- Ids, revisions and states only (no names or text in the receipt).
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence_id, 'revision', (v_change ->> 'revision')::bigint,
              'change', v_change ->> 'change', 'slot_id', v_change -> 'slot_id',
              'slot_revision', v_change -> 'slot_revision', 'assignment_id', v_change -> 'assignment_id',
              'assignment_revision', v_change -> 'assignment_revision',
              'superseded_assignment_id', v_change -> 'superseded_assignment_id',
              'response', v_change -> 'response',
              'notice_queued', (v_notified ->> 'queued')::integer > 0));
end;
$$;

-- duties.revise_series {series_id, from_occurrence_id, duty_name?, start_time?, end_time?,
-- reporting_time?, location?, instructions?, topic?, scripture?, event_ref?, deadline_before?};
-- expected = the series revision. "This and future": the anchor occurrence and every later
-- occurrence of the series that has not started and is not cancelled take the given fields
-- (church-local times on each occurrence's own church-local date); earlier and started
-- occurrences are never changed. Drafts are edited in place; each published occurrence changes
-- every position together through the 4.2 engine, and a material change needs
-- deadline_before (answer-by = (reporting or start) - deadline_before, church time). The
-- series keeps the new values for its record.
create function app.duties_revise_series(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_series_id uuid;
  v_anchor_id uuid;
  v_lock record;
  v_series app.duties_series;
  v_anchor app.duties_occurrences;
  v_occ app.duties_occurrences;
  v_new app.duties_occurrences;
  v_name text;
  v_location text;
  v_instructions text;
  v_topic text;
  v_scripture text;
  v_event uuid;
  v_start time;
  v_end time;
  v_reporting time;
  v_lead text;
  v_date date;
  v_start_t time;
  v_deadline timestamptz;
  v_change jsonb;
  v_ops jsonb := '[]'::jsonb;
  v_notified jsonb;
  v_changed integer := 0;
  v_drafts integer := 0;
  v_material integer := 0;
  v_created integer := 0;
  v_revision bigint;
  v_capacity text;
  v_fail_code text;
  v_fail_detail text;
  v_fail_errors jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['series_id', 'from_occurrence_id', 'duty_name', 'start_time', 'end_time',
                      'reporting_time', 'location', 'instructions', 'topic', 'scripture',
                      'event_ref', 'deadline_before']);
  select t.errors, t.value into v_errors, v_series_id from app.duties_uuid(p_payload, 'series_id', v_errors) t;
  select t.errors, t.value into v_errors, v_anchor_id
    from app.duties_uuid(p_payload, 'from_occurrence_id', v_errors) t;
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
  if coalesce(jsonb_typeof(p_payload -> 'event_ref'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_event from app.duties_uuid(p_payload, 'event_ref', v_errors) t;
  end if;
  if p_payload ? 'start_time' then
    select t.errors, t.value into v_errors, v_start
      from app.duties_local_time(p_payload, 'start_time', true, v_errors) t;
  end if;
  if p_payload ? 'end_time' then
    select t.errors, t.value into v_errors, v_end
      from app.duties_local_time(p_payload, 'end_time', false, v_errors) t;
  end if;
  if p_payload ? 'reporting_time' then
    select t.errors, t.value into v_errors, v_reporting
      from app.duties_local_time(p_payload, 'reporting_time', false, v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_lead
    from app.duties_lead(p_payload, 'deadline_before', false, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_series(v_actor.member_id, v_series_id, p_expected_revision) l;
  v_series := v_lock.series;
  v_capacity := v_lock.capacity;
  select o.* into v_anchor from app.duties_occurrences o
   where o.occurrence_id = v_anchor_id and o.series_id = v_series_id;
  if not found then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "not_in_series"}');
  elsif v_anchor.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "cancelled"}');
  elsif app.duties_occurrence_start(v_anchor) <= now() then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "started"}');
  end if;
  -- The series keeps a reporting time no later than its start time.
  if coalesce(case when p_payload ? 'reporting_time' then v_reporting else v_series.reporting_time end,
              '00:00'::time)
     > coalesce(case when p_payload ? 'start_time' then v_start else v_series.start_time end, '23:59'::time) then
    perform app.cmd_fail('validation_failed', '{"reporting_time": "after_start"}');
  end if;
  -- Lock every target occurrence up front, in series date order (AD-2 lock order).
  perform 1 from app.duties_occurrences o
   where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
     and o.occurrence_state <> 'cancelled'
   order by o.series_date for update;

  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
                  and o.occurrence_state <> 'cancelled' and app.duties_occurrence_start(o) > now()
                order by o.series_date loop
    -- The occurrence's own church-local date (an occurrence moved on its own keeps its date).
    v_date := (v_occ.starts_at at time zone v_series.zone)::date;
    v_new := v_occ;
    if p_payload ? 'duty_name' then v_new.duty_name := v_name; end if;
    if p_payload ? 'location' then v_new.location := v_location; end if;
    if p_payload ? 'instructions' then v_new.instructions := v_instructions; end if;
    if p_payload ? 'topic' then v_new.topic := v_topic; end if;
    if p_payload ? 'scripture' then v_new.scripture := v_scripture; end if;
    if p_payload ? 'event_ref' then v_new.event_ref := v_event; end if;
    if p_payload ? 'start_time' then
      v_new.starts_at := app.duties_wall(v_date, v_start, v_series.zone);
    end if;
    v_start_t := (v_new.starts_at at time zone v_series.zone)::time;
    if p_payload ? 'reporting_time' then
      v_new.reporting_at := case when v_reporting is not null
                                 then app.duties_wall(v_date, v_reporting, v_series.zone) end;
    end if;
    if p_payload ? 'end_time' then
      v_new.ends_at := case when v_end is not null
                            then app.duties_wall(v_date + case when v_end <= v_start_t then 1 else 0 end,
                                                 v_end, v_series.zone) end;
    end if;
    if (v_new.starts_at, v_new.ends_at, v_new.reporting_at)
       is distinct from (v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at) then
      v_errors := app.duties_times_errors(v_new.starts_at, v_new.ends_at, v_new.reporting_at,
                                          array['start_time', 'end_time', 'reporting_time']);
      if v_errors <> '{}'::jsonb then
        -- The date that cannot take the change is named (ids only).
        perform app.cmd_fail('validation_failed', v_errors || jsonb_build_object(
          'occurrence:' || v_occ.occurrence_id, (select e.value #>> '{}' from jsonb_each(v_errors) e limit 1)));
      end if;
    end if;
    if v_occ.occurrence_state = 'draft' then
      if (v_new.duty_name, v_new.starts_at, v_new.ends_at, v_new.reporting_at, v_new.location,
          v_new.instructions, v_new.topic, v_new.scripture, v_new.event_ref)
         is distinct from
         (v_occ.duty_name, v_occ.starts_at, v_occ.ends_at, v_occ.reporting_at, v_occ.location,
          v_occ.instructions, v_occ.topic, v_occ.scripture, v_occ.event_ref) then
        update app.duties_occurrences o
           set duty_name = v_new.duty_name, starts_at = v_new.starts_at, ends_at = v_new.ends_at,
               reporting_at = v_new.reporting_at, location = v_new.location,
               instructions = v_new.instructions, topic = v_new.topic,
               scripture = v_new.scripture, event_ref = v_new.event_ref, revision = o.revision + 1
         where o.occurrence_id = v_occ.occurrence_id;
        v_changed := v_changed + 1;
        v_drafts := v_drafts + 1;
      end if;
      continue;
    end if;
    v_deadline := case when v_lead is not null
                       then app.notifications_shift(coalesce(v_new.reporting_at, v_new.starts_at),
                                                    v_lead, -1, v_series.zone) end;
    begin
      v_change := app.duties_apply_change(v_occ, v_new, null, null, false, v_deadline,
                                          'deadline_before', v_actor.member_id, v_actor.account_id,
                                          v_capacity, 'duties.revise_series', true);
    exception when sqlstate 'PCMD1' then
      -- A refusal for one date (an assignee who can no longer serve, an answer-by that has
      -- passed) names that date (ids only) so the leader can fix it.
      get stacked diagnostics v_fail_code = message_text, v_fail_detail = pg_exception_detail;
      v_fail_errors := coalesce(v_fail_detail::jsonb -> 'field_errors', '{}'::jsonb);
      if v_fail_code = 'validation_failed' and v_fail_errors <> '{}'::jsonb then
        perform app.cmd_fail('validation_failed', v_fail_errors || jsonb_build_object(
          'occurrence:' || v_occ.occurrence_id,
          (select e.value #>> '{}' from jsonb_each(v_fail_errors) e limit 1)));
      end if;
      raise;
    end;
    if v_change is not null then
      v_changed := v_changed + 1;
      if v_change ->> 'change' = 'material' then
        v_material := v_material + 1;
      end if;
      v_created := v_created + (v_change ->> 'assignments_created')::integer;
      v_ops := v_ops || (v_change -> 'ops');
    end if;
  end loop;
  if v_changed = 0 then
    perform app.cmd_fail('validation_failed', '{"series_id": "unchanged"}');
  end if;
  update app.duties_series r
     set duty_name = case when p_payload ? 'duty_name' then v_name else r.duty_name end,
         start_time = case when p_payload ? 'start_time' then v_start else r.start_time end,
         end_time = case when p_payload ? 'end_time' then v_end else r.end_time end,
         reporting_time = case when p_payload ? 'reporting_time' then v_reporting else r.reporting_time end,
         location = case when p_payload ? 'location' then v_location else r.location end,
         instructions = case when p_payload ? 'instructions' then v_instructions else r.instructions end,
         topic = case when p_payload ? 'topic' then v_topic else r.topic end,
         scripture = case when p_payload ? 'scripture' then v_scripture else r.scripture end,
         event_ref = case when p_payload ? 'event_ref' then v_event else r.event_ref end,
         revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id
  returning r.revision into v_revision;
  perform app.duties_audit_series_event('series_revised', v_actor.member_id, v_actor.account_id,
                                        v_capacity, 'duties.revise_series', v_series.department_id,
                                        v_series_id, v_anchor_id, null, null, null, v_revision);
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'from_occurrence_id', v_anchor_id, 'occurrences', v_changed,
                               'drafts', v_drafts, 'material', v_material,
                               'assignments', v_created,
                               'notices_queued', (v_notified ->> 'queued')::integer));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: cancellation
-- ---------------------------------------------------------------------------------------------

-- duties.cancel_occurrence {occurrence_id}; expected = the occurrence revision. One occurrence
-- of a series (draft or published) that has not started.
create function app.duties_cancel_occurrence(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select l.* into v_lock from app.duties_lock_occurrence(v_actor.member_id, v_occurrence_id, p_expected_revision) l;
  if (v_lock.occ).series_id is null then
    -- One-off duties are cancelled with the coverage tools (entry 9).
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "not_in_series"}');
  end if;
  v_result := app.duties_cancel_one(v_lock.occ, v_actor.member_id, v_actor.account_id,
                                    v_lock.capacity, 'duties.cancel_occurrence');
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

-- duties.cancel_series {series_id, from_occurrence_id}; expected = the series revision. The
-- anchor and every later occurrence of the series that has not started (this and future);
-- earlier and started occurrences are kept.
create function app.duties_cancel_series(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_series_id uuid;
  v_anchor_id uuid;
  v_lock record;
  v_anchor app.duties_occurrences;
  v_occ app.duties_occurrences;
  v_result jsonb;
  v_ops jsonb := '[]'::jsonb;
  v_notified jsonb;
  v_count integer := 0;
  v_assignments integer := 0;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['series_id', 'from_occurrence_id']);
  select t.errors, t.value into v_errors, v_series_id from app.duties_uuid(p_payload, 'series_id', v_errors) t;
  select t.errors, t.value into v_errors, v_anchor_id
    from app.duties_uuid(p_payload, 'from_occurrence_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select l.* into v_lock from app.duties_lock_series(v_actor.member_id, v_series_id, p_expected_revision) l;
  select o.* into v_anchor from app.duties_occurrences o
   where o.occurrence_id = v_anchor_id and o.series_id = v_series_id;
  if not found then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "not_in_series"}');
  elsif v_anchor.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "cancelled"}');
  elsif app.duties_occurrence_start(v_anchor) <= now() then
    perform app.cmd_fail('validation_failed', '{"from_occurrence_id": "started"}');
  end if;
  -- Lock every target occurrence up front, in series date order (AD-2 lock order).
  perform 1 from app.duties_occurrences o
   where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
     and o.occurrence_state <> 'cancelled'
   order by o.series_date for update;
  for v_occ in select o.* from app.duties_occurrences o
                where o.series_id = v_series_id and o.series_date >= v_anchor.series_date
                  and o.occurrence_state <> 'cancelled' and app.duties_occurrence_start(o) > now()
                order by o.series_date loop
    v_result := app.duties_cancel_one(v_occ, v_actor.member_id, v_actor.account_id,
                                      v_lock.capacity, 'duties.cancel_series');
    v_count := v_count + 1;
    v_assignments := v_assignments + (v_result ->> 'assignments_cancelled')::integer;
    v_ops := v_ops || (v_result -> 'ops');
  end loop;
  update app.duties_series r set revision = r.revision + 1, updated_at = now()
   where r.series_id = v_series_id returning r.revision into v_revision;
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object(
    'aggregate_type', 'duties_series', 'aggregate_id', v_series_id, 'revision', v_revision,
    'data', jsonb_build_object('series_id', v_series_id, 'revision', v_revision,
                               'from_occurrence_id', v_anchor_id, 'occurrences', v_count,
                               'assignments_cancelled', v_assignments,
                               'notices_queued', (v_notified ->> 'queued')::integer));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command entry point, authorizer and replay recheck (replaced: the 4.3 commands)
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
       'duties.revise_series', 'duties.cancel_occurrence', 'duties.cancel_series') then
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

-- Replay recheck (replaced): a series is in scope for a current manager of its department.
create or replace function app.duties_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_department uuid;
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
    select o.department_id into v_department from app.duties_occurrences o
     where o.occurrence_id = p_aggregate_id for share;
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
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
  );
end;
$$;

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.3: departments, publishing and revising duties, the assignee''s answer, and rota '
  'series (create_series, assign_slot, publish_drafts, revise_series, cancel_occurrence, '
  'cancel_series) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced: draft assignees cleared, series creators anonymised; no new row
-- deletions)
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
               or a.assigned_by_account = p_account_id)
        + (select count(*) from app.duties_occurrences o
            where o.created_by_member = p_member_id or o.created_by_account = p_account_id)
        + (select count(*) from app.duties_departments d
            where d.created_by_member = p_member_id or d.created_by_account = p_account_id)
        + (select count(*) from app.duties_series r
            where r.created_by_member = p_member_id or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_slots s where s.draft_member_id = p_member_id)
        + (select count(*) from app.duties_slot_revisions r
            where r.member_id = p_member_id or r.created_by_member = p_member_id
               or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_audit au
            where au.actor_member_id = p_member_id or au.member_id = p_member_id
               or au.actor_account_id = p_account_id))::integer;
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
    update app.duties_assignments a set member_id = v_nil, response_note = null
     where a.member_id = v_member;
    update app.duties_assignments a set responded_by_member = v_nil
     where a.responded_by_member = v_member;
    update app.duties_assignments a set assigned_by_member = v_nil
     where a.assigned_by_member = v_member;
    update app.duties_occurrences o set created_by_member = v_nil where o.created_by_member = v_member;
    update app.duties_departments d set created_by_member = v_nil where d.created_by_member = v_member;
    update app.duties_series r set created_by_member = v_nil where r.created_by_member = v_member;
    -- A planned (draft) position of the member becomes unassigned.
    update app.duties_slots s set draft_member_id = null where s.draft_member_id = v_member;
    update app.duties_slot_revisions r set member_id = v_nil where r.member_id = v_member;
    update app.duties_slot_revisions r set created_by_member = v_nil
     where r.created_by_member = v_member;
    update app.duties_audit au set actor_member_id = v_nil where au.actor_member_id = v_member;
    update app.duties_audit au set member_id = v_nil where au.member_id = v_member;
    if v_account is not null then
      update app.duties_department_members dm set added_by_account = v_nil
       where dm.added_by_account = v_account;
      update app.duties_assignments a set responded_by_account = v_nil
       where a.responded_by_account = v_account;
      update app.duties_assignments a set assigned_by_account = v_nil
       where a.assigned_by_account = v_account;
      update app.duties_occurrences o set created_by_account = v_nil
       where o.created_by_account = v_account;
      update app.duties_departments d set created_by_account = v_nil
       where d.created_by_account = v_account;
      update app.duties_series r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_slot_revisions r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1-4.3): erase or check the member''s Duties personal data.';

-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_positions_ok(text[]),
  app.duties_local_time(jsonb, text, boolean, jsonb),
  app.duties_local_date(jsonb, text, jsonb),
  app.duties_lead(jsonb, text, boolean, jsonb),
  app.duties_wall(date, time, text),
  app.duties_can_serve(uuid, uuid),
  app.duties_audit_series_event(text, uuid, uuid, text, text, uuid, uuid, uuid, uuid, uuid, text, bigint),
  app.duties_notify(jsonb),
  app.duties_apply_change(app.duties_occurrences, app.duties_occurrences, uuid, uuid, boolean,
                          timestamptz, text, uuid, uuid, text, text, boolean),
  app.duties_times_errors(timestamptz, timestamptz, timestamptz, text[]),
  app.duties_cancel_one(app.duties_occurrences, uuid, uuid, text, text),
  app.duties_rota_occurrence_json(uuid),
  app.duties_series_json(uuid),
  app.duties_rota(),
  api.duties_rota(),
  app.duties_cancelled_reminder_check(jsonb),
  app.duties_create_series(uuid, bigint, jsonb),
  app.duties_lock_occurrence(uuid, uuid, bigint),
  app.duties_assign_slot(uuid, bigint, jsonb),
  app.duties_lock_series(uuid, uuid, bigint),
  app.duties_publish_drafts(uuid, bigint, jsonb),
  app.duties_revise_series(uuid, bigint, jsonb),
  app.duties_cancel_occurrence(uuid, bigint, jsonb),
  app.duties_cancel_series(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.duties_rota() to authenticated;
grant execute on function api.duties_rota() to authenticated;

notify pgrst, 'reload schema';
