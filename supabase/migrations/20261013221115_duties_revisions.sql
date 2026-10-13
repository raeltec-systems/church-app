-- Revise assignments on material change and refuse stale responses (story 4.2; AD-2, AD-6, AD-8,
-- AC-10). A forward migration on the 4.1 Duties owner (20261013220239_duties_department_tracer.sql
-- is not edited). It adds:
--
--   * Immutable slot revisions (app.duties_slot_revisions): one row per published, material or
--     notes change of a slot, with a snapshot of the slot's fields, its assignee and the current
--     assignment at that revision. Rows are never updated, except that member deletion replaces
--     person ids with the nil UUID (trigger app.duties_slot_revision_guard). Existing 4.1 slots
--     get revision 1 (`published`).
--   * The assignment lifecycle: `current`, `superseded` (a material change replaced it) and
--     `cancelled` (vocabulary only; the cancelling command arrives with 4.3), with ended_at,
--     end_reason, the slot revision it answers and the assignment it supersedes. The answer, its
--     actor, time and provenance stay on the superseded row.
--   * Field classification (app.duties_slot_field_class): material = duty_name, starts_at (date
--     and start), ends_at, reporting_at, location, member_id (assignee); notes = instructions;
--     response_deadline belongs to the assignment (required with a material change, refused with
--     a notes-only change). Any slot field a later story adds must be classified here.
--   * duties.revise_duty {occurrence_id, <changed fields>} with expected = the occurrence
--     revision (the department's leader or deputy, or an Admin). A material change supersedes the
--     current assignment and creates a new pending one (new deadline, same or new assignee),
--     cancels the old assignment's pending jobs (`source_revised`) and enqueues a generic change
--     notice: `duty_changed` (same assignee), or `duty_assigned` to the new assignee and
--     `duty_released` to the old one. A notes-only change keeps the answer and enqueues
--     `duty_updated` to a pending or accepted assignee.
--   * duties.respond refuses an answer to a superseded assignment with `conflict` and the fields
--     changed since it (`{"assignment_id": "superseded", "<field>": "changed"}`), and to a
--     cancelled one with `{"assignment_id": "cancelled"}`.
--   * Reads: My duties shows what the replacing change changed, the member's earlier answer and the
--     earlier assignment ids (an old reminder link finds the current version); the leader board
--     shows each position's slot revision, the changes and the kept history.
--   * The deletion hook also anonymises slot revisions (no new row deletions: the 4.1 purge is
--     reused).
--
-- Lock order (AD-2): the actor's Identity grant rows FOR SHARE (authorizer) -> command receipt
-- -> department FOR SHARE -> occurrence FOR UPDATE -> department membership FOR SHARE -> slot
-- FOR UPDATE -> assignment FOR UPDATE -> Notifications (cancel, enqueue). duties.respond locks only
-- the assignment, so a racing revise and respond serialise on the assignment row: whichever
-- commits first wins, and the other sees the new state.
--
-- No destructive statements, no row deletions. No client table privileges; no new client grant.

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
    when 'occurrence_state' then p_value in ('published')
    when 'assignment_state' then p_value in ('current', 'superseded', 'cancelled')
    when 'assignment_end_reason' then p_value in ('revised', 'cancelled')
    when 'response' then p_value in ('pending', 'accepted', 'declined')
    when 'response_provenance' then p_value in ('member')
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member')
    when 'change_class' then p_value in ('published', 'material', 'notes')
    when 'slot_field' then p_value in ('duty_name', 'starts_at', 'ends_at', 'reporting_at',
                                       'location', 'member_id', 'instructions')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised')
    else false end;
$$;

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (stories 4.1, 4.2). Later stories widen them by replacing this function.';

-- Material or notes? Every slot field is classified here (spec: date, reporting/start/end time,
-- location, duty and assignee are material; instructions are notes). response_deadline is an
-- assignment field. Anything else is not revisable (null).
create function app.duties_slot_field_class(p_field text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_field in ('duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id')
      then 'material'
    when p_field = 'instructions' then 'notes'
    when p_field = 'response_deadline' then 'assignment'
  end;
$$;

comment on function app.duties_slot_field_class(text) is
  'Story 4.2: material or notes classification of each revisable slot field.';

create function app.duties_fields_ok(p_fields text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_fields is not null
     and not exists (select 1 from unnest(p_fields) f where not app.duties_state_ok('slot_field', f));
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

alter table app.duties_slots
  add column revision bigint not null default 1 check (revision >= 1);

alter table app.duties_assignments
  add column slot_revision bigint not null default 1 check (slot_revision >= 1),
  add column supersedes_assignment_id uuid references app.duties_assignments (assignment_id),
  add column ended_at timestamptz,
  add column end_reason text
    check (end_reason is null or app.duties_state_ok('assignment_end_reason', end_reason)),
  add constraint duties_assignments_lifecycle
    check ((assignment_state = 'current') = (ended_at is null)
           and (ended_at is null) = (end_reason is null));

create unique index duties_assignments_supersedes
  on app.duties_assignments (supersedes_assignment_id) where supersedes_assignment_id is not null;
create index duties_assignments_slot on app.duties_assignments (slot_id, assigned_at);

comment on column app.duties_assignments.slot_revision is
  'Story 4.2: the slot revision this assignment asks the member to answer.';

-- One immutable row per slot revision. Snapshot of the slot's fields and assignee at that
-- revision; changed_fields lists what changed against the previous revision.
create table app.duties_slot_revisions (
  slot_id uuid not null references app.duties_slots (slot_id),
  slot_revision bigint not null check (slot_revision >= 1),
  occurrence_id uuid not null references app.duties_occurrences (occurrence_id),
  occurrence_revision bigint not null check (occurrence_revision >= 1),
  change_class text not null check (app.duties_state_ok('change_class', change_class)),
  changed_fields text[] not null default '{}' check (app.duties_fields_ok(changed_fields)),
  duty_name text not null check (length(duty_name) between 1 and 80),
  starts_at timestamptz not null,
  ends_at timestamptz,
  reporting_at timestamptz,
  location text check (location is null or length(location) between 1 and 120),
  instructions text check (instructions is null or length(instructions) between 1 and 1000),
  member_id uuid,
  assignment_id uuid references app.duties_assignments (assignment_id),
  response_deadline timestamptz,
  created_by_member uuid not null,
  created_by_account uuid not null,
  command_request_id uuid,
  created_at timestamptz not null default now(),
  primary key (slot_id, slot_revision)
);

create index duties_slot_revisions_member on app.duties_slot_revisions (member_id);
create index duties_slot_revisions_occurrence on app.duties_slot_revisions (occurrence_id);

comment on table app.duties_slot_revisions is
  'owner: duties. Immutable slot revisions (story 4.2): what each published, material or notes '
  'change set, with the assignee and the current assignment at that revision.';

alter table app.duties_slot_revisions enable row level security;
revoke all on table app.duties_slot_revisions from public, anon, authenticated, service_role;

-- Immutable: only member deletion may replace a person id with the nil UUID.
create function app.duties_slot_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if (new.slot_id, new.slot_revision, new.occurrence_id, new.occurrence_revision, new.change_class,
      new.changed_fields, new.duty_name, new.starts_at, new.ends_at, new.reporting_at, new.location,
      new.instructions, new.assignment_id, new.response_deadline, new.command_request_id,
      new.created_at)
     is distinct from
     (old.slot_id, old.slot_revision, old.occurrence_id, old.occurrence_revision, old.change_class,
      old.changed_fields, old.duty_name, old.starts_at, old.ends_at, old.reporting_at, old.location,
      old.instructions, old.assignment_id, old.response_deadline, old.command_request_id,
      old.created_at)
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

create trigger duties_slot_revisions_immutable
  before update on app.duties_slot_revisions
  for each row execute function app.duties_slot_revision_guard();

-- An ended (superseded or cancelled) assignment is history: it is never changed again, except
-- that member deletion replaces person ids with the nil UUID and clears the note.
create function app.duties_assignment_history_guard()
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
      new.slot_revision, new.supersedes_assignment_id, new.ended_at, new.end_reason)
     is distinct from
     (old.assignment_id, old.slot_id, old.assignment_state, old.response, old.response_deadline,
      old.responded_at, old.response_provenance, old.revision, old.assigned_at,
      old.slot_revision, old.supersedes_assignment_id, old.ended_at, old.end_reason)
     or (new.member_id is distinct from old.member_id and new.member_id is distinct from v_nil)
     or (new.responded_by_member is distinct from old.responded_by_member
         and new.responded_by_member is distinct from v_nil)
     or (new.responded_by_account is distinct from old.responded_by_account
         and new.responded_by_account is distinct from v_nil)
     or (new.assigned_by_member is distinct from old.assigned_by_member
         and new.assigned_by_member is distinct from v_nil)
     or (new.assigned_by_account is distinct from old.assigned_by_account
         and new.assigned_by_account is distinct from v_nil)
     or (new.response_note is distinct from old.response_note and new.response_note is not null) then
    raise exception using errcode = 'P0001', message = 'ended duties assignments are immutable';
  end if;
  return new;
end;
$$;

create trigger duties_assignments_history_immutable
  before update on app.duties_assignments
  for each row execute function app.duties_assignment_history_guard();

-- Revision 1 (`published`) for every slot published before this story.
insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id, occurrence_revision,
                                       change_class, changed_fields, duty_name, starts_at, ends_at,
                                       reporting_at, location, instructions, member_id,
                                       assignment_id, response_deadline, created_by_member,
                                       created_by_account, created_at)
select s.slot_id, 1, o.occurrence_id, o.revision, 'published', '{}', o.duty_name, o.starts_at,
       o.ends_at, o.reporting_at, o.location, o.instructions, a.member_id, a.assignment_id,
       a.response_deadline, o.created_by_member, o.created_by_account, o.published_at
  from app.duties_slots s
  join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
  left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
 where not exists (select 1 from app.duties_slot_revisions r where r.slot_id = s.slot_id);

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The fields changed on a slot after revision p_after (up to p_upto when given), in a fixed order.
create function app.duties_changes_since(p_slot_id uuid, p_after bigint, p_upto bigint)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(x.f order by array_position(
           array['duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location', 'member_id',
                 'instructions'], x.f)), '{}')
    from (select distinct f
            from app.duties_slot_revisions r cross join unnest(r.changed_fields) f
           where r.slot_id = p_slot_id and r.slot_revision > p_after
             and (p_upto is null or r.slot_revision <= p_upto)) x;
