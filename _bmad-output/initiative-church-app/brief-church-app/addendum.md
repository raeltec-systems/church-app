# Addendum: Church App brief

Detail that informs the brief or downstream documents (PRD, architecture) but does not belong in the 1–2 page brief.

## Landscape research digest (web research, 2 Oct 2026)

Figures come from review sites and public pricing pages and change often. Verify before relying on them.

### Off-the-shelf alternatives
- Planning Center Services: free for up to 5 team members, about $32/mo for 50 members, about $69/mo for 150. People module is free.
- Breeze: about $72/mo flat. Tithe.ly ChMS: about $72/mo, with card giving at 2.9% + $0.30.
- Elvanto: from about $50/mo. ChurchSuite: about GBP 30–80/mo. Subsplash: by quote, usually $300+/mo.
- All of the above are priced in USD or GBP, use card payments and email logins, and have no mobile-money support.
- Africa-focused options (not verified for maturity, pricing or rota features):
  - Nehemiah (nehemiahplatform.com), which mentions Zambia
  - Giver/Zuhile (usezuhile.com, Zambia; MTN MoMo and Zamtel Kwacha)
  - GraceFlow (Kenya)
  - Asoriba (Ghana)

### Current coordination
- Evidence that Southern African churches coordinate through WhatsApp groups is anecdotal. ZICTA 2018: 71% of smartphone users used WhatsApp or Facebook.
- No Zambia-specific study of how churches communicate was found.

### Auth SMS
- Twilio: about $0.39 per SMS to Zambia.
- Africa's Talking: about ZMW 0.17 per SMS, possibly a promotional rate.
- Supabase natively supports Twilio, MessageBird, Vonage and Textlocal. Any other provider needs a Send SMS Auth Hook.
- ZICTA requires alphanumeric sender IDs to be registered with each carrier, which takes about 2–4 weeks. MTN may replace unregistered sender IDs with a generic numeric one.

### Mobile money and devices
- Mobile money covered 58.4% of adults in 2023.
- Subscriber shares at end-2024: Airtel about 48%, MTN 28–35%, Zamtel about 23%.
- Smartphone penetration: about 18.6% in 2022 (ZICTA, dated). The 4G figure found (about 65%, OpenSignal 2019) is also dated.

### Store and custom-build risks
- Apple 3.2.1/3.2.2: instruction-only giving that collects funds outside the app fits the guideline, but rejections do happen. Keep the wording informational and explain it in App Review notes.
- Google Play's donations policy has not been verified.
- Other risks:
  - Recurring costs: Apple $99/yr, Supabase tier, SMS.
  - Supabase's free tier pauses inactive projects.
  - Annual Flutter and SDK upkeep.
  - Zambia Data Protection Act 2021.
  - Adoption competing with WhatsApp.

### Sources
- planningcenter pricing: churchmemberpro.com/blog/planning-center-pricing-guide/
- twilio.com/en-us/sms/pricing/zm
- zambia.africastalking.com
- supabase.com/docs/guides/auth/phone-login
- telerivet.com/blog/zambia-sms-compliance-zicta-sender-id-and-data-protection-guide
- voxdev.org/topic/finance/mobile-money-zambia-opportunities-challenges-current-policy-debates
- zicta.zm/market-reports/2024_annual_market_report.pdf
- developer.apple.com/app-store/review/guidelines/
- freedomhouse.org/country/zambia/freedom-net/2022

## Design handoff vs spec 1.2: known conflicts (the spec wins)

The handoff (`docs/design-handoff/`) was drawn before spec 1.2. Where its prototype behaviour differs from the spec, build the spec's behaviour while keeping the design's layout:

1. **Recap publication.** In the handoff, submitting a cell report makes the summary and testimonies visible to members. Spec 1.2 says submitting a private report never publishes a recap. A recap needs a separate preview → publish step and can be corrected or withdrawn. Testimonies need consent.
2. **Cell offering custody.** In the handoff, the offering block in the cell report has fields for two counters and a "Handed to the treasurer" checkbox. Spec 1.2 requires something stricter:
   - each of the two distinct counters attests the count
   - the handover is recorded separately
   - a different, independent Treasurer or deputy records the receipt
   - discrepancies are resolved through append-only corrections

   A checkbox the leader ticks is not a receipt.
3. **Pastoral care kanban.** In the handoff, dropping a card on most columns moves it directly. Spec 1.2 says dragging can never create consent. Moves that imply agreement (Confirmed, new time accepted) have to go through the member's response or a confirmation staff record after direct contact. The board also needs keyboard and list alternatives to drag and drop.
4. **Admin role switcher.** The handoff's sidebar switch between Admin, Cell leader and Pastor is a prototype convenience. In production a switcher only chooses among roles the account has actually been granted, and the server enforces every scope.

## Design pack contents
- `docs/design-handoff/README.md`: design tokens (colour, type, radii, spacing), every screen described, state flows and the data additions the screens imply.
- `design/BIC Kafue App.dc.html` and `design/BIC Kafue Admin.dc.html`: interactive prototypes. Mock data and state logic are in each file's `class Component` script.
- `screenshots/`: 19 member-app screens and 13 admin screens.
- All names, numbers, giving destinations and figures in the pack are placeholders.
