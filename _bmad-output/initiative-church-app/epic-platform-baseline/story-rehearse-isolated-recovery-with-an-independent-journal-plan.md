---
title: 'Rehearse isolated recovery with an independent journal'
type: 'feature'
ticket: '10'
created: '2026-10-03'
status: 'blocked'
blocked_reason: 'staging apply of recovery_journal needs owner approval (MCP apply timed out 3x awaiting confirmation of in-function auth session delete)'
baseline_revision: 'f93eac02d09b212822c8614a15fb4a5aa64a7685'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing records revocations/deletions outside the database's own rollback lifecycle, and no procedure restores a database-plus-object backup, so restoring an older snapshot would silently resurrect revoked access and deleted objects (P9, AD-14, AD-17).

**Approach:** An append-only, hash-chained recovery journal behind an adapter interface (local segment files, plus the owner's private Google Drive folder through the connector), a DB recovery state that keeps the existing `private_access`/`outbound_sending` release gates closed while a restore is unreconciled, and a rehearsal tool that backs up one synthetic subject and object, restores the older snapshot into an isolated throwaway Postgres container plus an isolated object directory, replays newer journal entries, removes the restored object, and only then clears the hold.

## Boundaries & Constraints

**Always:** journal entries carry only opaque UUIDs, a bucket name, kind, seq, times and hashes (no content); journal segments are create-only (never rewritten); entries are deny-only so an entry whose DB transaction rolled back is safe to replay; the backup artifact itself applies the hold when restored; restore targets are isolated (no published port, no API); hold reuses the 1.5 gates via `app.policy_effective`, not a new gate set; operator-only functions have no client grants; migration is additive with `rcv_` prefix owned by `platform`; synthetic data only.

**Never:** restore into hosted staging or any hosted project; share Drive files or touch Drive files outside the rehearsal folder; invent Q4 retention or Q12 RPO/RTO values; a scheduler/worker; edits to merged migrations or other lanes' files.

- Decision (agent, under owner pre-approval): Drive folder `bic-kafue-ops-SYNTHETIC-recovery-rehearsal` (id `18v5zuOlrRr8UzJqNwLq5jpX5JOCI0t1h`, owner-only permissions) holds the journal mirror and backup manifest/object copy. The connector is agent-mediated, so the in-repo `DriveJournal` adapter takes an injected client; the rehearsal writes segments through the connector, reads them back into a directory and reconciles from that readback. A token-based Drive client for unattended use is an owner step before real data.
- Decision (agent, under owner pre-approval): the large DB dump stays in the gitignored local `.recovery-state/`; Drive gets the backup manifest (sha256 of dump and object) and the synthetic object bytes. The real independent object store is chosen before real data (owner decision).
- Decision (agent, under owner pre-approval): journal completeness = contiguous seq from 1, valid hash chain, a final `seal` entry whose cutoff ≥ the requested recovery cutoff, and head ≥ the restored DB's acknowledged watermark; anything else keeps the hold.
- Decision (agent, under owner pre-approval): Q4 (journal retention) and Q12 (RPO/RTO, backup schedule) stay gates: config `recovery.activation.*` false; runbook lists them.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Complete journal | T1 snapshot restored; journal 1..N sealed after cutoff | entries > watermark replayed: access revoked, object marked deleted and removed from isolated store, verified absent; state `reconciled`; gates then depend only on owner approval | — |
| Absent journal | no journal | state stays `restored_held`; `policy_is_open('private_access'/'outbound_sending')` false even if approved | exit non-zero, reason `journal_absent` |
| Gap / tampered / unsealed / sealed before cutoff / behind DB watermark | incomplete journal | held, nothing reconciled | reasons `journal_gap`, `journal_chain_broken`, `journal_unsealed`, `journal_seal_before_cutoff`, `journal_behind_database` |
| Re-run reconcile | already applied | idempotent | — |
| Complete with wrong restore id / unverified object | — | refused, held | SQL error |
| Restore via plain psql of artifact | dump file | lands `restored_held`, restored sessions deleted | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `policy_gates` (`private_access`, `outbound_sending`), `policy_effective`/`policy_is_open`, `platform_current_environment`, `contract_module_prefixes`, revoke loop pattern. Do not edit; redefine `policy_effective` in the new migration with the same body plus the hold check.
- `supabase/migrations/20261003154040_bounded_system_access.sql` -- prefix registration and `ops_operators` (FK for operator names) to mirror.
- `supabase/tests/system_access_test.sql`, `system_api_smoke.sh` -- pgTAP and `pg()` helper style.
- `tools/env/environments.mjs` (+test), `config/environments/*.json` -- add a validated `recovery` block.
- `tools/ci/verify-hosted.sql` -- add: recovery state not held on hosted.
- `.github/workflows/ci.yml` -- `policy` runs `tools/*/*.test.mjs`; `db` job excludes storage-api (rehearsal needs it).
- `docs/runbooks/system-access-and-operations.md`, `environments-and-promotion.md`, `contracts-and-owner-seams.md` -- link the new backup/restore runbook.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261003161000_recovery_journal.sql` -- `rcv_` prefix; `rcv_recovery_state`, `rcv_journal_acks`, `rcv_events`, SYNTHETIC `rcv_fixture_subjects/objects`; `rcv_apply_journal_entry`, `rcv_hold_after_restore`, `rcv_complete_reconciliation`, `rcv_serving_hold`, `rcv_recovery_status`, fixture helpers; redefined `policy_effective`; no grants.
- [x] `supabase/tests/recovery_journal_test.sql` -- pgTAP for hold/gates, replay idempotency, completion guards, privileges, session invalidation.
- [x] `tools/recovery/journal.mjs` (+test) -- entry schema, hashing, `LocalSegmentJournal`, `DriveJournal` (injected client), `verifyJournal`.
- [x] `tools/recovery/rehearse.mjs` (+test where pure) -- seed/backup/revoke/delete/seal/restore/reconcile/status/`all`; isolated container target.
- [x] `config/environments/*.json`, `tools/env/environments.mjs` (+test) -- `recovery` block, flags false.
- [x] `tools/ci/verify-hosted.sql`, `.github/workflows/ci.yml`, `package.json`, `.gitignore` -- checks and scripts.
- [x] `docs/runbooks/backup-and-restore.md` + links -- procedure, owner steps, gates.
- [ ] Hosted staging -- apply migration (same name), verify not held, advisors. (connector apply timed out twice; the coordinator applies it after merge)
- [x] `evidence-1.10/` -- raw outputs, Drive file ids/names.

**Acceptance Criteria:**
- Given `supabase db reset`, when `npm run db:test`, `db:smoke`, `ci:policy-test` and `recovery:rehearse` run, then all pass.
- Given the Drive readback journal, when reconcile runs against the restored T1 snapshot, then the subject's access is revoked, the restored object is gone, and the hold clears only afterwards.

## Implementation Notes

Implemented 2026-10-03 directly (no subagent tool in this session).

**What landed**
- Migration `20261003161000_recovery_journal.sql` (additive). It adds:
  - the `rcv_` prefix, owned by `platform`;
  - `rcv_recovery_state` (seeded `live`), `rcv_journal_acks`, `rcv_events` (content-free) and the SYNTHETIC `rcv_synthetic_subjects`/`rcv_synthetic_objects`;
  - the operator-only functions `rcv_apply_journal_entry`, `rcv_hold_after_restore` (also deletes `auth.refresh_tokens`/`auth.sessions` when present), `rcv_record_refusal`, `rcv_complete_reconciliation`, `rcv_serving_hold` (a missing row counts as held) and `rcv_recovery_status`;
  - `app.policy_effective`, redefined with the 1.5 body plus the hold check for `private_access`/`outbound_sending`;
  - no client grants.
- `tools/recovery/journal.mjs` provides:
  - canonical JSON and a sha256 hash chain;
  - per-kind field allowlists (content refused);
  - `LocalSegmentJournal` (create-only `wx`), `DriveJournal` (injected client: list/download/create only), `DriveRestClient` (token-based, unit-tested only);
  - `verifyJournal`, with seven fail-closed reasons.
- `tools/recovery/rehearse.mjs`:
  - backs up from the local stack: a pg_dump of `app`+`api` with an appended hold call, and object bytes through the Storage API, with sha256 manifests;
  - restores into the `bic-rcv-isolated` container (`--network none`) plus isolated object dirs;
  - covers six scenarios, plus `drive` through `--journal-dir`;
  - checks gates with a rolled-back approval probe.
- Config `recovery` block (local `local_segments`, staging `google_drive_folder`, production `owner_selection_required`; `restore_target: isolated_only`; `activation.real_data_backups: false` gated by Q4+Q12), validated by `validateRecovery`.
- `verify-hosted.sql` fails promotion onto a held database.
- CI: the `policy` job runs `tools/recovery` tests; the `db` job starts storage-api and runs `npm run recovery:rehearse`.
- `.gitignore` adds `.recovery-state/`.
- Runbooks: `docs/runbooks/backup-and-restore.md`, linked from the environments, system-access and contracts runbooks.
- Drive: the folder `18v5zuOlrRr8UzJqNwLq5jpX5JOCI0t1h` (owner-only), with `journal/` holding 5 segments and `backups/` holding the manifest and object (`evidence-1.10/drive-files.md`).

**Decisions / surprises**
- The source local DB acks must be a prefix of the long-lived `.recovery-state/journal`. `seed` refuses otherwise (`npm run db:reset` fixes it). The pgTAP file clears rehearsal rows inside its rolled-back transaction.
- Entries are applied in full on replay. Seq 1 was already acked in the snapshot and reports `newly_applied: false`. Effects are re-applied each time because they are deny-only.
- The 175 KB DB artifact is not uploaded to Drive (the connector takes content inline). Its sha256 is in the Drive manifest.
- In the rehearsal, Drive segments were mirrored by the agent through the connector after each local append. Reconciliation of the `drive` scenario used only the bytes read back from Drive.
- Hosted `apply_migration` timed out twice with nothing applied, probably at the approval prompt for the `delete from auth.*` statements inside the function body (no schema object is dropped). This is the blocked reason.

**Verification**
- After `db reset`: `db:test` 348/348 (44 new), `db:smoke` exit 0, `recovery:rehearse` exit 0 (twice, on the same journal), `ci:policy-test` 45/45, `env:check`, `ci:migrations --base f93eac0`, `ci:secrets` clean.
- Isolated restores: `drive` and `complete` reconciled (subject revoked, object removed and verified absent, gates follow approval only); `absent`, `gap`, `tampered`, `unsealed` and `early_seal` stayed held with gates closed even when approved. Raw evidence is in `evidence-1.10/`.

**Matrix audit**
- Complete: rehearse `complete`/`drive`, pgTAP.
- Absent: rehearse, pgTAP refusal.
- Gap / tampered / unsealed / early seal: rehearse plus unit tests. Behind DB watermark: unit test.
- Re-run idempotent: pgTAP.
- Wrong restore id / unverified object: pgTAP.
- Plain psql restore of the artifact lands held: rehearse restores the artifact with `psql`; session deletion is covered by pgTAP.
- All of these ran and passed.

**Review follow-up (2026-10-03)** (edits are in place because the migration is not on staging yet):
- `rcv_hold_after_restore` refuses unless `app.restore_in_progress = 'on'` is set in the session, so a call outside a restore deletes no session. The artifact sets the flag, calls the hold, then resets it. The hold no longer checks operator rows; it only validates the name's format.
- `rcv_apply_journal_entry` requires a valid `at`. A seal must carry `head_seq = seq - 1` and a `cutoff`, and the cutoff may not be after the seal's `at`. JS `validateEntry` enforces the same cutoff rule.
- Journal appends:
  - Local append claims each seq with a `wx` `claim-<seq>` file.
  - Drive append re-lists after the create and fails with `journal fork` on a duplicate seq.
  - The runbook documents the single-writer rule.
- Before replay, `verifyJournal` compares the restored database's acks (seq and hash) with the journal (`journal_mismatch`). Any replay failure records a refusal (`journal_mismatch` or `replay_failed`).
- `rehearse.mjs` commands:
  - `restore` now only restores.
  - `reconcile` exits 1 with the refusal reason.
  - `status` and `scenario` are new.
  - `all` adds a plain `psql -f` restore check (no `ON_ERROR_STOP`, no single transaction), which lands `restored_held`.
- `validateRecovery` message reworded; the `validateEnvironments` JSDoc is back in place.
- Verified:
  - `db reset`, then the recovery pgTAP file passed 53 of 53.
  - `tools/recovery` tests passed 12 of 12, and `tools/env` tests passed 12 of 12.
  - `recovery:rehearse` exited 0, including the plain-psql check.
  - The CLI checks behaved as expected: `reconcile absent` exits 1 with `journal_absent`, and a forked journal gives `journal_mismatch` with the hold kept.

## Plan Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| (parent) rcv_hold_after_restore can wipe live sessions if called by a DB owner on a live DB | medium | patch | function deletes all auth.sessions/refresh_tokens; only client grants revoked |
| hosted staging migration not applied | medium | parent action | evidence README: staging ends at 20261003155428; applied by parent after merge |
| reconcile/status commands missing | medium | patch | rehearse.mjs main() switch lacks both; `restore absent` exits 0 |
| seal cutoff can exceed its own `at` | high | patch | validateEntry checks ISO only; defeats journal_seal_before_cutoff |
| SQL accepts entries without `at`; revocation ack'd without effect | high | patch | coalesce(access_revoked_at, NULL) then reconciliation clears hold |
| artifact hold fails under plain psql if operator row absent | medium | patch | rcv_require_operator reads restored snapshot; rest of dump loads |
| concurrent appends fork journal | low | patch | read-head-then-create; Drive allows duplicate names |
| hash mismatch crashes replay with no refusal | medium | patch | verifyJournal compares seq only |
| folder_id called private but committed in evidence | low | patch | validator wording vs evidence files |
| displaced JSDoc | low | patch | environments.mjs ~146-190 |

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- pass.
- `npm run ci:policy-test && npm run env:check && npm run ci:migrations && npm run ci:secrets` -- pass.
- `npm run recovery:rehearse` -- all scenarios as the matrix; evidence saved.
