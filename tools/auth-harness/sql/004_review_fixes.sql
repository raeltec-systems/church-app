-- Auth harness recovery fence, independent-review fixes (story 1.3).
-- Apply ONLY to szfyfezfvxyuvovnnakr, after 001-003, as migration
-- auth_harness_008_review_fixes. Non-destructive and idempotent: adds
-- columns/triggers/functions and replaces function bodies; nothing is
-- dropped. The superseded one-argument harness_rc_request(text) is retired
-- by revoking EXECUTE (not dropped). 001 + 002 + 003 + 004 together are the
-- exact hosted definitions (fingerprints in evidence-1.3).
--
-- Changes:
--   * Trusted detection also covers auth.identities insert/delete,
--     auth.mfa_factors insert/delete/status-or-secret update and auth.users
--     delete. An unattributed credential change on an account with an
--     uncertain or recently reconciled op re-opens that op and holds access.
--   * Holds and pending binding review refuse grant issue and redemption; a
--     hold advances the generation (supersedes issued grants). Redemption is
--     checked against the APPROVED login binding, never the live Auth email.
--   * Completion: 'failed' requires zero credential changes in the window;
--     malformed outcomes are 'uncertain'; late payloads on finished ops are
--     recorded. Dispatch records how many pre-dispatch sessions were live.
--   * Reconcile verifies that no pre-dispatch session is still live, and sets
--     a trust epoch: only sessions created after it pass the recovery gate.
--   * Staff can expire stuck ops (pending -> obsolete, dispatched ->
--     uncertain) once they are older than 30 seconds (harness bound).
--   * Replay only re-submits the RECORDED outcome of a finished op.
--   * Requests expire (30 min), are rate limited, carry the member's claimed
--     login and can only be bound to the account whose approved login matches.
--   * Staff enrolment is out of band (sql/enroll_staff.sql), never by the
--     operator token.

alter table harness.rc_account add column if not exists approved_email text;
alter table harness.rc_account add column if not exists trusted_since timestamptz not null default '-infinity';
alter table harness.rc_request add column if not exists claimed_login text;
alter table harness.rc_request add column if not exists expires_at timestamptz;
alter table harness.rc_op add column if not exists sessions_at_dispatch integer;

-- Accounts enrolled before this migration approve their current login.
update harness.rc_account a set approved_email = u.email
  from auth.users u
 where u.id = a.auth_user_id and a.approved_email is null;

-- ---------------------------------------------------------------------------
-- Trusted detection.
-- ---------------------------------------------------------------------------

