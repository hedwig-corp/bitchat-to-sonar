import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.multiplatform)
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

val repoRootDir = rootProject.projectDir.parentFile.parentFile
val generatedMdkDir = layout.buildDirectory.dir("generated/mdk-v0.9.4")
val generatedKotlinDir = generatedMdkDir.map { it.dir("kotlin") }
val generatedJniDir = generatedMdkDir.map { it.dir("jniLibs") }
val mdkVersionMarker = generatedMdkDir.map { it.file(".mdk-version") }

val buildDarkmatterMdk by tasks.registering(Exec::class) {
    description = "Builds the pinned MDK v0.9.4 MarmotKit Kotlin/JNI bindings."
    group = "build"

    val buildScript = repoRootDir.resolve("core/build-darkmatter-android.sh")
    inputs.file(buildScript)
    inputs.property("mdkVersion", "v0.9.4")
    inputs.property("mdkRevision", "e391adc133a9b60e420da7a0446f014a180ac8d2")
    inputs.property("androidAbis", providers.environmentVariable("DARKMATTER_ANDROID_ABIS").orElse("arm64-v8a armeabi-v7a"))
    outputs.file(mdkVersionMarker)
    outputs.dir(generatedKotlinDir)
    outputs.dir(generatedJniDir)

    environment("DARKMATTER_MDK_OUTPUT", generatedMdkDir.get().asFile.absolutePath)
    environment(
        "ANDROID_ABIS",
        providers.environmentVariable("DARKMATTER_ANDROID_ABIS")
            .orElse("arm64-v8a armeabi-v7a")
            .get(),
    )
    workingDir(repoRootDir)
    commandLine(buildScript.absolutePath)
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
            implementation(libs.coroutines.test)
        }
        androidMain {
            kotlin.srcDir(generatedKotlinDir)
            dependencies {
                implementation(libs.androidx.activity.compose)
                implementation(libs.coroutines.android)
                // Keep the Android AAR variant: generated UniFFI code needs
                // libjnidispatch.so packaged as a native library.
                //noinspection GradleDependency,UseTomlInstead
                implementation("net.java.dev.jna:jna:5.14.0@aar")
                implementation(libs.androidx.annotation)
            }
        }
    }
}

android {
    namespace = "chat.bitchat.sonar.darkmatter"
    compileSdk = libs.versions.android.compileSdk.get().toInt()
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "chat.bitchat.sonar.darkmatter"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0-darkmatter.1"
    }

    sourceSets["main"].jniLibs.srcDir(generatedJniDir)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs.useLegacyPackaging = false
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }

    val signingProperties = Properties().apply {
        val file = rootProject.file("local.properties")
        if (file.exists()) file.inputStream().use(::load)
    }
    fun signingValue(environment: String, property: String): String? =
        System.getenv(environment)?.takeIf(String::isNotBlank)
            ?: signingProperties.getProperty(property)?.takeIf(String::isNotBlank)

    val keystorePath = signingValue("DARKMATTER_KEYSTORE", "darkmatter.keystore")
    val keystorePassword = signingValue("DARKMATTER_KEYSTORE_PASSWORD", "darkmatter.keystore.password")
    val keyAlias = signingValue("DARKMATTER_KEY_ALIAS", "darkmatter.key.alias")
    val keyPassword = signingValue("DARKMATTER_KEY_PASSWORD", "darkmatter.key.password")
    val hasReleaseSigning =
        !keystorePath.isNullOrBlank() &&
            !keystorePassword.isNullOrBlank() &&
            !keyAlias.isNullOrBlank() &&
            !keyPassword.isNullOrBlank() &&
            file(requireNotNull(keystorePath)).isFile

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(requireNotNull(keystorePath))
                storePassword = keystorePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        getByName("debug") {
            ndk.abiFilters += "arm64-v8a"
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        getByName("release") {
            isMinifyEnabled = false
            ndk.abiFilters += listOf("arm64-v8a", "armeabi-v7a")
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
    }
}

tasks.named("preBuild").configure { dependsOn(buildDarkmatterMdk) }
tasks.matching { it.name.startsWith("compile") && it.name.contains("KotlinAndroid", ignoreCase = true) }
    .configureEach { dependsOn(buildDarkmatterMdk) }
