-- Run only with the repository pgTAP runner against a disposable LOCAL stack.
-- These database protocol/privilege tests do not replace real Auth/HTTP/concurrency tests.
begin;
select no_plan();
-- A new unmarked database deliberately has production behaviour. Exercise that
-- default before installing the transaction-scoped fixture, rolled back below.
select is(app.platform_current_environment(),'production','unmarked database fails closed as production');
select ok(app.identity_admin_setup_notice(true) is null,'production refuses a synthetic setup notice');
select app.platform_set_environment('local', 'pgtap owner-invited commissioning');
select is(app.platform_current_environment(),'local','test fixture is explicitly local inside this transaction');
select has_table('app','identity_admin_commissioning','permanent commissioning latch exists');
select has_table('app','identity_admin_setup_invites','private invitation store exists');
select has_table('app','identity_admin_setup_audit','separate operator provenance exists');
select ok(not exists(select 1 from pg_class where oid in (
  'app.identity_admin_commissioning'::regclass,'app.identity_admin_setup_invites'::regclass,
  'app.identity_admin_setup_audit'::regclass,'app.identity_admin_setup_limits'::regclass)
  and not relrowsecurity),'commissioning tables have RLS');
select ok(not exists(select 1 from unnest(array['anon','authenticated','service_role']) r
  cross join unnest(array['app.identity_admin_commissioning','app.identity_admin_setup_invites',
    'app.identity_admin_setup_audit','app.identity_admin_setup_limits']) t
  cross join unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
  where has_table_privilege(r,t,p)),'client and service roles cannot access commissioning tables');
select ok(not exists(select 1 from pg_proc p
  cross join unnest(array['anon','authenticated','service_role']) r
  where p.pronamespace='app'::regnamespace
    and (p.proname like 'identity_admin_setup_%' or p.proname='identity_sys_admin_setup')
    and has_function_privilege(r,p.oid,'EXECUTE')),'setup procedures are not direct client endpoints');
select ok(not exists(select 1 from pg_proc p,
  aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
  where p.pronamespace='app'::regnamespace
    and (p.proname like 'identity_admin_setup_%' or p.proname='identity_sys_admin_setup')
    and a.grantee=0),'no PUBLIC execution path');
select ok(not exists(select 1 from pg_proc where pronamespace='app'::regnamespace
  and (proname like 'identity_admin_setup_%' or proname='identity_sys_admin_setup')
  and proconfig is distinct from array['search_path=""']),'all setup functions pin search_path');
select is((select purpose from app.sys_command_kinds where command='identity.admin_setup'),
  'identity_admin_onboarding','system command has its own purpose');
select is((select retain_result from app.sys_command_kinds where command='identity.admin_setup'),
  false,'system receipts do not retain provisioning authority');
select ok(app.identity_admin_setup_notice(false) is null,'unapproved live privacy fails closed');
select ok(app.identity_admin_setup_notice(true)->>'text' like 'SYNTHETIC%',
  'fictional enrollment uses an explicitly synthetic notice');
select throws_ok($$select app.identity_admin_setup_operator_status('not-an-operator')$$,
  '42501',null,'unknown operator refused');
select throws_ok($$select app.identity_admin_setup_issue(repeat('a',64),'+260970000000',null,
  true,'in_person','SETUP-test','israel')$$,'22023',null,'nonfictional number refused in synthetic setup');
select throws_ok($$select app.identity_admin_setup_issue(repeat('a',64),'+12025550191',null,
  false,'in_person','SETUP-test','israel')$$,'22023',null,'live enrollment cannot use unapproved privacy');

-- Fresh migrated databases have no historical Admin; an upgrade with an Admin is tested separately.
select is((select commissioned_at is null from app.identity_admin_commissioning where singleton),
  true,'fresh-install fixture has not been commissioned');
create temporary table setup_fixture as select app.identity_admin_setup_issue(
  repeat('a',64),'+12025550191',null,true,'in_person','SETUP-local-1','israel') value;
select is((select count(*)::integer from app.identity_admin_setup_invites),1,'one invitation issued');
select is((select mode from app.identity_admin_setup_invites limit 1),'new_account','new-account mode is explicit');
select ok((select expires_at>issued_at and expires_at<=issued_at+interval '24 hours 1 second'
  from app.identity_admin_setup_invites limit 1),'invitation has the approved bounded expiry');
select is((select count(*)::integer from auth.users u join app.identity_admin_setup_invites i on i.auth_user_id=u.id),
  0,'issuing does not create an Auth account');
select is((select count(*)::integer from app.identity_grants where role='admin'),0,
  'issuing does not grant Admin');
