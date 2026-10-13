-- Publish a one-position department duty and accept it on mobile (story 4.1; AD-1, AD-2, AD-4,
-- AD-6, AD-8, AD-14).
--
-- Duties becomes a registered owner (module `duties`, prefix `duties_`, edges to platform,
-- identity, followups and notifications already exist since story 1.5). This tracer adds:
--
--   * Departments (app.duties_departments), created by an Admin. While Q4 is unapproved every
--     department name starts `SYNTHETIC ` and the department is synthetic.
--   * Leader and deputy are Identity scope grants of the Duties-registered kinds
--     `department_leader` and `department_deputy` (scope_id = department_id), given and removed
--     with the audited 2.3 commands identity.grant_scope / identity.revoke_scope. A cell leader
--     scope gives no department authority.
--   * Department members (app.duties_department_members): approved members, with or without a
--     login, added by an Admin. Department membership is a Duties record, not an Identity grant.
--   * A published occurrence (one owning department, duty name, start, optional end, reporting
--     time, location and instructions), its single slot (position 1) and the slot's one current
--     assignment with the leader-entered response deadline (never after the start).
--   * Commands through the 1.4 envelope (`api.duties_command`, authorizer `duties`):
--     duties.create_department and duties.add_member (Admin), duties.publish_duty (the
--     department's leader or deputy, or an Admin) and duties.respond (the assignee only).
--   * The reminder source `duties_assignment` with kind `duty_assigned` and its 3.2 reminder
--     contract (generic text, link /duties/assignments/{source_id}). Publishing enqueues one job
--     due now in the same transaction (Notifications last in the lock order); a response cancels
--     the assignment's pending jobs (`responded`).
--   * Reads: api.duties_my_duties (the member's own assignments), api.duties_leader_board (the
--     departments the caller leads or deputises; Admin all; Pastor all, read-only, without
--     members' notes) and api.duties_admin_overview (Admin: departments, leaders, deputies,
--     members and the approved members to choose from).
--   * Content-free audit app.duties_audit (ids, codes, revisions).
--   * Deletion hook app.duties_erase_member: department memberships are deleted (row deletion in
--     20261013220300_duties_department_tracer_rows.sql; the stub here fails closed), assignments
--     and audit rows are kept as anonymous facts (nil UUID, note cleared).
--
-- State vocabularies are checked by app.duties_state_ok(kind, value) instead of inline CHECK
-- lists, so a later story widens them with CREATE OR REPLACE instead of replacing a constraint.
--
-- Lock order (AD-2): the actor's Identity grant rows FOR SHARE (authorizer) -> command receipt
-- -> department (FOR UPDATE for setup, FOR SHARE to publish) -> department membership FOR SHARE
-- -> occurrence / slot / assignment -> Notifications (enqueue, cancel).
--
-- No destructive statements, no row deletions (see the _rows file). No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------------------------

create function app.duties_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'department_state' then p_value in ('active')
    when 'occurrence_state' then p_value in ('published')
    when 'assignment_state' then p_value in ('current')
    when 'response' then p_value in ('pending', 'accepted', 'declined')
    when 'response_provenance' then p_value in ('member')
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded')
    else false end;
$$;

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (story 4.1). Later stories widen them by replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.duties_departments (
  department_id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 80),
  department_state text not null default 'active'
    check (app.duties_state_ok('department_state', department_state)),
  is_synthetic boolean not null,
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index duties_departments_name on app.duties_departments (lower(name));

comment on table app.duties_departments is
  'owner: duties. Departments (Admin-created); leaders and deputies are Identity scope grants.';

-- One row per period of membership; at most one current row per department and member.
-- No foreign key across owners: member ids are checked against Identity in the commands.
create table app.duties_department_members (
  membership_id uuid primary key default gen_random_uuid(),
  department_id uuid not null references app.duties_departments (department_id),
  member_id uuid not null,
  added_by_member uuid not null,
  added_by_account uuid not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create unique index duties_department_members_current
  on app.duties_department_members (department_id, member_id) where ended_at is null;
create index duties_department_members_member on app.duties_department_members (member_id);

comment on table app.duties_department_members is
  'owner: duties. Approved members (with or without a login) serving in a department.';

create table app.duties_occurrences (
  occurrence_id uuid primary key default gen_random_uuid(),
  department_id uuid not null references app.duties_departments (department_id),
  duty_name text not null check (length(duty_name) between 1 and 80),
  starts_at timestamptz not null,
  ends_at timestamptz,
  reporting_at timestamptz,
  location text check (location is null or length(location) between 1 and 120),
  instructions text check (instructions is null or length(instructions) between 1 and 1000),
  occurrence_state text not null default 'published'
    check (app.duties_state_ok('occurrence_state', occurrence_state)),
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at),
  check (reporting_at is null or reporting_at <= starts_at)
);

create index duties_occurrences_department on app.duties_occurrences (department_id, starts_at);

comment on table app.duties_occurrences is
  'owner: duties. One duty occurrence with exactly one owning department (AD-6).';

create table app.duties_slots (
  slot_id uuid primary key default gen_random_uuid(),
  occurrence_id uuid not null references app.duties_occurrences (occurrence_id),
  position_no integer not null default 1 check (position_no between 1 and 50),
  unique (occurrence_id, position_no)
);

comment on table app.duties_slots is
  'owner: duties. One required position of an occurrence (story 4.1 creates position 1 only).';

create table app.duties_assignments (
  assignment_id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references app.duties_slots (slot_id),
  member_id uuid not null,
  assignment_state text not null default 'current'
    check (app.duties_state_ok('assignment_state', assignment_state)),
  response text not null default 'pending' check (app.duties_state_ok('response', response)),
  response_deadline timestamptz not null,
  responded_at timestamptz,
  responded_by_member uuid,
  responded_by_account uuid,
  response_provenance text
    check (response_provenance is null or app.duties_state_ok('response_provenance', response_provenance)),
  response_note text check (response_note is null or length(response_note) between 1 and 280),
  revision bigint not null default 1 check (revision >= 1),
  assigned_by_member uuid not null,
  assigned_by_account uuid not null,
  assigned_at timestamptz not null default now(),
  check ((response = 'pending') = (responded_at is null)),
  check ((response = 'pending') = (response_provenance is null)),
  check (response <> 'pending' or response_note is null)
);

create unique index duties_assignments_one_current
  on app.duties_assignments (slot_id) where assignment_state = 'current';
create index duties_assignments_member on app.duties_assignments (member_id);

comment on table app.duties_assignments is
  'owner: duties. The current assignment of a slot with the member''s explicit response.';

-- Content-free: ids, codes and revisions only. Never names, phones or free text.
create table app.duties_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (app.duties_state_ok('audit_action', action)),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  actor_capacity text not null check (app.duties_state_ok('capacity', actor_capacity)),
  command_request_id uuid,
  department_id uuid,
  occurrence_id uuid,
  assignment_id uuid,
  member_id uuid,
  code text check (code is null or code ~ '^[a-z][a-z0-9_]{0,62}$'),
  revision_after bigint
);

