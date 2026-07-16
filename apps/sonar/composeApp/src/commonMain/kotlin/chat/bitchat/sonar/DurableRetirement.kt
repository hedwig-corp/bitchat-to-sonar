package chat.bitchat.sonar

/**
 * Shared fail-closed sequencing for a filesystem tree retirement.
 *
 * Platform implementations own the rename/delete details and their directory
 * barriers. This helper makes it impossible to run cleanup after an uncommitted
 * quarantine or to report success without an authoritative absence proof.
 */
internal inline fun completeDurableRetirement(
    quarantine: () -> Boolean,
    cleanup: () -> Boolean,
    proveAbsent: () -> Boolean,
): Boolean = try {
    quarantine() && cleanup() && proveAbsent()
} catch (_: Throwable) {
    false
}
