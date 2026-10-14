-- Auth harness recovery fence for story 1.3 (AD-20 assisted reset).
-- Apply ONLY to the isolated auth-test project (bic-kafue-auth-test /
-- szfyfezfvxyuvovnnakr). This is NOT an application migration and must never
-- be copied into supabase/migrations. Non-destructive and idempotent: it
-- creates or replaces objects and never drops anything. Applied through the
-- Supabase MCP as migration auth_harness_005_recovery_fence; the completion
-- and replay functions were then replaced by auth_harness_007_db_verified_revocation.
-- 004_review_fixes.sql (auth_harness_008) supersedes several functions here;
-- apply 001-004 in order to reproduce the hosted definitions.
--
-- What it proves (harness-scoped model of the Identity-owned mechanism):
--   * rc_account.generation is the recovery/credential generation. Every
--     recovery event advances it: grant (re)issue, relink, reconciliation and
--     ANY native credential change, which the auth.users trigger below records
--     in the same transaction as GoTrue's own write (trusted detection).
--   * Grants are bound to case, member, account, link revision, generation,
--     purpose and expiry. Only the SHA-256 digest of the member-held secret is
--     stored. At most one grant is issued per account; a grant is consumed
--     exactly once under the account lock.
--   * At most one privileged credential mutation is unresolved per account
--     (partial unique index). Dispatch and completion are fenced by the
--     recorded generation and op id. Obsolete, uncertain and late outcomes
--     keep access held until staff reconciliation; nothing here clears a
--     security hold.
--
-- Lock order in the harness RPCs: rc_account row, then rc_grant / rc_op rows.
-- The auth.users trigger runs inside GoTrue's transaction after its
-- auth.users row lock and takes only the rc_account lock. The identity/MFA
-- triggers added in 004 also run inside GoTrue transactions that may hold
-- other auth.* row locks in an order this harness does not control, so a
-- lock inversion with GoTrue is NOT ruled out (known limit, evidence-1.3).
--
-- All harness_rc_* RPCs are executable by service_role only (the harness
-- Edge Function); harness_recovery_probe() by authenticated only.

create schema if not exists harness;

