import org.jetbrains.kotlin.gradle.dsl.JvmTarget

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
        }
        androidMain.dependencies {
            implementation(libs.androidx.activity.compose)
            // UniFFI Kotlin bindings for the Rust core use JNA at runtime.
            // MUST be the @aar variant on Android — it ships libjnidispatch.so
            // as proper jniLibs (the plain jar hides it as a classpath resource
            // and you get UnsatisfiedLinkError).
            implementation("net.java.dev.jna:jna:5.14.0@aar")
        }
    }
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
    }
}
