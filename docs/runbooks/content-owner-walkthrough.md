# Epic 6 owner walkthrough: public content and giving

Prepared 30 October 2026. **This is a runnable acceptance procedure, not a record of a passed pilot.** Use it with [the acceptance reconciliation](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/acceptance-reconciliation-2026-10-30.md), [Content's operator reference](content.md), and [the promotion runbook](production-promotion-content.md). Stories 6.15 and 6.17 remain open until their actual evidence and owner decisions exist.

## 1. Prepare the candidate and record the environment

On Windows use Git Bash with Docker Desktop's Linux engine running; on macOS/Linux use Bash and Docker. Android needs an SDK/emulator or a USB-debuggable phone. iOS needs macOS, Xcode and a simulator or provisioned device. Use **Node 22, Flutter 3.47.6 / Dart 3.13.5, and the locked Supabase CLI 2.119.0**. Do not silently use another Flutter version.

Make a dedicated checkout. By default the stack uses project ID `church-app` and port 54321; a second checkout does **not** create an independent database. Never reset a shared stack. The 31 October continuation used a separate project `church-content-acceptance-20261031`, API 55421 / DB 55422, with all other configured ports changed to unused values. Its exact temporary config delta is in the [continuation evidence](../../_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-acceptance-continuation-2026-10-31/README.md). Restore that configuration intentionally before reproducing its local tests; it is not the tracked default.

The local test helpers now verify the current config, loopback API, Docker project labels, network, mapped ports and exact container ID. Missing or mismatched targets are refused rather than falling back to another running database. The examples below use default port 54321; substitute the deliberately configured port consistently, including emulator/USB forwarding. Keep the local mail service enabled for the full deletion test's email-change fixture.

```bash
git clone --branch acceptance/epic-6-reconcile-epic-7-plan https://github.com/raeltec-systems/church-app.git church-app-acceptance
cd church-app-acceptance
git status --short
git rev-parse HEAD
node --version
flutter --version
docker version
npm ci
npx supabase --version
mkdir -p /tmp/church-content-owner-evidence
```

Record the full SHA, date, OS, device/browser versions, app build, environment and tester in the result sheet below. The candidate must be reviewed again if its application/server code changes. Never put passwords, session tokens, provider credentials, device tokens or real contacts in committed evidence.

## 2. Run the automated baseline before building pilot fixtures

The aggregate runner **resets the local database**, and restores generated Linux Flutter files at its end. Use the clean dedicated checkout only. It continues after individual failures; its final `done` line or exit code is not an all-pass verdict.

```bash
npm run ci:policy-test
npm run env:check
npm run ci:migrations -- --base origin/main
npm run ci:secrets
npm run ci:function-imports
npm run contracts:test
node --test supabase/functions/content-assets/*.test.mjs
bash tools/ci/run-local-ci.sh /tmp/church-content-owner-evidence/local-ci.txt --base origin/main
cat /tmp/church-content-owner-evidence/local-ci.txt
```

Every `FAIL` or `UNRUN` needs a disposition. If the machine is memory-limited, run the Flutter suites sequentially with `flutter test --concurrency=2`; record that command. The aggregate script recognizes `chrome` on `PATH` or its listed Windows Chrome path; if Chrome is installed elsewhere, run the browser suite explicitly with its executable path:

```bash
read -r -p 'Absolute path to the installed Chrome executable: ' CHURCH_CHROME_EXECUTABLE
(cd packages/contracts/dart && CHROME_EXECUTABLE="$CHURCH_CHROME_EXECUTABLE" dart test -p chrome)
```

Keep the aggregate script's `UNRUN` entry and attach the separate result. Real non-Lusaka checks require an OS that honors `TZ`:

```bash
(cd packages/client_core && TZ=America/New_York flutter test --concurrency=2 test/duties)
(cd packages/client_core && TZ=America/New_York flutter test --concurrency=2 test/followups)
(cd apps/mobile && flutter test --concurrency=2 test/offline/public_content_ordering_test.dart test/offline/public_content_cache_adapter_test.dart)
```

### Real RSVP and retention integrations

Run these before creating the persistent UI pilot accounts. The runners own fictional identities and may remove their fixtures. They refuse a remote target and obtain local keys internally; do not supply staging credentials or relax their guards.

```bash
npx supabase start
npx supabase db reset --local
npx supabase test db
(
  set -e
  trap 'node tools/auth-harness/local-phone-auth.mjs off' EXIT INT TERM
  node tools/auth-harness/local-phone-auth.mjs on
  node tools/identity-e2e/content-event-rsvp.mjs --evidence /tmp/church-content-owner-evidence/rsvp.jsonl
)
node tools/identity-e2e/content-retention.mjs --evidence /tmp/church-content-owner-evidence/retention.jsonl
bash tools/auth-harness/scan-evidence.sh /tmp/church-content-owner-evidence
```

Expected: RSVP **13/13**, including one winner/four Full responses in the first five-client race and one winner/three Full responses in the second four-client race; retention **6/6**, including actual scheduler → worker → Storage removal and retained recent/referenced files. An interruption always requires `node tools/auth-harness/local-phone-auth.mjs off`. These are real integrations; the corresponding `*.test.mjs` files are offline unit tests and cannot replace them. The existing 28 October results remain historical evidence.

## 3. Start the actual clients

For an isolated local pilot, reset once after the automated suites, then keep that database for the whole walkthrough:

```bash
npx supabase db reset --local
docker exec -i "$(node tools/auth-harness/local-target.mjs db)" psql -U postgres -X -v ON_ERROR_STOP=1 <<'SQL'
do $$ begin
  if app.platform_current_environment() is not null
     and app.platform_current_environment() <> 'local' then
    raise exception 'Expected a disposable local database';
  end if;
end $$;
select app.platform_set_environment('local', 'israel');
SQL
node tools/auth-harness/local-phone-auth.mjs on
```

In a second terminal from the repo root, serve the local Edge Functions, leaving it running:

```bash
npx supabase functions serve --no-verify-jwt
```

Inspect `npx supabase status` privately and copy **only the publishable key** into a local untracked variable. Do not copy the secret/service-role key into a client. In Git Bash/macOS/Linux:

```bash
read -r -p 'Local publishable key: ' CHURCH_PUBLIC_KEY
(cd apps/staff && flutter run -d web-server --web-port 8081 \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$CHURCH_PUBLIC_KEY")
```

Open the printed staff URL in separate browser profiles for different roles. Run mobile in another terminal:

```bash
flutter devices
read -r -p 'Local publishable key: ' CHURCH_PUBLIC_KEY
read -r -p 'Device ID from flutter devices: ' CHURCH_DEVICE_ID
(cd apps/mobile && flutter run -d "$CHURCH_DEVICE_ID" \
  --dart-define=SUPABASE_URL=http://10.0.2.2:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$CHURCH_PUBLIC_KEY")
```

`10.0.2.2` is for an Android emulator. For Android over USB, run `adb reverse tcp:54321 tcp:54321` and use `http://127.0.0.1:54321`. For an iOS simulator on the same Mac use `http://127.0.0.1:54321`. For physical iOS, use an already approved HTTPS staging build or a deliberately configured development network; this repo does not provide a general-purpose HTTP bypass. Do not change release transport policy to make a device test pass. Preserve each platform's required build/signing setup.

For an **owner-authorized staging pilot**, use `https://tmurpotfluignacfueki.supabase.co` and its current publishable key instead, with an app built from the candidate SHA. Do not run any local reset, bootstrap or backdating SQL against staging. The physical push test also needs the existing approved Firebase/APNs configuration in [notifications.md](notifications.md); the two Supabase defines alone do not enable push.

## 4. Set up useful fictional church activity

Use the following coherent dataset in the **disposable local stack**, after the automated runners have finished. The `SYNTHETIC` account-name prefix is required by the existing safety gates, not a new app mode. Use `SAMPLE` for giving. Do not reuse these accounts concurrently with the giving harness, which owns the same reserved number block.

| Person / login | Initial role and purpose |
| --- | --- |
| SYNTHETIC Grace Banda / +447700900510 | Admin A; creates giving drafts and grants roles |
| SYNTHETIC Peter Lungu / +447700900511 | Admin B; independent verifier, after eligible tenure |
| SYNTHETIC Chileshe Banda / +447700900512 | Media; prepares teaching and events |
| SYNTHETIC Ruth Zulu / +447700900513 | Pastor only; content allowed, giving administration denied |
| SYNTHETIC Abel Sakala / +447700900514 | Member of Shikoswe; preaching assignee, favourites and RSVP |
| SYNTHETIC Lydia Banda / +447700900515 | Pending applicant; leave unapproved for denial checks |
| SYNTHETIC John Siane / +447700900516 | Shikoswe cell leader and SYNTHETIC Preaching Rota department leader |
| SYNTHETIC Mary Siamu / +447700900517 | Newly granted Admin C; tenure refusal |
| SYNTHETIC Esther Mwale / +447700900518 | Approved member in Estates; privacy and RSVP comparison |

Create each account through the app's phone/password signup, choosing private test passwords and leaving optional email blank. Bootstrap **only the first local Admin** after her Auth account exists; stop before submitting her membership application:

```bash
docker exec -i "$(node tools/auth-harness/local-target.mjs db)" psql -U postgres -X -v ON_ERROR_STOP=1 <<'SQL'
do $$ begin
  if app.platform_current_environment() is distinct from 'local' then
    raise exception 'Expected local';
  end if;
end $$;
select app.identity_seed_synthetic_link(
  (select id from auth.users where phone = '447700900510'),
  'SYNTHETIC Grace Banda', 'israel') as pilot_admin_id \gset
select app.identity_bootstrap_admin(:'pilot_admin_id', 'israel');
SQL
```

Sign Grace out and back in after the trust-epoch margin (more than five seconds). In the staff sidebar use **People → Members → Applications** to approve the other applicants, **People → Members → All members** to inspect their records, and **People → Roles & access** for grants. **Cells → Cells** manages the cells; **Cells → Cell meetings** manages their schedules. **Duties → Departments** manages the department. Keep Lydia Pending. Under **People → Members → All members → Add member record (no login)**, create an accountless member with only fictional agreed details. Verify church approval and cell confirmation remain separate. Assign John to the relevant cell/department and Abel to Shikoswe; Esther belongs to the comparison cell.

For the local positive giving-verification case only, age Peter's fictional Admin grant after Grace grants it. This is fixture preparation already used by the local giving runner, not an operational tenure override:

```bash
docker exec -i "$(node tools/auth-harness/local-target.mjs db)" psql -U postgres -X -v ON_ERROR_STOP=1 <<'SQL'
begin;
do $$ begin
  if app.platform_current_environment() is distinct from 'local' then
    raise exception 'Local fixture preparation only';
  end if;
end $$;
update app.identity_grants g
set granted_at = now() - interval '15 days'
from app.identity_members m
where m.member_id = g.member_id
  and m.display_name = 'SYNTHETIC Peter Lungu'
  and g.role = 'admin' and g.revoked_at is null;
commit;
SQL
```

Expect exactly one updated row. Keep Mary newly granted. On staging, use an already eligible independently controlled Admin account or record the positive case blocked until eligibility; do not backdate a real grant.

### Content fixture sheet

These are fictional examples, not approved church announcements or giving destinations. If testing after these dates, move the entire set forward together; preserve the durations and Africa/Lusaka times.

| Item | Values and relationship |
| --- | --- |
| Sunday service | 8 November 2026, 10:00–12:00, Church hall; topic **Faithful in small things**, Luke 16:10 |
| Sermon series | **Faithfulness in everyday life**; description: “Teaching on honest service, reliable commitments and care for one another.” |
| Sermon | **Faithful in small things**, speaker **SYNTHETIC Ruth Zulu**, 8 November, linked to that series, Luke 16:10; notes below |
| Youth fellowship | 7 November, 14:00–16:00, Fellowship room; two places for the RSVP exercise |
| Multi-day conference | 13 November 16:00 to 15 November 13:00; Church hall; both dates must survive calendar export |
| Announcement | **Prepare together for Sunday**; “Please arrive in time to prepare your ministry area. Read Luke 16 before the service.”; pinned; publish without a notice |
| Cell meeting | Shikoswe, 5 November 17:00–18:00, a fictional private venue; confirmed cell members only |
| Department duty | **SYNTHETIC Preaching Rota**, Abel assigned to the Sunday service; add topic/scripture using **Duties → Rota** and its existing date editor, link the published event. The department prefix is required while the local Q4 fixture is in use. |
| Sunday hymns | Hymn 12 **Pupulala Basinkombe (Cila)** and hymn 45 **Mbunono Ncobeni**, from the bundled Tonga edition; use the server's current Sunday for the immediate chip check, independently of the later service fixture; use actual book text, not the old English prototype labels |
| Giving | **SAMPLE Local pilot giving**, using the exact fictional fields below; never a real account or a live payment test |

Suggested original sermon notes:

> Faithfulness can be practised in ordinary responsibilities: arriving when promised, preparing carefully and speaking honestly. Discuss one responsibility that needs attention this week.
>
> Choose one practical act of service before the next meeting. Encourage one another without sharing private pastoral information in a public story.

Through **Content → Rights**, prepare the appropriate verifiable rights records, then draft content through the ordinary editors. Church-owned test artwork uses the approved image exemption. Bible text/video use still requires the applicable cleared source/use.

For **WEB in the disposable local stack**, the existing Q5 fixture already permits source key `web` for display and offline use. No policy-gate approval is needed for this local rehearsal. In **Content → Rights**, create a record with **What it covers** `World English Bible (WEB)`, **Source key** `web`, **Holder** `Public domain; eBible.org source`, **Basis** `Public domain`, and **Evidence** `World English Bible Protestant edition (engwebp), eBible.org; bundled source apps/staff/assets/bible/engwebp_vpl.txt. Local fixture rehearsal.` Tick **Display in the app** and **Offline download**, leave Audio unticked, **Save draft**, then **Verify**. In **Content → Bible**, select that **WEB source rights record**, choose **Install WEB package**, wait for the complete private draft, then **Publish**. A draft rights record may be attached during installation, but publication still needs verified display clearance. For the display-only negative case, remove offline clearance in a new rights revision and verify it; restore and verify offline clearance before the positive cold-start check. On an authorized staging pilot, inspect the current catalog and source clearance first and use the existing published WEB only if those checks succeed. Neither the local fixture nor a successful staging read approves production distribution. A refusal while the applicable source/use clearance is absent remains a valid negative case; do not open a policy gate to manufacture a positive result.

For **Giving**, use **Content → Giving → New method**, kind **Mobile money**, name `SAMPLE Local pilot giving`, purpose `Local walkthrough only`, currency `ZMW`, beneficiary `SAMPLE No payment destination`, Identifier **Merchant ID**, and value `SAMPLE-NOT-PAYABLE`. Leave **Starting code** blank. Add two steps: `Copy the fictional identifier for this local check.` and `Stop here; do not send money or dial a payment code.` Set **Contact for questions** to `SAMPLE local pilot support`. In verification, use today's Africa/Lusaka date and an honest **How it was tested** entry such as `Local UI rehearsal: copied the fictional identifier and checked the manual instructions; no provider or payment was tested.` Change the identifier to `SAMPLE-NOT-PAYABLE-2` for the changed-destination refusal/reverification case. This setup exercises draft, verification, publication, copy and manual recovery. It does not exercise a dialler: the separate physical handoff case still needs the owner-approved non-transacting code/SIM described in UI-15.

Use an owner-cleared public YouTube/Facebook link for actual playback, plus an unavailable link. Fictional IDs used by API tests cannot demonstrate playback. Keep those positive playback dependencies visibly blocked until supplied.

## 5. Walk the normal member and leader journeys

All rows below start **authored only**. Fill a result and evidence reference for each; the automated ledger does not fill them for you. Capture short recordings/screenshots of the ordinary navigation, useful outcome and recovery. Use redacted request/status evidence where needed; no tokens or private text.

| ID / role | Action through the app | Expected useful outcome and failure/recovery check | Evidence to return |
| --- | --- | --- | --- |
| UI-01 Guest | Home → search → find the sermon, event and announcement; Bible & Hymns → Hymn book → search `12`, its title and first line; open each result and go back. | Five tabs remain usable without sign-in; correct content opens; no staff/private links. A failed uncached request has an error/retry state, distinct from a valid empty list. | Navigation recording, search terms and offline/online state |
| UI-02 Guest | Bible & Hymns → Bible → choose translation, Luke 16; previous/next; **Save offline** when cleared. Force-close, airplane mode, relaunch. | Saved chapter remains readable with saved/offline indication; unsupported uncached chapters do not pretend to load. Reconnect and **Try online again** restores current content. | Cold-start recording and rights state |
| UI-03 Guest/member | Open hymn 12; inspect verses/chorus; restart offline and search again. As Abel, Save; as the same member on a second session, verify and remove; sign in as Esther. | Built-in hymn text/search works offline. Favourites are personal and server-backed; Esther cannot see Abel's list. Offline persistence of personal favourites is not a promised feature. | Two-session favourite evidence and offline hymn recording |
| UI-04 Worship leader/Media | Read the server's current Sunday (`select app.content_this_sunday();` on the disposable local stack, or the `sunday` field of the public read); on 30 October this is 1 November. Staff Content → Sunday hymns → select that date → set 12 and 45; guest reopens Hymn book and Home. Use Chileshe's Media account first; for the scoped-only case an Admin uses Content → Sunday hymns → Worship leaders to grant a member with no general editor role. | With the device in the same church-local week, hymn-book Sunday chips identify the current list. Home shows it only during its Saturday/Sunday window; outside that window, absence is expected and the positive Home case remains unverified. An 8 November list is future content until both server and device reach its week. Changing only device time cannot prove either positive case. | Server Sunday, device church-local date, role and both surfaces; distinguish expected current absence from the deferred positive case |
| UI-05 Media/guest | Draft sermon/series; read live sermon; save a replacement draft without publishing; publish replacement. | Draft remains private; existing live teaching stays until replacement. Invalid markup/link is refused with typed input retained. Stale editor conflicts do not overwrite another editor. | Before/draft/after views plus refusal/retry |
| UI-06 Guest | Play owner-cleared YouTube, then Facebook/public livestream; navigate away/back; test removed/private/unreachable video. | No autoplay or Facebook sign-in requirement; readable scripture/notes remain when media is unavailable. Navigation and player disposal behave on Android and iOS. Background audio is out of scope. | Device recording for each provider and unavailable case |
| UI-07 Media/guest | Publish a church-owned poster/banner, save public content, then withdraw it or its rights; guest refreshes and restarts. Throttle or fail image requests. | Public reads remove withdrawn items; successful refresh evicts saved rows/files without stale resurrection. Slow/failed/oversized images leave text usable. Already offline copies cannot be remotely erased. | Rights/public state, refresh and restart evidence |
| UI-08 Member/guest | Calendar → conference → **Add to calendar** → actual phone calendar. | Start 13 November and end 15 November survive; timezone and both endpoints are correct; copy caveat is visible. Returning to app works. | Calendar-app view showing both endpoints and timezone |
| UI-09 Abel/Esther | Both open a capacity-one variant of Youth fellowship, submit concurrently, refresh, winner cancels, loser retries. | Exactly one current attendee; other sees Full; cancel frees the place. Repeat/uncertain submission never double-books. Cross-check with the real G1 runner. | Two-client recording + counts/results |
| UI-10 Admin/organiser/member | Staff Content → Events → **Who's coming**; compare organiser, other Media, Admin and plain member. Deactivate a future attendee in the local fixture. | Only organiser/Admin gets names; other readers get counts only. Deactivation frees future RSVP. Record the known limitation: RSVP cancellation is unavailable while RSVP is disabled. | Allowed/denied results and released count |
| UI-11 Member/Pending/guest | Member Calendar → My duties / My cell → open items; switch to Esther, Lydia, then guest. | Only current user's duties and confirmed cell meetings appear; Pending/guest switches absent; no private overlay survives sign-out or enters public cache. Failed protected load differs from no items. | Role-switch and deep-link denial recording |
| UI-12 Leader/Media | Staff rota date → link Sunday event; Media sees linked count and changes event time/place or withdraws it. | Leaders get review flag; no duty republish or answer reset. On staging this can send notices: run only after explicit authorization for every affected test recipient. | Before/after duty revision and answer, intended notice counts |
| UI-13 Assignee/leader/Media | Abel Home → My duties → duty → **Send to Media**; repeat; Media → Sermons opens **From a duty**, completes and publishes. | One private snapshot draft; no automatic publication or private duty fields. Wrong/revoked sender refused. A later send returns the existing draft; Media edits it. | Sender route, draft privacy, editor route and explicit publish |
| UI-14 Admin A/B/C | A creates SAMPLE giving draft; A attempts Verify; C attempts Verify; eligible B verifies; A publishes. A changes destination and tries to publish before B verifies again. | A cannot self-verify; C fails 14-day tenure; changed destination cannot publish unverified. Old live instructions remain until verified replacement. Verify dialog shows tenure/grantor. | Distinct accounts, refusals, old/new public revision |
| UI-15 Guest | Give → method → copy each field; manual steps; supported external dialler; return to app. | Exact copy, verification date and beneficiary-check instruction; readable text despite slow logo. Android handoff or iOS/manual fallback; no payment-success state, amount capture or payer record. Use an owner-approved non-transacting code/SIM for the physical test; a SAMPLE code is not proof it is safe to execute. | Device/clipboard results, manual fallback, return state |
| UI-16 Admin/guest | Flag method unsafe; guest refreshes; hide it; guest refreshes, reconnects and restarts. | Warning appears, hidden method disappears after successful refresh; offline old copy is labelled honestly. No generic successful-payment message appears. | Online/offline sequence and final absence |
| UI-17 Media + consenting test devices | After specific sending approval, publish announcement with notice; compare notification allowed, OS denied, category off, held and accountless accounts. | Allowed device receives generic notice and authorized detail; opted-out member retains inbox only; held/accountless/guest gets no push job. Provider acceptance alone is not device receipt. | OS settings, inbox/job result, actual notification tap |
| UI-18 Every role | Guest, Pending, Member, Media, Pastor, Admin, Media+Admin; paste protected URLs; revoke a grant while its editor is open; interrupt/retry a save. | Server denies unauthorized reads/writes even with stale session/deep link. Draft/error behavior stays honest; successful recovery reflects persisted server state. Admin+Media receives only the union of those grants, never unrelated care/finance access. | Role matrix below, network refusal and recovery evidence |
| UI-19 Owner/source-book check | Compare hymns 25, 29 and 30 against the source/printed book; inspect stanza numbering and hymn 29 chorus placement. | Confirm the interpretation or record the exact correction needed; do not silently alter the bundled book. | Page references and decision, without redistributing unnecessary book pages |

### Permission matrix to complete

| Role | Public reading | Favourite / RSVP / own overlays | Content editors | Sunday hymns | Giving administration |
| --- | --- | --- | --- | --- | --- |
| Guest | Allowed | Refused/sign-in prompt | Refused | Read published only | Refused |
| Pending | Allowed | Refused until approved/current scope | Refused | Read published only | Refused |
| Approved member | Allowed | Own only; cell needs confirmation | Refused | Read published only | Refused |
| Media | Allowed | Own member operations | Allowed | Allowed | Refused |
| Pastor only | Allowed | Own member operations | Allowed | Refused unless separately authorized | Refused |
| Admin | Allowed | Own member operations | Allowed | Allowed | Allowed subject to verifier separation/tenure |
| Worship-leader scoped member | Allowed | Own member operations | No general editor role | Allowed | Refused |
| Media + Admin | Allowed | Own member operations | Allowed | Allowed | Same giving safeguards; no bypass |
| Revoked/held/stale private session | Public remains public | Current private predicate governs; cached authority is insufficient | Current grants govern | Current grant governs | Current Admin grant governs |

## 6. Real sermon-from-duty contention gate

The actual database/HTTP concurrency check now has a runnable local driver. It uses independent transactions, verifies actual advisory-lock waiters, and exercises reassignment, cancellation, revoked scope and duplicate sends. It changes no application function to manufacture the race. Run before persistent pilot fixtures; keep phone auth enabled only for the run:

```bash
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-sermon-duty-drafts.mjs --contention \
  --evidence /tmp/church-content-owner-evidence/sermon-lock.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

Expected: **13/13**, including four `DL11`-`DL14` real-contention checks and zero remaining fixture users/items. If interrupted, still turn the local phone switch off. This proves the backend race; it does not replace the normal-UI two-session walkthrough below or the owner's device sign-off.


The pgTAP stale-first-read wrapper is useful, but it does not demonstrate two live sessions waiting on a lock. This remains **unverified** until the following controlled local exercise is witnessed. It is not a proven product defect.

Prepare a distinct published fictional preaching duty with a topic or scripture for each case through the app. Keep its assignee and manager screens open before beginning. Use Abel as the assignee and John as the department leader; John must not also be that duty's assignee, deputy or an Admin for the manager-revocation case.

The route `/duties/assignments/<id>` contains an **assignment ID**, not an occurrence ID. Do not use it directly as the lock key. Open two local `psql` sessions with:

```bash
docker exec -it supabase_db_church-app psql -U postgres -X -v ON_ERROR_STOP=1
```

In session A, confirm the local environment and identify the occurrence. If the native device does not show its route, use this read-only fixture lookup to identify the correct assignment by its duty name and start time:

```sql
do $$ begin
  if app.platform_current_environment() is distinct from 'local' then
    raise exception 'Local contention rehearsal only';
  end if;
end $$;
select a.assignment_id, s.occurrence_id, o.duty_name, o.starts_at, a.response
from app.duties_assignments a
join app.duties_slots s on s.slot_id = a.slot_id
join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
join app.identity_members m on m.member_id = a.member_id
where m.display_name = 'SYNTHETIC Abel Sakala'
  and a.assignment_state = 'current'
  and a.response in ('pending', 'accepted')
  and s.cancelled_at is null and o.occurrence_state = 'published'
order by o.starts_at;
```

Replace the placeholder with that exact assignment ID. The lookup below must return exactly one row; `\gset` refuses any other count. Require zero existing drafts before the race, then take the same lock as `app.content_sermon_from_duty`:

```sql
\set assignment_id 'REPLACE-WITH-LOCAL-ASSIGNMENT-UUID'
\unset occurrence_id
select s.occurrence_id
from app.duties_assignments a
join app.duties_slots s on s.slot_id = a.slot_id
where a.assignment_id = :'assignment_id'::uuid
  and a.assignment_state = 'current' \gset
\echo occurrence_id=:occurrence_id
select count(*) as drafts_for_occurrence
from app.content_sermon_duty_drafts
where occurrence_id = :'occurrence_id'::uuid;
begin;
set local application_name = 'content-pilot-lock-holder';
select pg_backend_pid() as lock_holder_pid;
select pg_advisory_xact_lock(hashtextextended('content_sermon_duty_draft:' || :'occurrence_id', 0));
```

Record A's `lock_holder_pid` and occurrence ID. While A holds the lock, use the actual sender's app to **Send to Media**. Reassignment/cancellation use Abel's **Home → My duties → duty** route. Manager revocation uses John's staff **Duties → Rota → date → Send to Media** route. In session B, replace both placeholders with A's values and observe a real advisory-lock wait blocked by that exact holder:

```sql
\set lock_holder_pid 'REPLACE-WITH-A-PID'
\set occurrence_id 'REPLACE-WITH-A-OCCURRENCE-UUID'
select a.pid, a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) as blockers
from pg_stat_activity a
where a.wait_event_type = 'Lock' and a.wait_event = 'advisory'
  and :'lock_holder_pid'::integer = any(pg_blocking_pids(a.pid));
