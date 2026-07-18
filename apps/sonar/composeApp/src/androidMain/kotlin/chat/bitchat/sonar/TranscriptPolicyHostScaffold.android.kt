package chat.bitchat.sonar

/**
 * Phase 3 cutover: the owned-chrome transcript host is production default in
 * every build. Kill switches (fallback to the legacy sibling-composer shell):
 * env [SonarTranscriptPolicyHost.ENV_KEY]`=0` or property
 * [SonarTranscriptPolicyHost.PROPERTY_KEY]`=0`.
 */
internal actual val sonarTranscriptPolicyHostEnabled: Boolean =
    System.getenv(SonarTranscriptPolicyHost.ENV_KEY) != "0" &&
        System.getProperty(SonarTranscriptPolicyHost.PROPERTY_KEY) != "0"

internal actual val sonarTranscriptPolicyHostEntryVisible: Boolean = BuildConfig.DEBUG