create index duties_audit_member on app.duties_audit (member_id, event_id);

comment on table app.duties_audit is
  'owner: duties. Attributed department setup, publishing and responses: ids and codes only.';

alter table app.duties_departments enable row level security;
alter table app.duties_department_members enable row level security;
alter table app.duties_occurrences enable row level security;
alter table app.duties_slots enable row level security;
alter table app.duties_assignments enable row level security;
alter table app.duties_audit enable row level security;
revoke all on table app.duties_departments, app.duties_department_members, app.duties_occurrences,
                    app.duties_slots, app.duties_assignments, app.duties_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.duties_audit_event_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Scope kinds: department leader and deputy (Identity grant model, 2.3)
-- ---------------------------------------------------------------------------------------------

create function app.duties_scope_target_ok(p_scope jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.duties_departments d
                  where d.department_id::text = p_scope ->> 'scope_id'
                    and d.department_state = 'active');
$$;

select app.identity_register_scope_kind('duties', 'department_leader',
  'app.duties_scope_target_ok(jsonb)'::regprocedure,
  'Leads one department: publishes its duties and sees its members'' responses');
select app.identity_register_scope_kind('duties', 'department_deputy',
  'app.duties_scope_target_ok(jsonb)'::regprocedure,
  'Deputises for one department''s leader: publishes its duties and sees its responses');

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The acting member of a duties command (authorised in this transaction) and whether Admin.
create function app.duties_command_actor(
  p_actor uuid,
  out member_id uuid,
  out account_id uuid,
  out is_admin boolean
)
language plpgsql
set search_path = ''
as $$
begin
  select e.member_id into member_id from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if member_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  account_id := p_actor;
  is_admin := app.identity_member_has_role(member_id, 'admin');
