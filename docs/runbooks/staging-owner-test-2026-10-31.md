# BIC Kafue — owner staging test

Candidate: 33e97b2c4443578a0a86a92c02014b5730048bbd
Prepared: 31 October 2026
Staff app: https://bic-kafue-staff-staging-israel-muyobas-projects.vercel.app
Backend: bic-kafue-platform-test (staging), not production.
Android app: bic-kafue-staging-33e97b2.apk, version 0.1.0, build 2026103101.
Package: zm.bickafue.bic_kafue_mobile. Minimum Android API 24 (Android 7.0).
The APK includes arm64-v8a, armeabi-v7a and x86_64. It is release-optimized but signed with the existing development/debug certificate, for owner testing only.

## Open and install

The staff site keeps Vercel's authentication protection. Sign into the Vercel account that owns the project, or use the temporary share link supplied privately in the conversation. Do not publish that share token. The church app's own phone/password and role checks still apply.

Download the APK to the Android phone and open it. Allow installation from the browser/file app only when Android asks, then turn that permission off after installation. This is not a Play Store release. Do not disable Play Protect. If Android refuses installation, send the exact message. Do not uninstall an existing church app or clear its storage merely to force installation; doing that can remove local/offline data. An older installation signed by a different development machine may reject this update.

No computer, local Supabase or port forwarding is required. Both clients use the same HTTPS staging backend. Start on Wi-Fi, then repeat selected reads on mobile data.

Use existing approved staging accounts for each role, with their existing phone/password. Do not post passwords in results. A newly registered account is not automatically an approved member or Admin. Where an account, role, published item or permission is missing, mark the scenario BLOCKED and say what is missing rather than inventing a pass or changing access controls.

Use authorised fictional/SYNTHETIC content and SAMPLE giving methods for writes. Do not alter real member data or delete your own account. Do not publish announcements with notifications, change event-linked schedules that send notices, or run bulk sends during this pass. Never initiate a real payment or confirm a USSD transaction.

## Phone tests to return

For each row record PASS, FAIL or BLOCKED, your phone model, Android version, role, what you did and what actually happened. Attach a short screen recording or screenshot where useful, with private information removed.

| ID | Steps | Expected result |
| --- | --- | --- |
| P01 — install and guest navigation | Launch without signing in. Visit Home, Bible & Hymns, Sermons, Give and Calendar. Search for an existing sermon, event and hymn 12; open and go back. | No crash, readable layout and working navigation. Public content is readable without login. An empty list differs from an error with Retry. |
| P02 — Bible cold restart offline | While online, open a cleared translation/chapter such as Luke 16 and tap Save offline. Close the app fully, switch to airplane mode, then relaunch and open the saved chapter. Reconnect and use Try online again. | Saved chapter stays readable and shows an honest offline/saved state. An uncached chapter does not pretend to load. Reconnection restores current content. |
| P03 — bundled hymns and source check | Search hymn 12 by number, title and first line, then restart offline and repeat. Compare hymn 25, 29 and 30 with the printed/source book, including hymn 29 chorus placement. | Hymn text/search remains available offline. Report exact stanza/chorus differences; do not silently change the book. Personal favourites are a separate server-backed feature. |
| P04 — video playback and return | Open existing authorised YouTube and public Facebook/livestream sermons. Press Play, use full screen where available, navigate away/back. Try an unavailable video fixture. | Playback begins only on request. App navigation survives returning. Scripture and notes remain readable if a video is unavailable. Background audio is not in scope. |
| P05 — member persistence and privacy | Sign into an approved test member. Save a favourite, close/reopen online and verify it. Compare a second approved test account. Sign out and inspect Calendar again. | The favourite persists for its owner, not the other account. Own duties/cell overlays stay scoped and disappear on sign-out. Durable offline favourites are not implemented. |
| P06 — native calendar export | Calendar → an authorised multi-day event → Add to calendar. Open/import in the phone calendar and return. | Actual event start, end and timezone match both endpoints in the church app. Import does not silently collapse a multi-day event. The copy/export caveat is visible. |
| P07 — RSVP across clients | With two approved test accounts and an authorised capacity-one event, submit near-simultaneously. Refresh both, have the successful account cancel, then let the other retry. | One winner, the other sees Full; cancellation frees the place; repeated taps do not double-book. Cancellation while RSVP is disabled is a known limitation. |
| P08 — Give, copy and external handoff | Open Give → an authorised test method. Check copy buttons, manual instructions, verification date and beneficiary check. Only use a specifically approved non-transacting code/SIM to test opening the dialler, then return without submitting. | Copied values match. Text stays usable if a logo is slow. Manual fallback is available. Returning never says a payment succeeded or asks for a payer record. If safe dialler setup is unavailable, mark that subcase BLOCKED. |
| P09 — staff change visible on phone | On the staff website, use a permitted Media/Admin account and authorised test item: save a replacement draft, then publish it; refresh the phone. Withdraw the test item and refresh/restart again. Keep all notification options off. | Existing live content remains until replacement is published. Published changes reach the phone. Withdrawal disappears after a successful refresh; already-offline copies cannot be remotely erased. |
| P10 — duty to Media | On an approved preaching assignee's phone: Home → My duties → eligible duty with topic/scripture → Send to Media. Repeat. On staff as Media, open Sermons → From a duty. | Exactly one private draft, no automatic publication. Media can complete it. Wrong or revoked roles are refused. The draft is a snapshot; the staff special-assignment screen has no equivalent Send to Media path. |
| P11 — recovery and accessibility | Try large system text, scrolling, keyboard open/close and device Back. Interrupt the network during a safe test read/save, restore it and Retry; close/reopen after a successful save. | No inaccessible essential controls, hidden error or false success. Recovery reflects the persisted state. Record any overflow, blank icon, crash, repeated save or lost input. |

## Giving administration on staff

Use separate eligible Admin accounts to exercise creation, independent verification and publication. The creator must not self-verify; a newly granted Admin fails the tenure requirement. Changing a destination must require verification again. Do not backdate grants or alter backend settings to pass a test. Record BLOCKED when the required existing test roles/tenure are unavailable. No real payment is part of acceptance.

## Not covered by this APK delivery

- Push notification receipt is BLOCKED: this build does not include the four Firebase Android client settings. No notification was sent. Authorised device-specific configuration and permission are required for a later push test.
- APKs are Android-only. iOS playback, dialler/manual fallback, sharing/calendar and cold-restart checks require a separate iOS build and Apple signing/distribution.
- Backend deletion/recovery and permission races already have separate engineering evidence. Do not delete an actual member account as an improvised phone test.
- Build/hosting success is not owner acceptance. Stories 6.15/6.17 remain open until the required observations and release decisions are recorded; production has not been promoted.

The full role matrix and 19-scenario acceptance procedure remain in docs/runbooks/content-owner-walkthrough.md at the candidate commit. Some steps there are explicitly LOCAL-only or require separate notification authorisation; do not run local bootstrap/reset/backdating commands against staging.

## Results template

Device / Android version:
App build: 0.1.0 (2026103101), source 33e97b2
Test ID and role (no password):
Result: PASS / FAIL / BLOCKED
Steps performed:
Expected result:
Actual result / exact error:
Screenshot or recording:

Retain failures as failures even when a later retry succeeds; report both. Do not mark a missing fixture or untested provider/device as passed.