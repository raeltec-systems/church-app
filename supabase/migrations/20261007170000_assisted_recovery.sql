-- Staff-assisted recovery with a single-use, generation-bound setup grant (story 2.9; AD-3,
-- AD-19, AD-20, AC-06). The 1.3 proven mechanism, owned by Identity:
--
--   * The member's phone creates a random grant secret and sends ONLY its sha256 digest with a
--     recovery request (through the Edge Function identity-assisted-recovery). The request gets a
--     non-secret 8-character request code that the member shows to the church office.
--   * An Admin (not the member) opens a recovery case with the identity check and the evidence
--     seen, then binds the request into a grant: short-lived (15 min), single use, bound to the
--     case, member, account, link, approved binding revision, credential generation and purpose.
--     Only the digest is stored. A new grant supersedes every earlier grant of the account.
--   * The member chooses the password on the phone. The Edge Function is the only holder of Auth
--     Admin power (the platform's service-role key). It reaches the database ONLY through the
--     1.9 system route (api.system_command) with a credential of the purpose
--     `identity_assisted_recovery`, in fenced steps:
--       begin     under the link lock: validate the grant and the current case/link/binding/
--                 generation, consume the grant, record ONE pending operation (one unresolved
--                 operation per account and per member);
--       dispatch  the generation must be unchanged; place the operation's own security hold
--                 (password_reset_required_since), count the sessions; only then does the
--                 function call Auth Admin;
--       complete  succeeded only with exactly one `password` change since dispatch, generation +1
--                 and no session from before dispatch alive (Auth Admin password update signs
--                 out every session, 1.3 finding): the operation's own hold is released and the
--                 evidence is recorded that identity_member_reset_since and
--                 identity_password_unreviewed now accept. Auth refused and nothing changed:
--                 failed (own hold released). Anything else: uncertain, and the hold stays.
--     A late completion is recorded and changes nothing. A pending operation older than 60 s can
--     no longer be dispatched (obsolete); a dispatched one older than 120 s is `stuck` and treated
--     as uncertain. An Admin reconciles an uncertain/stuck operation: every session is revoked and
--     the hold stays until the member's next successful reset (and an Admin's release).
--   * A grant presented with another phone username is burned. A new account link for the
--     account or member is refused while an operation is unresolved (unlinking stays possible).
--   * A reset never clears a pre-existing hold (2.8): a lost-device or unreviewed-password hold
--     becomes releasable by an Admin after the successful assisted reset.
--
-- The 1.9 system kernel gains a command registry (payload check + handler per kind); the
-- synthetic probe behaves exactly as before. No new anon or service_role grant.
-- Admin commands: api.identity_recovery_command (1.4 envelope). Read:
-- api.identity_admin_recovery_cases(). Audit: app.identity_recovery_audit (ids and codes only).
--
-- No destructive statements and no row deletions. Session revocation reuses
-- app.identity_revoke_auth_sessions (20261007160100).

-- ---------------------------------------------------------------------------------------------
-- System kernel: command registry (platform, 1.9)
-- ---------------------------------------------------------------------------------------------

alter table app.sys_command_kinds
  add column payload_check text,
  add column handler text;

comment on column app.sys_command_kinds.payload_check is
  'Owner payload validator signature, `(jsonb)` -> jsonb field errors; null keeps the 1.9 probe '
  'rules. Text (resolved with to_regprocedure), because reg* columns block pg_upgrade.';
comment on column app.sys_command_kinds.handler is
  'Owner handler signature, `(principal uuid, request_id uuid, payload jsonb)` -> jsonb '
  '{data, revision?}. It answers refusals as data, never raises them. Null or unresolvable: not '
  'executable.';

-- Replaces the 1.9 kernel body (same signature, grants and audit). Changes: a command other
-- than the probe is validated by its registered payload check and executed by its registered
-- handler; everything else (route contract, credential, gate, envelope, receipts, audit) is
-- unchanged.
create or replace function app.sys_execute(p_envelope jsonb) returns jsonb
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
  v_kind app.sys_command_kinds;
  v_check_proc regprocedure;
  v_handler_proc regprocedure;
  v_check jsonb;
  v_errors jsonb;
  v_hash bytea;
  v_existing app.sys_receipts;
  v_rows integer;
  v_data jsonb;
  v_result jsonb;
begin
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

  -- 4. Envelope: the shared command_request contract; no expected_revision. A registered owner
  -- payload check validates its own command; any other command keeps the 1.9 probe rules (only
  -- an optional integer `sequence`; every other key is unknown_field).
  select k.* into v_kind from app.sys_command_kinds k where k.command = v_command;
  v_check_proc := pg_catalog.to_regprocedure(v_kind.payload_check);
  v_handler_proc := pg_catalog.to_regprocedure(v_kind.handler);
  v_check := app.contract_check('command_request', p_envelope);
  v_errors := v_check -> 'field_errors';
  if (v_check ->> 'valid')::boolean and p_envelope ? 'expected_revision'
     and jsonb_typeof(p_envelope -> 'expected_revision') <> 'null' then
    v_errors := v_errors || '{"expected_revision": "must_be_null"}';
  end if;
  if jsonb_typeof(p_envelope -> 'payload') = 'object' then
    if v_check_proc is not null then
      execute format('select %s($1)', v_check_proc::regproc)
        into v_check using p_envelope -> 'payload';
      v_errors := v_errors || coalesce(v_check, '{}'::jsonb);
    else
      select v_errors || coalesce(jsonb_object_agg(k, 'unknown_field'), '{}'::jsonb)
        into v_errors
        from jsonb_object_keys(p_envelope -> 'payload') k
       where k <> 'sequence';
      if p_envelope -> 'payload' ? 'sequence'
         and not app.contract_integer_in(p_envelope -> 'payload' -> 'sequence', 1, 2147483647) then
        v_errors := v_errors || '{"sequence": "invalid"}';
      end if;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'validation_failed', 'envelope_invalid');
    return app.cmd_error_envelope(v_request_id, 'validation_failed', v_errors);
  end if;

  -- 5. Allowlist: globally known, executable by the kernel (the probe or a registered handler)
  -- AND granted to this principal.
  if v_kind.command is null
     or (v_command <> 'system.synthetic_probe' and v_handler_proc is null)
     or not exists (
       select 1 from app.sys_principal_commands pc
        where pc.principal_id = v_principal.principal_id and pc.command = v_command) then
    perform app.sys_audit_write(v_env, v_caller, v_principal.principal_id, v_cred.credential_id,
                                v_command, v_request_id, 'rejected', 'forbidden', 'command_not_allowed');
    return app.cmd_error_envelope(v_request_id, 'forbidden');
  end if;

  -- 6-7. Idempotency per principal/command/request_id (the job id), then execute under the
  -- trusted system context built here (never from the request). The block is a subtransaction:
  -- any unexpected failure rolls back the reservation and the work; the audit row stays.
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

    if v_command = 'system.synthetic_probe' then
      v_data := app.sys_synthetic_probe(v_principal.principal_id, v_env);
      v_result := jsonb_build_object(
        'request_id', v_request_id,
        'data', jsonb_build_object(
          'actor', jsonb_build_object('kind', 'system',
                                      'system_principal_id', v_principal.principal_id,
                                      'job_id', v_request_id,
                                      'initiating_member_id', null)) || v_data,
        'revision', (v_data ->> 'probe_revision')::bigint);
    else
      execute format('select %s($1, $2, $3)', v_handler_proc::regproc)
        into v_data using v_principal.principal_id, v_request_id, p_envelope -> 'payload';
      v_result := jsonb_build_object(
        'request_id', v_request_id,
        'data', jsonb_build_object(
          'actor', jsonb_build_object('kind', 'system',
                                      'system_principal_id', v_principal.principal_id,
                                      'job_id', v_request_id,
                                      'initiating_member_id', null))
                || coalesce(v_data -> 'data', '{}'::jsonb),
        'revision', (v_data ->> 'revision')::bigint);
    end if;
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

-- ---------------------------------------------------------------------------------------------
-- Tables (owner: identity)
-- ---------------------------------------------------------------------------------------------

