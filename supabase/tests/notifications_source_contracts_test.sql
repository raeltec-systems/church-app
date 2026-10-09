-- Source contracts with generic payloads and authorised deep links (story 3.2; AD-5, AD-8;
-- epic 3 N1, N2). Registration of reminder contracts and its refusals, strict enqueue keys, the
-- strict reminder check answer, the worker recheck through the contract, opening an item for a
-- current, stale, cancelled, revoked and expired SYNTHETIC source, and privileges. HTTP evidence
-- through real GoTrue: tools/identity-e2e/source-contracts.mjs. Every account here is SYNTHETIC
-- (+44 7700 900830-900839).
begin;
select plan(80);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000320' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000320' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (830 + n)::text $$;
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
create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  select api.fixture_reminder_command(jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.create_due(n int, p_due timestamptz default now() - interval '1 minute')
returns uuid language sql as $$
  select (pg_temp.cmd(pg_temp.c(n), 'fixture.reminder_create', null,
                      jsonb_build_object('due_at', app.cmd_utc(p_due))) -> 'data' ->> 'source_id')::uuid
$$;
create function pg_temp.change(n int, p_source uuid, p_change text, p_expected bigint default 1)
returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'fixture.reminder_change', p_expected,
                     jsonb_build_object('source_id', p_source, 'change', p_change))
$$;
-- A read as the given claims: 'ok <json>' or 'sqlstate|message|detail'.
create function pg_temp.call(p_claims jsonb, p_sql text) returns text
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
    return 'ok ' || r::text;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
create function pg_temp.open(n int, p_item uuid) returns jsonb language sql as $$
  select substr(pg_temp.call(pg_temp.c(n), format('select api.notifications_open_item(%L::uuid)', p_item)), 4)::jsonb
$$;
create function pg_temp.items(n int) returns jsonb language sql as $$
  select substr(pg_temp.call(pg_temp.c(n), 'select api.notifications_my_inbox()'), 4)::jsonb -> 'items'
$$;
-- The item delivered for a source at a revision.
create function pg_temp.item(p_source uuid, p_revision bigint default 1) returns uuid language sql as $$
  select i.item_id from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id
   where j.source_id = p_source and j.source_revision = p_revision
$$;
-- Field errors of a direct owner-operation call (or 'ok').
create function pg_temp.errors(p_sql text) returns jsonb
language plpgsql as $$
declare
  v_detail text;
begin
  execute p_sql;
  return '"ok"'::jsonb;
exception when sqlstate 'PCMD1' then
  get stacked diagnostics v_detail = pg_exception_detail;
  return v_detail::jsonb -> 'field_errors';
end;
$$;
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
create function pg_temp.run() returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', pg_temp.token('Q'))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', 'notifications.deliver_due',
           'request_id', gen_random_uuid(), 'payload', '{}'::jsonb)) into r;
  reset role;
  return (r -> 'data') - 'actor'::text;
end;
$$;

insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 2) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 2) n;

-- Structure, privileges and guards -------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.contract_reminder_contracts', p)),
  'no client role has any privilege on the reminder contract registry');
select ok(not has_function_privilege('anon', 'api.notifications_open_item(uuid)', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.notifications_open_item(uuid)', 'EXECUTE'),
  'signed-out callers cannot open items; authenticated sessions can');
select ok(not exists (
  select 1 from unnest(array['app.contract_register_reminder_contract(text,text,text,regprocedure,jsonb)',
                             'app.contract_check_reminder(jsonb)', 'app.contract_reminder_text_errors(jsonb)',
                             'app.notifications_job_key(app.notifications_jobs)',
                             'app.fixture_reminder_open_check(jsonb)',
                             'app.fixture_reminder_change(uuid,bigint,jsonb)']) f
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where has_function_privilege(r, f, 'EXECUTE')),
  'registration, the reminder check and the fixture adapters are not client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select module || '|' || check_hook || '|' || title || '|' || body || '|' || link
             from app.contract_reminder_contracts
            where source_type = 'fixture_reminder' and reminder_kind = 'fixture_due'),
  'fixture|app.fixture_reminder_open_check(jsonb)|SYNTHETIC test reminder|A test reminder is waiting for you.|/fixture/reminders/{source_id}',
  'the SYNTHETIC source registers its reminder contract: check, generic text and link');