select throws_ok($$select app.identity_admin_setup_issue(repeat('b',64),'+12025550192',null,
  true,'in_person','SETUP-local-2','israel')$$,'22023',null,'second active invitation refused');

create function pg_temp.setup_call(action text,extra jsonb default '{}'::jsonb) returns jsonb
language sql as $$
 select app.identity_sys_admin_setup(null,gen_random_uuid(),jsonb_build_object(
   'action',action,'invitation_digest',repeat('a',64),'phone_username','+12025550191',
   'client_key',encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'))||extra)->'data'
$$;
select is(pg_temp.setup_call('inspect')->>'outcome','ready','intended invite can inspect readiness');
select is(pg_temp.setup_call('inspect','{"phone_username":"+12025550192"}')->>'outcome','refused',
  'wrong phone cannot inspect intended invite');
select is(pg_temp.setup_call('inspect',jsonb_build_object('invitation_digest',repeat('b',64)))->>'outcome',
  'refused','unknown digest cannot inspect an invite');
select is(app.identity_admin_setup_check(jsonb_build_object('action','inspect',
  'invitation_digest',repeat('a',64),'phone_username','+12025550191','client_key',repeat('c',64))),
  '{}'::jsonb,'valid inspect payload accepted');
select ok(app.identity_admin_setup_check(jsonb_build_object('action','inspect',
  'invitation_digest',repeat('a',64),'phone_username','+12025550191','client_key',repeat('c',64),
  'role','admin'))<>'{}'::jsonb,'forged privilege field rejected');
create temporary table reserved_setup as select pg_temp.setup_call('begin',jsonb_build_object(
  'request_id','a1111111-1111-4111-8111-111111111111','full_name','SYNTHETIC First Administrator',
  'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true)) value;
select is((select value->>'outcome' from reserved_setup),'provision','begin reserves one provider operation');
select is((select count(*)::integer from app.identity_grants where role='admin'),0,
  'reservation does not grant Admin before provider validation');
select is(pg_temp.setup_call('begin',jsonb_build_object(
  'request_id','a1111111-1111-4111-8111-111111111111','full_name','SYNTHETIC First Administrator',
  'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true))->>'outcome',
  'pending','repeated begin does not redispatch provider authority');
select is(pg_temp.setup_call('begin',jsonb_build_object(
  'request_id','b1111111-1111-4111-8111-111111111111','full_name','SYNTHETIC First Administrator',
  'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true))->>'outcome',
  'refused','another request cannot claim the first pending operation');
select is(pg_temp.setup_call('begin',jsonb_build_object(
  'request_id','a1111111-1111-4111-8111-111111111111','full_name','SYNTHETIC Changed Submission',
  'privacy_notice_version','synthetic-admin-setup-1','privacy_accepted',true))->>'outcome',
  'refused','same-request changed profile intent cannot replay a pending begin');
select is(pg_temp.setup_call('status','{"request_id":"b1111111-1111-4111-8111-111111111111"}')->>'outcome',
  'refused','wrong operation status denied');
select is(pg_temp.setup_call('status','{"request_id":"a1111111-1111-4111-8111-111111111111"}')->>'outcome',
  'pending','missing provider outcome stays pending, not success');
select is((select app.identity_admin_setup_revoke((value->>'invitation_id')::uuid,'israel')->>'outcome'
  from setup_fixture),'revoked','revocation immediately denies enrollment');
select is(pg_temp.setup_call('status','{"request_id":"a1111111-1111-4111-8111-111111111111"}')->>'outcome',
  'refused','revoked invite cannot reconcile into privilege');
select throws_ok($$select app.identity_admin_setup_issue(repeat('b',64),'+12025550192',null,
  true,'in_person','SETUP-local-2','israel')$$,'22023',null,'unsettled provider operation prevents unsafe reissue');

-- Inject the terminal-state fixture, rather than pretending this tests actual successful Auth creation.
update app.identity_admin_commissioning set commissioned_at=clock_timestamp(),source='historical_admin'
  where singleton;
select throws_ok($$select app.identity_admin_setup_issue(repeat('b',64),'+12025550192',null,
  true,'in_person','SETUP-local-2','israel')$$,'22023',null,
  'commissioned marker denies setup even while usable Admin count is zero');
select is((select count(*)::integer from app.contract_unowned_objects()),0,'no unowned application objects');
select is((select count(*)::integer from app.contract_unpinned_functions()),0,'all application functions remain pinned');
select is((select count(*)::integer from app.contract_boundary_violations()),0,'module ownership boundaries remain clean');
select * from finish();
rollback;
