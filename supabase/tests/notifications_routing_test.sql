-- Recipient routing, device tokens, push settings, lifecycle and deletion hooks (story 3.5;
-- AD-3, AD-8, AD-14; epic 3 N5): an active linked account gets the inbox item and one pending
-- member-push job; held, deactivated and accountless members get a direct-contact need instead
-- (never a relative's contact); deleted and never-approved members get nothing; Identity's
-- lifecycle events retire tokens and cancel member-push jobs; the deletion hook erases every
-- notification row. HTTP evidence: tools/identity-e2e/routing.mjs. Every account here is
-- SYNTHETIC (+44 7700 900880-900888).
begin;
select plan(100);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000350' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000350' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (880 + n)::text $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1', 'session_id', pg_temp.s(n),
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint,
                             p_payload jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.read(n int, p_sql text) returns jsonb language plpgsql as $$
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
create function pg_temp.err(r jsonb) returns text language sql as
$$ select (r ->> 'code') || ' ' || coalesce(r -> 'field_errors', '{}'::jsonb)::text $$;
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.dev(n int, p_command text, p_expected bigint, p_payload jsonb) returns jsonb
language sql as $$ select pg_temp.call(n, 'notifications_command', p_command, p_expected, p_payload) $$;
create function pg_temp.tok(p_fill text) returns text language sql as
$$ select 'fcm-' || repeat(p_fill, 40) || ':APA91b' $$;
-- The Admin (1) creates a due SYNTHETIC reminder for member n; returns its job id.
create function pg_temp.for_member(n int, p_due timestamptz default now() - interval '1 minute')
returns uuid language plpgsql as $$
declare
  v_source uuid;
  v_job uuid;
begin
  v_source := (pg_temp.call(1, 'fixture_reminder_command', 'fixture.reminder_create_for', null,
                 jsonb_build_object('member_id', pg_temp.mid(n), 'due_at', app.cmd_utc(p_due)))
               -> 'data' ->> 'source_id')::uuid;
  select j.job_id into v_job from app.notifications_jobs j where j.source_id = v_source;
  return v_job;
end;
$$;
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.st(p_job uuid) returns text language sql as $$
  select job_state || '|' || coalesce(finish_reason, cancel_reason, '-') from app.notifications_jobs
   where job_id = p_job
$$;
create function pg_temp.items(n int) returns int language sql as
$$ select count(*)::int from app.notifications_inbox_items where recipient_member_id = pg_temp.mid($1) $$;
create function pg_temp.push(p_job uuid) returns text language sql as $$
  select coalesce((select push_state || '|' || coalesce(finish_reason, '-')
                     from app.notifications_push_jobs where job_id = p_job), 'none')
$$;
create function pg_temp.lifecycle(p_event text, n int) returns int language sql as $$
  select app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', p_event, 'member_id', pg_temp.mid(n), 'occurred_at', app.cmd_utc(now()),
    'identity_revision', pg_temp.mrev(n)))
$$;
create function pg_temp.tokens(n int) returns text language sql as $$
  select coalesce(string_agg(coalesce(retire_reason, 'live'), ',' order by registered_at, device_id), '')
    from app.notifications_device_tokens where member_id = pg_temp.mid($1)
$$;

-- Accounts: 1 Admin; 2 active; 3 held; 4 deactivated; 5 (no account) accountless with a
-- relative's contact number, the relative being 6 (active, with a device); 7 lost device;
-- 8 never approved (no account); 9 deleted.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n where n not in (5, 8);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n where n not in (5, 8);
select app.platform_set_environment('local', 'pgtap 3.5');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.5 Member ' || n, 'pgtap 3.5')
  from generate_series(1, 9) n where n not in (5, 8);
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 3.5 Accountless', 'approved', true) returning member_id)
insert into m select 5, member_id from ins;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 3.5 Applicant', 'pending', true) returning member_id)
insert into m select 8, member_id from ins;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_contact_routes (member_id, kind, value, belongs_to, holder_label, is_synthetic,
                                         created_by_member, created_by_account)
