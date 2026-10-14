-- Read-only ClickHouse query for Supabase MCP query_logs (project
-- szfyfezfvxyuvovnnakr), story 1.2 hosted phone track. It has NO time filter
-- of its own: the window is the iso_timestamp_start/end passed to query_logs,
-- and lines ingested after the call are not included (log-ingestion lag).
-- Lists every Auth log line that mentions SMS or Twilio, reduced to non-secret
-- fields: actor ids, IPs and request ids are dropped and the phone is cut to
-- its last 4 digits. It does not identify a successful send directly: what a
-- successful send logs was not observed on this project (no provider exists).
-- "0 successful sends" is therefore an inference: every SMS-channel request
-- line in the window ended with status 500 and a provider error, paired with
-- its audit line. Pipe the raw JSON result into
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
