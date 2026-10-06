-- Identity live session trust (story 2.2; AD-3, AD-20): trusted detection of direct Auth
-- credential changes on linked accounts, the durable binding review, the session trust epoch
-- (with its safety margin), relinks, the server-side AMR record and the verified approved email.
-- HTTP evidence: tools/identity-e2e (real GoTrue routes) and identity_api_smoke.sh. Every
-- account, phone, email and name here is SYNTHETIC.
--
-- Time model (one transaction): an "old" session is created an hour ago or at the current clock
-- (before a later epoch); a "fresh" sign-in is created 6 s ahead of the clock, i.e. after the
-- latest epoch plus its 5 s margin. A fresh session is never used to assert a LATER epoch.
begin;
select plan(83);

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

-- A session as GoTrue records it, with its server-side AMR claim.
create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password',
                                p_created timestamptz default clock_timestamp())
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at) values (p_session, p_user, 'aal1', p_created);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), p_method);
  select p_session;
$$;

-- A fresh password sign-in: after the latest epoch plus the 5 s margin.
create function pg_temp.fresh(p_user uuid, p_session uuid) returns uuid
language sql as $$
  select pg_temp.session(p_user, p_session, 'password', clock_timestamp() + interval '6 seconds')
$$;

create function pg_temp.link(p_user uuid) returns app.identity_account_links
language sql as $$
  select l from app.identity_account_links l where l.auth_user_id = p_user and l.link_state <> 'ended'
$$;

-- Auth-side (and hold) events of the account's links, oldest first.
create function pg_temp.events(p_user uuid) returns text
language sql as $$
  select coalesce(string_agg(e.source || ':' || array_to_string(e.kinds, '+') || ':'
                             || case when e.binding_review then 'review' else 'epoch' end, ', '
                             order by e.event_id), '')
    from app.identity_credential_events e
    join app.identity_account_links l using (link_id)
   where l.auth_user_id = p_user and e.source <> 'identity_account_links'
$$;

-- Link-state events of the account's links, oldest first.
create function pg_temp.link_events(p_user uuid) returns text
language sql as $$
  select coalesce(string_agg(array_to_string(e.kinds, '+'), ', ' order by e.event_id), '')
    from app.identity_credential_events e
    join app.identity_account_links l using (link_id)
   where l.auth_user_id = p_user and e.source = 'identity_account_links'
$$;

-- The reviewed re-approval of entries 5/8 (restricted operator): records a new binding revision
-- and makes the link active.
create function pg_temp.reapprove(p_user uuid) returns void
language sql as $$
  update app.identity_account_links set link_state = 'active', binding_revision = binding_revision + 1
   where auth_user_id = p_user and link_state <> 'ended';
$$;

-- Structure and privileges ---------------------------------------------------------------------
select has_column('app', 'identity_account_links', 'credential_generation', 'links carry a credential generation');
select has_column('app', 'identity_account_links', 'sessions_valid_after', 'links carry a session trust epoch');
select has_column('app', 'identity_account_links', 'binding_review_required', 'links carry a durable binding review flag');
select has_table('app', 'identity_credential_events', 'credential events table exists');
select is(app.identity_epoch_margin(), interval '5 seconds', 'the epoch safety margin is 5 seconds');
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
                             'app.identity_on_auth_mfa_change()', 'app.identity_on_link_update()',
                             'app.identity_on_link_insert()', 'app.identity_on_link_inserted()',
                             'app.identity_on_hold_placed()', 'app.identity_epoch_margin()',
                             'app.identity_access_evaluate()']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'detection functions and the predicate have no client grants');
select has_trigger('auth', 'users', 'identity_credential_change', 'auth.users change trigger');
select has_trigger('auth', 'users', 'identity_credential_delete', 'auth.users delete trigger');
select has_trigger('auth', 'identities', 'identity_credential_identity_change', 'auth.identities insert/delete trigger');
select has_trigger('auth', 'identities', 'identity_credential_identity_moved', 'auth.identities move trigger');
select has_trigger('auth', 'mfa_factors', 'identity_credential_mfa_change', 'auth.mfa_factors insert/delete trigger');
select has_trigger('auth', 'mfa_factors', 'identity_credential_mfa_update', 'auth.mfa_factors update trigger');

