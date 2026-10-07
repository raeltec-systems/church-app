-- Delete a member fully through a resumable workflow (story 2.11; I10, AD-14, AD-19, AC-22).
-- The in-app and staff requests (access denied at once), the system-route steps of the
-- `identity_deletion` purpose (journal acknowledgement, the Auth Admin fence, erasure, owner
-- hooks, anonymisation, verification, completion), interruption and idempotent retries, the
-- handover and retention-gate waits, restore replay from the journal while a restore is held,
-- and the fail-closed row-deletion stubs. HTTP evidence through real GoTrue, the served Edge
-- Function and an isolated restore: tools/identity-e2e/deletion.mjs. Every account here is
-- SYNTHETIC (+44 7700 900600-900619).
begin;
select plan(91);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000211' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000211' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s2(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9100-0000000211' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (600 + n)::text $$;

create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.c2(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s2(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid, p_age interval default interval '1 hour')
returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - p_age);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.call(p_claims jsonb, p_endpoint text, p_command text, p_expected bigint,
                             p_payload jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
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
create function pg_temp.summary(p_claims jsonb) returns text language sql as
$$ select case when r like 'ok %' then 'ok' else r end
     from pg_temp.read(p_claims, 'select api.identity_my_member_summary()') r $$;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
create function pg_temp.err(r jsonb) returns text language sql as
$$ select (r ->> 'code') || ' ' || coalesce(r -> 'field_errors', '{}'::jsonb)::text $$;
create function pg_temp.mine(n int, p_payload jsonb default '{"confirm": "delete_my_account"}') returns jsonb
language sql as $$
  select pg_temp.call(pg_temp.c(n), 'identity_deletion_command', 'identity.request_my_deletion',
                      null, p_payload)
$$;
create function pg_temp.staff(n int, p_claims jsonb default null, p_payload jsonb default '{"identity_check": "in_person"}')
returns jsonb language sql as $$
  select pg_temp.call(coalesce(p_claims, pg_temp.c(1)), 'identity_deletion_command',
                      'identity.request_member_deletion', pg_temp.mrev(n),
                      jsonb_build_object('member_id', pg_temp.mid(n)) || p_payload)
$$;
create function pg_temp.grant(n int, p_payload jsonb) returns jsonb language sql as $$
  select pg_temp.call(pg_temp.c(1), 'identity_grant_command', 'identity.grant_role',
                      pg_temp.grev(n), jsonb_build_object('member_id', pg_temp.mid(n)) || p_payload)
$$;
create function pg_temp.del(n int) returns uuid language sql as
$$ select deletion_id from app.identity_deletions where member_id = pg_temp.mid(n) $$;
create function pg_temp.steps(n int) returns text language sql as $$
  select string_agg(step || ':' || step_state, ',' order by ordinal)
    from app.identity_deletion_steps where deletion_id = pg_temp.del(n)
$$;
create function pg_temp.calls(n int) returns text language sql as $$
  select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls
   where member_id = pg_temp.mid(n)
$$;

-- The system route as the worker and the Edge Function call it (anon + x-system-credential).
create function pg_temp.token(p_fill text) returns text
language sql as $$ select 'sysc_local_' || repeat(p_fill, 43) $$;
create function pg_temp.sys(p_command text, p_payload jsonb, p_token text default null)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    jsonb_build_object('x-system-credential', coalesce(p_token, pg_temp.token('D')))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  select api.system_command(jsonb_build_object('version', 1, 'command', p_command,
           'request_id', gen_random_uuid(), 'payload', p_payload)) into r;
  reset role;
  return r;
end;
$$;
-- A journal entry as tools/recovery/journal.mjs builds it (synthetic hashes; the database does
-- not see the chain, the restore verifies it).
create sequence pg_temp.jseq start 9100;
create function pg_temp.entry(p_fields jsonb) returns jsonb language plpgsql as $$
declare
  v_seq bigint := nextval('pg_temp.jseq');
begin
  return jsonb_build_object('v', 1, 'journal', 'bic-kafue-recovery-SYNTHETIC', 'seq', v_seq,
    'at', to_char(clock_timestamp() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'prev_hash', repeat('0', 64), 'hash', encode(sha256(convert_to(v_seq::text || p_fields::text, 'UTF8')), 'hex'))
    || p_fields;
end;
$$;
-- The worker loop: at most p_max actions; returns the last next-action (`done`, `wait:<reason>`,
-- or the action it stopped before). Auth Admin is simulated by removing the Auth user row.
create function pg_temp.work(p_deletion uuid, p_max int default 40) returns text
language plpgsql as $$
declare
  v_next jsonb;
  v_begin jsonb;
  i int := 0;
begin
  loop
    v_next := pg_temp.sys('identity.deletion_next', jsonb_build_object('deletion_id', p_deletion)) -> 'data' -> 'next';
    if v_next ->> 'action' = 'done' then return 'done'; end if;
    if v_next ->> 'action' = 'wait' then return 'wait:' || (v_next ->> 'reason'); end if;
    if i >= p_max then return 'stopped_before:' || (v_next ->> 'step'); end if;
    i := i + 1;
    if v_next ->> 'action' = 'journal' then
      perform pg_temp.sys('identity.deletion_journal_ack', jsonb_build_object(
        'deletion_id', p_deletion, 'step', v_next ->> 'step', 'entry', pg_temp.entry(v_next -> 'entry')));
    elsif v_next ->> 'action' = 'auth' then
      v_begin := pg_temp.sys('identity.deletion_auth_begin', jsonb_build_object('deletion_id', p_deletion)) -> 'data';
      if (v_begin ->> 'proceed')::boolean then
        delete from auth.users where id = (v_begin ->> 'auth_user_id')::uuid;
      end if;
      perform pg_temp.sys('identity.deletion_auth_complete',
        jsonb_build_object('deletion_id', p_deletion, 'auth_result', 'deleted'));
    else
      perform pg_temp.sys('identity.deletion_advance', jsonb_build_object('deletion_id', p_deletion));
    end if;
  end loop;
end;
$$;

-- Accounts: 1 Admin A; 2 Admin B; 3 in-app deletion (cell, grant, two devices); 4 accountless
-- member (staff route); 5 member with working app access (staff route refused); 6 login-held
-- member with a fixture duty (staff route, waits for the handover); 8 restore replay subject.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 8) n where n not in (4, 7);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 8) n where n not in (4, 7);
select pg_temp.session(pg_temp.u(3), pg_temp.s2(3));

-- Structure and privileges ---------------------------------------------------------------------
select ok(not exists (
  select 1 from unnest(array['app.identity_deletions', 'app.identity_deletion_steps',
                             'app.identity_deletion_audit', 'app.identity_deletion_hooks',
                             'app.identity_deletion_retention_rules', 'app.rcv_replay_hooks']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the new tables');
select ok(not has_function_privilege('anon', 'api.identity_deletion_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_deletions()', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.identity_deletion_command(jsonb)', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.identity_admin_deletions()', 'EXECUTE')
          and has_function_privilege('authenticated', 'api.identity_admin_membership_lifecycle()', 'EXECUTE')
          and not exists (
            select 1 from unnest(array[
              'app.identity_deletion_purge_rows(uuid, uuid)', 'app.identity_deletion_purge_auth_user(uuid)',
              'app.cells_deletion_purge_rows(uuid)', 'app.rcv_apply_journal_entry_as(jsonb, text)',
              'app.rcv_apply_journal_entry(jsonb, text)', 'app.rcv_register_replay_hook(text, regprocedure)',
              'app.identity_rcv_replay(jsonb)', 'app.cells_erase_member(jsonb)',
              'app.fixture_erase_member(jsonb)', 'app.identity_register_deletion_hook(text, regprocedure)',
              'app.identity_sys_deletion_advance(uuid, uuid, jsonb)',
              'app.identity_request_my_deletion(uuid, bigint, jsonb)']) f
             cross join unnest(array['anon', 'authenticated', 'service_role']) r
             where has_function_privilege(r, f, 'EXECUTE')),
  'only the command, the Admin read and the 2.10 read are client-executable; row deletions, replay and hooks are not');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok((select count(*) from app.contract_lifecycle_events where event in ('deletion_requested', 'member_deleted')) = 2,
  'deletion_requested (v1) and member_deleted are lifecycle events');
select is((select fixture_value ->> 'fixture_label' from app.policy_gates where gate = 'identity_deletion_retention'),
  'TEST FIXTURE - Q4 retention and backup periods unapproved', 'the Q4 retention gate carries only a labelled fixture');
select ok(not exists (select 1 from app.identity_deletion_retention_rules where label not like 'FIXTURE%'),
  'every retention rule is a labelled fixture');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_deletion_audit'),
  array['action', 'actor_kind', 'actor_member_id', 'code', 'deletion_id', 'environment', 'event_id',
        'occurred_at', 'request_id', 'step', 'system_principal_id'],
  'the deletion audit holds ids and codes only');
select throws_ok($$select app.identity_register_deletion_hook('identity', 'app.fixture_erase_member(jsonb)'::regprocedure)$$,
  'PCTR1', NULL, 'identity does not hook itself');
select throws_ok($$select app.identity_register_deletion_hook('cells', 'app.fixture_erase_member(jsonb)'::regprocedure)$$,
  'PCTR1', NULL, 'a deletion handler must belong to the registering owner');
select is((select handler from app.identity_deletion_hooks where module = 'cells'), 'app.cells_erase_member(jsonb)',
  'Cells erases its own data through a registered deletion hook');
select is((select handler from app.rcv_replay_hooks where module = 'identity'), 'app.identity_rcv_replay(jsonb)',
  'Identity re-applies its journal entries through a registered replay hook');

-- Environment, members, grants, cells, credential and the SYNTHETIC hooks ---------------------------
select app.platform_set_environment('local', 'pgtap 2.11');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.11 Member ' || n, 'pgtap 2.11') as member_id
  from generate_series(1, 8) n where n not in (4, 7);
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             values ('SYNTHETIC 2.11 Accountless', 'approved', true) returning member_id)
insert into m select 4, member_id from ins;
grant select on m to authenticated;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_contact_routes (member_id, kind, value, belongs_to, is_synthetic,
                                         created_by_member, created_by_account)
values (pg_temp.mid(4), 'phone', '+447700900619', 'member', true, pg_temp.mid(1), pg_temp.u(1));
select app.contract_register_lifecycle_hook('fixture', e, 'app.fixture_record_lifecycle(jsonb)'::regprocedure)
  from unnest(array['membership_deactivated', 'deletion_requested', 'sessions_revoked', 'member_deleted']) e;
select app.identity_register_handover_hook('fixture', 'app.fixture_report_handover(jsonb)'::regprocedure);
select app.identity_register_deletion_hook('fixture', 'app.fixture_erase_member(jsonb)'::regprocedure);
create temp table t_ids (k text primary key, v uuid);
grant select on t_ids to anon;
insert into t_ids values ('principal', app.sys_create_principal('identity-deletion', 'identity_deletion', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'principal'),
  encode(sha256(convert_to(pg_temp.token('D'), 'UTF8')), 'hex'), 'pgtap 2.11', interval '1 hour', 'israel');
insert into t_ids values ('probe', app.sys_create_principal('pgtap-probe-211', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'probe'),
  encode(sha256(convert_to(pg_temp.token('P'), 'UTF8')), 'hex'), 'pgtap probe', interval '1 hour', 'israel');
select is((select array_agg(command order by command) from app.sys_principal_commands
            where principal_id = (select v from t_ids where k = 'principal')),
  array['identity.deletion_advance', 'identity.deletion_auth_begin', 'identity.deletion_auth_complete',
        'identity.deletion_journal_ack', 'identity.deletion_next', 'identity.deletion_queue'],
  'the deletion principal holds exactly its own six commands');
select is(pg_temp.sys('identity.deletion_queue', '{}', pg_temp.token('P')) ->> 'code', 'forbidden',
  'a principal of another purpose cannot run a deletion step');

-- Refusals ---------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.mine(1)), 'forbidden {"member_id": "last_admin"}',
  'the last usable Admin cannot delete their own account');
