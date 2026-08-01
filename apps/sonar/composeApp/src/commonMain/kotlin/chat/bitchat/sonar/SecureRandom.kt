package chat.bitchat.sonar

/**
 * Cryptographically secure random bytes.
 *
 * `kotlin.random.Random` is a seeded, non-cryptographic generator (XorWow on
 * JVM, seeded once from the system clock). Its outputs are predictable to
 * anyone who observes enough of them — and mesh message ids *are* observed:
 * they go out on the wire. That makes it the wrong source for anything another
 * participant could try to guess or pre-empt, including the dedup keys the mesh
 * uses to decide a message has already been seen.
 *
 * iOS mints the same ids from `UUID()`, which is CSPRNG-backed. This is the
 * Compose side of that guarantee.
 *
 *  - androidMain → `java.security.SecureRandom`,
 *  - jvmMain (desktop) → `java.security.SecureRandom`.
 */
internal expect fun secureRandomBytes(count: Int): ByteArray

/** Lowercase hex over [count] CSPRNG bytes. `secureRandomHex(8)` → 16 chars. */
internal fun secureRandomHex(count: Int): String =
    secureRandomBytes(count).joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
