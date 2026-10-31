# Owner-access delivery — 31 October 2026

Israel explicitly requested Vercel hosting of staff web and a downloadable Android APK for his device checks. This delivery publishes **staging client artifacts only**. It does not authorise or perform production backend promotion, migration replay, data fixtures, notification sends, policy approval, merge or acceptance completion.

## Delivered

Both builds use exact app source `33e97b2c4443578a0a86a92c02014b5730048bbd` and the hosted staging backend. Later documentation commits are not the binaries' source revision.

- Staff: https://bic-kafue-staff-staging-israel-muyobas-projects.vercel.app
- APK and verification files: https://github.com/raeltec-systems/church-app/releases/tag/staging-owner-20261031-33e97b2
- Owner steps and results template: [staging-owner-test-2026-10-31.md](../../../../docs/runbooks/staging-owner-test-2026-10-31.md).

The existing Vercel team is used, in a dedicated `bic-kafue-staff-staging` project. Its authentication protection remains enabled. The owner received a temporary share URL privately; no share token is committed. No Git integration or automatic deployment from main was added. The deployment wrapper fetches the public repository at the exact source SHA, uses Flutter 3.47.6 at `5fc346839b5d0eef006ed8404392afb4dfae428d`, enforces the lockfile, builds staff with the staging URL and publishable client key only, runs the repository bundle scan, seals/verifies the web tree, and serves only the generated web output. The public client-config build input is outside that served output. `build-info.json` and robots.txt are added after sealing, so the 53-file tree hash covers the original Flutter output, not those additional files.

## Executed checks

- Vercel reports READY; `/build-info.json` returns HTTP 200 and the correct source/environment/backend. `/sign-in` resolves the SPA entry with HTTP 200. Headers include noindex, no-cache and nosniff.
- A fresh, signed-out Chrome context rendered the actual staff landing page. The screenshot was visually inspected: church emblem, staff heading and Sign in control rendered. No page errors or failed requests were recorded. There were no backend calls on that initial landing; this does **not** establish signed-in login or user journeys. No credentials were entered. The earlier blocked signed-in harness was not retried.
- Android release compilation passed with build number 2026103101. The existing development/debug signer is used; `apksigner verify` passed. This is a test distribution, not production signing. Package/minimum SDK/ABIs were read with aapt; see `apk-verification.json`.
- All 423 decompressed APK entries were scanned using the repository's bundle secret rules with no size skips and zero findings. Each ABI's actual libapp.so contains the expected staging URL and publishable client key. No private key/server credential was placed in either client.
- The publicly published APK was downloaded without authentication, independently rehashed and matched the build SHA-256 exactly. Size 73,956,657 bytes. See `download-verification.json`.
- Full CI run 41187112542 completed successfully for the exact application source SHA. Planning/history runs 41187112406 and 41187112407 also succeeded. Documentation commits require separate CI observations.

## Failed preparation steps and warnings retained

The first Vercel wrapper deployment `dpl_Av3w9tYZ27Ff3ZWqPAnwEVkShuL6` failed its staging-config preflight before compiling. The literal initial target was interpreted as production by the provider, but only in this new test project and with no running output or production backend contact. The corrected deployment explicitly uses target `staging` and its public client config. Environment-variable listing returned permission denied and was not bypassed; no hosted environment variables or tokens were extracted.

An initial Windows ZIP extraction collided on case-distinct Android resource filenames. The verification rerun preserved every ZIP entry under an ordinal filename plus a name manifest, checked CRCs while reading, and scanned all bytes. No resource was omitted. The first publication scan was given file paths rather than the scanner's required directory and refused; the six-file publication directory then passed.

Build warnings were not hidden: the Firebase plugin reports future built-in-Kotlin compatibility work, CupertinoIcons font-family metadata is missing, and Android has deprecated-API warnings. Compilation succeeded; device/UI observations are still required. No dependency, app screen, design token, permission policy or SQL migration was changed during delivery.

## Still open

The APK has **no Firebase Android configuration**, so push receipt is blocked in this artifact. No push was sent. Android installation and native user flows are for the owner to observe. iOS requires a separate signed iOS build; an Android APK cannot cover that platform. Existing staging roles and authorised test fixtures are prerequisites, not supplied credentials or automatic role grants.

6.15 remains in progress and 6.17 remains planned. Independent review, hosted parity and all applicable witnessed acceptance/production prerequisites remain separate. Hosting and an artifact download do not close those gates.