-- Registration refusals (PCTR1) ----------------------------------------------------------------
create function app.fixture_pgtap_check(p_key jsonb) returns jsonb
language sql stable set search_path = '' as
$$ select '{"current": true, "revision": 1, "actionable": true, "recipient_eligible": true}'::jsonb $$;
create function app.fixture_pgtap_bad_check(p_key jsonb) returns boolean
language sql stable set search_path = '' as $$ select true $$;
create function pg_temp.reg(p_kind text, p_text jsonb,
                            p_check regprocedure default 'app.fixture_pgtap_check(jsonb)',
                            p_module text default 'fixture') returns void
language sql as $$
  select app.contract_register_reminder_contract(p_module, 'fixture_reminder', p_kind, p_check, p_text)
$$;
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_pgtap_kind');
select throws_ok($$select pg_temp.reg('fixture_never_registered',
    '{"title": "Test", "body": "Test body.", "link": "/fixture/x"}')$$,
  'PCTR1', null, 'a reminder kind that is not registered cannot get a contract');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Test body.", "link": "/fixture/x"}', p_module => 'cells')$$,
  'PCTR1', null, 'only the module that owns the source type may register');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Test body.", "link": "/fixture/x"}', 'app.fixture_pgtap_bad_check(jsonb)')$$,
  'PCTR1', null, 'a check with the wrong return type is refused');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Test body.", "link": "/fixture/x"}', 'app.cells_erase_member(jsonb)')$$,
  'PCTR1', null, 'a check owned by another module is refused');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Hello {member_name}", "body": "Test body.", "link": "/fixture/x"}')$$,
  'PCTR1', null, 'a placeholder in the text is refused (text is fixed and generic)');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Call 0977 123 456 now.", "link": "/fixture/x"}')$$,
  'PCTR1', null, 'a phone-like number in the text is refused');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Write to a@b.example", "link": "/fixture/x"}')$$,
  'PCTR1', null, 'an address in the text is refused');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Test body.", "link": "/fixture/x", "member_phone": "x"}')$$,
  'PCTR1', null, 'a private field next to the text is refused');
select throws_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "Test", "body": "Test body.", "link": "https://example.org/x"}')$$,
  'PCTR1', null, 'a link with a scheme or host is refused');
select is(app.contract_reminder_text_errors(
    '{"title": " Padded", "body": "See https://x.example", "link": "/a/{source_id}/{source_id}?q=1", "note": "x"}'),
  '{"title": "out_of_range", "body": "not_generic", "link": "invalid", "note": "unknown_field"}'::jsonb,
  'the text checks name every refused field');
select is(app.contract_reminder_text_errors('[]'), '{"text": "must_be_object"}'::jsonb,
  'the text must be an object');
-- Review fix: the generic-text check cannot be bypassed with look-alike or split characters.
select is(app.contract_reminder_text_errors(jsonb_build_object('title', 'Test', 'body', t.v, 'link', '/x')) ->> 'body',
  'not_generic', 'generic text refuses ' || t.label)
  from (values
    ('full-width digits', 'Call ' || repeat(chr(65296 + 9), 7)),
    ('a full-width at sign', 'Write to a' || chr(65312) || 'b'),
    ('a full-width https', chr(65352) || chr(65364) || chr(65364) || chr(65360) || chr(65363) || '://x'),
    ('a zero-width space', 'Hello' || chr(8203) || 'there'),
    ('a bidi override', 'Hello ' || chr(8238) || 'there'),
    ('digits split by slashes', 'Call 0977/123/456 now'),
    ('digits split by commas', 'Call 0977,123,456 now'),
    ('digits split by underscores', 'Call 0977_123_456 now'),
    ('digits split by double spaces', 'Call 0977  123  456 now'),
    ('a bare domain', 'See example.com/x for more')) t (label, v);
select is(app.contract_reminder_text_errors(
    '{"title": "Duty response needed", "body": "Please accept or decline your duty by 10:00, e.g. today.", "link": "/duties/{source_id}"}'),
  '{}'::jsonb, 'ordinary generic text still passes');
select lives_ok($$select pg_temp.reg('fixture_pgtap_kind',
    '{"title": "First text", "body": "Test body.", "link": "/fixture/pgtap/{source_id}/detail"}')$$,
  'a valid contract registers');
