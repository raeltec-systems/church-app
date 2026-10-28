# Story 6.3 external check (independent reviewer)

The entry's external check: an independent reviewer repeated the giving permission,
re-verification and payer-field cases against the verify and K1, K15, K16, with the owner's
2026-10-21 decision (a destination added or changed by one Admin is verified by a different Admin
before members see it). Read-only review of the diff since `d2ed154`, the evidence and the offline
E2E tests.

## First pass: FAIL (1 high, 2 medium, 4 low)

1. High: the Admin who changed a destination could verify it after any other Admin saved the
   draft, even a save that changed nothing (the rule compared only the last saver). Fixed: every
   saver of a revision is recorded (`saved_by_members`, `saved_by_accounts`) and none of them may
   verify, in the command and in the trigger; a save that changes nothing is refused
   (`method_id: unchanged`); each save records its changed field names; new
   `content.discard_giving_draft` so two Admins who both saved a draft can start afresh.
2. Medium: one person can hold two Admin identities (Identity lets one Admin approve a member and
   grant Admin alone). Not fixed in Content: a "granted by the saver" rule would block the normal
   case where the first Admin grants the second. Recorded as a residual risk in the runbook and an
   owner question.
3. Medium: the tested date could be before the save it vouches for. Fixed:
   `tested_on: before_saved`.
4. Low: one direct UPDATE could add a verification together with a content or saver change.
   Fixed in the trigger, with pgTAP cases.
5. Low: the mobile "Copied" state could outlive the copied value. Fixed (keyed by value and
   publication revision), with a test.
6. Low: the test note invited transaction data. Fixed (helper text; examples changed).
7. Low: promotion runbook, doc wording and staging evidence missing. Done
   (`production-promotion-content.md`, `content.md`, `staging-verify.md`).

## Second pass: PASS

Findings 1, 3, 4, 5 and 6 closed; property 1 (no Admin publishes a destination alone) and
property 2 (no payer data anywhere) hold. Residual notes, recorded as deferred in the plan: a
two-statement direct write by a database-owner role could still rewrite an unverified row's saver
list before verifying (owner roles only, never the app); the Admins' read names only the last
saver; the savers list is capped at 50.
