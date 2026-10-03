---
title: "Product Brief: BIC Kafue Church App"
status: draft
created: 2026-10-02
updated: 2026-10-03
---

# Product Brief: BIC Kafue Church App

**Owner:** Israel Muyoba (approved, with the pastor's blessing) · **Audience:** the engineer building v1 · **Sources:** `inputs/church-app-v1-spec-1.2.md` with the Oct 2 changelog, and the design handoff in `docs/design-handoff/`

## Executive Summary

Brethren in Christ Church Kafue has fewer than 200 members. Today it runs its Sunday duties by phone calls, WhatsApp messages and people chasing each other in the church foyer. Members aren't always sure what they've been asked to do. Leaders can't see who has said yes. Gaps surface on the day, when it's too late to fill them.

The Church App is a Flutter mobile app for iOS and Android plus a staff web portal, built on Supabase. It turns each duty into an explicit request: the member is reminded on time, gives a clear Accept or Can't make it, and the leader sees every unfilled, declined or unanswered slot early enough to act. Around that core, it gives the congregation sermons, events, the Bible and hymn book, giving instructions, cell life, prayer and pastoral care in one place.

One volunteer owner reviews and maintains it, with coding agents doing most of the implementation, so every module reuses the same building blocks: assignments, responses, follow-ups, reminders and scoped permissions.

## The Problem

- **Duties are invisible until they fail.** Assignments are spread across calls and chats. Nobody holds one list showing who confirmed, who declined and who never replied.
- **Leaders carry the follow-up in their heads.** Chasing people happens one by one, often on Sunday morning itself.
- **Members are unsure what's expected.** Without a clear "you're on Main door, Sun 4 Oct, report 08:30", even willing people get missed or turn up unsure.
- **Off-the-shelf tools don't fit.** Planning Center, Breeze, Tithe.ly and similar tools charge in dollars or pounds and assume email logins and card giving. Members here use phones and mobile money. See `addendum.md`.

## The Solution

The heart of the app is a duty loop: **publish → remind → respond → see gaps → follow up → confirm**.

- **Members** get a *My duties* card on Home showing the next assignment, with Accept or Can't make it. They get on-time reminders sent from the server even when the app is closed, and a *My follow-ups* list for any task they own.
- **Leaders** get a *Needs attention* view and a coverage queue (unfilled, overdue, declined, needs contact). From there they can call, reassign, or record a confirmation made in person or by phone. A leader-recorded confirmation is labelled as such and is never shown as the member's own acceptance.
- **Cell groups** use the same machinery for meeting programmes (who leads each part). Recaps are published separately and are safe for members to see; private reports stay with leaders and pastors.
- **Pastoral visits** are requested or proposed, and a visit only counts as agreed when the member actually consents.
- **Staff work** happens in a role-scoped web portal: rotas, membership, cell reports, service attendance counts, the cell offering register and the care board. Essential leader actions also stay in the mobile app. Both surfaces share one backend, so the same records and the same rules apply on mobile and web.
- **Public content** needs no account: sermons, events, the Bible and hymn book, and an instruction-only *How to give* list.

The design handoff fixes the look: navy #14246B with water blue #0A7FE0, Outfit and Figtree fonts, light and dark modes, and 32 reference screens.

## What Makes This Different

What sets it apart is fit, not technology. Sign-up and login are by phone (+260, a code by text message), with email optional. Members without a phone can still be given duties through leader-managed records. Giving instructions cover mobile money with dialler shortcuts. The rota follows the church's own departments and cells. Members, prayer and care data stay with the church, and there is no platform subscription, though hosting, SMS and app store accounts still cost money.

What it really competes with is WhatsApp, not other apps. It wins only if responding in the app is quicker than replying in a chat, and if leaders trust the coverage view more than their own memory.

## Who This Serves

- **Members** (most users, mainly phone users): know what they're serving, when and where; respond in one tap; follow their cell and church life.
- **Department and cell leaders:** see gaps early, follow up without chasing, plan cell meetings.
- **Pastor:** a church-wide picture (duty coverage, attendance trends, cell reports, care cases) without exposing what has to stay private.
- **Admin, treasurer and service recorders:** a narrow, audited set of permissions for each. Holding the Admin role does not by itself grant access to care or finance content.
- **Guests:** public content and giving instructions without signing in.

## Success Criteria

The owner's definition of success:

1. Leaders no longer chase members for tasks.
2. Members know exactly what they're supposed to do.
3. Reminders arrive on time.
4. Members feel actively involved in the life of the church.

Measurable proxies `[ASSUMPTION — proposed, baselines not yet measured]`:

- At least 90% of published duties get an explicit Accept or Decline before their response deadline.
- No slot is still unfilled or unconfirmed 48 hours before the service without already appearing in a leader's queue.
- Leaders report spending little or no Sunday-morning time chasing people (a quick check-in after 4–6 weeks).
- No missed or stale reminders in the server logs. A resolved or replaced duty never triggers a reminder.
- Involvement: the share of active members holding at least one duty or programme part each month, and repeat app use beyond Sunday.

The roughly 40 must-pass tests in spec §Milestones are the release gate. These proxies tell us whether the app actually helps.

## Scope

**Included in v1 (decided, not to be reopened):**

- The core app (public content, membership, duties and reminders, cells, prayer, directory).
- The six approved additions:
  - cell meeting programmes
  - member-visible recaps
  - pastoral visits
  - service attendance counts
  - the staff web portal
  - the cell offering register
- Chat is a separate launch decision. Nothing else may depend on it.

**Boundaries that must hold:**

- No payments, gift records or donor history anywhere in the app.
- No general ledger, accounting, bank reconciliation, payroll or automated SMS/WhatsApp messaging.
- Nothing is shown as confirmed, delivered or attended unless a person actually did it.
- The web portal never becomes a second source of truth.

**Later:** passkeys, email/SMS duty reminders, availability and rota optimisation, livestreaming, devotionals, multi-branch support.

## Delivery Reality

**Target: the full v1, all seven milestones, by November 2026.** This is the owner's decision. Coding agents write most of the implementation and the owner reviews it, working in their free time.

What this means for the build:

- **Code is not the bottleneck.** Owner review time is, along with decisions and lead times outside the code. Keep changes small and reviewable, one ticket at a time. The spec's tests are the evidence a change is correct, so a reviewer can trust a passing suite instead of reading every line.
- **Tests come first and run in CI.** RLS and permission tests, state-transition tests and reminder-worker tests are written alongside each feature, starting in milestone 1. Agents are least reliable on access control and concurrency, and a mistake there exposes care, prayer or finance data.
- **Milestones still set the build order.** Each milestone is finished and tested before the next one leans on it, starting with the shared building blocks (records, permissions, assignments, reminders). Six modules built side by side on unproven foundations would be harder to review than building them one after another.

Lead times outside the code, which can block November whatever the build speed:

- registering an SMS sender ID with Zambian carriers (about 2–4 weeks)
- choosing an SMS provider (Supabase supports some natively; Africa's Talking would need a custom auth hook)
- creating the Apple and Google developer accounts
- naming a time zone, the pilot department and cell, and their leaders
- App Store and Play review, including the giving screen (allow for at least one rejection)
- the staff beta and church onboarding in milestone 7, which run on the church's calendar

## Open Decisions

The spec (§Decisions for the church owner) lists ten decisions. Those that block building:

1. **Access:** SMS provider and spending limit, and who approves members, confirms cell membership and handles account recovery.
2. **Duties:** pilot department and cell, response deadline, reminder timing and quiet hours.
3. **Web:** confirm that Flutter Web works for the portal (accessibility and grid trial in milestone 1), and choose hosting and a domain.

These must be settled before each module goes live, but don't block milestones 1 and 2:

- real giving destinations
- safeguarding and youth rules
- testimony consent and retention periods
- Bible and hymn rights
- recorders and counting definitions
- offering custody procedure and Treasurer appointment

**Risks to watch:**

- Members keep using WhatsApp anyway.
- Smartphone ownership in Zambia is low (about 19% nationally in 2022; the figure is old and the congregation may differ). That makes leader-managed members without logins essential, not optional.
- Store review of the giving screen.
- The project depends on one owner as the only reviewer; keep modules small, tests strong and support procedures written down.

## Source Precedence

1. **Behaviour, permissions and states:** spec 1.2 with the Oct 2 changelog.
2. **Layout, visuals and copy:** `docs/design-handoff/` (README, prototypes, screenshots).
3. The spec copy bundled inside the handoff is out of date. Where the prototypes conflict with the spec, the spec wins. Known cases are in `addendum.md`.
