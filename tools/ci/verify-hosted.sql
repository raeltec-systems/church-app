-- Post-promotion assertions for a hosted environment (story 1.8). Read-only.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -v expected_env=staging -f tools/ci/verify-hosted.sql
-- Fails (non-zero exit) when the database marker is not the expected environment, or when the
-- private_access / outbound_sending release gates are open in a baseline that must keep them
-- closed, or when the database is an unreconciled restore (story 1.10). Production stays
-- private-disabled and sending-disabled until the owner approves those
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
  -- Story 1.9: alerting stays disabled until the owner approves Q12 thresholds and the
  -- restricted alert destination; this baseline ships no dispatcher.
  if to_regprocedure('app.ops_alert_status()') is null then
    raise exception 'verify-hosted: app.ops_alert_status() is missing (story 1.9 migration not applied)';
  end if;
  if app.ops_alert_status() ->> 'alerting' <> 'disabled' then
    raise exception 'verify-hosted: alerting is not disabled in %', v_actual;
  end if;
  -- Story 1.10: a database restored from a backup stays held until journal reconciliation;
  -- promotion must not proceed onto an unreconciled restore.
  if to_regprocedure('app.rcv_serving_hold()') is null then
    raise exception 'verify-hosted: app.rcv_serving_hold() is missing (story 1.10 migration not applied)';
  end if;
  if app.rcv_serving_hold() then
    raise exception 'verify-hosted: % is an unreconciled restore (recovery hold active); see docs/runbooks/backup-and-restore.md', v_actual;
  end if;
  raise notice 'verify-hosted: % marker confirmed; private_access and outbound_sending closed; alerting disabled; no recovery hold', v_actual;
end;
$$;

-- Story 2.7: the email-recovery reset gate (trigger identity_email_link_gate) depends on how
-- GoTrue redeems a recovery or magic link: `UPDATE auth.users SET recovery_token = ''` with the
-- password unchanged. That was proven against GoTrue v2.197.0, whose Auth schema ends at
-- migration 20260831180000. A different Auth schema means a GoTrue that has not been proven:
-- fail loudly, re-run the redemption canary (docs/runbooks/identity-access.md, "Reset-gate
-- canary") and the recovery E2E, then add the version here. The columns and the trigger the
-- gate relies on are asserted as well. Skipped until the 2.7 migration is applied.
do $$
declare
  c_proven constant text[] := array['20260831180000'];  -- GoTrue v2.197.0
  v_auth_schema text;
  v_missing text[];
begin
  if to_regprocedure('app.identity_on_auth_email_link_redeemed()') is null then
    raise notice 'verify-hosted: story 2.7 reset gate not applied; Auth version check skipped';
    return;
  end if;
  select max(m.version) into v_auth_schema from auth.schema_migrations m;
  if v_auth_schema is null or not (v_auth_schema = any (c_proven)) then
    raise exception 'verify-hosted: Auth schema % is not one the 2.7 reset gate was proven against (%); run the reset-gate canary and the recovery E2E before allowing it',
      coalesce(v_auth_schema, 'unknown'), array_to_string(c_proven, ', ');
  end if;
  select array_agg(x.t || '.' || x.c) into v_missing
    from (values ('users', 'recovery_token'), ('users', 'encrypted_password'),
                 ('users', 'email_change'), ('users', 'email_change_token_new'),
                 ('users', 'email_change_token_current'), ('users', 'email_change_confirm_status'),
                 ('one_time_tokens', 'token_type'), ('one_time_tokens', 'token_hash')) x(t, c)
   where not exists (select 1 from information_schema.columns ic
                      where ic.table_schema = 'auth' and ic.table_name = x.t and ic.column_name = x.c);
  if v_missing is not null then
    raise exception 'verify-hosted: Auth columns the 2.7 reset gate relies on are missing: %', v_missing;
  end if;
  if not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid = 'auth.users'::regclass and t.tgname = 'identity_email_link_gate'
          and t.tgenabled = 'O'
          and t.tgfoid = 'app.identity_on_auth_email_link_redeemed()'::regprocedure) then
    raise exception 'verify-hosted: the 2.7 reset gate trigger identity_email_link_gate is missing or disabled';
  end if;
  raise notice 'verify-hosted: 2.7 reset gate present on proven Auth schema %', v_auth_schema;
end;
$$;
