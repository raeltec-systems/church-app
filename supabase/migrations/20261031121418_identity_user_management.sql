-- Users & access: bounded management projections and audited ordinary profile corrections.
-- SOURCE DELIVERY ONLY. Existing approved-member pickers and credentials stay unchanged.
-- New APIs require the CURRENT Admin grant; navigation is never the access control.

create table app.identity_profile_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  actor_member_id uuid,
  member_id uuid not null,
  request_id uuid not null,
  action text not null default 'profile_corrected' check (action='profile_corrected'),
  changed_fields text[] not null check (changed_fields <@ array['full_name','contact_routes']),
  consent_basis text not null check (consent_basis in ('in_person','leader_assisted')),
  revision_after bigint not null check (revision_after>=1)
);
comment on table app.identity_profile_audit is
  'owner: identity. Ordinary profile correction metadata; no old/new contact values or credential data.';
create index identity_profile_audit_member on app.identity_profile_audit(member_id,occurred_at,event_id);
create index identity_members_management_page on app.identity_members
  (membership_state,display_name collate "C",member_id);
alter table app.identity_profile_audit enable row level security;
revoke all on table app.identity_profile_audit from public,anon,authenticated,service_role;
revoke all on sequence app.identity_profile_audit_event_id_seq from public,anon,authenticated,service_role;

create function app.identity_management_account_label(p_member uuid) returns text
language sql stable set search_path = '' as $$
  select case when l.link_id is null then 'no_login'
    when s.outcome='ok' and app.identity_link_dormancy(l.link_id) is null then 'app_account'
    else 'access_review' end
  from (select 1) one left join app.identity_account_links l
    on l.member_id=p_member and l.link_state<>'ended'
  left join lateral app.identity_account_standing(l.auth_user_id) s on l.link_id is not null;
$$;

create function app.identity_management_record(p_member uuid) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_admin_member_json(m.member_id) || jsonb_build_object(
    'membership_state',m.membership_state,
    'account',app.identity_management_account_label(m.member_id),
    'grants',app.identity_member_grants_json(m.member_id),
    'deletion_pending',exists(select 1 from app.identity_deletions d where d.member_id=m.member_id),
    'commissioned_admin',exists(select 1 from app.identity_admin_setup_audit a
      where a.member_id=m.member_id and a.action='commissioned'))
  from app.identity_members m where m.member_id=p_member
    and not exists(select 1 from app.identity_deletions d
      where d.member_id=m.member_id and d.deletion_state='completed');
$$;

