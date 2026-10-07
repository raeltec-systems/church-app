-- Recover a password through a verified same-account email (story 2.7; AD-3, AD-4, AD-20,
-- AC-06). A member proposes a recovery email for the same account (fresh password sign-in), Auth
-- verifies it, an Admin approves it into the credential binding; the reset gate on recovery-link
-- redemption admits only that approved, current, confirmed email; holds stay in force. HTTP
-- evidence through real GoTrue and Mailpit: tools/identity-e2e/recovery.mjs. Every account,
-- phone and email here is SYNTHETIC (+44 7700 900270-900289, @example.test).
begin;
select plan(75);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000027' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000027' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (270 + n)::text $$;
create function pg_temp.mail(n int) returns text language sql as
$$ select 'synthetic-2-7-' || n || '@example.test' $$;

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

-- A session row (created p_age ago) whose server AMR record is p_amr_age old.
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

create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  select api.identity_recovery_email_command(jsonb_build_object(
           'version', 1, 'command', p_command, 'request_id', p_request,
           'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.propose(p_claims jsonb, p_email text) returns jsonb language sql as
$$ select pg_temp.cmd(p_claims, 'identity.propose_recovery_email', null,
                      jsonb_build_object('email', p_email)) $$;

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

create function pg_temp.pending(n int) returns app.identity_recovery_email_proposals
language sql as $$
  select p.* from app.identity_recovery_email_proposals p
   where p.auth_user_id = pg_temp.u(n) order by p.proposed_at desc limit 1
$$;
create function pg_temp.link(n int) returns app.identity_account_links language sql as $$
  select l.* from app.identity_account_links l
   where l.auth_user_id = pg_temp.u(n) and l.link_state <> 'ended'
$$;
-- GoTrue's /verify redemption: the recovery token set by /recover, then cleared alone.
create function pg_temp.redeem(p_user uuid) returns text language plpgsql as $$
begin
  update auth.users set recovery_token = 'synthetic-2-7-token-' || p_user where id = p_user;
  begin
    update auth.users set recovery_token = '' where id = p_user;
    return 'ok';
  exception when others then
    return sqlstate || '|' || sqlerrm;
  end;
end;
$$;
-- GoTrue's confirmation of an email change.
create function pg_temp.verify_email(n int, p_email text) returns void language sql as $$
  update auth.users set email = p_email, email_confirmed_at = now() where id = pg_temp.u(n);
$$;

-- Accounts: 1 Admin A, 2 member (full flow), 3 member with an old password sign-in, 4 unlinked
-- account with a confirmed email, 5 member with an approved email, 6 held member with an
-- approved email, 7 member whose phone changes, 8 member who adds an MFA factor, 9 member whose
-- email is never verified, 10 member whose approved email Auth holds unconfirmed, 11 banned member
-- with an approved email, 12 member who withdraws a verified email, 13 member whose verified email
-- is rejected, 14 member whose Auth email change predates the proposal.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 14) n;
update auth.users u set email = pg_temp.mail(x.n), email_confirmed_at = now()
  from (values (4), (5), (6), (11)) x(n) where u.id = pg_temp.u(x.n);
update auth.users set email = pg_temp.mail(10) where id = pg_temp.u(10);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 14) n where n <> 3;
select pg_temp.session(pg_temp.u(3), pg_temp.s(3), 'password', interval '1 hour', interval '20 minutes');

-- Structure and privileges ---------------------------------------------------------------------
select ok((select count(*) from information_schema.tables where table_schema = 'app'
            and table_name in ('identity_recovery_email_proposals', 'identity_credential_audit')) = 2,
  'proposal and credential audit tables exist');
