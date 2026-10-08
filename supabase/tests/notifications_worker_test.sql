-- Leased and fenced notification worker (story 3.4; AD-8, AD-17, AD-19; epic 3 N4): central
-- worker policy, notifications.claim / notifications.attempt on the system route, fencing
-- tokens, reclaim of expired leases, rechecks (cancel, revision, actionability, schedule,
-- recipient, membership, expiry), retries with backoff and the attempt limit, the attempts
-- record, and the scheduler tick / enable / disable / status. HTTP, Edge Function and pg_cron
-- evidence: tools/identity-e2e/worker.mjs. Every account here is SYNTHETIC
-- (+44 7700 900860-900869).
begin;
select plan(83);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000340' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000340' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (860 + n)::text $$;
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
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  select api.fixture_reminder_command(jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
-- A due SYNTHETIC reminder of member n; returns its job id.
create function pg_temp.due(n int, p_due timestamptz default now() - interval '1 minute') returns uuid
language plpgsql as $$
declare
  v_source uuid;
  v_job uuid;
begin
  v_source := (pg_temp.cmd(n, 'fixture.reminder_create', null,
                 jsonb_build_object('due_at', app.cmd_utc(p_due))) -> 'data' ->> 'source_id')::uuid;
  select j.job_id into v_job from app.notifications_jobs j where j.source_id = v_source;
  return v_job;
end;
$$;
create function pg_temp.source_of(p_job uuid) returns uuid language sql as
$$ select source_id from app.notifications_jobs where job_id = p_job $$;
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
-- The system route as a worker calls it (anon + x-system-credential).
create function pg_temp.sys(p_fill text, p_command text, p_payload jsonb default '{}') returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', pg_temp.token(p_fill))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', p_command,
           'request_id', gen_random_uuid(), 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.claim(p_fill text, p_limit int default null) returns jsonb language sql as $$
  select (pg_temp.sys(p_fill, 'notifications.claim',
            case when p_limit is null then '{}'::jsonb else jsonb_build_object('limit', p_limit) end)
          -> 'data') - 'actor'::text
$$;
create function pg_temp.attempt(p_fill text, p_job uuid, p_token bigint) returns jsonb language sql as $$
  select (pg_temp.sys(p_fill, 'notifications.attempt',
            jsonb_build_object('job_id', p_job, 'lease_token', p_token)) -> 'data') - 'actor'::text
$$;
create function pg_temp.tok(p_claim jsonb, p_job uuid) returns bigint language sql as $$
  select (e ->> 'lease_token')::bigint from jsonb_array_elements(p_claim -> 'jobs') e
   where (e ->> 'job_id')::uuid = p_job
$$;
create function pg_temp.st(p_job uuid) returns text language sql as $$
  select job_state || '|' || coalesce(finish_reason, cancel_reason, '-') from app.notifications_jobs
   where job_id = p_job
$$;
create function pg_temp.outcomes(p_job uuid) returns text language sql as $$
  select string_agg(outcome, ',' order by attempted_at, attempt_id) from app.notifications_attempts
   where job_id = p_job
$$;
-- Simulates the passage of time for a lease (a worker killed mid-lease).
create function pg_temp.lapse(p_job uuid) returns void language sql as $$
  update app.notifications_jobs set lease_expires_at = now() - interval '1 second' where job_id = p_job
$$;

insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;

-- Structure, privileges and guards -------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.notifications_worker_settings', 'app.notifications_scheduler_state',
                             'app.notifications_attempts', 'app.notifications_worker_runs']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not has_sequence_privilege('authenticated', 'app.notifications_lease_token_seq', 'USAGE')
  and not has_sequence_privilege('anon', 'app.notifications_lease_token_seq', 'USAGE'),
  'no client role has any privilege on the new tables or the fencing sequence');
