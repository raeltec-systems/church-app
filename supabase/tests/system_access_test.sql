-- Bounded system access (story 1.9, AD-19): the system route accepts only an environment-bound
-- system credential, runs only the allowlisted synthetic probe, refuses user sessions and
-- forged actor fields, and audits every outcome without content. Operator procedures, health
-- snapshot, alert status and activation gates fail closed. HTTP evidence: system_api_smoke.sh.
-- All principals, credentials and data are SYNTHETIC; tokens are built at run time.
begin;
select plan(103);

-- Calls the route the way PostgREST does: role switch, JWT claims and request headers.
create function pg_temp.sys(
  p_role text, p_credential text, p_envelope jsonb,
  p_claims jsonb default null, p_extra_headers jsonb default '{}'
) returns jsonb
language plpgsql
as $$
declare
  r jsonb;
begin
  perform set_config('request.headers',
    (p_extra_headers || case when p_credential is null then '{}'::jsonb
                             else jsonb_build_object('x-system-credential', p_credential) end)::text,
    true);
  perform set_config('request.jwt.claims', coalesce(p_claims, jsonb_build_object('role', p_role))::text, true);
  execute format('set local role %I', p_role);
  r := api.system_command(p_envelope);
  reset role;
  return r;
end;
$$;

create function pg_temp.token(p_env text, p_fill text) returns text
language sql as $$ select 'sysc_' || p_env || '_' || repeat(p_fill, 43) $$;

create function pg_temp.digest(p_token text) returns text
language sql as $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

create function pg_temp.probe(p_request_id text, p_payload jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('version', 1, 'command', 'system.synthetic_probe',
                            'request_id', p_request_id, 'payload', p_payload)
$$;

create function pg_temp.last_audit() returns text
language sql as $$
  select a.outcome || ':' || a.reason || ':' || a.caller_role
    from app.sys_audit a order by a.id desc limit 1
$$;

-- Start from empty counters inside this rolled-back transaction (db:smoke leaves audit rows).
delete from app.sys_audit;
delete from app.ops_health_events;
delete from app.ops_operator_actions;
update app.sys_probe_state set revision = 0, last_probe_at = null, last_principal_id = null;

-- Structure and privileges -------------------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['ops_operators', 'ops_operator_actions', 'sys_command_kinds', 'sys_principals',
                    'sys_principal_commands', 'sys_credentials', 'sys_receipts', 'sys_probe_state',
                    'sys_audit', 'ops_health_events']) t;
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relkind = 'r'
      and (c.relname like 'sys\_%' or c.relname like 'ops\_%')),
  'RLS is enabled on every sys_/ops_ table');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relkind in ('r', 'S')
      and (c.relname like 'sys\_%' or c.relname like 'ops\_%')
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'))),
  0, 'no client role has any privilege on sys_/ops_ tables or sequences');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and (p.proname like 'sys\_%' or p.proname like 'ops\_%')
      and p.proname <> 'sys_command'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
           or has_function_privilege('authenticated', p.oid, 'EXECUTE')
           or has_function_privilege('service_role', p.oid, 'EXECUTE'))),
  0, 'operator procedures, kernel, probe and health functions have no client grants');
select ok(not has_function_privilege('service_role', 'api.system_command(jsonb)', 'EXECUTE'),
  'service_role cannot execute the system route');
select is_definer('app', 'sys_command', array['jsonb'], 'the app entry point is SECURITY DEFINER');
select isnt_definer('api', 'system_command', array['jsonb'], 'the api wrapper uses invoker security');
select isnt_definer('app', 'sys_execute', array['jsonb'], 'the kernel itself is not a definer');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'every new object has an owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function pins search_path');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select results_eq(
  $$select column_name::text collate "C" from information_schema.columns
     where table_schema = 'app' and table_name = 'sys_audit' order by 1$$,
  $$values ('caller_role'::text collate "C"), ('code'), ('command'), ('credential_id'),
           ('environment'), ('id'), ('initiating_member_id'), ('occurred_at'), ('outcome'),
           ('reason'), ('request_id'), ('system_principal_id')$$,
  'the audit row has only ids, enums and timestamps (no payload, token, digest or free text)');