select ok(not exists (
  select 1 from unnest(array['app.identity_recovery_email_proposals', 'app.identity_credential_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, 'app.identity_credential_audit_event_id_seq', p)),
  'no client role has any privilege on the new tables or the audit sequence');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_credential_audit'),
  array['action', 'actor_account_id', 'actor_member_id', 'binding_revision_after', 'environment',
        'event_id', 'identity_check', 'link_id', 'member_id', 'occurred_at', 'proposal_id',
        'reason_code', 'request_id', 'revision_after'],
  'the credential audit holds ids, codes and revisions only (never the email)');
select ok(not has_function_privilege('anon', 'api.identity_recovery_email_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_my_recovery_email()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_recovery_email_queue()', 'EXECUTE'),
  'signed-out callers cannot execute the recovery-email command or reads');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok(exists (select 1 from pg_trigger t where t.tgrelid = 'auth.users'::regclass
                    and t.tgname = 'identity_email_link_gate' and t.tgenabled = 'O'),
  'the redemption gate trigger is installed on auth.users');

-- Environment and members -----------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.7');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.7 Member ' || n, 'pgtap 2.7') as member_id
  from generate_series(1, 14) n where n <> 4;
select app.identity_bootstrap_admin((select member_id from m where n = 1), 'israel');
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'SYNTHETIC hold', 'pgtap 2.7' from m where n = 6;
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(11);

-- Proposing (member) -----------------------------------------------------------------------------
select is(pg_temp.propose(pg_temp.c(3), 'synthetic-2-7-3@example.test') -> 'field_errors',
  '{"session": "reauthenticate"}'::jsonb,
  'a password sign-in older than 10 minutes must sign in again before adding an email');
select is(pg_temp.propose(pg_temp.c(4), 'synthetic-2-7-x@example.test') ->> 'code', 'forbidden',
  'an unlinked account cannot propose a recovery email');
select is(pg_temp.propose(pg_temp.fresh(2, 'otp'), 'synthetic-2-7-x@example.test') ->> 'code',
  'unauthenticated', 'an email-link (otp) session cannot propose');
select is(pg_temp.propose(pg_temp.c(2), 'not an email') -> 'field_errors', '{"email": "invalid"}'::jsonb,
  'a malformed email is refused');
select is(pg_temp.propose(pg_temp.c(2), 'someone@gmail.com') -> 'field_errors', '{"email": "unsupported"}'::jsonb,
  'while Q4 is unapproved a real-looking address is refused locally');
select is(pg_temp.cmd(pg_temp.c(2), 'identity.propose_recovery_email', null,
            '{"email": "synthetic-2-7-2@example.test", "phone": "+447700900272"}') -> 'field_errors',
  '{"phone": "unknown_field"}'::jsonb, 'unknown payload fields are refused');
select is(pg_temp.propose(pg_temp.c(5), 'synthetic-2-7-new@example.test') -> 'field_errors',
  '{"email": "already_approved"}'::jsonb,
  'replacing an approved recovery email is not this flow (entry 8)');
select is(pg_temp.propose(pg_temp.c(2), 'Synthetic-2-7-Old@Example.TEST') -> 'data' ->> 'state', 'pending',
  'a granted member with a fresh password sign-in proposes an email');
select is(pg_temp.propose(pg_temp.c(2), ' synthetic-2-7-2@example.test ') -> 'data' ->> 'email',
  'synthetic-2-7-2@example.test', 'the address is stored trimmed and lower-case');
select is((select array_agg(proposal_state order by proposed_at)
             from app.identity_recovery_email_proposals where auth_user_id = pg_temp.u(2)),
  array['superseded', 'pending'], 'a new proposal supersedes the pending one');
select is((select array_agg(action order by event_id) from app.identity_credential_audit
            where member_id = (select member_id from m where n = 2)),
  array['recovery_email_proposed', 'recovery_email_superseded', 'recovery_email_proposed'],
  'proposals and supersessions are audited');
select pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test');
select pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test');
select pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test');
select pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test');
select pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test');
select is(pg_temp.propose(pg_temp.c(7), 'synthetic-2-7-7@example.test') ->> 'code', 'rate_limited',
  'at most 5 proposals per account per 24 hours');
select is(pg_temp.readj(pg_temp.c(2), 'select api.identity_my_recovery_email()')
            - 'recent_sign_in_minutes' #- '{proposal,proposal_id}' #- '{proposal,proposed_at}',
  '{"access": "granted", "approved_email": null, "can_propose": true,
    "proposal": {"email": "synthetic-2-7-2@example.test", "state": "pending", "revision": 1, "verified": false}}'::jsonb,
  'the member reads their own pending, unverified proposal');

