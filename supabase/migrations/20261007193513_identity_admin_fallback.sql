-- Story 2.12: the identity-checked last-Admin fallback (I10, AD-4, AD-19).
--
-- app.identity_bootstrap_admin (2.3) grants Admin only while NO usable Admin exists. "Usable"
-- means "passes every non-session condition of the predicate", so a sole Admin who forgot the
-- password and has no approved recovery email, or who left the church without being deactivated,
-- still counts: bootstrap refuses, and every Admin-side exit (staff-assisted recovery, a hold, a
-- deactivation) needs a second Admin. This migration adds the one missing restricted-operator
-- path:
--
--   app.identity_admin_fallback_grant(member_id, identity_check, reason_code, confirming_owner,
--                                     case_reference, operator)
--
-- * Restricted operator only (app.ops_operators); no client role has EXECUTE.
-- * Two people: a second named owner (`confirming_owner`, an identifier distinct from the
--   operator) confirms the case, and a case reference ties the grant to the owners' restricted
--   case note. Both are stored.
-- * reason_code must match the real Admin state: `no_usable_admin` only while no usable Admin
--   exists, `admins_unreachable` only while at least one exists (the named owners confirmed that
--   none of them can act). identity_check is `in_person` or `established_relationship`.
-- * The member must be approved, with a live account link whose account passes
--   app.identity_account_standing (= 'ok': not deleted, banned or anonymous; link active; no
--   binding review; Auth phone and email equal the approved binding; no open hold), not dormant,
--   not under deletion, with no active scope grant (care, finance, cell, ...), and must not
--   already hold Admin.
-- * It writes NO Auth row: no password, session, token or link is created or changed. Like
--   identity.grant_role, the role applies to the member's next protected call, including calls of
--   a session they already have.
-- * Audited with the DISTINCT action `admin_fallback_granted` in app.identity_access_audit and in
--   the restricted-operator journal app.ops_operator_actions, plus a row in the new
--   app.identity_admin_fallbacks. Both action lists are inline CHECKs, and widening a CHECK needs
--   removing the old constraint, which the non-destructive policy forbids; so, as story 2.3 did for the
--   journal, each table is retired by rename (rows copied first, every privilege revoked) and
--   recreated with the same shape and a wider list. Functions name the tables, so they write to
--   the new ones unchanged. The retired access audit is added to the deletion retention rules so
--   a deletion anonymises its account ids too. The retired tables are dropped by a later
--   owner-approved cleanup.
-- * Visible to every Admin: app.identity_admin_member_grants (Roles & access) carries
--   `admin_via_fallback` for a member whose active Admin grant came from this command.
--
-- No row deletions, no destructive statements.

-- ---------------------------------------------------------------------------------------------
-- Retire and recreate app.identity_access_audit with `admin_fallback_granted`
-- ---------------------------------------------------------------------------------------------

alter table app.identity_access_audit rename to identity_retired_access_audit_v0;
alter index app.identity_access_audit_pkey rename to identity_retired_access_audit_v0_pkey;
alter index app.identity_access_audit_target rename to identity_retired_access_audit_v0_target;
alter sequence app.identity_access_audit_event_id_seq rename to identity_retired_access_audit_v0_event_id_seq;
revoke all on table app.identity_retired_access_audit_v0 from public, anon, authenticated, service_role;
revoke all on sequence app.identity_retired_access_audit_v0_event_id_seq
  from public, anon, authenticated, service_role;
comment on table app.identity_retired_access_audit_v0 is
  'owner: identity. RETIRED (story 2.12): rows copied to app.identity_access_audit; dropped by a '
  'later owner-approved cleanup.';

create table app.identity_access_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in ('role_granted', 'role_revoked', 'scope_granted',
                                         'scope_revoked', 'admin_bootstrapped',
                                         'lead_pastor_designated', 'church_setting_approved',
                                         'admin_fallback_granted')),
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

insert into app.identity_access_audit (event_id, occurred_at, environment, action, actor_kind,
                                       actor_member_id, actor_account_id, operator, request_id,
                                       target_member_id, grant_id, role, scope_kind, scope_id,
                                       setting, revision_after)
overriding system value
select r.event_id, r.occurred_at, r.environment, r.action, r.actor_kind, r.actor_member_id,
       r.actor_account_id, r.operator, r.request_id, r.target_member_id, r.grant_id, r.role,
       r.scope_kind, r.scope_id, r.setting, r.revision_after
  from app.identity_retired_access_audit_v0 r;
select setval(pg_catalog.pg_get_serial_sequence('app.identity_access_audit', 'event_id'),
              coalesce((select max(a.event_id) from app.identity_access_audit a), 0) + 1, false);

