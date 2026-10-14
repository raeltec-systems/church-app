-- Read-only (ClickHouse, Supabase MCP query_logs, NOT Postgres): scans every platform log
-- source of the target project in the run window for a system credential
-- ('sysc_<env>_' + base64url), the story 1.9 synthetic user's password shape, a secret key, and
-- whether the x-system-credential header was logged at all. Only counts are returned.
-- Pass the run window as iso_timestamp_start/end.
select
  source,
  count(*) as lines,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'sysc_(local|staging|production)_[A-Za-z0-9_-]{20}')) as system_credential_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'Sys19-[A-Za-z0-9_-]{16}')) as synthetic_user_password_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'sb_secret_[A-Za-z0-9_-]{8}')) as secret_key_like,
  countIf(mapContains(log_attributes, 'request.headers.x_system_credential')) as credential_header_logged,
  countIf(match(arrayStringConcat(mapKeys(log_attributes), ' '), 'system_credential')) as credential_key_present,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'system_command')) as system_route_lines,
  length(groupUniqArrayArray(mapKeys(log_attributes))) as distinct_attribute_keys_scanned
from logs
group by source
order by source