$$;

-- The latest notes-only change of a slot after revision p_after (null when none).
create function app.duties_notes_updated_at(p_slot_id uuid, p_after bigint)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select max(r.created_at) from app.duties_slot_revisions r
   where r.slot_id = p_slot_id and r.slot_revision > p_after and r.change_class = 'notes';
$$;

-- The member's own earlier assignments of this position that this one (directly or through
-- other members' assignments, A -> B -> A) replaced, newest first; the chain is followed at most
-- 50 steps. Other members' assignment ids are never listed.
create function app.duties_previous_assignment_ids(p_assignment_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with recursive chain(assignment_id, member_id, supersedes, depth) as (
    select a.assignment_id, a.member_id, a.supersedes_assignment_id, 0
      from app.duties_assignments a where a.assignment_id = p_assignment_id
    union all
    select p.assignment_id, p.member_id, p.supersedes_assignment_id, c.depth + 1
      from chain c join app.duties_assignments p on p.assignment_id = c.supersedes
     where c.depth < 50)
  select coalesce(jsonb_agg(to_jsonb(c.assignment_id) order by c.depth), '[]'::jsonb)
    from chain c
   where c.depth > 0
     and c.member_id = (select a.member_id from app.duties_assignments a
                         where a.assignment_id = p_assignment_id);
$$;

-- Can Notifications address this member? (Not the nil UUID of an erased member.)
create function app.duties_notice_recipient(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_member_id is not null
     and exists (select 1 from app.identity_members m where m.member_id = p_member_id);
$$;

-- The changed fields as command field errors: {"<field>": "changed", ...}.
create function app.duties_changes_errors(p_fields text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(f, 'changed'), '{}'::jsonb) from unnest(p_fields) f;
$$;

-- ---------------------------------------------------------------------------------------------
-- Projections (replaced: history, slot revisions, changes)
-- ---------------------------------------------------------------------------------------------

-- One occurrence with its positions as a leader sees it. Each position has its slot revision,
-- its current assignment (with the fields changed by the revision that created it) and the
-- history of ended assignments (newest first, at most 20) with their kept answers. p_with_notes
-- false hides members' practical notes (Pastor oversight).
create or replace function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'department_id', o.department_id,
    'duty_name', o.duty_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'state', o.occurrence_state,
    'revision', o.revision,
    'published_at', app.cmd_utc(o.published_at),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
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

-- One assignment as its member sees it, with what the change that created it changed (when it
-- replaced the same member's earlier assignment on this position; null for a first assignment
-- or one taken over from someone else), the member's earlier answer,
-- the earlier assignment ids (so an old reminder link finds the current version) and the latest
-- notes-only update since this assignment.
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
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
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

-- ---------------------------------------------------------------------------------------------
-- Reminder kinds: change notices (3.2 contracts)
-- ---------------------------------------------------------------------------------------------

-- Source check (replaced): a current assignment at its revision, as in 4.1, and a superseded
-- one at its final revision (it never changes again), so the old assignee's released notice can
-- be keyed to it. The per-kind reminder checks still decide what is delivered and opened: the
-- new-duty, change and update notices need a current assignment.
create or replace function app.duties_assignment_source_check(p_source jsonb)
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
    return '{"current": false}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_row.assignment_state in ('current', 'superseded')
               and v_row.occurrence_state = 'published'
               and v_row.revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision);
end;
$$;

-- duty_updated (notes-only change): current while the assignment is current at that revision;
-- actionable while the duty has not started and the member has not declined.
create function app.duties_update_reminder_check(p_key jsonb)
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
                          and exists (select 1 from app.duties_department_members dm
                                       where dm.department_id = v_occurrence.department_id
                                         and dm.member_id = v_assignment.member_id
                                         and dm.ended_at is null));