select results_eq($$select command, purpose from app.sys_command_kinds order by 1$$,
  $$values ('identity.assisted_recovery_request'::text, 'identity_assisted_recovery'::text),
           ('identity.assisted_recovery_status', 'identity_assisted_recovery'),
           ('identity.assisted_reset_begin', 'identity_assisted_recovery'),
           ('identity.assisted_reset_complete', 'identity_assisted_recovery'),
           ('identity.assisted_reset_dispatch', 'identity_assisted_recovery'),
           ('identity.deletion_advance', 'identity_deletion'),
           ('identity.deletion_auth_begin', 'identity_deletion'),
           ('identity.deletion_auth_complete', 'identity_deletion'),
           ('identity.deletion_journal_ack', 'identity_deletion'),
           ('identity.deletion_journal_catch_up', 'identity_deletion'),
           ('identity.deletion_next', 'identity_deletion'),
           ('identity.deletion_queue', 'identity_deletion'),
           ('notifications.deliver_due', 'notifications_worker'),
           ('system.synthetic_probe', 'synthetic_probe')$$,
  'the allowlist is the synthetic probe plus the story 2.9 assisted-recovery, 2.11 deletion and 3.1 notification worker commands (each their own purpose)');

-- Operators, gates and alert status ------------------------------------------------------------
select results_eq($$select operator from app.ops_operators where active$$,
  $$values ('israel'::text)$$, 'Israel is the only restricted operator');
select results_eq(
  $$select gate, state from app.policy_gates
     where gate in ('ops_alert_destination', 'ops_system_access', 'q12_operations') order by 1$$,
  $$values ('ops_alert_destination'::text, 'unresolved'::text), ('ops_system_access', 'unresolved'),
           ('q12_operations', 'unresolved')$$,
  'alert destination, production system access and Q12 gates exist and are unresolved');
select is((select fixture_value from app.policy_gates where gate = 'ops_alert_destination'), null,
  'the alert destination gate has no fixture (closed in every environment)');
select is(app.ops_alert_status(),
  '{"alerting": "disabled", "dispatcher": "none", "unresolved_gates": ["q12_operations", "ops_alert_destination"]}'::jsonb,
  'alerting is disabled and names both unresolved gates');
select throws_ok($$select app.sys_create_principal('rogue', 'synthetic_probe', 'mallory')$$,
  '42501', 'not an active restricted operator', 'a non-operator cannot create a principal');
select throws_ok($$select app.sys_create_principal('worker', 'reminder_scheduler', 'israel')$$,
  '22023', 'no allowlisted command has this purpose', 'no scheduler principal can be created');

-- Local setup ------------------------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap');
create temp table t_ids (k text primary key, v uuid);
insert into t_ids values ('principal', app.sys_create_principal('pgtap-probe', 'synthetic_probe', 'israel'));
insert into t_ids
select 'cred', (app.sys_register_credential((select v from t_ids where k = 'principal'),
  pg_temp.digest(pg_temp.token('local', 'A')), 'pgtap local', interval '1 hour', 'israel') ->> 'credential_id')::uuid;
-- A staging-prefixed token registered here: used after the database is re-marked staging.
insert into t_ids
select 'cred_moved', (app.sys_register_credential((select v from t_ids where k = 'principal'),
  pg_temp.digest(pg_temp.token('staging', 'M')), 'pgtap moved', interval '1 hour', 'israel') ->> 'credential_id')::uuid;
select throws_ok($$select app.sys_register_credential((select v from t_ids where k = 'principal'),
  repeat('0', 64), 'too long', interval '31 days', 'israel')$$,
  '22023', 'ttl must be between 1 minute and 30 days', 'credential lifetime is bounded');
select is((select count(*)::int from app.ops_operator_actions where operator = 'israel'), 3,
  'operator actions are attributed to the named operator');