-- Shared by both triggers: record one credential/binding change of an
-- enrolled, LOCKED account. Attributed to the in-flight op if there is one;
-- otherwise, if an op of this account is uncertain or was reconciled within
-- the last hour, the change may be that op's late external outcome: re-open
-- it as uncertain and hold access until staff reconcile again.
create or replace function harness.rc_record_change(p_uid uuid, p_kinds text[], p_binding boolean, p_hold boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
  op_status text;
  late_op uuid;
begin
  select * into a from harness.rc_account where auth_user_id = p_uid;
  if a.in_flight_op is null then
    select o.op_id into late_op from harness.rc_op o
     where o.auth_user_id = p_uid
       and (o.status = 'uncertain'
            or (o.status = 'reconciled' and o.completed_at > now() - interval '1 hour'))
     order by o.created_at desc limit 1;
    if late_op is not null then
      update harness.rc_op set status = 'uncertain' where op_id = late_op and status = 'reconciled';
      update harness.rc_account
         set in_flight_op = late_op, reconcile_required = true, security_hold = true, updated_at = now()
       where auth_user_id = p_uid;
      insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
      values (p_uid, 'late_change_reopened_op', late_op, a.generation, jsonb_build_object('changed', to_jsonb(p_kinds)));
      a.in_flight_op := late_op;
    end if;
  end if;
  select o.status into op_status from harness.rc_op o where o.op_id = a.in_flight_op;
  if p_binding or p_hold then
    update harness.rc_account
       set binding_review_required = binding_review_required or p_binding,
           security_hold = security_hold or p_hold
     where auth_user_id = p_uid;
  end if;
  perform harness.rc_advance(p_uid, 'native_credential_change', a.in_flight_op,
    jsonb_build_object('changed', to_jsonb(p_kinds), 'in_flight_status', op_status));
end;
$$;
revoke all on function harness.rc_record_change(uuid, text[], boolean, boolean) from public, anon, authenticated;

create or replace function harness.rc_on_auth_credential_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  kinds text[] := '{}';
begin
  perform 1 from harness.rc_account where auth_user_id = new.id for update;
  if not found then
    return null;
  end if;
  if new.encrypted_password is distinct from old.encrypted_password then kinds := array_append(kinds, 'password'); end if;
  if new.email is distinct from old.email then kinds := array_append(kinds, 'email'); end if;
  if new.phone is distinct from old.phone then kinds := array_append(kinds, 'phone'); end if;
  if cardinality(kinds) = 0 then
    return null;
  end if;
  perform harness.rc_record_change(new.id, kinds, 'email' = any(kinds) or 'phone' = any(kinds), false);
  return null;
end;
$$;
revoke all on function harness.rc_on_auth_credential_change() from public, anon, authenticated;

-- Identity link/unlink, MFA factor changes and user deletion. All require
-- binding review; deletion also holds the account.
create or replace function harness.rc_on_auth_binding_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  kind text;
begin
  if TG_TABLE_NAME = 'users' then
    uid := old.id;
    kind := 'user_deleted';
  elsif TG_OP = 'DELETE' then
    uid := old.user_id;
    kind := TG_TABLE_NAME || '_deleted';
  elsif TG_OP = 'INSERT' then
    uid := new.user_id;
    kind := TG_TABLE_NAME || '_inserted';
  else
    uid := new.user_id;
    kind := TG_TABLE_NAME || '_updated';
  end if;
  perform 1 from harness.rc_account where auth_user_id = uid for update;
  if not found then
    return null;
  end if;
  perform harness.rc_record_change(uid, array[kind], true, kind = 'user_deleted');
  return null;
end;
$$;
revoke all on function harness.rc_on_auth_binding_change() from public, anon, authenticated;

create or replace trigger rc_auth_identity_change
  after insert or delete on auth.identities
  for each row execute function harness.rc_on_auth_binding_change();

create or replace trigger rc_auth_mfa_factor_change
  after insert or delete or update of status, secret on auth.mfa_factors
  for each row execute function harness.rc_on_auth_binding_change();

create or replace trigger rc_auth_user_deleted
  after delete on auth.users
  for each row execute function harness.rc_on_auth_binding_change();

-- ---------------------------------------------------------------------------
-- Enrolment, requests, issue, begin.
-- ---------------------------------------------------------------------------

-- Members only. Staff are enrolled out of band (sql/enroll_staff.sql).
create or replace function public.harness_rc_enroll(p_uid uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a harness.rc_account;
  em text;
begin
  select u.email into em from auth.users u
   where u.id = p_uid and u.email like 'israelmuyoba+bicauth-%@gmail.com';
  if em is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_role <> 'member' then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  insert into harness.rc_account (auth_user_id, member_id, approved_email) values (p_uid, gen_random_uuid(), em)
    on conflict do nothing;
  select * into a from harness.rc_account where auth_user_id = p_uid;
  insert into harness.rc_event (auth_user_id, kind, generation_after, detail)
  values (p_uid, 'enrolled', a.generation, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'role', 'member', 'member_id', a.member_id,
    'link_revision', a.link_revision, 'generation', a.generation);
end;
$$;

-- Retired: the request without a claimed login.
revoke all on function public.harness_rc_request(text) from public, anon, authenticated, service_role;

create or replace function public.harness_rc_request(p_digest text, p_claimed_login text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r uuid;
begin
  if p_digest is null or p_digest !~ '^[0-9a-f]{64}$'
     or p_claimed_login is null or length(p_claimed_login) > 254 or position('@' in p_claimed_login) = 0 then
    return jsonb_build_object('ok', false, 'code', 'validation_failed');
  end if;
  -- Harness rate limit: at most 30 requests per 10 minutes, project-wide.
  if (select count(*) from harness.rc_request q where q.created_at > now() - interval '10 minutes') >= 30 then
    insert into harness.rc_event (kind, detail) values ('request_rate_limited', '{}'::jsonb);
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  insert into harness.rc_request (grant_digest, claimed_login, expires_at)
  values (p_digest, lower(p_claimed_login), now() + interval '30 minutes')
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
  refuse text;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select * into a from harness.rc_account where auth_user_id = p_uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into req from harness.rc_request where request_ref = p_request_ref for update;

  if a.member_id is distinct from p_member_id or a.link_revision is distinct from p_link_revision then
    refuse := 'link_mismatch';
  elsif a.in_flight_op is not null or a.reconcile_required then
    refuse := 'unresolved_work';
  elsif a.security_hold then
    refuse := 'security_hold';
  elsif a.binding_review_required then
    refuse := 'binding_review_required';
  elsif req.request_ref is null or req.status <> 'open' then
    refuse := 'request_not_open';
  elsif req.expires_at is null or req.expires_at <= now() then
    refuse := 'request_expired';
  elsif req.claimed_login is distinct from lower(a.approved_email) then
    refuse := 'request_for_other_account';
  end if;
  if refuse is not null then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (p_uid, 'issue_refused', a.in_flight_op, a.generation, jsonb_build_object('reason', refuse));
    return jsonb_build_object('ok', false,
      'code', case when refuse in ('request_not_open', 'request_expired') then 'not_found' else 'conflict' end,
      'reason', refuse);
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

  if gr.status <> 'issued' then
    reason := 'grant_' || gr.status;
  elsif gr.expires_at <= now() then
    reason := 'expired';
    update harness.rc_grant set status = 'expired', status_reason = 'expired', updated_at = now()
     where grant_id = gr.grant_id;
  elsif lower(coalesce(a.approved_email, '')) <> lower(coalesce(p_login_email, '')) then
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
  elsif a.security_hold then
    reason := 'security_hold';
  elsif a.binding_review_required then
    reason := 'binding_review_required';
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
  return jsonb_build_object('ok', true, 'op_id', oid, 'auth_user_id', uid, 'generation', a.generation);
end;
$$;

-- ---------------------------------------------------------------------------
-- Dispatch, completion, replay, stuck ops.
-- ---------------------------------------------------------------------------

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
  live integer;
begin
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;
  if o.status = 'pending' and o.generation = p_generation and a.generation = p_generation
     and a.in_flight_op = p_op and not a.reconcile_required then
    select count(*) into live from auth.sessions s
     where s.user_id = uid and (s.not_after is null or s.not_after > now());
    update harness.rc_op set status = 'dispatched', dispatched_at = clock_timestamp(),
           sessions_at_dispatch = live
     where op_id = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'op_dispatched', p_op, a.generation, jsonb_build_object('live_sessions_at_dispatch', live));
    return jsonb_build_object('ok', true, 'status', 'dispatched');
  end if;
  if o.status = 'pending' then
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

-- Fenced completion. p_outcome as reported by the Edge Function:
-- {admin_status (3-digit number or null), applied (boolean), transport
-- ('ok'|'lost')}. A malformed outcome is 'uncertain', never an error that
-- leaves the op dispatched. Success needs: Auth reported the apply, exactly
-- one password-only change for this op since dispatch, and no session created
-- before dispatch still live. 'failed' needs a definitive 4xx AND no change.
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
  pre_dispatch_sessions integer;
  transport_ok boolean;
  applied boolean;
  admin_status integer;
  verdict text;
begin
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;

  transport_ok := jsonb_typeof(p_outcome) = 'object' and p_outcome ->> 'transport' = 'ok';
  applied := case when jsonb_typeof(p_outcome -> 'applied') = 'boolean'
                  then (p_outcome ->> 'applied')::boolean end;
  admin_status := case when jsonb_typeof(p_outcome -> 'admin_status') = 'number'
                        and (p_outcome ->> 'admin_status') ~ '^[1-5][0-9]{2}$'
                       then (p_outcome ->> 'admin_status')::integer end;

  if o.generation <> p_generation then
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'completion_rejected', p_op, a.generation,
            jsonb_build_object('reason', 'fence_mismatch', 'outcome', p_outcome));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'fence_mismatch');
  end if;
  if o.status = 'uncertain' then
    update harness.rc_op
       set late_outcomes = late_outcomes || jsonb_build_array(jsonb_build_object(
             'outcome', p_outcome, 'recorded_at', clock_timestamp(), 'op_status', o.status))
     where op_id = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'late_outcome_recorded', p_op, a.generation, jsonb_build_object('outcome', p_outcome));
    return jsonb_build_object('ok', false, 'code', 'late_outcome_recorded', 'status', 'uncertain',
                              'access_held', true);
  end if;
  if o.status <> 'dispatched' then
    -- Finished (or never dispatched): record the payload, change nothing.
    update harness.rc_op
       set late_outcomes = late_outcomes || jsonb_build_array(jsonb_build_object(
             'outcome', p_outcome, 'recorded_at', clock_timestamp(), 'op_status', o.status))
     where op_id = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'completion_rejected', p_op, a.generation,
            jsonb_build_object('reason', 'stale', 'op_status', o.status, 'outcome', p_outcome));
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

  if transport_ok and applied is true and pre_dispatch_sessions = 0 and n_changes = 1 and n_non_password = 0 then
    verdict := 'succeeded';
  elsif transport_ok and applied is false and admin_status between 400 and 499 and n_changes = 0 then
    verdict := 'failed';
  else
    verdict := 'uncertain';
  end if;

  update harness.rc_op
     set status = verdict, completed_at = clock_timestamp(),
         outcome = jsonb_build_object('reported', p_outcome, 'changes_since_dispatch', n_changes,
                                      'pre_dispatch_sessions_live', pre_dispatch_sessions)
   where op_id = p_op;
  if verdict = 'uncertain' then
    update harness.rc_account set reconcile_required = true, updated_at = now() where auth_user_id = uid;
  else
    update harness.rc_account
       set in_flight_op = null, updated_at = now(),
           trusted_since = case when verdict = 'succeeded' then o.dispatched_at else trusted_since end
     where auth_user_id = uid and in_flight_op = p_op;
  end if;
  insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
  values (uid, 'op_' || verdict, p_op, a.generation,
          jsonb_build_object('changes_since_dispatch', n_changes, 'sessions_at_dispatch', o.sessions_at_dispatch,
                             'pre_dispatch_sessions_live', pre_dispatch_sessions, 'outcome', p_outcome));
  return jsonb_build_object('ok', verdict = 'succeeded', 'status', verdict,
                            'generation', a.generation, 'access_held', verdict = 'uncertain');
