-- AUTHORED ONLY, not executed. Initial privilege/projection contract checks.
-- The full authenticated mutation, lifecycle and two-session suite is still required.
begin;
select no_plan();
select has_table('app','identity_profile_audit','ordinary corrections have a separate metadata audit');
select ok((select relrowsecurity from pg_class where oid='app.identity_profile_audit'::regclass),
  'profile audit is protected with RLS');
select ok(not exists(select 1 from unnest(array['anon','authenticated','service_role']) r
  cross join unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
  where has_table_privilege(r,'app.identity_profile_audit',p)),
  'no broad client or service-role audit-table access');
select ok(not exists(select 1 from unnest(array['anon','authenticated','service_role']) r
  where has_function_privilege(r,'app.identity_update_member_profile(uuid,bigint,jsonb)','EXECUTE')),
  'profile mutation is only reached through the command kernel');
select ok(has_function_privilege('authenticated',
  'api.identity_admin_users(text,text,text,text,text,uuid)','EXECUTE'),
  'authenticated users can reach the role-checked directory wrapper');
select ok(not has_function_privilege('anon',
  'api.identity_admin_users(text,text,text,text,text,uuid)','EXECUTE'),
  'guests cannot execute the directory');
select ok(not has_function_privilege('service_role',
  'api.identity_admin_users(text,text,text,text,text,uuid)','EXECUTE'),
  'service role does not gain the ordinary management API');
select ok(has_function_privilege('authenticated',
  'api.identity_user_management_command(jsonb)','EXECUTE'),
  'profile changes enter the normal checked command wrapper');
select ok(not exists(select 1 from information_schema.columns
  where table_schema='app' and table_name='identity_profile_audit'
    and column_name ~ '(password|token|phone|email|old_value|new_value|payload)'),
  'profile audit stores no credential or historical contact fields');
select ok(position('membership_state = ''approved''' in (select prosrc from pg_proc
  where oid='app.identity_admin_member_search(text,text,uuid)'::regprocedure))>0,
  'legacy approved-member picker is not silently widened');
select ok(position('identity_management_erase_data' in (select prosrc from pg_proc
  where oid='app.identity_deletion_erase_identity(app.identity_deletions)'::regprocedure))>0,
  'existing Identity erasure invokes new-store cleanup');
select ok(position('identity_profile_audit' in (select prosrc from pg_proc
  where oid='app.identity_deletion_remaining(app.identity_deletions,boolean)'::regprocedure))>0,
  'deletion verification checks the new audit store');
select is((select count(*)::integer from app.contract_unowned_objects()),0,'module ownership remains complete');
select is((select count(*)::integer from app.contract_unpinned_functions()),0,'functions retain explicit search paths');
select is((select count(*)::integer from app.contract_boundary_violations()),0,'module boundaries remain clean');
select * from finish();
rollback;
