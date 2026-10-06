# Owner decisions for the milestone 1 build run

Recorded 2026-10-03 from Israel Muyoba's answers. These answers authorise the autonomous milestone 1 build to proceed without stopping at each ticket. Steps that genuinely need the owner still pause.

| Area | Decision | Applies to |
|------|----------|------------|
| **Auth tests** | Create a separate free Supabase project, `bic-kafue-auth-test`, for sign-in experiments. Test verification and reset emails go to `israelmuyoba+<tag>@gmail.com`. Only those test emails are read, through the owner's connected Gmail. Accounts and data are synthetic. | 1.2, 1.3 |
| **Staff web framework (Q10 trial)** | The trial result decides. If Flutter Web passes the default matrix, select it. Otherwise run the React/Next.js trial and select that. The owner reviews the evidence afterwards. The default matrix is the latest desktop Chrome, Edge and Firefox, desktop Safari where testable, and Chrome on Android. | 1.6, 1.7 |
| **Environments** | Stay on the free plan. `bic-kafue-platform-test` (`tmurpotfluignacfueki`) serves as staging. The production Supabase project is created later, when the org is upgraded or the auth-test project is paused. Staff web goes on a free static host whose account the owner creates when needed. The production-baseline deployment waits for the owner. | 1.8 |
| **Operations and backup** | Israel is the only restricted operator. The synthetic recovery journal and the backup/restore rehearsal use a private folder in the owner's Google Drive, through the connector, until a proper independent object store is chosen before real data. | 1.9, 1.10 |

Constraints that still hold:
- No real member data.
- No SMS configuration.
- Production stays gated, with private features and sending disabled.
- Unresolved Q1/Q2/Q4/Q12 policy values stay fail-closed. Fixture values are labelled.

## 2026-10-06 — phone sign-in (story 1.2)

- **Hosted phone provider:** enabled by the owner via Management API PATCH on `bic-kafue-auth-test` (no SMS provider/credentials). Production needs the same PATCH (the dashboard refuses).
- **Phone numbers are international:** any country code, normalized to international format; +260 is only the default picker value. No validation may assume Zambian operator prefixes. Tests use only reserved fictional ranges (e.g. `+1 202 555 0100–0199`).
- **F1 accepted as constraint:** passwordless `/otp` create_user can register any number with a server-side `password`-AMR session (no tokens returned). Identity access must require the staff-approved binding, not AMR alone; staff need number reclaim.

## 2026-10-06 — story 1.3 frozen-block amendment

- Approved: Supabase Auth Admin password update signs out all sessions; the recovery function relies on it and verifies it in the database (uncertain outcome if any pre-reset session survives).
