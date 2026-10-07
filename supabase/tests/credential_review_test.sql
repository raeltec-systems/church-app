-- Change credentials under review and hold access (story 2.8; AD-3, AD-4, AD-14, AD-20, AC-05).
-- Reviewed phone-username and recovery-email changes applied to Auth server-side by an Admin
-- decision; holds (dispute, security, lost device) with identity-checked release by another
-- Admin; restore/accept of an account in credential review; the generic own read and the Admin
-- queue. HTTP evidence through real GoTrue: tools/identity-e2e/credentials.mjs. Every account,
-- phone and email here is SYNTHETIC (+44 7700 900300-900329, @example.test).
begin;
select plan(125);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000028' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000028' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (300 + n)::text $$;
create function pg_temp.mail(n int) returns text language sql as
$$ select 'synthetic-2-8-' || n || '@example.test' $$;

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

create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password',
                                p_age interval default interval '1 hour',
                                p_amr_age interval default interval '0 seconds')
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - p_age);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now() - p_amr_age, now() - p_amr_age, p_method);
  select p_session;
$$;
-- A fresh password session of account n, opened after every epoch so far (sign in again).
create function pg_temp.fresh(n int, p_method text default 'password') returns jsonb
language plpgsql as $$
declare
  v_session uuid := gen_random_uuid();
begin
  perform pg_temp.session(pg_temp.u(n), v_session, p_method, interval '-1 minute');
  return pg_temp.claims(pg_temp.u(n), v_session, p_method);
end;
$$;
-- A session opened NOW (not after a later epoch).
create function pg_temp.now_session(n int) returns jsonb
language plpgsql as $$
declare
  v_session uuid := gen_random_uuid();
begin
  perform pg_temp.session(pg_temp.u(n), v_session, 'password', interval '0 seconds');
  return pg_temp.claims(pg_temp.u(n), v_session);
end;
$$;

create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  select api.identity_credential_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', p_request,
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.request(p_claims jsonb, p_payload jsonb) returns jsonb language sql as
$$ select pg_temp.cmd(p_claims, 'identity.request_credential_change', null, p_payload) $$;

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

create function pg_temp.change(n int) returns app.identity_credential_changes language sql as $$
  select c.* from app.identity_credential_changes c
   where c.auth_user_id = pg_temp.u(n) order by c.requested_at desc limit 1
$$;
create function pg_temp.link(n int) returns app.identity_account_links language sql as $$
  select l.* from app.identity_account_links l
   where l.auth_user_id = pg_temp.u(n) and l.link_state <> 'ended'
$$;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.decide(p_command text, n int, p_payload jsonb default '{}') returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), p_command, (pg_temp.change(n)).revision,
                     jsonb_build_object('change_id', (pg_temp.change(n)).change_id) || p_payload)
$$;
create function pg_temp.on_member(p_command text, n int, p_payload jsonb default '{}',
                                  p_claims jsonb default null) returns jsonb
language sql as $$
  select pg_temp.cmd(coalesce(p_claims, pg_temp.c(1)), p_command, pg_temp.mrev(n),
                     jsonb_build_object('member_id', pg_temp.mid(n)) || p_payload)
$$;
create function pg_temp.open_hold(n int) returns app.identity_holds language sql as $$
  select h.* from app.identity_holds h
   where h.member_id = pg_temp.mid(n) and h.released_at is null order by h.placed_at desc limit 1
$$;
create function pg_temp.redeem(p_user uuid) returns text language plpgsql as $$
begin
  update auth.users set recovery_token = 'synthetic-2-8-token-' || p_user where id = p_user;
  begin
    update auth.users set recovery_token = '' where id = p_user;
    return 'ok';
  exception when others then
    return sqlstate || '|' || sqlerrm;
  end;
end;
$$;
create function pg_temp.auth_row(n int) returns text language sql as $$
  select row(coalesce(u.phone, ''), coalesce(u.email, ''), u.email_confirmed_at is not null)::text
    from auth.users u where u.id = pg_temp.u(n)
$$;

-- Accounts: 1 Admin A; 2 phone change approved; 3 phone change rejected and withdrawn; 4 email
-- replaced (approved); 5 email replacement withdrawn; 6 email removed; 7 disputed (hold), direct
-- changes and reset during the hold, restored; 8 lost device; 9 stolen-session email change,
-- restored; 10 MFA factor, restored; 11 phone changed in Auth, accepted; 12 unlinked account;
-- 13 requests a number someone else takes; 14 unlinked holder of a number; 15 old sign-in;
-- 16 reset link issued before a restore; 17 reset link before a 2.7 reject; 18 password changed
-- by a "thief" before a restore.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 18) n;
update auth.users u set email = pg_temp.mail(x.n), email_confirmed_at = now()
  from (values (4), (5), (6), (7), (8), (16), (18)) x(n) where u.id = pg_temp.u(x.n);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 18) n where n <> 15;
select pg_temp.session(pg_temp.u(15), pg_temp.s(15), 'password', interval '1 hour', interval '20 minutes');

-- Structure and privileges ---------------------------------------------------------------------
select ok((select count(*) from information_schema.tables where table_schema = 'app'
            and table_name in ('identity_credential_changes', 'identity_credential_review_audit')) = 2,
  'change and review audit tables exist');