select ok(not exists (
  select 1 from unnest(array['app.notifications_claim(uuid,uuid,integer,text)',
                             'app.notifications_attempt(uuid,uuid,uuid,bigint)',
                             'app.notifications_sys_claim(uuid,uuid,jsonb)',
                             'app.notifications_sys_attempt(uuid,uuid,jsonb)',
                             'app.notifications_configure_worker(jsonb,text)',
                             'app.notifications_scheduler_tick()',
                             'app.notifications_scheduler_enable(text,text)',
                             'app.notifications_scheduler_disable(text)',
                             'app.notifications_scheduler_status()',
                             'app.notifications_finish_job(uuid,text,text,uuid,uuid)']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'the worker, policy and scheduler functions are not client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select results_eq($$select command, purpose || '|' || payload_check || '|' || handler from app.sys_command_kinds
                     where command in ('notifications.claim', 'notifications.attempt') order by 1$$,
  $$values ('notifications.attempt'::text, 'notifications_worker|app.notifications_check_attempt(jsonb)|app.notifications_sys_attempt(uuid, uuid, jsonb)'::text),
           ('notifications.claim', 'notifications_worker|app.notifications_check_deliver_due(jsonb)|app.notifications_sys_claim(uuid, uuid, jsonb)')$$,
  'claim and attempt are commands of the notifications_worker purpose');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'notifications_attempts'),
  array['attempt_id', 'attempted_at', 'channel', 'error_sqlstate', 'finish_reason', 'job_id',
        'lease_token', 'outcome', 'principal_id', 'request_id'],
  'an attempt row holds ids, codes and times only');
select is((select to_jsonb(s) - 'updated_at' from app.notifications_worker_settings s),
  '{"singleton": true, "lease_seconds": 120, "batch_max": 25, "max_attempts": 5,
    "backoff_base_seconds": 60, "backoff_max_seconds": 3600, "default_ttl_seconds": 604800,
    "worker_url": null, "updated_by": null}'::jsonb,
  'the central worker policy has the decided defaults and no worker URL');
select is(array[app.notifications_backoff_seconds(0, s), app.notifications_backoff_seconds(1, s),
                app.notifications_backoff_seconds(2, s), app.notifications_backoff_seconds(7, s),
                app.notifications_backoff_seconds(40, s)],
          array[0, 60, 120, 3600, 3600], 'backoff doubles from the base up to the maximum')
  from app.notifications_worker_settings s;

-- Worker policy changes (operator only) -------------------------------------------------------
select throws_ok($$select app.notifications_configure_worker('{"lease_seconds": 60}', 'mallory')$$,
  '42501', 'not an active restricted operator', 'only a restricted operator changes the policy');
select throws_ok($$select app.notifications_configure_worker('{"lease": 60}', 'israel')$$,
  '22023', 'invalid worker settings', 'an unknown key is refused');
select throws_ok($$select app.notifications_configure_worker('{"lease_seconds": 2}', 'israel')$$,
  '23514', null, 'a value outside its bounds is refused');
select throws_ok($$select app.notifications_configure_worker('{"worker_url": "https://evil.example/x"}', 'israel')$$,
  '23514', null, 'a worker URL that is not the notifications-worker function is refused');
select is(app.notifications_configure_worker('{"max_attempts": 3}', 'israel') ->> 'max_attempts', '3',
  'a valid change is applied and attributed');

-- Production (no marker): the scheduler stays off ------------------------------------------------
select is(app.notifications_scheduler_tick(), '{"tick": "gate_closed"}'::jsonb,
  'production: the tick does nothing while ops_system_access, Q2 and Q12 are unapproved');
select throws_ok($$select app.notifications_scheduler_enable('israel')$$, '42501', null,
  'production: no scheduler job can be created before the gates are approved');
select is((select last_tick_outcome from app.notifications_scheduler_state), 'gate_closed',
  'the refused tick is recorded content-free');

