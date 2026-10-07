-- Staff-assisted recovery with a single-use setup grant (story 2.9; AD-3, AD-19, AD-20, AC-06).
-- Admin cases and grants through api.identity_recovery_command, the fenced system steps through
-- the 1.9 system route (api.system_command, purpose identity_assisted_recovery), Auth Admin's
-- password update simulated as GoTrue v2.197.0 does it (encrypted_password changed, every session
-- deleted). HTTP evidence through real GoTrue and the served Edge Function:
-- tools/identity-e2e/assisted.mjs. Every account and phone here is SYNTHETIC
-- (+44 7700 900400-900429).
begin;
select plan(122);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000029' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000029' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (400 + n)::text $$;
create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid, p_age interval default interval '1 hour')
returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - p_age);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
-- A fresh password sign-in of account n, after every epoch so far.
create function pg_temp.fresh(n int) returns jsonb language plpgsql as $$
declare
  v_session uuid := gen_random_uuid();
begin
  perform pg_temp.session(pg_temp.u(n), v_session, interval '-1 minute');
  return pg_temp.claims(pg_temp.u(n), v_session);
end;
$$;
create function pg_temp.read(p_claims jsonb, p_sql text) returns text language plpgsql as $$
declare
  r jsonb; v_state text; v_msg text; v_detail text;
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
create function pg_temp.summary(p_claims jsonb) returns text language sql as
$$ select case when r like 'ok %' then 'ok' else r end
     from pg_temp.read(p_claims, 'select api.identity_my_member_summary()') r $$;

-- Admin commands (api.identity_recovery_command).
create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', p_claims::text, true);
  set local role authenticated;
  select api.identity_recovery_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.ccmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', p_claims::text, true);
  set local role authenticated;
  select api.identity_credential_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;

-- The system route as the Edge Function calls it (anon + x-system-credential).
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
create function pg_temp.sys(p_command text, p_payload jsonb, p_token text default null)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', coalesce(p_token, pg_temp.token('R')))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', p_command,
           'request_id', gen_random_uuid(), 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.dg(n int, k text) returns text language sql as
$$ select encode(sha256(convert_to('arg_synthetic_2_9_' || n || '_' || k, 'UTF8')), 'hex') $$;
-- A member device's request: returns the request code.
-- The client key the function derives from a client IP (a keyed hash; here one per account n).
create function pg_temp.ck(n int) returns text language sql as
$$ select encode(sha256(convert_to('synthetic-2-9-client-' || n, 'UTF8')), 'hex') $$;
create function pg_temp.request(n int, k text, p_phone text default null, p_client text default null)
returns text language sql as $$
  select pg_temp.sys('identity.assisted_recovery_request',
    jsonb_build_object('phone_username', coalesce(p_phone, pg_temp.phone(n)), 'grant_digest', pg_temp.dg(n, k),
                       'client_key', coalesce(p_client, pg_temp.ck(n))))
    -> 'data' ->> 'request_code'
$$;
create function pg_temp.begin_(n int, k text, p_phone text default null, p_client text default null)
returns jsonb language sql as $$
  select pg_temp.sys('identity.assisted_reset_begin',
    jsonb_build_object('phone_username', coalesce(p_phone, pg_temp.phone(n)), 'grant_digest', pg_temp.dg(n, k),
                       'client_key', coalesce(p_client, pg_temp.ck(n)))) -> 'data'
$$;
create function pg_temp.dispatch(p_op text) returns jsonb language sql as $$
  select pg_temp.sys('identity.assisted_reset_dispatch', jsonb_build_object('operation_id', p_op)) -> 'data'
$$;
create function pg_temp.complete(p_op text, p_result text) returns jsonb language sql as $$
  select pg_temp.sys('identity.assisted_reset_complete',
    jsonb_build_object('operation_id', p_op, 'auth_result', p_result)) -> 'data'
$$;
-- GoTrue v2.197.0 Auth Admin password update: the hash changes and every session is deleted.
create function pg_temp.admin_apply(n int) returns void language sql as $$
  update auth.users set encrypted_password = 'synthetic-2-9-hash-' || gen_random_uuid() where id = pg_temp.u(n);
  delete from auth.sessions where user_id = pg_temp.u(n);
$$;

create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.kase(n int) returns app.identity_recovery_cases language sql as $$
  select c.* from app.identity_recovery_cases c where c.member_id = pg_temp.mid(n)
   order by c.opened_at desc limit 1
$$;
create function pg_temp.open_case(n int) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'identity.open_recovery_case', null,
    jsonb_build_object('member_id', pg_temp.mid(n), 'identity_check', 'in_person',
                       'evidence', jsonb_build_array('photo_id', 'known_in_person')))
$$;
create function pg_temp.issue(n int, p_code text) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'identity.issue_recovery_grant', (pg_temp.kase(n)).revision,
    jsonb_build_object('case_id', (pg_temp.kase(n)).case_id, 'request_code', p_code))