end;
$$;

-- duty_released (the duty went to someone else): current while this superseded assignment is
-- at that revision and the position's current assignment is not the same member's; actionable
-- until the duty starts; only its member is eligible.
create function app.duties_released_reminder_check(p_key jsonb)
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
    'current', v_assignment.assignment_state = 'superseded'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint
               and not exists (select 1 from app.duties_assignments c
                                where c.slot_id = v_assignment.slot_id
                                  and c.assignment_state = 'current'
                                  and c.member_id = v_assignment.member_id),
    'revision', v_assignment.revision,
    'actionable', app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id');
end;
$$;

select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_changed');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_changed',
  'app.duties_assignment_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty changed",
    "body": "One of your duties changed. Open it to see what changed and answer again.",
    "link": "/duties/assignments/{source_id}"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_updated');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_updated',
  'app.duties_update_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty details updated",
    "body": "The details of one of your duties were updated. Open it to read them.",
    "link": "/duties/assignments/{source_id}"}'::jsonb);
select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_released');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_released',
  'app.duties_released_reminder_check(jsonb)'::regprocedure,
  '{"title": "Duty changed",
    "body": "A duty you were given has changed and is no longer assigned to you.",
    "link": "/duties"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Commands: revise and respond
-- ---------------------------------------------------------------------------------------------

