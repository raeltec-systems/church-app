-- Identity-checked last-Admin fallback (story 2.12; I10, AD-4, AD-19):
-- app.identity_admin_fallback_grant restores Admin access through the restricted operator and a
-- second named owner for an existing, linked, identity-checked member without scopes, with a
-- reason that matches the real Admin state; audited as `admin_fallback_granted`, journalled,
-- visible to every Admin in Roles & access, and without touching any Auth row (no password,
-- session or token). HTTP rehearsal with real GoTrue sessions: tools/identity-e2e/runbooks.mjs.
-- Every account, phone and name here is SYNTHETIC (fictional range +1 202 555 0171-0180).
begin;
select plan(47);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000212' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000212' || lpad(n::text, 2, '0'))::uuid $$;

create function pg_temp.claims(p_sub uuid, p_session uuid)
returns jsonb
language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;

create function pg_temp.session(p_user uuid, p_session uuid)
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;

create function pg_temp.m(n int) returns uuid language sql as
$$ select l.member_id from app.identity_account_links l where l.auth_user_id = pg_temp.u(n) $$;

-- An authenticated read as member n's own session.
create function pg_temp.as_member(n int, p_sql text) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute p_sql into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.roles(n int) returns text language sql as $$
  select coalesce(string_agg(x, ',' order by o), '')
    from jsonb_array_elements_text(pg_temp.as_member(n, 'select api.identity_my_access()') -> 'roles')
         with ordinality t(x, o)
$$;

create function pg_temp.fallback(n int, p_check text, p_reason text, p_owner text default 'owner-two',
                                 p_case text default 'RB8-2026-10-07-01', p_operator text default 'israel')
returns jsonb language sql as
$$ select app.identity_admin_fallback_grant(pg_temp.m(n), p_check, p_reason, p_owner, p_case, p_operator) $$;

-- Structure and privileges ---------------------------------------------------------------------
select has_table('app', 'identity_admin_fallbacks', 'the fallback record table exists');
select ok(not exists (
  select 1 from unnest(array['app.identity_admin_fallbacks', 'app.identity_access_audit',
                             'app.identity_retired_access_audit_v0', 'app.ops_operator_actions',
                             'app.ops_retired_operator_actions_v1']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['app.identity_access_audit_event_id_seq',
                             'app.identity_retired_access_audit_v0_event_id_seq',
                             'app.ops_operator_actions_id_seq',
                             'app.ops_retired_operator_actions_v1_id_seq']) q
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, q, p))
  and (select bool_and(relrowsecurity) from pg_class
        where oid in ('app.identity_admin_fallbacks'::regclass, 'app.identity_access_audit'::regclass,
                      'app.identity_retired_access_audit_v0'::regclass, 'app.ops_operator_actions'::regclass,
                      'app.ops_retired_operator_actions_v1'::regclass)),
  'no client role has any privilege on the fallback records, the audit and journal tables (live or retired) or their sequences; RLS is on');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, 'app.identity_admin_fallback_grant(uuid,text,text,text,text,text)', 'EXECUTE'))
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   where p.oid = 'app.identity_admin_fallback_grant(uuid,text,text,text,text,text)'::regprocedure
                     and a.grantee = 0),
  'the fallback command has no client or PUBLIC EXECUTE');
select ok(has_function_privilege('authenticated', 'app.identity_admin_member_grants(text,uuid)', 'EXECUTE')
          = (select has_function_privilege('authenticated', 'api.identity_admin_member_grants(text,uuid)', 'EXECUTE'))
          and not has_function_privilege('anon', 'api.identity_admin_member_grants(text,uuid)', 'EXECUTE'),
  'the replaced Roles & access read keeps its privileges (anon has none)');
select ok(not exists (
  select 1 from information_schema.columns
   where table_schema = 'app' and table_name = 'identity_admin_fallbacks'
     and column_name ~ '(name|phone|email|payload|password|token|content)'),
  'fallback rows hold ids, codes, counts, the owner identifier and the case reference only');