select pg_temp.grant(2, '{"role": "admin"}');
select pg_temp.grant(3, '{"role": "pastor"}');
select is(pg_temp.err(pg_temp.mine(3, '{}')), 'validation_failed {"confirm": "required"}',
  'the in-app request needs the confirmation');
select is(pg_temp.err(pg_temp.mine(3, '{"confirm": "yes"}')), 'validation_failed {"confirm": "invalid"}',
  'only the exact confirmation counts');
update auth.mfa_amr_claims set created_at = now() - interval '2 hours', updated_at = now() - interval '2 hours'
 where session_id = pg_temp.s(3);
select is(pg_temp.err(pg_temp.mine(3)), 'forbidden {"session": "reauthenticate"}',
  'the in-app request needs a recent password sign-in');
update auth.mfa_amr_claims set created_at = now(), updated_at = now() where session_id = pg_temp.s(3);
select is(pg_temp.err(pg_temp.staff(5)), 'conflict {"member_id": "member_can_use_app"}',
  'staff cannot delete a member who can use the app (they request it there)');
select is(pg_temp.err(pg_temp.staff(4, pg_temp.c(1), '{}')), 'validation_failed {"identity_check": "required"}',
  'the staff route needs an identity check');
select is(pg_temp.err(pg_temp.staff(1, pg_temp.c(2))) , 'conflict {"member_id": "member_can_use_app"}',
  'an Admin with working app access is not deleted on the staff route');
