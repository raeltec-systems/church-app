# Story 4.15 evidence: verify Duties and Follow-ups end to end (staging evidence; production is an owner package)

| File | What it is | State |
|---|---|---|
| `local-verification.md` | The full local verification on the final code, including the closing suite (default and `--staging-path`) and the two-run rehearsal | done |
| `duties-staging-suite-local.jsonl`, `duties-staging-suite-local-summary.md` | The closing suite on the local stack (redacted evidence and the matrix summary) | done |
| `duties-staging-suite-staging-path.jsonl`, `duties-staging-suite-staging-path-summary.md` | The same on the staging route against the local stack (sign-up, application, approval; cleanup SQL executed and checked) | done |
| `builds.md`, `builds/` | Clean staging builds: staff web sealed as staging and refused as production, APK arm64 release (debug-signed); redacted logs and checksums | done |
| `owner-demonstration.md` | The mobile and staff-web walkthrough the owner witnesses on staging (4.13 loop, 4.16 items, refusals and disabled gates), with blanks | **pending (owner)** |
| `staging-suite.jsonl`, `staging-suite-summary.md` | The closing suite on staging, run by the parent session (duties.md, story 4.15) | **pending (parent session)** |
| `independent-rerun.jsonl` | The independent reviewer's rerun on staging | **pending (reviewer)** |
| `production-verify.md` | The read-only production checklist (`docs/runbooks/production-promotion-duties.md`, step 7) after the owner's promotion | **pending (owner)** |

Counts (local and `--staging-path`): 22 scenario checks and 22 matrix checks, 253 matrix cells
(11 principals x 12 reads + 11 principals x 11 command probes), every one as expected.

No migration (the suite found no defect). No production, staging or hosted change was made by the
builder. Synthetic data only; fictional numbers; no SMS.
