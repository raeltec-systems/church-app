-- Identity live session trust (story 2.2; AD-3, AD-20): trusted detection of direct Auth
-- credential changes on linked accounts, the session trust epoch, the server-side AMR record and
-- the verified approved email. HTTP evidence: tools/identity-e2e (real GoTrue routes) and
-- identity_api_smoke.sh. Every account, phone, email and name here is SYNTHETIC.
begin;
select plan(60);

create function pg_temp.read(p_claims jsonb) returns text
language plpgsql
as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  begin
    r := api.identity_my_member_summary();
    reset role;
    return 'ok';
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

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000022' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000022' || lpad(n::text, 2, '0'))::uuid $$;

-- A session as GoTrue records it: created now (clock time) with its server-side AMR claim.
create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password',
                                p_created timestamptz default clock_timestamp())
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at) values (p_session, p_user, 'aal1', p_created);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), p_method);
  select p_session;
$$;

create function pg_temp.link(p_user uuid) returns app.identity_account_links
language sql as $$
  select l from app.identity_account_links l where l.auth_user_id = p_user and l.link_state <> 'ended'
$$;

create function pg_temp.events(p_user uuid) returns text
language sql as $$
  select coalesce(string_agg(e.source || ':' || array_to_string(e.kinds, '+') || ':'
                             || case when e.binding_review then 'review' else 'epoch' end, ', '
                             order by e.event_id), '')
    from app.identity_credential_events e
    join app.identity_account_links l using (link_id)
   where l.auth_user_id = p_user
$$;

-- Simulates the reviewed re-approval of entries 5/8 (restricted operator), keeping the epoch.
create function pg_temp.reapprove(p_user uuid) returns void
language sql as $$
  update app.identity_account_links set link_state = 'active'
   where auth_user_id = p_user and link_state <> 'ended';
$$;

-- Structure and privileges ---------------------------------------------------------------------
select has_column('app', 'identity_account_links', 'credential_generation', 'links carry a credential generation');
select has_column('app', 'identity_account_links', 'sessions_valid_after', 'links carry a session trust epoch');
select has_table('app', 'identity_credential_events', 'credential events table exists');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.identity_credential_events', p)),
  'no client role has any privilege on credential events');
select ok(not exists (
  select 1 from information_schema.columns
   where table_schema = 'app' and table_name = 'identity_credential_events'
     and column_name ~ '(phone|email|password|token|secret)'),
  'credential events hold change kinds only, no credential values');
select ok(not exists (
  select 1 from unnest(array['app.identity_note_credential_change(uuid,text,text[],boolean)',
                             'app.identity_on_auth_user_change()', 'app.identity_on_auth_identity_change()',
                             'app.identity_on_auth_mfa_change()', 'app.identity_on_link_state_change()',
                             'app.identity_on_hold_placed()', 'app.identity_access_evaluate()']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'detection functions and the predicate have no client grants');
select has_trigger('auth', 'users', 'identity_credential_change', 'auth.users change trigger');
select has_trigger('auth', 'users', 'identity_credential_delete', 'auth.users delete trigger');
select has_trigger('auth', 'identities', 'identity_credential_identity_change', 'auth.identities trigger');
select has_trigger('auth', 'mfa_factors', 'identity_credential_mfa_change', 'auth.mfa_factors trigger');

-- Fixtures -------------------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.2');
insert into auth.users (id, aud, role, phone, phone_confirmed_at) values
  (pg_temp.u(1), 'authenticated', 'authenticated', '12025550121', now()),
  (pg_temp.u(2), 'authenticated', 'authenticated', '12025550122', now()),
  (pg_temp.u(3), 'authenticated', 'authenticated', '447700900122', now()),
  (pg_temp.u(4), 'authenticated', 'authenticated', '12025550124', now()),
  (pg_temp.u(5), 'authenticated', 'authenticated', '12025550125', now()),
  (pg_temp.u(6), 'authenticated', 'authenticated', '12025550126', now());
update auth.users set email = 'synthetic-2-2-alias@example.test', email_confirmed_at = now()
 where id = pg_temp.u(2);
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.2 Member ' || n, 'pgtap 2.2')
  from generate_series(1, 5) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n), 'password', now() - interval '1 hour')
  from generate_series(1, 6) n;

-- Server-side AMR record -----------------------------------------------------------------------
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'ok', 'password session: granted');
select pg_temp.session(pg_temp.u(1), pg_temp.s(11), 'otp');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(11))), 'PT401|unauthenticated|untrusted_session',
  'JWT says password but the server recorded otp (custom-hook forgery): denied');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(11), array['otp'])), 'PT401|unauthenticated|untrusted_session',
  'otp session (magic link, email OTP, signup link): denied');
insert into auth.sessions (id, user_id, aal, created_at) values (pg_temp.s(12), pg_temp.u(1), 'aal1', clock_timestamp());
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(12))), 'PT401|unauthenticated|untrusted_session',
  'a session with no server AMR record: denied');