end;
$$;

-- Harness-only: re-submit the RECORDED outcome of a finished op. Refused for
-- ops that are not finished; nothing is fabricated.
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
  if o.status not in ('succeeded', 'failed', 'obsolete', 'reconciled') then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_finished', 'status', o.status);
  end if;
  return public.harness_rc_complete(p_op, o.generation, coalesce(o.outcome -> 'reported', o.outcome, '{}'::jsonb));
end;
$$;

-- Stuck ops: a pending op older than 30 s did no external work and is
-- abandoned (obsolete); a dispatched op older than 30 s may or may not have
-- reached Auth and becomes uncertain (access held until reconcile).
create or replace function public.harness_rc_expire_stuck(p_staff uuid, p_op uuid)
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
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into a from harness.rc_account where auth_user_id = uid for update;
  select * into o from harness.rc_op where op_id = p_op for update;
  if o.status = 'pending' and o.created_at < now() - interval '30 seconds' then
    update harness.rc_op set status = 'obsolete', completed_at = clock_timestamp(),
           outcome = jsonb_build_object('reason', 'abandoned_pending')
     where op_id = p_op;
    update harness.rc_account set in_flight_op = null, updated_at = now()
     where auth_user_id = uid and in_flight_op = p_op;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'op_abandoned', p_op, a.generation, jsonb_build_object('by_staff', true));
    return jsonb_build_object('ok', true, 'status', 'obsolete');
  elsif o.status = 'dispatched' and o.dispatched_at < now() - interval '30 seconds' then
    update harness.rc_op set status = 'uncertain', completed_at = clock_timestamp(),
           outcome = jsonb_build_object('reason', 'dispatch_timed_out')
     where op_id = p_op;
    update harness.rc_account set reconcile_required = true, updated_at = now() where auth_user_id = uid;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'op_uncertain', p_op, a.generation, jsonb_build_object('reason', 'dispatch_timed_out', 'by_staff', true));
    return jsonb_build_object('ok', true, 'status', 'uncertain', 'access_held', true);
  end if;
  return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_stuck', 'status', o.status);
