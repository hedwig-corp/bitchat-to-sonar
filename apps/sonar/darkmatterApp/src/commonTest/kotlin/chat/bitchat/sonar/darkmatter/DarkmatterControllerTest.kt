package chat.bitchat.sonar.darkmatter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class DarkmatterControllerTest {
    @Test
    fun paintsLocalChatsBeforeRelayConnectCompletes() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            conversations += CHAT
            connectGate = CompletableDeferred()
        }
        val controller = controller(backend, InMemoryPendingStore())

        controller.start()
        runCurrent()

        assertTrue(controller.state.value.localReady)
        assertFalse(controller.state.value.connected)
        assertEquals(listOf(CHAT.id), controller.state.value.conversations.map { it.id })

        backend.connectGate.complete(Unit)
        runCurrent()
        assertTrue(controller.state.value.connected)
    }

    @Test
    fun pendingStoreFailureDoesNotBlockLocalChatPaint() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            conversations += CHAT
            connectGate = CompletableDeferred()
        }
        val store = InMemoryPendingStore().apply { loadFailure = IllegalStateException("corrupt") }
        val controller = controller(backend, store)

        controller.start()
        runCurrent()

        assertTrue(controller.state.value.localReady)
        assertEquals(ACCOUNT, controller.state.value.account)
        assertEquals(listOf(CHAT.id), controller.state.value.conversations.map { it.id })
        assertTrue(controller.state.value.error?.contains("encrypted pending outbox") == true)
    }

    @Test
    fun pendingConversationPaintsAndQueuesBeforeNetworkSetup() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            connectGate.complete(Unit)
            createGate = CompletableDeferred()
        }
        val store = InMemoryPendingStore()
        val controller = controller(backend, store)
        controller.start()
        runCurrent()

        controller.beginConversation(PEER_NPUB, "Alice")
        val pendingId = controller.state.value.selectedConversationId
        assertNotNull(pendingId)
        assertTrue(controller.state.value.conversations.single { it.id == pendingId }.isPendingSetup)

        controller.sendMessage("hello before relays")
        assertEquals(DarkmatterDelivery.QUEUED, controller.state.value.messages.single().delivery)
        runCurrent()
        assertEquals("hello before relays", store.value.single().messages.single().text)

        requireNotNull(backend.createGate).complete("group-1")
        runCurrent()

        assertEquals(listOf("group-1" to "hello before relays"), backend.sent)
        assertEquals("group-1", controller.state.value.selectedConversationId)
        assertTrue(store.value.isEmpty())
    }

    @Test
    fun failedSetupSurvivesAndCanBeRetried() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            connectGate.complete(Unit)
            failCreate = true
        }
        val store = InMemoryPendingStore()
        val controller = controller(backend, store)
        controller.start()
        runCurrent()

        controller.beginConversation(PEER_NPUB, "Retry chat")
        runCurrent()

        val persisted = store.value.single()
        assertNotNull(persisted.setupError)
        assertNotNull(controller.state.value.conversations.single().setupError)

        backend.failCreate = false
        controller.retryPending(persisted.id)
        runCurrent()

        assertTrue(store.value.isEmpty())
        assertTrue(controller.state.value.conversations.any { it.id == "group-1" })
    }

    @Test
    fun pendingQueueIsBounded() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            connectGate.complete(Unit)
            createGate = CompletableDeferred()
        }
        val controller = controller(backend, InMemoryPendingStore())
        controller.start()
        runCurrent()
        controller.beginConversation(PEER_NPUB, "Bounded")

        repeat(DarkmatterController.MAX_QUEUED_MESSAGES + 1) { controller.sendMessage("message-$it") }

        assertEquals(DarkmatterController.MAX_QUEUED_MESSAGES, controller.state.value.messages.size)
        assertEquals("This pending chat queue is full.", controller.state.value.error)
    }

    @Test
    fun successfulSendReconcilesOptimisticMessageWithStoredMessage() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            conversations += CHAT
            connectGate.complete(Unit)
        }
        val controller = controller(backend, InMemoryPendingStore())
        controller.start()
        runCurrent()
        controller.selectConversation(CHAT.id)
        runCurrent()

        controller.sendMessage("one visible copy")
        runCurrent()

        assertEquals(1, controller.state.value.messages.size)
        assertEquals("one visible copy", controller.state.value.messages.single().text)
        assertEquals(DarkmatterDelivery.DELIVERED, controller.state.value.messages.single().delivery)
    }

    @Test
    fun failedQueuedSendCanBeRetriedFromResolvedGroupRow() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            connectGate.complete(Unit)
            failSend = true
        }
        val store = InMemoryPendingStore()
        val controller = controller(backend, store)
        controller.start()
        runCurrent()

        controller.beginConversation(PEER_NPUB, "Retry resolved")
        controller.sendMessage("retry me")
        runCurrent()

        assertNotNull(controller.state.value.conversations.single { it.id == "group-1" }.setupError)
        assertEquals("group-1", controller.state.value.selectedConversationId)
        assertEquals("group-1", store.value.single().resolvedGroupId)

        backend.failSend = false
        controller.retryPending("group-1")
        runCurrent()

        assertTrue(store.value.isEmpty())
        assertEquals(listOf("group-1" to "retry me"), backend.sent)
    }

    @Test
    fun olderPageCannotRepopulateAClosedConversation() = runTest {
        val backend = FakeBackend().apply {
            accounts += ACCOUNT
            conversations += CHAT
            messages[CHAT.id] = mutableListOf(
                DarkmatterMessage("message-1", "cached", ACCOUNT.npub, true, 100, DarkmatterDelivery.DELIVERED),
            )
            hasMoreBefore = true
            connectGate.complete(Unit)
        }
        val controller = controller(backend, InMemoryPendingStore())
        controller.start()
        runCurrent()
        controller.selectConversation(CHAT.id)
        runCurrent()
        backend.beforeLocalMessages = {
            backend.beforeLocalMessages = null
            controller.closeConversation()
        }

        controller.loadOlder()
        runCurrent()

        assertNull(controller.state.value.selectedConversationId)
        assertTrue(controller.state.value.messages.isEmpty())
    }

    private fun kotlinx.coroutines.test.TestScope.controller(
        backend: FakeBackend,
        store: InMemoryPendingStore,
    ): DarkmatterController {
        var id = 0
        return DarkmatterController(
            backend = backend,
            pendingStore = store,
            scope = backgroundScope,
            nowSeconds = { 1_700_000_000L + id },
            idFactory = { "local-${id++}" },
        )
    }

    private class InMemoryPendingStore : PendingConversationStore {
        var value: List<PendingConversation> = emptyList()
        var loadFailure: Throwable? = null

        override suspend fun load(): List<PendingConversation> = loadFailure?.let { throw it } ?: value

        override suspend fun save(conversations: List<PendingConversation>) {
            value = conversations
        }
    }

    private class FakeBackend : DarkmatterBackend {
        val accounts = mutableListOf<DarkmatterAccount>()
        val conversations = mutableListOf<DarkmatterConversation>()
        val messages = mutableMapOf<String, MutableList<DarkmatterMessage>>()
        val sent = mutableListOf<Pair<String, String>>()
        val conversationEvents = MutableSharedFlow<Unit>()
        val messageEvents = MutableSharedFlow<Unit>()
        var connectGate = CompletableDeferred<Unit>()
        var createGate: CompletableDeferred<String>? = null
        var failCreate = false
        var failSend = false
        var hasMoreBefore = false
        var beforeLocalMessages: (() -> Unit)? = null

        override fun localAccounts(): List<DarkmatterAccount> = accounts.toList()

        override fun localConversations(accountReference: String): List<DarkmatterConversation> =
            conversations.toList()

        override fun localMessages(
            accountReference: String,
            groupId: String,
            beforeTimestampSeconds: Long?,
            beforeMessageId: String?,
            limit: Int,
        ): DarkmatterMessagePage {
            beforeLocalMessages?.invoke()
            return DarkmatterMessagePage(
                messages = messages[groupId].orEmpty().takeLast(limit),
                hasMoreBefore = hasMoreBefore,
            )
        }

        override suspend fun connect() {
            connectGate.await()
        }

        override suspend fun createIdentity(): DarkmatterAccount = ACCOUNT.also(accounts::add)

        override suspend fun createGroup(
            accountReference: String,
            memberReference: String,
            title: String,
        ): String {
            if (failCreate) error("relay setup failed")
            val groupId = createGate?.await() ?: "group-1"
            conversations.removeAll { it.id == groupId }
            conversations += DarkmatterConversation(groupId, title, "", 1_700_000_001L)
            return groupId
        }

        override suspend fun sendText(accountReference: String, groupId: String, text: String) {
            if (failSend) error("relay send failed")
            sent += groupId to text
            messages.getOrPut(groupId, ::mutableListOf) += DarkmatterMessage(
                id = "remote-${sent.size}",
                text = text,
                sender = ACCOUNT.npub,
                isOwn = true,
                timestampSeconds = 1_700_000_100L + sent.size,
                delivery = DarkmatterDelivery.DELIVERED,
            )
        }

        override suspend fun acceptInvite(accountReference: String, groupId: String) = Unit

        override suspend fun declineInvite(accountReference: String, groupId: String) = Unit

        override fun conversationChanges(accountReference: String): Flow<Unit> = conversationEvents

        override fun messageChanges(accountReference: String, groupId: String): Flow<Unit> = messageEvents

        override suspend fun shutdown() = Unit
    }

    companion object {
        private val ACCOUNT = DarkmatterAccount("account-1", "ab".repeat(32), "npub1account")
        private val CHAT = DarkmatterConversation("group-local", "Local chat", "cached", 100)
        private const val PEER_NPUB = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpqq"
    }
}