select ok((select prosrc from pg_proc where oid = 'app.identity_admin_fallback_grant(uuid,text,text,text,text,text)'::regprocedure)
          !~* '(auth\.|password|session|token)',
  'the fallback body never names an Auth table, a password, a session or a token');
select ok((select proconfig from pg_proc where oid = 'app.identity_admin_fallback_grant(uuid,text,text,text,text,text)'::regprocedure)
          = array['search_path=""'],
  'the fallback pins an empty search_path');
select ok(not exists (select 1 from app.contract_unowned_objects())
          and not exists (select 1 from app.contract_unpinned_functions())
          and not exists (select 1 from app.contract_boundary_violations()),
  'owner registry guards stay clean');
select ok(not exists (select r.event_id from app.identity_retired_access_audit_v0 r
                      except select a.event_id from app.identity_access_audit a)
          and not exists (select r.id from app.ops_retired_operator_actions_v1 r
                          except select a.id from app.ops_operator_actions a),
  'every retired audit and journal row was copied to the recreated table');
select ok(exists (select 1 from app.identity_deletion_retention_rules
                   where table_name = 'identity_retired_access_audit_v0' and column_name = 'actor_account_id'),
  'a deletion anonymises the retired access audit too');

-- Fixtures ---------------------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.12');
insert into auth.users (id, aud, role, phone, phone_confirmed_at, encrypted_password)
select pg_temp.u(n), 'authenticated', 'authenticated', '12025550' || (170 + n)::text, now(),
       'SYNTHETIC-not-a-real-hash-' || n
  from generate_series(1, 10) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 10) n;
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.12 Member ' || n, 'pgtap 2.12')
  from generate_series(1, 10) n;
create temp table accountless as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               values ('SYNTHETIC 2.12 Accountless', 'approved', true) returning member_id)
  select member_id from ins;
-- Member 1 is the church's only Admin (first-Admin bootstrap).
select isnt(app.identity_bootstrap_admin(pg_temp.m(1), 'israel'), null, 'first Admin bootstrapped');
select is(app.identity_usable_admin_count(), 1, 'one usable Admin');

-- Refusals (nothing written) -----------------------------------------------------------------------
create temp table before_counts as
  select (select count(*) from app.identity_grants where revoked_at is null) as grants,
         (select count(*) from app.identity_access_audit) as audit,
         (select count(*) from app.identity_admin_fallbacks) as fallbacks,
         (select count(*) from app.ops_operator_actions) as journal;
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', 'owner-two', 'RB8-1', 'mallory')$$,
  '42501', 'not an active restricted operator', 'only a restricted operator may use the fallback');
select throws_ok($$select pg_temp.fallback(2, 'phone_call', 'admins_unreachable')$$,
  '22023', 'identity_check must be in_person or established_relationship', 'the identity check must be a known code');
select throws_ok($$select pg_temp.fallback(2, null, 'admins_unreachable')$$,
  '22023', 'identity_check must be in_person or established_relationship', 'the identity check is required');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'because')$$,
  '22023', 'reason_code must be no_usable_admin or admins_unreachable', 'the reason must be a known code');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', '')$$,
  '22023', 'confirming_owner must identify the second named owner', 'a confirming owner is required');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', null)$$,
  '22023', 'confirming_owner must identify the second named owner', 'a null confirming owner is refused');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', ' Israel ')$$,
  '22023', 'confirming_owner must be a different person from the operator', 'the operator cannot confirm their own fallback');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', 'owner-two', '')$$,
  '22023', 'case_reference must name the owners'' restricted case note', 'a case reference is required');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', 'owner-two', 'free text with spaces')$$,
  '22023', 'case_reference must name the owners'' restricted case note', 'the case reference is a reference, not free text');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'no_usable_admin')$$,
  '22023', 'a usable Admin exists: the reason is admins_unreachable', 'no_usable_admin is refused while a usable Admin exists');