select pg_temp.reg('fixture_pgtap_kind', '{"title": "Second text", "body": "Test body.", "link": "/fixture/pgtap"}');
select is((select count(*)::int || '|' || min(title) || '|' || min(link) from app.contract_reminder_contracts
            where reminder_kind = 'fixture_pgtap_kind'),
  '1|Second text|/fixture/pgtap', 'the owner re-registering replaces its contract');

-- Enqueue refusals -----------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 3.2');
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 3.2 Member ' || n, 'pgtap 3.2')
  from generate_series(1, 2) n;
insert into app.fixture_reminder_sources (source_id, member_id, due_at, created_by_account)
values ('00000000-0000-4000-a000-000000032000', (select member_id from m where n = 1), now(), pg_temp.u(1));
create function pg_temp.key(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('source_type', 'fixture_reminder',
    'source_id', '00000000-0000-4000-a000-000000032000', 'source_revision', 1,
    'recipient_member_id', (select member_id from m where n = 1), 'reminder_kind', 'fixture_due',
    'scheduled_at', app.cmd_utc(now())) || p_extra
$$;
select is(pg_temp.errors(format('select app.notifications_enqueue(%L)',
            pg_temp.key('{"source_type": "fixture_never_registered"}'))),
  '{"source_type": "unregistered"}'::jsonb, 'an unregistered source type is refused');
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_no_contract');
select is(pg_temp.errors(format('select app.notifications_enqueue(%L)',
            pg_temp.key('{"reminder_kind": "fixture_no_contract"}'))),
  '{"reminder_kind": "unregistered"}'::jsonb, 'a registered kind without a reminder contract is refused');
select is(pg_temp.errors(format('select app.notifications_enqueue(%L)',
            pg_temp.key('{"reminder_kind": "fixture_never_registered"}'))),
  '{"reminder_kind": "unregistered"}'::jsonb, 'an unregistered kind is refused');
select is(pg_temp.errors(format('select app.notifications_enqueue(%L)',
            pg_temp.key('{"body": "Pastoral note", "recipient_phone": "+447700900830"}'))),
  '{"body": "unknown_field", "recipient_phone": "unknown_field"}'::jsonb,
  'a key carrying private fields is rejected');
select is((select count(*)::int from app.notifications_jobs), 0, 'none of the refused keys wrote a job');
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_create', null,
            jsonb_build_object('due_at', app.cmd_utc(now()), 'reminder_kind', 'fixture_never_registered'))
            -> 'field_errors',
  '{"reminder_kind": "unregistered"}'::jsonb, 'through the API, an unregistered kind is refused');
select is((select count(*)::int from app.fixture_reminder_sources), 1,
  'and the refused command wrote no source (it rolled back with the enqueue)');

-- The reminder check answer is strict ----------------------------------------------------------
create function app.fixture_pgtap_leaky(p_key jsonb) returns jsonb
language plpgsql stable set search_path = '' as $$
begin
  return case current_setting('pgtap.leak', true)
    when 'extra' then '{"current": true, "revision": 1, "actionable": true, "recipient_eligible": true, "note": "private"}'
    when 'revision' then '{"current": true, "revision": 2, "actionable": true, "recipient_eligible": true}'
    when 'type' then '{"current": true, "revision": 1, "actionable": "yes", "recipient_eligible": true}'
    else '{"current": true, "actionable": true, "recipient_eligible": true}' end::jsonb;
end;
$$;
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_pgtap_leaky');
select pg_temp.reg('fixture_pgtap_leaky', '{"title": "Leaky", "body": "Leaky test.", "link": "/fixture/leaky"}',
                   'app.fixture_pgtap_leaky(jsonb)');
select set_config('pgtap.leak', 'extra', true);
select throws_ok(format('select app.contract_check_reminder(%L)', pg_temp.key('{"reminder_kind": "fixture_pgtap_leaky"}')),
  'PCTR1', null, 'a check answer with an extra (private) field is refused');
select set_config('pgtap.leak', 'revision', true);
select throws_ok(format('select app.contract_check_reminder(%L)', pg_temp.key('{"reminder_kind": "fixture_pgtap_leaky"}')),
  'PCTR1', null, 'a check that calls another revision current is refused');