values (pg_temp.mid(5), 'phone', pg_temp.phone(6), 'relative', 'Daughter', true, pg_temp.mid(1), pg_temp.u(1));

-- Structure, privileges and guards -------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.contract_direct_contact_routes', 'app.notifications_direct_contact_needs',
                             'app.notifications_device_tokens', 'app.notifications_push_settings',
                             'app.notifications_push_jobs', 'app.fixture_reminder_contact_needs']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the new tables');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname in ('app', 'api')
     and (p.proname ~ '^notifications_' or p.proname ~ '^contract_(register_)?(route_)?direct_contact'
          or p.proname in ('fixture_reminder_direct_contact', 'fixture_reminder_create_for',
                           'fixture_deletion_purge_rows', 'fixture_erase_member'))
     and not (p.proname in ('notifications_command', 'notifications_my_push_settings',
                            'notifications_my_inbox', 'notifications_open_item') and r = 'authenticated')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'only the member command and reads are client-executable, and only by authenticated');
select is((select handler from app.identity_deletion_hooks where module = 'notifications'),
  'app.notifications_erase_member(jsonb)', 'Notifications registered its deletion hook');
select is((select handler from app.identity_deletion_hooks where module = 'fixture'),
  'app.fixture_erase_member(jsonb)', 'the fixture deletion hook is registered by migration');
select is((select string_agg(event, ',' order by event) from app.contract_lifecycle_hooks
            where module = 'notifications' and handler = 'app.notifications_on_member_lifecycle(jsonb)'),
  'access_hold_applied,account_deactivated,deletion_requested,membership_deactivated,sessions_revoked',
  'Notifications hooks the five lifecycle events');
select is((select handler from app.contract_direct_contact_routes
            where source_type = 'fixture_reminder' and reminder_kind = 'fixture_due'),
  'app.fixture_reminder_direct_contact(jsonb)', 'the fixture registered its direct-contact route');