create index identity_access_audit_target on app.identity_access_audit (target_member_id, event_id);

alter table app.identity_access_audit enable row level security;
revoke all on table app.identity_access_audit from public, anon, authenticated, service_role;
revoke all on sequence app.identity_access_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- A deletion anonymises the retired copy's account ids as it does the live table's.
insert into app.identity_deletion_retention_rules (table_name, column_name, rule, label)
values ('identity_retired_access_audit_v0', 'actor_account_id', 'anonymise_account',
        'FIXTURE - Q4 retention unapproved');

-- ---------------------------------------------------------------------------------------------
-- Retire and recreate app.ops_operator_actions with `admin_fallback_granted`
-- ---------------------------------------------------------------------------------------------

alter table app.ops_operator_actions rename to ops_retired_operator_actions_v1;
alter index app.ops_operator_actions_pkey rename to ops_retired_operator_actions_v1_pkey;
alter sequence app.ops_operator_actions_id_seq rename to ops_retired_operator_actions_v1_id_seq;
revoke all on table app.ops_retired_operator_actions_v1 from public, anon, authenticated, service_role;
revoke all on sequence app.ops_retired_operator_actions_v1_id_seq
  from public, anon, authenticated, service_role;
comment on table app.ops_retired_operator_actions_v1 is
  'RETIRED (story 2.12): rows copied to app.ops_operator_actions; dropped by a later owner-approved cleanup.';

create table app.ops_operator_actions (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  operator text not null references app.ops_operators (operator),
  action text not null check (action in (
    'principal_created', 'principal_disabled', 'credential_registered', 'credential_revoked',
    'admin_bootstrapped', 'lead_pastor_designated', 'church_setting_approved',
    'admin_fallback_granted')),
  target_id uuid,
  check (target_id is not null or action = 'church_setting_approved')
);

comment on table app.ops_operator_actions is
  'Attributable, content-free record of every restricted operator action (1.9; widened by 2.3 and 2.12).';

insert into app.ops_operator_actions (id, occurred_at, environment, operator, action, target_id)
overriding system value
select r.id, r.occurred_at, r.environment, r.operator, r.action, r.target_id
  from app.ops_retired_operator_actions_v1 r;
select setval(pg_catalog.pg_get_serial_sequence('app.ops_operator_actions', 'id'),
              coalesce((select max(a.id) from app.ops_operator_actions a), 0) + 1, false);

alter table app.ops_operator_actions enable row level security;
revoke all on table app.ops_operator_actions from public, anon, authenticated, service_role;
revoke all on sequence app.ops_operator_actions_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- The fallback record and command
-- ---------------------------------------------------------------------------------------------

