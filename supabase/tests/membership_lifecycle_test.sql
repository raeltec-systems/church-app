-- Hold, deactivate and restore membership with handover obligations (story 2.10; I10, AD-14,
-- AC-22). Login hold through the 2.8 hold machinery; church deactivation and reviewed
-- restoration in one transaction each; owner handover hooks (SYNTHETIC fixture only); the
-- last-usable-Admin and last-responsible refusals; the Admin and own reads. HTTP evidence
-- through real GoTrue: tools/identity-e2e/lifecycle.mjs. Every account here is SYNTHETIC
-- (+44 7700 900500-900519).
begin;
select plan(76);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000210' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000210' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s2(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9100-0000000210' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (500 + n)::text $$;

create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.c2(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s2(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid, p_age interval default interval '1 hour')
returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - p_age);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
-- A fresh password session of account n, opened after every epoch so far (sign in again).
create function pg_temp.fresh(n int) returns jsonb language plpgsql as $$
declare
  v_session uuid := gen_random_uuid();
begin
  perform pg_temp.session(pg_temp.u(n), v_session, interval '-1 minute');
  return pg_temp.claims(pg_temp.u(n), v_session);
end;
$$;

create function pg_temp.call(p_claims jsonb, p_endpoint text, p_command text, p_expected bigint,
                             p_payload jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
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
create function pg_temp.readj(p_claims jsonb, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(p_claims, p_sql), 4)::jsonb $$;
create function pg_temp.summary(p_claims jsonb) returns text language sql as
$$ select case when r like 'ok %' then 'ok' else r end
     from pg_temp.read(p_claims, 'select api.identity_my_member_summary()') r $$;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
create function pg_temp.state(n int) returns text language sql as
$$ select membership_state from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.lc(p_claims jsonb, p_command text, n int, p_payload jsonb) returns jsonb
language sql as $$
  select pg_temp.call(p_claims, 'identity_lifecycle_command', p_command, pg_temp.mrev(n),
                      jsonb_build_object('member_id', pg_temp.mid(n)) || p_payload)
$$;
create function pg_temp.deactivate(n int, p_claims jsonb default null, p_reason text default 'church_decision')
returns jsonb language sql as $$
  select pg_temp.lc(coalesce(p_claims, pg_temp.c(1)), 'identity.deactivate_membership', n,
                    jsonb_build_object('reason_code', p_reason))
$$;
create function pg_temp.restore(n int, p_claims jsonb default null) returns jsonb language sql as $$
  select pg_temp.lc(coalesce(p_claims, pg_temp.c(1)), 'identity.restore_membership', n,
                    '{"identity_check": "in_person"}')
$$;
create function pg_temp.hold(n int, p_reason text, p_claims jsonb default null) returns jsonb
language sql as $$
  select pg_temp.call(coalesce(p_claims, pg_temp.c(1)), 'identity_credential_command',
                      'identity.place_hold', pg_temp.mrev(n),
                      jsonb_build_object('member_id', pg_temp.mid(n), 'reason_code', p_reason))
$$;
create function pg_temp.grant(n int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.call(pg_temp.c(1), 'identity_grant_command',
                      case when p_payload ? 'role' then 'identity.grant_role' else 'identity.grant_scope' end,
                      pg_temp.grev(n), jsonb_build_object('member_id', pg_temp.mid(n)) || p_payload)
$$;
create function pg_temp.err(r jsonb) returns text language sql as
$$ select (r ->> 'code') || ' ' || coalesce(r -> 'field_errors', '{}'::jsonb)::text $$;
create function pg_temp.calls(n int) returns text language sql as $$
  select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls
   where member_id = pg_temp.mid(n)
$$;
create function pg_temp.live_sessions(n int) returns int language sql as
$$ select count(*)::int from auth.sessions where user_id = pg_temp.u(n) $$;

-- Accounts: 1 Admin A; 2 Admin B; 3 login hold (cell, fixture duty, two devices); 4 deactivated
-- and restored (grants, two devices, fixture duty, an issued recovery grant); 5 sole responsible
-- for a fixture duty; 6 (no account) accountless member; 7 uncertain recovery operation;
-- 8 pending recovery operation; 9 a raising owner hook; 10 a malformed handover hook.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 10) n where n <> 6;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 10) n where n <> 6;
select pg_temp.session(pg_temp.u(n), pg_temp.s2(n)) from (values (3), (4)) x(n);

-- Structure and privileges ---------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.identity_membership_lifecycle', 'app.identity_handover_hooks',
                             'app.identity_handover_obligations', 'app.fixture_duties']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the new tables');
