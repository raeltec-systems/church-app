-- LOCAL stack only (story 1.2). Read-only: shows that no SMS-side state exists
-- for the harness phone users in the local Auth database: no SMS (phone) MFA
-- factors, no phone one-time tokens, and no phone confirmation/change tokens.
-- Run: psql "$LOCAL_DB_URL" -X -A -t -f tools/auth-harness/sql/local/observe_local_sms_state.sql
-- and pipe into `run.mjs attach --source sql/local/observe_local_sms_state.sql --via local-psql`.
select jsonb_build_object(
  'observed_at', now(),
  'postgres_version', version(),
  'harness_phone_users', (select count(*) from auth.users where phone like '26097000%'),
  'phone_mfa_factors', (select count(*) from auth.mfa_factors where factor_type::text = 'phone'),
  'phone_one_time_tokens', (select count(*) from auth.one_time_tokens
                            where relates_to like '26097000%'),
  'users_with_phone_confirmation_token', (select count(*) from auth.users
                                          where phone like '26097000%'
                                            and coalesce(confirmation_token, '') <> ''),
  'users_with_phone_change_token', (select count(*) from auth.users
                                    where phone like '26097000%'
                                      and coalesce(phone_change_token, '') <> ''),
  'phone_users_with_confirmation_sent_at', (select count(*) from auth.users
                                            where phone like '26097000%'
                                              and confirmation_sent_at is not null)
) as observation;
