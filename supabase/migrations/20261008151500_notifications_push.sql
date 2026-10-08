-- Story 3.6: send generic expiring push through FCM and retire invalid tokens (AD-8, AD-13,
-- AD-18; epic 3 requirements N7, N4).
--
--   * Member-push jobs (story 3.5, one per inbox item of an active linked account that allows
--     push and has a live token) get their own lease, fencing token (the 3.4 sequence), lapse
--     count, failure count and backoff, under the central worker policy.
--   * Four system commands of purpose `notifications_worker`, all rules in SQL (the Edge Function
--     is transport):
--       notifications.push_claim   {limit?}  count lapsed push leases, expire push jobs, and (only
--                                            while the operator switch `push_enabled` is on)
--                                            lease a bounded batch;
--       notifications.push_prepare {push_job_id, lease_token}  recheck NOW (lease, expiry, source
--                                            current and actionable, recipient eligible, schedule,
--                                            snooze, current route to the same account, push
--                                            setting) and answer either a terminal outcome or the
--                                            generic message (the contract's fixed title and body,
--                                            the item id as the only data and the stable
--                                            notification id, the remaining TTL) with the live
--                                            targets still owed;
--       notifications.push_record  {push_job_id, lease_token, results}  one attempt row per
--                                            device answer (`accepted`, `token_invalid`,
--                                            `rejected`, `transient`), retire invalid tokens, then
--                                            end the push job (`accepted` / `failed` / `obsolete`)
--                                            or retry it with backoff;
--       notifications.push_release {push_job_id, lease_token}  give back an unused lease.
--     Provider acceptance is recorded as `accepted`, never as delivery, reading or consent.
--   * The 1.9 system kernel learns `retain_result`: the receipt of a kind registered with false
--     (push_prepare, whose answer carries device tokens) keeps only a marker, so no token is
--     stored in `app.sys_receipts`; a replay of such a request is a conflict.
--   * `push_enabled` (worker settings, default false, operator-set) is the push switch. With it
--     off nothing is claimed for push and pending push jobs expire; the inbox is unaffected.
--   * Push attempts live in `app.notifications_attempts` (channel `push`), so the story 3.5
--     deletion hook and its rows file already erase them (no new rows file).
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- System kernel (platform, 1.9): result retention per command kind
-- ---------------------------------------------------------------------------------------------

alter table app.sys_command_kinds
  add column retain_result boolean not null default true;

comment on column app.sys_command_kinds.retain_result is
  'Story 3.6: false = the answer is returned once and its receipt keeps only a marker (for '
  'answers that carry personal or secret values, such as device tokens); a replay is a conflict.';

-- Replaces the story 2.9 kernel body (same signature, grants and audit). Only change: a kind
-- with retain_result = false stores a marker instead of its answer and is never replayed.
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
      if v_existing.payload_hash = v_hash and v_existing.result is not null
         and coalesce(v_kind.retain_result, true) then
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
    -- Story 3.6: a kind registered with retain_result = false (an answer that carries device
    -- tokens) keeps only a marker in its receipt; a replay of it is then a conflict.
    update app.sys_receipts r
       set result = case when coalesce(v_kind.retain_result, true) then v_result
                         else jsonb_build_object('request_id', v_request_id, 'retained', false) end
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
-- Push policy, push-job leases and push attempts (owner: notifications)
-- ---------------------------------------------------------------------------------------------

alter table app.notifications_worker_settings
  add column push_enabled boolean not null default false;

comment on column app.notifications_worker_settings.push_enabled is
  'Story 3.6: operator switch for member push through FCM (default off). Off: no push job is '
  'claimed and pending ones expire; the durable inbox is unaffected.';

-- The lease fields record the push job's LAST lease, as for notification jobs (story 3.4).
alter table app.notifications_push_jobs
  add column lease_token bigint check (lease_token >= 1),
  add column lease_principal uuid,
  add column lease_request uuid,
  add column lease_expires_at timestamptz,
  add column failed_attempts integer not null default 0 check (failed_attempts >= 0),
  add column lapsed_attempts integer not null default 0 check (lapsed_attempts >= 0),
  add column last_failed_at timestamptz,
  add check ((lease_token is null) = (lease_expires_at is null)
             and (lease_token is null) = (lease_principal is null)
             and (lease_token is null) = (lease_request is null));

create index notifications_push_jobs_due on app.notifications_push_jobs (created_at)
  where push_state = 'pending';

-- Push attempts: channel `push`, the push job and (for a provider answer) the device. No foreign
-- keys, so the 3.5 deletion order (attempts by job first) stays valid. provider_status is the
-- HTTP status of the provider's answer, provider_code its error code (never a token or text).
alter table app.notifications_attempts
  add column push_job_id uuid,
  add column device_id uuid,
  add column provider_status integer check (provider_status between 100 and 599),
  add column provider_code text check (provider_code ~ '^[A-Z][A-Z0-9_]{0,39}$'),
  add check ((channel = 'push') = (push_job_id is not null)),
  add check (device_id is null or push_job_id is not null);

