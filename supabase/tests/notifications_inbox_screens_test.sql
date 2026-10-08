-- The inbox screens' server contract (story 3.7; AD-5, AD-8, AD-13; epic 3 N6, N3): opened and
-- snoozed markers, the member snooze command (choices from the policy, clamped to the source
-- expiry, ended by a response or a cancellation), push off keeping in-app items, and the
-- per-account generic refresh signal (Realtime broadcast with an empty payload, receive-only
-- channel authorisation). The signal checks are skipped when this database has no Realtime
-- message partition for today (they then run in tools/identity-e2e/inbox-screens.mjs against
-- a running Realtime). Every account here is SYNTHETIC (+44 7700 900920-900929).
begin;
select plan(65);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000370' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000370' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (920 + n)::text $$;
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
-- A command envelope as member n (expected_revision null unless given).
create function pg_temp.cmd(n int, p_endpoint text, p_command text, p_payload jsonb,
                            p_expected bigint default null) returns jsonb
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
-- A read as member n.
create function pg_temp.read(n int, p_sql text) returns jsonb
language plpgsql as $$
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
create function pg_temp.open(n int, p_item uuid) returns jsonb language sql as
$$ select pg_temp.read(n, format('select api.notifications_open_item(%L::uuid)', p_item)) $$;
create function pg_temp.listed(n int, p_item uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.read(n, 'select api.notifications_my_inbox()') -> 'items') e
   where (e ->> 'item_id')::uuid = p_item
$$;
create function pg_temp.snooze(n int, p_item uuid, p_choice text, p_expected bigint default null)
returns jsonb language sql as $$
  select pg_temp.cmd(n, 'notifications_command', 'notifications.snooze_item',
                     jsonb_build_object('item_id', p_item, 'choice', p_choice), p_expected)
$$;
-- 'code {field_errors}' of an error envelope, or 'ok'.
create function pg_temp.res(p jsonb) returns text language sql as $$
  select case when p ? 'code' then (p ->> 'code') || ' ' || (p -> 'field_errors')::text else 'ok' end
$$;
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.deliver() returns jsonb language sql as
$$ select app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') $$;
create function pg_temp.item_of(p_source uuid) returns uuid language sql as $$
  select i.item_id from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
   where j.source_id = p_source and j.snoozed_from_item_id is null
   order by i.delivered_at desc limit 1
$$;
create function pg_temp.snooze_jobs(p_item uuid) returns text language sql as $$
  select coalesce(string_agg(job_state || ':' || coalesce(cancel_reason, '-'), ',' order by enqueued_at), '')
    from app.notifications_jobs where snoozed_from_item_id = p_item
$$;
create temp table v (k text primary key, id uuid, j jsonb);

-- Realtime: whether a broadcast row can be stored now (table and today's partition exist).
create function pg_temp.rt() returns boolean language plpgsql as $$
begin
  if to_regclass('realtime.messages') is null then
    return false;
  end if;
  begin
    execute 'insert into realtime.messages (topic, extension, payload, event, private) '
            'values (''pgtap-probe'', ''broadcast'', ''{}'', ''probe'', true)';
    raise exception using errcode = 'P0001', message = 'probe ok';
  exception when others then
    return sqlerrm = 'probe ok';
  end;
end;
$$;
-- Broadcast rows for member n's account so far in this transaction.
create function pg_temp.sig(n int) returns int language plpgsql as $$
begin
  if to_regclass('realtime.messages') is null then
    return 0;
  end if;
  return (select count(*)::int from realtime.messages where topic = 'account:' || pg_temp.u(n)::text);
end;
$$;
-- A new transaction as far as the per-transaction de-duplication is concerned.
create function pg_temp.next_tx() returns void language sql as
$$ select set_config('app.notifications_refreshed', '', true) $$;

-- Accounts: 1 Admin; 2 member A; 3 member B. Member 4 has no account.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 3) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 3) n;
select app.platform_set_environment('local', 'pgtap 3.7');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.7 Member ' || n, 'pgtap 3.7')
  from generate_series(1, 3) n;
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 3.7 Accountless', 'approved', true) returning member_id)
insert into m select 4, member_id from ins;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

-- Structure and privileges --------------------------------------------------------------------
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'app'
     and p.proname in ('notifications_item_snoozed_until', 'notifications_snooze_choices',
                       'notifications_item_snooze', 'notifications_publish_refresh',
                       'notifications_inbox_item_signal', 'fixture_reminder_reply_schedule',
                       'fixture_reminder_schedule', 'fixture_reminder_respond')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'nothing new is client-executable (snooze goes through the existing member command)');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select string_agg(tgname, ',' order by tgname) from pg_trigger
            where tgrelid in ('app.notifications_inbox_items'::regclass, 'app.notifications_jobs'::regclass)
              and tgname like '%signal%'),
  'notifications_inbox_items_signal_insert,notifications_inbox_items_signal_update,notifications_jobs_snooze_signal_insert,notifications_jobs_snooze_signal_update',
  'the inbox and snooze changes publish the refresh signal');
