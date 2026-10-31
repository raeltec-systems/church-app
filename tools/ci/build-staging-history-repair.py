#!/usr/bin/env python3
"""Generate an owner-run metadata-only repair; never connect to a database."""
from pathlib import Path
import argparse, hashlib, json
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[2])
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root, out = args.repo_root.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
manifest_path = root / '_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-reconciliation-2026-10-30/migration-manifest.json'
manifest = json.loads(manifest_path.read_text())
if manifest['source_commit'] != 'c96cd562b2650c37f5d3d879cb12891419700139' or manifest['count'] != 101:
    raise SystemExit('STOP: reviewed migration manifest changed')
paths = [row['path'] for row in manifest['migrations']]
actual_paths = sorted(str(p.relative_to(root)) for p in (root / 'supabase/migrations').glob('*.sql'))
if sorted(paths) != actual_paths or len(set(paths)) != 101:
    raise SystemExit('STOP: migration file set differs from the reviewed manifest')
for row in manifest['migrations']:
    data = (root / row['path']).read_bytes()
    if hashlib.sha256(data).hexdigest() != row['sha256'] or len(data) != row['bytes']:
        raise SystemExit('STOP: migration bytes differ: ' + row['path'])
expected = dict(Path(p).stem.split('_', 1) for p in paths)
missing = ['20261027140200', '20261027182300']
source_paths = {
    'source-rsvp.sql': 'supabase/migrations/20261027140200_content_event_posters_rsvp_rows.sql',
    'source-hymn.sql': 'supabase/migrations/20261027182300_content_hymn_lists_rows.sql',
}
source_text = {k: (root / p).read_text() for k, p in source_paths.items()}
functions = {}
for filename, signature in [
    ('source-hymn.sql', 'app.content_hymn_favourite_purge_rows(uuid)'),
    ('source-rsvp.sql', 'app.content_rsvp_purge_rows(uuid)'),
]:
    body = source_text[filename].split('as $$', 1)[1].split('$$;', 1)[0]
    definition = ('CREATE OR REPLACE FUNCTION ' + signature.replace('(uuid)', '(p_member_id uuid)')
                  + "\n RETURNS integer\n LANGUAGE plpgsql\n SET search_path TO ''\nAS $function$"
                  + body + '$function$\n')
    functions[signature] = {
        'owner_name': 'postgres', 'acl': '{postgres=X/postgres}', 'settings': ['search_path=""'],
        'security_definer': False, 'anon_execute': False, 'authenticated_execute': False,
        'service_role_execute': False, 'public_execute': False, 'definition': definition,
    }
(out / 'expected-migrations.json').write_text(json.dumps(expected, indent=2) + '\n')
(out / 'expected-function-descriptors.json').write_text(json.dumps(functions, indent=2) + '\n')
def lit(value:str,tag:str)->str:
    delimiter=f'${tag}$'
    assert delimiter not in value
    return delimiter+value+delimiter
arrays={}
for version,filename in zip(missing,['source-rsvp.sql','source-hymn.sql']):
    s=source_text[filename]
    a,b=s.split(';\n\nrevoke all on function ',1)
    statements=[a.strip(),('revoke all on function '+b).strip().removesuffix(';')]
    arrays[version]='ARRAY['+ ',\n      '.join(lit(st,f'stored_{version}_{i}') for i,st in enumerate(statements))+']::text[]'
function_query="""SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
    'definition', replace(pg_get_functiondef(p.oid), chr(13), ''),
    'owner_name', pg_get_userbyid(p.proowner), 'acl', p.proacl::text,
    'settings', p.proconfig, 'security_definer', p.prosecdef,
    'anon_execute', has_function_privilege('anon', p.oid, 'EXECUTE'),
    'authenticated_execute', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
    'service_role_execute', has_function_privilege('service_role', p.oid, 'EXECUTE'),
    'public_execute', EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                             WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
  )) INTO v_functions
  FROM pg_proc p
  WHERE p.oid IN ('app.content_rsvp_purge_rows(uuid)'::regprocedure,
                  'app.content_hymn_favourite_purge_rows(uuid)'::regprocedure);"""