select is(pg_temp.err(pg_temp.staff(4, pg_temp.c(5))), 'forbidden {}', 'a member who is not an Admin cannot request it');

-- In-app request: access denied from the first step ------------------------------------------------
select app.cells_seed_synthetic_cells('pgtap 2.11');
insert into app.cells_member_states (member_id) values (pg_temp.mid(3));
insert into app.cells_membership_requests (member_id, kind, origin, choice, requested_cell_id)
values (pg_temp.mid(3), 'join', 'admin', 'cell', (select min(cell_id::text)::uuid from app.cells_cells));
insert into app.cells_memberships (member_id, cell_id, request_id, confirmed_by_member, confirmed_by_account, confirmed_as)
select member_id, requested_cell_id, request_id, pg_temp.mid(1), pg_temp.u(1), 'admin'
  from app.cells_membership_requests where member_id = pg_temp.mid(3);
update app.cells_membership_requests r
   set request_state = 'confirmed', decided_at = now(), decided_as = 'admin',
       resulting_membership_id = (select membership_id from app.cells_memberships where member_id = pg_temp.mid(3))
 where r.member_id = pg_temp.mid(3);
select is(pg_temp.summary(pg_temp.c(3)) || '|' || pg_temp.summary(pg_temp.c2(3)), 'ok|ok', 'member 3 is granted on both devices');
create temp table r3 as select pg_temp.mine(3) as r;
select is((select r -> 'data' ->> 'deletion_state' from r3) || '|' || (select r -> 'data' ->> 'signed_out' from r3)
          || '|' || (select (r -> 'data' ? 'display_name')::text from r3),
  'requested|true|false', 'the member is told the deletion started and the account is signed out (no name echoed)');
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u(3)), 0, 'every Auth session of the account is revoked');
select ok((select banned_until > now() + interval '99 years' from auth.users where id = pg_temp.u(3)),
  'the Auth user is banned: a password sign-in fails at Auth from this step');