$$;
-- Open a case, request and issue: the ready-to-redeem state.
create function pg_temp.ready(n int, k text) returns jsonb language sql as $$
  select pg_temp.open_case(n);
  select pg_temp.issue(n, pg_temp.request(n, k));
$$;
create function pg_temp.op(n int) returns app.identity_recovery_operations language sql as $$
  select o.* from app.identity_recovery_operations o where o.member_id = pg_temp.mid(n)
   order by o.begun_at desc limit 1
$$;
create function pg_temp.open_holds(n int) returns text language sql as $$
  select coalesce(string_agg(coalesce(h.reason_code, h.reason), ',' order by h.placed_at), '')
    from app.identity_holds h where h.member_id = pg_temp.mid(n) and h.released_at is null
$$;
create function pg_temp.audit(n int) returns text language sql as $$
  select coalesce(string_agg(a.action || coalesce(':' || a.code, ''), ',' order by a.event_id), '')
    from app.identity_recovery_audit a where a.member_id = pg_temp.mid(n)
$$;

-- Accounts: 1 Admin; 2 happy path; 3 reissue; 4 direct password change; 5 unlinked; 6 the
-- member whose phone 7's grant is presented with; 7 cross-member; 8 uncertain then late, relink
-- blocked, reconciled, recovered; 9 lost-device hold; 10 dispute hold; 11 obsolete at dispatch;
-- 12 Auth refused; 13 expired; 14 pre-dispatch session survives; 15 stuck; 16 replay/concurrent;
-- 17 cancel between begin and dispatch; 18 deactivated after begin; 19 deactivated during an open
-- case; 20 binding revision moved after begin; 21 a session opened before the password change;
-- 22 deactivated after dispatch; 23 case closed under a dispatched operation.
insert into auth.users (id, aud, role, phone, phone_confirmed_at, encrypted_password)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now(), 'synthetic-2-9-initial'
  from generate_series(1, 23) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 23) n;

-- Structure and privileges ---------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.identity_recovery_requests', 'app.identity_recovery_cases',
                             'app.identity_recovery_grants', 'app.identity_recovery_operations',
                             'app.identity_recovery_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the recovery tables');
select ok(not has_function_privilege('anon', 'api.identity_recovery_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_recovery_cases()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_sys_reset_begin(uuid, uuid, jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'app.identity_sys_reset_begin(uuid, uuid, jsonb)', 'EXECUTE')
          and not has_function_privilege('service_role', 'app.identity_sys_reset_complete(uuid, uuid, jsonb)', 'EXECUTE')
          and not has_function_privilege('service_role', 'api.identity_recovery_command(jsonb)', 'EXECUTE'),
  'signed-out callers get neither the command nor the read; nobody calls the system handlers directly');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_recovery_audit'),
  array['action', 'actor_account_id', 'actor_kind', 'actor_member_id', 'case_id', 'code', 'environment',
        'event_id', 'evidence', 'grant_id', 'identity_check', 'member_id', 'occurred_at', 'operation_id',
        'request_id', 'revision_after', 'sessions', 'system_principal_id'],
  'the audit holds ids, codes and timestamps only (no phone, code, secret or digest)');
select ok(not exists (select 1 from information_schema.columns
                       where table_schema = 'app' and table_name like 'identity_recovery_%'
                         and (column_name ~ '(secret|token)' or column_name ~ '^(new_)?password$')),
  'no recovery table has a secret, password or token column (only the digest)');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Environment, members, Admin, system principal ----------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.9');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.9 Member ' || n, 'pgtap 2.9') as member_id
  from generate_series(1, 23) n;
