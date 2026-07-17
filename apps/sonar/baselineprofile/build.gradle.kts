plugins {
    // No versions: AGP and Kotlin are already on the build classpath via
    // :composeApp (android-application + multiplatform).
    id("com.android.test")
    id("org.jetbrains.kotlin.android")
    alias(libs.plugins.baselineprofile)
}

// Macrobenchmark module that generates Baseline Profiles for :composeApp
// (issue #305: chat-open first-composition jank). See README.md for how to
// run generation and verify the profile ships in the release APK.
android {
    namespace = "chat.bitchat.sonar.baselineprofile"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        // Baseline Profile generation needs API 28+; unrooted devices need 33+.
        minSdk = 28
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    targetProjectPath = ":composeApp"
}

baselineProfile {
    // Generate on whatever device/emulator is plugged in (API 33+ unrooted,
    // e.g. the Medium_Phone_API_36 AVD) instead of a Gradle-managed device —
    // the repo's system images are managed by hand, not by Gradle.
    useConnectedDevices = true
}

dependencies {
    implementation(libs.androidx.benchmark.macro.junit4)
    implementation(libs.androidx.test.uiautomator)
    implementation(libs.androidx.test.runner)
    implementation(libs.androidx.test.ext.junit)
    implementation(libs.junit)
}
