-- Story 6.3: verified giving methods. Registries, privileges and the payer-field scan; the seven
-- giving commands for Admin only (refused for Media, Pastor, a plain member and a Pending account);
-- type-specific validation with amount and payer keys refused; the second-Admin verification
-- (owner decision 2026-10-21) in the command and in the database (check and trigger); publication
-- through the q3_giving gate (SAMPLE fixture locally, closed in a simulated production); a changed
-- destination refused until verified again while the old revision stays live; hide, archive and
-- the order; the anonymous projection; the Admins' read; replay; the deletion erase part. Every
-- account, phone and name is SYNTHETIC or SAMPLE (fictional range +1 202 555 0181-0187).
begin;
select plan(183);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000083' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000083' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (80 + n)::text $$;
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
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  r := api.content_command(jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', p_request,
    'expected_revision', p_expected, 'payload', p_payload));
  reset role;
  return r;
end;
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- A read as account n (or anon when n is null): its JSON, or 'SQLSTATE|message|detail'.
create function pg_temp.read(n int, p_sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  if n is null then
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
    set local role authenticated;
  end if;
  begin
    execute p_sql into r;
    reset role;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return to_jsonb(v_state || '|' || v_msg || '|' || coalesce(v_detail, ''));
  end;
end;
$$;
-- Runs p_sql (answering text) in a database marked production with member data served (the
-- private_access gate and the dormancy setting approved, q3_giving left closed), then undoes
-- everything.
create function pg_temp.in_production(p_sql text) returns text
language plpgsql as $$
declare
  r text;
begin
  begin
    perform app.platform_set_environment('production', 'pgtap content giving');
    perform app.policy_approve('private_access', '{}'::jsonb, 'pgtap', 'pgtap 6.3 production check');
    insert into app.identity_settings (setting, version, value, source, label, set_by)
    values ('dormancy_days', 99, '{"days": 90}', 'approved', 'pgtap 6.3 production check', 'pgtap');
    execute p_sql into r;
    raise exception using errcode = 'P0099', message = coalesce(r, '<null>');
  exception when sqlstate 'P0099' then
    return sqlerrm;
  end;
end;
$$;
create function pg_temp.today() returns date language sql as $$ select app.content_church_today() $$;
create function pg_temp.steps() returns jsonb language sql as $$
  select jsonb_build_array('Dial the starting code on your SAMPLE line.', 'Choose Pay merchant.',
                           'Enter the merchant ID shown above.')
$$;
create function pg_temp.mm(p_name text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'method_type', 'mobile_money', 'name', p_name, 'purpose', 'Tithes and offerings', 'currency', 'ZMW',
    'beneficiary', 'SAMPLE Brethren in Christ Church Kafue', 'identifier_kind', 'merchant',
    'identifier', '990101', 'ussd_code', '*990#', 'steps', pg_temp.steps(),
    'note', 'SAMPLE support note.', 'contact', 'SAMPLE church office, +260 97 000 0099') || p_extra
$$;
create function pg_temp.bank(p_name text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'method_type', 'bank', 'name', p_name, 'purpose', 'Building project', 'currency', 'ZMW',
    'bank_name', 'SAMPLE Bank of Testing', 'beneficiary', 'SAMPLE BICC Kafue',
    'account_number', '9900 1111 2222', 'branch', 'SAMPLE Kafue branch', 'branch_code', '990001',
    'swift_code', 'SMPLZMLU', 'reference', 'Your name and GIVING',
    'steps', jsonb_build_array('Open your banking app.', 'Pay the account shown above.'),
    'note', null, 'contact', 'SAMPLE church office, +260 97 000 0099') || p_extra
$$;
-- A save payload from a create payload.
create function pg_temp.sv(p_id uuid, p jsonb) returns jsonb language sql as $$
  select (p - 'method_type') || jsonb_build_object('method_id', p_id)
$$;
create function pg_temp.vf(p_id uuid, p_days int default 0) returns jsonb language sql as $$
  select jsonb_build_object('method_id', p_id, 'tested_on', to_char(pg_temp.today() - p_days, 'YYYY-MM-DD'),
                            'test_method', 'SAMPLE test: the treasurer''s provider showed the church name for these details.')
$$;
create function pg_temp.idp(p uuid) returns jsonb language sql as $$ select jsonb_build_object('method_id', p) $$;
create function pg_temp.rev(p uuid) returns bigint language sql as $$
  select revision from app.content_items where item_id = p $$;

-- Accounts: 1 Admin A; 2 Admin B; 3 Media; 4 Pastor; 5 plain member; 6 Pending (no member link);
-- 7 Admin C (erased at the end).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.platform_set_environment('local', 'pgtap content giving');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Giving Member ' || n,
                                                         'pgtap content giving')
  from generate_series(1, 7) n where n <> 6;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'admin', 'israel'), (pg_temp.mid(3), 'media', 'israel'),
       (pg_temp.mid(4), 'pastor', 'israel'), (pg_temp.mid(7), 'admin', 'israel');
update app.identity_grants set granted_at = now() - interval '14 days'
 where member_id in (pg_temp.mid(1), pg_temp.mid(2)) and role = 'admin' and revoked_at is null;

-- Structure, registries and privileges ----------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['content_giving_methods', 'content_giving_revisions', 'content_giving_audit']) t;
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relkind = 'r' and c.relname like 'content\_giving%'),
  'RLS is enabled on every giving table');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relkind in ('r', 'S') and c.relname like 'content\_giving%'
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'))),
  0, 'no client role has any privilege on a giving table or sequence');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%giving%'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_public_giving_method'::text collate "C"), ('api.content_public_giving_methods'),
           ('app.content_public_giving_method'), ('app.content_public_giving_methods')$$,
  'anon can execute only the two public giving reads');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%giving%'
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_public_giving_method'::text collate "C"), ('api.content_public_giving_methods'),
           ('api.content_staff_giving_methods'), ('app.content_public_giving_method'),
           ('app.content_public_giving_methods'), ('app.content_staff_giving_methods')$$,
  'authenticated can execute only the giving reads (commands go through api.content_command)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api') and p.proname like 'content\_%giving%'
              and has_function_privilege('service_role', p.oid, 'EXECUTE')), 0,
  'service_role executes no giving function');