create table app.identity_admin_fallbacks (
  fallback_id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  operator text not null references app.ops_operators (operator),
  confirming_owner text not null check (confirming_owner ~ '^[a-z][a-z0-9_.-]{1,39}$'),
  case_reference text not null check (case_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{2,63}$'),
  target_member_id uuid not null,
  grant_id uuid not null unique,
  reason_code text not null check (reason_code in ('no_usable_admin', 'admins_unreachable')),
  identity_check text not null check (identity_check in ('in_person', 'established_relationship')),
  usable_admins_before integer not null check (usable_admins_before >= 0),
  revision_after bigint not null,
  check ((reason_code = 'no_usable_admin') = (usable_admins_before = 0)),
  check (confirming_owner <> lower(operator))
);

comment on table app.identity_admin_fallbacks is
  'owner: identity. Story 2.12: restricted-operator last-Admin fallback grants (ids, codes, the '
  'confirming owner identifier and the case reference).';

alter table app.identity_admin_fallbacks enable row level security;
revoke all on table app.identity_admin_fallbacks from public, anon, authenticated, service_role;

create function app.identity_admin_fallback_grant(
  p_member_id uuid,
  p_identity_check text,
  p_reason_code text,
  p_confirming_owner text,
  p_case_reference text,
  p_operator text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_owner text := lower(btrim(coalesce(p_confirming_owner, '')));
  v_case text := btrim(coalesce(p_case_reference, ''));
  v_usable integer;
  v_grant uuid;
  v_revision bigint;
  v_fallback uuid;
begin
  perform app.ops_require_operator(p_operator);
  if p_identity_check is null or p_identity_check not in ('in_person', 'established_relationship') then
    raise exception using errcode = '22023',
      message = 'identity_check must be in_person or established_relationship';
  end if;
  if p_reason_code is null or p_reason_code not in ('no_usable_admin', 'admins_unreachable') then
    raise exception using errcode = '22023',
      message = 'reason_code must be no_usable_admin or admins_unreachable';
  end if;
  if v_owner !~ '^[a-z][a-z0-9_.-]{1,39}$' then
    raise exception using errcode = '22023',
      message = 'confirming_owner must identify the second named owner';
  end if;
  if v_owner = lower(btrim(p_operator)) then
    raise exception using errcode = '22023',
      message = 'confirming_owner must be a different person from the operator';
  end if;
  if v_case !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{2,63}$' then
    raise exception using errcode = '22023',
      message = 'case_reference must name the owners'' restricted case note';
  end if;
  if p_member_id is null then
    raise exception using errcode = '22023', message = 'member_id is required';
  end if;
  -- Same lock as the bootstrap, the grant commands' last-Admin rule and every deletion route.
  perform 1 from app.identity_roles r where r.role = 'admin' for update;
  v_usable := app.identity_usable_admin_count(null);
  if p_reason_code = 'no_usable_admin' and v_usable > 0 then
    raise exception using errcode = '22023',
      message = 'a usable Admin exists: the reason is admins_unreachable';
  end if;
  if p_reason_code = 'admins_unreachable' and v_usable = 0 then
    raise exception using errcode = '22023',
      message = 'no usable Admin exists: the reason is no_usable_admin';
  end if;
  if exists (select 1 from app.identity_deletions d where d.member_id = p_member_id) then
    raise exception using errcode = '22023', message = 'the member is being deleted';
  end if;
  if not exists (select 1 from app.identity_members m
                  where m.member_id = p_member_id and m.membership_state = 'approved') then
    raise exception using errcode = '22023', message = 'the member must be an approved church member';
  end if;
  if not exists (select 1 from app.identity_account_links l
                 cross join lateral app.identity_account_standing(l.auth_user_id) st
                 where l.member_id = p_member_id and l.link_state <> 'ended'
                   and st.outcome = 'ok' and st.member_id = p_member_id
                   and app.identity_link_dormancy(l.link_id) is null) then
    raise exception using errcode = '22023',
      message = 'the member needs a usable account link (no hold, review, ban or dormancy)';
  end if;
  perform 1 from app.identity_grant_sets s where s.member_id = p_member_id for update;
  if exists (select 1 from app.identity_grants g
              where g.member_id = p_member_id and g.role = 'admin' and g.revoked_at is null) then
    raise exception using errcode = '22023', message = 'the member already holds Admin';
  end if;
  if exists (select 1 from app.identity_grants g
              where g.member_id = p_member_id and g.scope_kind is not null and g.revoked_at is null) then
    raise exception using errcode = '22023',
      message = 'the member holds a scope grant: choose a member without care, finance or cell scopes';
  end if;
  insert into app.identity_grants (member_id, role, granted_by_operator)
  values (p_member_id, 'admin', p_operator)
  returning grant_id into v_grant;
  v_revision := app.identity_bump_grant_set(p_member_id);
  insert into app.identity_access_audit (action, actor_kind, operator, target_member_id, grant_id,
                                         role, revision_after)
  values ('admin_fallback_granted', 'operator', p_operator, p_member_id, v_grant, 'admin', v_revision);
  insert into app.identity_admin_fallbacks (operator, confirming_owner, case_reference,
                                            target_member_id, grant_id, reason_code,
                                            identity_check, usable_admins_before, revision_after)
  values (p_operator, v_owner, v_case, p_member_id, v_grant, p_reason_code, p_identity_check,
          v_usable, v_revision)
  returning fallback_id into v_fallback;
  perform app.ops_record_action(p_operator, 'admin_fallback_granted', v_grant);
  return jsonb_build_object('fallback_id', v_fallback, 'grant_id', v_grant, 'member_id', p_member_id,
                            'reason_code', p_reason_code, 'usable_admins_before', v_usable,
                            'revision', v_revision);
end;
$$;

comment on function app.identity_admin_fallback_grant(uuid, text, text, text, text, text) is
  'Restricted operator only (no grants): two-owner, identity-checked last-Admin fallback (story '
  '2.12). Writes no Auth row.';

revoke all on function app.identity_admin_fallback_grant(uuid, text, text, text, text, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Roles & access shows a fallback Admin to every Admin (same signature and privileges)
-- ---------------------------------------------------------------------------------------------

create or replace function app.identity_admin_member_grants(p_after_display_name text, p_after_member_id uuid)
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
               'admin_via_fallback', exists (
                 select 1 from app.identity_grants g
                   join app.identity_admin_fallbacks f on f.grant_id = g.grant_id
                  where g.member_id = m.member_id and g.role = 'admin' and g.revoked_at is null),
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
