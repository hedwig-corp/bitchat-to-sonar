package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConversationFoldTest {
    @Test
    fun foldedDirectDmTitleComesFromMarmotCounterpart() {
        assertEquals(
            "Sara D",
            homeListTitleForFoldedMeshRow(
                directMarmotTitle = "Sara D",
                meshDerivedName = "Wrong BLE Name",
            ),
        )
    }

    @Test
    fun meshOnlyConversationKeepsMeshDerivedTitle() {
        assertEquals(
            "Nearby Peer",
            homeListTitleForFoldedMeshRow(
                directMarmotTitle = null,
                meshDerivedName = "Nearby Peer",
            ),
        )
    }

    @Test
    fun foldIdentityRequiresMatchingNpub() {
        val sara = "ab".repeat(32)

        assertTrue(peerNpubHexMatchesLinkedPeer(sara, sara.uppercase()))
        assertFalse(peerNpubHexMatchesLinkedPeer(sara, "cd".repeat(32)))
        assertFalse(peerNpubHexMatchesLinkedPeer(sara, null))
    }

    @Test
    fun rotatedMeshAliasesStillMatchTheActiveConversation() {
        val npub = "ab".repeat(32)
        val links = mapOf("old-fingerprint" to npub, "new-fingerprint" to npub.uppercase())

        assertTrue(sameMeshConversationIdentity("old-fingerprint", "new-fingerprint", links))
        assertFalse(
            sameMeshConversationIdentity(
                "old-fingerprint",
                "different-peer",
                links + ("different-peer" to "cd".repeat(32)),
            ),
        )
    }

    @Test
    fun restrictedBlePolicyIgnoresDiscoveryOnlyLinks() {
        val discoveryOnlyPeerIds = setOf("STRANGER")
        val allowed = knownBlePeerIdsForPolicy(
            meshChatPeerIds = listOf("KNOWN"),
            persistedFoldPeerIds = listOf("FOLDED"),
            liveFoldPeerIds = listOf("LIVE"),
        )

        assertEquals(setOf("known", "folded", "live"), allowed)
        discoveryOnlyPeerIds.forEach { assertFalse(it.lowercase() in allowed) }
    }

    @Test
    fun freshPeerWithoutProfileWaitsForCapabilitySettleWindow() {
        assertEquals(
            true,
            shouldWaitForCapabilities(
                firstSeenMs = 1_000,
                nowMs = 2_000,
                hasProfile = false,
                hasMessages = false,
            ),
        )
    }

    @Test
    fun settledPeerWithoutProfileDoesNotWait() {
        assertEquals(
            false,
            shouldWaitForCapabilities(
                firstSeenMs = 1_000,
                nowMs = 3_000,
                hasProfile = false,
                hasMessages = false,
            ),
        )
    }

    @Test
    fun profileOrMessagesBypassCapabilityWait() {
        assertEquals(
            false,
            shouldWaitForCapabilities(
                firstSeenMs = 1_000,
                nowMs = 2_000,
                hasProfile = true,
                hasMessages = false,
            ),
        )
        assertEquals(
            false,
            shouldWaitForCapabilities(
                firstSeenMs = 1_000,
                nowMs = 2_000,
                hasProfile = false,
                hasMessages = true,
            ),
        )
    }

    @Test
    fun recentMarmotActivityIsBoundedToSettleWindow() {
        assertEquals(
            true,
            hasRecentMarmotActivityForCapabilitySettle(
                latestMessageTsSecs = 1,
                nowMs = 2_000,
            ),
        )
        assertEquals(
            false,
            hasRecentMarmotActivityForCapabilitySettle(
                latestMessageTsSecs = 1,
                nowMs = 3_000,
            ),
        )
        assertEquals(
            false,
            hasRecentMarmotActivityForCapabilitySettle(
                latestMessageTsSecs = null,
                nowMs = 2_000,
            ),
        )
        assertEquals(
            true,
            hasRecentMarmotActivityForCapabilitySettle(
                latestMessageTsSecs = 3,
                nowMs = 2_000,
            ),
        )
        assertEquals(
            false,
            hasRecentMarmotActivityForCapabilitySettle(
                latestMessageTsSecs = 10,
                nowMs = 2_000,
            ),
        )
    }

    @Test
    fun profileCacheRoundTripsDisplayName() {
        val encoded = encodeProfileCache(
            mapOf(
                "npub1vincent" to SonarProfile(
                    name = "vincent",
                    displayName = "Vincent",
                    about = "hello\nthere",
                    picture = null,
                    nip05 = null,
                ),
            ),
        )

        val decoded = decodeProfileCache(encoded)

        assertEquals("Vincent", decoded["npub1vincent"]?.bestName)
        assertEquals("hello\nthere", decoded["npub1vincent"]?.about)
        assertNull(decoded["npub1vincent"]?.picture)
    }

    @Test
    fun profileCacheCanonicalizesHexPubkeyToNpub() {
        val raw = ByteArray(32) { it.toByte() }
        val hex = raw.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        val npub = chat.bitchat.sonar.crypto.Bech32.encode("npub", raw)!!
        val encoded = encodeProfileCache(
            mapOf(
                hex to SonarProfile(
                    name = null,
                    displayName = "Sara D",
                    about = null,
                    picture = null,
                    nip05 = null,
                ),
            ),
        )

        val decoded = decodeProfileCache(encoded)

        assertEquals("Sara D", decoded[npub]?.bestName)
        assertNull(decoded[hex])
        assertEquals(npub, canonicalProfileKey(hex))
    }

    @Test
    fun profileCacheLookupResolvesGroupAuthorName() {
        val senderNpub = "npub1vincent"
        val profilesByNpub = decodeProfileCache(
            encodeProfileCache(
                mapOf(
                    senderNpub to SonarProfile(
                        name = "vincent",
                        displayName = "Vincent P",
                        about = null,
                        picture = null,
                        nip05 = null,
                    ),
                ),
            ),
        )
        val fetched = mutableListOf<String>()
        val message = SonarMsg(
            id = "msg-1",
            senderNpub = senderNpub,
            content = "hello",
            mine = false,
            tsSecs = 42,
        )

        val resolved = resolveGroupAuthorName(
            message = message,
            isGroup = true,
            profilesByNpub = profilesByNpub,
            fetchMissingProfile = { fetched += it },
        )

        assertEquals("Vincent P", resolved)
        assertEquals(emptyList(), fetched)
    }

    @Test
    fun profileCacheMissFetchesGroupAuthorProfileAndFallsBack() {
        val senderNpub = "npub1sender1234567890"
        val profilesByNpub = decodeProfileCache(
            encodeProfileCache(
                mapOf(
                    "npub1alice" to SonarProfile(
                        name = "Alice",
                        displayName = null,
                        about = null,
                        picture = null,
                        nip05 = null,
                    ),
                ),
            ),
        )
        val fetched = mutableListOf<String>()
        val message = SonarMsg(
            id = "msg-1",
            senderNpub = senderNpub,
            content = "hello",
            mine = false,
            tsSecs = 42,
        )

        val resolved = resolveGroupAuthorName(
            message = message,
            isGroup = true,
            profilesByNpub = profilesByNpub,
            fetchMissingProfile = { fetched += it },
        )

        assertEquals(shortNpubLabel(senderNpub), resolved)
        assertEquals(listOf(senderNpub), fetched)
    }

    @Test
    fun malformedProfileCacheRowsAreIgnored() {
        val decoded = decodeProfileCache("not-a-valid-row\n")

        assertEquals(emptyMap(), decoded)
    }

    @Test
    fun chatSnapshotKeepsRowsWithoutPersistingMessages() {
        val newest = SonarChat("group-z", "", listOf("npub1sara", "npub1me"))
        val older = SonarChat("group-a", "", listOf("npub1bob", "npub1me"))
        val messages = listOf(
            SonarMsg(
                id = "msg-1",
                senderNpub = "npub1sara",
                content = "hello",
                mine = false,
                tsSecs = 42,
                viaInternet = true,
                media = listOf(SonarMedia("pending-url", "image/png", "photo.png", 640, 480, null)),
                state = null,
            ),
        )

        val decoded = decodeChatSnapshot(
            encodeChatSnapshot(listOf(newest, older), mapOf(newest.id to messages)),
        )

        // The snapshot keeps the last local recency order instead of sorting by
        // opaque group id, while still excluding plaintext message content.
        assertEquals(listOf(newest, older), decoded.first)
        assertEquals(emptyMap(), decoded.second)
        assertEquals(mapOf(newest.id to 42L), decodeChatSnapshotLatest(
            encodeChatSnapshot(listOf(newest, older), mapOf(newest.id to messages)),
        ))
    }

    @Test
    fun chatSnapshotPreservesRecoveredRoomIsDirect() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf(ownNpub, peerNpub))
        val pendingRoom = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf(ownNpub, peerNpub),
            isDirect = false,
        )

        val decoded = decodeChatSnapshot(
            encodeChatSnapshot(listOf(dm, pendingRoom), emptyMap(), mapOf(dm.id to 2L, pendingRoom.id to 1L)),
        ).first

        assertEquals(listOf(true, false), decoded.map { it.isDirect })
        assertEquals(listOf(dm, pendingRoom), decoded)
        assertEquals(null, directMarmotPeerKey(decoded[1], ownNpub))
        assertEquals(
            listOf(dm, pendingRoom),
            dedupeDirectMarmotChats(
                chats = decoded,
                ownNpub = ownNpub,
                latestSecs = { if (it == dm.id) 2L else 1L },
            ),
        )
        assertEquals(
            mapOf(dm.id to 2L, pendingRoom.id to 1L),
            decodeChatSnapshotLatest(
                encodeChatSnapshot(listOf(dm, pendingRoom), emptyMap(), mapOf(dm.id to 2L, pendingRoom.id to 1L)),
            ),
        )
    }

    @Test
    fun legacyChatSnapshotWithoutIsDirectDefaultsToDirect() {
        val room = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf("npub1me", "npub1bob"),
            isDirect = false,
        )
        val modern = encodeChatSnapshot(listOf(room), emptyMap(), mapOf(room.id to 9L)).trimEnd()
        val legacy = modern.removeSuffix("\t0")

        val decoded = decodeChatSnapshot(legacy).first.single()
        assertTrue(decoded.isDirect)
        assertEquals(room.id, decoded.id)
        assertEquals(room.name, decoded.name)
        assertEquals(mapOf(room.id to 9L), decodeChatSnapshotLatest(legacy))
    }

    @Test
    fun directMarmotPeerKeyCanonicalizesHexAndNpub() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val peerHex = peerRaw.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        val chat = SonarChat(id = "group-a", name = "", members = listOf(ownNpub, peerHex))

        assertEquals(peerNpub, directMarmotPeerKey(chat, ownNpub))
    }

    @Test
    fun duplicateDirectMarmotChatsRenderOnceByCanonicalPeer() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val peerHex = peerRaw.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        val older = SonarChat(id = "group-old", name = "", members = listOf(ownNpub, peerNpub))
        val newer = SonarChat(id = "group-new", name = "", members = listOf(ownNpub, peerHex))
        val room = SonarChat(id = "group-room", name = "room", members = listOf(ownNpub, peerNpub, "npub1third"))

        val visible = dedupeDirectMarmotChats(
            chats = listOf(older, newer, room),
            ownNpub = ownNpub,
            latestSecs = { if (it == newer.id) 2L else 1L },
        )

        assertEquals(listOf(newer, room), visible)
    }

    @Test
    fun recoveredAndResumedDirectChatsRenderOnceByPeer() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val historical = SonarChat(id = "group-08", name = "alice & bob", members = listOf(ownNpub, peerNpub))
        val live = SonarChat(id = "group-09", name = "alice & bob", members = listOf(ownNpub, peerNpub))

        val visible = dedupeDirectMarmotChats(
            chats = listOf(historical, live),
            ownNpub = ownNpub,
            latestSecs = { if (it == live.id) 2L else 1L },
        )

        assertEquals(listOf(live), visible)
        assertEquals(
            live.id,
            marmotSendTargetGroupId(
                openChatId = historical.id,
                duplicateGroupIds = listOf(historical.id, live.id),
                latestSecs = { if (it == live.id) 2L else 1L },
            ),
        )
    }

    @Test
    fun recoveredRoomWithOneKnownPeerDoesNotFoldOntoDirect() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf(ownNpub, peerNpub))
        val pendingRoom = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf(ownNpub, peerNpub),
            isDirect = false,
        )

        val visible = dedupeDirectMarmotChats(
            chats = listOf(dm, pendingRoom),
            ownNpub = ownNpub,
            latestSecs = { if (it == dm.id) 2L else 1L },
        )

        assertEquals(listOf(dm, pendingRoom), visible)
        assertEquals(null, directMarmotPeerKey(pendingRoom, ownNpub))
        assertEquals(
            chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw),
            directMarmotPeerKey(dm, ownNpub),
        )
        assertEquals(dm.id, directMarmotChatIdForPeer(listOf(pendingRoom, dm), ownNpub, peerNpub))
        assertEquals("pending room", marmotNotificationGroupName(pendingRoom))
        assertEquals(null, marmotNotificationGroupName(dm))
    }

    @Test
    fun recoveredChatWaitsForPeerUpdateUntilLiveSiblingExists() {
        assertEquals(
            RecoveredChatResumeUi.WaitingForPeerUpdate,
            recoveredChatResumeUi(hasLiveFoldSibling = false, keyPackageMissing = true),
        )
        assertEquals(
            RecoveredChatResumeUi.Live,
            recoveredChatResumeUi(hasLiveFoldSibling = true, keyPackageMissing = true),
        )
        assertEquals(
            RecoveredChatResumeUi.Live,
            recoveredChatResumeUi(hasLiveFoldSibling = false, keyPackageMissing = false),
        )
        assertTrue(marmotSendNeedsPeerUpdate("no key package found on relays for npub1abc"))
        assertEquals(
            "Waiting for them to update Sonar",
            marmotSendUserMessage("no key package found on relays for npub1abc"),
        )
        assertTrue(
            recoveredLegacyMediaUnavailable(
                "encrypted media error: this attachment is from an older Sonar and cannot be opened after the update",
            ),
        )
        assertFalse(recoveredLegacyMediaUnavailable("hash verification failed"))
        assertFalse(
            recoveredLegacyMediaUnavailable("error sending request for url (https://127.0.0.1:1/old.bin)"),
        )
        assertEquals(
            "This attachment is from an older Sonar and can't be opened after the update.",
            RECOVERED_LEGACY_MEDIA_COPY,
        )
    }

    @Test
    fun meshFingerprintsLinkedToSameNpubFormOneConversation() {
        val sharedNpubHex = "ab".repeat(32)
        val groups = groupMeshPeerIdsByIdentity(
            peerIds = listOf("fp-old", "fp-current", "fp-other"),
            linkedNpubByPeer = mapOf(
                "fp-old" to sharedNpubHex.uppercase(),
                "fp-current" to sharedNpubHex,
                "fp-other" to "cd".repeat(32),
            ),
        )

        assertEquals(
            setOf(setOf("fp-old", "fp-current"), setOf("fp-other")),
            groups.map { it.toSet() }.toSet(),
        )
    }

    @Test
    fun persistedFoldTargetKeepsCanonicalMeshRowStable() {
        assertEquals(
            "fp-current",
            selectCanonicalMeshPeerId(
                aliases = listOf("fp-old", "fp-current", "fp-new"),
                persistedFoldPeerIds = setOf("fp-current"),
            ),
        )
        assertEquals(
            "fp-new",
            selectCanonicalMeshPeerId(
                aliases = listOf("fp-old", "fp-new"),
                persistedFoldPeerIds = emptySet(),
            ),
        )
    }

    @Test
    fun persistedAliasOutsideMessageKeysStillOwnsConversationRow() {
        val sharedNpubHex = "ef".repeat(32)
        val aliases = groupMeshConversationAliases(
            knownPeerIds = listOf("fp-with-messages", "fp-persisted-fold", "fp-current"),
            peerIdsWithMessages = setOf("fp-with-messages"),
            linkedNpubByPeer = mapOf(
                "fp-with-messages" to sharedNpubHex,
                "fp-persisted-fold" to sharedNpubHex,
                "fp-current" to sharedNpubHex,
            ),
        ).single()

        assertEquals(
            "fp-persisted-fold",
            selectCanonicalMeshPeerId(aliases, setOf("fp-persisted-fold")),
        )
    }

    @Test
    fun liveAliasIsPreferredForTransportAndCapabilityLookup() {
        assertEquals(
            listOf("fp-live", "fp-canonical", "fp-old"),
            orderMeshAliasesByLiveRoute(
                aliases = listOf("fp-old", "fp-live", "fp-canonical"),
                livePeerId = "fp-live",
            ),
        )
        assertEquals(
            listOf("fp-canonical", "fp-old"),
            orderMeshAliasesByLiveRoute(
                aliases = listOf("fp-old", "fp-canonical"),
                livePeerId = null,
            ),
        )
    }

    @Test
    fun rotatedAliasSuppliesMarmotAndSplitFavoriteRoutingCapabilities() {
        val aliases = listOf("fp-canonical", "fp-live")

        assertTrue(
            aliasesSupportMarmotRoute(
                aliases = aliases,
                hasSonarProfile = { it == "fp-live" },
                capabilitiesForAlias = { 0 },
            ),
        )
        assertTrue(
            aliasesSupportMarmotRoute(
                aliases = aliases,
                hasSonarProfile = { false },
                capabilitiesForAlias = { if (it == "fp-live") SonarAnnounce.CAP_MARMOT else 0 },
            ),
        )
        assertTrue(
            aliasesHaveMutualFavorite(
                aliases = aliases,
                isFavorite = { it == "fp-canonical" },
                isRemoteFavorite = { it == "fp-live" },
            ),
        )
        assertFalse(
            aliasesHaveMutualFavorite(
                aliases = aliases,
                isFavorite = { it == "fp-canonical" },
                isRemoteFavorite = { false },
            ),
        )
        assertFalse(
            aliasesHaveMutualFavorite(
                aliases = aliases,
                isFavorite = { false },
                isRemoteFavorite = { it == "fp-live" },
            ),
        )
    }

    @Test
    fun openFoldedConversationRefreshesWhenAnyAliasIsTouched() {
        val aliases = setOf("fp-canonical", "fp-live")

        assertTrue(meshAliasGroupWasTouched(aliases, setOf("fp-live")))
        assertTrue(meshAliasGroupWasTouched(aliases, setOf("fp-canonical")))
        assertFalse(meshAliasGroupWasTouched(aliases, setOf("fp-other")))
        assertFalse(meshAliasGroupWasTouched(emptySet(), setOf("fp-live")))
    }

    @Test
    fun anyAliasOrSharedNpubBlocksFoldedConversation() {
        val aliases = setOf("fp-canonical", "fp-live")
        val linked = aliases.associateWith { "ab".repeat(32) }

        assertTrue(
            isMeshAliasGroupBlocked(
                aliases,
                isPeerBlocked = { it == "fp-live" },
                linkedNpubHex = linked::get,
                isNpubBlocked = { false },
            ),
        )
        assertTrue(
            isMeshAliasGroupBlocked(
                aliases + "fp-later",
                isPeerBlocked = { false },
                linkedNpubHex = { linked[it] ?: "ab".repeat(32) },
                isNpubBlocked = { it == "ab".repeat(32) },
            ),
        )
        assertFalse(
            isMeshAliasGroupBlocked(
                aliases,
                isPeerBlocked = { false },
                linkedNpubHex = linked::get,
                isNpubBlocked = { false },
            ),
        )
    }
}
