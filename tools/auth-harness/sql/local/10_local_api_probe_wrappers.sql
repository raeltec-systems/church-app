-- LOCAL stack only (story 1.2 LOCAL run). The local stack's PostgREST exposes
-- only the `api` schema (supabase/config.toml [api] schemas), so the harness
-- RPCs from 001_trusted_session_probe.sql (in `public`) are reached through
-- these thin SECURITY INVOKER wrappers. They add no logic: the caller's role,
-- JWT claims and RLS apply exactly as for the hosted `public.harness_*` RPCs.
-- Apply after 001, as postgres, then reload the PostgREST schema cache. Never
-- copy into supabase/migrations; `supabase db reset` removes them.
create or replace function api.harness_whoami()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$ select public.harness_whoami(); $$;
revoke all on function api.harness_whoami() from public, anon;
grant execute on function api.harness_whoami() to authenticated;

create or replace function api.harness_private_probe()
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$ select public.harness_private_probe(); $$;
revoke all on function api.harness_private_probe() from public, anon;
grant execute on function api.harness_private_probe() to authenticated;

notify pgrst, 'reload schema';
