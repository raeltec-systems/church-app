# Evidence 2.1: phone username sign-in reaching a live-access-checked read

Everything here is **LOCAL** (Supabase CLI 2.119.0, GoTrue v2.197.0, Postgres 17.11) and uses synthetic data only, observed on 2026-10-06. The hosted staging demonstration is an owner step (see [Still owner-gated](#still-owner-gated)).

- **Phone numbers:** the reserved fictional ranges only, `+1 202 555 0100–0199` (NANP) and `+44 7700 900000–900999` (Ofcom drama range).
- **SMS:** no SMS provider, credential, hook, test OTP or phone MFA was configured at any point.

## Files

| File | What it shows |
|---|---|
| [`local-pgtap.txt`](local-pgtap.txt) | `supabase/tests/identity_live_access_test.sql`: 71 assertions, all passing. |
| [`local-api-smoke.txt`](local-api-smoke.txt) | `supabase/tests/identity_api_smoke.sh` through PostgREST and Auth, with the CLI's default config (phone off). Sign-in uses the verified-email alias of a phone account. |
| [`local-e2e-log.jsonl`](local-e2e-log.jsonl) | `tools/identity-e2e/run.mjs`: phone sign-up and sign-in through native GoTrue with the local-only phone switch on. 15 checks pass. The log keeps status codes, error codes and AMR names only, never tokens or passwords. |
| [`local-client-adapter-check.txt`](local-client-adapter-check.txt) | The real Dart adapters the apps use (`SupabaseAccountAuthGateway`, `SupabaseMemberAccessRepository`) doing sign-up, then the operator link, then a new-client sign-in, read and sign-out. |

## Results against the plan's I/O matrix

| Matrix row | Evidence | Observed |
|---|---|---|
| Approved member read | pgTAP "approved member reads their own summary", "+44 member is granted"; E2E `E13`, `E14`; adapter check 2 | 200 with the caller's own summary. Activity is recorded only after the grant (`E23`; pgTAP "a granted read records member activity"). A sign-in from a second client needs no re-approval (`E14`). |
| Unlinked account | pgTAP "unlinked account (F1: password AMR alone) is denied"; smoke; E2E `E11`, `E19`; adapter check 1 | 403 `forbidden` / `not_linked`. A `password`-AMR session alone never grants access. |
| Signed out | pgTAP "signed-out client: no EXECUTE"; smoke; E2E `E20`; adapter "read after sign-out: signedOut" | 401, permission denied for anon. The client sends no request without a session. |
| Untrusted session | pgTAP: otp, recovery, empty, missing or malformed AMR; another account's session; deleted session; `not_after` passed; banned user; anon role claim; anonymous session; activity untouched | 401 `unauthenticated` / `untrusted_session`. After local sign-out, the still-unexpired JWT is refused and its refresh fails (smoke, `E22`), while another session of the same account keeps working (`E22`). |
| Binding drift, hold, dormant | pgTAP: changed Auth phone; unapproved, approved and removed email; open hold and its release; link in review; deactivated member; dormancy at 91 days and at the approval baseline; inside the window | 403 `review_required`. Dormancy is evaluated before refresh, and a denial never refreshes activity. |
| Gate closed | pgTAP: non-synthetic member with closed `private_access`, then owner approval; unmarked (production) database ignores fixture settings; staging honours the labelled fixture while the gate stays closed; a held restore (`restored_held`) removes the synthetic bypass in local and staging | 403 `unavailable` until approved. Production fails closed. |
| Direct table query | smoke; E2E `E21` | `app` schema returns 406 (not exposed). `identity_*` under `api` returns 404. pgTAP: no client role holds any table privilege, and RLS is on. |
| Sign-up and sign-in | E2E `E10`, `E15`–`E18`; Flutter tests `test/identity/*`, app tests | Normalized E.164 is sent. Wrong password and unknown phone get the same `invalid_credentials` (`E15`). A duplicate username is refused with 422 (`E16`). A passwordless sign-up is refused (`E17`). |

## F1 reproduced locally (`E18`)

- **What happened:** `/otp {phone, create_user: true}` returned 500 "Unable to get SMS provider" and no tokens. It still created an Auth user row (`f1_user_rows: 1`), which has no link.
- **Effect on access:** that account cannot reach member data, because the predicate needs the staff-approved link and binding.
- **Number reclaim:** staff need a way to reclaim a number registered this way. That is recorded for entries 2 and 5.

## No SMS

- **Config:** local Auth settings show `sms_provider: ""` (`E00`).
- **Phone `/otp`:** fails with "Unable to get SMS provider" (`E18`).
- **Logs:** the GoTrue log for the run has 0 SMS-send lines (`E98`).
- **Local phone switch:** `tools/auth-harness/local-phone-auth.mjs` refuses to run if any SMS provider, credential, hook, test OTP or phone-MFA env is present. Its unit tests cover each case.

## Cleanup

- Every run deletes its synthetic identity rows and Auth users (`E99`: 0 left; adapter check: 0 `auth.users`, 0 `identity_members`).
- The local database marker the tools set is removed again.
- The local phone switch was turned back `off`.

## Still owner-gated

These are not done, and are not claimed here. Exact steps are in `docs/runbooks/identity-access.md`, "Owner steps".

1. **Staging migrations.** Apply `20261006215306_recovery_journal (+ 20261006215400_recovery_journal_hold)` (pending since story 1.10) and then `20261006215842_identity_live_access` on `tmurpotfluignacfueki`. The order matters, so this migration was not applied ahead of 1.10.
2. **Staging phone provider.** Enable it through the Management API `PATCH …/projects/tmurpotfluignacfueki/config/auth`, with the same no-SMS body used on `bic-kafue-auth-test`. The dashboard refuses this change, and the agent has no Management API token.
3. **Native and staff-web demonstration on staging.** Build both clients against staging, then show the approved member's summary on a native target and on staff web. Also show the denials for an unlinked account, a signed-out client and a direct table query, and that no SMS was sent. This needs a device and the owner's hands.