select ok(not exists (
  select 1 from unnest(array['app.identity_credential_changes', 'app.identity_credential_review_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, 'app.identity_credential_review_audit_event_id_seq', p)),
  'no client role has any privilege on the new tables or the audit sequence');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_credential_review_audit'),
  array['action', 'actor_account_id', 'actor_member_id', 'binding_revision_after', 'change_id',
        'change_kind', 'environment', 'event_id', 'hold_id', 'hold_kind', 'identity_check',
        'link_id', 'member_id', 'occurred_at', 'reason_code', 'request_id', 'revision_after',
        'sessions_revoked'],
  'the review audit holds ids, codes and revisions only (never a number or an address)');
select ok(not has_function_privilege('anon', 'api.identity_credential_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_my_credentials()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_credential_queue()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_revoke_auth_sessions(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.identity_remove_auth_extras(uuid, text)', 'EXECUTE'),
  'signed-out callers cannot execute the command or reads; nobody can call the Auth row helpers');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok((select prosrc from pg_proc where oid = 'app.identity_revoke_auth_sessions(uuid)'::regprocedure)
            not like '%not installed%'
          and (select prosrc from pg_proc where oid = 'app.identity_remove_auth_extras(uuid, text)'::regprocedure)
            not like '%not installed%',
  'the follow-up migration replaced the fail-closed Auth row stubs');
select ok(exists (select 1 from pg_trigger t where t.tgrelid = 'app.identity_holds'::regclass
                    and t.tgname = 'identity_hold_release_epoch'),
  'releasing a hold has its epoch trigger');

-- Environment, members and the SYNTHETIC lifecycle hook --------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.8');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.8 Member ' || n, 'pgtap 2.8') as member_id
  from generate_series(1, 18) n where n not in (12, 14);
grant select on m to authenticated;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
select app.contract_register_lifecycle_hook('fixture', 'access_hold_applied', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
select app.contract_register_lifecycle_hook('fixture', 'access_hold_released', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
select app.contract_register_lifecycle_hook('fixture', 'sessions_revoked', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
create function app.fixture_fail_lifecycle(p_event jsonb) returns void language plpgsql set search_path = '' as $$
begin
  raise exception 'SYNTHETIC failing device-registration hook';
end;
$$;
create function pg_temp.hook(p_event text, p_handler text) returns void language sql as $$
  update app.contract_lifecycle_hooks set handler = p_handler where event = p_event and module = 'fixture'
$$;
create function pg_temp.calls(n int) returns text language sql as $$
  select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls
   where member_id = pg_temp.mid(n)
$$;
-- A reset (or magic) link GoTrue issued: the token on the user and in one_time_tokens.
create function pg_temp.issue_reset(n int) returns void language sql as $$
  update auth.users set recovery_token = 'synthetic-2-8-rt-' || n, recovery_sent_at = now()
   where id = pg_temp.u(n);
  insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to)
  values (gen_random_uuid(), pg_temp.u(n), 'recovery_token', 'synthetic-2-8-rt-' || n, 'synthetic');
$$;
-- Redeeming THAT link: GoTrue finds the user by the token and clears it (the 2.7 gate fires).
create function pg_temp.redeem_issued(n int) returns text language plpgsql as $$
declare
  v_rows int;
begin
  update auth.users set recovery_token = '' where id = pg_temp.u(n)
     and recovery_token = 'synthetic-2-8-rt-' || n;
  get diagnostics v_rows = row_count;
  return case when v_rows = 0 then 'no such link' else 'redeemed' end
         || '|' || (select count(*) from auth.one_time_tokens
                     where user_id = pg_temp.u(n) and token_hash = 'synthetic-2-8-rt-' || n);
exception when others then
  return sqlstate || '|' || sqlerrm;
end;
$$;
create function pg_temp.rcmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', p_claims::text, true);
  set local role authenticated;
  select api.identity_recovery_email_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;

-- Requesting a change (member) ------------------------------------------------------------------
select is(pg_temp.request(pg_temp.c(15), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(25))) -> 'field_errors',
  '{"session": "reauthenticate"}'::jsonb, 'a password sign-in older than 10 minutes must sign in again');
select is(pg_temp.request(pg_temp.c(12), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(25))) ->> 'code',
  'forbidden', 'an unlinked account cannot request a credential change');
select is(pg_temp.request(pg_temp.fresh(3, 'otp'), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(25))) ->> 'code',
  'unauthenticated', 'an email-link (otp) session cannot request');
select is(pg_temp.request(pg_temp.c(3), '{"change_kind": "password"}') -> 'field_errors',
  '{"change_kind": "invalid"}'::jsonb, 'only the three reviewed kinds exist');
select is(pg_temp.request(pg_temp.c(3), '{"change_kind": "phone_username", "phone_username": "0977 000 000"}') -> 'field_errors',
  '{"phone_username": "invalid"}'::jsonb, 'the new username must be E.164');
select is(pg_temp.request(pg_temp.c(3), '{"change_kind": "phone_username", "phone_username": "+260970000301"}') -> 'field_errors',
  '{"phone_username": "out_of_range"}'::jsonb, 'while Q4 is unapproved only fictional numbers are accepted');
