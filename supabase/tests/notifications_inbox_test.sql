-- Durable inbox tracer (story 3.1; AD-2, AD-8, AD-19; epic 3 N1, N4, N6). The Notifications
-- owner tables and operations, the SYNTHETIC fixture_reminder source and its commands, the worker
-- step on the system route (purpose notifications_worker) and the member's inbox read behind the
-- live-access predicate. HTTP evidence through real GoTrue: tools/identity-e2e/inbox.mjs. Every
-- account here is SYNTHETIC (+44 7700 900800-900809).
begin;
select plan(62);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000310' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000310' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (800 + n)::text $$;
create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
-- A fixture command as account n (or the given claims) with an optional fixed request id.
create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default null) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  select api.fixture_reminder_command(jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', coalesce(p_request, gen_random_uuid()),
    'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.create_due(n int, p_due timestamptz default now()) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'fixture.reminder_create', null,
                     jsonb_build_object('due_at', app.cmd_utc(p_due)))
$$;
create function pg_temp.inbox(p_claims jsonb) returns text
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  begin
    select api.notifications_my_inbox() into r;
    reset role;
    return 'ok ' || r::text;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
create function pg_temp.items(n int) returns jsonb language sql as
$$ select substr(pg_temp.inbox(pg_temp.c(n)), 4)::jsonb -> 'items' $$;
-- The system route as the worker calls it (anon + x-system-credential).
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
create function pg_temp.sys(p_payload jsonb default '{}', p_token text default null,
                            p_command text default 'notifications.deliver_due') returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', coalesce(p_token, pg_temp.token('N')))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', p_command,
           'request_id', gen_random_uuid(), 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.run() returns jsonb language sql as
$$ select (pg_temp.sys() -> 'data') - 'actor'::text $$;
create function pg_temp.job_state(p_source uuid) returns text language sql as $$
  select string_agg(job_state, ',' order by enqueued_at) from app.notifications_jobs
   where source_type = 'fixture_reminder' and source_id = p_source
$$;
create function pg_temp.item_count() returns int language sql as
$$ select count(*)::int from app.notifications_inbox_items $$;

insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;

-- Structure, privileges and guards -------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.notifications_jobs', 'app.notifications_inbox_items',
                             'app.fixture_reminder_sources']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the new tables');
select ok(not has_function_privilege('anon', 'api.notifications_my_inbox(timestamptz, uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.fixture_reminder_command(jsonb)', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.notifications_my_inbox(timestamptz, uuid)', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.fixture_reminder_command(jsonb)', 'EXECUTE'),
  'signed-out callers execute nothing new; authenticated sessions reach only the read and the fixture command');
select ok(not exists (
  select 1 from unnest(array['app.notifications_enqueue(jsonb)', 'app.notifications_cancel(jsonb)',
                             'app.notifications_sys_deliver_due(uuid,uuid,jsonb)',
                             'app.notifications_check_deliver_due(jsonb)',
                             'app.fixture_reminder_create(uuid,bigint,jsonb)',
                             'app.fixture_reminder_cancel(uuid,bigint,jsonb)',
                             'app.fixture_reminder_check(jsonb)']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'owner operations, the worker handler and the fixture handlers are not client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select module || ':' || check_hook from app.contract_source_types where source_type = 'fixture_reminder'),
  'fixture:app.fixture_reminder_check(jsonb)', 'the fixture module owns the SYNTHETIC source type');
select ok(exists (select 1 from app.contract_reminder_kinds
                   where source_type = 'fixture_reminder' and reminder_kind = 'fixture_due'),
  'its reminder kind is registered');
select is((select purpose || '|' || payload_check || '|' || handler from app.sys_command_kinds
            where command = 'notifications.deliver_due'),
  'notifications_worker|app.notifications_check_deliver_due(jsonb)|app.notifications_sys_deliver_due(uuid, uuid, jsonb)',
  'the worker step is its own purpose on the system route');
select ok(exists (select 1 from app.contract_module_dependencies
                   where from_module = 'fixture' and to_module = 'notifications')
          and not exists (select 1 from app.contract_module_dependencies
                           where from_module = 'notifications' and to_module = 'fixture'),
  'fixture may call notifications, never the reverse');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'notifications_inbox_items'),
  array['delivered_at', 'delivered_by_principal', 'due_at', 'item_id', 'job_id', 'recipient_member_id',
        'reminder_kind'],
  'an inbox item holds ids, the kind and times only (no text, source id or revision)');

