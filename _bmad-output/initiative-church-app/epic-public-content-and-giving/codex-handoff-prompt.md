# Resume guide: Epic 6 acceptance and Epic 7 inception

Reconciled 30 October 2026 for Israel Muyoba. Repository: `raeltec-systems/church-app`.

## Current position and authorized work

Start by inspecting the actual checkout, applicable instructions, status, worktrees, remotes and current `origin/main`. Preserve concurrent/uncommitted work. The verified starting main is **`c96cd562b2650c37f5d3d879cb12891419700139`**, merged on 28 October 2026. Its tree matches the former `story/5.8-meetings-held` integration branch; there is no unmerged feature implementation to resume there.

The current acceptance branch is **`acceptance/epic-6-reconcile-epic-7-plan`**. The user authorizes regular commits and pushes to this branch so progress is recoverable. That authorization does not include merge to main, deployment, policy approval, notification sending or acceptance completion. Recheck the remote head before publishing changes; use normal non-forced pushes and preserve other work.

Epic 6 features 6.1–6.14, 6.16, 6.18, 6.19 and the Giving-tenure, church-owned-image and private-upload-retention follow-ups have built plans and are merged. **6.15 (owner pilot) and 6.17 (integrated acceptance/promotion) remain open.** The owner permitted the refactor sweep before the pilot, so do not repeat it or treat it as waiving the pilot. Epic 7 is selected for BMAD inception only; its proposed breakdown and unresolved policy decisions require owner review before agreement/build.

