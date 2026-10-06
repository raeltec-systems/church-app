# Runbook: backup, independent recovery journal and isolated restore (story 1.10)

AD-14 and AD-17 say a restore must never bring back access or objects that were revoked or deleted after the backup was taken. A database-only backup is not a restore plan. This runbook describes what milestone 1 provides, how to rehearse it, and which owner decisions still gate real data.

Everything here is **SYNTHETIC**. Real-data backups stay off until the Q4 and Q12 gates are resolved (see "Gates").

## The three parts

| Part | What it is | Where |
|------|------------|-------|
| Database bytes | `pg_dump` of the `app` and `api` schemas. The artifact ends with `set app.restore_in_progress = 'on'; select app.rcv_hold_after_restore('<backup_id>', '<operator>')`, so any restore of it lands **held** and deletes restored Auth sessions and refresh tokens. That includes a plain `psql -f` with no `ON_ERROR_STOP` and no single transaction; the rehearsal checks this case. | Rehearsal: gitignored `.recovery-state/backups/<backup_id>/database.sql`, with a sha256 in `manifest.json`. |
| Object bytes | Each object is downloaded separately through the Storage API and checked against a sha256 in the manifest. | Rehearsal: `.recovery-state/backups/<backup_id>/objects/`, plus a copy and the manifest in the owner's Drive folder. |
| Recovery journal | Append-only, hash-chained segments outside the database and its rollback lifecycle. Each segment holds opaque UUIDs, a bucket, the kind, seq, times and hashes, and nothing else. Every kind only denies: `access_revoked`, `deletion_manifest` (written before the destructive step), `deletion_completed`, plus `checkpoint` and `seal`. | `tools/recovery/journal.mjs`, behind an adapter. See "Journal adapters". |

### Database side (`supabase/migrations/20261003161000_recovery_journal.sql`)

- `app.rcv_recovery_state` holds one of three states: `live`, `restored_held` or `reconciled`. A missing row counts as held.
- While the state is `restored_held`, the release gates `private_access` and `outbound_sending` read as closed through `app.policy_effective` and `app.policy_is_open`. This applies even when the restored snapshot had them approved. The gates are the existing ones from 1.5, not new ones, and `tools/ci/verify-hosted.sql` (1.8) now also fails promotion onto a held database.
- `app.rcv_hold_after_restore` runs only in a restore session, meaning `app.restore_in_progress = 'on'` is set in that session. A mistaken call on a live database is refused and signs nobody out. The function does not depend on operator rows in the restored snapshot; the operator name is used for attribution only.
- `app.rcv_journal_acks` records the journal entries the database has applied. Its highest seq is the watermark that a snapshot carries.
- `app.rcv_apply_journal_entry(entry, operator)` applies or replays one entry and is idempotent. If an applied seq comes back with a different hash, it fails with `journal_mismatch`.
- `app.rcv_complete_reconciliation(restore_id, head_seq, head_hash, verified_absent[], operator)` clears the hold only when all of these hold:
  - every entry from 1 to the head has been applied;
  - the head is the applied `seal`;
  - every object the journal deleted is listed as verified absent from the restored store.
- `app.rcv_record_refusal` records why a reconciliation was refused. `app.rcv_recovery_status()` reports the current state.
- Only a restricted operator can run any of this (`ops_operators`, story 1.9). No client role has grants on it.

## Journal completeness (fail closed)

`verifyJournal(entries, {cutoff, databaseWatermark})` accepts a journal only when all of these are true:

- the seq runs from 1 with no gaps;
- every `prev_hash` and `hash` checks out;
- the last entry is a `seal` whose `cutoff` is at or after the chosen recovery cut-off;
- the head is at or after the restored database's watermark;
- for every seq the restored database already applied, the database's recorded hash equals the journal's hash at that seq. Otherwise the reason is `journal_mismatch`, and the journal is refused before any replay.

A seal's `cutoff` can never be later than the seal's own `at`, because a seal only vouches for what was journaled before it was written. If any step of the replay fails, the tool records the refusal (`journal_mismatch` or `replay_failed`), and the hold stays.

Otherwise it returns one of these reasons, and the hold stays: `journal_absent`, `journal_malformed`, `journal_gap`, `journal_chain_broken`, `journal_unsealed`, `journal_seal_before_cutoff`, `journal_behind_database`, `journal_mismatch`.

**Single writer.** Each journal has exactly one writer at a time.

- `LocalSegmentJournal` claims each seq with a create-only `claim-<seq>` file, so a concurrent append of the same seq fails.
- `DriveJournal` lists the folder again after each create and fails loudly (`journal fork`) if two segments share a seq.

If either error happens, stop every writer and reconcile the journal before writing again.

## Journal adapters

| Adapter | Use |
|---------|-----|
| `LocalSegmentJournal(dir)` | Create-only files (`wx`). Used for local rehearsals and CI, and for reconciling from a readback directory. |
| `DriveJournal({client, folderId})` | A Google Drive folder. It can only list, download and create files. It never updates, trashes or shares them. |
| `DriveRestClient({accessToken})` | A Drive REST v3 client for unattended use. It is unit-tested only and **not exercised live** (see "Owner steps"). |

The adapter for each environment is set in `config/environments/*.json` under `recovery.journal.adapter`, and `node tools/env/environments.mjs check` validates it:

- local: `local_segments`
- staging: `google_drive_folder`
- production: `owner_selection_required`

The milestone 1 journal location is the owner's private Drive folder `bic-kafue-ops-SYNTHETIC-recovery-rehearsal`, which only Israel can access. Its file IDs are recorded in `_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.10/drive-files.md`. The Google Drive connector is agent-mediated. In the rehearsal, each segment was written locally first, then created in the Drive `journal/` subfolder through the connector. The Drive copy was then read back into a directory, and the restore was reconciled **from that readback**.

