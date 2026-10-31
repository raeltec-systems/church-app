#!/usr/bin/env python3
"""Exercise the manual script on an isolated, loopback-only PostgreSQL fixture."""
from pathlib import Path
import argparse, concurrent.futures, json, os, subprocess, unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo-root', type=Path, required=True)
parser.add_argument('--bundle', type=Path, required=True)
args = parser.parse_args()
root, bundle = args.repo_root.resolve(), args.bundle.resolve()
required = {'PGHOST': '127.0.0.1', 'PGPORT': '55432', 'PGDATABASE': 'history_repair_test', 'PGUSER': 'postgres'}
if any(os.environ.get(k) != v for k, v in required.items()):
    raise SystemExit('REFUSED: this fixture runner only uses 127.0.0.1:55432/history_repair_test as postgres')
if os.environ.get('PGSERVICE') or os.environ.get('PGSERVICEFILE'):
    raise SystemExit('REFUSED: PostgreSQL service overrides are not allowed')
expected = json.loads((bundle / 'expected-migrations.json').read_text())
repair = (bundle / '02-staging-history-repair.sql').read_text()
verify = (bundle / '03-staging-history-verify.sql').read_text()
missing = {'20261027140200', '20261027182300'}


def sql(text, ok=True):
    result = subprocess.run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], input=text,
                            text=True, capture_output=True, timeout=45)
    if ok and result.returncode:
        raise AssertionError(result.stderr)
    return result


def fixture():
    # This destructive setup is exclusively for the hard-coded disposable local fixture.
    sql("""
DROP SCHEMA IF EXISTS app CASCADE;
DROP SCHEMA IF EXISTS supabase_migrations CASCADE;
CREATE SCHEMA app;
CREATE SCHEMA supabase_migrations;
DO $$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END;$$;
CREATE TABLE supabase_migrations.schema_migrations (
  version text PRIMARY KEY, statements text[], name text, created_by text,
  idempotency_key text UNIQUE, rollback text[]
);
CREATE TABLE app.content_event_rsvps (member_id uuid);
CREATE TABLE app.content_event_organisers (member_id uuid);
CREATE TABLE app.content_hymn_favourites (member_id uuid);
INSERT INTO app.content_event_rsvps VALUES ('00000000-0000-0000-0000-000000000001');
INSERT INTO app.content_event_organisers SELECT * FROM app.content_event_rsvps;
INSERT INTO app.content_hymn_favourites SELECT * FROM app.content_event_rsvps;
CREATE FUNCTION app.platform_current_environment() RETURNS text LANGUAGE sql STABLE AS $$SELECT 'staging'::text$$;
CREATE FUNCTION app.contract_boundary_violations() RETURNS TABLE(finding text) LANGUAGE sql STABLE AS $$SELECT NULL::text WHERE false$$;
CREATE FUNCTION app.contract_unowned_objects() RETURNS TABLE(finding text) LANGUAGE sql STABLE AS $$SELECT NULL::text WHERE false$$;
""")
    rows = ','.join("('%s','%s',ARRAY['existing metadata %s'])" % (v, name, v)
                    for v, name in expected.items() if v not in missing)
    sql('INSERT INTO supabase_migrations.schema_migrations(version,name,statements) VALUES '+rows+';')
    for f in ('20261027140200_content_event_posters_rsvp_rows.sql', '20261027182300_content_hymn_lists_rows.sql'):
        sql((root / 'supabase/migrations' / f).read_text())


def snapshot():
    return sql("SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY version),'[]'::jsonb) FROM supabase_migrations.schema_migrations m;").stdout.strip()