select is((select count(*)::int from app.sys_audit), 0, 'audit starts empty');

-- Valid credential: the only success ----------------------------------------------------------
create temp table t_r (k text primary key, v jsonb);
grant all on t_r to anon, authenticated, service_role;
insert into t_r values ('ok', pg_temp.sys('anon', pg_temp.token('local', 'A'),
  pg_temp.probe('00000000-0000-4000-8000-000000000001')));
select is((select v -> 'data' -> 'actor' from t_r where k = 'ok'),
  jsonb_build_object('kind', 'system', 'system_principal_id', (select v from t_ids where k = 'principal'),
                     'job_id', '00000000-0000-4000-8000-000000000001', 'initiating_member_id', null),
  'the actor is the credential''s principal with the request id as job id and no member');
select ok((app.contract_check('actor', (select v -> 'data' -> 'actor' from t_r where k = 'ok')) ->> 'valid')::boolean,
  'the system actor satisfies the shared actor contract');
select ok((app.contract_check('command_response', (select v from t_r where k = 'ok')) ->> 'valid')::boolean,
  'the success satisfies the shared command_response contract');
select is((select v -> 'revision' from t_r where k = 'ok'), '1'::jsonb, 'probe revision 1');
select is((select v -> 'data' ->> 'environment' from t_r where k = 'ok'), 'local', 'environment is reported');
select is(pg_temp.last_audit(), 'succeeded:ok:anon', 'success audited');
select is((select count(*)::int from app.sys_audit a, t_ids i
            where i.k = 'principal' and a.system_principal_id = i.v and a.credential_id is not null
              and a.command = 'system.synthetic_probe'
              and a.request_id = '00000000-0000-4000-8000-000000000001'
              and a.initiating_member_id is null),
  1, 'the success row attributes principal, credential, command and job id');
select is((select count(*)::int from app.ops_health_events where signal = 'synthetic_probe_ok'), 1,
  'a content-free health event was recorded');

-- Replay and conflict --------------------------------------------------------------------------
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000001')),
  (select v from t_r where k = 'ok'), 'a replay returns the stored result');
select is(pg_temp.last_audit(), 'replayed:replay:anon', 'replay audited');
select is((select revision from app.sys_probe_state), 1::bigint, 'the replay did not run the probe again');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000001', '{"sequence": 2}')) ->> 'code',
  'conflict', 'same request id with a changed payload is a conflict');
select is(pg_temp.last_audit(), 'rejected:request_conflict:anon', 'conflict audited');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000002', '{"sequence": 2}')) -> 'revision',
  '2'::jsonb, 'a new request with a sequence succeeds');

-- Credential failures ----------------------------------------------------------------------------
select is(pg_temp.sys('anon', null, pg_temp.probe('00000000-0000-4000-8000-000000000003')),
  app.cmd_error_envelope('00000000-0000-4000-8000-000000000003', 'unauthenticated'),
  'no credential: unauthenticated');
select is(pg_temp.last_audit(), 'rejected:credential_missing:anon', 'missing credential audited');
select is(pg_temp.sys('anon', 'sysc_local_short', pg_temp.probe('00000000-0000-4000-8000-000000000003')) ->> 'code',
  'unauthenticated', 'malformed credential: unauthenticated');
select is(pg_temp.last_audit(), 'rejected:credential_malformed:anon', 'malformed credential audited');
select is(pg_temp.sys('anon', pg_temp.token('local', 'Z'), pg_temp.probe('00000000-0000-4000-8000-000000000003')) ->> 'code',
  'unauthenticated', 'unregistered credential: unauthenticated');