-- Operator tokens: the harness caller presents the secret; only its digest is
-- stored here (registered through the MCP by the operator).
create table if not exists harness.rc_operator_token (
  digest text primary key check (digest ~ '^[0-9a-f]{64}$'),
  label text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists harness.rc_staff (
  auth_user_id uuid primary key,
  created_at timestamptz not null default now()
);

create table if not exists harness.rc_account (
  auth_user_id uuid primary key,
  member_id uuid not null,
  link_revision integer not null default 1,
  generation bigint not null default 1,
  security_hold boolean not null default false,
  reconcile_required boolean not null default false,
  binding_review_required boolean not null default false,
  in_flight_op uuid,
  updated_at timestamptz not null default now()
);

create table if not exists harness.rc_request (
  request_ref uuid primary key default gen_random_uuid(),
  grant_digest text not null unique check (grant_digest ~ '^[0-9a-f]{64}$'),
  status text not null default 'open' check (status in ('open', 'bound')),
  created_at timestamptz not null default now()
);

create table if not exists harness.rc_grant (
  grant_id uuid primary key default gen_random_uuid(),
  grant_digest text not null unique check (grant_digest ~ '^[0-9a-f]{64}$'),
  case_id text not null,
  member_id uuid not null,
  auth_user_id uuid not null,
  link_revision integer not null,
  generation bigint not null,
  purpose text not null default 'password_setup' check (purpose = 'password_setup'),
  issued_by uuid not null,
  expires_at timestamptz not null,
  status text not null default 'issued'
    check (status in ('issued', 'consumed', 'superseded', 'burned', 'expired')),
  status_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists rc_grant_one_issued_per_account
  on harness.rc_grant (auth_user_id) where status = 'issued';

create table if not exists harness.rc_op (
  op_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null,
  grant_id uuid not null references harness.rc_grant (grant_id),
  generation bigint not null,
  status text not null default 'pending'
    check (status in ('pending', 'dispatched', 'succeeded', 'failed', 'uncertain', 'obsolete', 'reconciled')),
  outcome jsonb,
  late_outcomes jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  dispatched_at timestamptz,
  completed_at timestamptz
);
-- One unresolved privileged credential mutation per account.
create unique index if not exists rc_op_one_unresolved_per_account
  on harness.rc_op (auth_user_id) where status in ('pending', 'dispatched', 'uncertain');

create table if not exists harness.rc_event (
  id bigserial primary key,
  at timestamptz not null default clock_timestamp(),
  auth_user_id uuid,
  kind text not null,
  op_id uuid,
  grant_id uuid,
  generation_before bigint,
  generation_after bigint,
  detail jsonb not null default '{}'::jsonb
);

alter table harness.rc_operator_token enable row level security;
alter table harness.rc_staff enable row level security;
alter table harness.rc_account enable row level security;
alter table harness.rc_request enable row level security;
alter table harness.rc_grant enable row level security;
alter table harness.rc_op enable row level security;
alter table harness.rc_event enable row level security;
revoke all on harness.rc_operator_token, harness.rc_staff, harness.rc_account, harness.rc_request,
  harness.rc_grant, harness.rc_op, harness.rc_event from public, anon, authenticated;
revoke all on sequence harness.rc_event_id_seq from public, anon, authenticated;

-- Internal: advance the generation of a LOCKED account and supersede any
-- outstanding grant. Returns the new generation.
create or replace function harness.rc_advance(p_uid uuid, p_kind text, p_op uuid, p_detail jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  g_before bigint;
  g_after bigint;
begin
  update harness.rc_account
     set generation = generation + 1, updated_at = now()
   where auth_user_id = p_uid
   returning generation - 1, generation into g_before, g_after;
  update harness.rc_grant
     set status = 'superseded', status_reason = p_kind, updated_at = now()
   where auth_user_id = p_uid and status = 'issued';
  insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, generation_after, detail)
  values (p_uid, p_kind, p_op, g_before, g_after, coalesce(p_detail, '{}'::jsonb));
  return g_after;
end;
$$;
revoke all on function harness.rc_advance(uuid, text, uuid, jsonb) from public, anon, authenticated;

-- Trusted detection: any change to an enrolled account's password hash,
-- email or phone advances the generation inside GoTrue's own transaction.
-- Email/phone changes additionally require binding review. If this trigger
-- fails, GoTrue's write fails too (fail closed: no unrecorded change).
create or replace function harness.rc_on_auth_credential_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
  kinds text[] := '{}';
  op_status text;
begin
  select * into a from harness.rc_account where auth_user_id = new.id for update;
  if not found then
    return null;
  end if;
  if new.encrypted_password is distinct from old.encrypted_password then kinds := array_append(kinds, 'password'); end if;
  if new.email is distinct from old.email then kinds := array_append(kinds, 'email'); end if;
  if new.phone is distinct from old.phone then kinds := array_append(kinds, 'phone'); end if;
  if cardinality(kinds) = 0 then
    return null;
  end if;
  select o.status into op_status from harness.rc_op o where o.op_id = a.in_flight_op;
  if 'email' = any(kinds) or 'phone' = any(kinds) then
    update harness.rc_account set binding_review_required = true where auth_user_id = new.id;
  end if;
  perform harness.rc_advance(new.id, 'native_credential_change', a.in_flight_op,
    jsonb_build_object('changed', to_jsonb(kinds), 'in_flight_status', op_status));
  return null;
end;
$$;
revoke all on function harness.rc_on_auth_credential_change() from public, anon, authenticated;

create or replace trigger rc_auth_credential_change
  after update of encrypted_password, email, phone on auth.users
  for each row
  when (old.encrypted_password is distinct from new.encrypted_password
        or old.email is distinct from new.email
        or old.phone is distinct from new.phone)
  execute function harness.rc_on_auth_credential_change();

-- ---------------------------------------------------------------------------
-- Service-only RPCs (called by the harness-recovery Edge Function).
-- Every result is jsonb {ok, code, ...}; rejections still commit their audit
-- rows and grant burns, so they return rather than raise.
-- ---------------------------------------------------------------------------

create or replace function public.harness_rc_check_operator(p_digest text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from harness.rc_operator_token t
                 where t.digest = p_digest and t.expires_at > now());
$$;

create or replace function public.harness_rc_is_staff(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from harness.rc_staff s where s.auth_user_id = p_uid);
$$;

create or replace function public.harness_rc_enroll(p_uid uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
begin
  if not exists (select 1 from auth.users u where u.id = p_uid
                 and u.email like 'israelmuyoba+bicauth-%@gmail.com') then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_role = 'staff' then
    insert into harness.rc_staff (auth_user_id) values (p_uid) on conflict do nothing;
    return jsonb_build_object('ok', true, 'role', 'staff');
  elsif p_role = 'member' then
    insert into harness.rc_account (auth_user_id, member_id) values (p_uid, gen_random_uuid())
      on conflict do nothing;
    select * into a from harness.rc_account where auth_user_id = p_uid;
    insert into harness.rc_event (auth_user_id, kind, generation_after, detail)
    values (p_uid, 'enrolled', a.generation, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'role', 'member', 'member_id', a.member_id,
      'link_revision', a.link_revision, 'generation', a.generation);
  end if;
  return jsonb_build_object('ok', false, 'code', 'validation_failed');
end;
$$;

-- Member device submits only the digest of a secret it generated. Staff later
-- binds the request; staff never sees the secret.
create or replace function public.harness_rc_request(p_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r uuid;
begin
  if p_digest is null or p_digest !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'code', 'validation_failed');
  end if;
  insert into harness.rc_request (grant_digest) values (p_digest)
    on conflict (grant_digest) do nothing
    returning request_ref into r;
  if r is null then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  return jsonb_build_object('ok', true, 'request_ref', r);
end;
$$;

create or replace function public.harness_rc_issue(
  p_staff uuid, p_request_ref uuid, p_case_id text, p_member_id uuid, p_uid uuid,
  p_link_revision integer, p_ttl_s integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
  req harness.rc_request;
  g bigint;
  gid uuid;
  exp timestamptz;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into a from harness.rc_account where auth_user_id = p_uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if a.member_id is distinct from p_member_id or a.link_revision is distinct from p_link_revision then
    insert into harness.rc_event (auth_user_id, kind, generation_before, detail)
    values (p_uid, 'issue_refused', a.generation, jsonb_build_object('reason', 'link_mismatch'));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'link_mismatch');
  end if;
  if a.in_flight_op is not null or a.reconcile_required then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (p_uid, 'issue_refused', a.in_flight_op, a.generation, jsonb_build_object('reason', 'unresolved_work'));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'unresolved_work');
  end if;
  select * into req from harness.rc_request where request_ref = p_request_ref for update;
  if not found or req.status <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  g := harness.rc_advance(p_uid, 'grant_issue', null, jsonb_build_object('case_id', p_case_id));
  exp := now() + make_interval(secs => greatest(1, least(coalesce(p_ttl_s, 900), 900)));
  insert into harness.rc_grant (grant_digest, case_id, member_id, auth_user_id, link_revision,
                                generation, issued_by, expires_at)
  values (req.grant_digest, p_case_id, a.member_id, p_uid, a.link_revision, g, p_staff, exp)
  returning grant_id into gid;
  update harness.rc_request set status = 'bound' where request_ref = p_request_ref;
  insert into harness.rc_event (auth_user_id, kind, grant_id, generation_after, detail)
  values (p_uid, 'grant_issued', gid, g, jsonb_build_object('case_id', p_case_id, 'expires_at', exp));
  return jsonb_build_object('ok', true, 'grant_id', gid, 'generation', g, 'expires_at', exp,
                            'link_revision', a.link_revision);
end;
$$;

-- Validate and consume a grant, then record ONE pending op, all under the
-- account lock. Any grant problem returns the same public code.
create or replace function public.harness_rc_begin(p_digest text, p_login_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  a harness.rc_account;
  gr harness.rc_grant;
  em text;
  oid uuid;
  reason text;
begin
  select g.auth_user_id into uid from harness.rc_grant g where g.grant_digest = p_digest;
  if uid is null then
    insert into harness.rc_event (kind, detail) values ('redeem_rejected', '{"reason":"unknown_grant"}');
    return jsonb_build_object('ok', false, 'code', 'grant_rejected');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into gr from harness.rc_grant where grant_digest = p_digest for update;
  select u.email into em from auth.users u where u.id = uid;

  if gr.status <> 'issued' then
    reason := 'grant_' || gr.status;
  elsif gr.expires_at <= now() then
    reason := 'expired';
    update harness.rc_grant set status = 'expired', status_reason = 'expired', updated_at = now()
     where grant_id = gr.grant_id;
  elsif lower(coalesce(em, '')) <> lower(coalesce(p_login_email, '')) then
    reason := 'identifier_mismatch';
    update harness.rc_grant set status = 'burned', status_reason = 'identifier_mismatch', updated_at = now()
     where grant_id = gr.grant_id;
  elsif gr.generation <> a.generation or gr.link_revision <> a.link_revision
        or gr.member_id <> a.member_id then
    reason := 'stale_binding';
    update harness.rc_grant set status = 'superseded', status_reason = 'stale_binding', updated_at = now()
     where grant_id = gr.grant_id;
  elsif a.in_flight_op is not null or a.reconcile_required then
    reason := 'unresolved_work';
  end if;

  if reason is not null then
    insert into harness.rc_event (auth_user_id, kind, grant_id, op_id, generation_before, detail)
    values (uid, 'redeem_rejected', gr.grant_id, a.in_flight_op, a.generation,
            jsonb_build_object('reason', reason));
    return jsonb_build_object('ok', false,
      'code', case when reason = 'unresolved_work' then 'conflict' else 'grant_rejected' end);
  end if;

  update harness.rc_grant set status = 'consumed', status_reason = 'redeemed', updated_at = now()
   where grant_id = gr.grant_id;
  insert into harness.rc_op (auth_user_id, grant_id, generation)
  values (uid, gr.grant_id, a.generation)
  returning op_id into oid;
  update harness.rc_account set in_flight_op = oid, updated_at = now() where auth_user_id = uid;
  insert into harness.rc_event (auth_user_id, kind, grant_id, op_id, generation_before, detail)
  values (uid, 'op_begun', gr.grant_id, oid, a.generation, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'op_id', oid, 'auth_user_id', uid,
                            'generation', a.generation, 'email', em);
end;
$$;

-- Resume a pending op (only by the holder of its grant secret).
create or replace function public.harness_rc_resume(p_op uuid, p_digest text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o harness.rc_op;
  em text;
begin
  select o2.* into o from harness.rc_op o2
    join harness.rc_grant g on g.grant_id = o2.grant_id
   where o2.op_id = p_op and g.grant_digest = p_digest;
  if not found then
    insert into harness.rc_event (kind, op_id, detail) values ('resume_rejected', p_op, '{"reason":"no_match"}');
    return jsonb_build_object('ok', false, 'code', 'grant_rejected');
  end if;
  select u.email into em from auth.users u where u.id = o.auth_user_id;
  return jsonb_build_object('ok', true, 'op_id', o.op_id, 'auth_user_id', o.auth_user_id,
                            'generation', o.generation, 'status', o.status, 'email', em);
end;
$$;

-- Fence before any external Auth work.
create or replace function public.harness_rc_dispatch(p_op uuid, p_generation bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  a harness.rc_account;
  o harness.rc_op;
begin
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;
  if o.status = 'pending' and o.generation = p_generation and a.generation = p_generation
     and a.in_flight_op = p_op and not a.reconcile_required then
    update harness.rc_op set status = 'dispatched', dispatched_at = clock_timestamp() where op_id = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'op_dispatched', p_op, a.generation, '{}'::jsonb);
    return jsonb_build_object('ok', true, 'status', 'dispatched');
  end if;
  if o.status = 'pending' then
    -- No external work happened: the op is obsolete and releases the account.
    update harness.rc_op set status = 'obsolete', completed_at = clock_timestamp(),
           outcome = jsonb_build_object('reason', 'dispatch_fenced')
     where op_id = p_op;
    update harness.rc_account set in_flight_op = null, updated_at = now()
     where auth_user_id = uid and in_flight_op = p_op;
  end if;
  insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
  values (uid, 'dispatch_fenced', p_op, a.generation,
          jsonb_build_object('op_generation', o.generation, 'requested_generation', p_generation,
                             'op_status_before', o.status));
  return jsonb_build_object('ok', false, 'code', 'obsolete', 'status', 'obsolete');
end;
$$;

-- Used when the caller stops waiting for Auth (timeout): the op becomes
-- uncertain and access is held until reconciliation.
create or replace function public.harness_rc_mark_uncertain(p_op uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  o harness.rc_op;
begin
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  perform 1 from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;
  if not found or o.status <> 'dispatched' then
    return jsonb_build_object('ok', false, 'code', 'conflict');
  end if;
  update harness.rc_op set status = 'uncertain', completed_at = clock_timestamp(),
         outcome = jsonb_build_object('reason', p_reason)
   where op_id = p_op;
  update harness.rc_account set reconcile_required = true, updated_at = now() where auth_user_id = uid;
  insert into harness.rc_event (auth_user_id, kind, op_id, detail)
  values (uid, 'op_uncertain', p_op, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'status', 'uncertain');
end;
$$;

-- Fenced completion. p_outcome: {admin_status, applied, transport
-- ('ok'|'lost')} as reported by the Edge Function. Success is accepted only
-- when Auth reported the apply, exactly one password-only credential change
-- was recorded for this op since dispatch, AND no session created before
-- dispatch is still live (revocation verified here, not self-reported; Auth
-- Admin password update logs out every session in the same transaction on
-- the observed Auth version).
create or replace function public.harness_rc_complete(p_op uuid, p_generation bigint, p_outcome jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  a harness.rc_account;
  o harness.rc_op;
  n_changes integer;
  n_non_password integer;
  transport_ok boolean := coalesce(p_outcome ->> 'transport', '') = 'ok';
  applied boolean := coalesce((p_outcome ->> 'applied')::boolean, false);
  pre_dispatch_sessions integer;
  admin_status integer := nullif(p_outcome ->> 'admin_status', '')::integer;
  verdict text;
begin
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;

  if o.generation <> p_generation then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'completion_rejected', p_op, a.generation,
            jsonb_build_object('reason', 'fence_mismatch', 'outcome', p_outcome));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'fence_mismatch');
  end if;
  if o.status = 'uncertain' then
    update harness.rc_op
       set late_outcomes = late_outcomes || jsonb_build_array(p_outcome || jsonb_build_object('recorded_at', clock_timestamp()))
     where op_id = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'late_outcome_recorded', p_op, a.generation, jsonb_build_object('outcome', p_outcome));
    return jsonb_build_object('ok', false, 'code', 'late_outcome_recorded', 'status', 'uncertain',
                              'access_held', true);
  end if;
  if o.status <> 'dispatched' then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'completion_rejected', p_op, a.generation,
            jsonb_build_object('reason', 'stale', 'op_status', o.status));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'stale', 'status', o.status);
  end if;

  select count(*), count(*) filter (where e.detail -> 'changed' <> '["password"]'::jsonb)
    into n_changes, n_non_password
    from harness.rc_event e
   where e.auth_user_id = uid and e.kind = 'native_credential_change'
     and e.op_id = p_op and e.at >= o.dispatched_at;

  select count(*) into pre_dispatch_sessions
    from auth.sessions s
   where s.user_id = uid and s.created_at < o.dispatched_at
     and (s.not_after is null or s.not_after > now());

  if transport_ok and applied and pre_dispatch_sessions = 0 and n_changes = 1 and n_non_password = 0 then
    verdict := 'succeeded';
  elsif transport_ok and not applied and admin_status between 400 and 499 and n_non_password = 0 then
    verdict := 'failed';
  else
    verdict := 'uncertain';
  end if;

  update harness.rc_op
     set status = verdict, completed_at = clock_timestamp(),
         outcome = p_outcome || jsonb_build_object('changes_since_dispatch', n_changes,
                                                   'pre_dispatch_sessions_live', pre_dispatch_sessions)
   where op_id = p_op;
  if verdict = 'uncertain' then
    update harness.rc_account set reconcile_required = true, updated_at = now() where auth_user_id = uid;
  else
    update harness.rc_account set in_flight_op = null, updated_at = now()
     where auth_user_id = uid and in_flight_op = p_op;
  end if;
  insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
  values (uid, 'op_' || verdict, p_op, a.generation,
          jsonb_build_object('changes_since_dispatch', n_changes,
                             'pre_dispatch_sessions_live', pre_dispatch_sessions, 'outcome', p_outcome));
  return jsonb_build_object('ok', verdict = 'succeeded', 'status', verdict,
                            'generation', a.generation, 'access_held', verdict = 'uncertain');
end;
$$;

-- Harness-only: replay the recorded completion of an op to prove stale
-- completions are rejected.
create or replace function public.harness_rc_replay_complete(p_staff uuid, p_op uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o harness.rc_op;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into o from harness.rc_op where op_id = p_op;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return public.harness_rc_complete(p_op, o.generation,
    coalesce(o.outcome, '{}'::jsonb) - 'changes_since_dispatch' - 'pre_dispatch_sessions_live' - 'reason'
      || jsonb_build_object('transport', 'ok', 'applied', true, 'replayed', true));
end;
$$;

create or replace function public.harness_rc_relink(
  p_staff uuid, p_uid uuid, p_member_id uuid, p_expected_link_revision integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
  g bigint;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into a from harness.rc_account where auth_user_id = p_uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if a.in_flight_op is not null or a.reconcile_required then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (p_uid, 'relink_refused', a.in_flight_op, a.generation, jsonb_build_object('reason', 'unresolved_work'));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'unresolved_work');
  end if;
  if a.link_revision <> p_expected_link_revision then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'stale_link_revision',
                              'current_revision', a.link_revision);
  end if;
  update harness.rc_account
     set member_id = coalesce(p_member_id, member_id), link_revision = link_revision + 1,
         binding_review_required = false, updated_at = now()
   where auth_user_id = p_uid;
  g := harness.rc_advance(p_uid, 'relinked', null,
         jsonb_build_object('member_changed', p_member_id is not null and p_member_id <> a.member_id));
  return jsonb_build_object('ok', true, 'link_revision', a.link_revision + 1, 'generation', g,
                            'member_id', coalesce(p_member_id, a.member_id));
end;
$$;

-- Security holds are always applicable, even with unresolved work in flight.
create or replace function public.harness_rc_hold(p_staff uuid, p_uid uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into a from harness.rc_account where auth_user_id = p_uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  update harness.rc_account set security_hold = p_on, updated_at = now() where auth_user_id = p_uid;
  insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
  values (p_uid, case when p_on then 'hold_applied' else 'hold_released' end, a.in_flight_op,
          a.generation, jsonb_build_object('in_flight', a.in_flight_op is not null));
  return jsonb_build_object('ok', true, 'security_hold', p_on, 'in_flight', a.in_flight_op is not null);
end;
$$;

-- Staff reconciliation of an uncertain op after checking Auth state. It
-- advances the generation (killing anything issued before) and never clears
-- a security hold.
create or replace function public.harness_rc_reconcile(p_staff uuid, p_op uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  o harness.rc_op;
  g bigint;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform 1 from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;
  if o.status <> 'uncertain' then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'status', o.status);
  end if;
  update harness.rc_op set status = 'reconciled' where op_id = p_op;
  update harness.rc_account set reconcile_required = false, in_flight_op = null, updated_at = now()
   where auth_user_id = uid;
  g := harness.rc_advance(uid, 'reconciled', p_op, jsonb_build_object('note', left(coalesce(p_note, ''), 80)));
  return jsonb_build_object('ok', true, 'status', 'reconciled', 'generation', g);
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.harness_rc_check_operator(text)',
    'public.harness_rc_is_staff(uuid)',
    'public.harness_rc_enroll(uuid, text)',
    'public.harness_rc_request(text)',
    'public.harness_rc_issue(uuid, uuid, text, uuid, uuid, integer, integer)',
    'public.harness_rc_begin(text, text)',
    'public.harness_rc_resume(uuid, text)',
    'public.harness_rc_dispatch(uuid, bigint)',
    'public.harness_rc_mark_uncertain(uuid, text)',
    'public.harness_rc_complete(uuid, bigint, jsonb)',
    'public.harness_rc_replay_complete(uuid, uuid)',
    'public.harness_rc_relink(uuid, uuid, uuid, integer)',
    'public.harness_rc_hold(uuid, uuid, boolean)',
    'public.harness_rc_reconcile(uuid, uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;

-- Private-data gate for an enrolled account: the 1.2 trusted password session
-- AND no security hold, no unresolved/uncertain credential work and no
-- unreviewed binding change.
create or replace function public.harness_recovery_probe()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with a as (select * from harness.rc_account where auth_user_id = auth.uid())
  select jsonb_build_object(
    'trusted_password_session', harness.trusted_password_session(),
    'enrolled', exists (select 1 from a),
    'security_hold', (select security_hold from a),
    'reconcile_required', (select reconcile_required from a),
    'in_flight', (select in_flight_op is not null from a),
    'binding_review_required', (select binding_review_required from a),
    'generation', (select generation from a),
    'allowed', coalesce(harness.trusted_password_session()
      and (select not security_hold and not reconcile_required and in_flight_op is null
                  and not binding_review_required from a), false)
  );
$$;
revoke all on function public.harness_recovery_probe() from public, anon;
grant execute on function public.harness_recovery_probe() to authenticated;
