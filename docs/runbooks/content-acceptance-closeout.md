# Owner closeout: Epic 6 stories 6.15 and 6.17

Status: **acceptance pending; no production promotion performed**. Use the [31 October engineering evidence](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-acceptance-continuation-2026-10-31/README.md), not the historical 30 October open-history-drift observation. The 101-entry staging migration-history repair is already verified; do not replay it.

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
| Optional announcement push | Only after explicit permission naming the intended test recipient/device, with existing approved Firebase/APNs configuration. Record both permission refusal and authorised delivery. No broad test send. |

Save the candidate SHA, deployed build/environment, tester, device/OS, role, action, expected and actual result, and redacted screenshot/recording. Mark every scenario **pass / fail / blocked**, not just ?looks good?. Return the completed section 7 result sheet from the walkthrough. Record native tests as native, browser tests as browser.

## 2. Dispose of known product limitations

The following are real current behaviors, not items that another test run will implement. The owner has not silently accepted them:

| Current behavior | Decision/evidence needed |
| --- | --- |
| Organiser roster access requires an editor role (Media/Pastor/Admin) | Confirm that scope meets ministry operations, or specify/build the missing non-editor organiser permission. |
| Members cannot cancel while event RSVP is disabled | Decide whether that operational policy is acceptable or cancellation must remain available. |
| A duty/event link is added from an existing date editor, not the new-series form | Demonstrate and accept the two-step workflow, or request the additional creation path. |
| Staff special-assignment screens lack Send to Media; the assignee can use mobile | Confirm the mobile handoff meets the need, or define/build a properly authorised staff path. |
| A sent sermon draft remains a snapshot | Accept Media's manual review/editing after topic changes, or define a revision-aware replacement behavior. |
| Favourites do not have durable offline persistence; bundled hymn text does | Confirm the published product promise makes this distinction. |
| A failed staff refresh replaces the list with an error and Retry | Record the usability outcome, or require preservation of the last-good list. |

The previously owner-accepted public-upload residual remains: process death or persistent take-back failure may leave a public object until another authorised sync. Do not claim guaranteed immediate removal or an autonomous sweep.

## 3. Close 6.17 only after release prerequisites

The local backend checks now include actual RSVP races, scheduled Storage cleanup and actual sermon-lock contention. They do not prove current deployed schema/function byte equality or native UI acceptance.

Confirm proper production Android signing (the current Gradle release block uses debug signing), the candidate's full CI, independent review/reruns, current staging schema/Function/client parity and the recorded **4.15 ? 5.12** production prerequisite chain. Keep Q3 destinations and Q5 source/use rights either explicitly approved by the owner or visibly fail-closed. Once the staging results and product dispositions pass, record the explicit production-promotion decision and follow [the production promotion runbook](production-promotion-content.md). Record deployed production workflows and refused unapproved publication before closing 6.17.

Completion remains evidence-based: 6.15 requires the owner's staged device pilot; 6.17 also requires witnessed integrated acceptance and controlled, verified production promotion. This checklist does not approve a deployment or change a ticket to done.