end;
$$;

-- Personal-data gate (Q4) for every Duties command (member names are shown to leaders).
create function app.duties_require_open()
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
end;
$$;

-- The read-side denial for a closed personal-data gate.
create function app.duties_require_open_read()
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not app.identity_applications_open() then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = 'unavailable';
  end if;
end;
$$;

-- In what capacity may the member manage (publish for) the department? null = not at all.
-- A cell scope or the Pastor role gives none.
create function app.duties_manage_capacity(p_member_id uuid, p_department_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_member_id is null or p_department_id is null then null
    when app.identity_member_has_scope(p_member_id, 'department_leader', p_department_id)
      then 'department_leader'
    when app.identity_member_has_scope(p_member_id, 'department_deputy', p_department_id)
      then 'department_deputy'
    when app.identity_member_has_role(p_member_id, 'admin') then 'admin'
  end;
$$;

-- An approved member with no deletion request.
create function app.duties_member_active(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_members m
                  where m.member_id = p_member_id and m.membership_state = 'approved')
     and not exists (select 1 from app.identity_deletions d where d.member_id = p_member_id);
$$;

create function app.duties_display_name(p_member_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select m.display_name from app.identity_members m where m.member_id = p_member_id;
$$;

-- A staff text field: collapsed whitespace (single line) or trimmed lines (multiline),
-- 1..p_max characters, no control or format characters except newlines in multiline text.
create function app.duties_text(p_payload jsonb, p_key text, p_required boolean, p_max integer,
                                p_multiline boolean, inout errors jsonb, out value text)
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
  if jsonb_typeof(v) <> 'string' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  if p_multiline then
    value := btrim(regexp_replace(regexp_replace(v #>> '{}', '\r\n?', E'\n', 'g'),
                                  '[ \t]+', ' ', 'g'), E' \n');
  else
    value := btrim(regexp_replace(v #>> '{}', '\s+', ' ', 'g'));
  end if;
  if value = '' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    value := null;
  elsif length(value) > p_max
        or regexp_replace(value, E'\n', '', 'g') ~ '[[:cntrl:]]'
        or value ~ '[\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

-- A UTC RFC3339 instant field.
create function app.duties_instant(p_payload jsonb, p_key text, p_required boolean,
                                   inout errors jsonb, out value timestamptz)
language plpgsql
set search_path = ''
as $$
declare
  v_error text;
begin
  if not p_required and coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    return;
  end if;
  v_error := app.contract_instant_error(p_payload -> p_key);
  if v_error is not null then
    errors := errors || jsonb_build_object(p_key, v_error);
    return;
  end if;
  value := (p_payload ->> p_key)::timestamptz;
end;
$$;

create function app.duties_uuid(p_payload jsonb, p_key text, inout errors jsonb, out value uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_error text := app.contract_uuid_error(p_payload -> p_key);
begin
  if v_error is not null then
    errors := errors || jsonb_build_object(p_key, v_error);
    return;
  end if;
  value := (p_payload ->> p_key)::uuid;
end;
$$;

create function app.duties_audit_event(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_department uuid,
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
                                command_request_id, department_id, occurrence_id, assignment_id,
                                member_id, code, revision_after)
  values (p_action, p_actor_member, p_actor_account, p_capacity,
          app.cmd_current_request_id(p_actor_account, p_command), p_department, p_occurrence,
          p_assignment, p_member, p_code, p_revision);
$$;

-- The start a response deadline may not pass: the reporting time when there is one.
create function app.duties_occurrence_start(p_occurrence app.duties_occurrences)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select coalesce(p_occurrence.reporting_at, p_occurrence.starts_at);
$$;

-- ---------------------------------------------------------------------------------------------
-- Projections
-- ---------------------------------------------------------------------------------------------

create function app.duties_staff_list(p_department_id uuid, p_kind text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', g.member_id,
                                               'display_name', m.display_name,
                                               'grants_revision', gs.revision)
                            order by m.display_name, g.member_id), '[]'::jsonb)
    from app.identity_grants g
    join app.identity_members m on m.member_id = g.member_id
    join app.identity_grant_sets gs on gs.member_id = g.member_id
   where g.scope_kind = p_kind and g.scope_id = p_department_id and g.revoked_at is null;
$$;

-- The department's current, active members. p_full (Admin) gives the full account label; a
-- leader sees only `app_account` or `no_login` (an access review is not disclosed to leaders).
-- Members who are not approved or are under deletion are left out (their past assignments stay
-- readable on the duties themselves).
create function app.duties_roster(p_department_id uuid, p_full boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
                    'member_id', dm.member_id,
                    'display_name', m.display_name,
                    'account', case when p_full then app.identity_member_account_label(dm.member_id)
                                    when app.identity_member_account_label(dm.member_id) = 'no_login'
                                      then 'no_login'
                                    else 'app_account' end,
                    'since', app.cmd_utc(dm.started_at))
                  order by m.display_name, dm.member_id), '[]'::jsonb)
    from app.duties_department_members dm
    join app.identity_members m on m.member_id = dm.member_id
   where dm.department_id = p_department_id and dm.ended_at is null
     and app.duties_member_active(dm.member_id);
$$;

-- The Admin's view of one department.
create function app.duties_department_json(p_department_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'department_id', d.department_id,
    'name', d.name,
    'department_state', d.department_state,
    'is_synthetic', d.is_synthetic,
    'revision', d.revision,
    'leaders', app.duties_staff_list(d.department_id, 'department_leader'),
    'deputies', app.duties_staff_list(d.department_id, 'department_deputy'),
    'members', app.duties_roster(d.department_id, true))
    from app.duties_departments d
   where d.department_id = p_department_id;
$$;

-- A department command's outcome: ids and revision only. Receipts keep command results, and
-- member deletion does not rewrite receipts, so no name or member list goes in here; clients
-- read the department again.
create function app.duties_department_outcome(p_department_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'duties_department',
    'aggregate_id', p_department_id,
    'revision', d.revision,
    'data', jsonb_build_object('department_id', d.department_id, 'revision', d.revision))
    from app.duties_departments d where d.department_id = p_department_id;
$$;

-- One occurrence with its single position as a leader sees it. p_with_notes false hides the
-- member's practical note (Pastor oversight).
create function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean)
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
                          'revision', a.revision)
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

