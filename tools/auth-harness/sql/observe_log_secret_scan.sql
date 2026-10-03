-- Read-only (ClickHouse, Supabase MCP query_logs, NOT Postgres): scans every
-- platform log source of szfyfezfvxyuvovnnakr in the run window for values
-- shaped like a harness password ('Hx!' + base64url), a grant secret ('hg_'),
-- an operator token ('ho_'), a JWT or a secret key, and returns only counts
-- plus coarse message shapes (hex ids masked). The bare word "password" is
-- not counted: it appears legitimately as grant_type=password in Auth request
-- logs and in migration SQL. Pass the run window as iso_timestamp_start/end
-- and pipe the raw JSON into
-- `run.mjs attach --source sql/observe_log_secret_scan.sql --via supabase-mcp-query_logs`.
select
  source,
  count(*) as lines,
  countIf(match(event_message, 'Hx![A-Za-z0-9_-]{16}')) as harness_password_like,
  countIf(match(event_message, 'hg_[A-Za-z0-9_-]{20}')) as grant_secret_like,
  countIf(match(event_message, 'ho_[A-Za-z0-9_-]{20}')) as operator_token_like,
  countIf(match(event_message, 'eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.')) as jwt_like,
  countIf(match(event_message, 'sb_secret_[A-Za-z0-9_-]{8}')) as secret_key_like,
  arraySlice(groupUniqArray(substring(replaceRegexpAll(event_message, '[0-9a-f-]{8,}', '#'), 1, 60)), 1, 6) as message_shapes
from logs
group by source
order by source
