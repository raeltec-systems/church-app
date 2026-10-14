-- Open the Follow-ups registry with My follow-ups for every owner (story 4.6; AD-1, AD-2, AD-5,
-- AD-7, AD-14).
--
-- Follow-ups becomes a registered owner (module `followups`, prefix `followups_`, lock rank 30,
-- edges to platform, identity and notifications exist since story 1.5). This migration adds:
--
--   * Purpose registration (app.followups_purposes). A source owner registers, for a purpose it
--     already registered with app.contract_register_purpose: a generic label, the Identity scope
--     kinds that may supervise its tasks, the outcome codes, the legal lifecycle effect of a
--     source event (`resolved` / `cancelled` -> `close` or `keep`), whether a scope holder may
--     create tasks by hand (`manual_create`) and an optional context hook that returns a
--     minimal {"label"} for the task's viewers.
--   * Scope families (app.followups_scope_families, review S1/S2): the owner of a scope kind
--     registers its family and a read-only roster hook. A department's leader and deputy (Duties)
--     and a cell's leader and assistant (Cells) supervise the same tasks, and a task's owner is
--     chosen from the target's roster (its current members and leaders) only.
--   * Tasks (app.followups_tasks): exactly one per source_type/source_id/purpose, one owner, a
--     supervisor holding the task's scope, the scope, a next action, the original due date,
--     state open / in_progress / waiting (with review date) / done / closed (with a reason),
--     the latest outcome. Content-free activity (app.followups_activity) and separately
--     restricted private notes (app.followups_notes).
--   * Owner operations for source owners, called inside their own command's transaction after
--     their own locks: app.followups_open_task and app.followups_source_event.
--   * Commands through the 1.4 envelope (`api.followups_command`, authorizer `followups`):
--     followups.create_task (manual purposes only), followups.update_task (the owner, or a
--     holder of the task's scope recording for the owner) and followups.reassign (a holder of
--     the scope, or an Admin).
--   * Reads: api.followups_my_tasks (every owner), api.followups_task (one task: owner and scope
--     holders see it all; an Admin sees routing metadata only), api.followups_supervision (scope
--     holders) and api.followups_admin_routing (Admin, metadata only).
--   * Deletion hook app.followups_erase_member: tasks, activity and notes are kept as anonymous
--     facts (nil UUID) and note bodies the member wrote or that sit on the member's tasks are
--     cleared. No row is removed, so there is no _rows file.
--   * The SYNTHETIC source `fixture_followup` (owner: fixture) with the manual purpose
--     `synthetic_check_in`, current only in a database marked local or staging.
--
-- No reminders (entry 7) and no lifecycle or handover hooks (entry 12) yet.
--
-- Lock order (AD-2): the actor's Identity grant rows FOR SHARE (authorizer) -> command receipt
-- -> task FOR UPDATE. A source owner calls the owner operations after locking its own source;
-- Follow-ups (rank 30) comes before Notifications (rank 40).
--
-- ASCII only; no destructive statements; no row deletions. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------------------------

create function app.followups_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'task_state' then p_value in ('open', 'in_progress', 'waiting', 'done', 'closed')
    when 'active_state' then p_value in ('open', 'in_progress', 'waiting')
    when 'effect' then p_value in ('close', 'keep')
    when 'source_event' then p_value in ('resolved', 'cancelled')
    when 'close_code' then p_value in ('manual', 'source_resolved', 'source_cancelled')
    when 'capacity' then p_value in ('owner', 'supervisor', 'admin', 'source')
    when 'notes_access' then p_value in ('practical')
    when 'activity' then p_value in ('created', 'status_changed', 'review_date_set',
                                     'outcome_recorded', 'next_action_changed', 'note_added',
                                     'reassigned', 'supervisor_changed', 'closed_by_source')
    else false end;
$$;

comment on function app.followups_state_ok(text, text) is
  'Follow-ups state vocabularies (story 4.6). Later stories widen them by replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- One row per registered source_type/purpose. Handlers are stored as signature text.
