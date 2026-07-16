package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.ExchangeRate
import chat.bitchat.sonar.wallet.FiatCurrency
import chat.bitchat.sonar.wallet.WalletState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class HomeMessageRowsTest {

    @Test
    fun pendingPanicWipeSkipsOldAccountLoadsAndKeepsFirstFrameRedacted() {
        val reads = mutableListOf<String>()
        val oldChat = loadInitialAccountState(
            panicWipePending = true,
            redacted = "",
        ) {
            reads += "chat"
            "old transcript"
        }
        val onboarded = recoverInitialOnboardingState(
            panicWipePending = true,
            readStored = { reads += "onboarding"; true },
            hasIdentity = { reads += "identity"; true },
            persistRecovered = { reads += "migration" },
        )

        assertEquals("", oldChat)
        assertFalse(onboarded)
        assertTrue(reads.isEmpty())
        assertFalse(isFirstLocalStateReady(
            panicWipeRecoveryPending = true,
            onboarded = onboarded,
            locked = false,
            homeMessagesHydrated = false,
        ))
    }

    @Test
    fun pendingPanicMarkerRunsRecoveryWithoutStartingIdentityOrMesh() {
        val events = mutableListOf<String>()

        runAccountColdStart(
            panicWipePending = true,
            onboarded = false,
            recoverPendingWipe = { events += "recover" },
            activateAccount = {
                events += "identity"
                events += "mesh"
            },
        )

        assertEquals(listOf("recover"), events)
        assertFalse(canStartAccountServices(
            panicWipePending = true,
            onboarded = true,
            accountStarted = true,
        ))
    }

    @Test
    fun accountAndMeshActivationWaitForSuccessfulRecoveryAndAccountBoot() {
        val events = mutableListOf<String>()

        runAccountColdStart(
            panicWipePending = false,
            onboarded = true,
            recoverPendingWipe = { events += "recover" },
            activateAccount = { events += "boot" },
        )

        assertEquals(listOf("boot"), events)
        assertFalse(canStartAccountServices(false, onboarded = true, accountStarted = false))
        assertTrue(canStartAccountServices(false, onboarded = true, accountStarted = true))
    }

    @Test
    fun pendingPanicMarkerSkipsEveryWalletConstructionRead() {
        val reads = mutableListOf<String>()

        val wallet = loadInitialWalletAccountState(
            panicWipePending = true,
            loadState = { reads += "state"; WalletState.Ready(42) },
            loadShowFiat = { reads += "showFiat"; true },
            loadCurrency = { reads += "currency"; FiatCurrency.CHF },
            loadRate = { reads += "rate"; ExchangeRate(it.code, 1.0) },
        )

        assertEquals(WalletState.NotConfigured, wallet.state)
        assertFalse(wallet.showFiat)
        assertEquals(FiatCurrency.USD, wallet.currency)
        assertEquals(null, wallet.rate)
        assertTrue(reads.isEmpty())
    }

    @Test
    fun normalColdStartLoadsAccountStateAndRecoversOnboarding() {
        val reads = mutableListOf<String>()
        val oldChat = loadInitialAccountState(
            panicWipePending = false,
            redacted = "",
        ) {
            reads += "chat"
            "old transcript"
        }
        val onboarded = recoverInitialOnboardingState(
            panicWipePending = false,
            readStored = { reads += "onboarding"; false },
            hasIdentity = { reads += "identity"; true },
            persistRecovered = { reads += "migration" },
        )

        assertEquals("old transcript", oldChat)
        assertTrue(onboarded)
        assertEquals(listOf("chat", "onboarding", "identity", "migration"), reads)
    }

    @Test
    fun unlockedAccountWaitsForCoherentLocalHomeBeforeFirstPaint() {
        assertFalse(isFirstLocalStateReady(false, onboarded = true, locked = false, homeMessagesHydrated = false))
        assertTrue(isFirstLocalStateReady(false, onboarded = true, locked = false, homeMessagesHydrated = true))
        assertTrue(isFirstLocalStateReady(false, onboarded = true, locked = true, homeMessagesHydrated = false))
        assertTrue(isFirstLocalStateReady(false, onboarded = false, locked = false, homeMessagesHydrated = false))
    }

    private fun mesh(peerId: String, ts: Long) =
        MeshDmRow(peerId = peerId, name = peerId, preview = "m", tsSecs = ts)

    private fun chat(id: String) =
        SonarChat(id = id, name = id, members = emptyList())

    @Test
    fun mergesMeshAndMarmotByRecencyDescending() {
        val meshRows = listOf(mesh("ble-old", 100), mesh("ble-new", 300))
        val chatRows = listOf(chat("g-mid"), chat("g-newest"))
        val ts = mapOf("g-mid" to 200L, "g-newest" to 400L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals(
            listOf("g-newest", "mesh:ble-new", "g-mid", "mesh:ble-old"),
            merged.map { it.listKey },
        )
    }

    @Test
    fun pendingCreationTimeSortsAboveOlderHistory() {
        // Freshly-started pending chat (createdAt=500) must not sink under a
        // mesh conversation from last week (ts=100) — iOS dmRows parity.
        val meshRows = listOf(mesh("old-ble", 100))
        val chatRows = listOf(chat("npub:pending"))
        val ts = mapOf("npub:pending" to 500L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals("npub:pending", merged.first().listKey)
        assertIs<HomeMessageRow.Marmot>(merged.first())
    }

    @Test
    fun zeroTsWithoutCreationTimeSortsLast() {
        val meshRows = listOf(mesh("active", 50))
        val chatRows = listOf(chat("empty"))
        val merged = mergeHomeMessageRows(meshRows, chatRows) { 0L }
        assertEquals("mesh:active", merged.first().listKey)
        assertEquals("empty", merged.last().listKey)
    }

    @Test
    fun listKeysAreNamespacedPerTransport() {
        val merged = mergeHomeMessageRows(
            listOf(mesh("abc", 1)),
            listOf(chat("group-1")),
        ) { 1L }
        assertTrue(merged.any { it.listKey == "mesh:abc" })
        assertTrue(merged.any { it.listKey == "group-1" })
    }

    @Test
    fun localHydrationUsesPreviousPaintOrderAsRecencyTieBreaker() {
        val chats = listOf(chat("same-old"), chat("newest"), chat("same-new"), chat("new-row"))
        val timestamps = mapOf(
            "newest" to 300L,
            "same-old" to 200L,
            "same-new" to 200L,
            "new-row" to 0L,
        )

        val ordered = orderChatsByLocalRecency(
            chats = chats,
            latestSecs = { timestamps[it] ?: 0L },
            previousOrder = listOf("newest", "same-new", "same-old"),
        )

        assertEquals(
            listOf("newest", "same-new", "same-old", "new-row"),
            ordered.map { it.id },
        )
    }

    @Test
    fun restoredMetadataKeepsMixedTransportRowsInRecencyOrder() {
        val newest = chat("marmot-new")
        val oldest = chat("marmot-old")
        val blob = encodeChatSnapshot(
            chats = listOf(newest, oldest),
            messagesByChat = emptyMap(),
            latestByChat = mapOf(newest.id to 300L, oldest.id to 100L),
        )
        val restoredChats = decodeChatSnapshot(blob).first
        val restoredLatest = decodeChatSnapshotLatest(blob)

        val merged = mergeHomeMessageRows(
            meshRows = listOf(mesh("mesh-middle", 200L)),
            chatRows = restoredChats,
            marmotTsSecs = { restoredLatest[it] ?: 0L },
        )

        assertEquals(
            listOf("marmot-new", "mesh:mesh-middle", "marmot-old"),
            merged.map { it.listKey },
        )
    }

    @Test
    fun conversationIndexHydratesRowsOutsideBoundedTranscriptWindow() {
        val summaries = listOf(
            SonarConversationSummary("paged", "", "summary paged", "peer", 400L, false, 2L, 0L),
            SonarConversationSummary("outside", "", "outside preview", "peer", 300L, false, 1L, 0L),
        )
        val pageMessage = SonarMsg("page-msg", "peer", "page preview", false, 400L, viaInternet = true)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("paged", "outside"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = summaries,
            pages = listOf(SonarRecentTranscriptPage("paged", 400L, listOf(pageMessage))),
        )

        assertEquals(300L, hydration.latestByChat["outside"])
        assertEquals("outside preview", hydration.messagesByChat["outside"]?.single()?.content)
        assertEquals(listOf(pageMessage), hydration.messagesByChat["paged"])
    }

    @Test
    fun sameSecondSummaryRefreshesWhenLatestContentChanges() {
        val old = SonarMsg("summary:chat:42:1", "peer", "old", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "new", "peer", 42L, false, 2L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(old)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals("new", hydration.messagesByChat["chat"]?.single()?.content)
        assertEquals("summary:chat:42:2", hydration.messagesByChat["chat"]?.single()?.id)
    }

    @Test
    fun sameSecondSummaryRefreshesSyntheticIdentityWhenCountChanges() {
        val old = SonarMsg("summary:chat:42:1", "peer", "same", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "same", "peer", 42L, false, 2L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(old)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals("summary:chat:42:2", hydration.messagesByChat["chat"]?.single()?.id)
    }

    @Test
    fun matchingRealPageRowIsNotReplacedBySyntheticSummary() {
        val pageRow = SonarMsg("real-message", "peer", "same", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "same", "peer", 42L, false, 3L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(pageRow)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals(listOf(pageRow), hydration.messagesByChat["chat"])
    }
}
