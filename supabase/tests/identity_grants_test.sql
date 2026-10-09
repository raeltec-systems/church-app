-- Identity grants (story 2.3; AD-2, AD-3, AD-4, AD-19): role catalogue, scope-kind registry,
-- grant commands through the 1.4 envelope, immediate effect on the next protected call of an
-- already signed-in session, content-free audit, the last-Admin refusal, the restricted-operator
-- bootstrap, Identity church settings (Q-values) and the SYNTHETIC care/finance fixture surfaces
-- that Admin-only and combined-role members cannot reach.
-- HTTP evidence with real GoTrue sessions: tools/identity-e2e/grants.mjs. Every account, phone
-- and name here is SYNTHETIC (fictional range +1 202 555 0131-0139).
begin;
select plan(113);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000023' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000023' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.req(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-a000-0000000023' || lpad(n::text, 2, '0'))::uuid $$;

create function pg_temp.claims(p_sub uuid, p_session uuid, p_method text default 'password')
returns jsonb
language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', p_method, 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;

-- A live password session as GoTrue records it (with its server-side AMR claim).
create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password')
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), p_method);
  select p_session;
$$;

create function pg_temp.m(n int) returns uuid language sql as
$$ select l.member_id from app.identity_account_links l where l.auth_user_id = pg_temp.u(n) $$;

create function pg_temp.rev(p_member uuid) returns bigint language sql as
$$ select s.revision from app.identity_grant_sets s where s.member_id = p_member $$;

-- One command envelope as the session in p_claims.
create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  r := api.identity_grant_command(jsonb_build_object(
         'version', 1, 'command', p_command, 'request_id', p_request,
         'expected_revision', p_expected, 'payload', p_payload));
  reset role;
  return r;
end;
$$;

-- A read as the session in p_claims: 'ok' plus the result, or sqlstate|message|detail.
create function pg_temp.read(p_claims jsonb, p_sql text) returns text
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  begin
    execute p_sql into r;
    reset role;
    return 'ok ' || coalesce(r::text, 'null');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
-- Owner-side helper call (owner code runs as the definer; clients have no EXECUTE).
create function pg_temp.has_role(p_claims jsonb, p_role text) returns boolean
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  return app.identity_has_role(p_role);
end;
$$;
create function pg_temp.fixture_cmd(p_claims jsonb) returns jsonb
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', p_claims::text, true);
  return app.fixture_counter_command(jsonb_build_object(
    'version', 1, 'command', 'fixture_counter.create', 'request_id', gen_random_uuid(),
    'expected_revision', null, 'payload', '{"intent_key": "k"}'::jsonb));
end;
$$;
create function pg_temp.roles(n int) returns text language plpgsql as $$
declare
  v text := pg_temp.read(pg_temp.c(n), 'select api.identity_my_access()');
begin
  if v not like 'ok %' then return v; end if;
  return (select coalesce(string_agg(x, ',' order by o), '')
            from jsonb_array_elements_text(substr(v, 4)::jsonb -> 'roles') with ordinality t(x, o));
end;
$$;