select set_config('pgtap.leak', 'type', true);
select throws_ok(format('select app.contract_check_reminder(%L)', pg_temp.key('{"reminder_kind": "fixture_pgtap_leaky"}')),
  'PCTR1', null, 'a check answer with a wrong type is refused');
select set_config('pgtap.leak', 'missing', true);
select throws_ok(format('select app.contract_check_reminder(%L)', pg_temp.key('{"reminder_kind": "fixture_pgtap_leaky"}')),
  'PCTR1', null, 'a check answer without the revision is refused');
select is(app.contract_check_reminder(pg_temp.key()),
  '{"current": true, "revision": 1, "actionable": true, "recipient_eligible": true}'::jsonb,
  'the SYNTHETIC check answers the four facts');

-- Worker credential ---------------------------------------------------------------------------
create temp table t_ids (k text primary key, v uuid);
insert into t_ids values ('worker', app.sys_create_principal('pgtap-notifications-worker-32', 'notifications_worker', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'worker'),
  encode(sha256(convert_to(pg_temp.token('Q'), 'UTF8')), 'hex'), 'pgtap 3.2', interval '1 hour', 'israel');

-- Five SYNTHETIC adapters, delivered, then changed --------------------------------------------
create temp table src (k text primary key, v uuid);
insert into src select k, pg_temp.create_due(1)
  from unnest(array['current', 'stale', 'cancelled', 'revoked', 'expired']) k;
select is(pg_temp.run(), '{"claimed": 5, "delivered": 5, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'the five reminders are delivered while their sources are current');
select is((select string_agg(x ->> 'title', ',') from jsonb_array_elements(pg_temp.items(1)) x),
  'SYNTHETIC test reminder,SYNTHETIC test reminder,SYNTHETIC test reminder,SYNTHETIC test reminder,SYNTHETIC test reminder',
  'the inbox shows the registered generic title');
select is((pg_temp.items(1) -> 0 ->> 'body'), 'A test reminder is waiting for you.',
  'and the registered generic body');

select is(pg_temp.change(1, (select v from src where k = 'stale'), 'revise') -> 'data' ->> 'job_state',
  'pending', 'revise: a new revision and a job at that revision');
select is((pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_cancel', 1,
            jsonb_build_object('source_id', (select v from src where k = 'cancelled'))) ->> 'revision'),
  '2', 'cancel: the source is cancelled');
select is(pg_temp.change(1, (select v from src where k = 'revoked'), 'revoke') -> 'data' ->> 'recipient_revoked',
  'true', 'revoke: the recipient''s SYNTHETIC scope is revoked (revision kept)');
select is(pg_temp.change(1, (select v from src where k = 'expired'), 'expire') ->> 'revision',
  '1', 'expire: the source expires now (revision kept)');

select is(pg_temp.open(1, pg_temp.item((select v from src where k = 'current'))),
  (select jsonb_build_object('item_id', i.item_id, 'reminder_kind', 'fixture_due',
            'title', 'SYNTHETIC test reminder', 'body', 'A test reminder is waiting for you.',
            'due_at', app.cmd_utc(i.due_at), 'delivered_at', app.cmd_utc(i.delivered_at),
            'state', 'current', 'target', '/fixture/reminders/' || (select v from src where k = 'current'),
            -- Story 3.7: a current item also offers the policy's snooze choices.
            'snooze_choices', '["1 hour", "24 hours", "2 days"]'::jsonb, 'snoozed_until', null)
     from app.notifications_inbox_items i where i.item_id = pg_temp.item((select v from src where k = 'current'))),
  'a current item opens with its generic text and the authorised target');
select is(pg_temp.open(1, pg_temp.item((select v from src where k = k2))) ->> 'state', 'superseded',
  'a ' || k2 || ' source opens as superseded')
  from unnest(array['stale', 'cancelled', 'revoked', 'expired']) k2;
select is((select count(*)::int from unnest(array['stale', 'cancelled', 'revoked', 'expired']) k2
            where pg_temp.open(1, pg_temp.item((select v from src where k = k2))) ->> 'target' is null
              and position((select v from src where k = k2)::text
                           in pg_temp.open(1, pg_temp.item((select v from src where k = k2)))::text) = 0
              and (select array_agg(x order by x) from jsonb_object_keys(
                     pg_temp.open(1, pg_temp.item((select v from src where k = k2)))) x)
                  = array['body', 'delivered_at', 'due_at', 'item_id', 'reminder_kind', 'state', 'target', 'title']),
  4, 'a superseded item carries no target, no source id and nothing beyond the generic fields');
