-- Identity live access (story 2.1; AD-3, AD-20): the one server predicate behind the tracer read
-- api.identity_my_member_summary(). Covers the session half (password AMR + live auth.sessions
-- row), the approved link and binding, holds, dormancy before activity refresh, the release
-- gate and the restricted synthetic seeding. HTTP evidence: identity_api_smoke.sh and
-- tools/identity-e2e. Every account, phone and name here is SYNTHETIC (fictional ranges only).
begin;
select plan(71);

-- Calls the read the way PostgREST does: role switch plus verified JWT claims.
-- Returns 'ok' + the summary, or '<sqlstate>|<message>|<detail>'.
create function pg_temp.read(p_role text, p_claims jsonb) returns text
language plpgsql
as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  execute format('set local role %I', p_role);
  begin
    r := api.identity_my_member_summary();
    reset role;
    return 'ok ' || r::text;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;

create function pg_temp.claims(p_sub uuid, p_session uuid, p_methods text[] default array['password'])
returns jsonb
language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', (select coalesce(jsonb_agg(jsonb_build_object('method', m, 'timestamp', 1790000000)), '[]')
              from unnest(p_methods) m))
$$;

create function pg_temp.activity(p_user uuid) returns timestamptz
language sql as $$
  select l.last_member_activity_at from app.identity_account_links l
   where l.auth_user_id = p_user and l.link_state <> 'ended'
$$;

-- Fixed synthetic ids.
create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000021' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000021' || lpad(n::text, 2, '0'))::uuid $$;

-- Structure and privileges ---------------------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['identity_members', 'identity_account_links', 'identity_binding_history',
                    'identity_holds', 'identity_settings']) t;
select ok(not exists (
  select 1 from unnest(array['identity_members', 'identity_account_links', 'identity_binding_history',
                             'identity_holds', 'identity_settings']) t
   cross join unnest(array['anon', 'authenticated']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.' || t, p)),
  'no client role has any table privilege on Identity tables');
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relname like 'identity\_%' and c.relkind = 'r'),
  'RLS is enabled on every Identity table');
select ok(has_function_privilege('authenticated', 'api.identity_my_member_summary()', 'EXECUTE'),
  'authenticated may call the api read');
select ok(not has_function_privilege('anon', 'api.identity_my_member_summary()', 'EXECUTE'),
  'anon may not call the api read');
select ok(not exists (
  select 1 from unnest(array['app.identity_access_evaluate()', 'app.identity_current_member_id()',
                             'app.identity_require_access()', 'app.identity_record_activity(uuid)',
                             'app.identity_setting(text)',
                             'app.identity_seed_synthetic_link(uuid,text,text)']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'internal Identity functions and the seeding procedure have no client grants');
select is_empty($$select * from app.contract_unowned_objects()$$, 'every app object has an owner');
select is_empty($$select * from app.contract_unpinned_functions()$$, 'every function pins search_path');
select is_empty($$select * from app.contract_boundary_violations()$$, 'Identity depends only on platform');

-- Fixtures: SYNTHETIC Auth users and sessions --------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.1');
insert into auth.users (id, aud, role, phone, phone_confirmed_at) values
  (pg_temp.u(1), 'authenticated', 'authenticated', '12025550101', now()),
  (pg_temp.u(2), 'authenticated', 'authenticated', '12025550102', now()),
  (pg_temp.u(3), 'authenticated', 'authenticated', '447700900123', now()),
  (pg_temp.u(4), 'authenticated', 'authenticated', '12025550200', now());
insert into auth.sessions (id, user_id, aal) values
  (pg_temp.s(1), pg_temp.u(1), 'aal1'),
  (pg_temp.s(2), pg_temp.u(2), 'aal1'),
  (pg_temp.s(3), pg_temp.u(3), 'aal1'),
  (pg_temp.s(4), pg_temp.u(4), 'aal1');

-- Seeding guards
select throws_ok($$select app.identity_seed_synthetic_link(pg_temp.u(1), 'Real Name', 'pgtap')$$,
  '22023', 'display name must start with "SYNTHETIC "', 'seeding needs a SYNTHETIC label');
select throws_ok($$select app.identity_seed_synthetic_link(pg_temp.u(4), 'SYNTHETIC Z', 'pgtap')$$,
  '22023', 'phone username is not in a reserved fictional range',
  'seeding refuses a number outside the reserved fictional ranges');
select lives_ok($$select app.identity_seed_synthetic_link(pg_temp.u(1), 'SYNTHETIC Member One', 'pgtap')$$,
  'seeds a synthetic approved member for a NANP fictional number');
select lives_ok($$select app.identity_seed_synthetic_link(pg_temp.u(3), 'SYNTHETIC Member Three', 'pgtap')$$,
  'seeds a synthetic approved member for an Ofcom drama-range number');
select throws_ok($$select app.identity_seed_synthetic_link(pg_temp.u(1), 'SYNTHETIC Again', 'pgtap')$$,
  '23505', null, 'one live link per account');
select is((select approved_phone from app.identity_account_links where auth_user_id = pg_temp.u(1)),
  '+12025550101', 'binding stores the normalized E.164 phone');
select is((select count(*)::int from app.identity_binding_history h
            join app.identity_account_links l using (link_id) where l.auth_user_id = pg_temp.u(1)),
  1, 'binding revision 1 is recorded with its approver');

-- Granted read ---------------------------------------------------------------------------------
select is(pg_temp.activity(pg_temp.u(1)), null, 'no activity before the first granted read');
select matches(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  '^ok .*"display_name": "SYNTHETIC Member One"', 'approved member reads their own summary');
select matches(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  '"phone_username": "\+12025550101"', 'summary shows the approved phone username');
select ok(pg_temp.activity(pg_temp.u(1)) is not null, 'a granted read records member activity');
select matches(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(3), pg_temp.s(3))),
  '^ok .*"membership_state": "approved"', 'a +44 member is granted too (no country assumptions)');