-- A member device's request: the claimed phone username and the DIGEST of the grant secret the
-- device holds. Neutral: it is stored whether or not the number has an account.
create table app.identity_recovery_requests (
  recovery_request_id uuid primary key default gen_random_uuid(),
  request_code text not null check (request_code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  claimed_phone text not null check (claimed_phone ~ '^\+[1-9][0-9]{7,14}$'),
  grant_digest text not null check (grant_digest ~ '^[0-9a-f]{64}$'),
  request_state text not null default 'waiting'
    check (request_state in ('waiting', 'bound')),
  requested_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  bound_at timestamptz,
  system_principal_id uuid,
  check ((request_state = 'bound') = (bound_at is not null)),
  check (expires_at > requested_at)
);

create unique index identity_recovery_requests_digest on app.identity_recovery_requests (grant_digest);
create unique index identity_recovery_requests_code_waiting
  on app.identity_recovery_requests (request_code) where request_state = 'waiting';
create index identity_recovery_requests_phone on app.identity_recovery_requests (claimed_phone, requested_at);
create index identity_recovery_requests_at on app.identity_recovery_requests (requested_at);

comment on table app.identity_recovery_requests is
  'owner: identity. Assisted-recovery requests from a member device: the claimed phone username '
  'and the sha256 digest of the grant secret the device holds (never the secret).';

-- A staff-assisted recovery case: the identity check, the evidence seen, the reviewer, outcome.
create table app.identity_recovery_cases (
  case_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  link_id uuid not null references app.identity_account_links (link_id),
  auth_user_id uuid not null,
  case_state text not null default 'open' check (case_state in ('open', 'completed', 'cancelled')),
  revision bigint not null default 1 check (revision >= 1),
  identity_check text not null check (identity_check in ('established_relationship', 'in_person')),
  evidence text[] not null check (
    cardinality(evidence) between 1 and 4
    and evidence <@ array['photo_id', 'known_in_person', 'church_records', 'leader_confirmation']),
  opened_by_member uuid not null references app.identity_members (member_id),
  opened_by_account uuid not null,
  opened_at timestamptz not null default clock_timestamp(),
  closed_at timestamptz,
  closed_by_member uuid references app.identity_members (member_id),
  closed_by_account uuid,
  outcome text check (outcome in ('reset_completed', 'cancelled')),
  cancel_reason text
    check (cancel_reason in ('identity_not_confirmed', 'member_withdrew', 'opened_in_error')),
  is_synthetic boolean not null,
  check ((case_state = 'open') = (closed_at is null)),
  check ((case_state = 'completed') = (outcome is not distinct from 'reset_completed')),
  check ((case_state = 'cancelled') = (outcome is not distinct from 'cancelled')),
  check ((case_state = 'cancelled') = (cancel_reason is not null)),
  check (opened_by_member <> member_id)
);

create unique index identity_recovery_cases_one_open
  on app.identity_recovery_cases (link_id) where case_state = 'open';
create index identity_recovery_cases_member on app.identity_recovery_cases (member_id, opened_at);

comment on table app.identity_recovery_cases is
  'owner: identity. Staff-assisted recovery case (AD-20): identity check, evidence codes, '
  'reviewer and outcome. No password, secret, digest or free text.';

-- A single-use password-setup grant. Its secret lives only on the member device; the grant is
-- found through the request's digest.
create table app.identity_recovery_grants (
  grant_id uuid primary key default gen_random_uuid(),
  case_id uuid not null references app.identity_recovery_cases (case_id),
  recovery_request_id uuid not null unique references app.identity_recovery_requests (recovery_request_id),
  member_id uuid not null references app.identity_members (member_id),
  link_id uuid not null references app.identity_account_links (link_id),
  auth_user_id uuid not null,
  binding_revision bigint not null,
  credential_generation bigint not null,
  purpose text not null default 'password_setup' check (purpose = 'password_setup'),
  grant_state text not null default 'issued'
    check (grant_state in ('issued', 'consumed', 'superseded', 'burned', 'cancelled')),
  issued_by_member uuid not null references app.identity_members (member_id),
  issued_by_account uuid not null,
  issued_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  ended_at timestamptz,
  end_reason text check (end_reason in (
    'redeemed', 'reissued', 'case_cancelled', 'reset_completed', 'identifier_mismatch',
    'stale', 'expired')),
  check ((grant_state = 'issued') = (ended_at is null)),
  check ((grant_state = 'issued') = (end_reason is null)),
  check (expires_at > issued_at)
);

create unique index identity_recovery_grants_one_issued
  on app.identity_recovery_grants (auth_user_id) where grant_state = 'issued';
create index identity_recovery_grants_case on app.identity_recovery_grants (case_id, issued_at);

comment on table app.identity_recovery_grants is
  'owner: identity. Single-use password-setup grant bound to case, member, account, link, '
  'binding revision, credential generation and purpose; only the digest exists (on the request).';

-- One fenced external Auth operation per consumed grant.
create table app.identity_recovery_operations (
  operation_id uuid primary key default gen_random_uuid(),
  grant_id uuid not null unique references app.identity_recovery_grants (grant_id),
  case_id uuid not null references app.identity_recovery_cases (case_id),
  member_id uuid not null references app.identity_members (member_id),
  link_id uuid not null references app.identity_account_links (link_id),
  auth_user_id uuid not null,
  generation_at_begin bigint not null,
  op_state text not null default 'pending' check (op_state in (
    'pending', 'dispatched', 'succeeded', 'failed', 'uncertain', 'obsolete', 'reconciled')),
  system_principal_id uuid not null,
  begun_at timestamptz not null default clock_timestamp(),
  dispatched_at timestamptz,
  event_floor bigint,
  sessions_at_dispatch integer,
  hold_id uuid references app.identity_holds (hold_id),
  completed_at timestamptz,
  auth_result text check (auth_result in ('applied', 'rejected', 'unknown')),
  credential_changes integer,
  password_event_id bigint references app.identity_credential_events (event_id),
  reconciled_at timestamptz,
  reconciled_by_member uuid references app.identity_members (member_id),
  reconciled_by_account uuid,
  reconcile_identity_check text
    check (reconcile_identity_check in ('established_relationship', 'in_person')),
  sessions_revoked integer,
  check ((op_state = 'pending') = (dispatched_at is null and completed_at is null)
         or op_state = 'obsolete'),
  check (op_state <> 'succeeded' or password_event_id is not null),
  check ((op_state = 'reconciled') = (reconciled_at is not null))
);

create unique index identity_recovery_operations_one_unresolved_account
  on app.identity_recovery_operations (auth_user_id)
  where op_state in ('pending', 'dispatched', 'uncertain');
create unique index identity_recovery_operations_one_unresolved_member
  on app.identity_recovery_operations (member_id)
  where op_state in ('pending', 'dispatched', 'uncertain');
create index identity_recovery_operations_case on app.identity_recovery_operations (case_id, begun_at);

comment on table app.identity_recovery_operations is
  'owner: identity. Fenced privileged password operations (begin, dispatch, complete). An '
  'unresolved one blocks overlapping resets and relinking, never security denial.';

-- Content-free: ids, codes and timestamps only. Never a phone number, code, secret or digest.
create table app.identity_recovery_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in (
    'request_received', 'request_refused', 'case_opened', 'case_cancelled', 'case_completed',
    'grant_issued', 'grant_superseded', 'grant_rejected', 'grant_burned',
    'operation_begun', 'operation_obsolete', 'operation_dispatched', 'operation_succeeded',
    'operation_failed', 'operation_uncertain', 'late_outcome', 'operation_reconciled')),
  actor_kind text not null check (actor_kind in ('admin', 'system')),
  actor_member_id uuid,
  actor_account_id uuid,
  system_principal_id uuid,
  request_id uuid,
  member_id uuid,
  case_id uuid,
  grant_id uuid,
  operation_id uuid,
  code text check (code ~ '^[a-z][a-z0-9_]{0,62}$'),
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  evidence text[],
  revision_after bigint,
  sessions integer,
  check ((actor_kind = 'admin') = (actor_member_id is not null and actor_account_id is not null)),
  check ((actor_kind = 'system') = (system_principal_id is not null))
);

create index identity_recovery_audit_case on app.identity_recovery_audit (case_id, event_id);

comment on table app.identity_recovery_audit is
  'owner: identity. Attributed assisted-recovery events (AD-19: Admin or system principal): ids, '
  'codes and timestamps only.';

