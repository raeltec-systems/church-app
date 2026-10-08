plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "zm.bickafue.bic_kafue_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "zm.bickafue.bic_kafue_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Story 3.6: the Firebase app identifiers come only from the build's
        // --dart-define values (never committed; no google-services.json and
        // no google-services plugin). They become the same string resources
        // that plugin would generate, so Firebase also starts natively when a
        // push wakes the app with no Flutter engine running.
        val firebase = firebaseDartDefines()
        if (firebase != null) {
            resValue("string", "google_app_id", firebase.getValue("FIREBASE_ANDROID_APP_ID"))
            resValue("string", "gcm_defaultSenderId", firebase.getValue("FIREBASE_SENDER_ID"))
            resValue("string", "google_api_key", firebase.getValue("FIREBASE_API_KEY"))
            resValue("string", "project_id", firebase.getValue("FIREBASE_PROJECT_ID"))
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// The four Android Firebase values from Flutter's --dart-define list (passed to
// Gradle base64-encoded as the `dart-defines` property), or null when any is
// missing: the app then keeps push off.
fun firebaseDartDefines(): Map<String, String>? {
    val raw = project.findProperty("dart-defines") as String? ?: return null
    val defines = raw.split(",").filter { it.isNotBlank() }.mapNotNull { encoded ->
        val decoded = try {
            String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            return@mapNotNull null
        }
        val i = decoded.indexOf('=')
        if (i <= 0) null else decoded.substring(0, i) to decoded.substring(i + 1).trim()
    }.toMap()
    val keys = listOf(
        "FIREBASE_PROJECT_ID",
        "FIREBASE_SENDER_ID",
        "FIREBASE_API_KEY",
        "FIREBASE_ANDROID_APP_ID",
    )
    return if (keys.all { !defines[it].isNullOrEmpty() }) defines.filterKeys { it in keys } else null
}