select is_definer('app', 'content_public_giving_methods', array[]::text[], 'the public read body is a definer');
select isnt_definer('api', 'content_public_giving_methods', array[]::text[], 'the public api wrapper is invoker');
select results_eq($$select editor_roles from app.content_kinds where kind = 'giving_method'$$,
  $$values (array['admin']::text[])$$, 'giving methods are edited by Admin only');
select results_eq(
  $$select command || ':' || handler || ':' || creates from app.content_commands
     where kind = 'giving_method' order by 1$$,
  $$values ('content.archive_giving_method:app.content_giving_archive(uuid,bigint,jsonb):false'::text),
           ('content.create_giving_method:app.content_giving_create(uuid,bigint,jsonb):true'),
           ('content.discard_giving_draft:app.content_giving_discard(uuid,bigint,jsonb):false'),
           ('content.hide_giving_method:app.content_giving_hide(uuid,bigint,jsonb):false'),
           ('content.move_giving_method:app.content_giving_move(uuid,bigint,jsonb):false'),
           ('content.publish_giving_method:app.content_giving_publish(uuid,bigint,jsonb):false'),
           ('content.save_giving_method:app.content_giving_save(uuid,bigint,jsonb):false'),
           ('content.verify_giving_method:app.content_giving_verify(uuid,bigint,jsonb):false')$$,
  'the eight giving commands are registered');
select is((select handler from app.content_erase_parts where part = 'giving_methods'),
  'app.content_giving_erase_part(jsonb)', 'the giving erase part is registered');
select is((select handler from app.identity_deletion_hooks where module = 'content'),
  'app.content_erase_member(jsonb)', 'Content keeps its one deletion hook');
select results_eq(
  $$select state, decision_ref, fixture_value ->> 'sample_only', fixture_value ? 'fixture_label'
      from app.policy_gates where gate = 'q3_giving'$$,
  $$values ('unresolved'::text, 'Q3'::text, 'true'::text, true)$$,
  'q3_giving is unresolved with a labelled SAMPLE-only fixture');
select is(
  (select string_agg(c.table_name || '.' || c.column_name, ', ')
     from information_schema.columns c
    where c.table_schema = 'app' and c.table_name like 'content\_giving%'
      and c.column_name ~ '(amount|payer|donor|proof|transaction|gift|receipt|sender|payment)'),
  null, 'no giving table has an amount, payer, donor, proof, transaction, gift, receipt or sender column');
select results_eq(
  $$select column_name::text collate "C" from information_schema.columns
     where table_schema = 'app' and table_name = 'content_giving_audit' order by 1$$,
  $$values ('action'::text collate "C"), ('actor_account_id'), ('actor_member_id'), ('changed_fields'),
           ('command_request_id'), ('environment'), ('event_id'), ('item_id'), ('occurred_at'), ('position'),
           ('revision_after'), ('revision_no')$$,
  'the giving audit row holds ids, codes, changed field names, positions and revisions only');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'every giving object has an owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function pins search_path');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Create: who may, and what is refused -----------------------------------------------------------
create temp table c1 as select pg_temp.cmd(1, 'content.create_giving_method', null,
  pg_temp.mm('SAMPLE Mobile Money')) as r;