-- duties.revise_duty {occurrence_id, duty_name?, starts_at?, ends_at?, reporting_at?, location?,
-- instructions?, member_id?, response_deadline?}; expected = the occurrence revision. The
-- department's leader or deputy, or an Admin, before the duty starts. Present keys are the
-- change (null clears an optional field); a value equal to the current one is no change.
create function app.duties_revise_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_occurrence_id uuid;
  v_department uuid;
  v_occ app.duties_occurrences;
  v_capacity text;
  v_name text;
  v_location text;
  v_instructions text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_deadline timestamptz;
  v_member uuid;
  v_slots integer;
  v_cur_member uuid;
  v_changed text[] := '{}';
  v_material boolean;
  v_class text;
  v_slot app.duties_slots;
  v_old app.duties_assignments;
  v_old_revision bigint;
  v_revision bigint;
  v_slot_revision bigint;
  v_current uuid;
  v_current_member uuid;
  v_current_revision bigint;
  v_current_deadline timestamptz;
  v_response text;
  v_superseded uuid;
  v_job jsonb;
  v_queued boolean := false;
  v_request uuid := app.cmd_current_request_id(p_actor, 'duties.revise_duty');
  v_in_department boolean;
  v_kind text;
  v_cancelled integer;
  v_k text;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['occurrence_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'member_id', 'response_deadline']);
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
  select o.department_id into v_department from app.duties_occurrences o
   where o.occurrence_id = v_occurrence_id;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  perform 1 from app.duties_departments d
   where d.department_id = v_department and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.duties_manage_capacity(v_actor.member_id, v_department);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  select o.* into v_occ from app.duties_occurrences o
   where o.occurrence_id = v_occurrence_id for update;
  if v_occ.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_occ.revision);
  end if;
  if app.duties_occurrence_start(v_occ) <= now() then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "started"}');
  end if;

  -- The merged values and what changed.
  v_name := case when p_payload ? 'duty_name' then v_name else v_occ.duty_name end;
  v_starts := case when p_payload ? 'starts_at' then v_starts else v_occ.starts_at end;
  v_ends := case when p_payload ? 'ends_at' then v_ends else v_occ.ends_at end;
  v_reporting := case when p_payload ? 'reporting_at' then v_reporting else v_occ.reporting_at end;
  v_location := case when p_payload ? 'location' then v_location else v_occ.location end;
  v_instructions := case when p_payload ? 'instructions' then v_instructions else v_occ.instructions end;
  select count(*)::integer into v_slots from app.duties_slots s where s.occurrence_id = v_occurrence_id;
  select a.member_id into v_cur_member
    from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
   where s.occurrence_id = v_occurrence_id and a.assignment_state = 'current'
   order by s.position_no limit 1;
  if p_payload ? 'member_id' and v_slots <> 1 then
    -- One assignee per occurrence only while occurrences have one position (4.3 adds positions).
    perform app.cmd_fail('validation_failed', '{"member_id": "unsupported"}');
  end if;
  v_member := case when p_payload ? 'member_id' then v_member else v_cur_member end;
  if v_name is distinct from v_occ.duty_name then
    v_changed := array_append(v_changed, 'duty_name');
  end if;
  if v_starts is distinct from v_occ.starts_at then
    v_changed := array_append(v_changed, 'starts_at');
  end if;
  if v_ends is distinct from v_occ.ends_at then
    v_changed := array_append(v_changed, 'ends_at');
  end if;
  if v_reporting is distinct from v_occ.reporting_at then
    v_changed := array_append(v_changed, 'reporting_at');
  end if;
  if v_location is distinct from v_occ.location then
    v_changed := array_append(v_changed, 'location');
  end if;
  if v_member is distinct from v_cur_member then
    v_changed := array_append(v_changed, 'member_id');
  end if;
  if v_instructions is distinct from v_occ.instructions then
    v_changed := array_append(v_changed, 'instructions');
  end if;
  v_material := exists (select 1 from unnest(v_changed) f
                         where app.duties_slot_field_class(f) = 'material');
  v_class := case when v_material then 'material' else 'notes' end;
  v_errors := '{}'::jsonb;
  if not v_material then
    if p_payload ? 'response_deadline' then
      v_errors := v_errors || '{"response_deadline": "not_material"}';
    elsif cardinality(v_changed) = 0 then
      v_errors := v_errors || '{"occurrence_id": "unchanged"}';
    end if;
  else
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
    -- A material change asks for a fresh answer by a new deadline (the leader's until entry 8).
    if not p_payload ? 'response_deadline' then
      v_errors := v_errors || '{"response_deadline": "required"}';
    elsif v_deadline <= now() then
      v_errors := v_errors || '{"response_deadline": "past"}';
    elsif v_deadline > coalesce(v_reporting, v_starts) then
      v_errors := v_errors || '{"response_deadline": "after_start"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if v_material and v_member is not null then
    perform 1 from app.duties_department_members dm
     where dm.department_id = v_department and dm.member_id = v_member and dm.ended_at is null
       for share;
    v_in_department := found;
    if not (v_in_department and app.duties_member_active(v_member)) then
      if not p_payload ? 'member_id' then
        -- The kept assignee was erased, left the department or is under deletion: a material
        -- change would ask someone who cannot answer, so it needs a new assignee (fail closed).
        perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
      elsif not v_in_department then
        perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
      else
        perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
      end if;
    end if;
  end if;

  update app.duties_occurrences o
     set duty_name = v_name, starts_at = v_starts, ends_at = v_ends, reporting_at = v_reporting,
         location = v_location, instructions = v_instructions, revision = o.revision + 1
   where o.occurrence_id = v_occurrence_id
  returning o.revision into v_revision;

  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = v_occurrence_id
                 order by s.position_no for update loop
    update app.duties_slots s set revision = s.revision + 1 where s.slot_id = v_slot.slot_id
    returning s.revision into v_slot_revision;
    select a.* into v_old from app.duties_assignments a
     where a.slot_id = v_slot.slot_id and a.assignment_state = 'current' for update;
    v_current := null;
    v_current_member := null;
    v_current_revision := null;
    v_current_deadline := null;
    v_response := null;
    if v_old.assignment_id is not null and v_material then
      update app.duties_assignments a
         set assignment_state = 'superseded', ended_at = now(), end_reason = 'revised',
             revision = a.revision + 1
       where a.assignment_id = v_old.assignment_id
      returning a.revision into v_old_revision;
      insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                          assigned_by_account, slot_revision,
                                          supersedes_assignment_id)
      values (v_slot.slot_id, coalesce(v_member, v_old.member_id), v_deadline, v_actor.member_id,
              v_actor.account_id, v_slot_revision, v_old.assignment_id)
      returning assignment_id, member_id, revision, response_deadline, response
           into v_current, v_current_member, v_current_revision, v_current_deadline, v_response;
      v_superseded := v_old.assignment_id;
    elsif v_old.assignment_id is not null then
      v_current := v_old.assignment_id;
      v_current_member := v_old.member_id;
      v_current_revision := v_old.revision;
      v_current_deadline := v_old.response_deadline;
      v_response := v_old.response;
    end if;
    insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                           occurrence_revision, change_class, changed_fields,
                                           duty_name, starts_at, ends_at, reporting_at, location,
                                           instructions, member_id, assignment_id,
                                           response_deadline, created_by_member,
                                           created_by_account, command_request_id)
    values (v_slot.slot_id, v_slot_revision, v_occurrence_id, v_revision, v_class, v_changed,
            v_name, v_starts, v_ends, v_reporting, v_location, v_instructions, v_current_member,
            v_current, v_current_deadline, v_actor.member_id, v_actor.account_id, v_request);
    perform app.duties_audit_event('duty_revised', v_actor.member_id, v_actor.account_id,
                                   v_capacity, 'duties.revise_duty', v_department,
                                   v_occurrence_id, v_current, v_current_member, v_class,
                                   v_revision);

    -- Notifications last (AD-2).
    if v_current is not null and v_material then
      perform app.notifications_cancel(jsonb_build_object(
        'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
        'reason', 'source_revised'));
      if app.duties_notice_recipient(v_current_member) then
        v_job := app.notifications_enqueue(jsonb_build_object(
          'source_type', 'duties_assignment', 'source_id', v_current, 'source_revision', 1,
          'recipient_member_id', v_current_member,
          'reminder_kind', case when v_current_member = v_old.member_id then 'duty_changed'
                                else 'duty_assigned' end,
          'scheduled_at', app.cmd_utc(now())));
        v_queued := coalesce((v_job ->> 'created')::boolean, false);
      end if;
      if v_current_member is distinct from v_old.member_id
         and app.duties_notice_recipient(v_old.member_id) then
        perform app.notifications_enqueue(jsonb_build_object(
          'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
          'source_revision', v_old_revision, 'recipient_member_id', v_old.member_id,
          'reminder_kind', 'duty_released', 'scheduled_at', app.cmd_utc(now())));
      end if;
    elsif v_current is not null and v_response in ('pending', 'accepted')
          and app.duties_notice_recipient(v_current_member) then
      -- One notice per assignment: any notice of it not yet sent (new duty, change or update) is
      -- replaced by one of the most telling kind (a new duty stays a new duty). The clock time
      -- keeps the new job's logical key distinct from the replaced one.
      v_kind := null;
      foreach v_k in array array['duty_assigned', 'duty_changed', 'duty_updated'] loop
        v_cancelled := (app.notifications_cancel(jsonb_build_object(
          'source_type', 'duties_assignment', 'source_id', v_current, 'reason', 'replaced',
          'reminder_kind', v_k)) ->> 'cancelled')::integer;
        if v_cancelled > 0 and v_kind is null then
          v_kind := v_k;
        end if;
      end loop;
      v_job := app.notifications_enqueue(jsonb_build_object(
        'source_type', 'duties_assignment', 'source_id', v_current,
        'source_revision', v_current_revision, 'recipient_member_id', v_current_member,
        'reminder_kind', coalesce(v_kind, 'duty_updated'),
        'scheduled_at', app.cmd_utc(clock_timestamp())));
      v_queued := coalesce((v_job ->> 'created')::boolean, false);
    end if;
  end loop;

  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence_id, 'revision', v_revision,
    -- Ids, revisions and states only (no names or text in the receipt).
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence_id, 'revision', v_revision, 'change', v_class,
              'slot_id', v_slot.slot_id, 'slot_revision', v_slot_revision,
              'assignment_id', v_current, 'assignment_revision', v_current_revision,
              'superseded_assignment_id', v_superseded, 'response', v_response,
              'notice_queued', v_queued));
