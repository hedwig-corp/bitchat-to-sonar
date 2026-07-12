package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Fast end-to-end projections of the conversation-list regressions that have
 * escaped manual testing: wrong sender, rotating aliases, duplicate direct
 * groups, cold-start hydration, and post-receive ordering. */
class ConversationRegressionSmokeTest {
    private val ownNpubHex = "01".repeat(32)
    private val saraNpubHex = "02".repeat(32)
    private val vincenzoNpubHex = "03".repeat(32)

    private val persistedLinks = linkedMapOf(
        "fp-vincenzo" to vincenzoNpubHex,
        "fp-vincenzo-mac" to vincenzoNpubHex,
        "fp-sara" to saraNpubHex,
    )

    private fun npub(hex: String): String = chat.bitchat.sonar.crypto.Bech32.encode(
        "npub",
        hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
    )!!

    private fun chat(id: String, peerNpubHex: String) = SonarChat(
        id = id,
        name = "",
        members = listOf(npub(ownNpubHex), npub(peerNpubHex)),
    )

    @Test
    fun saraMessageCannotRouteIntoVincenzoConversation() {
        val liveLinks = mapOf(
            "fp-vincenzo-mac" to vincenzoNpubHex,
            "fp-sara" to saraNpubHex,
        )

        val target = resolvePeerIdForNpubHex(
            senderNpubHex = saraNpubHex.uppercase(),
            livePeerIds = liveLinks.keys,
            liveNpubHexForPeer = liveLinks::get,
            persistedNpubHexByPeer = persistedLinks,
        )

        assertEquals("fp-sara", target)
        assertTrue(peerNpubHexMatchesLinkedPeer(saraNpubHex, persistedLinks[target]))
        assertFalse(peerNpubHexMatchesLinkedPeer(saraNpubHex, persistedLinks["fp-vincenzo-mac"]))

        // The same route must survive a process restart before BLE announces
        // repopulate the live profile map.
        assertEquals(
            "fp-sara",
            resolvePeerIdForNpubHex(
                senderNpubHex = saraNpubHex,
                livePeerIds = emptyList(),
                liveNpubHexForPeer = { null },
                persistedNpubHexByPeer = persistedLinks,
            ),
        )
    }

    @Test
    fun rotatingVincenzoAliasesCollapseWithoutAbsorbingSara() {
        val groups = groupMeshPeerIdsByIdentity(persistedLinks.keys, persistedLinks)
            .map { it.toSet() }
            .toSet()

        assertEquals(
            setOf(
                setOf("fp-vincenzo", "fp-vincenzo-mac"),
                setOf("fp-sara"),
            ),
            groups,
        )
    }

    @Test
    fun duplicateSaraGroupsKeepOneNewestTranscript() {
        val oldSara = chat("sara-old", saraNpubHex)
        val newSara = chat("sara-new", saraNpubHex)
        val vincenzo = chat("vincenzo", vincenzoNpubHex)

        val visible = dedupeDirectMarmotChats(
            chats = listOf(oldSara, vincenzo, newSara),
            ownNpub = npub(ownNpubHex),
            latestSecs = mapOf(
                oldSara.id to 100L,
                vincenzo.id to 200L,
                newSara.id to 300L,
            )::getValue,
        )

        assertEquals(listOf(vincenzo, newSara), visible)
    }

    @Test
    fun coldRestartPaintsPersistedOrderThenNewSaraMessageMovesOnlySara() {
        val sara = chat("sara", saraNpubHex)
        val vincenzo = chat("vincenzo", vincenzoNpubHex)
        val snapshot = encodeChatSnapshot(
            chats = listOf(vincenzo, sara),
            messagesByChat = emptyMap(),
            latestByChat = mapOf(vincenzo.id to 200L, sara.id to 100L),
        )
        val restored = decodeChatSnapshot(snapshot).first
        val restoredLatest = decodeChatSnapshotLatest(snapshot)

        val firstPaint = orderChatsByLocalRecency(
            chats = restored,
            latestSecs = restoredLatest::getValue,
            previousOrder = listOf("vincenzo", "sara"),
        )
        assertEquals(listOf("vincenzo", "sara"), firstPaint.map { it.id })

        val afterGoodMorning = orderChatsByLocalRecency(
            chats = restored,
            latestSecs = { if (it == sara.id) 300L else restoredLatest.getValue(it) },
            previousOrder = firstPaint.map { it.id },
        )
        assertEquals(listOf("sara", "vincenzo"), afterGoodMorning.map { it.id })
        assertEquals(
            "Sara D",
            homeListTitleForFoldedMeshRow(
                directMarmotTitle = "Sara D",
                meshDerivedName = "Vincenzo-Mac",
            ),
        )
    }
}