select is(pg_temp.last_audit(), 'rejected:credential_unknown:anon', 'unknown credential audited');
select is(pg_temp.sys('anon', pg_temp.token('staging', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000003')) ->> 'code',
  'unauthenticated', 'staging credential on local: unauthenticated');
select is(pg_temp.last_audit(), 'rejected:wrong_environment:anon', 'wrong environment audited');
select is(pg_temp.sys('anon', pg_temp.token('production', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000003')) ->> 'code',
  'unauthenticated', 'production credential on local: unauthenticated');

-- User sessions and other roles ------------------------------------------------------------------
select is(pg_temp.sys('authenticated', pg_temp.token('local', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000004'),
            '{"role": "authenticated", "sub": "00000000-0000-4000-8000-0000000000aa", "aal": "aal1"}'),
  app.cmd_error_envelope('00000000-0000-4000-8000-000000000004', 'forbidden'),
  'a user JWT is refused even with a valid credential');
select is(pg_temp.last_audit(), 'rejected:user_session_rejected:authenticated', 'user session audited');
select is((select system_principal_id from app.sys_audit order by id desc limit 1), null,
  'a refused session is not attributed to the system principal');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000004'),
            '{"role": "anon", "sub": "00000000-0000-4000-8000-0000000000aa"}') ->> 'code',
  'forbidden', 'a JWT carrying a subject is refused');
select is(pg_temp.last_audit(), 'rejected:user_session_rejected:anon', 'subject-bearing JWT audited');
select throws_ok($$select pg_temp.sys('service_role', pg_temp.token('local', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000004'))$$,
  '42501', null, 'service_role cannot call the system route');
reset role;
select set_config('request.jwt.claims', '', true);
select is(app.sys_execute(pg_temp.probe('00000000-0000-4000-8000-000000000004')) ->> 'code', 'forbidden',
  'a direct database caller without a client role is refused');
select is(pg_temp.last_audit(), 'rejected:role_rejected:other', 'other role audited');

-- Forged actor fields ----------------------------------------------------------------------------
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000005') || '{"actor": {"kind": "member", "member_id": "00000000-0000-4000-8000-0000000000bb"}}') -> 'field_errors',
  '{"actor": "unknown_field"}'::jsonb, 'an actor envelope field is rejected');
select is(pg_temp.last_audit(), 'rejected:envelope_invalid:anon', 'forged envelope audited');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000005',
              '{"system_principal_id": "00000000-0000-4000-8000-0000000000cc", "initiating_member_id": "00000000-0000-4000-8000-0000000000bb", "role": "admin"}')) -> 'field_errors',
  '{"initiating_member_id": "unknown_field", "role": "unknown_field", "system_principal_id": "unknown_field"}'::jsonb,
  'principal, member and role payload fields are rejected');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000005', '{"sequence": 0}')) -> 'field_errors',
  '{"sequence": "invalid"}'::jsonb, 'an out-of-range sequence is rejected');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            pg_temp.probe('00000000-0000-4000-8000-000000000005') || '{"expected_revision": 1}') -> 'field_errors',
  '{"expected_revision": "must_be_null"}'::jsonb, 'expected_revision must be null');
insert into t_r values ('forged_header', pg_temp.sys('anon', pg_temp.token('local', 'A'),
  pg_temp.probe('00000000-0000-4000-8000-000000000006'), null,
  '{"x-system-principal": "00000000-0000-4000-8000-0000000000cc", "x-initiating-member": "00000000-0000-4000-8000-0000000000bb"}'));
select is((select v -> 'data' -> 'actor' ->> 'system_principal_id' from t_r where k = 'forged_header'),
  (select v::text from t_ids where k = 'principal'), 'forged actor headers are ignored');
select is((select count(*)::int from app.sys_audit
            where system_principal_id = '00000000-0000-4000-8000-0000000000cc'
               or initiating_member_id is not null), 0,
  'no forged principal or member ever reaches the audit');

-- Allowlist --------------------------------------------------------------------------------------
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            jsonb_build_object('version', 1, 'command', 'fixture_counter.increment',
                               'request_id', '00000000-0000-4000-8000-000000000007', 'payload', '{}'::jsonb)) ->> 'code',
  'forbidden', 'a command outside the allowlist is refused');
select is(pg_temp.last_audit(), 'rejected:command_not_allowed:anon', 'not-allowlisted audited');
select is((select command from app.sys_audit order by id desc limit 1), null,
  'an unlisted command name is not recorded');
