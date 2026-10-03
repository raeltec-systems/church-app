-- AD-2: no default table exposure. Supabase's default ACLs give anon and authenticated full
-- privileges on tables, sequences and functions the postgres role creates in schema public.
-- Remove them so any future public object needs an explicit grant. service_role and
-- supabase_admin-owned defaults are intentionally left unchanged.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated;