update auth.users set is_anonymous = true where id = pg_temp.u(1);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT401|unauthenticated|untrusted_session',
  'an anonymous Auth user is denied even if the JWT says otherwise');
update auth.users set is_anonymous = false where id = pg_temp.u(1);
select is(pg_temp.events(pg_temp.u(1)), '', 'sessions and AMR records are not credential changes');

-- Direct Auth phone change: persistent review, epoch, generation -------------------------------
update app.identity_account_links set last_member_activity_at = '2026-10-01T00:00:00Z'
 where auth_user_id = pg_temp.u(1);
update auth.users set phone = '12025550129' where id = pg_temp.u(1);
select is((pg_temp.link(pg_temp.u(1))).link_state, 'review_required', 'a direct phone change moves the link to review');
select is((pg_temp.link(pg_temp.u(1))).credential_generation, 2::bigint, 'and advances the credential generation');
select ok((pg_temp.link(pg_temp.u(1))).sessions_valid_after is not null, 'and sets the session trust epoch');
select is(pg_temp.events(pg_temp.u(1)), 'auth_users:phone:review', 'the change is recorded by kind only');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT403|forbidden|review_required',
  'stale token after a direct phone change: review required');
update auth.users set phone = '12025550121' where id = pg_temp.u(1);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT403|forbidden|review_required',
  'changing the phone back does not restore access (detection, not value comparison)');
select is((pg_temp.link(pg_temp.u(1))).credential_generation, 3::bigint, 'the revert is a change too');
select pg_temp.session(pg_temp.u(1), pg_temp.s(14));
select pg_temp.reapprove(pg_temp.u(1));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT401|unauthenticated|untrusted_session',
  'after re-approval the pre-change session stays dead');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(14))), 'PT401|unauthenticated|untrusted_session',
  'a session opened while the link was in review is not admitted by the re-approval');
select pg_temp.session(pg_temp.u(1), pg_temp.s(13));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(13))), 'ok', 'a fresh password sign-in is granted');
select is((pg_temp.link(pg_temp.u(1))).last_member_activity_at > '2026-10-01T00:00:00Z', true,
  'only that granted read wrote activity');
select ok((select bool_and(e.at >= now()) from app.identity_credential_events e
            join app.identity_account_links l using (link_id) where l.auth_user_id = pg_temp.u(1)),
  'events are stamped with the change time');

-- Verified email/password alias ------------------------------------------------------------------
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(2))), 'ok',
  'verified approved email alias (same account, password AMR): granted');
select is((pg_temp.link(pg_temp.u(2))).approved_recovery_email, 'synthetic-2-2-alias@example.test',
  'the alias is the approved recovery email');
update auth.users set email = 'synthetic-2-2-other@example.test' where id = pg_temp.u(2);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(2))), 'PT403|forbidden|review_required',
  'a direct email change: review required');
select is(pg_temp.events(pg_temp.u(2)), 'auth_users:email:review', 'recorded as an email change');
update auth.users set email = 'synthetic-2-2-alias@example.test', email_confirmed_at = null where id = pg_temp.u(2);
select pg_temp.reapprove(pg_temp.u(2));
select pg_temp.session(pg_temp.u(2), pg_temp.s(21));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(21))), 'PT403|forbidden|review_required',
  'an approved email that Auth holds unconfirmed does not count');
update auth.users set email_confirmed_at = now() where id = pg_temp.u(2);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(21))), 'ok', 'confirmed again: granted');

-- Password change (native PUT /user or recovery): epoch, no review ------------------------------
update auth.users set encrypted_password = 'synthetic-hash-not-a-password' where id = pg_temp.u(3);
select is((pg_temp.link(pg_temp.u(3))).link_state, 'active', 'a password change needs no binding review');
select is(pg_temp.events(pg_temp.u(3)), 'auth_users:password:epoch', 'it is recorded and moves the epoch');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(3))), 'PT401|unauthenticated|untrusted_session',
  'every session from before the password change is denied (even if Auth kept it)');
select pg_temp.session(pg_temp.u(3), pg_temp.s(31));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(31))), 'ok', 'fresh password sign-in: granted');
insert into auth.sessions (id, user_id, aal) values (pg_temp.s(32), pg_temp.u(3), 'aal1');
insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
values (gen_random_uuid(), pg_temp.s(32), now(), now(), 'password');
update auth.sessions set created_at = null where id = pg_temp.s(32);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(32))), 'PT401|unauthenticated|untrusted_session',
  'a session without a creation time cannot prove it is after the epoch');

-- Identities and MFA factors are binding changes ----------------------------------------------
insert into auth.identities (provider_id, user_id, identity_data, provider)
values ('synthetic-2-2', pg_temp.u(4), '{"sub": "synthetic-2-2"}', 'synthetic');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(4), pg_temp.s(4))), 'PT403|forbidden|review_required',
  'a new Auth identity on a linked account: review required');