insert into app.sys_command_kinds values ('system.other_probe', 'synthetic_probe', 'pgtap only');
insert into app.sys_principal_commands select v, 'system.other_probe' from t_ids where k = 'principal';
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'),
            jsonb_build_object('version', 1, 'command', 'system.other_probe',
                               'request_id', '00000000-0000-4000-8000-000000000007', 'payload', '{}'::jsonb)) ->> 'code',
  'forbidden', 'a listed and granted command without a kernel handler is still refused');

-- Revoked, expired, disabled --------------------------------------------------------------------
insert into t_ids
select 'cred_b', (app.sys_register_credential((select v from t_ids where k = 'principal'),
  pg_temp.digest(pg_temp.token('local', 'B')), 'pgtap b', interval '1 hour', 'israel') ->> 'credential_id')::uuid;
select app.sys_revoke_credential((select v from t_ids where k = 'cred_b'), 'israel');
select is(pg_temp.sys('anon', pg_temp.token('local', 'B'), pg_temp.probe('00000000-0000-4000-8000-000000000008')) ->> 'code',
  'unauthenticated', 'a revoked credential is refused');
select is(pg_temp.last_audit(), 'rejected:credential_revoked:anon', 'revoked audited');
insert into t_ids
select 'cred_c', (app.sys_register_credential((select v from t_ids where k = 'principal'),
  pg_temp.digest(pg_temp.token('local', 'C')), 'pgtap c', interval '1 minute', 'israel') ->> 'credential_id')::uuid;
update app.sys_credentials set created_at = now() - interval '2 hours', expires_at = now() - interval '1 hour'
 where credential_id = (select v from t_ids where k = 'cred_c');
select is(pg_temp.sys('anon', pg_temp.token('local', 'C'), pg_temp.probe('00000000-0000-4000-8000-000000000008')) ->> 'code',
  'unauthenticated', 'an expired credential is refused');
select is(pg_temp.last_audit(), 'rejected:credential_expired:anon', 'expired audited');

-- Health snapshot ---------------------------------------------------------------------------------
select is((select array_agg(k order by k) from jsonb_object_keys(app.ops_health_snapshot()) k),
  array['alerts', 'credentials_active', 'credentials_expiring_7d', 'environment', 'generated_at',
        'principals_active', 'synthetic_probe', 'system_access', 'system_route', 'window_seconds'],
  'the health snapshot carries counts, timestamps and states only');
select is(app.ops_health_snapshot() -> 'system_route' -> 'succeeded', '3'::jsonb,
  'snapshot counts successes');
select ok((app.ops_health_snapshot() -> 'system_route' -> 'rejected_by_reason' ->> 'wrong_environment')::int >= 2,
  'snapshot counts rejections by reason');
select is(app.ops_health_snapshot() ->> 'system_access', 'open', 'local system access is open');

-- Re-marked staging: local credentials stop working ---------------------------------------------
select app.platform_set_environment('staging', 'pgtap');
select is(pg_temp.sys('anon', pg_temp.token('local', 'A'), pg_temp.probe('00000000-0000-4000-8000-000000000009')) ->> 'code',
  'unauthenticated', 'after re-marking, the local credential is refused');
select is(pg_temp.last_audit(), 'rejected:wrong_environment:anon', 'audited as wrong environment');
select is(pg_temp.sys('anon', pg_temp.token('staging', 'M'), pg_temp.probe('00000000-0000-4000-8000-000000000009')) ->> 'code',
  'unauthenticated', 'a staging-prefixed credential registered while local is refused (row binding)');
select is((select reason || ':' || (system_principal_id is not null)::text from app.sys_audit order by id desc limit 1),
  'wrong_environment:true', 'row-binding refusal is attributed to the principal');
select is(app.ops_alert_status() ->> 'alerting', 'disabled', 'alerting stays disabled on staging');