alter table app.identity_recovery_requests enable row level security;
alter table app.identity_recovery_cases enable row level security;
alter table app.identity_recovery_grants enable row level security;
alter table app.identity_recovery_operations enable row level security;
alter table app.identity_recovery_audit enable row level security;
revoke all on table app.identity_recovery_requests, app.identity_recovery_cases,
  app.identity_recovery_grants, app.identity_recovery_operations, app.identity_recovery_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_recovery_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Settings and shared helpers
-- ---------------------------------------------------------------------------------------------

-- Assisted recovery is open when email recovery's Q1 gate (which covers the assisted procedure)
-- is approved or the database is marked local/staging, personal data is allowed (Q4 or
-- local/staging), and the database is not serving a held restore.
create function app.identity_assisted_recovery_open()
returns boolean
language sql
set search_path = ''
as $$
  select app.identity_email_recovery_open() and app.identity_applications_open();
$$;

create function app.identity_recovery_request_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '30 minutes' $$;
create function app.identity_recovery_grant_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '15 minutes' $$;
-- A pending operation older than this can no longer be dispatched.
create function app.identity_recovery_dispatch_window() returns interval
language sql immutable set search_path = '' as $$ select interval '60 seconds' $$;
-- A dispatched operation not completed within this is `stuck` (treated as uncertain).
create function app.identity_recovery_stuck_after() returns interval
language sql immutable set search_path = '' as $$ select interval '120 seconds' $$;
-- Abuse limits on requests (Q1 values are owner policy; these are fail-closed defaults).
create function app.identity_recovery_requests_per_phone_hour() returns integer
language sql immutable set search_path = '' as $$ select 5 $$;
create function app.identity_recovery_requests_per_ten_minutes() returns integer
language sql immutable set search_path = '' as $$ select 60 $$;

-- An unresolved operation of this account or member (a stale pending one no longer counts: it
-- can never be dispatched).
create function app.identity_recovery_unresolved(p_auth_user_id uuid, p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from app.identity_recovery_operations o
     where (o.auth_user_id = p_auth_user_id or o.member_id = p_member_id)
       and (o.op_state in ('dispatched', 'uncertain')
            or (o.op_state = 'pending'
                and o.begun_at > clock_timestamp() - app.identity_recovery_dispatch_window())));
$$;

-- Marks the account's stale pending operations obsolete (nothing external ever happened: a
-- pending operation older than the dispatch window cannot be dispatched).
create function app.identity_recovery_expire_pending(p_auth_user_id uuid, p_member_id uuid)
returns void
language sql
set search_path = ''
as $$
  update app.identity_recovery_operations o
     set op_state = 'obsolete', completed_at = clock_timestamp()
   where (o.auth_user_id = p_auth_user_id or o.member_id = p_member_id)
     and o.op_state = 'pending'
     and o.begun_at <= clock_timestamp() - app.identity_recovery_dispatch_window();
$$;

-- Why this link cannot be recovered now (null = it can): the link must be the live, active link
-- of an approved member with no binding review, the Auth account present and unbanned with the
-- approved phone, and every open hold a security hold (a reset never clears it).
create function app.identity_recovery_link_problem(p_link app.identity_account_links)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_link.link_id is null or p_link.link_state = 'ended' then 'not_linked'
    when not exists (select 1 from app.identity_members m
                      where m.member_id = p_link.member_id and m.membership_state = 'approved')
      then 'not_approved'
    when p_link.link_state <> 'active' or p_link.binding_review_required then 'access_review'
    when not exists (select 1 from auth.users u
                      where u.id = p_link.auth_user_id and u.deleted_at is null
                        and (u.banned_until is null or u.banned_until <= now()))
      then 'account_unavailable'
    when app.identity_auth_phone(p_link.auth_user_id) is distinct from p_link.approved_phone
      then 'phone_changed'
    when exists (select 1 from app.identity_holds h
                  where h.member_id = p_link.member_id and h.released_at is null
                    and h.hold_kind <> 'security')
      then 'disputed'
  end;
$$;

create function app.identity_recovery_audit_add(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_principal uuid,
  p_request uuid,
  p_member uuid,
  p_case uuid,
  p_grant uuid,
  p_operation uuid,
  p_code text,
  p_identity_check text default null,
  p_evidence text[] default null,
  p_revision bigint default null,
  p_sessions integer default null
) returns void
language sql
set search_path = ''
as $$
  insert into app.identity_recovery_audit (
    action, actor_kind, actor_member_id, actor_account_id, system_principal_id, request_id,
    member_id, case_id, grant_id, operation_id, code, identity_check, evidence, revision_after,
    sessions)
  values (p_action, case when p_principal is null then 'admin' else 'system' end,
          p_actor_member, p_actor_account, p_principal, p_request, p_member, p_case, p_grant,
          p_operation, p_code, p_identity_check, p_evidence, p_revision, p_sessions);
$$;

-- Ends every issued grant of the account (reissue, cancellation, success).
create function app.identity_recovery_end_grants(
  p_auth_user_id uuid,
  p_state text,
  p_reason text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_principal uuid,
  p_request uuid
) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_grant app.identity_recovery_grants;
  v_count integer := 0;
begin
  for v_grant in
    update app.identity_recovery_grants g
       set grant_state = p_state, ended_at = clock_timestamp(), end_reason = p_reason
     where g.auth_user_id = p_auth_user_id and g.grant_state = 'issued'
    returning g.*
  loop
    v_count := v_count + 1;
    perform app.identity_recovery_audit_add('grant_superseded', p_actor_member, p_actor_account,
      p_principal, p_request, v_grant.member_id, v_grant.case_id, v_grant.grant_id, null, p_reason);
  end loop;
  return v_count;
end;
$$;

-- A random 8-character request code (no 0/O/1/I), not a secret: it only finds the request.
create function app.identity_recovery_new_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  v_code text := '';
  i integer;
begin
  -- Bytes 0-5 of each uuid are fully random (version/variant bits are in bytes 6 and 8).
  foreach i in array array[0, 1, 2, 3, 16, 17, 18, 19] loop
    v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 2.8 helpers replaced: the assisted reset is the member's own reset (entry 9 records its own
-- equivalent of the 2.7 redemption evidence). Same signatures.
-- ---------------------------------------------------------------------------------------------

-- A member-initiated password reset since p_since: a 2.7 email-link redemption followed by a
-- password change, or a SUCCEEDED assisted operation dispatched since then (its single password
-- change was attributed to it at completion).
create or replace function app.identity_member_reset_since(p_link_id uuid, p_since timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from app.identity_credential_events r
      join app.identity_credential_events p
        on p.link_id = r.link_id and p.at >= r.at and 'password' = any (p.kinds)
     where r.link_id = p_link_id
       and r.at >= p_since
       and 'email_link_redeemed' = any (r.kinds))
  or exists (
    select 1 from app.identity_recovery_operations o
     where o.link_id = p_link_id and o.op_state = 'succeeded'
       and o.dispatched_at >= p_since);
$$;