-- Production (no marker): the Q2 gate is closed, nothing is enqueued -----------------------------
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 3.1 Gate', 'approved', true) returning member_id)
insert into m select 0, member_id from ins;
insert into app.fixture_reminder_sources (source_id, member_id, due_at, created_by_account)
values ('00000000-0000-4000-a000-000000031000', (select member_id from m where n = 0), now(), pg_temp.u(1));
select throws_ok($$select app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', '00000000-0000-4000-a000-000000031000',
    'source_revision', 1, 'recipient_member_id', (select member_id from m where n = 0),
    'reminder_kind', 'fixture_due', 'scheduled_at', app.cmd_utc(now())))$$,
  'PCMD1', 'unavailable', 'production: enqueue is unavailable while Q2 is unapproved');
select is((select count(*)::int from app.notifications_jobs), 0, 'production: no job written');

-- Local: members, worker credential ----------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 3.1');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.1 Member ' || n, 'pgtap 3.1')
  from generate_series(1, 3) n;
create temp table t_ids (k text primary key, v uuid);
insert into t_ids values ('worker', app.sys_create_principal('pgtap-notifications-worker', 'notifications_worker', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'worker'),
  encode(sha256(convert_to(pg_temp.token('N'), 'UTF8')), 'hex'), 'pgtap 3.1', interval '1 hour', 'israel');
insert into t_ids values ('probe', app.sys_create_principal('pgtap-probe-31', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'probe'),
  encode(sha256(convert_to(pg_temp.token('P'), 'UTF8')), 'hex'), 'pgtap probe 3.1', interval '1 hour', 'israel');
select is((select array_agg(command) from app.sys_principal_commands
            where principal_id = (select v from t_ids where k = 'worker')),
  array['notifications.deliver_due'], 'the worker principal holds exactly the deliver step');

-- Create a due reminder: source and job in one transaction --------------------------------------
create temp table r (k text primary key, v jsonb);
insert into r values ('first', pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_create', null,
  jsonb_build_object('due_at', app.cmd_utc(now() - interval '1 minute')),
  '00000000-0000-4000-b000-000000031001'));
select is((select (v ->> 'revision') || '|' || (v -> 'data' ->> 'state') || '|' || (v -> 'data' ->> 'job_state')
                  || '|' || (v -> 'data' ->> 'job_created') from r where k = 'first'),
  '1|active|pending|true', 'the command creates the source at revision 1 and enqueues one pending job');
select is((select count(*)::int || '|' || min(policy_source) || '|' || min(source_revision)::text
                  || '|' || (bool_and(recipient_member_id = (select member_id from m where n = 1)))::text
             from app.notifications_jobs),
  '1|fixture|1|true', 'one job for the caller''s member, source revision 1, under the labelled Q2 fixture');
select is((select policy_digest from app.notifications_jobs limit 1),
  encode(sha256(convert_to((app.policy_effective('q2_church_time') -> 'value')::text, 'UTF8')), 'hex'),
  'the job records the digest of the applied Q2 policy value');
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_create', null,
            jsonb_build_object('due_at', app.cmd_utc(now() - interval '1 minute')),
            '00000000-0000-4000-b000-000000031001'),
  (select v from r where k = 'first'), 'repeating the command (same request id) returns the stored result');
select is((select count(*)::int from app.notifications_jobs), 1, 'and adds no second job');
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_create', null,
            jsonb_build_object('due_at', app.cmd_utc(now())), '00000000-0000-4000-b000-000000031001') ->> 'code',
  'conflict', 'the same request id with a changed body is a conflict');
