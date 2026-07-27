package chat.bitchat.sonar

import chat.bitchat.sonar.push.isAcceptableNdsReplyUrl
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the reply-URL host pin — the only control between a forged NDS push and
 * a redirected BOLT12 invoice. Cases are the bypasses walked during review of
 * PR #295; the positive case is the real captured production URL.
 */
class NdsReplyUrlTest {

    private val host = "nds.sonar.hedwig.sh"

    private fun ok(raw: String) = isAcceptableNdsReplyUrl(raw, host)

    @Test
    fun acceptsTheRealCapturedReplyUrl() {
        assertTrue(ok("https://nds.sonar.hedwig.sh/api/v1/response/9087202477922764671"))
    }

    @Test
    fun acceptsExplicitDefaultPort() {
        assertTrue(ok("https://nds.sonar.hedwig.sh:443/api/v1/response/1"))
    }

    @Test
    fun rejectsPlainHttp() {
        assertFalse(ok("http://nds.sonar.hedwig.sh/api/v1/response/1"))
    }

    @Test
    fun rejectsUserinfoBeforeTheRealHost() {
        // `https://user@evil/` — parsed host is `evil`, and userinfo is present.
        assertFalse(ok("https://nds.sonar.hedwig.sh@evil.example/api/v1/response/1"))
        assertFalse(ok("https://user@nds.sonar.hedwig.sh/api/v1/response/1"))
    }

    @Test
    fun rejectsSuffixLookalikeHost() {
        // Would pass an endsWith() check; must fail an equals() check.
        assertFalse(ok("https://nds.sonar.hedwig.sh.evil.example/api/v1/response/1"))
        assertFalse(ok("https://evil.example/api/v1/response/1"))
    }

    @Test
    fun rejectsNonDefaultPortOnTheRealHost() {
        assertFalse(ok("https://nds.sonar.hedwig.sh:1234/api/v1/response/1"))
    }

    @Test
    fun rejectsPathOutsideTheResponsePrefix() {
        assertFalse(ok("https://nds.sonar.hedwig.sh/admin"))
        assertFalse(ok("https://nds.sonar.hedwig.sh/api/v1/notify"))
        assertFalse(ok("https://nds.sonar.hedwig.sh/"))
    }

    @Test
    fun rejectsDotSegmentTraversalOutOfThePrefix() {
        // java.net.URL does NOT normalize dot-segments (only URI.normalize does),
        // so without explicit normalization this passes the prefix check.
        assertFalse(ok("https://nds.sonar.hedwig.sh/api/v1/response/../../admin"))
        assertFalse(ok("https://nds.sonar.hedwig.sh/api/v1/response/../admin"))
    }

    @Test
    fun rejectsPercentEncodedTraversal() {
        // Survives normalization here and re-appears once the NDS decodes.
        assertFalse(ok("https://nds.sonar.hedwig.sh/api/v1/response/..%2f..%2fadmin"))
        assertFalse(ok("https://nds.sonar.hedwig.sh/api/v1/response/%2e%2e/admin"))
    }

    @Test
    fun keepsAcceptingAPlainNumericRequestId() {
        // Guard against the traversal rules over-rejecting the real shape.
        assertTrue(ok("https://nds.sonar.hedwig.sh/api/v1/response/9674711774637014390"))
    }

    @Test
    fun rejectsGarbageAndEmpty() {
        assertFalse(ok(""))
        assertFalse(ok("not a url"))
        assertFalse(ok("ftp://nds.sonar.hedwig.sh/api/v1/response/1"))
    }

    @Test
    fun hostComparisonIsCaseInsensitive() {
        assertTrue(ok("https://NDS.Sonar.Hedwig.SH/api/v1/response/1"))
    }
}
