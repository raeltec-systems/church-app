# Screens designed for the journey videos (not in the prototypes)

Each one is built from the prototypes' own components and tokens (Outfit / Figtree / JetBrains Mono,
navy #14246B, water blue #0A7FE0, the existing chips, sheets and toasts). The owner should approve
each one before it goes into the real app.

| # | Screen / state | Used in | Why it was needed |
|---|---|---|---|
| 1 | **Phone lock screen and home-screen push notifications** (BIC Kafue app icon, title, one-line body, time) | all four | Neither prototype has OS-level notifications. Copy follows the spec's notifications section. |
| 2 | **SMS code notification** during phone sign-up (code autofills the 6 boxes) | Member | The prototype has the OTP screen but not the incoming SMS. |
| 3 | **Member: "Confirm your part" sheet** on My cell (Yes, I'll lead it / Tentative / Can't make it + optional note), and the resulting chip on the part row | Cell leader | Flagged in the brief as missing. Built from the duty "Can't make it?" sheet. |
| 4 | **Leader: per-part status on Cell meetings** (Confirmed / Tentative / Can't make it / Waiting chip on each programme row, and an "x of y confirmed" summary) | Cell leader | Flagged in the brief as missing. Uses the chip colours from the pastoral care board. |
| 5 | **Pastor: "Declined" state on a pastoral care card** (red-tinted chip + the member's reason, with *Schedule visit* to try again) | Pastor | The board has no Declined column or state; the member app already sends a decline note. |
| 6 | **Visit confirmed push** to the member after *Accept new time* | Pastor | Part of #1; listed separately because it is a new notification type. |

Staging (not new screens): the laptop → phone hand-offs are composited in the edit because the two prototypes don't share
state, and the prototype's existing Mwila Chanda visit card is hidden before recording so the pastor can create it on camera.
Native `<select>` dropdown lists don't appear in headless screenshots, so they're drawn in the prototype's style over the real control.