select ok(not has_function_privilege('anon', 'api.identity_lifecycle_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_membership_lifecycle()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_my_membership_status()', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.identity_lifecycle_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_register_handover_hook(text, regprocedure)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_resolve_handover_obligation(text, uuid, text)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.fixture_report_handover(jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_place_hold(uuid, bigint, jsonb)', 'EXECUTE'),
  'signed-out callers execute nothing new; owner seams and handlers are not client-executable');
select ok(has_function_privilege('authenticated', 'api.identity_credential_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_credential_command(jsonb)', 'EXECUTE'),
  'the 2.8 command keeps its privileges after the hold functions were replaced');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_handover_obligations'),
  array['lifecycle_event_id', 'member_id', 'obligation_id', 'obligation_kind', 'obligation_state',
        'owner_module', 'recorded_at', 'resolution', 'resolved_at', 'subject_id'],
  'an obligation holds owner, kind and an opaque subject only');
select ok((select count(*) from app.contract_lifecycle_events
            where event in ('membership_deactivated', 'membership_restored')) = 2,
  'the two lifecycle events are in the v1 list');
select throws_ok($$select app.identity_register_handover_hook('identity', 'app.fixture_report_handover(jsonb)'::regprocedure)$$,
  'PCTR1', NULL, 'identity cannot report handovers to itself');
select throws_ok($$select app.identity_register_handover_hook('cells', 'app.fixture_report_handover(jsonb)'::regprocedure)$$,
  'PCTR1', NULL, 'a handler must belong to the registering owner');
select throws_ok($$select app.identity_register_handover_hook('fixture', 'app.fixture_record_lifecycle(jsonb)'::regprocedure)$$,
  'PCTR1', NULL, 'a handover handler must return jsonb');

-- Environment, members, grants and the SYNTHETIC hooks ----------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.10');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.10 Member ' || n, 'pgtap 2.10') as member_id
  from generate_series(1, 10) n where n <> 6;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 2.10 Accountless', 'approved', true) returning member_id)
insert into m select 6, member_id from ins;
grant select on m to authenticated;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
select pg_temp.grant(2, '{"role": "admin"}');
select pg_temp.grant(4, '{"role": "pastor"}');
insert into app.fixture_scope_targets (scope_kind, scope_id) values ('fixture_care', '00000000-0000-4000-b000-000000021001');
select pg_temp.grant(4, '{"scope_kind": "fixture_care", "scope_id": "00000000-0000-4000-b000-000000021001"}');
select app.contract_register_lifecycle_hook('fixture', e, 'app.fixture_record_lifecycle(jsonb)'::regprocedure)
  from unnest(array['access_hold_applied', 'sessions_revoked', 'scope_revoked', 'membership_deactivated',
                    'membership_restored']) e;
