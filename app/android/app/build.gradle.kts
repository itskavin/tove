import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Credentials never live in the repo. First match wins:
//   1. $TOVE_KEY_PROPERTIES (path to a key.properties file;
//      $HERMES_LIVE_KEY_PROPERTIES is still read as a legacy name)
//   2. android/key.properties (gitignored)
//   3. ~/.config/tove/key.properties (a per-user location outside the repo)
// Keys: storeFile, storePassword, keyAlias, keyPassword, optional storeType.
// Without one, release packaging fails; it never falls back to debug keys.
val releaseKeyProperties: File? =
    listOfNotNull(
        System.getenv("TOVE_KEY_PROPERTIES")?.takeIf { it.isNotBlank() }?.let(::File),
        System.getenv("HERMES_LIVE_KEY_PROPERTIES")?.takeIf { it.isNotBlank() }?.let(::File),
        rootProject.file("key.properties"),
        File(System.getProperty("user.home"), ".config/tove/key.properties"),
    ).firstOrNull { it.isFile }

val releaseSigning: Properties? =
    releaseKeyProperties?.let { file ->
        Properties().apply { file.inputStream().use { load(it) } }
    }

android {
    namespace = "io.github.tovechat.tove"
    // flutter_local_notifications 23 and androidx.core 1.19 need API 37 to
    // compile against (targetSdk is unchanged).
    compileSdk = maxOf(37, flutter.compileSdkVersion)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 23 needs java.time on older Android.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "io.github.tovechat.tove"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_webrtc needs API 23+. Keep Flutter's default when it is higher.
        minSdk = maxOf(23, flutter.minSdkVersion)
        // Pinned, not Flutter's default, so a Flutter upgrade never changes runtime behaviour
        // untested. Raise (and test) deliberately.
        targetSdk = 36
        // versionCode = the pubspec build number (version: 1.2.3+N), which must grow with every
        // release (Android refuses to update to a lower one); versionName = 1.2.3. The GitHub
        // release tag is v1.2.3+N (app/README.md "Releasing").
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        releaseSigning?.let { props ->
            create("release") {
                fun required(key: String): String =
                    props.getProperty(key)?.takeIf { it.isNotBlank() }
                        ?: throw GradleException("$key missing in $releaseKeyProperties")
                // Relative storeFile paths resolve against the properties file.
                val store = File(required("storeFile"))
                storeFile = if (store.isAbsolute) store else File(releaseKeyProperties!!.parentFile, store.path)
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
                props.getProperty("storeType")?.takeIf { it.isNotBlank() }?.let { storeType = it }
            }
        }
    }

    buildTypes {
        release {
            // Stable release key from outside the repo; debug builds keep the
            // default debug key (and the debug-only loopback cleartext config).
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Refuse to package an unsigned or debug-signed release.
if (releaseSigning == null) {
    tasks.matching { it.name.startsWith("package") && it.name.contains("Release") }.configureEach {
        doFirst {
            throw GradleException(
                "No Tove release signing config found. Set TOVE_KEY_PROPERTIES to the " +
                    "path of a key.properties file, or create android/key.properties. " +
                    "See docs/native-call-integration.md.",
            )
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// UnifiedPush's connector pulls the JVM `tink` artifact while
// flutter_secure_storage uses `tink-android`, the Android build of the same
// classes; both on the classpath fail with duplicate classes. Keep the
// Android one.
configurations.configureEach {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
