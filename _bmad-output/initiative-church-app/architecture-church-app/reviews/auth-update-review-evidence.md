# Architecture review — authentication technology evidence

**Verdict: PASS — no blocking technology-evidence findings.** The changed AD-3/AD-20 contract is supported by the current official Supabase documentation and upstream Auth behavior recorded on 2026-10-03. No implemented or deployed behavior is claimed.

Reviewed the saved spine, its Auth/email structural diagram, Q1 deferred gate, and `technology-auth-update.md`. Unchanged stack/starter decisions were cross-checked against dated `technology-flutter.md` and `technology-backend.md`; no full version re-search was needed.

## Findings

| Area | Assessment and evidence |
| --- | --- |
| Native phone/password without SMS | Supported by the official password-auth guide and inspected signup source. AD-20 correctly disables phone confirmation, excludes SMS providers/hooks/test OTP/SMS MFA and treats the phone as an unverified username. It does not incorrectly disable the entire Phone provider. |
| Native OTP reachability | Correctly bounded. Phone confirmation off is not an OTP endpoint disable switch. AD-20 acknowledges native routes remain reachable; AD-3 requires password authentication in trusted signed AMR plus live current authorization. This permits the native password method while denying OTP-only/recovery-only private sessions. |
| Recovery AMR | Supported and sufficiently precise. The documented claims include `password`, `otp` and `recovery`; current implicit verification can issue `otp` even for recovery. The spine uses a positive password requirement rather than relying solely on a `recovery` blacklist. Missing AMR and non-password sessions cannot inherit private access through `role = authenticated`. |
| Same-account optional email | Supported by authenticated `updateUser` and email-change verification. Native signup accepts one phone or email identifier, so adding email afterward on the existing account is the correct sequence. Approved binding remains separate from an arbitrary profile email. The architecture accurately admits the same confirmed email/password as a native alias while keeping the UI phone-first. |
| Reset delivery and session behavior | Official reset-email flow and redirect allowlisting support the chosen mechanism. Current native password update deletes other sessions while preserving its current session; Admin password reset deletes all sessions. AD-20 explicitly requires deployed-version verification and live-session enforcement. Recovery's surviving session still fails the password-AMR private-access gate, so setting a password does not itself grant private access. |
| No-email assisted recovery | Auth Admin supports password update; the application proof/one-use setup-grant workflow is correctly marked `[ASSUMPTION]`. It is not presented as a built-in Supabase recovery product. Account binding, expiry, replay failure, server-only privileged execution and no password/token logging bound the design. Auth remains the sole password store. |
| Diagram and operational gates | Auth → verified recovery email/production SMTP matches the available provider mechanism. Q1 retires SMS provider and SMS-only fallback gates while retaining required email delivery, recovery ownership and abuse/password policy work. Email configuration gates optional email recovery, not phone/password login without email. |
| Unchanged stack and official starter | Flutter 3.47.6, Dart 3.13.5, Riverpod 3.4.3, go_router 18.0.2, supabase_flutter 2.18.0, firebase_core 4.15.0 and firebase_messaging 16.7.0 match the same-date official release/pub.dev evidence. PostgreSQL 17.11 matches the dated managed-platform announcement. `flutter create` is covered by official CLI/quickstart evidence. The spine correctly leaves dependency resolution, actual managed build and deployment floors for foundation verification. |

## Implementation verification retained by the contract

- Run direct `/otp`, `/verify`, native password update and Admin reset cases against the selected hosted Auth version. Verify both AMR and actual `auth.sessions` removal; old signed JWT expiry alone is insufficient. Include Data API, file, command and subscription boundaries, not only client navigation.
- Exercise initial email addition, replacement/confirmation, neutral reset requests, allowed redirects, expired/replayed links and no-email assistance. Ordinary credential changes use recent password authentication; the separately restricted recovery/reset route is the explicit exception for forgotten passwords. Do not introduce nonce reauthentication that silently needs SMS for a phone-only member.

These are already foundation/activation obligations under AD-18/AD-20 and Q1, not blockers to finalizing the architecture document. The existing evidence clearly distinguishes documented capability and inspected upstream behavior from an unperformed deployed-project test.

## Principal official references

- https://supabase.com/docs/guides/auth/passwords
- https://supabase.com/docs/reference/dart/auth-updateuser
- https://supabase.com/docs/reference/dart/auth-admin-updateuserbyid
- https://supabase.com/docs/guides/auth/jwt-fields
- https://supabase.com/docs/guides/auth/auth-mfa
- https://supabase.com/docs/guides/auth/sessions
- https://supabase.com/docs/guides/auth/auth-smtp
- https://github.com/supabase/auth/tree/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/models/user.go
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/models/sessions.go

Full configuration, changelog, package-source references and verification limits remain in the three technology evidence files. No spine or canonical memlog was edited in this review.

## Targeted assisted-recovery recheck — 2026-10-03

**Verdict: PASS — no additional technology-evidence blockers.** Rechecked the final AD-20 grant-generation refinement and the matching “Changed credentials and secure recovery” requirements. The application-owned recovery workflow remains explicitly `[ASSUMPTION]`; native credential-change detection and generation enforcement must be proved against the deployed provider before assisted resets are enabled. No particular unverified provider hook or implemented mechanism is claimed.

The contract separates atomic application-side grant consumption from external Auth work: one pending operation per account, revision/generation checks, unresolved-operation restrictions and reconciliation handle delayed or uncertain results. It explicitly rejects claiming atomicity between an Auth API call and the application transaction. These are required implementation properties, not a claim that Supabase provides distributed transactions or conditional Admin password updates.

Auth remains the sole password store and verifier. Storing a digest of the one-use recovery grant does not introduce an application password store; member-chosen passwords are applied only through the server-side Auth Admin API, without staff disclosure or password/usable-grant logging. The existing provider-source evidence and unperformed deployed-project test limitations remain unchanged. Only this review report was edited.