create function app.identity_admin_users(
  p_query text,p_membership text,p_account text,p_role text,
  p_after_name text,p_after_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_link uuid; v_pattern text; v_rows jsonb; v_count integer;
begin
  select g.link_id into v_link from app.identity_require_grant('admin',null,null,true) g;
  if p_membership is null or p_membership not in ('all','approved','deactivated','pending','rejected')
    or p_account is null or p_account not in ('all','app_account','no_login','access_review')
    or (p_role is not null and not exists(select 1 from app.identity_roles where role=p_role))
    or (p_after_name is null)<>(p_after_id is null)
    or length(coalesce(p_after_name,''))>120 or length(coalesce(p_query,''))>120 then
    raise exception using errcode='22023',message='invalid management filter or cursor';
  end if;
  if nullif(btrim(coalesce(p_query,'')),'') is not null then
    v_pattern:='%'||replace(replace(replace(btrim(p_query),'\','\\'),'%','\%'),'_','\_')||'%';
  end if;
  select coalesce(jsonb_agg(x.obj order by x.rn) filter(where x.rn<=25),'[]'::jsonb),count(*)
  into v_rows,v_count from (
    select row_number() over(order by m.display_name collate "C",m.member_id) rn,
      app.identity_management_record(m.member_id) obj
    from app.identity_members m
    where (p_membership='all' or m.membership_state=p_membership)
      and (p_account='all' or app.identity_management_account_label(m.member_id)=p_account)
      and (p_role is null or app.identity_member_has_role(m.member_id,p_role))
      and not exists(select 1 from app.identity_deletions d where d.member_id=m.member_id and d.deletion_state='completed')
      and (v_pattern is null or m.display_name ilike v_pattern
        or exists(select 1 from app.identity_contact_routes c
          where c.member_id=m.member_id and c.ended_at is null and c.value like v_pattern))
      and (p_after_name is null or (m.display_name collate "C",m.member_id)>(p_after_name collate "C",p_after_id))
    order by m.display_name collate "C",m.member_id limit 26
  ) x;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object('members',v_rows,'next',case when v_count>25 then
    jsonb_build_object('after_display_name',v_rows->24->>'display_name','after_member_id',v_rows->24->>'member_id') end,
    'roles',(select coalesce(jsonb_agg(jsonb_build_object('role',role,'available',role<>'lead_pastor' and (requires_setting is null or app.identity_church_setting_enabled(requires_setting))) order by sort_order),'[]'::jsonb)
      from app.identity_roles));
end;
$$;

create function api.identity_admin_users(
  query text default null,membership text default 'all',account text default 'all',role_filter text default null,
  after_display_name text default null,after_member_id uuid default null
) returns jsonb language sql security invoker set search_path = '' as $$
  select app.identity_admin_users(query,membership,account,role_filter,after_display_name,after_member_id);
$$;

create function app.identity_admin_user_detail(p_member uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a record; r jsonb;
begin
  select * into a from app.identity_require_grant('admin',null,null,true);
  r:=app.identity_management_record(p_member);
  if r is null then raise exception using errcode='PT404',message='not_found'; end if;
  perform app.identity_record_activity(a.link_id);
  return jsonb_build_object('member',r,'own_record',p_member=a.member_id);
end;
$$;
create function api.identity_admin_user_detail(member_id uuid) returns jsonb
language sql security invoker set search_path = '' as $$
  select app.identity_admin_user_detail(member_id);
$$;

-- One purpose-limited activity read. Never return raw audit rows, Auth ids, case secrets,
-- historical contacts, personal recovery reasons, or care/finance content.
create function app.identity_admin_user_activity(
  p_member uuid,p_after_at timestamptz,p_after_source text,p_after_event bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_link uuid; v_rows jsonb; v_count integer;
begin
  select g.link_id into v_link from app.identity_require_grant('admin',null,null,true) g;
  if app.identity_management_record(p_member) is null then
    raise exception using errcode='PT404',message='not_found';
  end if;
  if num_nonnulls(p_after_at,p_after_source,p_after_event) not in (0,3)
    or (p_after_source is not null and p_after_source not in ('access','profile','membership','credentials','recovery','commissioning'))
    or p_after_event<1 then raise exception using errcode='22023',message='invalid activity cursor'; end if;
  with events as (
    select 'access'::text source,event_id,occurred_at,action,actor_member_id,
      actor_kind,role,'{}'::text[] changed_fields
      from app.identity_access_audit where target_member_id=p_member
    union all
    select 'profile',event_id,occurred_at,action,actor_member_id,'member',null,changed_fields
      from app.identity_profile_audit where member_id=p_member
    union all
    select 'membership',event_id,occurred_at,action,actor_member_id,'member',null,'{}'::text[]
      from app.identity_membership_lifecycle where member_id=p_member
    union all
    select 'credentials',event_id,occurred_at,action,actor_member_id,'member',null,'{}'::text[]
      from app.identity_credential_review_audit where member_id=p_member
    union all
    select 'recovery',event_id,occurred_at,action,actor_member_id,
      case when actor_kind='admin' then 'member' else 'system' end,null,'{}'::text[]
      from app.identity_recovery_audit where member_id=p_member
    union all
    select 'commissioning',event_id,occurred_at,action,null,'operator',null,'{}'::text[]
      from app.identity_admin_setup_audit where member_id=p_member
  ), page as (
    select * from events e where p_after_at is null
      or (e.occurred_at,e.source collate "C",e.event_id)<(p_after_at,p_after_source collate "C",p_after_event)
    order by occurred_at desc,source collate "C" desc,event_id desc limit 51
  ), rendered as (
    select row_number() over(order by occurred_at desc,source collate "C" desc,event_id desc) rn,
      jsonb_build_object('source',source,'event_id',event_id::text,'at',app.cmd_utc(occurred_at),
        'action',action,'actor_kind',actor_kind,'actor_label',
        case when actor_kind='operator' then 'Restricted operator'
          when actor_kind='system' then 'System'
          else coalesce((select case when m.display_name=app.identity_deletion_placeholder()
            then 'Former staff member' else m.display_name end from app.identity_members m
            where m.member_id=page.actor_member_id),'Former staff member') end,
        'role',role,'changed_fields',changed_fields) obj
    from page
  ) select coalesce(jsonb_agg(obj order by rn) filter(where rn<=50),'[]'::jsonb),count(*)
    into v_rows,v_count from rendered;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object('events',v_rows,'next',case when v_count>50 then jsonb_build_object(
    'after_at',v_rows->49->>'at','after_source',v_rows->49->>'source','after_event_id',v_rows->49->>'event_id') end);
end;
$$;
create function api.identity_admin_user_activity(
  member_id uuid,after_at timestamptz default null,after_source text default null,after_event_id bigint default null
) returns jsonb language sql security invoker set search_path = '' as $$
  select app.identity_admin_user_activity(member_id,after_at,after_source,after_event_id);
$$;

create function app.identity_update_member_profile(p_actor uuid,p_expected_revision bigint,p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare a record; m app.identity_members; e jsonb; v_name text; c jsonb;
  v_changed text[]:='{}'; v_old jsonb; v_new jsonb; v_contacts jsonb;
begin
  select * into a from app.identity_command_actor(p_actor);
  e:=app.contract_unknown_keys(p_payload,array['member_id','full_name','contact_routes','consent_basis']);
  if app.contract_uuid_error(p_payload->'member_id') is not null then e:=e||'{"member_id":"invalid"}'; end if;
  select x.errors,x.full_name into e,v_name from app.identity_application_name(p_payload->'full_name',e) x;
  if coalesce(p_payload->>'consent_basis','') not in ('in_person','leader_assisted') then e:=e||'{"consent_basis":"invalid"}'; end if;
  v_contacts:=p_payload->'contact_routes';
  if jsonb_typeof(v_contacts) is distinct from 'array' then e:=e||'{"contact_routes":"invalid"}';
  elsif jsonb_array_length(v_contacts)>5 then e:=e||'{"contact_routes":"out_of_range"}';
  else
    for c in select value from jsonb_array_elements(v_contacts) loop
      if jsonb_typeof(c) is distinct from 'object' then e:=e||'{"contact_routes":"invalid"}'; exit; end if;
      if app.contract_unknown_keys(c,array['phone','belongs_to','holder_label'])<>'{}'::jsonb
        or jsonb_typeof(c->'phone') is distinct from 'string'
        or coalesce(c->>'phone','') !~ '^\+[1-9][0-9]{7,14}$'
        or coalesce(c->>'belongs_to','') not in ('member','relative','household','other')
        or (c->>'belongs_to'<>'member' and (jsonb_typeof(c->'holder_label') is distinct from 'string'
          or length(btrim(c->>'holder_label')) not between 1 and 60))
        or (c->>'holder_label') ~ '[[:cntrl:]]'
        or (c->'holder_label' is not null and c->'holder_label'<>'null'::jsonb
          and (jsonb_typeof(c->'holder_label')<>'string' or length(btrim(c->>'holder_label'))>60)) then
        e:=e||'{"contact_routes":"invalid"}';
      end if;
    end loop;
  end if;
  if e<>'{}'::jsonb then perform app.cmd_fail('validation_failed',e); end if;
  if not app.identity_applications_open() then perform app.cmd_fail('unavailable','{"policy":"gate_closed"}'); end if;
  select * into m from app.identity_members where member_id=(p_payload->>'member_id')::uuid for update;
  if not found then perform app.cmd_fail('not_found'); end if;
  if m.member_id=a.member_id then perform app.cmd_fail('forbidden','{"member_id":"unsupported"}'); end if;
  if exists(select 1 from app.identity_deletions where member_id=m.member_id) then
    perform app.cmd_fail('conflict','{"member_id":"deletion_pending"}',m.revision);
  end if;
  if m.membership_state not in ('approved','deactivated') then perform app.cmd_fail('conflict',null,m.revision); end if;
  if m.revision is distinct from p_expected_revision then perform app.cmd_fail('conflict',null,m.revision); end if;
  if m.is_synthetic and (v_name !~ '^SYNTHETIC '
    or exists(select 1 from jsonb_array_elements(v_contacts) x
      where x->>'phone' !~ '^\+(120255501[0-9]{2}|447700900[0-9]{3})$')) then
    perform app.cmd_fail('validation_failed','{"contact_routes":"invalid"}');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('phone',value,'belongs_to',belongs_to,'holder_label',holder_label)
    order by value,belongs_to,coalesce(holder_label,'')),'[]'::jsonb) into v_old
    from app.identity_contact_routes where member_id=m.member_id and ended_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('phone',x->>'phone','belongs_to',x->>'belongs_to',
    'holder_label',case when x->>'belongs_to'='member' then null else btrim(x->>'holder_label') end)
    order by x->>'phone',x->>'belongs_to',coalesce(btrim(x->>'holder_label'),'')),'[]'::jsonb)
    into v_new from jsonb_array_elements(v_contacts) x;
  if m.display_name is distinct from v_name then v_changed:=v_changed||'full_name'::text; end if;
  if v_old is distinct from v_new then
    v_changed:=v_changed||'contact_routes'::text;
    update app.identity_contact_routes set ended_at=clock_timestamp()
      where member_id=m.member_id and ended_at is null;
    for c in select value from jsonb_array_elements(v_new) loop
      insert into app.identity_contact_routes(member_id,value,belongs_to,holder_label,is_synthetic,
        created_by_member,created_by_account)
      values(m.member_id,c->>'phone',c->>'belongs_to',c->>'holder_label',m.is_synthetic,a.member_id,a.account_id);
    end loop;
  end if;
  if cardinality(v_changed)>0 then
    update app.identity_members set display_name=v_name,revision=revision+1,updated_at=clock_timestamp()
      where member_id=m.member_id returning * into m;
    insert into app.identity_profile_audit(actor_member_id,member_id,request_id,changed_fields,consent_basis,revision_after)
    values(a.member_id,m.member_id,app.cmd_current_request_id(p_actor,'identity.update_member_profile'),
      v_changed,p_payload->>'consent_basis',m.revision);
  end if;
  return jsonb_build_object('aggregate_type','identity_member','aggregate_id',m.member_id,
    'revision',m.revision,'data',app.identity_management_record(m.member_id));
end;
$$;

create function app.identity_management_in_scope(p_actor uuid,p_type text,p_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select p_type='identity_member' and p_id is not null
    and exists(select 1 from app.identity_members where member_id=p_id)
    and not exists(select 1 from app.identity_deletions where member_id=p_id);
$$;

-- Preserve every existing command branch; add only the ordinary profile-correction command.
create or replace function app.identity_authorize_command(p_request jsonb) returns boolean
language plpgsql set search_path = '' as $$
declare r record;
begin
  if coalesce(p_request->>'command','') in ('identity.submit_application','identity.correct_application') then
    return app.identity_authorize_application_command(p_request);
  end if;
  if coalesce(p_request->>'command','') in ('identity.propose_recovery_email','identity.request_credential_change','identity.request_my_deletion') then
    return app.identity_authorize_member_credential_command(p_request);
  end if;
  if coalesce(p_request->>'command','') in ('identity.withdraw_recovery_email','identity.withdraw_credential_change') then
    return app.identity_authorize_member_withdraw_command(p_request);
  end if;
  if coalesce(p_request->>'command','') not in (
    'identity.grant_role','identity.revoke_role','identity.grant_scope','identity.revoke_scope',
    'identity.approve_application','identity.link_application','identity.request_application_details','identity.reject_application',
    'identity.create_member','identity.unlink_account','identity.reclaim_phone_username',
    'identity.approve_recovery_email','identity.reject_recovery_email','identity.approve_credential_change','identity.reject_credential_change',
    'identity.place_hold','identity.release_hold','identity.restore_credentials','identity.accept_credentials',
    'identity.open_recovery_case','identity.issue_recovery_grant','identity.cancel_recovery_case','identity.reconcile_recovery_operation',
    'identity.deactivate_membership','identity.restore_membership','identity.request_member_deletion',
    'identity.update_member_profile') then return false; end if;
  select * into r from app.identity_evaluate_grant('admin',null,null);
  if r.outcome in ('unauthenticated','untrusted_session') then perform app.cmd_fail('unauthenticated'); end if;
  if r.outcome<>'granted' then return false; end if;
  perform 1 from app.identity_roles where role='admin' for update;
  perform 1 from app.identity_grants where member_id=r.member_id and role='admin' and revoked_at is null for share;
  return found;
end;
$$;

create function app.identity_user_management_command(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return app.cmd_execute(p,
    case when p->>'command'='identity.update_member_profile'
      then 'app.identity_update_member_profile(uuid,bigint,jsonb)'::regprocedure end,
    'app.identity_management_in_scope(uuid,text,uuid)'::regprocedure,true);
end;
$$;
create function api.identity_user_management_command(jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select app.identity_user_management_command($1); $$;

revoke all on function app.identity_management_account_label(uuid),app.identity_management_record(uuid),
  app.identity_admin_users(text,text,text,text,text,uuid),api.identity_admin_users(text,text,text,text,text,uuid),
  app.identity_admin_user_detail(uuid),api.identity_admin_user_detail(uuid),
  app.identity_admin_user_activity(uuid,timestamptz,text,bigint),api.identity_admin_user_activity(uuid,timestamptz,text,bigint),
  app.identity_update_member_profile(uuid,bigint,jsonb),app.identity_management_in_scope(uuid,text,uuid),
  app.identity_user_management_command(jsonb),api.identity_user_management_command(jsonb)
  from public,anon,authenticated,service_role;
grant execute on function app.identity_admin_users(text,text,text,text,text,uuid),api.identity_admin_users(text,text,text,text,text,uuid),
  app.identity_admin_user_detail(uuid),api.identity_admin_user_detail(uuid),
  app.identity_admin_user_activity(uuid,timestamptz,text,bigint),api.identity_admin_user_activity(uuid,timestamptz,text,bigint),
  app.identity_user_management_command(jsonb),api.identity_user_management_command(jsonb) to authenticated;
notify pgrst,'reload schema';

-- Identity owns these new records: extend its existing erase/verify functions rather than
-- registering an illegal Identity-to-itself deletion hook. Permanent commissioning stays closed.
create function app.identity_management_erase_data(p_member uuid,p_accounts uuid[]) returns void
language plpgsql set search_path = '' as $$
begin
  update app.identity_admin_setup_invites set state='erased',digest=null,phone_username=null,
    auth_user_id=null,case_reference=null,request_id=null,operation_id=null,correlation_nonce=null,
    full_name=null,privacy_notice_version=null,intent_hash=null,member_id=null,grant_id=null
  where member_id=p_member or auth_user_id=any(p_accounts);
  update app.identity_admin_setup_audit set member_id=null,application_id=null,operation_id=null
    where member_id=p_member;
  delete from app.identity_profile_audit where member_id=p_member;
  update app.identity_profile_audit set actor_member_id=null where actor_member_id=p_member;
end;
$$;
revoke all on function app.identity_management_erase_data(uuid,uuid[])
  from public,anon,authenticated,service_role;

create or replace function app.identity_deletion_erase_identity(p_deletion app.identity_deletions)
returns void language plpgsql set search_path = '' as $$
declare
  v_accounts uuid[]:=app.identity_deletion_account_ids(p_deletion.deletion_id);
  v_links uuid[]; v_apps uuid[];
begin
  perform app.identity_management_erase_data(p_deletion.member_id,v_accounts);
  v_links:=array(select l.link_id from app.identity_account_links l
    where l.member_id=p_deletion.member_id or l.auth_user_id=any(v_accounts));
  v_apps:=array(select a.application_id from app.identity_membership_applications a
    where a.member_id=p_deletion.member_id or a.auth_user_id=any(v_accounts));
  insert into app.identity_deletion_aggregates(deletion_id,kind,aggregate_id)
  select p_deletion.deletion_id,x.kind,x.id from (
    select 'link'::text kind,unnest(v_links) id
    union all select 'application',unnest(v_apps)
    union all select 'credential_change',c.change_id from app.identity_credential_changes c
      where c.member_id=p_deletion.member_id or c.link_id=any(v_links)
    union all select 'recovery_email_proposal',p.proposal_id from app.identity_recovery_email_proposals p
      where p.member_id=p_deletion.member_id or p.link_id=any(v_links)
    union all select 'recovery_case',c.case_id from app.identity_recovery_cases c
      where c.member_id=p_deletion.member_id or c.link_id=any(v_links)
    union all select 'recovery_grant',g.grant_id from app.identity_recovery_grants g
      where g.member_id=p_deletion.member_id or g.link_id=any(v_links)
    union all select 'recovery_request',g.recovery_request_id from app.identity_recovery_grants g
      where g.member_id=p_deletion.member_id or g.link_id=any(v_links)
    union all select 'phone_reclaim',r.reclaim_id from app.identity_phone_reclaims r
      where r.released_account_id=any(v_accounts) or r.withdrawn_application_id=any(v_apps)
  ) x where x.id is not null on conflict do nothing;
  perform app.identity_deletion_purge_rows(p_deletion.deletion_id);
  perform app.identity_deletion_redact_receipts(p_deletion);
  update app.identity_members m
    set display_name=app.identity_deletion_placeholder(),membership_state='deactivated',
      revision=m.revision+1,updated_at=now()
    where m.member_id=p_deletion.member_id
      and (m.display_name<>app.identity_deletion_placeholder() or m.membership_state<>'deactivated');
end;
$$;

create or replace function app.identity_deletion_remaining(p_deletion app.identity_deletions,p_with_auth boolean)
returns text[] language plpgsql set search_path = '' as $$
declare
  m uuid:=p_deletion.member_id;
  v_accounts uuid[]:=app.identity_deletion_account_ids(p_deletion.deletion_id);
  v_aggs uuid[]; v_links uuid[]; v_left text[]:='{}'; v_rule record;
  v_account uuid; v_id uuid; v_n bigint; v_owner jsonb; v_identity boolean:=false;
begin
  v_aggs:=array(select g.aggregate_id from app.identity_deletion_aggregates g
    where g.deletion_id=p_deletion.deletion_id);
  v_links:=array(select g.aggregate_id from app.identity_deletion_aggregates g
    where g.deletion_id=p_deletion.deletion_id and g.kind='link');
  if p_with_auth then
    foreach v_account in array v_accounts loop
      if app.identity_deletion_auth_present(v_account) then
        v_left:=v_left||'auth_account'::text; exit;
      end if;
    end loop;
  end if;
  foreach v_account in array v_accounts loop
    if app.identity_deletion_auth_audit_present(v_account) then v_identity:=true; end if;
  end loop;
  if v_identity
    or exists(select 1 from app.identity_admin_setup_invites i
      where i.member_id=m or i.auth_user_id=any(v_accounts))
    or exists(select 1 from app.identity_admin_setup_audit a where a.member_id=m)
    or exists(select 1 from app.identity_profile_audit a where a.member_id=m or a.actor_member_id=m)
    or exists(select 1 from app.identity_account_links l
      where l.member_id=m or l.auth_user_id=any(v_accounts) or l.link_id=any(v_links))
    or exists(select 1 from app.identity_binding_history h where h.link_id=any(v_links))
    or exists(select 1 from app.identity_credential_events e where e.link_id=any(v_links))
    or exists(select 1 from app.identity_holds h where h.member_id=m)
    or exists(select 1 from app.identity_contact_routes c where c.member_id=m)
    or exists(select 1 from app.identity_member_provenance p where p.member_id=m)
    or exists(select 1 from app.identity_membership_applications x
      where x.member_id=m or x.auth_user_id=any(v_accounts) or x.application_id=any(v_aggs))
    or exists(select 1 from app.identity_application_events e where e.application_id=any(v_aggs))
    or exists(select 1 from app.identity_recovery_cases c where c.member_id=m or c.case_id=any(v_aggs))
    or exists(select 1 from app.identity_recovery_grants g where g.member_id=m or g.grant_id=any(v_aggs))
    or exists(select 1 from app.identity_recovery_operations o where o.member_id=m)
    or exists(select 1 from app.identity_recovery_requests r where r.recovery_request_id=any(v_aggs))
    or exists(select 1 from app.identity_credential_changes c where c.member_id=m or c.change_id=any(v_aggs))
    or exists(select 1 from app.identity_recovery_email_proposals p where p.member_id=m or p.proposal_id=any(v_aggs))
    or exists(select 1 from app.identity_phone_reclaims r
      where r.released_account_id=any(v_accounts) or r.reclaim_id=any(v_aggs))
    or exists(select 1 from app.cmd_receipts r
      where r.actor_id=any(v_accounts) or r.aggregate_id=any(v_aggs||array[m,p_deletion.deletion_id]))
    or not exists(select 1 from app.identity_members x
      where x.member_id=m and x.display_name=app.identity_deletion_placeholder() and x.membership_state='deactivated')
  then v_identity:=true; end if;
  if not v_identity then
    foreach v_id in array (array[m]||v_accounts) loop
      if exists(select 1 from app.cmd_receipts r where strpos(r.result::text,v_id::text)>0)
        or exists(select 1 from app.sys_receipts r where strpos(r.result::text,v_id::text)>0) then
        v_identity:=true; exit;
      end if;
    end loop;
  end if;
  if v_identity then v_left:=v_left||'identity'::text; end if;
  foreach v_account in array coalesce(nullif(v_accounts,'{}'::uuid[]),array[null::uuid]) loop
    for v_owner in select x.value from jsonb_array_elements(app.identity_call_deletion_hooks(
      m,v_account,p_deletion.deletion_id,'check')) x loop
      if (v_owner->>'remaining')::integer>0 and not (('owner_'||(v_owner->>'module'))=any(v_left)) then
        v_left:=v_left||('owner_'||(v_owner->>'module'))::text;
      end if;
    end loop;
  end loop;
  <<rules>>
  foreach v_account in array v_accounts loop
    for v_rule in select x.* from app.identity_deletion_retention_rules x loop
      execute format('select count(*) from app.%I where %I = $1',v_rule.table_name,v_rule.column_name)
        into v_n using v_account;
      if v_n>0 then v_left:=v_left||'retained_facts'::text; exit rules; end if;
    end loop;
  end loop;
  return v_left;
end;
$$;
