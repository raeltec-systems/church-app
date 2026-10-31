-- Owner-approved first-Admin commissioning, 31 October 2026.
-- SOURCE DELIVERY ONLY: not applied to any database or independently accepted.
-- Installs code; creates no invitation, Auth account, role grant or policy approval.
-- Passwords remain in the member -> Edge Function -> Supabase Auth path, never SQL.

create table app.identity_admin_commissioning (
  singleton boolean primary key default true check (singleton),
  commissioned_at timestamptz,
  source text check (source in ('historical_admin', 'admin_grant', 'owner_invitation')),
  active_invitation_id uuid,
  check ((commissioned_at is null) = (source is null))
);
comment on table app.identity_admin_commissioning is
  'owner: identity. Permanent non-personal commissioning latch; zero usable Admins never resets it.';
insert into app.identity_admin_commissioning(singleton, commissioned_at, source)
select true,
  case when exists(select 1 from app.identity_grants where role = 'admin')
    or exists(select 1 from app.identity_access_audit where role = 'admin') then clock_timestamp() end,
  case when exists(select 1 from app.identity_grants where role = 'admin')
    or exists(select 1 from app.identity_access_audit where role = 'admin') then 'historical_admin' end;

create table app.identity_admin_setup_invites (
  invitation_id uuid primary key default gen_random_uuid(),
  environment text not null check (environment in ('local', 'staging', 'production')),
  digest text unique check (digest ~ '^[0-9a-f]{64}$'),
  phone_username text check (phone_username ~ '^\+[1-9][0-9]{7,14}$'),
  auth_user_id uuid,
  mode text not null check (mode in ('new_account', 'existing_account')),
  is_synthetic boolean not null,
  issued_by text not null references app.ops_operators(operator),
  identity_check text not null check (identity_check in ('in_person', 'established_relationship')),
  case_reference text check (case_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{2,63}$'),
  issued_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp() + interval '24 hours',
  state text not null default 'issued'
    check (state in ('issued', 'provisioning', 'completed', 'revoked', 'failed', 'erased')),
  request_id uuid,
  operation_id uuid,
  correlation_nonce uuid,
  started_at timestamptz,
  provider_settled_at timestamptz,
  cleanup_started_at timestamptz,
  cleanup_completed_at timestamptz,
  full_name text,
  privacy_notice_version text,
  intent_hash bytea,
  member_id uuid,
  grant_id uuid,
  completed_at timestamptz,
  revoked_at timestamptz,
  check (expires_at > issued_at and expires_at <= issued_at + interval '24 hours 1 second'),
  check (state <> 'provisioning' or (request_id is not null and operation_id is not null and started_at is not null)),
  check (state <> 'completed' or (member_id is not null and grant_id is not null and completed_at is not null))
);
comment on table app.identity_admin_setup_invites is
  'owner: identity. Environment/account-bound commissioning; digest-only invitation, never passwords or Auth tokens.';
create index identity_admin_setup_invites_account on app.identity_admin_setup_invites(auth_user_id);
create index identity_admin_setup_invites_member on app.identity_admin_setup_invites(member_id);

create table app.identity_admin_setup_audit (
  event_id bigint generated always as identity primary key,
  invitation_id uuid not null,
  action text not null check (action in ('issued','revoked','provisioning_started',
    'provider_rejected','completion_refused','commissioned','application_commissioned','erased',
    'cleanup_started','cleanup_completed','completion_redacted')),
  operator text,
  member_id uuid,
  application_id uuid,
  operation_id uuid,
  occurred_at timestamptz not null default clock_timestamp()
);
comment on table app.identity_admin_setup_audit is
  'owner: identity. Operator commissioning provenance: ids, codes and timestamps, no personal values or secrets.';
create index identity_admin_setup_audit_member on app.identity_admin_setup_audit(member_id,event_id);

create table app.identity_admin_setup_limits (
  bucket text primary key,
  window_start timestamptz not null,
  attempts integer not null check (attempts > 0)
);
comment on table app.identity_admin_setup_limits is
  'owner: identity. Short-lived abuse counters with HMAC client identifiers, never raw addresses.';

alter table app.identity_admin_commissioning enable row level security;
alter table app.identity_admin_setup_invites enable row level security;
alter table app.identity_admin_setup_audit enable row level security;
alter table app.identity_admin_setup_limits enable row level security;
revoke all on table app.identity_admin_commissioning, app.identity_admin_setup_invites,
  app.identity_admin_setup_audit, app.identity_admin_setup_limits
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_admin_setup_audit_event_id_seq
  from public, anon, authenticated, service_role;

create function app.identity_admin_setup_latch() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.role = 'admin' then
    update app.identity_admin_commissioning
    set commissioned_at = clock_timestamp(), source = 'admin_grant'
    where singleton and commissioned_at is null;
  end if;
  return new;
end;
$$;
create trigger identity_admin_setup_latch after insert on app.identity_grants
for each row execute function app.identity_admin_setup_latch();

create function app.identity_admin_setup_operator_active(p_operator text) returns boolean
language plpgsql set search_path = '' as $$
begin
  perform app.ops_require_operator(p_operator);
  return true;
exception when insufficient_privilege then return false;
end;
$$;

-- Live setup requires Q4's explicit approved value and a reviewed notice. It never invents one.
-- Expected Q4 value component: {"privacy_notice":{"version":"...","text":"..."}}.
-- The synthetic notice is allowed only for reserved fictional accounts in local/staging.
create function app.identity_admin_setup_notice(p_synthetic boolean) returns jsonb
language plpgsql set search_path = '' as $$
declare v_policy jsonb; v_notice jsonb;
begin
  if app.rcv_serving_hold() then return null; end if;
  if p_synthetic and app.platform_current_environment() in ('local','staging') then
    return jsonb_build_object('version','synthetic-admin-setup-1','text',
      'SYNTHETIC TEST ONLY. Use fictional details. This test creates an approved member and Admin account. It does not approve the church privacy policy.');
  end if;
  if p_synthetic or not app.policy_is_open('q4_personal_data') then return null; end if;
  v_policy := app.policy_effective('q4_personal_data');
  if v_policy->>'source' is distinct from 'approved' then return null; end if;
  v_notice := v_policy->'value'->'privacy_notice';
  if jsonb_typeof(v_notice) is distinct from 'object'
    or coalesce(v_notice->>'version','') !~ '^[a-z0-9][a-z0-9_.-]{0,62}$'
    or jsonb_typeof(v_notice->'text') is distinct from 'string'
    or length(btrim(v_notice->>'text')) not between 20 and 12000 then return null; end if;
  return v_notice;
end;
$$;

-- Restricted operator only. Caller supplies a digest, never the usable invitation.
-- Existing accounts must be named explicitly; a matching phone never adopts an account.
create function app.identity_admin_setup_issue(
  p_digest text, p_phone_username text, p_existing_account uuid,
  p_synthetic boolean, p_identity_check text, p_case_reference text, p_operator text
) returns jsonb language plpgsql set search_path = '' as $$
declare v_id uuid; v_account uuid; v_active app.identity_admin_setup_invites; v_commissioned timestamptz;
begin
  perform app.ops_require_operator(p_operator);
  perform 1 from app.identity_roles where role = 'admin' for update;
  select commissioned_at into v_commissioned
    from app.identity_admin_commissioning where singleton for update;
  if v_commissioned is not null then
    raise exception using errcode='22023',
      message='installation already commissioned; use Admin management or reviewed recovery';
  end if;
  if p_digest is null or p_digest !~ '^[0-9a-f]{64}$'
    or p_phone_username is null or p_phone_username !~ '^\+[1-9][0-9]{7,14}$'
    or p_identity_check is null or p_identity_check not in ('in_person','established_relationship')
    or p_case_reference is null or p_case_reference !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{2,63}$'
    or p_synthetic is null then
    raise exception using errcode='22023', message='invalid commissioning inputs';
  end if;
  if app.identity_admin_setup_notice(p_synthetic) is null then
    raise exception using errcode='22023', message='personal-data approval and reviewed notice are required';
  end if;
  if p_synthetic and p_phone_username !~ '^\+(120255501[0-9]{2}|447700900[0-9]{3})$' then
    raise exception using errcode='22023', message='synthetic setup requires a reserved fictional username';
  end if;
  select * into v_active from app.identity_admin_setup_invites where digest=p_digest;
  if found then
    if v_active.environment=app.platform_current_environment()
      and v_active.phone_username=p_phone_username and v_active.is_synthetic=p_synthetic
      and v_active.issued_by=p_operator and v_active.identity_check=p_identity_check
      and v_active.case_reference=p_case_reference
      and v_active.mode=(case when p_existing_account is null then 'new_account' else 'existing_account' end)
      and (p_existing_account is null or v_active.auth_user_id=p_existing_account)
      and v_active.state='issued' and v_active.expires_at>clock_timestamp() then
      return jsonb_build_object('invitation_id',v_active.invitation_id,'expires_at',app.cmd_utc(v_active.expires_at));
    end if;
    raise exception using errcode='22023',message='invitation issue conflicts with a prior request';
  end if;
  select i.* into v_active from app.identity_admin_setup_invites i
    join app.identity_admin_commissioning c on c.active_invitation_id = i.invitation_id
    where c.singleton;
  if (v_active.cleanup_started_at is not null and v_active.cleanup_completed_at is null)
    or (v_active.started_at is not null and v_active.provider_settled_at is null)
    or (v_active.state='issued' and v_active.expires_at>clock_timestamp()) then
    raise exception using errcode='22023',
      message='active or unresolved invitation; revoke or reconcile before reissuing';
  end if;
  if p_existing_account is null then
    if exists(select 1 from auth.users
      where '+'||ltrim(phone,'+') = p_phone_username and deleted_at is null) then
      raise exception using errcode='22023',
        message='account collision; review and explicitly bind the existing account';
    end if;
    v_account := gen_random_uuid();
  else
    select id into v_account from auth.users
      where id=p_existing_account and '+'||ltrim(phone,'+')=p_phone_username
      and deleted_at is null and not coalesce(is_anonymous,false)
      and coalesce(encrypted_password,'')<>''
      and (banned_until is null or banned_until<=clock_timestamp());
    if v_account is null then
      raise exception using errcode='22023', message='intended account is unavailable';
    end if;
  end if;
  if exists(select 1 from app.identity_account_links where auth_user_id=v_account)
    or exists(select 1 from app.identity_deletion_accounts where auth_user_id=v_account) then
    raise exception using errcode='22023', message='existing member history requires normal identity recovery';
  end if;
  insert into app.identity_admin_setup_invites(environment,digest,phone_username,auth_user_id,
    mode,is_synthetic,issued_by,identity_check,case_reference)
  values(app.platform_current_environment(),p_digest,p_phone_username,v_account,
    case when p_existing_account is null then 'new_account' else 'existing_account' end,
    p_synthetic,p_operator,p_identity_check,p_case_reference)
  returning invitation_id into v_id;
  update app.identity_admin_commissioning set active_invitation_id=v_id where singleton;
  insert into app.identity_admin_setup_audit(invitation_id,action,operator)
    values(v_id,'issued',p_operator);
  return jsonb_build_object('invitation_id',v_id,'expires_at',
    (select app.cmd_utc(expires_at) from app.identity_admin_setup_invites where invitation_id=v_id));
end;
$$;

create function app.identity_admin_setup_revoke(p_invitation uuid,p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_row app.identity_admin_setup_invites;
begin
  perform app.ops_require_operator(p_operator);
  perform 1 from app.identity_roles where role='admin' for update;
  perform 1 from app.identity_admin_commissioning where singleton for update;
  select * into v_row from app.identity_admin_setup_invites where invitation_id=p_invitation for update;
  if not found or v_row.environment<>app.platform_current_environment()
    or v_row.state in ('completed','erased') then
    raise exception using errcode='22023', message='invitation cannot be revoked here';
  end if;
  if v_row.state<>'revoked' then
    update app.identity_admin_setup_invites
      set state='revoked',revoked_at=clock_timestamp(),full_name=null,digest=null
      where invitation_id=p_invitation;
    insert into app.identity_admin_setup_audit(invitation_id,action,operator,operation_id)
      values(p_invitation,'revoked',p_operator,v_row.operation_id);
  end if;
  return jsonb_build_object('outcome','revoked','provider_reconciliation_required',
    v_row.started_at is not null and v_row.provider_settled_at is null);
end;
$$;

create function app.identity_admin_setup_operator_status(p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
begin
  perform app.ops_require_operator(p_operator);
  return (select jsonb_build_object('commissioned',c.commissioned_at is not null,
    'commissioned_at',app.cmd_utc(c.commissioned_at),'invitation_id',i.invitation_id,
    'state',i.state,'mode',i.mode,'expires_at',app.cmd_utc(i.expires_at),
    'operation_id',i.operation_id,'provider_reconciliation_required',
      i.started_at is not null and i.provider_settled_at is null,
    'provider_account_present',exists(select 1 from auth.users u
      where u.id=i.auth_user_id and u.deleted_at is null))
    from app.identity_admin_commissioning c left join app.identity_admin_setup_invites i
      on i.invitation_id=c.active_invitation_id where c.singleton);
end;
$$;

create function app.identity_admin_setup_limited(p_client text) returns boolean
language plpgsql set search_path = '' as $$
declare v_key text; v_n integer; v_limit integer; v_now timestamptz:=clock_timestamp();
begin
  delete from app.identity_admin_setup_limits where window_start<v_now-interval '20 minutes';
  foreach v_key in array array['global',p_client] loop
    v_limit:=case when v_key='global' then 120 else 10 end;
    insert into app.identity_admin_setup_limits(bucket,window_start,attempts) values(v_key,v_now,1)
    on conflict(bucket) do update set
      attempts=case when app.identity_admin_setup_limits.window_start<=v_now-interval '10 minutes'
        then 1 else app.identity_admin_setup_limits.attempts+1 end,
      window_start=case when app.identity_admin_setup_limits.window_start<=v_now-interval '10 minutes'
        then v_now else app.identity_admin_setup_limits.window_start end
    returning attempts into v_n;
    if v_n>v_limit then return true; end if;
  end loop;
  return false;
end;
$$;

create function app.identity_admin_setup_check(p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare e jsonb; k text; v_allowed text[];
begin
  v_allowed:=array['action','invitation_digest','phone_username','client_key'];
  if p->>'action' in ('begin','finish','status') then v_allowed:=v_allowed||'request_id'::text; end if;
  if p->>'action'='begin' then
    v_allowed:=v_allowed||array['session_id','full_name','privacy_notice_version','privacy_accepted'];
  elsif p->>'action'='finish' then v_allowed:=v_allowed||array['operation_id','provider_result']; end if;
  e:=app.contract_unknown_keys(p,v_allowed);
  if coalesce(p->>'action','') not in ('inspect','begin','finish','status') then e:=e||'{"action":"invalid"}'; end if;
  foreach k in array array['invitation_digest','client_key'] loop
    if jsonb_typeof(p->k) is distinct from 'string' or coalesce(p->>k,'') !~ '^[0-9a-f]{64}$' then
      e:=e||jsonb_build_object(k,'invalid');
    end if;
  end loop;
  if jsonb_typeof(p->'phone_username') is distinct from 'string'
    or coalesce(p->>'phone_username','') !~ '^\+[1-9][0-9]{7,14}$' then
    e:=e||'{"phone_username":"invalid"}';
  end if;
  if p->>'action' in ('begin','finish','status')
    and app.contract_uuid_error(p->'request_id') is not null then e:=e||'{"request_id":"invalid"}'; end if;
  if p->>'action'='begin' and (jsonb_typeof(p->'full_name') is distinct from 'string'
    or length(btrim(p->>'full_name')) not between 1 and 120 or p->>'full_name' ~ '[[:cntrl:]]'
    or p->'privacy_accepted' is distinct from 'true'::jsonb
    or coalesce(p->>'privacy_notice_version','') !~ '^[a-z0-9][a-z0-9_.-]{0,62}$') then
    e:=e||'{"setup":"invalid"}';
  end if;
  if p ? 'session_id' and app.contract_uuid_error(p->'session_id',true) is not null then e:=e||'{"session_id":"invalid"}'; end if;
  if p->>'action'='finish' and (app.contract_uuid_error(p->'operation_id') is not null
    or coalesce(p->>'provider_result','') not in ('observed','unknown','password_rejected','rejected')) then
    e:=e||'{"operation_id":"invalid"}';
  end if;
  return e;
end;
$$;

-- Called only after locking role -> commissioning -> invitation. No public EXECUTE.
create function app.identity_admin_setup_finish(p_id uuid,p_session uuid default null) returns jsonb
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites; u auth.users; v_member uuid; v_link uuid; v_grant uuid;
  v_revision bigint; v_app record; v_notice jsonb; v_by text;
begin
  select * into i from app.identity_admin_setup_invites where invitation_id=p_id for update;
  if not found or i.state<>'provisioning' or i.expires_at<=clock_timestamp()
    or i.environment<>app.platform_current_environment()
    or not app.identity_admin_setup_operator_active(i.issued_by)
    or exists(select 1 from app.identity_admin_commissioning where singleton and commissioned_at is not null) then
    return jsonb_build_object('outcome','refused');
  end if;
  v_notice:=app.identity_admin_setup_notice(i.is_synthetic);
  if v_notice is null or v_notice->>'version' is distinct from i.privacy_notice_version then
    return jsonb_build_object('outcome','refused');
  end if;
  select * into u from auth.users where id=i.auth_user_id for update;
  if not found then return jsonb_build_object('outcome','pending','request_id',i.request_id); end if;
  if u.deleted_at is not null or coalesce(u.is_anonymous,false) or coalesce(u.encrypted_password,'')=''
    or (u.banned_until is not null and u.banned_until>clock_timestamp())
    or ('+'||ltrim(u.phone,'+')) is distinct from i.phone_username
    or (nullif(u.email,'') is not null and u.email_confirmed_at is null)
    or app.identity_auth_has_extras(u.id)
    or exists(select 1 from app.identity_account_links where auth_user_id=u.id)
    or exists(select 1 from app.identity_deletion_accounts where auth_user_id=u.id)
    or exists(select 1 from app.identity_account_links
      where approved_phone=i.phone_username and link_state<>'ended') then
    return jsonb_build_object('outcome','refused');
  end if;
  if i.mode='new_account' then
    if u.raw_app_meta_data->>'church_setup_operation' is distinct from i.operation_id::text
      or u.raw_app_meta_data->>'church_setup_nonce' is distinct from i.correlation_nonce::text
      or u.created_at<i.started_at-interval '1 second' then return jsonb_build_object('outcome','refused'); end if;
  elsif p_session is null or not exists(
    select 1 from auth.sessions s where s.id=p_session and s.user_id=u.id
      and s.created_at>=greatest(i.issued_at,clock_timestamp()-interval '5 minutes')
      and (s.not_after is null or s.not_after>clock_timestamp())
      and exists(select 1 from auth.mfa_amr_claims a
        where a.session_id=s.id and a.authentication_method='password')
  ) then return jsonb_build_object('outcome','refused'); end if;
  v_by:='operator:'||i.issued_by;
  insert into app.identity_members(display_name,membership_state,is_synthetic)
    values(i.full_name,'approved',i.is_synthetic) returning member_id into v_member;
  -- The internal link guard admits this new-account link only to the member
  -- reserved by this locked completion, never to a coincidentally matching person.
  update app.identity_admin_setup_invites set member_id=v_member where invitation_id=i.invitation_id;
  insert into app.identity_account_links(member_id,auth_user_id,approved_phone,
    approved_recovery_email,approved_by,sessions_valid_after)
  values(v_member,u.id,i.phone_username,lower(nullif(u.email,'')),v_by,clock_timestamp())
    returning link_id into v_link;
  insert into app.identity_binding_history(link_id,binding_revision,approved_phone,
    approved_recovery_email,approved_by,reason)
  values(v_link,1,i.phone_username,lower(nullif(u.email,'')),v_by,'owner_authorised_commissioning');
  -- Separate operator provenance: never fake a new Admin approving their own application.
  for v_app in
    update app.identity_membership_applications set application_state='approved',member_id=v_member,
      decided_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp()
      where auth_user_id=u.id and application_state in ('submitted','needs_details')
      returning application_id
  loop
    insert into app.identity_admin_setup_audit(invitation_id,action,operator,member_id,application_id,operation_id)
      values(i.invitation_id,'application_commissioned',i.issued_by,v_member,v_app.application_id,i.operation_id);
  end loop;
  perform app.identity_revoke_auth_sessions(u.id);
  insert into app.identity_grants(member_id,role,granted_by_operator)
    values(v_member,'admin',i.issued_by) returning grant_id into v_grant;
  v_revision:=app.identity_bump_grant_set(v_member);
  insert into app.identity_access_audit(action,actor_kind,operator,target_member_id,grant_id,role,revision_after)
    values('admin_bootstrapped','operator',i.issued_by,v_member,v_grant,'admin',v_revision);
  perform app.ops_record_action(i.issued_by,'admin_bootstrapped',v_grant);
  update app.identity_admin_setup_invites set state='completed',member_id=v_member,grant_id=v_grant,
    full_name=null,completed_at=clock_timestamp(),provider_settled_at=clock_timestamp()
    where invitation_id=i.invitation_id;
  update app.identity_admin_commissioning set source='owner_invitation' where singleton;
  insert into app.identity_admin_setup_audit(invitation_id,action,operator,member_id,operation_id)
    values(i.invitation_id,'commissioned',i.issued_by,v_member,i.operation_id);
  return jsonb_build_object('outcome',case when i.is_synthetic or app.policy_is_open('private_access')
    then 'completed' else 'activation_pending' end,'sign_in_required',true);
end;
$$;

create function app.identity_sys_admin_setup(p_principal uuid,p_request uuid,p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites; n jsonb; r jsonb; v_closed boolean; v_action text:=p->>'action';
  v_name text; v_errors jsonb; v_session uuid; v_hash bytea;
begin
  if app.identity_admin_setup_limited(p->>'client_key') then
    return jsonb_build_object('data',jsonb_build_object('outcome','rate_limited'));
  end if;
  perform 1 from app.identity_roles where role='admin' for update;
  select commissioned_at is not null into v_closed
    from app.identity_admin_commissioning where singleton for update;
  select * into i from app.identity_admin_setup_invites
    where digest=p->>'invitation_digest' and phone_username=p->>'phone_username'
    and environment=app.platform_current_environment() for update;
  if not found or i.state in ('revoked','failed','erased') or i.expires_at<=clock_timestamp()
    or not app.identity_admin_setup_operator_active(i.issued_by) or app.rcv_serving_hold() then
    return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
  end if;
  if v_action in ('status','finish') and i.request_id is not null
    and i.request_id::text is distinct from p->>'request_id' then
    return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
  end if;
  n:=app.identity_admin_setup_notice(i.is_synthetic);
  if n is null then return jsonb_build_object('data',jsonb_build_object('outcome','refused')); end if;
  if i.state='completed' then
    -- Reporting prior completion never renews a held, changed, unlinked or deleted identity.
    if not exists(select 1 from app.identity_members m
      join app.identity_account_links l on l.member_id=m.member_id
      join auth.users u on u.id=l.auth_user_id
      where m.member_id=i.member_id and m.membership_state='approved'
      and l.auth_user_id=i.auth_user_id and l.link_state='active' and not l.binding_review_required
      and l.approved_phone=i.phone_username and '+'||ltrim(u.phone,'+')=l.approved_phone
      and lower(nullif(u.email,'')) is not distinct from l.approved_recovery_email
      and u.deleted_at is null and (u.banned_until is null or u.banned_until<=clock_timestamp())
      and not exists(select 1 from app.identity_holds where member_id=m.member_id and released_at is null)
      and not exists(select 1 from app.identity_deletions where member_id=m.member_id)
      and exists(select 1 from app.identity_grants where grant_id=i.grant_id and revoked_at is null)) then
      r:=jsonb_build_object('outcome','refused');
    else
      r:=jsonb_build_object('outcome',case when i.is_synthetic or app.policy_is_open('private_access')
        then 'completed' else 'activation_pending' end,'sign_in_required',true);
    end if;
    return jsonb_build_object('data',r);
  end if;
  if v_closed then return jsonb_build_object('data',jsonb_build_object('outcome','refused')); end if;
  if i.state='issued' and v_action in ('inspect','status') then
    return jsonb_build_object('data',jsonb_build_object('outcome','ready','mode',i.mode,
      'privacy_notice_version',n->>'version','privacy_notice_text',n->>'text','expires_at',app.cmd_utc(i.expires_at)));
  end if;
  if i.state='issued' and v_action='begin' then
    if n->>'version' is distinct from p->>'privacy_notice_version' then
      return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
    end if;
    select x.errors,x.full_name into v_errors,v_name
      from app.identity_application_name(p->'full_name','{}'::jsonb) x;
    if v_errors<>'{}'::jsonb or (i.is_synthetic and v_name !~ '^SYNTHETIC ') then
      return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
    end if;
    if i.mode='existing_account' then
      v_session:=(p->>'session_id')::uuid;
      if v_session is null or not exists(select 1 from auth.sessions s
        where s.id=v_session and s.user_id=i.auth_user_id
        and s.created_at>=greatest(i.issued_at,clock_timestamp()-interval '5 minutes')
        and (s.not_after is null or s.not_after>clock_timestamp())
        and exists(select 1 from auth.mfa_amr_claims a
          where a.session_id=s.id and a.authentication_method='password')) then
        return jsonb_build_object('data',jsonb_build_object('outcome','password_rejected'));
      end if;
    end if;
    v_hash:=sha256(convert_to(jsonb_build_array(v_name,p->>'privacy_notice_version',p->>'request_id')::text,'UTF8'));
    update app.identity_admin_setup_invites
      set state='provisioning',request_id=(p->>'request_id')::uuid,
      operation_id=gen_random_uuid(),correlation_nonce=gen_random_uuid(),started_at=clock_timestamp(),
      provider_settled_at=null,full_name=v_name,privacy_notice_version=n->>'version',intent_hash=v_hash
      where invitation_id=i.invitation_id returning * into i;
    insert into app.identity_admin_setup_audit(invitation_id,action,operator,operation_id)
      values(i.invitation_id,'provisioning_started',i.issued_by,i.operation_id);
    if i.mode='existing_account' then
      r:=app.identity_admin_setup_finish(i.invitation_id,v_session);
      if coalesce(r->>'outcome','') not in ('completed','activation_pending') then
        -- Existing-account enrollment makes no external account-creation call.
        -- A definite SQL refusal must not leave a fictitious unresolved provider
        -- operation. Drop its submitted data and require a deliberate fresh proof.
        update app.identity_admin_setup_invites
          set state='issued',request_id=null,operation_id=null,correlation_nonce=null,
            started_at=null,provider_settled_at=clock_timestamp(),full_name=null,
            privacy_notice_version=null,intent_hash=null
          where invitation_id=i.invitation_id;
        insert into app.identity_admin_setup_audit(invitation_id,action,operator,operation_id)
          values(i.invitation_id,'completion_refused',i.issued_by,i.operation_id);
        r:=jsonb_build_object('outcome','refused');
      end if;
    else
      r:=jsonb_build_object('outcome','provision','auth_user_id',i.auth_user_id,
        'operation_id',i.operation_id,'correlation_nonce',i.correlation_nonce);
    end if;
    return jsonb_build_object('data',r);
  end if;
  if i.state='provisioning' then
    if v_action='finish' and i.operation_id::text is distinct from p->>'operation_id' then
      return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
    end if;
    -- A second begin never returns provisioning authority, even for the same request id.
    if i.mode='new_account' then
      r:=app.identity_admin_setup_finish(i.invitation_id);
      if r->>'outcome'='pending' and v_action='finish'
        and p->>'provider_result' in ('password_rejected','rejected') then
        update app.identity_admin_setup_invites
          set state=case when p->>'provider_result'='password_rejected' then 'issued' else 'failed' end,
          request_id=null,operation_id=null,correlation_nonce=null,started_at=null,
          provider_settled_at=clock_timestamp(),full_name=null,intent_hash=null
          where invitation_id=i.invitation_id;
        insert into app.identity_admin_setup_audit(invitation_id,action,operator,operation_id)
          values(i.invitation_id,'provider_rejected',i.issued_by,i.operation_id);
        r:=jsonb_build_object('outcome',case when p->>'provider_result'='password_rejected'
          then 'password_rejected' else 'refused' end);
      end if;
    else r:=jsonb_build_object('outcome','pending','request_id',i.request_id); end if;
    return jsonb_build_object('data',r);
  end if;
  return jsonb_build_object('data',jsonb_build_object('outcome','refused'));
end;
$$;

-- No cached system result may replay authority or retain a provider correlation nonce.
insert into app.sys_command_kinds(command,purpose,description,payload_check,handler,retain_result)
values('identity.admin_setup','identity_admin_onboarding',
  'Owner-invited first Admin enrollment; no public self-promotion',
  'app.identity_admin_setup_check(jsonb)','app.identity_sys_admin_setup(uuid,uuid,jsonb)',false);

do $$ declare p regprocedure; begin
  for p in select oid::regprocedure from pg_proc
    where pronamespace='app'::regnamespace
    and (proname like 'identity_admin_setup_%' or proname='identity_sys_admin_setup')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role',p);
  end loop;
end $$;
notify pgrst, 'reload schema';

-- Provider writes are fenced inside the Auth transaction, not by a timer or by
-- assuming that a missing account means an in-flight HTTP request has stopped.
-- Only server-owned app_metadata and the reserved account id participate.
create function app.identity_admin_setup_auth_insert_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare i app.identity_admin_setup_invites; v_closed boolean; v_notice jsonb;
begin
  if not (coalesce(new.raw_app_meta_data,'{}'::jsonb) ?| array['church_setup_operation','church_setup_nonce'])
    and not exists(select 1 from app.identity_admin_setup_invites
      where mode='new_account' and auth_user_id=new.id) then return new; end if;
  perform 1 from app.identity_roles where role='admin' for update;
  select commissioned_at is not null into v_closed
    from app.identity_admin_commissioning where singleton for update;
  select * into i from app.identity_admin_setup_invites
    where mode='new_account' and auth_user_id=new.id for update;
  v_notice:=app.identity_admin_setup_notice(i.is_synthetic);
  if i.invitation_id is null or v_notice is null or v_closed or i.state<>'provisioning'
    or i.cleanup_started_at is not null or i.expires_at<=clock_timestamp()
    or i.environment<>app.platform_current_environment()
    or not app.identity_admin_setup_operator_active(i.issued_by)
    or v_notice->>'version' is distinct from i.privacy_notice_version
    or ((coalesce(new.raw_app_meta_data,'{}'::jsonb) ?| array['church_setup_operation','church_setup_nonce'])
      and (new.raw_app_meta_data->>'church_setup_operation' is distinct from i.operation_id::text
        or new.raw_app_meta_data->>'church_setup_nonce' is distinct from i.correlation_nonce::text))
    or '+'||ltrim(new.phone,'+') is distinct from i.phone_username then
    raise exception using errcode='42501',message='setup account creation refused';
  end if;
  return new;
end;
$$;
create trigger identity_admin_setup_provider_fence before insert on auth.users
  for each row execute function app.identity_admin_setup_auth_insert_guard();

-- Before normal membership linking, new-account commissioning must already be
-- complete (or be the exact internal member reserved by the locked completion).
-- A quarantined orphan cannot become a real member between cleanup prepare and
-- Auth deletion. Existing-account invitations do not quarantine their holder.
create function app.identity_admin_setup_link_guard() returns trigger
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites;
begin
  select * into i from app.identity_admin_setup_invites
    where mode='new_account' and auth_user_id=new.auth_user_id;
  if found and not (i.state='completed' or (i.state='provisioning'
    and i.member_id=new.member_id and i.cleanup_started_at is null)) then
    raise exception using errcode='42501',message='setup account cannot be linked here';
  end if;
  return new;
end;
$$;
create trigger identity_admin_setup_link_fence before insert or update of auth_user_id,member_id
  on app.identity_account_links for each row execute function app.identity_admin_setup_link_guard();

-- Keep the correlation markers on an unclaimed created account until cleanup.
-- GoTrue's ordinary sign-in timestamp updates are unaffected. Completed members
-- use the pre-existing credential/binding review workflow instead of this fence.
create function app.identity_admin_setup_auth_update_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare i app.identity_admin_setup_invites; v_closed boolean; v_notice jsonb;
  v_changed boolean;
begin
  v_changed := old.raw_app_meta_data->>'church_setup_operation' is distinct from new.raw_app_meta_data->>'church_setup_operation'
    or old.raw_app_meta_data->>'church_setup_nonce' is distinct from new.raw_app_meta_data->>'church_setup_nonce';
  if v_changed and coalesce(new.raw_app_meta_data,'{}'::jsonb) ?| array['church_setup_operation','church_setup_nonce'] then
    -- GoTrue creates its provider scaffold first and adds app_metadata in the
    -- SAME transaction. Validate that second write, including late calls after
    -- cleanup has erased the invitation's account identifier.
    perform 1 from app.identity_roles where role='admin' for update;
    select commissioned_at is not null into v_closed
      from app.identity_admin_commissioning where singleton for update;
    select * into i from app.identity_admin_setup_invites
      where mode='new_account' and auth_user_id=new.id for update;
    v_notice:=app.identity_admin_setup_notice(i.is_synthetic);
    if i.invitation_id is null or v_notice is null or v_closed or i.state<>'provisioning'
      or i.cleanup_started_at is not null or i.expires_at<=clock_timestamp()
      or i.environment<>app.platform_current_environment()
      or not app.identity_admin_setup_operator_active(i.issued_by)
      or v_notice->>'version' is distinct from i.privacy_notice_version
      or old.id is distinct from new.id or old.phone is distinct from new.phone
      or new.raw_app_meta_data->>'church_setup_operation' is distinct from i.operation_id::text
      or new.raw_app_meta_data->>'church_setup_nonce' is distinct from i.correlation_nonce::text
      or '+'||ltrim(new.phone,'+') is distinct from i.phone_username then
      raise exception using errcode='42501',message='setup provider metadata refused';
    end if;
    -- Only the initial empty-to-valid provider metadata transition is allowed.
    if not (coalesce(old.raw_app_meta_data,'{}'::jsonb) ?| array['church_setup_operation','church_setup_nonce']) then
      return new;
    end if;
  end if;
  select * into i from app.identity_admin_setup_invites
    where mode='new_account' and auth_user_id=old.id;
  if found and i.state<>'completed' and (old.id is distinct from new.id
    or old.phone is distinct from new.phone or v_changed) then
    raise exception using errcode='42501',message='unclaimed setup account changes refused';
  end if;
  return new;
end;
$$;
create trigger identity_admin_setup_provider_correlation before update of id,phone,raw_app_meta_data
  on auth.users for each row execute function app.identity_admin_setup_auth_update_guard();

-- A provisional Auth insert is never allowed to COMMIT without server-owned
-- correlation. Inspect the final row, not the earlier INSERT trigger snapshot.
-- This models GoTrue's actual atomic insert-then-update account creation.
create function app.identity_admin_setup_auth_commit_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare u auth.users; i app.identity_admin_setup_invites;
begin
  select * into u from auth.users where id=new.id;
  if not found then return null; end if;
  select * into i from app.identity_admin_setup_invites where mode='new_account' and auth_user_id=u.id;
  if i.invitation_id is null and not (coalesce(u.raw_app_meta_data,'{}'::jsonb)
      ?| array['church_setup_operation','church_setup_nonce']) then return null; end if;
  if i.invitation_id is null or i.state<>'provisioning' or i.cleanup_started_at is not null
    or i.expires_at<=clock_timestamp() or i.environment<>app.platform_current_environment()
    or u.raw_app_meta_data->>'church_setup_operation' is distinct from i.operation_id::text
    or u.raw_app_meta_data->>'church_setup_nonce' is distinct from i.correlation_nonce::text
    or '+'||ltrim(u.phone,'+') is distinct from i.phone_username then
    raise exception using errcode='42501',message='setup provider transaction incomplete';
  end if;
  return null;
end;
$$;
create constraint trigger identity_admin_setup_provider_commit after insert on auth.users
  deferrable initially deferred for each row execute function app.identity_admin_setup_auth_commit_guard();

create function app.identity_admin_setup_redact_unclaimed(p_invitation uuid) returns void
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites;
begin
  select * into i from app.identity_admin_setup_invites where invitation_id=p_invitation for update;
  if i.mode='new_account' and i.auth_user_id is not null then
    -- Auth retains contact-bearing audit records after account deletion. Purge
    -- only the proven-absent, never-linked setup orphan before losing its id.
    if exists(select 1 from auth.users where id=i.auth_user_id)
      or exists(select 1 from app.identity_account_links where auth_user_id=i.auth_user_id)
      or exists(select 1 from app.identity_deletion_accounts where auth_user_id=i.auth_user_id) then
      raise exception using errcode='22023',message='setup orphan absence not confirmed';
    end if;
    if pg_catalog.to_regclass('auth.audit_log_entries') is not null then
      execute 'delete from auth.audit_log_entries e where e.payload ->> ''actor_id'' = $1
        or e.payload -> ''traits'' ->> ''user_id'' = $1' using i.auth_user_id::text;
    end if;
  end if;
  update app.identity_admin_setup_invites set state='erased',digest=null,phone_username=null,
    auth_user_id=null,case_reference=null,request_id=null,operation_id=null,correlation_nonce=null,
    full_name=null,privacy_notice_version=null,intent_hash=null,member_id=null,grant_id=null,
    provider_settled_at=clock_timestamp(),cleanup_completed_at=clock_timestamp()
    where invitation_id=p_invitation and state<>'completed';
end;
$$;

create function app.identity_admin_setup_cleanup_prepare(p_invitation uuid,p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites; u auth.users;
begin
  perform app.ops_require_operator(p_operator);
  perform 1 from app.identity_roles where role='admin' for update;
  perform 1 from app.identity_admin_commissioning where singleton for update;
  select * into i from app.identity_admin_setup_invites where invitation_id=p_invitation for update;
  if not found or i.environment<>app.platform_current_environment() then
    raise exception using errcode='22023',message='invitation unavailable in this environment';
  end if;
  if i.state='erased' then return jsonb_build_object('outcome','cleaned'); end if;
  if i.state='completed' then
    if i.expires_at>clock_timestamp() then
      return jsonb_build_object('outcome','completed','cleanup_eligible',false);
    end if;
    if i.digest is not null or i.correlation_nonce is not null then
      update app.identity_admin_setup_invites set digest=null,phone_username=null,case_reference=null,
        request_id=null,operation_id=null,correlation_nonce=null,full_name=null,intent_hash=null,
        cleanup_started_at=coalesce(cleanup_started_at,clock_timestamp()),cleanup_completed_at=clock_timestamp()
        where invitation_id=p_invitation;
      insert into app.identity_admin_setup_audit(invitation_id,action,operator,member_id)
        values(p_invitation,'completion_redacted',p_operator,i.member_id);
    end if;
    return jsonb_build_object('outcome','completed','cleanup_eligible',false);
  end if;
  if i.mode='new_account' and (
    exists(select 1 from app.identity_account_links where auth_user_id=i.auth_user_id)
    or exists(select 1 from app.identity_deletion_accounts where auth_user_id=i.auth_user_id)
    or i.member_id is not null or i.grant_id is not null) then
    raise exception using errcode='22023',message='member history requires normal identity recovery';
  end if;
  -- Revocation and the Auth insertion guard take the same locks. After this
  -- transaction commits, no old provider operation can insert its reserved id.
  update app.identity_admin_setup_invites set state='revoked',revoked_at=coalesce(revoked_at,clock_timestamp()),
    digest=null,full_name=null,intent_hash=null,cleanup_started_at=coalesce(cleanup_started_at,clock_timestamp())
    where invitation_id=p_invitation;
  if i.cleanup_started_at is null then
    insert into app.identity_admin_setup_audit(invitation_id,action,operator,operation_id)
      values(p_invitation,'cleanup_started',p_operator,i.operation_id);
  end if;
  if i.mode='existing_account' then
    -- Never remove or alter the account that existed before the invitation.
    perform app.identity_admin_setup_redact_unclaimed(p_invitation);
    insert into app.identity_admin_setup_audit(invitation_id,action,operator)
      values(p_invitation,'cleanup_completed',p_operator);
    return jsonb_build_object('outcome','cleaned','existing_account_preserved',true);
  end if;
  select * into u from auth.users where id=i.auth_user_id for update;
  if not found then
    perform app.identity_admin_setup_redact_unclaimed(p_invitation);
    insert into app.identity_admin_setup_audit(invitation_id,action,operator)
      values(p_invitation,'cleanup_completed',p_operator);
    return jsonb_build_object('outcome','cleaned','late_provider_fenced',true);
  end if;
  if i.operation_id is null or i.correlation_nonce is null
    or u.raw_app_meta_data->>'church_setup_operation' is distinct from i.operation_id::text
    or u.raw_app_meta_data->>'church_setup_nonce' is distinct from i.correlation_nonce::text
    or '+'||ltrim(u.phone,'+') is distinct from i.phone_username then
    -- Do not delete a collision or independently altered account. The revoked
    -- invitation remains fenced and reissue remains blocked for operator review.
    return jsonb_build_object('outcome','operator_review_required');
  end if;
  perform app.identity_revoke_auth_sessions(u.id);
  return jsonb_build_object('outcome','delete_orphan','auth_user_id',u.id,
    'invitation_id',i.invitation_id,'operation_id',i.operation_id);
end;
$$;

create function app.identity_admin_setup_cleanup_finish(p_invitation uuid,p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
declare i app.identity_admin_setup_invites;
begin
  perform app.ops_require_operator(p_operator);
  perform 1 from app.identity_roles where role='admin' for update;
  perform 1 from app.identity_admin_commissioning where singleton for update;
  select * into i from app.identity_admin_setup_invites where invitation_id=p_invitation for update;
  if not found or i.environment<>app.platform_current_environment() then
    raise exception using errcode='22023',message='invitation unavailable in this environment';
  end if;
  if i.state='erased' then return jsonb_build_object('outcome','cleaned'); end if;
  if i.state<>'revoked' or i.cleanup_started_at is null or i.mode<>'new_account'
    or i.member_id is not null or i.grant_id is not null
    or exists(select 1 from app.identity_account_links where auth_user_id=i.auth_user_id)
    or exists(select 1 from app.identity_deletion_accounts where auth_user_id=i.auth_user_id) then
    raise exception using errcode='22023',message='cleanup is not authorised for this account';
  end if;
  if exists(select 1 from auth.users where id=i.auth_user_id) then
    return jsonb_build_object('outcome','cleanup_pending');
  end if;
  perform app.identity_admin_setup_redact_unclaimed(p_invitation);
  insert into app.identity_admin_setup_audit(invitation_id,action,operator)
    values(p_invitation,'cleanup_completed',p_operator);
  return jsonb_build_object('outcome','cleaned','late_provider_fenced',true);
end;
$$;

create function app.identity_admin_setup_operator_view(p_invitation uuid,p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
begin
  perform app.ops_require_operator(p_operator);
  if p_invitation is null then return app.identity_admin_setup_operator_status(p_operator); end if;
  return (select jsonb_build_object('invitation_id',i.invitation_id,'state',i.state,'mode',i.mode,
    'environment',i.environment,'expires_at',app.cmd_utc(i.expires_at),
    'expired',i.expires_at<=clock_timestamp(),'commissioned',c.commissioned_at is not null,
    'provider_reconciliation_required',i.started_at is not null and i.provider_settled_at is null,
    'cleanup_pending',i.cleanup_started_at is not null and i.cleanup_completed_at is null,
    'provider_account_present',exists(select 1 from auth.users u where u.id=i.auth_user_id))
    from app.identity_admin_setup_invites i cross join app.identity_admin_commissioning c
    where i.invitation_id=p_invitation and i.environment=app.platform_current_environment() and c.singleton);
end;
$$;

create function app.identity_admin_setup_cleanup_candidates(p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
begin
  perform app.ops_require_operator(p_operator);
  return (select coalesce(jsonb_agg(jsonb_build_object('invitation_id',i.invitation_id,'state',i.state,
    'mode',i.mode,'expired',i.expires_at<=clock_timestamp()) order by i.issued_at,i.invitation_id),'[]'::jsonb)
    from (select * from app.identity_admin_setup_invites
      where environment=app.platform_current_environment() and state<>'erased'
        and (state in ('revoked','failed') or expires_at<=clock_timestamp())
        and not (state='completed' and cleanup_completed_at is not null)
      order by issued_at,invitation_id limit 25) i);
end;
$$;

do $$ declare p regprocedure; begin
  for p in select oid::regprocedure from pg_proc where pronamespace='app'::regnamespace
    and proname like 'identity_admin_setup_%'
  loop execute format('revoke all on function %s from public,anon,authenticated,service_role',p); end loop;
end $$;

create function app.identity_admin_setup_lookup_digest(p_digest text,p_operator text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  perform app.ops_require_operator(p_operator);
  if p_digest is null or p_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='invalid invitation lookup';
  end if;
  select invitation_id into v_id from app.identity_admin_setup_invites
    where digest=p_digest and environment=app.platform_current_environment();
  if v_id is null then return null; end if;
  return app.identity_admin_setup_operator_view(v_id,p_operator);
end;
$$;
revoke all on function app.identity_admin_setup_lookup_digest(text,text) from public,anon,authenticated,service_role;
