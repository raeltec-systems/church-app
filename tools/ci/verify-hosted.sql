-- Post-promotion assertions for a hosted environment (story 1.8). Read-only.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -v expected_env=staging -f tools/ci/verify-hosted.sql
-- Fails (non-zero exit) when the database marker is not the expected environment, or when the
-- private_access / outbound_sending release gates are open in a baseline that must keep them
-- closed. Production stays private-disabled and sending-disabled until the owner approves those
-- gates in that database.
select set_config('ci.expected_env', :'expected_env', false);

do $$
declare
  v_expected text := current_setting('ci.expected_env');
  v_actual text := app.platform_current_environment();
  v_marked boolean := exists (select 1 from app.platform_environment);
begin
  if v_expected not in ('staging', 'production') then
    raise exception 'verify-hosted: unknown expected environment %', v_expected;
  end if;
  if not v_marked then
    raise exception '%', format(
      'verify-hosted: database has no environment marker (owner step: select app.platform_set_environment(%L, <name>))',
      v_expected);
  end if;
  if v_actual <> v_expected then
    raise exception 'verify-hosted: database is marked %, expected %', v_actual, v_expected;
  end if;
  if app.policy_is_open('private_access') then
    raise exception 'verify-hosted: private_access gate is open in %', v_actual;
  end if;
  if app.policy_is_open('outbound_sending') then
    raise exception 'verify-hosted: outbound_sending gate is open in %', v_actual;
  end if;
  raise notice 'verify-hosted: % marker confirmed; private_access and outbound_sending closed', v_actual;
end;
$$;