-- Direct-contact route registration refusals ---------------------------------------------------
select throws_ok($$select app.contract_register_direct_contact_route('cells', 'fixture_reminder', 'fixture_due',
                     'app.fixture_reminder_direct_contact(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'only the source''s owner registers its route');
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_no_contract');
select throws_ok($$select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_no_contract',
                     'app.fixture_reminder_direct_contact(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a kind without a reminder contract cannot have a route');
select throws_ok($$select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_due',
                     'app.fixture_reminder_open_check(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a route must take (jsonb) and return void');

-- Devices and push settings (member commands) ----------------------------------------------------
create temp table d (k text primary key, v jsonb);
insert into d values ('2a', pg_temp.dev(2, 'notifications.register_device', null,
                              jsonb_build_object('token', pg_temp.tok('a'), 'platform', 'android')));
select is(d.v -> 'data' ->> 'platform', 'android', 'a member registers a device') from d where k = '2a';
select ok(not (d.v::text like '%' || pg_temp.tok('a') || '%') and not (d.v -> 'data' ? 'token'),
  'the answer never carries the token') from d where k = '2a';
insert into d values ('2a2', pg_temp.dev(2, 'notifications.register_device', null,
                               jsonb_build_object('token', pg_temp.tok('a'), 'platform', 'android')));
select is((select v -> 'data' ->> 'device_id' from d where k = '2a2'), (select v -> 'data' ->> 'device_id' from d where k = '2a'),
  'registering the same token again refreshes the same device');
select is((select (v ->> 'revision')::int from d where k = '2a2'), 2, 'and bumps its revision');
insert into d values ('6a', pg_temp.dev(6, 'notifications.register_device', null,
                              jsonb_build_object('token', pg_temp.tok('a'), 'platform', 'ios')));
select is(pg_temp.tokens(2), 'reassigned', 'a token registered by another account is retired on the first');
select is(pg_temp.tokens(6), 'live', 'and live on the new one');
select is(pg_temp.err(pg_temp.dev(2, 'notifications.register_device', null, '{"token": "short", "platform": "web", "x": 1}')),
  'validation_failed {"x": "unknown_field", "token": "invalid", "platform": "invalid"}', 'shape is checked');
select pg_temp.dev(6, 'notifications.register_device', null,
                   jsonb_build_object('token', pg_temp.tok(chr(98 + n)), 'platform', 'android'))
  from generate_series(0, 10) n;
select is((select count(*)::int from app.notifications_device_tokens where member_id = pg_temp.mid(6) and retired_at is null),
  10, 'an account keeps at most ten live tokens');
select is((select retire_reason from app.notifications_device_tokens where token = pg_temp.tok('a') and member_id = pg_temp.mid(6)),
  'replaced', 'the least recently refreshed token was replaced');
select is(pg_temp.err(pg_temp.dev(2, 'notifications.retire_device', 1,
            jsonb_build_object('device_id', (select v -> 'data' ->> 'device_id' from d where k = '6a')))),
  'not_found {}', 'another account''s device is not found');
insert into d values ('2b', pg_temp.dev(2, 'notifications.register_device', null,
                              jsonb_build_object('token', pg_temp.tok('z'), 'platform', 'android')));
select is(pg_temp.err(pg_temp.dev(2, 'notifications.retire_device', 7,
            jsonb_build_object('device_id', (select v -> 'data' ->> 'device_id' from d where k = '2b')))),
  'conflict {}', 'a stale revision conflicts');
select is((pg_temp.dev(2, 'notifications.retire_device', 1,
            jsonb_build_object('device_id', (select v -> 'data' ->> 'device_id' from d where k = '2b'))) -> 'data' ->> 'retired'),
  'true', 'the member retires their own device');
select is(pg_temp.err(pg_temp.dev(2, 'notifications.retire_device', 2,
            jsonb_build_object('device_id', (select v -> 'data' ->> 'device_id' from d where k = '2b')))),
  'conflict {"device_id": "retired"}', 'a retired device cannot be retired again');
insert into d values ('2c', pg_temp.dev(2, 'notifications.register_device', null,
                              jsonb_build_object('token', pg_temp.tok('y'), 'platform', 'android')));
select is(pg_temp.err(pg_temp.dev(2, 'notifications.set_push_category', null,
            '{"source_type": "fixture_reminder", "reminder_kind": "fixture_no_contract", "push_enabled": false}')),
  'validation_failed {"reminder_kind": "unregistered"}', 'a kind without a contract is not a category');
select is(pg_temp.err(pg_temp.dev(2, 'notifications.set_push_category', 1,
            '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": false}')),
  'conflict {}', 'a setting that does not exist cannot be updated');
select is((pg_temp.dev(2, 'notifications.set_push_category', null,
            '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": false}') ->> 'revision')::int,
  1, 'the member turns push off for the category');
select is((pg_temp.dev(2, 'notifications.set_push_category', null,
            '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": true}') ->> 'current_revision')::int,
  1, 'creating it again conflicts with the current revision');
select is((pg_temp.read(2, 'select api.notifications_my_push_settings()') -> 'categories')
            @> '[{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": false, "revision": 1}]'::jsonb,
  true, 'the read lists the category with its setting');
select is((select count(*)::int from jsonb_array_elements(pg_temp.read(2, 'select api.notifications_my_push_settings()') -> 'devices')),
  1, 'the read lists the live devices');
select ok(pg_temp.read(2, 'select api.notifications_my_push_settings()')::text not like '%fcm-%',
  'the read never carries a token');
select ok(not has_function_privilege('anon', 'api.notifications_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.notifications_my_push_settings()', 'EXECUTE'),
  'signed-out callers cannot execute the command or the read');

-- Hold, deactivation (real Identity commands) -------------------------------------------------
select pg_temp.dev(3, 'notifications.register_device', null,
                   jsonb_build_object('token', pg_temp.tok('h'), 'platform', 'android'));
select pg_temp.dev(4, 'notifications.register_device', null,
                   jsonb_build_object('token', pg_temp.tok('d'), 'platform', 'android'));
create temp table j (k text primary key, v uuid);
insert into j values ('active', pg_temp.for_member(2)), ('held', pg_temp.for_member(3)),
                     ('deactivated', pg_temp.for_member(4)), ('accountless', pg_temp.for_member(5)),
                     ('applicant', pg_temp.for_member(8));
select is((select count(*)::int from app.notifications_jobs where job_id in (select v from j)), 5,
  'the Admin enqueued one job for each recipient through the API');
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(3),
            jsonb_build_object('member_id', pg_temp.mid(3), 'reason_code', 'security_concern')) ->> 'code',
  null, 'the Admin places a hold on member 3');
