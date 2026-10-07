-- Identity-checked last-Admin fallback (story 2.12; I10, AD-4, AD-19):
-- app.identity_admin_fallback_grant restores Admin access through the restricted operator for an
-- existing, linked, identity-checked member, with a reason that matches the real Admin state,
-- audited and journalled, and without touching any Auth row (no password, session or token).
-- HTTP rehearsal with real GoTrue sessions: tools/identity-e2e/runbooks.mjs. Every account, phone
-- and name here is SYNTHETIC (fictional range +1 202 555 0171-0177).
begin;
select plan(32);

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

create function pg_temp.roles(n int) returns text language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  r := api.identity_my_access();
  reset role;
  return (select coalesce(string_agg(x, ',' order by o), '')
            from jsonb_array_elements_text(r -> 'roles') with ordinality t(x, o));
end;
$$;

create function pg_temp.fallback(n int, p_check text, p_reason text, p_operator text default 'israel')
returns jsonb language sql as
$$ select app.identity_admin_fallback_grant(pg_temp.m(n), p_check, p_reason, p_operator) $$;

-- Structure and privileges ---------------------------------------------------------------------
select has_table('app', 'identity_admin_fallbacks', 'the fallback record table exists');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.identity_admin_fallbacks', p))
  and (select relrowsecurity from pg_class where oid = 'app.identity_admin_fallbacks'::regclass),
  'no client role has any privilege on the fallback records, and RLS is on');
select ok(not exists (
  select 1 from unnest(array['public', 'anon', 'authenticated', 'service_role']) r
   where r <> 'public' and has_function_privilege(r, 'app.identity_admin_fallback_grant(uuid,text,text,text)', 'EXECUTE'))
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   where p.oid = 'app.identity_admin_fallback_grant(uuid,text,text,text)'::regprocedure
                     and a.grantee = 0),
  'the fallback command has no client or PUBLIC EXECUTE');
select ok(not exists (
  select 1 from information_schema.columns
   where table_schema = 'app' and table_name = 'identity_admin_fallbacks'
     and column_name ~ '(name|phone|email|note|content|payload|text|password|token)'),
  'fallback rows are content-free: ids, codes, counts and revisions only');
select ok((select prosrc from pg_proc where oid = 'app.identity_admin_fallback_grant(uuid,text,text,text)'::regprocedure)
          !~* '(auth\.|password|session|token)',
  'the fallback body never names an Auth table, a password, a session or a token');
select ok((select proconfig from pg_proc where oid = 'app.identity_admin_fallback_grant(uuid,text,text,text)'::regprocedure)
          = array['search_path=""'],
  'the fallback pins an empty search_path');
select ok(not exists (select 1 from app.contract_unowned_objects())
          and not exists (select 1 from app.contract_unpinned_functions())
          and not exists (select 1 from app.contract_boundary_violations()),
  'owner registry guards stay clean');

-- Fixtures ---------------------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.12');
insert into auth.users (id, aud, role, phone, phone_confirmed_at, encrypted_password)
select pg_temp.u(n), 'authenticated', 'authenticated', '120255501' || (70 + n)::text, now(),
       'SYNTHETIC-not-a-real-hash-' || n
  from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.12 Member ' || n, 'pgtap 2.12')
  from generate_series(1, 7) n;
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
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'admins_unreachable', 'mallory')$$,
  '42501', null, 'only a restricted operator may use the fallback');
select throws_ok($$select pg_temp.fallback(2, 'phone_call', 'admins_unreachable')$$,
  '22023', null, 'the identity check must be in_person or established_relationship');
select throws_ok($$select pg_temp.fallback(2, null, 'admins_unreachable')$$,
  '22023', null, 'the identity check is required');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'because')$$,
  '22023', null, 'the reason must be a known code');
select throws_ok($$select pg_temp.fallback(2, 'in_person', 'no_usable_admin')$$,
  '22023', null, 'no_usable_admin is refused while a usable Admin exists');