create index notifications_attempts_push on app.notifications_attempts (push_job_id, lease_token)
  where push_job_id is not null;

comment on column app.notifications_attempts.push_job_id is
  'Story 3.6: the member-push job of a `push` attempt. Outcomes: accepted (the provider accepted '
  'the message; never delivery), token_invalid (token retired), rejected, transient, and the '
  'push job outcomes of prepare/claim (fenced, expired, obsolete, failed, lapsed, exhausted).';

-- ---------------------------------------------------------------------------------------------
-- Push helpers
-- ---------------------------------------------------------------------------------------------

-- Ends a pending push job and its lease.
create function app.notifications_push_finish(p_push_job_id uuid, p_state text, p_reason text)
returns void
language sql
set search_path = ''
as $$
  update app.notifications_push_jobs p
     set push_state = p_state, finish_reason = p_reason, finished_at = clock_timestamp(),
         lease_expires_at = case when p.lease_expires_at is null then null
                                 else least(p.lease_expires_at, now()) end
   where p.push_job_id = p_push_job_id and p.push_state = 'pending';
$$;

-- True when the provider accepted the push job's message for at least one device.
create function app.notifications_push_accepted_any(p_push_job_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.notifications_attempts a
                  where a.push_job_id = p_push_job_id and a.outcome = 'accepted');
$$;

-- The live devices of the push job's account and member still owed this message: no `accepted`
-- or `rejected` answer for this push job yet. At most 10 (the per-account limit).
create function app.notifications_push_owed(p_push app.notifications_push_jobs)
returns setof app.notifications_device_tokens
language sql
stable
set search_path = ''
as $$
  select t.* from app.notifications_device_tokens t
   where t.account_id = p_push.account_id and t.member_id = p_push.recipient_member_id
     and t.retired_at is null
     and not exists (select 1 from app.notifications_attempts a
                      where a.push_job_id = p_push.push_job_id and a.device_id = t.device_id
                        and a.outcome in ('accepted', 'rejected'))
   order by t.refreshed_at desc, t.device_id
   limit 10;
$$;

-- Ends a push job whose retries are used up: `accepted` when some device accepted it, else
-- `failed`, both with finish reason `attempts_exhausted`.
create function app.notifications_push_exhaust(p_push_job_id uuid)
returns void
language sql
set search_path = ''
as $$
  select app.notifications_push_finish(p_push_job_id,
           case when app.notifications_push_accepted_any(p_push_job_id) then 'accepted' else 'failed' end,
           'attempts_exhausted');
$$;

create function app.notifications_push_attempt_row(p_push app.notifications_push_jobs, p_token bigint,
                                                   p_principal uuid, p_request uuid, p_outcome text,
                                                   p_reason text, p_sqlstate text)
returns void
language sql
set search_path = ''
as $$
  insert into app.notifications_attempts (job_id, channel, push_job_id, lease_token, principal_id,
                                          request_id, outcome, finish_reason, error_sqlstate)
  values (p_push.job_id, 'push', p_push.push_job_id, p_token, p_principal, p_request, p_outcome,
          p_reason, p_sqlstate);
$$;

-- ---------------------------------------------------------------------------------------------
-- Claim, release
-- ---------------------------------------------------------------------------------------------

-- 1. A lapsed push lease whose holder recorded nothing (the worker crashed or timed out after
--    prepare, possibly after the provider accepted) is counted once as `lapsed` and freed; the
--    next send reuses the same notification id. At max_attempts (failures plus lapses) it ends
--    (`attempts_exhausted`).
-- 2. Pending push jobs past their expiry and not under a live lease end `obsolete` (`expired`).
-- 3. Only while push_enabled: up to p_limit pending push jobs are leased (fewest failures first,
--    then oldest), skipping live leases, jobs backing off and rows another worker holds.
-- Returns {jobs: [{push_job_id, lease_token}], claimed, reclaimed, expired, lease_seconds,
-- push_enabled}.
create function app.notifications_push_claim(p_principal uuid, p_request uuid, p_limit integer)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_push app.notifications_push_jobs;
  v_token bigint;
  v_exhausted boolean;
  v_jobs jsonb := '[]'::jsonb;
  v_claimed integer := 0;
  v_reclaimed integer := 0;
  v_expired integer := 0;
