You are taking over the remaining work of **epic 6 ("Public church content and giving instructions")** of the BICC Kafue church app: a Flutter mobile app and a Flutter staff web over Supabase/Postgres. The repository is `C:\Users\Administrator\church-app` (Windows). Work on branch `story/5.8-meetings-held`, which is at `a125e79` or later. Read this whole brief before you start.

## Where things stand

- **Planned:** the epic is planned in `_bmad-output/initiative-church-app/epic-public-content-and-giving/`:
  - `epic-public-content-and-giving.md`: the requirements K1-K17, and Notes recording every decision, assumption and open question. **Read the Notes: they hold the owner's decisions.**
  - `tickets.toml`: 19 entries in build order, each with description, verify, covers, after, hitl, risk, references and, for some, external_check.
- **Built, merged and on staging:** entries **1** (publication lifecycle, events, Home and Calendar tabs), **2** (rights registry, `q5_content_rights` gate, private and public storage buckets, `content-assets` Edge function, Home banners), **3** (Admin-verified giving methods, `q3_giving` gate, Give tab) and **13** (pinned announcements with an optional generic notice).
  - Read their plan files (`story-*-plan.md` in the epic folder) and their migrations (`supabase/migrations/2026102123*` and `2026102201*`) before you write anything. They define the shared patterns you must follow:
  - **Registries:** a new content kind, its commands and its deletion steps are added as rows in the Content registries. Never replace a shared function.
  - **Public reads:** functions only; no client role touches a Content table.
  - **Commands:** one command envelope, `api.content_command`.
  - **Deletion:** one Content deletion hook, which later entries add parts to.
- **Staff web:** fully redesigned. It has a grouped, foldable sidebar with a **Content** group (Events, Banners, Rights, Announcements, Giving), an Overview, and a shared white page header. New staff screens go into this structure.
- **Mobile:**
  - **Look:** redesigned to the design handoff.
  - **Tabs:** today Home, Give and Calendar. The owner decided on the design's five tabs, in this order: **Home, Bible & Hymns, Sermons, Give, Calendar**. Entries 6 and 9 add the two missing ones.
  - **Home:** lives in `home_screen.dart`.
  - **My duties and My cell:** open from their Home cards and the Account menu.

## Owner decisions you must follow (also in the epic Notes)
1. **Tabs:** the five design tabs above.
2. **Giving:** a destination added or changed by one Admin is verified by a different Admin before members see it. This is built in 6.3.
3. **RSVP:** the event's organisers and Admin see RSVP names; everyone else sees only the count and the spaces left (entry 11).
4. **Hymns for this Sunday:** set by Media plus members given a worship-leader scope (entry 8).
5. **Event editors:** Media, Pastor and Admin.
6. **Church-owned images need no Q5 rights approval;** only third-party material does. 6.2 built the stricter rule, so fix it (follow-up F2 below).
7. **No consent record** for photos showing people.
8. **Replaced or abandoned private uploads** (draft files no published revision uses) are deleted automatically after **30 days** (follow-up F3).
9. **New Admins and giving:** an Admin who became Admin less than **14 days** ago cannot verify a giving method, and the Verify dialog shows the verifier's "Admin since <date>, granted by <name>" (follow-up F1).
10. **Members never see internal process.** Empty states are plain: for example, Give says "No giving methods yet / When the church adds how to give, it will show here."

Still open; these block production only, so build with SYNTHETIC or public-domain content:
- Q3: the church's real giving details.
- Q5: which Bible translation and hymn book, and the rights to sermon media and offline use.
- Whether keeping display-only items in the app's cache counts as offline use. Until answered, such items show online only.

## What to build, in this order
1. **Follow-ups F1, F2, F3**, as small separate changes:
   - **F1:** the 14-day rule, enforced by the server in the giving verify command, and the staff Verify dialog text.
   - **F2:** church-owned images skip the Q5 check.
   - **F3:** 30-day deletion of unreferenced private uploads, using the platform's existing scheduled or system mechanism. Read how the notifications worker and system principal are run; do not invent a new scheduler.
2. **Entry 4:** the offline public cache. It is the one allowed exception in `boundaries_test`; read the entry.
3. **Entries 5, 6, 9, 11.**
4. **Entries 7, 12, 19.**
5. **Entry 8.** Right after it is on staging, the owner must hand-apply its `_rows` file on staging; see the epic Notes. Tell him at once.
6. **Entries 10, 14.**
7. **Entry 18.**
8. **Entry 16** (refactor sweep).
9. **Entries 15 and 17** are **hitl**: prepare everything they need (runbooks, pilot script, the promotion runbook and checks), then **stop and hand over to the owner**. Never promote to production.

Entry 11 also has an owner `_rows` file to hand-apply on staging. Respect each entry's `after` list. Build one entry at a time, unless two entries share no files and you can keep them fully separate.

