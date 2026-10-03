---
title: "Product Brief: BIC Kafue Church App"
status: final
created: 2026-10-02
updated: 2026-10-03
---

# Product Brief: BIC Kafue Church App

**Owner:** Israel Muyoba (scope approved by the owner, with the pastor's blessing) · **Audience:** the engineer building v1

**Sources and precedence:**

1. **Behaviour, permissions and states:** `inputs/church-app-v1-spec-1.2.md` with the Oct 2 changelog.
2. **Layout, visuals and copy:** `docs/design-handoff/` (README, prototypes, 32 reference screens, light and dark modes).
3. The spec copy bundled inside the handoff is out of date. Where the prototypes conflict with the spec, the spec wins. Known cases are in `addendum.md`.

## Executive Summary

Brethren in Christ Church Kafue has fewer than 200 members. It runs its Sunday duties by phone calls, WhatsApp messages and people chasing each other in the church foyer. Members aren't sure what's asked of them, leaders can't see who said yes, and gaps surface on the day.

The Church App is a Flutter mobile app for iOS and Android plus a staff web portal, built on Supabase. It turns each duty into an explicit request: the member is reminded on time, gives a clear **Accept** or **Can't make it**, and the leader sees every unfilled, declined or unanswered slot early enough to act. Around that core, it gives the congregation sermons, events, the Bible and hymn book, giving instructions, cell life, prayer and pastoral care in one place.

One volunteer owner reviews and maintains it, with coding agents doing most of the implementation, so every module reuses the same building blocks: assignments, responses, follow-ups, reminders and scoped permissions.

## The Problem

- **Duties are invisible until they fail.** Assignments are spread across calls and chats. Nobody holds one list showing who confirmed, who declined and who never replied.
- **Leaders carry the follow-up in their heads.** Chasing people happens one by one, often on Sunday morning itself.
- **Members are unsure what's expected.** Without a clear "you're on Main door, Sun 4 Oct, report 08:30", even willing people get missed or turn up not knowing their part.
- **Off-the-shelf tools don't fit.** They assume dollars, email sign-in and card payments. See `addendum.md` for the comparison.

## The Solution

The heart of the app is a duty loop: **publish → remind → respond → see gaps → follow up → confirm**.

- **Members** get a *My duties* card on Home showing the next assignment, with **Accept** or **Can't make it**. They get on-time reminders sent from the server even when the app is closed, and a *My follow-ups* list for any task they own. Most will use the mobile app, not the web portal.
- **Department and cell leaders** get a *Needs attention* view and a coverage queue (unfilled, overdue, declined, needs contact). From there they can call, reassign, or record a confirmation made in person or by phone. A leader-recorded confirmation is labelled as such and is never shown as the member's own acceptance.
- **Cell groups** use the same machinery for meeting programmes (who leads each part). Recaps are published separately for members to see; private reports stay with leaders and pastors.
- **Pastoral visits** are requested by members or proposed by the pastoral team. A visit counts as agreed only when the member consents.
- **The pastor** gets a church-wide picture (duty coverage, attendance trends, cell reports, care cases) without seeing what has to stay private.
- **Staff work** happens in a role-scoped web portal: rotas, membership, cell reports, service attendance counts, the cell offering register and the care board. Essential leader actions also stay in the mobile app. Both surfaces share one backend, so the same records and the same rules apply on mobile and web.
- **Admins, the Treasurer and service recorders** each get a narrow, audited set of permissions. Holding the Admin role does not by itself grant access to care or finance content.
- **Guests** need no account for public content: sermons, events, the Bible and hymn book, and an instruction-only *How to give* list.

## Scope

**Boundaries that must hold:**

- No payments, gift records or donor history anywhere in the app.
- No general ledger, accounting, bank reconciliation, payroll or automated SMS/WhatsApp reminders (sign-in codes are the only text messages the app sends).
- Nothing is shown as confirmed, delivered or attended unless a person actually did it.
- The web portal never becomes a second source of truth.

**Included in v1 (decided, not to be reopened):**

- The core app (public content, membership, duties and reminders, cells, prayer, directory).
- The six approved additions:
  - cell meeting programmes
  - member-visible recaps
  - pastoral visits
  - service attendance counts
  - the staff web portal
  - the cell offering register

**Chat** is a separate launch decision. Nothing else may depend on it.

**Later:** passkeys, email/SMS duty reminders, availability and rota optimisation, livestreaming, devotionals, multi-branch support.

## What Makes This Different

What sets it apart is fit, not technology:

- Sign-up and sign-in use a phone number (+260) confirmed with a code sent by text message. Email is optional.
- Members without a phone can still be given duties through leader-managed records.
- Giving instructions cover mobile money, with dialler shortcuts.
- The rota follows the church's own departments and cells.
- Member, prayer and care data stay with the church. There is no platform subscription, though hosting, SMS and app store accounts still cost money.

What it really competes with is WhatsApp, not other apps. It wins only if responding in the app is quicker than replying in a chat, and if leaders trust the coverage view more than their own memory.

## Success Criteria

**Release gate:** the roughly 40 must-pass tests in spec §Milestones.

**The owner's definition of success:**

1. Leaders no longer chase members for tasks.
2. Members know exactly what they're supposed to do.
3. Reminders arrive on time.
4. Members feel actively involved in the life of the church.

**Measurable proxies** `[ASSUMPTION — proposed, baselines not yet measured]`. These show whether the app actually helps:

- At least 90% of published duties get an explicit **Accept** or **Can't make it** before their response deadline.
- Every slot still unfilled or unconfirmed 48 hours before the service already appears in a leader's queue.
- Leaders report spending little or no Sunday-morning time chasing people (a quick check-in after 4–6 weeks).
- No missed or stale reminders in the server logs. A resolved or replaced duty never triggers a reminder.
- Involvement: the share of active members holding at least one duty or programme part each month, and repeat app use beyond Sunday.

## Delivery Reality

**Target: the full v1, all seven milestones, by November 2026.** This is the owner's decision. Coding agents write most of the implementation and the owner reviews it, working in their free time.

What this means for the build:

- **Code is not the bottleneck.** The bottlenecks are owner review time, pending decisions and lead times outside the code. Keep changes small and reviewable, one ticket at a time. The spec's tests are the evidence a change is correct, so a reviewer can trust a passing suite instead of reading every line.
- **Tests come first and run in CI.** Row-level security (RLS) and permission tests, state-transition tests and reminder-worker tests are written alongside each feature, starting in milestone 1. Agents are least reliable on access control and concurrency, and a mistake there exposes care, prayer or finance data.
- **Milestones still set the build order.** Each milestone is finished and tested before the next one leans on it, starting with the shared building blocks (records, permissions, assignments, reminders). Building six modules side by side on unproven foundations would be harder to review than building them one after another.

**Lead times outside the code**, which can block a November release regardless of build speed:

- registering an SMS sender ID with Zambian carriers (about 2–4 weeks), which waits on choosing a provider (decision 1 below)
- creating the Apple and Google developer accounts
- App Store and Play review, including the giving screen (allow for at least one rejection)
- the staff beta and church onboarding in milestone 7, which run on the church's calendar

## Open Decisions

The spec (§Decisions for the church owner) lists ten decisions. These three block building:

1. **Access:** the SMS provider and spending limit (Supabase supports some providers natively; Africa's Talking would need a custom auth hook), and who approves members, confirms cell membership and handles account recovery.
2. **Duties:** the church time zone, the pilot department and cell and their leaders, the response deadline, reminder timing and quiet hours.
3. **Web:** confirm that Flutter Web works for the portal (accessibility and grid trial in milestone 1), and choose hosting and a domain.

These must be settled before the module they affect goes live, but don't block milestones 1 and 2:

- real giving destinations
- safeguarding and youth rules
- testimony consent and retention periods
- Bible and hymn rights
- who records service attendance, and how it is counted
- offering custody procedure and Treasurer appointment

## Risks

- Members keep using WhatsApp anyway.
- Smartphone ownership in Zambia is low (about 19% nationally in 2022; the figure is old and the congregation may differ). That makes leader-managed records for members without logins essential, not optional.
- Store review rejects the giving screen.
- The owner is the only reviewer (see Delivery Reality). Write the support procedures down.