-- Verification (GoTrue's email-change link confirms it on the same account) --------------------
select pg_temp.verify_email(2, 'synthetic-2-7-2@example.test');
select is(pg_temp.read(pg_temp.c(2), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|review_required',
  'a verified but unapproved email keeps private access in review (AD-3)');
select is(pg_temp.readj(pg_temp.c(2), 'select api.identity_my_recovery_email()') #>> '{proposal,verified}',
  'true', 'the member still reads their own proposal, now verified');
select is(pg_temp.readj(pg_temp.c(2), 'select api.identity_my_recovery_email()') ->> 'access',
  'review_required', 'and is told the account waits for review');
select is(pg_temp.propose(pg_temp.fresh(2), 'synthetic-2-7-other@example.test') ->> 'code', 'forbidden',
  'no further proposal while in review');
select is(pg_temp.redeem(pg_temp.u(2)), '42501|email link not accepted',
  'a verified but unapproved email cannot redeem a recovery link');

-- Admin decision --------------------------------------------------------------------------------
select is(pg_temp.read(pg_temp.c(5), 'select api.identity_admin_recovery_email_queue()'),
  'PT403|forbidden|not_granted', 'a member without Admin cannot read the queue');
select is((select jsonb_agg(p - 'proposal_id' - 'proposed_at' - 'member_id' - 'revision' - 'display_name')
             from jsonb_array_elements(pg_temp.readj(pg_temp.c(1),
               'select api.identity_admin_recovery_email_queue()') -> 'proposals') p
            where p ->> 'email' = 'synthetic-2-7-2@example.test'),
  '[{"email": "synthetic-2-7-2@example.test", "state": "pending", "verified": true, "own_account": false,
     "is_synthetic": true, "access_review": true, "other_changes": false,
     "phone_username": "+447700900272"}]'::jsonb,
  'the Admin queue shows the verified proposal, no other changes, and the account in review');
select is(pg_temp.cmd(pg_temp.c(5), 'identity.approve_recovery_email', (pg_temp.pending(2)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(2)).proposal_id,
                               'identity_check', 'in_person')) ->> 'code',
  'forbidden', 'a non-Admin cannot approve');
insert into app.identity_recovery_email_proposals (link_id, member_id, auth_user_id, email, is_synthetic)
select l.link_id, l.member_id, l.auth_user_id, 'synthetic-2-7-1@example.test', true
  from app.identity_account_links l where l.auth_user_id = pg_temp.u(1);
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', 1,
            jsonb_build_object('proposal_id', (pg_temp.pending(1)).proposal_id,
                               'identity_check', 'in_person')) -> 'field_errors',
  '{"proposal_id": "unsupported"}'::jsonb, 'an Admin cannot approve their own recovery email');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(2)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(2)).proposal_id)) -> 'field_errors',
  '{"identity_check": "required"}'::jsonb, 'approval needs a recorded identity check');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', 7,
            jsonb_build_object('proposal_id', (pg_temp.pending(2)).proposal_id,
                               'identity_check', 'in_person')) ->> 'code',
  'conflict', 'a stale proposal revision is a conflict');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(2)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(2)).proposal_id,
                               'identity_check', 'established_relationship')) #>> '{data,state}',
  'approved', 'the Admin approves the verified email');
select is((select row(l.link_state, l.binding_revision, l.approved_recovery_email, l.binding_review_required)::text
             from app.identity_account_links l where l.auth_user_id = pg_temp.u(2)),
  '(active,2,synthetic-2-7-2@example.test,f)',
  'the binding gets revision 2 with the email; review cleared; link active');