end;
$$;

-- ---------------------------------------------------------------------------
-- Relink, hold, reconcile, gate.
-- ---------------------------------------------------------------------------

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
  em text;
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
  -- Relink is the authorised review: it approves the account's CURRENT login.
  select u.email into em from auth.users u where u.id = p_uid;
  update harness.rc_account
     set member_id = coalesce(p_member_id, member_id), link_revision = link_revision + 1,
         binding_review_required = false, approved_email = em, updated_at = now()
   where auth_user_id = p_uid;
  g := harness.rc_advance(p_uid, 'relinked', null,
         jsonb_build_object('member_changed', p_member_id is not null and p_member_id <> a.member_id,
                            'approved_login_changed', em is distinct from a.approved_email));
  return jsonb_build_object('ok', true, 'link_revision', a.link_revision + 1, 'generation', g,
                            'member_id', coalesce(p_member_id, a.member_id));
end;
$$;

-- Holds always apply, even with work in flight, and supersede issued grants.
create or replace function public.harness_rc_hold(p_staff uuid, p_uid uuid, p_on boolean)
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
  update harness.rc_account set security_hold = p_on, updated_at = now() where auth_user_id = p_uid;
  if p_on then
    g := harness.rc_advance(p_uid, 'hold_applied', a.in_flight_op,
                            jsonb_build_object('in_flight', a.in_flight_op is not null));
  else
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (p_uid, 'hold_released', a.in_flight_op, a.generation,
            jsonb_build_object('in_flight', a.in_flight_op is not null));
  end if;
  return jsonb_build_object('ok', true, 'security_hold', p_on, 'in_flight', a.in_flight_op is not null,
                            'generation', coalesce(g, a.generation));