## Rehearsal (local only, never hosted)

Restores go into **isolation only**:

- the database goes into a throwaway container `bic-rcv-isolated`, built from the same image as the local stack, with `--network none`, no published port and no API;
- objects go into `.recovery-state/isolated-objects/<scenario>/`.

Never restore into hosted staging or production.

```bash
npm run db:start                  # Storage must be running
npm run recovery:rehearse         # seed -> backup T1 -> revoke -> delete -> seal -> 6 isolated restores
```

The six restores check the following. Every restore first lands `restored_held`, with both gates closed even under a rolled-back owner approval.

| Scenario | Expected |
|----------|----------|
| `absent`, `gap`, `tampered`, `unsealed`, `early_seal` | Held, with the refusal recorded. Gates stay closed even if approved. The restored object stays in the isolated store but is not served. |
| `complete` | Newer entries are replayed, the subject's access is revoked, the restored object is removed and verified absent, and the state becomes `reconciled`. After that the gates depend only on owner approval, and they stay closed because they are unresolved. |

To run it step by step (for example, to mirror each segment to Drive in between):

```bash
node tools/recovery/rehearse.mjs seed|backup|revoke|delete|seal
node tools/recovery/rehearse.mjs restore <scenario>       # restore T1 into isolated rcv_<scenario>; lands held
node tools/recovery/rehearse.mjs reconcile <scenario> [--journal-dir <readback dir>] [--cutoff <iso>]
                                                          # exits 1 with the refusal reason if incomplete
node tools/recovery/rehearse.mjs status <scenario>        # recovery status and gate probe of that target
node tools/recovery/rehearse.mjs scenario <scenario> [--journal-dir <dir>]   # restore + reconcile + expectations
node tools/recovery/rehearse.mjs cleanup     # removes the container and any local marker it set
```

The journal in `.recovery-state/journal` is long-lived, because it is the independent record. If the local database acknowledges entries that journal does not hold, `seed` refuses. Fix it with `npm run db:reset`.

## Restore procedure (any environment; operator: `israel`)

1. **Decide the cut-off and seal.**
   - Choose the recovery point: the time the source system stopped being trusted.
   - Stop the journal's writer.
   - Then write a `seal` whose `cutoff` is that recovery point. The seal's own time is "now", which is never earlier than its cutoff.
   - Reconciliation requires a seal whose cutoff is at or after the recovery point you use.
2. **Prepare an isolated target.** Use a new database or project with no clients pointed at it. Never use the live project.
3. **Restore the database artifact** in one transaction (`psql -v ON_ERROR_STOP=1 --single-transaction -f database.sql`). The artifact applies the hold. If the backup came from somewhere else (for example, a provider's backup), run `set app.restore_in_progress = 'on'; select app.rcv_hold_after_restore('<backup id>', 'israel'); reset app.restore_in_progress;` **before anything else**.
4. **Re-assert the environment marker** for the target (`contracts-and-owner-seams.md`), and revoke the source environment's system credentials (`system-access-and-operations.md`).
5. **Restore objects** from the object backup, checking each sha256 against the manifest.
6. **Reconcile.** The rehearsal's reference implementation is `rehearse.mjs reconcile <target>` followed by `status <target>`.
   - Read the journal from its independent location and run `verifyJournal` with the cut-off and the database's acknowledgements (`seq` and `entry_hash` from `app.rcv_journal_acks`).
   - If it is not complete, run `app.rcv_record_refusal` and **stop**. Access and sending stay disabled until the owner has revalidated access.
   - If it is complete:
     - apply every entry with `app.rcv_apply_journal_entry`;
     - delete each named object from the restored store and verify it is absent;
     - then run `app.rcv_complete_reconciliation`.
   - If any replay step fails, record the refusal and stop.
7. **Verify.** `app.rcv_recovery_status()` should show `reconciled`, and `tools/ci/verify-hosted.sql` must pass before any client is pointed at the target.

## Gates (unresolved; set by the owner, never by this runbook)

| Gate | Blocks |
|------|--------|
| **Q4** (`q4_personal_data`) | Journal and backup retention, plus access to them until affected backups expire. Real-data backups wait for it. |
| **Q12** (`q12_operations`) | RPO/RTO, the backup schedule and backup alerting. The full release restore demonstration waits for it. |
| Independent production store | The owner chooses a restricted journal and object store before real data. `production.json` keeps `owner_selection_required`. |

`recovery.activation.real_data_backups` must stay `false` in every config, and the validator enforces this.

## Owner steps

1. **Unattended Drive journal.** Only needed if Drive stays the journal before the production store is chosen. Create an OAuth token restricted to the rehearsal folder, store it only in a server or CI secret store, and wire it to `DriveRestClient`. Until then, operators write the journal through the connector.
2. **Hosted staging schema.** Apply `20261003161000_recovery_journal.sql` to `tmurpotfluignacfueki`. Either approve the Supabase connector's `apply_migration` (name `recovery_journal`) and then rename the local file to the version it records, or run the `promote.yml` staging promotion, which applies it under its own version.
3. Resolve Q4 and Q12, and choose the production journal and object store.

## Tests

- `supabase/tests/recovery_journal_test.sql` (pgTAP, `npm run db:test`) covers hold and gates, session deletion, replay idempotency and mismatch, content refusal, completion guards, fail-closed handling of a missing state row, and privileges.
- `tools/recovery/*.test.mjs` (`npm run ci:policy-test`) covers hashing, create-only segments, every incomplete reason, the Drive adapter (fake client), the REST client (stubbed fetch), scenario derivation and expectations.
- `tools/env/environments.test.mjs` covers the `recovery` config block.
- The CI `db` job runs `npm run recovery:rehearse` with Storage enabled.
