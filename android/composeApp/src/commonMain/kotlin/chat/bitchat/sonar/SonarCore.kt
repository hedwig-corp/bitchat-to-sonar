package chat.bitchat.sonar

/**
 * The shared boundary to the headless Rust core (`sonar-core`). UI in
 * `commonMain` calls this; each platform provides the `actual` binding:
 *  - androidMain → UniFFI Kotlin/JNA over the `.so` (issue #6 step 1),
 *  - iosMain (later) → Kotlin/Native call path (revisit at the iOS shift).
 *
 * This first version only exposes the smoke test; the real surface (identity,
 * Marmot, etc.) grows here as the app gains features.
 */
expect object SonarCore {
    /** Generate a fresh Nostr identity in the Rust core and return its npub. */
    fun generateNpub(): String
}
