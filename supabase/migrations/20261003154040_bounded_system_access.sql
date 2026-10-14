-- Bounded system access and restricted operations (story 1.9, AD-17, AD-19, P8).
--
-- One system route, api.system_command(jsonb), for automation that has no member session:
--   * It authenticates ONLY a system credential sent in the `x-system-credential` header:
--     `sysc_<environment>_<43 base64url chars>`. Only its sha256 digest is stored here.
--   * The credential is bound to the environment marker (app.platform_current_environment();
--     an unmarked database behaves as production). A credential for another environment, or one
--     registered before the database was re-marked, is refused.
--   * The system actor (principal, job/request id) is derived from the credential and the
--     envelope request_id. No request field or header can choose an actor, member or role;
--     unknown envelope or payload keys are rejected. Nothing here sets JWT claims.
--   * A user session (authenticated JWT, or any JWT with `sub`), service_role or any role other
--     than anon is refused, even with a valid credential.
--   * Exactly one command is allowlisted: `system.synthetic_probe` (SYNTHETIC; it only advances a
--     probe counter; payload {} or {"sequence": <int>}). Each principal is granted commands of its own purpose only.
--   * Every outcome writes one content-free row to app.sys_audit (no payload, token, digest,
--     address or free text).
--   * In production (or unmarked) the route also needs the owner-approved `ops_system_access` gate.
-- Restricted operations (no client grants; run by a named restricted operator as the database
-- owner through the Supabase MCP/psql): principal and credential lifecycle, health snapshot and
-- alert status. Alerting stays disabled until the owner resolves Q12 thresholds and the restricted
-- alert destination (gates q12_operations and ops_alert_destination). No scheduler, reminder or
-- notification worker exists in this story.
--
-- Additive only: no DROP/TRUNCATE/DELETE of schema objects.

-- ---------------------------------------------------------------------------------------------
-- Ownership (AD-1): sys_ and ops_ objects belong to the platform module.
-- ---------------------------------------------------------------------------------------------
insert into app.contract_module_prefixes (prefix, module) values
  ('sys_', 'platform'), ('ops_', 'platform');

-- ---------------------------------------------------------------------------------------------
-- Fail-closed activation gates (owner-only approval via app.policy_approve)
-- ---------------------------------------------------------------------------------------------
insert into app.policy_gates (gate, decision_ref, description, fixture_value) values
  ('ops_alert_destination', 'Q12',
   'Restricted operator alert destination; with q12_operations thresholds gates alert delivery',
   null),
  ('ops_system_access', 'Release gate',
   'System-principal route in production (allowlisted commands only); local/staging need no approval',
   null);

-- ---------------------------------------------------------------------------------------------
-- Restricted operators
-- ---------------------------------------------------------------------------------------------
create table app.ops_operators (
  operator text primary key check (operator ~ '^[a-z][a-z0-9_-]{1,31}$'),
  display_name text not null check (length(btrim(display_name)) > 0),
  active boolean not null default true,
  added_by text not null check (length(btrim(added_by)) > 0),
  added_at timestamptz not null default now()
);

comment on table app.ops_operators is
  'Named restricted operators (owner-decisions-milestone-1.md: Israel is the only one).';

insert into app.ops_operators (operator, display_name, added_by) values
  ('israel', 'Israel Muyoba (owner)', 'owner-decisions-milestone-1');

-- Attributable, content-free record of every restricted operator action.
create table app.ops_operator_actions (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  operator text not null references app.ops_operators (operator),
  action text not null check (action in (
    'principal_created', 'principal_disabled', 'credential_registered', 'credential_revoked')),
  target_id uuid not null
);