select is((select pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1), array['otp', 'password']))) like 'ok %',
  true, 'password among several AMR entries is accepted');

-- Denials: who is calling ----------------------------------------------------------------------
select is(pg_temp.read('anon', '{"role": "anon"}'), '42501|permission denied for function identity_my_member_summary|',
  'signed-out client: no EXECUTE');
select is(pg_temp.read('authenticated', '{"role": "authenticated"}'), 'PT401|unauthenticated|unauthenticated',
  'no subject: unauthenticated');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(2), pg_temp.s(2))),
  'PT403|forbidden|not_linked', 'unlinked account (F1: password AMR alone) is denied');

-- Denials: untrusted sessions (activity untouched) ---------------------------------------------
update app.identity_account_links set last_member_activity_at = '2026-10-01T00:00:00Z'
 where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1), array['otp'])),
  'PT401|unauthenticated|untrusted_session', 'otp-only AMR (magic link, signup link, recovery) is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1), array['recovery'])),
  'PT401|unauthenticated|untrusted_session', 'recovery AMR is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1), array[]::text[])),
  'PT401|unauthenticated|untrusted_session', 'empty AMR is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1)) - 'amr'),
  'PT401|unauthenticated|untrusted_session', 'missing AMR is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1)) || '{"amr": ["password"]}'),
  'PT401|unauthenticated|untrusted_session', 'malformed AMR entries are denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(2))),
  'PT401|unauthenticated|untrusted_session', 'another account''s session id is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(99))),
  'PT401|unauthenticated|untrusted_session', 'a revoked (deleted) session is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1)) || '{"role": "anon"}'),
  'PT401|unauthenticated|untrusted_session', 'a non-authenticated role claim is denied');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1)) || '{"is_anonymous": true}'),
  'PT401|unauthenticated|untrusted_session', 'an anonymous session is denied');
update auth.sessions set not_after = now() - interval '1 minute' where id = pg_temp.s(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT401|unauthenticated|untrusted_session', 'a session past not_after is denied');
update auth.sessions set not_after = null where id = pg_temp.s(1);
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT401|unauthenticated|untrusted_session', 'a banned Auth user is denied');
update auth.users set banned_until = null where id = pg_temp.u(1);
select is(pg_temp.activity(pg_temp.u(1)), '2026-10-01T00:00:00Z'::timestamptz,
  'denied calls never refresh activity');

-- Denials: binding, holds, link and membership state --------------------------------------------
update auth.users set phone = '12025550109' where id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'a changed Auth phone needs review (direct Auth change)');
update auth.users set phone = '12025550101', email = 'synthetic-2-1@example.test' where id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'an unapproved recovery email needs review');
update app.identity_account_links set approved_recovery_email = 'synthetic-2-1@example.test'
 where auth_user_id = pg_temp.u(1);
select matches(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  '^ok .*"has_recovery_email": true', 'an approved binding with email is granted');
update auth.users set email = null where id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'a removed approved email needs review');
update app.identity_account_links set approved_recovery_email = null where auth_user_id = pg_temp.u(1);

insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'pgtap synthetic hold', 'pgtap'
  from app.identity_account_links where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'an open hold denies every session');
update app.identity_holds set released_at = now(), released_by = 'pgtap';
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))) like 'ok %', true,
  'a released hold no longer denies');

update app.identity_account_links set link_state = 'review_required' where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'a link in review is denied');
update app.identity_account_links set link_state = 'active' where auth_user_id = pg_temp.u(1);
update app.identity_members m set membership_state = 'deactivated'
  from app.identity_account_links l where l.member_id = m.member_id and l.auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|not_linked', 'a deactivated member has no member access');
update app.identity_members m set membership_state = 'approved'
  from app.identity_account_links l where l.member_id = m.member_id and l.auth_user_id = pg_temp.u(1);

