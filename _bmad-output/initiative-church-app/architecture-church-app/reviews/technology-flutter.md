# Flutter/Dart evidence for architecture discussion

Retrieved **2026-10-03**, approximately **05:50–05:53 UTC**, from official Flutter/Firebase/Supabase documentation and the pub.dev package API. This is research evidence, **not an architecture decision, dependency pin, scaffold, or implementation**. No repository files were changed and no SDK/packages were installed.

## Inherited scope

The local approved input proposes Flutter for iOS/Android with Riverpod and go_router, and treats Flutter Web for the staff portal as conditional on a foundation grid/accessibility/browser spike. See `/workspace/church-app/_bmad-output/initiative-church-app/brief-church-app/inputs/church-app-v1-spec-1.2.md`, lines 438–443. This evidence does not promote that proposal into a selected web stack.

## Current SDK and direct-package metadata

| Component | Latest stable/version reported by source | Published/released (UTC date) | Declared SDK constraints |
| --- | --- | --- | --- |
| Flutter Linux stable | **3.47.6**, bundled **Dart 3.13.5** | 2026-10-01 | Release manifest, x64; hash `5fc346839b5d0eef006ed8404392afb4dfae428d` |
| `flutter_riverpod` | **3.4.3** | 2026-09-03 | Dart `^3.12.0`; Flutter `>=3.0.0` |
| `go_router` | **18.0.2** | 2026-09-28 | Dart `^3.12.0`; Flutter `>=3.44.0` |
| `supabase_flutter` | **2.18.0** | 2026-09-30 | Dart `>=3.9.0 <4.0.0`; Flutter `>=3.35.0` |
| `firebase_core` | **4.15.0** | 2026-09-14 | Dart `^3.6.0`; Flutter `>=3.27.0` |
| `firebase_messaging` | **16.7.0** | 2026-09-14 | Dart `^3.6.0`; Flutter `>=3.27.0` |

Sources:

