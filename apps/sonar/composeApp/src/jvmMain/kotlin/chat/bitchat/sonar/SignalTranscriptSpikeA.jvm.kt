package chat.bitchat.sonar

internal actual fun signalTranscriptSpikeAPlatformEnabled(): Boolean =
    System.getenv(SignalTranscriptSpikeA.ENV_KEY) == "1" ||
        System.getProperty(SignalTranscriptSpikeA.PROPERTY_KEY) == "1"