grant select on m to authenticated, anon;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
select app.contract_register_lifecycle_hook('fixture', 'access_hold_applied', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
select app.contract_register_lifecycle_hook('fixture', 'access_hold_released', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
select app.contract_register_lifecycle_hook('fixture', 'sessions_revoked', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
create function pg_temp.calls(n int) returns text language sql as $$
  select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls
   where member_id = pg_temp.mid(n)
$$;
create temp table t_ids (k text primary key, v uuid);
grant select on t_ids to anon;
insert into t_ids values ('principal', app.sys_create_principal('identity-assisted-recovery', 'identity_assisted_recovery', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'principal'),
  encode(sha256(convert_to(pg_temp.token('R'), 'UTF8')), 'hex'), 'pgtap 2.9', interval '1 hour', 'israel');
insert into t_ids values ('probe', app.sys_create_principal('pgtap-probe-29', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'probe'),
  encode(sha256(convert_to(pg_temp.token('P'), 'UTF8')), 'hex'), 'pgtap probe', interval '1 hour', 'israel');
select is((select array_agg(command order by command) from app.sys_principal_commands
            where principal_id = (select v from t_ids where k = 'principal')),
  array['identity.assisted_recovery_request', 'identity.assisted_recovery_status', 'identity.assisted_reset_begin',
        'identity.assisted_reset_complete', 'identity.assisted_reset_dispatch'],
  'the assisted-recovery principal holds exactly its own five commands');
select is(pg_temp.sys('identity.assisted_reset_begin',
            jsonb_build_object('phone_username', pg_temp.phone(2), 'grant_digest', pg_temp.dg(2, 'a'),
                               'client_key', pg_temp.ck(2)), pg_temp.token('P')) ->> 'code',
  'forbidden', 'a principal of another purpose cannot run a recovery step');
select is(pg_temp.sys('system.synthetic_probe', '{}', pg_temp.token('R')) ->> 'code', 'forbidden',
  'the recovery principal cannot run the probe');
select is(pg_temp.sys('system.synthetic_probe', '{}', pg_temp.token('P')) -> 'data' ->> 'is_synthetic', 'true',
  'the probe still works for its own principal');
select is(pg_temp.sys('identity.assisted_reset_begin',
            jsonb_build_object('phone_username', '0977', 'grant_digest', 'XYZ', 'member_id', pg_temp.mid(2))) -> 'field_errors',
  '{"client_key": "required", "grant_digest": "invalid", "member_id": "unknown_field", "phone_username": "invalid"}'::jsonb,
  'the payload is checked strictly by the owner check (no forged member)');
select is(pg_temp.sys('identity.assisted_reset_complete',
            jsonb_build_object('operation_id', gen_random_uuid(), 'auth_result', 'maybe')) -> 'field_errors',
  '{"auth_result": "invalid"}'::jsonb, 'auth_result is one of applied, rejected, unknown');

-- Requests (neutral) ------------------------------------------------------------------------------
create temp table r (k text primary key, v jsonb);
grant all on r to anon, authenticated;
insert into r values ('req_unknown', pg_temp.sys('identity.assisted_recovery_request',
  jsonb_build_object('phone_username', '+447700900499', 'grant_digest', pg_temp.dg(99, 'a'), 'client_key', pg_temp.ck(99))));
select ok((select (v -> 'data' ->> 'accepted')::boolean and v -> 'data' ->> 'request_code' ~ '^[A-HJ-NP-Z2-9]{8}$'
             from r where k = 'req_unknown'),
  'a request for a number without an account is answered like any other (neutral)');
select is((pg_temp.sys('identity.assisted_recovery_request',
            jsonb_build_object('phone_username', '+260971234567', 'grant_digest', pg_temp.dg(98, 'a'),
                               'client_key', pg_temp.ck(98))) -> 'data') - 'actor',
  '{"accepted": false, "reason": "unsupported"}'::jsonb, 'a real-looking number is refused while Q4 is unapproved');
select is((pg_temp.sys('identity.assisted_recovery_request',
            jsonb_build_object('phone_username', '+447700900498', 'grant_digest', pg_temp.dg(99, 'a'),
                               'client_key', pg_temp.ck(98))) -> 'data') - 'actor',
  '{"accepted": false, "reason": "invalid"}'::jsonb, 'a digest is accepted once');
select is((select count(*)::int from (select pg_temp.request(97, 'r' || i, '+447700900497') c
                                         from generate_series(1, 6) i) x where c is not null), 5,
  'at most 5 requests per number per hour (the sixth is refused)');
select is(pg_temp.sys('identity.assisted_recovery_status', jsonb_build_object('grant_digest', pg_temp.dg(99, 'a'))) -> 'data' ->> 'state',
  'waiting', 'status: waiting');
select is((pg_temp.sys('identity.assisted_recovery_status', jsonb_build_object('grant_digest', pg_temp.dg(96, 'x'))) -> 'data') - 'actor',
  '{"state": "closed"}'::jsonb, 'status of an unknown digest: closed');


-- Owner decision 2026-10-07: per-client limit (10 request + redeem attempts per 10 minutes) -----
select is((select count(*)::int from (select pg_temp.request(96, 'c' || i, '+44770090049' || (i % 3), pg_temp.ck(96)) c
                                         from generate_series(1, 10) i) x where c is not null), 10,
  'ten requests from one client (three numbers) are accepted');
select is((pg_temp.sys('identity.assisted_recovery_request',
            jsonb_build_object('phone_username', '+447700900493', 'grant_digest', pg_temp.dg(96, 'c11'),
                               'client_key', pg_temp.ck(96))) -> 'data') - 'actor',
  '{"accepted": false, "reason": "rate_limited"}'::jsonb,
  'the 11th attempt from the same client is limited, with the same neutral answer');
select ok(pg_temp.request(95, 'c1', '+447700900493', pg_temp.ck(95)) is not null,
  'a different client is not limited');
select is(pg_temp.begin_(2, 'zz', pg_temp.phone(2), pg_temp.ck(96)) - 'actor',
  '{"accepted": false, "reason": "rate_limited"}'::jsonb,
  'redeem attempts count against the same client limit');
select is((select count(*)::int from app.identity_recovery_client_attempts where client_key = pg_temp.ck(96)), 10,
  'a limited attempt is not recorded; only the client key is stored, never an IP');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_recovery_client_attempts'),
  array['at', 'attempt_id', 'attempt_kind', 'client_key'], 'the attempt table holds the key, kind and time only');

-- Admin: cases ----------------------------------------------------------------------------------
select is(pg_temp.cmd(pg_temp.c(2), 'identity.open_recovery_case', null,
            jsonb_build_object('member_id', pg_temp.mid(3), 'identity_check', 'in_person', 'evidence', '["photo_id"]'::jsonb)) ->> 'code',
  'forbidden', 'a member who is not an Admin cannot open a case');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.open_recovery_case', null,
            jsonb_build_object('member_id', pg_temp.mid(1), 'identity_check', 'in_person', 'evidence', '["photo_id"]'::jsonb)) -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'an Admin cannot open a case for themselves');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.open_recovery_case', null,
            jsonb_build_object('member_id', pg_temp.mid(2), 'evidence', '["password"]'::jsonb)) -> 'field_errors',
  '{"evidence": "invalid", "identity_check": "required"}'::jsonb, 'identity check and known evidence codes are required');