select is((select count(*)::int from app.contract_reminder_contracts
            where source_type = 'fixture_reminder' and reminder_kind = 'fixture_reply'
              and title = 'SYNTHETIC reply reminder'), 1,
  'the SYNTHETIC reply kind registers its generic contract');

-- Opened marker -------------------------------------------------------------------------------
insert into v (k, id) values ('src1', (pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_create',
  jsonb_build_object('due_at', app.cmd_utc(now() - interval '1 minute'))) -> 'data' ->> 'source_id')::uuid);
select pg_temp.next_tx();
select is(pg_temp.deliver() -> 'data' ->> 'delivered', '1', 'the worker delivers the reminder');
insert into v (k, id) values ('item1', pg_temp.item_of((select id from v where k = 'src1')));
select is(pg_temp.listed(2, (select id from v where k = 'item1')) - 'item_id' - 'due_at' - 'delivered_at',
  '{"opened": false, "snoozed_until": null, "title": "SYNTHETIC test reminder", "body": "A test reminder is waiting for you.", "reminder_kind": "fixture_due"}'::jsonb,
  'a new item is listed as not opened and not snoozed');
select is(pg_temp.open(3, (select id from v where k = 'item1')), '{"state": "not_found"}'::jsonb,
  'another member opening it learns nothing');
select is((select opened_at from app.notifications_inbox_items where item_id = (select id from v where k = 'item1')),
  null, '... and does not mark it opened');
select pg_temp.next_tx();
insert into v (k, j) values ('open1', pg_temp.open(2, (select id from v where k = 'item1')));
select is((select j - 'item_id' - 'due_at' - 'delivered_at' - 'target' from v where k = 'open1'),
  '{"state": "current", "title": "SYNTHETIC test reminder", "body": "A test reminder is waiting for you.", "reminder_kind": "fixture_due", "snooze_choices": ["1 hour", "24 hours", "2 days"], "snoozed_until": null}'::jsonb,
  'a current item offers the policy''s snooze choices');
select is(pg_temp.listed(2, (select id from v where k = 'item1')) ->> 'opened', 'true', 'opening marks it opened');
insert into v (k, j) values ('opened_at', (select to_jsonb(opened_at) from app.notifications_inbox_items
                                           where item_id = (select id from v where k = 'item1')));
select pg_temp.open(2, (select id from v where k = 'item1'));
select is((select to_jsonb(opened_at) from app.notifications_inbox_items where item_id = (select id from v where k = 'item1')),
  (select j from v where k = 'opened_at'), 'a second open changes nothing');

-- Snooze ---------------------------------------------------------------------------------------
select is(pg_temp.res(pg_temp.snooze(3, (select id from v where k = 'item1'), '1 hour')), 'not_found {}',
  'another member cannot snooze the item');
select is(pg_temp.res(pg_temp.snooze(2, (select id from v where k = 'item1'), '3 hours')),
  'validation_failed {"choice": "invalid"}', 'only a policy choice is accepted');
select is(pg_temp.res(pg_temp.cmd(2, 'notifications_command', 'notifications.snooze_item',
            jsonb_build_object('item_id', (select id from v where k = 'item1'), 'note', 'x'))),
  'validation_failed {"note": "unknown_field", "choice": "required"}', 'the payload is strict');
select is(pg_temp.res(pg_temp.snooze(2, (select id from v where k = 'item1'), '1 hour', 1)),
  'validation_failed {"expected_revision": "must_be_null"}', 'a snooze carries no expected revision');
select is(pg_temp.snooze_jobs((select id from v where k = 'item1')), '', 'the refusals wrote nothing');
select pg_temp.next_tx();
insert into v (k, j) values ('sz1', pg_temp.snooze(2, (select id from v where k = 'item1'), '24 hours'));
select is((select (j -> 'data') - 'scheduled_at' || jsonb_build_object('revision', j -> 'revision') from v where k = 'sz1'),
  jsonb_build_object('item_id', (select id from v where k = 'item1'), 'clamped', false, 'expires_at', null, 'revision', 2),
  'the member snoozes the item for 24 hours (the item''s revision moves to 2)');
