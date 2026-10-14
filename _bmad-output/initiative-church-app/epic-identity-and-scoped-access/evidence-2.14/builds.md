# Story 2.14: staging builds of both clients

Built 2026-10-07 from commit `aca0241196bee6cedb930bc3b7448e6f52851f5e` (the integration branch
after 2.13). This story changes nothing under `apps/` or `packages/`, so the builds are the client
code of every later 2.14 commit too (`git diff aca0241 -- apps packages` is empty). Script:
scratchpad `build-2.14.sh`; logs in `builds/` with the publishable key replaced by
`sb_publishable_<redacted>`. Each build ran after `flutter clean`.

| Artifact (scratchpad) | What | Hash |
|---|---|---|
| `church-app-2.14-staging-arm64.apk` | Mobile, release, arm64 only (debug-signed, test use; 20.3 MB) | sha256 `c0391f964c0e1e7f5d7a00ff6b245ecf0ec75eba2e42da3b92ae4b48635ebc83` |
| `staff-web-2.14-staging/` | Staff web (Flutter Web), release, no CDN resources, 40 files | tree sha256 `9a1f2f036f3cf64b855e5ec60cdf3543a4d79e3ad0daf9f0b28217be0b1b53a8` |
| `staff-web-2.14-staging.SHA256SUMS` | per-file hashes (copy in `builds/`) | sha256 of the file `9a1f2f03…53a8` (equals the tree hash by construction) |
| `staff-web-2.14-staging.manifest.json` | environment `staging`, commit, API URL, tree hash (copy in `builds/`) | |

## Commands

```sh
export PATH=/opt/sdk/flutter/bin:$PATH ANDROID_HOME=/opt/sdk/android
# staff web (apps/staff)
flutter clean && flutter build web --release --no-web-resources-cdn \
  --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging sb_publishable_ key>
node tools/ci/scan-secrets.mjs --bundle staff-web-2.14-staging
node tools/ci/package-web.mjs seal staff-web-2.14-staging --env staging --commit <sha> --api-url https://tmurpotfluignacfueki.supabase.co
node tools/ci/package-web.mjs verify staff-web-2.14-staging --env staging --commit <sha>
node tools/ci/package-web.mjs verify staff-web-2.14-staging --env production --commit <sha>   # must refuse
# mobile (apps/mobile)
flutter clean && flutter build apk --release --target-platform android-arm64 \
  --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging sb_publishable_ key>
unzip church-app-2.14-staging-arm64.apk -d apk214 && node tools/ci/scan-secrets.mjs --bundle apk214
```

## Results

| Check | Result | Log |
|---|---|---|
| Staff web build | exit 0 | `builds/staff-web-build.txt` |
| Staff web bundle secret scan | clean (40 files) | `builds/staff-web-bundle-scan.txt` |
| Seal / verify for staging | sealed and verified, tree `9a1f2f03…` | `builds/staff-web-seal.txt`, `builds/staff-web-verify-staging.txt` |
| Verify as production | refused: "artifact was built for staging, not production" | `builds/staff-web-verify-as-production-refused.txt` |
| APK build | exit 0, `app-release.apk (20.3MB)` | `builds/mobile-apk-build.txt` |
| APK secret scan (unzipped) | clean (367 files) | `builds/mobile-apk-bundle-scan.txt` |
| APK ABIs | Flutter engine and app code only in `arm64-v8a` (`libflutter.so`, `libapp.so`); `armeabi-v7a` and `x86_64` hold only two small plugin helper libraries, so the APK runs on arm64 phones only | `builds/mobile-apk-abis.txt` |
| Publishable key present only in the compiled app | `lib/arm64-v8a/libapp.so` | `builds/mobile-apk-key-present.txt` |

Owner use: `owner-demonstration.md` (install the APK; serve the staff web folder locally or on
the static host).
