package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarSocialStateTest {
    @Test
    fun roundTripsSocialStateBlob() {
        val state = SonarSocialState()
            .withFavoritePeer("mesh:ABCDEF", true)
            .withRemoteFavoritePeer("abcdef", true)
            .withBlockedPeer("mesh:blocked", true)
            .withBlockedNostr("0".repeat(64), true)

        val decoded = decodeSonarSocialState(encodeSonarSocialState(state))

        assertTrue(decoded.isFavoritePeer("abcdef"))
        assertTrue(decoded.isMutualFavorite("abcdef"))
        assertTrue(decoded.isBlockedPeer("blocked"))
        assertTrue(decoded.isBlockedNostr("0".repeat(64)))
    }

    @Test
    fun ignoresMalformedRows() {
        val decoded = decodeSonarSocialState(
            """
            nope
            fav
            fav	peer-a
            blockNostr	not-a-key
            blockPeer	peer-b
            """.trimIndent()
        )

        assertTrue(decoded.isFavoritePeer("peer-a"))
        assertTrue(decoded.isBlockedPeer("peer-b"))
        assertFalse(decoded.isBlockedNostr("not-a-key"))
    }

    @Test
    fun channelSenderFilteringSupportsNostrAndMeshKeys() {
        val blockedNostr = "a".repeat(64)
        val state = SonarSocialState()
            .withBlockedNostr(blockedNostr, true)
            .withBlockedPeer("mesh-peer", true)

        assertFalse(state.allowsChannelSender(blockedNostr.uppercase(), mine = false))
        assertFalse(state.allowsChannelSender("mesh:mesh-peer", mine = false))
        assertTrue(state.allowsChannelSender(blockedNostr, mine = true))
        assertTrue(state.allowsChannelSender("other-peer", mine = false))
    }

    @Test
    fun chatMessageFilteringAllowsOwnMessagesButBlocksPeerAndNostrSenders() {
        val blockedNostr = "b".repeat(64)
        val state = SonarSocialState()
            .withBlockedPeer("peer-a", true)
            .withBlockedNostr(blockedNostr, true)

        assertFalse(state.allowsChatMessage("mesh:peer-a", "", mine = false))
        assertFalse(state.allowsChatMessage("chat", blockedNostr, mine = false))
        assertTrue(state.allowsChatMessage("mesh:peer-a", blockedNostr, mine = true))
        assertTrue(state.allowsChatMessage("chat", "c".repeat(64), mine = false))
    }

    @Test
    fun settingFavoriteAndRemoteFavoriteComputesMutualState() {
        var state = SonarSocialState()

        state = state.withFavoritePeer("peer-a", true)
        assertFalse(state.isMutualFavorite("peer-a"))

        state = state.withRemoteFavoritePeer("mesh:peer-a", true)
        assertTrue(state.isMutualFavorite("peer-a"))

        state = state.withFavoritePeer("peer-a", false)
        assertFalse(state.isMutualFavorite("peer-a"))
        assertTrue(state.remoteFavoritePeers.contains("peer-a"))
    }

    @Test
    fun normalizedNostrKeysRequireFullPublicKeys() {
        assertEquals("d".repeat(64), normalizeSocialNostrKey("0x" + "d".repeat(64)))
        assertEquals(null, normalizeSocialNostrKey("d".repeat(62)))
    }
}
