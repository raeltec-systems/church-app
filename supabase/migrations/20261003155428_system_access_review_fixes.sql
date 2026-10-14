-- Story 1.9 review fixes (forward, non-destructive; replaces two functions in place).
--   * app.sys_disable_principal also revokes the principal's unrevoked credentials, and records
--     one credential_revoked operator action for each.
--   * app.ops_health_snapshot counts only this environment's audit rows, and counts a
--     credential as active only while its principal is enabled.

create or replace function app.sys_disable_principal(p_principal_id uuid, p_operator text) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_credential uuid;
begin
  perform app.ops_require_operator(p_operator);
  update app.sys_principals p set disabled_at = now()
   where p.principal_id = p_principal_id and p.disabled_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'unknown or already disabled principal';
  end if;
  perform app.ops_record_action(p_operator, 'principal_disabled', p_principal_id);
  for v_credential in
    update app.sys_credentials c set revoked_at = now(), revoked_by = p_operator
     where c.principal_id = p_principal_id and c.revoked_at is null
    returning c.credential_id
  loop
    perform app.ops_record_action(p_operator, 'credential_revoked', v_credential);
  end loop;
end;
$$;

create or replace function app.ops_health_snapshot(p_window interval default interval '24 hours')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_since timestamptz := now() - coalesce(p_window, interval '24 hours');
  v_env text := app.platform_current_environment();
begin
  return jsonb_build_object(
    'environment', v_env,
    'generated_at', app.cmd_utc(now()),
    'window_seconds', extract(epoch from coalesce(p_window, interval '24 hours'))::bigint,
    'system_route', jsonb_build_object(
      'succeeded', (select count(*) from app.sys_audit a
                     where a.environment = v_env and a.occurred_at >= v_since and a.outcome = 'succeeded'),
      'replayed', (select count(*) from app.sys_audit a
                    where a.environment = v_env and a.occurred_at >= v_since and a.outcome = 'replayed'),
      'rejected', (select count(*) from app.sys_audit a
                    where a.environment = v_env and a.occurred_at >= v_since and a.outcome = 'rejected'),
      'rejected_by_reason', coalesce((
        select jsonb_object_agg(r.reason, r.n) from (
          select a.reason, count(*) as n from app.sys_audit a
           where a.environment = v_env and a.occurred_at >= v_since and a.outcome = 'rejected'
           group by a.reason) r),
        '{}'::jsonb)),
    'synthetic_probe', (select jsonb_build_object(
        'revision', s.revision,
        'last_probe_at', case when s.last_probe_at is null then null else app.cmd_utc(s.last_probe_at) end)
       from app.sys_probe_state s),
    'principals_active', (select count(*) from app.sys_principals p
                           where p.environment = v_env and p.disabled_at is null),
    'credentials_active', (select count(*) from app.sys_credentials c
                             join app.sys_principals p on p.principal_id = c.principal_id
                            where c.environment = v_env and p.disabled_at is null
                              and c.revoked_at is null and c.expires_at > now()),
    'credentials_expiring_7d', (select count(*) from app.sys_credentials c
                                  join app.sys_principals p on p.principal_id = c.principal_id
                                 where c.environment = v_env and p.disabled_at is null
                                   and c.revoked_at is null and c.expires_at > now()
                                   and c.expires_at <= now() + interval '7 days'),
    'system_access', case when v_env in ('local', 'staging') or app.policy_is_open('ops_system_access')
                          then 'open' else 'gate_closed' end,
    'alerts', app.ops_alert_status());
end;
$$;

revoke all on function
  app.sys_disable_principal(uuid, text),
  app.ops_health_snapshot(interval)
  from public, anon, authenticated, service_role;