The [historical handoff at the starting commit](https://github.com/raeltec-systems/church-app/blob/c96cd562b2650c37f5d3d879cb12891419700139/_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md) preserves the earlier build context. Its Windows path, `a125e79` starting point, pending-feature list, “never push”, staging-deployment directions and renderer bypass were superseded. Do not use them as current instructions or authority.

## Read first

1. The initiative and its `tickets.toml` under `_bmad-output/initiative-church-app/`.
2. `spec-church-app/`: the spec, functional requirements, design contract, acceptance map and delivery/decisions register; then the architecture and owner decision files.
3. This epic’s envelope/Notes, current `tickets.toml`, relevant plans and [implementation/acceptance history](pr-description.md).
4. [Acceptance reconciliation](acceptance-reconciliation-2026-10-30.md), [owner walkthrough](../../../docs/runbooks/content-owner-walkthrough.md), [Content runbook](../../../docs/runbooks/content.md) and [promotion runbook](../../../docs/runbooks/production-promotion-content.md).
5. `docs/runbooks/contracts-and-owner-seams.md`, `identity-access.md`, `notifications.md`, `environments-and-promotion.md` and the Epic 7 envelope before inception.

Dates and story-plan `built` statuses are not owner acceptance. Existing evidence applies to its own commit, environment and scope. Record new results explicitly as `run-passed`, `run-failed`, `blocked`, `skipped` or `authored only`.

## BMAD workflow

Read the current relevant `.agents/skills/bmad-ticket/SKILL.md`, `bmad-build/SKILL.md`, `bmad-code-review/SKILL.md` or other named skill before activating it. Resolve configuration, store and customization through the scripts the skill names.

For build/review wrappers that require rendering, invoke the exact command required by their current SKILL.md with actual absolute paths:

```bash
uv run --no-cache "{project-root}/_bmad/scripts/render_skill.py" --project-root "{project-root}" --skill "{skill-root}"
```

Read the generated workflow. If tooling/network access prevents the renderer, investigate supported environment recovery; report unresolved failures and halt that workflow. **Do not invoke workflow source files directly or substitute another execution route.** The current session resolved its renderer dependency download through the supported permission escalation; that result is not a permanent claim about the next executor.

Story 6.15 has an in-progress preparation plan. Its remaining human pilot prevents marking the whole story `built` or `done`. Story 6.17 stays open through the release evidence/approval boundary. Use ticket tooling for truthful state. Epic 7 uses **bmad-ticket full inception**, preserving CAP-8 and output dependencies; propose the story sequence and visibly unresolved Q4/Q6/Q8 decisions before treating it as agreed.

## Binding behavior and design

A church member or leader must accomplish the promised work through ordinary navigation, not merely call an endpoint. Verify navigation, meaningful content, backend authorization, saved state, feedback, failure/retry, restart and applicable offline behavior. Missing user-facing workflow is unfinished implementation; inaccessible hardware or environment is unverified behavior. Keep those categories separate.

Read `docs/design-handoff/README.md`, the HTML prototypes and relevant images together with the later binding `spec-church-app/design-contract.md`. Reuse `packages/design_system` and shared client components. Preserve the five tabs **Home, Bible & Hymns, Sermons, Give, Calendar**, with My duties, My follow-ups and My cell on Home/account routes. Preserve readable status text, accessible targets, usable back/cancel/retry, safe role navigation and plain empty/error/offline states. Inspect actual reference images before changing a screen; apply the repository taste rules alongside the binding contract.

Keep these settled decisions:

- A new/changed giving destination needs another Admin’s verification. The verifier must hold the active Admin grant for at least 14 elapsed days. Giving remains instruction-only, with no amount form, payer record, receipt or payment-success state.
- Event organisers and Admin see RSVP names; others see counts/spaces only. Current organisers must be event editors. An unscoped ministry leader is not silently granted that access.
- Admin, Media and a granted worship leader set Sunday hymns; Pastor alone does not. Favourites belong only to the current member.
- The supplied official BICC Tonga hymn book ships inside both clients (199 hymns and 67 choruses); staff do not import/edit its text. No sample book is pending. Hymns 25, 29 and 30 still need the recorded printed-source stanza spot-check.
- YouTube or public Facebook video/livestream links are supported. The owner **descoped background audio and hymn audio on 27 October**. Do not reintroduce them as acceptance failures.
- Verified church-owned images bypass Q5 under the recorded exemption; third-party material still needs the applicable source/use clearance. Display-only material is online-only. Private records never enter the public cache.
- Current series posters alone persist offline under the owner’s data-saving decision. Protected duties/cell overlays remain outside that cache.
- Sermon drafts from duties are private snapshots. A second authorized send refers to the existing draft; Media completes and deliberately publishes it.
- Content reaches other modules only through registered owner operations/hooks. Preserve command registries, current authorization, immutable published revisions, idempotency/revision checks and lifecycle/deletion behavior; never broaden table grants to make a journey pass.

## Reconciled evidence and remaining verification

[Hosted run 40733936249](https://github.com/raeltec-systems/church-app/actions/runs/40733936249) succeeded on exact starting main. Its policy log explicitly skipped staging migration drift because `SUPABASE_ACCESS_TOKEN` was unset. See [the inspected summary](evidence-reconciliation-2026-10-30/hosted-main-ci-summary.json). This is historical base-commit evidence, not a candidate-head run or physical-device pilot.

The [migration manifest](evidence-reconciliation-2026-10-30/migration-manifest.json) enumerates and hashes all 101 tracked SQL migrations at that base. It includes the later Cells/Duties review fixes, notably `20261028150927_cells_moved_meeting_place_notices.sql`; compare the complete set, not the old 14-migration subset. A manifest of files is not a report of deployed versions.

Do not reopen historical F1/F3/F8/C1/C2 from an old HOLD list: later source fixes and regressions exist. G1 real last-seat RSVP and G2 scheduler/worker/Storage retention have recorded 13/13 and 6/6 release runs. Rerun affected release gates on the candidate as required by `content.md`, keeping old evidence distinct from new results.

Still specifically unverified: **actual two-session sermon-from-duty lock contention**. The existing SQL regression injects a stale first read and proves the later authority recheck; it does not establish an authentic waiting transaction. A real test must observe the advisory-lock wait, commit reassignment/cancellation/revocation before release, and show refusal with no draft, plus permitted/idempotent recovery.

The connected [read-only staging inspection](evidence-reconciliation-2026-10-30/staging-read-only.json), at **30 October 2026, 21:48:59 Africa/Lusaka (19:48:59 UTC)**, confirmed `bic-kafue-platform-test` (`tmurpotfluignacfueki`). It found **99/101 expected migration versions** with no unexpected versions; `20261027140200` (RSVP rows) and `20261027182300` (hymn-favourites rows) are absent from history. Both real purge bodies are installed, have no missing-rows stub and match repository bodies after CRLF normalization. Both are invoker functions with empty `search_path`; `anon`, `authenticated` and `service_role` cannot execute either directly. Boundary and unowned counts are 0. Edge metadata confirms **content-assets ACTIVE v4** and **notifications-worker ACTIVE v10**.

**Migration-history drift is known and nonzero.** The installed bodies corroborate the later 28 October manual-apply report, but do not supply the missing history entries or prove whole-schema/function/Edge source-byte parity. No deletion or Storage workflow was run by this read. Keep those remaining checks and the device pilot open. Do not replay either `_rows` file or repair history automatically; the discrepancy needs separately reviewed, owner-authorized remediation. This task does not authorize staging mutation or deployment.

Accepted residual (owner, 28 October): process death after a public upload or persistent take-back failure may leave public bytes until the next authorized sync. No autonomous public-object sweep was added. Preserve bounded retries and the residual; do not claim universally immediate removal or redesign system privileges without a scope decision.

## Execute feasible checks

Use the pins in `.github/workflows/ci.yml`: Node 22, Flutter 3.47.6 and Supabase CLI 2.119.0 from the package lock, plus Docker and Chrome where required. Inspect the aggregate runner before use: it resets the isolated local database and restores generated Linux Flutter files. Protect shared work and run it only against the intended disposable checkout/stack.

```bash
npm ci
npm run ci:policy-test
npm run env:check
npm run ci:migrations -- --base origin/main
npm run ci:secrets
npm run ci:function-imports
npm run contracts:test
node --test supabase/functions/content-assets/*.test.mjs
bash tools/ci/run-local-ci.sh /tmp/church-app-ci-results.txt --base origin/main
```

Use the current Content release-gate commands for real HTTP RSVP/retention tests; offline `*.test.mjs` files are not those live integrations. Inspect every step’s result. Keep exact command, full commit, environment/tool versions, date, exit/counts and redacted evidence path. For a blocked check state the missing dependency/access and exact local setup/steps/expected result; do not record it as passed.

Staging has live push recipients. Existing harnesses use guarded local origins and reserved fictional phone blocks; preserve those boundaries. The owner’s narrow live-staging membership exception is documented in the owner decision file, but automated fixtures stay SYNTHETIC and giving samples stay SAMPLE. Use a separate isolated local fixture dataset for a natural-looking walkthrough when needed. Do not publish notifications or approve gates without explicit authority.

## Return to Israel

Give the actual branch/head and pushed commits; explain useful workflows completed and any true implementation gap. Separately list unverified workflows, accepted residuals and owner decisions. Link the candidate evidence ledger, runnable owner walkthrough, design evidence for any touched screen and the Epic 7 inception proposal. State deployment/merge/approval status explicitly. Complete independent preparation while owner-only checks remain open; do not manufacture acceptance so Epic 7 planning can proceed.
