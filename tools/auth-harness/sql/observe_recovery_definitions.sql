-- Read-only: fingerprint of the hosted recovery-fence objects, so the
-- committed 001-004 SQL files can be shown to match the hosted project
-- (compare with the same query run where the file was applied verbatim).
-- Also returns the grants of every harness_rc_* RPC and the trigger state.
-- Run via Supabase MCP execute_sql against szfyfezfvxyuvovnnakr and pipe the
-- raw JSON into `run.mjs attach --source sql/observe_recovery_definitions.sql`.
select jsonb_build_object(
  'observed_at', now(),
  'server_version', current_setting('server_version'),
  'functions', (
    select jsonb_agg(jsonb_build_object(
      'name', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
      'security_definer', p.prosecdef,
      'definition_md5', md5(pg_get_functiondef(p.oid)),
      'execute_roles', (select coalesce(jsonb_agg(r.rolname order by r.rolname), '[]'::jsonb)
                        from pg_roles r
                        where r.rolname in ('anon', 'authenticated', 'service_role')
                          and has_function_privilege(r.oid, p.oid, 'execute')))
      order by n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'public' and (p.proname like 'harness_rc_%' or p.proname = 'harness_recovery_probe'))
       or (n.nspname = 'harness' and p.proname like 'rc_%')
  ),
  'triggers', (
    select jsonb_agg(jsonb_build_object('table', t.tgrelid::regclass::text, 'name', t.tgname,
                                        'enabled', t.tgenabled,
                                        'definition_md5', md5(pg_get_triggerdef(t.oid)))
                     order by t.tgname)
    from pg_trigger t
    where t.tgname like 'rc\_auth\_%' and not t.tgisinternal
  ),
  'tables', (
    select jsonb_agg(jsonb_build_object(
      'name', c.relname, 'rls', c.relrowsecurity,
      'client_privileges', (select coalesce(jsonb_agg(r.rolname order by r.rolname), '[]'::jsonb)
                            from pg_roles r where r.rolname in ('anon', 'authenticated')
                              and has_table_privilege(r.oid, c.oid, 'select, insert, update, delete')))
      order by c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'harness' and c.relname like 'rc_%' and c.relkind = 'r'
  )
) as observation;
