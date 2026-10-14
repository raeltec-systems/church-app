-- Read-only: recovery-fence state for the synthetic harness accounts whose
-- plus-address tag starts with :tag_prefix (e.g. r13-). Ids are returned
-- only as short digests (same 'h:' + 10 hex as the harness); grant digests,
-- emails and password hashes are never selected. Events can be limited to
-- those after :since (an RFC3339 timestamp; use '-infinity' for all).
-- Run via Supabase MCP execute_sql against szfyfezfvxyuvovnnakr after
-- replacing :tag_prefix and :since, then pipe the raw JSON into
-- `run.mjs attach --source sql/observe_recovery_state.sql`.
with acct as (
  select a.*, coalesce(u.email, a.approved_email) as email, u.id is null as auth_user_deleted
  from harness.rc_account a
  left join auth.users u on u.id = a.auth_user_id
  where coalesce(u.email, a.approved_email) like 'israelmuyoba+bicauth-' || ':tag_prefix' || '%@gmail.com'

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
        from harness.rc_event e where e.auth_user_id = a.auth_user_id and e.at > ':since'::timestamptz)
    ) order by a.email)
    from acct a
  ),
  'requests', (
    select jsonb_build_object(
      'open', count(*) filter (where q.status = 'open' and q.expires_at > now()),
      'bound', count(*) filter (where q.status = 'bound'),
      'expired_unbound', count(*) filter (where q.status = 'open' and q.expires_at <= now()))
    from harness.rc_request q
    where q.created_at > ':since'::timestamptz
  ),
  'unbound_rejections', (
    select count(*) from harness.rc_event e
    where e.auth_user_id is null and e.at > ':since'::timestamptz
  )
) as observation;
