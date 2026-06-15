import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.multiplatform)
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.ui)
            implementation(libs.coroutines.core)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        androidMain.dependencies {
            implementation(libs.androidx.activity.compose)
            implementation(libs.coroutines.android)
            // On-device Lightning wallet (Breez SDK Liquid) for ⚡PAY.
            implementation(libs.breez.sdk.liquid)
            // UniFFI Kotlin bindings for the Rust core use JNA at runtime.
            // MUST be the @aar variant on Android — it ships libjnidispatch.so
            // as proper jniLibs (the plain jar hides it as a classpath resource
            // and you get UnsatisfiedLinkError).
            implementation("net.java.dev.jna:jna:5.14.0@aar")
        }
    }
}

// Breez API key from a gitignored secret — NEVER hardcode or commit it.
// Resolution order: local.properties `breez.apiKey`, else env `BREEZ_API_KEY`,
// else empty (wallet UI then shows "unavailable", like iOS with no key).
val breezApiKey: String = run {
    val lp = rootProject.file("local.properties")
    val fromFile = if (lp.exists()) {
        Properties().apply { lp.inputStream().use { load(it) } }.getProperty("breez.apiKey")
    } else null
    (fromFile ?: System.getenv("BREEZ_API_KEY") ?: "").trim()
}

android {
    namespace = "chat.bitchat.sonar"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "chat.bitchat.sonar.dev"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1"
        buildConfigField("String", "BREEZ_API_KEY", "\"$breezApiKey\"")
    }

    buildFeatures {
        buildConfig = true
    }

    // The Rust core .so per ABI lives in src/androidMain/jniLibs (produced by
    // core/build-android.sh). Map it onto the Android main source set.
    sourceSets["main"].jniLibs.srcDirs("src/androidMain/jniLibs")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
        }
        getByName("debug") {
            // Debug builds only run on the local dev device. Both the Apple-
            // Silicon emulator and the Pixel 8 are arm64-v8a, so ship just that
            // ABI — keeps the debug APK small (the full multi-ABI build bundles
            // the Rust + Breez .so for every ABI and overflows small partitions).
            ndk { abiFilters += "arm64-v8a" }
        }
    }
}
