# Staff acceptance: first Admin and Users & access

Run against one recorded candidate and an approved test environment. This document is an executable owner walkthrough, **not a record that the owner has passed it**. Record source SHA, client build SHA, backend migration/function version, browser/device, role, expected result, actual result and PASS/FAIL/BLOCKED for every case. The automatic browser and backend evidence are separate from owner sign-off.

Before deployment approval, use the isolated local rehearsal in [verification](admin-onboarding-verification.md). Do not point a stale Vercel client at new APIs or assume a published APK contains this feature. Use fictional names and reserved numbers until live-data policy is approved. Never send setup invitations/passwords/tokens in evidence.

## First-Admin setup

The operator follows [restricted operations](admin-onboarding-operations.md) and delivers one invitation privately to its intended account holder. The holder uses their own device; no staff-selected password or manual member-table edit is part of this path.

| ID | Normal action | Required outcome/evidence |
| --- | --- | --- |
| A01 | From the staff landing page choose **Have an owner setup invitation?**. | First Admin setup is discoverable without a signed-in session. The page does not claim setup is open merely because it exists. |
| A02 | Enter the invitation and its intended normalized phone username; choose **Check invitation**. | The actual server returns the mode, expiry and reviewed notice. A wrong phone, wrong environment, expired/revoked invitation or closed installation is refused without granting access. Screenshot only the refusal, with the private field empty. |
| A03 | Enter a full name, choose/confirm a private password, read/acknowledge the notice, and complete setup. | Success appears only after confirmed account/member/link/Admin creation. Missing consent or mismatched confirmation is not submitted. No code/password is placed in the address bar or retained by a browser refresh. |
| A04 | For an explicitly bound existing account, enter its **current** password. | A wrong password is refused. The original account and password remain; no account is adopted just because the phone matches. |
| A05 | Interrupt a submission or its response, then use **Check setup status**. | The original request is reconciled. Pending/uncertain stays distinct from success. No automatic password resend, duplicate member or duplicate Admin grant. Use operator status/reconciliation if it cannot settle. |
| A06 | Choose **Go to sign in** and use the same phone/password normally. | Current Admin access opens the staff tools. Older sessions from before commissioning cannot read private data. If private access remains closed, the app correctly says activation is pending rather than bypassing it. |
| A07 | Attempt another first-Admin setup after commissioning or after the original Admin loses access. | First-time setup stays closed. Normal second-Admin grant or controlled last-Admin recovery is required. |

Public registration may remain disabled for A01–A06. Production data/policy activation is not part of this walkthrough.

## Everyday management

Use an authorised Admin, a second approved member with an app account, an ordinary Member-only account, and an agreed no-login member record. The following fictional labels are examples, not production seed data: **SYNTHETIC Naomi Phiri**, **SYNTHETIC Miriam Banda**, and **SYNTHETIC Grace Banda**.

| ID | Normal action | Required outcome/evidence |
| --- | --- | --- |
| U01 | Open **Users & access** from the staff navigation. Search by name/contact; combine membership, account and role filters. Page through a result set larger than 25. | Results are current, bounded and ordered. Membership and account labels are separate; a deactivated member is not silently excluded from All. A failed load is not an empty directory. |
| U02 | Choose **Add member record**, record the agreed name and consent basis, optionally a labelled contact, then submit. | A persistent approved member record can exist without a login. A relative/household number does not become anyone's username. Return to the management directory and select the new person. |
| U03 | In the selected person's panel choose **Edit name & contacts**, correct the name, add/change/remove labelled contact routes and choose the actual consent basis. | Save confirms only after the server. Reload the page and reopen the person: changes persist. No password, login-phone or recovery-email field is exposed as a normal contact edit. |
| U04 | Open the same person in two sessions and save different corrections. | The stale revision is refused. The second user sees that another session changed the record; reload/review before deliberately submitting a new edit. No silent overwrite. |
| U05 | Interrupt a save response and use **Check again**. | The original immutable request is sent again, not a new mutation. Only one change/audit entry results. Selection/navigation must not hide or misattribute the unresolved action. |
| U06 | Load administrative activity and request the next page. | It shows actual permitted actions, actor labels and timestamps. No historical contact values, passwords, invitation material, private care/finance content or raw provider diagnostics appear. |
| U07 | Grant/remove an available role on another eligible approved person; confirm the named consequence. | Current authority and the correct grant revision are checked by the backend. The other person's normal session observes its next-request permissions. Admin does not imply care/finance access. Self-grant, last-Admin removal and required handover remain refused. |
| U08 | Open **Account recovery**, **Access reviews**, **Recovery email** or **Member deletions** from one person. Return with **Back to person**. | The selected identity remains visible. Only that person's relevant queue entries/actions are shown; a missing/denied record does not fall back to a different person. A deliberate **Show everyone** returns to the general queue. |
| U09 | Place an appropriate access hold on another person, then review/release through the existing identity-checked procedure. | Their old session loses protected access. The normal reason/reset/second-Admin constraints still apply. An Admin cannot use a reset or self-action to bypass a hold. |
| U10 | Deactivate a member after required handovers, locate them through the Deactivated filter, then restore with the required identity check. | History remains. Sessions/roles end on deactivation; restoration does not silently restore old roles. Last-Admin and deletion-pending cases refuse truthfully. |
| U11 | Disconnect during a directory/activity refresh, then reconnect and retry. | A visible retryable failure remains distinct from empty data. Once restored, the current authorised data is read again. No fabricated success toast. |
| U12 | Revoke/hold the current Admin from another authorised session while a profile dialog is open. Trigger a normal protected refresh. | Protected record, dialog and pending private state disappear when the denial is observed. Do not claim an offline disconnected screen was remotely erased. |
| U13 | Open the management URL signed out, as an ordinary Member, and with a stale session. | The app presents the appropriate sign-in/denial state and does not fetch/render the directory as though navigation granted permission. |
| U14 | Use keyboard navigation, a narrow viewport and 200% text scaling. | Labels, confirmation consequences, filters and recovery actions remain usable. Status is not conveyed by colour alone. Match the approved navy sidebar/table/detail typography and spacing. |

A blocked role, missing fixture, unsupported phone capability or missing activation is **BLOCKED**, not a pass. Record a genuine missing workflow as **unfinished**, not merely unverified. The user-management module is staff web; unrelated Android media/dialler/push acceptance remains in the Epic 6 owner pilot.

## Results template

```text
Candidate / client / backend versions:
Environment (local/staging):
Browser or device + OS:
Case ID:
Acting role and target role (no password or phone):
Result: PASS / FAIL / BLOCKED
Expected useful outcome:
Observed outcome, including reload/persistence:
Redacted screenshot or short recording:
Recovery attempted and result:
```

Do not deploy, merge, open policy gates or mark acceptance complete merely because the automated test counts are green. Return the witnessed results against the exact candidate for owner review.
