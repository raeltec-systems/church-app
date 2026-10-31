# Owner-run staging history repair — 31 October 2026

**Approval received; owner preflight reviewed; repair and post-repair staging verification still pending.**

This is the current operator handoff for the two-version proposal in [content-staging-history-reconciliation.md](content-staging-history-reconciliation.md). It supersedes that historical proposal's unapproved status, not its narrow scope or required evidence. Israel approved both the history repair and the 14-story Epic 7 plan, then asked to run blocked SQL manually while independent repository work continues.

## Reviewed owner evidence

Israel returned the complete read-only JSON observed at **2026-10-31T06:53:45.775Z** (08:53:45.775 Africa/Lusaka). The uploaded text SHA-256 is `f90d31f444f40221bdb19da01cb6a7125b115ad9a7aca42069bfc37d4f75310e`.

The 99 returned version/name pairs match the reviewed 101-file manifest except for `20261027140200` (`content_event_posters_rsvp_rows`) and `20261027182300` (`content_hymn_lists_rows`). There are no unexpected versions or name mismatches. Both complete function definitions match the repository after CRLF normalization, not only their body hashes. Owner is postgres, search path is empty, security-definer is false, and PUBLIC/anon/authenticated/service_role execution is denied. Boundary findings and unowned objects are zero; no noninternal history triggers were returned. Environment is staging and transaction_read_only is on.

The target remains **bic-kafue-platform-test / tmurpotfluignacfueki**. The reference printed in SQL is an operator label, not an independently obtained server identifier: select that exact project in the dashboard. Do not select production or another staging project.

## Generate the scripts

From this reviewed checkout:

```bash
python3 tools/ci/build-staging-history-repair.py --output /tmp/church-history-repair
```

The generator reads the repository's manifest, checks the complete 101-file set and every file's SHA-256/size, and derives both function definitions and stored migration statements from the original files. It never connects to a database. It deliberately refuses a different migration snapshot.

It produces `02-staging-history-repair.sql`, `03-staging-history-verify.sql`, expected metadata and a script SHA-256 manifest. The exact-head **Manual history repair validation** workflow also exports these files and tests the repair on a separate loopback-only PostgreSQL fixture. A successful fixture test is not hosted execution or app acceptance.

## Run manually, in this order

1. Confirm the dashboard project is bic-kafue-platform-test (`tmurpotfluignacfueki`). Coordinate so no deployment, migration or function/privilege change runs concurrently.
2. Open `02-staging-history-repair.sql` and execute its entire contents once as postgres. Do not execute only its INSERT. The script locks the history table briefly, rechecks the complete version/name set, exact function definitions/owners/settings/privileges and module guards, then records the two missing history rows in one transaction. The embedded CREATE FUNCTION/REVOKE text is stored in the history's statements arrays; it is never executed. No purge is called and no application row or schema object is changed.
3. Run all of `03-staging-history-verify.sql` separately after the repair succeeds. Return the single evidence JSON cell, including both history records and their statement hashes. Expected migration count is 101, both body hashes are unchanged, privileges remain restricted and module findings remain zero.

If any guard or database command fails, stop and return its exact error. If the editor reports an aborted transaction, execute `ROLLBACK;` before further inspection. Do not remove guards, overwrite existing history, call a purge, replay either SQL file or use db push/include-all. An exact repeat of this repair is a no-op; a partial or differently recorded repair is deliberately refused for investigation.

## Evidence still required

The after JSON must be compared with the original before evidence and the full repository manifest. Run the repository's strict drift checker against that captured output before closing this one metadata blocker:

```bash
node tools/ci/check-migration-drift.mjs --env staging --hosted-file /path/to/after-evidence.json --require-synced
```

The evidence JSON contains a top-level migrations array accepted by that checker. Exit 0 is required; a credential-dependent CI skip is not a pass for this target. Also verify both definitions, owners, privileges, stored statement hashes and zero module findings.

No repair has been executed by the assistant. Owner execution and fresh after-checks are pending. Broader deployed parity, deletion workflows, Epic 6 owner/device acceptance, production prerequisites and release approval remain separate. This operation does not authorize deployment, sending notifications, policy-gate approval, merge or acceptance closure.