-- Structure and privileges ---------------------------------------------------------------------
select has_table('app', 'identity_grant_sets', 'grant sets table exists');
select has_table('app', 'identity_grants', 'grants table exists');
select has_table('app', 'identity_access_audit', 'access audit table exists');
select has_table('app', 'identity_church_settings', 'church settings table exists');
select has_table('app', 'cmd_authorizers', 'command authorizer registry exists');
select ok(not exists (
  select 1 from unnest(array['app.identity_grant_sets', 'app.identity_grants',
                             'app.identity_access_audit', 'app.identity_church_settings',
                             'app.identity_roles', 'app.identity_scope_kinds',
                             'app.cmd_authorizers', 'app.fixture_scope_targets']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['app.identity_access_audit_event_id_seq',
                             'app.ops_operator_actions_id_seq',
                             'app.ops_retired_operator_actions_v0_id_seq']) q
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, q, p))
  and not exists (
  select 1 from unnest(array['app.ops_operator_actions', 'app.ops_retired_operator_actions_v0']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on grant, audit, settings, registry or operator-journal tables or their sequences');
select ok(not exists (
  select 1 from information_schema.columns
   where table_schema = 'app' and table_name = 'identity_access_audit'
     and column_name ~ '(name|phone|email|reason|note|content|payload|text)'),
  'audit rows are content-free: ids, codes and revisions only');
select ok(not exists (
  select 1 from unnest(array['app.identity_evaluate_grant(text,text,uuid)',
                             'app.identity_has_role(text)', 'app.identity_has_scope(text,uuid)',
                             'app.identity_require_grant(text,text,uuid,boolean)',
                             'app.identity_bootstrap_admin(uuid,text)',
                             'app.identity_approve_church_setting(text,jsonb,text,text)',
                             'app.identity_authorize_command(jsonb)',
                             'app.identity_grant_role(uuid,bigint,jsonb)',
                             'app.cmd_register_authorizer(text,regprocedure)',
                             'app.identity_register_scope_kind(text,text,regprocedure,text)']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'helpers, handlers, bootstrap and registration have no client grants');
select ok(not has_function_privilege('anon', 'api.identity_grant_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_my_access()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_member_grants(text,uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.fixture_scoped_read(text,uuid)', 'EXECUTE'),
  'anon cannot call the grant command or the grant reads');
select results_eq($$select role from app.identity_roles order by sort_order$$,
  $$values ('admin'), ('pastor'), ('media'), ('lead_pastor')$$,
  'church-wide roles: admin, pastor, media, lead_pastor (held independently)');
select results_eq($$select namespace || ':' || handler from app.cmd_authorizers where namespace = 'identity'$$,
  $$values ('identity:app.identity_authorize_command(jsonb)')$$,
  'identity commands are authorised by the Identity authorizer');
select results_eq($$select scope_kind || ':' || module from app.identity_scope_kinds where module <> 'cells' order by 1$$,
  $$values ('fixture_care:fixture'), ('fixture_finance:fixture')$$,
  'only the SYNTHETIC fixture scope kinds are registered by this story (Cells adds its own in 2.6)');
select ok(not exists (select 1 from app.contract_boundary_violations())
          and not exists (select 1 from app.contract_unowned_objects())
          and not exists (select 1 from app.contract_unpinned_functions()),
  'owner registry guards stay clean (platform depends on no owner)');

-- Settings (Q-values) ----------------------------------------------------------------------------
select ok(app.identity_church_setting('lead_pastor_designation') is null
          and not app.identity_church_setting_enabled('lead_pastor_designation')
          and app.identity_church_setting('operational_contact') is null,
  'unmarked database (production behaviour): church settings are unset and fail closed');
select app.platform_set_environment('local', 'pgtap 2.3');
select ok(app.identity_church_setting_enabled('lead_pastor_designation')
          and app.identity_church_setting('operational_contact') is null,
  'local: the labelled lead-pastor fixture is honoured; the operational contact stays unset');
select throws_ok($$select app.identity_approve_church_setting('operational_contact', '{"route": "x"}', 'mallory', 'owner note')$$,
  '42501', null, 'only a restricted operator records a church setting');
select throws_ok($$select app.identity_approve_church_setting('operational_contact', '{"route": "x"}', 'israel', 'TEST FIXTURE note')$$,
  '22023', null, 'a fixture-labelled note is not an approval');

-- Fixtures ---------------------------------------------------------------------------------------
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '120255501' || (30 + n)::text, now()
  from generate_series(1, 8) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 8) n;
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.3 Member ' || n, 'pgtap 2.3')
  from generate_series(1, 8) n;
-- An OTP-only session for member 1 (untrusted).
select pg_temp.session(pg_temp.u(1), pg_temp.s(21), 'otp');
create temp table accountless as
  with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
               values ('SYNTHETIC 2.3 Accountless', 'approved', true) returning member_id)
  select member_id from ins;
insert into app.fixture_scope_targets (scope_kind, scope_id) values
  ('fixture_care', '00000000-0000-4000-b000-000000002301'),
  ('fixture_care', '00000000-0000-4000-b000-000000002302'),
  ('fixture_finance', '00000000-0000-4000-b000-000000002301');

select ok(not exists (select 1 from app.identity_members m
                       where not exists (select 1 from app.identity_grant_sets s
                                          where s.member_id = m.member_id))
          and pg_temp.rev(pg_temp.m(2)) = 1,
  'every member (including new ones) has a grant set starting at revision 1');

-- Bootstrap (restricted operator) ----------------------------------------------------------------
select is(pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants()'),
  'PT403|forbidden|not_granted', 'before any Admin, nobody reaches the Admin grant list');
select throws_ok(format('select app.identity_bootstrap_admin(%L, %L)', pg_temp.m(1), 'mallory'),
  '42501', null, 'bootstrap needs a restricted operator');
select throws_ok(format('select app.identity_bootstrap_admin(%L, %L)',
                        (select member_id from accountless), 'israel'),
  '22023', null, 'bootstrap needs an approved member with an active account link');
select isnt(app.identity_bootstrap_admin(pg_temp.m(1), 'israel'), null,
  'the restricted operator bootstraps the first Admin');
select results_eq($$select action || ':' || actor_kind || ':' || operator || ':' || role || ':' || revision_after
                      from app.identity_access_audit where action = 'admin_bootstrapped'$$,
  $$values ('admin_bootstrapped:operator:israel:admin:2')$$,
  'the bootstrap is audited with the operator, no member actor');
select is((select string_agg(action || ':' || operator, ',' order by id) from app.ops_operator_actions
            where action in ('admin_bootstrapped', 'lead_pastor_designated', 'church_setting_approved')),
  'admin_bootstrapped:israel', 'the bootstrap is journalled in the restricted-operator journal');
select throws_ok(format('select app.identity_bootstrap_admin(%L, %L)', pg_temp.m(2), 'israel'),
  '22023', null, 'no second bootstrap while a usable Admin exists');
select is(pg_temp.roles(1), 'admin', 'the Admin''s next call lists admin');

-- Helpers compose the live-access predicate --------------------------------------------------------
select ok(pg_temp.has_role(pg_temp.c(1), 'admin'),
  'identity_has_role: admin for the Admin (helpers usable from owner code)');
select ok(not pg_temp.has_role(pg_temp.c(2), 'admin'), 'identity_has_role: not for a plain member');
select ok(not pg_temp.has_role(pg_temp.claims(pg_temp.u(1), pg_temp.s(21), 'otp'), 'admin'),
  'a role never passes without a trusted session (OTP AMR)');
select is(pg_temp.read('{}', 'select api.identity_my_access()'), 'PT401|unauthenticated|unauthenticated',
  'no verified subject: unauthenticated');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(21), 'otp'), 'select api.identity_my_access()'),
  'PT401|unauthenticated|untrusted_session', 'an untrusted session reads no access');