select app.identity_register_handover_hook('fixture', 'app.fixture_report_handover(jsonb)'::regprocedure);
-- Cell facts for member 3 (the Cells owner's rows; seeded directly).
select app.cells_seed_synthetic_cells('pgtap 2.10');
insert into app.cells_member_states (member_id) values (pg_temp.mid(3));
insert into app.cells_membership_requests (member_id, kind, origin, choice, requested_cell_id)
values (pg_temp.mid(3), 'join', 'admin', 'cell', (select min(cell_id::text)::uuid from app.cells_cells));
insert into app.cells_memberships (member_id, cell_id, request_id, confirmed_by_member, confirmed_by_account, confirmed_as)
select member_id, requested_cell_id, request_id, pg_temp.mid(1), pg_temp.u(1), 'admin'
  from app.cells_membership_requests where member_id = pg_temp.mid(3);
update app.cells_membership_requests r
   set request_state = 'confirmed', decided_at = now(), decided_as = 'admin',
       resulting_membership_id = (select membership_id from app.cells_memberships where member_id = pg_temp.mid(3))
 where r.member_id = pg_temp.mid(3);
insert into app.fixture_duties (member_id, duty_kind) values
  (pg_temp.mid(3), 'fixture_door_duty'), (pg_temp.mid(4), 'fixture_door_duty'),
  (pg_temp.mid(5), 'fixture_custody');
update app.fixture_duties set sole_responsible = true where member_id = pg_temp.mid(5);
create temp table facts as
select 'cells' k, (select count(*)::int from app.cells_memberships where member_id = pg_temp.mid(3) and ended_at is null) v
union all select 'duties', (select count(*)::int from app.fixture_duties where member_id = pg_temp.mid(3));
select is(pg_temp.summary(pg_temp.c(3)) || '|' || pg_temp.summary(pg_temp.c2(3)), 'ok|ok', 'member 3 is granted on both devices');

-- Login hold -------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.hold(3, 'login_paused')), 'validation_failed {"reason_code": "invalid"}',
  'an unknown hold reason is refused');
select is(pg_temp.err(pg_temp.hold(3, 'login_disabled', pg_temp.c(4))), 'forbidden {}',
  'a member who is not an Admin cannot hold a login');
select is(pg_temp.hold(3, 'login_disabled') -> 'data' -> 'holds' -> 0 ->> 'reason_code', 'login_disabled',
  'an Admin holds the login');
select is((select hold_kind || '|' || reason || '|' || coalesce(reason_code, '-') || '|' || sessions_revoked
             from app.identity_holds where member_id = pg_temp.mid(3) and released_at is null),
  'login|login_disabled|-|2', 'a 2.8 hold of kind login; both sessions counted');
select is(pg_temp.live_sessions(3), 0, 'every Auth session of the account is revoked');
select is(pg_temp.summary(pg_temp.c(3)) || ' / ' || pg_temp.summary(pg_temp.c2(3)),
  'PT401|unauthenticated|untrusted_session / PT401|unauthenticated|untrusted_session',
  'both devices are denied at once');
select is(pg_temp.summary(pg_temp.fresh(3)), 'PT403|forbidden|review_required',
  'a fresh sign-in reaches only the generic help state');
select is(pg_temp.calls(3), 'access_hold_applied,sessions_revoked', 'owner hooks ran in the same transaction');
select is((select string_agg(k || '=' || v, ',' order by k) from facts),
  (select 'cells=' || (select count(*) from app.cells_memberships where member_id = pg_temp.mid(3) and ended_at is null)
          || ',duties=' || (select count(*) from app.fixture_duties where member_id = pg_temp.mid(3))),
  'cell membership and fixture duty facts survive the hold');
select is(pg_temp.state(3) || '|' || (select link_state from app.identity_account_links where member_id = pg_temp.mid(3) and link_state <> 'ended')
          || '|' || (select count(*) from app.identity_handover_obligations where member_id = pg_temp.mid(3)),
  'approved|active|0', 'a hold keeps membership and link, and records no handover');
select is(pg_temp.err(pg_temp.hold(3, 'login_disabled')), 'conflict {"reason_code": "already_held"}',
  'the same login hold twice is refused');
select is((select count(*)::int from app.identity_credential_review_audit
            where member_id = pg_temp.mid(3) and action = 'hold_placed' and reason_code = 'login_disabled'), 1,
  'the login hold is audited with its code');
