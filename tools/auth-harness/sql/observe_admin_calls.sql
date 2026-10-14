-- Read-only (ClickHouse, Supabase MCP query_logs, NOT Postgres): Auth Admin
-- API requests (/auth/v1/admin/...) and harness-recovery function calls in a
-- window, by method and status. Used to show that refused callers caused no
-- Auth Admin call. Pass the window as iso_timestamp_start/end and pipe the raw
-- JSON into `run.mjs attach --source sql/observe_admin_calls.sql --via supabase-mcp-query_logs`.
select
  source,
  log_attributes['request.method'] as method,
  multiIf(log_attributes['request.path'] like '/auth/v1/admin/%', 'auth_admin',
          log_attributes['request.pathname'] like '/functions/v1/harness-recovery%', 'harness_recovery_function',
          'other') as target,
  log_attributes['response.status_code'] as status,
  count(*) as requests
from logs
where source in ('edge_logs', 'function_edge_logs')
  and (log_attributes['request.path'] like '/auth/v1/admin/%'
       or log_attributes['request.pathname'] like '/functions/v1/harness-recovery%')
group by source, method, target, status
order by source, target, method, status
