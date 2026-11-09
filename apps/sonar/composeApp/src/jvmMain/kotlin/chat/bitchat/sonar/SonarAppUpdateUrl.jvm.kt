package chat.bitchat.sonar

/** Desktop builds ship as GitHub release assets. */
actual fun sonarAppUpdateUrl(): String = SONAR_GITHUB_RELEASES_URL
