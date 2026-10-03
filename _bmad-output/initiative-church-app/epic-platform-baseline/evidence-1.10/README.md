# Evidence: story 1.10, isolated recovery with an independent journal (SYNTHETIC)

This evidence was recorded on 2026-10-03 against the local Supabase stack. The local database was reset first, and Storage was running. Restores went only into the throwaway container `bic-rcv-isolated` (`--network none`, no published ports) and into isolated object directories. No hosted project was restored into.

| File | What it shows |
|------|---------------|
| `rehearsal-log.jsonl` | The raw step-by-step run: `seed`, then `backup` (T1, journal watermark 1), `revoke` (seq 2), `delete` (seq 3 deletion manifest, Storage DELETE then HTTP 400 on read, seq 4 deletion completed), `seal` (seq 5), then `restore` for `drive` (from the Drive readback), `absent`, `gap`, `tampered`, `unsealed`, `early_seal` and `complete`, then `cleanup`. |
| `scenario-summary.json` | A condensed per-scenario view of the restored state, the journal verdict, the outcome, and the gates with and without a rolled-back owner approval. |
| `isolated-db-rows.txt` | Rows from each isolated restored database: recovery events, state, journal acks, the synthetic subject and object, and live gate values. |
| `backup-t1-manifest.json` | The T1 backup manifest: sha256 values, the watermark, and the bucket and object ID. |
| `drive-files.md`, `drive-readback/`, `drive-readback-index.json` | Drive file IDs and names; the journal read back from Drive is byte-identical to the local journal. |
| `npm-recovery-rehearse-second-run.jsonl` | `npm run recovery:rehearse` (the CI command), run a second time on top of the same long-lived journal, which by then held seq 6 to 10. It reported no problems. |

## Results

Every restore first landed `restored_held`. In that state `private_access` and `outbound_sending` were closed, even under a rolled-back owner approval. The subject still had access in the restored T1 snapshot, and the object was present in the isolated store.

| Scenario | Verdict | Outcome | After |
|----------|---------|---------|-------|
| drive (Drive readback) | complete | reconciled | Seqs 2 to 5 replayed (seq 1 was already in the snapshot). Subject access revoked, restored object removed and verified absent. Gates open only if approved; unapproved, they stay closed. |
| complete (local journal) | complete | reconciled | Same as drive. |
| absent | journal_absent | held | Refusal recorded. Gates closed even if approved. |
| gap (seq 3 missing) | journal_gap | held | As above. |
| tampered (seq 2 subject changed) | journal_chain_broken | held | As above. |
| unsealed (seal missing) | journal_unsealed | held | As above. |
| early_seal (cut-off 1 h after the seal) | journal_seal_before_cutoff | held | As above. |

## Checks run

| Check | Result |
|-------|--------|
| `npx supabase db reset` then `npm run db:test` | 5 files, 348 tests pass, including the 44 in `recovery_journal_test.sql`; passed again after the rehearsals. |
| `npm run db:smoke` | Exit 0. |
| `npm run ci:policy-test` | 45 pass. |
| `npm run env:check`, `ci:migrations --base f93eac0…`, `ci:secrets` | All clean. |

## Hosted staging (`tmurpotfluignacfueki`)

`apply_migration` with name `recovery_journal` and the exact local file contents (sha256 `08d43730…1ddf1`) timed out twice at 60 s. Afterwards `list_migrations` still ended at `20261003155428`, and `to_regclass('app.rcv_recovery_state')` returned null, so nothing was applied. This is an owner step; see `docs/runbooks/backup-and-restore.md`, "Owner steps". Nothing was restored into staging.
