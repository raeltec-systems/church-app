# Story 6.3 staging verification (project tmurpotfluignacfueki, environment `staging`)

Applied 2026-10-22 through the Supabase connector (`apply_migration`, name `content_giving_methods`),
verbatim from the local file after the external review fixes; staging recorded version
`20261022011438` and the local file was renamed to it.

| Check | Staging | Fresh local reset (same migration) |
|---|---|---|
| Migration recorded | `20261022011438 content_giving_methods` | n/a |
| `app.contract_boundary_violations()` | 0 | 0 |
| `app.contract_unowned_objects()` | 0 | 0 |
| 37 `app`/`api` giving functions (`content%giving%`, `content_church_today`): md5 of each `replace(pg_get_functiondef(oid), chr(13), '')`, aggregated | `28cf7d7b867605e27cf3edea9a96448c` | `28cf7d7b867605e27cf3edea9a96448c` |
| Constraint definitions of the three giving tables | `d38d1e5606af5be36da6cec4bee61e01` | `d38d1e5606af5be36da6cec4bee61e01` |
| Columns of the three giving tables | `933f6587216a768b37b19f8ef573ba31` | `933f6587216a768b37b19f8ef573ba31` |
| `q3_giving` | unresolved, fixture `sample_only` | same |
| Kinds | `event: admin,pastor,media`, `giving_method: admin` | same |
| Erase parts | `event_revisions, giving_methods` | same |
| Giving commands registered | 8 | 8 |
| Anonymous `api.content_public_giving_methods()` | `{"sample": true, "methods": [], "truncated": false}` | same |
| Anonymous `api.content_public_giving_method(<unknown>)` | `{"sample": true, "method": null}` | same |
| anon EXECUTE on `api.content_staff_giving_methods()` | false | false |
| Client-role privileges on any giving table or sequence | 0 | 0 |

Local evidence: full pgTAP suite PASS (59 files, 4661 tests, `content_giving_test.sql` 171) on a
fresh reset; E2E `content-giving-e2e.jsonl` 12/12.

Not yet done on staging: the owner's walkthrough with two SYNTHETIC Admins and a signed-out phone
([content.md](../../../../docs/runbooks/content.md), Story 6.3, "Owner manual check"). The E2E
proves the same verify at the API on the local stack; it is LOCAL-only by design (exact origin).
