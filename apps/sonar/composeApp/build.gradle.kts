import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.gradle.api.tasks.Exec
import java.util.Properties

plugins {
    alias(libs.plugins.multiplatform)
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.google.services) apply false
    // Bakes the generated Baseline Profile (src/androidRelease/generated/baselineProfiles)
    // into release APKs so cold starts and first compositions run AOT-compiled
    // (issue #305). Generation lives in :baselineprofile.
    alias(libs.plugins.baselineprofile)
}

// CI device tests do not need Firebase and must not depend on a production
// google-services.json. Normal app builds still apply the plugin by default.
val skipGoogleServices = providers.gradleProperty("sonar.skipGoogleServices").orNull == "true"
if (!skipGoogleServices) {
    apply(plugin = "com.google.gms.google-services")
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

// Escape for BuildConfig string literals (`"` / `\`). Never log the key itself.
fun escapeBuildConfigString(value: String): String =
    value.replace("\\", "\\\\").replace("\"", "\\\"")

if (breezApiKey.isEmpty()) {
    logger.warn(
        "BREEZ_API_KEY is empty — Lightning wallet will show as Unavailable. " +
            "Set breez.apiKey in apps/sonar/local.properties or export BREEZ_API_KEY.",
    )
}

// Desktop has no Android-style BuildConfig, so the key is written to a generated
// resource (`/breez_api_key.txt`) the jvm WalletBridge reads at runtime. The dir
// is gitignored; the value never lands in source.
val breezKeyResDir = layout.buildDirectory.dir("generated/breezKey")
val generateBreezKeyResource = tasks.register("generateBreezKeyResource") {
    val out = breezKeyResDir.get().file("breez_api_key.txt").asFile
    inputs.property("breezApiKey", breezApiKey)
    outputs.file(out)
    doLast {
        out.parentFile.mkdirs()
        out.writeText(breezApiKey)
    }
}

val repoRootDir = rootProject.projectDir.parentFile.parentFile
val notificationResourcesDir = repoRootDir.resolve("assets/notifications")
val configuredPython =
    providers.gradleProperty("pythonExecutable").orNull
        ?: providers.environmentVariable("PYTHON").orNull
val pythonCommand = when {
    !configuredPython.isNullOrBlank() -> listOf(configuredPython)
    System.getProperty("os.name", "").startsWith("Windows", ignoreCase = true) ->
        listOf("py", "-3")
    else -> listOf("python3")
}

// Verifies the committed Compose string resources are in sync with the iOS
// localization catalog (ios/bitchat/Localizable.xcstrings), the single source
// of truth. Run scripts/i18n/xcstrings_to_compose.py to regenerate after
// editing the catalog. Python 3 is required; override executable discovery with
// `-PpythonExecutable=/path/to/python` or the `PYTHON` environment variable.
val checkI18nStringsInSync = tasks.register<Exec>("checkI18nStringsInSync") {
    description = "Checks generated Compose string resources match the iOS xcstrings catalog."
    group = "verification"

    val generator = repoRootDir.resolve("scripts/i18n/xcstrings_to_compose.py")
    val idMap = repoRootDir.resolve("scripts/i18n/string_id_map.json")
    val stamp = layout.buildDirectory.file("i18n/strings-in-sync.stamp")
    inputs.file(repoRootDir.resolve("ios/bitchat/Localizable.xcstrings"))
    inputs.file(generator)
    inputs.file(idMap)
    inputs.dir(layout.projectDirectory.dir("src/commonMain/composeResources"))
    // Output stamp lets Gradle mark the task UP-TO-DATE when nothing changed.
    outputs.file(stamp)

    workingDir(repoRootDir)
    isIgnoreExitValue = true
    executable(pythonCommand.first())
    args(pythonCommand.drop(1))
    args(generator.absolutePath, "--check")

    doLast {
        val result = executionResult.get()
        if (result.exitValue != 0) {
            throw GradleException(
                "Compose string resources are out of sync with " +
                    "ios/bitchat/Localizable.xcstrings. " +
                    "Run: python3 scripts/i18n/xcstrings_to_compose.py",
            )
        }
        val stampFile = stamp.get().asFile
        stampFile.parentFile.mkdirs()
        stampFile.writeText("in-sync")
    }
}

val androidMainDir = layout.projectDirectory.dir("src/androidMain")
val androidBindingsFile = androidMainDir.file("kotlin/uniffi/sonar_ffi/sonar_ffi.kt")
val androidJniLibsDir = androidMainDir.dir("jniLibs")
val desktopMainDir = layout.projectDirectory.dir("src/jvmMain")
val desktopBindingsFile = desktopMainDir.file("kotlin/uniffi/sonar_ffi/sonar_ffi.kt")
val desktopResourcesDir = desktopMainDir.dir("resources")

val buildAndroidRustCore = tasks.register<Exec>("buildAndroidRustCore") {
    description = "Builds the Android Rust core and UniFFI Android bindings."
    group = "build"

    inputs.file(repoRootDir.resolve("core/build-android.sh"))
    inputs.file(repoRootDir.resolve("core/Cargo.toml"))
    inputs.file(repoRootDir.resolve("core/Cargo.lock"))
    inputs.dir(repoRootDir.resolve("core/sonar-core/src"))
    inputs.dir(repoRootDir.resolve("core/sonar-ffi/src"))
    inputs.dir(repoRootDir.resolve("core/vendor/nostr-blossom/src"))
    inputs.property(
        "sonarAbis",
        providers.environmentVariable("SONAR_ABIS")
            .orElse("-t arm64-v8a -t armeabi-v7a -t x86_64"),
    )
    inputs.property(
        "sonarBindingsAbi",
        providers.environmentVariable("SONAR_BINDINGS_ABI").orElse("arm64-v8a"),
    )
    outputs.file(androidBindingsFile)
    outputs.dir(androidJniLibsDir)

    workingDir(repoRootDir)
    commandLine(repoRootDir.resolve("core/build-android.sh").absolutePath)
}

val buildDesktopRustCore = tasks.register<Exec>("buildDesktopRustCore") {
    description = "Builds the desktop Rust core, BLE bridge, native wallet lib, and UniFFI JVM bindings."
    group = "build"

    inputs.file(repoRootDir.resolve("core/build-desktop.sh"))
    inputs.file(repoRootDir.resolve("core/Cargo.toml"))
    inputs.file(repoRootDir.resolve("core/Cargo.lock"))
    inputs.file(repoRootDir.resolve("core/sonar-ble/Cargo.toml"))
    inputs.dir(repoRootDir.resolve("core/sonar-core/src"))
    inputs.dir(repoRootDir.resolve("core/sonar-ffi/src"))
    inputs.dir(repoRootDir.resolve("core/sonar-ble/src"))
    inputs.file(rootProject.file("gradle/libs.versions.toml"))
    outputs.file(desktopBindingsFile)
    outputs.dir(desktopResourcesDir)

    workingDir(repoRootDir)
    commandLine(repoRootDir.resolve("core/build-desktop.sh").absolutePath)
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    // Desktop (macOS / Windows / Linux) via Compose Desktop. Default source-set
    // names are jvmMain/jvmTest. The same commonMain UI + SonarAppState drive it;
    // the Rust core is reached through the SAME UniFFI/JNA bindings as Android
    // (generated by core/build-desktop.sh into jvmMain) loading a host .dylib/.so.
    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(project(":transcript-engine-compose"))
            api(project(":transcript-engine-policy"))
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.ui)
            // Brand assets (design/handoff/project/sonar/brand) vendored into
            // src/commonMain/composeResources — the home-header wordmark chip.
            implementation(compose.components.resources)
            implementation(libs.coroutines.core)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
        }
        // Compose UI tests live in jvmTest, not commonTest: they need a real
        // composition + layout pass, which the Android *unit* test target
        // cannot provide without Robolectric. The code under test is
        // commonMain, so the desktop target exercises the shared behavior.
        jvmTest.dependencies {
            @OptIn(org.jetbrains.compose.ExperimentalComposeLibrary::class)
            implementation(compose.uiTest)
            implementation(compose.desktop.currentOs)
        }
        androidMain.dependencies {
            implementation(libs.androidx.activity.compose)
            implementation(libs.coroutines.android)
            // Android-supported WebSocket transport for relay diagnostics.
            implementation(libs.okhttp.client)
            // On-device Lightning wallet (Breez SDK Liquid) for ⚡PAY.
            implementation(libs.breez.sdk.liquid)
            // UniFFI Kotlin bindings for the Rust core use JNA at runtime.
            // MUST be the @aar variant on Android — it ships libjnidispatch.so
            // as proper jniLibs (the plain jar hides it as a classpath resource
            // and you get UnsatisfiedLinkError).
            implementation("net.java.dev.jna:jna:5.14.0@aar")
            // QR encoding for shareable group invite links.
            implementation("com.google.zxing:core:3.5.3")
        }
        androidInstrumentedTest.dependencies {
            implementation(libs.androidx.test.runner)
            implementation(libs.androidx.test.ext.junit)
            implementation(libs.junit)
            implementation(libs.okhttp.mockwebserver)
        }
        val androidUnitTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation("org.robolectric:robolectric:4.16.1")
            }
        }
        val jvmMain by getting {
            // The desktop Breez API key is written here by `generateBreezKeyResource`
            // (gitignored generated dir), mirroring Android's BuildConfig field.
            resources.srcDir(breezKeyResDir)
            resources.srcDir(notificationResourcesDir.resolve("raw"))
            dependencies {
                implementation(compose.desktop.currentOs)
                // Swing/AWT EDT main dispatcher for Dispatchers.Main on desktop.
                implementation(libs.coroutines.swing)
                // On-device Lightning wallet (Breez SDK Liquid) for ⚡PAY — same
                // KMP artifact as Android; Gradle resolves its `jvm` variant (a
                // UniFFI/JNA binding). The host native lib (libbreez_sdk_liquid_
                // bindings.dylib) is fetched into jvmMain/resources by
                // core/build-desktop.sh, where JNA loads it off the classpath.
                implementation(libs.breez.sdk.liquid)
                // UniFFI Kotlin bindings load the host dynamic library via JNA.
                // Plain jar (the @aar variant is Android-only); the bundled
                // libjnidispatch ships in the jna jar for the desktop OS.
                implementation(libs.jna)
                // QR encoding for shareable group invite links.
                implementation("com.google.zxing:core:3.5.3")
            }
        }
    }
}

