package chat.bitchat.sonar

// Desktop: ./gradlew :composeApp:run -Dsonar.transcript.spike.b=1
internal actual val sonarTranscriptSpikeBEnabled: Boolean =
    SonarTranscriptSpikeB.FORCE_ENABLE_IN_DEBUG ||
        System.getProperty(SonarTranscriptSpikeB.PROPERTY_KEY) == "1"

// Always offer the Settings entry on desktop so the isolated host is one tap away.
internal actual val sonarTranscriptSpikeBEntryVisible: Boolean = true
