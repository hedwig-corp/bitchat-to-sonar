package chat.bitchat.sonar

import uniffi.sonar_ffi.SonarIdentity

/**
 * Android `actual`: call the Rust core through the UniFFI Kotlin bindings
 * (JNA over libsonar_ffi.so in src/androidMain/jniLibs).
 */
actual object SonarCore {
    actual fun generateNpub(): String {
        return SonarIdentity.generate().npub()
    }
}
