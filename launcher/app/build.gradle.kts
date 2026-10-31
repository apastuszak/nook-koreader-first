import java.util.Properties

plugins {
    id("com.android.application")
}

// Release signing is read from helper/keystore.properties, which is never committed.
// Keys: storeFile, storePassword, keyAlias, keyPassword.
val keystoreProps = Properties().apply {
    val f = rootProject.file("../helper/keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.nookkoreader.launcher"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.nookkoreader.launcher"
        minSdk = 27
        // Matches the Nook GlowLight 4 Plus (API 27).
        targetSdk = 27
        versionCode = 4
        versionName = "0.1.3"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    signingConfigs {
        if (!keystoreProps.isEmpty) {
            create("release") {
                storeFile = rootProject.file("../helper/app").resolve(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (!keystoreProps.isEmpty) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    lint {
        // targetSdk 27 is deliberate: this app is sideloaded onto an API 27 device, not published.
        disable += setOf("ExpiredTargetSdkVersion", "OldTargetApi")
        abortOnError = true
    }
}

dependencies {
    // Test-only: JVM unit tests for the launcher guard. Nothing ships in the APK.
    testImplementation("junit:junit:4.13.2")
}