class RepairTests(unittest.TestCase):
    def setUp(self):
        fixture()

    def unchanged_on_refusal(self, message):
        before = snapshot()
        result = sql(repair, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertEqual(before, snapshot(), 'Failure changed history')

    def test_01_exact_repair_preserves_application_rows_and_existing_history(self):
        before = json.loads(snapshot())
        sql(repair)
        evidence = json.loads(sql(verify).stdout)
        self.assertEqual(evidence['migration_count'], 101)
        self.assertEqual({m['version']: m['name'] for m in evidence['migrations']}, expected)
        self.assertEqual([r['statement_count'] for r in evidence['repaired_history_rows']], [2, 2])
        self.assertEqual([r for r in json.loads(snapshot()) if r['version'] not in missing], before)
        self.assertEqual(sql('SELECT (SELECT count(*) FROM app.content_event_rsvps)+(SELECT count(*) FROM app.content_event_organisers)+(SELECT count(*) FROM app.content_hymn_favourites);').stdout.strip(), '3')
        self.assertEqual(evidence['boundary_violations'], 0)
        self.assertEqual(evidence['unowned_objects'], 0)
        self.assertEqual(evidence['transaction_read_only'], 'on')

    def test_02_repeat_is_noop(self):
        sql(repair)
        before = snapshot()
        sql(repair)
        self.assertEqual(before, snapshot())

    def test_03_concurrent_runs_serialize_without_duplicates(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: sql(repair), range(2)))
        self.assertTrue(all(r.returncode == 0 for r in results))
        self.assertEqual(len(json.loads(snapshot())), 101)

    def test_04_production_label_refused(self):
        sql("CREATE OR REPLACE FUNCTION app.platform_current_environment() RETURNS text LANGUAGE sql STABLE AS $$SELECT 'production'::text$$;")
        self.unchanged_on_refusal('expected staging')

    def test_05_changed_function_refused(self):
        sql("CREATE OR REPLACE FUNCTION app.content_rsvp_purge_rows(p_member_id uuid) RETURNS integer LANGUAGE plpgsql SET search_path = '' AS $$ BEGIN RETURN 0; END; $$;")
        self.unchanged_on_refusal('complete function definitions')

    def test_06_expanded_privilege_refused(self):
        sql('GRANT EXECUTE ON FUNCTION app.content_rsvp_purge_rows(uuid) TO authenticated;')
        self.unchanged_on_refusal('complete function definitions')

    def test_07_unexpected_version_refused(self):
        sql("INSERT INTO supabase_migrations.schema_migrations(version,name) VALUES ('20990101000000','unexpected');")
        self.unchanged_on_refusal('full migration version/name set')

    def test_08_additional_missing_version_refused(self):
        sql("DELETE FROM supabase_migrations.schema_migrations WHERE version='20261003112319';")
        self.unchanged_on_refusal('full migration version/name set')

    def test_09_partial_prior_repair_refused(self):
        sql("INSERT INTO supabase_migrations.schema_migrations(version,name) VALUES ('20261027140200','content_event_posters_rsvp_rows');")
        self.unchanged_on_refusal('full migration version/name set')

    def test_10_module_boundary_finding_refused(self):
        sql("CREATE OR REPLACE FUNCTION app.contract_boundary_violations() RETURNS TABLE(finding text) LANGUAGE sql STABLE AS $$SELECT 'fixture finding'::text$$;")
        self.unchanged_on_refusal('module guard findings')

    def test_11_unowned_object_refused(self):
        sql("CREATE OR REPLACE FUNCTION app.contract_unowned_objects() RETURNS TABLE(finding text) LANGUAGE sql STABLE AS $$SELECT 'fixture finding'::text$$;")
        self.unchanged_on_refusal('module guard findings')

    def test_12_history_trigger_refused(self):
        sql("CREATE OR REPLACE FUNCTION public.history_fixture_trigger() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END;$$; CREATE TRIGGER history_fixture_trigger BEFORE INSERT ON supabase_migrations.schema_migrations FOR EACH ROW EXECUTE FUNCTION public.history_fixture_trigger();")
        self.unchanged_on_refusal('unexpected migration-history trigger or rule')

    def test_13_existing_mismatched_statements_not_overwritten(self):
        sql(repair)
        sql("UPDATE supabase_migrations.schema_migrations SET statements=ARRAY['mismatched'] WHERE version='20261027140200';")
        self.unchanged_on_refusal('recorded statements differ')

    def test_14_renamed_existing_version_refused(self):
        sql("UPDATE supabase_migrations.schema_migrations SET name='unexpected_name' WHERE version='20261003112319';")
        self.unchanged_on_refusal('full migration version/name set')


if __name__ == '__main__':
    print('Scope: isolated PostgreSQL fixture only; no hosted database or app-acceptance claim.', flush=True)
    print(sql('SELECT version();').stdout.strip(), flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RepairTests))
    raise SystemExit(0 if result.wasSuccessful() else 1)
