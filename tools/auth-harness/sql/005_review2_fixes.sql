-- Auth harness recovery fence, second review fixes (story 1.3).
-- Apply ONLY to szfyfezfvxyuvovnnakr, after 001-004, as migration
-- auth_harness_009_review2_fixes. Non-destructive: adds a column and
-- functions, replaces function bodies. The superseded 3-argument reconcile
-- and 4-argument relink are retired by revoking EXECUTE (not dropped).
--
--   * Force-revoke target is resolved server-side from the op
--     (harness_rc_force_revoke_target): the op must exist, be uncertain and
--     belong to an enrolled account; a caller-supplied uid that differs is
--     refused and recorded. A 'force_revoke' event records the staff id.
--   * rc_op.reconciled_at is set on every reconcile; the late-change re-open
--     window (1 h) is measured from it.
--   * Relink requires the expected live login and refuses if Auth holds a
--     different one; the approved login (masked) is returned.
--   * Every staff-driven event carries the staff auth uid; reconcile events
--     carry forced: true|false.

alter table harness.rc_op add column if not exists reconciled_at timestamptz;

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
            or (o.status = 'reconciled' and o.reconciled_at > now() - interval '1 hour'))
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

-- Resolve and check the force-revoke target BEFORE any Auth Admin call.
create or replace function public.harness_rc_force_revoke_target(p_staff uuid, p_op uuid, p_claimed_uid uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  o harness.rc_op;
begin
  if not exists (select 1 from harness.rc_staff s where s.auth_user_id = p_staff) then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  select o2.auth_user_id into uid from harness.rc_op o2 where o2.op_id = p_op;
  if uid is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  perform 1 from harness.rc_account where auth_user_id = uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into o from harness.rc_op where op_id = p_op for update;
  if p_claimed_uid is not null and p_claimed_uid <> uid then
    insert into harness.rc_event (auth_user_id, kind, op_id, detail)
    values (uid, 'force_revoke_refused', p_op, jsonb_build_object('reason', 'uid_mismatch', 'staff', p_staff));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'uid_mismatch');
  end if;
  if o.status <> 'uncertain' then
    insert into harness.rc_event (auth_user_id, kind, op_id, detail)
    values (uid, 'force_revoke_refused', p_op,
            jsonb_build_object('reason', 'op_not_uncertain', 'op_status', o.status, 'staff', p_staff));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'op_not_uncertain', 'status', o.status);
  end if;
  insert into harness.rc_event (auth_user_id, kind, op_id, detail)
  values (uid, 'force_revoke', p_op, jsonb_build_object('staff', p_staff));
  return jsonb_build_object('ok', true, 'auth_user_id', uid);
end;
$$;

-- Retired: reconcile without the forced flag.
revoke all on function public.harness_rc_reconcile(uuid, uuid, text) from public, anon, authenticated, service_role;

create or replace function public.harness_rc_reconcile(p_staff uuid, p_op uuid, p_note text, p_forced boolean)
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
    values (uid, 'reconcile_refused', p_op, jsonb_build_object('reason', 'sessions_not_revoked', 'live', live_old,
            'staff', p_staff, 'forced', coalesce(p_forced, false)));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'sessions_not_revoked',
                              'pre_dispatch_sessions_live', live_old);
  end if;
  update harness.rc_op set status = 'reconciled', reconciled_at = clock_timestamp() where op_id = p_op;
  update harness.rc_account
     set reconcile_required = false, in_flight_op = null, trusted_since = now(), updated_at = now()
   where auth_user_id = uid;
  g := harness.rc_advance(uid, 'reconciled', p_op, jsonb_build_object('note', left(coalesce(p_note, ''), 80),
         'staff', p_staff, 'forced', coalesce(p_forced, false)));
  return jsonb_build_object('ok', true, 'status', 'reconciled', 'generation', g, 'forced', coalesce(p_forced, false));
end;
$$;

-- Retired: relink without the expected login.
revoke all on function public.harness_rc_relink(uuid, uuid, uuid, integer) from public, anon, authenticated, service_role;

create or replace function public.harness_rc_relink(
  p_staff uuid, p_uid uuid, p_member_id uuid, p_expected_link_revision integer, p_expected_email text)
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
    values (p_uid, 'relink_refused', a.in_flight_op, a.generation,
            jsonb_build_object('reason', 'unresolved_work', 'staff', p_staff));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'unresolved_work');
  end if;
  if a.link_revision <> p_expected_link_revision then
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'stale_link_revision',
                              'current_revision', a.link_revision);
  end if;
  -- Relink approves exactly the login staff reviewed: it must still be the
  -- account's live Auth email.
  select u.email into em from auth.users u where u.id = p_uid;
  if p_expected_email is null or lower(coalesce(em, '')) <> lower(p_expected_email) then
    insert into harness.rc_event (auth_user_id, kind, generation_before, detail)
    values (p_uid, 'relink_refused', a.generation, jsonb_build_object('reason', 'login_changed_since_review', 'staff', p_staff));
    return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'login_changed_since_review');
  end if;
  update harness.rc_account
     set member_id = coalesce(p_member_id, member_id), link_revision = link_revision + 1,
         binding_review_required = false, approved_email = em, updated_at = now()
   where auth_user_id = p_uid;
  g := harness.rc_advance(p_uid, 'relinked', null,
         jsonb_build_object('member_changed', p_member_id is not null and p_member_id <> a.member_id,
                            'approved_login_changed', em is distinct from a.approved_email, 'staff', p_staff));
  return jsonb_build_object('ok', true, 'link_revision', a.link_revision + 1, 'generation', g,
                            'member_id', coalesce(p_member_id, a.member_id),
                            'approved_login', regexp_replace(em, '^[^+]*', '…'));
end;
$$;

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
                            jsonb_build_object('in_flight', a.in_flight_op is not null, 'staff', p_staff));
  else
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (p_uid, 'hold_released', a.in_flight_op, a.generation,
            jsonb_build_object('in_flight', a.in_flight_op is not null, 'staff', p_staff));
  end if;
  return jsonb_build_object('ok', true, 'security_hold', p_on, 'in_flight', a.in_flight_op is not null,
                            'generation', coalesce(g, a.generation));
end;
$$;

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
    values (uid, 'op_abandoned', p_op, a.generation, jsonb_build_object('by_staff', true, 'staff', p_staff));
    return jsonb_build_object('ok', true, 'status', 'obsolete');
  elsif o.status = 'dispatched' and o.dispatched_at < now() - interval '30 seconds' then
    update harness.rc_op set status = 'uncertain', completed_at = clock_timestamp(),
           outcome = jsonb_build_object('reason', 'dispatch_timed_out')
     where op_id = p_op;
    update harness.rc_account set reconcile_required = true, updated_at = now() where auth_user_id = uid;
    insert into harness.rc_event (auth_user_id, kind, op_id, generation_before, detail)
    values (uid, 'op_uncertain', p_op, a.generation,
            jsonb_build_object('reason', 'dispatch_timed_out', 'by_staff', true, 'staff', p_staff));
    return jsonb_build_object('ok', true, 'status', 'uncertain', 'access_held', true);
  end if;
  return jsonb_build_object('ok', false, 'code', 'conflict', 'reason', 'not_stuck', 'status', o.status);
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.harness_rc_force_revoke_target(uuid, uuid, uuid)',
    'public.harness_rc_reconcile(uuid, uuid, text, boolean)',
    'public.harness_rc_relink(uuid, uuid, uuid, integer, text)',
    'public.harness_rc_hold(uuid, uuid, boolean)',
    'public.harness_rc_expire_stuck(uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