begin
  for v_push in
    select p.* from app.notifications_push_jobs p
     where p.push_state = 'pending' and p.lease_token is not null and p.lease_expires_at <= now()
       and not exists (select 1 from app.notifications_attempts a
                        where a.push_job_id = p.push_job_id and a.lease_token = p.lease_token
                          and a.principal_id = p.lease_principal and a.outcome <> 'fenced')
     order by p.lease_expires_at, p.push_job_id
     limit 500
     for update skip locked
  loop
    v_exhausted := v_push.failed_attempts + v_push.lapsed_attempts + 1 >= v_settings.max_attempts;
    perform app.notifications_push_attempt_row(v_push, v_push.lease_token, v_push.lease_principal,
      v_push.lease_request, case when v_exhausted then 'exhausted' else 'lapsed' end,
      case when v_exhausted then 'attempts_exhausted' end, null);
    update app.notifications_push_jobs p
       set lapsed_attempts = p.lapsed_attempts + 1, lease_token = null, lease_principal = null,
           lease_request = null, lease_expires_at = null
     where p.push_job_id = v_push.push_job_id;
    if v_exhausted then
      perform app.notifications_push_exhaust(v_push.push_job_id);
    end if;
    v_reclaimed := v_reclaimed + 1;
  end loop;

  for v_push in
    select p.* from app.notifications_push_jobs p
     where p.push_state = 'pending' and p.expires_at <= now()
       and (p.lease_expires_at is null or p.lease_expires_at <= now())
     order by p.expires_at, p.push_job_id
     limit 500
     for update skip locked
  loop
    perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', 'expired');
    v_expired := v_expired + 1;
  end loop;

  if v_settings.push_enabled then
    for v_push in
      select p.* from app.notifications_push_jobs p
       where p.push_state = 'pending' and p.expires_at > now()
         and (p.lease_expires_at is null or p.lease_expires_at <= now())
         and (p.last_failed_at is null
              or p.last_failed_at <= now() - make_interval(
                   secs => app.notifications_backoff_seconds(p.failed_attempts, v_settings)))
       order by p.failed_attempts, p.created_at, p.push_job_id
       limit greatest(p_limit, 0)
       for update skip locked
    loop
      v_token := nextval('app.notifications_lease_token_seq');
      update app.notifications_push_jobs p
         set lease_token = v_token, lease_principal = p_principal, lease_request = p_request,
             lease_expires_at = now() + make_interval(secs => v_settings.lease_seconds)
       where p.push_job_id = v_push.push_job_id;
      v_jobs := v_jobs || jsonb_build_object('push_job_id', v_push.push_job_id, 'lease_token', v_token);
      v_claimed := v_claimed + 1;
    end loop;
  end if;

  return jsonb_build_object('jobs', v_jobs, 'claimed', v_claimed, 'reclaimed', v_reclaimed,
                            'expired', v_expired, 'lease_seconds', v_settings.lease_seconds,
                            'push_enabled', v_settings.push_enabled);
end;
$$;

