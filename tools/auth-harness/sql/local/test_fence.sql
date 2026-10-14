-- LOCAL CONTAINER ONLY: assertion test of the recovery fence for branches the
-- hosted run cannot reach without OAuth, phone, a 1 h wait or 30 requests.
-- Run as supabase_admin after local/00_stubs.sql and 001-005 (as postgres)
-- in a throwaway container. Any failed check raises and aborts; on success
-- the final row is a JSON summary, attached to evidence-1.3 labelled local.
\set ON_ERROR_STOP 1
create temp table t_result (n serial, check_name text, ok boolean, detail jsonb);

insert into auth.users (id, email, encrypted_password) values
  ('10000000-0000-0000-0000-00000000000f', 'israelmuyoba+bicauth-l-staff@gmail.com', 'h'),
  ('10000000-0000-0000-0000-0000000000a1', 'israelmuyoba+bicauth-l-a1@gmail.com', 'h'),
  ('10000000-0000-0000-0000-0000000000a2', 'israelmuyoba+bicauth-l-a2@gmail.com', 'h')
on conflict do nothing;
insert into harness.rc_staff values ('10000000-0000-0000-0000-00000000000f') on conflict do nothing;
select public.harness_rc_enroll('10000000-0000-0000-0000-0000000000a1', 'member');
select public.harness_rc_enroll('10000000-0000-0000-0000-0000000000a2', 'member');

do $$
declare
  s uuid := '10000000-0000-0000-0000-00000000000f';
  a uuid := '10000000-0000-0000-0000-0000000000a1';
  b uuid := '10000000-0000-0000-0000-0000000000a2';
  g0 bigint; g1 bigint; r jsonb; acct harness.rc_account; ref uuid; op jsonb; fid uuid; i int;
  function_ok boolean;
