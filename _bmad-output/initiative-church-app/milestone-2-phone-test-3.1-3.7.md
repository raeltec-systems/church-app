# Phone and web test: reminders and inbox (stories 3.1 to 3.7)

Staging only (`tmurpotfluignacfueki`), synthetic members only. About 45 minutes, plus one check the
next day (step 7). Record pass/fail per step in
`epic-durable-inbox-and-reminders/evidence-3.7/owner-device-check.md`: device model, Android
version and browser. Leave out numbers, ids and keys.

## What you need

- **Phone:** `church-app-3.7-staging-arm64.apk` (from this session). Install it over the old test
  app. Android may ask you to allow installing from this source.
- **Staff web:** `staff-web-3.7-staging.zip`. Unzip it and serve it the same way as the 2.14 package
  (unzipped folder, then in it: `python3 -m http.server 8767`, and open http://localhost:8767).
- **Accounts:** your existing synthetic accounts.
  - **A** = `+1 202 555 0152` (SYNTHETIC Church Member), on the phone AND on the web.
  - **B** = `+1 202 555 0151` (SYNTHETIC Owner Demo), used only in step 9.
  - Use the passwords you set during the identity test. If you have forgotten one, ask the
    assistant for a staff-assisted reset.
- **Nothing to set up on staging:** the reminder worker runs every minute by itself (set up today).
  Push to the phone is not part of this round: it needs the Firebase setup (owner step 4 in
  `milestone-2-owner-test.md`). Every check below works through the Inbox.

## Steps

1. **Find the inbox (3.1, 3.7).**
   - Phone: sign in as A; **Inbox** is in the bottom bar.
   - Web: sign in as A; **Inbox** is in the sidebar.
   - Both show the same list. Loading shows a spinner. With the phone in airplane mode, pull down:
     you get a "No connection" message with a retry, never a crash or an empty list that pretends
     to be complete.
2. **A reminder arrives with the app closed (3.1, 3.4).**
   1. Phone: **Fixture** tab > **SYNTHETIC test reminders** > **Send me a test reminder**.
   2. Close the app completely, and wait 1 to 2 minutes.
   3. Open the app > **Inbox**: **SYNTHETIC test reminder**, labelled **New**. The web Inbox shows it too.
3. **Live refresh (3.7).** Keep the phone Inbox open and send another test reminder from the web
   (**Fixture** > **SYNTHETIC test reminders**). Within about a minute it appears on the phone
   without touching it. If it hasn't appeared after 2 minutes, pull down; it must be there then.
4. **Generic text only (3.2).** Titles and texts in the Inbox never contain a name, number, place or
   link: only the fixed "SYNTHETIC ..." wording.
5. **Open, Opened, and following the link (3.2, 3.7).**
   1. Tap the item: it shows **Still current** with an **Open** button.
   2. Go back: the item is now labelled **Opened** on the phone, and on the web within seconds or
      after **Check again**.
   3. Nothing anywhere says delivered, seen or read.
   4. **Open** leads to the **SYNTHETIC test source** page.
6. **Out of date (3.2).** Send a fresh test reminder and, once it arrives, open it > **Open** >
   **Cancel it** on its source page. Open the same Inbox item again: it says the reminder is out of
   date, with no reason given and no **Open** button.
7. **Snooze (3.3, 3.7).**
   1. On a new current test reminder: **Remind me later** > **24 hours**. The screen and the Inbox
      show **Snoozed until** tomorrow at this time.
   2. Choose **1 hour** instead: the time is replaced, so only one snooze exists.
   3. About an hour later, the reminder comes back as a new **New** item.
   4. (Next day, optional) A 24-hour snooze comes back at the shown time.
8. **Snooze is cut short to the deadline (3.3, 3.7).**
   1. **Fixture** > **Send me a test request (starts in 20 h)**.
   2. When **SYNTHETIC reply reminder** arrives (within about a minute), open it and choose
      **2 days**.
   3. The answer says it comes back at the start time (about 20 hours away), not in 2 days.
9. **Answering or cancelling removes the reminder (3.3, 3.7).**
   1. On that request choose **Open** > **Answer it**. Back in the Inbox the **Snoozed until** label
      is gone, and opening the reminder says it is out of date.
   2. Repeat with a fresh test reminder: snooze it, then **Open** > **Cancel it**. The snooze label goes and the item is out of date.
10. **Push off keeps the Inbox (3.5, 3.7).**
    1. Inbox > **Notification settings**: turn **SYNTHETIC test reminder** off. It shows **Saved**
       and "Still in your Inbox".
    2. Send another test reminder: it still appears in the Inbox.
    3. Turn the switch back on. The web shows the same switches.
11. **Someone else's reminder (3.1, 3.7).**
    1. On the web, open one of A's reminders and copy the address (`.../inbox/<id>`).
    2. Sign out, then paste the address: you see **Not signed in** with **Sign in**. After signing in
       as A, the same reminder opens.
    3. Sign out, sign in as B, paste it again: **This reminder isn't available**. B's Inbox never
       shows A's items.
12. **Routing by access (3.5).** Ask the assistant to run this one for you. As Admin it sends test
    reminders to an active, a held, a deactivated and an accountless synthetic member. Only the
    active one gets an Inbox item; the other three appear on the "needs direct contact" list it
    shows you.
13. **Clean up.** Tell the assistant "inbox test done": it removes the test reminders of A and B on
    staging.

## If something looks wrong

Note the step, the time, and what you saw (a screenshot is fine if it shows no keys), and send it
to the assistant. A reminder that never arrives is checked from the worker's status on staging.