end;
$$;

-- Reconcile an uncertain op only when no session created before the op's
-- dispatch (or creation) is still live; the Edge Function can force that by
-- an Auth Admin password reset to an undisclosed random value first. Sets the
-- trust epoch: only sessions created from now on pass the recovery gate.
-- Clears reconcile_required; never clears a security hold.
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
  live_old integer;
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
  select count(*) into live_old from auth.sessions s
   where s.user_id = uid and s.created_at < coalesce(o.dispatched_at, o.created_at)
     and (s.not_after is null or s.not_after > now());
  if live_old > 0 then
    insert into harness.rc_event (auth_user_id, kind, op_id, detail)
    values (uid, 'reconcile_refused', p_op, jsonb_build_object('reason', 'sessions_not_revoked', 'live', live_old));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'sessions_not_revoked',
                              'pre_dispatch_sessions_live', live_old);
  end if;
  update harness.rc_op set status = 'reconciled' where op_id = p_op;
  update harness.rc_account
     set reconcile_required = false, in_flight_op = null, trusted_since = now(), updated_at = now()
   where auth_user_id = uid;
  g := harness.rc_advance(uid, 'reconciled', p_op, jsonb_build_object('note', left(coalesce(p_note, ''), 80)));
  return jsonb_build_object('ok', true, 'status', 'reconciled', 'generation', g);
end;
$$;

-- Full private-data gate: 1.2 trusted password session, a session created
-- after the account's trust epoch, no hold, no unresolved work, no pending
-- binding review.
create or replace function public.harness_recovery_probe()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with a as (select * from harness.rc_account where auth_user_id = auth.uid()),
  s as (
    select s.created_at from auth.sessions s
     where s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid and s.user_id = auth.uid()
  )
  select jsonb_build_object(
    'trusted_password_session', harness.trusted_password_session(),
    'enrolled', exists (select 1 from a),
    'session_after_trust_epoch', coalesce((select s.created_at >= a.trusted_since from s, a), false),
    'security_hold', (select security_hold from a),
    'reconcile_required', (select reconcile_required from a),
    'in_flight', (select in_flight_op is not null from a),
    'binding_review_required', (select binding_review_required from a),
    'generation', (select generation from a),
    'allowed', coalesce(harness.trusted_password_session()
      and (select s.created_at >= a.trusted_since from s, a)
      and (select not security_hold and not reconcile_required and in_flight_op is null
                  and not binding_review_required from a), false)
  );
$$;
revoke all on function public.harness_recovery_probe() from public, anon;
grant execute on function public.harness_recovery_probe() to authenticated;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.harness_rc_enroll(uuid, text)',
    'public.harness_rc_request(text, text)',
    'public.harness_rc_issue(uuid, uuid, text, uuid, uuid, integer, integer)',
    'public.harness_rc_begin(text, text)',
    'public.harness_rc_dispatch(uuid, bigint)',
    'public.harness_rc_complete(uuid, bigint, jsonb)',
    'public.harness_rc_replay_complete(uuid, uuid)',
    'public.harness_rc_expire_stuck(uuid, uuid)',
    'public.harness_rc_relink(uuid, uuid, uuid, integer)',
    'public.harness_rc_hold(uuid, uuid, boolean)',
    'public.harness_rc_reconcile(uuid, uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Observation (exactly sql/observe_recovery_state.sql, parameterised).
