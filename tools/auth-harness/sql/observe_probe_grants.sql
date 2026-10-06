-- Read-only: hosted grants/policies/definitions for the harness probe objects,
-- plus the database version. Run via Supabase MCP execute_sql against
-- szfyfezfvxyuvovnnakr only; pipe the raw JSON result into
-- `run.mjs attach --source sql/observe_probe_grants.sql`.
select jsonb_build_object(
  'postgres_version', version(),
  'functions', (
    select jsonb_agg(jsonb_build_object(
      'fn', n.nspname || '.' || p.proname,
      'security_definer', p.prosecdef,
      'anon_execute', has_function_privilege('anon', p.oid, 'execute'),
      'authenticated_execute', has_function_privilege('authenticated', p.oid, 'execute'),
      'public_acl', coalesce(p.proacl::text, '(default: PUBLIC execute)'),
      'definition_md5', md5(pg_get_functiondef(p.oid))
    ) order by n.nspname, p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'harness')
       or (n.nspname = 'public' and p.proname like 'harness\_%')
  ),
  'table_privileges', (
    select jsonb_agg(jsonb_build_object('grantee', grantee, 'privilege', privilege_type)
                     order by grantee, privilege_type)
    from information_schema.role_table_grants
    where table_schema = 'harness' and table_name = 'private_probe'
      and grantee in ('anon', 'authenticated', 'PUBLIC')
  ),
  'rls_enabled', (select relrowsecurity from pg_class where oid = 'harness.private_probe'::regclass),
  'policies', (
    select jsonb_agg(jsonb_build_object('name', policyname, 'cmd', cmd, 'roles', roles)
                     order by policyname)
    from pg_policies where schemaname = 'harness' and tablename = 'private_probe'
  ),
  'anon_schema_usage', has_schema_privilege('anon', 'harness', 'usage')
) as observation;