select is(pg_temp.run(), '{"claimed": 1, "delivered": 1, "obsolete": 0, "ineligible": 0, "failed": 0}'::jsonb,
  'the revised source''s new job is delivered');
select is(pg_temp.open(1, pg_temp.item((select v from src where k = 'stale'), 2)) ->> 'state', 'current',
  'the item of the new revision opens as current');

-- The worker rechecks through the contract ------------------------------------------------------
insert into src values ('w_revoked', pg_temp.create_due(1)), ('w_expired', pg_temp.create_due(1));
update app.fixture_reminder_sources set recipient_revoked = true where source_id = (select v from src where k = 'w_revoked');
update app.fixture_reminder_sources set expires_at = now() - interval '1 second'
 where source_id = (select v from src where k = 'w_expired');
select is(pg_temp.run(), '{"claimed": 2, "delivered": 0, "obsolete": 1, "ineligible": 1, "failed": 0}'::jsonb,
  'the worker ends an expired source obsolete and a revoked recipient ineligible, with no item');

-- Changes cancel pending work -----------------------------------------------------------------
insert into src values ('future', pg_temp.create_due(1, now() + interval '1 day'));
select is(pg_temp.change(1, (select v from src where k = 'future'), 'revoke') -> 'data' ->> 'cancelled_jobs', '1',
  'revoking cancels the pending job');
select is((select string_agg(job_state || ':' || cancel_reason, ',') from app.notifications_jobs
            where source_id = (select v from src where k = 'future')),
  'cancelled:scope_revoked', 'with its reason');

-- Who may open what ---------------------------------------------------------------------------
select is(pg_temp.open(2, pg_temp.item((select v from src where k = 'current'))), '{"state": "not_found"}'::jsonb,
  'another member opening the item learns nothing');
select is(pg_temp.open(1, gen_random_uuid()), '{"state": "not_found"}'::jsonb, 'an unknown id is not found');
select is(pg_temp.call('{"role": "authenticated"}'::jsonb,
            format('select api.notifications_open_item(%L::uuid)', pg_temp.item((select v from src where k = 'current')))),
  'PT401|unauthenticated|unauthenticated', 'a session without a subject is refused by the live-access predicate');
select is(split_part(pg_temp.call(pg_temp.c(1), 'select api.notifications_open_item(null)'), '|', 1), '22023',
  'an item id is required');

-- Review fix: a raising or malformed owner check never reaches the member ------------------------
create function app.fixture_pgtap_raising(p_key jsonb) returns jsonb
language plpgsql stable set search_path = '' as $$
begin
  raise exception 'secret source value 0977123456 in app.fixture_pgtap_raising';
end;
$$;
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_pgtap_raising');
select pg_temp.reg('fixture_pgtap_raising', '{"title": "Raising", "body": "Raising test.", "link": "/fixture/raising"}',
                   'app.fixture_pgtap_raising(jsonb)');
create function pg_temp.delivered_item(p_kind text) returns uuid
language plpgsql as $$
declare
  v_job uuid;
  v_item uuid;
begin
  insert into app.notifications_jobs (source_type, source_id, source_revision, recipient_member_id, reminder_kind,
                                      scheduled_at, policy_source, policy_digest, job_state, finished_at,
                                      processed_by_principal)
  values ('fixture_reminder', '00000000-0000-4000-a000-000000032000', 1, (select member_id from m where n = 1),
          p_kind, now() - interval '1 minute', 'fixture', repeat('0', 64), 'delivered', now(),
          (select v from t_ids where k = 'worker'))
  returning job_id into v_job;
  insert into app.notifications_inbox_items (job_id, recipient_member_id, reminder_kind, due_at, delivered_by_principal)
  values (v_job, (select member_id from m where n = 1), p_kind, now() - interval '1 minute', (select v from t_ids where k = 'worker'))
  returning item_id into v_item;
  return v_item;
end;
$$;
select is(pg_temp.call(pg_temp.c(1), format('select api.notifications_open_item(%L::uuid)',
            pg_temp.delivered_item('fixture_pgtap_raising'))),
  'PT503|source_check_failed|', 'a raising check answers a fixed, content-free 503 (no error text, no hook name)');