select is(pg_temp.summary(pg_temp.c(3)) || ' / ' || pg_temp.summary(pg_temp.c2(3)),
  'PT401|unauthenticated|untrusted_session / PT401|unauthenticated|untrusted_session',
  'both devices are denied at once');
select is((select link_state from app.identity_account_links where member_id = pg_temp.mid(3)), 'ended',
  'the account link ended');
select is((select membership_state from app.identity_members where member_id = pg_temp.mid(3)), 'deactivated',
  'the membership is deactivated');
select is((select count(*)::int from app.identity_grants where member_id = pg_temp.mid(3) and revoked_at is null), 0,
  'every grant ended');
select is(pg_temp.calls(3), 'membership_deactivated,deletion_requested,sessions_revoked',
  'owner lifecycle hooks heard the deactivation, the deletion request and the session revocation');
select is(pg_temp.steps(3),
  'journal_access_revoked:pending,journal_manifest_member:pending,journal_manifest_account:pending,auth_account:pending,erase_identity:pending,erase_owners:pending,anonymise:pending,verify:pending,journal_completed_member:pending,journal_completed_account:pending,complete:pending',
  'the ordered steps of a deletion with a login are recorded');
select is(pg_temp.err(pg_temp.staff(3, pg_temp.c(1))), 'conflict {"member_id": "deletion_requested"}',
  'a second request is refused');
