package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Locks the shared invite-link formats so the emitted universal/deep links stay
 * parseable by MainActivity (`uri.fragment` / `uri.lastPathSegment`) and by the
 * Rust core's `normalize_invite_token`.
 */
class InviteShareTest {
    private val token = "sinvite1deadbeef"

    @Test fun universalLinkPutsTokenInFragment() {
        val link = inviteUniversalLink(token)
        assertEquals("https://$JOIN_LINK_HOST/join#$token", link)
        // The fragment (everything after '#') must be exactly the bare token.
        assertEquals(token, link.substringAfter('#'))
    }

    @Test fun deepLinkKeepsLegacyScheme() {
        assertEquals("sonar://invite/$token", inviteDeepLink(token))
    }

    @Test fun previewIsShortAndShowsHost() {
        val preview = inviteLinkPreview(token)
        assertTrue(preview.startsWith(JOIN_LINK_HOST), "preview should name the host: $preview")
        assertTrue(preview.length < 40, "preview should be short: $preview")
    }
}
