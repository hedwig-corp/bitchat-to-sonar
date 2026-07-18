package chat.bitchat.sonar

/**
 * Spike B stays off in Release. In Debug, enable via
 * [SonarTranscriptSpikeB.FORCE_ENABLE_IN_DEBUG] or open the Settings host
 * (entry visible whenever [sonarTranscriptSpikeBEntryVisible] is true).
 *
 * JVM-style `-Dsonar.transcript.spike.b=1` is honored when present on the runtime.
 */
internal actual val sonarTranscriptSpikeBEnabled: Boolean =
    BuildConfig.DEBUG && (
        SonarTranscriptSpikeB.FORCE_ENABLE_IN_DEBUG ||
            System.getProperty(SonarTranscriptSpikeB.PROPERTY_KEY) == "1"
        )

internal actual val sonarTranscriptSpikeBEntryVisible: Boolean = BuildConfig.DEBUG

