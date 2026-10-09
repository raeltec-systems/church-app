# Identity epic: owner demonstration on staging (story 2.14)

For Israel, on staging `tmurpotfluignacfueki`, with the 2.14 builds. About 45 minutes. Synthetic
data only: names start with `SYNTHETIC `, numbers in `+1 202 555 0170-0179` (reserved for you;
the automated suite never uses them), passwords you choose and keep to yourself. Tick each box and
note anything that looks wrong; screenshots are welcome but must not show a password.

The automated staging suite already ran every API path below (`staging-suite-summary.md`); this
demonstration is the human check of the two clients.

## Before you start

1. **Install the APK** `church-app-2.14-staging-arm64.apk` (sha256 in `builds.md`) on your Android
   phone (arm64). Remove an older staging build first if Android refuses the update.
2. **Open staff web.** Unzip `staff-web-2.14-staging` (sha256 list in `builds.md`) and serve the
   folder from your computer, for example `python3 -m http.server 8080 --directory staff-web-2.14-staging`,
   then open `http://localhost:8080` in Chrome. (Any static host works; staff web signs in with a
   phone number and password only.)
3. **Two Admin accounts of your own.** Ask the assistant to give Admin, through the synthetic
   Admin, to your demo accounts `+1 202 555 0151` (SYNTHETIC Owner Demo) and `+1 202 555 0152`.
   Two Admins are needed because a hold, a deactivation and a deletion each need a second Admin.
   (If you no longer know their passwords, create two new accounts with `0170` and `0171`, apply,
   and ask the assistant to approve them and give them Admin.)
4. Email steps need the redirect allowlist from `owner-consolidated-test.md` item 1, and the
   built-in sender allows about 2 emails per hour: they are in the consolidated test, not here.

## A. Registration, application and review

- [ ] A1. Mobile: **Account → Create account** with `+1 202 555 0172` and a password. The app opens
  **Join the church**. Enter `SYNTHETIC Demo Member`, pick **SYNTHETIC Market Cell**, tick the
  privacy notice, send. The status card shows **Church approval: awaiting** and **Cell group:
  requested** as two separate lines. My membership shows no member content.
- [ ] A2. Staff web as Admin (0151): **Members & applications → Applications**. The request is
  there with the unverified sign-in username. Click **Ask for details** (full name). Mobile:
  **Check again** shows what was asked; **Correct my request**, change the name, send.
- [ ] A3. Staff web: choose an identity check, **Approve as a new member**. Mobile: the app asks
  you to sign in again; after signing in, **My membership** shows **Approved**.
- [ ] A4. Staff web: **All members → Add member record (no login)**: `SYNTHETIC Demo Accountless`,
  consent in person. Mobile: create `+1 202 555 0173`, apply with exactly that name. Staff web:
  the application shows the accountless record as a possible match (same name). Click
  **Link existing** with an identity check. Mobile (0173) signs in again and sees the member.
  Nothing linked by itself before you clicked.

## B. Roles, navigation and cells

- [ ] B1. Staff web **Roles & access**: give 0172 the **Media** role. On mobile (0172) switch tabs:
  **Access** shows Media without signing in again. Remove it: it disappears on the next tab switch.
- [ ] B2. Staff web **Cells**: make 0173 **leader** of SYNTHETIC Market Cell. Staff web signed in as
  0173 (another browser profile or a private window): **My cell group** lists 0172's join
  request; **Confirm**. Mobile (0172) **My cell** shows SYNTHETIC Market Cell.
- [ ] B3. Mobile (0172): **Ask to join/change cell** → SYNTHETIC Hilltop Cell. Staff web as Admin,
  **Cells**: the request is listed under requests waiting for a leader; confirm it as Admin (an
  Admin may confirm any request). My cell now shows Hilltop only, and 0173 (Market's leader) no
  longer has 0172 in the roster.
- [ ] B4. Staff web as 0173 (a leader, not an Admin): the menu has **My cell group** but no Admin
  destinations, and no care, finance or prayer destination exists for anyone.

## C. Credential change, holds, lifecycle

- [ ] C1. Mobile (0172): **My membership → Sign-in details → Ask for a change → new phone
  number username** `+1 202 555 0174` with the current password. Staff web **Access reviews**:
  approve after an identity check. Mobile signs out; sign in with `0174` and the same password.
- [ ] C2. Staff web (0151) **Access reviews → Place a hold** on 0174 (security concern). Mobile
  shows only **Access review required** (no reason). Staff web as the OTHER Admin (0152):
  release it with an identity check. Mobile signs in again and sees the member.
- [ ] C3. Staff web **Membership status**: **Disable login (hold)** for 0174: mobile is signed out
  and, after signing in, shows **Access review required**. Release it as the other Admin.
- [ ] C4. **Deactivate membership** for 0174 (reason moved away): mobile shows **Church membership
  not active** with no request link. **Restore membership** as the other Admin with an identity
  check: mobile signs in fresh and sees the member; roles are not restored.

## D. Staff-assisted recovery (no email)

- [ ] D1. Mobile (0174), signed out: **Sign in → Get church help → I need help accessing my
  account**, enter `+1 202 555 0174`. Note the 8-character code.
- [ ] D2. Staff web **Account recovery**: find SYNTHETIC Demo Member, record the identity check and
  evidence, type the code, issue the grant. Staff web never shows a password, secret or code back.
- [ ] D3. Mobile: **The office is done: continue**, choose a new password. Sign in with it. The old
  password no longer works.

## E. Deletion

- [ ] E1. Mobile (0174): **Account → Delete my account**, confirm with the password. The app signs
  you out; signing in again fails.
- [ ] E2. Staff web **Member deletions**: the deletion is listed with its steps waiting for the
  worker. (Erasure itself is the worker run in the consolidated test, with your credential.)
- [ ] E3. Staff web as 0151: **Disable login (hold)** for 0173, then try **Delete member** as 0151:
  it is refused (a second Admin is needed). As 0152: **Delete member** with an identity check
  succeeds; 0173 can no longer sign in.

## F. What you should NOT see

- [ ] No screen ever shows an SMS, a code sent to the phone, or a password.
- [ ] Admin screens never show care, finance or prayer content.
- [ ] A member never sees another member's application, candidates or reviewer notes.

## Afterwards

Tell the assistant which boxes passed and anything odd. The accounts you created stay on staging
as synthetic data; the deletion worker run in `owner-consolidated-test.md` erases the deleted ones.
