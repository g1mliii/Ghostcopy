import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Add the Google services Gradle plugin for Firebase
    id("com.google.gms.google-services")
}

// Release signing is driven by android/key.properties, which is gitignored and
// never committed. Without it the release build falls back to the debug key, so
// `flutter run --release` still works on a machine that has no keystore - it
// just produces something Play will refuse, which is the correct outcome.
//
// See left_TO_DO/PLAY_STORE_SETUP.md for generating the keystore.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

android {
    namespace = "com.ghostcopy.ghostcopy"

    // Ahead of Flutter's default (36) because receive_sharing_intent compiles
    // against 37, and AGP only warns about that mismatch today - it becomes a
    // hard failure on a later AGP or plugin bump.
    //
    // compileSdk only chooses which APIs are visible at compile time and is
    // backward compatible, so it does not change runtime behaviour. targetSdk
    // is the one that does, and it deliberately stays on Flutter's default.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ghostcopy.ghostcopy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // Required for super_clipboard (image/rich text support)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Only build for ARM devices (excludes x86_64 emulators) to reduce build time/size
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "GhostCopy: android/key.properties not found - signing the release " +
                    "build with the DEBUG key. Google Play will reject this artifact."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // AndroidX Core Libraries
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")

    // Firebase
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))
    implementation("com.google.firebase:firebase-messaging")

    // WorkManager for background tasks (widget refresh)
    implementation("androidx.work:work-runtime-ktx:2.8.1")

    // Gson for JSON serialization (widget data persistence)
    implementation("com.google.code.gson:gson:2.10.1")
}