select ok((select (j -> 'data' ->> 'scheduled_at')::timestamptz between now() + interval '23 hours 59 minutes'
                                                                    and now() + interval '24 hours 1 minute'
             from v where k = 'sz1'), 'it fires again in 24 hours');
select is(pg_temp.snooze_jobs((select id from v where k = 'item1')), 'pending:-', 'one pending snooze job');
select is(pg_temp.listed(2, (select id from v where k = 'item1')) ->> 'snoozed_until',
  (select j -> 'data' ->> 'scheduled_at' from v where k = 'sz1'), 'the list shows when it comes back');
select is(pg_temp.open(2, (select id from v where k = 'item1')) ->> 'snoozed_until',
  (select j -> 'data' ->> 'scheduled_at' from v where k = 'sz1'), 'so does the opened item');
select pg_temp.next_tx();
insert into v (k, j) values ('sz2', pg_temp.snooze(2, (select id from v where k = 'item1'), '1 hour'));
select is(pg_temp.snooze_jobs((select id from v where k = 'item1')), 'cancelled:snooze_replaced,pending:-',
  'a new snooze replaces the earlier one');

-- Cancellation ends the snooze ---------------------------------------------------------------
select pg_temp.next_tx();
select is(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_cancel',
            jsonb_build_object('source_id', (select id from v where k = 'src1')), 1)), 'ok',
  'the source is cancelled');
select is(pg_temp.snooze_jobs((select id from v where k = 'item1')), 'cancelled:snooze_replaced,cancelled:source_cancelled',
  'the pending snooze is cancelled with it');
select is(pg_temp.listed(2, (select id from v where k = 'item1')) ->> 'snoozed_until', null, 'the list no longer shows a snooze');
select is(pg_temp.open(2, (select id from v where k = 'item1')) ->> 'state', 'superseded', 'the item opens out of date');
select is(pg_temp.res(pg_temp.snooze(2, (select id from v where k = 'item1'), '1 hour')),
  'conflict {"item_id": "superseded"}', 'and cannot be snoozed again');

-- Clamp to the expiry, then a response ends the snooze -----------------------------------------
select is(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_schedule',
            jsonb_build_object('starts_at', app.cmd_utc(now() - interval '1 hour')))),
  'validation_failed {"starts_at": "invalid"}', 'a SYNTHETIC request must start in the future');
insert into v (k, id, j) select 'src2', (r -> 'data' ->> 'source_id')::uuid, r
  from pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_schedule',
                   jsonb_build_object('starts_at', app.cmd_utc(date_trunc('second', now()) + interval '20 hours'))) r;
select is((select (j -> 'data' ->> 'enqueued')::int from v where k = 'src2'), 1,
  'short notice: one respond-now reminder, planned by the 3.3 calculation');
select is((select string_agg(reminder_kind || '|' || (scheduled_at <= now())::text || '|' || app.cmd_utc(expires_at), ',')
             from app.notifications_jobs where source_id = (select id from v where k = 'src2')),
  'fixture_reply|true|' || app.cmd_utc(date_trunc('second', now()) + interval '20 hours'),
  'it is due now and expires when the request starts');
select pg_temp.next_tx();
select pg_temp.deliver();
insert into v (k, id) values ('item2', pg_temp.item_of((select id from v where k = 'src2')));
select isnt((select id from v where k = 'item2'), null, 'the reply reminder reached the inbox');
select pg_temp.next_tx();
insert into v (k, j) values ('sz3', pg_temp.snooze(2, (select id from v where k = 'item2'), '2 days'));
select is((select (j -> 'data' ->> 'clamped')::boolean from v where k = 'sz3'), true,
  'a 2-day snooze past the request''s start is clamped');
select is((select j -> 'data' ->> 'scheduled_at' from v where k = 'sz3'),
  app.cmd_utc(date_trunc('second', now()) + interval '20 hours'), '... to the expiry itself');
select is((select j -> 'data' ->> 'expires_at' from v where k = 'sz3'),
  app.cmd_utc(date_trunc('second', now()) + interval '20 hours'), 'the answer names the expiry');
select is(pg_temp.res(pg_temp.cmd(3, 'fixture_reminder_command', 'fixture.reminder_respond',
            jsonb_build_object('source_id', (select id from v where k = 'src2')), 1)), 'not_found {}',
  'only the recipient answers their request');
select pg_temp.next_tx();
select is(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_respond',
            jsonb_build_object('source_id', (select id from v where k = 'src2')), 1)), 'ok',
  'the member responds');
select is(pg_temp.snooze_jobs((select id from v where k = 'item2')), 'cancelled:responded',
  'the response cancels the pending snooze');