select is(pg_temp.tokens(3), 'access_hold_applied', 'the hold retired the held member''s token in Identity''s transaction');
select is(pg_temp.err(pg_temp.dev(3, 'notifications.register_device', null,
            jsonb_build_object('token', pg_temp.tok('i'), 'platform', 'android'))),
  'forbidden {}', 'a held member cannot register a device');
select is(pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(4),
            jsonb_build_object('member_id', pg_temp.mid(4), 'reason_code', 'church_decision')) ->> 'code',
  null, 'the Admin deactivates member 4');
select is(pg_temp.tokens(4), 'membership_deactivated', 'the deactivation retired their token');

-- Routing --------------------------------------------------------------------------------------
select is(pg_temp.run(), '{"claimed": 5, "delivered": 1, "obsolete": 0, "ineligible": 4, "failed": 0}'::jsonb,
  'one worker run: one delivery, four without member delivery');
select is(pg_temp.st((select v from j where k = 'active')), 'delivered|delivered', 'the active member''s job is delivered');
select is(pg_temp.items(2), 1, 'the active member has the inbox item');
select is(pg_temp.push((select v from j where k = 'active')), 'none',
  'push off for the category: no member-push job');
select is(pg_temp.st((select v from j where k = 'held')), 'ineligible|direct_contact', 'held: routed to direct contact');
select is(pg_temp.st((select v from j where k = 'deactivated')), 'ineligible|direct_contact', 'deactivated: routed to direct contact');
select is(pg_temp.st((select v from j where k = 'accountless')), 'ineligible|direct_contact', 'accountless: routed to direct contact');
select is(pg_temp.st((select v from j where k = 'applicant')), 'ineligible|membership_inactive', 'never approved: no route');
select is((select pg_temp.items(3) + pg_temp.items(4) + pg_temp.items(5) + pg_temp.items(8)), 0,
  'none of them has an inbox item');
select is((select count(*)::int from app.notifications_push_jobs where recipient_member_id in
            (pg_temp.mid(3), pg_temp.mid(4), pg_temp.mid(5), pg_temp.mid(8))), 0, 'nor a member-push job');
select is((select string_agg(route_state, ',' order by recipient_member_id) from app.notifications_direct_contact_needs
            where job_id in (select v from j)), 'routed,routed,routed', 'three needs recorded, each routed');
select is((select count(*)::int from app.fixture_reminder_contact_needs n
             join app.notifications_direct_contact_needs x on x.need_id = n.need_id
            where n.member_id in (pg_temp.mid(3), pg_temp.mid(4), pg_temp.mid(5))), 3,
  'the source owner''s Needs direct contact list has all three, by need id');
select is((select count(*)::int from app.notifications_jobs where recipient_member_id = pg_temp.mid(6))
          + (select count(*)::int from app.notifications_inbox_items where recipient_member_id = pg_temp.mid(6))
          + (select count(*)::int from app.notifications_push_jobs where recipient_member_id = pg_temp.mid(6)), 0,
  'the relative whose number is the accountless member''s contact route gets no job, item or push');
select ok(not exists (select 1 from app.notifications_direct_contact_needs n
                       where to_jsonb(n)::text like '%' || ltrim(pg_temp.phone(6), '+') || '%')
          and not exists (select 1 from app.fixture_reminder_contact_needs n
                           where to_jsonb(n)::text like '%' || ltrim(pg_temp.phone(6), '+') || '%'),
  'no need carries a contact number');