select is(pg_temp.err(pg_temp.call(pg_temp.c(1), 'identity_lifecycle_command', 'identity.restore_membership',
            pg_temp.mrev(3), jsonb_build_object('member_id', pg_temp.mid(3), 'identity_check', 'in_person'))),
  'conflict {"member_id": "deletion_requested"}', 'a member with a deletion is never restored');
select throws_ok($$update app.identity_account_links set link_state = 'active', ended_at = null where member_id = pg_temp.mid(3)$$,
  'PCMD1', NULL, 'a link of a member with a deletion never becomes live again');
select is(position(pg_temp.mid(3)::text in
            (substr(pg_temp.read(pg_temp.c(1), 'select api.identity_admin_membership_lifecycle()'), 4)::jsonb -> 'deactivated')::text), 0,
  'the 2.10 overview no longer lists the member as a restorable deactivation');

-- The worker: steps, interruption, idempotent retries --------------------------------------------------
select is(jsonb_array_length(pg_temp.sys('identity.deletion_queue', '{}') -> 'data' -> 'deletions'), 1,
  'the queue holds the open deletion');
select is(pg_temp.sys('identity.deletion_next', jsonb_build_object('deletion_id', pg_temp.del(3))) -> 'data' -> 'next' -> 'entry',
  jsonb_build_object('kind', 'access_revoked', 'subject', pg_temp.mid(3)),
  'the first step is the access-denied journal entry (opaque subject only)');
select is(pg_temp.sys('identity.deletion_advance', jsonb_build_object('deletion_id', pg_temp.del(3))) -> 'data' ->> 'outcome',
  'not_next', 'nothing destructive runs before the manifest is journaled');
select is(pg_temp.sys('identity.deletion_auth_begin', jsonb_build_object('deletion_id', pg_temp.del(3))) -> 'data' ->> 'proceed',
  'false', 'the Auth Admin fence stays closed before the manifest is journaled');
select is(pg_temp.sys('identity.deletion_journal_ack', jsonb_build_object('deletion_id', pg_temp.del(3),
            'step', 'journal_access_revoked', 'entry', pg_temp.entry(jsonb_build_object('kind', 'access_revoked', 'subject', pg_temp.u(9)))))
            -> 'data' ->> 'reason', 'entry_mismatch', 'an entry for another subject is refused');
