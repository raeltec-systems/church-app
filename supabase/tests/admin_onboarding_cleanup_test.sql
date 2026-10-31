-- Disposable LOCAL pgTAP transaction. Auth rows are SQL fixtures here; the HTTP
-- rehearsal separately proves actual GoTrue deletion and late-call refusal.
begin;
select no_plan();
select app.platform_set_environment('local','pgtap commissioning cleanup');
create temporary table v(k text primary key,j jsonb);
create function pg_temp.issue(p_char text,p_existing uuid default null) returns jsonb language sql as $$
  select app.identity_admin_setup_issue(repeat(p_char,64),'+447700900818',p_existing,true,
    'in_person','SETUP-cleanup-test','israel');
$$;
create function pg_temp.call(p_action text,p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select app.identity_sys_admin_setup(null,gen_random_uuid(),jsonb_build_object('action',p_action,
    'invitation_digest',repeat('a',64),'phone_username','+447700900818','client_key',repeat('b',64),
    'request_id','00000000-0000-4000-8000-000000031899')||p_extra)->'data';
$$;
create function pg_temp.reserve() returns jsonb language sql as $$
  select pg_temp.call('begin','{"full_name":"SYNTHETIC Cleanup Owner","privacy_notice_version":"synthetic-admin-setup-1","privacy_accepted":true}');
$$;
create function pg_temp.insert_provider(p jsonb) returns void language sql as $$
  insert into auth.users(id,phone,encrypted_password,raw_app_meta_data,created_at,updated_at)
  values((p->>'auth_user_id')::uuid,'447700900818','SYNTHETIC-HASH',
    jsonb_build_object('provider','phone','providers',jsonb_build_array('phone'),
      'church_setup_operation',p->>'operation_id','church_setup_nonce',p->>'correlation_nonce'),clock_timestamp(),clock_timestamp());
$$;

savepoint missing_provider;
insert into v values('invite',pg_temp.issue('a'));
select is(pg_temp.issue('a'),(select j from v where k='invite'),'same prepared operator request keeps original invitation and expiry');
insert into v values('reservation',pg_temp.reserve());
select is((select j->>'outcome' from v where k='reservation'),'provision','one provider reservation exists');
select is(app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome',
  'cleaned','unknown provider with no account is cancelled under the insertion fence');
select throws_ok($$select pg_temp.insert_provider((select j from v where k='reservation'))$$,'42501',null,
  'late original provider insertion is refused even after identifiers were redacted');
select is((select count(*)::int from auth.users),0,'no orphan account was created by the late call');
select is((select count(*)::int from app.identity_admin_setup_invites where digest is not null or phone_username is not null or auth_user_id is not null),
  0,'cleanup removes unclaimed private invitation data');
select is(app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome',
  'cleaned','repeat cleanup is a no-op');
select lives_ok($$select pg_temp.issue('c')$$,'reissue is allowed only after the old provider authority is fenced');
select throws_ok($$select pg_temp.insert_provider((select j from v where k='reservation'))$$,'42501',null,
  'an old operation cannot claim the phone during a reissued setup');
rollback to missing_provider;

savepoint present_provider;
insert into v values('invite',pg_temp.issue('a')),('reservation',pg_temp.reserve());
select lives_ok($$select pg_temp.insert_provider((select j from v where k='reservation'))$$,'current provider operation may create its reserved Auth account');
select throws_ok($$update auth.users set raw_app_meta_data='{}'::jsonb$$,'42501',null,'unclaimed provider correlation cannot be stripped');
select throws_ok($$update auth.users set phone='447700900819'$$,'42501',null,'unclaimed provider phone cannot be changed to bypass cleanup checks');
insert into v values('prepared',app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel'));
select is((select j->>'outcome' from v where k='prepared'),'delete_orphan','only a proven correlated orphan receives deletion authority');
select is((select j->>'auth_user_id' from v where k='prepared'),(select j->>'auth_user_id' from v where k='reservation'),'deletion authority names the exact reserved account');
select is(app.identity_admin_setup_cleanup_finish((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome',
  'cleanup_pending','provider deletion is not fabricated from a prepared operation');
select throws_ok($$select pg_temp.issue('c')$$,'22023',null,'reissue stays fenced while deletion is unconfirmed');
insert into app.identity_members(member_id,display_name,membership_state,is_synthetic)
 values('00000000-0000-4000-8000-000000031898','SYNTHETIC Unrelated Member','approved',true);
select throws_ok($$insert into app.identity_account_links(member_id,auth_user_id,approved_phone,approved_by)
 values('00000000-0000-4000-8000-000000031898',(select (j->>'auth_user_id')::uuid from v where k='reservation'),'+447700900818','pgtap')$$,
 '42501',null,'quarantined orphan cannot acquire member history between prepare and Auth deletion');
delete from auth.users where id=(select (j->>'auth_user_id')::uuid from v where k='reservation');
select is(app.identity_admin_setup_cleanup_finish((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome','cleaned','confirmed Auth absence completes cleanup');
select throws_ok($$select pg_temp.insert_provider((select j from v where k='reservation'))$$,'42501',null,'late provider retry cannot recreate an erased orphan');
rollback to present_provider;

savepoint existing_account;
insert into auth.users(id,phone,encrypted_password,raw_app_meta_data,created_at,updated_at)
 values('00000000-0000-4000-8000-000000031897','447700900818','SYNTHETIC-EXISTING-HASH','{}',clock_timestamp(),clock_timestamp());
insert into v values('invite',pg_temp.issue('a','00000000-0000-4000-8000-000000031897'));
select is(app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome','cleaned','unclaimed existing-account invitation can be discarded');
select is((select encrypted_password from auth.users where id='00000000-0000-4000-8000-000000031897'),'SYNTHETIC-EXISTING-HASH',
 'cleanup never deletes or resets the existing account');
rollback to existing_account;

savepoint expiry;
insert into v values('invite',pg_temp.issue('a'));
update app.identity_admin_setup_invites set issued_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 minute';
select is(jsonb_array_length(app.identity_admin_setup_cleanup_candidates('israel')),1,'expired unclaimed invitation appears in the bounded cleanup queue');
select is(app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome','cleaned','expired unclaimed invitation is safely redacted');
select is(jsonb_array_length(app.identity_admin_setup_cleanup_candidates('israel')),0,'already cleaned invitation leaves the queue');
rollback to expiry;

savepoint completed;
insert into v values('invite',pg_temp.issue('a')),('reservation',pg_temp.reserve());
select pg_temp.insert_provider((select j from v where k='reservation'));
select is(pg_temp.call('finish',jsonb_build_object('operation_id',(select j->>'operation_id' from v where k='reservation'),'provider_result','observed'))->>'outcome','completed','normal commissioning still completes behind the insertion/link fences');
update app.identity_admin_setup_invites set issued_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 minute';
select is(app.identity_admin_setup_cleanup_prepare((select (j->>'invitation_id')::uuid from v where k='invite'),'israel')->>'outcome','completed','completed setup only discards expired temporary authority');
select is((select count(*)::int from auth.users),1,'completed member account is preserved');
select is((select count(*)::int from app.identity_grants where role='admin'),1,'completed Admin access is preserved');
select ok((select commissioned_at is not null from app.identity_admin_commissioning),'cleanup never resets permanent commissioning');
select ok((select digest is null and correlation_nonce is null and full_name is null from app.identity_admin_setup_invites),'expired completion no longer holds reusable setup material');
rollback to completed;

select throws_ok($$select app.identity_admin_setup_cleanup_candidates('not-an-operator')$$,'42501',null,'cleanup metadata is restricted to the named operator');
select is((select count(*)::int from pg_proc p cross join unnest(array['anon','authenticated','service_role']) r
 where p.pronamespace='app'::regnamespace and p.proname like 'identity_admin_setup_%' and has_function_privilege(r,p.oid,'EXECUTE')),0,'no new cleanup/trigger function is a client endpoint');
select is((select count(*)::int from app.contract_unowned_objects()),0,'new operator procedures have module owners');
select is((select count(*)::int from app.contract_boundary_violations()),0,'module boundaries remain clean');
select * from finish();
rollback;
