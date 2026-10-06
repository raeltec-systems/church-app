-- Identity grants: scoped roles with audited, immediate effect (story 2.3; AD-1, AD-2, AD-3,
-- AD-4, AD-19).
--
-- Extends the live-access predicate app.identity_access_evaluate() (2.1, hardened by 2.2)
-- without forking it: every grant helper below first asks that predicate and then reads the
-- CURRENT grant rows, so a grant or revocation applies to the very next protected call of an
-- already signed-in session (no re-sign-in, no JWT claim, no client cache).
--
--   * Role catalogue: admin, pastor, media, lead_pastor, held independently. No role implies a
--     care, finance or any other scope. lead_pastor also needs the Identity church setting
--     `lead_pastor_designation` (Q4): a labelled TEST FIXTURE enables it only in local/staging;
--     production stays unset (the role can be neither granted nor used) until the owner approves.
--   * Scope-kind registry: later owners register their scope kinds (cell, department, service,
--     care, finance, prayer team ...) with a target-check hook through
--     app.identity_register_scope_kind. This story registers only the SYNTHETIC fixture kinds
--     `fixture_care` and `fixture_finance` that prove Admin/combined roles get no such access.
--   * Grant sets: one revisioned aggregate per member; grants and revocations are 1.4 commands
--     (api.identity_grant_command) with request_id, expected_revision, payload hash and receipts.
--   * Audit: app.identity_access_audit, ids/codes/revisions only. Revocations also dispatch the
--     contract v1 lifecycle event `scope_revoked` to registered owner hooks.
--   * Authorizer registry (platform): app.cmd_authorize now calls the authorizer an owner
--     registered for the command's namespace, and otherwise keeps the 1.4 fixture grants. The
--     platform still depends on no owner (the call is through the registry).
--   * Restricted-operator bootstrap of an Admin, allowed only while no usable Admin exists, and
--     the restricted-operator lead-pastor designation (never an Admin command). Every operator
--     procedure is journalled in app.ops_operator_actions (1.9) as well as Identity's audit.
--   * Separation of duty: no grant command may target the acting Admin's own member record.
--   * The predicate's account/link conditions (everything except the session itself and the
--     release gate) are factored into app.identity_account_standing and
--     app.identity_link_dormancy; the predicate and the usable-Admin count both use them.
--   * Identity church settings (Q-values) that stay unset and fail closed.
--
-- Helpers for later owners (all read current rows; none trusts a client value):
--   app.identity_evaluate_grant(role, scope_kind, scope_id) -> (outcome, member_id, link_id)
--       outcome: the predicate's own denial, else 'not_granted' or 'granted'
--   app.identity_has_role(role) / app.identity_has_scope(scope_kind, scope_id) -> boolean
--   app.identity_require_grant(role, scope_kind, scope_id, lock) -> (member_id, link_id)
--       raises PT401/PT403 like identity_require_access (detail 'not_granted' when only the
--       grant is missing); with lock = true it share-locks the grant row for a command.
--
-- Lock order (AD-2): Identity authority rows (the admin catalogue row FOR UPDATE, then the
-- actor's admin grant FOR SHARE) -> command receipt -> the target grant set FOR UPDATE.
-- Serialising every grant command on the admin catalogue row means two Admins removing each
-- other neither deadlock nor both succeed.
--
-- No destructive statements. Clients reach only the api wrappers listed at the end.

-- ---------------------------------------------------------------------------------------------
-- Platform: command authorizer registry (owners plug their checks into app.cmd_authorize)
-- ---------------------------------------------------------------------------------------------

create table app.cmd_authorizers (
  namespace text primary key check (namespace ~ '^[a-z][a-z0-9_]{0,62}$'),
  module text not null references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now(),
  -- An owner authorises only its own namespace (`identity.*` commands -> identity).
  check (namespace = module)
);

comment on table app.cmd_authorizers is
  'owner: cmd. Per-namespace command authorizers: (jsonb {actor, command}) -> boolean.';

alter table app.cmd_authorizers enable row level security;
revoke all on table app.cmd_authorizers from public, anon, authenticated, service_role;

-- Migration-time registration. The handler must be the module's own app function taking
-- (jsonb) and returning boolean with an empty search_path (app.contract_validate_handler).
create function app.cmd_register_authorizer(p_module text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
begin
  v_handler := app.contract_validate_handler(p_module, p_handler, 'boolean'::regtype);
  insert into app.cmd_authorizers (namespace, module, handler)
  values (p_module, p_module, v_handler);
end;
$$;

-- The request_id of the command this transaction is executing for (actor, command): the
-- receipt the kernel reserved is the only one with a null result visible here (committed
-- receipts always carry their result). Lets handlers attribute audit rows to the request.
create function app.cmd_current_request_id(p_actor uuid, p_command text)
returns uuid
language sql
stable
set search_path = ''
as $$
  select r.request_id
    from app.cmd_receipts r
   where r.actor_id = p_actor and r.command = p_command and r.result is null
   limit 1;
$$;

-- The 1.4 seam, same signature: a registered owner authorizer decides for its namespace and
-- may itself raise app.cmd_fail (for example `unauthenticated`); anything else keeps the
-- story 1.4 SYNTHETIC fixture grants. Fails closed: no authorizer and no fixture grant is
-- `forbidden`; a registered handler that no longer exists is an internal error (unavailable).
create or replace function app.cmd_authorize(p_actor uuid, p_command text) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
  v_proc regprocedure;
  v_ok boolean;
begin
  select a.handler into v_handler
    from app.cmd_authorizers a
   where a.namespace = split_part(coalesce(p_command, ''), '.', 1);
  if found then
    v_proc := pg_catalog.to_regprocedure(v_handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered authorizer %s is missing', v_handler);
    end if;
    execute format('select %s($1)', v_proc::regproc)
      into v_ok
      using jsonb_build_object('actor', p_actor, 'command', p_command);
    if v_ok is not true then
      perform app.cmd_fail('forbidden');
    end if;
    return;
  end if;

  perform 1
    from app.fixture_command_grants g
   where g.actor_id = p_actor
     and g.command = p_command
     and g.revoked_at is null
     for share;
  if not found then
    perform app.cmd_fail('forbidden');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Platform: widen the restricted-operator journal (1.9) for Identity's operator procedures
-- ---------------------------------------------------------------------------------------------
-- The 1.9 table's inline CHECK lists only the system-principal actions, and widening a CHECK
-- needs DROP CONSTRAINT, which the non-destructive migration policy forbids. So the 1.9 table is
-- retired by rename (its rows copied first, every privilege revoked) and replaced by one of the
-- same shape with a wider action list. app.ops_record_action names the table and is unchanged.
-- target_id may be null only for a church-setting approval (it has no row id).

alter table app.ops_operator_actions rename to ops_retired_operator_actions_v0;
alter index app.ops_operator_actions_pkey rename to ops_retired_operator_actions_v0_pkey;
alter sequence app.ops_operator_actions_id_seq rename to ops_retired_operator_actions_v0_id_seq;
revoke all on table app.ops_retired_operator_actions_v0 from public, anon, authenticated, service_role;
revoke all on sequence app.ops_retired_operator_actions_v0_id_seq
  from public, anon, authenticated, service_role;
comment on table app.ops_retired_operator_actions_v0 is
  'RETIRED (story 2.3): rows copied to app.ops_operator_actions; dropped by a later owner-approved cleanup.';

create table app.ops_operator_actions (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  operator text not null references app.ops_operators (operator),
  action text not null check (action in (
    'principal_created', 'principal_disabled', 'credential_registered', 'credential_revoked',
    'admin_bootstrapped', 'lead_pastor_designated', 'church_setting_approved')),
  target_id uuid,
  check (target_id is not null or action = 'church_setting_approved')
);

comment on table app.ops_operator_actions is
  'Attributable, content-free record of every restricted operator action (1.9; widened by 2.3).';

insert into app.ops_operator_actions (id, occurred_at, environment, operator, action, target_id)
overriding system value
select r.id, r.occurred_at, r.environment, r.operator, r.action, r.target_id
  from app.ops_retired_operator_actions_v0 r;
select setval(pg_catalog.pg_get_serial_sequence('app.ops_operator_actions', 'id'),
              coalesce((select max(a.id) from app.ops_operator_actions a), 0) + 1, false);

alter table app.ops_operator_actions enable row level security;
revoke all on table app.ops_operator_actions from public, anon, authenticated, service_role;
revoke all on sequence app.ops_operator_actions_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Identity church settings (Q-values): unset means fail closed
-- ---------------------------------------------------------------------------------------------

create table app.identity_church_settings (
  setting text not null check (setting in ('lead_pastor_designation', 'operational_contact')),
  version integer not null check (version >= 1),
  value jsonb not null check (jsonb_typeof(value) = 'object'),
  source text not null check (source in ('fixture', 'approved')),
  label text not null check (length(btrim(label)) > 0),
  set_by text not null check (length(btrim(set_by)) > 0),
  set_at timestamptz not null default now(),
  primary key (setting, version),
  check (source <> 'fixture' or label like 'TEST FIXTURE%'),
  check (source <> 'approved' or label not like 'TEST FIXTURE%'),
  check (setting <> 'lead_pastor_designation' or jsonb_typeof(value -> 'enabled') = 'boolean'),
  check (setting <> 'operational_contact' or (
    jsonb_typeof(value -> 'route') = 'string' and length(btrim(value ->> 'route')) between 1 and 200))
);

comment on table app.identity_church_settings is
  'owner: identity. Versioned church settings awaiting owner decisions (Q1 operational contact, '
  'Q4 lead-pastor designation). Fixture rows count only in local/staging; production stays '
  'unset and fails closed until an approved row exists.';

insert into app.identity_church_settings (setting, version, value, source, label, set_by) values
  ('lead_pastor_designation', 1, '{"enabled": true}', 'fixture',
   'TEST FIXTURE - lead-pastor designation enabled for synthetic tests (Q4), not church policy',
   'story 2.3 migration');

alter table app.identity_church_settings enable row level security;
revoke all on table app.identity_church_settings from public, anon, authenticated, service_role;

-- Effective value: the latest approved row; else, only in local/staging, the latest fixture;
-- else null (callers fail closed).
create function app.identity_church_setting(p_setting text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select s.value from app.identity_church_settings s
      where s.setting = p_setting and s.source = 'approved'
      order by s.version desc limit 1),
    (select s.value from app.identity_church_settings s
      where s.setting = p_setting and s.source = 'fixture'
        and app.platform_current_environment() in ('local', 'staging')
      order by s.version desc limit 1)
  );
$$;

-- A boolean designation is in force only when its effective value says enabled = true.
create function app.identity_church_setting_enabled(p_setting text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((app.identity_church_setting(p_setting) ->> 'enabled')::boolean, false);
$$;

-- Restricted operator only (no grants): records the owner's approved value as a new version.
create function app.identity_approve_church_setting(
  p_setting text,
  p_value jsonb,
  p_operator text,
  p_note text
) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_version integer;
begin
  perform app.ops_require_operator(p_operator);
  if length(btrim(coalesce(p_note, ''))) = 0 or btrim(p_note) like 'TEST FIXTURE%' then
    raise exception using errcode = '22023', message = 'an owner decision note is required';
  end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' or p_value ? 'fixture_label' then
    raise exception using errcode = '22023', message = 'approved value must be a plain object';
  end if;
  select coalesce(max(s.version), 0) + 1 into v_version
    from app.identity_church_settings s where s.setting = p_setting;
  insert into app.identity_church_settings (setting, version, value, source, label, set_by)
  values (p_setting, v_version, p_value, 'approved', btrim(p_note), p_operator);
  insert into app.identity_access_audit (action, actor_kind, operator, setting, revision_after)
  values ('church_setting_approved', 'operator', p_operator, p_setting, v_version);
  perform app.ops_record_action(p_operator, 'church_setting_approved', null);
  return v_version;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Role catalogue and scope-kind registry
-- ---------------------------------------------------------------------------------------------

create table app.identity_roles (
  role text primary key check (role ~ '^[a-z][a-z0-9_]{0,62}$'),
  description text not null,
  -- Church setting that must be in force before the role can be granted or counts.
  requires_setting text check (requires_setting in ('lead_pastor_designation')),
  sort_order smallint not null unique
);

comment on table app.identity_roles is
  'owner: identity. Church-wide roles, held independently. A role implies no scope.';

insert into app.identity_roles (role, description, requires_setting, sort_order) values
  ('admin', 'Membership, account links, roles and routing metadata; no care or finance content',
   null, 1),
  ('pastor', 'Pastoral role; care oversight and finance oversight are separate scopes', null, 2),
  ('media', 'Church content management', null, 3),
  ('lead_pastor', 'Lead-pastor designation (anonymous-prayer identity access, Q4)',
   'lead_pastor_designation', 4);

create table app.identity_scope_kinds (
  scope_kind text primary key check (scope_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  module text not null references app.contract_modules (module),
  -- (jsonb {"scope_kind", "scope_id"}) -> boolean: does the target exist and accept grants now?
  target_hook text not null,
  description text not null check (length(btrim(description)) > 0),
  registered_at timestamptz not null default now()
);

comment on table app.identity_scope_kinds is
  'owner: identity. Scope kinds registered by their owning modules (AD-1); Identity stores '
  'grants of them but owns none of their business rules.';

alter table app.identity_roles enable row level security;
alter table app.identity_scope_kinds enable row level security;
revoke all on table app.identity_roles, app.identity_scope_kinds
  from public, anon, authenticated, service_role;

-- Migration-time registration by the owning module (programming errors raise PCTR1).
create function app.identity_register_scope_kind(
  p_module text,
  p_scope_kind text,
  p_target_hook regprocedure,
  p_description text
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
begin
  if app.contract_token_error(to_jsonb(p_scope_kind)) is not null then
    perform app.contract_registration_fail('invalid scope_kind');
  end if;
  if exists (select 1 from app.identity_roles r where r.role = p_scope_kind) then
    perform app.contract_registration_fail('scope_kind collides with a role');
  end if;
  v_hook := app.contract_validate_handler(p_module, p_target_hook, 'boolean'::regtype);
  insert into app.identity_scope_kinds (scope_kind, module, target_hook, description)
  values (p_scope_kind, p_module, v_hook, btrim(p_description));
end;
$$;

-- Calls the owner's target hook for one scope.
create function app.identity_scope_target_ok(p_scope_kind text, p_scope_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_proc regprocedure;
  v_ok boolean;
begin
  select k.target_hook into v_hook from app.identity_scope_kinds k where k.scope_kind = p_scope_kind;
  if not found or p_scope_id is null then
    return false;
  end if;
  v_proc := pg_catalog.to_regprocedure(v_hook);
  if v_proc is null then
    raise exception using errcode = 'PCTR1',
      message = format('registered scope target hook %s is missing', v_hook);
  end if;
  execute format('select %s($1)', v_proc::regproc)
    into v_ok
    using jsonb_build_object('scope_kind', p_scope_kind, 'scope_id', p_scope_id);
  return v_ok is true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Grant sets, grants and audit
-- ---------------------------------------------------------------------------------------------

create table app.identity_grant_sets (
  member_id uuid primary key references app.identity_members (member_id),
  revision bigint not null default 1 check (revision >= 1),
  updated_at timestamptz not null default now()
);

comment on table app.identity_grant_sets is
  'owner: identity. One revisioned grant aggregate per member (expected_revision of grant commands).';

insert into app.identity_grant_sets (member_id) select m.member_id from app.identity_members m;

create function app.identity_on_member_inserted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into app.identity_grant_sets (member_id) values (new.member_id);
  return null;
end;
$$;

create trigger identity_member_grant_set
  after insert on app.identity_members
  for each row
  execute function app.identity_on_member_inserted();

create table app.identity_grants (
  grant_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_grant_sets (member_id),
  role text references app.identity_roles (role),
  scope_kind text references app.identity_scope_kinds (scope_kind),
  scope_id uuid,
  granted_at timestamptz not null default now(),
  granted_by_member uuid,
  granted_by_account uuid,
  granted_by_operator text,
  revoked_at timestamptz,
  revoked_by_member uuid,
  revoked_by_account uuid,
  check ((role is not null and scope_kind is null and scope_id is null)
         or (role is null and scope_kind is not null and scope_id is not null)),
  check ((granted_by_operator is not null and granted_by_member is null and granted_by_account is null)
         or (granted_by_operator is null and granted_by_member is not null
             and granted_by_account is not null)),
  check ((revoked_at is null) = (revoked_by_member is null)
         and (revoked_at is null) = (revoked_by_account is null))
);

comment on table app.identity_grants is
  'owner: identity. Role and scope grants with attribution. Effective only while active and '
  'only through the live-access predicate.';

create unique index identity_grants_one_active_role
  on app.identity_grants (member_id, role) where revoked_at is null and role is not null;
create unique index identity_grants_one_active_scope
  on app.identity_grants (member_id, scope_kind, scope_id)
  where revoked_at is null and scope_kind is not null;
create index identity_grants_active_by_role
  on app.identity_grants (role) where revoked_at is null and role is not null;
create index identity_grants_active_by_scope
  on app.identity_grants (scope_kind, scope_id) where revoked_at is null and scope_kind is not null;

-- Content-free: ids, codes and revisions only. Never names, phones, emails or free text.
create table app.identity_access_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in ('role_granted', 'role_revoked', 'scope_granted',
                                         'scope_revoked', 'admin_bootstrapped',
                                         'lead_pastor_designated', 'church_setting_approved')),
  actor_kind text not null check (actor_kind in ('member', 'operator')),
  actor_member_id uuid,
  actor_account_id uuid,
  operator text,
  request_id uuid,
  target_member_id uuid,
  grant_id uuid,
  role text,
  scope_kind text,
  scope_id uuid,
  setting text,
  revision_after bigint,
  check (actor_kind <> 'member' or (actor_member_id is not null and actor_account_id is not null
                                    and request_id is not null and operator is null)),
  check (actor_kind <> 'operator' or (operator is not null and actor_member_id is null
                                      and actor_account_id is null))
);

comment on table app.identity_access_audit is
  'owner: identity. Attributed permission changes (AD-4, AD-19): ids, codes and revisions only.';

create index identity_access_audit_target on app.identity_access_audit (target_member_id, event_id);

alter table app.identity_grant_sets enable row level security;
alter table app.identity_grants enable row level security;
alter table app.identity_access_audit enable row level security;
revoke all on table app.identity_grant_sets, app.identity_grants, app.identity_access_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_access_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Account standing: the predicate's non-session conditions, shared with the usable-Admin count
-- ---------------------------------------------------------------------------------------------

-- Everything the predicate checks about an ACCOUNT before the session's trust epoch: the Auth
-- user (not deleted, banned or anonymous), the live link to an approved member, the link state
-- and pending binding review, the approved binding against the current Auth phone/email (an
-- approved recovery email only while confirmed) and open holds.
--   outcome: 'untrusted_session' | 'not_linked' | 'review_required' | 'ok'
create function app.identity_account_standing(p_auth_user_id uuid)
returns table (outcome text, member_id uuid, link_id uuid, sessions_valid_after timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_phone text;
  v_email text;
  v_email_confirmed boolean;
  v_link app.identity_account_links;
  v_member app.identity_members;
begin
  select nullif(btrim(u.phone), ''), lower(nullif(btrim(u.email), '')),
         u.email_confirmed_at is not null
    into v_phone, v_email, v_email_confirmed
    from auth.users u
   where u.id = p_auth_user_id
     and u.deleted_at is null
     and not coalesce(u.is_anonymous, false)
     and (u.banned_until is null or u.banned_until <= now());
  if not found then
    return query select 'untrusted_session'::text, null::uuid, null::uuid, null::timestamptz;
    return;
  end if;

  -- No row lock: the predicate must also run inside read-only (GET) requests.
  select l.* into v_link
    from app.identity_account_links l
   where l.auth_user_id = p_auth_user_id and l.link_state <> 'ended';
  if not found then
    return query select 'not_linked'::text, null::uuid, null::uuid, null::timestamptz;
    return;
  end if;
  select m.* into v_member from app.identity_members m where m.member_id = v_link.member_id;
  if v_member.membership_state <> 'approved' then
    return query select 'not_linked'::text, null::uuid, null::uuid, null::timestamptz;
    return;
  end if;
  if v_link.link_state <> 'active' or v_link.binding_review_required
     or v_phone is null
     or '+' || ltrim(v_phone, '+') <> v_link.approved_phone
     or coalesce(v_email, '') <> coalesce(v_link.approved_recovery_email, '')
     or (v_link.approved_recovery_email is not null and not v_email_confirmed)
     or exists (select 1 from app.identity_holds h
                 where h.member_id = v_member.member_id and h.released_at is null) then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id,
                        v_link.sessions_valid_after;
    return;
  end if;
  return query select 'ok'::text, v_member.member_id, v_link.link_id, v_link.sessions_valid_after;
end;
$$;

-- Dormancy against the PREVIOUSLY stored activity: null when in use, 'unavailable' when the
-- dormancy setting is unset here, 'review_required' when dormant.
create function app.identity_link_dormancy(p_link_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days integer := (app.identity_setting('dormancy_days') ->> 'days')::integer;
begin
  if v_days is null then
    return 'unavailable';
  end if;
  if exists (select 1 from app.identity_account_links l
              where l.link_id = p_link_id
                and coalesce(l.last_member_activity_at, l.approved_at)
                    < now() - make_interval(days => v_days)) then
    return 'review_required';
  end if;
  return null;
end;
$$;

-- The live-access predicate (2.1, 2.2), same signature and outcomes in the same order, now
-- composed of the shared standing helpers:
--   unauthenticated -> untrusted_session (JWT / session / server AMR) -> account standing
--   (untrusted_session, not_linked, review_required) -> untrusted_session (trust epoch)
--   -> dormancy (unavailable, review_required) -> unavailable (release gate) -> granted.
create or replace function app.identity_access_evaluate()
returns table (outcome text, member_id uuid, link_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_claims jsonb := app.identity_request_claims();
  v_sub uuid;
  v_session uuid;
  v_session_created timestamptz;
  v_standing record;
  v_dormancy text;
begin
  if coalesce(v_claims ->> 'sub', '') !~* c_uuid then
    return query select 'unauthenticated'::text, null::uuid, null::uuid;
    return;
  end if;
  v_sub := (v_claims ->> 'sub')::uuid;

  -- Session half (story 1.2): signed `password` AMR AND a live session row for this subject.
  if coalesce(v_claims ->> 'role', '') <> 'authenticated'
     or coalesce(v_claims ->> 'is_anonymous', 'false') = 'true'
     or jsonb_typeof(v_claims -> 'amr') is distinct from 'array'
     or not exists (
       select 1 from jsonb_array_elements(v_claims -> 'amr') a(entry)
        where jsonb_typeof(a.entry) = 'object' and a.entry ->> 'method' = 'password')
     or coalesce(v_claims ->> 'session_id', '') !~* c_uuid then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;
  v_session := (v_claims ->> 'session_id')::uuid;
  select s.created_at into v_session_created
    from auth.sessions s
   where s.id = v_session and s.user_id = v_sub
     and (s.not_after is null or s.not_after > now());
  if not found then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;
  -- Story 2.2: the server's own record of how this session authenticated must say `password`.
  if not exists (
    select 1 from auth.mfa_amr_claims c
     where c.session_id = v_session and c.authentication_method = 'password') then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  select st.* into v_standing from app.identity_account_standing(v_sub) st;
  if v_standing.outcome in ('untrusted_session', 'not_linked') then
    return query select v_standing.outcome, null::uuid, null::uuid;
    return;
  elsif v_standing.outcome <> 'ok' then
    return query select v_standing.outcome, v_standing.member_id, v_standing.link_id;
    return;
  end if;

  -- Sessions from before a credential change, hold or review stay dead: sign in again.
  if v_standing.sessions_valid_after is not null
     and (v_session_created is null
          or v_session_created <= v_standing.sessions_valid_after + app.identity_epoch_margin()) then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  v_dormancy := app.identity_link_dormancy(v_standing.link_id);
  if v_dormancy is not null then
    return query select v_dormancy, v_standing.member_id, v_standing.link_id;
    return;
  end if;

  if not (app.policy_is_open('private_access')
          or (exists (select 1 from app.identity_members m
                       where m.member_id = v_standing.member_id and m.is_synthetic)
              and app.platform_current_environment() in ('local', 'staging')
              and not app.rcv_serving_hold())) then
    return query select 'unavailable'::text, v_standing.member_id, v_standing.link_id;
    return;
  end if;

  return query select 'granted'::text, v_standing.member_id, v_standing.link_id;
end;
$$;

comment on function app.identity_access_evaluate() is
  'AD-3 live-access predicate for human sessions (2.1, hardened by 2.2, factored by 2.3). Every '
  'protected surface must use it.';

-- ---------------------------------------------------------------------------------------------
-- Grant evaluation (composes the live-access predicate; reads current rows every call)
-- ---------------------------------------------------------------------------------------------

-- Is this role in force for the member right now (active grant, required setting in force)?
create function app.identity_member_has_role(p_member_id uuid, p_role text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from app.identity_grants g
      join app.identity_roles r on r.role = g.role
     where g.member_id = p_member_id and g.role = p_role and g.revoked_at is null
       and (r.requires_setting is null or app.identity_church_setting_enabled(r.requires_setting)));
$$;

create function app.identity_member_has_scope(p_member_id uuid, p_scope_kind text, p_scope_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from app.identity_grants g
     where g.member_id = p_member_id and g.scope_kind = p_scope_kind and g.scope_id = p_scope_id
       and g.revoked_at is null);
$$;

-- The caller's live access (identity_access_evaluate) AND, when asked, the role or scope.
-- Exactly one of p_role or (p_scope_kind, p_scope_id) may be given; neither = access only.
create function app.identity_evaluate_grant(p_role text, p_scope_kind text, p_scope_id uuid)
returns table (outcome text, member_id uuid, link_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r record;
begin
  if p_role is not null and (p_scope_kind is not null or p_scope_id is not null) then
    raise exception using errcode = '22023', message = 'ask for a role or a scope, not both';
  end if;
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome <> 'granted' then
    return query select r.outcome, r.member_id, r.link_id;
    return;
  end if;
  if (p_role is not null and not app.identity_member_has_role(r.member_id, p_role))
     or (p_role is null and (p_scope_kind is not null or p_scope_id is not null)
         and not app.identity_member_has_scope(r.member_id, p_scope_kind, p_scope_id)) then
    return query select 'not_granted'::text, r.member_id, r.link_id;
    return;
  end if;
  return query select 'granted'::text, r.member_id, r.link_id;
end;
$$;

comment on function app.identity_evaluate_grant(text, text, uuid) is
  'AD-3/AD-4 grant check for human sessions: the live-access predicate plus the current role or '
  'scope grant. For owner reads, RLS policies and commands.';

create function app.identity_has_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select e.outcome = 'granted'
                     from app.identity_evaluate_grant(p_role, null, null) e), false)
     and p_role is not null;
$$;

create function app.identity_has_scope(p_scope_kind text, p_scope_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select e.outcome = 'granted'
                     from app.identity_evaluate_grant(null, p_scope_kind, p_scope_id) e), false)
     and p_scope_kind is not null and p_scope_id is not null;
$$;

-- Raises the denial like identity_require_access (PT401 for unauthenticated/untrusted sessions,
-- PT403 otherwise; detail = the caller's own reason, 'not_granted' when only the grant is
-- missing). With p_lock, share-locks the grant row so a concurrent revocation waits for this
-- command (never use p_lock in a read-only request).
create function app.identity_require_grant(
  p_role text,
  p_scope_kind text,
  p_scope_id uuid,
  p_lock boolean default false
) returns table (member_id uuid, link_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  if p_role is null and (p_scope_kind is null or p_scope_id is null) then
    raise exception using errcode = '22023', message = 'a role or a complete scope is required';
  end if;
  select e.* into r from app.identity_evaluate_grant(p_role, p_scope_kind, p_scope_id) e;
  if r.outcome = 'granted' and p_lock then
    perform 1 from app.identity_grants g
     where g.member_id = r.member_id and g.revoked_at is null
       and ((p_role is not null and g.role = p_role)
            or (p_role is null and g.scope_kind = p_scope_kind and g.scope_id = p_scope_id))
       for share;
    if not found then
      r.outcome := 'not_granted';
    end if;
  end if;
  if r.outcome = 'granted' then
    return query select r.member_id, r.link_id;
    return;
  end if;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = r.outcome;
  elsif r.outcome = 'unavailable' then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = r.outcome;
  else
    raise exception using errcode = 'PT403', message = 'forbidden', detail = r.outcome;
  end if;
end;
$$;

-- Admins whose access is usable now: an active Admin grant whose account passes every
-- non-session condition of the predicate (app.identity_account_standing = 'ok' and not dormant;
-- the dormancy setting must be in force). Optionally excludes one member. Not counted: the
-- caller's session itself and the environment's release gate.
create function app.identity_usable_admin_count(p_except_member uuid default null)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from app.identity_grants g
    join app.identity_account_links l on l.member_id = g.member_id and l.link_state <> 'ended'
   cross join lateral app.identity_account_standing(l.auth_user_id) st
   where g.role = 'admin' and g.revoked_at is null
     and (p_except_member is null or g.member_id <> p_except_member)
     and st.outcome = 'ok' and st.member_id = g.member_id
     and app.identity_link_dormancy(l.link_id) is null;
$$;

-- Wire form of one member's current grants (effective roles only).
create function app.identity_member_grants_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', s.member_id,
    'revision', s.revision,
    'roles', coalesce((
      select jsonb_agg(r.role order by r.sort_order)
        from app.identity_roles r
       where app.identity_member_has_role(s.member_id, r.role)), '[]'::jsonb),
    'scopes', coalesce((
      select jsonb_agg(jsonb_build_object('scope_kind', g.scope_kind, 'scope_id', g.scope_id)
                       order by g.scope_kind, g.scope_id)
        from app.identity_grants g
       where g.member_id = s.member_id and g.scope_kind is not null and g.revoked_at is null),
      '[]'::jsonb))
    from app.identity_grant_sets s
   where s.member_id = p_member_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Grant commands (1.4 envelope)
-- ---------------------------------------------------------------------------------------------

-- Registered authorizer for `identity.*`: the caller must pass the live-access predicate and
-- hold Admin now. Every grant command serialises on the admin catalogue row, then share-locks
-- the actor's own Admin grant (a concurrent revocation of it waits; a later one is seen).
create function app.identity_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in ('identity.grant_role', 'identity.revoke_role',
                                     'identity.grant_scope', 'identity.revoke_scope') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant('admin', null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.role = 'admin' and g.revoked_at is null
     for share;
  return found;
end;
$$;

-- The acting Admin (authorised above in the same transaction) and its account.
create function app.identity_command_actor(p_actor uuid, out member_id uuid, out account_id uuid)
language plpgsql
set search_path = ''
as $$
begin
  select e.member_id into member_id from app.identity_evaluate_grant('admin', null, null) e
   where e.outcome = 'granted';
  if member_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  account_id := p_actor;
end;
$$;

-- Validates the payload keys and member_id, locks the target grant set and checks the revision.
create function app.identity_lock_grant_set(
  p_payload jsonb,
  p_allowed text[],
  p_expected_revision bigint
) returns app.identity_grant_sets
language plpgsql
set search_path = ''
as $$
declare
  v_set app.identity_grant_sets;
  v_err text;
begin
  if exists (select 1 from jsonb_object_keys(p_payload) k where k <> all (p_allowed)) then
    perform app.cmd_fail('validation_failed', '{"payload": "unknown_field"}');
  end if;
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('member_id', v_err));
  end if;
  select s.* into v_set from app.identity_grant_sets s
   where s.member_id = (p_payload ->> 'member_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_set.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  return v_set;
end;
$$;

create function app.identity_bump_grant_set(p_member_id uuid)
returns bigint
language sql
set search_path = ''
as $$
  update app.identity_grant_sets s
     set revision = s.revision + 1, updated_at = now()
   where s.member_id = p_member_id
  returning s.revision;
$$;

create function app.identity_grant_outcome(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_member_grants',
    'aggregate_id', p_member_id,
    'revision', (app.identity_member_grants_json(p_member_id) ->> 'revision')::bigint,
    'data', app.identity_member_grants_json(p_member_id));
$$;

create function app.identity_role_payload(p_payload jsonb)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if jsonb_typeof(p_payload -> 'role') is distinct from 'string' then
    perform app.cmd_fail('validation_failed', '{"role": "required"}');
  end if;
  if not exists (select 1 from app.identity_roles r where r.role = p_payload ->> 'role') then
    perform app.cmd_fail('validation_failed', '{"role": "invalid"}');
  end if;
  return p_payload ->> 'role';
end;
$$;

create function app.identity_scope_payload(p_payload jsonb, out scope_kind text, out scope_id uuid)
language plpgsql
set search_path = ''
as $$
declare
  v_err text;
begin
  if app.contract_token_error(p_payload -> 'scope_kind') is not null then
    perform app.cmd_fail('validation_failed',
      jsonb_build_object('scope_kind', app.contract_token_error(p_payload -> 'scope_kind')));
  end if;
  if not exists (select 1 from app.identity_scope_kinds k
                  where k.scope_kind = p_payload ->> 'scope_kind') then
    perform app.cmd_fail('validation_failed', '{"scope_kind": "unregistered"}');
  end if;
  v_err := app.contract_uuid_error(p_payload -> 'scope_id');
  if v_err is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('scope_id', v_err));
  end if;
  scope_kind := p_payload ->> 'scope_kind';
  scope_id := (p_payload ->> 'scope_id')::uuid;
end;
$$;

-- identity.grant_role  payload {member_id, role}; expected_revision = the member's grant set.
create function app.identity_grant_role(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_set app.identity_grant_sets;
  v_role text;
  v_setting text;
  v_grant uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_set := app.identity_lock_grant_set(p_payload, array['member_id', 'role'], p_expected_revision);
  v_role := app.identity_role_payload(p_payload);
  -- Separation of duty: an Admin never grants to their own member record.
  if v_set.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  -- The lead-pastor designation is made only by the restricted operator procedure.
  if v_role = 'lead_pastor' then
    perform app.cmd_fail('forbidden', '{"role": "unsupported"}');
  end if;
  -- Roles are for approved members with a live account link.
  if not exists (select 1 from app.identity_members m
                  where m.member_id = v_set.member_id and m.membership_state = 'approved')
     or not exists (select 1 from app.identity_account_links l
                     where l.member_id = v_set.member_id and l.link_state <> 'ended') then
    perform app.cmd_fail('validation_failed', '{"member_id": "invalid"}');
  end if;
  select r.requires_setting into v_setting from app.identity_roles r where r.role = v_role;
  if v_setting is not null and not app.identity_church_setting_enabled(v_setting) then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if exists (select 1 from app.identity_grants g
              where g.member_id = v_set.member_id and g.role = v_role and g.revoked_at is null) then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  insert into app.identity_grants (member_id, role, granted_by_member, granted_by_account)
  values (v_set.member_id, v_role, v_actor.member_id, v_actor.account_id)
  returning grant_id into v_grant;
  v_revision := app.identity_bump_grant_set(v_set.member_id);
  insert into app.identity_access_audit (action, actor_kind, actor_member_id, actor_account_id,
                                         request_id, target_member_id, grant_id, role,
                                         revision_after)
  values ('role_granted', 'member', v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.grant_role'), v_set.member_id, v_grant,
          v_role, v_revision);
  return app.identity_grant_outcome(v_set.member_id);
end;
$$;

-- Ends one active grant: attribution, revision, audit and the scope_revoked lifecycle event.
create function app.identity_end_grant(
  p_actor uuid,
  p_actor_member uuid,
  p_command text,
  p_grant app.identity_grants
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  update app.identity_grants g
     set revoked_at = now(), revoked_by_member = p_actor_member, revoked_by_account = p_actor
   where g.grant_id = p_grant.grant_id;
  v_revision := app.identity_bump_grant_set(p_grant.member_id);
  insert into app.identity_access_audit (action, actor_kind, actor_member_id, actor_account_id,
                                         request_id, target_member_id, grant_id, role,
                                         scope_kind, scope_id, revision_after)
  values (case when p_grant.role is not null then 'role_revoked' else 'scope_revoked' end,
          'member', p_actor_member, p_actor, app.cmd_current_request_id(p_actor, p_command),
          p_grant.member_id, p_grant.grant_id, p_grant.role, p_grant.scope_kind,
          p_grant.scope_id, v_revision);
  -- Owners registered for scope_revoked run inside this transaction (AD-14 hook seam).
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'scope_revoked',
    'member_id', p_grant.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
end;
$$;

-- identity.revoke_role  payload {member_id, role}. The last usable Admin cannot be removed.
create function app.identity_revoke_role(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_set app.identity_grant_sets;
  v_role text;
  v_grant app.identity_grants;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_set := app.identity_lock_grant_set(p_payload, array['member_id', 'role'], p_expected_revision);
  v_role := app.identity_role_payload(p_payload);
  select g.* into v_grant from app.identity_grants g
   where g.member_id = v_set.member_id and g.role = v_role and g.revoked_at is null
     for update;
  if not found then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  -- Grant commands are serialised on the admin catalogue row by the authorizer, so two Admins
  -- removing each other cannot both succeed. A hold, link change or Auth change committed
  -- concurrently (or later) is NOT serialised here and is never blocked: it can still leave
  -- zero usable Admins. The designed way out is the restricted-operator bootstrap, which is
  -- allowed exactly while no usable Admin exists.
  if v_role = 'admin' and app.identity_usable_admin_count(v_set.member_id) = 0 then
    perform app.cmd_fail('forbidden', '{"role": "unsupported"}');
  end if;
  perform app.identity_end_grant(p_actor, v_actor.member_id, 'identity.revoke_role', v_grant);
  return app.identity_grant_outcome(v_set.member_id);
end;
$$;

-- identity.grant_scope  payload {member_id, scope_kind, scope_id}; the owner's hook checks the
-- target. Scopes are for approved members (an accountless member may hold one; it only takes
-- effect through a live account link).
create function app.identity_grant_scope(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_set app.identity_grant_sets;
  v_scope record;
  v_grant uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_set := app.identity_lock_grant_set(p_payload, array['member_id', 'scope_kind', 'scope_id'],
                                       p_expected_revision);
  select sp.* into v_scope from app.identity_scope_payload(p_payload) sp;
  -- Separation of duty: an Admin never grants a scope (care, finance ...) to themselves.
  if v_set.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if not exists (select 1 from app.identity_members m
                  where m.member_id = v_set.member_id and m.membership_state = 'approved') then
    perform app.cmd_fail('validation_failed', '{"member_id": "invalid"}');
  end if;
  if not app.identity_scope_target_ok(v_scope.scope_kind, v_scope.scope_id) then
    perform app.cmd_fail('validation_failed', '{"scope_id": "unknown"}');
  end if;
  if exists (select 1 from app.identity_grants g
              where g.member_id = v_set.member_id and g.scope_kind = v_scope.scope_kind
                and g.scope_id = v_scope.scope_id and g.revoked_at is null) then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_member,
                                   granted_by_account)
  values (v_set.member_id, v_scope.scope_kind, v_scope.scope_id, v_actor.member_id,
          v_actor.account_id)
  returning grant_id into v_grant;
  v_revision := app.identity_bump_grant_set(v_set.member_id);
  insert into app.identity_access_audit (action, actor_kind, actor_member_id, actor_account_id,
                                         request_id, target_member_id, grant_id, scope_kind,
                                         scope_id, revision_after)
  values ('scope_granted', 'member', v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.grant_scope'), v_set.member_id, v_grant,
          v_scope.scope_kind, v_scope.scope_id, v_revision);
  return app.identity_grant_outcome(v_set.member_id);
end;
$$;

-- identity.revoke_scope  payload {member_id, scope_kind, scope_id}.
create function app.identity_revoke_scope(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_set app.identity_grant_sets;
  v_scope record;
  v_grant app.identity_grants;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_set := app.identity_lock_grant_set(p_payload, array['member_id', 'scope_kind', 'scope_id'],
                                       p_expected_revision);
  select sp.* into v_scope from app.identity_scope_payload(p_payload) sp;
  select g.* into v_grant from app.identity_grants g
   where g.member_id = v_set.member_id and g.scope_kind = v_scope.scope_kind
     and g.scope_id = v_scope.scope_id and g.revoked_at is null
     for update;
  if not found then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  perform app.identity_end_grant(p_actor, v_actor.member_id, 'identity.revoke_scope', v_grant);
  return app.identity_grant_outcome(v_set.member_id);
end;
$$;

-- Replay seam: authority was already rechecked by the authorizer before any replay; the
-- receipt must name a grant aggregate.
create function app.identity_grants_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_type = 'identity_member_grants' and p_aggregate_id is not null
     and exists (select 1 from app.identity_grant_sets s where s.member_id = p_aggregate_id);
$$;

create function app.identity_grant_command(p_envelope jsonb)
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
      when 'identity.grant_role' then 'app.identity_grant_role(uuid, bigint, jsonb)'::regprocedure
      when 'identity.revoke_role' then 'app.identity_revoke_role(uuid, bigint, jsonb)'::regprocedure
      when 'identity.grant_scope' then 'app.identity_grant_scope(uuid, bigint, jsonb)'::regprocedure
      when 'identity.revoke_scope' then 'app.identity_revoke_scope(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_grants_in_scope(uuid, text, uuid)'::regprocedure,
    true
  );
end;
$$;

-- POST /rest/v1/rpc/identity_grant_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_grant_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_grant_command($1);
$$;

comment on function api.identity_grant_command(jsonb) is
  'Story 2.3: Admin grant/revoke of roles and scopes (identity.grant_role, identity.revoke_role, '
  'identity.grant_scope, identity.revoke_scope) through the 1.4 command envelope.';

select app.cmd_register_authorizer('identity', 'app.identity_authorize_command(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Reads: the caller's own access (navigation) and the Admin grant list
-- ---------------------------------------------------------------------------------------------

-- The signed-in member's current roles and scopes. Clients build navigation from this and
-- re-read it on every navigation; it is presentation only, never the security control.
create function app.identity_my_access()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_link_id uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member_id, v_link_id from app.identity_require_access() a;
  v_result := app.identity_member_grants_json(v_member_id);
  perform app.identity_record_activity(v_link_id);
  return v_result;
end;
$$;

create function api.identity_my_access()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_access();
$$;

comment on function api.identity_my_access() is
  'Story 2.3: the signed-in member''s current roles and scopes, behind the live-access '
  'predicate. POST /rest/v1/rpc/identity_my_access with Content-Profile: api.';

-- Admin only: approved members with their account state and grants, in pages of 50 ordered by
-- (display_name, member_id). Basic membership administration only: no care or finance fields.
create function app.identity_admin_member_grants(p_after_display_name text, p_after_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_rows jsonb;
  v_count integer;
begin
  select g.link_id into v_link_id from app.identity_require_grant('admin', null, null) g;
  if (p_after_display_name is null) <> (p_after_member_id is null) then
    raise exception using errcode = '22023', message = 'cursor needs both parts';
  end if;
  select coalesce(jsonb_agg(x.obj order by x.rn) filter (where x.rn <= 50), '[]'::jsonb),
         count(*)
    into v_rows, v_count
    from (
      select row_number() over (order by m.display_name collate "C", m.member_id) as rn,
             jsonb_build_object(
               'member_id', m.member_id,
               'display_name', m.display_name,
               'is_synthetic', m.is_synthetic,
               'account', case
                 when l.link_id is null then 'no_login'
                 when l.link_state = 'active' and not l.binding_review_required
                      and not exists (select 1 from app.identity_holds h
                                       where h.member_id = m.member_id and h.released_at is null)
                   then 'app_account'
                 else 'access_review' end,
               'grants', app.identity_member_grants_json(m.member_id)) as obj
        from app.identity_members m
        left join app.identity_account_links l
          on l.member_id = m.member_id and l.link_state <> 'ended'
       where m.membership_state = 'approved'
         and (p_after_display_name is null
              or (m.display_name collate "C", m.member_id)
                 > (p_after_display_name collate "C", p_after_member_id))
       order by m.display_name collate "C", m.member_id
       limit 51
    ) x;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object(
    'members', v_rows,
    'next', case when v_count > 50
                 then jsonb_build_object('after_display_name', v_rows -> 49 ->> 'display_name',
                                         'after_member_id', v_rows -> 49 ->> 'member_id')
                 end,
    'roles', (select jsonb_agg(jsonb_build_object(
                       'role', r.role,
                       -- lead_pastor is designated by the restricted operator, never here.
                       'available', r.role <> 'lead_pastor'
                                    and (r.requires_setting is null
                                         or app.identity_church_setting_enabled(r.requires_setting)))
                     order by r.sort_order)
                from app.identity_roles r),
    'scope_kinds', coalesce((select jsonb_agg(k.scope_kind order by k.scope_kind)
                               from app.identity_scope_kinds k), '[]'::jsonb));
end;
$$;

create function api.identity_admin_member_grants(
  after_display_name text default null,
  after_member_id uuid default null
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_member_grants(after_display_name, after_member_id);
$$;

comment on function api.identity_admin_member_grants(text, uuid) is
  'Story 2.3: Admin-only page of approved members with account state and current grants.';

-- ---------------------------------------------------------------------------------------------
-- Restricted operator: first-Admin bootstrap (no client grants)
-- ---------------------------------------------------------------------------------------------

-- Grants Admin to an approved member with an active link, ONLY while no usable Admin exists
-- (first Admin, or recovery when every Admin is held/in review). Audited with the operator.
create function app.identity_bootstrap_admin(p_member_id uuid, p_operator text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_grant uuid;
  v_revision bigint;
begin
  perform app.ops_require_operator(p_operator);
  perform 1 from app.identity_roles r where r.role = 'admin' for update;
  if app.identity_usable_admin_count(null) > 0 then
    raise exception using errcode = '22023',
      message = 'a usable Admin exists: grant Admin through the audited Admin command';
  end if;
  if not exists (select 1 from app.identity_account_links l
                  cross join lateral app.identity_account_standing(l.auth_user_id) st
                 where l.member_id = p_member_id and l.link_state <> 'ended'
                   and st.outcome = 'ok' and app.identity_link_dormancy(l.link_id) is null) then
    raise exception using errcode = '22023',
      message = 'the member must be approved with a usable account link';
  end if;
  perform 1 from app.identity_grant_sets s where s.member_id = p_member_id for update;
  if exists (select 1 from app.identity_grants g
              where g.member_id = p_member_id and g.role = 'admin' and g.revoked_at is null) then
    raise exception using errcode = '22023', message = 'the member already holds Admin';
  end if;
  insert into app.identity_grants (member_id, role, granted_by_operator)
  values (p_member_id, 'admin', p_operator)
  returning grant_id into v_grant;
  v_revision := app.identity_bump_grant_set(p_member_id);
  insert into app.identity_access_audit (action, actor_kind, operator, target_member_id, grant_id,
                                         role, revision_after)
  values ('admin_bootstrapped', 'operator', p_operator, p_member_id, v_grant, 'admin', v_revision);
  perform app.ops_record_action(p_operator, 'admin_bootstrapped', v_grant);
  return v_grant;
end;
$$;

comment on function app.identity_bootstrap_admin(uuid, text) is
  'Restricted operator only (no grants): first Admin, or recovery when no usable Admin exists.';

-- Designates the lead pastor (Q4): only this restricted-operator procedure grants `lead_pastor`,
-- naming one member, and only while the lead_pastor_designation setting is in force (approved,
-- or the labelled fixture in local/staging). Journalled and audited. Admins may still remove
-- the role through identity.revoke_role (removing access is never an escalation).
create function app.identity_designate_lead_pastor(p_member_id uuid, p_operator text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_grant uuid;
  v_revision bigint;
begin
  perform app.ops_require_operator(p_operator);
  if not app.identity_church_setting_enabled('lead_pastor_designation') then
    raise exception using errcode = '22023',
      message = 'the lead-pastor designation is not approved for this environment (Q4)';
  end if;
  if not exists (select 1 from app.identity_members m
                  join app.identity_account_links l on l.member_id = m.member_id
                 where m.member_id = p_member_id and m.membership_state = 'approved'
                   and l.link_state <> 'ended') then
    raise exception using errcode = '22023',
      message = 'the member must be approved with a live account link';
  end if;
  perform 1 from app.identity_grant_sets s where s.member_id = p_member_id for update;
  if exists (select 1 from app.identity_grants g
              where g.member_id = p_member_id and g.role = 'lead_pastor' and g.revoked_at is null) then
    raise exception using errcode = '22023', message = 'the member is already lead pastor';
  end if;
  insert into app.identity_grants (member_id, role, granted_by_operator)
  values (p_member_id, 'lead_pastor', p_operator)
  returning grant_id into v_grant;
  v_revision := app.identity_bump_grant_set(p_member_id);
  insert into app.identity_access_audit (action, actor_kind, operator, target_member_id, grant_id,
                                         role, revision_after)
  values ('lead_pastor_designated', 'operator', p_operator, p_member_id, v_grant, 'lead_pastor',
          v_revision);
  perform app.ops_record_action(p_operator, 'lead_pastor_designated', v_grant);
  return v_grant;
end;
$$;

comment on function app.identity_designate_lead_pastor(uuid, text) is
  'Restricted operator only (no grants): names the lead pastor under the Q4 setting.';

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC fixture scopes: prove that Admin and combined roles reach no care/finance surface
-- ---------------------------------------------------------------------------------------------

-- The fixture module may use Identity access checks like every owner (its 1.5 exclusion only
-- reflected that it had no reason to yet).
insert into app.contract_module_dependencies (from_module, to_module) values ('fixture', 'identity');

create table app.fixture_scope_targets (
  scope_kind text not null check (scope_kind in ('fixture_care', 'fixture_finance')),
  scope_id uuid not null,
  is_synthetic boolean not null default true check (is_synthetic),
  created_at timestamptz not null default now(),
  primary key (scope_kind, scope_id)
);

comment on table app.fixture_scope_targets is
  'owner: fixture. SYNTHETIC scope targets standing in for later care/finance owners.';

alter table app.fixture_scope_targets enable row level security;
revoke all on table app.fixture_scope_targets from public, anon, authenticated, service_role;

create function app.fixture_scope_target_exists(p_scope jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.fixture_scope_targets t
                  where t.scope_kind = p_scope ->> 'scope_kind'
                    and t.scope_id::text = p_scope ->> 'scope_id');
$$;

select app.identity_register_scope_kind('fixture', 'fixture_care',
  'app.fixture_scope_target_exists(jsonb)'::regprocedure,
  'SYNTHETIC stand-in for a care scope (the Care owner registers real kinds)');
select app.identity_register_scope_kind('fixture', 'fixture_finance',
  'app.fixture_scope_target_exists(jsonb)'::regprocedure,
  'SYNTHETIC stand-in for a finance scope (the Offerings owner registers real kinds)');

-- The fixture "care" and "finance" surfaces: readable only with the exact scope grant.
create function app.fixture_scoped_read(p_scope_kind text, p_scope_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_scope_kind is null or p_scope_kind not in ('fixture_care', 'fixture_finance')
     or p_scope_id is null then
    raise exception using errcode = '22023', message = 'unknown fixture scope';
  end if;
  perform 1 from app.identity_require_grant(null, p_scope_kind, p_scope_id);
  return jsonb_build_object('scope_kind', p_scope_kind, 'scope_id', p_scope_id,
                            'content', 'SYNTHETIC fixture surface');
end;
$$;

create function api.fixture_scoped_read(scope_kind text, scope_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.fixture_scoped_read(scope_kind, scope_id);
$$;

comment on function api.fixture_scoped_read(text, uuid) is
  'SYNTHETIC (story 2.3): a care/finance stand-in readable only with the exact scope grant.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cmd_register_authorizer(text, regprocedure),
  app.cmd_current_request_id(uuid, text),
  app.cmd_authorize(uuid, text),
  app.identity_church_setting(text),
  app.identity_church_setting_enabled(text),
  app.identity_approve_church_setting(text, jsonb, text, text),
  app.identity_register_scope_kind(text, text, regprocedure, text),
  app.identity_scope_target_ok(text, uuid),
  app.identity_on_member_inserted(),
  app.identity_member_has_role(uuid, text),
  app.identity_member_has_scope(uuid, text, uuid),
  app.identity_evaluate_grant(text, text, uuid),
  app.identity_has_role(text),
  app.identity_has_scope(text, uuid),
  app.identity_require_grant(text, text, uuid, boolean),
  app.identity_usable_admin_count(uuid),
  app.identity_member_grants_json(uuid),
  app.identity_authorize_command(jsonb),
  app.identity_command_actor(uuid),
  app.identity_lock_grant_set(jsonb, text[], bigint),
  app.identity_bump_grant_set(uuid),
  app.identity_grant_outcome(uuid),
  app.identity_role_payload(jsonb),
  app.identity_scope_payload(jsonb),
  app.identity_grant_role(uuid, bigint, jsonb),
  app.identity_end_grant(uuid, uuid, text, app.identity_grants),
  app.identity_revoke_role(uuid, bigint, jsonb),
  app.identity_grant_scope(uuid, bigint, jsonb),
  app.identity_revoke_scope(uuid, bigint, jsonb),
  app.identity_grants_in_scope(uuid, text, uuid),
  app.identity_grant_command(jsonb),
  api.identity_grant_command(jsonb),
  app.identity_my_access(),
  api.identity_my_access(),
  app.identity_admin_member_grants(text, uuid),
  api.identity_admin_member_grants(text, uuid),
  app.identity_bootstrap_admin(uuid, text),
  app.identity_designate_lead_pastor(uuid, text),
  app.identity_account_standing(uuid),
  app.identity_link_dormancy(uuid),
  app.identity_access_evaluate(),
  app.fixture_scope_target_exists(jsonb),
  app.fixture_scoped_read(text, uuid),
  api.fixture_scoped_read(text, uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.identity_grant_command(jsonb) to authenticated;
grant execute on function api.identity_grant_command(jsonb) to authenticated;
grant execute on function app.identity_my_access() to authenticated;
grant execute on function api.identity_my_access() to authenticated;
grant execute on function app.identity_admin_member_grants(text, uuid) to authenticated;
grant execute on function api.identity_admin_member_grants(text, uuid) to authenticated;
grant execute on function app.fixture_scoped_read(text, uuid) to authenticated;
grant execute on function api.fixture_scoped_read(text, uuid) to authenticated;

notify pgrst, 'reload schema';