select set_config('pgtap.leak', 'extra', true);
select is(pg_temp.call(pg_temp.c(1), format('select api.notifications_open_item(%L::uuid)',
            pg_temp.delivered_item('fixture_pgtap_leaky'))),
  'PT503|source_check_failed|', 'a malformed check answer is the same fixed 503');
select throws_ok(format('select app.contract_check_reminder(%L)', pg_temp.key('{"reminder_kind": "fixture_pgtap_leaky"}')),
  'PCTR1', 'reminder check returned a malformed result', 'the PCTR1 message names no hook');

-- Review fix: a due job whose kind has no reminder contract ends obsolete, never retried ---------
insert into app.notifications_jobs (source_type, source_id, source_revision, recipient_member_id, reminder_kind,
                                    scheduled_at, policy_source, policy_digest)
values ('fixture_reminder', '00000000-0000-4000-a000-000000032000', 1, (select member_id from m where n = 1),
        'fixture_no_contract', now() - interval '1 minute', 'fixture', repeat('0', 64));
select is(pg_temp.run(), '{"claimed": 1, "delivered": 0, "obsolete": 1, "ineligible": 0, "failed": 0}'::jsonb,
  'a job without a reminder contract ends obsolete at once');
select is((select job_state || '|' || failed_attempts from app.notifications_jobs where reminder_kind = 'fixture_no_contract'),
  'obsolete|0', 'with no failure recorded and no retry');

-- fixture.reminder_change refusals --------------------------------------------------------------
insert into src values ('refusals', pg_temp.create_due(1, now() + interval '1 day'));
select is(pg_temp.change(1, (select v from src where k = 'refusals'), 'delete') -> 'field_errors',
  '{"change": "invalid"}'::jsonb, 'an unknown change is refused');
select is(pg_temp.cmd(pg_temp.c(1), 'fixture.reminder_change', 1,
            jsonb_build_object('source_id', (select v from src where k = 'refusals'), 'change', 'revise',
                               'note', 'x')) -> 'field_errors',
  '{"note": "unknown_field"}'::jsonb, 'the change payload is strict');
select is(pg_temp.change(1, (select v from src where k = 'refusals'), 'revise', 2) ->> 'code', 'conflict',
  'a stale expected revision is a conflict');
select is(pg_temp.change(2, (select v from src where k = 'refusals'), 'revise') ->> 'code', 'not_found',
  'another member cannot change it');
select is(pg_temp.change(1, (select v from src where k = 'cancelled'), 'revise', 2) -> 'field_errors',
  '{"source_id": "cancelled"}'::jsonb, 'a cancelled source cannot be changed');
select is(pg_temp.change(1, (select v from src where k = 'refusals'), 'revise') ->> 'revision', '2',
  'the owner can revise its own active source');


-- Review fix: fixture.reminder_change refuses non-SYNTHETIC members and production --------------
update app.identity_members set is_synthetic = false where member_id = (select member_id from m where n = 2);
select is(pg_temp.change(2, (select v from src where k = 'refusals'), 'revise', 2) ->> 'code', 'forbidden',
  'a member who is not SYNTHETIC cannot change fixture reminders (refused by the live-access gate here)');
select app.policy_approve('private_access', '{"serve": true}', 'pgtap', 'pgtap 3.2 only, rolled back');
select is(pg_temp.change(2, (select v from src where k = 'refusals'), 'revise', 2) -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'the fixture handler itself refuses a member who is not SYNTHETIC');
create temp table before_prod as select revision from app.fixture_reminder_sources
 where source_id = (select v from src where k = 'refusals');
select app.platform_set_environment('production', 'pgtap 3.2');
update app.policy_gates set state = 'unresolved', approved_value = null, approved_by = null,
       approved_at = null, approval_note = null
 where gate = 'private_access';
select is(pg_temp.change(1, (select v from src where k = 'refusals'), 'revise', 2) ->> 'code', 'forbidden',
  'production: fixture.reminder_change is refused');
select is((select revision from app.fixture_reminder_sources where source_id = (select v from src where k = 'refusals')),
  (select revision from before_prod), 'production: the source is unchanged');

select * from finish();
rollback;