create function pg_temp.mm1() returns uuid language sql as $$ select (r #>> '{data,method_id}')::uuid from c1 $$;
select is((select (r -> 'data') - 'method_id' from c1),
  '{"state": "draft", "revision": 1, "live_revision_no": null, "draft_revision_no": 1}'::jsonb,
  'Admin A creates a private draft (revision 1, draft revision 1)');
create temp table c2 as select pg_temp.cmd(1, 'content.create_giving_method', null,
  pg_temp.bank('SAMPLE Bank transfer')) as r;
create function pg_temp.bk1() returns uuid language sql as $$ select (r #>> '{data,method_id}')::uuid from c2 $$;
select is(pg_temp.err((select r from c2)), 'ok', 'Admin A creates a bank method');
create temp table c3 as select pg_temp.cmd(2, 'content.create_giving_method', null, jsonb_build_object(
  'method_type', 'other', 'name', 'SAMPLE At church', 'purpose', 'Offering during the service',
  'currency', null, 'steps', jsonb_build_array('Bring your gift to the Sunday service.'), 'note', null,
  'contact', 'SAMPLE church office, +260 97 000 0099')) as r;
create function pg_temp.ot1() returns uuid language sql as $$ select (r #>> '{data,method_id}')::uuid from c3 $$;
select is(pg_temp.err((select r from c3)), 'ok', 'Admin B creates an instruction-only method');
select results_eq(
  $$select g.sort_order from app.content_giving_methods g
     where g.item_id in (pg_temp.mm1(), pg_temp.bk1(), pg_temp.ot1()) order by g.sort_order$$,
  $$values (1), (2), (3)$$, 'each new method goes last in the order');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_giving_method', null, pg_temp.mm('SAMPLE By Media'))),
  'forbidden', 'Media cannot create a giving method');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_giving_method', null, pg_temp.mm('SAMPLE By Pastor'))),
  'forbidden', 'a Pastor cannot create a giving method');
select is(pg_temp.err(pg_temp.cmd(5, 'content.create_giving_method', null, pg_temp.mm('SAMPLE By member'))),
  'forbidden', 'a plain member cannot create a giving method');
select is(pg_temp.err(pg_temp.cmd(6, 'content.create_giving_method', null, pg_temp.mm('SAMPLE By Pending'))),
  'forbidden', 'a Pending account cannot create a giving method');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null, jsonb_build_object(
    'title', 'SYNTHETIC Media event', 'description', 'SYNTHETIC', 'location', 'SYNTHETIC hall',
    'starts_at', to_char((now() + interval '3 days') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'ends_at', to_char((now() + interval '3 days 2 hours') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))),
  'ok', 'Media still edits events (the authorizer reads each command''s kind)');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null,
    pg_temp.mm('SAMPLE Amount', '{"amount": "50.00", "payer_phone": "+447700900510"}'))),
  'validation_failed|amount=unknown_field,payer_phone=unknown_field',
  'an amount or payer field is refused');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null,
    pg_temp.mm('SAMPLE Mixed', '{"account_number": "12345678"}'))),
  'validation_failed|account_number=unknown_field', 'a bank field is unknown on a mobile money method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null,
    pg_temp.bank('SAMPLE Mixed bank', '{"ussd_code": "*990#"}'))),
  'validation_failed|ussd_code=unknown_field', 'a USSD code is unknown on a bank method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, '{"method_type": "mobile_money"}')),
  'validation_failed|beneficiary=required,contact=required,identifier=required,identifier_kind=required,name=required,steps=required',
  'the required fields of a mobile money method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, '{"method_type": "bank"}')),
  'validation_failed|account_number=required,bank_name=required,beneficiary=required,contact=required,name=required,steps=required',
  'the required fields of a bank method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, '{"name": "SAMPLE x"}')),
  'validation_failed|method_type=required', 'the type is required');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, '{"method_type": "card"}')),
  'validation_failed|method_type=invalid', 'only mobile money, bank and other exist');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.mm('SAMPLE Bad', jsonb_build_object(
    'currency', 'Z1W', 'ussd_code', '990', 'identifier_kind', 'iban', 'identifier', '99/01')))),
  'validation_failed|currency=invalid,identifier=invalid,identifier_kind=invalid,ussd_code=invalid',
  'bad currency, USSD code, identifier kind and identifier are refused');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.bank('SAMPLE Bad bank', jsonb_build_object(
    'swift_code', 'NOTASWIFT', 'account_number', '12', 'branch_code', '#1')))),
  'validation_failed|account_number=invalid,branch_code=invalid,swift_code=invalid',
  'bad SWIFT code, short account number and bad branch code are refused');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.mm('SAMPLE Steps',
    jsonb_build_object('steps', (select jsonb_agg('Step ' || n) from generate_series(1, 13) n))))),
  'validation_failed|steps=too_many', 'at most twelve steps');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.mm('SAMPLE Steps',
    jsonb_build_object('steps', jsonb_build_array('Dial.', ' '))))),
  'validation_failed|steps=invalid', 'a blank step is refused');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.mm('SAMPLE Steps',
    jsonb_build_object('steps', 'Dial the code.')))),
  'validation_failed|steps=invalid', 'steps are a list');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_giving_method', null, pg_temp.mm(repeat('S', 61)))),
  'validation_failed|name=too_long', 'a name is at most 60 characters');
create temp table c4 as select pg_temp.cmd(1, 'content.create_giving_method', null,
  pg_temp.mm('SAMPLE Till money', '{"currency": "zmw", "identifier_kind": "till", "identifier": "+260 990 0101"}')) as r;
select results_eq(
  $$select r.currency, r.identifier from app.content_giving_revisions r
     where r.item_id = (select (r #>> '{data,method_id}')::uuid from c4)$$,
  $$values ('ZMW'::text, '+260 990 0101'::text)$$, 'a currency is upper-cased; an identifier keeps its spaces');
select is((select count(*)::int from app.content_items where kind = 'giving_method'), 4,
  'refused creates wrote nothing');
select is(pg_temp.read(null, 'select api.content_public_giving_methods()'),
  '{"sample": true, "methods": [], "truncated": false}'::jsonb, 'anon reads no draft');
select is(pg_temp.read(null, format('select api.content_public_giving_method(%L)', pg_temp.mm1())),
  '{"sample": true, "method": null}'::jsonb, 'anon reads no draft by id either');

-- Verification by a second Admin ---------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.idp(pg_temp.mm1()))),
  'validation_failed|method_id=not_verified', 'an unverified draft cannot be published');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1()))),
  'validation_failed|method_id=saved_by_you', 'Admin A cannot verify the method Admin A saved');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1(), -1))),
  'validation_failed|tested_on=out_of_range', 'a tested date in the future is refused');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1(), 91))),
  'validation_failed|tested_on=out_of_range', 'a test more than 90 days ago is refused');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()),
    jsonb_build_object('method_id', pg_temp.mm1(), 'tested_on', '2026-02-30'))),
  'validation_failed|test_method=required,tested_on=invalid', 'an impossible date and a missing how are refused');
select is(pg_temp.err(pg_temp.cmd(3, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1()))),
  'forbidden', 'Media cannot verify');
select is(pg_temp.err(pg_temp.cmd(4, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1()))),
  'forbidden', 'a Pastor cannot verify');
select throws_ok(
  format($$update app.content_giving_revisions set verified_at = now(), verified_by_member = %L,
           verified_by_account = %L, tested_on = current_date, test_method = 'x'
          where item_id = %L$$, pg_temp.mid(1), pg_temp.u(1), pg_temp.mm1()),
  'PCNT1', 'an Admin who saved a giving revision cannot verify it',
  'the database refuses a verification by one of the revision''s savers');
select throws_ok(
  format($$update app.content_giving_revisions set verified_at = now(), verified_by_member = %L,
           verified_by_account = %L, tested_on = current_date, test_method = 'x', identifier = '990199'
          where item_id = %L$$, pg_temp.mid(2), pg_temp.u(2), pg_temp.mm1()),
  'PCNT1', 'a giving revision is verified as it was saved, in an update of its own',
  'the database refuses a verification recorded together with a change');