-- Grant, immediate effect, audit -----------------------------------------------------------------
select is(pg_temp.roles(2), '', 'member 2 starts with no role');
select is(
  (select r - 'request_id' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
     jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor'), pg_temp.req(1)) r),
  jsonb_build_object('revision', 2, 'data', jsonb_build_object(
    'member_id', pg_temp.m(2), 'revision', 2, 'roles', '["pastor"]'::jsonb, 'scopes', '[]'::jsonb)),
  'Admin grants Pastor: success envelope with the new grant-set revision');
select is(pg_temp.roles(2), 'pastor',
  'the already signed-in session sees Pastor on its next call (same session, no re-sign-in)');
select results_eq(
  format($$select action || ':' || actor_kind || ':' || (actor_member_id = %L) || ':' || (actor_account_id = %L)
              || ':' || request_id || ':' || (target_member_id = %L) || ':' || role || ':' || revision_after
             from app.identity_access_audit where action = 'role_granted'$$,
         pg_temp.m(1), pg_temp.u(1), pg_temp.m(2)),
  format($$values ('role_granted:member:true:true:%s:true:pastor:2')$$, pg_temp.req(1)),
  'the grant is audited with actor member, acting account, request_id, target, role and revision');
select is(
  (select r ->> 'code' || ':' || (r ->> 'current_revision')
     from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
       jsonb_build_object('member_id', pg_temp.m(2), 'role', 'media')) r),
  'conflict:2', 'a stale tab (old expected_revision) gets conflict with the current revision');
