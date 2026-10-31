# Acceptance update — 31 October 2026

## What this update supersedes

The [30 October reconciliation](acceptance-reconciliation-2026-10-30.md) remains a dated observation, not the current status of the approvals or the two-entry history mismatch. This update supersedes only those points and records their evidence. It does not rewrite historical failed checks as successes or close the owner pilot.

## Closed: narrow staging migration-history mismatch

Israel approved the bounded metadata repair and executed the owner-run scripts. His read-only after-check, observed at `2026-10-31T07:35:55.656Z`, reports 101 migration records, including `20261027140200` and `20261027182300`, with zero boundary violations and zero unowned objects. Complete definitions and permission descriptors for both functions match the preflight and reviewed reference; the original 99 version/name pairs are unchanged. The four stored-statement fingerprints match exact CRLF variants of the supplied statements. No original migration replay is required.

A separately targeted connected staging migration-list read corroborates all 101 version/name pairs. The actual strict repository checker returned **in_sync** with successful exit in [run 41181686464](https://github.com/raeltec-systems/church-app/actions/runs/41181686464) on exact verification commit `b197d5cd49b1523e389aaf0e8fe78c68a2fd2651`; the same run passed 14/14 isolated repair fixtures. The [evidence record](evidence-history-repair-2026-10-31/README.md) explains provenance, line endings, the raw-evidence publication limit and the distinction between captured-history verification and live application acceptance.

**Disposition: close this two-entry metadata blocker only. Do not rerun the repair or change stored statement line endings.** Full deployed schema/function parity and actual deletion-workflow behavior remain separate checks. The assistant performed no hosted mutation.

## Adopted: approved Epic 7 planning

The owner's approval of the recommended 14-story sequence is already reflected in [canonical tickets](../epic-cell-attendance-and-private-reports/tickets.toml) and the [adoption record](../epic-cell-attendance-and-private-reports/adoption-2026-10-31.md). Parsed entry content is unchanged from the reviewed proposal. [Planning run 41181686506](https://github.com/raeltec-systems/church-app/actions/runs/41181686506) passed on verification commit `b197d5c`.

All 14 stories remain planned, with 7.1 the next structurally ready story. Its planning checkpoint must review attendance readership/retention and the report-care authority/lifecycle boundary. Approval of the sequence did not choose Q4 visitor/youth/report privacy and retention, Q6 named operators, or Q8 exact report timing and metric definitions. No leaf implementation or acceptance completion is recorded by this update.

## Still open: known functional limitations and dispositions

Preserve the [reconciled limitation table](acceptance-reconciliation-2026-10-30.md#unfinished-capability-and-known-behavior-requiring-disposition): organiser permissions tied to editor roles; cancellation unavailable while RSVP is disabled; event linking from an existing duty date; the absent staff Send to Media action; sermon drafts remaining snapshots; favourites lacking durable offline persistence; and failed staff refresh replacing the list with an error. These are established behaviors or missing capabilities, not problems that more testing alone will implement. Owner disposition remains separate where documented. Preserve the existing owner-accepted residual concerning public uploads after process death or persistent take-back failure.

## Still open: verification and owner evidence

The [normal-app owner walkthrough](../../../docs/runbooks/content-owner-walkthrough.md) and [local validation instructions](evidence-reconciliation-2026-10-30/local-validation.md) remain the actionable procedures. Outstanding evidence includes fresh G1/G2 real integration runs where required, actual two-session sermon locking, signed-in cross-client workflows, physical-device checks, hymn 25/29/30 source review, giving/provider verification, broader deployed parity, predecessor production prerequisites and explicit release approval. No new device, notification-delivery or owner-pilot result is claimed here.

**6.15 stays in progress; 6.17 stays planned.** No merge, deployment, policy-gate approval, publication, notification send or acceptance completion is authorized by this metadata closure. The runtime app, design system, dependency locks and SQL migrations are unchanged by these verification/documentation checkpoints.

## Later 31 October continuation: executable checks, not acceptance

The [continuation evidence package](evidence-acceptance-continuation-2026-10-31/README.md) supersedes the earlier list of unrun local G1/G2 and backend sermon-lock checks: fresh local RSVP 13/13, retention 6/6 and actual database contention 13/13 now passed. It preserves Windows test limitations, initial failures and retries. The [owner closeout checklist](../../../docs/runbooks/content-acceptance-closeout.md) separates the remaining normal-UI, device, known-capability and release decisions. Full deletion and exact-head CI results are recorded in the package's final observations.

This continuation makes no app/design/migration change. The signed-in browser authoring/execution request was blocked by tool safety and was not bypassed. No owner pilot, independent reviewer, native-device acceptance or production promotion is claimed. **6.15 remains in-progress; 6.17 remains planned.**