select throws_ok(
  format($$update app.content_giving_revisions set verified_at = now(), verified_by_member = %L,
           verified_by_account = %L, tested_on = current_date, test_method = 'x',
           saved_by_members = array[%L]::uuid[], saved_by_member = %L
          where item_id = %L$$, pg_temp.mid(2), pg_temp.u(2), pg_temp.mid(3), pg_temp.mid(3), pg_temp.mm1()),
  'PCNT1', 'a giving revision is verified as it was saved, in an update of its own',
  'nor one that rewrites the savers to slip past the rule');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1(), 1))),
  'validation_failed|tested_on=before_saved', 'a test before the day the details were saved is refused');
select throws_ok(
  format($$update app.content_giving_revisions set published_at = now(), published_by_member = %L,
           published_by_account = %L where item_id = %L$$, pg_temp.mid(1), pg_temp.u(1), pg_temp.mm1()),
  '23514', null, 'the database refuses a published revision that is not verified');
select is(pg_temp.err(pg_temp.cmd(7, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()),
  pg_temp.vf(pg_temp.mm1()))), 'validation_failed|admin_tenure=not_eligible',
  'a recently granted Admin cannot verify');
select is(pg_temp.rev(pg_temp.mm1()), 1::bigint, 'a tenure refusal leaves the revision unchanged');
select ok(not app.content_giving_admin_tenure_eligible(null),
  'missing Identity self-read metadata fails closed');
select ok(app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', to_char((now() - interval '15 days') at time zone 'Africa/Lusaka', 'YYYY-MM-DD'),
    'granted_by', 'SAMPLE grantor')),
  'well-formed old Admin context is eligible');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', 20261007,
    'granted_by', 'SAMPLE grantor')),
  'a non-string Lusaka display date fails closed');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', '2026-02-30',
    'granted_by', 'SAMPLE grantor')),
  'an impossible Lusaka display date fails closed');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', to_char((now() - interval '15 days') at time zone 'Africa/Lusaka', 'YYYY-MM-DD'),
    'granted_by', 17)),
  'a non-string grantor fails closed');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', to_char((now() - interval '15 days') at time zone 'Africa/Lusaka', 'YYYY-MM-DD'),
    'granted_by', '   ')),
  'a blank grantor fails closed');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', app.cmd_utc(now() - interval '15 days'),
    'admin_since', to_char((now() - interval '14 days') at time zone 'Africa/Lusaka', 'YYYY-MM-DD'),
    'granted_by', 'SAMPLE grantor')),
  'a Lusaka display date inconsistent with the grant timestamp fails closed');
select ok(not app.content_giving_admin_tenure_eligible(jsonb_build_object(
    'granted_at', 'not-a-timestamp', 'admin_since', '2026-10-07', 'granted_by', 'SAMPLE grantor')),
  'an invalid grant timestamp fails closed');
create or replace function api.identity_my_access()
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select '{}'::jsonb $$;
create temp table v_missing_context as
  select pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()),
                     pg_temp.vf(pg_temp.mm1())) as r;
create or replace function api.identity_my_access()
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select app.identity_my_access() $$;
select is(pg_temp.err((select r from v_missing_context)), 'validation_failed|admin_tenure=not_eligible',
  'missing Identity self-read context is refused by the verification command');
select is(pg_temp.rev(pg_temp.mm1()), 1::bigint,
  'missing Identity self-read context leaves the method revision unchanged');
create temp table v1 as select pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()),
  pg_temp.vf(pg_temp.mm1())) as r;
select is(pg_temp.err((select r from v1)), 'ok',
  'Admin B verifies Admin A''s method at the exact 14-day boundary');
select is((select (r #>> '{data,revision}')::int from v1), 2, 'verification moves the method''s revision on');
select results_eq(
  $$select r.verified_by_member, r.tested_on, r.verified_at is not null from app.content_giving_revisions r
     where r.item_id = pg_temp.mm1() and r.revision_no = 1$$,
  $$values (pg_temp.mid(2), pg_temp.today(), true)$$, 'the verifier, tested date and time are recorded');
select is((select count(*)::int from app.content_giving_audit a
            where a.item_id = pg_temp.mm1() and a.action = 'verified' and a.actor_member_id = pg_temp.mid(2)
              and a.revision_no = 1), 1, 'the verification is audited');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1()))),
  'validation_failed|method_id=already_verified', 'a verified draft is not verified twice');
select throws_ok(
  format($$update app.content_giving_revisions set account_number = null, identifier = '990199'
          where item_id = %L$$, pg_temp.mm1()),
  'PCNT1', null, 'the database refuses a change of a verified draft that keeps its verification');

-- Publication ----------------------------------------------------------------------------------------
create temp table p1 as select pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.mm1()),
  pg_temp.idp(pg_temp.mm1())) as r;
select is((select (r -> 'data') - 'method_id' from p1),
  '{"state": "published", "revision": 3, "live_revision_no": 1, "draft_revision_no": null}'::jsonb,
  'Admin A publishes the method Admin B verified');
select is((select published_by_member from app.content_giving_revisions where item_id = pg_temp.mm1() and revision_no = 1),
  pg_temp.mid(1), 'the revision records who published it');
