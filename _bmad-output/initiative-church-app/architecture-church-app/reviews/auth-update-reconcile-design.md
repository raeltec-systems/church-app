# Authentication update — design reconciliation

Reviewed: 2026-10-03
Verdict: **PASS — no blocking or non-blocking reconciliation findings.**

## Inputs and scope

- Current `../../spec-church-app/design-contract.md`.
- Updated `../architecture-church-app.md`, particularly AD-3 and AD-20.
- Owner-approved change: phone number and password, optional verified email for recovery, no SMS, and identity-checked staff assistance when email is unavailable.
- Before-update design snapshot: `/workspace/work/auth-update/before/spec-church-app/design-contract.md`.

This review independently reconciles the design contract, which this reviewer did not author or update. It does not claim that authentication screens, Supabase settings or recovery mechanisms have been implemented or tested.

## Authentication consistency

| Requirement | Design evidence | Result |
| --- | --- | --- |
| Phone username and user-chosen password | Mobile obligations replace the old code sequence with phone/password inputs, password visibility, autofill/paste, validation and a returning Sign in action. Username ownership is explicitly unverified. | Pass |
| No SMS and explicit override of historical references | Signup has no Send code, SMS input or resend timer. State override 10 supersedes the historical code/PIN sequence on both surfaces. Screenshot `app-17-phone-signup` remains a styling reference with its OTP behaviour marked superseded. | Pass |
| Email remains optional on the same account | Email is attached after phone signup, becomes recovery-eligible only after verification and approved binding, and setup failure does not delete the phone account. | Pass |
| Safe password recovery | Forgot password asks for the previously verified email, returns neutral acknowledgement, never reveals the account email from a phone lookup, and includes pending/sent/expired-or-used/retry/support states. | Pass |
| No-email or inaccessible-email recovery | The recovery row requires identity-checked staff assistance and says staff cannot view passwords. Required staff work includes recovery/handover; the functional and architecture contracts govern the secure implementation. | Pass |
| Holds and password-session access | Password setup does not clear holds or grant private access; a fresh password sign-in is required after reset. This agrees with AD-3's live account gate and AD-20's recovery restrictions. | Pass |
| Credential changes and both clients | Phone/recovery-email changes use the approved credential-binding workflow; the binding override explicitly applies the approved flows on both surfaces. | Pass |
| Provider-native email behaviour | The design specifies the phone-first product UI without claiming that hidden email controls disable provider-native email/password routes. AD-3/AD-20 remain the authority for those routes. | Pass |
| Independent approval states | Request-sent and pending presentations retain separate church-approval and cell states. The update never treats phone/password signup or email verification as church/cell approval. | Pass |

## Preservation checks

Deterministic comparison against the before-update snapshot passed:

- All **32 screenshot links** remain identical and in the same order: **19 mobile and 13 staff**. Every linked file exists. Only the phone-signup caption changes to identify the approved behaviour override.
- **References and implementation boundaries**, **Tokens, type and geometry**, **Assets**, and **Staff screens and flows** are byte-for-byte unchanged.
- Every pre-existing non-authentication mobile table row is byte-for-byte unchanged. The signup row is replaced and a recovery/credential-change row is added.
- All ten pre-existing state-fidelity overrides remain exact after accounting for the new auth override and renumbering the privacy override from 10 to 11.
- The six approved additions, scoped permissions, safe recap publication, independent offering custody, visit consent, programme/duty revisions, reporting integrity, follow-up access, accessible alternatives and private-cache restrictions remain intact.
- The only scope-policy wording change replaces obsolete SMS controls/security-acceptance work with password/recovery controls and email delivery setup.

No new design conflict with the architecture or owner-approved authentication decision was found. The old HTML and screenshots are correctly retained as visual evidence while their superseded authentication interactions are explicitly overridden.
