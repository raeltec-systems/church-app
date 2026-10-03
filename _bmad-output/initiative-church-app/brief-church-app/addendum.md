# Addendum: Church App brief

Detail behind the brief. The design pack map and the design-vs-spec conflicts are binding for the build. The research digest is background, and its figures need checking before use.

## Design pack contents

**Note:** all names, phone numbers, giving destinations (mobile-money and bank details) and figures in the pack are placeholders. Never ship them.

- `docs/design-handoff/README.md`: design tokens (colour, type, radii, spacing), every screen described, state flows and the data additions the screens imply.
- `design/BIC Kafue App.dc.html` and `design/BIC Kafue Admin.dc.html`: interactive prototypes. Mock data and state logic are in each file's `class Component` script.
- `screenshots/`: 19 member-app screens and 13 admin screens.

## Design handoff vs spec 1.2: known conflicts (the spec wins)

The handoff was drawn before spec 1.2. Where its prototype behaviour differs from the spec, build the spec's behaviour while keeping the design's layout. The same rule applies to any conflict not listed here.

1. **Recap publication**
   - **Handoff:** submitting a cell report makes its summary and testimonies visible to members.
   - **Build instead:** submitting a cell report, which is private, never publishes a recap. A recap goes through a separate preview → publish step and can be corrected or withdrawn. Include a testimony only as an edited story, with the permission of the person it is about, or leave it out. (Spec §Cell groups → Member-visible recaps.)
2. **Cell offering custody**
   - **Handoff:** the cell report's offering block records two counters' names and a "Handed to the treasurer" checkbox.
   - **Build instead:** a checkbox the leader ticks is not a receipt. Each of two distinct counters attests the count, the handover is recorded separately, and a Treasurer or deputy who is neither a counter nor the handing-over custodian records the receipt. Resolve discrepancies through append-only corrections. (Spec §Cell offerings.)
3. **Pastoral care kanban**
   - **Handoff:** dropping a card on most columns moves it straight there.
   - **Build instead:** dragging never creates consent. Moves that imply agreement (to the Confirmed column, or accepting a new time) go through the member's response, or through a confirmation that staff record after direct contact with the member. The board has keyboard and list alternatives to drag and drop. (Spec §Pastoral visits → Staff board and privacy.)
4. **Admin role switcher**
   - **Handoff:** the sidebar switches freely between Admin, Cell leader and Pastor (a prototype convenience).
   - **Build instead:** a switcher chooses only among roles the account actually holds, and the server enforces every scope. (Spec §Navigation and visual style → Staff web; §Roles and permissions.)

## Landscape research digest (web research, 2 October 2026)

Figures come from review sites and public pricing pages and change often. Verify before relying on them.

### Off-the-shelf alternatives

All the mainstream tools are priced in USD or GBP and use card payments and email sign-in. None supports mobile money.

- Planning Center Services: free for up to 5 team members, about $32/mo for 50, about $69/mo for 150. The People module is free. ([churchmemberpro.com](https://churchmemberpro.com/blog/planning-center-pricing-guide/), [gracesquad.org](https://gracesquad.org/blog/planning-center-pricing))
- Breeze: about $72/mo flat. Tithe.ly ChMS (church management system): about $72/mo, with card giving at 2.9% + $0.30. Elvanto: from about $50/mo. ChurchSuite: about GBP 30–80/mo. Subsplash: by quote, usually $300+/mo. ([theleadpastor.com](https://theleadpastor.com/tools/tithely-vs-subsplash/), [itqlick.com](https://www.itqlick.com/compare/elvanto/breeze), [usebuildify.com](https://usebuildify.com/post/church-app-cost-every-option-compared))
- Africa-focused options, not verified for maturity, pricing or rota features:
  - Nehemiah, which mentions Zambia ([nehemiahplatform.com](https://nehemiahplatform.com/))
  - Giver/Zuhile, Zambia, with MTN MoMo and Zamtel Kwacha ([usezuhile.com](https://usezuhile.com/))
  - GraceFlow, Kenya ([graceflow.life](https://graceflow.life/))
  - Asoriba, Ghana (unsourced)

### Phone, app and mobile-money use

- Evidence that Southern African churches coordinate through WhatsApp groups is anecdotal. No Zambia-specific study of how churches communicate was found. ([umnews.org](https://www.umnews.org/en/news/church-whatsapp-group-fosters-business-collaboration), [pharosjot.com](https://www.pharosjot.com/uploads/7/1/6/3/7163688/article_51_vol_101__2020__unizul.pdf))
- ZICTA (Zambia Information and Communications Technology Authority) 2018: 71% of smartphone users used WhatsApp or Facebook. ([freedomhouse.org](https://freedomhouse.org/country/zambia/freedom-net/2022))
- Smartphone penetration: about 18.6% in 2022 (ZICTA; now out of date). ([freedomhouse.org](https://freedomhouse.org/country/zambia/freedom-net/2022), [ZICTA 2024 report](https://www.zicta.zm/market-reports/2024_annual_market_report.pdf))
- 4G coverage: about 65% (OpenSignal 2019), also out of date (unsourced).
- 58.4% of adults had an active mobile money account in 2023. Mobile subscriber shares at end-2024: Airtel about 48%, MTN 28–35%, Zamtel about 23%. ([voxdev.org](https://voxdev.org/topic/finance/mobile-money-zambia-opportunities-challenges-current-policy-debates), [itweb.africa](https://itweb.africa/article/zambia-telecom-duopoly-proves-unbreakable/xA9POvNE2mmqo4J8))

### SMS for phone sign-in

- Twilio: about $0.39 per SMS to Zambia. ([twilio.com](https://www.twilio.com/en-us/sms/pricing/zm))
- Africa's Talking: about ZMW 0.17 per SMS, possibly a promotional rate. ([zambia.africastalking.com](https://zambia.africastalking.com/))
- Supabase natively supports Twilio, MessageBird, Vonage and Textlocal. Any other provider needs a Send SMS Auth Hook. ([supabase.com](https://supabase.com/docs/guides/auth/phone-login))
- ZICTA requires alphanumeric sender IDs to be registered with each carrier. Registration takes about 2–4 weeks. MTN may replace unregistered sender IDs with a generic numeric one. ([telerivet.com](https://www.telerivet.com/blog/zambia-sms-compliance-zicta-sender-id-and-data-protection-guide), [sent.dm](https://www.sent.dm/en/resources/sms-compliance/zambia-sms-guide))

### Store and custom-build risks

- App Store Review Guidelines 3.2.1 and 3.2.2: a giving screen that only explains how to give outside the app fits these guidelines, but rejections do happen. Keep the wording informational and explain it in App Review notes. ([developer.apple.com guidelines](https://developer.apple.com/app-store/review/guidelines/), [developer forums](https://developer.apple.com/forums/thread/799549))
- Google Play's donations policy has not been verified.
- **Recurring costs and upkeep** (unsourced): Apple Developer Program $99/yr, a paid Supabase tier (the free tier pauses inactive projects), SMS (see above), and annual Flutter and SDK upkeep.
- **Compliance** (unsourced): Zambia Data Protection Act 2021.
