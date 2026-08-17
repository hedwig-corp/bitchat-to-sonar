package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CrashReportTest {
    @Test
    fun reportKeepsStackAndBreadcrumbButRedactsAccountKeys() {
        val report = formatDiagnosticCrashReport(
            generatedAtMillis = 123,
            appVersion = "0.1-test (1)",
            sdk = "35",
            device = "Test Phone",
            processUptimeMillis = 456,
            threadName = "main",
            breadcrumb = "transcript_open route=marmot rows=20 replies=1",
            throwableText = "java.lang.IllegalArgumentException: nsec1secret123\n\tat QuoteThenBody",
        )

        assertContains(report, "thread=main")
        assertContains(report, "last_breadcrumb=transcript_open route=marmot rows=20 replies=1")
        assertContains(report, "IllegalArgumentException")
        assertContains(report, "QuoteThenBody")
        assertContains(report, "nsec1[REDACTED]")
        assertFalse(report.contains("nsec1secret123"))
        assertFalse(report.contains("secret123"))
    }

    @Test
    fun reportRedactsUppercaseAndNcryptsecSecrets() {
        val report = formatDiagnosticCrashReport(
            generatedAtMillis = 123,
            appVersion = "test",
            sdk = "35",
            device = "Test Phone",
            processUptimeMillis = 456,
            threadName = "main",
            breadcrumb = null,
            throwableText = "boom NSEC1SECRETUPPER ncryptsec1abcxyz",
        )

        assertContains(report, "nsec1[REDACTED]")
        assertContains(report, "ncryptsec1[REDACTED]")
        assertFalse(report.contains("NSEC1SECRETUPPER"))
        assertFalse(report.contains("ncryptsec1abcxyz"))
        assertFalse(report.contains("SECRETUPPER"))
        assertFalse(report.contains("abcxyz"))
    }

    @Test
    fun reportIsBounded() {
        val report = formatDiagnosticCrashReport(
            generatedAtMillis = 123,
            appVersion = "test",
            sdk = "35",
            device = "Test Phone",
            processUptimeMillis = 456,
            threadName = "main",
            breadcrumb = "b".repeat(8_000),
            throwableText = "x".repeat(300_000),
        )

        assertTrue(report.length <= 256 * 1024)
        assertFalse(report.contains("x".repeat(260_000)))
        assertFalse(report.contains("b".repeat(3_000)))
    }
}