select is((select attempts || '|' || step_state || '|' || outcome from app.identity_deletion_steps
            where deletion_id = pg_temp.del(3) and step = 'journal_access_revoked'), '1|failed|entry_mismatch',
  'the failed attempt is recorded');
create temp table e1 as select pg_temp.entry(jsonb_build_object('kind', 'access_revoked', 'subject', pg_temp.mid(3))) as e;
select is(pg_temp.sys('identity.deletion_journal_ack', jsonb_build_object('deletion_id', pg_temp.del(3),
            'step', 'journal_access_revoked', 'entry', (select e from e1))) -> 'data' ->> 'acked', 'true',
  'the exact entry is acknowledged');
select is((pg_temp.sys('identity.deletion_journal_ack', jsonb_build_object('deletion_id', pg_temp.del(3),
            'step', 'journal_access_revoked', 'entry', (select e from e1))) -> 'data') - 'actor',
  '{"acked": true, "reason": "already_done"}'::jsonb, 'acknowledging the same entry again is an idempotent no-op');
select is((select seq::text || '|' || kind || '|' || subject_id::text from app.rcv_journal_acks
            where entry_hash = (select e ->> 'hash' from e1)),
  ((select e ->> 'seq' from e1) || '|access_revoked|' || pg_temp.mid(3)::text),
  'the journal acknowledgement holds the opaque subject only');
select is(pg_temp.work(pg_temp.del(3), 2), 'stopped_before:auth_account', 'interrupted after the two manifest entries');
select is((select count(*)::int from app.identity_account_links where member_id = pg_temp.mid(3)), 1,
  'nothing was erased yet');
update app.policy_gates set fixture_value = null where gate = 'identity_deletion_retention';
select is(pg_temp.work(pg_temp.del(3)), 'wait:policy_gate_closed', 'destructive steps wait while the Q4 retention gate is closed');
update app.policy_gates set fixture_value = '{"fixture_label": "TEST FIXTURE - Q4 retention and backup periods unapproved", "retained_facts": "anonymise_account_ids"}'
 where gate = 'identity_deletion_retention';
select is(pg_temp.sys('identity.deletion_auth_complete', jsonb_build_object('deletion_id', pg_temp.del(3), 'auth_result', 'unknown'))
            -> 'data' ->> 'outcome', 'retry', 'the Auth step is done only when the Auth user is gone');
select is((select step_state || '|' || outcome from app.identity_deletion_steps where deletion_id = pg_temp.del(3) and step = 'auth_account'),
  'failed|auth_unknown', 'the failed Auth attempt is recorded');
select is(pg_temp.work(pg_temp.del(3), 3), 'stopped_before:anonymise', 'interrupted again after the Auth and erase steps');
select is((select count(*)::int from auth.users where id = pg_temp.u(3)), 0, 'the Auth user is gone');
select is((select display_name from app.identity_members where member_id = pg_temp.mid(3)), 'Deleted member',
  'only the tombstone remains of the member record');
select is((select count(*)::int from app.cells_memberships where member_id = pg_temp.mid(3))
          + (select count(*)::int from app.cells_membership_requests where member_id = pg_temp.mid(3))
          + (select count(*)::int from app.cells_member_states where member_id = pg_temp.mid(3)), 0,
  'the Cells hook erased the member''s cell data');
select is(pg_temp.work(pg_temp.del(3)), 'done', 'resumed: the worker finishes');
select is((select deletion_state || '|' || coalesce(auth_user_id::text, 'null') from app.identity_deletions where member_id = pg_temp.mid(3)),
  'completed|null', 'completed; the account id is not kept');
select is((select string_agg(distinct step_state, ',') from app.identity_deletion_steps where deletion_id = pg_temp.del(3)), 'done',
  'every step is done');
select is((select attempts || '|' || outcome from app.identity_deletion_steps where deletion_id = pg_temp.del(3) and step = 'auth_account'), '1|deleted',
  'the Auth step records its dispatched attempt and outcome');
