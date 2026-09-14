package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.SonarPaymentActivity
import chat.bitchat.sonar.wallet.remountedPaymentActivities
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
        val newest = SonarChat("group-z", "", listOf("npub1sara", "npub1me"), isDirect = true)
        val older = SonarChat("group-a", "", listOf("npub1bob", "npub1me"), isDirect = true)
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
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf(ownNpub, peerNpub), isDirect = true)
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
    fun legacyChatSnapshotWithoutIsDirectDoesNotFoldAsDirect() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val room = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf(ownNpub, peerNpub),
            isDirect = false,
        )
        val modern = encodeChatSnapshot(listOf(room), emptyMap(), mapOf(room.id to 9L)).trimEnd()
        val legacy = modern.removeSuffix("\t0")

        val decoded = decodeChatSnapshot(legacy).first.single()
        assertFalse(decoded.isDirect)
        assertEquals(room.id, decoded.id)
        assertEquals(room.name, decoded.name)
        assertEquals(null, directMarmotPeerKey(decoded, ownNpub))
        assertEquals(mapOf(room.id to 9L), decodeChatSnapshotLatest(legacy))
    }

    @Test
    fun startupSnapshotRewriteDoesNotStampInventedIsDirect() {
        val room = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf("npub1me", "npub1bob"),
            isDirect = false,
        )
        val stripped = encodeChatSnapshot(
            listOf(room),
            emptyMap(),
            mapOf(room.id to 9L),
            includeIsDirect = false,
        ).trimEnd()

        assertFalse(stripped.endsWith("\t0") || stripped.endsWith("\t1"))
        val decoded = decodeChatSnapshot(stripped).first.single()
        assertFalse(decoded.isDirect)
        assertEquals(mapOf(room.id to 9L), decodeChatSnapshotLatest(stripped))
        assertFalse(chatSnapshotNeedsMetadataRewrite(stripped))
        assertFalse(chatSnapshotHasIsDirect(stripped))
    }

    @Test
    fun modernSnapshotDoesNotNeedStartupRewrite() {
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf("npub1me", "npub1bob"), isDirect = true)
        val room = SonarChat(
            id = "pending-room",
            name = "pending room",
            members = listOf("npub1me", "npub1bob"),
            isDirect = false,
        )
        val modern = encodeChatSnapshot(listOf(dm, room), emptyMap(), mapOf(dm.id to 2L, room.id to 1L))
        assertFalse(chatSnapshotNeedsMetadataRewrite(modern))
        assertTrue(chatSnapshotHasIsDirect(modern))
        assertFalse(chatSnapshotNeedsMetadataRewrite("c\tid\tname\t\t0\n"))
        assertTrue(chatSnapshotNeedsMetadataRewrite("c\tid\tname\t\t0\nm\told-body\n"))
    }

    @Test
    fun directMarmotPeerKeyCanonicalizesHexAndNpub() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val peerHex = peerRaw.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        val chat = SonarChat(id = "group-a", name = "", members = listOf(ownNpub, peerHex), isDirect = true)

        assertEquals(peerNpub, directMarmotPeerKey(chat, ownNpub))
    }

    @Test
    fun duplicateDirectMarmotChatsRenderOnceByCanonicalPeer() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val peerHex = peerRaw.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        val older = SonarChat(id = "group-old", name = "", members = listOf(ownNpub, peerNpub), isDirect = true)
        val newer = SonarChat(id = "group-new", name = "", members = listOf(ownNpub, peerHex), isDirect = true)
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
        val historical = SonarChat(id = "group-08", name = "alice & bob", members = listOf(ownNpub, peerNpub), isDirect = true)
        val live = SonarChat(id = "group-09", name = "alice & bob", members = listOf(ownNpub, peerNpub), isDirect = true)

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
    fun foldedOpenUnreadAndTranscriptWindowRemountOntoLiveSibling() {
        assertEquals(
            mapOf("group-08" to 3L, "group-09" to 3L),
            remountFoldedOpenValues(
                historicalKeys = listOf("group-08"),
                liveKeys = listOf("group-09"),
                values = mapOf("group-08" to 3L),
            ),
        )
        assertEquals(
            mapOf("group-08" to 3L, "group-09" to 1L),
            remountFoldedOpenValues(
                historicalKeys = listOf("group-08"),
                liveKeys = listOf("group-09"),
                values = mapOf("group-08" to 3L, "group-09" to 1L),
            ),
        )
        assertEquals(
            mapOf("group-08" to 3L, "group-09" to 3L),
            remountFoldedOpenValues(
                historicalKeys = listOf("group-08"),
                liveKeys = listOf("group-09"),
                values = mapOf("group-08" to 3L, "group-09" to 0L),
                preferExisting = { it > 0L },
            ),
        )
        val historicalRows = listOf("old-1", "old-2")
        assertEquals(
            mapOf("group-08" to historicalRows, "group-09" to historicalRows),
            remountFoldedOpenValues(
                historicalKeys = listOf("group-08"),
                liveKeys = listOf("group-09"),
                values = mapOf("group-08" to historicalRows),
                preferExisting = { it.isNotEmpty() },
            ),
        )
        assertEquals(
            listOf("already-live", "old-1", "old-2"),
            mergedFoldedMessageLists(
                historicalRows,
                listOf("already-live"),
            ) { it },
        )
        assertEquals(
            listOf("shared", "new-1", "old-1"),
            mergedFoldedMessageLists(
                listOf("old-1", "shared"),
                listOf("shared", "new-1"),
            ) { it },
        )
        assertEquals("group-09", remountFoldedOpenId(listOf("group-08"), "group-09", "group-08"))
        assertEquals("other", remountFoldedOpenId(listOf("group-08"), "group-09", "other"))
    }

    @Test
    fun foldedHistoricalRoomRemountsOntoLiveSibling() {
        val listed = setOf("group-09")
        assertEquals(
            "group-09",
            remountFoldedOpenChatId(
                openChatId = "group-08",
                listedChatIds = listed,
                liveFoldTarget = "group-09",
            ),
        )
        assertEquals(
            "group-09",
            remountFoldedOpenChatId(
                openChatId = "group-09",
                listedChatIds = listed,
                liveFoldTarget = "group-09",
            ),
        )
        assertEquals(
            "group-08",
            remountFoldedOpenChatId(
                openChatId = "group-08",
                listedChatIds = setOf("group-08", "group-09"),
                liveFoldTarget = "group-09",
            ),
        )
        assertEquals(
            "group-08",
            remountFoldedOpenChatId(
                openChatId = "group-08",
                listedChatIds = listed,
                liveFoldTarget = null,
            ),
        )
        assertEquals(
            "group-09",
            remountFoldedOpenChatId(
                openChatId = "group-08",
                listedChatIds = emptySet(),
                liveFoldTarget = "group-09",
            ),
        )
        val listedLive = SonarChat(id = "group-09", name = "room", members = listOf("npub1a"), isDirect = false)
        assertEquals(listedLive, notificationOpenChat("group-09", listOf(listedLive)))
        val historical = SonarChat(
            id = "group-08",
            name = "standup",
            members = listOf("npub1a", "npub1b"),
            isDirect = false,
        )
        val remapped = notificationOpenChat(
            "group-09",
            listOf(historical),
            mapOf("group-08" to "group-09"),
        )
        assertEquals("group-09", remapped.id)
        assertEquals("standup", remapped.name)
        assertEquals(listOf("npub1a", "npub1b"), remapped.members)
        assertFalse(remapped.isDirect)
        assertEquals(
            remapped,
            listedOrFoldedSiblingChat(
                chatId = "group-09",
                listedChats = listOf(historical),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        val sittingOnHidden = listedOrFoldedSiblingChat(
            chatId = "group-08",
            listedChats = listOf(listedLive.copy(name = "standup", members = listOf("npub1a", "npub1b"))),
            historicalFolds = mapOf("group-08" to "group-09"),
        )
        assertEquals("group-08", sittingOnHidden?.id)
        assertEquals("standup", sittingOnHidden?.name)
        assertEquals(listOf("npub1a", "npub1b"), sittingOnHidden?.members)
        assertEquals(false, sittingOnHidden?.isDirect)
        val liveDm = SonarChat(
            id = "dm-09",
            name = "",
            members = listOf("npub1me", "npub1bob"),
            isDirect = true,
        )
        val hiddenDm = listedOrFoldedSiblingChat(
            chatId = "dm-08",
            listedChats = listOf(liveDm),
            historicalFolds = mapOf("dm-08" to "dm-09"),
        )
        assertEquals("dm-08", hiddenDm?.id)
        assertEquals(
            "npub1bob",
            directMarmotPeerKey(hiddenDm!!, "npub1me"),
        )
        assertEquals(
            listOf(
                Screen.Chat("group-09", "standup"),
                Screen.GroupInfo("group-09"),
                Screen.ContactProfile("group-09", "Ada"),
                Screen.Call("group-09", "Ada", false),
            ),
            remountFoldedNavStack(
                listOf(
                    Screen.Chat("group-08", "standup"),
                    Screen.GroupInfo("group-08"),
                    Screen.ContactProfile("group-08", "Ada"),
                    Screen.Call("group-08", "Ada", false),
                ),
            ) { id -> if (id == "group-08") "group-09" else id },
        )
        val stub = notificationOpenChat("group-09", emptyList())
        assertEquals("group-09", stub.id)
        assertEquals("", stub.name)
        assertFalse(stub.isDirect)
        assertNull(
            listedOrFoldedSiblingChat(
                chatId = "group-09",
                listedChats = emptyList(),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        val titleOf: (SonarChat) -> String = { it.name.ifBlank { "Group chat" } }
        assertEquals(
            "standup",
            adoptedListedChatTitle(
                openChatId = "group-09",
                currentTitle = "Group chat",
                listedChats = listOf(listedLive.copy(name = "standup")),
                titleOf = titleOf,
            ),
        )
        assertNull(
            adoptedListedChatTitle(
                openChatId = "group-09",
                currentTitle = "standup",
                listedChats = listOf(listedLive.copy(name = "standup")),
                titleOf = titleOf,
            ),
        )
        assertNull(
            adoptedListedChatTitle(
                openChatId = "group-09",
                currentTitle = "Group chat",
                listedChats = emptyList(),
                titleOf = titleOf,
            ),
        )
        assertNull(
            adoptedListedChatTitle(
                openChatId = "group-09",
                currentTitle = "standup",
                listedChats = listOf(listedLive.copy(name = "")),
                titleOf = titleOf,
            ),
        )
    }

    @Test
    fun foldedHistoricalMuteMovesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            mapOf("group-08" to 50L, "group-09" to 50L),
            promotedFoldedMutes(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                mutes = mapOf("group-08" to 50L),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to 50L, "group-09" to 80L),
            promotedFoldedMutes(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                mutes = mapOf("group-08" to 50L, "group-09" to 80L),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to 50L),
            promotedFoldedMutes(
                previousIds = setOf("group-08"),
                currentIds = setOf("group-08"),
                mutes = mapOf("group-08" to 50L),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to 50L, "group-09" to 50L),
            promotedFoldedMutes(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                mutes = mapOf("group-08" to 50L),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to 50L, "group-09" to 50L),
            promotedFoldedMutesFromFolds(
                mutes = mapOf("group-08" to 50L),
                historicalFolds = folds,
            ),
        )
    }

    @Test
    fun foldedHistoricalPaymentActivitiesMoveOntoLiveSibling() {
        fun row(id: String, peerKey: String) = SonarPaymentActivity(
            id = id,
            kind = SonarPaymentActivity.Kind.SonarDirect,
            peerKey = peerKey,
            peerName = "Alice",
            direction = SonarPaymentActivity.Direction.Outgoing,
            sats = 1000,
            via = "internet",
            createdAtSecs = 100,
            destinationHash = null,
            status = SonarPaymentActivity.Status.Paid,
        )
        val historical = row("pay-08", "group-08")
        val live = row("pay-09", "group-09")
        val wallet = row("wallet", "wallet")
        val unify = row("unify", "unify:peer")
        assertEquals(
            listOf(historical.copy(peerKey = "group-09"), live, wallet, unify),
            remountedPaymentActivities(
                historicalKeys = listOf("group-08"),
                liveKey = "group-09",
                activities = listOf(historical, live, wallet, unify),
            ),
        )
        assertEquals(
            setOf("group-08", "group-09"),
            paymentActivityPeerKeys("group-09", mapOf("group-08" to "group-09")),
        )
        assertEquals(
            setOf("group-08", "group-09"),
            paymentActivityPeerKeys("group-08", mapOf("group-08" to "group-09")),
        )
        assertEquals(setOf("group-09"), paymentActivityPeerKeys("group-09", emptyMap()))
    }

    @Test
    fun callRecordsReadWalksFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        val historical = CallRecord(
            id = "call-08",
            video = false,
            mine = true,
            durSecs = 12,
            tsSecs = 1L,
        )
        val live = CallRecord(
            id = "call-09",
            video = true,
            mine = false,
            durSecs = 4,
            tsSecs = 2L,
        )
        val logs = mapOf(
            "group-08" to listOf(historical),
            "group-09" to listOf(live),
        )
        assertEquals(
            setOf("call-08", "call-09"),
            callRecordsForChat("group-09", logs, folds).map { it.id }.toSet(),
        )
        assertEquals(
            setOf("call-08", "call-09"),
            callRecordsForChat("group-08", logs, folds).map { it.id }.toSet(),
        )
        assertEquals(
            listOf(live),
            callRecordsForChat("group-09", logs, emptyMap()),
        )
        val updatedLive = live.copy(durSecs = 40)
        assertEquals(
            listOf(updatedLive),
            dedupeCallRecordsLastWins(
                callRecordsForChat(
                    "group-09",
                    mapOf(
                        "group-08" to listOf(live),
                        "group-09" to listOf(updatedLive),
                    ),
                    folds,
                ),
            ),
        )
    }

    @Test
    fun pendingMessagesReadWalksFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        val historical = listOf(
            SonarMsg(id = "echo-08", senderNpub = "me", content = "queued", mine = true, tsSecs = 1L, state = "Couldn't send"),
        )
        val live = listOf(
            SonarMsg(id = "echo-09", senderNpub = "me", content = "live", mine = true, tsSecs = 2L, state = "Sending"),
        )
        val byChat = mapOf("group-08" to historical, "group-09" to live)
        assertEquals(
            setOf("echo-08", "echo-09"),
            pendingMessagesForChat("group-09", byChat, folds).map { it.id }.toSet(),
        )
        assertEquals(
            setOf("echo-08", "echo-09"),
            pendingMessagesForChat("group-08", byChat, folds).map { it.id }.toSet(),
        )
        assertEquals(live, pendingMessagesForChat("group-09", byChat, emptyMap()))
    }

    @Test
    fun pendingMessagesMutateWalksFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        val byChat = mutableMapOf(
            "group-08" to mutableListOf(
                SonarMsg(id = "echo-08", senderNpub = "me", content = "queued", mine = true, tsSecs = 1L, state = "Sending"),
            ),
            "group-09" to mutableListOf(
                SonarMsg(id = "echo-09", senderNpub = "me", content = "live", mine = true, tsSecs = 2L, state = "Sending"),
            ),
        )
        assertTrue(
            updatePendingMessagesForChat(
                "group-09",
                byChat,
                folds,
                matches = { it.id == "echo-08" },
                update = { it.copy(state = "Couldn't send") },
            ),
        )
        assertEquals("Couldn't send", byChat["group-08"]!!.single().state)
        assertEquals("Sending", byChat["group-09"]!!.single().state)
        removePendingMessagesForChat("group-09", byChat, folds) { it.id == "echo-08" }
        assertTrue("group-08" !in byChat)
        assertEquals(listOf("echo-09"), byChat["group-09"]!!.map { it.id })
    }

    @Test
    fun resolvedOpenGroupIdRemapsStaleHistOntoListedLive() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            "group-09",
            resolvedOpenGroupId("group-08", setOf("group-09"), folds),
        )
        assertEquals(
            "group-09",
            resolvedOpenGroupId("group-09", setOf("group-09"), folds),
        )
        assertEquals(
            "group-08",
            resolvedOpenGroupId("group-08", emptySet(), folds),
        )
        assertEquals(
            "group-08",
            resolvedOpenGroupId("group-09", setOf("group-08"), folds),
        )
    }

    @Test
    fun foldFamilyCachedMessagesUnionsHiddenSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = SonarMsg(id = "m-08", senderNpub = "peer", content = "keep this chat", mine = false, tsSecs = 1L)
        val live = SonarMsg(id = "m-09", senderNpub = "me", content = "already on live", mine = true, tsSecs = 2L)
        val byChat = mapOf("group-08" to listOf(historical), "group-09" to listOf(live))
        assertEquals(
            listOf("m-09", "m-08"),
            foldFamilyCachedMessages("group-09", byChat, folds) { it.id }.map { it.id },
        )
        assertEquals(
            listOf(historical),
            foldFamilyCachedMessages("group-09", mapOf("group-08" to listOf(historical)), folds) { it.id },
        )
        assertEquals(
            listOf(live),
            foldFamilyCachedMessages("group-09", byChat, emptyMap()) { it.id },
        )
    }

    @Test
    fun hasOlderForFoldFamilyReadsHiddenSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertTrue(hasOlderForFoldFamily("group-09", mapOf("group-08" to true), folds))
        assertTrue(hasOlderForFoldFamily("group-09", mapOf("group-09" to true), folds))
        assertFalse(hasOlderForFoldFamily("group-09", mapOf("group-08" to false, "group-09" to false), folds))
        assertFalse(hasOlderForFoldFamily("group-09", mapOf("group-08" to true), emptyMap()))
        assertEquals(setOf("group-09"), pagedFoldFamilyGroupIds(setOf("group-09", "")))
        assertTrue(hiddenFoldFamilyNeedsPage("group-09", folds, setOf("group-09")))
        assertEquals(listOf("group-08"), hiddenFoldFamilyIdsNeedingPage("group-09", folds, setOf("group-09")))
        assertEquals(
            listOf("group-08"),
            loadOlderHiddenSiblingsNeedingNewestPage(listOf("group-09"), folds, setOf("group-09")),
        )
        assertEquals(
            emptyList<String>(),
            loadOlderHiddenSiblingsNeedingNewestPage(
                listOf("group-09"),
                folds,
                setOf("group-08", "group-09"),
            ),
        )
        assertEquals(
            listOf("group-08"),
            loadOlderFamilyPageIds(
                "group-09",
                folds,
                mapOf("group-08" to true),
            ),
        )
        assertEquals(
            listOf("group-08", "group-09"),
            loadOlderFamilyPageIds(
                "group-09",
                folds,
                mapOf("group-08" to true, "group-09" to true),
            ),
        )
        assertEquals(
            emptyList<String>(),
            loadOlderFamilyPageIds(
                "group-09",
                folds,
                mapOf("group-08" to false, "group-09" to false),
            ),
        )
        assertEquals(
            listOf("group-09"),
            loadOlderFamilyPageIds("group-09", emptyMap(), mapOf("group-09" to true)),
        )
        assertTrue(
            loadOlderBusyRetryShouldWait("group-09", setOf("group-08"), folds),
        )
        assertTrue(
            loadOlderBusyRetryShouldWait("group-09", setOf("group-09"), folds),
        )
        assertFalse(
            loadOlderBusyRetryShouldWait("group-09", setOf("group-08"), emptyMap()),
        )
        assertFalse(
            loadOlderBusyRetryShouldWait("group-09", emptySet(), folds),
        )
        // loadOlderDM may pass hist. A remounted live extract must not be
        // newest-paged (snap). Empty unpaged hist still needs a newest page.
        assertFalse(foldFamilySourceNeedsNewestPage("group-09", setOf("group-08"), cachedRowCount = 20))
        assertTrue(foldFamilySourceNeedsNewestPage("group-08", setOf("group-09"), cachedRowCount = 0))
        assertEquals(
            setOf("h1", "l1"),
            foldFamilyCanonicalMessageIds(
                "group-09",
                mapOf(
                    "group-09" to listOf(
                        SonarMsg("l1", "me", "live", true, 2L),
                    ),
                    "group-08" to listOf(
                        SonarMsg("h1", "peer", "hist", false, 1L),
                    ),
                ),
                folds,
            ) { it.id },
        )
        assertFalse(hiddenFoldFamilyNeedsPage("group-09", folds, setOf("group-08", "group-09")))
        assertFalse(hiddenFoldFamilyNeedsPage("group-09", emptyMap(), setOf("group-09")))
        assertTrue(foldFamilySourceNeedsNewestPage("group-08", setOf("group-09"), cachedRowCount = 0))
        assertFalse(foldFamilySourceNeedsNewestPage("group-09", setOf("group-09"), cachedRowCount = 0))
        assertFalse(foldFamilySourceNeedsNewestPage("group-09", emptySet(), cachedRowCount = 20))
        assertTrue(
            shouldPageHiddenFoldFamilyForOpenLive(
                "group-09",
                folds,
                setOf("group-09"),
            ),
        )
        assertFalse(
            shouldPageHiddenFoldFamilyForOpenLive(
                "group-09",
                folds,
                setOf("group-08", "group-09"),
            ),
        )
        assertTrue(
            shouldPageHiddenFoldFamilyForOpenLive(
                "mesh:peer",
                folds,
                setOf("group-09"),
                listOf("group-09"),
            ),
        )
        assertFalse(
            shouldPageHiddenFoldFamilyForOpenLive(
                "mesh:peer",
                folds,
                setOf("group-08", "group-09"),
                listOf("group-09"),
            ),
        )
        assertFalse(
            shouldPageHiddenFoldFamilyForOpenLive(
                "mesh:peer",
                folds,
                setOf("group-09"),
            ),
        )
        assertTrue(loadOlderEmptyPaintShouldPublishFamily(paintedCount = 0, familyRowCount = 30))
        assertFalse(loadOlderEmptyPaintShouldPublishFamily(paintedCount = 0, familyRowCount = 0))
        assertFalse(loadOlderEmptyPaintShouldPublishFamily(paintedCount = 5, familyRowCount = 30))
        assertTrue(
            hasOlderForFoldFamily(
                "group-09",
                mapOf("group-08" to false, "group-09" to false),
                folds,
                unpagedHiddenSibling = true,
            ),
        )
        assertFalse(
            hasOlderForFoldFamily(
                "group-09",
                mapOf("group-08" to false, "group-09" to false),
                folds,
                unpagedHiddenSibling = false,
            ),
        )
        assertTrue(
            hasOlderForFoldFamily(
                "group-09",
                mapOf("group-08" to false, "group-09" to false),
                folds,
                cachedCount = TRANSCRIPT_PAGE_SIZE + 1,
                pageSize = TRANSCRIPT_PAGE_SIZE,
            ),
        )
        assertFalse(
            foldFamilyCacheHasOlderThanPage(
                cachedCount = TRANSCRIPT_PAGE_SIZE,
                pageSize = TRANSCRIPT_PAGE_SIZE,
            ),
        )
        assertTrue(
            seededFoldFamilyTranscriptHasMore(
                cachedCount = TRANSCRIPT_PAGE_SIZE + 10,
                familyHasOlder = false,
            ),
        )
        assertFalse(
            seededFoldFamilyTranscriptHasMore(
                cachedCount = TRANSCRIPT_PAGE_SIZE,
                familyHasOlder = false,
            ),
        )
        assertTrue(
            seededFoldFamilyTranscriptHasMore(
                cachedCount = TRANSCRIPT_PAGE_SIZE,
                familyHasOlder = true,
            ),
        )
        // First-paint extract is 80; a live-only newest page must not
        // compare overflow to the 500-row retained cap. The iOS
        // snap-to-newest replace path uses the same helper so dropping
        // those 80 cannot disarm load-older.
        assertTrue(
            newestPageFamilyHasOlder(
                existingCount = 80,
                incomingCount = 2,
                rawPageCount = 2,
                previousHasOlder = false,
            ),
        )
        assertFalse(
            newestPageFamilyHasOlder(
                existingCount = 10,
                incomingCount = 5,
                rawPageCount = 5,
                previousHasOlder = false,
            ),
        )
        assertTrue(
            newestPageFamilyHasOlder(
                existingCount = 10,
                incomingCount = 5,
                rawPageCount = TRANSCRIPT_PAGE_SIZE + 1,
                previousHasOlder = false,
            ),
        )
        assertTrue(
            newestPageFamilyHasOlder(
                existingCount = 10,
                incomingCount = 5,
                rawPageCount = 5,
                previousHasOlder = true,
            ),
        )
        // Home hydrate remounts only 20 rows. Persist-folds live is a
        // short 0.9 page; extract 21–80 + bak stay on hist. Without
        // hasFoldFamily this must stay false (ordinary short chat).
        assertTrue(
            newestPageFamilyHasOlder(
                existingCount = 20,
                incomingCount = 2,
                rawPageCount = 2,
                previousHasOlder = false,
                hasFoldFamily = true,
            ),
        )
        assertFalse(
            newestPageFamilyHasOlder(
                existingCount = 20,
                incomingCount = 2,
                rawPageCount = 2,
                previousHasOlder = false,
                hasFoldFamily = false,
            ),
        )
        assertFalse(
            newestPageFamilyHasOlder(
                existingCount = 0,
                incomingCount = 2,
                rawPageCount = 2,
                previousHasOlder = false,
                hasFoldFamily = true,
            ),
        )
        // First load-older can hit an empty/short page before bak
        // remainder is copied. Do not disarm the newest-page arm.
        assertTrue(
            loadOlderPageHasOlder(
                rawPageCount = 0,
                pageSize = TRANSCRIPT_PAGE_SIZE,
                admittedNewRows = false,
                previousHasOlder = true,
            ),
        )
        assertTrue(
            loadOlderPageHasOlder(
                rawPageCount = 5,
                pageSize = TRANSCRIPT_PAGE_SIZE,
                admittedNewRows = false,
                previousHasOlder = true,
            ),
        )
        assertFalse(
            loadOlderPageHasOlder(
                rawPageCount = 5,
                pageSize = TRANSCRIPT_PAGE_SIZE,
                admittedNewRows = true,
                previousHasOlder = true,
            ),
        )
        assertTrue(
            loadOlderPageHasOlder(
                rawPageCount = TRANSCRIPT_PAGE_SIZE + 1,
                pageSize = TRANSCRIPT_PAGE_SIZE,
                admittedNewRows = true,
                previousHasOlder = false,
            ),
        )
        assertFalse(
            loadOlderPageHasOlder(
                rawPageCount = 0,
                pageSize = TRANSCRIPT_PAGE_SIZE,
                admittedNewRows = false,
                previousHasOlder = false,
            ),
        )
        // iOS formats only sourceMessageLimit Marmot rows. An 80-row
        // remounted extract must raise that window or load-older that
        // re-reads the same page leaves the rest unreachable.
        assertEquals(
            80,
            cachedFoldFamilySourceLimit(
                cachedCount = 80,
                currentLimit = TRANSCRIPT_PAGE_SIZE,
            ),
        )
        assertEquals(
            TRANSCRIPT_PAGE_SIZE,
            cachedFoldFamilySourceLimit(
                cachedCount = 10,
                currentLimit = TRANSCRIPT_PAGE_SIZE,
            ),
        )
        assertEquals(
            TRANSCRIPT_RETAINED_ROWS,
            cachedFoldFamilySourceLimit(
                cachedCount = TRANSCRIPT_RETAINED_ROWS + 20,
                currentLimit = TRANSCRIPT_PAGE_SIZE,
            ),
        )
        assertEquals(
            "cursor-08",
            foldFamilyPagingCursor(
                "group-09",
                mapOf("group-08" to "cursor-08"),
                mapOf("group-08" to "group-09"),
            ),
        )
        assertEquals(
            "cursor-09",
            foldFamilyPagingCursor(
                "group-09",
                mapOf("group-08" to "cursor-08", "group-09" to "cursor-09"),
                mapOf("group-08" to "group-09"),
            ),
        )
    }

    @Test
    fun foldedHistoricalPendingMediaUploadsMoveOntoLiveSibling() {
        assertEquals(
            mapOf("group-09" to listOf("uploading")),
            remountFoldedPendingMediaUploads(
                historical = "group-08",
                live = "group-09",
                uploads = mapOf("group-08" to listOf("uploading")),
            ),
        )
        assertEquals(
            mapOf("group-09" to listOf("already", "uploading")),
            remountFoldedPendingMediaUploads(
                historical = "group-08",
                live = "group-09",
                uploads = mapOf(
                    "group-08" to listOf("uploading"),
                    "group-09" to listOf("already"),
                ),
            ),
        )
        assertEquals(
            mapOf("group-09" to listOf("already", "uploading")),
            promotedFoldedPendingMediaUploads(
                previousIds = setOf("group-08"),
                currentIds = setOf("group-09"),
                uploads = mapOf(
                    "group-08" to listOf("uploading"),
                    "group-09" to listOf("already"),
                ),
                liveFoldTarget = { if (it == "group-08") "group-09" else null },
            ),
        )
        assertEquals(
            mapOf("group-08" to listOf("uploading")),
            promotedFoldedPendingMediaUploads(
                previousIds = setOf("group-08"),
                currentIds = setOf("group-08"),
                uploads = mapOf("group-08" to listOf("uploading")),
                liveFoldTarget = { if (it == "group-08") "group-09" else null },
            ),
        )
    }

    @Test
    fun conversationChangeTargetPrefersListedLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            listOf("group-08", "group-09"),
            conversationRefreshIds(
                changedId = "group-08",
                listedIds = setOf("group-09"),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            listOf("group-09"),
            conversationRefreshIds(
                changedId = "group-09",
                listedIds = setOf("group-09"),
                historicalFolds = folds,
            ),
        )
        assertTrue(
            conversationRefreshShouldLoadPage(
                refreshId = "group-08",
                listedIds = setOf("group-09"),
                cachedIds = emptySet(),
                changedId = "group-08",
                historicalFolds = folds,
            ),
        )
        assertFalse(
            conversationRefreshShouldLoadPage(
                refreshId = "brand-new",
                listedIds = setOf("group-09"),
                cachedIds = emptySet(),
                changedId = "brand-new",
                historicalFolds = folds,
            ),
        )
        assertEquals(
            "group-09",
            conversationChangeTargetId(
                changedId = "group-08",
                listedIds = setOf("group-09"),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            "group-09",
            conversationChangeTargetId(
                changedId = "group-09",
                listedIds = setOf("group-09"),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            "group-08",
            conversationChangeTargetId(
                changedId = "group-08",
                listedIds = emptySet(),
                historicalFolds = folds,
            ),
        )
    }

    @Test
    fun conversationChangeRefreshesOpenMeshFromHiddenSibling() {
        val folds = mapOf("group-08" to "group-09")
        val peerByGroup = mapOf("group-09" to "peer-a")
        fun meshId(peerId: String) = "mesh:$peerId"
        assertTrue(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-a",
                changedGroupId = "group-08",
                historicalFolds = folds,
                peerIdForGroup = peerByGroup::get,
                meshChatId = ::meshId,
            ),
        )
        assertTrue(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-a",
                changedGroupId = "group-09",
                historicalFolds = folds,
                peerIdForGroup = peerByGroup::get,
                meshChatId = ::meshId,
            ),
        )
        assertTrue(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-a",
                changedGroupId = "group-08",
                historicalFolds = emptyMap(),
                peerIdForGroup = mapOf("group-08" to "peer-a")::get,
                meshChatId = ::meshId,
            ),
        )
        assertFalse(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-a",
                changedGroupId = "group-08",
                historicalFolds = folds,
                peerIdForGroup = { null },
                meshChatId = ::meshId,
            ),
        )
        assertFalse(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-b",
                changedGroupId = "group-08",
                historicalFolds = folds,
                peerIdForGroup = peerByGroup::get,
                meshChatId = ::meshId,
            ),
        )
        assertFalse(
            conversationChangeShouldRefreshOpenMesh(
                openMeshChatId = "mesh:peer-a",
                changedGroupId = "other",
                historicalFolds = folds,
                peerIdForGroup = peerByGroup::get,
                meshChatId = ::meshId,
            ),
        )
    }

    @Test
    fun pendingMediaUploadLookupWalksFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            setOf("group-08", "group-09"),
            pendingMediaUploadLookupIds("group-08", folds).toSet(),
        )
        assertEquals(
            setOf("group-08", "group-09"),
            pendingMediaUploadLookupIds("group-09", folds).toSet(),
        )
        assertEquals("group-09", pendingMediaUploadStoreId("group-08", folds))
        assertEquals("group-09", pendingMediaUploadStoreId("group-09", folds))
        assertEquals("group-08", pendingMediaUploadStoreId("group-08", emptyMap()))
    }

    @Test
    fun retainedTranscriptReadWalksFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        val historical = listOf(
            SonarMsg(id = "m1", senderNpub = "npub1peer", content = "old", mine = false, tsSecs = 1L),
        )
        val snapshot = listOf(
            SonarMsg(id = "m2", senderNpub = "npub1me", content = "snap", mine = true, tsSecs = 2L),
        )
        val retained = mapOf("group-08" to historical)
        assertEquals(historical, retainedTranscriptForChat("group-09", retained, folds))
        assertEquals(historical, retainedTranscriptForChat("group-08", retained, folds))
        assertEquals(emptyList(), retainedTranscriptForChat("group-09", retained, emptyMap()))
        assertEquals(
            listOf(historical.single(), snapshot.single()),
            firstOpenTranscriptPaintRows("group-09", retained, snapshot, folds),
        )
        assertEquals(
            snapshot,
            firstOpenTranscriptPaintRows("group-09", retained, snapshot, emptyMap()),
        )
        assertEquals(
            snapshot,
            firstOpenTranscriptPaintRows("group-09", emptyMap(), snapshot, folds),
        )
        val liveLeave = listOf(
            SonarMsg(id = "m-live", senderNpub = "npub1me", content = "new 0.9", mine = true, tsSecs = 3L),
        )
        assertEquals(
            listOf(historical.single(), liveLeave.single()),
            firstOpenTranscriptPaintRows(
                "group-09",
                mapOf("group-09" to liveLeave),
                historical,
                folds,
            ),
        )
        assertTrue(firstOpenHasLocalTranscriptPaint(emptyList(), snapshot))
        assertTrue(firstOpenHasLocalTranscriptPaint(historical, emptyList()))
        assertFalse(firstOpenHasLocalTranscriptPaint(emptyList(), emptyList()))
        assertFalse(
            firstOpenHasLocalTranscriptPaint(
                emptyList(),
                listOf(
                    SonarMsg(
                        id = "${SYNTHETIC_SUMMARY_ID_PREFIX}group-09:1:1",
                        senderNpub = "npub1peer",
                        content = "preview",
                        mine = false,
                        tsSecs = 1L,
                    ),
                ),
            ),
        )
    }

    @Test
    fun firstOpenFoldFamilySeedSurvivesLiveOnlyLocalPage() {
        val hist = (1..40).map { i ->
            SonarMsg(
                id = "h$i",
                senderNpub = "npub1peer",
                content = "old $i",
                mine = false,
                tsSecs = i.toLong(),
            )
        }
        val liveOnly = listOf(
            SonarMsg(id = "l1", senderNpub = "npub1me", content = "new 0.9", mine = true, tsSecs = 100L),
        )
        val seeded = firstOpenFoldFamilySeedRows(hist)
        val afterLocal = mergeTranscriptRows(seeded, liveOnly)
        assertTrue(afterLocal.any { it.id == "h1" })
        assertTrue(afterLocal.any { it.id == "l1" })
        assertTrue(seededFoldFamilyTranscriptHasMore(cachedCount = afterLocal.size))
        assertTrue(
            newestPageShouldMergeFamilyWindow(
                existingCanonicalCount = hist.size,
                hiddenSiblingHasRows = false,
                hasFoldFamily = true,
                pinnedToOlderEdge = false,
            ),
        )
        assertFalse(
            newestPageShouldMergeFamilyWindow(
                existingCanonicalCount = hist.size,
                hiddenSiblingHasRows = false,
                hasFoldFamily = true,
                pinnedToOlderEdge = true,
            ),
        )
        assertFalse(
            newestPageShouldMergeFamilyWindow(
                existingCanonicalCount = hist.size,
                hiddenSiblingHasRows = false,
                hasFoldFamily = false,
                pinnedToOlderEdge = false,
            ),
        )
        assertTrue(
            newestPageShouldMergeFamilyWindow(
                existingCanonicalCount = hist.size,
                hiddenSiblingHasRows = true,
                hasFoldFamily = false,
                pinnedToOlderEdge = false,
            ),
        )
        assertFalse(
            newestPageShouldMergeFamilyWindow(
                existingCanonicalCount = 0,
                hiddenSiblingHasRows = true,
                hasFoldFamily = true,
                pinnedToOlderEdge = false,
            ),
        )
        assertEquals(
            hist,
            firstOpenFoldFamilySeedRows(hist + listOf(
                SonarMsg(
                    id = "${SYNTHETIC_SUMMARY_ID_PREFIX}group-09:1:1",
                    senderNpub = "npub1peer",
                    content = "preview",
                    mine = false,
                    tsSecs = 1L,
                ),
            )),
        )
    }

    @Test
    fun quotedMessageRevealExpandsPaintedPageToParent() {
        val cached = (1..40).map { i ->
            SonarMsg(
                id = "m$i",
                senderNpub = "npub1peer",
                content = "row $i",
                mine = false,
                tsSecs = i.toLong(),
            )
        }
        val parent = cached.first { it.id == "m5" }
        val painted = cached.takeLast(TRANSCRIPT_PAGE_SIZE)
        assertNull(painted.firstOrNull { it.id == "m5" })
        assertEquals(parent, quotedParentInFamilyCache("m5", cached))
        assertEquals(parent, quotedParentInFamilyCache("M5", cached))
        assertNull(quotedParentInFamilyCache("m5", painted))
        assertEquals(36, quotedMessageRevealLimit("m5", cached))
        assertEquals(TRANSCRIPT_PAGE_SIZE, quotedMessageRevealLimit("m39", cached))
        assertNull(quotedMessageRevealLimit("missing", cached))
        assertNull(quotedMessageRevealLimit("m5", emptyList()))
        assertNull(quotedMessageRevealLimit("  ", cached))
        val retained = (1..TRANSCRIPT_RETAINED_ROWS + 20).map { i ->
            SonarMsg(
                id = "r$i",
                senderNpub = "npub1peer",
                content = "row $i",
                mine = false,
                tsSecs = i.toLong(),
            )
        }
        assertEquals(
            TRANSCRIPT_RETAINED_ROWS,
            quotedMessageRevealLimit("r1", retained),
        )
        assertTrue(shouldSettleQuotedJump(parentInFeed = true))
        assertFalse(shouldSettleQuotedJump(parentInFeed = false))
        // Empty first bak page / hist miss is not exhaustion. Clearing
        // here dropped recovered 0.8 quote + notification jumps.
        assertFalse(shouldClearQuotedJumpAfterMiss(added = false, parentInFeed = false))
        assertFalse(shouldClearQuotedJumpAfterMiss(added = true, parentInFeed = false))
        assertTrue(shouldClearQuotedJumpAfterMiss(added = true, parentInFeed = true))
        assertEquals("500:old:new", quotedJumpRetryToken(500, "old", "new"))
        assertTrue(
            quotedJumpRetryToken(500, "older", "new") !=
                quotedJumpRetryToken(500, "old", "new"),
        )
        assertTrue(
            quotedJumpRetryToken(500, "old", "newer") !=
                quotedJumpRetryToken(500, "old", "new"),
        )
        val folds = mapOf("group-08" to "group-09")
        val histJump = mapOf("group-08" to "parent-08")
        assertEquals("parent-08", quotedJumpParentId("group-09", histJump, folds))
        assertEquals("parent-08", quotedJumpParentId("group-08", histJump, folds))
        assertNull(quotedJumpParentId("group-09", histJump, emptyMap()))
        val written = quotedJumpWritten("group-08", "parent-08", emptyMap(), folds)
        assertEquals("parent-08", written["group-08"])
        assertEquals("parent-08", written["group-09"])
        val cleared = quotedJumpCleared("group-09", written, folds)
        assertNull(cleared["group-08"])
        assertNull(cleared["group-09"])
    }

    @Test
    fun composerDraftReadAndClearWalkFoldFamily() {
        val folds = mapOf("group-08" to "group-09")
        val drafts = mapOf("group-08" to "hello from 0.8")
        assertEquals("hello from 0.8", composerDraftForChat("group-09", drafts, folds))
        assertEquals("hello from 0.8", composerDraftForChat("group-08", drafts, folds))
        assertEquals("", composerDraftForChat("group-09", drafts, emptyMap()))
        assertEquals(
            mapOf("group-09" to "hello from 0.8"),
            composerDraftsAfterEdit(drafts, "group-09", "hello from 0.8", folds),
        )
        assertEquals(
            emptyMap(),
            composerDraftsAfterEdit(drafts, "group-09", "", folds),
        )
    }

    @Test
    fun trillCooldownReadsHiddenHistoricalSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            80L,
            trillCooldownUntilMsForChat("group-09", mapOf("group-08" to 80L), folds),
        )
        assertEquals(
            90L,
            trillCooldownUntilMsForChat(
                "group-09",
                mapOf("group-08" to 80L, "group-09" to 90L),
                folds,
            ),
        )
    }

    @Test
    fun foldedHistoricalComposerDraftMovesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            mapOf("group-08" to "hello from 0.8", "group-09" to "hello from 0.8"),
            promotedFoldedComposerDrafts(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                drafts = mapOf("group-08" to "hello from 0.8"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to "old", "group-09" to "already typing"),
            promotedFoldedComposerDrafts(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                drafts = mapOf("group-08" to "old", "group-09" to "already typing"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to "hello from 0.8"),
            promotedFoldedComposerDrafts(
                previousIds = setOf("group-08"),
                currentIds = setOf("group-08"),
                drafts = mapOf("group-08" to "hello from 0.8"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to "hello from 0.8", "group-09" to "hello from 0.8"),
            promotedFoldedComposerDrafts(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                drafts = mapOf("group-08" to "hello from 0.8"),
                liveFoldTarget = folds::get,
            ),
        )
    }

    @Test
    fun snapshotLatestFollowsPersistedFoldOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            mapOf("group-08" to 1_700_000_000L, "group-09" to 1_700_000_000L),
            snapshotLatestAfterHistoricalFolds(
                latestByChat = mapOf("group-08" to 1_700_000_000L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            mapOf("group-08" to 1_700_000_000L, "group-09" to 1_700_000_100L),
            snapshotLatestAfterHistoricalFolds(
                latestByChat = mapOf("group-08" to 1_700_000_000L, "group-09" to 1_700_000_100L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            mapOf("group-08" to 1_700_000_200L, "group-09" to 1_700_000_200L),
            snapshotLatestAfterHistoricalFolds(
                latestByChat = mapOf("group-08" to 1_700_000_200L, "group-09" to 1_700_000_050L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            mapOf("group-09" to 9L),
            snapshotLatestAfterHistoricalFolds(
                latestByChat = mapOf("group-09" to 9L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            "group-09",
            persistedLiveFoldTarget("group-08", folds),
        )
        assertNull(persistedLiveFoldTarget("group-09", folds))
        assertEquals(
            1_700_000_000L,
            localLatestTsForChat(
                chatId = "group-09",
                messagesByChat = emptyMap(),
                latestByChat = mapOf("group-08" to 1_700_000_000L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            0L,
            localLatestTsForChat(
                chatId = "group-09",
                messagesByChat = emptyMap(),
                latestByChat = mapOf("group-08" to 1_700_000_000L),
                historicalFolds = emptyMap(),
            ),
        )
        val newestFirstExtract = (80 downTo 1).map { n ->
            SonarMsg("hist-$n", "npub1peer", "row $n", false, n.toLong())
        }
        assertEquals(
            80L,
            localLatestTsForChat(
                chatId = "group-09",
                messagesByChat = mapOf("group-09" to newestFirstExtract),
                latestByChat = emptyMap(),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            200L,
            localLatestTsForChat(
                chatId = "group-09",
                messagesByChat = mapOf("group-09" to newestFirstExtract),
                latestByChat = mapOf("group-09" to 200L),
                historicalFolds = folds,
            ),
        )
        val ownNpub = "npub1me"
        val peerNpub = "npub1peer"
        val remounted = SonarChat(id = "group-09", name = "", members = listOf(ownNpub, peerNpub), isDirect = true)
        val otherLive = SonarChat(id = "group-10", name = "", members = listOf(ownNpub, peerNpub), isDirect = true)
        val latest = { id: String ->
            localLatestTsForChat(
                chatId = id,
                messagesByChat = mapOf(
                    "group-09" to newestFirstExtract,
                    "group-10" to listOf(SonarMsg("live-1", ownNpub, "hi", true, 10L)),
                ),
                latestByChat = emptyMap(),
                historicalFolds = folds,
            )
        }
        assertEquals(
            listOf(remounted),
            dedupeDirectMarmotChats(
                chats = listOf(remounted, otherLive),
                ownNpub = ownNpub,
                latestSecs = latest,
            ),
        )
        // Process death drops the remounted extract. Persist must keep max
        // recency — `lastOrNull()` on newest-first extract is 1 and would
        // let the empty sibling win after decode.
        assertEquals(80L, chatSnapshotLatestTs(newestFirstExtract, null))
        assertEquals(200L, chatSnapshotLatestTs(newestFirstExtract, 200L))
        val persisted = decodeChatSnapshotLatest(
            encodeChatSnapshot(
                listOf(remounted, otherLive),
                mapOf("group-09" to newestFirstExtract),
                mapOf("group-10" to 10L),
            ),
        )
        assertEquals(80L, persisted["group-09"])
        assertEquals(10L, persisted["group-10"])
        val afterDeath = { id: String ->
            localLatestTsForChat(
                chatId = id,
                messagesByChat = emptyMap(),
                latestByChat = persisted,
                historicalFolds = folds,
            )
        }
        assertEquals(
            listOf(remounted),
            dedupeDirectMarmotChats(
                chats = listOf(remounted, otherLive),
                ownNpub = ownNpub,
                latestSecs = afterDeath,
            ),
        )
        // Home-row preview used `lastOrNull()` on the unsorted remount.
        // Newest-first extract would show "row 1" and ts=1, then sink.
        val newestFirstPreview = latestHomeRowMessage(newestFirstExtract)
        assertEquals("row 80", newestFirstPreview?.content)
        assertEquals(80L, newestFirstPreview?.tsSecs)
        assertEquals(80L, foldedMeshRowTs(latestMessageTs = 1L, localLatestTs = 80L))
        assertEquals(80L, foldedMeshRowTs(latestMessageTs = null, localLatestTs = 80L))
        assertEquals(10L, foldedMeshRowTs(latestMessageTs = 10L, localLatestTs = 0L))
    }

    @Test
    fun foldedHistoricalSnapshotMessagesMoveOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = listOf(
            SonarMsg(id = "m1", senderNpub = "npub1peer", content = "old", mine = false, tsSecs = 1L),
        )
        val live = listOf(
            SonarMsg(id = "m2", senderNpub = "npub1me", content = "new", mine = true, tsSecs = 2L),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedSnapshotMessages(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to live + historical),
            promotedFoldedSnapshotMessages(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical, "group-09" to live),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedSnapshotMessages(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical, "group-09" to historical),
                liveFoldTarget = folds::get,
            ),
        )
    }

    @Test
    fun foldedHistoricalPendingEchoesMoveOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = listOf(
            SonarMsg(id = "echo-08", senderNpub = "npub1me", content = "sending", mine = true, tsSecs = 1L),
        )
        val live = listOf(
            SonarMsg(id = "echo-09", senderNpub = "npub1me", content = "already", mine = true, tsSecs = 2L),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedPendingMessages(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical),
                liveFoldTarget = folds::get,
                idOf = { it.id },
            ),
        )
        assertEquals(
            mapOf(
                "group-08" to historical,
                "group-09" to live + historical,
            ),
            promotedFoldedPendingMessages(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical, "group-09" to live),
                liveFoldTarget = folds::get,
                idOf = { it.id },
            ),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedPendingMessages(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                messagesByChat = mapOf("group-08" to historical, "group-09" to historical),
                liveFoldTarget = folds::get,
                idOf = { it.id },
            ),
        )
    }

    @Test
    fun foldedHistoricalCallLogsMoveOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = CallRecord(id = "call-08", video = false, mine = true, durSecs = 12, tsSecs = 1L)
        val live = CallRecord(id = "call-09", video = true, mine = false, durSecs = 0, tsSecs = 2L)
        assertEquals(
            mapOf("group-08" to listOf(historical), "group-09" to listOf(historical)),
            promotedFoldedCallLogs(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                callLogs = mapOf("group-08" to listOf(historical)),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf(
                "group-08" to listOf(historical),
                "group-09" to listOf(historical, live),
            ),
            promotedFoldedCallLogs(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                callLogs = mapOf("group-08" to listOf(historical), "group-09" to listOf(live)),
                liveFoldTarget = folds::get,
            ),
        )
    }

    @Test
    fun foldAliasesDiscoverHiddenHistoricalIdFromLiveSibling() {
        val folds = historicalFoldsFromAliases(
            listedIds = listOf("group-09"),
            foldAliases = { id ->
                if (id == "group-09" || id == "group-08") listOf("group-09", "group-08") else listOf(id)
            },
            liveFoldTarget = { id -> if (id == "group-08" || id == "group-09") "group-09" else null },
        )
        assertEquals(mapOf("group-08" to "group-09"), folds)
        assertEquals(
            emptyMap(),
            historicalFoldsFromAliases(
                listedIds = listOf("plain"),
                foldAliases = { listOf(it) },
                liveFoldTarget = { null },
            ),
        )
    }

    @Test
    fun accountRestoreHostFoldsComeFromLiveSiblingNotPreviousAccount() {
        val previousAccount = mapOf("other-08" to "other-09", "group-08" to "stale-09")
        val aliases = { id: String ->
            if (id == "group-09" || id == "group-08") listOf("group-09", "group-08") else listOf(id)
        }
        val live = { id: String -> if (id == "group-08" || id == "group-09") "group-09" else null }
        val restored = historicalFoldsAfterAccountRestore(
            previousAccountFolds = previousAccount,
            listedIds = listOf("group-09"),
            foldAliases = aliases,
            liveFoldTarget = live,
        )
        assertEquals(mapOf("group-08" to "group-09"), restored)
        assertFalse("other-08" in restored)
        assertEquals("group-09", restored["group-08"])
        assertEquals(
            listOf("group-09"),
            collapsedFoldedSnapshotChats(
                chats = listOf(
                    SonarChat(id = "group-08", name = "room", members = listOf("npub1a"), isDirect = false),
                    SonarChat(id = "group-09", name = "room", members = listOf("npub1a"), isDirect = false),
                ),
                historicalFolds = restored,
            ).map { it.id },
        )
    }

    @Test
    fun foldedSiblingHasMoreKeepsLoadOlderAfterLeave() {
        assertTrue(foldedSiblingHasMore(historicalHasMore = true, liveHasMore = false))
        assertTrue(foldedSiblingHasMore(historicalHasMore = false, liveHasMore = true))
        assertFalse(foldedSiblingHasMore(historicalHasMore = false, liveHasMore = false))
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            mapOf("group-08" to true, "group-09" to true),
            promotedFoldedPagingFlags(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                flags = mapOf("group-08" to true, "group-09" to false),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to true, "group-09" to true),
            promotedFoldedPagingFlags(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                flags = mapOf("group-08" to true),
                liveFoldTarget = { if (it == "group-08") "group-09" else null },
            ),
        )
    }

    @Test
    fun retainedScanChatIdsKeepHiddenHistoricalSibling() {
        val listed = setOf("group-09")
        assertEquals(listed, retainedScanChatIds(listed, emptyMap()))
        assertEquals(
            setOf("group-08", "group-09"),
            retainedScanChatIds(listed, mapOf("group-08" to "group-09")),
        )
        assertEquals(
            listed,
            retainedScanChatIds(listed, mapOf("other-08" to "other-09")),
        )
    }

    @Test
    fun foldedHistoricalVerifiedBlobRecoversOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            setOf("group-08", "group-09"),
            recoveredVerifiedIdsFromFolds(
                folds = folds,
                verifiedIds = emptySet(),
                historicalBlobVerified = { it == "group-08" },
            ),
        )
        assertEquals(
            setOf("group-08", "group-09"),
            recoveredVerifiedIdsFromFolds(
                folds = folds,
                verifiedIds = setOf("group-08"),
                historicalBlobVerified = { false },
            ),
        )
        assertEquals(
            emptySet(),
            recoveredVerifiedIdsFromFolds(
                folds = folds,
                verifiedIds = emptySet(),
                historicalBlobVerified = { false },
            ),
        )
    }

    @Test
    fun foldedHistoricalVerifiedMovesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            setOf("group-08", "group-09"),
            promotedFoldedVerifiedIds(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                verifiedIds = setOf("group-08"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            setOf("group-08", "group-09"),
            promotedFoldedVerifiedIds(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                verifiedIds = setOf("group-08"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            setOf("group-08"),
            promotedFoldedVerifiedIds(
                previousIds = setOf("group-08"),
                currentIds = setOf("group-08"),
                verifiedIds = setOf("group-08"),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            setOf("group-09"),
            promotedFoldedVerifiedIds(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                verifiedIds = setOf("group-09"),
                liveFoldTarget = folds::get,
            ),
        )
        assertTrue(
            verifiedForFoldFamily(
                chatId = "group-09",
                verifiedIds = setOf("group-08"),
                historicalFolds = folds,
            ),
        )
        assertFalse(
            verifiedForFoldFamily(
                chatId = "group-09",
                verifiedIds = setOf("group-08"),
                historicalFolds = emptyMap(),
            ),
        )
        assertTrue(
            verifiedForFoldFamily(
                chatId = "group-09",
                verifiedIds = setOf("group-09"),
                historicalFolds = folds,
            ),
        )
    }

    @Test
    fun foldedHistoricalScanWatermarkMovesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = ScanMark(secs = 50L, count = 12L)
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedScanMarks(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                watermarks = mapOf("group-08" to historical),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf(
                "group-08" to historical,
                "group-09" to ScanMark(secs = 80L, count = 2L),
            ),
            promotedFoldedScanMarks(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                watermarks = mapOf(
                    "group-08" to historical,
                    "group-09" to ScanMark(secs = 80L, count = 2L),
                ),
                liveFoldTarget = folds::get,
            ),
        )
        val promoted = promotedFoldedScanMarks(
            previousIds = setOf("group-08"),
            currentIds = setOf("group-09"),
            watermarks = mapOf("group-08" to historical),
            liveFoldTarget = folds::get,
        )
        assertEquals(
            emptySet(),
            chatsNeedingPageScan(
                latestByChat = mapOf("group-09" to historical),
                scannedWatermark = promoted,
            ),
        )
        assertEquals(
            mapOf("group-08" to setOf("evt-1"), "group-09" to setOf("evt-1", "evt-2")),
            promotedFoldedSeenMessageIds(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                seenByChat = mapOf("group-08" to setOf("evt-1"), "group-09" to setOf("evt-2")),
                liveFoldTarget = folds::get,
            ),
        )
    }

    @Test
    fun foldedHistoricalSnapshotChatDropsOnceLiveSiblingIsListed() {
        val historical = SonarChat(id = "group-08", name = "room", members = listOf("npub1a"), isDirect = false)
        val live = SonarChat(id = "group-09", name = "room", members = listOf("npub1a"), isDirect = false)
        assertEquals(
            listOf(live),
            collapsedFoldedSnapshotChats(
                chats = listOf(historical, live),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        assertEquals(
            listOf(historical),
            collapsedFoldedSnapshotChats(
                chats = listOf(historical),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        assertEquals(
            listOf(historical, live),
            collapsedFoldedSnapshotChats(
                chats = listOf(historical, live),
                historicalFolds = emptyMap(),
            ),
        )
    }

    @Test
    fun persistFoldsCollapseUnionsRecoveredRosterAndTitle() {
        assertEquals("Family", collapsedFoldDisplayName("", "Family"))
        assertEquals("new name", collapsedFoldDisplayName("new name", "Family"))
        assertEquals(
            listOf("npub1alice", "npub1bob", "npub1carol"),
            collapsedFoldDisplayMembers(
                listOf("npub1alice", "npub1bob"),
                listOf("npub1alice", "npub1carol"),
            ),
        )
        val historical = SonarChat(
            id = "group-08",
            name = "Family",
            members = listOf("npub1alice", "npub1bob", "npub1carol"),
            isDirect = false,
        )
        val live = SonarChat(
            id = "group-09",
            name = "",
            members = listOf("npub1alice", "npub1bob"),
            isDirect = false,
        )
        val collapsed = collapsedFoldedSnapshotChats(
            chats = listOf(historical, live),
            historicalFolds = mapOf("group-08" to "group-09"),
        )
        assertEquals(listOf("group-09"), collapsed.map { it.id })
        assertEquals("Family", collapsed.single().name)
        assertEquals(
            listOf("npub1alice", "npub1bob", "npub1carol"),
            collapsed.single().members,
        )
        assertFalse(collapsed.single().isDirect)
        val liveDirect = live.copy(isDirect = true)
        assertTrue(
            collapsedFoldDisplayChat(liveDirect, historical).isDirect,
            "R-045: collapse must keep the live isDirect bit",
        )
    }

    @Test
    fun notificationSuppressIdsIncludeHiddenHistoricalSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            listOf("group-09", "group-08"),
            notificationSuppressIds(listOf("group-09"), folds),
        )
        assertEquals(
            listOf("group-09"),
            notificationSuppressIds(listOf("group-09"), emptyMap()),
        )
        assertTrue("group-08" in notificationSuppressIds(listOf("group-09"), folds))
        assertFalse("group-08" in listOf("group-09"))
        assertEquals(
            setOf("group-09", "group-08"),
            notificationClearIds("group-09", emptyList(), folds),
        )
        assertEquals(
            setOf("mesh:peer", "group-09", "group-08"),
            notificationClearIds("mesh:peer", listOf("group-09"), folds),
        )
        assertEquals(
            setOf("group-09"),
            notificationClearIds("group-09", emptyList(), emptyMap()),
        )
        val mesh = meshNotificationSuppressIds("group-09", "mesh:peer", folds)
        assertTrue("group-08" in mesh)
        assertTrue("group-09" in mesh)
        assertTrue("mesh:peer" in mesh)
        assertFalse("group-08" in listOf("group-09", "mesh:peer"))
    }

    @Test
    fun transcriptSourceIdsIncludeHiddenHistoricalSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            listOf("group-09", "group-08"),
            transcriptSourceIds("group-09", listOf("group-09"), folds),
        )
        assertEquals(
            listOf("group-09"),
            transcriptSourceIds("group-09", listOf("group-09"), emptyMap()),
        )
        // Room / persist-folds: listed live-only would miss bak remainder.
        // iOS `localTranscriptGroups` and Compose `marmotMessagesPageForChat`
        // page these same ids.
        assertEquals(
            listOf("group-09", "group-08"),
            transcriptSourceIds("group-09", emptyList(), folds),
        )
        // Mesh-folded openDm / load-older used listed live ids only.
        assertEquals(
            listOf("group-09", "group-08"),
            meshFoldTranscriptSourceIds(listOf("group-09"), folds),
        )
        assertEquals(
            listOf("group-09", "group-08"),
            meshFoldTranscriptSourceIds(emptyList(), folds, resolvedGroupId = "group-09"),
        )
        assertEquals(
            listOf("group-09"),
            meshFoldTranscriptSourceIds(listOf("group-09"), emptyMap()),
        )
        assertEquals(
            emptyList(),
            meshFoldTranscriptSourceIds(emptyList(), folds),
        )
        assertEquals(
            listOf("group-09", "group-08"),
            mediaFetchGroupIds("group-09", folds),
        )
        assertEquals(
            listOf("group-08", "group-09"),
            mediaFetchGroupIds("group-08", folds),
        )
        assertEquals(
            listOf("group-09"),
            mediaFetchGroupIds("group-09", emptyMap()),
        )
        assertEquals(
            emptyList(),
            mediaFetchGroupIds("", folds),
        )
        assertTrue(
            blankTranscriptKnownNonEmpty(
                chatId = "group-09",
                latestByChat = emptyMap(),
                messageCountByChat = mapOf("group-08" to 80L),
                historicalFolds = folds,
            ),
        )
        assertFalse(
            blankTranscriptKnownNonEmpty(
                chatId = "group-09",
                latestByChat = emptyMap(),
                messageCountByChat = mapOf("group-08" to 80L),
                historicalFolds = emptyMap(),
            ),
        )
        assertTrue(
            blankTranscriptKnownNonEmpty(
                chatId = "group-09",
                latestByChat = mapOf("group-08" to 1_700_000_000L),
                messageCountByChat = emptyMap(),
                historicalFolds = folds,
            ),
        )
        // Live 0.9 empty after resume; leftover hist cache is already paint.
        assertFalse(
            familyTranscriptNeedsNetworkBackfill(
                "group-09",
                mapOf("group-08" to listOf("old from 0.8")),
                folds,
            ),
        )
        assertTrue(
            familyTranscriptNeedsNetworkBackfill(
                "group-09",
                mapOf("group-08" to listOf("old from 0.8")),
                emptyMap(),
            ),
        )
        assertTrue(
            familyTranscriptNeedsNetworkBackfill(
                "group-09",
                emptyMap(),
                folds,
            ),
        )
    }

    @Test
    fun homeRowUnreadFollowsPersistedFoldOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val unreadOnHist = mapOf("group-08" to 3L)
        assertEquals(
            3L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = unreadOnHist,
                historicalFolds = folds,
            ),
        )
        assertEquals(
            0L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = unreadOnHist,
                historicalFolds = emptyMap(),
            ),
        )
        assertEquals(
            4L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = mapOf("group-08" to 3L, "group-09" to 1L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            1L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = mapOf("group-09" to 1L),
                historicalFolds = folds,
            ),
        )
        assertEquals(
            2L,
            unreadForFoldFamily(
                chatId = "dm-09",
                unreadByChat = mapOf("dm-08" to 2L),
                historicalFolds = mapOf("dm-08" to "dm-09"),
                listedDuplicateIds = listOf("dm-09", "dm-extra"),
            ),
        )
        // openChat used to mark only the live id. Home-row unread then
        // walked the leftover hist key and the badge returned after open.
        assertEquals(
            listOf("group-09", "group-08"),
            notificationSuppressIds(listOf("group-09"), folds),
        )
        assertEquals(
            0L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = emptyMap(),
                historicalFolds = folds,
            ),
        )
    }

    @Test
    fun publishedMediaUrlsIncludeHiddenHistoricalSibling() {
        val folds = mapOf("group-08" to "group-09")
        val histPhoto = SonarMsg(
            id = "h-photo",
            senderNpub = "npub1peer",
            content = "",
            mine = false,
            tsSecs = 1L,
            media = listOf(
                SonarMedia("https://blossom.example/old.jpg", "image/jpeg", "image.jpg", 640, 480, null),
            ),
        )
        val liveOnly = listOf(
            SonarMsg(id = "l1", senderNpub = "npub1me", content = "new 0.9", mine = true, tsSecs = 100L),
        )
        assertEquals(
            emptySet<String>(),
            publishedMediaUrlsFromMessages(liveOnly.asSequence()),
            "live-only page must not invent the recovered 0.8 URL",
        )
        assertEquals(
            setOf("https://blossom.example/old.jpg"),
            publishedMediaUrlsFromFamilyPages(
                groupId = "group-09",
                historicalFolds = folds,
                pageForId = { id -> if (id == "group-08") listOf(histPhoto) else liveOnly },
            ),
            "new-send exclude set must include remounted 0.8 attachments",
        )
        assertEquals(
            emptySet<String>(),
            publishedMediaUrlsFromFamilyPages(
                groupId = "group-09",
                historicalFolds = emptyMap(),
                pageForId = { liveOnly },
            ),
        )
    }

    @Test
    fun closedNodeListingDoesNotReplaceOrPersistCachedChats() {
        val cached = listOf(
            SonarChat(id = "group-09", name = "room", members = listOf("npub1a"), isDirect = false),
        )
        assertEquals(cached, chatListingOrCached(loaded = null, cached = cached))
        assertFalse(shouldPersistChatListing(null))
        assertNull(trustedChatListing(loaded = null, sessionReady = true))
        assertEquals(
            emptyList<SonarChat>(),
            trustedChatListing(loaded = emptyList(), sessionReady = true),
        )
        assertTrue(shouldPersistChatListing(emptyList()))
        assertEquals(
            emptyList<SonarChat>(),
            chatListingOrCached(loaded = emptyList(), cached = cached),
        )
        assertEquals(cached, chatListingOrCached(trustedChatListing(null, sessionReady = false), cached))
        assertEquals(
            cached,
            chatListingOrCached(trustedChatListing(emptyList(), sessionReady = false), cached),
        )
    }

    @Test
    fun closedNodeInviteProbeDoesNotClearCachedWelcomes() {
        val cached = listOf(
            SonarGroupInvite(
                id = "welcome-08",
                groupId = "group-08",
                groupName = "standup",
                groupDescription = "",
                welcomerNpub = "npub1welcomer",
                memberCount = 3,
                relays = emptyList(),
            ),
        )
        assertEquals(cached, pendingInvitesOrCached(loaded = null, cached = cached))
        assertEquals(
            emptyList(),
            pendingInvitesOrCached(loaded = emptyList(), cached = cached),
        )
        assertEquals(
            emptyList(),
            pendingInvitesOrCached(loaded = emptyList(), cached = emptyList()),
        )
        assertFalse(shouldApplyUnreadCounts(null))
        assertTrue(shouldApplyUnreadCounts(emptyList()))
        val cachedRequests = listOf(
            SonarJoinRequest(
                requesterNpub = "npub1joiner",
                groupId = "group-08",
                receivedAt = 1_700_000_000L,
            ),
        )
        assertEquals(cachedRequests, pendingJoinRequestsOrCached(loaded = null, cached = cachedRequests))
        assertEquals(
            emptyList(),
            pendingJoinRequestsOrCached(loaded = emptyList(), cached = cachedRequests),
        )
    }

    @Test
    fun emptyAuthoritativeListingDoesNotPruneFolds() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(
            folds,
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = emptySet(),
                listedAuthoritative = true,
            ),
        )
        assertEquals(
            emptyMap(),
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = setOf("other-room"),
                listedAuthoritative = true,
            ),
        )
    }

    @Test
    fun deleteAfterFoldDropsTheHiddenHistoricalSibling() {
        val folds = mapOf("group-08" to "group-09")
        assertEquals(setOf("group-08", "group-09"), foldFamilyIds("group-09", folds))
        assertEquals(setOf("group-08", "group-09"), foldFamilyIds("group-08", folds))
        assertEquals(setOf("group-09"), foldFamilyIds("group-09", emptyMap()))
        assertTrue(conversationsMatchFoldFamily("group-08", "group-09", folds))
        assertTrue(conversationsMatchFoldFamily("group-09", "group-08", folds))
        assertTrue(conversationsMatchFoldFamily("group-09", "group-09", folds))
        assertFalse(conversationsMatchFoldFamily("group-08", "other", folds))
        assertFalse(conversationsMatchFoldFamily("group-08", "group-09", emptyMap()))
        assertTrue(
            groupInfoShouldReloadPending(
                openGroupInfoChatId = "group-09",
                changedId = "group-08",
                historicalFolds = folds,
            ),
        )
        assertTrue(
            groupInfoShouldReloadPending(
                openGroupInfoChatId = "group-09",
                changedId = "group-09",
                historicalFolds = folds,
            ),
        )
        assertFalse(
            groupInfoShouldReloadPending(
                openGroupInfoChatId = "group-09",
                changedId = "other",
                historicalFolds = folds,
            ),
        )
        assertFalse(
            groupInfoShouldReloadPending(
                openGroupInfoChatId = null,
                changedId = "group-08",
                historicalFolds = folds,
            ),
        )
        assertEquals(emptyMap(), purgedHistoricalFolds(folds, setOf("group-09")))
        assertEquals(folds, purgedHistoricalFolds(folds, setOf("unrelated")))
        assertEquals(
            emptyMap(),
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = setOf("other-room"),
                listedAuthoritative = true,
            ),
        )
        assertEquals(
            folds,
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = setOf("group-09"),
                listedAuthoritative = true,
            ),
        )
        assertEquals(
            folds,
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = emptySet(),
                listedAuthoritative = false,
            ),
        )
        assertEquals(
            folds,
            prunedOrphanedHistoricalFolds(
                folds = folds,
                listedIds = emptySet(),
                listedAuthoritative = true,
            ),
        )
        val historical = SonarChat(id = "group-08", name = "room", members = listOf("npub1a"), isDirect = false)
        val live = SonarChat(id = "group-09", name = "room", members = listOf("npub1a"), isDirect = false)
        val leftover = listOf(historical, live).filterNot { it.id in foldFamilyIds("group-09", folds) }
        assertEquals(emptyList(), leftover)
        assertEquals(listOf("group-08"), leaveFamilyCorePurgeIds("group-09", folds))
        assertEquals(listOf("group-09"), leaveFamilyCorePurgeIds("group-08", folds))
        assertEquals(emptyList(), leaveFamilyCorePurgeIds("group-09", emptyMap()))
        assertEquals(
            listOf("group-08", "group-09"),
            deletedConversationCorePurgeIds(listOf("group-09"), folds),
        )
        assertEquals(
            listOf("group-09"),
            deletedConversationCorePurgeIds(listOf("group-09"), emptyMap()),
        )
        assertEquals(
            listOf(historical),
            collapsedFoldedSnapshotChats(
                chats = listOf(historical),
                historicalFolds = purgedHistoricalFolds(folds, setOf("group-09")),
            ),
        )
    }

    @Test
    fun foldedHistoricalComposerReplyMovesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val historical = SonarReplyRef(parentId = "evt-08", preview = "quote")
        val live = SonarReplyRef(parentId = "evt-09", preview = "newer")
        assertEquals(
            mapOf("group-08" to historical, "group-09" to historical),
            promotedFoldedComposerReplies(
                previousIds = setOf("group-08", "group-09"),
                currentIds = setOf("group-09"),
                replies = mapOf("group-08" to historical),
                liveFoldTarget = folds::get,
            ),
        )
        assertEquals(
            mapOf("group-08" to historical, "group-09" to live),
            promotedFoldedComposerReplies(
                previousIds = emptySet(),
                currentIds = setOf("group-09"),
                replies = mapOf("group-08" to historical, "group-09" to live),
                liveFoldTarget = folds::get,
            ),
        )
    }

    @Test
    fun recoveredRoomWithOneKnownPeerDoesNotFoldOntoDirect() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf(ownNpub, peerNpub), isDirect = true)
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
        assertEquals(
            "pending room",
            marmotChatDisplayTitle(
                isDirect = false,
                name = "pending room",
                otherMemberCount = 1,
                profileName = "Bob",
                npubFallback = "npub1bob…",
            ),
        )
        assertEquals(
            "Bob",
            marmotChatDisplayTitle(
                isDirect = true,
                name = "bob dm",
                otherMemberCount = 1,
                profileName = "Bob",
                npubFallback = "npub1bob…",
            ),
        )
        assertEquals(
            "standup",
            marmotChatDisplayTitle(
                isDirect = false,
                name = "standup",
                otherMemberCount = 1,
                profileName = "Bob",
                npubFallback = "npub1bob…",
            ),
        )
        assertEquals(
            "Group chat",
            marmotChatDisplayTitle(
                isDirect = false,
                name = "",
                otherMemberCount = 2,
                profileName = "Bob",
                npubFallback = "npub1bob…",
            ),
        )
    }

    @Test
    fun emptyTopicResumedRoomDoesNotFoldOntoWelcomerDm() {
        val ownRaw = ByteArray(32) { 1 }
        val peerRaw = ByteArray(32) { 2 }
        val ownNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", ownRaw)!!
        val peerNpub = chat.bitchat.sonar.crypto.Bech32.encode("npub", peerRaw)!!
        val dm = SonarChat(id = "bob-dm", name = "bob dm", members = listOf(ownNpub, peerNpub), isDirect = true)
        // Live sibling after an empty-topic 3-person resume: two MLS members,
        // empty name. FFI reports is_direct=false. Omitting the host flag
        // must stay a room — the in-memory default used to be true (R-045).
        val resumedRoom = SonarChat(
            id = "empty-topic-live",
            name = "",
            members = listOf(ownNpub, peerNpub),
        )

        val visible = dedupeDirectMarmotChats(
            chats = listOf(dm, resumedRoom),
            ownNpub = ownNpub,
            latestSecs = { if (it == dm.id) 2L else 1L },
        )

        assertEquals(listOf(dm, resumedRoom), visible)
        assertEquals(null, directMarmotPeerKey(resumedRoom, ownNpub))
        assertEquals(peerNpub, directMarmotPeerKey(dm, ownNpub))
        assertEquals(dm.id, directMarmotChatIdForPeer(listOf(resumedRoom, dm), ownNpub, peerNpub))
        assertEquals(null, marmotNotificationGroupName(resumedRoom))
        assertEquals(
            "Group chat",
            marmotChatDisplayTitle(
                isDirect = resumedRoom.isDirect,
                name = resumedRoom.name,
                otherMemberCount = 1,
                profileName = "Bob",
                npubFallback = "npub1bob…",
            ),
        )
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
        // FFI hides the folded 0.8 id, so listed duplicates go back to 1.
        // Rooms never have listed 1:1 duplicates. The hist→live blob is
        // the live sibling.
        assertTrue(
            recoveredChatHasLiveFoldSibling(
                chatId = "group-08",
                listedDuplicateCount = 1,
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        assertTrue(
            recoveredChatHasLiveFoldSibling(
                chatId = "group-09",
                listedDuplicateCount = 1,
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        assertFalse(
            recoveredChatHasLiveFoldSibling(
                chatId = "group-08",
                listedDuplicateCount = 1,
                historicalFolds = emptyMap(),
            ),
        )
        assertTrue(
            recoveredChatHasLiveFoldSibling(
                chatId = "group-08",
                listedDuplicateCount = 2,
                historicalFolds = emptyMap(),
            ),
        )
        assertEquals(
            setOf("other"),
            remountClearsRecoveredWaitingFlag(
                needsUpdate = setOf("group-08", "other"),
                historicalId = "group-08",
                liveId = "group-09",
            ),
        )
        assertEquals(
            emptySet(),
            remountClearsRecoveredWaitingFlag(
                needsUpdate = setOf("group-08", "group-09"),
                historicalId = "group-08",
                liveId = "group-09",
            ),
        )
        assertTrue(marmotSendNeedsPeerUpdate("no key package found on relays for npub1abc"))
        assertEquals(
            "Waiting for them to update Sonar",
            marmotSendUserMessage("no key package found on relays for npub1abc"),
        )
        assertEquals(
            "Send a message first to resume this chat, then invite",
            marmotInviteUserMessage("this recovered chat cannot invite until it is resumed"),
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
