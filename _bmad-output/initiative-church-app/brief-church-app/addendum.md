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