insert into r values ('open2', pg_temp.open_case(2));
select is((select v -> 'data' ->> 'case_state' from r where k = 'open2'), 'open', 'case opened');
select is((select v -> 'data' -> 'evidence' from r where k = 'open2'), '["known_in_person", "photo_id"]'::jsonb,
  'the evidence seen is recorded');
select is(pg_temp.open_case(2) -> 'field_errors', '{"member_id": "open_case"}'::jsonb, 'one open case per account');
select is(pg_temp.issue(2, 'AAAAAAAA') -> 'field_errors', '{"request_code": "unknown"}'::jsonb,
  'an unknown request code is refused');
select is(pg_temp.issue(2, (select v -> 'data' ->> 'request_code' from r where k = 'req_unknown')) -> 'field_errors',
  '{"request_code": "mismatch"}'::jsonb, 'a request from another number cannot be bound to this member');
insert into r values ('issue2', pg_temp.issue(2, pg_temp.request(2, 'a')));
select is((select v -> 'data' -> 'grant' ->> 'state' from r where k = 'issue2'), 'issued', 'grant issued');
select ok((select v::text from r where k = 'issue2') !~ pg_temp.dg(2, 'a')
          and (select v::text from r where k = 'issue2') !~ 'request_code'
          and (select v::text from r where k = 'issue2') !~ 'digest',
  'the staff answer carries no digest and no request code');
select is(pg_temp.sys('identity.assisted_recovery_status', jsonb_build_object('grant_digest', pg_temp.dg(2, 'a'))) -> 'data' ->> 'state',
  'ready', 'status: ready once a grant is issued');
select is((select grant_state || '|' || binding_revision || '|' || credential_generation || '|' || purpose
             from app.identity_recovery_grants g where g.member_id = pg_temp.mid(2)),
  'issued|1|' || (select credential_generation from app.identity_account_links where member_id = pg_temp.mid(2)) || '|password_setup',
  'the grant binds binding revision, generation and purpose');

-- Happy path ---------------------------------------------------------------------------------------
select is(pg_temp.begin_(2, 'a', pg_temp.phone(3)) -> 'accepted', 'false'::jsonb, 'wrong phone: rejected');
select is((select grant_state || ':' || end_reason from app.identity_recovery_grants where member_id = pg_temp.mid(2)),
  'burned:identifier_mismatch', 'a grant presented with another phone username is burned');
insert into r values ('issue2b', pg_temp.issue(2, pg_temp.request(2, 'b')));
insert into r values ('begin2', pg_temp.begin_(2, 'b'));
select is((select v -> 'accepted' from r where k = 'begin2'), 'true'::jsonb, 'a valid grant is accepted');
select is(pg_temp.begin_(2, 'b') -> 'accepted', 'false'::jsonb, 'the same grant is refused the second time (single use)');
select is(pg_temp.open_case(2) -> 'field_errors', '{"member_id": "open_case"}'::jsonb, 'still one case');
select is(pg_temp.issue(2, pg_temp.request(2, 'c')) -> 'field_errors', '{"case_id": "recovery_unresolved"}'::jsonb,
  'no overlapping grant while the operation is unresolved');