-- One assignment as its member sees it.
create function app.duties_my_assignment_json(p_assignment_id uuid)
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
    'note', a.response_note)
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
    join app.duties_departments d on d.department_id = o.department_id
   where a.assignment_id = p_assignment_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reminder source: duties_assignment (3.2 contract)
-- ---------------------------------------------------------------------------------------------

-- Source check (1.5 registry): current while the assignment is current, its occurrence is
-- published and its revision is the given one.
create function app.duties_assignment_source_check(p_source jsonb)
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
    'current', v_row.assignment_state = 'current' and v_row.occurrence_state = 'published'
               and v_row.revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision);
end;
$$;

-- Reminder check (3.2): exactly {current, revision, actionable, recipient_eligible}.
--   actionable          the response is still pending and the duty has not started;
--   recipient_eligible  the recipient is the assignee and still serves in the department.
create function app.duties_assignment_reminder_check(p_key jsonb)
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
                          and exists (select 1 from app.duties_department_members dm
                                       where dm.department_id = v_occurrence.department_id
                                         and dm.member_id = v_assignment.member_id
                                         and dm.ended_at is null));
end;
$$;

select app.contract_register_source_type(
  'duties', 'duties_assignment', 'app.duties_assignment_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('duties', 'duties_assignment', 'duty_assigned');
select app.contract_register_reminder_contract(
  'duties', 'duties_assignment', 'duty_assigned',
  'app.duties_assignment_reminder_check(jsonb)'::regprocedure,
  '{"title": "New duty assigned",
    "body": "You have a new duty. Open it to accept or say you cannot make it.",
    "link": "/duties/assignments/{source_id}"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Commands: Admin department setup
-- ---------------------------------------------------------------------------------------------

-- duties.create_department {name}; expected null. Admin only.
create function app.duties_create_department(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_name text;
  v_department uuid;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['name']);
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_payload, 'name', true, 80, false, v_errors) t;
  if v_name is not null and not app.policy_is_open('q4_personal_data') and v_name !~ '^SYNTHETIC ' then
    v_errors := v_errors || '{"name": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  if exists (select 1 from app.duties_departments d where lower(d.name) = lower(v_name)) then
    perform app.cmd_fail('conflict', '{"name": "taken"}');
  end if;
  begin
    insert into app.duties_departments (name, is_synthetic, created_by_member, created_by_account)
    values (v_name, not app.policy_is_open('q4_personal_data'), v_actor.member_id, v_actor.account_id)
    returning department_id into v_department;
  exception when unique_violation then
    -- A concurrent create with the same name committed first.
    perform app.cmd_fail('conflict', '{"name": "taken"}');
  end;
  perform app.duties_audit_event('department_created', v_actor.member_id, v_actor.account_id,
                                 'admin', 'duties.create_department', v_department, null, null,
                                 null, null, 1);
  return app.duties_department_outcome(v_department);
end;
$$;

-- duties.add_member {department_id, member_id}; expected = department revision. Admin only.
-- The member must be approved (a login is not needed) and not under deletion.
create function app.duties_add_member(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_department_id uuid;
  v_member uuid;
  v_department app.duties_departments;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['department_id', 'member_id']);
  select t.errors, t.value into v_errors, v_department_id
    from app.duties_uuid(p_payload, 'department_id', v_errors) t;
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_payload, 'member_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select d.* into v_department from app.duties_departments d
   where d.department_id = v_department_id for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_department.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_department.revision);
  end if;
  if not app.duties_member_active(v_member) then
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  if exists (select 1 from app.duties_department_members dm
              where dm.department_id = v_department_id and dm.member_id = v_member
                and dm.ended_at is null) then
    perform app.cmd_fail('validation_failed', '{"member_id": "current"}');
  end if;
  insert into app.duties_department_members (department_id, member_id, added_by_member,
                                             added_by_account)
  values (v_department_id, v_member, v_actor.member_id, v_actor.account_id);
  update app.duties_departments d
     set revision = d.revision + 1, updated_at = now()
   where d.department_id = v_department_id
  returning d.revision into v_revision;
  perform app.duties_audit_event('member_added', v_actor.member_id, v_actor.account_id, 'admin',
                                 'duties.add_member', v_department_id, null, null, v_member, null,
                                 v_revision);
  return app.duties_department_outcome(v_department_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: publish and respond
-- ---------------------------------------------------------------------------------------------

-- duties.publish_duty {department_id, duty_name, starts_at, ends_at?, reporting_at?, location?,
-- instructions?, member_id, response_deadline}; expected null. The department's leader or deputy,
-- or an Admin. Creates the published occurrence, its one slot and the slot's pending assignment,
-- and enqueues the member's new-duty inbox item (due now) in the same transaction.
create function app.duties_publish_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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

-- duties.respond {assignment_id, response: accepted | declined, note?}; expected = the
-- assignment's revision. Only the assignee, while the response is pending and before the duty
-- starts. The member's pending jobs for the assignment are cancelled (`responded`).
create function app.duties_respond(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  if not found or v_assignment.member_id <> v_actor.member_id
     or v_assignment.assignment_state <> 'current' then
    perform app.cmd_fail('not_found');
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
-- Command entry point and the registered `duties` authorizer
-- ---------------------------------------------------------------------------------------------

-- `duties.*`: a live member session; handlers check Admin, the department scope or the
-- assignee. The actor's Admin and department leader/deputy grants are share-locked here, so a
-- concurrent revocation waits for the command (AD-2: authority rows before the receipt).
create function app.duties_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'duties.create_department', 'duties.add_member', 'duties.publish_duty', 'duties.respond') then
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

select app.cmd_register_authorizer('duties', 'app.duties_authorize_command(jsonb)'::regprocedure);

-- Replay recheck (AD-2): does the actor still have scope on the stored aggregate?
--   department  an Admin;
--   occurrence  a manager of its department (leader, deputy, Admin);
--   assignment  its assignee (only the assignee responds in 4.1).
create function app.duties_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
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
  elsif p_aggregate_type = 'duties_assignment' then
    return exists (select 1 from app.duties_assignments a
                    where a.assignment_id = p_aggregate_id and a.member_id = v_member);
  end if;
  return false;
end;
$$;

create function app.duties_command(p_envelope jsonb)
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
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
  );