select is((select reason from app.identity_binding_history h join app.identity_account_links l using (link_id)
            where l.auth_user_id = pg_temp.u(2) and h.binding_revision = 2),
  'recovery_email_approved', 'binding history records the approval');
select is(pg_temp.read(pg_temp.c(2), 'select api.identity_my_member_summary()'),
  'PT401|unauthenticated|untrusted_session', 'a session from before the approval must sign in again');
select is(pg_temp.readj(pg_temp.fresh(2), 'select api.identity_my_member_summary()') ->> 'has_recovery_email',
  'true', 'a fresh password sign-in is granted with the approved recovery email');
select is((select row(a.identity_check, a.binding_revision_after, a.actor_member_id = (select member_id from m where n = 1))::text
             from app.identity_credential_audit a
            where a.action = 'recovery_email_approved' and a.member_id = (select member_id from m where n = 2)),
  '(established_relationship,2,t)', 'the approval is audited with the check and the Admin');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(2)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(2)).proposal_id,
                               'identity_check', 'in_person')) ->> 'code',
  'conflict', 'a decided proposal cannot be approved again');

-- Other binding changes, unverified emails, rejection --------------------------------------------
select pg_temp.verify_email(7, 'synthetic-2-7-7@example.test');
update auth.users set phone = '447700900288' where id = pg_temp.u(7);
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(7)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(7)).proposal_id,
                               'identity_check', 'in_person')) -> 'field_errors',
  '{"proposal_id": "other_changes"}'::jsonb,
  'a phone change since the proposal sends the case to the credential review');
select pg_temp.propose(pg_temp.c(8), 'synthetic-2-7-8@example.test');
select pg_temp.verify_email(8, 'synthetic-2-7-8@example.test');
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), pg_temp.u(8), 'synthetic', 'totp', 'unverified', now(), now());
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(8)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(8)).proposal_id,
                               'identity_check', 'in_person')) -> 'field_errors',
  '{"proposal_id": "other_changes"}'::jsonb, 'an MFA factor added since the proposal is refused too');
select pg_temp.propose(pg_temp.c(9), 'synthetic-2-7-9@example.test');
-- What GoTrue's updateUser(email) leaves until the link is opened.
update auth.users set email_change = 'synthetic-2-7-9@example.test', email_change_token_new = 'synthetic-2-7-tok-9',
                      email_change_sent_at = now(), email_change_confirm_status = 0
 where id = pg_temp.u(9);
insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to)
values (gen_random_uuid(), pg_temp.u(9), 'email_change_token_new', 'synthetic-2-7-tok-9',
        'synthetic-2-7-9@example.test');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(9)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(9)).proposal_id,
                               'identity_check', 'in_person')) -> 'field_errors',
  '{"recovery_email": "unverified"}'::jsonb, 'an unverified email cannot be approved');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.reject_recovery_email', (pg_temp.pending(9)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(9)).proposal_id, 'reason', 'because')) -> 'field_errors',
  '{"reason": "invalid"}'::jsonb, 'reject reasons are codes');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.reject_recovery_email', (pg_temp.pending(9)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(9)).proposal_id,
                               'reason', 'contact_church_office')) #>> '{data,state}',
  'rejected', 'the Admin rejects a proposal');
select is(pg_temp.readj(pg_temp.c(9), 'select api.identity_my_recovery_email()') #>> '{proposal,decision_reason}',
  'contact_church_office', 'the member sees the rejection code');
select is((select reason_code from app.identity_credential_audit
            where action = 'recovery_email_rejected' and member_id = (select member_id from m where n = 9)),
  'contact_church_office', 'the rejection is audited by code');

select is((select row(coalesce(email, ''), email_change, email_change_token_new, email_change_sent_at is null)::text
             from auth.users where id = pg_temp.u(9)),
  '("","","",t)', 'rejecting an unverified email clears the pending Auth email change');