select is(pg_temp.listed(2, (select id from v where k = 'item2')) ->> 'snoozed_until', null,
  'the list no longer shows a snooze');
select is(pg_temp.open(2, (select id from v where k = 'item2')) - 'item_id' - 'due_at' - 'delivered_at',
  '{"state": "superseded", "target": null, "title": "SYNTHETIC reply reminder", "body": "A test request is waiting for your answer.", "reminder_kind": "fixture_reply"}'::jsonb,
  'the answered reminder opens out of date, with no snooze offered');
select is(pg_temp.res(pg_temp.snooze(2, (select id from v where k = 'item2'), '1 hour')),
  'conflict {"item_id": "superseded"}', 'and cannot be snoozed again');
select is(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_respond',
            jsonb_build_object('source_id', (select id from v where k = 'src2')), 1)),
  'conflict {"source_id": "responded"}', 'a second response is refused');

-- An expired reminder cannot be snoozed through the member command ------------------------------
insert into v (k, id) values ('srcx', (pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_create',
  jsonb_build_object('due_at', app.cmd_utc(now() - interval '1 minute'))) -> 'data' ->> 'source_id')::uuid);
select pg_temp.next_tx();
select pg_temp.deliver();
insert into v (k, id) values ('itemx', pg_temp.item_of((select id from v where k = 'srcx')));
update app.notifications_jobs j set expires_at = now() - interval '1 second'
 where j.job_id = (select i.job_id from app.notifications_inbox_items i where i.item_id = (select id from v where k = 'itemx'));
select is(pg_temp.res(pg_temp.snooze(2, (select id from v where k = 'itemx'), '1 hour')),
  'conflict {"item_id": "expired"}', 'a reminder past its expiry cannot be snoozed');
select is(pg_temp.snooze_jobs((select id from v where k = 'itemx')), '', '... and nothing was written');

-- Push off keeps in-app items -----------------------------------------------------------------
select pg_temp.cmd(2, 'notifications_command', 'notifications.register_device',
  '{"token": "fcm-ssssssssssssssssssssssssssssssssssssssss:APA91b", "platform": "android"}');
select is(pg_temp.res(pg_temp.cmd(2, 'notifications_command', 'notifications.set_push_category',
            '{"source_type": "fixture_reminder", "reminder_kind": "fixture_due", "push_enabled": false}')), 'ok',
  'the member turns push off for the category');
insert into v (k, id) values ('src3', (pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_create',
  jsonb_build_object('due_at', app.cmd_utc(now() - interval '1 minute'))) -> 'data' ->> 'source_id')::uuid);
select pg_temp.next_tx();
select pg_temp.deliver();
insert into v (k, id) values ('item3', pg_temp.item_of((select id from v where k = 'src3')));
select is(pg_temp.listed(2, (select id from v where k = 'item3')) ->> 'opened', 'false',
  'with push off the reminder is still in the inbox');
select is((select count(*)::int from app.notifications_push_jobs where item_id = (select id from v where k = 'item3')), 0,
  '... and no push is queued for it');

-- The refresh signal ---------------------------------------------------------------------------
create function pg_temp.total() returns int language plpgsql as $$
begin
  if to_regclass('realtime.messages') is null then
    return 0;
  end if;
  return (select count(*)::int from realtime.messages);
