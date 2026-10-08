-- Member push through FCM: leases, rechecks, provider answers and invalid-token retirement
-- (story 3.6; AD-8, AD-13, AD-18; epic 3 N7, N4). The Edge worker's transport and the FCM
-- adapter are tested in supabase/functions/notifications-worker/*.test.mjs; the HTTP path with a
-- fake FCM endpoint in tools/identity-e2e/push.mjs. Every account here is SYNTHETIC
-- (+44 7700 900900-900909); device tokens are synthetic.
begin;
select plan(91);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000360' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000360' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (900 + n)::text $$;
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
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.tok(p_fill text) returns text language sql as
$$ select 'fcm-' || repeat(p_fill, 40) || ':APA91b' $$;
create function pg_temp.register(n int, p_fill text) returns uuid language sql as $$
  select (pg_temp.call(n, 'notifications_command', 'notifications.register_device', null,
            jsonb_build_object('token', pg_temp.tok(p_fill), 'platform', 'android')) ->> 'aggregate_id')::uuid
$$;
create function pg_temp.dev(p_fill text) returns uuid language sql as
$$ select device_id from app.notifications_device_tokens where token = pg_temp.tok(p_fill) $$;
create function pg_temp.retired(p_fill text) returns text language sql as
$$ select coalesce(retire_reason, 'live') from app.notifications_device_tokens where token = pg_temp.tok(p_fill) $$;
-- The Admin (1) creates a due SYNTHETIC reminder for member n and the worker delivers it;
-- returns the push job id (null when none was queued).
create function pg_temp.pushed(n int) returns uuid language plpgsql as $$
declare
  v_source uuid;
  v_job uuid;
begin
  v_source := (pg_temp.call(1, 'fixture_reminder_command', 'fixture.reminder_create_for', null,
                 jsonb_build_object('member_id', pg_temp.mid(n),
                                    'due_at', app.cmd_utc(now() - interval '1 minute')))
               -> 'data' ->> 'source_id')::uuid;
  select j.job_id into v_job from app.notifications_jobs j where j.source_id = v_source;
  perform app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}');
  return (select p.push_job_id from app.notifications_push_jobs p where p.job_id = v_job);
end;
$$;
create function pg_temp.source_of(p_push uuid) returns uuid language sql as $$
  select j.source_id from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
   where p.push_job_id = p_push
$$;
create function pg_temp.w(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-c000-0000000360' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.claim(p_w int default 1) returns jsonb language sql as
$$ select app.notifications_push_claim(pg_temp.w(p_w), gen_random_uuid(), 25) $$;
create function pg_temp.tokof(p_claim jsonb, p_push uuid) returns bigint language sql as $$
  select (e ->> 'lease_token')::bigint from jsonb_array_elements(p_claim -> 'jobs') e
   where (e ->> 'push_job_id')::uuid = p_push
$$;
create function pg_temp.lease(p_push uuid) returns bigint language sql as
$$ select lease_token from app.notifications_push_jobs where push_job_id = p_push $$;
create function pg_temp.prep(p_push uuid, p_w int default 1, p_token bigint default null) returns jsonb
language sql as $$
  select app.notifications_push_prepare(pg_temp.w(p_w), gen_random_uuid(), p_push,
                                        coalesce(p_token, pg_temp.lease(p_push)))
$$;
create function pg_temp.rec(p_push uuid, p_results jsonb, p_w int default 1, p_token bigint default null)
returns jsonb language sql as $$
  select app.notifications_push_record(pg_temp.w(p_w), gen_random_uuid(), p_push,
                                       coalesce(p_token, pg_temp.lease(p_push)), p_results)
$$;
create function pg_temp.res(p_fill text, p_result text, p_status int default null, p_code text default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('device_id', pg_temp.dev(p_fill), 'result', p_result,
                                              'provider_status', p_status, 'provider_code', p_code))
$$;
create function pg_temp.pst(p_push uuid) returns text language sql as $$
  select push_state || '|' || coalesce(finish_reason, '-') from app.notifications_push_jobs
   where push_job_id = p_push
$$;
create function pg_temp.outcomes(p_push uuid) returns text language sql as $$
  select coalesce(string_agg(outcome, ',' order by attempted_at, attempt_id), '')
    from app.notifications_attempts where push_job_id = p_push
$$;
create function pg_temp.ntargets(p_prep jsonb) returns int language sql as
$$ select jsonb_array_length(coalesce(p_prep -> 'targets', '[]')) $$;
create function pg_temp.lifecycle(p_event text, n int) returns int language sql as $$
  select app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', p_event, 'member_id', pg_temp.mid(n), 'occurred_at', app.cmd_utc(now()),
    'identity_revision', pg_temp.mrev(n)))
$$;
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
create function pg_temp.sys(p_command text, p_payload jsonb, p_request uuid) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', pg_temp.token('Q'))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', p_command,
           'request_id', p_request, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create temp table v (k text primary key, id uuid, j jsonb);

-- Accounts: 1 Admin; 2, 3, 4, 5 active members with devices; 6 to be held.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 6) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 6) n;
select app.platform_set_environment('local', 'pgtap 3.6');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.6 Member ' || n, 'pgtap 3.6')
  from generate_series(1, 6) n;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
select pg_temp.register(2, 'a'), pg_temp.register(2, 'b'), pg_temp.register(3, 'c'),
       pg_temp.register(3, 'd'), pg_temp.register(4, 'e'), pg_temp.register(5, 'f'),
       pg_temp.register(6, 'g');
insert into v (k, id) values ('da', pg_temp.dev('a')), ('db', pg_temp.dev('b'));

-- Structure, privileges and the kernel's result retention ---------------------------------------
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'app' and p.proname ~ '^notifications_(push_|check_push|sys_push_)'
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'no client role may execute the push functions');
select is((select array_agg(command || ':' || retain_result::text order by command) from app.sys_command_kinds
            where command like 'notifications.push_%'),
  array['notifications.push_claim:true', 'notifications.push_prepare:false', 'notifications.push_record:true',
        'notifications.push_release:true'],
  'four push commands; only push_prepare (it answers device tokens) keeps no result');
select is((select count(*)::int from app.sys_command_kinds where not retain_result), 1,
  'every other system command keeps its replayable result');
select is((select push_enabled from app.notifications_worker_settings), false, 'push is off by default');
select throws_ok($$select app.notifications_configure_worker('{"push_enabled": "yes"}', 'israel')$$, '22023', null,
  'push_enabled must be a boolean');

-- Push off: nothing is claimed, the item is still delivered --------------------------------------
insert into v (k, id) values ('off', pg_temp.pushed(2));
select is(pg_temp.pst((select id from v where k = 'off')), 'pending|-', 'delivery queued one pending push job');
select is((select count(*)::int from app.notifications_inbox_items i join app.notifications_push_jobs p
            on p.item_id = i.item_id where p.push_job_id = (select id from v where k = 'off')), 1,
  'the inbox item exists whether or not push is sent');
select throws_ok($$insert into app.notifications_attempts (job_id, channel, principal_id, request_id, outcome)
                   select job_id, 'push', gen_random_uuid(), gen_random_uuid(), 'accepted'
                     from app.notifications_jobs limit 1$$, '23514', null,
  'a push attempt names its push job');
select is(pg_temp.claim() - 'lease_seconds',
  '{"jobs": [], "claimed": 0, "reclaimed": 0, "expired": 0, "push_enabled": false}'::jsonb,
  'with push off nothing is claimed');
select is((app.notifications_configure_worker('{"push_enabled": true}', 'israel') ->> 'push_enabled'), 'true',
  'the operator turns push on');

-- Accepted on both devices ----------------------------------------------------------------------
insert into v (k, j) values ('c1', pg_temp.claim());
select is(((select j from v where k = 'c1') ->> 'claimed')::int, 1, 'the pending push job is leased');
select ok(pg_temp.tokof((select j from v where k = 'c1'), (select id from v where k = 'off')) >= 1,
  'with a fencing token');
insert into v (k, j) values ('p1', pg_temp.prep((select id from v where k = 'off')));
select is((select j ->> 'outcome' from v where k = 'p1'), 'send', 'prepare answers send');
select is((select array_agg(x order by x) from v, jsonb_object_keys(v.j -> 'message') x where v.k = 'p1'),
  array['body', 'expires_at_epoch', 'item_id', 'notification_id', 'title', 'ttl_seconds'],
  'the message is generic: title, body, the item id (also the notification id) and expiry only');
select is((select (j -> 'message' ->> 'title') || '|' || (j -> 'message' ->> 'body') from v where k = 'p1'),
  'SYNTHETIC test reminder|A test reminder is waiting for you.', 'the contract''s fixed text');
select is((select (j -> 'message' ->> 'notification_id')::uuid from v where k = 'p1'),
  (select item_id from app.notifications_push_jobs where push_job_id = (select id from v where k = 'off')),
  'the stable notification id is the inbox item id');
select ok((select (j -> 'message' ->> 'ttl_seconds')::bigint between 1 and 2419200
                  and (j -> 'message' ->> 'expires_at_epoch')::bigint
                      = floor(extract(epoch from (select expires_at from app.notifications_push_jobs
                                                   where push_job_id = (select id from v where k = 'off'))))
             from v where k = 'p1'),
  'the provider TTL is the push job''s remaining life');
select is((select array_agg(x order by x) from v, jsonb_array_elements(v.j -> 'targets') t, jsonb_object_keys(t) x
            where v.k = 'p1' and t ->> 'device_id' = pg_temp.dev('a')::text),
  array['device_id', 'platform', 'token'], 'each target is a device, its platform and its token');
select is(pg_temp.ntargets((select j from v where k = 'p1')), 2, 'both live devices of the member are targets');
select is(pg_temp.outcomes((select id from v where k = 'off')), '', 'prepare that answers send writes no attempt');
select is(pg_temp.rec((select id from v where k = 'off'),
            jsonb_build_array(pg_temp.res('a', 'accepted', 200), pg_temp.res('b', 'accepted', 200))),
  '{"outcome": "accepted", "finish_reason": "accepted", "recorded": 2, "retired": 0}'::jsonb,
  'both devices accepted: the push job ends accepted');
select is(pg_temp.pst((select id from v where k = 'off')), 'accepted|accepted', 'push job accepted');
select is(pg_temp.outcomes((select id from v where k = 'off')), 'accepted,accepted',
  'one attempt row per device answer');
select is((select count(*)::int from app.notifications_attempts
            where channel = 'push' and outcome in ('delivered', 'read', 'opened')), 0,
  'no push attempt claims delivery or reading');
select is((select array_agg(distinct provider_status) from app.notifications_attempts
            where push_job_id = (select id from v where k = 'off')), array[200], 'the provider status is kept');

-- Invalid token: retired; the other device accepts ------------------------------------------------
insert into v (k, id) values ('inv', pg_temp.pushed(3));
select pg_temp.claim();
select is(pg_temp.ntargets(pg_temp.prep((select id from v where k = 'inv'))), 2, 'two targets');
select is(pg_temp.rec((select id from v where k = 'inv'),
            jsonb_build_array(pg_temp.res('c', 'token_invalid', 404, 'UNREGISTERED'), pg_temp.res('d', 'accepted', 200))),
  '{"outcome": "accepted", "finish_reason": "accepted", "recorded": 2, "retired": 1}'::jsonb,
  'an unregistered token is retired after the provider''s answer; the other device accepted');
select is(pg_temp.retired('c') || ',' || pg_temp.retired('d'), 'provider_invalid,live',
  'only the invalid token is retired (provider_invalid)');
select is((select provider_code from app.notifications_attempts where device_id = pg_temp.dev('c')),
  'UNREGISTERED', 'the provider''s error code is recorded, never the token');

-- Every token invalid: obsolete, the inbox item stays -------------------------------------------
insert into v (k, id) values ('allinv', pg_temp.pushed(4));
select pg_temp.claim();
select pg_temp.prep((select id from v where k = 'allinv'));
select is(pg_temp.rec((select id from v where k = 'allinv'),
            jsonb_build_array(pg_temp.res('e', 'token_invalid', 403, 'SENDER_ID_MISMATCH'))) ->> 'outcome',
  'obsolete', 'the only token is invalid');
select is(pg_temp.pst((select id from v where k = 'allinv')), 'obsolete|no_live_token', 'push job obsolete');
select is((select count(*)::int from app.notifications_inbox_items where recipient_member_id = pg_temp.mid(4)), 1,
  'the inbox item is untouched');
select is(pg_temp.pushed(4), null::uuid, 'with no live token the next item queues no push job');

-- Transient: retry with backoff and the same notification id; only owed devices again --------------
insert into v (k, id) values ('tr', pg_temp.pushed(2));
insert into v (k, j) values ('trc', pg_temp.claim());
insert into v (k, j) values ('trp', pg_temp.prep((select id from v where k = 'tr')));
select is(pg_temp.rec((select id from v where k = 'tr'),
            jsonb_build_array(pg_temp.res('a', 'accepted', 200), pg_temp.res('b', 'transient', 503, 'UNAVAILABLE'))),
  '{"outcome": "retry", "recorded": 2, "retired": 0}'::jsonb, 'one transient answer: retry');
select is((select failed_attempts || '|' || (last_failed_at is not null)::text || '|' || (lease_expires_at <= now())::text
             from app.notifications_push_jobs where push_job_id = (select id from v where k = 'tr')),
  '1|true|true', 'the failure is counted and the lease ended');
select is((pg_temp.claim(2) ->> 'claimed')::int, 0, 'a push job backing off is not claimed');
update app.notifications_push_jobs set last_failed_at = now() - interval '61 seconds'
 where push_job_id = (select id from v where k = 'tr');
insert into v (k, j) values ('trc2', pg_temp.claim(2));
select ok(pg_temp.tokof((select j from v where k = 'trc2'), (select id from v where k = 'tr'))
          > pg_temp.tokof((select j from v where k = 'trc'), (select id from v where k = 'tr')),
  'after the backoff it is claimed again with a higher token');
insert into v (k, j) values ('trp2', pg_temp.prep((select id from v where k = 'tr'), 2));
select is((select j -> 'message' ->> 'notification_id' from v where k = 'trp2'),
  (select j -> 'message' ->> 'notification_id' from v where k = 'trp'), 'the retry keeps the same notification id');
select is((select jsonb_agg(t ->> 'device_id') from v, jsonb_array_elements(v.j -> 'targets') t where v.k = 'trp2'),
  jsonb_build_array(pg_temp.dev('b')), 'only the device still owed is sent again');
select is(pg_temp.rec((select id from v where k = 'tr'), jsonb_build_array(pg_temp.res('b', 'accepted', 200)), 2) ->> 'outcome',
  'accepted', 'the retry is accepted');
select is(pg_temp.outcomes((select id from v where k = 'tr')), 'accepted,transient,accepted', 'attempt history');
select is(pg_temp.rec((select id from v where k = 'tr'), jsonb_build_array(pg_temp.res('b', 'accepted', 200)), 1,
            pg_temp.tokof((select j from v where k = 'trc'), (select id from v where k = 'tr'))) ->> 'outcome',
  'fenced', 'a late record with the old token is fenced');
select is(pg_temp.pst((select id from v where k = 'tr')), 'accepted|accepted', 'and changes nothing');

-- Exhausted ---------------------------------------------------------------------------------------
select app.notifications_configure_worker('{"max_attempts": 2}', 'israel');
insert into v (k, id) values ('ex', pg_temp.pushed(5));
select pg_temp.claim();
select pg_temp.prep((select id from v where k = 'ex'));
select is(pg_temp.rec((select id from v where k = 'ex'), jsonb_build_array(pg_temp.res('f', 'transient', 429, 'QUOTA_EXCEEDED'))) ->> 'outcome',
  'retry', 'first transient failure');
update app.notifications_push_jobs set last_failed_at = now() - interval '1 hour'
 where push_job_id = (select id from v where k = 'ex');
select pg_temp.claim();
select pg_temp.prep((select id from v where k = 'ex'));
select is(pg_temp.rec((select id from v where k = 'ex'), jsonb_build_array(pg_temp.res('f', 'transient', 500, 'INTERNAL'))),
  '{"outcome": "exhausted", "finish_reason": "attempts_exhausted", "recorded": 1, "retired": 0}'::jsonb,
  'at max_attempts the push job ends');
select is(pg_temp.pst((select id from v where k = 'ex')), 'failed|attempts_exhausted', 'failed, never delivered');
select app.notifications_configure_worker('{"max_attempts": 5}', 'israel');

-- Rejected: not retried, token kept -------------------------------------------------------------
insert into v (k, id) values ('rj', pg_temp.pushed(5));
select pg_temp.claim();
select pg_temp.prep((select id from v where k = 'rj'));
select is(pg_temp.rec((select id from v where k = 'rj'), jsonb_build_array(pg_temp.res('f', 'rejected', 400, 'INVALID_ARGUMENT'))) ->> 'outcome',
  'failed', 'a rejected message is not retried');
select is(pg_temp.pst((select id from v where k = 'rj')) || ',' || pg_temp.retired('f'), 'failed|provider_rejected,live',
  'failed (provider_rejected); the token stays live');

-- Expired -----------------------------------------------------------------------------------------
insert into v (k, id) values ('exp1', pg_temp.pushed(5));
insert into v (k, id) values ('exp2', pg_temp.pushed(5));
update app.notifications_push_jobs set expires_at = now() - interval '1 second'
 where push_job_id = (select id from v where k = 'exp1');
insert into v (k, j) values ('expc', pg_temp.claim());
select is((select (j ->> 'expired')::int || '|' || (j ->> 'claimed')::int from v where k = 'expc'), '1|1',
  'the claim expires the old push job and leases the other');
select is(pg_temp.pst((select id from v where k = 'exp1')), 'obsolete|expired', 'expired at the claim');
update app.notifications_push_jobs set expires_at = now() where push_job_id = (select id from v where k = 'exp2');
select is(pg_temp.prep((select id from v where k = 'exp2')), '{"outcome": "expired", "finish_reason": "expired"}'::jsonb,
  'expired at prepare: nothing is sent');
select is(pg_temp.pst((select id from v where k = 'exp2')), 'obsolete|expired', 'push job obsolete');

-- Stale: rechecked right before the provider call ------------------------------------------------
insert into v (k, id) select 'st' || n, pg_temp.pushed(2) from generate_series(1, 8) n;
select pg_temp.claim();
update app.fixture_reminder_sources set revision = revision + 1 where source_id = pg_temp.source_of((select id from v where k = 'st1'));
update app.fixture_reminder_sources set expires_at = now() - interval '1 second' where source_id = pg_temp.source_of((select id from v where k = 'st2'));
update app.fixture_reminder_sources set recipient_revoked = true where source_id = pg_temp.source_of((select id from v where k = 'st3'));
select app.notifications_enqueue_job(jsonb_build_object(
    'source_type', j.source_type, 'source_id', j.source_id, 'source_revision', j.source_revision,
    'recipient_member_id', j.recipient_member_id, 'reminder_kind', j.reminder_kind,
    'scheduled_at', app.cmd_utc(now() + interval '1 hour')), null, null, p.item_id)
  from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
 where p.push_job_id = (select id from v where k = 'st4');
update app.notifications_push_jobs set account_id = gen_random_uuid() where push_job_id = (select id from v where k = 'st5');
select pg_temp.call(2, 'notifications_command', 'notifications.set_push_category', null,
  '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": false}');
select is(array[pg_temp.prep((select id from v where k = 'st1')) ->> 'finish_reason',
                pg_temp.prep((select id from v where k = 'st2')) ->> 'finish_reason',
                pg_temp.prep((select id from v where k = 'st3')) ->> 'finish_reason',
                pg_temp.prep((select id from v where k = 'st4')) ->> 'finish_reason',
                pg_temp.prep((select id from v where k = 'st5')) ->> 'finish_reason',
                pg_temp.prep((select id from v where k = 'st6')) ->> 'finish_reason'],
  array['source_changed', 'not_actionable', 'recipient_ineligible', 'snoozed', 'recipient_changed', 'push_disabled'],
  'revised, expired, revoked, snoozed, routed away and push turned off: nothing is sent');
select is((select count(*)::int from app.notifications_push_jobs
            where push_job_id in (select id from v where k in ('st1', 'st2', 'st3', 'st4', 'st5', 'st6'))
              and push_state = 'obsolete'), 6, 'each push job ends obsolete');
select is((select count(*)::int from app.notifications_attempts
            where push_job_id in (select id from v where k in ('st1', 'st2', 'st3', 'st4', 'st5', 'st6'))
              and outcome = 'obsolete'), 6, 'each with one attempt row');
select pg_temp.call(2, 'notifications_command', 'notifications.set_push_category', 1,
  '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": true}');
update app.fixture_reminder_sources set check_fault_until = now() + interval '1 hour'
 where source_id = pg_temp.source_of((select id from v where k = 'st7'));
select is(pg_temp.prep((select id from v where k = 'st7')), '{"outcome": "failed"}'::jsonb,
  'a raising source check is transient');
select is((select error_sqlstate || '|' || failed_attempts from app.notifications_attempts a
             join app.notifications_push_jobs p on p.push_job_id = a.push_job_id
            where a.push_job_id = (select id from v where k = 'st7')), 'P0001|1',
  'recorded with its SQLSTATE only and counted');
select is(pg_temp.prep((select id from v where k = 'st8'), 2) ->> 'outcome', 'fenced',
  'another worker''s prepare is fenced');

-- Lifecycle: a hold cancels the push job; the late prepare is told so --------------------------
insert into v (k, id) values ('held', pg_temp.pushed(6));
select pg_temp.claim();
select pg_temp.lifecycle('access_hold_applied', 6);
select is(pg_temp.pst((select id from v where k = 'held')), 'cancelled|access_hold_applied',
  'the hold cancelled the pending push job (story 3.5 hook)');
select is(pg_temp.prep((select id from v where k = 'held')) ->> 'outcome', 'cancelled', 'prepare does not send it');

-- Lapse: the worker dies after prepare; the next claim counts it and resends the same id ----------
insert into v (k, id) values ('lap', pg_temp.pushed(5));
insert into v (k, j) values ('lapc', pg_temp.claim());
insert into v (k, j) values ('lapp', pg_temp.prep((select id from v where k = 'lap')));
update app.notifications_push_jobs set lease_expires_at = now() - interval '1 second'
 where push_job_id = (select id from v where k = 'lap');
insert into v (k, j) values ('lapc2', pg_temp.claim(2));
select is((select (j ->> 'reclaimed')::int from v where k = 'lapc2'), 1, 'the lapsed lease is counted');
select ok(pg_temp.tokof((select j from v where k = 'lapc2'), (select id from v where k = 'lap'))
          > pg_temp.tokof((select j from v where k = 'lapc'), (select id from v where k = 'lap')),
  'and reclaimed with a higher token');
select is(pg_temp.prep((select id from v where k = 'lap'), 2) -> 'message' ->> 'notification_id',
  (select j -> 'message' ->> 'notification_id' from v where k = 'lapp'), 'the resend keeps the notification id');
select is(pg_temp.rec((select id from v where k = 'lap'), jsonb_build_array(pg_temp.res('f', 'accepted', 200)), 1,
            pg_temp.tokof((select j from v where k = 'lapc'), (select id from v where k = 'lap'))) ->> 'outcome',
  'fenced', 'the dead worker''s late record is fenced');
select is(pg_temp.rec((select id from v where k = 'lap'), jsonb_build_array(pg_temp.res('f', 'accepted', 200)), 2) ->> 'outcome',
  'accepted', 'the new holder records the acceptance');
select is(pg_temp.outcomes((select id from v where k = 'lap')), 'lapsed,fenced,accepted', 'attempt history');

-- Records for foreign devices are ignored; release counts nothing --------------------------------
insert into v (k, id) values ('fx', pg_temp.pushed(5));
select pg_temp.claim();
select pg_temp.prep((select id from v where k = 'fx'));
select is(pg_temp.rec((select id from v where k = 'fx'), jsonb_build_array(pg_temp.res('a', 'token_invalid', 404, 'UNREGISTERED'))),
  '{"outcome": "retry", "recorded": 0, "retired": 0}'::jsonb, 'another member''s device is ignored');
select is(pg_temp.retired('a'), 'live', 'and never retired');
select pg_temp.claim();
select is(app.notifications_push_release(pg_temp.w(1), (select id from v where k = 'fx'), pg_temp.lease((select id from v where k = 'fx'))),
  '{"released": true}'::jsonb, 'an unused lease is released');
select is(pg_temp.outcomes((select id from v where k = 'fx')), '', 'releasing records no attempt');

-- Payload checks ----------------------------------------------------------------------------------
select is(app.notifications_check_push('{"push_job_id": "x", "lease_token": 0, "token": "y"}'),
  '{"push_job_id": "invalid", "lease_token": "invalid", "token": "unknown_field"}'::jsonb,
  'prepare/release payloads are strict');
select is(app.notifications_check_push_record(jsonb_build_object(
    'push_job_id', gen_random_uuid(), 'lease_token', 1,
    'results', jsonb_build_array(pg_temp.res('a', 'delivered')))) -> 'results', '"invalid"'::jsonb,
  'a provider answer can never say delivered');
select is(app.notifications_check_push_record(jsonb_build_object(
    'push_job_id', gen_random_uuid(), 'lease_token', 1,
    'results', jsonb_build_array(pg_temp.res('a', 'accepted', 200), pg_temp.res('a', 'accepted', 200)))) -> 'results',
  '"duplicate_device"'::jsonb, 'one answer per device');
select is(app.notifications_check_push_record(jsonb_build_object(
    'push_job_id', gen_random_uuid(), 'lease_token', 1,
    'results', jsonb_build_array(jsonb_build_object('device_id', gen_random_uuid(), 'result', 'accepted',
                                                    'token', pg_temp.tok('z'))))) -> 'results',
  '"invalid"'::jsonb, 'an answer cannot carry a token');
select is(app.notifications_check_push_record(jsonb_build_object(
    'push_job_id', gen_random_uuid(), 'lease_token', 1,
    'results', jsonb_build_array(pg_temp.res('a', 'rejected', 400, 'bad code')))) -> 'results',
  '"invalid"'::jsonb, 'a provider code is an upper-case token');
select is(app.notifications_check_push_record(jsonb_build_object(
    'push_job_id', gen_random_uuid(), 'lease_token', 1, 'results', '[]'::jsonb)) -> 'results',
  '"invalid"'::jsonb, 'at least one answer');

-- The system route: prepare's answer (with tokens) is not kept in the receipt --------------------
insert into v (k, id) values ('w', app.sys_create_principal('pgtap-push-worker', 'notifications_worker', 'israel'));
select app.sys_register_credential((select id from v where k = 'w'),
  encode(sha256(convert_to(pg_temp.token('Q'), 'UTF8')), 'hex'), 'pgtap 3.6', interval '1 hour', 'israel');
insert into v (k, id) values ('route', pg_temp.pushed(5));
insert into v (k, j) values ('rc', pg_temp.sys('notifications.push_claim', '{}', gen_random_uuid()));
select ok((select (j -> 'data' ->> 'claimed')::int from v where k = 'rc') >= 1
          and pg_temp.lease((select id from v where k = 'route')) is not null, 'the route claims the push job');
insert into v (k, id, j) values ('rq', gen_random_uuid(), null);
update v set j = pg_temp.sys('notifications.push_prepare',
    jsonb_build_object('push_job_id', (select id from v where k = 'route'),
                       'lease_token', pg_temp.lease((select id from v where k = 'route'))),
    (select id from v where k = 'rq'))
 where k = 'rq';
select is((select j -> 'data' ->> 'outcome' from v where k = 'rq'), 'send', 'the route answers send with the targets');
select is((select r.result - 'request_id' from app.sys_receipts r where r.request_id = (select id from v where k = 'rq')),
  '{"retained": false}'::jsonb, 'the receipt keeps a marker, not the answer');
select is((select count(*)::int from app.sys_receipts r where r.result::text like '%APA91%'), 0,
  'no device token is stored in any receipt');
select is(pg_temp.sys('notifications.push_prepare',
    jsonb_build_object('push_job_id', (select id from v where k = 'route'),
                       'lease_token', pg_temp.lease((select id from v where k = 'route'))),
    (select id from v where k = 'rq')) ->> 'code', 'conflict', 'a replay of it is a conflict, never the tokens');
select is(pg_temp.sys('notifications.push_record',
    jsonb_build_object('push_job_id', (select id from v where k = 'route'),
                       'lease_token', pg_temp.lease((select id from v where k = 'route')),
                       'results', jsonb_build_array(pg_temp.res('f', 'accepted', 200))),
    gen_random_uuid()) -> 'data' ->> 'outcome', 'accepted', 'the route records the answer');

-- Status (content-free) ---------------------------------------------------------------------------
select is((select array_agg(k order by k) from jsonb_object_keys(app.notifications_scheduler_status() -> 'push') k),
  array['attempts_24h', 'enabled', 'ended_24h', 'leased', 'pending', 'tokens_retired_24h'],
  'the status has a push block');
select is((app.notifications_scheduler_status() -> 'push' ->> 'tokens_retired_24h')::int, 2,
  'two tokens retired on the provider''s answer');
select ok((app.notifications_scheduler_status() -> 'push' -> 'attempts_24h' ->> 'accepted')::int >= 6
          and not (app.notifications_scheduler_status() -> 'attempts_24h' ? 'accepted'),
  'push outcomes are counted apart from inbox attempts');
select ok(app.notifications_scheduler_status()::text !~ '(APA91|fcm-|SYNTHETIC test reminder)',
  'the status carries no token or text');

-- Deletion: push attempts are erased with the member's jobs -------------------------------------
select is(app.notifications_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(2),
                                                            'account_id', pg_temp.u(2))),
  '{"remaining": 0}'::jsonb, 'erasing member 2 leaves no notification row, push attempts included');
select is((select count(*)::int from app.notifications_attempts a where a.device_id in (select id from v where k in ('da', 'db'))), 0,
  'no attempt of the member''s devices is left');

-- Guards ------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname ~ '^notifications_(push_|check_push|sys_push_)'
              and not coalesce(p.proconfig @> array['search_path=""'], false)), 0,
  'every push function pins an empty search_path');
select is((select count(*)::int from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname ~ '^notifications_(push_|check_push|sys_push_)' and p.prosecdef), 0,
  'no push function is a security definer');
select is((select count(*)::int from app.notifications_attempts where channel = 'push' and push_job_id is null), 0,
  'every push attempt names its push job');

select * from finish();
rollback;
