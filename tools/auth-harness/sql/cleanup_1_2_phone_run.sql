-- Story 1.2 hosted phone run (2026-10-06): the exact scoped cleanup that was
-- executed once through Supabase MCP execute_sql against szfyfezfvxyuvovnnakr
-- (harness step H93). NOT read-only: it deletes ONLY this run's synthetic
-- users (phones in the NANP fictional range +1-202-555-01xx and the ph1/e2
-- plus-addresses) and their harness.private_probe rows. auth.users deletion
-- cascades to identities, sessions, refresh tokens and one-time tokens.
-- Result at H93: probe_rows_deleted = 2, users_deleted = 3.
-- Verify with sql/observe_cleanup_1_2_phone_run.sql afterwards.
with targets as (
  select id from auth.users
  where phone like '120255501%'
     or email in ('israelmuyoba+bicauth-ph1@gmail.com', 'israelmuyoba+bicauth-e2@gmail.com')
), p as (
  delete from harness.private_probe where user_id in (select id from targets) returning 1
), u as (
  delete from auth.users where id in (select id from targets) returning 1
)
select (select count(*) from p) probe_rows_deleted, (select count(*) from u) users_deleted;