-- Fixtures -------------------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.2');
insert into auth.users (id, aud, role, phone, phone_confirmed_at) values
  (pg_temp.u(1), 'authenticated', 'authenticated', '12025550121', now()),
  (pg_temp.u(2), 'authenticated', 'authenticated', '12025550122', now()),
  (pg_temp.u(3), 'authenticated', 'authenticated', '447700900122', now()),
  (pg_temp.u(4), 'authenticated', 'authenticated', '12025550124', now()),
  (pg_temp.u(5), 'authenticated', 'authenticated', '12025550125', now()),
  (pg_temp.u(6), 'authenticated', 'authenticated', '12025550126', now()),
  (pg_temp.u(7), 'authenticated', 'authenticated', '12025550131', now()),
  (pg_temp.u(8), 'authenticated', 'authenticated', '12025550132', now());
update auth.users set email = 'synthetic-2-2-alias@example.test', email_confirmed_at = now()
 where id = pg_temp.u(2);
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.2 Member ' || n, 'pgtap 2.2')
  from unnest(array[1, 2, 3, 4, 5, 7, 8]) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n), 'password', now() - interval '1 hour')
  from generate_series(1, 8) n;
select is((select count(*)::int from app.identity_account_links
            where auth_user_id = any (array[pg_temp.u(1), pg_temp.u(2)]) and sessions_valid_after is null),
  2, 'a first link for a fresh signup has no trust epoch');

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
select is(pg_temp.events(pg_temp.u(1)) || pg_temp.link_events(pg_temp.u(1)), '',
  'sessions and AMR records are not credential changes');

-- Direct Auth phone change: durable review, epoch, generation ----------------------------------
update app.identity_account_links set last_member_activity_at = '2026-10-01T00:00:00Z'
 where auth_user_id = pg_temp.u(1);
update auth.users set phone = '12025550129' where id = pg_temp.u(1);
select is((pg_temp.link(pg_temp.u(1))).link_state, 'review_required', 'a direct phone change moves the link to review');
select ok((pg_temp.link(pg_temp.u(1))).binding_review_required, 'and records a pending binding review');
select is((pg_temp.link(pg_temp.u(1))).credential_generation, 2::bigint, 'and advances the credential generation');
select ok((pg_temp.link(pg_temp.u(1))).sessions_valid_after is not null, 'and sets the session trust epoch');
select is(pg_temp.events(pg_temp.u(1)), 'auth_users:phone:review', 'the change is recorded by kind only');
select is(pg_temp.link_events(pg_temp.u(1)), 'link_review_required', 'the link state move is recorded too');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT403|forbidden|review_required',
  'stale token after a direct phone change: review required');
update auth.users set phone = '12025550121' where id = pg_temp.u(1);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT403|forbidden|review_required',
  'changing the phone back does not restore access (detection, not value comparison)');
select is((pg_temp.link(pg_temp.u(1))).credential_generation, 3::bigint, 'the revert is a change too');
update app.identity_account_links set binding_review_required = false where auth_user_id = pg_temp.u(1);
select ok((pg_temp.link(pg_temp.u(1))).binding_review_required,
  'the binding review cannot be cleared without a new binding revision');
select pg_temp.session(pg_temp.u(1), pg_temp.s(14));  -- opened while the link is in review
select pg_temp.reapprove(pg_temp.u(1));
select ok(not (pg_temp.link(pg_temp.u(1))).binding_review_required, 're-approval with a new binding revision clears it');
select is(pg_temp.link_events(pg_temp.u(1)), 'link_review_required, link_active', 'the re-approval is recorded');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(1))), 'PT401|unauthenticated|untrusted_session',
  'after re-approval the pre-change session stays dead');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(14))), 'PT401|unauthenticated|untrusted_session',
  'a session opened while the link was in review is not admitted by the re-approval');
select pg_temp.fresh(pg_temp.u(1), pg_temp.s(13));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(13))), 'ok', 'a fresh password sign-in is granted');
select is((pg_temp.link(pg_temp.u(1))).last_member_activity_at > '2026-10-01T00:00:00Z', true,
  'only that granted read wrote activity');
select pg_temp.session(pg_temp.u(1), pg_temp.s(15), 'password',
  (pg_temp.link(pg_temp.u(1))).sessions_valid_after + interval '4 seconds');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(15))), 'PT401|unauthenticated|untrusted_session',
  'a session within the 5 s margin after the epoch is not trusted (clock skew, open transaction)');