-- Local: members and worker principals ----------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 3.4');
create temp table m (n int primary key, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.4 Member ' || n, 'pgtap 3.4')
  from generate_series(1, 3) n;
create temp table t_ids (k text primary key, v uuid);
insert into t_ids values ('w1', app.sys_create_principal('pgtap-worker-a', 'notifications_worker', 'israel')),
                         ('w2', app.sys_create_principal('pgtap-worker-b', 'notifications_worker', 'israel')),
                         ('probe', app.sys_create_principal('pgtap-probe-34', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = k2),
  encode(sha256(convert_to(pg_temp.token(f), 'UTF8')), 'hex'), 'pgtap 3.4 ' || k2, interval '1 hour', 'israel')
  from (values ('w1', 'A'), ('w2', 'B'), ('probe', 'P')) x (k2, f);

-- Route contract ------------------------------------------------------------------------------
select is(pg_temp.sys('P', 'notifications.claim') ->> 'code', 'forbidden',
  'a credential of another purpose cannot claim');
select is(pg_temp.sys('A', 'notifications.attempt', '{"job_id": "x", "lease_token": 0, "member_id": 1}') -> 'field_errors',
  '{"job_id": "invalid", "lease_token": "invalid", "member_id": "unknown_field"}'::jsonb,
  'an attempt payload is strict (uuid job id, positive token, no other keys)');
select is(pg_temp.attempt('A', gen_random_uuid(), 1), '{"outcome": "not_found"}'::jsonb,
  'an unknown job answers not_found');
select is(pg_temp.claim('A'), '{"jobs": [], "claimed": 0, "reclaimed": 0, "expired": 0, "lease_seconds": 120}'::jsonb,
  'nothing due: an empty claim');

-- Two workers, one batch -----------------------------------------------------------------------
create temp table j (k text primary key, v uuid);
insert into j select 'r' || g, pg_temp.due(1, now() - make_interval(mins => 10 - g)) from generate_series(1, 3) g;
insert into j values ('future', pg_temp.due(1, now() + interval '1 hour'));
create temp table cl (k text primary key, v jsonb);
insert into cl values ('a', pg_temp.claim('A', 2));
insert into cl values ('b', pg_temp.claim('B'));
select is(array[(select (v ->> 'claimed')::int from cl where k = 'a'), (select (v ->> 'claimed')::int from cl where k = 'b')],
  array[2, 1], 'the first worker leases two (its limit), the second only the one left');
select is((select count(distinct e ->> 'job_id')::int from cl, jsonb_array_elements(v -> 'jobs') e), 3,
  'the two leases are disjoint and cover the batch; the future job is not claimed');
select ok((select bool_and(lease_token is not null and lease_expires_at = now() + interval '120 seconds')
             from app.notifications_jobs where job_id in (select v from j where k like 'r%')),
  'each leased job carries a fencing token and a lease of lease_seconds');
select is((pg_temp.claim('A') ->> 'claimed')::int, 0, 'a live lease is never claimed again');
select is((select count(*)::int from cl, jsonb_array_elements(v -> 'jobs') e,
                lateral (select pg_temp.attempt(case when cl.k = 'a' then 'A' else 'B' end,
                                                (e ->> 'job_id')::uuid, (e ->> 'lease_token')::bigint) ->> 'outcome' o) x
            where x.o = 'delivered'), 3, 'each worker delivers its own leases');
select is((select count(*)::int from app.notifications_inbox_items i
            where i.job_id in (select v from j where k like 'r%')), 3, 'exactly one inbox item per job');
select is(pg_temp.attempt('A', (select v from j where k = 'r1'), pg_temp.tok((select v from cl where k = 'a'), (select v from j where k = 'r1'))),
  '{"outcome": "finished", "finish_reason": "delivered"}'::jsonb,
  'repeating a finished attempt changes nothing (finished)');
select is(pg_temp.outcomes((select v from j where k = 'r1')), 'delivered,finished',
  'both attempts are recorded');
select is(pg_temp.st((select v from j where k = 'future')), 'pending|-', 'the future job waits');

-- A worker killed mid-lease, reclaim and the stale fencing token -----------------------------------
insert into j values ('k', pg_temp.due(2));
insert into cl values ('k1', pg_temp.claim('A'));
select pg_temp.lapse((select v from j where k = 'k'));
insert into cl values ('k2', pg_temp.claim('B'));
select is((select (v ->> 'reclaimed')::int from cl where k = 'k2'), 1, 'an expired lease is reclaimed');
select ok(pg_temp.tok((select v from cl where k = 'k2'), (select v from j where k = 'k'))
          > pg_temp.tok((select v from cl where k = 'k1'), (select v from j where k = 'k')),
  'the reclaim takes a higher fencing token');
select is(pg_temp.attempt('A', (select v from j where k = 'k'), pg_temp.tok((select v from cl where k = 'k1'), (select v from j where k = 'k'))),
  '{"outcome": "fenced"}'::jsonb, 'the killed worker''s late attempt with its stale token is fenced');
select is(pg_temp.st((select v from j where k = 'k')), 'pending|-', 'the fenced attempt changed nothing');
select is(pg_temp.attempt('B', (select v from j where k = 'k'), pg_temp.tok((select v from cl where k = 'k2'), (select v from j where k = 'k'))) ->> 'outcome',
  'delivered', 'the reclaiming worker delivers');
select is(pg_temp.outcomes((select v from j where k = 'k')), 'fenced,delivered',
  'one logical outcome, both attempts recorded');
select is((select count(*)::int from app.notifications_inbox_items where job_id = (select v from j where k = 'k')), 1,
  'still one item');
insert into j values ('lost', pg_temp.due(2));
insert into cl values ('l', pg_temp.claim('A'));
select is(pg_temp.attempt('A', (select v from j where k = 'lost'), pg_temp.tok((select v from cl where k = 'l'), (select v from j where k = 'lost')) + 1000),
  '{"outcome": "fenced"}'::jsonb, 'a token that is not the job''s current one is fenced');
select is(pg_temp.attempt('B', (select v from j where k = 'lost'), pg_temp.tok((select v from cl where k = 'l'), (select v from j where k = 'lost'))),
  '{"outcome": "fenced"}'::jsonb, 'another principal cannot use the holder''s token');
select pg_temp.lapse((select v from j where k = 'lost'));
select is(pg_temp.attempt('A', (select v from j where k = 'lost'), pg_temp.tok((select v from cl where k = 'l'), (select v from j where k = 'lost'))),
  '{"outcome": "fenced"}'::jsonb, 'the holder''s own token is fenced once its lease has lapsed');
select is(pg_temp.st((select v from j where k = 'lost')), 'pending|-', 'and the job is left for a reclaim');
select is((pg_temp.claim('B') ->> 'reclaimed')::int, 1, 'which the next claim performs');

-- Rechecks between claim and attempt ---------------------------------------------------------------
insert into j values ('cancel', pg_temp.due(3)), ('revised', pg_temp.due(3)), ('revoked', pg_temp.due(3)),
                     ('stale_actionable', pg_temp.due(3)), ('expired', pg_temp.due(3));
update app.notifications_jobs set lease_expires_at = null, lease_token = null, lease_principal = null, lease_request = null
 where job_id = (select v from j where k = 'lost');
insert into cl values ('c', pg_temp.claim('A'));
select is((select (v ->> 'claimed')::int from cl where k = 'c'), 6, 'the five new jobs and the lost one are leased');
select is((pg_temp.cmd(3, 'fixture.reminder_cancel', 1,
             jsonb_build_object('source_id', pg_temp.source_of((select v from j where k = 'cancel')))) -> 'data' ->> 'cancelled_jobs'),
  '1', 'the source cancels its leased job after the claim');
update app.fixture_reminder_sources set revision = revision + 1
 where source_id = pg_temp.source_of((select v from j where k = 'revised'));
update app.fixture_reminder_sources set recipient_revoked = true
 where source_id = pg_temp.source_of((select v from j where k = 'revoked'));
update app.fixture_reminder_sources set expires_at = now() - interval '1 second'
 where source_id = pg_temp.source_of((select v from j where k = 'stale_actionable'));
update app.notifications_jobs set expires_at = now() - interval '1 second'
 where job_id = (select v from j where k = 'expired');
create function pg_temp.try(p_k text) returns jsonb language sql as $$
  select pg_temp.attempt('A', (select v from j where k = p_k), pg_temp.tok((select v from cl where k = 'c'), (select v from j where k = p_k)))
$$;
select is(pg_temp.try('cancel'), '{"outcome": "cancelled", "finish_reason": "source_cancelled"}'::jsonb,
  'a job cancelled after the claim is never dispatched');
select is(pg_temp.try('revised'), '{"outcome": "obsolete", "finish_reason": "source_changed"}'::jsonb,
  'a source revised after enqueue ends the job obsolete');
select is(pg_temp.try('revoked'), '{"outcome": "ineligible", "finish_reason": "recipient_ineligible"}'::jsonb,
  'a revoked recipient grant ends the job ineligible');
select is(pg_temp.try('stale_actionable'), '{"outcome": "obsolete", "finish_reason": "not_actionable"}'::jsonb,
  'a source that is no longer actionable ends the job obsolete');
select is(pg_temp.try('expired'), '{"outcome": "expired", "finish_reason": "expired"}'::jsonb,
  'a job past its expiry ends expired at the attempt');
update app.identity_members set membership_state = 'deactivated' where member_id = (select member_id from m where n = 2);
select is(pg_temp.try('lost'), '{"outcome": "ineligible", "finish_reason": "membership_inactive"}'::jsonb,
  'a recipient who is no longer an approved member ends ineligible');
update app.identity_members set membership_state = 'approved' where member_id = (select member_id from m where n = 2);
select is((select string_agg(pg_temp.st(v), ';' order by k) from j where k in ('cancel', 'expired', 'revised', 'revoked', 'stale_actionable')),
  'cancelled|source_cancelled;obsolete|expired;obsolete|source_changed;ineligible|recipient_ineligible;obsolete|not_actionable',
  'each job ends in one recorded state');
select is((select count(*)::int from app.notifications_inbox_items
            where job_id in (select v from j where k in ('cancel', 'revised', 'revoked', 'stale_actionable', 'expired', 'lost'))), 0,
  'none of them became an item');

-- Expiry at the claim (default ttl and own expiry) ------------------------------------------------
insert into j values ('old', pg_temp.due(1, now() - interval '8 days'));
insert into j values ('own', pg_temp.due(1));
update app.notifications_jobs set expires_at = now() - interval '1 minute' where job_id = (select v from j where k = 'own');
select is(pg_temp.claim('A') - 'jobs', '{"claimed": 0, "reclaimed": 0, "expired": 2, "lease_seconds": 120}'::jsonb,
  'the claim expires a job past its own expiry and one past the default ttl, and leases neither');
select is(pg_temp.st((select v from j where k = 'old')) || ';' || pg_temp.st((select v from j where k = 'own')),
  'obsolete|expired;obsolete|expired', 'both end obsolete (expired)');

-- The approved schedule -----------------------------------------------------------------------
insert into j values ('sched', pg_temp.due(1, now() - interval '2 minutes'));
insert into app.notifications_schedules (source_type, source_id, recipient_member_id, source_revision,
  schedule_type, intent, kinds, plan, policy_version, policy_source, policy_digest, schedule_state, end_reason)
select 'fixture_reminder', s.source_id, s.member_id, s.revision, 'task', '{}', '{}', '{}', 1, 'fixture',
       repeat('0', 64), 'ended', 'source_cancelled'
  from app.fixture_reminder_sources s
 where s.source_id = pg_temp.source_of((select v from j where k = 'sched'));
update app.notifications_jobs jj set schedule_id = s.schedule_id
  from app.notifications_schedules s
 where s.source_id = jj.source_id and s.source_type = jj.source_type
   and jj.job_id = (select v from j where k = 'sched');
insert into cl values ('s', pg_temp.claim('A'));
select is(pg_temp.attempt('A', (select v from j where k = 'sched'), pg_temp.tok((select v from cl where k = 's'), (select v from j where k = 'sched'))),
  '{"outcome": "obsolete", "finish_reason": "schedule_changed"}'::jsonb,
  'a job whose schedule has ended is not dispatched');

-- Transient failures, backoff and the attempt limit (max_attempts is 3 here) ------------------------
insert into j values ('flaky', pg_temp.due(1)), ('poison', pg_temp.due(1, now() - interval '5 minutes'));
update app.fixture_reminder_sources set check_fault_until = now() + interval '1 hour'
 where source_id in (pg_temp.source_of((select v from j where k = 'flaky')), pg_temp.source_of((select v from j where k = 'poison')));
insert into cl values ('f1', pg_temp.claim('A'));
select is(pg_temp.attempt('A', (select v from j where k = 'flaky'), pg_temp.tok((select v from cl where k = 'f1'), (select v from j where k = 'flaky'))),
  '{"outcome": "failed"}'::jsonb, 'a raising recheck is a transient failure');
select is((select job_state || '|' || failed_attempts || '|' || (lease_expires_at <= now())::text
             from app.notifications_jobs where job_id = (select v from j where k = 'flaky')),
  'pending|1|true', 'the job stays pending, counts the failure and releases its lease');
select is((select error_sqlstate from app.notifications_attempts where job_id = (select v from j where k = 'flaky')),
  'P0001', 'the attempt records the SQLSTATE only');
select is(pg_temp.attempt('A', (select v from j where k = 'poison'), pg_temp.tok((select v from cl where k = 'f1'), (select v from j where k = 'poison'))),
  '{"outcome": "failed"}'::jsonb, 'the poison job fails too');
select is((pg_temp.claim('A') ->> 'claimed')::int, 0, 'while backing off, neither is claimed');
update app.notifications_jobs set last_failed_at = now() - interval '61 seconds'
 where job_id in ((select v from j where k = 'flaky'), (select v from j where k = 'poison'));
update app.fixture_reminder_sources set check_fault_until = null
 where source_id = pg_temp.source_of((select v from j where k = 'flaky'));
insert into cl values ('f2', pg_temp.claim('A'));
select is(pg_temp.attempt('A', (select v from j where k = 'flaky'), pg_temp.tok((select v from cl where k = 'f2'), (select v from j where k = 'flaky'))) ->> 'outcome',
  'delivered', 'after its backoff the retried job is delivered');
select is(pg_temp.outcomes((select v from j where k = 'flaky')), 'failed,delivered', 'its attempts are recorded in order');
select is(pg_temp.attempt('A', (select v from j where k = 'poison'), pg_temp.tok((select v from cl where k = 'f2'), (select v from j where k = 'poison'))),
  '{"outcome": "failed"}'::jsonb, 'the poison job fails a second time');
select is((pg_temp.claim('A') ->> 'claimed')::int, 0, 'the second backoff (120 s) is longer than the first');
update app.notifications_jobs set last_failed_at = now() - interval '121 seconds'
 where job_id = (select v from j where k = 'poison');
insert into cl values ('f3', pg_temp.claim('A'));
select is(pg_temp.attempt('A', (select v from j where k = 'poison'), pg_temp.tok((select v from cl where k = 'f3'), (select v from j where k = 'poison'))),
  '{"outcome": "exhausted", "finish_reason": "attempts_exhausted"}'::jsonb,
  'at the attempt limit the job is given up');
select is(pg_temp.st((select v from j where k = 'poison')) || ';' || pg_temp.outcomes((select v from j where k = 'poison')),
  'obsolete|attempts_exhausted;failed,failed,exhausted', 'it ends obsolete with every attempt recorded');
select is((pg_temp.claim('A') ->> 'claimed')::int, 0, 'and is never claimed again');

-- deliver_due uses the same rules ----------------------------------------------------------------
insert into j values ('dd', pg_temp.due(1));
select is((pg_temp.sys('A', 'notifications.deliver_due') -> 'data') - 'actor'::text,
  '{"claimed": 1, "delivered": 1, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'the 3.1 deliver step leases and attempts in one transaction');
select is(pg_temp.outcomes((select v from j where k = 'dd')), 'delivered', 'and records the attempt');
select ok((select count(*) from app.notifications_worker_runs) >= 10
          and not exists (select 1 from app.notifications_worker_runs where via not in ('claim', 'deliver_due')),
  'every claim is recorded as a content-free run');

-- Scheduler ------------------------------------------------------------------------------------
select is(app.notifications_scheduler_tick(), '{"tick": "not_configured"}'::jsonb,
  'without a worker URL the tick does nothing');
select app.notifications_configure_worker(
  '{"worker_url": "http://supabase_kong_church-app:8000/functions/v1/notifications-worker"}', 'israel');
select is(app.notifications_scheduler_tick(), '{"tick": "not_configured"}'::jsonb,
  'without the Vault credential the tick does nothing');
select vault.create_secret(pg_temp.token('A'), 'notifications_worker_credential', 'pgtap 3.4');
select is(app.notifications_scheduler_tick(), '{"tick": "sent"}'::jsonb,
  'with the URL and the Vault credential the tick posts to the Edge worker');
select ok(exists (select 1 from net.http_request_queue q
                   where q.url = 'http://supabase_kong_church-app:8000/functions/v1/notifications-worker'
                     and q.body = convert_to('{"action": "run"}', 'UTF8')),
  'the post goes to the configured worker (pg_net queue, sent after commit)');
select throws_ok($$select app.notifications_scheduler_enable('mallory')$$, '42501', null,
  'only a restricted operator creates the scheduler');
select throws_ok($$select app.notifications_scheduler_enable('israel', '5 minutes')$$, '22023', null,
  'the schedule must be one minute or a number of seconds');
select is((app.notifications_scheduler_enable('israel', '30 seconds') -> 'scheduler_jobs')::int, 1,
  'the scheduler is one named Cron job');
select is(app.notifications_scheduler_enable('israel') - array['cron_runs_24h', 'last_tick_at', 'last_claim_at',
            'claims_24h', 'due_pending', 'leased', 'attempts_24h', 'settings'],
  '{"environment": "local", "allowed": true, "scheduler_jobs": 1, "schedule": "* * * * *", "active": true,
    "worker_url_set": true, "last_tick_outcome": "sent"}'::jsonb,
  'enabling again replaces it (still one job, now every minute)');
select ok(not exists (select 1 from cron.job where command like '%sysc_%')
          and not exists (select 1 from cron.job where jobname = 'notifications-worker'
                                                   and command <> 'select app.notifications_scheduler_tick()'),
  'the Cron command holds no credential');
select cron.schedule('pgtap-second-scheduler', '* * * * *', 'select app.notifications_scheduler_tick()');
select throws_ok($$select app.notifications_scheduler_enable('israel')$$, '55000', null,
  'a second Cron job running the tick blocks the enable (one scheduler per environment)');
select cron.unschedule('pgtap-second-scheduler');
select is((app.notifications_scheduler_disable('israel') -> 'scheduler_jobs')::int, 0,
  'disable removes the job');
select is((app.notifications_scheduler_disable('israel') -> 'scheduler_jobs')::int, 0,
  'disabling again is harmless');
select ok((select (s -> 'attempts_24h' ->> 'delivered')::int >= 5 and (s ->> 'leased')::int >= 0
                  and s::text not like '%sysc_%' and s::text not like '%' || (select member_id::text from m where n = 1) || '%'
             from app.notifications_scheduler_status() s),
  'the status is counts and times only');

select * from finish();
rollback;