select ok(not exists (select 1 from auth.one_time_tokens t where t.user_id = pg_temp.u(9)
                       and t.token_hash = 'synthetic-2-7-tok-9'),
  'its emailed confirmation token can no longer be found (a later click changes nothing)');
select is(pg_temp.readj(pg_temp.fresh(9), 'select api.identity_my_member_summary()') ->> 'has_recovery_email',
  'false', 'the account keeps member access on its approved binding');

-- Lockout exit: reject a verified email, withdraw one's own -----------------------------------
select pg_temp.propose(pg_temp.c(13), 'synthetic-2-7-13@example.test');
select pg_temp.verify_email(13, 'synthetic-2-7-13@example.test');
select is(pg_temp.read(pg_temp.c(13), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|review_required', 'a verified unapproved email puts member 13 in review');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.reject_recovery_email', (pg_temp.pending(13)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(13)).proposal_id)) #>> '{data,state}',
  'rejected', 'the Admin rejects the verified email');
select is((select row(coalesce(u.email, ''), u.email_confirmed_at is null, l.link_state, l.binding_review_required,
                      l.binding_revision, l.approved_recovery_email is null)::text
             from auth.users u join app.identity_account_links l on l.auth_user_id = u.id
            where u.id = pg_temp.u(13) and l.link_state <> 'ended'),
  '("",t,active,f,2,t)', 'the account returns to its approved binding and the review is lifted');
select is(pg_temp.read(pg_temp.c(13), 'select api.identity_my_member_summary()'),
  'PT401|unauthenticated|untrusted_session', 'earlier sessions must still sign in again');
select is(pg_temp.readj(pg_temp.fresh(13), 'select api.identity_my_member_summary()') ->> 'has_recovery_email',
  'false', 'a fresh sign-in is granted after the rejection');
select is((select array_agg(action order by event_id) from app.identity_credential_audit
            where member_id = (select member_id from m where n = 13)),
  array['recovery_email_proposed', 'recovery_email_rejected', 'recovery_email_reverted'],
  'the rejection and the revert are audited');

select pg_temp.propose(pg_temp.c(12), 'synthetic-2-7-12@example.test');
select pg_temp.verify_email(12, 'synthetic-2-7-12@example.test');
select is(pg_temp.cmd(pg_temp.c(12), 'identity.withdraw_recovery_email', (pg_temp.pending(13)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(13)).proposal_id)) ->> 'code',
  'not_found', 'a member cannot withdraw another account''s proposal');
select is(pg_temp.cmd(pg_temp.fresh(12, 'otp'), 'identity.withdraw_recovery_email', (pg_temp.pending(12)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(12)).proposal_id)) ->> 'code',
  'unauthenticated', 'an email-link session cannot withdraw');
select is(pg_temp.cmd(pg_temp.c(12), 'identity.withdraw_recovery_email', (pg_temp.pending(12)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(12)).proposal_id)) #>> '{data,state}',
  'withdrawn', 'the member withdraws their own verified email while access is in review');
select is((select row(coalesce(u.email, ''), l.link_state, l.binding_review_required)::text
             from auth.users u join app.identity_account_links l on l.auth_user_id = u.id
            where u.id = pg_temp.u(12) and l.link_state <> 'ended'),
  '("",active,f)', 'withdrawing returns the account to its approved binding');
select is(pg_temp.readj(pg_temp.fresh(12), 'select api.identity_my_member_summary()') ->> 'has_recovery_email',
  'false', 'and a fresh sign-in is granted');
select is((select array_agg(action order by event_id) from app.identity_credential_audit
            where member_id = (select member_id from m where n = 12)),
  array['recovery_email_proposed', 'recovery_email_withdrawn', 'recovery_email_reverted'],
  'the withdrawal is audited without content');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.reject_recovery_email', (pg_temp.pending(7)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(7)).proposal_id)) #>> '{data,state}',
  'rejected', 'a proposal with other changes can be rejected');