select is(pg_temp.run(), '{"claimed": 0, "delivered": 0, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'a second run routes nothing twice');

-- Push settings decide member-push work --------------------------------------------------------
select pg_temp.dev(2, 'notifications.set_push_category', 1,
                   '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": true}');
insert into j values ('active2', pg_temp.for_member(2));
select is((pg_temp.run() ->> 'delivered')::int, 1, 'the next reminder is delivered');
select is(pg_temp.push((select v from j where k = 'active2')), 'pending|-',
  'push on and a live token: one pending member-push job');
select is((select account_id from app.notifications_push_jobs where job_id = (select v from j where k = 'active2')),
  pg_temp.u(2), 'bound to the member''s linked account');
insert into j values ('relative', pg_temp.for_member(6));
select is((pg_temp.run() ->> 'delivered')::int, 1, 'an active member with a token is delivered');
select is(pg_temp.push((select v from j where k = 'relative')), 'pending|-', 'and gets member-push work');

-- No registered route, and a raising route -----------------------------------------------------
create temp table saved_route as select * from app.contract_direct_contact_routes where reminder_kind = 'fixture_due';
delete from app.contract_direct_contact_routes where reminder_kind = 'fixture_due';
insert into j values ('unrouted', pg_temp.for_member(5));
select is((pg_temp.run() ->> 'ineligible')::int, 1, 'without a registered route the job still ends');
select is(pg_temp.st((select v from j where k = 'unrouted')), 'ineligible|no_direct_contact_route',
  'with the reason no_direct_contact_route');
select is((select route_state from app.notifications_direct_contact_needs where job_id = (select v from j where k = 'unrouted')),
  'unrouted', 'and the need is recorded unrouted');
create function app.fixture_raising_route(p jsonb) returns void language plpgsql set search_path = '' as $$
begin
  raise exception 'synthetic route failure';
end; $$;
select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_due',
         'app.fixture_raising_route(jsonb)'::regprocedure);
insert into j values ('raising', pg_temp.for_member(5));
select is((pg_temp.run() ->> 'failed')::int, 1, 'a raising route is a transient failure');
select is(pg_temp.st((select v from j where k = 'raising')), 'pending|-', 'the job stays pending to be retried');
select is((select count(*)::int from app.notifications_direct_contact_needs where job_id = (select v from j where k = 'raising')),
  0, 'and no need was recorded');
select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_due',
         'app.fixture_reminder_direct_contact(jsonb)'::regprocedure);
drop function app.fixture_raising_route(jsonb);
update app.notifications_jobs set last_failed_at = now() - interval '1 day' where job_id = (select v from j where k = 'raising');
select is((pg_temp.run() ->> 'ineligible')::int, 1, 'the retry routes it');
select is(pg_temp.st((select v from j where k = 'raising')), 'ineligible|direct_contact', 'to direct contact');

-- No token: item only; a link in review: direct contact ----------------------------------------
insert into j values ('notoken', pg_temp.for_member(7));
select is((pg_temp.run() ->> 'delivered')::int, 1, 'an active member without a device is delivered');
select is(pg_temp.push((select v from j where k = 'notoken')), 'none', 'but gets no member-push job');
update app.identity_account_links set binding_review_required = true where member_id = pg_temp.mid(2) and link_state = 'active';
insert into j values ('review', pg_temp.for_member(2));
select is((pg_temp.run() ->> 'ineligible')::int, 1, 'a member whose link is in review gets no item');
select is(pg_temp.st((select v from j where k = 'review')), 'ineligible|direct_contact', 'the need goes to direct contact');
update app.identity_account_links set binding_review_required = false where member_id = pg_temp.mid(2) and link_state = 'active';

-- Lifecycle events retire tokens and cancel member-push work ----------------------------------
select pg_temp.dev(7, 'notifications.register_device', null,
                   jsonb_build_object('token', pg_temp.tok('l'), 'platform', 'ios'));