insert into r values ('disp2', pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin2')));
select is((select (v ->> 'proceed') || '|' || (v ->> 'auth_user_id') from r where k = 'disp2'),
  'true|' || pg_temp.u(2), 'dispatch lets the function call Auth Admin for the bound account only');
select is(pg_temp.open_holds(2), 'assisted_reset_operation', 'the account is held while the operation is in flight');
select is(pg_temp.summary(pg_temp.fresh(2)), 'PT403|forbidden|review_required', 'a sign-in during the operation is held');
select pg_temp.admin_apply(2);
insert into r values ('done2', pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin2'), 'applied'));
select is((select v ->> 'outcome' from r where k = 'done2'), 'succeeded', 'completion: succeeded');
select is(pg_temp.open_holds(2), '', 'the operation''s own hold is released');
select is((select case_state || ':' || outcome from app.identity_recovery_cases where member_id = pg_temp.mid(2)),
  'completed:reset_completed', 'the case records the outcome');
select is(pg_temp.summary(pg_temp.c(2)), 'PT401|unauthenticated|untrusted_session', 'the old session is gone');
select is(pg_temp.summary(pg_temp.fresh(2)), 'ok', 'a fresh password sign-in is granted');
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin2'), 'applied') ->> 'late', 'true',
  'a repeated completion is recorded as late and changes nothing');
select is(pg_temp.calls(2), 'access_hold_applied,access_hold_released,sessions_revoked',
  'lifecycle hooks: hold applied at dispatch, released and sessions revoked at success');
select is(app.identity_password_unreviewed((pg_temp.op(2)).link_id), false,
  'the assisted password counts as the member''s own reviewed reset');
select is(pg_temp.audit(2), 'case_opened,grant_issued,grant_burned:identifier_mismatch,grant_issued,operation_begun,grant_rejected:grant_consumed,operation_dispatched,operation_succeeded:applied,case_completed:reset_completed,late_outcome:applied',
  'the audit trail (codes only)');

-- Reissue supersedes -------------------------------------------------------------------------------
select pg_temp.ready(3, 'g1');
select pg_temp.issue(3, pg_temp.request(3, 'g2'));
select is(pg_temp.begin_(3, 'g1') -> 'accepted', 'false'::jsonb, 'an unused grant after reissue is rejected');
select is(pg_temp.begin_(3, 'g2') -> 'accepted', 'true'::jsonb, 'the reissued grant works');

-- Direct password change invalidates --------------------------------------------------------------
select pg_temp.ready(4, 'a');
update auth.users set encrypted_password = 'synthetic-2-9-direct' where id = pg_temp.u(4);
select is(pg_temp.begin_(4, 'a') -> 'accepted', 'false'::jsonb, 'a direct password change kills an issued grant');
select is((select grant_state || ':' || end_reason from app.identity_recovery_grants where member_id = pg_temp.mid(4)),
  'superseded:stale', 'recorded as stale');

-- Unlink invalidates --------------------------------------------------------------------------------
select pg_temp.ready(5, 'a');
update app.identity_account_links set link_state = 'ended', ended_at = now() where member_id = pg_temp.mid(5);
select is(pg_temp.begin_(5, 'a') -> 'accepted', 'false'::jsonb, 'an ended link kills the grant');

-- Cross-member: 7's grant presented with 6's phone ----------------------------------------------------
select pg_temp.ready(7, 'a');
select is(pg_temp.begin_(7, 'a', pg_temp.phone(6)) -> 'accepted', 'false'::jsonb, 'cross-member use is rejected');
select is(pg_temp.begin_(7, 'a') -> 'accepted', 'false'::jsonb, 'and the burned grant no longer works for its owner');
select is((select count(*)::int from app.identity_recovery_operations where member_id in (pg_temp.mid(6), pg_temp.mid(7))), 0,
  'no operation for either member');

-- Uncertain, late, relink blocked, reconcile, recover, release ----------------------------------------
select pg_temp.ready(8, 'a');
insert into r values ('begin8', pg_temp.begin_(8, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin8'));
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin8'), 'unknown') ->> 'outcome', 'uncertain',
  'a lost Auth response is uncertain');
select is(pg_temp.open_holds(8), 'assisted_reset_operation', 'uncertain keeps the account held');
select pg_temp.admin_apply(8);  -- the Auth call actually applied, late
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin8'), 'applied') -> 'late', 'true'::jsonb,
  'the late result is recorded only');
select is(pg_temp.open_holds(8), 'assisted_reset_operation', 'still held after the late apply');
select is(pg_temp.summary(pg_temp.fresh(8)), 'PT403|forbidden|review_required', 'a sign-in with whatever password is held');
update app.identity_account_links set link_state = 'ended', ended_at = now() where member_id = pg_temp.mid(8);
select throws_ok($$insert into app.identity_account_links (member_id, auth_user_id, approved_phone, approved_by)
                   values (pg_temp.mid(8), pg_temp.u(8), pg_temp.phone(8), 'pgtap')$$,
  'PCMD1', null, 'relinking is refused while the earlier reset is unresolved');
update app.identity_account_links set link_state = 'active', ended_at = null where member_id = pg_temp.mid(8);
select is(pg_temp.issue(8, pg_temp.request(8, 'b')) -> 'field_errors', '{"case_id": "recovery_unresolved"}'::jsonb,
  'no new grant while uncertain');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.cancel_recovery_case', (pg_temp.kase(8)).revision,
            jsonb_build_object('case_id', (pg_temp.kase(8)).case_id, 'reason', 'member_withdrew')) -> 'field_errors',
  '{"case_id": "recovery_unresolved"}'::jsonb, 'nor cancelling the case before reconciliation');
