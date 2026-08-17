package chat.bitchat.sonar

private const val MAX_CRASH_REPORT_CHARS = 256 * 1024
private const val TRUNCATION_MARKER = "\n[TRUNCATED]\n"
private const val MAX_FIELD_CHARS = 2_048
// Bech32 secrets may be all-uppercase on the wire / in exception text.
private val diagnosticSecretPattern =
    Regex("""(?i)(nsec1|ncryptsec1)[a-z0-9]+""")

/**
 * Format the last uncaught exception for the shareable diagnostics bundle.
 * Kept in commonMain so redaction/truncation remain unit-testable even though
 * Android owns the process-level exception handler.
 *
 * Platform gap: iOS has no JVM uncaught-exception twin; Apple `.ips` / Xcode
 * Organizer remain the crash source of truth there. Follow-up is optional
 * last-exception breadcrumb in `SonarDiagnostics`, not a share-bundle rewrite.
 */
internal fun formatDiagnosticCrashReport(
    generatedAtMillis: Long,
    appVersion: String,
    sdk: String,
    device: String,
    processUptimeMillis: Long,
    threadName: String,
    breadcrumb: String?,
    throwableText: String,
): String {
    val headerBudget = 1_024
    val throwableBudget = (MAX_CRASH_REPORT_CHARS - headerBudget - TRUNCATION_MARKER.length)
        .coerceAtLeast(4_096)
    val boundedThrowable = throwableText.take(throwableBudget)
    val raw = buildString(capacity = (boundedThrowable.length + headerBudget).coerceAtMost(MAX_CRASH_REPORT_CHARS)) {
        appendLine("generated_at_millis=$generatedAtMillis")
        appendLine("app_version=${boundField(appVersion)}")
        appendLine("android_sdk=${boundField(sdk)}")
        appendLine("device=${boundField(device)}")
        appendLine("process_uptime_millis=$processUptimeMillis")
        appendLine("thread=${boundField(threadName)}")
        appendLine("last_breadcrumb=${boundField(breadcrumb ?: "none")}")
        appendLine()
        append(boundedThrowable)
    }
    val scrubbed = scrubDiagnosticSecrets(raw)
    if (scrubbed.length <= MAX_CRASH_REPORT_CHARS) return scrubbed
    val keep = MAX_CRASH_REPORT_CHARS - TRUNCATION_MARKER.length
    return scrubbed.take(keep) + TRUNCATION_MARKER
}

internal fun scrubDiagnosticSecrets(text: String): String =
    diagnosticSecretPattern.replace(text) { match ->
        "${match.groupValues[1].lowercase()}[REDACTED]"
    }

private fun boundField(value: String): String =
    if (value.length <= MAX_FIELD_CHARS) value else value.take(MAX_FIELD_CHARS) + "…"
