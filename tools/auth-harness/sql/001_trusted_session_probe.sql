-- Auth harness probe for story 1.2.
-- Apply ONLY to the isolated auth-test project (bic-kafue-auth-test /
-- szfyfezfvxyuvovnnakr). This is NOT an application migration and must never
-- be copied into supabase/migrations.
--
-- harness.trusted_password_session() mirrors the session half of the AD-3
-- private-data predicate: the signed JWT's amr must contain a `password`
-- entry AND its session_id must still exist in auth.sessions for the same
-- user (a live session). Membership, binding, hold and grant checks belong to
-- the identity epic and are out of scope here.

create schema if not exists harness;
revoke all on schema harness from public;
grant usage on schema harness to authenticated;

create or replace function harness.trusted_password_session()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    exists (
      select 1
      from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as a(entry)
      where a.entry ->> 'method' = 'password'
    )
    and exists (
      select 1
      from auth.sessions s
      where s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
        and s.user_id = auth.uid()
        and (s.not_after is null or s.not_after > now())
    ),
    false
  );
$$;
revoke all on function harness.trusted_password_session() from public;
grant execute on function harness.trusted_password_session() to authenticated;

-- One synthetic "private" row per user, readable/writable only under the
-- trusted predicate. Lives in an unexposed schema; reached through the
-- security-invoker RPCs below so RLS applies to the caller.
create table if not exists harness.private_probe (
  user_id uuid primary key,
  note text not null default 'synthetic private probe row',
  created_at timestamptz not null default now()
);
alter table harness.private_probe enable row level security;
revoke all on harness.private_probe from public, anon, authenticated;
grant select, insert on harness.private_probe to authenticated;

drop policy if exists private_probe_select on harness.private_probe;
create policy private_probe_select on harness.private_probe
  for select to authenticated
  using (user_id = (select auth.uid()) and (select harness.trusted_password_session()));

drop policy if exists private_probe_insert on harness.private_probe;
create policy private_probe_insert on harness.private_probe
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select harness.trusted_password_session()));

-- Private-data probe: inserts the caller's row if allowed, then returns how
-- many private rows the caller can see (1 = allowed, 0 = denied by RLS).
-- An RLS insert violation is reported as denied, never as an error body.
create or replace function public.harness_private_probe()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  visible integer;
  write_ok boolean := true;
begin
  begin
    insert into harness.private_probe (user_id) values (auth.uid())
      on conflict (user_id) do nothing;
  exception when insufficient_privilege or check_violation or not_null_violation then
    write_ok := false;
  end;
  select count(*) into visible from harness.private_probe;
  return jsonb_build_object(
    'private_rows_visible', visible,
    'write_allowed', write_ok,
    'allowed', visible > 0 and write_ok
  );
end;
$$;
revoke all on function public.harness_private_probe() from public, anon;
grant execute on function public.harness_private_probe() to authenticated;

-- Diagnostic RPC: what the server sees for the caller's session. Returns only
-- method names, aal, the live-session flag and the predicate result.
create or replace function public.harness_whoami()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'role', auth.role(),
    'user_id_present', auth.uid() is not null,
    'amr_methods', coalesce((
      select jsonb_agg(a.entry ->> 'method')
      from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as a(entry)
    ), '[]'::jsonb),
    'aal', auth.jwt() ->> 'aal',
    'session_live', exists (
      select 1 from auth.sessions s
      where s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
        and s.user_id = auth.uid()
    ),
    'trusted_password_session', harness.trusted_password_session()
  );
$$;
revoke all on function public.harness_whoami() from public;
grant execute on function public.harness_whoami() to anon, authenticated;
