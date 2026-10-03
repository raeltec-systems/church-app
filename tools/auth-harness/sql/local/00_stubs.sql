-- LOCAL CONTAINER ONLY (public.ecr.aws/supabase/postgres:17.11.0.002, run as
-- supabase_admin, --network none). Never apply to a hosted project.
-- Minimal stand-ins for the GoTrue-owned auth tables/functions the harness
-- SQL references, so 001-005 and test_fence.sql can run without GoTrue.
alter table auth.users add column if not exists phone text;
alter table auth.users add column if not exists encrypted_password text;
create table if not exists auth.sessions (id uuid primary key, user_id uuid, created_at timestamptz default now(), not_after timestamptz);
create table if not exists auth.identities (id uuid primary key default gen_random_uuid(), user_id uuid, provider text, provider_id text);
create table if not exists auth.mfa_factors (id uuid primary key default gen_random_uuid(), user_id uuid, status text, secret text, factor_type text);
create or replace function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true),''),'{}')::jsonb $$;
grant execute on function auth.jwt() to public;
grant all on auth.sessions, auth.identities, auth.mfa_factors to postgres;