select is(
  (select r - 'request_id' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
     jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor'), pg_temp.req(1)) r),
  jsonb_build_object('revision', 2, 'data', jsonb_build_object(
    'member_id', pg_temp.m(2), 'revision', 2, 'roles', '["pastor"]'::jsonb, 'scopes', '[]'::jsonb)),
  'an identical replay returns the stored result');
select is(
  (select r ->> 'code' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
     jsonb_build_object('member_id', pg_temp.m(2), 'role', 'media'), pg_temp.req(1)) r),
  'conflict', 'the same request_id with a changed payload conflicts');
select is((select count(*)::int from app.identity_access_audit where action = 'role_granted'), 1,
  'replays and conflicts write no audit');
select is(
  (select r ->> 'code' || ':' || coalesce(r ->> 'current_revision', '-')
     from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 2,
       jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor')) r),
  'conflict:2', 'granting a role already held conflicts');

-- Refusals ---------------------------------------------------------------------------------------
select is((select r ->> 'code' from pg_temp.cmd(pg_temp.c(2), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'admin')) r),
  'forbidden', 'a Pastor (not Admin) cannot grant');
select is((select r ->> 'code' from pg_temp.cmd(pg_temp.claims(pg_temp.u(1), pg_temp.s(21), 'otp'),
            'identity.grant_role', 1, jsonb_build_object('member_id', pg_temp.m(3), 'role', 'media')) r),
  'unauthenticated', 'an Admin on an untrusted (OTP) session is unauthenticated');
select is((select r ->> 'code' from pg_temp.cmd('{}', 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'media')) r),
  'unauthenticated', 'no subject: unauthenticated');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'superuser')) r),
  '{"role": "invalid"}'::jsonb, 'an unknown role is invalid');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'media', 'scope', 'x')) r),
  '{"payload": "unknown_field"}'::jsonb, 'unknown payload fields are refused');
select is((select r ->> 'code' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', gen_random_uuid(), 'role', 'media')) r),
  'not_found', 'an unknown member is not_found');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', (select member_id from accountless), 'role', 'media')) r),
  '{"member_id": "invalid"}'::jsonb, 'roles need an approved member with a live account link');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', null,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'media')) r),
  '{"expected_revision": "required"}'::jsonb, 'grant commands require expected_revision');

-- Combined roles: Admin + Pastor + Media on member 3, Admin only on member 4 ------------------------
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'admin')) r), '2', 'grant Admin to 3');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(3), 'identity.grant_role', 2,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'pastor')) r),
  '{"member_id": "unsupported"}'::jsonb,
  'the new Admin acts at once (same session), but may not grant a role to itself');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(3), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(8), 'role', 'media')) r), '2',
  'the new Admin acts at once (same session) for another member');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(3), 'identity.revoke_role', 2,
            jsonb_build_object('member_id', pg_temp.m(8), 'role', 'media')) r), '3',
  'and removes it again');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 2,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'pastor')) r), '3',
  'another Admin grants Pastor to 3');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 3,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'media')) r), '4', 'grant Media to 3');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(4), 'role', 'admin')) r), '2', 'grant Admin to 4');