end;
$$;
select pg_temp.next_tx();
insert into v (k, j) values ('total', to_jsonb(pg_temp.total()));
select app.notifications_publish_refresh(pg_temp.mid(4));
select is(pg_temp.total(), (select (j #>> '{}')::int from v where k = 'total'),
  'an accountless member has no account to signal: nothing is published');
select * from (select case when pg_temp.rt() then
  is(pg_temp.sig(2), 10, 'one signal per changing transaction for A: two deliveries, first open, three snoozes, '
                        'cancellation, response, push-off delivery and the reply delivery')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
select * from (select case when pg_temp.rt() then
  is((select count(*)::int from realtime.messages where topic = 'account:' || pg_temp.u(2)::text
        and (payload <> '{}'::jsonb or event <> 'inbox_changed' or not private or extension <> 'broadcast')), 0,
     'every signal is a private broadcast `inbox_changed` with an empty payload (no ids, text or source type)')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
select * from (select case when pg_temp.rt() then
  is(pg_temp.sig(3), 0, 'B''s failed open and snooze of A''s item signal nobody on B''s account')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
create function pg_temp.rolled_back() returns int language plpgsql as $$
begin
  perform pg_temp.next_tx();
  begin
    perform app.notifications_publish_refresh(pg_temp.mid(2));
    raise exception 'roll back';
  exception when others then
    null;
  end;
  return pg_temp.sig(2);
end;
$$;
select * from (select case when pg_temp.rt() then
  is(pg_temp.rolled_back(), 10, 'a rolled back change publishes nothing')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
-- Channel authorisation: a session reads its own topic only; nobody may send.
create function pg_temp.visible(n int, p_topic_of int) returns int language plpgsql as $$
declare
  r int;
  v_topic text := 'account:' || pg_temp.u(p_topic_of)::text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  perform set_config('realtime.topic', v_topic, true);
  set local role authenticated;
  select count(*)::int into r from realtime.messages where topic = v_topic;
  reset role;
  return r;
end;
$$;
create function pg_temp.send_as(n int) returns text language plpgsql as $$
declare
  v_topic text := 'account:' || pg_temp.u(n)::text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  perform set_config('realtime.topic', v_topic, true);
  set local role authenticated;
  insert into realtime.messages (topic, extension, payload, event, private)
  values (v_topic, 'broadcast', '{}', 'inbox_changed', true);
  reset role;
  return 'sent';
exception when others then
  reset role;
  return sqlstate;
end;
$$;
select * from (select case when pg_temp.rt() then
  is(pg_temp.visible(2, 2), 10, 'A''s session may read A''s own topic')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
select * from (select case when pg_temp.rt() then
  is(pg_temp.visible(3, 2), 0, 'B''s session cannot read A''s topic')
  else skip('no Realtime message partition for today (covered by the E2E)', 1) end) x;
select * from (select case when to_regclass('realtime.messages') is not null then
  is(pg_temp.send_as(2), '42501', 'a client cannot publish on its own topic (receive-only)')
  else skip('Realtime is not installed here', 1) end) x;
select * from (select case when to_regclass('realtime.messages') is not null then
  is((select string_agg(polcmd::text || ':' || array_to_string(polroles::regrole[], '+'), ',')
        from pg_policy where polrelid = 'realtime.messages'::regclass
         and polname = 'notifications_account_refresh_receive'),
     'r:authenticated', 'the one Notifications policy on realtime.messages is SELECT for authenticated')
  else skip('Realtime is not installed here', 1) end) x;

-- SYNTHETIC fixture commands and categories: never for real members, never in production -------
update app.identity_members set is_synthetic = false where member_id = pg_temp.mid(3);
select ok(pg_temp.res(pg_temp.cmd(3, 'fixture_reminder_command', 'fixture.reminder_schedule',
            jsonb_build_object('starts_at', app.cmd_utc(now() + interval '20 hours')))) like 'forbidden%',
  'a non-SYNTHETIC member cannot schedule a test request');
select ok(pg_temp.res(pg_temp.cmd(3, 'fixture_reminder_command', 'fixture.reminder_respond',
            jsonb_build_object('source_id', (select id from v where k = 'src2')), 1)) like 'forbidden%',
  '... nor respond to one');
update app.identity_members set is_synthetic = true where member_id = pg_temp.mid(3);
select is((select count(*)::int from jsonb_array_elements(
             pg_temp.read(2, 'select api.notifications_my_push_settings()') -> 'categories') e
            where e ->> 'source_type' = 'fixture_reminder'), 2,
  'in local, the SYNTHETIC categories are offered');
create function pg_temp.set_err(p jsonb) returns text language plpgsql as $$
begin
  perform app.notifications_push_category_set(pg_temp.u(2), null, p);
  return 'ok';
exception when others then
  return sqlerrm;
end;
$$;

select app.platform_set_environment('production', 'pgtap 3.7');
select isnt(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_schedule',
            jsonb_build_object('starts_at', app.cmd_utc(now() + interval '20 hours')))), 'ok',
  'production refuses a test request');
select isnt(pg_temp.res(pg_temp.cmd(2, 'fixture_reminder_command', 'fixture.reminder_respond',
            jsonb_build_object('source_id', (select id from v where k = 'src2')), 1)), 'ok',
  '... and a test response');
select ok(not app.notifications_category_offered('fixture') and app.notifications_category_offered('duties'),
  'production offers no SYNTHETIC (fixture module) category; real modules stay');
select ok((select prosrc like '%notifications_category_offered(c.module)%' from pg_proc
            where oid = 'app.notifications_my_push_settings()'::regprocedure),
  'notification settings list only offered categories');
select is(pg_temp.set_err('{"source_type": "fixture_reminder", "reminder_kind": "fixture_reply", "push_enabled": false}'),
  'validation_failed', 'setting a SYNTHETIC category is refused in production (unregistered)');

select * from finish();
rollback;