-- Suspension does not launder a binding change --------------------------------------------------
update app.identity_account_links set link_state = 'suspended' where auth_user_id = pg_temp.u(8);
update auth.users set phone = '12025550133' where id = pg_temp.u(8);
update auth.users set phone = '12025550132' where id = pg_temp.u(8);
select is((pg_temp.link(pg_temp.u(8))).link_state, 'suspended', 'a suspended link stays suspended on a change');
update app.identity_account_links set link_state = 'active' where auth_user_id = pg_temp.u(8);
select pg_temp.fresh(pg_temp.u(8), pg_temp.s(81));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(8), pg_temp.s(81))), 'PT403|forbidden|review_required',
  'suspend, change, revert, unsuspend, fresh sign-in: still review required');
select is(pg_temp.link_events(pg_temp.u(8)), 'link_suspended, link_active', 'suspension and its lifting are recorded');
select pg_temp.reapprove(pg_temp.u(8));
select pg_temp.fresh(pg_temp.u(8), pg_temp.s(82));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(8), pg_temp.s(82))), 'ok', 'after re-approval a fresh sign-in is granted');

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
select pg_temp.fresh(pg_temp.u(2), pg_temp.s(21));
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
select pg_temp.fresh(pg_temp.u(3), pg_temp.s(31));
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
update auth.mfa_factors set status = status, updated_at = now() where user_id = pg_temp.u(4);
select is(pg_temp.events(pg_temp.u(4)),
  'auth_identities:identity_added:review, auth_identities:identity_removed:review, '
  'auth_mfa_factors:mfa_added:review, auth_mfa_factors:mfa_changed:review',
  'identity add/remove and MFA add/verify are recorded; a no-op MFA update records nothing');
delete from auth.mfa_factors where user_id = pg_temp.u(4);
insert into auth.identities (provider_id, user_id, identity_data, provider)
values ('synthetic-2-2-moved', pg_temp.u(6), '{"sub": "synthetic-2-2-moved"}', 'synthetic');
update auth.identities set user_id = pg_temp.u(4) where provider_id = 'synthetic-2-2-moved';
update auth.identities set provider_id = 'synthetic-2-2-moved-2' where provider_id = 'synthetic-2-2-moved';
update auth.identities set identity_data = '{"sub": "x"}' where provider_id = 'synthetic-2-2-moved-2';
select is(pg_temp.events(pg_temp.u(4)),
  'auth_identities:identity_added:review, auth_identities:identity_removed:review, '
  'auth_mfa_factors:mfa_added:review, auth_mfa_factors:mfa_changed:review, auth_mfa_factors:mfa_removed:review, '
  'auth_identities:identity_moved:review, auth_identities:identity_moved:review',
  'an identity re-pointed to this account, or to another provider id, is recorded (other updates are not)');
select is((pg_temp.link(pg_temp.u(4))).credential_generation, 8::bigint, 'each advanced the generation');

-- Ban, soft delete and hard delete -------------------------------------------------------------
update auth.users set banned_until = now() + interval '1 day' where id = pg_temp.u(5);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(5))), 'PT401|unauthenticated|untrusted_session',
  'banned (revoked by Auth Admin): denied');
update auth.users set banned_until = null where id = pg_temp.u(5);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(5))), 'PT401|unauthenticated|untrusted_session',
  'unbanning does not bring the old session back');
select is((pg_temp.link(pg_temp.u(5))).link_state, 'active', 'a ban is not a binding change');
select pg_temp.fresh(pg_temp.u(5), pg_temp.s(51));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(5), pg_temp.s(51))), 'ok', 'fresh sign-in after unban: granted');
select is(pg_temp.events(pg_temp.u(5)), 'auth_users:ban_changed:epoch, auth_users:ban_changed:epoch',
  'ban and unban are recorded');
update auth.users set deleted_at = now() where id = pg_temp.u(5);
select is((pg_temp.link(pg_temp.u(5))).link_state, 'review_required', 'an Auth soft delete puts the link in review');
delete from auth.users where id = pg_temp.u(4);
select is((select link_state from app.identity_account_links where auth_user_id = pg_temp.u(4)),
  'review_required', 'an Auth hard delete leaves the link in review');

