-- Read-only ClickHouse query for Supabase MCP query_logs (project
-- szfyfezfvxyuvovnnakr). It has no time filter of its own: pass
-- iso_timestamp_start/end for the window under test. Lists Auth audit events
-- (actions such as user_modified, user_recovery_requested,
-- user_confirmation_requested) with the actor reduced to a masked identifier:
-- emails keep only the `+bicauth-<tag>@…` part, phones only the last 4 digits.
-- Actor ids, IPs and request ids are dropped. This shows which mail-triggering
-- actions Auth recorded; it does not prove delivery (the inbox does).
-- Pipe the raw JSON result into
-- `run.mjs attach --source sql/observe_auth_audit_actions.sql`.
select
  timestamp,
  JSONExtractString(event_message, 'auth_audit_event', 'action') as action,
  JSONExtractString(event_message, 'auth_audit_event', 'log_type') as log_type,
  multiIf(
    position(JSONExtractString(event_message, 'auth_audit_event', 'actor_username'), '@') > 0,
      concat('…', replaceRegexpOne(JSONExtractString(event_message, 'auth_audit_event', 'actor_username'), '^[^+]*', '')),
    concat('…', right(JSONExtractString(event_message, 'auth_audit_event', 'actor_username'), 4))
  ) as actor_masked,
  JSONExtractRaw(event_message, 'auth_audit_event', 'traits') as traits
from logs
where source = 'auth_audit_logs'
order by timestamp
