-- Read-only (story 1.2 hosted phone track): phone users in the synthetic NANP
-- fictional range +1-202-555-01xx, their sessions with AMR methods, and every
-- trace an SMS send would leave (phone OTP/confirmation/change tokens, one-time
-- tokens, phone MFA factors). Ids and phones are returned only as digests /
-- last-4. Run via Supabase MCP execute_sql against szfyfezfvxyuvovnnakr. Pipe
-- the raw JSON result into `run.mjs attach --source sql/observe_phone_sms_state.sql`.
select jsonb_build_object(
  'observed_at', now(),
  'phone_users', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user', 'h:' || left(encode(sha256(u.id::text::bytea), 'hex'), 10),
      'phone', '…' || right(u.phone, 4),
      'phone_confirmed', u.phone_confirmed_at is not null,
      'email', regexp_replace(coalesce(u.email, ''), '^[^+]*', '…'),
      'email_confirmed', u.email_confirmed_at is not null,
      'pending_new_email', coalesce(u.email_change, '') <> '',
      'has_confirmation_token', coalesce(u.confirmation_token, '') <> '',
      'has_phone_change_token', coalesce(u.phone_change_token, '') <> '',
      'has_reauthentication_token', coalesce(u.reauthentication_token, '') <> '',
      'confirmation_sent_at', u.confirmation_sent_at,
      'phone_change_sent_at', u.phone_change_sent_at,
      'reauthentication_sent_at', u.reauthentication_sent_at,
      'identities', (select jsonb_agg(i.provider order by i.provider) from auth.identities i where i.user_id = u.id),
      'live_sessions', (select count(*) from auth.sessions s where s.user_id = u.id),
      'sessions', (select coalesce(jsonb_agg(jsonb_build_object(
          'session_id', 'h:' || left(encode(sha256(s.id::text::bytea), 'hex'), 10),
          'created_at', s.created_at,
          'not_after', s.not_after,
          'amr_methods', (select jsonb_agg(a.authentication_method order by a.created_at)
                          from auth.mfa_amr_claims a where a.session_id = s.id)
        ) order by s.created_at), '[]'::jsonb) from auth.sessions s where s.user_id = u.id)
    ) order by u.phone)
    from auth.users u where u.phone like '120255501%'), '[]'::jsonb),
  'users_with_any_phone', (select count(*) from auth.users where coalesce(phone, '') <> ''),
  -- Same-account check: every user holding a story-1.2 phone-track alias address.
  'users_with_ph_alias_email', (select count(*) from auth.users
                                where email like 'israelmuyoba+bicauth-ph%@gmail.com'
                                   or email_change like 'israelmuyoba+bicauth-ph%@gmail.com'),
  'phone_one_time_tokens', (select count(*) from auth.one_time_tokens t
                            where t.token_type::text in ('confirmation_token', 'phone_change_token', 'reauthentication_token')
                              and t.relates_to like '1202555%'),
  'phone_mfa_factors', (select count(*) from auth.mfa_factors f where f.factor_type::text = 'phone')
) as observation;