compose.resources {
    // Stable, explicit package for the generated Res class (default derives from
    // the project name and is easy to break by renaming modules).
    packageOfResClass = "chat.bitchat.sonar.resources"
}

compose.desktop {
    application {
        mainClass = "chat.bitchat.sonar.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Sonar"
            packageVersion = "1.0.0"
            description = "Sonar — Bluetooth mesh + Nostr secure messaging (desktop)"
            macOS {
                bundleID = "chat.bitchat.sonar.desktop"
                // Reuse the Android launcher icon (sonar rings on #0A1418),
                // rendered 1:1 to .icns so the Mac app matches the phone.
                iconFile.set(project.file("sonar.icns"))
                // Required so macOS shows the Bluetooth permission prompt for the
                // packaged app — the desktop BLE radio (sonar-ble / CoreBluetooth)
                // needs it. Without an .app bundle (e.g. `gradle run`) macOS can't
                // prompt, so BLE only works when the launching app already has the
                // Bluetooth grant.
                infoPlist {
                    extraKeysRawXml = """
                        <key>NSBluetoothAlwaysUsageDescription</key>
                        <string>Sonar uses Bluetooth to find people nearby and relay messages over the mesh.</string>
                    """.trimIndent()
                }
                // Under the hardened runtime, Bluetooth needs an entitlement (on
                // top of the Info.plist string) or macOS blocks it before prompting.
                // The file also carries the JVM's JIT + library-validation
                // entitlements (the app loads the Rust core/BLE dylibs at runtime).
                entitlementsFile.set(project.file("macos-entitlements.plist"))
                runtimeEntitlementsFile.set(project.file("macos-entitlements.plist"))
            }
        }
    }
}