select is(jsonb_array_length(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_membership_lifecycle()') -> 'login_holds'), 1,
  'the Admin lifecycle read lists the login hold');
select is(pg_temp.call(pg_temp.c(1), 'identity_credential_command', 'identity.release_hold', pg_temp.mrev(3),
            jsonb_build_object('member_id', pg_temp.mid(3), 'identity_check', 'in_person',
              'hold_id', (select hold_id from app.identity_holds where member_id = pg_temp.mid(3) and released_at is null))) -> 'data' -> 'holds',
  '[]'::jsonb, 'the 2.8 release lifts the login hold');
select is(pg_temp.summary(pg_temp.fresh(3)), 'ok', 'after release a fresh sign-in is granted');

-- Last usable Admin ------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.deactivate(1)), 'forbidden {"member_id": "unsupported"}',
  'an Admin cannot deactivate their own membership while another Admin remains');
select pg_temp.hold(2, 'security_concern');
select ok(app.identity_is_last_admin(pg_temp.mid(1)), 'with B held, A is the last usable Admin');
select is(pg_temp.err(pg_temp.deactivate(1)), 'forbidden {"member_id": "last_admin"}',
  'removing the last usable Admin is refused');
select is(pg_temp.state(1), 'approved', 'and nothing changed');

-- Last responsible person (owner handover hook) ----------------------------------------------------
select is(pg_temp.err(pg_temp.deactivate(5)), 'conflict {"member_id": "handover_required"}',
  'the last responsible person for an owner''s work cannot be removed without a handover');
select is(pg_temp.state(5) || '|' || pg_temp.live_sessions(5) || '|'
          || (select count(*) from app.identity_handover_obligations where member_id = pg_temp.mid(5)),
  'approved|1|0', 'nothing was written: still approved, session alive, no obligation');
update app.fixture_duties set sole_responsible = false where member_id = pg_temp.mid(5);  -- the owner handed over
select is(pg_temp.deactivate(5) -> 'data' ->> 'membership_state', 'deactivated',
  'after the owner''s handover the member can be deactivated');
select is((select obligation_kind || '|' || owner_module || '|' || obligation_state from app.identity_handover_obligations
            where member_id = pg_temp.mid(5)), 'fixture_custody|fixture|pending',
  'the remaining duty is recorded as a pending handover');

-- Deactivation -----------------------------------------------------------------------------------
-- An issued recovery grant (2.9) for member 4.
insert into app.identity_recovery_requests (request_code, claimed_phone, grant_digest, request_state, expires_at, bound_at)
values ('ABCDEFGH', pg_temp.phone(4), repeat('a', 64), 'bound', now() + interval '30 minutes', now());
insert into app.identity_recovery_cases (member_id, link_id, auth_user_id, identity_check, evidence, opened_by_member,
                                         opened_by_account, is_synthetic)
select pg_temp.mid(4), l.link_id, l.auth_user_id, 'in_person', array['photo_id'], pg_temp.mid(1), pg_temp.u(1), true
  from app.identity_account_links l where l.member_id = pg_temp.mid(4) and l.link_state <> 'ended';
insert into app.identity_recovery_grants (case_id, recovery_request_id, member_id, link_id, auth_user_id, binding_revision,
                                          credential_generation, issued_by_member, issued_by_account, expires_at)
select c.case_id, (select recovery_request_id from app.identity_recovery_requests where request_code = 'ABCDEFGH'),
       c.member_id, c.link_id, c.auth_user_id, l.binding_revision, l.credential_generation, pg_temp.mid(1), pg_temp.u(1),
       now() + interval '15 minutes'
  from app.identity_recovery_cases c join app.identity_account_links l on l.link_id = c.link_id
 where c.member_id = pg_temp.mid(4);
select is(pg_temp.summary(pg_temp.c(4)) || '|' || pg_temp.summary(pg_temp.c2(4)), 'ok|ok', 'member 4 is granted on both devices');
select is(pg_temp.err(pg_temp.deactivate(4, null, 'left')), 'validation_failed {"reason_code": "invalid"}',
  'an unknown reason code is refused');