select is(pg_temp.roles(3), 'admin,pastor,media', 'member 3 holds Admin, Pastor and Media independently');

-- Lead pastor (Q4 fixture) -------------------------------------------------------------------------
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 2,
            jsonb_build_object('member_id', pg_temp.m(2), 'role', 'lead_pastor')) r),
  '{"role": "unsupported"}'::jsonb, 'no Admin command can grant lead_pastor');
select throws_ok(format('select app.identity_designate_lead_pastor(%L, %L)', pg_temp.m(2), 'mallory'),
  '42501', null, 'the designation needs a restricted operator');
select isnt(app.identity_designate_lead_pastor(pg_temp.m(2), 'israel'), null,
  'local: the restricted operator designates the lead pastor under the labelled fixture');
select ok(pg_temp.rev(pg_temp.m(2)) = 3
          and exists (select 1 from app.identity_access_audit
                       where action = 'lead_pastor_designated' and operator = 'israel'
                         and target_member_id = pg_temp.m(2))
          and exists (select 1 from app.ops_operator_actions
                       where action = 'lead_pastor_designated' and operator = 'israel'),
  'the designation is audited and journalled');
delete from app.platform_environment;
select ok(not app.identity_member_has_role(pg_temp.m(2), 'lead_pastor')
          and app.identity_member_has_role(pg_temp.m(2), 'pastor'),
  'production behaviour: the lead_pastor grant is not in force while the setting is unset');
select app.platform_set_environment('local', 'pgtap 2.3');
create temp table saved_setting as
  select * from app.identity_church_settings where setting = 'lead_pastor_designation';
delete from app.identity_church_settings where setting = 'lead_pastor_designation';
select throws_ok(format('select app.identity_designate_lead_pastor(%L, %L)', pg_temp.m(5), 'israel'),
  '22023', null, 'with the setting unset, no lead pastor can be designated');
insert into app.identity_church_settings select * from saved_setting;

-- Scopes and the fixture care/finance surfaces -----------------------------------------------------
select is((select r -> 'data' -> 'scopes' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_scope', 1,
            jsonb_build_object('member_id', pg_temp.m(5), 'scope_kind', 'fixture_care',
                               'scope_id', '00000000-0000-4000-b000-000000002301')) r),
  '[{"scope_id": "00000000-0000-4000-b000-000000002301", "scope_kind": "fixture_care"}]'::jsonb,
  'Admin grants a SYNTHETIC care scope');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_scope', 2,
            jsonb_build_object('member_id', pg_temp.m(5), 'scope_kind', 'fixture_care',
                               'scope_id', '00000000-0000-4000-b000-0000000023ff')) r),
  '{"scope_id": "unknown"}'::jsonb, 'the owner''s target hook refuses an unknown target');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_scope', 2,
            jsonb_build_object('member_id', pg_temp.m(5), 'scope_kind', 'cell',
                               'scope_id', '00000000-0000-4000-b000-000000002301')) r),
  '{"scope_kind": "unregistered"}'::jsonb, 'unregistered scope kinds are refused');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_scope', 1,
            jsonb_build_object('member_id', (select member_id from accountless), 'scope_kind', 'fixture_care',
                               'scope_id', '00000000-0000-4000-b000-000000002302')) r),
  '2', 'an approved member without an account can hold a scope');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_scope', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'scope_kind', 'fixture_care',
                               'scope_id', '00000000-0000-4000-b000-000000002301')) r),
  '{"member_id": "unsupported"}'::jsonb, 'an Admin cannot grant itself a care scope');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'role', 'media')) r),
  '{"member_id": "unsupported"}'::jsonb, 'nor a role');