select throws_ok(format('select app.identity_admin_fallback_grant(%L, %L, %L, %L)',
                        (select member_id from accountless), 'in_person', 'admins_unreachable', 'israel'),
  '22023', null, 'a member without a login cannot be given Admin');
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
values (pg_temp.m(3), 'access_review', 'SYNTHETIC pgtap dispute', 'pgtap 2.12');
select throws_ok($$select pg_temp.fallback(3, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'a held member cannot be given Admin');
update app.identity_account_links set binding_review_required = true, link_state = 'review_required'
 where member_id = pg_temp.m(4);
select throws_ok($$select pg_temp.fallback(4, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'a member in access review cannot be given Admin');
update app.identity_account_links set last_member_activity_at = now() - interval '200 days'
 where member_id = pg_temp.m(5);
select throws_ok($$select pg_temp.fallback(5, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'a dormant member cannot be given Admin');
insert into app.identity_deletions (member_id, had_account, origin, requested_by_member, is_synthetic)
values (pg_temp.m(7), true, 'member_request', pg_temp.m(7), true);
select throws_ok($$select pg_temp.fallback(7, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'a member being deleted cannot be given Admin');
select throws_ok($$select pg_temp.fallback(1, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'a member who already holds Admin is refused');
select ok((select grants = (select count(*) from app.identity_grants where revoked_at is null)
              and audit = (select count(*) from app.identity_access_audit)
              and fallbacks = (select count(*) from app.identity_admin_fallbacks)
              and journal = (select count(*) from app.ops_operator_actions)
             from before_counts),
  'refused fallbacks write no grant, audit, fallback or journal row');

-- Admins unreachable: one usable Admin exists on paper, the named owners confirmed none can act --
create temp table auth_before as
  select u.id, u.encrypted_password, u.updated_at, u.phone, u.email, u.banned_until,
         (select count(*) from auth.sessions s where s.user_id = u.id) as sessions,
         (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text) as refresh_tokens
    from auth.users u where u.id = pg_temp.u(2);
select is((select r ->> 'reason_code' || ':' || (r ->> 'usable_admins_before')
             from pg_temp.fallback(2, 'established_relationship', 'admins_unreachable') r),
  'admins_unreachable:1', 'the operator grants Admin to an identity-checked linked member');
select is(pg_temp.roles(2), 'admin', 'the member''s next call (own session) lists Admin');
select ok((select b.encrypted_password = u.encrypted_password and b.updated_at is not distinct from u.updated_at
                  and b.phone is not distinct from u.phone and b.email is not distinct from u.email
                  and b.banned_until is not distinct from u.banned_until
                  and b.sessions = (select count(*) from auth.sessions s where s.user_id = u.id)
                  and b.refresh_tokens = (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text)
             from auth_before b join auth.users u on u.id = b.id),
  'no credential shortcut: the Auth user, its password hash, sessions and refresh tokens are unchanged');
select results_eq($$select action || ':' || actor_kind || ':' || operator || ':' || role
                      from app.identity_access_audit
                     where target_member_id = pg_temp.m(2) and action = 'admin_bootstrapped'$$,
  $$values ('admin_bootstrapped:operator:israel:admin')$$,
  'the grant is in the access audit with the operator and no member actor');
select results_eq($$select reason_code || ':' || identity_check || ':' || usable_admins_before || ':' || operator
                      from app.identity_admin_fallbacks where target_member_id = pg_temp.m(2)$$,
  $$values ('admins_unreachable:established_relationship:1:israel')$$,
  'the fallback record keeps the reason, the identity check and the Admin count');
select is((select count(*)::int from app.ops_operator_actions
            where action = 'admin_bootstrapped' and operator = 'israel'), 2,
  'the bootstrap and the fallback are both in the restricted-operator journal');
select is(app.identity_usable_admin_count(), 2, 'two usable Admins now');

-- No usable Admin: every Admin is held -------------------------------------------------------------
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select pg_temp.m(n), 'security', 'SYNTHETIC pgtap hold', 'pgtap 2.12' from generate_series(1, 2) n;
select is(app.identity_usable_admin_count(), 0, 'held Admins are not usable');
select throws_ok($$select pg_temp.fallback(6, 'in_person', 'admins_unreachable')$$,
  '22023', null, 'admins_unreachable is refused when no usable Admin exists');
select is((select r ->> 'reason_code' || ':' || (r ->> 'usable_admins_before')
             from pg_temp.fallback(6, 'in_person', 'no_usable_admin') r),
  'no_usable_admin:0', 'with no usable Admin the operator restores Admin with no_usable_admin');
select is(pg_temp.roles(6), 'admin', 'the restored Admin''s own session lists Admin at once');

select * from finish();
rollback;