-- ---------------------------------------------------------------------------------------------
-- System principals, allowlist and credentials
-- ---------------------------------------------------------------------------------------------
-- Global allowlist. The kernel dispatches only commands it knows AND that are listed here.
create table app.sys_command_kinds (
  command text primary key check (command ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  purpose text not null check (purpose ~ '^[a-z][a-z0-9_]{0,62}$'),
  description text not null
);

insert into app.sys_command_kinds (command, purpose, description) values
  ('system.synthetic_probe', 'synthetic_probe',
   'SYNTHETIC: advances the probe counter and records a health event; touches no member data');

create table app.sys_principals (
  principal_id uuid primary key default gen_random_uuid(),
  name text not null check (name ~ '^[a-z][a-z0-9-]{1,62}$'),
  environment text not null check (environment in ('local', 'staging', 'production')),
  purpose text not null,
  created_by text not null references app.ops_operators (operator),
  created_at timestamptz not null default now(),
  disabled_at timestamptz,
  unique (environment, name)
);

comment on table app.sys_principals is
  'AD-19 system principals: environment-bound, purpose-separated, never a member or church role.';

create table app.sys_principal_commands (
  principal_id uuid not null references app.sys_principals (principal_id),
  command text not null references app.sys_command_kinds (command),
  primary key (principal_id, command)
);

create table app.sys_credentials (
  credential_id uuid primary key default gen_random_uuid(),
  -- sha256 hex of the whole presented token; the token itself is never stored.
  digest text not null unique check (digest ~ '^[0-9a-f]{64}$'),
  principal_id uuid not null references app.sys_principals (principal_id),
  environment text not null check (environment in ('local', 'staging', 'production')),
  label text not null check (label ~ '^[a-z0-9][a-z0-9 ._-]{0,62}$'),
  created_by text not null references app.ops_operators (operator),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by text references app.ops_operators (operator),
  check (expires_at > created_at and expires_at <= created_at + interval '30 days')
);

-- Idempotency receipts for system commands (per principal; the request_id is the job id).
create table app.sys_receipts (
  principal_id uuid not null references app.sys_principals (principal_id),
  command text not null,
  request_id uuid not null,
  payload_hash bytea not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (principal_id, command, request_id)
);

-- The synthetic probe's aggregate (singleton).
create table app.sys_probe_state (
  singleton boolean primary key default true check (singleton),
  revision bigint not null default 0 check (revision >= 0),
  last_probe_at timestamptz,
  last_principal_id uuid
);

insert into app.sys_probe_state (singleton) values (true);

-- Content-free audit of every system-route outcome.
create table app.sys_audit (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  caller_role text not null check (caller_role in ('anon', 'authenticated', 'service_role', 'other')),
  system_principal_id uuid,
  credential_id uuid,
  -- Only allowlisted command names are recorded; anything else is null.
  command text references app.sys_command_kinds (command),
  -- Job/request id (the envelope request_id) when it is a valid uuid.
  request_id uuid,
  -- AD-19: the initiating human, recorded separately from the executor. Never taken from a
  -- request field; always null for the synthetic probe.
  initiating_member_id uuid,
  outcome text not null check (outcome in ('succeeded', 'replayed', 'rejected')),
  code text check (code is null or code in (
    'validation_failed', 'unauthenticated', 'forbidden', 'conflict', 'unavailable')),
  reason text not null check (reason in (
    'ok', 'replay', 'credential_missing', 'credential_malformed', 'credential_unknown',
    'credential_expired', 'credential_revoked', 'principal_disabled', 'wrong_environment',
    'user_session_rejected', 'role_rejected', 'system_access_gate_closed', 'envelope_invalid',
    'command_not_allowed', 'request_conflict', 'internal_error')),
  check ((outcome = 'rejected') = (code is not null))
);

create index sys_audit_occurred_at_idx on app.sys_audit (occurred_at);

comment on table app.sys_audit is
  'Content-free system-route audit: who (principal/credential ids, caller role), what (allowlisted command, request id), outcome and reason code only.';

-- Content-free health signals.
create table app.ops_health_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  signal text not null check (signal in ('synthetic_probe_ok')),
  system_principal_id uuid
);

alter table app.ops_operators enable row level security;
alter table app.ops_operator_actions enable row level security;
alter table app.sys_command_kinds enable row level security;
alter table app.sys_principals enable row level security;
alter table app.sys_principal_commands enable row level security;
alter table app.sys_credentials enable row level security;
alter table app.sys_receipts enable row level security;
alter table app.sys_probe_state enable row level security;
alter table app.sys_audit enable row level security;
alter table app.ops_health_events enable row level security;