select ok(not exists (select 1 from app.identity_access_audit
                       where action in ('role_granted', 'scope_granted')
                         and target_member_id = pg_temp.m(1))
          and pg_temp.read(pg_temp.c(1), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002301')$$)
              = 'PT403|forbidden|not_granted',
  'no self-grant was recorded and the Admin still reaches no care surface');
select is(pg_temp.read(pg_temp.c(5), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002301')$$),
  'ok {"content": "SYNTHETIC fixture surface", "scope_id": "00000000-0000-4000-b000-000000002301", "scope_kind": "fixture_care"}',
  'the scoped member reads exactly its care scope');
select is(pg_temp.read(pg_temp.c(5), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002302')$$),
  'PT403|forbidden|not_granted', 'another care scope stays forbidden');
select is(pg_temp.read(pg_temp.c(5), $$select api.fixture_scoped_read('fixture_finance', '00000000-0000-4000-b000-000000002301')$$),
  'PT403|forbidden|not_granted', 'a care scope gives no finance access');
select is(pg_temp.read(pg_temp.c(3), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002301')$$)
          || ' / ' ||
          pg_temp.read(pg_temp.c(3), $$select api.fixture_scoped_read('fixture_finance', '00000000-0000-4000-b000-000000002301')$$),
  'PT403|forbidden|not_granted / PT403|forbidden|not_granted',
  'combined Admin + Pastor + Media reaches neither care nor finance');
select is(pg_temp.read(pg_temp.c(4), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002301')$$)
          || ' / ' ||
          pg_temp.read(pg_temp.c(4), $$select api.fixture_scoped_read('fixture_finance', '00000000-0000-4000-b000-000000002301')$$),
  'PT403|forbidden|not_granted / PT403|forbidden|not_granted',
  'Admin only reaches neither care nor finance');
select is(pg_temp.read(pg_temp.c(1), $$select api.fixture_scoped_read('cell', '00000000-0000-4000-b000-000000002301')$$),
  '22023|unknown fixture scope|', 'the fixture surface serves only the fixture kinds');

-- Revocation takes effect on the next call ---------------------------------------------------------
create temp table hook_log (event jsonb);
grant insert on hook_log to public;
create function app.fixture_test_on_scope_revoked(p_event jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  insert into pg_temp.hook_log values (p_event);
end;
$$;
select app.contract_register_lifecycle_hook('fixture', 'scope_revoked',
  'app.fixture_test_on_scope_revoked(jsonb)');
select is((select r -> 'data' -> 'scopes' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_scope', 2,
            jsonb_build_object('member_id', pg_temp.m(5), 'scope_kind', 'fixture_care',
                               'scope_id', '00000000-0000-4000-b000-000000002301')) r),
  '[]'::jsonb, 'Admin revokes the care scope');
select is(pg_temp.read(pg_temp.c(5), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000002301')$$),
  'PT403|forbidden|not_granted', 'the same session is denied on its next call');
select is((select r -> 'data' -> 'roles' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 3,
            jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor')) r),
  '["lead_pastor"]'::jsonb, 'Admin revokes Pastor (lead_pastor stays independent)');
select is(pg_temp.roles(2), 'lead_pastor', 'member 2''s next call no longer lists Pastor');
select is((select count(*)::int from hook_log where event ->> 'event' = 'scope_revoked'
             and event ->> 'member_id' in (pg_temp.m(2)::text, pg_temp.m(5)::text)), 2,
  'each revocation dispatched scope_revoked to the registered owner hooks');
select results_eq(
  format($$select action || ':' || coalesce(role, scope_kind) || ':' || revision_after
             from app.identity_access_audit
            where action in ('role_revoked', 'scope_revoked') and target_member_id in (%L, %L)
            order by event_id$$, pg_temp.m(5), pg_temp.m(2)),
  $$values ('scope_revoked:fixture_care:3'), ('role_revoked:pastor:4')$$,
  'revocations are audited');
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 4,
            jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor')) r)::text
          || (select r ->> 'code' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 4,
            jsonb_build_object('member_id', pg_temp.m(2), 'role', 'pastor')) r),
  '{}conflict', 'revoking a role that is not held conflicts');

-- Admin grant list (basic membership administration only) ------------------------------------------
select is((select jsonb_array_length(substr(v, 4)::jsonb -> 'members')
             from pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants()') v),
  (select count(*)::int from app.identity_members where membership_state = 'approved'),
  'the Admin lists every approved member');
select is((select string_agg(distinct k, ',' order by k)
             from pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants()') v,
                  jsonb_array_elements(substr(v, 4)::jsonb -> 'members') e,
                  jsonb_object_keys(e) k),
  'account,admin_via_fallback,display_name,grants,is_synthetic,member_id',
  'member rows carry only basic administration fields (no care, finance or contact data)');
select is((select e ->> 'account'
             from pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants()') v,
                  jsonb_array_elements(substr(v, 4)::jsonb -> 'members') e
            where e ->> 'display_name' = 'SYNTHETIC 2.3 Accountless'),
  'no_login', 'an accountless member shows as No login');
select is((select substr(v, 4)::jsonb -> 'roles'
             from pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants()') v),
  '[{"role": "admin", "available": true}, {"role": "pastor", "available": true}, {"role": "media", "available": true}, {"role": "lead_pastor", "available": false}]'::jsonb,
  'the role catalogue says which roles an Admin can grant here (never lead_pastor)');
select is(pg_temp.read(pg_temp.c(5), 'select api.identity_admin_member_grants()'),
  'PT403|forbidden|not_granted', 'a non-Admin cannot list grants');

-- Last Admin --------------------------------------------------------------------------------------
-- Admins: 1, 3, 4. Hold Admin 4 (not usable), then revoke 3: Admin 1 is the last usable Admin.
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
values (pg_temp.m(4), 'security', 'SYNTHETIC pgtap hold', 'pgtap 2.3');
select is((select r ->> 'code' from pg_temp.cmd(pg_temp.c(4), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(6), 'role', 'media')) r),
  'forbidden', 'a held Admin cannot act');
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 4,
            jsonb_build_object('member_id', pg_temp.m(3), 'role', 'admin')) r), '5',
  'Admin 1 removes Admin from member 3');
select is((select r ->> 'code' from pg_temp.cmd(pg_temp.c(3), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(6), 'role', 'media')) r),
  'forbidden', 'the removed Admin''s still-open session is refused on its next command');
select is(pg_temp.read(pg_temp.c(3), 'select api.identity_admin_member_grants()'),
  'PT403|forbidden|not_granted', 'and on its next Admin read (stale tab)');
select is((select r::text from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'role', 'admin'), pg_temp.req(9)) r),
  format('{"code": "forbidden", "message": "You are not allowed to do this.", "request_id": "%s", "field_errors": {"role": "unsupported"}}', pg_temp.req(9)),
  'the last usable Admin cannot be removed (a held Admin does not count)');