end;
$$;

-- POST /rest/v1/rpc/duties_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.duties_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.duties_command($1);
$$;

comment on function api.duties_command(jsonb) is
  'Story 4.1: departments (duties.create_department, add_member), publishing a one-position duty '
  '(duties.publish_duty) and the assignee''s answer (duties.respond) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- The signed-in member's own current assignments of the last 90 days onwards: future duties
-- first (soonest first), then past ones (most recent first); at most 200 (`truncated` says
-- more exist).
create function app.duties_my_duties()
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
  with ranked as (
    select a.assignment_id, o.starts_at,
           row_number() over (order by (o.starts_at <= now()),
                                       case when o.starts_at > now() then o.starts_at end,
                                       o.starts_at desc, a.assignment_id) as rn
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.member_id = v_member and a.assignment_state = 'current'
       and o.occurrence_state = 'published'
       and o.starts_at > now() - interval '90 days')
  select jsonb_build_object(
           'member_id', v_member,
           'assignments', coalesce(jsonb_agg(app.duties_my_assignment_json(r.assignment_id)
                                             order by r.rn) filter (where r.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked r;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_my_duties()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_my_duties();
$$;

comment on function api.duties_my_duties() is
  'Story 4.1: the signed-in member''s current duty assignments (future and the last 90 days).';

-- The departments the caller leads or deputises (Admin: all, may publish; Pastor: all, read
-- only, without members' notes), with the roster and the duties of the last 30 days onwards.
create function app.duties_leader_board()
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
                            and o2.starts_at > now() - interval '30 days'
                          order by o2.starts_at limit 200) o), '[]'::jsonb),
               'duties_truncated', (select count(*) > 200 from app.duties_occurrences o3
                                     where o3.department_id = d.department_id
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

create function api.duties_leader_board()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_leader_board();
$$;

comment on function api.duties_leader_board() is
  'Story 4.1: departments the caller leads or deputises (Admin all; Pastor read-only), with '
  'their rosters and duties and each position''s response.';

-- Admin only: every department with its leaders, deputies and members, and the approved
-- members (with or without a login) to choose from (at most 500).
create function app.duties_admin_overview()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
begin
  select g.member_id, g.link_id into v_member, v_link from app.identity_require_grant('admin', null, null) g;
  perform app.duties_require_open_read();
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'departments', coalesce((
      select jsonb_agg(app.duties_department_json(d.department_id) order by d.name, d.department_id)
        from app.duties_departments d
       where not d.is_synthetic or app.platform_current_environment() in ('local', 'staging')),
      '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(x.obj order by x.display_name collate "C", x.member_id)
        from (
          select im.member_id, im.display_name, jsonb_build_object(
                   'member_id', im.member_id, 'display_name', im.display_name,
                   'account', app.identity_member_account_label(im.member_id),
                   'grants_revision', gs.revision) as obj
            from app.identity_members im
            join app.identity_grant_sets gs on gs.member_id = im.member_id
           where im.membership_state = 'approved'
             and not exists (select 1 from app.identity_deletions dl where dl.member_id = im.member_id)
           order by im.display_name collate "C", im.member_id
           limit 500) x), '[]'::jsonb),
    'members_truncated', (select count(*) > 500 from app.identity_members im
                           where im.membership_state = 'approved'
                             and not exists (select 1 from app.identity_deletions dl
                                              where dl.member_id = im.member_id)));
