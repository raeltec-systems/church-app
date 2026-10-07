-- Story 2.12: the identity-checked last-Admin fallback (I10, AD-4, AD-19).
--
-- app.identity_bootstrap_admin (2.3) grants Admin only while NO usable Admin exists. "Usable"
-- means "passes every non-session condition of the predicate", so a sole Admin who forgot the
-- password and has no approved recovery email, or who left the church without being deactivated,
-- still counts: bootstrap refuses, and every Admin-side exit (staff-assisted recovery, a hold, a
-- deactivation) needs a second Admin. This migration adds the one missing restricted-operator
-- path:
--
--   app.identity_admin_fallback_grant(member_id, identity_check, reason_code, operator)
--
-- * Restricted operator only (app.ops_operators); no client role has EXECUTE.
-- * reason_code must match the real Admin state: `no_usable_admin` only while no usable Admin
--   exists, `admins_unreachable` only while at least one exists (the named owners confirmed that
--   none of them can act). identity_check is `in_person` or `established_relationship` (the
--   named owners' check of the member, recorded by code; names never enter the database).
-- * The member must be approved, with a live account link whose account passes
--   app.identity_account_standing (= 'ok': not deleted, banned or anonymous; link active; no
--   binding review; Auth phone and email equal the approved binding; no open hold), not dormant,
--   not under deletion, and must not already hold Admin.
-- * It writes NO Auth row: no password, session, token or link is created or changed. The new
--   Admin signs in with their own password and then helps the unreachable Admin through the
--   normal runbooks (docs/runbooks/identity-support.md).
-- * Audited in app.identity_access_audit as `admin_bootstrapped` with the operator (the existing
--   action value: widening that CHECK needs a DROP), in the new content-free
--   app.identity_admin_fallbacks (reason, identity check, usable-Admin count before), and
--   journalled in app.ops_operator_actions (`admin_bootstrapped`).
--
-- No row deletions, no DROP or TRUNCATE.

create table app.identity_admin_fallbacks (
  fallback_id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  operator text not null references app.ops_operators (operator),
  target_member_id uuid not null,
  grant_id uuid not null,
  reason_code text not null check (reason_code in ('no_usable_admin', 'admins_unreachable')),
  identity_check text not null check (identity_check in ('in_person', 'established_relationship')),
  usable_admins_before integer not null check (usable_admins_before >= 0),
  revision_after bigint not null,
  check ((reason_code = 'no_usable_admin') = (usable_admins_before = 0))
);

comment on table app.identity_admin_fallbacks is
  'owner: identity. Story 2.12: restricted-operator last-Admin fallback grants (ids and codes only).';

alter table app.identity_admin_fallbacks enable row level security;
revoke all on table app.identity_admin_fallbacks from public, anon, authenticated, service_role;

create function app.identity_admin_fallback_grant(
  p_member_id uuid,
  p_identity_check text,
  p_reason_code text,
  p_operator text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
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
  if p_member_id is null then
    raise exception using errcode = '22023', message = 'member_id is required';
  end if;
  -- Same lock as the bootstrap, the grant commands' last-Admin rule and every deletion route.
  perform 1 from app.identity_roles r where r.role = 'admin' for update;
  v_usable := app.identity_usable_admin_count(null);
  if p_reason_code = 'no_usable_admin' and v_usable > 0 then
    raise exception using errcode = '22023',
      message = 'a usable Admin exists: use admins_unreachable only after the named owners confirm no Admin can act';
  end if;
  if p_reason_code = 'admins_unreachable' and v_usable = 0 then
    raise exception using errcode = '22023',
      message = 'no usable Admin exists: the reason is no_usable_admin';
  end if;
  if exists (select 1 from app.identity_deletions d where d.member_id = p_member_id) then
    raise exception using errcode = '22023', message = 'the member is being deleted';
  end if;
  if not exists (select 1 from app.identity_members m
                  join app.identity_account_links l
                    on l.member_id = m.member_id and l.link_state <> 'ended'
                 cross join lateral app.identity_account_standing(l.auth_user_id) st
                 where m.member_id = p_member_id and m.membership_state = 'approved'
                   and st.outcome = 'ok' and st.member_id = m.member_id
                   and app.identity_link_dormancy(l.link_id) is null) then
    raise exception using errcode = '22023',
      message = 'the member must be approved with a usable account link (no hold, review or dormancy)';
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
  insert into app.identity_admin_fallbacks (operator, target_member_id, grant_id, reason_code,
                                            identity_check, usable_admins_before, revision_after)
  values (p_operator, p_member_id, v_grant, p_reason_code, p_identity_check, v_usable, v_revision)
  returning fallback_id into v_fallback;
  perform app.ops_record_action(p_operator, 'admin_bootstrapped', v_grant);
  return jsonb_build_object('fallback_id', v_fallback, 'grant_id', v_grant, 'member_id', p_member_id,
                            'reason_code', p_reason_code, 'usable_admins_before', v_usable,
                            'revision', v_revision);
end;
$$;

comment on function app.identity_admin_fallback_grant(uuid, text, text, text) is
  'Restricted operator only (no grants): identity-checked last-Admin fallback (story 2.12). Writes no Auth row.';

revoke all on function app.identity_admin_fallback_grant(uuid, text, text, text)
  from public, anon, authenticated, service_role;
