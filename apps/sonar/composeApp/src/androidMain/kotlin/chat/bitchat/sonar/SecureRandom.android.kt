package chat.bitchat.sonar

import java.security.SecureRandom

// Top-level vals are already initialized once under the JVM class-init lock;
// `by lazy` here would add a second Lazy indirection plus a synchronized read
// on every randomMeshId() call. SecureRandom itself is thread-safe.
private val rng = SecureRandom()

internal actual fun secureRandomBytes(count: Int): ByteArray =
    ByteArray(count).also { rng.nextBytes(it) }
