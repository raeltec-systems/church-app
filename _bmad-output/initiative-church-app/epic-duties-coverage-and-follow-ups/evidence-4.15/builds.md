# Story 4.15: clean staging builds of both clients

Built 2026-10-15 by scratchpad `build-4.15.sh` (the 3.7 and 2.14 pattern) from commit
`3dda0747b2d34be72e2179444e87c4cbb845b930` (`builds/commit.txt`), after `flutter clean`, with
`SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co` and the staging **publishable** key from
the environment (never printed; every log in `builds/` has it replaced by
`sb_publishable_<redacted>`). Later commits of this story change only evidence and the plan (no
client code, no package).

| Artifact (scratchpad) | Check | Result |
|---|---|---|
| `staff-web-4.15-staging/` (Flutter web release, `--no-web-resources-cdn`) | `builds/staff-web-build.txt` | exit 0 |
| | bundle secret scan (`scan-secrets --bundle`) | clean, 40 files |
| | sealed as **staging** (`package-web seal`) | tree `e7cf0b2f7946589a7ca6bc91d98ce2bc80ea84e8fd229b80d0f65427f27a7c8d`, 40 files (`staff-web-4.15-staging.manifest.json`, `.SHA256SUMS`) |
| | verify as staging | exit 0 |
| | verify as **production** | **refused** (exit 1: "artifact was built for staging, not production") |
| `church-app-4.15-staging-arm64.apk` (release, `--target-platform android-arm64`, signed with the debug key: testing only, not for a store) | `builds/mobile-apk-build.txt` | exit 0 |
| | sha256 | `722b65526dd3c40916179a2caaddd8011052b187e8b64d7ef0657cab2c2e3f81` |
| | bundle secret scan of the unzipped APK | clean, 384 files |
| | ABIs | app code `arm64-v8a` only (`libapp.so`, `libflutter.so`); `armeabi-v7a` and `x86_64` hold only two plugin libraries (as in 2.14) |
| | publishable key present only in `lib/arm64-v8a/libapp.so` (the compiled `--dart-define`) | as expected |

Install: remove an older staging build first if Android refuses the update. Serve the staff web
folder with any static server (owner-demonstration.md, "Before you start").