select is(pg_temp.request(pg_temp.c(3), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(25), 'email', 'x@example.test')) -> 'field_errors',
  '{"email": "unknown_field"}'::jsonb, 'fields of another kind are refused');
select is(pg_temp.request(pg_temp.c(3), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(3))) -> 'field_errors',
  '{"phone_username": "unchanged"}'::jsonb, 'the same username is not a change');
select is(pg_temp.request(pg_temp.c(13), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(14))) -> 'field_errors',
  '{"phone_username": "unavailable"}'::jsonb, 'a number held by another account is never taken over');
select is(pg_temp.request(pg_temp.c(3), '{"change_kind": "recovery_email_remove"}') -> 'field_errors',
  '{"change_kind": "no_recovery_email"}'::jsonb, 'removing needs an approved recovery email');
select is(pg_temp.request(pg_temp.c(4), '{"change_kind": "recovery_email_replace", "email": "someone@gmail.com"}') -> 'field_errors',
  '{"email": "unsupported"}'::jsonb, 'while Q4 is unapproved a real-looking address is refused');

-- Phone username change, approved ---------------------------------------------------------------
select is(pg_temp.request(pg_temp.c(2), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(20))) #>> '{data,state}',
  'pending', 'a granted member with a fresh password sign-in requests a new username');
select is(pg_temp.auth_row(2) || '|' || pg_temp.summary(pg_temp.c(2)), '(447700900302,"",f)|ok',
  'until approved, Auth and access are unchanged');
select is(pg_temp.request(pg_temp.c(2), jsonb_build_object('change_kind', 'phone_username',
            'phone_username', pg_temp.phone(21))) -> 'field_errors',
  '{"change_id": "pending"}'::jsonb, 'one pending change per account');
select is(pg_temp.readj(pg_temp.c(2), $$select api.identity_recovery_email_command(jsonb_build_object(
            'version', 1, 'command', 'identity.propose_recovery_email', 'request_id', gen_random_uuid(),
            'expected_revision', null, 'payload', jsonb_build_object('email', 'synthetic-2-8-2@example.test')))$$)
            - 'message' - 'request_id',
  '{"code": "conflict", "field_errors": {"email": "pending_change"}}'::jsonb,
  'nor a 2.7 recovery-email proposal beside it');
select is(pg_temp.cmd(pg_temp.c(3), 'identity.approve_credential_change', (pg_temp.change(2)).revision,
            jsonb_build_object('change_id', (pg_temp.change(2)).change_id, 'identity_check', 'in_person')) ->> 'code',
  'forbidden', 'a member cannot approve a change');
select is(pg_temp.decide('identity.approve_credential_change', 2) -> 'field_errors',
  '{"identity_check": "required"}'::jsonb, 'approval needs a recorded identity check');
select is(pg_temp.decide('identity.approve_credential_change', 2, '{"identity_check": "in_person"}') #>> '{data,state}',
  'approved', 'an Admin approves the new username after an identity check');
select is(pg_temp.auth_row(2), '(447700900320,"",f)',
  'Identity changed the Auth phone server-side (no SMS, no OTP)');
select is((select row(l.approved_phone, l.binding_revision, l.link_state, l.binding_review_required)::text
             from app.identity_account_links l where l.auth_user_id = pg_temp.u(2) and l.link_state <> 'ended'),
  '(+447700900320,2,active,f)', 'the binding has revision 2 with the new username; no review left');
select is((select reason from app.identity_binding_history h where h.link_id = (pg_temp.link(2)).link_id
             and h.binding_revision = 2), 'phone_username_changed', 'binding history records it');
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u(2)) || '|' || pg_temp.summary(pg_temp.c(2)),
  '0|PT401|unauthenticated|untrusted_session', 'every session of the account was revoked');
select is(pg_temp.readj(pg_temp.fresh(2), 'select api.identity_my_member_summary()') ->> 'phone_username',
  '+447700900320', 'a fresh sign-in with the new username is granted');
select is((select row(a.identity_check, a.binding_revision_after, a.sessions_revoked, a.change_kind)::text
             from app.identity_credential_review_audit a
            where a.action = 'credential_change_approved' and a.member_id = pg_temp.mid(2)),
  '(in_person,2,1,phone_username)', 'the approval is audited with the check and the revoked sessions');
select is(pg_temp.calls(2), 'sessions_revoked', 'device-registration owners hear of the revoked sessions (same transaction)');