-- Fail closed: the latest password change since the last binding approval was neither preceded
-- by the member's own email-link redemption nor the attributed change of a succeeded assisted
-- operation.
create or replace function app.identity_password_unreviewed(p_link_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  with approval as (
    select coalesce(max(h.approved_at), '-infinity'::timestamptz) as at
      from app.identity_binding_history h where h.link_id = p_link_id
  ), latest as (
    select e.event_id, e.at from app.identity_credential_events e, approval a
     where e.link_id = p_link_id and 'password' = any (e.kinds) and e.at >= a.at
     order by e.at desc, e.event_id desc
     limit 1
  ), previous as (
    select coalesce(max(e.at), '-infinity'::timestamptz) as at
      from app.identity_credential_events e, latest l
     where e.link_id = p_link_id and 'password' = any (e.kinds) and e.at < l.at
  )
  select coalesce((
    select not exists (
             select 1 from app.identity_credential_events r, previous pr
              where r.link_id = p_link_id and 'email_link_redeemed' = any (r.kinds)
                and r.at > pr.at and r.at <= l.at)
       and not exists (
             select 1 from app.identity_recovery_operations o
              where o.link_id = p_link_id and o.op_state = 'succeeded'
                and o.password_event_id = l.event_id)
      from latest l), false);
$$;

-- ---------------------------------------------------------------------------------------------
-- Relinking is blocked while an earlier reset is unresolved (unlinking is not).
-- ---------------------------------------------------------------------------------------------

create function app.identity_on_link_insert_recovery_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if app.identity_recovery_unresolved(new.auth_user_id, new.member_id) then
    perform app.cmd_fail('conflict', '{"member_id": "recovery_unresolved"}');
  end if;
  return new;
end;
$$;

create trigger identity_link_recovery_guard
  before insert on app.identity_account_links
  for each row
  execute function app.identity_on_link_insert_recovery_guard();

-- ---------------------------------------------------------------------------------------------
-- System commands (purpose identity_assisted_recovery), run by the Edge Function
-- identity-assisted-recovery through api.system_command. Refusals are answered as data.
-- ---------------------------------------------------------------------------------------------

create function app.identity_recovery_payload_check(p_command text, p_payload jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_allowed text[];
  v_errors jsonb;
  v_err text;
begin
  v_allowed := case p_command
    when 'identity.assisted_recovery_request' then array['phone_username', 'grant_digest']
    when 'identity.assisted_recovery_status' then array['grant_digest']
    when 'identity.assisted_reset_begin' then array['phone_username', 'grant_digest']
    when 'identity.assisted_reset_dispatch' then array['operation_id']
    when 'identity.assisted_reset_complete' then array['operation_id', 'auth_result']
  end;
  v_errors := app.contract_unknown_keys(p_payload, v_allowed);
  if 'phone_username' = any (v_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'phone_username'), 'null') = 'null' then
      v_errors := v_errors || '{"phone_username": "required"}';
    elsif jsonb_typeof(p_payload -> 'phone_username') <> 'string'
          or p_payload ->> 'phone_username' !~ '^\+[1-9][0-9]{7,14}$' then
      v_errors := v_errors || '{"phone_username": "invalid"}';
    end if;
  end if;
  if 'grant_digest' = any (v_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'grant_digest'), 'null') = 'null' then
      v_errors := v_errors || '{"grant_digest": "required"}';
    elsif jsonb_typeof(p_payload -> 'grant_digest') <> 'string'
          or p_payload ->> 'grant_digest' !~ '^[0-9a-f]{64}$' then
      v_errors := v_errors || '{"grant_digest": "invalid"}';
    end if;
  end if;
  if 'operation_id' = any (v_allowed) then
    v_err := app.contract_uuid_error(p_payload -> 'operation_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('operation_id', v_err);
    end if;
  end if;
  if 'auth_result' = any (v_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'auth_result'), 'null') = 'null' then
      v_errors := v_errors || '{"auth_result": "required"}';
    elsif jsonb_typeof(p_payload -> 'auth_result') <> 'string'
          or p_payload ->> 'auth_result' not in ('applied', 'rejected', 'unknown') then
      v_errors := v_errors || '{"auth_result": "invalid"}';
    end if;
  end if;
  return v_errors;
end;
$$;

