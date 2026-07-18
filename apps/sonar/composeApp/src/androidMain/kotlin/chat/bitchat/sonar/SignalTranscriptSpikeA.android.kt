package chat.bitchat.sonar

internal actual fun signalTranscriptSpikeAPlatformEnabled(): Boolean {
    if (!BuildConfig.DEBUG) return false
    return System.getenv(SignalTranscriptSpikeA.ENV_KEY) == "1" ||
        System.getProperty(SignalTranscriptSpikeA.PROPERTY_KEY) == "1"
}