select throws_ok(format('select app.identity_admin_fallback_grant(%L, %L, %L, %L, %L, %L)',
                        (select member_id from accountless), 'in_person', 'admins_unreachable', 'owner-two', 'RB8-1', 'israel'),
  '22023', 'the member needs a usable account link (no hold, review, ban or dormancy)',
  'a member without a login cannot be given Admin');
select throws_ok(format('select app.identity_admin_fallback_grant(%L, %L, %L, %L, %L, %L)',
                        gen_random_uuid(), 'in_person', 'admins_unreachable', 'owner-two', 'RB8-1', 'israel'),
  '22023', 'the member must be an approved church member', 'an unknown member is refused');
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
values (pg_temp.m(3), 'access_review', 'SYNTHETIC pgtap dispute', 'pgtap 2.12');
select throws_ok($$select pg_temp.fallback(3, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member needs a usable account link (no hold, review, ban or dormancy)', 'a held member cannot be given Admin');
update app.identity_account_links set binding_review_required = true, link_state = 'review_required'
 where member_id = pg_temp.m(4);
select throws_ok($$select pg_temp.fallback(4, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member needs a usable account link (no hold, review, ban or dormancy)', 'a member in access review cannot be given Admin');
update app.identity_account_links set last_member_activity_at = now() - interval '200 days'
 where member_id = pg_temp.m(5);
select throws_ok($$select pg_temp.fallback(5, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member needs a usable account link (no hold, review, ban or dormancy)', 'a dormant member cannot be given Admin');
insert into app.identity_deletions (member_id, had_account, origin, requested_by_member, is_synthetic)
values (pg_temp.m(7), true, 'member_request', pg_temp.m(7), true);
select throws_ok($$select pg_temp.fallback(7, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member is being deleted', 'a member being deleted cannot be given Admin');
update app.identity_members set membership_state = 'deactivated' where member_id = pg_temp.m(8);
update app.identity_account_links set link_state = 'suspended' where member_id = pg_temp.m(8);
select throws_ok($$select pg_temp.fallback(8, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member must be an approved church member', 'a deactivated member cannot be given Admin');
update auth.users set banned_until = now() + interval '100 years' where id = pg_temp.u(9);
select throws_ok($$select pg_temp.fallback(9, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member needs a usable account link (no hold, review, ban or dormancy)', 'a member whose Auth user is banned cannot be given Admin');
insert into app.fixture_scope_targets (scope_kind, scope_id) values ('fixture_care', '00000000-0000-4000-b000-000000021201');
insert into app.identity_grants (member_id, scope_kind, scope_id, granted_by_operator)
values (pg_temp.m(10), 'fixture_care', '00000000-0000-4000-b000-000000021201', 'israel');
select throws_ok($$select pg_temp.fallback(10, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member holds a scope grant: choose a member without care, finance or cell scopes',
  'a member holding a scope (care here) cannot be given Admin');
select throws_ok($$select pg_temp.fallback(1, 'in_person', 'admins_unreachable')$$,
  '22023', 'the member already holds Admin', 'a member who already holds Admin is refused');
select ok((select grants + 1 = (select count(*) from app.identity_grants where revoked_at is null)
              and audit = (select count(*) from app.identity_access_audit)
              and fallbacks = (select count(*) from app.identity_admin_fallbacks)
              and journal = (select count(*) from app.ops_operator_actions)
             from before_counts),
  'refused fallbacks write no grant, audit, fallback or journal row (only the fixture scope was added)');

-- Admins unreachable: one usable Admin exists on paper, two owners confirmed none can act --------
create temp table auth_before as
  select u.id, u.encrypted_password, u.updated_at, u.last_sign_in_at, u.phone, u.email, u.banned_until,
         (select count(*) from auth.sessions s where s.user_id = u.id) as sessions,
         (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text) as refresh_tokens
    from auth.users u where u.id = pg_temp.u(2);
select is((select r ->> 'reason_code' || ':' || (r ->> 'usable_admins_before')
             from pg_temp.fallback(2, 'established_relationship', 'admins_unreachable', 'Owner-Two') r),
  'admins_unreachable:1', 'the operator and a second owner grant Admin to an identity-checked linked member');
select is(pg_temp.roles(2), 'admin', 'the member''s existing session lists Admin on its next call (no new session needed)');
select ok((select b.encrypted_password = u.encrypted_password and b.updated_at is not distinct from u.updated_at
                  and b.last_sign_in_at is not distinct from u.last_sign_in_at
                  and b.phone is not distinct from u.phone and b.email is not distinct from u.email
                  and b.banned_until is not distinct from u.banned_until
                  and b.sessions = (select count(*) from auth.sessions s where s.user_id = u.id)
                  and b.refresh_tokens = (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text)
             from auth_before b join auth.users u on u.id = b.id),
  'no credential shortcut: the Auth user, its password hash, sessions and refresh tokens are unchanged');
select results_eq($$select action || ':' || actor_kind || ':' || operator || ':' || role
                      from app.identity_access_audit where target_member_id = pg_temp.m(2)$$,
  $$values ('admin_fallback_granted:operator:israel:admin')$$,
  'the grant is in the access audit with its own action, the operator and no member actor');
select results_eq($$select reason_code || ':' || identity_check || ':' || usable_admins_before || ':'
                           || operator || ':' || confirming_owner || ':' || case_reference
                      from app.identity_admin_fallbacks where target_member_id = pg_temp.m(2)$$,
  $$values ('admins_unreachable:established_relationship:1:israel:owner-two:RB8-2026-10-07-01')$$,
  'the fallback record keeps the reason, the identity check, the Admin count, both owners and the case');
select results_eq($$select action from app.ops_operator_actions
                     where operator = 'israel' and action in ('admin_bootstrapped', 'admin_fallback_granted')
                     order by id$$,
  $$values ('admin_bootstrapped'), ('admin_fallback_granted')$$,
  'the bootstrap and the fallback are journalled with distinct actions');
select is(app.identity_usable_admin_count(), 2, 'two usable Admins now');
select is((select jsonb_object_agg(x ->> 'member_id', x -> 'admin_via_fallback')
             from jsonb_array_elements(pg_temp.as_member(1, 'select api.identity_admin_member_grants()') -> 'members') x
            where x ->> 'member_id' in (pg_temp.m(1)::text, pg_temp.m(2)::text)),
  jsonb_build_object(pg_temp.m(1)::text, false, pg_temp.m(2)::text, true),
  'Roles & access shows the other Admin that the new Admin came through the fallback');

-- No usable Admin: every Admin is held -------------------------------------------------------------
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select pg_temp.m(n), 'security', 'SYNTHETIC pgtap hold', 'pgtap 2.12' from generate_series(1, 2) n;
select is(app.identity_usable_admin_count(), 0, 'held Admins are not usable');
select throws_ok($$select pg_temp.fallback(6, 'in_person', 'admins_unreachable')$$,
  '22023', 'no usable Admin exists: the reason is no_usable_admin', 'admins_unreachable is refused when no usable Admin exists');
select is((select r ->> 'reason_code' || ':' || (r ->> 'usable_admins_before')
             from pg_temp.fallback(6, 'in_person', 'no_usable_admin', 'owner-two', 'RB8-2026-10-07-02') r),
  'no_usable_admin:0', 'with no usable Admin the operator restores Admin with no_usable_admin');
select is(pg_temp.roles(6), 'admin', 'the restored Admin''s own session lists Admin at once');
select is((select count(*)::int from app.identity_access_audit where action = 'admin_fallback_granted'), 2,
  'both fallbacks are audited with the distinct action');
select is((select count(*)::int from app.identity_admin_fallbacks), 2, 'both fallbacks are recorded');

select * from finish();
rollback;
