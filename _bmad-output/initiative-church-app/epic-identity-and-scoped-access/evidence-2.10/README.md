# Evidence: story 2.10, hold, deactivate and restore membership with handover obligations

Plan: `../story-hold-deactivate-and-restore-membership-with-handover-obligat-plan.md`. Runbook: `docs/runbooks/identity-access.md`, section "Login hold, church deactivation and reviewed restoration (story 2.10)".

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0), on 2026-10-07, with synthetic fictional numbers only. No hosted project was touched. No SMS provider, hook, test OTP or SMS MFA exists. The phone switch was on only for the E2E runs and is off again.

## Files

| File | What it shows |
|---|---|
| `lifecycle-e2e.jsonl` | `tools/identity-e2e/lifecycle.mjs`: 9/9 checks through real GoTrue (phone/password sign-in, refresh) and PostgREST. Statuses, codes, counts and booleans only. |

## The verify bullet, row by row

| Case | Evidence |
|---|---|
| Hold through staff web and the API; access denied at once on both clients | E2E `L10`: two sessions of the member (mobile and staff web) answer 401 right after the login hold and their refresh tokens are refused; a fresh sign-in reaches only `review_required`. pgTAP `membership_lifecycle_test.sql` (both sessions, sessions counted). Widgets: staff "Disable login (hold)" sends `identity.place_hold` `login_disabled`; mobile shows only the generic help screen |
| Membership, cell and fixture duty facts survive a hold | E2E `L10`: membership `approved`, the confirmed cell (made through `cells_command`) and the SYNTHETIC fixture duty are unchanged after the hold; pgTAP likewise, and no handover is recorded |
| Release | E2E `L11`: the member cannot release; another Admin releases after an identity check; a fresh sign-in is granted |
| Deactivate: access denied at once on both clients | E2E `L20`: both sessions 401, refresh refused; a fresh sign-in is `not_linked` and the member's own status says `deactivated` (no reason); pgTAP likewise. Widgets: staff "Deactivate membership" needs a reason; both clients show "Church membership not active" without a membership-request link |
| Deactivation records handover obligations | E2E `L20`: the registered SYNTHETIC handover hook's duty is listed as a pending handover in the Admin read; owner lifecycle hooks heard `scope_revoked`, `membership_deactivated`, `sessions_revoked` in the same transaction. pgTAP: a raising owner hook or a malformed handover answer rolls everything back |
| Deactivation invalidates a pending grant | E2E `L20`: a staff-assisted recovery grant issued through the Admin API is `cancelled` after the deactivation. pgTAP: `cancelled/stale`; a pending operation becomes `obsolete`; an uncertain one keeps its hold (2.9 rules) |
| Removing the last Admin is refused | E2E `L01`: the sole Admin's deactivation answers `forbidden {"member_id": "last_admin"}`. pgTAP: with the other Admin held, the same refusal, nothing changed. Widgets: its own notice |
| Concurrent removal of the last two Admins (review fix) | E2E `L40`: the two Admins deactivate each other in parallel requests; exactly one succeeds, the other is `forbidden`, one usable Admin remains |
| Atomicity and 2.9 after deactivation (review fixes) | pgTAP: after a raising owner hook or a malformed handover answer the state, sessions, grants, issued recovery grant, `link_state` and obligations are unchanged; a dispatched assisted reset completed after the deactivation is `uncertain`, keeps its hold and access stays denied |
| Last responsible staff member | E2E `L21`: a sole-responsible fixture duty refuses the deactivation (`handover_required`, nothing written); after the owner's handover it succeeds |
| Reviewed restoration | E2E `L30`: needs an identity check; a session opened during the deactivation stays dead; a fresh sign-in is granted; no role comes back; the handover stays pending. pgTAP likewise, and only the owning module resolves its obligation |

## Regressions (same stack, same day)

`run` 30/30, `grants` 18/18, `apply` 27/27, `review` 18/18, `cells` 13/13, `recovery` 20/20, `credentials` 15/15, `assisted` 16/16.

## Not run here (staging)

- The parent session applies `20261007151523` to staging; then the E2E matrix can be repeated against staging Auth with synthetic numbers, and the staff web and mobile demonstration run.
