-- Read-only ClickHouse query for Supabase MCP query_logs (project
-- szfyfezfvxyuvovnnakr). Pass iso_timestamp_start/end covering the harness run.
-- Groups Auth API lines by path and error_code, and counts lines that mention
-- SMS or Twilio. Pipe the raw JSON result into
-- `run.mjs attach --source sql/observe_auth_logs.sql`.
select
  JSONExtractString(event_message, 'path') as path,
  JSONExtractString(event_message, 'error_code') as error_code,
  count() as n,
  countIf(positionCaseInsensitive(event_message, 'sms') > 0
       or positionCaseInsensitive(event_message, 'twilio') > 0) as sms_mentions
from logs
where source in ('auth_logs', 'auth_audit_logs')
group by path, error_code
order by path, error_code
