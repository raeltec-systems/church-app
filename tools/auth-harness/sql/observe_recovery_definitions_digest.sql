-- Read-only: one digest over every recovery-fence function definition and
-- EXECUTE grant (same objects as observe_recovery_definitions.sql) and every
-- rc_auth_* trigger definition. Equal digests = identical definitions.
-- Run via Supabase MCP execute_sql (hosted) or psql (committed files applied
-- to a local container) and pipe the raw JSON into
-- `run.mjs attach --source sql/observe_recovery_definitions_digest.sql`.
select jsonb_build_object(
  'observed_at', now(),
  'functions', count(*) filter (where kind = 'f'),
  'triggers', count(*) filter (where kind = 't'),
  'digest', md5(string_agg(item, '|' order by item))
) as observation
from (
  select 'f' as kind,
         n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')='
           || md5(pg_get_functiondef(p.oid)) || ':'
           || coalesce((select string_agg(r.rolname, ',' order by r.rolname) from pg_roles r
                        where r.rolname in ('anon', 'authenticated', 'service_role')
                          and has_function_privilege(r.oid, p.oid, 'execute')), '') as item
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where (n.nspname = 'public' and (p.proname like 'harness_rc_%' or p.proname = 'harness_recovery_probe'))
     or (n.nspname = 'harness' and p.proname like 'rc_%')
  union all
  select 't', t.tgname || '=' || md5(pg_get_triggerdef(t.oid))
  from pg_trigger t
  where t.tgname like 'rc\_auth\_%' and not t.tgisinternal
) x;
