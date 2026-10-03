-- Tracer (story 1.1): synthetic platform status exposed read-only through the api schema.
-- AD-2: application tables live in the non-exposed `app` schema with RLS enabled;
-- clients read only allowlisted security_invoker views in the exposed `api` schema.
-- No client role receives table DML. No objects are added to auth, storage or realtime.

create schema if not exists app;
create schema if not exists api;

revoke all on schema app from public;
revoke all on schema api from public;

-- AD-2: revoke the default PUBLIC EXECUTE on functions created by the migration role, so
-- every later app/api function needs an explicit grant. Per-schema default privileges
-- cannot remove a global default, hence the global form.
alter default privileges for role postgres revoke execute on functions from public;

create table app.platform_status (
  id smallint primary key default 1 check (id = 1),
  status text not null check (length(btrim(status)) > 0),
  message text not null,
  is_synthetic boolean not null default true,
  updated_at timestamptz not null default now()
);

comment on table app.platform_status is
  'Single-row synthetic platform status used by the tracer. Holds no member data.';

alter table app.platform_status enable row level security;

revoke all on table app.platform_status from public, anon, authenticated, service_role;

create policy platform_status_select on app.platform_status
  for select
  to anon, authenticated
  using (true);

create view api.platform_status
  with (security_invoker = true)
as
  select status, message, is_synthetic, updated_at
  from app.platform_status;

comment on view api.platform_status is
  'Read-only tracer projection of app.platform_status (synthetic data).';

revoke all on table api.platform_status from public, anon, authenticated, service_role;

-- security_invoker means the caller's own privileges and RLS apply to the base table,
-- so the read path needs USAGE on both schemas and SELECT on both relations.
-- `app` is still unreachable through the Data API because only `api` is exposed.
grant usage on schema api to anon, authenticated;
grant usage on schema app to anon, authenticated;
grant select on table api.platform_status to anon, authenticated;
grant select on table app.platform_status to anon, authenticated;
