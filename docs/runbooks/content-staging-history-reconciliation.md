# Proposed staging migration-history reconciliation

**Status: prepared for owner review on 30 October 2026; not authorized or executed.**

This proposal repairs two missing history records only after fresh checks prove that their
complete intended effects already exist. It does not replay SQL, change application behavior,
approve a policy gate, publish content, send notifications or promote production. The user
explicitly reserved deployment and acceptance decisions; that is the reason approval is
required here. No automatic approval review rejected this operation: it has not been requested.

## Evidence and exact target

Target: staging `bic-kafue-platform-test`, project ref `tmurpotfluignacfueki`.
Repository source: `c96cd562b2650c37f5d3d879cb12891419700139`.

The [30 October read-only observation](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-reconciliation-2026-10-30/staging-read-only.json)
found 99 of the 101 expected migration versions and no unexpected versions. The two absent
history rows are:

| Version | Complete migration file | Observed installed body, normalized `prosrc` MD5 |
| --- | --- | --- |
| `20261027140200` | `20261027140200_content_event_posters_rsvp_rows.sql` | `app.content_rsvp_purge_rows(uuid)`: `3dd55a0d61f54b81d13006bdfa481ea6` |
| `20261027182300` | `20261027182300_content_hymn_lists_rows.sql` | `app.content_hymn_favourite_purge_rows(uuid)`: `907c140ce9fc7bf5f3fd494f9f807194` |

Both bodies match the corresponding repository body after removal of carriage returns;
both contain their real deletion statements, neither contains the missing-rows stub,
both are invoker functions with an empty search path, and `anon`, `authenticated` and
`service_role` cannot execute them directly. Module boundary/unowned-object counts were zero.
These checks explain why blindly replaying the files is inappropriate. They do not make
the absent history rows disappear or prove that a real deletion workflow has run.

The repository drift checker was run against the captured complete history and exited **1**:
[staging-drift-check.log](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-reconciliation-2026-10-30/staging-drift-check.log).
It identifies both versions as missing out-of-order migrations. This is an open release blocker.

## Before requesting the repair

The operator must verify the exact reviewed candidate and target, inspect both full SQL files
(including owner/privilege statements), and retain the before/after evidence privately where
appropriate. Use a restricted authorized SQL session for the following **read-only** queries:

```sql
select version from supabase_migrations.schema_migrations order by version;

select p.oid::regprocedure::text as function_name,
       md5(replace(p.prosrc, chr(13), '')) as normalized_body_md5,
       p.prosecdef as security_definer,
       p.proconfig as settings,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role_execute,
       pg_get_userbyid(p.proowner) as owner_name,
       pg_get_functiondef(p.oid) as complete_definition
from pg_proc p
where p.oid in ('app.content_rsvp_purge_rows(uuid)'::regprocedure,
                'app.content_hymn_favourite_purge_rows(uuid)'::regprocedure)
order by 1;

select count(*) as boundary_violations from app.contract_boundary_violations();
select count(*) as unowned_objects from app.contract_unowned_objects();
```

Compare the complete history **set**, not only its count, with the
[101-file candidate manifest](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-reconciliation-2026-10-30/migration-manifest.json).
Compare the complete definitions, function owner and privileges to the two reviewed files.
The hashes above are comparison aids for these two bodies, not cryptographic proof of the
whole schema. If any effect differs, any additional version is missing/unexpected, or the
target/candidate changed, stop and investigate a revised plan. Do not mark an unapplied or
partially applied migration as applied merely to silence drift.

For an input accepted by the repository checker, export this query's single JSON value
to a local file such as `/tmp/church-staging-history-before.json`:

```sql
select jsonb_build_object('migrations',
         coalesce(jsonb_agg(jsonb_build_object('version', version) order by version), '[]'::jsonb))
from supabase_migrations.schema_migrations;
```

From the repository root:

```bash
node tools/ci/check-migration-drift.mjs --env staging \
  --hosted-file /tmp/church-staging-history-before.json --require-synced
```

Before repair, the expected result for this observed state is exit 1 naming **only** the two
versions above. Keep that failed check as evidence; it is not a successful verification.

## Operation to approve

After the fresh comparison and explicit owner approval, an authorized operator may run
the following **metadata-only** repair using the repository-pinned Supabase CLI 2.119.0.
The `migration repair --help` output in this environment confirmed `--status applied`
and `--project-ref` support. Authenticate locally by the repository's established method;
do not paste access tokens, database passwords or service keys into chat or commit them.

```bash
npx --no-install supabase --version
npx --no-install supabase migration repair \
  --project-ref tmurpotfluignacfueki \
  --status applied \
  20261027140200 20261027182300
```

This is the concrete proposed change: record both versions as applied because their
reviewed effects already exist. **Do not run `db push`, `--include-all`, the SQL files or
an unrelated repair.** If credentials or CLI behavior differ, stop and record the error;
do not change authentication/security settings to make the command succeed.

## Required after evidence

Repeat all read-only queries above, exporting the history JSON to
`/tmp/church-staging-history-after.json`, and run:

```bash
node tools/ci/check-migration-drift.mjs --env staging \
  --hosted-file /tmp/church-staging-history-after.json --require-synced
```

Expected: exit 0, all 101 candidate versions present, no unexpected versions, identical
function definitions/owners/privileges and zero module-guard findings. Record the operator,
approval reference, full candidate SHA, target, UTC/Lusaka time, command exit and sanitized
before/after evidence. If anything differs, leave the blocker open and investigate; never
rewrite evidence or automatically revert an applied status without reviewing actual state.

History synchronization closes this specific metadata blocker only. Fresh local replay,
affected deletion/workflow verification, broader deployed schema/function parity, required
devices, the owner pilot, production prerequisites and release approval remain separate.
Update the [acceptance reconciliation](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/acceptance-reconciliation-2026-10-30.md)
only after the actual operation and after-check have evidence.
