package chat.bitchat.sonar

import java.security.SecureRandom

private val rng by lazy { SecureRandom() }

internal actual fun secureRandomBytes(count: Int): ByteArray =
    ByteArray(count).also { rng.nextBytes(it) }