-- Gives back a live push lease its holder will not use. No attempt is counted.
create function app.notifications_push_release(p_principal uuid, p_push_job_id uuid, p_token bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  update app.notifications_push_jobs p
     set lease_token = null, lease_principal = null, lease_request = null, lease_expires_at = null
   where p.push_job_id = p_push_job_id and p.push_state = 'pending' and p.lease_token = p_token
     and p.lease_principal = p_principal and p.lease_expires_at > now();
  return jsonb_build_object('released', found);
end;
$$;

-- Counts a transient failure of a push job: failure + 1, lease ended, backoff from now; at
-- max_attempts the push job ends (`attempts_exhausted`). Returns `failed` or `exhausted`.
create function app.notifications_push_fail(p_push app.notifications_push_jobs,
                                            p_settings app.notifications_worker_settings)
returns text
language plpgsql
set search_path = ''
as $$
begin
  update app.notifications_push_jobs p
     set failed_attempts = p.failed_attempts + 1, last_failed_at = clock_timestamp(),
         lease_expires_at = least(p.lease_expires_at, now())
   where p.push_job_id = p_push.push_job_id;
  if p_push.failed_attempts + 1 + p_push.lapsed_attempts >= p_settings.max_attempts then
    perform app.notifications_push_exhaust(p_push.push_job_id);
    return 'exhausted';
  end if;
  return 'failed';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Prepare: the recheck right before the provider call
-- ---------------------------------------------------------------------------------------------

-- Order of checks: the token must be the push job's current one, held by this principal
-- (`fenced`); a push job that already ended answers `cancelled` or `finished`; a lapsed lease is
-- `fenced`; past its expiry `expired`. Then, rechecked now, first failing rule wins (the push job
-- ends `obsolete` with the reason; the inbox item is untouched): no contract (`no_contract`),
-- source not current (`source_changed`), not actionable (`not_actionable`), the source no longer
-- admits the recipient (`recipient_ineligible`), the schedule ended/moved/cancelled the kind or
-- the member responded (`schedule_changed`), the member snoozed the item (`snoozed`), the member
-- no longer routes to this account (`recipient_changed`), push turned off for the category
-- (`push_disabled`), no live device left (`no_live_token`; `accepted` when some device already
-- accepted it). A raising check is transient (`failed`, backoff). Otherwise the answer is
-- {outcome: "send", message: {notification_id, item_id, title, body, ttl_seconds,
-- expires_at_epoch}, targets: [{device_id, platform, token}]} and no attempt row is written yet
-- (push_record writes one per device answer). Every other outcome writes one attempt row.
create function app.notifications_push_prepare(p_principal uuid, p_request uuid, p_push_job_id uuid,
                                               p_token bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_push app.notifications_push_jobs;
  v_job app.notifications_jobs;
  v_contract app.contract_reminder_contracts;
  v_state jsonb;
  v_schedule app.notifications_schedules;
  v_route record;
  v_recipient uuid;
  v_targets jsonb;
  v_ttl bigint;
  v_outcome text;
  v_reason text;
  v_sqlstate text;
begin
  -- AD-2 lock order: Identity (the member row) before any Notifications lock.
  select p.recipient_member_id into v_recipient from app.notifications_push_jobs p
   where p.push_job_id = p_push_job_id;
  if v_recipient is not null then
    perform 1 from app.identity_members m where m.member_id = v_recipient for key share;
  end if;
  select p.* into v_push from app.notifications_push_jobs p where p.push_job_id = p_push_job_id for update;
  if not found then
    return '{"outcome": "not_found"}'::jsonb;
  end if;

  if v_push.lease_token is distinct from p_token or v_push.lease_principal is distinct from p_principal then
    v_outcome := 'fenced';
  elsif v_push.push_state <> 'pending' then
    v_outcome := case when v_push.push_state = 'cancelled' then 'cancelled' else 'finished' end;
    v_reason := v_push.finish_reason;
  elsif v_push.lease_expires_at <= now() then
    v_outcome := 'fenced';
  elsif v_push.expires_at <= now() + interval '1 second' then
    v_outcome := 'expired';
    v_reason := 'expired';
    perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
  else
    begin
      select j.* into v_job from app.notifications_jobs j where j.job_id = v_push.job_id;
      select c.* into v_contract from app.contract_reminder_contracts c
       where c.source_type = v_job.source_type and c.reminder_kind = v_job.reminder_kind;
      if not found then
        v_reason := 'no_contract';
      else
        v_state := app.contract_check_reminder(app.notifications_job_key(v_job));
        if not (v_state ->> 'current')::boolean then
          v_reason := 'source_changed';
        elsif not (v_state ->> 'actionable')::boolean then
          v_reason := 'not_actionable';
        elsif not (v_state ->> 'recipient_eligible')::boolean then
          v_reason := 'recipient_ineligible';
        end if;
      end if;
      if v_reason is null and v_job.schedule_id is not null then
        select s.* into v_schedule from app.notifications_schedules s
         where s.schedule_id = v_job.schedule_id;
        if v_schedule.schedule_state is distinct from 'active'
           or v_schedule.source_revision <> v_job.source_revision
           or v_job.reminder_kind = any (v_schedule.cancelled_kinds)
           or (coalesce((v_schedule.intent ->> 'responded')::boolean, false)
               and v_job.reminder_kind = any (app.notifications_response_kinds(v_schedule.kinds))) then
          v_reason := 'schedule_changed';
        end if;
      end if;
      if v_reason is null and exists (select 1 from app.notifications_jobs s
                                       where s.snoozed_from_item_id = v_push.item_id) then
        v_reason := 'snoozed';
      end if;
      if v_reason is null then
        select r.* into v_route from app.notifications_recipient_route(v_push.recipient_member_id) r;
        if v_route.route is distinct from 'member' or v_route.account_id is distinct from v_push.account_id then
          v_reason := 'recipient_changed';
        end if;
      end if;
      if v_reason is null and exists (
           select 1 from app.notifications_push_settings s
            where s.account_id = v_push.account_id and s.member_id = v_push.recipient_member_id
              and s.source_type = v_job.source_type and s.reminder_kind = v_job.reminder_kind
              and not s.push_enabled) then
        v_reason := 'push_disabled';
      end if;
      if v_reason is not null then
        v_outcome := 'obsolete';
        perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
      else
        select coalesce(jsonb_agg(jsonb_build_object('device_id', t.device_id, 'platform', t.platform,
                                                     'token', t.token)), '[]'::jsonb)
          into v_targets
          from app.notifications_push_owed(v_push) t;
        if v_targets = '[]'::jsonb then
          if app.notifications_push_accepted_any(v_push.push_job_id) then
            v_outcome := 'accepted';
            v_reason := 'accepted';
            perform app.notifications_push_finish(v_push.push_job_id, 'accepted', v_reason);
          else
            v_outcome := 'obsolete';
            v_reason := 'no_live_token';
            perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
          end if;
        else
          v_ttl := least(floor(extract(epoch from (v_push.expires_at - now()))), 2419200)::bigint;
          return jsonb_build_object(
            'outcome', 'send',
            'message', jsonb_build_object(
              'notification_id', v_push.item_id, 'item_id', v_push.item_id,
              'title', v_contract.title, 'body', v_contract.body,
              'ttl_seconds', v_ttl,
              'expires_at_epoch', floor(extract(epoch from v_push.expires_at))::bigint),
            'targets', v_targets);
        end if;
      end if;
    exception
      when query_canceled then
        v_sqlstate := sqlstate;
      when others then
        v_sqlstate := sqlstate;
    end;
    if v_sqlstate is not null then
      raise log 'notifications.push_prepare recheck failed: sqlstate %', v_sqlstate;
      v_reason := null;
      v_outcome := app.notifications_push_fail(v_push, v_settings);
      if v_outcome = 'exhausted' then
        v_reason := 'attempts_exhausted';
      end if;
    end if;
  end if;

  perform app.notifications_push_attempt_row(v_push, p_token, p_principal, p_request, v_outcome,
    case when v_outcome in ('fenced', 'failed') then null else v_reason end, v_sqlstate);
  return jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'finish_reason',
    case when v_outcome in ('fenced', 'failed') then null else v_reason end));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Record: the provider's answers
