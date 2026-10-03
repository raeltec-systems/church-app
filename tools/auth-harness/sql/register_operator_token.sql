-- Operator write (not an observation): register the DIGEST of a harness
-- operator token printed by `run.mjs rc-operator-token`. The token itself
-- never leaves the private state dir. Run via Supabase MCP execute_sql
-- against szfyfezfvxyuvovnnakr after replacing :digest and :label. Tokens
-- expire after 8 hours; register a new one per session.
insert into harness.rc_operator_token (digest, label, expires_at)
values (':digest', ':label', now() + interval '8 hours')
on conflict (digest) do nothing
returning label, expires_at;
