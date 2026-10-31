# Owner-executed staging history repair: after evidence

Recorded 31 October 2026 against branch source `23aa7f83ecf2dcd581c316bfb68d1d4f5eb8bf0a` and the unchanged 101-migration set reviewed at `34f273a9d31480be07e9a71eb84e502c486dd886`.

## Result and scope

Israel supplied the read-only after-check observed at **2026-10-31T07:35:55.656Z** (09:35:55.656 Africa/Lusaka). The complete migration version/name set now matches all 101 expected versions. Relative to the owner's 06:53:45.775Z preflight, only the two previously missing version/name pairs were added: `20261027140200` and `20261027182300`. No prior version/name pair disappeared or changed.

Both complete function definitions, owners, ACLs, settings and execution permissions match the preflight. Complete definitions also match the generated reviewed reference after CRLF-to-LF normalization; the comparison was not limited to body fingerprints. Both remain invoker functions, owned by postgres, with empty search paths and no direct execution for PUBLIC, anon, authenticated or service_role. Both body fingerprints are unchanged. Boundary violations and unowned objects are zero; the output lists no noninternal history triggers and confirms a read-only verification transaction.

A separate connected `Supabase.list_migrations` read addressed to `tmurpotfluignacfueki` on 31 October also returned the same 101 version/name pairs, including both repaired versions. That corroborates target migration history only; full function evidence is owner-supplied. The project reference printed by the SQL is still a label, not server identity proof.

The strict repository checker is wired to consume the captured migration metadata in the **Manual history repair validation** workflow. **Its new candidate run must pass before this metadata blocker is closed.** The workflow executes the real checker with `--require-synced`; it does not rely on the usual credential-dependent live drift step, which may skip. This is verification of a dated captured observation, not continuous target monitoring.

## Evidence provenance and publication limit

Original attachment: `Pasted text(20261031-073624).txt`, 10,964 bytes; SHA-256 `d7ebd7e590ba056560473210493236a5b9a815118b605600a0be57afb2a2ec1c`.

The GitHub tool blocked uploading the full SQL-containing output. It was not encoded or otherwise republished to bypass that restriction. The full original remains in the conversation attachment. [owner-after-migrations.json](owner-after-migrations.json) is a deliberately reduced, non-SQL record of the returned version/name pairs, observation time and source hash. Its migrations array was compared exactly with the original input before publication.

Reference bundle: artifact `13034207285`, workflow `41179257804`, exact head `23aa7f83ecf2dcd581c316bfb68d1d4f5eb8bf0a`. The downloaded archive SHA-256 was verified as `d1c5bffed4c23b18c0d081a0a2897aba52d54b0c7882fd424da119aaa61ce7b5` before use. The bundle carries expected migrations, complete function descriptors, generated scripts and the prior 14-case isolated PostgreSQL fixture results.

## Stored statement line endings

The four returned stored-statement MD5 values match the exact **CRLF** variants of the generated statements, rather than the LF variants. The initial LF-only fingerprint comparison failed; an explicit CRLF comparison matched all four. No arbitrary whitespace normalization, ignored statements or widened permissions were used to make the comparison pass. These hashes are consistency checks, not signatures or provenance proof.

| Version | Statement 1 MD5 (CRLF) | Statement 2 MD5 (CRLF) |
| --- | --- | --- |
| 20261027140200 | ff61d8087f26729e2361ecf26da1d823 | 78ee6ff66b3e48ccbba03ea939b68385 |
| 20261027182300 | 5413334b4a33e711a05c6f7faf3b11c0 | ddb390dd532cd18b227dbd075113930d |

Do not replay the original migrations, rewrite the history or rerun a line-ending-changed repair merely to force the LF hashes. The repair intentionally rejects differently recorded statement text; successful reconciliation does not require cosmetic normalization of stored history.

## Executed checks and limits

- Offline full input comparison against the verified bundle: passed, including full version/name equality, uniqueness/count, complete function definitions and permissions, both stored statement counts and all four CRLF fingerprints.
- Before/after comparison: all comparable function fields unchanged; exactly two migration pairs added; none removed or renamed. This does not independently snapshot every application row or every field of the original 99 history rows; those preservation assertions belong to the guarded repair and isolated fixture tests.
- Offline validator self-checks: 12/12 passed (CRLF and LF successes; refusal of production label, missing/duplicate migration, wrong name, changed definition, broadened permission, changed statement fingerprint, missing repair row, module finding and non-read-only after-check).
- Full repository CI for source `23aa7f8`, run `41179257778`: all four jobs now completed successfully. Database pgTAP/API smoke/isolated restore and Flutter analyses/tests/web builds completed; this is not a new app pilot or device acceptance.
- New-head strict drift and fixture results must be read from the resulting workflow, with their exact commit. Do not relabel the preceding-head full CI result as a new-head run.

No hosted mutation was issued by the assistant. This evidence does not close broader schema/function parity, deletion workflows, G1/G2 real integrations, actual two-session sermon locking, owner/device acceptance, known functional limitations, production prerequisites or release approval. Story 6.15 remains in progress; 6.17 remains planned. The approved Epic 7 plan remains canonical and unimplemented, with Q4/Q6/Q8 and affected human checkpoints still open.