-- ---------------------------------------------------------------------------------------------

-- p_results: [{device_id, result, provider_status?, provider_code?}] with result one of
-- accepted (the provider accepted the message: never delivery or reading), token_invalid (the
-- provider says the token is unregistered or not ours: the device is retired
-- `provider_invalid`), rejected (refused for this device, token kept, not retried) and transient
-- (quota, provider error, timeout: retried with backoff and the same notification id). A stale
-- token (`fenced`) records one row and changes nothing. Answers for devices that are not the push
-- job's account and member are ignored. Then, while the push job is pending: nothing owed ->
-- `accepted` (some device accepted), `failed` (`provider_rejected`) or `obsolete`
-- (`no_live_token`); a transient answer -> `retry` with backoff (`exhausted` at max_attempts);
-- otherwise (a device registered meanwhile) -> `retry` at once. Returns {outcome, finish_reason?,
-- recorded, retired}.
create function app.notifications_push_record(p_principal uuid, p_request uuid, p_push_job_id uuid,
                                              p_token bigint, p_results jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_push app.notifications_push_jobs;
  v_recipient uuid;
  v_r jsonb;
  v_device app.notifications_device_tokens;
  v_recorded integer := 0;
  v_retired integer := 0;
  v_transient boolean := false;
  v_rejected boolean;
  v_outcome text;
  v_reason text;
begin
  select p.recipient_member_id into v_recipient from app.notifications_push_jobs p
   where p.push_job_id = p_push_job_id;
  if v_recipient is not null then
    perform 1 from app.identity_members m where m.member_id = v_recipient for key share;
  end if;
  select p.* into v_push from app.notifications_push_jobs p where p.push_job_id = p_push_job_id for update;
  if not found then
    return '{"outcome": "not_found"}'::jsonb;
  end if;
  if v_push.lease_token is distinct from p_token or v_push.lease_principal is distinct from p_principal then
    perform app.notifications_push_attempt_row(v_push, p_token, p_principal, p_request, 'fenced', null, null);
    return jsonb_build_object('outcome', 'fenced', 'recorded', 0, 'retired', 0);
  end if;

  for v_r in select e from jsonb_array_elements(p_results) e loop
    select t.* into v_device from app.notifications_device_tokens t
     where t.device_id = (v_r ->> 'device_id')::uuid and t.account_id = v_push.account_id
       and t.member_id = v_push.recipient_member_id
     for update;
    if not found then
      continue;
    end if;
    insert into app.notifications_attempts (job_id, channel, push_job_id, device_id, lease_token,
                                            principal_id, request_id, outcome, provider_status,
                                            provider_code)
    values (v_push.job_id, 'push', v_push.push_job_id, v_device.device_id, p_token, p_principal,
            p_request, v_r ->> 'result', (v_r ->> 'provider_status')::integer, v_r ->> 'provider_code');
    v_recorded := v_recorded + 1;
    if v_r ->> 'result' = 'token_invalid' and v_device.retired_at is null then
      update app.notifications_device_tokens t
         set retired_at = clock_timestamp(), retire_reason = 'provider_invalid', revision = t.revision + 1
       where t.device_id = v_device.device_id;
      v_retired := v_retired + 1;
    elsif v_r ->> 'result' = 'transient' then
      v_transient := true;
    end if;
  end loop;

  if v_push.push_state <> 'pending' then
    return jsonb_build_object('outcome', case when v_push.push_state = 'cancelled' then 'cancelled'
                                              else 'finished' end,
                              'finish_reason', v_push.finish_reason,
                              'recorded', v_recorded, 'retired', v_retired);
  end if;

  if not exists (select 1 from app.notifications_push_owed(v_push)) then
    if app.notifications_push_accepted_any(v_push.push_job_id) then
      v_outcome := 'accepted';
      v_reason := 'accepted';
    else
      v_rejected := exists (select 1 from app.notifications_attempts a
                             where a.push_job_id = v_push.push_job_id and a.outcome = 'rejected');
      v_outcome := case when v_rejected then 'failed' else 'obsolete' end;
      v_reason := case when v_rejected then 'provider_rejected' else 'no_live_token' end;
    end if;
    perform app.notifications_push_finish(v_push.push_job_id, v_outcome, v_reason);
  elsif v_transient then
    v_outcome := app.notifications_push_fail(v_push, v_settings);
    v_outcome := case when v_outcome = 'exhausted' then 'exhausted' else 'retry' end;
    if v_outcome = 'exhausted' then
      v_reason := 'attempts_exhausted';
    end if;
  else
    -- Nothing failed but a device is still owed (registered meanwhile, or its answer was not
    -- this push job's device): free the lease without counting anything; claimed again at once.
    update app.notifications_push_jobs p
       set lease_token = null, lease_principal = null, lease_request = null, lease_expires_at = null
     where p.push_job_id = v_push.push_job_id;
    v_outcome := 'retry';
  end if;
  return jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'finish_reason', v_reason,
                                              'recorded', v_recorded, 'retired', v_retired));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- System commands (purpose notifications_worker)