-- Rejected, withdrawn, taken, self, held -----------------------------------------------------------
select pg_temp.request(pg_temp.c(3), jsonb_build_object('change_kind', 'phone_username', 'phone_username', pg_temp.phone(21)));
select pg_temp.on_member('identity.place_hold', 3, '{"reason_code": "ownership_dispute"}');
select is(pg_temp.decide('identity.approve_credential_change', 3, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"member_id": "held"}'::jsonb, 'no change is approved while a hold is open');
select is(pg_temp.on_member('identity.accept_credentials', 3, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"member_id": "held"}'::jsonb, 'nor are current credentials accepted');
select is(pg_temp.cmd(pg_temp.c(3), 'identity.withdraw_credential_change', (pg_temp.change(3)).revision,
            jsonb_build_object('change_id', (pg_temp.change(3)).change_id)) ->> 'code',
  'forbidden', 'and the member cannot withdraw while held');
select pg_temp.on_member('identity.release_hold', 3, jsonb_build_object('hold_id', (pg_temp.open_hold(3)).hold_id, 'identity_check', 'in_person'));
select is(pg_temp.decide('identity.reject_credential_change', 3, '{"reason": "contact_church_office"}') #>> '{data,state}',
  'rejected', 'an Admin rejects a change');
select is(pg_temp.auth_row(3) || '|' || pg_temp.summary(pg_temp.fresh(3)), '(447700900303,"",f)|ok',
  'a rejected username change leaves Auth and access as they were');
select pg_temp.request(pg_temp.fresh(3), jsonb_build_object('change_kind', 'phone_username', 'phone_username', pg_temp.phone(21)));
select is(pg_temp.cmd(pg_temp.fresh(2), 'identity.withdraw_credential_change', (pg_temp.change(3)).revision,
            jsonb_build_object('change_id', (pg_temp.change(3)).change_id)) ->> 'code',
  'not_found', 'another account''s change is not found');
select is(pg_temp.cmd(pg_temp.fresh(3), 'identity.withdraw_credential_change', (pg_temp.change(3)).revision,
            jsonb_build_object('change_id', (pg_temp.change(3)).change_id)) #>> '{data,state}',
  'withdrawn', 'the member withdraws their own pending change');
select pg_temp.request(pg_temp.c(13), jsonb_build_object('change_kind', 'phone_username', 'phone_username', pg_temp.phone(22)));
update auth.users set phone = ltrim(pg_temp.phone(22), '+') where id = pg_temp.u(14);
select is(pg_temp.decide('identity.approve_credential_change', 13, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"phone_username": "taken"}'::jsonb, 'a number another account took meanwhile is never overwritten');
select is(pg_temp.on_member('identity.restore_credentials', 13, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"member_id": "pending_change"}'::jsonb, 'a credential review waits for the pending change to be decided');
select pg_temp.decide('identity.reject_credential_change', 13);
select pg_temp.request(pg_temp.fresh(1), jsonb_build_object('change_kind', 'phone_username', 'phone_username', pg_temp.phone(23)));
select is(pg_temp.decide('identity.approve_credential_change', 1, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"change_id": "unsupported"}'::jsonb, 'an Admin cannot approve a change to their own account');
select pg_temp.cmd(pg_temp.c(1), 'identity.withdraw_credential_change', (pg_temp.change(1)).revision,
  jsonb_build_object('change_id', (pg_temp.change(1)).change_id));

-- Recovery email replaced (approved) ------------------------------------------------------------
select is(pg_temp.request(pg_temp.c(4), jsonb_build_object('change_kind', 'recovery_email_replace',
            'email', 'Synthetic-2-8-4-New@Example.TEST')) #>> '{data,email}',
  'synthetic-2-8-4-new@example.test', 'a replacement address is stored lower-case');
select is(pg_temp.auth_row(4) || '|' || pg_temp.summary(pg_temp.c(4)), '(447700900304,"",f)|PT403|forbidden|review_required',
  'the old address leaves Auth at once and the account waits in access review');
select is(pg_temp.readj(pg_temp.c(4), 'select api.identity_my_credentials()')
            #- '{pending_change,change_id}',
  '{"access": "review_required", "church_contact": null, "pending_recovery_email": null,
    "pending_change": {"state": "pending", "revision": 1, "change_kind": "recovery_email_replace"}}'::jsonb,
  'in review the own read carries only access, the contact and the own request id/state (no phone, no address, no reason)');
select is(pg_temp.readj(pg_temp.c(4), 'select api.identity_my_recovery_email()') - 'recent_sign_in_minutes',
  '{"access": "review_required", "proposal": null, "can_propose": false, "approved_email": null}'::jsonb,
  'the 2.7 own read carries no approved address while in review either');
select is(pg_temp.decide('identity.approve_credential_change', 4, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"recovery_email": "unverified"}'::jsonb, 'an unconfirmed new address cannot be approved');
update auth.users set email = 'synthetic-2-8-4-new@example.test', email_confirmed_at = now() where id = pg_temp.u(4);
select is(pg_temp.summary(pg_temp.fresh(4)), 'PT403|forbidden|review_required',
  'confirming the new address (email verification) approves nothing');
select is(pg_temp.redeem(pg_temp.u(4)), '42501|email link not accepted',
  'and the new address cannot reset the password before approval');
select is(pg_temp.decide('identity.approve_credential_change', 4, '{"identity_check": "established_relationship"}') #>> '{data,state}',
  'approved', 'the Admin approves the confirmed replacement');
select is((select row(l.approved_recovery_email, l.binding_revision, l.link_state)::text
             from app.identity_account_links l where l.link_id = (pg_temp.link(4)).link_id),
  '(synthetic-2-8-4-new@example.test,2,active)', 'the binding holds the new address');
select is(pg_temp.summary(pg_temp.fresh(4)) || '|' || pg_temp.redeem(pg_temp.u(4)), 'ok|ok',
  'a fresh sign-in is granted, and the new address can reset the password');

-- Replacement withdrawn: the approved address returns ----------------------------------------------
select pg_temp.issue_reset(5);
select pg_temp.request(pg_temp.c(5), jsonb_build_object('change_kind', 'recovery_email_replace', 'email', 'synthetic-2-8-5-new@example.test'));
update auth.users set email_change = 'synthetic-2-8-5-new@example.test', email_change_token_new = 'synthetic-2-8-tok-5',
                      email_change_sent_at = now() where id = pg_temp.u(5);
select is(pg_temp.cmd(pg_temp.c(5), 'identity.withdraw_credential_change', (pg_temp.change(5)).revision,
            jsonb_build_object('change_id', (pg_temp.change(5)).change_id)) #>> '{data,state}',
  'withdrawn', 'the member withdraws the replacement from the review state');
select is(pg_temp.auth_row(5) || '|' || (select coalesce(email_change, '') from auth.users where id = pg_temp.u(5)),
  '(447700900305,synthetic-2-8-5@example.test,t)|', 'the approved address is back, confirmed; the pending change is gone');
select is((select row(l.binding_revision, l.link_state, l.binding_review_required)::text
             from app.identity_account_links l where l.link_id = (pg_temp.link(5)).link_id)
          || '|' || pg_temp.summary(pg_temp.fresh(5)),
  '(2,active,f)|ok', 'the review is lifted with a new binding revision; a fresh sign-in is granted');
select is(pg_temp.redeem_issued(5), 'no such link|0',
  'a reset link issued before the replacement can never be redeemed after the revert');

-- Recovery email removed ---------------------------------------------------------------------------
select pg_temp.request(pg_temp.c(6), '{"change_kind": "recovery_email_remove"}');
select is(pg_temp.summary(pg_temp.c(6)), 'ok', 'a removal request leaves access as it is until approved');
select is(pg_temp.decide('identity.approve_credential_change', 6, '{"identity_check": "in_person"}') #>> '{data,state}',
  'approved', 'the Admin approves the removal');
select is(pg_temp.auth_row(6) || '|' || coalesce((pg_temp.link(6)).approved_recovery_email, 'none'),
  '(447700900306,"",f)|none', 'the address left Auth and the binding');
select is(pg_temp.summary(pg_temp.fresh(6)) || '|' || pg_temp.redeem(pg_temp.u(6)), 'ok|42501|email link not accepted',
  'a fresh sign-in is granted; no reset link works any more');

-- Holds: dispute ---------------------------------------------------------------------------------------
select is(pg_temp.on_member('identity.place_hold', 7) -> 'field_errors', '{"reason_code": "required"}'::jsonb,
  'a hold needs a reason code');
select is(pg_temp.on_member('identity.place_hold', 6, '{"reason_code": "ownership_dispute"}', pg_temp.c(7)) ->> 'code',
  'forbidden', 'a member cannot place a hold');
select is(pg_temp.on_member('identity.place_hold', 1, '{"reason_code": "security_concern"}') -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'an Admin cannot hold their own member record');
select is(pg_temp.on_member('identity.place_hold', 7, '{"reason_code": "ownership_dispute"}') #>> '{data,holds,0,hold_kind}',
  'access_review', 'an accepted ownership dispute holds the account for access review');
select is(pg_temp.summary(pg_temp.c(7)), 'PT403|forbidden|review_required',
  'the existing session sees only access review (help screen), not private data');
select is(pg_temp.readj(pg_temp.c(7), 'select api.identity_my_credentials()') ->> 'access', 'review_required',
  'the member''s own read answers in review, generically');
select ok(not (pg_temp.readj(pg_temp.c(7), 'select api.identity_my_credentials()') ?| array['hold', 'holds', 'reason', 'reason_code']),
  'and never says why');
select is((select string_agg(event, ',' order by call_id) from app.fixture_lifecycle_calls where member_id = pg_temp.mid(7)),
  'access_hold_applied', 'the registered hook received access_hold_applied');
select is(pg_temp.on_member('identity.place_hold', 7, '{"reason_code": "ownership_dispute"}') -> 'field_errors',
  '{"reason_code": "already_held"}'::jsonb, 'the same hold twice is a conflict');
-- Nothing but an authorised release clears it: a reset, a login, a direct Auth change.
select is(pg_temp.redeem(pg_temp.u(7)), 'ok', 'a hold does not block an email reset');
update auth.users set encrypted_password = 'synthetic-2-8-new-hash' where id = pg_temp.u(7);
select is(pg_temp.summary(pg_temp.fresh(7)), 'PT403|forbidden|review_required',
  'after a reset and a fresh login the hold still answers review');
update auth.users set email = 'synthetic-2-8-7-direct@example.test', email_confirmed_at = now() where id = pg_temp.u(7);
select is((select count(*)::int from app.identity_holds where member_id = pg_temp.mid(7) and released_at is null)
          || '|' || (pg_temp.link(7)).binding_review_required::text,
  '1|true', 'a direct Auth change neither clears the hold nor approves anything');
select is(pg_temp.on_member('identity.release_hold', 7, jsonb_build_object('hold_id', (pg_temp.open_hold(7)).hold_id)) -> 'field_errors',
  '{"identity_check": "required"}'::jsonb, 'releasing needs a recorded identity check');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.release_hold', pg_temp.mrev(7) - 1,
            jsonb_build_object('member_id', pg_temp.mid(7), 'hold_id', (pg_temp.open_hold(7)).hold_id,
                               'identity_check', 'in_person')) ->> 'code',
  'conflict', 'a stale member revision is a conflict');
create temp table during_hold as select pg_temp.now_session(7) as claims;
grant select on during_hold to authenticated;
select is(jsonb_array_length(pg_temp.on_member('identity.release_hold', 7, jsonb_build_object(
            'hold_id', (pg_temp.open_hold(7)).hold_id, 'identity_check', 'in_person')) #> '{data,holds}'),
  0, 'another Admin releases the hold after an identity check');
select is((select string_agg(event, ',' order by call_id) from app.fixture_lifecycle_calls where member_id = pg_temp.mid(7)),
  'access_hold_applied,access_hold_released', 'the hook received access_hold_released');
select is(pg_temp.summary(pg_temp.fresh(7)), 'PT403|forbidden|review_required',
  'releasing the hold does not approve the direct Auth change: still in review');

-- Credential review: restore (the stolen-session / other-changes exit) ----------------------------------
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
values (gen_random_uuid(), pg_temp.u(7), 'email', pg_temp.u(7)::text,
        jsonb_build_object('sub', pg_temp.u(7), 'email', 'synthetic-2-8-7-direct@example.test'), now(), now());
select is(pg_temp.on_member('identity.restore_credentials', 7, '{"identity_check": "in_person"}') #>> '{data,account}',
  'app_account', 'an Admin restores the account to its approved binding');
select is(pg_temp.auth_row(7) || '|' || (select count(*) from auth.identities where user_id = pg_temp.u(7) and provider = 'email'),
  '(447700900307,synthetic-2-8-7@example.test,t)|0', 'the approved address is back and the unapproved identity is gone');
select is(pg_temp.summary((select claims from during_hold)), 'PT401|unauthenticated|untrusted_session',
  'a session opened during the hold must sign in again');
select is(pg_temp.summary(pg_temp.fresh(7)), 'ok', 'a fresh sign-in is granted');

-- Lost device -----------------------------------------------------------------------------------------
select pg_temp.session(pg_temp.u(8), gen_random_uuid());
insert into auth.refresh_tokens (token, user_id, session_id, revoked)
values ('synthetic-2-8-refresh-8', pg_temp.u(8)::text, pg_temp.s(8), false);
select pg_temp.hook('sessions_revoked', 'app.fixture_fail_lifecycle(jsonb)');
select is(pg_temp.on_member('identity.place_hold', 8, '{"reason_code": "lost_device"}') ->> 'code', 'unavailable',
  'a raising device-registration hook fails the lost-device hold');
select is((select count(*)::int from app.identity_holds where member_id = pg_temp.mid(8))
          || '|' || (select count(*)::int from auth.sessions where user_id = pg_temp.u(8)),
  '0|2', 'and rolls it back: no hold, sessions intact');
select pg_temp.hook('sessions_revoked', 'app.fixture_record_lifecycle(jsonb)');
select is(pg_temp.on_member('identity.place_hold', 8, '{"reason_code": "lost_device"}') #>> '{data,holds,0,hold_kind}',
  'security', 'a lost device is a security hold');
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u(8)) || '|' || (pg_temp.open_hold(8)).sessions_revoked
          || '|' || (select count(*)::int from auth.refresh_tokens where user_id = pg_temp.u(8)::text)
          || '|' || pg_temp.summary(pg_temp.c(8)),
  '0|2|0|PT401|unauthenticated|untrusted_session', 'every session and refresh token of the account is revoked at once');
select is((select string_agg(event || ':' || (xact_id = pg_current_xact_id())::text, ',' order by call_id) from app.fixture_lifecycle_calls
            where member_id = pg_temp.mid(8)), 'access_hold_applied:true,sessions_revoked:true',
  'the device-registration hooks ran in the same transaction');
create temp table new_device as select pg_temp.now_session(8) as claims;
grant select on new_device to authenticated;
select is(pg_temp.summary((select claims from new_device)), 'PT403|forbidden|review_required',
  'a new sign-in during the hold reaches only access review');
select is(pg_temp.on_member('identity.release_hold', 8, jsonb_build_object('hold_id', (pg_temp.open_hold(8)).hold_id,
            'identity_check', 'established_relationship')) -> 'field_errors',
  '{"hold_id": "password_reset_required"}'::jsonb, 'a lost-device hold stays until the member resets the password');
-- The member resets through the approved email (holds do not block the reset), then a new password.
select pg_temp.redeem(pg_temp.u(8)) is not null as redeemed;
update auth.users set encrypted_password = 'synthetic-2-8-member-8-hash' where id = pg_temp.u(8);
select is(pg_temp.on_member('identity.release_hold', 8, jsonb_build_object('hold_id', (pg_temp.open_hold(8)).hold_id,
            'identity_check', 'established_relationship')) #>> '{data,account}',
  'app_account', 'after the member''s own reset another Admin releases it');
select is(pg_temp.summary((select claims from new_device)) || '|' || pg_temp.summary(pg_temp.fresh(8)),
  'PT401|unauthenticated|untrusted_session|ok', 'after release the hold-time session must sign in again; a fresh one is granted');
select is((select string_agg(action || ':' || coalesce(reason_code, '-') || ':' || coalesce(sessions_revoked::text, '-'), ',' order by event_id)
             from app.identity_credential_review_audit where member_id = pg_temp.mid(8)),
  'hold_placed:lost_device:2,hold_released:lost_device:-', 'holds are audited by code with the revoked sessions');

-- Stolen-session email change, restored ---------------------------------------------------------------
update auth.users set email = 'synthetic-2-8-thief@example.test', email_confirmed_at = now() where id = pg_temp.u(9);
select is(pg_temp.summary(pg_temp.c(9)), 'PT403|forbidden|review_required',
  'a direct email change from a stolen session puts the account in review');
select is(pg_temp.request(pg_temp.c(9), '{"change_kind": "recovery_email_remove"}') ->> 'code', 'forbidden',
  'no member request while in review');
select is(jsonb_path_query_first(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_credential_queue()'),
            '$.reviews[*] ? (@.member_id == $m)', jsonb_build_object('m', pg_temp.mid(9)))
            - 'member_id' - 'display_name' - 'member_revision',
  '{"auth_email": "synthetic-2-8-thief@example.test", "link_state": "review_required", "change_kinds": ["email"],
    "own_account": false, "is_synthetic": true, "extra_factors": false, "binding_review": true,
    "phone_username": "+447700900309", "recovery_email": null, "auth_phone_username": "+447700900309",
    "auth_email_confirmed": true}'::jsonb,
  'the Admin queue shows the account in review with the recorded change kinds and current Auth values');
select pg_temp.session(pg_temp.u(9), gen_random_uuid(), 'password', interval '-1 minute');
select is(pg_temp.on_member('identity.restore_credentials', 9, '{"identity_check": "in_person"}') #>> '{data,account}',
  'app_account', 'restore returns the account to its approved binding');
select is(pg_temp.auth_row(9) || '|' || (select count(*) from auth.sessions where user_id = pg_temp.u(9)),
  '(447700900309,"",f)|0', 'the unapproved address is gone and every session (the thief''s too) is revoked');
select is(pg_temp.summary(pg_temp.fresh(9)), 'ok', 'the member signs in again and is granted');

-- MFA factor: accept refused, restore removes it ---------------------------------------------------------
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), pg_temp.u(10), 'synthetic', 'totp', 'unverified', now(), now());
select is(pg_temp.on_member('identity.accept_credentials', 10, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"member_id": "unsupported_factors"}'::jsonb, 'an MFA factor cannot be accepted into the binding');
select pg_temp.hook('sessions_revoked', 'app.fixture_fail_lifecycle(jsonb)');
select is(pg_temp.on_member('identity.restore_credentials', 10, '{"identity_check": "in_person"}') ->> 'code',
  'unavailable', 'a raising hook fails the restore');
select is((select count(*)::int from auth.mfa_factors where user_id = pg_temp.u(10)) || '|' || (pg_temp.link(10)).binding_revision,
  '1|1', 'and rolls it back: the factor and the binding are unchanged');
select pg_temp.hook('sessions_revoked', 'app.fixture_record_lifecycle(jsonb)');
select pg_temp.on_member('identity.restore_credentials', 10, '{"identity_check": "in_person"}');
select is(pg_temp.calls(10), 'sessions_revoked', 'a restore tells device-registration owners');
select is((select count(*)::int from auth.mfa_factors where user_id = pg_temp.u(10)) || '|' || pg_temp.summary(pg_temp.fresh(10)),
  '0|ok', 'restore removes the factor and lifts the review');

-- Phone changed directly in Auth, accepted after an identity check ------------------------------------------
update auth.users set phone = ltrim(pg_temp.phone(24), '+') where id = pg_temp.u(11);
select is(pg_temp.summary(pg_temp.c(11)), 'PT403|forbidden|review_required', 'a direct phone change needs review');
select is(pg_temp.on_member('identity.accept_credentials', 11, '{"identity_check": "in_person"}', pg_temp.fresh(2)) ->> 'code',
  'forbidden', 'a member cannot accept credentials');
select is(pg_temp.on_member('identity.accept_credentials', 11, '{"identity_check": "established_relationship"}') #>> '{data,account}',
  'app_account', 'an Admin accepts the current Auth phone after an identity check');
select is((pg_temp.link(11)).approved_phone || '|' || pg_temp.summary(pg_temp.fresh(11)), '+447700900324|ok',
  'the binding holds the accepted username; a fresh sign-in is granted');
select is((select reason from app.identity_binding_history where link_id = (pg_temp.link(11)).link_id order by binding_revision desc limit 1),
  'credentials_accepted', 'binding history records the acceptance');

-- A reset link issued before a restore or a 2.7 reject is never redeemable after it ------------------------------
select pg_temp.issue_reset(16);
update auth.users set phone = ltrim(pg_temp.phone(26), '+') where id = pg_temp.u(16);
select pg_temp.on_member('identity.restore_credentials', 16, '{"identity_check": "in_person"}');
select is(pg_temp.auth_row(16) || '|' || pg_temp.redeem_issued(16),
  '(447700900316,synthetic-2-8-16@example.test,t)|no such link|0',
  'after a restore the earlier reset link is unusable (users and one_time_tokens)');
select pg_temp.rcmd(pg_temp.fresh(17), 'identity.propose_recovery_email', null,
  '{"email": "synthetic-2-8-17@example.test"}');
update auth.users set email = 'synthetic-2-8-17@example.test', email_confirmed_at = now() where id = pg_temp.u(17);
select pg_temp.issue_reset(17);
select is(pg_temp.rcmd(pg_temp.c(1), 'identity.reject_recovery_email',
            (select revision from app.identity_recovery_email_proposals where auth_user_id = pg_temp.u(17)),
            jsonb_build_object('proposal_id', (select proposal_id from app.identity_recovery_email_proposals
                                                where auth_user_id = pg_temp.u(17)))) #>> '{data,state}',
  'rejected', 'an Admin rejects a verified 2.7 address');
select is(pg_temp.redeem_issued(17), 'no such link|0', 'and a reset link issued before it is unusable');

-- A password changed without the member's own reset keeps the account held after a restore -----------------------
update auth.users set encrypted_password = 'synthetic-2-8-thief-hash' where id = pg_temp.u(18);
update auth.users set email = 'synthetic-2-8-18-thief@example.test' where id = pg_temp.u(18);
select is(pg_temp.on_member('identity.accept_credentials', 18, '{"identity_check": "in_person"}') -> 'field_errors',
  '{"member_id": "password_unreviewed"}'::jsonb, 'a possibly stolen password is never accepted with the account');
select is(pg_temp.on_member('identity.restore_credentials', 18, '{"identity_check": "in_person"}') #>> '{data,holds,0,reason_code}',
  'security_concern', 'restore puts the approved details back but keeps a security hold');
select is(pg_temp.summary(pg_temp.fresh(18)) || '|' || pg_temp.calls(18), 'PT403|forbidden|review_required|sessions_revoked,access_hold_applied',
  'so a fresh sign-in (possibly the thief''s) sees only access review');
select is(pg_temp.on_member('identity.release_hold', 18, jsonb_build_object('hold_id', (pg_temp.open_hold(18)).hold_id,
            'identity_check', 'in_person')) -> 'field_errors',
  '{"hold_id": "password_reset_required"}'::jsonb, 'until the member resets the password the hold stays');
select pg_temp.redeem(pg_temp.u(18)) is not null as redeemed;
update auth.users set encrypted_password = 'synthetic-2-8-member-18-hash' where id = pg_temp.u(18);
select pg_temp.on_member('identity.release_hold', 18, jsonb_build_object('hold_id', (pg_temp.open_hold(18)).hold_id, 'identity_check', 'in_person'));
select is(pg_temp.summary(pg_temp.fresh(18)), 'ok', 'after the member''s reset and the release, access is open');

-- Reads -------------------------------------------------------------------------------------------------------
select is(pg_temp.read(pg_temp.fresh(3), 'select api.identity_admin_credential_queue()'),
  'PT403|forbidden|not_granted', 'a member cannot read the Admin queue');
select is(pg_temp.read(pg_temp.c(12), 'select api.identity_my_credentials()'),
  'PT403|forbidden|not_linked', 'an unlinked account has no credentials read');
select is(pg_temp.readj(pg_temp.fresh(3), 'select api.identity_my_credentials()') - 'recent_sign_in_minutes' - 'last_change',
  '{"access": "granted", "can_request": true, "church_contact": null, "pending_change": null,
    "phone_username": "+447700900303", "recovery_email": null, "pending_recovery_email": null}'::jsonb,
  'a granted member reads their own sign-in details');