select is(app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', (select v -> 'data' ->> 'source_id' from r where k = 'first'),
    'source_revision', 1, 'recipient_member_id', (select member_id from m where n = 1),
    'reminder_kind', 'fixture_due',
    'scheduled_at', (select v -> 'data' ->> 'due_at' from r where k = 'first'))) -> 'created',
  'false'::jsonb, 'enqueueing the same logical key again creates nothing');
select is(pg_temp.items(1), '[]'::jsonb, 'nothing is in the inbox before the worker runs');

-- Worker: exactly one item, repeat runs add nothing ---------------------------------------------
select is(pg_temp.run(), '{"claimed": 1, "delivered": 1, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'the worker turns the due job into one inbox item');
select is(pg_temp.run(), '{"claimed": 0, "delivered": 0, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'a second worker run finds nothing to do');
select is(pg_temp.item_count(), 1, 'still exactly one inbox item');
select is(pg_temp.job_state(((select v -> 'data' ->> 'source_id' from r where k = 'first'))::uuid), 'delivered',
  'the job is delivered');
select throws_ok($$insert into app.notifications_inbox_items (job_id, recipient_member_id, reminder_kind, due_at, delivered_by_principal)
                   select i.job_id, i.recipient_member_id, i.reminder_kind, i.due_at, i.delivered_by_principal
                     from app.notifications_inbox_items i limit 1$$,
  '23505', null, 'a second item for the same job is impossible (duplicate or racing workers)');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.items(1) -> 0) k),
  array['delivered_at', 'due_at', 'item_id', 'reminder_kind'],
  'the member reads the item: kind and times only');
select is(pg_temp.items(1) -> 0 ->> 'reminder_kind', 'fixture_due', 'the item is the fixture reminder');
select is(pg_temp.items(2), '[]'::jsonb, 'another member sees nothing');
select is(pg_temp.inbox('{"role": "authenticated"}'::jsonb), 'PT401|unauthenticated|unauthenticated',
  'a session without a subject is refused by the live-access predicate');
select is(pg_temp.sys('{}', pg_temp.token('P')) ->> 'code', 'forbidden',
  'a principal of another purpose cannot run the worker step');
select is(pg_temp.sys('{"limit": 0}') -> 'field_errors', '{"limit": "out_of_range"}'::jsonb,
  'the worker limit is bounded');
select is(pg_temp.sys('{"member_id": "x"}') -> 'field_errors', '{"member_id": "unknown_field"}'::jsonb,
  'the worker payload is strict');

-- Cancelled work never becomes an item --------------------------------------------------------
insert into r values ('cancel', pg_temp.create_due(1, now() - interval '1 minute'));
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_cancel', 2,
            jsonb_build_object('source_id', (select v -> 'data' ->> 'source_id' from r where k = 'cancel'))) ->> 'code',
  'conflict', 'a stale expected revision is a conflict');
select is(pg_temp.cmd(pg_temp.c(2), 'fixture.reminder_cancel', 1,
            jsonb_build_object('source_id', (select v -> 'data' ->> 'source_id' from r where k = 'cancel'))) ->> 'code',
  'not_found', 'another member cannot cancel it');
insert into r values ('cancelled', pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_cancel', 1,
  jsonb_build_object('source_id', (select v -> 'data' ->> 'source_id' from r where k = 'cancel'))));
select is((select (v ->> 'revision') || '|' || (v -> 'data' ->> 'state') || '|' || (v -> 'data' ->> 'cancelled_jobs')
             from r where k = 'cancelled'),
  '2|cancelled|1', 'cancelling the source cancels its pending job in the same transaction');
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_cancel', 2,
            jsonb_build_object('source_id', (select v -> 'data' ->> 'source_id' from r where k = 'cancel'))) -> 'field_errors',
  '{"source_id": "cancelled"}'::jsonb, 'a cancelled source cannot be cancelled again');