## How to build each entry (the project's process)
- **Build skill:** follow `.agents/skills/bmad-build-auto/` (`workflow.md`, `step-01`..`step-04`, `plan-template.md`). Its SKILL.md runs a render script with `uv`, which is not installed here: run it with `python` (`python _bmad/scripts/render_skill.py --project-root <root> --skill <skill-root>`), or follow the step files directly.
- **Plan file:** write the story's plan beside the epic, in the same format as entries 1, 2, 3 and 13, and keep its status current with `tickets.py mark`, per `.agents/skills/bmad-ticket/references/tree-rules.md`. A finished entry is `built`. Only the owner marks `done`.
- **Branches:** create one branch per entry from `story/5.8-meetings-held` (`epic6/<entry>-<slug>`). When every check below passes and the plan is `built`, merge it back with `--no-ff`. Before merging, merge the latest `story/5.8-meetings-held` into your branch and resolve conflicts keeping both sides' additions. The shared files that conflict are `shell_routing.dart`, `church_client_core.dart`, `providers.dart`, `composition.dart`, `testing.dart`, both `app.dart` files, `command_foundation_test.sql`, `cross_epic_contracts_test.sql`, the content test files' registry and privilege lists, and the runbooks. Scope your own tests' registry and privilege assertions to your own kind, as 6.2, 6.3 and 6.13 do, so later kinds don't break them.
- **Commits:** commit as `git -c user.name="Israel Muyoba" -c user.email="israel.muyoba@raeltec.com" commit`. Use clear messages; never push.
- **Database:**
  - Migrations go under `supabase/migrations/`. They must be ASCII only, with no backslashes anywhere in the file.
  - A destructive statement needs a line `-- owner-approved-cleanup: <decision reference>`.
  - `node tools/ci/check-migrations.mjs --base origin/main` must pass.
  - Module ownership must hold: `select count(*) from app.contract_boundary_violations()` = 0 and `app.contract_unowned_objects()` = 0. Content may not read another module's tables; reach other modules through their registered functions or hooks.
  - pgTAP tests go in `supabase/tests/`. Run the **full** suite on a freshly reset local database: `npx supabase db reset --local`, then `npx supabase test db`. The local Supabase stack runs in Docker.
- **End-to-end:**
  - Write an HTTP E2E script in `tools/identity-e2e/`, in the style of `content-events.mjs`, `content-giving.mjs` and `content-announcements.mjs`, with its offline unit tests.
  - Use only fictional UK numbers `+44 7700 900xxx`. Before choosing a block, `grep` the repo to confirm it is unused. Runs free at last count: 111-121, 161-169, 172-180, 291-299, 571-579, 584-598, 604-612, 630-638, 641-649, 651-659, 690-698.
- **Clients:** `packages/client_core` (domain, application and presentation per module), `packages/design_system`, `apps/mobile` and `apps/staff`.
  - `flutter analyze` must be clean and `flutter test` must pass in all four.
  - Run `dart format` only on files you changed. Running it on a whole `lib` folder rewrites unrelated files.
  - Keep every existing widget key and behaviour; change tests only for copy or layout changes, and say which.
- **Design (mandatory for every screen):**
  - The design handoff `docs/design-handoff/README.md` is authoritative for brand, colours, fonts (Outfit, Figtree; JetBrains Mono only for times and figures) and each screen's content. Screens: 1 Home, 5 Bible & Hymns, 6 Sermons, 7 Give, 8 Calendar, the Admin web; its `design/` folder holds the prototype.
  - The taste rules in `.agents/skills/design-taste-frontend/references/app-screens.md` and `references/tells.md` are mandatory. Read them whole before building any screen:
    - colour on data, not chrome
    - one status mark per row
    - grouped rows split by lines, not a box per item
    - sentence case, no tracked uppercase labels, no monospace decoration
    - KPIs as type
    - tables as rules and alignment, with numbers right-aligned in tabular figures
    - honest empty, zero, error and offline states, where a failed read never looks like an empty list
  - Reuse the design system: ChurchCard, HeroCard, DateBadge, SectionHeader, CardLabel, DetailTable, MenuRow, BottomActionBar, RadioSegments, StatusLabel, ChurchLogo, the staff pieces in `staff.dart`, and `church_widgets.dart`.
  - Mobile pushed screens have a back bar. Members never see internal process.
- **Windows quirks:**
  - Don't write files through shell heredocs that contain quotes; write scripts to files and run them.
  - Building the Android APK needs `$env:JAVA_TOOL_OPTIONS='-Djdk.net.unixdomain.tmpdir=C:\gtmp'` set in PowerShell:
    - `flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_B7rxJq4-D4PBNohOgz3qmg_SfbQWRSY`
  - The staff web builds the same way:
    - `flutter build web --release --no-web-resources-cdn` with the same two defines.
- **Synthetic data only:** names start with `SYNTHETIC` (sample giving methods with `SAMPLE`), with public-domain or synthetic text and images. Never real member data.

## Staging (Supabase project `tmurpotfluignacfueki`); never production
- For each migration:
  - Apply it to staging **verbatim** with whatever access you have: a Supabase MCP connection to this project (`apply_migration`), or the Supabase CLI linked to it. **If you have no staging access, stop and ask the owner; do not guess.**
  - If staging records a different version than your file name, rename the local file to the hosted version, as earlier entries did.
  - Then verify on staging:
    - every function you added or changed hashes identically to the fresh local reset (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`)
    - the boundary and unowned checks are 0
    - the signed-out reads answer as your tests expect
- **Edge functions:** deploy any you add or change, as 6.2 did with `content-assets`.
- **Promotion runbook:** add every migration and owner step to `docs/runbooks/production-promotion-content.md`. Add the content operations to `docs/runbooks/content.md`, with an "Owner manual check" per entry.
- **Push notifications are live on staging:** about 30 test phones receive real pushes. Never publish anything with a notification on staging without the owner's go-ahead.
- **Never touch production**, and never approve a policy gate.

## Independent review
Entries with an `external_check` (8, 11, 12 and 17 remain, plus the follow-ups when they touch giving) need an independent review against the entry's verify and the epic requirements, done in a fresh pass or by a separate agent. Fix what it finds; record anything deferred in the plan with a reason.

## Report back after each entry
Keep it short:
- the branch and merge commit
- what was built (server, staff, mobile)
- decisions and why
- test counts: pgTAP files and tests, E2E, Flutter per package
- the staging version and verification
- the review result
- owner steps now due (for example a `_rows` file to hand-apply)
- new owner questions, each in one line

Ask the owner only for decisions that are truly his; otherwise decide, record the decision in the plan and the epic Notes, and continue to the next entry.