select is((select string_agg(action, ',' order by event_id) from app.identity_credential_review_audit where member_id = pg_temp.mid(3)),
  'credential_change_requested,hold_placed,hold_released,credential_change_rejected,credential_change_requested,credential_change_withdrawn',
  'requests and decisions are audited');
select is((select count(*)::int from app.identity_credential_review_audit a
            where a.action like 'credential_change%' and a.member_id = pg_temp.mid(5)
              and a.action = 'credential_change_reverted'), 1, 'the revert is audited');
select is(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_credential_queue()') -> 'holds', '[]'::jsonb,
  'no open hold is left');

-- Before 20261007160100 is applied the Auth row helpers are fail-closed stubs ---------------------------------
select pg_temp.request(pg_temp.fresh(3), jsonb_build_object('change_kind', 'phone_username', 'phone_username', pg_temp.phone(27)));
create or replace function app.identity_revoke_auth_sessions(p_auth_user_id uuid)
returns integer language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '0A000',
    message = 'identity Auth row helpers are not installed (20261007160100)';
end;
$$;
select is(pg_temp.decide('identity.approve_credential_change', 3, '{"identity_check": "in_person"}') - 'request_id' - 'message',
  '{"code": "unavailable", "field_errors": {}}'::jsonb, 'with the stub an approval answers unavailable');
select is((pg_temp.change(3)).change_state || '|' || pg_temp.auth_row(3), 'pending|(447700900303,"",f)',
  'and changes nothing');

select * from finish();
rollback;
