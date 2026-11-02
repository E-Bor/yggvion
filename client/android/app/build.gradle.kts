plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigning = listOf(
    "ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
).associateWith { System.getenv(it).orEmpty() }
val hasReleaseSigning = releaseSigning.values.all { it.isNotBlank() }
if (releaseSigning.values.any { it.isNotBlank() } && !hasReleaseSigning) {
    throw GradleException("Incomplete release signing environment: " +
        releaseSigning.filterValues { it.isBlank() }.keys.joinToString(", "))
}

android {
    namespace = "dev.yggvion.yggvion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.yggvion.yggvion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseSigning.getValue("ANDROID_KEYSTORE_PATH"))
                storePassword = releaseSigning.getValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = releaseSigning.getValue("ANDROID_KEY_ALIAS")
                keyPassword = releaseSigning.getValue("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // CI requires a distribution key; never publish a debug-signed APK.
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