select ok(pg_temp.rev(pg_temp.m(1)) = 2 and app.identity_member_has_role(pg_temp.m(1), 'admin')
          and not exists (select 1 from app.cmd_receipts where request_id = pg_temp.req(9)),
  'the refused removal changed nothing and kept no receipt');
select is(app.identity_usable_admin_count(), 1, 'one usable Admin remains');
-- A dormant Admin and a banned Admin do not count either.
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 3,
            jsonb_build_object('member_id', pg_temp.m(8), 'role', 'admin')) r), '4', 'grant Admin to 8');
update app.identity_account_links set last_member_activity_at = now() - interval '200 days'
 where member_id = pg_temp.m(8);
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'role', 'admin')) r),
  '{"role": "unsupported"}'::jsonb, 'a dormant Admin does not count: the last usable Admin stays');
update app.identity_account_links set last_member_activity_at = now() where member_id = pg_temp.m(8);
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(8);
select is((select r -> 'field_errors' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'role', 'admin')) r),
  '{"role": "unsupported"}'::jsonb, 'a banned Admin does not count: the last usable Admin stays');
select is(app.identity_usable_admin_count(), 1, 'still one usable Admin (8 is banned, 4 held)');
select throws_ok(format('select app.identity_bootstrap_admin(%L, %L)', pg_temp.m(6), 'israel'),
  '22023', null, 'bootstrap stays refused while one usable Admin exists');