create table app.followups_purposes (
  source_type text not null check (source_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  purpose text not null check (purpose ~ '^[a-z][a-z0-9_]{0,62}$'),
  module text not null,
  label text not null check (length(label) between 1 and 60),
  scope_kinds text[] not null check (cardinality(scope_kinds) between 1 and 8),
  outcomes text[] not null default '{}' check (cardinality(outcomes) <= 12),
  on_source_resolved text not null check (app.followups_state_ok('effect', on_source_resolved)),
  on_source_cancelled text not null check (app.followups_state_ok('effect', on_source_cancelled)),
  manual_create boolean not null default false,
  notes_access text not null default 'practical'
    check (app.followups_state_ok('notes_access', notes_access)),
  context_hook text,
  registered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (source_type, purpose)
);

comment on table app.followups_purposes is
  'owner: followups. Purposes a source owner registered for Follow-ups tasks, with their legal '
  'lifecycle effects (story 4.6).';

create table app.followups_tasks (
  task_id uuid primary key default gen_random_uuid(),
  source_type text not null,
  source_id uuid not null,
  purpose text not null,
  source_revision bigint not null check (source_revision >= 1),
  owner_member_id uuid not null,
  supervisor_member_id uuid not null,
  scope_kind text not null,
  scope_id uuid not null,
  next_action text not null check (length(next_action) between 1 and 200),
  due_at timestamptz not null,
  task_state text not null default 'open' check (app.followups_state_ok('task_state', task_state)),
  review_at timestamptz,
  latest_outcome text check (latest_outcome is null or latest_outcome ~ '^[a-z][a-z0-9_]{0,62}$'),
  close_code text check (close_code is null or app.followups_state_ok('close_code', close_code)),
  close_reason text check (close_reason is null or length(close_reason) between 1 and 200),
  finished_at timestamptz,
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (source_type, purpose) references app.followups_purposes (source_type, purpose),
  check ((task_state = 'waiting') = (review_at is not null)),
  check ((task_state in ('done', 'closed')) = (finished_at is not null)),
  check ((task_state = 'closed') = (close_code is not null)),
  check ((coalesce(close_code, '') = 'manual') = (close_reason is not null))
);

create unique index followups_tasks_one_per_purpose
  on app.followups_tasks (source_type, source_id, purpose);
create index followups_tasks_owner on app.followups_tasks (owner_member_id, task_state);
create index followups_tasks_scope on app.followups_tasks (scope_kind, scope_id, task_state);
create index followups_tasks_supervisor on app.followups_tasks (supervisor_member_id);

comment on table app.followups_tasks is
  'owner: followups. One accountable task per source_type/source_id/purpose (AD-7).';

-- Content-free: ids, codes, states and dates only. Never names, notes or free text.
create table app.followups_activity (
  activity_id bigint generated always as identity primary key,
  task_id uuid not null references app.followups_tasks (task_id),
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (app.followups_state_ok('activity', action)),
  actor_member_id uuid,
  actor_account_id uuid,
  actor_capacity text not null check (app.followups_state_ok('capacity', actor_capacity)),
  on_behalf_of_member uuid,
  command_request_id uuid,
  from_state text check (from_state is null or app.followups_state_ok('task_state', from_state)),
  to_state text check (to_state is null or app.followups_state_ok('task_state', to_state)),
  outcome text check (outcome is null or outcome ~ '^[a-z][a-z0-9_]{0,62}$'),
  review_at timestamptz,
  from_member uuid,
  to_member uuid,
  code text check (code is null or code ~ '^[a-z][a-z0-9_]{0,62}$'),
  revision_after bigint not null,
  -- Only a source's own event (followups_source_event) has no person behind it.
  check (actor_capacity = 'source' or (actor_member_id is not null and actor_account_id is not null))
);

create index followups_activity_task on app.followups_activity (task_id, activity_id);

comment on table app.followups_activity is
  'owner: followups. Attributed task activity: ids, codes, states and dates only.';

-- Private notes, separately restricted: the owner and the holders of the task's scope only.
create table app.followups_notes (
  note_id uuid primary key default gen_random_uuid(),
  task_id uuid not null references app.followups_tasks (task_id),
  body text check (body is null or length(body) between 1 and 1000),
  author_member_id uuid not null,
  author_account_id uuid not null,
  on_behalf_of_member uuid,
  created_at timestamptz not null default now(),
  erased_at timestamptz,
  check ((body is null) = (erased_at is not null))
);

create index followups_notes_task on app.followups_notes (task_id, created_at);

comment on table app.followups_notes is
  'owner: followups. Private task notes (owner and scope holders only; never Admin routing).';

-- Scope families (review S1, S2): the scope kinds of one target (a department's leader and
-- deputy, a cell's leader and assistant) supervise the same tasks; the owning module registers
-- the family and a read-only roster hook naming the target's members (owner candidates).
create table app.followups_scope_families (
  scope_kind text primary key check (scope_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  family text not null check (family ~ '^[a-z][a-z0-9_]{0,62}$'),
  module text not null,
  roster_hook text not null,
  registered_at timestamptz not null default now()
);

comment on table app.followups_scope_families is
  'owner: followups. Scope kinds grouped by target family, with the owner''s roster hook.';

alter table app.followups_scope_families enable row level security;
alter table app.followups_purposes enable row level security;
alter table app.followups_tasks enable row level security;
alter table app.followups_activity enable row level security;
alter table app.followups_notes enable row level security;
revoke all on table app.followups_purposes, app.followups_tasks, app.followups_activity,
                    app.followups_notes, app.followups_scope_families
  from public, anon, authenticated, service_role;
revoke all on sequence app.followups_activity_activity_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Purpose registration (source owners, in their own migration)
-- ---------------------------------------------------------------------------------------------

-- A registered read hook (context or roster): the owner's (jsonb) -> jsonb app function, with
-- search_path pinned, STABLE or IMMUTABLE (never volatile) and not SECURITY DEFINER. Hooks run
-- with Follow-ups' owner rights inside definer reads, so they must only read.
create function app.followups_validate_read_hook(p_module text, p_hook regprocedure)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_hook text := app.contract_validate_handler(p_module, p_hook, 'jsonb'::regtype);
begin
  if not exists (select 1 from pg_catalog.pg_proc p
                  where p.oid = p_hook and p.provolatile in ('s', 'i') and not p.prosecdef) then
    perform app.contract_registration_fail(
      format('hook %s must be STABLE or IMMUTABLE and not SECURITY DEFINER', p_hook));
  end if;
  return v_hook;
end;
$$;

-- The owner of a scope kind registers its family and roster hook (refused, PCTR1, for another
-- module's scope kind). The roster hook gets {scope_kind, scope_id} and answers exactly
-- {"member_ids": [uuid, ...]}: the target's current members.
create function app.followups_register_scope_family(
  p_module text,
  p_scope_kind text,
  p_family text,
  p_roster_hook regprocedure
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
begin
  if not exists (select 1 from app.identity_scope_kinds k
                  where k.scope_kind = p_scope_kind and k.module = p_module) then
    perform app.contract_registration_fail(
      format('module %s does not own scope kind %s', p_module, p_scope_kind));
  end if;
  if app.contract_token_error(to_jsonb(p_family)) is not null then
    perform app.contract_registration_fail('invalid family');
  end if;
  v_hook := app.followups_validate_read_hook(p_module, p_roster_hook);
  insert into app.followups_scope_families (scope_kind, family, module, roster_hook)
  values (p_scope_kind, p_family, p_module, v_hook)
  on conflict (scope_kind) do update
     set family = excluded.family, roster_hook = excluded.roster_hook, registered_at = now();
end;
$$;

-- Registers (or, from the owner's later migration, replaces) a Follow-ups purpose. Refusals are
-- migration-time programming errors (SQLSTATE PCTR1).
-- p_config keys: label (1-60 printable ASCII, generic, no { } < > @ \), scope_kinds (1-8
-- registered Identity scope kinds), outcomes (0-12 tokens), on_source_resolved and
-- on_source_cancelled (`close` | `keep`), manual_create (boolean, default false; only for a
-- SYNTHETIC `fixture_` source until a source-scope check exists: review S3).
-- p_context_hook: optional read-only app function of the source owner, (jsonb) returns jsonb.
create function app.followups_register_purpose(
  p_module text,
  p_source_type text,
  p_purpose text,
  p_config jsonb,
  p_context_hook regprocedure default null
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_kinds text[];
  v_outcomes text[];
  v_label text;
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if not exists (select 1 from app.contract_source_purposes p
                  where p.source_type = p_source_type and p.purpose = p_purpose) then
    perform app.contract_registration_fail(
      format('purpose %s of %s is not registered', p_purpose, p_source_type));
  end if;
  if jsonb_typeof(p_config) is distinct from 'object' then
    perform app.contract_registration_fail('config must be an object');
  end if;
  if app.contract_unknown_keys(p_config, array['label', 'scope_kinds', 'outcomes',
       'on_source_resolved', 'on_source_cancelled', 'manual_create']) <> '{}'::jsonb then
    perform app.contract_registration_fail('config has unknown keys');
  end if;
  v_label := p_config ->> 'label';
  if jsonb_typeof(p_config -> 'label') is distinct from 'string'
     or length(v_label) not between 1 and 60 or v_label !~ '^[ -~]+$'
     or v_label ~ '[{}<>@\\]' or v_label <> btrim(v_label) then
    perform app.contract_registration_fail('label must be 1-60 generic printable ASCII characters');
  end if;
  if jsonb_typeof(p_config -> 'scope_kinds') is distinct from 'array'
     or jsonb_array_length(p_config -> 'scope_kinds') not between 1 and 8
     or exists (select 1 from jsonb_array_elements(p_config -> 'scope_kinds') e
                 where jsonb_typeof(e) <> 'string'
                    or not exists (select 1 from app.identity_scope_kinds k
                                    where k.scope_kind = e #>> '{}')) then
    perform app.contract_registration_fail('scope_kinds must name 1-8 registered scope kinds');
  end if;
  select array_agg(distinct e #>> '{}' order by e #>> '{}') into v_kinds
    from jsonb_array_elements(p_config -> 'scope_kinds') e;
  if coalesce(jsonb_typeof(p_config -> 'outcomes'), 'array') <> 'array'
     or jsonb_array_length(coalesce(p_config -> 'outcomes', '[]')) > 12
     or exists (select 1 from jsonb_array_elements(coalesce(p_config -> 'outcomes', '[]')) e
                 where app.contract_token_error(e) is not null) then
    perform app.contract_registration_fail('outcomes must be at most 12 tokens');
  end if;
  select coalesce(array_agg(distinct e #>> '{}' order by e #>> '{}'), '{}') into v_outcomes
    from jsonb_array_elements(coalesce(p_config -> 'outcomes', '[]')) e;
  if not app.followups_state_ok('effect', p_config ->> 'on_source_resolved')
     or not app.followups_state_ok('effect', p_config ->> 'on_source_cancelled') then
    perform app.contract_registration_fail('on_source_resolved and on_source_cancelled must be close or keep');
  end if;
  if coalesce(jsonb_typeof(p_config -> 'manual_create'), 'boolean') <> 'boolean' then
    perform app.contract_registration_fail('manual_create must be a boolean');
  end if;
  -- Hand-made tasks never check that the source belongs to the chosen scope, so only SYNTHETIC
  -- fixture sources may allow them (a real source opens its tasks with followups_open_task).
  if coalesce((p_config ->> 'manual_create')::boolean, false) and p_source_type !~ '^fixture_' then
    perform app.contract_registration_fail('manual_create is only for SYNTHETIC fixture_ sources');
  end if;
  if p_context_hook is not null then
    v_hook := app.followups_validate_read_hook(p_module, p_context_hook);
  end if;
  insert into app.followups_purposes (source_type, purpose, module, label, scope_kinds, outcomes,
                                      on_source_resolved, on_source_cancelled, manual_create,
                                      context_hook)
  values (p_source_type, p_purpose, p_module, v_label, v_kinds, v_outcomes,
          p_config ->> 'on_source_resolved', p_config ->> 'on_source_cancelled',
          coalesce((p_config ->> 'manual_create')::boolean, false), v_hook)
  on conflict (source_type, purpose) do update
     set label = excluded.label, scope_kinds = excluded.scope_kinds, outcomes = excluded.outcomes,
         on_source_resolved = excluded.on_source_resolved,
         on_source_cancelled = excluded.on_source_cancelled,
         manual_create = excluded.manual_create, context_hook = excluded.context_hook,
         updated_at = now();
end;
$$;

comment on function app.followups_register_purpose(text, text, text, jsonb, regprocedure) is
  'Story 4.6: a source owner registers a Follow-ups purpose and its legal lifecycle effects.';

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The acting member of a followups command (authorised in this transaction) and whether Admin.
create function app.followups_command_actor(
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

-- Personal-data gate (Q4) for every Follow-ups command and owner operation.
create function app.followups_require_open()
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
create function app.followups_require_open_read()
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

-- An approved member with no deletion request.
create function app.followups_member_active(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_members m
                  where m.member_id = p_member_id and m.membership_state = 'approved')
     and not exists (select 1 from app.identity_deletions d where d.member_id = p_member_id);
$$;

-- {member_id, display_name, account}: display_name is null for an erased member (nil UUID).
-- p_full false folds an access review into `app_account` (not disclosed to scope holders).
create function app.followups_member_ref(p_member_id uuid, p_full boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', p_member_id,
    'display_name', (select m.display_name from app.identity_members m where m.member_id = p_member_id),
    'account', case
      when not exists (select 1 from app.identity_members m where m.member_id = p_member_id)
        then 'no_login'
      when p_full then app.identity_member_account_label(p_member_id)
      when app.identity_member_account_label(p_member_id) = 'no_login' then 'no_login'
      else 'app_account' end);
$$;

create function app.followups_display_name(p_member_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select m.display_name from app.identity_members m where m.member_id = p_member_id;
$$;

-- Invisible format characters refused in staff and member text (built with chr(), ASCII file):
-- soft hyphen, zero-width and direction marks, embeddings and isolates, word joiners, BOM.
create function app.followups_invisible_class()
returns text
language sql
immutable
set search_path = ''
as $$
  select '[' || chr(173) || chr(8203) || '-' || chr(8207) || chr(8234) || '-' || chr(8238)
         || chr(8288) || '-' || chr(8292) || chr(8294) || '-' || chr(8303) || chr(65279) || ']';
$$;

-- A text field: collapsed whitespace (single line) or trimmed lines (multiline), 1..p_max
-- characters, no control or format characters except newlines in multiline text.
create function app.followups_text(p_payload jsonb, p_key text, p_required boolean, p_max integer,
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
        or value ~ app.followups_invisible_class() then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

-- A UTC RFC3339 instant field.
create function app.followups_instant(p_payload jsonb, p_key text, p_required boolean,
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

create function app.followups_uuid(p_payload jsonb, p_key text, p_required boolean,
                                   inout errors jsonb, out value uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_error text;
begin
  if not p_required and coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    return;
  end if;
  v_error := app.contract_uuid_error(p_payload -> p_key);
  if v_error is not null then
    errors := errors || jsonb_build_object(p_key, v_error);
    return;
  end if;
  value := (p_payload ->> p_key)::uuid;
end;
$$;

create function app.followups_token(p_payload jsonb, p_key text, p_required boolean,
                                    inout errors jsonb, out value text)
language plpgsql
set search_path = ''
as $$
declare
  v_error text;
begin
  if not p_required and coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    return;
  end if;
  v_error := app.contract_token_error(p_payload -> p_key);
  if v_error is not null then
    errors := errors || jsonb_build_object(p_key, v_error);
    return;
  end if;
  value := p_payload ->> p_key;
end;
$$;

-- A scope kind's family (its registered family, or the kind itself when none is registered).
create function app.followups_family(p_scope_kind text)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce((select f.family from app.followups_scope_families f
                    where f.scope_kind = p_scope_kind), p_scope_kind);
$$;

-- The one supervision rule (review S1, N4), used by every command and read: the member holds
-- an active grant on the same target (scope_id) whose kind is in the same family as p_scope_kind
-- and is one of the kinds the purpose registered now. So a department's leader and deputy, or a
-- cell's leader and assistant, supervise each other's tasks; a narrowed registration narrows
-- every command and read at once.
create function app.followups_member_holds(p_member_id uuid, p_scope_kind text, p_scope_id uuid,
                                           p_purpose_kinds text[])
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_member_id is not null and exists (
    select 1 from app.identity_grants g
     where g.member_id = p_member_id and g.revoked_at is null and g.scope_id = p_scope_id
       and g.scope_kind = any (p_purpose_kinds)
       and app.followups_family(g.scope_kind) = app.followups_family(p_scope_kind));
$$;

create function app.followups_purpose_kinds(p_source_type text, p_purpose text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce((select p.scope_kinds from app.followups_purposes p
                    where p.source_type = p_source_type and p.purpose = p_purpose), '{}');
$$;

-- Does the member currently hold the task's scope (the supervising leaders)?
create function app.followups_holds_scope(p_member_id uuid, p_task app.followups_tasks)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.followups_member_holds(p_member_id, p_task.scope_kind, p_task.scope_id,
                                    app.followups_purpose_kinds(p_task.source_type, p_task.purpose));
$$;

-- The members of a scope's target who may own its tasks (review S2, fail closed): the members
-- its owner's roster hook names (a department's current members, a cell's current members) and
-- the current holders of the family's scope kinds, all approved and not under deletion. A hook
-- that raises or answers anything but {"member_ids": [uuid, ...]} names nobody.
create function app.followups_scope_roster(p_scope_kind text, p_scope_id uuid)
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
                     and app.followups_family(g.scope_kind) = app.followups_family(p_scope_kind)) y
           where app.followups_member_active(y.x));
end;
$$;

-- How the member may act on the task: `owner` (their own task), `supervisor` (holds the task's
-- scope), `admin` (routing only) or null (nothing; the task is not disclosed).
create function app.followups_capacity(p_member_id uuid, p_task app.followups_tasks)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_member_id is null then null
    when p_task.owner_member_id = p_member_id then 'owner'
    when app.followups_holds_scope(p_member_id, p_task) then 'supervisor'
    when app.identity_member_has_role(p_member_id, 'admin') then 'admin'
  end;
$$;

create function app.followups_activity_event(
  p_task_id uuid,
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_on_behalf_of uuid,
  p_command text,
  p_from_state text,
  p_to_state text,
  p_outcome text,
  p_review_at timestamptz,
  p_from_member uuid,
  p_to_member uuid,
  p_code text,
  p_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.followups_activity (task_id, action, actor_member_id, actor_account_id,
                                      actor_capacity, on_behalf_of_member, command_request_id,
                                      from_state, to_state, outcome, review_at, from_member,
                                      to_member, code, revision_after)
  values (p_task_id, p_action, p_actor_member, p_actor_account, p_capacity, p_on_behalf_of,
          case when p_command is not null and p_actor_account is not null
               then app.cmd_current_request_id(p_actor_account, p_command) end,
          p_from_state, p_to_state, p_outcome, p_review_at, p_from_member, p_to_member, p_code,
          p_revision);
$$;

-- The task's minimal source context from the registered hook, or null. A hook that raises or
-- answers anything but {"label": "<1-80 printable characters>"} shows no context (fail closed).
create function app.followups_context(p_task app.followups_tasks, p_viewer uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_proc regprocedure;
  v_answer jsonb;
  v_state text;
begin
  select p.context_hook into v_hook from app.followups_purposes p
   where p.source_type = p_task.source_type and p.purpose = p_task.purpose;
  if v_hook is null then
    return null;
  end if;
  v_proc := pg_catalog.to_regprocedure(v_hook);
  if v_proc is null then
    return null;
  end if;
  begin
    execute format('select %s($1)', v_proc::regproc) into v_answer
      using jsonb_build_object('source_type', p_task.source_type, 'source_id', p_task.source_id,
                               'purpose', p_task.purpose, 'task_id', p_task.task_id,
                               'viewer_member_id', p_viewer);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    raise log 'followups context hook failed: %', v_state;
    return null;
  end;
  if jsonb_typeof(v_answer) is distinct from 'object'
     or app.contract_unknown_keys(v_answer, array['label']) <> '{}'::jsonb
     or jsonb_typeof(v_answer -> 'label') is distinct from 'string'
     or length(v_answer ->> 'label') not between 1 and 80
     or (v_answer ->> 'label') ~ '[[:cntrl:]]'
     or (v_answer ->> 'label') ~ app.followups_invisible_class() then
    return null;
  end if;
  return jsonb_build_object('label', v_answer ->> 'label');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Projections
-- ---------------------------------------------------------------------------------------------

-- Is the task overdue now? Open / In progress: the due date passed; Waiting: the review date
-- passed. Done and Closed are never overdue.
create function app.followups_overdue(p_task app.followups_tasks)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_task.task_state
    when 'waiting' then p_task.review_at <= now()
    when 'open' then p_task.due_at <= now()
    when 'in_progress' then p_task.due_at <= now()
    else false end;
$$;

-- Routing metadata (Admin): owner, supervisor, scope, purpose, state and dates. No next action,
-- outcome, close reason, source context or notes.
create function app.followups_routing_json(p_task_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'task_id', t.task_id,
    'revision', t.revision,
    'source_type', t.source_type,
    'purpose', t.purpose,
    'purpose_label', p.label,
    'owner', app.followups_member_ref(t.owner_member_id, true),
    'supervisor', app.followups_member_ref(t.supervisor_member_id, true),
    'scope', jsonb_build_object('scope_kind', t.scope_kind, 'scope_id', t.scope_id),
    'state', t.task_state,
    'due_at', app.cmd_utc(t.due_at),
    'review_at', case when t.review_at is not null then app.cmd_utc(t.review_at) end,
    'overdue', app.followups_overdue(t),
    'due_passed', t.due_at <= now(),
    'finished_at', case when t.finished_at is not null then app.cmd_utc(t.finished_at) end,
    'created_at', app.cmd_utc(t.created_at),
    'updated_at', app.cmd_utc(t.updated_at))
    from app.followups_tasks t
    join app.followups_purposes p on p.source_type = t.source_type and p.purpose = t.purpose
   where t.task_id = p_task_id;
$$;

-- The full task for its owner or a holder of its scope (p_viewer), with what they may do.
create function app.followups_task_json(p_task_id uuid, p_viewer uuid)
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
                      and app.followups_state_ok('active_state', v_task.task_state));
end;
$$;

-- A person named in activity or notes: their name, or `a former member` once erased (review N3).
create function app.followups_person_name(p_member_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_member_id is not null
              then coalesce(app.followups_display_name(p_member_id), 'a former member') end;
$$;

-- The task's activity (oldest first, at most 200) for its owner and scope holders.
create function app.followups_activity_json(p_task_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', app.cmd_utc(a.occurred_at),
           'action', a.action,
           'capacity', a.actor_capacity,
           'actor', app.followups_person_name(a.actor_member_id),
           'on_behalf_of', app.followups_person_name(a.on_behalf_of_member),
           'from_state', a.from_state,
           'to_state', a.to_state,
           'outcome', a.outcome,
           'review_at', case when a.review_at is not null then app.cmd_utc(a.review_at) end,
           'from_member', app.followups_person_name(a.from_member),
           'to_member', app.followups_person_name(a.to_member),
           'code', a.code)
         order by a.activity_id), '[]'::jsonb)
    from (select a2.* from app.followups_activity a2 where a2.task_id = p_task_id
           order by a2.activity_id limit 200) a;
$$;

-- The task's private notes (newest first, at most 100) for its owner and scope holders.
create function app.followups_notes_json(p_task_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'note_id', n.note_id,
           'at', app.cmd_utc(n.created_at),
           'author', app.followups_person_name(n.author_member_id),
           'on_behalf_of', app.followups_person_name(n.on_behalf_of_member),
           'body', n.body,
           'erased', n.erased_at is not null)
         order by n.created_at desc, n.note_id), '[]'::jsonb)
    from (select n2.* from app.followups_notes n2 where n2.task_id = p_task_id
           order by n2.created_at desc, n2.note_id limit 100) n;
$$;

-- One scope with the members an owner may be chosen from (its roster, at most 200): name and
-- account standing only.
create function app.followups_scope_json(p_scope_kind text, p_scope_id uuid, p_full boolean)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object(
    'scope_kind', p_scope_kind,
    'scope_id', p_scope_id,
    'family', app.followups_family(p_scope_kind),
    'candidates', coalesce((
      select jsonb_agg(x.obj order by x.display_name collate "C", x.member_id)
        from (select im.member_id, im.display_name, app.followups_member_ref(im.member_id, p_full) as obj
                from app.identity_members im
               where im.member_id = any (app.followups_scope_roster(p_scope_kind, p_scope_id))
               order by im.display_name collate "C", im.member_id
               limit 200) x), '[]'::jsonb));
$$;

-- A command's outcome: ids, revision and state only (receipts keep results; no text).
create function app.followups_task_outcome(p_task_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'followups_task',
    'aggregate_id', t.task_id,
    'revision', t.revision,
    'data', jsonb_build_object('task_id', t.task_id, 'revision', t.revision, 'state', t.task_state))
    from app.followups_tasks t where t.task_id = p_task_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Opening a task (shared by the owner operation and followups.create_task)
-- ---------------------------------------------------------------------------------------------

-- Validates the registration, the scope, the source (current through its owner's check hook),
-- the owner and the supervisor, then inserts the Open task and its `created` activity. Raises
-- the kernel's refusals (PCMD1) so the calling command fails with them.
create function app.followups_insert_task(
  p_source_type text,
  p_source_id uuid,
  p_source_revision bigint,
  p_purpose text,
  p_owner uuid,
  p_supervisor uuid,
  p_scope_kind text,
  p_scope_id uuid,
  p_next_action text,
  p_due timestamptz,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_manual boolean,
  p_command text
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_purpose app.followups_purposes;
  v_check jsonb;
  v_task uuid;
begin
  select p.* into v_purpose from app.followups_purposes p
   where p.source_type = p_source_type and p.purpose = p_purpose;
  if not found then
    perform app.cmd_fail('validation_failed', '{"purpose": "unregistered"}');
  end if;
  if p_manual and not v_purpose.manual_create then
    perform app.cmd_fail('validation_failed', '{"purpose": "not_manual"}');
  end if;
  if not (p_scope_kind = any (v_purpose.scope_kinds)) then
    perform app.cmd_fail('validation_failed', '{"scope_kind": "not_allowed"}');
  end if;
  if p_due <= now() then
    perform app.cmd_fail('validation_failed', '{"due_at": "past"}');
  elsif p_due > now() + interval '1 year' then
    perform app.cmd_fail('validation_failed', '{"due_at": "out_of_range"}');
  end if;
  v_check := app.contract_check_source(jsonb_build_object(
               'source_type', p_source_type, 'source_id', p_source_id,
               'source_revision', p_source_revision));
  if not (v_check ->> 'current')::boolean then
    perform app.cmd_fail('validation_failed', '{"source_id": "not_current"}');
  end if;
  if not app.followups_member_active(p_owner) then
    perform app.cmd_fail('validation_failed', '{"owner_member_id": "unknown"}');
  end if;
  -- Review S2 (fail closed): the owner is a member of the scope's target or one of its leaders.
  if not (p_owner = any (app.followups_scope_roster(p_scope_kind, p_scope_id))) then
    perform app.cmd_fail('validation_failed', '{"owner_member_id": "not_in_scope"}');
  end if;
  -- Review N5: the supervisor's grants are share-locked (Identity rows, as the authorizer does).
  perform 1 from app.identity_grants g
   where g.member_id = p_supervisor and g.revoked_at is null for share;
  if not app.followups_member_active(p_supervisor)
     or not app.followups_member_holds(p_supervisor, p_scope_kind, p_scope_id,
                                       v_purpose.scope_kinds) then
    perform app.cmd_fail('validation_failed', '{"supervisor_member_id": "not_in_scope"}');
  end if;
  if exists (select 1 from app.followups_tasks t
              where t.source_type = p_source_type and t.source_id = p_source_id
                and t.purpose = p_purpose) then
    perform app.cmd_fail('conflict', '{"purpose": "task_exists"}');
  end if;
  begin
    insert into app.followups_tasks (source_type, source_id, purpose, source_revision,
                                     owner_member_id, supervisor_member_id, scope_kind, scope_id,
                                     next_action, due_at, created_by_member, created_by_account)
    values (p_source_type, p_source_id, p_purpose, p_source_revision, p_owner, p_supervisor,
            p_scope_kind, p_scope_id, p_next_action, p_due, p_actor_member, p_actor_account)
    returning task_id into v_task;
  exception when unique_violation then
    -- A concurrent open of the same source and purpose committed first.
    perform app.cmd_fail('conflict', '{"purpose": "task_exists"}');
  end;
  perform app.followups_activity_event(v_task, 'created', p_actor_member, p_actor_account,
                                       p_capacity, null, p_command, null, 'open', null, null,
                                       null, p_owner, null, 1);
  return v_task;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner operations (source owners call these inside their own command's transaction)
-- ---------------------------------------------------------------------------------------------

-- Opens the one task of a source and purpose. Input (strict): source_type, source_id,
-- source_revision (the source's current revision), purpose, owner_member_id,
-- supervisor_member_id (holds the scope), scope_kind, scope_id, next_action (1-200), due_at
-- (future, at most a year away), actor_member_id, actor_account_id (the source command's
-- actor). Answers {task_id, revision}. Refusals are the kernel's (validation_failed, conflict
-- {"purpose": "task_exists"}, unavailable while the personal-data gate is closed).
create function app.followups_open_task(p_input jsonb)
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
  v_task uuid;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'purpose', 'owner_member_id', 'supervisor_member_id',
                'scope_kind', 'scope_id', 'next_action', 'due_at', 'actor_member_id',
                'actor_account_id']);
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
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.followups_require_open();
  v_task := app.followups_insert_task(v_source_type, v_source_id,
              (p_input ->> 'source_revision')::numeric::bigint, v_purpose, v_owner, v_supervisor,
              v_scope_kind, v_scope_id, v_next, v_due, v_actor_member, v_actor_account, 'source',
              false, null);
  return jsonb_build_object('task_id', v_task, 'revision', 1);
end;
$$;

comment on function app.followups_open_task(jsonb) is
  'Story 4.6 owner operation: a source owner opens the one task of a source and purpose.';

-- Applies a source event to the source's active tasks, by each purpose's registered effect.
-- Input (strict): source_type, source_id, event (`resolved` | `cancelled`). `close` closes the
-- task with close code source_resolved / source_cancelled (no reason text; activity
-- closed_by_source); `keep` leaves it open (for example unresolved care that survives an
-- appointment). Answers {closed, kept}. Task completion never changes a source.
create function app.followups_source_event(p_input jsonb)
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
  -- Review N2: the same personal-data gate as every other Follow-ups change.
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
      v_closed := v_closed + 1;
    else
      v_kept := v_kept + 1;
    end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'kept', v_kept);
end;
$$;

comment on function app.followups_source_event(jsonb) is
  'Story 4.6 owner operation: apply a source''s resolved/cancelled event by the registered effect.';

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- followups.create_task {source_type, source_id, source_revision, purpose, owner_member_id,
-- scope_kind, scope_id, supervisor_member_id?, next_action, due_at, note?}; expected null.
-- Only for purposes registered with manual_create. A holder of the scope (the supervisor by
-- default), or an Admin naming a supervisor who holds it (an Admin adds no note).
create function app.followups_create_task(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
begin
  select a.* into v_actor from app.followups_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['source_type', 'source_id',
                'source_revision', 'purpose', 'owner_member_id', 'supervisor_member_id',
                'scope_kind', 'scope_id', 'next_action', 'due_at', 'note']);
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
  v_task := app.followups_insert_task(v_source_type, v_source_id,
              (p_payload ->> 'source_revision')::numeric::bigint, v_purpose, v_owner, v_supervisor,
              v_scope_kind, v_scope_id, v_next, v_due, v_actor.member_id, v_actor.account_id,
              v_capacity, true, 'followups.create_task');
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
  return app.followups_task_outcome(v_task);
end;
$$;

-- followups.update_task {task_id, status?, review_at?, close_reason?, outcome?, next_action?,
-- note?}; expected = the task's revision. The owner, or a holder of the task's scope recording
-- for the owner (attributed on_behalf_of the owner). At least one change.
create function app.followups_update_task(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
    -- Admin routes tasks; it does not work them (no private content).
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
    -- A changed review date is recorded, never a silent reset (the due date never moves).
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
  return app.followups_task_outcome(v_task.task_id);
end;
$$;

-- followups.reassign {task_id, owner_member_id?, supervisor_member_id?}; expected = the task's
-- revision. A holder of the task's scope, or an Admin. The new owner is an approved member
-- (with or without a login); the new supervisor holds the task's scope.
create function app.followups_reassign(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
      -- Review S2: an Admin routes within the scope's target too (fail closed).
      v_errors := v_errors || '{"owner_member_id": "not_in_scope"}';
    end if;
  end if;
  if v_supervisor is not null then
    -- Review N5: the new supervisor's grants are share-locked (also by the authorizer).
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
  return app.followups_task_outcome(v_task.task_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command entry point and the registered `followups` authorizer
-- ---------------------------------------------------------------------------------------------

-- `followups.*`: a live member session; handlers check the owner, the task's scope or Admin.
-- The actor's active grants are share-locked here, so a concurrent revocation waits for the
-- command (AD-2: authority rows before the receipt).
create function app.followups_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'followups.create_task', 'followups.update_task', 'followups.reassign') then
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
     and (g.role = 'admin' or g.scope_kind is not null)
     for share;
  -- Review N5: a named supervisor's grants too, before the receipt (AD-2 lock order).
  if jsonb_typeof(p_request -> 'payload') = 'object'
     and app.contract_uuid_error(p_request #> '{payload,supervisor_member_id}') is null then
    perform 1 from app.identity_grants g
     where g.member_id = (p_request #>> '{payload,supervisor_member_id}')::uuid
       and g.revoked_at is null
       for share;
  end if;
  return true;
end;
$$;

select app.cmd_register_authorizer('followups', 'app.followups_authorize_command(jsonb)'::regprocedure);

-- Replay recheck (AD-2): may the actor still act on the stored task (its owner, a holder of its
-- scope, or an Admin)?
create function app.followups_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_task app.followups_tasks;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null or p_aggregate_id is null or p_aggregate_type <> 'followups_task' then
    return false;
  end if;
  select t.* into v_task from app.followups_tasks t where t.task_id = p_aggregate_id for share;
  if not found then
    return false;
  end if;
  return app.followups_capacity(v_member, v_task) is not null;
end;
$$;

create function app.followups_command(p_envelope jsonb)
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
      when 'followups.create_task' then 'app.followups_create_task(uuid, bigint, jsonb)'::regprocedure
      when 'followups.update_task' then 'app.followups_update_task(uuid, bigint, jsonb)'::regprocedure
      when 'followups.reassign' then 'app.followups_reassign(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.followups_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'followups.create_task'
  );
end;
$$;

-- POST /rest/v1/rpc/followups_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.followups_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.followups_command($1);
$$;

comment on function api.followups_command(jsonb) is
  'Story 4.6: follow-up tasks (followups.create_task for manual purposes, update_task, '
  'reassign) through the 1.4 envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- The signed-in member's own tasks: active ones (most urgent first) and those finished in the
-- last 30 days (most recent first); at most 200 (`truncated` says more exist).
create function app.followups_my_tasks()
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
  perform app.followups_require_open_read();
  with ranked as (
    select t.task_id,
           row_number() over (order by (t.finished_at is not null),
                                       coalesce(t.review_at, t.due_at), t.finished_at desc,
                                       t.task_id) as rn
      from app.followups_tasks t
     where t.owner_member_id = v_member
       and (t.finished_at is null or t.finished_at > now() - interval '30 days'))
  select jsonb_build_object(
           'member_id', v_member,
           'tasks', coalesce(jsonb_agg(app.followups_task_json(r.task_id, v_member) order by r.rn)
                             filter (where r.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked r;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.followups_my_tasks()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.followups_my_tasks();
$$;

comment on function api.followups_my_tasks() is
  'Story 4.6: My follow-ups - the signed-in member''s own tasks (every owner).';

-- One task. Its owner and the holders of its scope get the task, its activity and its private
-- notes; an Admin gets routing metadata only (`view` = `routing`); anyone else is refused
-- (forbidden, not_granted) without saying whether the task exists.
create function app.followups_task(p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_task app.followups_tasks;
  v_capacity text;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.followups_require_open_read();
  select t.* into v_task from app.followups_tasks t where t.task_id = p_task_id;
  v_capacity := case when found then app.followups_capacity(v_member, v_task) end;
  if v_capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  if v_capacity = 'admin' then
    v_result := jsonb_build_object('view', 'routing',
                                   'task', app.followups_routing_json(p_task_id));
  else
    v_result := jsonb_build_object('view', 'full',
                                   'task', app.followups_task_json(p_task_id, v_member),
                                   'activity', app.followups_activity_json(p_task_id),
                                   'notes', app.followups_notes_json(p_task_id));
  end if;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.followups_task(p_task_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.followups_task(p_task_id);
$$;

comment on function api.followups_task(uuid) is
  'Story 4.6: one follow-up task (owner and scope holders: all; Admin: routing metadata only).';

-- The tasks the caller supervises (followups_holds_scope; active and finished in the last 30
-- days, at most 200), the caller's scopes (one per family and target) each with the members an
-- owner may be chosen from, and the manual purposes. Refused when the caller holds no such scope.
create function app.followups_supervision()
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
                                          'outcomes', to_jsonb(p.outcomes))
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

create function api.followups_supervision()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.followups_supervision();
$$;

comment on function api.followups_supervision() is
  'Story 4.6: follow-up tasks in the scopes the caller holds, with manual purposes and members.';

-- Admin only: routing metadata of every task (active and finished in the last 30 days, at most
-- 500) and, per active task scope, the members to reassign to. No next action, outcome, context
-- or notes.
create function app.followups_admin_routing()
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
  select g.member_id, g.link_id into v_member, v_link from app.identity_require_grant('admin', null, null) g;
  perform app.followups_require_open_read();
  with ranked as (
    select t.task_id,
           row_number() over (order by (t.finished_at is not null),
                                       coalesce(t.review_at, t.due_at), t.finished_at desc,
                                       t.task_id) as rn
      from app.followups_tasks t
     where t.finished_at is null or t.finished_at > now() - interval '30 days'),
  -- Review S2: an Admin reassigns within each active task's scope (its roster), not the roster
  -- of the whole church.
  families as (
    select distinct on (app.followups_family(t.scope_kind), t.scope_id) t.scope_kind, t.scope_id
      from app.followups_tasks t join ranked r on r.task_id = t.task_id
     where r.rn <= 500 and t.finished_at is null
     order by app.followups_family(t.scope_kind), t.scope_id, t.scope_kind)
  select jsonb_build_object(
    'tasks', coalesce((select jsonb_agg(app.followups_routing_json(r.task_id) order by r.rn)
                         from ranked r where r.rn <= 500), '[]'::jsonb),
    'truncated', (select count(*) > 500 from ranked),
    'scopes', coalesce((select jsonb_agg(app.followups_scope_json(f.scope_kind, f.scope_id, true)
                                         order by f.scope_kind, f.scope_id) from families f), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.followups_admin_routing()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.followups_admin_routing();
$$;

comment on function api.followups_admin_routing() is
  'Story 4.6: Admin-only follow-up routing metadata (no private content) and members.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (story 2.11 contract): anonymise, never remove rows
-- ---------------------------------------------------------------------------------------------

-- What of the member (or the account) is left in Follow-ups: member or account ids anywhere and
-- note text on the member's tasks or by the member.
create function app.followups_deletion_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.followups_tasks t
            where t.owner_member_id = p_member_id or t.supervisor_member_id = p_member_id
               or t.created_by_member = p_member_id or t.created_by_account = p_account_id)
        + (select count(*) from app.followups_activity a
            where a.actor_member_id = p_member_id or a.on_behalf_of_member = p_member_id
               or a.from_member = p_member_id or a.to_member = p_member_id
               or a.actor_account_id = p_account_id)
        + (select count(*) from app.followups_notes n
            where n.author_member_id = p_member_id or n.on_behalf_of_member = p_member_id
               or n.author_account_id = p_account_id))::integer;
$$;

-- Follow-ups' deletion hook: erase clears the text of notes the member wrote, wrote for them or
-- that sit on the member's tasks, then replaces the member's and the account's ids with the nil
-- UUID everywhere. A deleted owner's active task stays active for its scope to reassign.
create function app.followups_erase_member(p_input jsonb)
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
    update app.followups_notes n set body = null, erased_at = now()
     where n.body is not null
       and (n.author_member_id = v_member or n.on_behalf_of_member = v_member
            or n.author_account_id = v_account
            or exists (select 1 from app.followups_tasks t
                        where t.task_id = n.task_id and t.owner_member_id = v_member));
    update app.followups_notes n set author_member_id = v_nil where n.author_member_id = v_member;
    update app.followups_notes n set on_behalf_of_member = v_nil
     where n.on_behalf_of_member = v_member;
    update app.followups_tasks t set owner_member_id = v_nil where t.owner_member_id = v_member;
    update app.followups_tasks t set supervisor_member_id = v_nil
     where t.supervisor_member_id = v_member;
    update app.followups_tasks t set created_by_member = v_nil where t.created_by_member = v_member;
    update app.followups_activity a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.followups_activity a set on_behalf_of_member = v_nil
     where a.on_behalf_of_member = v_member;
    update app.followups_activity a set from_member = v_nil where a.from_member = v_member;
    update app.followups_activity a set to_member = v_nil where a.to_member = v_member;
    if v_account is not null then
      update app.followups_notes n set author_account_id = v_nil where n.author_account_id = v_account;
      update app.followups_tasks t set created_by_account = v_nil
       where t.created_by_account = v_account;
      update app.followups_activity a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.followups_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.followups_erase_member(jsonb) is
  'Follow-ups deletion hook (story 4.6): anonymise the member''s tasks, activity and notes.';

select app.identity_register_deletion_hook('followups', 'app.followups_erase_member(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Scope families: department (Duties) and cell (Cells) rosters (review S1, S2)
-- ---------------------------------------------------------------------------------------------

-- Duties: a department's current members (read only).
create function app.duties_followups_roster(p_input jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('member_ids', coalesce(jsonb_agg(dm.member_id order by dm.member_id),
                                                   '[]'::jsonb))
    from app.duties_department_members dm
   where dm.department_id::text = p_input ->> 'scope_id' and dm.ended_at is null;
$$;

-- Cells: a cell's current members (read only).
create function app.cells_followups_roster(p_input jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('member_ids', coalesce(jsonb_agg(m.member_id order by m.member_id),
                                                   '[]'::jsonb))
    from app.cells_memberships m
   where m.cell_id::text = p_input ->> 'scope_id' and m.ended_at is null;
$$;

select app.followups_register_scope_family('duties', 'department_leader', 'department',
  'app.duties_followups_roster(jsonb)'::regprocedure);
select app.followups_register_scope_family('duties', 'department_deputy', 'department',
  'app.duties_followups_roster(jsonb)'::regprocedure);
select app.followups_register_scope_family('cells', 'cell_leader', 'cell',
  'app.cells_followups_roster(jsonb)'::regprocedure);
select app.followups_register_scope_family('cells', 'cell_assistant', 'cell',
  'app.cells_followups_roster(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC source: fixture_followup (owner: fixture)
-- ---------------------------------------------------------------------------------------------

-- Any id is a SYNTHETIC source at revision 1, current only in a database marked local or
-- staging (production and an unmarked database refuse every task of it).
create function app.fixture_followup_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'current', app.platform_current_environment() in ('local', 'staging')
               and (p_source ->> 'source_revision')::numeric = 1,
    'revision', 1);
$$;

-- The minimal context a viewer may see: a fixed SYNTHETIC label.
create function app.fixture_followup_context(p_input jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select '{"label": "SYNTHETIC check-in source"}'::jsonb;
$$;

select app.contract_register_source_type(
  'fixture', 'fixture_followup', 'app.fixture_followup_source_check(jsonb)'::regprocedure);
select app.contract_register_purpose('fixture', 'fixture_followup', 'synthetic_check_in');
select app.followups_register_purpose(
  'fixture', 'fixture_followup', 'synthetic_check_in',
  '{"label": "SYNTHETIC check-in",
    "scope_kinds": ["department_leader", "department_deputy", "cell_leader", "cell_assistant"],
    "outcomes": ["contacted", "unreachable", "no_longer_needed"],
    "on_source_resolved": "close", "on_source_cancelled": "close", "manual_create": true}'::jsonb,
  'app.fixture_followup_context(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.followups_state_ok(text, text),
  app.followups_register_purpose(text, text, text, jsonb, regprocedure),
  app.followups_command_actor(uuid),
  app.followups_require_open(),
  app.followups_require_open_read(),
  app.followups_member_active(uuid),
  app.followups_member_ref(uuid, boolean),
  app.followups_display_name(uuid),
  app.followups_invisible_class(),
  app.followups_text(jsonb, text, boolean, integer, boolean, jsonb),
  app.followups_instant(jsonb, text, boolean, jsonb),
  app.followups_uuid(jsonb, text, boolean, jsonb),
  app.followups_token(jsonb, text, boolean, jsonb),
  app.followups_holds_scope(uuid, app.followups_tasks),
  app.followups_capacity(uuid, app.followups_tasks),
  app.followups_activity_event(uuid, text, uuid, uuid, text, uuid, text, text, text, text,
                               timestamptz, uuid, uuid, text, bigint),
  app.followups_context(app.followups_tasks, uuid),
  app.followups_overdue(app.followups_tasks),
  app.followups_routing_json(uuid),
  app.followups_task_json(uuid, uuid),
  app.followups_activity_json(uuid),
  app.followups_notes_json(uuid),
  app.followups_scope_json(text, uuid, boolean),
  app.followups_person_name(uuid),
  app.followups_family(text),
  app.followups_member_holds(uuid, text, uuid, text[]),
  app.followups_purpose_kinds(text, text),
  app.followups_scope_roster(text, uuid),
  app.followups_validate_read_hook(text, regprocedure),
  app.followups_register_scope_family(text, text, text, regprocedure),
  app.duties_followups_roster(jsonb),
  app.cells_followups_roster(jsonb),
  app.followups_task_outcome(uuid),
  app.followups_insert_task(text, uuid, bigint, text, uuid, uuid, text, uuid, text, timestamptz,
                            uuid, uuid, text, boolean, text),
  app.followups_open_task(jsonb),
  app.followups_source_event(jsonb),
  app.followups_create_task(uuid, bigint, jsonb),
  app.followups_update_task(uuid, bigint, jsonb),
  app.followups_reassign(uuid, bigint, jsonb),
  app.followups_authorize_command(jsonb),
  app.followups_in_scope(uuid, text, uuid),
  app.followups_command(jsonb),
  api.followups_command(jsonb),
  app.followups_my_tasks(),
  api.followups_my_tasks(),
  app.followups_task(uuid),
  api.followups_task(uuid),
  app.followups_supervision(),
  api.followups_supervision(),
  app.followups_admin_routing(),
  api.followups_admin_routing(),
  app.followups_deletion_remaining(uuid, uuid),
  app.followups_erase_member(jsonb),
  app.fixture_followup_source_check(jsonb),
  app.fixture_followup_context(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.followups_command(jsonb) to authenticated;
grant execute on function api.followups_command(jsonb) to authenticated;
grant execute on function app.followups_my_tasks() to authenticated;
grant execute on function api.followups_my_tasks() to authenticated;
grant execute on function app.followups_task(uuid) to authenticated;
grant execute on function api.followups_task(uuid) to authenticated;
grant execute on function app.followups_supervision() to authenticated;
grant execute on function api.followups_supervision() to authenticated;
grant execute on function app.followups_admin_routing() to authenticated;
grant execute on function api.followups_admin_routing() to authenticated;

notify pgrst, 'reload schema';