select is(pg_temp.err(pg_temp.deactivate(4, pg_temp.fresh(3))), 'forbidden {}', 'a member who is not an Admin cannot deactivate');
select is(pg_temp.err(pg_temp.call(pg_temp.c(1), 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(4) + 1,
            jsonb_build_object('member_id', pg_temp.mid(4), 'reason_code', 'church_decision'))),
  'conflict {}', 'a stale member revision is a conflict');
select is((pg_temp.deactivate(4) -> 'data') - 'member_id' - 'display_name' - 'revision',
  '{"account": "access_review", "is_synthetic": true, "membership_state": "deactivated", "pending_obligations": 1}'::jsonb,
  'an Admin deactivates the membership');
select is(pg_temp.live_sessions(4), 0, 'every Auth session of the account is revoked');
select is(pg_temp.summary(pg_temp.c(4)) || ' / ' || pg_temp.summary(pg_temp.c2(4)),
  'PT401|unauthenticated|untrusted_session / PT401|unauthenticated|untrusted_session',
  'both devices are denied at once');
select is(pg_temp.summary(pg_temp.fresh(4)), 'PT403|forbidden|not_linked', 'a fresh sign-in has no member access');
select is(pg_temp.readj(pg_temp.fresh(4), 'select api.identity_my_membership_status()'),
  '{"deactivated": true, "church_contact": null}'::jsonb, 'the member''s own status says deactivated');
select is((select count(*)::int from app.identity_grants where member_id = pg_temp.mid(4) and revoked_at is null), 0,
  'every grant ended');
select is((select string_agg(action, ',' order by action) from app.identity_access_audit where target_member_id = pg_temp.mid(4)
            and action like '%revoked'), 'role_revoked,scope_revoked', 'through the audited 2.3 path');
select is((select grant_state || '|' || end_reason from app.identity_recovery_grants where member_id = pg_temp.mid(4)),
  'cancelled|stale', 'the pending recovery grant is invalidated');
select is((select link_state from app.identity_account_links where member_id = pg_temp.mid(4) and link_state <> 'ended'),
  'suspended', 'the account link is kept but suspended');
select is((select row(action, reason_code, sessions_revoked, grants_ended, recovery_grants_ended, obligations_recorded)::text
             from app.identity_membership_lifecycle where member_id = pg_temp.mid(4)),
  '(membership_deactivated,church_decision,2,2,1,1)', 'the deactivation is recorded with its counts');
select is(pg_temp.calls(4), 'scope_revoked,scope_revoked,membership_deactivated,sessions_revoked',
  'owner hooks ran in the same transaction');
select is((select count(*)::int from app.fixture_duties where member_id = pg_temp.mid(4)), 1,
  'the owner''s duty fact is kept (the owner hands it over)');
select is(pg_temp.err(pg_temp.deactivate(4)), 'conflict {"member_id": "not_approved"}', 'deactivating twice is refused');
select is(pg_temp.err(pg_temp.hold(4, 'login_disabled')), 'conflict {"member_id": "not_approved"}',
  'a deactivated member cannot be login-held');

-- An accountless member (no login) can be deactivated.
select is(pg_temp.deactivate(6, null, 'moved_away') -> 'data' ->> 'membership_state', 'deactivated',
  'an accountless member is deactivated');
select is((select coalesce(sessions_revoked::text, 'null') from app.identity_membership_lifecycle where member_id = pg_temp.mid(6)),
  'null', 'with no account there are no sessions to revoke');