select is(pg_temp.run() ->> 'delivered', '0', 'the worker delivers nothing for the cancelled job');
select is(pg_temp.job_state(((select v -> 'data' ->> 'source_id' from r where k = 'cancel'))::uuid) || '|'
          || (select cancel_reason from app.notifications_jobs j
               where j.source_id = ((select v -> 'data' ->> 'source_id' from r where k = 'cancel'))::uuid),
  'cancelled|source_cancelled', 'the job stays cancelled with its reason');
select throws_ok(format($$select app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', %L, 'source_revision', 2,
    'recipient_member_id', %L, 'reminder_kind', 'fixture_due', 'scheduled_at', app.cmd_utc(now())))$$,
    (select v -> 'data' ->> 'source_id' from r where k = 'cancel'), (select member_id from m where n = 1)),
  'PCMD1', 'conflict', 'a source that is no longer current cannot be enqueued');
select is(pg_temp.item_count(), 1, 'still one inbox item');

-- Future, stale-source and ineligible jobs ------------------------------------------------------
insert into r values ('future', pg_temp.create_due(1, now() + interval '1 day'));
insert into r values ('stale', pg_temp.create_due(1, now() - interval '1 minute'));
update app.fixture_reminder_sources set revision = revision + 1
 where source_id = ((select v -> 'data' ->> 'source_id' from r where k = 'stale'))::uuid;
insert into r values ('leaving', pg_temp.create_due(3, now() - interval '1 minute'));
update app.identity_members set membership_state = 'deactivated' where member_id = (select member_id from m where n = 3);
select is(pg_temp.run(), '{"claimed": 2, "delivered": 0, "obsolete": 1, "ineligible": 1, "failed": 0}'::jsonb,
  'a stale source ends obsolete, a recipient who is no longer approved ends ineligible, a future job waits');
select is(pg_temp.job_state(((select v -> 'data' ->> 'source_id' from r where k = 'future'))::uuid), 'pending',
  'the future job stays pending');
select is(pg_temp.item_count(), 1, 'none of them became an item');