select pg_temp.session(pg_temp.u(8), gen_random_uuid(), interval '0 seconds');
insert into r values ('rec8', pg_temp.cmd(pg_temp.c(1), 'identity.reconcile_recovery_operation', (pg_temp.kase(8)).revision,
  jsonb_build_object('case_id', (pg_temp.kase(8)).case_id, 'identity_check', 'in_person')));
select is((select v -> 'data' -> 'operation' ->> 'state' from r where k = 'rec8'), 'reconciled', 'reconciled by an Admin');
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u(8)), 0, 'reconcile revoked every session');
select is(pg_temp.open_holds(8), 'assisted_reset_operation', 'the hold stays after reconciliation');
select is(pg_temp.ccmd(pg_temp.c(1), 'identity.release_hold', pg_temp.mrev(8),
            jsonb_build_object('member_id', pg_temp.mid(8), 'hold_id',
              (select hold_id from app.identity_holds where member_id = pg_temp.mid(8) and released_at is null),
              'identity_check', 'in_person')) -> 'field_errors',
  '{"hold_id": "password_reset_required"}'::jsonb, 'the hold cannot be released before a successful reset');
select pg_temp.issue(8, pg_temp.request(8, 'c'));
insert into r values ('begin8c', pg_temp.begin_(8, 'c'));
select is((select v -> 'accepted' from r where k = 'begin8c'), 'true'::jsonb, 'a new grant after reconciliation works');
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin8c'));
select pg_temp.admin_apply(8);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin8c'), 'applied') ->> 'outcome', 'succeeded',
  'the second operation succeeds');
select is(pg_temp.open_holds(8), 'assisted_reset_operation', 'the uncertain operation''s hold is not cleared by the reset');
select is(pg_temp.ccmd(pg_temp.c(1), 'identity.release_hold', pg_temp.mrev(8),
            jsonb_build_object('member_id', pg_temp.mid(8), 'hold_id',
              (select hold_id from app.identity_holds where member_id = pg_temp.mid(8) and released_at is null),
              'identity_check', 'in_person')) -> 'data' -> 'holds',
  '[]'::jsonb, 'an Admin may release it now: the member reset the password since');
select is(pg_temp.summary(pg_temp.fresh(8)), 'ok', 'and the member signs in with the new password');

-- Lost-device hold: assisted reset allowed, hold stays until released -----------------------------
select pg_temp.ccmd(pg_temp.c(1), 'identity.place_hold', pg_temp.mrev(9),
  jsonb_build_object('member_id', pg_temp.mid(9), 'reason_code', 'lost_device'));
select is(pg_temp.ccmd(pg_temp.c(1), 'identity.release_hold', pg_temp.mrev(9),
            jsonb_build_object('member_id', pg_temp.mid(9), 'hold_id',
              (select hold_id from app.identity_holds where member_id = pg_temp.mid(9) and released_at is null),
              'identity_check', 'in_person')) -> 'field_errors',
  '{"hold_id": "password_reset_required"}'::jsonb, 'a lost-device hold waits for a reset');
select pg_temp.ready(9, 'a');
insert into r values ('begin9', pg_temp.begin_(9, 'a'));
select is((select v -> 'accepted' from r where k = 'begin9'), 'true'::jsonb, 'assisted recovery works under a security hold');
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin9'));
select pg_temp.admin_apply(9);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin9'), 'applied') ->> 'outcome', 'succeeded',
  'reset succeeded');
select is(pg_temp.open_holds(9), 'lost_device', 'the reset never clears the lost-device hold');
select is(pg_temp.summary(pg_temp.fresh(9)), 'PT403|forbidden|review_required', 'still held after the reset');
select is(pg_temp.ccmd(pg_temp.c(1), 'identity.release_hold', pg_temp.mrev(9),
            jsonb_build_object('member_id', pg_temp.mid(9), 'hold_id',
              (select hold_id from app.identity_holds where member_id = pg_temp.mid(9) and released_at is null),
              'identity_check', 'in_person')) -> 'data' -> 'holds',
  '[]'::jsonb, 'an Admin releases it after the assisted reset (identity_member_reset_since)');

-- Dispute hold refuses ------------------------------------------------------------------------------
select pg_temp.ccmd(pg_temp.c(1), 'identity.place_hold', pg_temp.mrev(10),
  jsonb_build_object('member_id', pg_temp.mid(10), 'reason_code', 'ownership_dispute'));
select is(pg_temp.open_case(10) -> 'field_errors', '{"member_id": "disputed"}'::jsonb,
  'a disputed account gets no assisted recovery');

-- Obsolete at dispatch: a direct change between begin and dispatch -----------------------------------
select pg_temp.ready(11, 'a');
insert into r values ('begin11', pg_temp.begin_(11, 'a'));
update auth.users set encrypted_password = 'synthetic-2-9-between' where id = pg_temp.u(11);
select is(pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin11')) -> 'proceed', 'false'::jsonb,
  'a pending operation whose generation moved is fenced: no Auth call');