-- ---------------------------------------------------------------------------------------------

-- Payload of push_prepare and push_release: {push_job_id: uuid, lease_token: integer >= 1}.
create function app.notifications_check_push(p_payload jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                    where k not in ('push_job_id', 'lease_token')), '{}'::jsonb)
      || jsonb_strip_nulls(jsonb_build_object(
           'push_job_id', app.contract_uuid_error(p_payload -> 'push_job_id'),
           'lease_token', case when app.contract_integer_in(p_payload -> 'lease_token', 1, 9007199254740991)
                               then null else 'invalid' end));
$$;

-- One provider answer: {device_id, result, provider_status?: 100..599, provider_code?: A-Z token}.
create function app.notifications_push_result_error(p_result jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_result) is distinct from 'object' then 'invalid'
    when exists (select 1 from jsonb_object_keys(p_result) k
                  where k not in ('device_id', 'result', 'provider_status', 'provider_code')) then 'invalid'
    when app.contract_uuid_error(p_result -> 'device_id') is not null then 'invalid'
    when jsonb_typeof(p_result -> 'result') is distinct from 'string'
         or (p_result ->> 'result') not in ('accepted', 'token_invalid', 'rejected', 'transient') then 'invalid'
    when p_result ? 'provider_status'
         and not app.contract_integer_in(p_result -> 'provider_status', 100, 599) then 'invalid'
    when p_result ? 'provider_code'
         and (jsonb_typeof(p_result -> 'provider_code') is distinct from 'string'
              or (p_result ->> 'provider_code') !~ '^[A-Z][A-Z0-9_]{0,39}$') then 'invalid'
  end;
$$;

-- Payload of push_record: {push_job_id, lease_token, results: 1..10 answers, one per device}.
create function app.notifications_check_push_record(p_payload jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                    where k not in ('push_job_id', 'lease_token', 'results')), '{}'::jsonb)
      || jsonb_strip_nulls(jsonb_build_object(
           'push_job_id', app.contract_uuid_error(p_payload -> 'push_job_id'),
           'lease_token', case when app.contract_integer_in(p_payload -> 'lease_token', 1, 9007199254740991)
                               then null else 'invalid' end,
           'results', case
             when jsonb_typeof(p_payload -> 'results') is distinct from 'array'
                  or jsonb_array_length(p_payload -> 'results') not between 1 and 10 then 'invalid'
             when exists (select 1 from jsonb_array_elements(p_payload -> 'results') r
                           where app.notifications_push_result_error(r) is not null) then 'invalid'
             when (select count(distinct r ->> 'device_id') from jsonb_array_elements(p_payload -> 'results') r)
                  <> jsonb_array_length(p_payload -> 'results') then 'duplicate_device'
           end));
$$;