select is((select row(coalesce(u.email, ''), l.link_state, l.binding_review_required)::text
             from auth.users u join app.identity_account_links l on l.auth_user_id = u.id
            where u.id = pg_temp.u(7) and l.link_state <> 'ended'),
  '("",review_required,t)', 'its email is removed but the other change keeps the review (entry 8)');

-- Recency: the Auth email change must come after the proposal ----------------------------------
select pg_temp.propose(pg_temp.c(14), 'synthetic-2-7-14@example.test');
select pg_temp.verify_email(14, 'synthetic-2-7-14@example.test');
update app.identity_credential_events e set at = (pg_temp.pending(14)).proposed_at - interval '1 minute'
  from app.identity_account_links l
 where e.link_id = l.link_id and l.auth_user_id = pg_temp.u(14) and 'email' = any (e.kinds);
select is(pg_temp.cmd(pg_temp.c(1), 'identity.approve_recovery_email', (pg_temp.pending(14)).revision,
            jsonb_build_object('proposal_id', (pg_temp.pending(14)).proposal_id,
                               'identity_check', 'in_person')) -> 'field_errors',
  '{"proposal_id": "stale"}'::jsonb, 'an email change older than the proposal is not approved');

-- The reset gate on recovery-link redemption ------------------------------------------------------
create temp table epoch5 as select sessions_valid_after from app.identity_account_links where auth_user_id = pg_temp.u(5);
select is(pg_temp.redeem(pg_temp.u(5)), 'ok', 'the approved, confirmed, current email may redeem a recovery link');
select ok((select e.kinds = array['email_link_redeemed'] from app.identity_credential_events e
             join app.identity_account_links l using (link_id)
            where l.auth_user_id = pg_temp.u(5) order by e.event_id desc limit 1)
          and (select sessions_valid_after is not distinct from (select sessions_valid_after from epoch5)
                 from app.identity_account_links where auth_user_id = pg_temp.u(5)),
  'the redemption is recorded by kind and moves no epoch');
select is(pg_temp.redeem(pg_temp.u(2)), 'ok', 'after approval the member''s email may redeem');
select is(pg_temp.redeem(pg_temp.u(4)), '42501|email link not accepted',
  'an unlinked account''s email cannot redeem (no approved binding)');
select is(pg_temp.redeem(pg_temp.u(10)), '42501|email link not accepted',
  'an approved email that Auth holds unconfirmed cannot redeem');
select is(pg_temp.redeem(pg_temp.u(11)), '42501|email link not accepted', 'a banned account cannot redeem');
select is(pg_temp.redeem(pg_temp.u(6)), 'ok', 'a held member may reset (the hold is not cleared)');
update auth.users set encrypted_password = 'synthetic-2-7-hash', recovery_token = '' where id = pg_temp.u(6);
select is(pg_temp.read(pg_temp.fresh(6), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|review_required', 'after the password is set the hold stays in force');
update auth.users set recovery_token = 'synthetic-2-7-token-4b' where id = pg_temp.u(4);
update auth.users set encrypted_password = 'synthetic-2-7-hash', recovery_token = '' where id = pg_temp.u(4);
select is((select coalesce(recovery_token, '') from auth.users where id = pg_temp.u(4)), '',
  'a password update that clears the token is not a redemption and is never blocked');
update auth.users set email = 'synthetic-2-7-changed@example.test' where id = pg_temp.u(5);
select is(pg_temp.redeem(pg_temp.u(5)), '42501|email link not accepted',
  'after a direct Auth email change neither address can redeem');
select is(pg_temp.read(pg_temp.fresh(5, 'recovery'), 'select api.identity_my_recovery_email()'),
  'PT401|unauthenticated|untrusted_session', 'a recovery session reads nothing, not even its own email state');

select * from finish();
rollback;
