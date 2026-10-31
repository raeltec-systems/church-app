-- Existing-account enrollment: a refused completion must not strand setup.
-- Auth rows/sessions here are explicit transaction-scoped fixtures, not GoTrue calls.
begin;
select no_plan();
select app.platform_set_environment('local','pgtap existing-account commissioning');
create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000318'||lpad(n::text,2,'0'))::uuid $$;
create function pg_temp.session(n int,p_user uuid,p_at timestamptz) returns uuid language sql as $$
  insert into auth.sessions(id,user_id,aal,created_at) values(pg_temp.u(n),p_user,'aal1',p_at);
  insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
    values(gen_random_uuid(),pg_temp.u(n),clock_timestamp(),clock_timestamp(),'password');
  select pg_temp.u(n);
$$;
insert into auth.users(id,instance_id,aud,role,phone,phone_confirmed_at,encrypted_password,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values(pg_temp.u(1),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  '447700900818',clock_timestamp(),'SYNTHETIC-UNCHANGED-HASH','{}','{}',clock_timestamp(),clock_timestamp()),
  (pg_temp.u(2),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  '447700900819',clock_timestamp(),'SYNTHETIC-OTHER-HASH','{}','{}',clock_timestamp(),clock_timestamp());
select pg_temp.session(11,pg_temp.u(1),clock_timestamp()-interval '10 minutes');
create temp table invited as select app.identity_admin_setup_issue(repeat('f',64),'+447700900818',
  pg_temp.u(1),true,'established_relationship','SETUP-existing-pgtap','israel') value;
select pg_temp.session(12,pg_temp.u(2),clock_timestamp());
select pg_temp.session(13,pg_temp.u(1),clock_timestamp());
create function pg_temp.setup(p_action text,p_session uuid default null) returns jsonb language sql as $$
 select app.identity_sys_admin_setup(null,gen_random_uuid(),jsonb_build_object(
   'action',p_action,'invitation_digest',repeat('f',64),'phone_username','+447700900818',
   'client_key',encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'),
   'request_id',pg_temp.u(20),'session_id',p_session,'full_name','SYNTHETIC Existing Administrator',
   'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true))->'data'
$$;
select is(pg_temp.setup('begin',pg_temp.u(11))->>'outcome','password_rejected','proof older than the invitation is refused');
select is(pg_temp.setup('begin',pg_temp.u(12))->>'outcome','password_rejected','another account password session is refused');
select is((select state from app.identity_admin_setup_invites),'issued','bad proof creates no pending operation');
-- Account eligibility changed after invitation, before completion. No Auth Admin
-- write is made in this path, so a definite refusal is not an uncertain provider call.
update auth.users set email='synthetic-setup@example.test',email_confirmed_at=null where id=pg_temp.u(1);
select is(pg_temp.setup('begin',pg_temp.u(13))->>'outcome','refused','unverified changed recovery email refuses enrollment');
select is((select count(*)::int from app.identity_grants where role='admin'),0,'refused enrollment grants nothing');
select is((select state from app.identity_admin_setup_invites),'issued','definite existing-account refusal restores the invitation to ready');
select is(app.identity_admin_setup_operator_status('israel')->'provider_reconciliation_required','false'::jsonb,
  'operator is not told to reconcile a provider creation that was never attempted');
select ok((select request_id is null and operation_id is null and correlation_nonce is null
  and started_at is null and full_name is null from app.identity_admin_setup_invites),
  'refused completion discards temporary proof correlation and submitted name');
update auth.users set email=null where id=pg_temp.u(1);
select pg_temp.session(14,pg_temp.u(1),clock_timestamp());
select is(pg_temp.setup('begin',pg_temp.u(14))->>'outcome','completed','a deliberate retry with fresh proof can complete safely');
select is((select auth_user_id from app.identity_account_links),pg_temp.u(1),'the explicitly bound account is retained');
select is((select encrypted_password from auth.users where id=pg_temp.u(1)),'SYNTHETIC-UNCHANGED-HASH','setup never resets the existing password');
select is((select count(*)::int from auth.sessions where user_id=pg_temp.u(1)),0,'all earlier sessions of the enrolled account are revoked');
select is((select count(*)::int from auth.sessions where user_id=pg_temp.u(2)),1,'another account session is not revoked');
select is((select count(*)::int from app.identity_grants where role='admin'),1,'retry creates one Admin grant');
select ok((select commissioned_at is not null from app.identity_admin_commissioning),'successful retry closes commissioning permanently');
select * from finish();
rollback;
