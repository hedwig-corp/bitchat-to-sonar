package chat.bitchat.sonar

/** Release builds must ignore test `forceEnabled` latches. */
internal actual val sonarDebugForceFlagsAllowed: Boolean = BuildConfig.DEBUG