revoke all on table
  app.ops_operators, app.ops_operator_actions, app.sys_command_kinds, app.sys_principals,
  app.sys_principal_commands, app.sys_credentials, app.sys_receipts, app.sys_probe_state,
  app.sys_audit, app.ops_health_events
  from public, anon, authenticated, service_role;
revoke all on sequence app.ops_operator_actions_id_seq, app.sys_audit_id_seq,
  app.ops_health_events_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Restricted operator procedures (no client grants)
-- ---------------------------------------------------------------------------------------------
create function app.ops_require_operator(p_operator text) returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  if not exists (select 1 from app.ops_operators o where o.operator = p_operator and o.active) then
    raise exception using errcode = '42501', message = 'not an active restricted operator';
  end if;
  return p_operator;
end;
$$;

create function app.ops_record_action(p_operator text, p_action text, p_target uuid) returns void
language sql
set search_path = ''
as $$
  insert into app.ops_operator_actions (environment, operator, action, target_id)
  values (app.platform_current_environment(), p_operator, p_action, p_target);
$$;

-- Creates a principal in THIS database's environment, granted every command of its purpose.
create function app.sys_create_principal(p_name text, p_purpose text, p_operator text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.ops_require_operator(p_operator);
  if not exists (select 1 from app.sys_command_kinds k where k.purpose = p_purpose) then
    raise exception using errcode = '22023', message = 'no allowlisted command has this purpose';
  end if;
  insert into app.sys_principals (name, environment, purpose, created_by)
  values (p_name, app.platform_current_environment(), p_purpose, p_operator)
  returning principal_id into v_id;
  insert into app.sys_principal_commands (principal_id, command)
  select v_id, k.command from app.sys_command_kinds k where k.purpose = p_purpose;
  perform app.ops_record_action(p_operator, 'principal_created', v_id);
  return v_id;
end;
$$;

-- Registers the DIGEST of a credential minted off-database (tools/ops/system-credential.mjs).
create function app.sys_register_credential(
  p_principal_id uuid,
  p_digest text,
  p_label text,
  p_ttl interval,
  p_operator text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_env text := app.platform_current_environment();
  v_principal app.sys_principals;
  v_id uuid;
  v_expires timestamptz;
begin
  perform app.ops_require_operator(p_operator);
  select * into v_principal from app.sys_principals p where p.principal_id = p_principal_id;
  if not found or v_principal.disabled_at is not null then
    raise exception using errcode = '22023', message = 'unknown or disabled principal';
  end if;
  if v_principal.environment <> v_env then
    raise exception using errcode = '22023', message = 'principal belongs to another environment';
  end if;
  if p_ttl is null or p_ttl < interval '1 minute' or p_ttl > interval '30 days' then
    raise exception using errcode = '22023', message = 'ttl must be between 1 minute and 30 days';
  end if;
  insert into app.sys_credentials (digest, principal_id, environment, label, created_by, expires_at)
  values (p_digest, p_principal_id, v_env, p_label, p_operator, now() + p_ttl)
  returning credential_id, expires_at into v_id, v_expires;
  perform app.ops_record_action(p_operator, 'credential_registered', v_id);
  return jsonb_build_object('credential_id', v_id, 'environment', v_env,
                            'expires_at', app.cmd_utc(v_expires));
end;
$$;

create function app.sys_revoke_credential(p_credential_id uuid, p_operator text) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.ops_require_operator(p_operator);
  update app.sys_credentials c set revoked_at = now(), revoked_by = p_operator
   where c.credential_id = p_credential_id and c.revoked_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'unknown or already revoked credential';
  end if;
  perform app.ops_record_action(p_operator, 'credential_revoked', p_credential_id);
end;
$$;

create function app.sys_disable_principal(p_principal_id uuid, p_operator text) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.ops_require_operator(p_operator);
  update app.sys_principals p set disabled_at = now()
   where p.principal_id = p_principal_id and p.disabled_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'unknown or already disabled principal';
  end if;
  perform app.ops_record_action(p_operator, 'principal_disabled', p_principal_id);
end;
$$;

-- Alerting is enabled only when the owner has approved BOTH the Q12 thresholds and the
-- restricted alert destination. Even then this story ships no dispatcher.
create function app.ops_alert_status() returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_closed text[] := array[]::text[];
begin
  if not app.policy_is_open('q12_operations') then
    v_closed := array_append(v_closed, 'q12_operations');
  end if;
  if not app.policy_is_open('ops_alert_destination') then
    v_closed := array_append(v_closed, 'ops_alert_destination');
  end if;
  return jsonb_build_object(
    'alerting', case when cardinality(v_closed) = 0 then 'approved_no_dispatcher' else 'disabled' end,
    'unresolved_gates', to_jsonb(v_closed),
    'dispatcher', 'none');
end;
$$;

-- Content-free health snapshot for restricted operators: counts and timestamps only.
create function app.ops_health_snapshot(p_window interval default interval '24 hours')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_since timestamptz := now() - coalesce(p_window, interval '24 hours');
  v_env text := app.platform_current_environment();
begin
  return jsonb_build_object(
    'environment', v_env,
    'generated_at', app.cmd_utc(now()),
    'window_seconds', extract(epoch from coalesce(p_window, interval '24 hours'))::bigint,
    'system_route', jsonb_build_object(
      'succeeded', (select count(*) from app.sys_audit a where a.occurred_at >= v_since and a.outcome = 'succeeded'),
      'replayed', (select count(*) from app.sys_audit a where a.occurred_at >= v_since and a.outcome = 'replayed'),
      'rejected', (select count(*) from app.sys_audit a where a.occurred_at >= v_since and a.outcome = 'rejected'),
      'rejected_by_reason', coalesce((
        select jsonb_object_agg(r.reason, r.n) from (
          select a.reason, count(*) as n from app.sys_audit a
           where a.occurred_at >= v_since and a.outcome = 'rejected' group by a.reason) r),
        '{}'::jsonb)),
    'synthetic_probe', (select jsonb_build_object(
        'revision', s.revision,
        'last_probe_at', case when s.last_probe_at is null then null else app.cmd_utc(s.last_probe_at) end)
       from app.sys_probe_state s),
    'principals_active', (select count(*) from app.sys_principals p
                           where p.environment = v_env and p.disabled_at is null),
    'credentials_active', (select count(*) from app.sys_credentials c
                            where c.environment = v_env and c.revoked_at is null and c.expires_at > now()),
    'credentials_expiring_7d', (select count(*) from app.sys_credentials c
                                 where c.environment = v_env and c.revoked_at is null
                                   and c.expires_at > now() and c.expires_at <= now() + interval '7 days'),
    'system_access', case when v_env in ('local', 'staging') or app.policy_is_open('ops_system_access')
                          then 'open' else 'gate_closed' end,
    'alerts', app.ops_alert_status());
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- System route kernel
-- ---------------------------------------------------------------------------------------------
create function app.sys_audit_write(
  p_env text, p_caller_role text, p_principal uuid, p_credential uuid, p_command text,
  p_request_id uuid, p_outcome text, p_code text, p_reason text
) returns void
language sql
set search_path = ''
as $$
  insert into app.sys_audit (environment, caller_role, system_principal_id, credential_id, command,
                             request_id, outcome, code, reason)
  values (p_env, p_caller_role, p_principal, p_credential,
          (select k.command from app.sys_command_kinds k where k.command = p_command),
          p_request_id, p_outcome, p_code, p_reason);
$$;

-- The synthetic operation. Content-free: counter + health event.
create function app.sys_synthetic_probe(p_principal uuid, p_env text) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_state app.sys_probe_state;
begin
  update app.sys_probe_state s
     set revision = s.revision + 1, last_probe_at = now(), last_principal_id = p_principal
   where s.singleton
  returning * into v_state;
  insert into app.ops_health_events (environment, signal, system_principal_id)
  values (p_env, 'synthetic_probe_ok', p_principal);
  return jsonb_build_object('environment', p_env, 'probe_revision', v_state.revision,
                            'observed_at', app.cmd_utc(v_state.last_probe_at),
                            'is_synthetic', true);
end;
$$;

create function app.sys_execute(p_envelope jsonb) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_env text := app.platform_current_environment();
  v_claims jsonb;
  v_headers jsonb;
  v_role text;
  v_caller text;
  v_token text;
  v_token_env text;
  v_cred app.sys_credentials;
  v_principal app.sys_principals;
  v_request_id uuid;
  v_command text;
  v_check jsonb;
  v_errors jsonb;
  v_hash bytea;
  v_existing app.sys_receipts;
  v_rows integer;
  v_data jsonb;
  v_result jsonb;
begin
  -- Best-effort request id for attribution (never trusted for anything else).
  if jsonb_typeof(p_envelope) = 'object'
     and app.contract_uuid_error(p_envelope -> 'request_id') is null then
    v_request_id := (p_envelope ->> 'request_id')::uuid;
  end if;
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;

  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then
    v_claims := null;
  end;
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;

  -- 1. Route contract: only the anon role (publishable key) reaches the credential check.
  v_role := coalesce(v_claims ->> 'role', nullif(current_setting('role', true), 'none'));
  v_caller := case when v_role in ('anon', 'authenticated', 'service_role') then v_role else 'other' end;
  if v_role = 'authenticated' or (v_claims ? 'sub' and v_claims ->> 'sub' is not null) then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'forbidden', 'user_session_rejected');
    return app.cmd_error_envelope(v_request_id, 'forbidden');
  end if;
  if v_role is distinct from 'anon' then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'forbidden', 'role_rejected');
    return app.cmd_error_envelope(v_request_id, 'forbidden');
  end if;

  -- 2. Credential: environment-prefixed token, matched by digest, bound to this environment.
  v_token := case when jsonb_typeof(v_headers -> 'x-system-credential') = 'string'
                  then v_headers ->> 'x-system-credential' end;
  if v_token is null or v_token = '' then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'unauthenticated', 'credential_missing');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  if v_token !~ '^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$' then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'unauthenticated', 'credential_malformed');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  v_token_env := split_part(v_token, '_', 2);
  if v_token_env <> v_env then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'unauthenticated', 'wrong_environment');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  select * into v_cred from app.sys_credentials c
   where c.digest = encode(sha256(convert_to(v_token, 'UTF8')), 'hex');
  v_token := null;
  if not found then
    perform app.sys_audit_write(v_env, v_caller, null, null, v_command, v_request_id,
                                'rejected', 'unauthenticated', 'credential_unknown');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  select * into v_principal from app.sys_principals p where p.principal_id = v_cred.principal_id;
  if v_cred.environment <> v_env or v_principal.environment <> v_env then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unauthenticated', 'wrong_environment');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  if v_cred.revoked_at is not null then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unauthenticated', 'credential_revoked');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  if v_cred.expires_at <= now() then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unauthenticated', 'credential_expired');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;
  if v_principal.disabled_at is not null then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unauthenticated', 'principal_disabled');
    return app.cmd_error_envelope(v_request_id, 'unauthenticated');
  end if;

  -- 3. Production activation gate.
  if v_env not in ('local', 'staging') and not app.policy_is_open('ops_system_access') then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unavailable', 'system_access_gate_closed');
    return app.cmd_error_envelope(v_request_id, 'unavailable', '{"policy": "gate_closed"}');
  end if;

  -- 4. Envelope: the shared command_request contract; no expected_revision. The probe payload
  -- allows only an optional content-free `sequence` (integer 1..2147483647); every other payload
  -- key (e.g. a forged actor, member, principal or role field) is reported as unknown_field.
  v_check := app.contract_check('command_request', p_envelope);
  v_errors := v_check -> 'field_errors';
  if (v_check ->> 'valid')::boolean and p_envelope ? 'expected_revision'
     and jsonb_typeof(p_envelope -> 'expected_revision') <> 'null' then
    v_errors := v_errors || '{"expected_revision": "must_be_null"}';
  end if;
  if jsonb_typeof(p_envelope -> 'payload') = 'object' then
    select v_errors || coalesce(jsonb_object_agg(k, 'unknown_field'), '{}'::jsonb)
      into v_errors
      from jsonb_object_keys(p_envelope -> 'payload') k
     where k <> 'sequence';
    if p_envelope -> 'payload' ? 'sequence'
       and not app.contract_integer_in(p_envelope -> 'payload' -> 'sequence', 1, 2147483647) then
      v_errors := v_errors || '{"sequence": "invalid"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'validation_failed', 'envelope_invalid');
    return app.cmd_error_envelope(v_request_id, 'validation_failed', v_errors);
  end if;

  -- 5. Allowlist: globally known AND granted to this principal.
  if v_command is distinct from 'system.synthetic_probe' or not exists (
       select 1 from app.sys_principal_commands pc
        where pc.principal_id = v_principal.principal_id and pc.command = v_command) then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'forbidden', 'command_not_allowed');
    return app.cmd_error_envelope(v_request_id, 'forbidden');
  end if;

  -- 6-7. Idempotency per principal/command/request_id (the job id), then execute under the
  -- trusted system context built here (never from the request). The block is a subtransaction:
  -- any unexpected failure rolls back the reservation and the probe; the audit row stays.
  v_hash := app.cmd_payload_hash(1, v_command, null, p_envelope -> 'payload');
  begin
    insert into app.sys_receipts (principal_id, command, request_id, payload_hash)
    values (v_principal.principal_id, v_command, v_request_id, v_hash)
    on conflict do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      select * into v_existing from app.sys_receipts r
       where r.principal_id = v_principal.principal_id and r.command = v_command
         and r.request_id = v_request_id;
      if v_existing.payload_hash = v_hash and v_existing.result is not null then
        perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                    v_command, v_request_id, 'replayed', null, 'replay');
        return v_existing.result;
      end if;
      perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                  v_command, v_request_id, 'rejected', 'conflict', 'request_conflict');
      return app.cmd_error_envelope(v_request_id, 'conflict');
    end if;

    v_data := app.sys_synthetic_probe(v_principal.principal_id, v_env);
    v_result := jsonb_build_object(
      'request_id', v_request_id,
      'data', jsonb_build_object(
        'actor', jsonb_build_object('kind', 'system',
                                    'system_principal_id', v_principal.principal_id,
                                    'job_id', v_request_id,
                                    'initiating_member_id', null)) || v_data,
      'revision', (v_data ->> 'probe_revision')::bigint);
    update app.sys_receipts r set result = v_result
     where r.principal_id = v_principal.principal_id and r.command = v_command
       and r.request_id = v_request_id;
  exception when others then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'unavailable', 'internal_error');
    return app.cmd_error_envelope(v_request_id, 'unavailable');
  end;
  perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                              v_command, v_request_id, 'succeeded', null, 'ok');
  return v_result;