create function app.identity_recovery_check_request(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_recovery_payload_check('identity.assisted_recovery_request', p_payload) $$;
create function app.identity_recovery_check_status(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_recovery_payload_check('identity.assisted_recovery_status', p_payload) $$;
create function app.identity_recovery_check_begin(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_recovery_payload_check('identity.assisted_reset_begin', p_payload) $$;
create function app.identity_recovery_check_dispatch(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_recovery_payload_check('identity.assisted_reset_dispatch', p_payload) $$;
create function app.identity_recovery_check_complete(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_recovery_payload_check('identity.assisted_reset_complete', p_payload) $$;

-- identity.assisted_recovery_request {phone_username, grant_digest}: neutral; the answer never
-- says whether the number has an account.
create function app.identity_sys_recovery_request(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_phone text := p_payload ->> 'phone_username';
  v_row app.identity_recovery_requests;
  v_refusal text;
  i integer := 0;
begin
  if not app.identity_assisted_recovery_open() then
    v_refusal := 'unavailable';
  elsif not app.identity_phone_username_permitted(v_phone) then
    v_refusal := 'unsupported';
  elsif (select count(*) from app.identity_recovery_requests r
          where r.claimed_phone = v_phone
            and r.requested_at > clock_timestamp() - interval '1 hour')
        >= app.identity_recovery_requests_per_phone_hour()
     or (select count(*) from app.identity_recovery_requests r
          where r.requested_at > clock_timestamp() - interval '10 minutes')
        >= app.identity_recovery_requests_per_ten_minutes() then
    v_refusal := 'rate_limited';
  elsif exists (select 1 from app.identity_recovery_requests r
                 where r.grant_digest = p_payload ->> 'grant_digest') then
    v_refusal := 'invalid';
  end if;
  if v_refusal is not null then
    perform app.identity_recovery_audit_add('request_refused', null, null, p_principal, p_request,
      null, null, null, null, v_refusal);
    return jsonb_build_object('data', jsonb_build_object('accepted', false, 'reason', v_refusal));
  end if;
  loop
    i := i + 1;
    begin
      insert into app.identity_recovery_requests (request_code, claimed_phone, grant_digest,
                                                  expires_at, system_principal_id)
      values (app.identity_recovery_new_code(), v_phone, p_payload ->> 'grant_digest',
              clock_timestamp() + app.identity_recovery_request_ttl(), p_principal)
      returning * into v_row;
      exit;
    exception when unique_violation then
      if i >= 5 then
        raise;
      end if;
    end;
  end loop;
  perform app.identity_recovery_audit_add('request_received', null, null, p_principal, p_request,
    null, null, null, null, null);
  return jsonb_build_object('data', jsonb_build_object(
    'accepted', true, 'request_code', v_row.request_code,
    'expires_at', app.cmd_utc(v_row.expires_at)));
end;
$$;

-- identity.assisted_recovery_status {grant_digest}: waiting, ready (a grant is issued for it) or
-- closed (expired, used, superseded, burned, cancelled or unknown).
create function app.identity_sys_recovery_status(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_req app.identity_recovery_requests;
  v_grant app.identity_recovery_grants;
begin
  select r.* into v_req from app.identity_recovery_requests r
   where r.grant_digest = p_payload ->> 'grant_digest';
  if v_req.recovery_request_id is not null and v_req.request_state = 'waiting'
     and v_req.expires_at > clock_timestamp() then
    return jsonb_build_object('data', jsonb_build_object(
      'state', 'waiting', 'expires_at', app.cmd_utc(v_req.expires_at)));
  end if;
  select g.* into v_grant from app.identity_recovery_grants g
   where g.recovery_request_id = v_req.recovery_request_id;
  if v_grant.grant_id is not null and v_grant.grant_state = 'issued'
     and v_grant.expires_at > clock_timestamp() then
    return jsonb_build_object('data', jsonb_build_object(
      'state', 'ready', 'expires_at', app.cmd_utc(v_grant.expires_at)));
  end if;
  return jsonb_build_object('data', jsonb_build_object('state', 'closed'));
end;
$$;

-- identity.assisted_reset_begin {phone_username, grant_digest}: under the Identity link lock,
-- validate the grant against the CURRENT case, link, binding and generation, consume it and
-- record one pending operation. A wrong phone username burns the grant.
create function app.identity_sys_reset_begin(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_grant app.identity_recovery_grants;
  v_req app.identity_recovery_requests;
  v_case app.identity_recovery_cases;
  v_link app.identity_account_links;
  v_op app.identity_recovery_operations;
  v_reason text;
  v_end_state text;
begin
  select g.* into v_grant
    from app.identity_recovery_requests r
    join app.identity_recovery_grants g on g.recovery_request_id = r.recovery_request_id
   where r.grant_digest = p_payload ->> 'grant_digest';
  if v_grant.grant_id is null then
    perform app.identity_recovery_audit_add('grant_rejected', null, null, p_principal, p_request,
      null, null, null, null, 'unknown_grant');
    return jsonb_build_object('data', jsonb_build_object('accepted', false, 'reason', 'rejected'));
  end if;
  -- Lock order: the Identity link first, then the grant.
  select l.* into v_link from app.identity_account_links l
   where l.link_id = v_grant.link_id for update;
  select g.* into v_grant from app.identity_recovery_grants g
   where g.grant_id = v_grant.grant_id for update;
  select r.* into v_req from app.identity_recovery_requests r
   where r.recovery_request_id = v_grant.recovery_request_id;
  select c.* into v_case from app.identity_recovery_cases c where c.case_id = v_grant.case_id;
  perform app.identity_recovery_expire_pending(v_grant.auth_user_id, v_grant.member_id);

  if v_grant.grant_state <> 'issued' then
    v_reason := 'grant_' || v_grant.grant_state;
  elsif v_grant.expires_at <= clock_timestamp() then
    v_reason := 'expired'; v_end_state := 'superseded';
  elsif p_payload ->> 'phone_username' is distinct from v_req.claimed_phone
        or p_payload ->> 'phone_username' is distinct from v_link.approved_phone then
    v_reason := 'identifier_mismatch'; v_end_state := 'burned';
  elsif not app.identity_assisted_recovery_open() then
    v_reason := 'unavailable';
  elsif v_case.case_state <> 'open' then
    v_reason := 'stale'; v_end_state := 'superseded';
  else
    v_reason := app.identity_recovery_link_problem(v_link);
    if v_reason is null
       and (v_link.binding_revision <> v_grant.binding_revision
            or v_link.credential_generation <> v_grant.credential_generation
            or v_link.member_id <> v_grant.member_id
            or v_link.auth_user_id <> v_grant.auth_user_id) then
      v_reason := 'stale';
    end if;
    if v_reason is null
       and app.identity_recovery_unresolved(v_grant.auth_user_id, v_grant.member_id) then
      v_reason := 'recovery_unresolved';
    end if;
    if v_reason is not null then
      v_end_state := 'superseded';
      v_reason := case when v_reason = 'recovery_unresolved' then v_reason else 'stale' end;
    end if;
  end if;

  if v_reason is not null then
    if v_end_state is not null then
      update app.identity_recovery_grants g
         set grant_state = v_end_state, ended_at = clock_timestamp(),
             end_reason = case when v_reason in ('expired', 'identifier_mismatch') then v_reason
                               else 'stale' end
       where g.grant_id = v_grant.grant_id;
    end if;
    perform app.identity_recovery_audit_add(
      case when v_end_state = 'burned' then 'grant_burned' else 'grant_rejected' end,
      null, null, p_principal, p_request, v_grant.member_id, v_grant.case_id, v_grant.grant_id,
      null, v_reason);
    return jsonb_build_object('data', jsonb_build_object('accepted', false, 'reason', 'rejected'));
  end if;

  update app.identity_recovery_grants g
     set grant_state = 'consumed', ended_at = clock_timestamp(), end_reason = 'redeemed'
   where g.grant_id = v_grant.grant_id;
  insert into app.identity_recovery_operations (grant_id, case_id, member_id, link_id,
                                                auth_user_id, generation_at_begin,
                                                system_principal_id)
  values (v_grant.grant_id, v_grant.case_id, v_grant.member_id, v_grant.link_id,
          v_grant.auth_user_id, v_link.credential_generation, p_principal)
  returning * into v_op;
  perform app.identity_recovery_audit_add('operation_begun', null, null, p_principal, p_request,
    v_op.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id, null);
  return jsonb_build_object('data', jsonb_build_object(
    'accepted', true, 'operation_id', v_op.operation_id));
end;
$$;

-- identity.assisted_reset_dispatch {operation_id}: the fence before the external call. The
-- generation, link and binding must be unchanged since begin; the operation's own security hold
-- (password reset required) is placed and the sessions are counted. Only `proceed: true` lets
-- the function call Auth Admin.
create function app.identity_sys_reset_dispatch(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_op app.identity_recovery_operations;
  v_link app.identity_account_links;
  v_hold app.identity_holds;
  v_reason text;
  v_revision bigint;
begin
  select o.* into v_op from app.identity_recovery_operations o
   where o.operation_id = (p_payload ->> 'operation_id')::uuid;
  if v_op.operation_id is null then
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', 'rejected'));
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.link_id = v_op.link_id for update;
  select o.* into v_op from app.identity_recovery_operations o
   where o.operation_id = v_op.operation_id for update;
  if v_op.op_state <> 'pending' then
    v_reason := 'not_pending';
  elsif v_op.begun_at <= clock_timestamp() - app.identity_recovery_dispatch_window() then
    v_reason := 'too_late';
  elsif v_link.credential_generation <> v_op.generation_at_begin then
    v_reason := 'generation_moved';
  else
    v_reason := app.identity_recovery_link_problem(v_link);
  end if;
  if v_reason is not null then
    if v_op.op_state = 'pending' then
      update app.identity_recovery_operations o
         set op_state = 'obsolete', completed_at = clock_timestamp()
       where o.operation_id = v_op.operation_id;
      perform app.identity_recovery_audit_add('operation_obsolete', null, null, p_principal,
        p_request, v_op.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id, v_reason);
    end if;
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', 'rejected'));
  end if;

  update app.identity_recovery_operations o
     set op_state = 'dispatched', dispatched_at = clock_timestamp()
   where o.operation_id = v_op.operation_id;
  -- Held from now on: an uncertain or late outcome keeps access held (AD-20). The 2.2 hold
  -- trigger moves the trust epoch.
  insert into app.identity_holds (member_id, hold_kind, reason, placed_by,
                                  password_reset_required_since)
  values (v_op.member_id, 'security', 'assisted_reset_operation',
          'system:identity_assisted_recovery', clock_timestamp())
  returning * into v_hold;
  update app.identity_recovery_operations o
     set hold_id = v_hold.hold_id,
         event_floor = coalesce((select max(e.event_id) from app.identity_credential_events e
                                  where e.link_id = v_op.link_id), 0),
         sessions_at_dispatch = (select count(*) from auth.sessions s
                                  where s.user_id = v_op.auth_user_id
                                    and (s.not_after is null or s.not_after > now()))
   where o.operation_id = v_op.operation_id
  returning * into v_op;
  v_revision := app.identity_bump_member(v_op.member_id);
  perform app.identity_recovery_audit_add('operation_dispatched', null, null, p_principal,
    p_request, v_op.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id, null, null, null,
    v_revision, v_op.sessions_at_dispatch);
  perform app.identity_dispatch_lifecycle('access_hold_applied', v_op.member_id, v_revision);
  return jsonb_build_object('data', jsonb_build_object(
    'proceed', true, 'auth_user_id', v_op.auth_user_id));
end;
$$;

-- identity.assisted_reset_complete {operation_id, auth_result}: fenced completion.
create function app.identity_sys_reset_complete(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_op app.identity_recovery_operations;
  v_link app.identity_account_links;
  v_result text := p_payload ->> 'auth_result';
  v_changes integer;
  v_event app.identity_credential_events;
  v_pre_dispatch_live boolean;
  v_state text;
  v_revision bigint;
begin
  select o.* into v_op from app.identity_recovery_operations o
   where o.operation_id = (p_payload ->> 'operation_id')::uuid;
  if v_op.operation_id is null then
    return jsonb_build_object('data', jsonb_build_object('outcome', 'rejected'));
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.link_id = v_op.link_id for update;
  select o.* into v_op from app.identity_recovery_operations o
   where o.operation_id = v_op.operation_id for update;
  if v_op.op_state <> 'dispatched' then
    -- Late or repeated completion: recorded, never acted on.
    perform app.identity_recovery_audit_add('late_outcome', null, null, p_principal, p_request,
      v_op.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id, v_result);
    return jsonb_build_object('data', jsonb_build_object(
      'outcome', v_op.op_state, 'late', true));
  end if;

  select count(*) into v_changes from app.identity_credential_events e
   where e.link_id = v_op.link_id and e.event_id > v_op.event_floor
     and e.source in ('auth_users', 'auth_identities', 'auth_mfa_factors');
  select e.* into v_event from app.identity_credential_events e
   where e.link_id = v_op.link_id and e.event_id > v_op.event_floor
     and e.source in ('auth_users', 'auth_identities', 'auth_mfa_factors')
   order by e.event_id
   limit 1;
  v_pre_dispatch_live := exists (
    select 1 from auth.sessions s
     where s.user_id = v_op.auth_user_id and s.created_at <= v_op.dispatched_at
       and (s.not_after is null or s.not_after > now()));

  if v_result = 'applied' and v_changes = 1 and v_event.kinds = array['password']
     and v_link.credential_generation = v_op.generation_at_begin + 1
     and v_link.link_state <> 'ended' and not v_pre_dispatch_live
     and v_op.dispatched_at > clock_timestamp() - app.identity_recovery_stuck_after() then
    v_state := 'succeeded';
  elsif v_result = 'rejected' and v_changes = 0
        and v_link.credential_generation = v_op.generation_at_begin then
    v_state := 'failed';
  else
    v_state := 'uncertain';
  end if;

  update app.identity_recovery_operations o
     set op_state = v_state, completed_at = clock_timestamp(), auth_result = v_result,
         credential_changes = v_changes,
         password_event_id = case when v_state = 'succeeded' then v_event.event_id end
   where o.operation_id = v_op.operation_id
  returning * into v_op;

  if v_state in ('succeeded', 'failed') then
    -- Only the operation's OWN hold is released; any other hold stays (a reset never clears it).
    update app.identity_holds h
       set released_at = now(), released_by = 'system:identity_assisted_recovery'
     where h.hold_id = v_op.hold_id and h.released_at is null;
  end if;
  if v_state = 'succeeded' then
    update app.identity_recovery_cases c
       set case_state = 'completed', outcome = 'reset_completed', closed_at = clock_timestamp(),
           revision = c.revision + 1
     where c.case_id = v_op.case_id and c.case_state = 'open';
    perform app.identity_recovery_end_grants(v_op.auth_user_id, 'superseded', 'reset_completed',
      null, null, p_principal, p_request);
  end if;
  v_revision := app.identity_bump_member(v_op.member_id);
  perform app.identity_recovery_audit_add('operation_' || v_state, null, null, p_principal,
    p_request, v_op.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id, v_result, null,
    null, v_revision, v_changes);
  if v_state = 'succeeded' then
    perform app.identity_recovery_audit_add('case_completed', null, null, p_principal, p_request,
      v_op.member_id, v_op.case_id, null, v_op.operation_id, 'reset_completed');
  end if;
  if v_state in ('succeeded', 'failed') then
    perform app.identity_dispatch_lifecycle('access_hold_released', v_op.member_id, v_revision);
  end if;
  if v_state = 'succeeded' then
    -- Auth Admin's password update signed out every session (verified above).
    perform app.identity_dispatch_lifecycle('sessions_revoked', v_op.member_id, v_revision);
  end if;
  return jsonb_build_object('data', jsonb_build_object('outcome', v_state));
end;
$$;

insert into app.sys_command_kinds (command, purpose, description, payload_check, handler) values
  ('identity.assisted_recovery_request', 'identity_assisted_recovery',
   'Story 2.9: a member device records an assisted-recovery request (digest only)',
   'app.identity_recovery_check_request(jsonb)',
   'app.identity_sys_recovery_request(uuid, uuid, jsonb)'),
  ('identity.assisted_recovery_status', 'identity_assisted_recovery',
   'Story 2.9: whether a request is waiting, ready or closed',
   'app.identity_recovery_check_status(jsonb)',
   'app.identity_sys_recovery_status(uuid, uuid, jsonb)'),
  ('identity.assisted_reset_begin', 'identity_assisted_recovery',
   'Story 2.9: validate and consume a setup grant, record one pending operation',
   'app.identity_recovery_check_begin(jsonb)',
   'app.identity_sys_reset_begin(uuid, uuid, jsonb)'),
  ('identity.assisted_reset_dispatch', 'identity_assisted_recovery',
   'Story 2.9: fence the operation before the Auth Admin call and hold the account',
   'app.identity_recovery_check_dispatch(jsonb)',
   'app.identity_sys_reset_dispatch(uuid, uuid, jsonb)'),
  ('identity.assisted_reset_complete', 'identity_assisted_recovery',
   'Story 2.9: fenced completion of the Auth Admin password update',
   'app.identity_recovery_check_complete(jsonb)',
   'app.identity_sys_reset_complete(uuid, uuid, jsonb)');

-- ---------------------------------------------------------------------------------------------
-- Admin commands (1.4 envelope, the registered `identity` authorizer)
-- ---------------------------------------------------------------------------------------------

create function app.identity_recovery_case_json(p_case app.identity_recovery_cases)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'case_id', p_case.case_id,
    'revision', p_case.revision,
    'member_id', p_case.member_id,
    'display_name', (select m.display_name from app.identity_members m
                      where m.member_id = p_case.member_id),
    'member_revision', (select m.revision from app.identity_members m
                         where m.member_id = p_case.member_id),
    'case_state', p_case.case_state,
    'identity_check', p_case.identity_check,
    'evidence', to_jsonb(p_case.evidence),
    'opened_at', app.cmd_utc(p_case.opened_at),
    'opened_by_me', p_case.opened_by_account
                    = nullif(app.identity_request_claims() ->> 'sub', '')::uuid,
    'closed_at', case when p_case.closed_at is null then null else app.cmd_utc(p_case.closed_at) end,
    'outcome', p_case.outcome,
    'cancel_reason', p_case.cancel_reason,
    'account', app.identity_member_account_label(p_case.member_id),
    'link_problem', (select app.identity_recovery_link_problem(l)
                       from app.identity_account_links l where l.link_id = p_case.link_id),
    'held', app.identity_member_held(p_case.member_id),
    'grant', (select jsonb_build_object(
                'grant_id', g.grant_id,
                'state', case when g.grant_state = 'issued' and g.expires_at <= clock_timestamp()
                              then 'expired' else g.grant_state end,
                'issued_at', app.cmd_utc(g.issued_at),
                'expires_at', app.cmd_utc(g.expires_at),
                'end_reason', g.end_reason)
                from app.identity_recovery_grants g
               where g.case_id = p_case.case_id
               order by g.issued_at desc, g.grant_id
               limit 1),
    'operation', (select jsonb_build_object(
                    'operation_id', o.operation_id,
                    'state', case
                      when o.op_state = 'dispatched'
                           and o.dispatched_at <= clock_timestamp() - app.identity_recovery_stuck_after()
                        then 'stuck'
                      when o.op_state = 'pending'
                           and o.begun_at <= clock_timestamp() - app.identity_recovery_dispatch_window()
                        then 'obsolete'
                      else o.op_state end,
                    'begun_at', app.cmd_utc(o.begun_at),
                    'completed_at', case when o.completed_at is null then null
                                         else app.cmd_utc(o.completed_at) end)
                    from app.identity_recovery_operations o
                   where o.case_id = p_case.case_id
                   order by o.begun_at desc, o.operation_id
                   limit 1),
    'is_synthetic', p_case.is_synthetic);
$$;

create function app.identity_recovery_case_outcome(p_case_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_recovery_case',
    'aggregate_id', c.case_id,
    'revision', c.revision,
    'data', app.identity_recovery_case_json(c))
    from app.identity_recovery_cases c
   where c.case_id = p_case_id;
$$;

-- Validates {case_id, ...}, locks the case's link then the case at the expected revision, and
-- refuses the Admin's own member record or account.
create function app.identity_lock_recovery_case(
  p_payload jsonb,
  p_allowed text[],
  p_expected_revision bigint,
  p_actor_member uuid,
  p_actor_account uuid,
  out r_case app.identity_recovery_cases,
  out r_link app.identity_account_links
)
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_case_id uuid;
  v_link_id uuid;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  v_err := app.contract_uuid_error(p_payload -> 'case_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('case_id', v_err);
  end if;
  if 'identity_check' = any (p_allowed) then
    v_err := app.identity_check_value(p_payload -> 'identity_check', true);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  end if;
  if 'request_code' = any (p_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'request_code'), 'null') = 'null' then
      v_errors := v_errors || '{"request_code": "required"}';
    elsif jsonb_typeof(p_payload -> 'request_code') <> 'string'
          or upper(replace(replace(p_payload ->> 'request_code', ' ', ''), '-', ''))
             !~ '^[A-HJ-NP-Z2-9]{8}$' then
      v_errors := v_errors || '{"request_code": "invalid"}';
    end if;
  end if;
  if 'reason' = any (p_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') = 'null' then
      v_errors := v_errors || '{"reason": "required"}';
    elsif jsonb_typeof(p_payload -> 'reason') <> 'string'
          or p_payload ->> 'reason' not in ('identity_not_confirmed', 'member_withdrew',
                                            'opened_in_error') then
      v_errors := v_errors || '{"reason": "invalid"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_case_id := (p_payload ->> 'case_id')::uuid;
  select c.link_id into v_link_id from app.identity_recovery_cases c where c.case_id = v_case_id;
  if v_link_id is null then
    perform app.cmd_fail('not_found');
  end if;
  -- Lock order: the Identity link, then the case.
  select l.* into r_link from app.identity_account_links l where l.link_id = v_link_id for update;
  select c.* into r_case from app.identity_recovery_cases c where c.case_id = v_case_id for update;
  if r_case.member_id = p_actor_member or r_case.auth_user_id = p_actor_account then
    perform app.cmd_fail('forbidden', '{"case_id": "unsupported"}');
  end if;
  if r_case.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, r_case.revision);
  end if;
end;
$$;

-- identity.open_recovery_case {member_id, identity_check, evidence[]} (expected null): an Admin
-- other than the member records the identity check and the evidence seen.
create function app.identity_open_recovery_case(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_err text;
  v_evidence text[];
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_problem text;
  v_case app.identity_recovery_cases;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.open_recovery_case');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['member_id', 'identity_check', 'evidence']);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  v_err := app.identity_check_value(p_payload -> 'identity_check', true);
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('identity_check', v_err);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'evidence'), 'null') = 'null' then
    v_errors := v_errors || '{"evidence": "required"}';
  elsif jsonb_typeof(p_payload -> 'evidence') <> 'array'
        or jsonb_array_length(p_payload -> 'evidence') not between 1 and 4
        or exists (select 1 from jsonb_array_elements(p_payload -> 'evidence') e
                    where jsonb_typeof(e) <> 'string'
                       or e #>> '{}' not in ('photo_id', 'known_in_person', 'church_records',
                                             'leader_confirmation'))
        or (select count(distinct e) from jsonb_array_elements_text(p_payload -> 'evidence') e)
           <> jsonb_array_length(p_payload -> 'evidence') then
    v_errors := v_errors || '{"evidence": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if (p_payload ->> 'member_id')::uuid = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if not app.identity_assisted_recovery_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  select m.* into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  if v_link.link_id is null then
    perform app.cmd_fail('conflict', '{"member_id": "not_linked"}');
  end if;
  if v_link.auth_user_id = v_actor.account_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  v_problem := app.identity_recovery_link_problem(v_link);
  if v_problem is not null then
    perform app.cmd_fail('conflict', jsonb_build_object('member_id', v_problem));
  end if;
  if exists (select 1 from app.identity_recovery_cases c
              where c.link_id = v_link.link_id and c.case_state = 'open') then
    perform app.cmd_fail('conflict', '{"member_id": "open_case"}');
  end if;
  select array_agg(distinct e order by e) into v_evidence
    from jsonb_array_elements_text(p_payload -> 'evidence') e;
  insert into app.identity_recovery_cases (member_id, link_id, auth_user_id, identity_check,
                                           evidence, opened_by_member, opened_by_account,
                                           is_synthetic)
  values (v_member.member_id, v_link.link_id, v_link.auth_user_id,
          p_payload ->> 'identity_check', v_evidence, v_actor.member_id, v_actor.account_id,
          v_member.is_synthetic)
  returning * into v_case;
  perform app.identity_recovery_audit_add('case_opened', v_actor.member_id, v_actor.account_id,
    null, v_request, v_case.member_id, v_case.case_id, null, null, null, v_case.identity_check,
    v_case.evidence, v_case.revision);
  return app.identity_recovery_case_outcome(v_case.case_id);
end;
$$;

-- identity.issue_recovery_grant {case_id, request_code} (expected = case revision): binds the
-- member device's request into a single-use grant for the CURRENT link, binding and generation.
-- Every earlier issued grant of the account is superseded.
create function app.identity_issue_recovery_grant(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_locked record;
  v_case app.identity_recovery_cases;
  v_link app.identity_account_links;
  v_req app.identity_recovery_requests;
  v_grant app.identity_recovery_grants;
  v_problem text;
  v_code text;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.issue_recovery_grant');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  select x.* into v_locked from app.identity_lock_recovery_case(p_payload,
    array['case_id', 'request_code'], p_expected_revision, v_actor.member_id,
    v_actor.account_id) x;
  v_case := v_locked.r_case;
  v_link := v_locked.r_link;
  if v_case.case_state <> 'open' then
    perform app.cmd_fail('conflict', '{"case_id": "closed"}', v_case.revision);
  end if;
  if not app.identity_assisted_recovery_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if v_link.link_state = 'ended' or v_link.link_id <> v_case.link_id then
    perform app.cmd_fail('conflict', '{"case_id": "not_linked"}', v_case.revision);
  end if;
  v_problem := app.identity_recovery_link_problem(v_link);
  if v_problem is not null then
    perform app.cmd_fail('conflict', jsonb_build_object('case_id', v_problem), v_case.revision);
  end if;
  perform app.identity_recovery_expire_pending(v_case.auth_user_id, v_case.member_id);
  if app.identity_recovery_unresolved(v_case.auth_user_id, v_case.member_id) then
    perform app.cmd_fail('conflict', '{"case_id": "recovery_unresolved"}', v_case.revision);
  end if;
  v_code := upper(replace(replace(p_payload ->> 'request_code', ' ', ''), '-', ''));
  select r.* into v_req from app.identity_recovery_requests r
   where r.request_code = v_code and r.request_state = 'waiting'
     and r.expires_at > clock_timestamp()
     for update;
  if v_req.recovery_request_id is null then
    perform app.cmd_fail('conflict', '{"request_code": "unknown"}', v_case.revision);
  end if;
  -- The request must come from this member's approved phone username (cross-member refusal).
  if v_req.claimed_phone <> v_link.approved_phone then
    perform app.cmd_fail('conflict', '{"request_code": "mismatch"}', v_case.revision);
  end if;
  perform app.identity_recovery_end_grants(v_case.auth_user_id, 'superseded', 'reissued',
    v_actor.member_id, v_actor.account_id, null, v_request);
  update app.identity_recovery_requests r
     set request_state = 'bound', bound_at = clock_timestamp()
   where r.recovery_request_id = v_req.recovery_request_id;
  insert into app.identity_recovery_grants (case_id, recovery_request_id, member_id, link_id,
                                            auth_user_id, binding_revision,
                                            credential_generation, issued_by_member,
                                            issued_by_account, expires_at)
  values (v_case.case_id, v_req.recovery_request_id, v_case.member_id, v_link.link_id,
          v_link.auth_user_id, v_link.binding_revision, v_link.credential_generation,
          v_actor.member_id, v_actor.account_id,
          clock_timestamp() + app.identity_recovery_grant_ttl())
  returning * into v_grant;
  update app.identity_recovery_cases c set revision = c.revision + 1
   where c.case_id = v_case.case_id
  returning * into v_case;
  perform app.identity_recovery_audit_add('grant_issued', v_actor.member_id, v_actor.account_id,
    null, v_request, v_case.member_id, v_case.case_id, v_grant.grant_id, null, null, null, null,
    v_case.revision);
  return app.identity_recovery_case_outcome(v_case.case_id);
end;
$$;

-- identity.cancel_recovery_case {case_id, reason} (expected = case revision).
create function app.identity_cancel_recovery_case(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_locked record;
  v_case app.identity_recovery_cases;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.cancel_recovery_case');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  select x.* into v_locked from app.identity_lock_recovery_case(p_payload,
    array['case_id', 'reason'], p_expected_revision, v_actor.member_id, v_actor.account_id) x;
  v_case := v_locked.r_case;
  if v_case.case_state <> 'open' then
    perform app.cmd_fail('conflict', '{"case_id": "closed"}', v_case.revision);
  end if;
  if exists (select 1 from app.identity_recovery_operations o
              where o.case_id = v_case.case_id and o.op_state in ('dispatched', 'uncertain')) then
    perform app.cmd_fail('conflict', '{"case_id": "recovery_unresolved"}', v_case.revision);
  end if;
  perform app.identity_recovery_end_grants(v_case.auth_user_id, 'cancelled', 'case_cancelled',
    v_actor.member_id, v_actor.account_id, null, v_request);
  update app.identity_recovery_cases c
     set case_state = 'cancelled', outcome = 'cancelled', cancel_reason = p_payload ->> 'reason',
         closed_at = clock_timestamp(), closed_by_member = v_actor.member_id,
         closed_by_account = v_actor.account_id, revision = c.revision + 1
   where c.case_id = v_case.case_id
  returning * into v_case;
  perform app.identity_recovery_audit_add('case_cancelled', v_actor.member_id, v_actor.account_id,
    null, v_request, v_case.member_id, v_case.case_id, null, null, v_case.cancel_reason, null,
    null, v_case.revision);
  return app.identity_recovery_case_outcome(v_case.case_id);
end;
$$;

-- identity.reconcile_recovery_operation {case_id, identity_check} (expected = case revision):
-- an uncertain or stuck operation is closed after an identity check. Every Auth session of the
-- account is revoked; the operation's hold stays until the member's next successful reset.
create function app.identity_reconcile_recovery_operation(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_locked record;
  v_case app.identity_recovery_cases;
  v_op app.identity_recovery_operations;
  v_sessions integer;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.reconcile_recovery_operation');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  select x.* into v_locked from app.identity_lock_recovery_case(p_payload,
    array['case_id', 'identity_check'], p_expected_revision, v_actor.member_id,
    v_actor.account_id) x;
  v_case := v_locked.r_case;
  select o.* into v_op from app.identity_recovery_operations o
   where o.case_id = v_case.case_id
     and (o.op_state = 'uncertain'
          or (o.op_state = 'dispatched'
              and o.dispatched_at <= clock_timestamp() - app.identity_recovery_stuck_after()))
     for update;
  if v_op.operation_id is null then
    perform app.cmd_fail('conflict', '{"case_id": "nothing_to_reconcile"}', v_case.revision);
  end if;
  v_sessions := app.identity_revoke_auth_sessions(v_op.auth_user_id);
  update app.identity_recovery_operations o
     set op_state = 'reconciled', reconciled_at = clock_timestamp(),
         completed_at = coalesce(o.completed_at, clock_timestamp()),
         reconciled_by_member = v_actor.member_id, reconciled_by_account = v_actor.account_id,
         reconcile_identity_check = p_payload ->> 'identity_check', sessions_revoked = v_sessions
   where o.operation_id = v_op.operation_id;
  update app.identity_recovery_cases c set revision = c.revision + 1
   where c.case_id = v_case.case_id
  returning * into v_case;
  v_revision := app.identity_bump_member(v_case.member_id);
  perform app.identity_recovery_audit_add('operation_reconciled', v_actor.member_id,
    v_actor.account_id, null, v_request, v_case.member_id, v_case.case_id, v_op.grant_id,
    v_op.operation_id, null, p_payload ->> 'identity_check', null, v_revision, v_sessions);
  perform app.identity_dispatch_lifecycle('sessions_revoked', v_case.member_id, v_revision);
  return app.identity_recovery_case_outcome(v_case.case_id);
end;
$$;

create function app.identity_recovery_in_scope(p_actor uuid, p_aggregate_type text,
                                               p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and p_aggregate_type = 'identity_recovery_case'
     and exists (select 1 from app.identity_recovery_cases c where c.case_id = p_aggregate_id);
$$;

create function app.identity_recovery_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'identity.open_recovery_case'
        then 'app.identity_open_recovery_case(uuid, bigint, jsonb)'::regprocedure
      when 'identity.issue_recovery_grant'
        then 'app.identity_issue_recovery_grant(uuid, bigint, jsonb)'::regprocedure
      when 'identity.cancel_recovery_case'
        then 'app.identity_cancel_recovery_case(uuid, bigint, jsonb)'::regprocedure
      when 'identity.reconcile_recovery_operation'
        then 'app.identity_reconcile_recovery_operation(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_recovery_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.open_recovery_case'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_recovery_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_recovery_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_recovery_command($1);
$$;

comment on function api.identity_recovery_command(jsonb) is
  'Story 2.9: staff-assisted recovery cases, setup grants and reconciliation (1.4 envelope).';

-- The registered `identity` authorizer: the 2.8 body with the four recovery commands added to
-- the Admin branch (every earlier command kept).
create or replace function app.identity_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') in ('identity.submit_application',
                                                'identity.correct_application') then
    return app.identity_authorize_application_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') in ('identity.propose_recovery_email',
                                                'identity.request_credential_change') then
    return app.identity_authorize_member_credential_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') in ('identity.withdraw_recovery_email',
                                                'identity.withdraw_credential_change') then
    return app.identity_authorize_member_withdraw_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') not in (
       'identity.grant_role', 'identity.revoke_role', 'identity.grant_scope',
       'identity.revoke_scope',
       'identity.approve_application', 'identity.link_application',
       'identity.request_application_details', 'identity.reject_application',
       'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username',
       'identity.approve_recovery_email', 'identity.reject_recovery_email',
       'identity.approve_credential_change', 'identity.reject_credential_change',
       'identity.place_hold', 'identity.release_hold', 'identity.restore_credentials',
       'identity.accept_credentials',
       'identity.open_recovery_case', 'identity.issue_recovery_grant',
       'identity.cancel_recovery_case', 'identity.reconcile_recovery_operation') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant('admin', null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.role = 'admin' and g.revoked_at is null
     for share;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Read (Admin): open cases and those closed in the last 7 days. Never a code, digest or secret.
-- ---------------------------------------------------------------------------------------------

create function app.identity_admin_recovery_cases()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_member uuid;
  v_link_id uuid;
  v_cases jsonb;
begin
  select g.member_id, g.link_id into v_actor_member, v_link_id
    from app.identity_require_grant('admin', null, null) g;
  select coalesce(jsonb_agg(app.identity_recovery_case_json(x)
                            || jsonb_build_object('own_member', x.member_id = v_actor_member)
                            order by x.case_state <> 'open', x.opened_at desc, x.case_id),
                  '[]'::jsonb)
    into v_cases
    from (select c.* from app.identity_recovery_cases c
           where c.case_state = 'open' or c.closed_at > clock_timestamp() - interval '7 days'
           order by c.case_state <> 'open', c.opened_at desc, c.case_id
           limit 100) x;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object('cases', v_cases,
                            'accepting', app.identity_assisted_recovery_open());
end;
$$;

create function api.identity_admin_recovery_cases()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_recovery_cases();
$$;

comment on function api.identity_admin_recovery_cases() is
  'Story 2.9: Admin-only assisted-recovery cases with grant and operation states (no codes, '
  'digests or secrets).';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_assisted_recovery_open(),
  app.identity_recovery_request_ttl(),
  app.identity_recovery_grant_ttl(),
  app.identity_recovery_dispatch_window(),
  app.identity_recovery_stuck_after(),
  app.identity_recovery_requests_per_phone_hour(),
  app.identity_recovery_requests_per_ten_minutes(),
  app.identity_recovery_unresolved(uuid, uuid),
  app.identity_recovery_expire_pending(uuid, uuid),
  app.identity_recovery_link_problem(app.identity_account_links),
  app.identity_recovery_audit_add(text, uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, text,
                                  text, text[], bigint, integer),
  app.identity_recovery_end_grants(uuid, text, text, uuid, uuid, uuid, uuid),
  app.identity_recovery_new_code(),
  app.identity_member_reset_since(uuid, timestamptz),
  app.identity_password_unreviewed(uuid),
  app.identity_on_link_insert_recovery_guard(),
  app.identity_recovery_payload_check(text, jsonb),
  app.identity_recovery_check_request(jsonb),
  app.identity_recovery_check_status(jsonb),
  app.identity_recovery_check_begin(jsonb),
  app.identity_recovery_check_dispatch(jsonb),
  app.identity_recovery_check_complete(jsonb),
  app.identity_sys_recovery_request(uuid, uuid, jsonb),
  app.identity_sys_recovery_status(uuid, uuid, jsonb),
  app.identity_sys_reset_begin(uuid, uuid, jsonb),
  app.identity_sys_reset_dispatch(uuid, uuid, jsonb),
  app.identity_sys_reset_complete(uuid, uuid, jsonb),
  app.identity_recovery_case_json(app.identity_recovery_cases),
  app.identity_recovery_case_outcome(uuid),
  app.identity_lock_recovery_case(jsonb, text[], bigint, uuid, uuid),
  app.identity_open_recovery_case(uuid, bigint, jsonb),
  app.identity_issue_recovery_grant(uuid, bigint, jsonb),
  app.identity_cancel_recovery_case(uuid, bigint, jsonb),
  app.identity_reconcile_recovery_operation(uuid, bigint, jsonb),
  app.identity_recovery_in_scope(uuid, text, uuid),
  app.identity_recovery_command(jsonb),
  api.identity_recovery_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_admin_recovery_cases(),
  api.identity_admin_recovery_cases(),
  app.sys_execute(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.identity_recovery_command(jsonb) to authenticated;
grant execute on function api.identity_recovery_command(jsonb) to authenticated;
grant execute on function app.identity_admin_recovery_cases() to authenticated;
grant execute on function api.identity_admin_recovery_cases() to authenticated;

notify pgrst, 'reload schema';
