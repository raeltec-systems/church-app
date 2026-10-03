-- Auth harness recovery observation RPC for story 1.3.
-- Apply ONLY to szfyfezfvxyuvovnnakr (migration auth_harness_006_recovery_observe).
-- Non-destructive and idempotent.
--
-- public.harness_rc_observe() is EXACTLY the read-only query in
-- sql/observe_recovery_state.sql with :tag_prefix and :since as parameters.
-- The Edge Function exposes it to staff (action `observe`) so the harness
-- records the raw database state itself (`rc-observe`), with no transcription.
-- It returns digests only: no grant digest, email, hash or token.

create or replace function public.harness_rc_observe(p_tag_prefix text, p_since timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with acct as (
  select a.*, u.email
  from harness.rc_account a
  join auth.users u on u.id = a.auth_user_id
  where p_tag_prefix ~ '^[a-z0-9][a-z0-9-]{0,23}$'
    and u.email like 'israelmuyoba+bicauth-' || p_tag_prefix || '%@gmail.com'

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
  'unbound_rejections', (
    select count(*) from harness.rc_event e
    where e.auth_user_id is null and e.at > p_since
  )
)
$$;
revoke all on function public.harness_rc_observe(text, timestamptz) from public, anon, authenticated;
grant execute on function public.harness_rc_observe(text, timestamptz) to service_role;