insert into j values ('lost', pg_temp.for_member(7));
select is((pg_temp.run() ->> 'delivered')::int, 1, 'member 7 gets an item');
select is(pg_temp.push((select v from j where k = 'lost')), 'pending|-', 'and pending member-push work');
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(7),
            jsonb_build_object('member_id', pg_temp.mid(7), 'reason_code', 'lost_device')) ->> 'code',
  null, 'a lost-device hold (sessions revoked) is placed');
select is(pg_temp.tokens(7), 'access_hold_applied', 'the token is retired');
select is(pg_temp.push((select v from j where k = 'lost')), 'cancelled|access_hold_applied',
  'the pending member-push job is cancelled in Identity''s transaction');
select is(pg_temp.items(7), 2, 'the inbox items stay');
select is(pg_temp.lifecycle('sessions_revoked', 2), 1, 'sessions_revoked reaches Notifications');
select is(pg_temp.tokens(2), 'reassigned,member_retired,sessions_revoked', 'and retires the member''s live token');
select is(pg_temp.push((select v from j where k = 'active2')), 'cancelled|sessions_revoked', 'and cancels their push job');
select is(pg_temp.lifecycle('account_deactivated', 6), 1, 'account_deactivated reaches Notifications');
select is((select count(*)::int from app.notifications_device_tokens where member_id = pg_temp.mid(6) and retired_at is null),
  0, 'every token of the unlinked member is retired');
select is(pg_temp.push((select v from j where k = 'relative')), 'cancelled|account_deactivated', 'and their push job cancelled');

-- Deletion: tombstone, hook cancel, erase and check -------------------------------------------
select pg_temp.dev(9, 'notifications.register_device', null,
                   jsonb_build_object('token', pg_temp.tok('x'), 'platform', 'android'));
select pg_temp.dev(9, 'notifications.set_push_category', null,
                   '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": true}');
insert into j values ('del_due', pg_temp.for_member(9)), ('del_future', pg_temp.for_member(9, now() + interval '2 days'));
select is((pg_temp.run() ->> 'delivered')::int, 1, 'the member to be deleted has an item');
select app.notifications_set_schedule(jsonb_build_object(
  'source_type', 'fixture_reminder', 'source_id', (select source_id from app.notifications_jobs where job_id = (select v from j where k = 'del_future')),
  'source_revision', 1, 'recipient_member_id', pg_temp.mid(9), 'schedule_type', 'task',
  'intent', jsonb_build_object('due_at', app.cmd_utc(now() + interval '3 days'), 'task_state', 'open'),
  'kinds', '{"deadline": "fixture_due"}'::jsonb, 'fresh', true));
select is(pg_temp.lifecycle('deletion_requested', 9), 1, 'deletion_requested reaches Notifications');
select is((select count(*)::int from app.notifications_jobs where recipient_member_id = pg_temp.mid(9) and job_state = 'pending'),
  0, 'the deletion request cancels every pending job of the member');
select is((select string_agg(schedule_state || '|' || end_reason, ',') from app.notifications_schedules
            where recipient_member_id = pg_temp.mid(9)), 'ended|member_deleted', 'and ends their schedules');
select is(pg_temp.tokens(9), 'deletion_requested', 'and retires their tokens');
insert into j values ('del_route', pg_temp.for_member(9));
insert into app.identity_deletions (member_id, had_account, origin, is_synthetic)
values (pg_temp.mid(9), true, 'member_request', true);
select is((pg_temp.run() ->> 'ineligible')::int, 1, 'a job of a member with a deletion tombstone is not delivered');
select is(pg_temp.st((select v from j where k = 'del_route')), 'ineligible|member_deleted', 'it ends member_deleted, with no need');
select throws_ok(format($$select app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', %L, 'source_revision', 1,
    'recipient_member_id', %L, 'reminder_kind', 'fixture_due', 'scheduled_at', app.cmd_utc(now())))$$,
    (select source_id from app.notifications_jobs where job_id = (select v from j where k = 'del_future')), pg_temp.mid(9)),
  'PCMD1', 'validation_failed', 'nothing can be enqueued for a member with a deletion tombstone');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(9), pg_temp.u(9), gen_random_uuid(), 'check')) r
            where r ->> 'module' = 'notifications') > 0, true, 'before erasure the check counts notification rows');