end;
$$;

create function api.duties_admin_overview()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_admin_overview();
$$;

comment on function api.duties_admin_overview() is
  'Story 4.1: Admin-only departments with leaders, deputies and members, and approved members.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (story 2.11 contract) and its fail-closed row stub
-- ---------------------------------------------------------------------------------------------

-- The member's department memberships: replaced by 20261013220300_duties_department_tracer_rows.sql.
-- Returns the number of rows removed.
create function app.duties_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- What of the member (or the account) is left in Duties.
create function app.duties_deletion_remaining(p_member_id uuid, p_account_id uuid)
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
        + (select count(*) from app.duties_audit au
            where au.actor_member_id = p_member_id or au.member_id = p_member_id
               or au.actor_account_id = p_account_id))::integer;
$$;

-- Duties' deletion hook: erase deletes the member's department memberships and keeps
-- assignments, occurrences, departments and audit rows as anonymous facts (member and account
-- ids replaced by the nil UUID, the response note cleared); check counts what is left.
create function app.duties_erase_member(p_input jsonb)
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
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (story 4.1): erase or check the member''s Duties personal data.';

select app.identity_register_deletion_hook('duties', 'app.duties_erase_member(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_state_ok(text, text),
  app.duties_scope_target_ok(jsonb),
  app.duties_command_actor(uuid),
  app.duties_require_open(),
  app.duties_require_open_read(),
  app.duties_manage_capacity(uuid, uuid),
  app.duties_member_active(uuid),
  app.duties_display_name(uuid),
  app.duties_text(jsonb, text, boolean, integer, boolean, jsonb),
  app.duties_instant(jsonb, text, boolean, jsonb),
  app.duties_uuid(jsonb, text, jsonb),
  app.duties_audit_event(text, uuid, uuid, text, text, uuid, uuid, uuid, uuid, text, bigint),
  app.duties_occurrence_start(app.duties_occurrences),
  app.duties_staff_list(uuid, text),
  app.duties_roster(uuid, boolean),
  app.duties_department_json(uuid),
  app.duties_department_outcome(uuid),
  app.duties_occurrence_json(uuid, boolean),
  app.duties_my_assignment_json(uuid),
  app.duties_assignment_source_check(jsonb),
  app.duties_assignment_reminder_check(jsonb),
  app.duties_create_department(uuid, bigint, jsonb),
  app.duties_add_member(uuid, bigint, jsonb),
  app.duties_publish_duty(uuid, bigint, jsonb),
  app.duties_respond(uuid, bigint, jsonb),
  app.duties_authorize_command(jsonb),
  app.duties_in_scope(uuid, text, uuid),
  app.duties_command(jsonb),
  api.duties_command(jsonb),
  app.duties_my_duties(),
  api.duties_my_duties(),
  app.duties_leader_board(),
  api.duties_leader_board(),
  app.duties_admin_overview(),
  api.duties_admin_overview(),
  app.duties_deletion_purge_rows(uuid),
  app.duties_deletion_remaining(uuid, uuid),
  app.duties_erase_member(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.duties_command(jsonb) to authenticated;
grant execute on function api.duties_command(jsonb) to authenticated;
grant execute on function app.duties_my_duties() to authenticated;
grant execute on function api.duties_my_duties() to authenticated;
grant execute on function app.duties_leader_board() to authenticated;
grant execute on function api.duties_leader_board() to authenticated;
grant execute on function app.duties_admin_overview() to authenticated;
grant execute on function api.duties_admin_overview() to authenticated;

notify pgrst, 'reload schema';