-- Recovery operations follow the 2.9 rules.
insert into app.identity_holds (member_id, hold_kind, reason, placed_by, password_reset_required_since)
values (pg_temp.mid(7), 'security', 'assisted_reset', 'system:pgtap', now());
create temp table ops as
with c as (
  insert into app.identity_recovery_cases (member_id, link_id, auth_user_id, identity_check, evidence, opened_by_member,
                                           opened_by_account, is_synthetic)
  select pg_temp.mid(x.n), l.link_id, l.auth_user_id, 'in_person', array['photo_id'], pg_temp.mid(1), pg_temp.u(1), true
    from (values (7), (8)) x(n)
    join app.identity_account_links l on l.member_id = pg_temp.mid(x.n) and l.link_state <> 'ended'
  returning *), rq as (
  insert into app.identity_recovery_requests (request_code, claimed_phone, grant_digest, request_state, expires_at, bound_at)
  select case when c.member_id = pg_temp.mid(7) then 'BBBBBBBB' else 'CCCCCCCC' end, '+447700900599',
         repeat(case when c.member_id = pg_temp.mid(7) then 'b' else 'c' end, 64), 'bound', now() + interval '1 hour', now()
    from c returning *), g as (
  insert into app.identity_recovery_grants (case_id, recovery_request_id, member_id, link_id, auth_user_id, binding_revision,
                                            credential_generation, grant_state, issued_by_member, issued_by_account,
                                            expires_at, ended_at, end_reason)
  select c.case_id, rq.recovery_request_id, c.member_id, c.link_id, c.auth_user_id, 1, 1, 'consumed', pg_temp.mid(1),
         pg_temp.u(1), now() + interval '15 minutes', now(), 'redeemed'
    from c join rq on rq.grant_digest = repeat(case when c.member_id = pg_temp.mid(7) then 'b' else 'c' end, 64)
  returning *)
select g.member_id, g.grant_id, g.case_id, g.link_id, g.auth_user_id from g;
insert into app.identity_recovery_operations (grant_id, case_id, member_id, link_id, auth_user_id, generation_at_begin,
                                              binding_revision_at_begin, op_state, system_principal_id, dispatched_at,
                                              completed_at, hold_id)
select o.grant_id, o.case_id, o.member_id, o.link_id, o.auth_user_id, 1, 1,
       case when o.member_id = pg_temp.mid(7) then 'uncertain' else 'pending' end, gen_random_uuid(),
       case when o.member_id = pg_temp.mid(7) then now() end, case when o.member_id = pg_temp.mid(7) then now() end,
       case when o.member_id = pg_temp.mid(7) then (select hold_id from app.identity_holds where member_id = pg_temp.mid(7)) end
  from ops o;
select is(pg_temp.deactivate(7) -> 'data' ->> 'membership_state', 'deactivated', 'a member with an uncertain reset is deactivated');
select is((select op_state from app.identity_recovery_operations where member_id = pg_temp.mid(7))
          || '|' || (select count(*) from app.identity_holds where member_id = pg_temp.mid(7) and released_at is null),
  'uncertain|1', 'an uncertain operation stays, and its hold stays (2.9)');
select is(pg_temp.deactivate(8) -> 'data' ->> 'membership_state', 'deactivated', 'a member with a pending reset is deactivated');
select is((select op_state from app.identity_recovery_operations where member_id = pg_temp.mid(8))
          || '|' || (select recovery_operations_obsoleted from app.identity_membership_lifecycle where member_id = pg_temp.mid(8)),
  'obsolete|1', 'a pending operation (nothing external yet) becomes obsolete');
select is((select code from app.identity_recovery_audit where member_id = pg_temp.mid(8) and action = 'operation_obsolete'),
  'member_deactivated', 'and is audited with the reason');

-- Atomicity: a raising owner hook, or a malformed handover answer, rolls everything back.
create function app.fixture_fail_lifecycle(p_event jsonb) returns void language plpgsql set search_path = '' as $$
begin
  raise exception 'SYNTHETIC failing owner hook';
end;
$$;
create function app.fixture_bad_handover(p_event jsonb) returns jsonb language sql set search_path = '' as $$
  select '{"obligations": [{"kind": "Bad Kind", "subject_id": "x", "last_responsible": "yes"}]}'::jsonb
$$;
update app.contract_lifecycle_hooks set handler = 'app.fixture_fail_lifecycle(jsonb)'
 where event = 'membership_deactivated' and module = 'fixture';
