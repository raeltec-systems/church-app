-- Transactional commissioning completion and purpose isolation. Provider rows below
-- are explicit test fixtures; real GoTrue/HTTP execution has its own integration run.
begin;
select no_plan();
select app.platform_set_environment('local', 'pgtap commissioning completion');
create temp table setup_ids(k text primary key,v uuid);
create temp table setup_results(k text primary key,v jsonb);
insert into setup_ids values('principal',app.sys_create_principal('setup-completion','identity_admin_onboarding','israel'));
select app.sys_register_credential((select v from setup_ids where k='principal'),
  encode(sha256(convert_to('sysc_local_'||repeat('A',43),'UTF8')),'hex'),
  'pgtap setup',interval '1 hour','israel');
insert into setup_ids values('other',app.sys_create_principal('setup-wrong-purpose','synthetic_probe','israel'));
select app.sys_register_credential((select v from setup_ids where k='other'),
  encode(sha256(convert_to('sysc_local_'||repeat('B',43),'UTF8')),'hex'),
  'pgtap other',interval '1 hour','israel');
insert into setup_results values('issue',app.identity_admin_setup_issue(
  repeat('d',64),'+447700900818',null,true,'in_person','SETUP-pgtap-completion','israel'));
create function pg_temp.setup(p_action text,p_extra jsonb default '{}'::jsonb,
  p_credential text default 'A',p_role text default 'anon',p_request uuid default gen_random_uuid())
returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('role',p_role)::text,true);
  perform set_config('request.headers',jsonb_build_object('x-system-credential','sysc_local_'||repeat(p_credential,43))::text,true);
  execute format('set local role %I',p_role);
  r:=api.system_command(jsonb_build_object('version',1,'command','identity.admin_setup',
    'request_id',p_request,'payload',jsonb_build_object('action',p_action,
      'invitation_digest',repeat('d',64),'phone_username','+447700900818',
      'client_key',encode(sha256(convert_to(p_request::text,'UTF8')),'hex'))||p_extra));
  reset role;
  return r;
end $$;
select is(pg_temp.setup('inspect','{}','B')->>'code','forbidden','a different system purpose cannot inspect an invitation');
select is(pg_temp.setup('inspect','{}','A','authenticated')->>'code','forbidden','a user-session route cannot use a setup system credential');
select is(pg_temp.setup('inspect','{"role":"admin"}')->>'code','validation_failed','the system route rejects a forged role field');
select is(pg_temp.setup('inspect')->'data'->>'outcome','ready','purpose-bound system route inspects the invitation');
insert into setup_results values('begin',pg_temp.setup('begin',jsonb_build_object(
  'request_id','a1111111-1111-4111-8111-111111111111','full_name','SYNTHETIC Setup Administrator',
  'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true)));
select is((select v->'data'->>'outcome' from setup_results where k='begin'),'provision','the credentialed route reserves provider authority once');
select ok(not exists(select 1 from app.sys_receipts r
  where r.command='identity.admin_setup' and (r.result ? 'data' or r.result::text like '%correlation_nonce%')),
  'system receipts retain no provisioning nonce or private response');
insert into setup_ids select 'account',(v->'data'->>'auth_user_id')::uuid from setup_results where k='begin';
-- Model a provider-created account with only USER metadata: it must not be trusted.
insert into auth.users(id,instance_id,aud,role,phone,phone_confirmed_at,encrypted_password,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select (v->'data'->>'auth_user_id')::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  '447700900818',clock_timestamp(),'SYNTHETIC-NOT-A-PASSWORD-HASH','{}'::jsonb,
  jsonb_build_object('church_setup_operation',v->'data'->>'operation_id',
    'church_setup_nonce',v->'data'->>'correlation_nonce'),clock_timestamp(),clock_timestamp()
from setup_results where k='begin';
select is(pg_temp.setup('status','{"request_id":"a1111111-1111-4111-8111-111111111111"}')->'data'->>'outcome',
  'refused','user-editable metadata cannot authorize commissioning');
select is((select count(*)::int from app.identity_grants where role='admin'),0,'untrusted provider correlation grants nothing');
update auth.users set raw_app_meta_data=(select jsonb_build_object(
  'church_setup_operation',v->'data'->>'operation_id','church_setup_nonce',v->'data'->>'correlation_nonce')
  from setup_results where k='begin') where id=(select v from setup_ids where k='account');
insert into auth.sessions(id,user_id,aal,created_at)
  values('b1111111-1111-4111-8111-111111111111',(select v from setup_ids where k='account'),'aal1',clock_timestamp());
insert into setup_results values('complete',pg_temp.setup('status',
  '{"request_id":"a1111111-1111-4111-8111-111111111111"}'));
select is((select v->'data'->>'outcome' from setup_results where k='complete'),'completed','observed server-owned provider correlation completes enrollment');
select is((select v->'data'->'sign_in_required' from setup_results where k='complete'),'true'::jsonb,'completion requires a new ordinary sign-in');
select is((select count(*)::int from app.identity_members where membership_state='approved'),1,'exactly one approved member is created');
select is((select count(*)::int from app.identity_account_links),1,'exactly one account link is created');
select is((select count(*)::int from app.identity_grants where role='admin' and revoked_at is null),1,'exactly one Admin grant is created');
select is((select count(*)::int from auth.sessions where user_id=(select v from setup_ids where k='account')),0,'pre-commissioning sessions are revoked');
select is((select source from app.identity_admin_commissioning),'owner_invitation','commissioning permanently records its owner-authorised origin');
select is((select count(*)::int from app.identity_admin_setup_audit where action='commissioned'),1,'operator provenance is recorded once');
select is((select count(*)::int from app.identity_membership_audit),0,'no fabricated new Admin self-approval audit is written');
select is(pg_temp.setup('status','{"request_id":"a1111111-1111-4111-8111-111111111111"}')->'data'->>'outcome','completed','lost completion response is recoverable');
select is((select count(*)::int from app.identity_grants where role='admin'),1,'status replay creates no duplicate privilege');
select throws_ok($$select app.identity_admin_setup_issue(repeat('e',64),'+447700900819',null,
  true,'in_person','SETUP-other','israel')$$,'22023',null,'new first-Admin invitation is refused after commissioning');
insert into setup_ids select 'member',member_id from app.identity_account_links where auth_user_id=(select v from setup_ids where k='account');
insert into app.identity_holds(member_id,hold_kind,reason,placed_by)
  values((select v from setup_ids where k='member'),'security','SYNTHETIC test hold','pgtap');
select is(pg_temp.setup('status','{"request_id":"a1111111-1111-4111-8111-111111111111"}')->'data'->>'outcome','refused','replaying completed setup never revives a held Admin');
select ok((select commissioned_at is not null from app.identity_admin_commissioning),'loss of usable Admin access does not reopen commissioning');
select app.identity_management_erase_data((select v from setup_ids where k='member'),array[(select v from setup_ids where k='account')]);
select ok(not exists(select 1 from app.identity_admin_setup_invites where digest is not null or phone_username is not null or auth_user_id is not null or full_name is not null or correlation_nonce is not null),'Identity erasure clears enrollment personal data and authority');
select ok((select commissioned_at is not null from app.identity_admin_commissioning),'erasure preserves the non-personal terminal commissioning latch');
select * from finish();
rollback;