create function app.notifications_sys_push_claim(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
begin
  return jsonb_build_object('data', app.notifications_push_claim(
    p_principal, p_request,
    least(coalesce((p_payload ->> 'limit')::numeric::integer, v_settings.batch_max), v_settings.batch_max)));
end;
$$;

create function app.notifications_sys_push_prepare(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  return jsonb_build_object('data', app.notifications_push_prepare(
    p_principal, p_request, (p_payload ->> 'push_job_id')::uuid,
    (p_payload ->> 'lease_token')::numeric::bigint));
end;
$$;

create function app.notifications_sys_push_record(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  return jsonb_build_object('data', app.notifications_push_record(
    p_principal, p_request, (p_payload ->> 'push_job_id')::uuid,
    (p_payload ->> 'lease_token')::numeric::bigint, p_payload -> 'results'));
end;
$$;

create function app.notifications_sys_push_release(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  return jsonb_build_object('data', app.notifications_push_release(
    p_principal, (p_payload ->> 'push_job_id')::uuid, (p_payload ->> 'lease_token')::numeric::bigint));
end;
$$;

insert into app.sys_command_kinds (command, purpose, description, payload_check, handler, retain_result) values
  ('notifications.push_claim', 'notifications_worker',
   'Story 3.6: count lapsed push leases, expire push jobs and (push_enabled) lease a bounded batch',
   'app.notifications_check_deliver_due(jsonb)',
   'app.notifications_sys_push_claim(uuid, uuid, jsonb)', true),
  ('notifications.push_prepare', 'notifications_worker',
   'Story 3.6: recheck one leased push job and answer the generic message and its live targets (not retained)',
   'app.notifications_check_push(jsonb)',
   'app.notifications_sys_push_prepare(uuid, uuid, jsonb)', false),
  ('notifications.push_record', 'notifications_worker',
   'Story 3.6: record the provider''s per-device answers, retire invalid tokens, end or retry the push job',
   'app.notifications_check_push_record(jsonb)',
   'app.notifications_sys_push_record(uuid, uuid, jsonb)', true),
  ('notifications.push_release', 'notifications_worker',
   'Story 3.6: give back an unused push lease (no attempt counted)',
   'app.notifications_check_push(jsonb)',
   'app.notifications_sys_push_release(uuid, uuid, jsonb)', true);

-- Existing notification workers (staging since story 3.1) get the push commands here.
insert into app.sys_principal_commands (principal_id, command)
select p.principal_id, k.command
  from app.sys_principals p
 cross join (values ('notifications.push_claim'), ('notifications.push_prepare'),
                    ('notifications.push_record'), ('notifications.push_release')) as k (command)
 where p.purpose = 'notifications_worker' and p.disabled_at is null
on conflict do nothing;

-- ---------------------------------------------------------------------------------------------
-- Operator functions (story 3.4, replaced in place: same signatures and privileges)
-- ---------------------------------------------------------------------------------------------

-- As in story 3.4, plus `push_enabled` (boolean).
create or replace function app.notifications_configure_worker(p_changes jsonb, p_operator text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v app.notifications_worker_settings;
  k text;
begin
  perform app.ops_require_operator(p_operator);
  if jsonb_typeof(p_changes) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'changes must be a JSON object';
  end if;
  v_errors := '{}'::jsonb;
  for k in select jsonb_object_keys(p_changes) loop
    if k in ('lease_seconds', 'batch_max', 'max_attempts', 'backoff_base_seconds',
             'backoff_max_seconds', 'default_ttl_seconds') then
      if not app.contract_integer_in(p_changes -> k, 1, 7776000) then
        v_errors := v_errors || jsonb_build_object(k, 'invalid');
      end if;
    elsif k = 'worker_url' then
      if jsonb_typeof(p_changes -> k) not in ('string', 'null') then
        v_errors := v_errors || jsonb_build_object(k, 'invalid');
      elsif app.notifications_worker_url_error(p_changes ->> k) is not null then
        v_errors := v_errors || jsonb_build_object(k, app.notifications_worker_url_error(p_changes ->> k));
      end if;
    elsif k = 'push_enabled' then
      if jsonb_typeof(p_changes -> k) is distinct from 'boolean' then
        v_errors := v_errors || jsonb_build_object(k, 'invalid');
      end if;
    else
      v_errors := v_errors || jsonb_build_object(k, 'unknown_field');
    end if;
  end loop;
  if v_errors <> '{}'::jsonb then
    raise exception using errcode = '22023', message = 'invalid worker settings',
      detail = v_errors::text;
  end if;
  update app.notifications_worker_settings s
     set lease_seconds = coalesce((p_changes ->> 'lease_seconds')::integer, s.lease_seconds),
         batch_max = coalesce((p_changes ->> 'batch_max')::integer, s.batch_max),
         max_attempts = coalesce((p_changes ->> 'max_attempts')::integer, s.max_attempts),
         backoff_base_seconds = coalesce((p_changes ->> 'backoff_base_seconds')::integer,
                                         s.backoff_base_seconds),
         backoff_max_seconds = coalesce((p_changes ->> 'backoff_max_seconds')::integer,
                                        s.backoff_max_seconds),
         default_ttl_seconds = coalesce((p_changes ->> 'default_ttl_seconds')::integer,
                                        s.default_ttl_seconds),
         worker_url = case when p_changes ? 'worker_url' then p_changes ->> 'worker_url'
                           else s.worker_url end,
         push_enabled = coalesce((p_changes ->> 'push_enabled')::boolean, s.push_enabled),
         updated_by = p_operator,
         updated_at = clock_timestamp()
   where s.singleton
  returning * into v;
  perform app.ops_record_action(p_operator, 'worker_policy_changed', null);
  return to_jsonb(v) - 'singleton';
end;
$$;

-- As in story 3.4 (attempts_24h now counts inbox attempts only), plus a content-free `push`
-- block: the switch, pending and leased push jobs, push jobs ended in 24 h by state, push attempt
-- outcomes in 24 h and tokens the provider retired in 24 h.
create or replace function app.notifications_scheduler_status()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_state app.notifications_scheduler_state;
  v_jobs integer := 0;
  v_schedule text;
  v_active boolean;
  v_cron jsonb := '{}'::jsonb;
  v_trigger boolean := false;
begin
  select s.* into v_state from app.notifications_scheduler_state s where s.singleton;
  if pg_catalog.to_regnamespace('cron') is not null then
    execute 'select count(*) from cron.job j where j.command like $1'
      into v_jobs using '%notifications_scheduler_tick%';
    execute 'select j.schedule, j.active from cron.job j where j.jobname = $1'
      into v_schedule, v_active using 'notifications-worker';
    execute 'select coalesce(jsonb_object_agg(d.status, d.n), ''{}''::jsonb) from ('
            'select r.status, count(*) as n from cron.job_run_details r join cron.job j '
            'on j.jobid = r.jobid where j.jobname = $1 and r.start_time >= now() - interval ''24 hours'' '
            'group by r.status) d'
      into v_cron using 'notifications-worker';
  end if;
  if pg_catalog.to_regclass('vault.secrets') is not null then
    execute 'select exists (select 1 from vault.secrets s where s.name = $1)'
      into v_trigger using 'notifications_worker_trigger';
  end if;
  return jsonb_build_object(
    'environment', app.platform_current_environment(),
    'allowed', app.notifications_scheduler_allowed(),
    'scheduler_jobs', v_jobs,
    'schedule', v_schedule,
    'active', v_active,
    'cron_runs_24h', v_cron,
    'worker_url_set', v_settings.worker_url is not null,
    'worker_url_valid', v_settings.worker_url is not null
                        and app.notifications_worker_url_error(v_settings.worker_url) is null,
    'trigger_set', v_trigger,
    'last_tick_at', case when v_state.last_tick_at is not null then app.cmd_utc(v_state.last_tick_at) end,
    'last_tick_outcome', v_state.last_tick_outcome,
    'last_claim_at', (select app.cmd_utc(max(r.started_at)) from app.notifications_worker_runs r),
    'claims_24h', (select count(*) from app.notifications_worker_runs r
                    where r.started_at >= now() - interval '24 hours'),
    'due_pending', (select count(*) from app.notifications_jobs j
                     where j.job_state = 'pending' and j.scheduled_at <= now()),
    'leased', (select count(*) from app.notifications_jobs j
                where j.job_state = 'pending' and j.lease_expires_at > now()),
    'attempts_24h', coalesce((select jsonb_object_agg(a.outcome, a.n) from (
        select t.outcome, count(*) as n from app.notifications_attempts t
         where t.attempted_at >= now() - interval '24 hours' and t.channel = 'inbox'
         group by t.outcome) a), '{}'::jsonb),
    'push', jsonb_build_object(
      'enabled', v_settings.push_enabled,
      'pending', (select count(*) from app.notifications_push_jobs p where p.push_state = 'pending'),
      'leased', (select count(*) from app.notifications_push_jobs p
                  where p.push_state = 'pending' and p.lease_expires_at > now()),
      'ended_24h', coalesce((select jsonb_object_agg(e.push_state, e.n) from (
          select p.push_state, count(*) as n from app.notifications_push_jobs p
           where p.finished_at >= now() - interval '24 hours' group by p.push_state) e), '{}'::jsonb),
      'attempts_24h', coalesce((select jsonb_object_agg(a.outcome, a.n) from (
          select t.outcome, count(*) as n from app.notifications_attempts t
           where t.attempted_at >= now() - interval '24 hours' and t.channel = 'push'
           group by t.outcome) a), '{}'::jsonb),
      'tokens_retired_24h', (select count(*) from app.notifications_device_tokens t
                              where t.retire_reason = 'provider_invalid'
                                and t.retired_at >= now() - interval '24 hours')),
    'settings', to_jsonb(v_settings) - 'singleton' - 'worker_url' - 'updated_by');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing here is client-executable
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.sys_execute(jsonb),
  app.notifications_push_finish(uuid, text, text),
  app.notifications_push_accepted_any(uuid),
  app.notifications_push_owed(app.notifications_push_jobs),
  app.notifications_push_exhaust(uuid),
  app.notifications_push_attempt_row(app.notifications_push_jobs, bigint, uuid, uuid, text, text, text),
  app.notifications_push_claim(uuid, uuid, integer),
  app.notifications_push_release(uuid, uuid, bigint),
  app.notifications_push_fail(app.notifications_push_jobs, app.notifications_worker_settings),
  app.notifications_push_prepare(uuid, uuid, uuid, bigint),
  app.notifications_push_record(uuid, uuid, uuid, bigint, jsonb),
  app.notifications_check_push(jsonb),
  app.notifications_push_result_error(jsonb),
  app.notifications_check_push_record(jsonb),
  app.notifications_sys_push_claim(uuid, uuid, jsonb),
  app.notifications_sys_push_prepare(uuid, uuid, jsonb),
  app.notifications_sys_push_record(uuid, uuid, jsonb),
  app.notifications_sys_push_release(uuid, uuid, jsonb),
  app.notifications_configure_worker(jsonb, text),
  app.notifications_scheduler_status()
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