select is(pg_temp.err(pg_temp.deactivate(9)), 'unavailable {}', 'a raising owner lifecycle hook fails the deactivation');
select is(pg_temp.state(9) || '|' || pg_temp.live_sessions(9), 'approved|1', 'and nothing changed (one transaction)');
update app.contract_lifecycle_hooks set handler = 'app.fixture_record_lifecycle(jsonb)'
 where event = 'membership_deactivated' and module = 'fixture';
update app.identity_handover_hooks set handler = 'app.fixture_bad_handover(jsonb)' where module = 'fixture';
select is(pg_temp.err(pg_temp.deactivate(10)), 'unavailable {}', 'a malformed handover answer fails closed');
select is(pg_temp.state(10) || '|' || pg_temp.live_sessions(10), 'approved|1', 'and nothing changed');
update app.identity_handover_hooks set handler = 'app.fixture_report_handover(jsonb)' where module = 'fixture';

-- Reads ------------------------------------------------------------------------------------------
select is((select jsonb_agg(x ->> 'display_name' order by x ->> 'display_name')
             from jsonb_array_elements(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_membership_lifecycle()') -> 'deactivated') x),
  '["SYNTHETIC 2.10 Accountless", "SYNTHETIC 2.10 Member 4", "SYNTHETIC 2.10 Member 5", "SYNTHETIC 2.10 Member 7", "SYNTHETIC 2.10 Member 8"]'::jsonb,
  'the Admin read lists the deactivated members');
select is((select jsonb_agg(x ->> 'obligation_kind' order by x ->> 'obligation_kind')
             from jsonb_array_elements(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_membership_lifecycle()') -> 'handovers') x),
  '["fixture_custody", "fixture_door_duty"]'::jsonb, 'and the pending handovers');
select is(pg_temp.read(pg_temp.fresh(3), 'select api.identity_admin_membership_lifecycle()'), 'PT403|forbidden|not_granted',
  'a member who is not an Admin cannot read it');
select is(pg_temp.readj(pg_temp.fresh(3), 'select api.identity_my_membership_status()') ->> 'deactivated', 'false',
  'an approved member''s own status is not deactivated');
select is(pg_temp.read('{}', 'select api.identity_my_membership_status()'), 'PT401|unauthenticated|unauthenticated',
  'without a session there is no status');

-- Restoration ------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.lc(pg_temp.c(1), 'identity.restore_membership', 4, '{}')),
  'validation_failed {"identity_check": "required"}', 'a restoration needs an identity check');
select is(pg_temp.err(pg_temp.restore(3)), 'conflict {"member_id": "not_deactivated"}', 'only a deactivated member is restored');
select is(pg_temp.restore(4) -> 'data' ->> 'membership_state', 'approved', 'an Admin restores the membership after review');
select is((select link_state from app.identity_account_links where member_id = pg_temp.mid(4) and link_state <> 'ended')
          || '|' || (select count(*) from app.identity_grants where member_id = pg_temp.mid(4) and revoked_at is null)
          || '|' || (select obligation_state from app.identity_handover_obligations where member_id = pg_temp.mid(4)),
  'active|0|pending', 'the link is active again; grants are not restored; the handover stays pending');
select is(pg_temp.summary(pg_temp.fresh(4)), 'ok', 'a fresh sign-in is granted again');
select is(pg_temp.calls(4), 'scope_revoked,scope_revoked,membership_deactivated,sessions_revoked,membership_restored',
  'membership_restored reached the owner hooks');
select ok(app.identity_resolve_handover_obligation('fixture',
            (select obligation_id from app.identity_handover_obligations where member_id = pg_temp.mid(4)), 'handed_over')
          and not app.identity_resolve_handover_obligation('cells',
            (select obligation_id from app.identity_handover_obligations where member_id = pg_temp.mid(5)), 'handed_over'),
  'only the owning module resolves its obligation');

select * from finish();
rollback;
