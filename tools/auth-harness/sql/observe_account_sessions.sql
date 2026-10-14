-- Read-only: live auth.sessions for ONE synthetic harness account, with the
-- AMR methods recorded for each session. Ids are returned only as short
-- digests. Run via Supabase MCP execute_sql against szfyfezfvxyuvovnnakr,
-- after replacing :account_email with the account's plus-address (it must
-- match israelmuyoba+bicauth-%@gmail.com). Pipe the raw JSON result into
-- `run.mjs attach --source sql/observe_account_sessions.sql`.
select jsonb_build_object(
  'observed_at', now(),
  'account', regexp_replace(u.email, '^[^+]*', '…'),
  'user', 'h:' || left(encode(sha256(u.id::text::bytea), 'hex'), 10),
  'live_sessions', count(s.id),
  'sessions', coalesce(jsonb_agg(jsonb_build_object(
      'session_id', 'h:' || left(encode(sha256(s.id::text::bytea), 'hex'), 10),
      'created_at', s.created_at,
      'not_after', s.not_after,
      'amr_methods', (select jsonb_agg(a.authentication_method order by a.created_at)
                      from auth.mfa_amr_claims a where a.session_id = s.id)
    ) order by s.created_at) filter (where s.id is not null), '[]'::jsonb)
) as observation
from auth.users u
left join auth.sessions s on s.user_id = u.id
where u.email = ':account_email'
  and u.email like 'israelmuyoba+bicauth-%@gmail.com'
group by u.id, u.email;