-- Production: closed until the owner approves ops_system_access ---------------------------------
select app.platform_set_environment('production', 'pgtap');
insert into t_ids values ('principal_prod', app.sys_create_principal('pgtap-probe', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'principal_prod'),
  pg_temp.digest(pg_temp.token('production', 'P')), 'pgtap prod', interval '1 hour', 'israel');
select is(pg_temp.sys('anon', pg_temp.token('production', 'P'), pg_temp.probe('00000000-0000-4000-8000-00000000000a')),
  app.cmd_error_envelope('00000000-0000-4000-8000-00000000000a', 'unavailable', '{"policy": "gate_closed"}'),
  'production refuses the system route while ops_system_access is unresolved');
select is(pg_temp.last_audit(), 'rejected:system_access_gate_closed:anon', 'gate closure audited');
select is(app.ops_health_snapshot() ->> 'system_access', 'gate_closed', 'snapshot reports the closed gate');
select app.policy_approve('ops_system_access', '{"commands": ["system.synthetic_probe"]}', 'synthetic owner', 'pgtap');
select is(pg_temp.sys('anon', pg_temp.token('production', 'P'), pg_temp.probe('00000000-0000-4000-8000-00000000000a')) -> 'revision',
  '4'::jsonb, 'after owner approval the production probe succeeds');
select is(app.ops_health_snapshot() -> 'system_route',
  '{"succeeded": 1, "replayed": 0, "rejected": 1, "rejected_by_reason": {"system_access_gate_closed": 1}}'::jsonb,
  'snapshot route counters cover only this environment''s audit rows');
select is((app.ops_health_snapshot() ->> 'credentials_active')::int, 1, 'one active production credential');
select app.sys_disable_principal((select v from t_ids where k = 'principal_prod'), 'israel');
select is((select count(*)::int from app.sys_credentials c, t_ids i
            where i.k = 'principal_prod' and c.principal_id = i.v and c.revoked_at is null), 0,
  'disabling a principal revokes its credentials');
select is((select count(*)::int from app.ops_operator_actions
            where action = 'credential_revoked' and environment = 'production'), 1,
  'the cascaded revocation is an attributed operator action');
select is(pg_temp.sys('anon', pg_temp.token('production', 'P'), pg_temp.probe('00000000-0000-4000-8000-00000000000b')) ->> 'code',
  'unauthenticated', 'a disabled principal''s credential is refused');
select is(pg_temp.last_audit(), 'rejected:credential_revoked:anon', 'refusal audited as revoked');
-- A principal disabled without the procedure (defence in depth): refused, and not counted.
insert into t_ids values ('principal_prod2', app.sys_create_principal('pgtap-probe-two', 'synthetic_probe', 'israel'));
select app.sys_register_credential((select v from t_ids where k = 'principal_prod2'),
  pg_temp.digest(pg_temp.token('production', 'Q')), 'pgtap prod two', interval '1 hour', 'israel');
update app.sys_principals set disabled_at = now() where principal_id = (select v from t_ids where k = 'principal_prod2');
select is(app.ops_health_snapshot() -> 'credentials_active', '0'::jsonb,
  'credentials of a disabled principal are not counted as active');
select is(app.ops_health_snapshot() -> 'credentials_expiring_7d', '0'::jsonb,
  'credentials of a disabled principal are not counted as expiring');
select is(pg_temp.sys('anon', pg_temp.token('production', 'Q'), pg_temp.probe('00000000-0000-4000-8000-00000000000c')) ->> 'code',
  'unauthenticated', 'a disabled principal is refused');
select is(pg_temp.last_audit(), 'rejected:principal_disabled:anon', 'disabled principal audited');
select is(app.ops_alert_status() ->> 'alerting', 'disabled', 'alerting stays disabled in production');

-- Every call was audited exactly once ------------------------------------------------------------
select is((select count(*)::int from app.sys_audit), 27, 'every system-route call wrote one audit row (the service_role call never entered)');
select is((select count(*)::int from app.sys_audit where outcome = 'succeeded'), 4,
  'only the valid probe calls succeeded');

select * from finish();
rollback;