begin
  -- 1. identity insert (link) -> generation advance + binding review
  select generation into g0 from harness.rc_account where auth_user_id = a;
  insert into auth.identities (user_id, provider, provider_id) values (a, 'oauth-x', 'x1');
  select * into acct from harness.rc_account where auth_user_id = a;
  assert acct.generation = g0 + 1 and acct.binding_review_required, 'identity insert not detected';
  insert into t_result (check_name, ok, detail) values ('identity_insert_detected', true,
    jsonb_build_object('generation_before', g0, 'generation_after', acct.generation, 'binding_review_required', acct.binding_review_required));
  perform public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-a1@gmail.com');

  -- 2. MFA factor insert, status update, delete -> each detected
  insert into auth.mfa_factors (user_id, status, factor_type) values (a, 'unverified', 'totp') returning id into fid;
  select * into acct from harness.rc_account where auth_user_id = a;
  perform public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-a1@gmail.com');
  select generation into g0 from harness.rc_account where auth_user_id = a;
  update auth.mfa_factors set status = 'verified' where id = fid;
  select * into acct from harness.rc_account where auth_user_id = a;
  assert acct.generation = g0 + 1 and acct.binding_review_required, 'mfa update not detected';
  perform public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-a1@gmail.com');
  select generation into g0 from harness.rc_account where auth_user_id = a;
  delete from auth.mfa_factors where id = fid;
  select * into acct from harness.rc_account where auth_user_id = a;
  assert acct.generation = g0 + 1 and acct.binding_review_required, 'mfa delete not detected';
  insert into t_result (check_name, ok, detail) values ('mfa_factor_update_and_delete_detected', true,
    (select jsonb_agg(e.detail -> 'changed' order by e.id) from harness.rc_event e
      where e.auth_user_id = a and e.kind = 'native_credential_change' and e.detail::text like '%mfa%'));
  perform public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-a1@gmail.com');

  -- 3. phone change -> binding review
  select generation into g0 from harness.rc_account where auth_user_id = a;
  update auth.users set phone = '12025550199' where id = a;
  select * into acct from harness.rc_account where auth_user_id = a;
  assert acct.generation = g0 + 1 and acct.binding_review_required, 'phone change not detected';
  insert into t_result (check_name, ok, detail) values ('phone_change_detected', true,
    jsonb_build_object('generation_before', g0, 'generation_after', acct.generation, 'binding_review_required', true));
  perform public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-a1@gmail.com');

  -- 4. relink refuses a login that changed since review
  select * into acct from harness.rc_account where auth_user_id = a;
  r := public.harness_rc_relink(s, a, null, acct.link_revision, 'israelmuyoba+bicauth-l-other@gmail.com');
  assert r ->> 'reason' = 'login_changed_since_review', 'relink accepted a different login';
  insert into t_result (check_name, ok, detail) values ('relink_refuses_unreviewed_login', true, r);

  -- 5. expired request cannot be bound
  r := public.harness_rc_request(encode(sha256('local-exp'::bytea), 'hex'), 'israelmuyoba+bicauth-l-a1@gmail.com');
  ref := (r ->> 'request_ref')::uuid;
  update harness.rc_request set expires_at = now() - interval '1 second' where request_ref = ref;
  select * into acct from harness.rc_account where auth_user_id = a;
  r := public.harness_rc_issue(s, ref, 'c', acct.member_id, a, acct.link_revision, 600);
  assert r ->> 'reason' = 'request_expired', 'expired request was bound';
  insert into t_result (check_name, ok, detail) values ('request_expired_refused', true, r);

  -- 6. late apply after a reconcile done > 1 h after the op went uncertain
  r := public.harness_rc_request(encode(sha256('local-late'::bytea), 'hex'), 'israelmuyoba+bicauth-l-a2@gmail.com');
  ref := (r ->> 'request_ref')::uuid;
  select * into acct from harness.rc_account where auth_user_id = b;
  perform public.harness_rc_issue(s, ref, 'c', acct.member_id, b, acct.link_revision, 600);
  op := public.harness_rc_begin(encode(sha256('local-late'::bytea), 'hex'), 'israelmuyoba+bicauth-l-a2@gmail.com');
  perform public.harness_rc_dispatch((op ->> 'op_id')::uuid, (op ->> 'generation')::bigint);
  perform public.harness_rc_mark_uncertain((op ->> 'op_id')::uuid, 'injected_timeout');
  update harness.rc_op set completed_at = now() - interval '2 hours' where op_id = (op ->> 'op_id')::uuid;
  r := public.harness_rc_reconcile(s, (op ->> 'op_id')::uuid, 'late', false);
  assert (r ->> 'ok')::boolean, 'reconcile failed';
  update auth.users set encrypted_password = 'late' where id = b;
  select * into acct from harness.rc_account where auth_user_id = b;
  assert acct.reconcile_required and acct.security_hold, 'late apply after reconcile was not re-opened';
  insert into t_result (check_name, ok, detail) values ('late_apply_reopens_when_uncertain_over_1h_before_reconcile', true,
    jsonb_build_object('reconcile_required', acct.reconcile_required, 'security_hold', acct.security_hold,
      'op_status', (select status from harness.rc_op where op_id = (op ->> 'op_id')::uuid)));

  -- 7. force-revoke target checks
  r := public.harness_rc_force_revoke_target(s, (op ->> 'op_id')::uuid, a);
  assert r ->> 'reason' = 'uid_mismatch', 'mismatched uid accepted';
  insert into t_result (check_name, ok, detail) values ('force_revoke_uid_mismatch_refused', true, r);
  r := public.harness_rc_reconcile(s, (op ->> 'op_id')::uuid, 'again', false);
  r := public.harness_rc_force_revoke_target(s, (op ->> 'op_id')::uuid, null);
  assert r ->> 'reason' = 'op_not_uncertain', 'reconciled op accepted for force-revoke';
  insert into t_result (check_name, ok, detail) values ('force_revoke_non_uncertain_op_refused', true, r);
  perform public.harness_rc_hold(s, b, false);

  -- 8. rate limit: 30 requests per 10 minutes project-wide
  i := 0;
  loop
    r := public.harness_rc_request(encode(sha256(('local-rl-' || i)::bytea), 'hex'), 'israelmuyoba+bicauth-l-a1@gmail.com');
    exit when r ->> 'code' = 'rate_limited' or i > 40;
    i := i + 1;
  end loop;
  assert r ->> 'code' = 'rate_limited', 'rate limit never triggered';
  insert into t_result (check_name, ok, detail) values ('request_rate_limited', true,
    jsonb_build_object('accepted_before_limit', i, 'requests_in_window',
      (select count(*) from harness.rc_request q where q.created_at > now() - interval '10 minutes'), 'response', r));
end;
$$;

select jsonb_build_object(
  'label', 'LOCAL CONTAINER (supabase/postgres 17.11.0.002, stub auth tables), not hosted',
  'all_ok', bool_and(ok), 'checks', jsonb_agg(jsonb_build_object('check', check_name, 'ok', ok, 'detail', detail) order by n)
) from t_result;
