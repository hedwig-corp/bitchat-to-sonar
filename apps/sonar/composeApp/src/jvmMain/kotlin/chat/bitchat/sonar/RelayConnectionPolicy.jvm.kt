package chat.bitchat.sonar

/** Desktop window focus is not OS socket suspension. */
internal actual fun platformShouldInvalidateRelayOnBackground(): Boolean = false