-- With a second usable Admin, self-removal is allowed and takes effect at once.
select is((select r ->> 'revision' from pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', pg_temp.m(6), 'role', 'admin')) r), '2', 'grant Admin to 6');
select is((select r -> 'data' -> 'roles' from pg_temp.cmd(pg_temp.c(1), 'identity.revoke_role', 2,
            jsonb_build_object('member_id', pg_temp.m(1), 'role', 'admin')) r),
  '[]'::jsonb, 'an Admin may remove its own Admin while another usable Admin exists');
select is(pg_temp.roles(1), '', 'its next call lists no role');

-- Recovery bootstrap when no usable Admin exists ---------------------------------------------------
-- Admins left: 4 (held), 6 (made dormant now), 8 (banned).
update app.identity_account_links set last_member_activity_at = now() - interval '200 days'
 where member_id = pg_temp.m(6);
select is(app.identity_usable_admin_count(), 0, 'held, dormant and banned Admins are not usable');
select throws_ok(format('select app.identity_bootstrap_admin(%L, %L)', pg_temp.m(8), 'israel'),
  '22023', null, 'a banned member cannot be bootstrapped');
select isnt(app.identity_bootstrap_admin(pg_temp.m(7), 'israel'), null,
  'with every Admin held, dormant or banned, the restricted operator bootstraps a recovery Admin');
select is((select count(*)::int from app.ops_operator_actions
            where action = 'admin_bootstrapped' and operator = 'israel'), 2,
  'both bootstraps are journalled');

-- Church-setting approval (restricted operator) is journalled ----------------------------------------
select is(app.identity_approve_church_setting('operational_contact', '{"route": "SYNTHETIC church office"}',
                                              'israel', 'pgtap: synthetic approval'), 1,
  'the operator records an approved church setting');
select ok(app.identity_church_setting('operational_contact') ->> 'route' = 'SYNTHETIC church office'
          and exists (select 1 from app.ops_operator_actions
                       where action = 'church_setting_approved' and operator = 'israel' and target_id is null)
          and exists (select 1 from app.identity_access_audit
                       where action = 'church_setting_approved' and setting = 'operational_contact'),
  'the approval is in force, audited and journalled');

-- Registry guards ----------------------------------------------------------------------------------
select throws_ok($$select app.cmd_register_authorizer('cells', 'app.identity_authorize_command(jsonb)')$$,
  'PCTR1', null, 'an owner registers only its own authorizer function');
select throws_ok($$select app.identity_register_scope_kind('fixture', 'Bad Kind', 'app.fixture_scope_target_exists(jsonb)', 'x')$$,
  'PCTR1', null, 'scope kinds are lower_snake_case tokens');
select throws_ok($$select app.identity_register_scope_kind('fixture', 'pastor', 'app.fixture_scope_target_exists(jsonb)', 'x')$$,
  'PCTR1', null, 'a scope kind cannot shadow a role');
select throws_ok($$select app.identity_register_scope_kind('cells', 'cell', 'app.fixture_scope_target_exists(jsonb)', 'x')$$,
  'PCTR1', null, 'a scope kind''s target hook must belong to its owner');
-- The 1.4 fixture path still decides commands outside registered namespaces.
select is(pg_temp.fixture_cmd(pg_temp.c(1)) ->> 'code',
  'forbidden', 'commands outside a registered namespace keep the fixture grants (none here)');

select * from finish();
rollback;