- [Official Linux release JSON](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json), selecting the entry whose hash equals `current_release.stable`; [official archive](https://docs.flutter.dev/install/archive).
- [Riverpod API](https://pub.dev/api/packages/flutter_riverpod), [go_router API](https://pub.dev/api/packages/go_router), [Supabase Flutter API](https://pub.dev/api/packages/supabase_flutter), [Firebase Core API](https://pub.dev/api/packages/firebase_core), [Firebase Messaging API](https://pub.dev/api/packages/firebase_messaging). Values above are from `latest.version`, `latest.published`, and `latest.pubspec.environment`.

**Compatibility finding:** Flutter 3.47.6 / Dart 3.13.5 satisfies all five packages' declared SDK constraints. Among these direct packages, the strictest declared lower bounds are Flutter 3.44.0 and Dart 3.12.0. `firebase_messaging` 16.7.0 declares `firebase_core: ^4.14.0`, which includes 4.15.0. Both declare `firebase_core_platform_interface: ^8.1.1`. Riverpod pins its core `riverpod` dependency to 3.4.3; Supabase Flutter pins `supabase` to 2.16.2 and `supabase_common` to 0.1.2.

This establishes **declared compatibility only**. No `flutter pub get`, complete transitive resolution, compilation, device build, or runtime integration test was performed. Native Android/iOS minimum deployment versions and build-tool constraints were not audited. The execution environment currently exposes neither a `flutter` nor a `dart` command, and no application `pubspec.yaml` was found in the repository. The versions above are candidates for discussion, not installed or approved versions.

The older release JSON URL containing `/flutter/releases/` returned HTTP 404 for Linux and macOS. The current official archive asset references `/releases/`; the successful Linux manifest is linked above. No SDK version was inferred from a documentation banner.

## Fit of the inherited package choices

- **Riverpod:** its published description explicitly identifies a reactive caching/data-binding framework for asynchronous work. This is consistent with the inherited state-management role. It does not establish durable offline storage, synchronization, or an application cache policy.
- **go_router:** its published description identifies a declarative Flutter router supporting deep linking and data-driven routes. This matches the inherited navigation role. Platform association files, incoming notification links, auth redirects, and browser refresh/back behavior still require application-specific validation.
- **Supabase Flutter:** its manifest explicitly lists Android, iOS, web, macOS, Windows, and Linux. The [official Dart reference](https://supabase.com/docs/reference/dart/introduction) documents database access, database-change subscriptions, Edge Function invocation, login/user management, and file handling. The [official Flutter quickstart](https://supabase.com/docs/guides/getting-started/quickstarts/flutter.md) starts with `flutter create` and initializes with a project URL and publishable key. SDK support does not by itself establish authorization correctness or offline behavior.
- **Firebase:** the Core manifest provides Android/iOS/macOS/web/Windows plugin registrations; Messaging provides Android/iOS/macOS/web registrations, **not Linux/Windows Messaging registrations**. Android, iOS, and the proposed browser target are represented. [Official setup](https://firebase.google.com/docs/flutter/setup) requires platform registration/configuration and initializes from generated `firebase_options.dart`; package installation alone is insufficient.

The [Supabase changelog index](https://supabase.com/changelog.md) was fetched and scanned. No Flutter/Dart-specific breaking-change item was found in that index. This is not a claim that the complete package changelog or every backend change has been audited.

## Flutter Web: evidence for a conditional validation spike

**Application fit:** the [official web FAQ](https://docs.flutter.dev/platform-integration/web/faq) identifies app-centric experiences, single-page apps, and existing Flutter mobile apps as suitable scenarios. It cautions against static, text-rich, document-oriented sites and says Flutter output does not align with search-engine indexing needs. An authenticated staff portal is consistent with the app-centric use case; this does not prove the specific portal's usability or performance.

**Accessibility:** the [official web accessibility guide](https://docs.flutter.dev/ui/accessibility/web-accessibility) says Flutter translates its Semantics tree into an accessible HTML DOM. Web accessibility is **not enabled by default** for performance reasons: users can activate an invisible `Enable accessibility` button, or the application can activate semantics in code with `SemanticsBinding.instance.ensureSemantics()`. Standard widgets often provide semantics/roles; custom components may require explicit `Semantics` / `SemanticsRole`, translated to ARIA roles. Therefore keyboard focus, screen-reader table headers/cells/selection, responsive layouts, zoom/text scaling, and custom controls must be checked in the actual target browsers and assistive technologies. A canvas UI is not evidence of automatic inaccessibility, and framework semantics support is not evidence that this portal already meets its accessibility requirements.

**Dense tables:** the [official DataTable API](https://api.flutter.dev/flutter/material/DataTable-class.html) warns that large datasets are expensive because columns are measured twice. It also states that `SingleChildScrollView` mounts and paints the full child, including content outside the viewport. It points to `TableView` from `two_dimensional_scrollables`, `PaginatedDataTable`, or `CustomScrollView` as alternatives. The [PaginatedDataTable API](https://api.flutter.dev/flutter/material/PaginatedDataTable-class.html) reads lazily from a `DataTableSource` and offers sorting/selection/pagination controls; this does **not** automatically implement server-side pagination or a complete editable spreadsheet. The requested dense grid, keyboard behavior, screen-reader semantics, realistic record counts, and CSV download still need the inherited spike. No third-party grid package or web framework is selected here.

## Push-notification verification limits

- [FCM Flutter client documentation](https://firebase.google.com/docs/cloud-messaging/flutter/client) requires Google Play services on Android devices or a Google APIs emulator. The currently installed **default AOSP API 35 image** from the earlier environment setup cannot establish Android FCM delivery readiness.
- The same document requires Apple/APNs setup and method swizzling for the Flutter FCM plugin; web token requests use a VAPID public key.
- [FCM receiving documentation](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages) requires notification permission on iOS, macOS, web, and Android 13+, and describes a separate Firebase messaging service worker for browser background handling. Successful token registration, permissions, foreground/background/terminated delivery, and deep-link routing remain unverified.

## Official starter evidence

The [Flutter CLI reference](https://docs.flutter.dev/reference/flutter-cli) documents `flutter create <DIRECTORY>` and a basic workflow using `flutter analyze` and `flutter test`. The [new-app guide](https://docs.flutter.dev/reference/create-new-app) documents `flutter create my_app`, the optional `--empty` minimal starter, and `flutter create --help` for available options. Supabase's official Flutter quickstart uses the same Flutter-generated starter.

This confirms an official starter exists without choosing project names, target platforms, directory boundaries, dependency pins, or a web framework. No starter command was run.

## Evidence files

Raw API responses, downloaded official documentation, extracted text, and retrieval summaries are retained under `/workspace/work/bmad-architecture/flutter-sources/`. The successful SDK manifest is `flutter-releases-current.json`; exact retrieval/version metadata is in `release-summary.json`. Per-package JSON files contain the complete published manifests. `metadata-summary.json` records an initial parser failure on a nullable Supabase `flutter` field; the downloaded `supabase_flutter.json` is intact and its version/SDK values were independently read from that file above.