create temp table pub1 as select pg_temp.read(null, 'select api.content_public_giving_methods()') as r;
select is((select jsonb_array_length(r -> 'methods') from pub1), 1, 'anon reads the published method');
select results_eq(
  $$select k::text collate "C" from pub1, jsonb_object_keys(r #> '{methods,0}') k order by 1$$,
  $$values ('contact'::text collate "C"), ('currency'), ('details'), ('method_id'), ('method_type'), ('name'),
           ('note'), ('publication_revision'), ('published_at'), ('purpose'), ('steps'), ('ussd_code'),
           ('verified_on')$$,
  'the public projection carries no verifier, test note, editor or draft field');
select is((select (r #> '{methods,0}') - 'method_id' - 'published_at' from pub1),
  jsonb_build_object('method_type', 'mobile_money', 'name', 'SAMPLE Mobile Money', 'purpose', 'Tithes and offerings',
    'currency', 'ZMW', 'details', '[{"key": "beneficiary", "value": "SAMPLE Brethren in Christ Church Kafue"}, {"key": "merchant_id", "value": "990101"}]'::jsonb,
    'ussd_code', '*990#', 'steps', pg_temp.steps(), 'note', 'SAMPLE support note.',
    'contact', 'SAMPLE church office, +260 97 000 0099',
    'verified_on', to_char(pg_temp.today(), 'YYYY-MM-DD'), 'publication_revision', 1),
  'anon reads the live revision: copyable details in order, steps, the verified date and the contact');
select is((select r ->> 'sample' from pub1), 'true', 'off production the read says the methods are samples');
select is((pg_temp.read(5, format('select api.content_public_giving_method(%L)', pg_temp.mm1())) #>> '{method,name}'),
  'SAMPLE Mobile Money', 'a member reads the same projection by id');
select is((pg_temp.read(6, 'select api.content_public_giving_methods()') #>> '{methods,0,name}'),
  'SAMPLE Mobile Money', 'so does a Pending account');

-- The bank method: verify, then the SAMPLE fixture and the production gate
update app.content_giving_revisions set saved_at = saved_at - interval '3 days' where item_id = pg_temp.bk1();
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1(), 2))),
  'ok', 'Admin B verifies the bank method saved three days ago, tested two days ago');
select is(pg_temp.in_production(format(
    $q$select pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', %s, pg_temp.idp(%L)))$q$,
    pg_temp.rev(pg_temp.bk1()), pg_temp.bk1())),
  'unavailable|policy=gate_closed', 'in production the closed q3_giving gate refuses publication');
select is(pg_temp.in_production($q$select pg_temp.read(null, 'select api.content_public_giving_methods()') ->> 'sample'$q$),
  'false', 'in production the read says the methods are not samples');
select is(pg_temp.in_production(format(
    $q$select pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', %s, pg_temp.sv(%L, pg_temp.bank('Bank draft in production'))))$q$,
    pg_temp.rev(pg_temp.bk1()), pg_temp.bk1())),
  'ok', 'in production a closed gate still lets an Admin keep drafts');
select is(app.platform_current_environment(), 'local', 'the simulated production was undone');
create temp table rl1 as select pg_temp.cmd(1, 'content.create_giving_method', null,
  pg_temp.mm('Real-looking Money')) as r;
create function pg_temp.rl1() returns uuid language sql as $$ select (r #>> '{data,method_id}')::uuid from rl1 $$;
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.rl1()), pg_temp.vf(pg_temp.rl1()))),
  'ok', 'a method without the SAMPLE prefix can be verified');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_giving_method', pg_temp.rev(pg_temp.rl1()), pg_temp.idp(pg_temp.rl1()))),
  'validation_failed|name=sample_only', 'but the q3 fixture publishes SAMPLE methods only');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'ok', 'Admin B publishes the bank method');

-- A changed destination: refused until verified again, the old revision live meanwhile ------------
create temp table s1 as select pg_temp.cmd(1, 'content.save_giving_method', pg_temp.rev(pg_temp.bk1()),
  pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE Bank transfer', '{"account_number": "9900 3333 4444"}'))) as r;
select is((select (r -> 'data') - 'method_id' - 'revision' from s1),
  '{"state": "published", "live_revision_no": 1, "draft_revision_no": 2}'::jsonb,
  'Admin A changes the account number: a new draft beside the live revision');
create function pg_temp.public_account(p uuid) returns text language sql as $$
  select d ->> 'value' from jsonb_array_elements(
    pg_temp.read(null, format('select api.content_public_giving_method(%L)', p)) #> '{method,details}') d
   where d ->> 'key' = 'account_number' $$;
select is(pg_temp.public_account(pg_temp.bk1()), '9900 1111 2222', 'anon still reads the verified account number');
select is(pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'validation_failed|method_id=not_verified', 'the changed account number cannot be published unverified');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'validation_failed|method_id=not_verified', 'not by another Admin either');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1()))),
  'validation_failed|method_id=saved_by_you', 'Admin A cannot verify the change Admin A made');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1()))),
  'ok', 'Admin B verifies the change');
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_giving_method', pg_temp.rev(pg_temp.bk1()),
    pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE Bank transfer', '{"account_number": "9900 3333 4444"}')))),
  'validation_failed|method_id=unchanged', 'a save that changes nothing is refused (it would only add a saver)');
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_giving_method', pg_temp.rev(pg_temp.bk1()),
    pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE Bank transfer', '{"account_number": "9900 3333 4444", "note": "SAMPLE fee note."}')))),
  'ok', 'Admin B then edits the draft (a note)');
select is((select verified_at from app.content_giving_revisions where item_id = pg_temp.bk1() and revision_no = 2),
  null, 'any save clears the verification');
select is((select changed_fields from app.content_giving_audit
            where item_id = pg_temp.bk1() and action = 'saved' order by event_id desc limit 1),
  array['note']::text[], 'the save records the names of the changed fields');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1()))),
  'validation_failed|method_id=saved_by_you', 'Admin B, who saved it, cannot verify');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1()))),
  'validation_failed|method_id=saved_by_you', 'nor can Admin A, who changed the account number in the same draft');
