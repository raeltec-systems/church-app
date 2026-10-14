-- Read-only: after sql/cleanup_1_2_phone_run.sql, shows that the story 1.2
-- phone run's synthetic users are gone and lists the synthetic accounts that
-- remain (story 1.2 e1 and the story 1.3 accounts), masked to `…+bicauth-<tag>@…`.
-- Run via Supabase MCP execute_sql against szfyfezfvxyuvovnnakr. Pipe the raw
-- JSON result into `run.mjs attach --source sql/observe_cleanup_1_2_phone_run.sql`.
select jsonb_build_object(
  'observed_at', now(),
  'run_users_remaining', (select count(*) from auth.users
                          where phone like '120255501%'
                             or email in ('israelmuyoba+bicauth-ph1@gmail.com', 'israelmuyoba+bicauth-e2@gmail.com')),
  'run_probe_rows_remaining', (select count(*) from harness.private_probe pp
                               where not exists (select 1 from auth.users u where u.id = pp.user_id)),
  'e1_present', exists (select 1 from auth.users where email = 'israelmuyoba+bicauth-e1@gmail.com'),
  'r13_accounts_present', (select count(*) from auth.users where email like 'israelmuyoba+bicauth-r13-%@gmail.com'),
  'remaining_synthetic_accounts', (select jsonb_agg(regexp_replace(email, '^[^+]*', '…') order by email)
                                   from auth.users where email like 'israelmuyoba+bicauth-%@gmail.com'),
  'users_total', (select count(*) from auth.users)
) as observation;