delete from auth.identities where provider_id = 'synthetic-2-2';
insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), pg_temp.u(4), 'totp', 'unverified', now(), now());
update auth.mfa_factors set status = 'verified' where user_id = pg_temp.u(4);
delete from auth.mfa_factors where user_id = pg_temp.u(4);
select is(pg_temp.events(pg_temp.u(4)),
  'auth_identities:identity_added:review, auth_identities:identity_removed:review, '
  'auth_mfa_factors:mfa_added:review, auth_mfa_factors:mfa_changed:review, auth_mfa_factors:mfa_removed:review',
  'identity add/remove and MFA add/verify/remove are each recorded');
select is((pg_temp.link(pg_temp.u(4))).credential_generation, 6::bigint, 'each advanced the generation');

-- Ban, soft delete and hard delete -------------------------------------------------------------
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(5);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(5))), 'PT401|unauthenticated|untrusted_session',
  'banned (revoked by Auth Admin): denied');
update auth.users set banned_until = null where id = pg_temp.u(5);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(5))), 'PT401|unauthenticated|untrusted_session',
  'unbanning does not bring the old session back');
select is((pg_temp.link(pg_temp.u(5))).link_state, 'active', 'a ban is not a binding change');
select pg_temp.session(pg_temp.u(5), pg_temp.s(51));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(51))), 'ok', 'fresh sign-in after unban: granted');

-- Holds and link state move the epoch --------------------------------------------------------
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'pgtap 2.2 synthetic hold', 'pgtap'
  from app.identity_account_links where auth_user_id = pg_temp.u(5);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(51))), 'PT403|forbidden|review_required',
  'an open hold: review required');
update app.identity_holds set released_at = now(), released_by = 'pgtap'
 where member_id = (pg_temp.link(pg_temp.u(5))).member_id;
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(51))), 'PT401|unauthenticated|untrusted_session',
  'released hold: sessions from before the hold stay dead');
select pg_temp.session(pg_temp.u(5), pg_temp.s(52));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(52))), 'ok', 'fresh sign-in after release: granted');
update app.identity_account_links set link_state = 'suspended' where auth_user_id = pg_temp.u(5);
select pg_temp.reapprove(pg_temp.u(5));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(52))), 'PT401|unauthenticated|untrusted_session',
  'a suspended-then-restored link: earlier sessions stay dead');
select is(pg_temp.events(pg_temp.u(5)), 'auth_users:ban_changed:epoch, auth_users:ban_changed:epoch, identity_holds:hold_security:epoch',
  'ban, unban and the hold are recorded');

update auth.users set deleted_at = now() where id = pg_temp.u(5);
select is((pg_temp.link(pg_temp.u(5))).link_state, 'review_required', 'an Auth soft delete puts the link in review');
delete from auth.users where id = pg_temp.u(4);
select is((select link_state from app.identity_account_links where auth_user_id = pg_temp.u(4)),
  'review_required', 'an Auth hard delete leaves the link in review');

-- Unlinked and ended links are untouched -------------------------------------------------------
update auth.users set phone = '12025550127', encrypted_password = 'x' where id = pg_temp.u(6);
select is((select count(*)::int from app.identity_credential_events e
            join app.identity_account_links l using (link_id) where l.auth_user_id = pg_temp.u(6)),
  0, 'changes on an unlinked account record nothing and do not fail');
update app.identity_account_links set link_state = 'ended', ended_at = now() where auth_user_id = pg_temp.u(3);
update auth.users set phone = '447700900123' where id = pg_temp.u(3);
select is((select link_state from app.identity_account_links where auth_user_id = pg_temp.u(3)), 'ended',
  'an ended link is never reopened by a later change');

-- Denials never write activity; dormancy reads prior activity ------------------------------------
select is((pg_temp.link(pg_temp.u(2))).last_member_activity_at is not null, true, 'alias member has activity');
update app.identity_account_links set last_member_activity_at = now() - interval '91 days'
 where auth_user_id = pg_temp.u(2);
select pg_temp.session(pg_temp.u(2), pg_temp.s(22));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(22))), 'PT403|forbidden|review_required',
  'dormant (labelled 90-day fixture): a fresh password session is still denied');
select ok((pg_temp.link(pg_temp.u(2))).last_member_activity_at < now() - interval '90 days',
  'the dormancy denial wrote no activity');
select is((select count(*)::int from app.identity_credential_events e
            join app.identity_account_links l using (link_id) where l.auth_user_id = pg_temp.u(2)),
  2, 'denied reads record no credential events (only the email change and its revert)');
select is(app.identity_current_member_id(), null, 'identity_current_member_id: dormant caller is null');

select * from finish();
rollback;