select is(pg_temp.public_account(pg_temp.bk1()), '9900 1111 2222', 'the old number stays live meanwhile');
select is(pg_temp.err(pg_temp.cmd(2, 'content.discard_giving_draft', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'ok', 'the draft is discarded');
select results_eq(
  format($$select lifecycle_state, live_revision_no, draft_revision_no from app.content_items where item_id = %L$$, pg_temp.bk1()),
  $$values ('published'::text, 1, null::integer)$$, 'the live revision stays, with no draft');
select is((select count(*)::int from app.content_giving_audit where item_id = pg_temp.bk1() and action = 'draft_discarded'),
  1, 'the discard is audited');
select is(pg_temp.err(pg_temp.cmd(2, 'content.discard_giving_draft', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'validation_failed|method_id=nothing_to_discard', 'there is nothing more to discard');
select is(pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', pg_temp.rev(pg_temp.bk1()),
    pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE Bank transfer', '{"account_number": "9900 5555 6666"}')))),
  'ok', 'Admin A enters the new number again: a fresh revision');
select is((select saved_by_members from app.content_giving_revisions where item_id = pg_temp.bk1() and revision_no = 3),
  array[pg_temp.mid(1)], 'its savers start afresh');
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.vf(pg_temp.bk1()))),
  'ok', 'and Admin B, who did not save it, verifies');
select is(pg_temp.public_account(pg_temp.bk1()), '9900 1111 2222', 'the old number stays live until publication');
select is(pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.bk1()), pg_temp.idp(pg_temp.bk1()))),
  'ok', 'the verified change is published');
select is(pg_temp.public_account(pg_temp.bk1()), '9900 5555 6666', 'anon reads the new number');
select is((pg_temp.read(null, format('select api.content_public_giving_method(%L)', pg_temp.bk1())) #>> '{method,publication_revision}'),
  '3', 'from revision 3 (the discarded revision 2 never went public)');
select throws_ok(
  format($$update app.content_giving_revisions set account_number = '9900 7777 8888'
          where item_id = %L and revision_no = 3$$, pg_temp.bk1()),
  'PCNT1', 'a published content revision is immutable', 'a published revision never changes');
select is(pg_temp.err(pg_temp.cmd(1, 'content.discard_giving_draft', (select revision from app.content_items i, c4 where i.item_id = (c4.r #>> '{data,method_id}')::uuid),
    jsonb_build_object('method_id', (select (r #>> '{data,method_id}')::uuid from c4)))),
  'validation_failed|method_id=never_published', 'a never-published draft is archived, not discarded');
select is(pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', 1, pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE x')))),
  'conflict', 'a stale revision conflicts');
select is(pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', pg_temp.rev(pg_temp.bk1()),
    pg_temp.sv(pg_temp.bk1(), pg_temp.bank('SAMPLE x', '{"payer_name": "x"}')))),
  'validation_failed|payer_name=unknown_field', 'a save refuses a payer field too');
select is(pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', 1, jsonb_build_object('method_id', gen_random_uuid()))),
  'not_found', 'an unknown method is not found');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.vf(pg_temp.mm1()))),
  'validation_failed|method_id=nothing_to_verify', 'a method with no draft has nothing to verify');
select is(pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.idp(pg_temp.mm1()))),
  'validation_failed|method_id=nothing_to_publish', 'a published method with no draft has nothing to publish');

-- Commands refused for non-Admins on an existing method ---------------------------------------------
create temp table refused as
  select n, c, pg_temp.err(pg_temp.cmd(n, c, pg_temp.rev(pg_temp.mm1()),
     case c when 'content.save_giving_method' then pg_temp.sv(pg_temp.mm1(), pg_temp.mm('SAMPLE x'))
            when 'content.verify_giving_method' then pg_temp.vf(pg_temp.mm1())
            when 'content.move_giving_method' then pg_temp.idp(pg_temp.mm1()) || '{"position": 1}'
            else pg_temp.idp(pg_temp.mm1()) end)) as e
    from unnest(array[3, 4, 5, 6]) n,
         unnest(array['content.save_giving_method', 'content.verify_giving_method', 'content.publish_giving_method',
                      'content.hide_giving_method', 'content.archive_giving_method', 'content.move_giving_method',
                      'content.discard_giving_draft']) c;
select is((select string_agg(n || ':' || c || ':' || e, ',') from refused where e <> 'forbidden'), null,
  'Media, a Pastor, a plain member and a Pending account are refused every giving command');
select is((select count(*)::int from refused), 28, 'all 28 attempts were made');
select is((select lifecycle_state || ':' || revision from app.content_items where item_id = pg_temp.mm1()),
  'published:3', 'and nothing changed');

-- Order -------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_giving_method', pg_temp.rev(pg_temp.ot1()), pg_temp.idp(pg_temp.ot1()))),
  'validation_failed|method_id=not_verified', 'Admin B''s own method needs another Admin''s verification');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.ot1()), pg_temp.vf(pg_temp.ot1()))),
  'ok', 'Admin A verifies it');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_giving_method', pg_temp.rev(pg_temp.ot1()), pg_temp.idp(pg_temp.ot1()))),
  'ok', 'and Admin B publishes it');
create function pg_temp.public_names() returns text language sql as $$
  select string_agg(m ->> 'name', ' | ' order by o)
    from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_giving_methods()') -> 'methods')
         with ordinality as x (m, o) $$;
select is(pg_temp.public_names(), 'SAMPLE Mobile Money | SAMPLE Bank transfer | SAMPLE At church',
  'the public list follows the order');
create temp table mv1 as select pg_temp.rev(pg_temp.ot1()) as before,
  pg_temp.cmd(1, 'content.move_giving_method', pg_temp.rev(pg_temp.ot1()),
              pg_temp.idp(pg_temp.ot1()) || '{"position": 1}') as r;
select is(pg_temp.err((select r from mv1)), 'ok', 'an Admin moves a method to the top');
select is(pg_temp.public_names(), 'SAMPLE At church | SAMPLE Mobile Money | SAMPLE Bank transfer',
  'the public order follows at once');