-- ---------------------------------------------------------------------------
create or replace function public.harness_rc_observe(p_tag_prefix text, p_since timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with acct as (
  select a.*, coalesce(u.email, a.approved_email) as email, u.id is null as auth_user_deleted
  from harness.rc_account a
  left join auth.users u on u.id = a.auth_user_id
  where p_tag_prefix ~ '^[a-z0-9][a-z0-9-]{0,23}$'
    and coalesce(u.email, a.approved_email) like 'israelmuyoba+bicauth-' || p_tag_prefix || '%@gmail.com'

)
select jsonb_build_object(
  'observed_at', now(),
  'accounts', (
    select jsonb_agg(jsonb_build_object(
      'account', regexp_replace(a.email, '^[^+]*', '…'),
      'user', 'h:' || left(encode(sha256(a.auth_user_id::text::bytea), 'hex'), 10),
      'member', 'h:' || left(encode(sha256(a.member_id::text::bytea), 'hex'), 10),
      'generation', a.generation,
      'link_revision', a.link_revision,
      'security_hold', a.security_hold,
      'reconcile_required', a.reconcile_required,
      'binding_review_required', a.binding_review_required,
      'approved_login', regexp_replace(coalesce(a.approved_email, ''), '^[^+]*', '…'),
      'approved_login_is_current', a.approved_email is not distinct from a.email,
      'auth_user_deleted', a.auth_user_deleted,
      'trusted_since', a.trusted_since,
      'in_flight_op', case when a.in_flight_op is null then null
                      else 'h:' || left(encode(sha256(a.in_flight_op::text::bytea), 'hex'), 10) end,
      'live_sessions', (select count(*) from auth.sessions s where s.user_id = a.auth_user_id
                          and (s.not_after is null or s.not_after > now())),
      'grants', (select coalesce(jsonb_agg(jsonb_build_object(
          'grant', 'h:' || left(encode(sha256(g.grant_id::text::bytea), 'hex'), 10),
          'status', g.status, 'reason', g.status_reason, 'generation', g.generation,
          'link_revision', g.link_revision, 'case_id', g.case_id,
          'expired', g.expires_at <= now()) order by g.created_at), '[]'::jsonb)
        from harness.rc_grant g where g.auth_user_id = a.auth_user_id),
      'ops', (select coalesce(jsonb_agg(jsonb_build_object(
          'op', 'h:' || left(encode(sha256(o.op_id::text::bytea), 'hex'), 10),
          'status', o.status, 'generation', o.generation, 'outcome', o.outcome,
          'sessions_at_dispatch', o.sessions_at_dispatch,
          'late_outcomes', o.late_outcomes) order by o.created_at), '[]'::jsonb)
        from harness.rc_op o where o.auth_user_id = a.auth_user_id),
      'events', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', e.id, 'at', e.at, 'kind', e.kind,
          'op', case when e.op_id is null then null
                else 'h:' || left(encode(sha256(e.op_id::text::bytea), 'hex'), 10) end,
          'grant', case when e.grant_id is null then null
                   else 'h:' || left(encode(sha256(e.grant_id::text::bytea), 'hex'), 10) end,
          'generation_before', e.generation_before, 'generation_after', e.generation_after,
          'detail', e.detail) order by e.id), '[]'::jsonb)
        from harness.rc_event e where e.auth_user_id = a.auth_user_id and e.at > p_since)
    ) order by a.email)
    from acct a
  ),
  'requests', (
    select jsonb_build_object(
      'open', count(*) filter (where q.status = 'open' and q.expires_at > now()),
      'bound', count(*) filter (where q.status = 'bound'),
      'expired_unbound', count(*) filter (where q.status = 'open' and q.expires_at <= now()))
    from harness.rc_request q
    where q.created_at > p_since
  ),
  'unbound_rejections', (
    select count(*) from harness.rc_event e
    where e.auth_user_id is null and e.at > p_since
  )
)
$$;
revoke all on function public.harness_rc_observe(text, timestamptz) from public, anon, authenticated;
grant execute on function public.harness_rc_observe(text, timestamptz) to service_role;