end;
$$;

-- Definer entry point: the only way a client role reaches the kernel.
create function app.sys_command(p_envelope jsonb) returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select app.sys_execute(p_envelope);
$$;

-- PostgREST: POST /rest/v1/rpc/system_command, Content-Profile: api,
-- headers apikey: <publishable key>, x-system-credential: <system credential>,
-- body {version: 1, command, request_id, payload: {}}.
create function api.system_command(jsonb) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.sys_command($1);
$$;

comment on function api.system_command(jsonb) is
  'System route (story 1.9, AD-19): system credential only; allowlisted synthetic probe; user sessions refused.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.ops_require_operator(text),
  app.ops_record_action(text, text, uuid),
  app.sys_create_principal(text, text, text),
  app.sys_register_credential(uuid, text, text, interval, text),
  app.sys_revoke_credential(uuid, text),
  app.sys_disable_principal(uuid, text),
  app.ops_alert_status(),
  app.ops_health_snapshot(interval),
  app.sys_audit_write(text, text, uuid, uuid, text, uuid, text, text, text),
  app.sys_synthetic_probe(uuid, text),
  app.sys_execute(jsonb),
  app.sys_command(jsonb),
  api.system_command(jsonb)
  from public, anon, authenticated, service_role;

-- Granted to authenticated as well so a user session is refused explicitly and audited.
grant execute on function app.sys_command(jsonb) to anon, authenticated;
grant execute on function api.system_command(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