sql=f"""-- OWNER-RUN METADATA REPAIR ONLY. Prepared 31 October 2026.
-- Target: bic-kafue-platform-test (tmurpotfluignacfueki), NEVER production.
-- Candidate migration set: 34f273a9d31480be07e9a71eb84e502c486dd886 (101 migrations).
-- Owner preflight: 2026-10-31T06:53:45.775Z. Approval: 'approved both'.
-- Run the WHOLE file once in the target project's SQL Editor as postgres.
-- Do not run alongside a deployment, migration or function/privilege change.
-- The project reference above is an operator label, not proof of the selected project.
-- Writes ONLY two rows to supabase_migrations.schema_migrations.
-- Migration SQL below is STORED AS TEXT; no migration is replayed and no purge is called.
-- A changed environment, history, function, privilege or module guard raises an exception.
-- On ANY error: stop, run ROLLBACK if the editor says the transaction is aborted,
-- and return the error. Do not remove guards or replay the original migrations.
-- After success run 03-staging-history-verify.sql and return its evidence JSON.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
LOCK TABLE supabase_migrations.schema_migrations IN SHARE ROW EXCLUSIVE MODE;

DO $repair$
DECLARE
  v_expected jsonb := {lit(json.dumps(expected,indent=2),'expected_history')}::jsonb;
  v_expected_functions jsonb := {lit(json.dumps(functions,indent=2),'expected_functions')}::jsonb;
  v_actual jsonb;
  v_functions jsonb;
  v_before_rows jsonb;
  v_after_rows jsonb;
  v_rsvp_statements text[] := {arrays[missing[0]]};
  v_hymn_statements text[] := {arrays[missing[1]]};
  v_inserted integer := 0;
BEGIN
  IF app.platform_current_environment() IS DISTINCT FROM 'staging'
     OR session_user IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'STOP: expected staging and the reviewed postgres operator';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'supabase_migrations.schema_migrations'::regclass AND NOT tgisinternal)
     OR EXISTS (SELECT 1 FROM pg_rewrite WHERE ev_class = 'supabase_migrations.schema_migrations'::regclass AND rulename <> '_RETURN') THEN
    RAISE EXCEPTION 'STOP: unexpected migration-history trigger or rule';
  END IF;
  IF EXISTS (SELECT 1 FROM app.contract_boundary_violations())
     OR EXISTS (SELECT 1 FROM app.contract_unowned_objects()) THEN
    RAISE EXCEPTION 'STOP: module guard findings require investigation';
  END IF;

  SELECT jsonb_object_agg(version, name) INTO v_actual FROM supabase_migrations.schema_migrations;
  IF v_actual IS DISTINCT FROM (v_expected - '20261027140200' - '20261027182300')
     AND v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'STOP: full migration version/name set differs from the reviewed 99 or already-repaired 101';
  END IF;

  {function_query}
  IF v_functions IS DISTINCT FROM v_expected_functions THEN
    RAISE EXCEPTION 'STOP: complete function definitions, owner, settings or privileges differ';
  END IF;

  SELECT jsonb_agg(to_jsonb(m) ORDER BY version) INTO v_before_rows
  FROM supabase_migrations.schema_migrations m
  WHERE version NOT IN ('20261027140200', '20261027182300');

  IF v_actual = v_expected THEN
    IF (SELECT statements FROM supabase_migrations.schema_migrations WHERE version = '20261027140200') IS DISTINCT FROM v_rsvp_statements
       OR (SELECT statements FROM supabase_migrations.schema_migrations WHERE version = '20261027182300') IS DISTINCT FROM v_hymn_statements THEN
      RAISE EXCEPTION 'STOP: versions exist but their recorded statements differ; nothing overwritten';
    END IF;
    RAISE NOTICE 'Already reconciled: no history rows changed';
  ELSE
    INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
    VALUES ('20261027140200', 'content_event_posters_rsvp_rows', v_rsvp_statements),
           ('20261027182300', 'content_hymn_lists_rows', v_hymn_statements);
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted <> 2 THEN
      RAISE EXCEPTION 'STOP: expected exactly two inserted history rows';
    END IF;
  END IF;

  SELECT jsonb_object_agg(version, name) INTO v_actual FROM supabase_migrations.schema_migrations;
  SELECT jsonb_agg(to_jsonb(m) ORDER BY version) INTO v_after_rows
  FROM supabase_migrations.schema_migrations m
  WHERE version NOT IN ('20261027140200', '20261027182300');
  IF v_actual IS DISTINCT FROM v_expected OR v_after_rows IS DISTINCT FROM v_before_rows THEN
    RAISE EXCEPTION 'STOP: post-write history mismatch; transaction will roll back';
  END IF;
  {function_query}
  IF v_functions IS DISTINCT FROM v_expected_functions
     OR EXISTS (SELECT 1 FROM app.contract_boundary_violations())
     OR EXISTS (SELECT 1 FROM app.contract_unowned_objects()) THEN
    RAISE EXCEPTION 'STOP: post-write function/privilege/module mismatch; transaction will roll back';
  END IF;
  RAISE NOTICE 'Verified 101 migration names/versions; inserted % rows; original 99 rows and both functions unchanged', v_inserted;
END;
$repair$;

COMMIT;
"""
(out/'02-staging-history-repair.sql').write_text(sql)
verify="""-- READ-ONLY after-check. Run in bic-kafue-platform-test (tmurpotfluignacfueki).
-- Return the one evidence JSON cell after 02-staging-history-repair.sql succeeds.
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'observed_at_utc', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'expected_project_ref_label_only', 'tmurpotfluignacfueki',
  'reviewed_candidate', '34f273a9d31480be07e9a71eb84e502c486dd886',
  'environment', app.platform_current_environment(),
  'session_user', session_user,
  'transaction_read_only', current_setting('transaction_read_only'),
  'migration_count', (SELECT count(*) FROM supabase_migrations.schema_migrations),
  'migrations', (SELECT jsonb_agg(jsonb_build_object('version', version, 'name', name) ORDER BY version) FROM supabase_migrations.schema_migrations),
  'repaired_history_rows', (
    SELECT jsonb_agg(jsonb_build_object('version', m.version, 'name', m.name,
      'statement_count', cardinality(m.statements),
      'statement_md5', (SELECT jsonb_agg(md5(s.statement) ORDER BY s.ordinality) FROM unnest(m.statements) WITH ORDINALITY AS s(statement, ordinality))
    ) ORDER BY m.version)
    FROM supabase_migrations.schema_migrations m WHERE version IN ('20261027140200', '20261027182300')
  ),
  'functions', (SELECT jsonb_agg(jsonb_build_object(
    'function_name', p.oid::regprocedure::text,
    'normalized_body_md5', md5(replace(p.prosrc, chr(13), '')),
    'complete_definition', pg_get_functiondef(p.oid),
    'security_definer', p.prosecdef, 'settings', p.proconfig,
    'owner_name', pg_get_userbyid(p.proowner), 'acl', p.proacl::text,
    'anon_execute', has_function_privilege('anon', p.oid, 'EXECUTE'),
    'authenticated_execute', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
    'service_role_execute', has_function_privilege('service_role', p.oid, 'EXECUTE'),
    'public_execute', EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
  ) ORDER BY p.oid::regprocedure::text) FROM pg_proc p
  WHERE p.oid IN ('app.content_rsvp_purge_rows(uuid)'::regprocedure, 'app.content_hymn_favourite_purge_rows(uuid)'::regprocedure)),
  'boundary_violations', (SELECT count(*) FROM app.contract_boundary_violations()),
  'unowned_objects', (SELECT count(*) FROM app.contract_unowned_objects()),
  'history_triggers', (SELECT coalesce(jsonb_agg(pg_get_triggerdef(oid) ORDER BY tgname), '[]'::jsonb) FROM pg_trigger WHERE tgrelid = 'supabase_migrations.schema_migrations'::regclass AND NOT tgisinternal)
) AS evidence;
ROLLBACK;
"""
(out/'03-staging-history-verify.sql').write_text(verify)
manifest={name:{'sha256':hashlib.sha256((out/name).read_bytes()).hexdigest(),'bytes':(out/name).stat().st_size} for name in ['02-staging-history-repair.sql','03-staging-history-verify.sql']}
(out/'script-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