```

Before starting the **manager-revocation** case, use Grace's **Roles & access** screen to grant Peter an explicit **department deputy** scope for **SYNTHETIC Preaching Rota**. Confirm Peter is approved, has an active linked account and is not held. His Admin title alone does not make him a reachable department leader. This leaves an eligible leader/deputy after John's removal. An ordinary removal of the last reachable leader correctly returns `handover_required` and rolls back; it is a separate refusal case, not a successful revocation for this race. Keep John as leader until his waiting send has begun.

Before releasing A, use Grace's separate authorized staff session to commit the corresponding change, one case per fresh duty:

| Case | Waiting sender | Committed provider change | Recovery sender after refusal |
| --- | --- | --- | --- |
| Reassignment | Abel, current assignee | Reassign the same slot to Esther in the rota | Esther, now the assignee |
| Cancellation | Abel, current assignee | Cancel Abel's slot in the rota | John, still the authorized department leader |
| Manager revocation | John, department leader only for this occurrence; Peter is already a reachable deputy | Revoke John's department-leader scope through Roles & access; require a successful result and confirm the grant ended | Abel, still the current assignee |

Confirm the provider change succeeded and reload it in staff before releasing A. If revocation returns `handover_required`, record the refusal, safely release the diagnostic lock and correct the eligible-deputy setup before using a fresh duty; do not expect post-lock denial from a grant that remained active. If the provider action itself waits, record the blocking graph and stop the scenario; do not fabricate a commit or a pass. Prepare the provider dialog in advance and work within the actual request timeout. If the sending request times out before the committed change and lock release, that attempt has not demonstrated the post-lock authorization check; record it and repeat with controlled timing, without changing shared server timeouts.

Run `commit;` in A. Expected: the waiting old actor is refused (`not_found`, presented as **Only the person on this duty or its leaders can send it.**) and no Content draft was created. In B, check the count before the permitted recovery sender acts, and again after that sender succeeds:

```sql
select count(*) as drafts_for_occurrence
from app.content_sermon_duty_drafts
where occurrence_id = :'occurrence_id'::uuid;
```

The count must be zero after refusal and one after permitted recovery. Inspect the private draft as Media and confirm it was not published. Before the final case, restore John's department-leader scope through the Admin UI and sign him in again after the trust-epoch margin. On another fresh duty, hold the same occurrence lock, start Abel's and John's still-authorized sends, observe both waiters blocked by A, and release A. Both successful command responses must refer to the same single draft; the occurrence count must be one. Capture sanitized outcomes and IDs only, without request headers.

Capture the actual lock wait, committed provider change, command outcome and private-draft count. Do not capture authorization headers. Always `rollback;` any remaining diagnostic transaction. This procedure is authored; no two-session result was produced by writing it.

## 7. Return evidence and leave approval explicit

Copy this row for each UI/integration check:

```text
Case ID:
Candidate full SHA / application build:
Date and Africa/Lusaka time:
Environment and device/browser/OS:
Role(s), fictional fixture aliases:
Exact navigation or command:
Expected useful outcome:
Observed outcome and recovery:
Result: authored only | run-passed | run-failed | skipped | blocked
Evidence file(s), sanitized:
Missing tool/input or required decision:
```

For failures record reproducible steps, expected/actual result and whether the user can finish by an approved route. A missing button/backend workflow is **unfinished functionality**; a supported flow not exercised on a device is **unverified functionality**. Keep these lists separate. Report the known RSVP-disabled cancellation and snapshot/special-duty limitations explicitly rather than implying they are newly accepted.

Compare the touched/visited screens with the [binding design contract](../../_bmad-output/initiative-church-app/spec-church-app/design-contract.md), the supplied Home/Bible/hymn/Sermons/Give/Calendar references, and shared `packages/design_system`: correct emblem, Outfit/Figtree hierarchy, navy/blue palette, five tabs, readable status text, light/dark mobile, keyboard focus and accessible targets. No UI or token was changed by this reconciliation; running this walkthrough is still necessary to establish end-user fidelity.

At the end, restore the local phone harness with `node tools/auth-harness/local-phone-auth.mjs off`. Keep the isolated pilot database if more evidence is needed; reset only when ready to discard its fictional data. Do not use this walkthrough to deploy, approve Q3/Q5, send unapproved notifications or mark 6.15/6.17 done. The promotion runbook's approval and current-state checks still apply.