select is(pg_temp.calls(3), 'membership_deactivated,deletion_requested,sessions_revoked,member_deleted',
  'owners heard member_deleted at completion');
select is(app.identity_deletion_remaining((select d from app.identity_deletions d where d.member_id = pg_temp.mid(3)), true), '{}'::text[],
  'every store is checked empty');
select is((select count(*)::int from app.identity_access_audit where actor_account_id = pg_temp.u(3)), 0,
  'retained facts no longer hold the deleted account id');
select ok((select count(*) from app.identity_access_audit where target_member_id = pg_temp.mid(3)) > 0,
  'retained facts keep the tombstone id (correction links)');
select is((select count(*)::int from app.cmd_receipts r where r.actor_id = pg_temp.u(3) or r.result::text like '%' || pg_temp.mid(3)::text || '%')
          + (select count(*)::int from app.sys_receipts r where r.result::text like '%' || pg_temp.mid(3)::text || '%'
                                                         or r.result::text like '%' || pg_temp.u(3)::text || '%'), 0,
  'no receipt mentions the member or the account');
select is(pg_temp.sys('identity.deletion_advance', jsonb_build_object('deletion_id', pg_temp.del(3))) -> 'data' ->> 'outcome',
  'done', 'advancing a completed deletion changes nothing');

-- Staff route: accountless member, and a held member waiting for a handover ------------------------
create temp table r4 as select pg_temp.staff(4) as r;
select is((select (r -> 'data' ->> 'origin') || '|' || (r -> 'data' ->> 'had_account') from r4), 'staff_request|false',
  'an Admin records the deletion of an accountless member');
select is(pg_temp.steps(4),
  'journal_access_revoked:pending,journal_manifest_member:pending,erase_identity:pending,erase_owners:pending,anonymise:pending,verify:pending,journal_completed_member:pending,complete:pending',
  'no account steps without a login');
select is(pg_temp.work(pg_temp.del(4)), 'done', 'the worker completes it');
select is((select count(*)::int from app.identity_contact_routes where member_id = pg_temp.mid(4)), 0,
  'the contact route is erased');

select pg_temp.call(pg_temp.c(1), 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(6),
                    jsonb_build_object('member_id', pg_temp.mid(6), 'reason_code', 'login_disabled'));
insert into app.fixture_duties (member_id, duty_kind) values (pg_temp.mid(6), 'fixture_door_duty');
select is(pg_temp.staff(6) -> 'data' ->> 'pending_obligations', '1', 'a held member can be deleted by staff; the handover is recorded');
select is(pg_temp.work(pg_temp.del(6)), 'wait:handover_pending', 'erasure waits for the handover (the account is already gone)');
select is((select count(*)::int from auth.users where id = pg_temp.u(6)), 0, 'the Auth account was not kept waiting');
select app.identity_resolve_handover_obligation('fixture',
  (select obligation_id from app.identity_handover_obligations where member_id = pg_temp.mid(6)), 'handed_over');
select is(pg_temp.work(pg_temp.del(6)), 'done', 'once handed over, the deletion completes');
select is((select count(*)::int from app.fixture_duties where member_id = pg_temp.mid(6)), 0,
  'the fixture owner''s deletion hook anonymised its duty fact');
select is((select jsonb_array_length(substr(pg_temp.read(pg_temp.c(1), 'select api.identity_admin_deletions()'), 4)::jsonb -> 'deletions')),
  3, 'the Admin read lists the deletions');
select is(substr(pg_temp.read(pg_temp.c(5), 'select api.identity_admin_deletions()'), 1, 5), 'PT403',
  'only an Admin reads deletions');