end;
$$;

-- duties.publish_duty (replaced): as in 4.1, and it records slot revision 1 (`published`).
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
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_deadline timestamptz;
  v_capacity text;
  v_occurrence uuid;
  v_slot uuid;
  v_assignment uuid;
  v_job jsonb;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['department_id', 'duty_name', 'starts_at', 'ends_at', 'reporting_at',
                      'location', 'instructions', 'member_id', 'response_deadline']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_payload, 'duty_name', true, 80, false, v_errors) t;
  select t.errors, t.value into v_errors, v_location
    from app.duties_text(p_payload, 'location', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_instructions
    from app.duties_text(p_payload, 'instructions', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_starts
    from app.duties_instant(p_payload, 'starts_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_ends
    from app.duties_instant(p_payload, 'ends_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reporting
    from app.duties_instant(p_payload, 'reporting_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_payload, 'response_deadline', true, v_errors) t;
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
    -- The deadline is the leader's (4.1 has no default) and never later than the start.
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
  perform 1 from app.duties_department_members dm
   where dm.department_id = v_department_id and dm.member_id = v_member and dm.ended_at is null
     for share;
  if not found then
    perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
  end if;
  if not app.duties_member_active(v_member) then
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  insert into app.duties_occurrences (department_id, duty_name, starts_at, ends_at, reporting_at,
                                      location, instructions, created_by_member,
                                      created_by_account)
  values (v_department_id, v_name, v_starts, v_ends, v_reporting, v_location, v_instructions,
          v_actor.member_id, v_actor.account_id)
  returning occurrence_id into v_occurrence;
  insert into app.duties_slots (occurrence_id, position_no) values (v_occurrence, 1)
  returning slot_id into v_slot;
  insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                      assigned_by_account)
  values (v_slot, v_member, v_deadline, v_actor.member_id, v_actor.account_id)
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
  -- Notifications last (AD-2). Q2 closed in production -> unavailable, and everything rolls back.
  v_job := app.notifications_enqueue(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment, 'source_revision', 1,
    'recipient_member_id', v_member, 'reminder_kind', 'duty_assigned',
    'scheduled_at', app.cmd_utc(now())));
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', 1,
    -- Ids and states only (no names or text in the receipt); clients read the board again.
    'data', jsonb_build_object(
              'occurrence_id', v_occurrence, 'department_id', v_department_id, 'revision', 1,
              'slot_id', v_slot, 'assignment_id', v_assignment, 'assignment_revision', 1,
              'response', 'pending',
              'notice_queued', coalesce((v_job ->> 'created')::boolean, false)));
end;
$$;

-- duties.respond (replaced): as in 4.1, and an answer to a superseded assignment is refused
-- with `conflict` and the fields changed since it; a cancelled one with
-- `{"assignment_id": "cancelled"}`.
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
  v_changes text[];
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
  -- An old revision: refused with what changed from the change that replaced it onwards (the
  -- member saw every notes update while it was current), never the new assignee or their ids.
  -- When the position is the member's again (A -> B -> A), the assignee did not change for them.
  if v_assignment.assignment_state = 'superseded' then
    v_changes := app.duties_changes_since(v_assignment.slot_id,
      coalesce((select n.slot_revision - 1 from app.duties_assignments n
                 where n.supersedes_assignment_id = v_assignment.assignment_id),
               v_assignment.slot_revision), null);
    if exists (select 1 from app.duties_assignments c
                where c.slot_id = v_assignment.slot_id and c.assignment_state = 'current'
                  and c.member_id = v_actor.member_id) then
      v_changes := array_remove(v_changes, 'member_id');
    end if;
    perform app.cmd_fail('conflict',
      '{"assignment_id": "superseded"}'::jsonb || app.duties_changes_errors(v_changes));
  end if;
  if v_assignment.assignment_state <> 'current' then
    perform app.cmd_fail('conflict', '{"assignment_id": "cancelled"}');
  end if;
  if v_assignment.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_assignment.revision);
  end if;
  if v_assignment.response <> 'pending' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', v_assignment.revision);
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
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

-- ---------------------------------------------------------------------------------------------
-- Command entry point and authorizer (replaced: duties.revise_duty added)
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
       'duties.revise_duty') then
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
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
  );
end;
$$;

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.2: departments (duties.create_department, add_member), publishing a one-position '
  'duty (duties.publish_duty), revising it (duties.revise_duty) and the assignee''s answer '
  '(duties.respond) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (replaced: slot revisions are anonymised too; no new row deletions)
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
      update app.duties_slot_revisions r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1, 4.2): erase or check the member''s Duties personal data.';

-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep their 4.1 privileges)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_slot_field_class(text),
  app.duties_fields_ok(text[]),
  app.duties_slot_revision_guard(),
  app.duties_assignment_history_guard(),
  app.duties_notice_recipient(uuid),
  app.duties_changes_since(uuid, bigint, bigint),
  app.duties_notes_updated_at(uuid, bigint),
  app.duties_previous_assignment_ids(uuid),
  app.duties_changes_errors(text[]),
  app.duties_update_reminder_check(jsonb),
  app.duties_released_reminder_check(jsonb),
  app.duties_revise_duty(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