-- Dormancy is evaluated before the activity refresh ------------------------------------------
update app.identity_account_links set last_member_activity_at = now() - interval '91 days'
 where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'dormant past the (fixture) 90 days: identity recheck');
select ok(pg_temp.activity(pg_temp.u(1)) < now() - interval '90 days',
  'a dormant denial does not refresh activity');
update app.identity_account_links set last_member_activity_at = null,
       approved_at = now() - interval '91 days' where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|forbidden|review_required', 'with no activity, approval time is the dormancy baseline');
update app.identity_account_links set last_member_activity_at = now() - interval '89 days'
 where auth_user_id = pg_temp.u(1);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))) like 'ok %', true,
  'inside the dormancy window: granted');
select ok(pg_temp.activity(pg_temp.u(1)) > now() - interval '1 minute', 'and activity is refreshed');

-- Current-member helper for future RLS ------------------------------------------------------
select set_config('request.jwt.claims', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))::text, true);
select ok(app.identity_current_member_id() is not null, 'identity_current_member_id: granted caller');
select set_config('request.jwt.claims', pg_temp.claims(pg_temp.u(2), pg_temp.s(2))::text, true);
select is(app.identity_current_member_id(), null, 'identity_current_member_id: unlinked caller is null');

-- Release gate and settings by environment -------------------------------------------------
-- A non-synthetic member is never served while private_access is closed, even locally.
update app.identity_members m set is_synthetic = false
  from app.identity_account_links l where l.member_id = m.member_id and l.auth_user_id = pg_temp.u(3);
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(3), pg_temp.s(3))),
  'PT403|unavailable|unavailable', 'non-synthetic member + closed private_access: unavailable');
select app.policy_approve('private_access', '{"enabled": true}', 'pgtap', 'TEST ONLY, rolled back');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(3), pg_temp.s(3))) like 'ok %', true,
  'non-synthetic member is served once the owner approves private_access');
update app.policy_gates set state = 'unresolved', approved_value = null, approved_by = null,
       approved_at = null, approval_note = null where gate = 'private_access';

-- A held restore removes the synthetic bypass in local and staging.
update app.rcv_recovery_state set state = 'restored_held', restore_id = gen_random_uuid(),
       updated_by = 'pgtap';
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|unavailable|unavailable', 'local + held restore: synthetic member is unavailable');
update app.rcv_recovery_state set state = 'live', restore_id = null, updated_by = 'pgtap';
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))) like 'ok %', true,
  'live again: synthetic member is served');

-- Approved phones are E.164 with 8 to 15 digits.
select throws_ok($$update app.identity_account_links set approved_phone = '+1202555'
                    where auth_user_id = pg_temp.u(1)$$,
  '23514', null, 'a 7-digit approved phone is rejected');

-- Unmarked database = production: the fixture dormancy setting is ignored, so access fails closed.
delete from app.platform_environment;
select is(app.identity_setting('dormancy_days'), null, 'production ignores fixture settings');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|unavailable|unavailable', 'production with unset settings: unavailable');
select throws_ok($$select app.identity_seed_synthetic_link(pg_temp.u(2), 'SYNTHETIC Two', 'pgtap')$$,
  '22023', 'synthetic links are allowed only in a database marked local or staging',
  'seeding is refused in production');
insert into app.identity_settings (setting, version, value, source, label, set_by)
values ('dormancy_days', 2, '{"days": 30}', 'approved', 'pgtap approved value, rolled back', 'pgtap');
select is(app.identity_setting('dormancy_days'), '{"days": 30}'::jsonb, 'an approved setting applies in production');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|unavailable|unavailable', 'production still needs private_access for synthetic members');
select throws_ok($$insert into app.identity_settings (setting, version, value, source, label, set_by)
                   values ('dormancy_days', 3, '{"days": 30}', 'fixture', 'unlabelled', 'pgtap')$$,
  '23514', null, 'a fixture setting must be labelled TEST FIXTURE');
delete from app.identity_settings where version = 2;

-- Staging honours the labelled fixture for synthetic members.
select app.platform_set_environment('staging', 'pgtap 2.1');
select is(app.identity_setting('dormancy_days'), '{"days": 90}'::jsonb, 'staging uses the labelled fixture');
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))) like 'ok %', true,
  'staging serves a synthetic member with private_access closed');
select ok(not app.policy_is_open('private_access'), 'and the private_access gate itself stays closed');
update app.rcv_recovery_state set state = 'restored_held', restore_id = gen_random_uuid(),
       updated_by = 'pgtap';
select is(pg_temp.read('authenticated', pg_temp.claims(pg_temp.u(1), pg_temp.s(1))),
  'PT403|unavailable|unavailable', 'staging + held restore: synthetic member is unavailable');

select * from finish();
rollback;
