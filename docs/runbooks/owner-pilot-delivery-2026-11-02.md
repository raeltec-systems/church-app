# Owner pilot delivery - 2 November 2026

Status: **Android and staff builds prepared; local staff server started; hosted sample data prepared but not seeded; device acceptance and production promotion pending.**

This records the owner's accepted scope, Galaxy A26 delivery request and hosted-Supabase clarification. It does not close Story 6.15 or Story 6.17. See [owner decisions](epic-6-owner-decisions-2026-11-02.md), [sample-data preparation](owner-pilot-data-2026-11-02.md), [walkthrough](content-owner-walkthrough.md), and [closeout](content-acceptance-closeout.md).

## Candidate and environment

Both clients were built from `2c7b167c0fc4d5bd0af7d6b903d468b3de47b004`, whose parent is the historical CI-passing head `6f5cfe78afb99f0e572a285ad7421215eb6e978b`. Later fixture tooling and this delivery note do not change the compiled client source. Do not relabel the earlier CI results as CI for this candidate.

Work was isolated at `C:\Users\Administrator\church-app\.ops-state\e6-apk-20261102` on `acceptance/epic-6-owner-apk-20261102`. The original checkout's existing work was preserved.

Both clients use the existing hosted staging project **bic-kafue-platform-test / tmurpotfluignacfueki**, at `https://tmurpotfluignacfueki.supabase.co`, with its public client key. The local staff server serves frontend files only. The phone connects directly to hosted Supabase over the internet.

No local database reset, staging migration repair, schema change, grant backdating, real notification, payment or production operation was performed for this delivery.

## Android artifact

| Field | Observed value |
| --- | --- |
| Filename for delivery | `bicc-kafue-staging-20261102-2c7b167.apk` |
| Source | `2c7b167c0fc4d5bd0af7d6b903d468b3de47b004` |
| Version / build | `0.1.0 / 2026110201` |
| Package / displayed name | `zm.bickafue.bic_kafue_mobile` / BICC Kafue |
| Flutter application target | `android-arm64`, intended for the Galaxy A26 pilot |
| Minimum / target Android SDK | 24 / 36 |
| Size | 27,635,271 bytes |
| SHA-256 | `abfc3c106b36b5c0324aa74ebeacb54257672cb143e21063a9accefb959d30f9` |
| Signature | APK v2 verifies; Android Debug certificate, for staging testing |
| Certificate SHA-256 | `9202608e6c1d8d0c14464e16d9c1e4824b7ec98f542c5a4ea60feff049128b8b` |
| Build result | Exit 0, 1 November 2026 at 22:40:34 UTC (2 November in Lusaka) |

The certificate matches the previously delivered 31 October staging APK and the version code is higher. This is not production signing.

The build used Flutter 3.47.6 / Dart 3.13.5, locked dependencies and the staging define file. The compiled ARM64 application contains the expected staging URL and public key. All **419** uncompressed APK entries (**29,326,202 bytes**) were scanned using the repository's bundle credential rules, with **zero skipped entries and zero findings**. Extraction used ordinal filenames so Windows filename case collisions could not omit entries.

Firebase's four required Android client settings were not available in the approved build configuration. **Push is not configured in this APK.** The owner's all-enabled launch choice still requires approved configuration, named test devices/recipients and witnessed notification results before launch.

## Local staff frontend

The release web build completed with exit 0 from the same candidate. On the Windows workspace, open:

**http://127.0.0.1:5186**

Observed after launch at 22:42:57 UTC:

- HTTP 200 for the index.
- `version.json` reports staff version `0.1.0`, build `2026110201`.
- Compiled JavaScript contains the expected staging URL and public key.
- `main.dart.js` SHA-256 is `99e407ea46bc332e6fd8ebe6694fae4c91530522dd2efb85d0f6c1c3c88c8bf4`.
- All **52** web files (**51,302,649 bytes**) passed the bundle credential rules, with **zero skipped files and zero findings**.

The server binds loopback only and serves `apps/staff/build/web`. An existing approved staff account must sign in through the normal flow. No editor account or session was manufactured. The connected browser was unavailable in this chat, so HTTP/build checks do not claim an interactive sign-in or staff acceptance pass.

If the server has stopped, run this from the isolated worktree; do not terminate an unrelated process if the port is occupied:

```powershell
python -m http.server 5186 --bind 127.0.0.1 --directory apps/staff/build/web
```

## New engineering changes and verification

| Change or check | Result and limit |
| --- | --- |
| Disabled-RSVP cancellation | Existing eligible members can cancel before the event starts even when new RSVPs are disabled. New joins remain disabled; protected membership/read authority and offline boundaries remain. |
| Focused RSVP / offline event-detail tests | 36/36 passed, including seven new regression cases; client_core analysis reported no issues. |
| Independent RSVP review | No blocking findings. This is code review, not a physical-device result. |
| Promotion inventory | Added the omitted `content-assets` function and derived the expected inventory from enabled functions in `supabase/config.toml`. Nothing was deployed. |
| Promotion regression | Demonstrated failure with the omitted function, then passed 1/1 on Node v22.23.4; zero skipped. |
| Hosted pilot tooling | Twelve fictional fixtures prepared; seven meaningful guard/recovery tests passed on Node v22.23.4, offline preview passed, independent review found no blocker. No hosted authentication or writes were performed. |
| Locked client builds | Mobile and staff both completed successfully; no dependency lockfile changes. |
| Candidate CI / acceptance | Must be associated with the actual resulting PR head separately. Build success is not CI success, witnessed acceptance or release approval. |

Non-fatal build warnings included existing Kotlin-plugin/SDK compatibility notices, a web Wasm dry-run warning and a Cupertino font-family warning. Both requested release targets completed successfully; no dependency upgrade was made to suppress them.

## Hosted content and access still needed

Anonymous staging reads returned one event, one banner and one Bible translation. Sermon series/sermons, announcements, giving methods and the current Sunday hymn list were empty at the observation. These are observations before sample seeding, not a claim that the prepared data is present.

The prepared package supplies four future events, two series, three original-notes sermons and three announcements, all clearly marked fictional. It preserves existing content, never sends an announcement notification, and does not invent payment destinations or media rights. Hymn suggestions do not overwrite the shared Sunday list.

The Supabase CLI reported that no access token was configured, and no connected Supabase tool was available. Applying the package requires an existing approved staging editor session through the normal authorization path. Credentials must stay in the private local configuration/session file, never chat, committed evidence or client bundles.

## Acceptance gates carried forward

The 101-entry staging migration-history repair remains verified closed. Carry forward the original commit/environment evidence for G1 RSVP 13/13, G2 retention 6/6 and actual sermon-lock contention 13/13. Those integrations were not repeated for this client correction.

Still required: authenticated fixture publication and normal staff/member journeys; the witnessed Samsung pilot and unresolved iOS acceptance; actual calendar, offline relaunch, YouTube/Facebook and giving handoff results; hymn 25/29/30 source review; specific Q3 destination and Q5 source/use approvals; push configuration and authorized recipient testing; proper production signing; current hosted parity and candidate review/CI; the 4.15 then 5.12 prerequisite chain; and explicit candidate-specific production promotion with verification.

The seven product dispositions are recorded in the owner decision note. All-enabled launch is the required end state; missing approvals/configuration remain launch blockers. No unrun scenario is marked passed.
