-- Read-only ClickHouse query for Supabase MCP query_logs (project
-- szfyfezfvxyuvovnnakr), story 1.2 hosted phone track. Pass
-- iso_timestamp_start/end covering the harness run. Lists every Auth log line
-- that mentions SMS or Twilio, reduced to non-secret fields: actor ids, IPs and
-- request ids are dropped and the phone is cut to its last 4 digits. A
-- successful SMS send would show as an /otp (or /resend, /user phone change,
-- /reauthenticate) line with status 200; a provider failure shows status 500
-- with the provider error. Pipe the raw JSON result into
-- `run.mjs attach --source sql/observe_auth_sms_attempts.sql`.
select
  timestamp,
  source,
  coalesce(nullif(JSONExtractString(event_message, 'auth_event', 'action'), ''),
           JSONExtractString(event_message, 'auth_audit_event', 'action')) as action,
  coalesce(nullif(JSONExtractString(event_message, 'auth_event', 'traits', 'channel'), ''),
           JSONExtractString(event_message, 'auth_audit_event', 'traits', 'channel')) as channel,
  right(coalesce(nullif(JSONExtractString(event_message, 'auth_event', 'actor_username'), ''),
                 JSONExtractString(event_message, 'auth_audit_event', 'actor_username')), 4) as actor_last4,
  JSONExtractString(event_message, 'path') as path,
  JSONExtractInt(event_message, 'status') as status,
  JSONExtractString(event_message, 'error') as error,
  JSONExtractString(event_message, 'error_code') as error_code,
  JSONExtractString(event_message, 'level') as level
from logs
where source in ('auth_logs', 'auth_audit_logs')
  and (positionCaseInsensitive(event_message, 'sms') > 0
       or positionCaseInsensitive(event_message, 'twilio') > 0)
order by timestamp, source