-- Restore replay: a held restore whose snapshot predates the request --------------------------------
select is((select count(*)::int from app.identity_deletions where member_id = pg_temp.mid(8)), 0, 'member 8 has no deletion yet');
update app.rcv_recovery_state set state = 'restored_held', restore_id = gen_random_uuid(), updated_by = 'pgtap';
select is(app.identity_deletion_blocker((select d from app.identity_deletions d where d.member_id = pg_temp.mid(3)), 'verify'),
  'restore_held', 'worker steps wait while a restore is held');
select lives_ok(format($$select app.rcv_apply_journal_entry(%L, 'israel')$$,
  pg_temp.entry(jsonb_build_object('kind', 'access_revoked', 'subject', pg_temp.mid(8)))),
  'replaying the access entry');
select lives_ok(format($$select app.rcv_apply_journal_entry(%L, 'israel')$$,
  pg_temp.entry(jsonb_build_object('kind', 'deletion_manifest', 'subject', pg_temp.mid(8),
    'object', jsonb_build_object('bucket', 'identity-member', 'object_id', pg_temp.mid(8))))),
  'replaying the member manifest');
select is((select origin || '|' || deletion_state from app.identity_deletions where member_id = pg_temp.mid(8)),
  'journal_replay|requested', 'the workflow is re-created from the journal');
select is((select link_state from app.identity_account_links where member_id = pg_temp.mid(8)), 'ended',
  'access is denied again on the restored snapshot');
select lives_ok(format($$select app.rcv_apply_journal_entry(%L, 'israel')$$,
  pg_temp.entry(jsonb_build_object('kind', 'deletion_manifest', 'subject', pg_temp.mid(8),
    'object', jsonb_build_object('bucket', 'auth-user', 'object_id', pg_temp.u(8))))),
  'replaying the account manifest');
select lives_ok(format($$select app.rcv_apply_journal_entry(%L, 'israel')$$,
  pg_temp.entry(jsonb_build_object('kind', 'deletion_completed',
    'object', jsonb_build_object('bucket', 'identity-member', 'object_id', pg_temp.mid(8))))),
  'replaying the member completion erases inline');
select lives_ok(format($$select app.rcv_apply_journal_entry(%L, 'israel')$$,
  pg_temp.entry(jsonb_build_object('kind', 'deletion_completed',
    'object', jsonb_build_object('bucket', 'auth-user', 'object_id', pg_temp.u(8))))),
  'replaying the account completion removes the restored Auth user');
select is((select deletion_state from app.identity_deletions where member_id = pg_temp.mid(8))
          || '|' || (select count(*)::int from auth.users where id = pg_temp.u(8))
          || '|' || (select display_name from app.identity_members where member_id = pg_temp.mid(8)),
  'completed|0|Deleted member', 'the replay completed the deletion before access opens');
select ok(app.rcv_serving_hold() and not app.policy_is_open('private_access'),
  'the restore stays held (private access closed) until reconciliation');

-- Fail closed without the row-deletion migration ----------------------------------------------------
update app.rcv_recovery_state set state = 'live', restore_id = null, updated_by = 'pgtap';
create or replace function app.identity_deletion_purge_rows(p_member_id uuid, p_auth_user_id uuid)
returns integer language plpgsql set search_path = '' as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;
select pg_temp.call(pg_temp.c(1), 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(5),
                    jsonb_build_object('member_id', pg_temp.mid(5), 'reason_code', 'login_disabled'));
select is(pg_temp.staff(5) -> 'data' ->> 'deletion_state', 'requested', 'the request works without the row-deletion migration');
select is(pg_temp.work(pg_temp.del(5), 4), 'stopped_before:erase_identity', 'journal and Auth steps run');
select is(pg_temp.sys('identity.deletion_advance', jsonb_build_object('deletion_id', pg_temp.del(5))) ->> 'code',
  'unavailable', 'erasure answers unavailable until 20261007171600 is applied');
select is((select step_state from app.identity_deletion_steps where deletion_id = pg_temp.del(5) and step = 'erase_identity'),
  'pending', 'the step stays pending (retried after the file is applied)');

select * from finish();
rollback;