-- A recheck that raises leaves the job pending and backs off; it never blocks later jobs -------
create function app.fixture_pgtap_flaky_check(p_source jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if current_setting('pgtap.flaky', true) = 'on' then
    raise exception 'flaky source owner';
  end if;
  return '{"current": true, "revision": 1}'::jsonb;
end;
$$;
select app.contract_register_source_type('fixture', 'fixture_pgtap_flaky', 'app.fixture_pgtap_flaky_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('fixture', 'fixture_pgtap_flaky', 'fixture_due');
select app.notifications_enqueue(jsonb_build_object(
  'source_type', 'fixture_pgtap_flaky', 'source_id', gen_random_uuid(), 'source_revision', 1,
  'recipient_member_id', (select member_id from m where n = 2), 'reminder_kind', 'fixture_due',
  'scheduled_at', app.cmd_utc(now() - interval '1 minute')));
select set_config('pgtap.flaky', 'on', true);
select is(pg_temp.run(), '{"claimed": 1, "delivered": 0, "obsolete": 0, "ineligible": 0, "failed": 1}'::jsonb,
  'a raising recheck is counted failed and its work rolled back');
select is((select job_state || '|' || failed_attempts || '|' || (last_failed_at is not null)::text
             from app.notifications_jobs where source_type = 'fixture_pgtap_flaky'),
  'pending|1|true', 'the job stays pending with its failure recorded');
insert into r values ('later', pg_temp.create_due(2, now() - interval '30 seconds'));
select is((pg_temp.sys('{"limit": 1}') -> 'data') - 'actor'::text,
  '{"claimed": 1, "delivered": 1, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'a failing job backs off: a later due job is delivered even with limit 1');
select is(pg_temp.job_state(((select v -> 'data' ->> 'source_id' from r where k = 'later'))::uuid), 'delivered',
  'the later job is the one delivered');
select set_config('pgtap.flaky', 'off', true);
select is(pg_temp.run() ->> 'claimed', '0', 'while backing off the failed job is not retried');
update app.notifications_jobs set last_failed_at = now() - interval '2 minutes'
 where source_type = 'fixture_pgtap_flaky';
select is(pg_temp.run() ->> 'delivered', '1', 'after its backoff the next run delivers it');
select is(jsonb_array_length(pg_temp.items(2)), 2, 'member 2 sees exactly their own two items');

-- Keyset paging of the inbox ------------------------------------------------------------------
select app.notifications_enqueue(jsonb_build_object(
  'source_type', 'fixture_pgtap_flaky', 'source_id', gen_random_uuid(), 'source_revision', 1,
  'recipient_member_id', (select member_id from m where n = 1), 'reminder_kind', 'fixture_due',
  'scheduled_at', app.cmd_utc(now() - interval '1 minute')))
  from generate_series(1, 50);
select is(pg_temp.sys('{"limit": 100}') -> 'data' ->> 'delivered', '50', 'fifty more items for member 1');
create function pg_temp.page(p_after jsonb) returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(1)::text, true);
  set local role authenticated;
  select api.notifications_my_inbox((p_after ->> 'after_delivered_at')::timestamptz,
                                    (p_after ->> 'after_item_id')::uuid) into r;
  reset role;
  return r;
end;
$$;
insert into r values ('page1', pg_temp.page(null));
insert into r values ('page2', pg_temp.page((select v -> 'next' from r where k = 'page1')));
select is((select jsonb_array_length(v -> 'items') || '|' || (v -> 'next' is not null and v -> 'next' <> 'null')::text
             from r where k = 'page1'), '50|true', 'the first page holds 50 items and a cursor');
select is((select jsonb_array_length(v -> 'items') || '|' || coalesce(v ->> 'next', 'null') from r where k = 'page2'),
  '1|null', 'the second page holds the rest and no cursor');
select is((select count(distinct e ->> 'item_id')::int from r, jsonb_array_elements(v -> 'items') e
            where k in ('page1', 'page2')), 51, 'the pages neither overlap nor skip an item');

-- Command refusals ------------------------------------------------------------------------------
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_create', null, '{"due_at": "tomorrow", "note": "x"}') -> 'field_errors',
  '{"due_at": "invalid", "note": "unknown_field"}'::jsonb, 'the create payload is strict');
select is(pg_temp.cmd('{"role": "authenticated"}'::jsonb, 'fixture.reminder_create', null,
            jsonb_build_object('due_at', app.cmd_utc(now()))) ->> 'code',
  'unauthenticated', 'no session, no command');
update app.identity_members set is_synthetic = false where member_id = (select member_id from m where n = 2);
select is(pg_temp.create_due(2) ->> 'code', 'forbidden',
  'a member who is not SYNTHETIC cannot create fixture reminders (refused by the live-access gate here)');
-- With private access open, a non-SYNTHETIC member passes the live-access predicate, so the
-- fixture handler's own SYNTHETIC check is what refuses.
select app.policy_approve('private_access', '{"serve": true}', 'pgtap', 'pgtap 3.1 only, rolled back');
select is(pg_temp.create_due(2) -> 'field_errors', '{"member_id": "unsupported"}'::jsonb,
  'the fixture handler itself refuses a member who is not SYNTHETIC');

-- Production: the fixture command is refused and writes nothing --------------------------------
create temp table counts as
  select (select count(*) from app.fixture_reminder_sources) s, (select count(*) from app.notifications_jobs) j;
select app.platform_set_environment('production', 'pgtap 3.1');
update app.policy_gates set state = 'unresolved', approved_value = null, approved_by = null,
       approved_at = null, approval_note = null
 where gate = 'private_access';
select is(pg_temp.create_due(1) ->> 'code', 'forbidden',
  'production: the fixture command is refused (forbidden: no member access is served without the Q1 settings and release gates)');
select is((select count(*) from app.fixture_reminder_sources) || '|' || (select count(*) from app.notifications_jobs),
  (select s || '|' || j from counts), 'production: no source and no job written');

select * from finish();
rollback;