-- Fail closed while the rows file is missing (simulated in this transaction).
create or replace function app.notifications_deletion_purge_rows(p_member_id uuid, p_account_id uuid)
returns integer language plpgsql set search_path = '' as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end; $$;
select throws_ok(format($$select app.notifications_erase_member(jsonb_build_object(
    'member_id', %L, 'account_id', %L, 'deletion_id', gen_random_uuid(), 'phase', 'erase'))$$, pg_temp.mid(9), pg_temp.u(9)),
  'PCMD1', 'unavailable', 'without the rows file the erase step is unavailable');
-- Restore the real body (as in 20261008143100_notifications_routing_rows.sql).
create or replace function app.notifications_deletion_purge_rows(p_member_id uuid, p_account_id uuid)
returns integer language plpgsql set search_path = '' as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  delete from app.notifications_attempts a using app.notifications_jobs j
   where a.job_id = j.job_id and j.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_push_jobs p where p.recipient_member_id = p_member_id or p.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_direct_contact_needs n where n.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_inbox_items i where i.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_jobs j where j.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_schedules s where s.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_device_tokens t where t.member_id = p_member_id or t.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_push_settings s where s.member_id = p_member_id or s.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  return v_total;
end; $$;
select is((select string_agg((r ->> 'module') || '=' || (r ->> 'remaining'), ',' order by r ->> 'module')
             from jsonb_array_elements(
               app.identity_call_deletion_hooks(pg_temp.mid(9), pg_temp.u(9), gen_random_uuid(), 'erase')) r
            where r ->> 'module' in ('fixture', 'notifications')),
  'fixture=0,notifications=0', 'the erase phase removes every notification and fixture reminder row');
select is((select string_agg((r ->> 'module') || '=' || (r ->> 'remaining'), ',' order by r ->> 'module')
             from jsonb_array_elements(
               app.identity_call_deletion_hooks(pg_temp.mid(9), pg_temp.u(9), gen_random_uuid(), 'check')) r),
  'cells=0,fixture=0,notifications=0', 'the deletion check answers zero for every owner');
select is((select count(*)::int from app.notifications_jobs where recipient_member_id = pg_temp.mid(9))
          + (select count(*)::int from app.notifications_inbox_items where recipient_member_id = pg_temp.mid(9))
          + (select count(*)::int from app.notifications_schedules where recipient_member_id = pg_temp.mid(9))
          + (select count(*)::int from app.notifications_device_tokens where account_id = pg_temp.u(9))
          + (select count(*)::int from app.notifications_push_settings where account_id = pg_temp.u(9))
          + (select count(*)::int from app.fixture_reminder_sources where member_id = pg_temp.mid(9)), 0,
  'nothing of the deleted member is left');
select is((pg_temp.run() ->> 'claimed')::int, 0, 'and the worker finds nothing of theirs');
-- The Admin who created reminders for others: their account becomes the nil UUID in those.
select is((select count(*)::int from app.fixture_reminder_sources where created_by_account = pg_temp.u(1)) > 0, true,
  'the Admin''s account is on reminders they created for others');
select is((app.fixture_erase_member(jsonb_build_object('member_id', pg_temp.mid(1), 'account_id', pg_temp.u(1),
             'deletion_id', gen_random_uuid(), 'phase', 'erase')) ->> 'remaining')::int, 0,
  'erasing the Admin anonymises them there');
select is((select count(*)::int from app.fixture_reminder_sources
            where created_by_account = '00000000-0000-0000-0000-000000000000' and member_id <> pg_temp.mid(1)) > 0, true,
  'and keeps the other members'' reminders');

select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

select * from finish();
rollback;