// The jvm resources must carry the generated key file before packaging.
tasks.named("jvmProcessResources") { dependsOn(generateBreezKeyResource) }
tasks.named("compileKotlinJvm") { dependsOn(buildDesktopRustCore) }
tasks.named("jvmProcessResources") { dependsOn(buildDesktopRustCore) }
tasks.named("preBuild") { dependsOn(buildAndroidRustCore) }
tasks.matching { it.name == "check" }.configureEach { dependsOn(checkI18nStringsInSync) }

android {
    namespace = "chat.bitchat.sonar"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "chat.bitchat.sonar"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = 11
        versionName = "0.1-alpha.11"
        buildConfigField(
            "String",
            "BREEZ_API_KEY",
            "\"${escapeBuildConfigString(breezApiKey)}\"",
        )
        val lp = Properties().apply {
            val f = rootProject.file("local.properties")
            if (f.exists()) f.inputStream().use { load(it) }
        }
        // Push endpoints are non-secret committed defaults (public DNS host +
        // public npub) so every build registers a wakeup webhook. A peer with
        // an empty NDS_URL never registers one and can never be woken to answer
        // a payment. Override via local.properties for a private push stack.
        buildConfigField("String", "TRANSPONDER_NPUB",
            "\"${lp.getProperty("sonar.transponder.npub", "npub1606vwj2ztjw8vc9n4ljqgk8phmmq24r8ckt7l42sy97tte0nscqqfdj406")}\"")
        buildConfigField("String", "NDS_URL",
            "\"${lp.getProperty("sonar.nds.url", "https://nds.sonar.hedwig.sh")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        // MainActivity is a ComponentActivity and calls registerForActivityResult
        // directly (push-permission prompt + image picker). The fragment-version
        // check fires anyway via the transitive androidx.fragment dependency, but
        // we don't use the old FragmentActivity result path, so it's a false
        // positive. Don't let it fail the release (lintVitalRelease) build.
        disable += "InvalidFragmentVersionForActivityResult"
    }

    // The Rust core .so per ABI lives in src/androidMain/jniLibs (produced by
    // core/build-android.sh). Map it onto the Android main source set.
    sourceSets["main"].jniLibs.srcDirs("src/androidMain/jniLibs")
    // Android packages MP3 copies under src/androidMain/res/raw — NotificationPlayer
    // often fails silently on WAV files that carry LIST/INFO metadata chunks.
    // Desktop/JVM still loads the shared PCM WAVs from assets/notifications/raw.

    packaging {
        jniLibs {
            pickFirsts += listOf("lib/*/libc++_shared.so")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Optional release signing for sideload / Zapstore (SDK 35 needs v2+).
    // Never commit passwords. Set via env or apps/sonar/local.properties:
    //   SONAR_KEYSTORE / sonar.keystore
    //   SONAR_KEYSTORE_PASSWORD / sonar.keystore.password
    //   SONAR_KEY_ALIAS / sonar.key.alias
    //   SONAR_KEY_PASSWORD / sonar.key.password
    val lpSigning = Properties().apply {
        val f = rootProject.file("local.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    fun signProp(env: String, fileKey: String): String? =
        (System.getenv(env)?.takeIf { it.isNotBlank() }
            ?: lpSigning.getProperty(fileKey)?.takeIf { it.isNotBlank() })

    val releaseKeystorePath = signProp("SONAR_KEYSTORE", "sonar.keystore")
    val releaseKeystorePassword = signProp("SONAR_KEYSTORE_PASSWORD", "sonar.keystore.password")
    val releaseKeyAlias = signProp("SONAR_KEY_ALIAS", "sonar.key.alias")
    val releaseKeyPassword = signProp("SONAR_KEY_PASSWORD", "sonar.key.password")
    val hasReleaseSigning =
        !releaseKeystorePath.isNullOrBlank() &&
            !releaseKeystorePassword.isNullOrBlank() &&
            !releaseKeyAlias.isNullOrBlank() &&
            !releaseKeyPassword.isNullOrBlank() &&
            file(releaseKeystorePath!!).isFile

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Default release APK is phones only (arm64-v8a + armeabi-v7a).
            // Pass -Psonar.universalApk=true for a fat APK that also includes
            // x86/x86_64 emulator natives (Breez + Rust + JNA).
            val universal =
                (project.findProperty("sonar.universalApk") as String?)
                    ?.equals("true", ignoreCase = true) == true
            if (!universal) {
                ndk {
                    abiFilters += listOf("arm64-v8a", "armeabi-v7a")
                }
            }
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        getByName("debug") {
            // Local debug builds target arm64. CI passes
            // -Psonar.androidDebugAbi=x86_64 for its Linux emulator; keeping the
            // selection explicit avoids a multi-ABI APK overflowing small
            // emulator partitions.
            val debugAbi =
                (project.findProperty("sonar.androidDebugAbi") as String?)
                    ?.takeIf { it in setOf("arm64-v8a", "armeabi-v7a", "x86_64") }
                    ?: "arm64-v8a"
            ndk { abiFilters += debugAbi }
        }
    }
}

dependencies {
    // Firebase Cloud Messaging for push wakeups (transponder + Breez NDS).
    // platform() BOM isn't supported inside KMP's androidMain.dependencies {},
    // so Firebase goes through the standard Gradle dependencies block.
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    // Installs the baked Baseline Profile into ART on first run (API < 34
    // devices don't apply APK profiles at install time without it).
    implementation(libs.androidx.profileinstaller)
    baselineProfile(project(":baselineprofile"))
}

// Alpha / Zapstore phone APKs (and future Play AABs) must ship with a Breez key
// or every restore shows a dead Lightning wallet. Debug may omit the key for CI
// unit/UI tests.
//
// Use a shared prerequisite (not doFirst on assemble*) so packageRelease /
// installRelease fail *before* writing a keyless APK — assembleRelease's
// doFirst would otherwise run after packageRelease already produced the file.
val requireBreezApiKeyForRelease = tasks.register("requireBreezApiKeyForRelease") {
    group = "verification"
    description = "Fails when BREEZ_API_KEY is empty (release packaging must ship a live wallet)."
    doLast {
        check(breezApiKey.isNotEmpty()) {
            "BREEZ_API_KEY is empty — refusing release packaging. " +
                "Set breez.apiKey in apps/sonar/local.properties or export BREEZ_API_KEY."
        }
    }
}

tasks.matching {
    val n = it.name
    // Android phone APK/AAB paths only — not Compose Desktop packageReleaseDeb/Dmg/Msi.
    n.contains("Release", ignoreCase = true) && (
        n == "packageRelease" ||
            n == "packageReleaseUniversalApk" ||
            n == "packageReleaseBundle" ||
            n.startsWith("assemble") ||
            (n.startsWith("install") && !n.startsWith("uninstall")) ||
            (n.startsWith("bundle") && n.endsWith("Release") &&
                !n.contains("Classes") && !n.contains("Resources"))
        )
}.configureEach {
    dependsOn(requireBreezApiKeyForRelease)
}