select is((select (r #>> '{data,revision}')::bigint - before from mv1), 1::bigint, 'a move moves the revision on');
select is((select count(*)::int from app.content_giving_audit
            where item_id = pg_temp.ot1() and action = 'reordered' and position = 1), 1, 'the move is audited');
select is(pg_temp.err(pg_temp.cmd(1, 'content.move_giving_method', pg_temp.rev(pg_temp.ot1()),
    pg_temp.idp(pg_temp.ot1()) || '{"position": 7}')),
  'validation_failed|position=out_of_range', 'a position past the last method is refused');
select is(pg_temp.err(pg_temp.cmd(1, 'content.move_giving_method', pg_temp.rev(pg_temp.ot1()),
    pg_temp.idp(pg_temp.ot1()) || '{"position": "first"}')),
  'validation_failed|position=invalid', 'a position is a number');
create temp table mv2 as select pg_temp.rev(pg_temp.ot1()) as before,
  pg_temp.cmd(1, 'content.move_giving_method', pg_temp.rev(pg_temp.ot1()),
              pg_temp.idp(pg_temp.ot1()) || '{"position": 1}') as r;
select is((select (r #>> '{data,revision}')::bigint - before from mv2), 0::bigint, 'moving to its own place changes nothing');
select is(pg_temp.err(pg_temp.cmd(2, 'content.move_giving_method', pg_temp.rev(pg_temp.bk1()),
    pg_temp.idp(pg_temp.bk1()) || '{"position": 2}')),
  'ok', 'another Admin moves the bank method up');
select is(pg_temp.public_names(), 'SAMPLE At church | SAMPLE Bank transfer | SAMPLE Mobile Money',
  'and the order follows');

-- Hide and archive ------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(1, 'content.hide_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.idp(pg_temp.mm1()))),
  'ok', 'an Admin hides a method');
select is(pg_temp.public_names(), 'SAMPLE At church | SAMPLE Bank transfer', 'a hidden method leaves the public list');
select is(pg_temp.read(null, format('select api.content_public_giving_method(%L)', pg_temp.mm1())) -> 'method',
  'null'::jsonb, 'and its detail');
select is(pg_temp.err(pg_temp.cmd(1, 'content.hide_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.idp(pg_temp.mm1()))),
  'validation_failed|method_id=not_published', 'a hidden method cannot be hidden again');
select is(pg_temp.err(pg_temp.cmd(1, 'content.publish_giving_method', pg_temp.rev(pg_temp.mm1()), pg_temp.idp(pg_temp.mm1()))),
  'ok', 'publishing brings its verified live revision back');
select is(pg_temp.public_names(), 'SAMPLE At church | SAMPLE Bank transfer | SAMPLE Mobile Money',
  'in its place in the order');
select is((select r.published_by_member from app.content_giving_revisions r
            where r.item_id = pg_temp.mm1() and r.revision_no = 1), pg_temp.mid(1),
  'a revision published again keeps its first publication');
select is(pg_temp.err(pg_temp.cmd(1, 'content.hide_giving_method', pg_temp.rev(pg_temp.rl1()), pg_temp.idp(pg_temp.rl1()))),
  'validation_failed|method_id=not_published', 'a draft cannot be hidden');
select is(pg_temp.err(pg_temp.cmd(1, 'content.archive_giving_method', pg_temp.rev(pg_temp.rl1()), pg_temp.idp(pg_temp.rl1()))),
  'ok', 'an Admin archives a method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.save_giving_method', pg_temp.rev(pg_temp.rl1()),
    pg_temp.sv(pg_temp.rl1(), pg_temp.mm('SAMPLE Again')))),
  'validation_failed|method_id=archived', 'an archived method refuses every later command');
select is(pg_temp.err(pg_temp.cmd(1, 'content.move_giving_method', pg_temp.rev(pg_temp.mm1()),
    pg_temp.idp(pg_temp.mm1()) || '{"position": 5}')),
  'validation_failed|position=out_of_range', 'archived methods leave the order (four remain)');

-- The Admins' read --------------------------------------------------------------------------------------
create temp table st1 as select pg_temp.read(1, 'select api.content_staff_giving_methods()') as r;
create function pg_temp.st(p jsonb, p_id uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(p -> 'methods') e where (e ->> 'method_id')::uuid = p_id $$;
select is((select r ->> 'capacity' from st1), 'admin', 'an Admin reads every method');
select is((select jsonb_array_length(r -> 'methods') from st1), 5, 'drafts and archived methods included');
select results_eq(
  $$select (e ->> 'position')::int, e ->> 'state' from st1, jsonb_array_elements(r -> 'methods') e$$,
  $$values (1, 'published'::text), (2, 'published'), (3, 'published'), (4, 'draft'), (null, 'archived')$$,
  'methods in the public order, then the archived one without a position');
select is((select pg_temp.st(r, pg_temp.bk1()) #>> '{live,verification,verified_by}' from st1),
  'SYNTHETIC Giving Member 2', 'the live revision names its verifier');
select is((select pg_temp.st(r, pg_temp.bk1()) #>> '{live,saved_by}' from st1),
  'SYNTHETIC Giving Member 1', 'and its last saver');
select is((select pg_temp.st(r, pg_temp.bk1()) #>> '{live,verification,tested_on}' from st1),
  to_char(pg_temp.today(), 'YYYY-MM-DD'), 'and the tested date');
select ok((select (pg_temp.st(r, pg_temp.bk1()) #>> '{live,verification,test_method}') like 'SAMPLE test:%' from st1),
  'Admins read how it was tested');
select is((select pg_temp.st(r, pg_temp.bk1()) #>> '{live,verification,verified_by_you}' from st1), 'false',
  'and whether they verified it');
select is((select pg_temp.st(r, pg_temp.bk1()) #>> '{live,saved_by_you}' from st1), 'true',
  'and whether they saved it');
select is((select pg_temp.st(r, x.c4id) #>> '{draft,saved_by_you}' from st1,
                  (select (r #>> '{data,method_id}')::uuid as c4id from c4) x), 'true',
  'Admin A sees a draft they saved (so they cannot verify it)');
select results_eq(
  $$select k::text collate "C" from st1, jsonb_object_keys(pg_temp.st(r, pg_temp.bk1()) -> 'live') k order by 1$$,
  $$values ('account_number'::text collate "C"), ('bank_name'), ('beneficiary'), ('branch'), ('branch_code'),
           ('contact'), ('currency'), ('name'), ('note'), ('published_at'), ('published_by'), ('purpose'),
           ('reference'), ('revision_no'), ('saved_at'), ('saved_by'), ('saved_by_you'), ('steps'), ('swift_code'),
           ('verification')$$,
  'a bank revision carries the bank fields only');
select is(pg_temp.read(3, 'select api.content_staff_giving_methods()') #>> '{}', 'PT403|forbidden|not_granted',
  'Media cannot read the Admins'' list');
select is(pg_temp.read(4, 'select api.content_staff_giving_methods()') #>> '{}', 'PT403|forbidden|not_granted',
  'nor can a Pastor');
select is(pg_temp.read(5, 'select api.content_staff_giving_methods()') #>> '{}', 'PT403|forbidden|not_granted',
  'nor a plain member');
select is(pg_temp.read(null, 'select api.content_staff_giving_methods()') #>> '{}',
  '42501|permission denied for function content_staff_giving_methods|', 'nor anon');
select is(pg_temp.read(null, 'select count(*)::text::jsonb from app.content_giving_revisions') #>> '{}',
  '42501|permission denied for table content_giving_revisions|', 'anon cannot read a giving table');
select is(pg_temp.read(1, 'select count(*)::text::jsonb from app.content_giving_revisions') #>> '{}',
  '42501|permission denied for table content_giving_revisions|', 'nor can an Admin directly');

-- Replay ------------------------------------------------------------------------------------------------
create temp table rq as select gen_random_uuid() as id;
create temp table c5 as select pg_temp.cmd(7, 'content.create_giving_method', null,
  pg_temp.mm('SAMPLE Replay'), (select id from rq)) as r;
select is(pg_temp.cmd(7, 'content.create_giving_method', null, pg_temp.mm('SAMPLE Replay'), (select id from rq)),
  (select r from c5), 'a replay answers the stored result');
select is((select count(*)::int from app.content_giving_revisions where name = 'SAMPLE Replay'), 1,
  'and creates nothing twice');

-- Deletion: an erased Admin reads as a former member ----------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(7, 'content.verify_giving_method', pg_temp.rev(pg_temp.ot1()) ,
    pg_temp.vf(pg_temp.ot1()))), 'validation_failed|method_id=nothing_to_verify', 'Admin C has nothing to verify on a live method');
select is(pg_temp.err(pg_temp.cmd(7, 'content.save_giving_method', pg_temp.rev(pg_temp.ot1()),
    pg_temp.sv(pg_temp.ot1(), jsonb_build_object('method_type', 'other', 'name', 'SAMPLE At church', 'purpose', 'Offering',
      'currency', null, 'steps', jsonb_build_array('Bring your gift on Sunday.'), 'note', null,
      'contact', 'SAMPLE church office, +260 97 000 0099')))),
  'ok', 'Admin C saves a draft of the church method');
select is(pg_temp.err(pg_temp.cmd(1, 'content.verify_giving_method', pg_temp.rev(pg_temp.ot1()), pg_temp.vf(pg_temp.ot1()))),
  'ok', 'Admin A verifies it');
select is(pg_temp.err(pg_temp.cmd(7, 'content.publish_giving_method', pg_temp.rev(pg_temp.ot1()), pg_temp.idp(pg_temp.ot1()))),
  'ok', 'Admin C publishes it');
select is(pg_temp.err(pg_temp.cmd(7, 'content.move_giving_method', pg_temp.rev(pg_temp.ot1()),
    pg_temp.idp(pg_temp.ot1()) || '{"position": 2}')), 'ok', 'and moves it');
select ok((select (app.content_giving_erase_part(jsonb_build_object('member_id', pg_temp.mid(7), 'account_id', pg_temp.u(7),
                                                                      'phase', 'check')))) > 0,
  'the giving erase part counts Admin C''s attribution');
select is((select h ->> 'remaining' from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(7), pg_temp.u(7), gen_random_uuid(), 'erase')) h where h ->> 'module' = 'content'),
  '0', 'erase leaves nothing of Admin C in Content');
select is(app.content_giving_erase_part(jsonb_build_object('member_id', pg_temp.mid(7), 'account_id', pg_temp.u(7),
                                                             'phase', 'check')), 0, 'the giving part answers 0 afterwards');
create temp table st2 as select pg_temp.read(1, 'select api.content_staff_giving_methods()') as r;
select is((select pg_temp.st(r, pg_temp.ot1()) #>> '{live,saved_by}' from st2), 'Former member',
  'the erased Admin''s saved revision reads as a former member');
select is((select pg_temp.st(r, pg_temp.ot1()) #>> '{live,published_by}' from st2), 'Former member',
  'and their publication');
select is((select pg_temp.st(r, pg_temp.ot1()) #>> '{live,verification,verified_by}' from st2),
  'SYNTHETIC Giving Member 1', 'the verifier keeps their name');
select is((select count(*)::int from app.content_giving_audit where actor_member_id = pg_temp.mid(7)), 0,
  'the giving audit keeps no id of the erased Admin');
select is((pg_temp.read(null, format('select api.content_public_giving_method(%L)', pg_temp.ot1())) #>> '{method,name}'),
  'SAMPLE At church', 'the published method stays public');
select is((select count(*)::int from app.content_giving_revisions r
            where r.saved_by_member = '00000000-0000-0000-0000-000000000000'), 2,
  'both of Admin C''s revisions are anonymised (the published one and the replayed draft)');

select * from finish();
rollback;