select is((pg_temp.op(11)).op_state, 'obsolete', 'and is obsolete');
select is(pg_temp.open_holds(11), '', 'no hold was placed (nothing external happened)');

-- Auth refused, nothing changed: failed ------------------------------------------------------------
select pg_temp.ready(12, 'a');
insert into r values ('begin12', pg_temp.begin_(12, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin12'));
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin12'), 'rejected') ->> 'outcome', 'failed',
  'Auth refused the password and nothing changed: failed');
select is(pg_temp.open_holds(12) || '|' || (pg_temp.kase(12)).case_state, '|open',
  'failed releases the own hold and keeps the case open for a new grant');
select is(pg_temp.begin_(12, 'a') -> 'accepted', 'false'::jsonb, 'the consumed grant stays used');

-- Expired --------------------------------------------------------------------------------------------
select pg_temp.ready(13, 'a');
update app.identity_recovery_grants set issued_at = issued_at - interval '1 hour', expires_at = clock_timestamp() - interval '1 second'
 where member_id = pg_temp.mid(13);
select is(pg_temp.begin_(13, 'a') -> 'accepted', 'false'::jsonb, 'an expired grant is rejected');

-- A session from before dispatch survives the Auth call: uncertain ------------------------------------
select pg_temp.ready(14, 'a');
insert into r values ('begin14', pg_temp.begin_(14, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin14'));
update auth.users set encrypted_password = 'synthetic-2-9-no-logout' where id = pg_temp.u(14);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin14'), 'applied') ->> 'outcome', 'uncertain',
  'a pre-dispatch session still alive makes the outcome uncertain');
select is(app.identity_password_unreviewed((pg_temp.op(14)).link_id), true,
  'and that password is not counted as the member''s reviewed reset');

-- Stuck: dispatched, never completed --------------------------------------------------------------------
select pg_temp.ready(15, 'a');
insert into r values ('begin15', pg_temp.begin_(15, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin15'));
update app.identity_recovery_operations set dispatched_at = dispatched_at - interval '5 minutes'
 where operation_id = (select (v ->> 'operation_id')::uuid from r where k = 'begin15');
select pg_temp.admin_apply(15);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin15'), 'applied') ->> 'outcome', 'uncertain',
  'a completion after the stuck limit is uncertain');

-- Pending, never dispatched: stale after the window; a new grant can then be issued ---------------------
select pg_temp.ready(16, 'a');
insert into r values ('begin16', pg_temp.begin_(16, 'a'));
update app.identity_recovery_operations set begun_at = begun_at - interval '2 minutes'
 where operation_id = (select (v ->> 'operation_id')::uuid from r where k = 'begin16');
select is(pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin16')) -> 'proceed', 'false'::jsonb,
  'a pending operation past the dispatch window can never be dispatched');
select is((pg_temp.issue(16, pg_temp.request(16, 'b')) -> 'data' -> 'grant' ->> 'state'), 'issued',
  'so it no longer blocks a new grant');


-- Review fix: cancel between begin and dispatch ----------------------------------------------------
select pg_temp.ready(17, 'a');
insert into r values ('begin17', pg_temp.begin_(17, 'a'));
select is(pg_temp.cmd(pg_temp.c(1), 'identity.cancel_recovery_case', (pg_temp.kase(17)).revision,
            jsonb_build_object('case_id', (pg_temp.kase(17)).case_id, 'reason', 'opened_in_error')) -> 'data' ->> 'case_state',
  'cancelled', 'a case can be cancelled after begin consumed the grant (operation still pending)');
select is((pg_temp.op(17)).op_state, 'obsolete', 'cancelling makes the pending operation obsolete');
select is(pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin17')) -> 'proceed', 'false'::jsonb,
  'dispatch after a cancel is refused: no Auth call');
select is((select encrypted_password from auth.users where id = pg_temp.u(17)) || '|' || pg_temp.open_holds(17),
  'synthetic-2-9-initial|', 'no password was applied and no hold was placed');
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin17'), 'applied') ->> 'late', 'true',
  'a completion for it is recorded as late only');

-- Review fix: deactivation after begin -------------------------------------------------------------
select pg_temp.ready(18, 'a');
insert into r values ('begin18', pg_temp.begin_(18, 'a'));
update app.identity_members set membership_state = 'deactivated' where member_id = pg_temp.mid(18);
select is(pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin18')) -> 'proceed', 'false'::jsonb,
  'a member deactivated after begin: dispatch refused');
select is((pg_temp.op(18)).op_state || '|' || (select encrypted_password from auth.users where id = pg_temp.u(18)),
  'obsolete|synthetic-2-9-initial', 'obsolete, and no password applied');

-- Review fix: deactivation during an open case ------------------------------------------------------
select pg_temp.open_case(19);
update app.identity_members set membership_state = 'deactivated' where member_id = pg_temp.mid(19);
select is(pg_temp.issue(19, pg_temp.request(19, 'a')) -> 'field_errors', '{"case_id": "not_approved"}'::jsonb,
  'no grant is issued for a deactivated member');

-- Review fix: binding revision moved after begin ------------------------------------------------------
select pg_temp.ready(20, 'a');
insert into r values ('begin20', pg_temp.begin_(20, 'a'));
select is((pg_temp.op(20)).binding_revision_at_begin, 1::bigint, 'begin records the binding revision');
select app.identity_record_binding((pg_temp.op(20)).link_id, pg_temp.phone(20), null, 'pgtap', 'pgtap_rebind');
select is(pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin20')) -> 'proceed', 'false'::jsonb,
  'a binding revision moved after begin: dispatch refused');

-- Review fix: a session opened after dispatch but before the password change ------------------------
select pg_temp.ready(21, 'a');
insert into r values ('begin21', pg_temp.begin_(21, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin21'));
delete from auth.sessions where user_id = pg_temp.u(21);
select pg_temp.session(pg_temp.u(21), gen_random_uuid(), interval '0 seconds');
update auth.users set encrypted_password = 'synthetic-2-9-after-session' where id = pg_temp.u(21);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin21'), 'applied') ->> 'outcome', 'uncertain',
  'a session created before the password change still alive: uncertain');
select is(pg_temp.open_holds(21), 'assisted_reset_operation', 'and the account stays held');

-- Review fix: deactivation after dispatch --------------------------------------------------------------
select pg_temp.ready(22, 'a');
insert into r values ('begin22', pg_temp.begin_(22, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin22'));
update app.identity_members set membership_state = 'deactivated' where member_id = pg_temp.mid(22);
select pg_temp.admin_apply(22);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin22'), 'applied') ->> 'outcome', 'uncertain',
  'a member deactivated while the Auth call ran: uncertain, never success');
select is(pg_temp.open_holds(22), 'assisted_reset_operation', 'the hold is kept');

-- Review fix: a case closed under a dispatched operation (defence in depth) ------------------------------
select pg_temp.ready(23, 'a');
insert into r values ('begin23', pg_temp.begin_(23, 'a'));
select pg_temp.dispatch((select v ->> 'operation_id' from r where k = 'begin23'));
update app.identity_recovery_cases set case_state = 'cancelled', outcome = 'cancelled', cancel_reason = 'opened_in_error',
       closed_at = clock_timestamp() where member_id = pg_temp.mid(23);
select pg_temp.admin_apply(23);
select is(pg_temp.complete((select v ->> 'operation_id' from r where k = 'begin23'), 'applied') ->> 'outcome', 'uncertain',
  'a cancelled case never gets success effects');
select is(pg_temp.open_holds(23) || '|' || app.identity_member_reset_since((pg_temp.op(23)).link_id, '-infinity'),
  'assisted_reset_operation|false', 'the hold is kept and no reset evidence is recorded');

-- Admin read ---------------------------------------------------------------------------------------------
insert into r values ('cases', substr(pg_temp.read(pg_temp.c(1), 'select api.identity_admin_recovery_cases()'), 4)::jsonb);
select ok((select jsonb_array_length(v -> 'cases') from r where k = 'cases') >= 13, 'the Admin sees the cases');
select ok((select v::text from r where k = 'cases') !~ '[0-9a-f]{64}'
          and (select v::text from r where k = 'cases') !~ 'request_code'
          and (select v::text from r where k = 'cases') !~ 'arg_',
  'the Admin read has no digest, request code or secret');
select is((select c -> 'operation' ->> 'state' from r, jsonb_array_elements(v -> 'cases') c
            where k = 'cases' and (c ->> 'member_id')::uuid = pg_temp.mid(14)),
  'uncertain', 'an uncertain operation is shown for reconciliation');
select is(pg_temp.read(pg_temp.fresh(2), 'select api.identity_admin_recovery_cases()'), 'PT403|forbidden|not_granted',
  'a member who is not an Admin cannot read the cases');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.cancel_recovery_case', (pg_temp.kase(3)).revision,
            jsonb_build_object('case_id', (pg_temp.kase(3)).case_id, 'reason', 'opened_in_error')) -> 'data' ->> 'case_state',
  'cancelled', 'an open case without an unresolved operation can be cancelled');

-- Sys audit: recovery steps are attributed to the principal ---------------------------------------------
select ok((select count(*) from app.sys_audit a where a.command like 'identity.assisted_%'
             and a.system_principal_id = (select v from t_ids where k = 'principal') and a.outcome = 'succeeded') > 20,
  'every recovery step is in the system audit under the recovery principal');
select ok(not exists (select 1 from app.identity_recovery_audit a where a.actor_kind = 'system'
                        and a.system_principal_id is distinct from (select v from t_ids where k = 'principal')),
  'system recovery events name the executing principal');

select * from finish();
rollback;
