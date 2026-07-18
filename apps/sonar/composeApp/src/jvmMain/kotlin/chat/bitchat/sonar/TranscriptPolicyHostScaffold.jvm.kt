package chat.bitchat.sonar

// Phase 3 cutover: default ON. Fall back to the legacy shell with
// `./gradlew :composeApp:run -Dsonar.transcript.policy.host=0`
// or `SONAR_TRANSCRIPT_PHASE2_HOST=0`.
internal actual val sonarTranscriptPolicyHostEnabled: Boolean =
    System.getenv(SonarTranscriptPolicyHost.ENV_KEY) != "0" &&
        System.getProperty(SonarTranscriptPolicyHost.PROPERTY_KEY) != "0"

internal actual val sonarTranscriptPolicyHostEntryVisible: Boolean = true
