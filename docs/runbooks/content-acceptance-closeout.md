# Owner closeout: Epic 6 stories 6.15 and 6.17

Status: **acceptance pending; no production promotion performed**. Use the [31 October engineering evidence](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-acceptance-continuation-2026-10-31/README.md), not the historical 30 October open-history-drift observation. The 101-entry staging migration-history repair is already verified; do not replay it.

The [2 November owner decisions](epic-6-owner-decisions-2026-11-02.md) accept the recommended product scope, require the RSVP cancellation correction, identify a Samsung Galaxy A26 for testing, and require all accepted Epic 6 capabilities to be enabled at launch. The local staff frontend and coherent fictional/SAMPLE pilot data on the existing hosted staging backend are authorised. These decisions do not record a passed pilot or approve particular production destinations, rights, sends or promotion.

## 1. Run one witnessed staging walkthrough

Use a candidate built from the recorded engineering commit (see evidence), staging project **bic-kafue-platform-test / tmurpotfluignacfueki**, the project's current publishable client key, and authorised synthetic/SAMPLE fixtures. No local bootstrap, backdating or reset SQL belongs on staging. Never put a service-role key in either client.

[The owner walkthrough](content-owner-walkthrough.md) provides exact client-start commands, fictional role setup, all 19 scenarios, expected outcomes and a result sheet. Its section 3 explains staging URL/defines and the Android/iOS build constraints. Use existing staging roles or explicitly authorised fixture provisioning; do not lower access controls to complete a case.

| Check to witness | Required useful result |
| --- | --- |
| Guest navigation and teaching | From the normal Home, Bible & Hymns, Sermons and Calendar routes, find/read meaningful content; unavailable video does not hide the teaching notes. |
| Member and staff workflows | Sign in as the documented roles; favourites persist across sessions, Sunday hymns are correct, RSVP/cancel and multi-day calendar export work, private attendee names and overlays stay scoped. Staff can draft, validate, publish, replace and withdraw without replacing the live version prematurely. |
| Failure and recovery | Interrupted/repeated submissions, stale permissions, offline restart and reconnect, slow/failed images and refresh errors show truthful states and usable recovery. A withdrawn item/unsafe giving method disappears after refresh. |
| Giving on actual phones | Independent eligible Admin verification, changed destination re-verification, copy/manual fallback, supported dialler handoff and return; no payment-success claim. Do not make a payment as part of the test. |
| Actual media/device behavior | Android and iOS YouTube/Facebook playback, offline saved chapter/hymn after relaunch; check hymn 25/29/30 stanza numbering against the printed/source book. |
| Required announcement-push acceptance (specific sends need permission) | Only after explicit permission naming the intended test recipient/device, with existing approved Firebase/APNs configuration. Record both permission refusal and authorised delivery. No broad test send. |

Save the candidate SHA, deployed build/environment, tester, device/OS, role, action, expected and actual result, and redacted screenshot/recording. Mark every scenario **pass / fail / blocked**, not just ?looks good?. Return the completed section 7 result sheet from the walkthrough. Record native tests as native, browser tests as browser.

## 2. Apply the recorded product dispositions

The owner accepted the recommended dispositions on 2 November 2026. The accepted limits below remain visible product scope; they are not claims of additional functionality or passed device tests. Verify the required cancellation correction on the identified candidate.

| Behavior / required correction | Owner disposition and evidence still needed |
| --- | --- |
| Organiser roster access requires an editor role (Media/Pastor/Admin) | Accepted for this release where the intended organisers already need those roles. Confirm the actual pilot roles fit; do not grant broad editor rights merely to bypass the restriction. |
| Existing RSVPs must remain cancellable when new RSVP is disabled | Correction required before acceptance: expose the existing backend cancellation capability for eligible members before event start. Record focused regression and normal-client evidence on the resulting candidate. |
| A duty/event link is added from an existing date editor, not the new-series form | Accepted two-step workflow: create dates, then edit a date to attach the event. Demonstrate that route. |
| Staff special-assignment screens lack Send to Media; the assignee can use mobile | Accepted mobile assignee handoff for this release. Witness the eligible mobile route and Media's review. |
| A sent sermon draft remains a snapshot | Accepted: Media manually reviews and edits after duty-topic/scripture changes; no automatic replacement is promised. |
| Favourites do not have durable offline persistence; bundled hymn text does | Accepted: favourites reload from the server across online sessions, while bundled hymn text remains available offline. Keep this distinction in product instructions. |
| A failed staff refresh replaces the list with an error and Retry | Accepted initially, subject to witnessed usability. Record recovery; reopen the issue if an essential workflow cannot be completed. |

The previously owner-accepted public-upload residual remains: process death or persistent take-back failure may leave a public object until another authorised sync. Do not claim guaranteed immediate removal or an autonomous sweep.

## 3. Close 6.17 only after release prerequisites

The local backend checks now include actual RSVP races, scheduled Storage cleanup and actual sermon-lock contention. They do not prove current deployed schema/function byte equality or native UI acceptance.

Confirm proper production Android signing, the candidate's full CI, independent review/reruns, current staging schema/Function/client parity and the recorded **4.15 → 5.12** production prerequisite chain. The owner's 2 November launch choice requires all accepted Epic 6 capabilities ready, including giving, applicable content uses and push. Obtain the specific Q3 destination verification, Q5 source/use approvals and required configuration before launch; unresolved cases stay safely blocked and are launch blockers, not an accepted disabled-launch alternative. Once the staging results and dispositions pass, record the explicit candidate-specific production-promotion decision and follow [the production promotion runbook](production-promotion-content.md). Record deployed production workflows and refused unapproved publication before closing 6.17.

Completion remains evidence-based: 6.15 requires the owner's staged device pilot; 6.17 also requires witnessed integrated acceptance and controlled, verified production promotion. This checklist does not approve a deployment or change a ticket to done.
