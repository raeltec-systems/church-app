# Evidence: story 2.11, delete a member fully through a resumable workflow

Plan: `../story-delete-a-member-fully-through-a-resumable-workflow-plan.md`. Runbook: `docs/runbooks/identity-access.md`, section "Full member deletion through a resumable workflow (story 2.11)".

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0, the existing edge-runtime image), on 2026-10-07, with synthetic fictional numbers only. No hosted project was touched. No SMS provider, hook, test OTP or SMS MFA exists. The phone switch was found off, was on only for the E2E runs, and is off again.

## Files

| File | What it shows |
|---|---|
| `deletion-e2e.jsonl` | `tools/identity-e2e/deletion.mjs`: 11/11 checks through real GoTrue (phone/password sign-in, refresh), PostgREST, the 1.9 system route, the real worker CLI, the served Edge Function `identity-deletion`, the 1.10 journal and an isolated restore. Statuses, codes, counts and booleans only. |

## The verify bullet, row by row

| Case | Evidence |
|---|---|
| Delete a member WITH a login (in the app) | E2E `D10`, `D13`: the member's request; the worker completes after every store is checked. pgTAP `member_deletion_test.sql`: request effects, steps, completion. Widgets: mobile "Delete my account" (confirmation, password, sign-out) |
| Delete a member WITHOUT a login (staff route) | E2E `D20`: an Admin deletes an accountless member after an identity check; no account steps; the member who can use the app is refused (`member_can_use_app`), the Admin's own record is refused. pgTAP likewise, plus a login-held member. Widgets: staff "Member deletions" |
| Sign-in fails from the first step | E2E `D10`: right after the request both devices' tokens answer 401, their refresh tokens are refused, and a password sign-in fails at Auth (`user_banned`). `D11`, `D14`: it keeps failing while interrupted and after completion (then the Auth user is gone). pgTAP: sessions revoked, `banned_until`, link ended, grants ended |
| Interrupt the worker mid-way and resume it | E2E `D11` (stopped by `--max-steps` after the two first journal steps; nothing erased yet), `D12` (a crash between a journal append and its acknowledgement: the resumed worker acknowledges the existing entry and the journal does not grow; the Edge Function unreachable: the run stops, nothing changes), `D13` (the Auth user had already gone: the retried step is recorded `absent`, 1 attempt; then completion). pgTAP: interrupted twice, a closed retention gate waits, resumed to completion. Node: `tools/identity-deletion/worker.test.mjs` |
| Every step recorded and retried idempotently | E2E `D13` (each step's state/attempts/outcome), `D14` (a second run does nothing; the deletion is no longer queued). pgTAP: a wrong journal entry is refused and the failed attempt recorded, the same entry again is a no-op, the Auth step is done only when the Auth user is gone, a completed deletion does not advance |
| The journal holds only opaque identifiers | E2E `D30`: the eight entries of the two deletions validate with no field outside their kind, carry no number or name, and every database acknowledgement matches the journal's hash. pgTAP: the acknowledgement holds the opaque subject only |
| A synthetic restore replays the deletion before access opens | E2E `D40`: a backup taken BEFORE the member's deletion request, restored into a `--network none` container after the deletion completed, lands held (private access closed even if approved; the member present, linked, in a cell; a simulated restored Auth row present); reconciling from the sealed journal re-creates the workflow, denies access, erases the member's data and the Auth row, completes the deletion, and only then lifts the hold. pgTAP: replay while held. `npm run recovery:rehearse` (1.10) still passes with the replay hooks |
| Nothing left behind | E2E `D50`: no receipt, step or audit row mentions the deleted accounts or names; the function log holds no number, account id or credential |
| Q4 retention stays a labelled fixture; live personal data stays gated | pgTAP: the gate `identity_deletion_retention` carries only the labelled fixture, every retention rule is labelled `FIXTURE`, and with the fixture removed the destructive steps wait (`policy_gate_closed`). `q4_personal_data` is untouched |
| Fail closed without the row-deletion file | pgTAP: with the stub in place, requests and journal/Auth steps work, erasure answers `unavailable` and the step stays pending |

## Regressions (same stack, same day, each after a fresh reset)

`run` 30/30, `grants` 18/18, `apply` 27/27, `review` 18/18, `cells` 13/13, `recovery` 20/20, `credentials` 15/15, `assisted` 16/16, `lifecycle` 8/9.

`lifecycle` `L40` (the last two Admins deactivate each other in parallel) answers `ok` + `unauthenticated` instead of `ok` + `forbidden` in this environment. It fails the same way with this story's two migrations removed (checked), so it is pre-existing and timing-dependent: the second request's session check runs after the first transaction revoked its sessions. The safety property still holds (exactly one succeeds, one usable Admin remains). Recorded in deferred work.

## Not run here (staging)

Hosted steps (parent apply, the owner's hand-applied row-deletion file, the function deploy, the worker credential, the staging run) are listed in the runbook section "Hosted (parent session / owner)".
