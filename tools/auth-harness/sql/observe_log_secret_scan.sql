-- Read-only (ClickHouse, Supabase MCP query_logs, NOT Postgres): scans every
-- platform log source of szfyfezfvxyuvovnnakr in the run window for values
-- shaped like a harness password ('Hx!' or URL-encoded 'Hx%21' + base64url),
-- a member password set by force-revoke ('Rv!' / 'Rv%21'), a grant secret
-- ('hg_'), an operator token ('ho_'), a JWT or a secret key. It searches the
-- message AND every metadata attribute (request URL, path, query params,
-- headers, JWT payload fields), and counts lines that carry the
-- x-harness-operator header at all. Only counts (including how many distinct
-- attribute keys were scanned) are returned. Pass the run window as
-- iso_timestamp_start/end and pipe the raw JSON into
-- `run.mjs attach --source sql/observe_log_secret_scan.sql --via supabase-mcp-query_logs`.
select
  source,
  count(*) as lines,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'Hx(!|%21)[A-Za-z0-9_-]{16}')) as harness_password_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'Rv(!|%21)[A-Za-z0-9]{16}')) as force_revoke_password_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'hg_[A-Za-z0-9_-]{20}')) as grant_secret_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'ho_[A-Za-z0-9_-]{20}')) as operator_token_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'eyJ[A-Za-z0-9_-]+(\\.|%2E)eyJ[A-Za-z0-9_-]+(\\.|%2E)')) as jwt_like,
  countIf(match(concat(event_message, ' ', arrayStringConcat(mapValues(log_attributes), ' ')), 'sb_secret_[A-Za-z0-9_-]{8}')) as secret_key_like,
  countIf(mapContains(log_attributes, 'request.headers.x_harness_operator')) as operator_header_logged,
  length(groupUniqArrayArray(mapKeys(log_attributes))) as distinct_attribute_keys_scanned
from logs
group by source
order by source