-- Holds move the epoch ---------------------------------------------------------------------------
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'pgtap 2.2 synthetic hold', 'pgtap'
  from app.identity_account_links where auth_user_id = pg_temp.u(7);
select is(pg_temp.read(pg_temp.claims(pg_temp.u(7), pg_temp.s(7))), 'PT403|forbidden|review_required',
  'an open hold: review required');
update app.identity_holds set released_at = now(), released_by = 'pgtap'
 where member_id = (pg_temp.link(pg_temp.u(7))).member_id;
select is(pg_temp.read(pg_temp.claims(pg_temp.u(7), pg_temp.s(7))), 'PT401|unauthenticated|untrusted_session',
  'released hold: sessions from before the hold stay dead');
select pg_temp.fresh(pg_temp.u(7), pg_temp.s(71));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(7), pg_temp.s(71))), 'ok', 'fresh sign-in after release: granted');
select is(pg_temp.events(pg_temp.u(7)), 'identity_holds:hold_security:epoch', 'the hold is recorded');

-- Relink after an ended link -------------------------------------------------------------------
update app.identity_account_links set link_state = 'ended', ended_at = now() where auth_user_id = pg_temp.u(3);
select is((select kinds[1] from app.identity_credential_events e join app.identity_account_links l using (link_id)
            where l.auth_user_id = pg_temp.u(3) order by e.event_id desc limit 1), 'link_ended', 'ending a link is recorded');
select pg_temp.session(pg_temp.u(3), pg_temp.s(33));  -- a session from while the account was unlinked
select app.identity_seed_synthetic_link(pg_temp.u(3), 'SYNTHETIC 2.2 Member 3 relinked', 'pgtap 2.2');
select ok((pg_temp.link(pg_temp.u(3))).sessions_valid_after is not null, 'a relink starts with a trust epoch');
select ok((pg_temp.link(pg_temp.u(3))).credential_generation > 2, 'and continues the credential generation');
select is(pg_temp.link_events(pg_temp.u(3)), 'link_ended, link_relinked', 'the relink is recorded');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(3))), 'PT401|unauthenticated|untrusted_session',
  'relink after end: the session from the old link is not re-admitted');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(33))), 'PT401|unauthenticated|untrusted_session',
  'relink after end: a session opened while unlinked is not admitted');
select pg_temp.fresh(pg_temp.u(3), pg_temp.s(34));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(3), pg_temp.s(34))), 'ok', 'relink: a fresh sign-in is granted');

-- Unlinked and ended links are untouched -------------------------------------------------------
update auth.users set phone = '12025550127', encrypted_password = 'x' where id = pg_temp.u(6);
select is((select count(*)::int from app.identity_credential_events e
            join app.identity_account_links l using (link_id) where l.auth_user_id = pg_temp.u(6)),
  0, 'changes on an unlinked account record nothing and do not fail');
select is((select count(*)::int from app.identity_account_links where auth_user_id = pg_temp.u(3) and link_state = 'ended'),
  1, 'the ended link stays ended');
update auth.users set phone = '447700900123' where id = pg_temp.u(3);
select is((select count(*)::int from app.identity_account_links where auth_user_id = pg_temp.u(3) and link_state = 'ended'),
  1, 'an ended link is never reopened by a later change');

-- Denials never write activity; dormancy reads prior activity ------------------------------------
select is((pg_temp.link(pg_temp.u(2))).last_member_activity_at is not null, true, 'alias member has activity');
update app.identity_account_links set last_member_activity_at = now() - interval '91 days'
 where auth_user_id = pg_temp.u(2);
select pg_temp.fresh(pg_temp.u(2), pg_temp.s(22));
select is(pg_temp.read(pg_temp.claims(pg_temp.u(2), pg_temp.s(22))), 'PT403|forbidden|review_required',
  'dormant (labelled 90-day fixture): a fresh password session is still denied');
select ok((pg_temp.link(pg_temp.u(2))).last_member_activity_at < now() - interval '90 days',
  'the dormancy denial wrote no activity');
select is(pg_temp.events(pg_temp.u(2)), 'auth_users:email:review, auth_users:email:review',
  'denied reads record no credential events (only the email change and its revert)');
select is(app.identity_current_member_id(), null, 'identity_current_member_id: dormant caller is null');

select * from finish();
rollback;
