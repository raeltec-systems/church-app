-- LOCAL stack only (story 1.2 phone track). Read-only: the Auth user(s) for one
-- synthetic identifier (phone in the fictional +1 202 555 0100-0199 range, or a
-- +bicauth-l… plus-address), their identities and live auth.sessions with the
-- AMR methods recorded per session. Ids are returned only as short digests.
-- Run: psql "$LOCAL_DB_URL" -X -A -t -v ident='+12025550199' \
--        -f tools/auth-harness/sql/local/observe_local_account_sessions.sql
-- and pipe the output into
-- `run.mjs attach --source sql/local/observe_local_account_sessions.sql --via local-psql`.
select jsonb_build_object(
  'observed_at', now(),
  'ident', case when :'ident' like '%@%' then regexp_replace(:'ident', '^[^+]*', '…')
                else '…' || right(:'ident', 4) end,
  'users_matching', (select count(*) from auth.users u
                     where u.phone = ltrim(:'ident', '+') or u.email = :'ident'),
  'users', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user', 'h:' || left(encode(sha256(u.id::text::bytea), 'hex'), 10),
      'phone', case when coalesce(u.phone, '') = '' then null else '…' || right(u.phone, 4) end,
      'phone_confirmed', u.phone_confirmed_at is not null,
      'email', regexp_replace(coalesce(u.email, ''), '^[^+]*', '…'),
      'email_confirmed', u.email_confirmed_at is not null,
      'email_change_pending', coalesce(u.email_change, '') <> '',
      'identities', (select jsonb_agg(i.provider order by i.provider)
                     from auth.identities i where i.user_id = u.id),
      'live_sessions', (select count(*) from auth.sessions s where s.user_id = u.id),
      'sessions', coalesce((select jsonb_agg(jsonb_build_object(
          'session_id', 'h:' || left(encode(sha256(s.id::text::bytea), 'hex'), 10),
          'created_at', s.created_at,
          'not_after', s.not_after,
          'amr_methods', (select jsonb_agg(a.authentication_method order by a.created_at)
                          from auth.mfa_amr_claims a where a.session_id = s.id)
        ) order by s.created_at) from auth.sessions s where s.user_id = u.id), '[]'::jsonb)
    ) order by u.created_at)
    from auth.users u
    where (u.phone = ltrim(:'ident', '+') or u.email = :'ident')
      and (u.phone like '120255501%' or u.email like 'israelmuyoba+bicauth-l%@gmail.com')
  ), '[]'::jsonb)
) as observation;
