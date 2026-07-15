package chat.bitchat.sonar.darkmatter

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class DarkmatterController(
    private val backend: DarkmatterBackend,
    private val pendingStore: PendingConversationStore,
    private val scope: CoroutineScope,
    private val nowSeconds: () -> Long,
    private val idFactory: () -> String,
) {
    private val _state = MutableStateFlow(DarkmatterUiState())
    val state: StateFlow<DarkmatterUiState> = _state.asStateFlow()

    private val pending = MutableStateFlow<List<PendingConversation>>(emptyList())
    private val connectionMutex = Mutex()
    private val pendingDriveMutex = Mutex()
    private val pendingStoreMutex = Mutex()
    private var started = false
    private var connected = false
    private var conversationSubscription: Job? = null
    private var messageSubscription: Job? = null

    fun start() {
        if (started) return
        started = true
        scope.launch {
            try {
                val pendingLoadError = try {
                    pending.value = pendingStore.load()
                        .take(MAX_PENDING_CONVERSATIONS)
                        .map(::sanitizePendingConversation)
                    null
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    "The encrypted pending outbox could not be restored. Existing chats are still available."
                }
                val account = backend.localAccounts().firstOrNull()
                _state.update {
                    it.copy(
                        localReady = true,
                        account = account,
                        conversations = mergedConversations(),
                        error = pendingLoadError,
                    )
                }
                if (account != null) refreshConversations(account)
                connectAndObserve(account)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update {
                    it.copy(localReady = true, connecting = false, error = error.safeMessage())
                }
            }
        }
    }

    fun retryConnection() {
        scope.launch {
            _state.update { it.copy(error = null) }
            connectAndObserve(_state.value.account)
        }
    }

    fun createIdentity() {
        if (_state.value.creatingIdentity) return
        scope.launch {
            _state.update { it.copy(creatingIdentity = true, error = null) }
            try {
                ensureConnected()
                val account = backend.createIdentity()
                _state.update { it.copy(account = account, creatingIdentity = false) }
                refreshConversations(account)
                observeConversations(account)
                resumePendingWork()
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update {
                    it.copy(creatingIdentity = false, error = error.safeMessage())
                }
            }
        }
    }

    fun beginConversation(memberReference: String, title: String) {
        val member = memberReference.trim()
        if (member.isEmpty()) {
            _state.update { it.copy(error = "Enter an npub or public key.") }
            return
        }
        if (member.length > MAX_MEMBER_REFERENCE_LENGTH) {
            _state.update { it.copy(error = "The member reference is too long.") }
            return
        }
        if (pending.value.count { it.resolvedGroupId == null } >= MAX_PENDING_CONVERSATIONS) {
            _state.update { it.copy(error = "Too many conversations are waiting for setup.") }
            return
        }

        val createdAt = nowSeconds()
        val conversation = PendingConversation(
            id = idFactory(),
            memberReference = member,
            title = title.trim().ifEmpty { "Darkmatter chat" }.take(MAX_TITLE_LENGTH),
            createdAtSeconds = createdAt,
        )
        pending.update { it + conversation }
        _state.update {
            it.copy(
                selectedConversationId = conversation.id,
                messages = emptyList(),
                conversations = mergedConversations(),
                error = null,
            )
        }
        scope.launch {
            persistPending()
            drivePending(conversation.id)
        }
    }

    fun selectConversation(id: String) {
        messageSubscription?.cancel()
        val pendingConversation = pending.value.firstOrNull { it.id == id && it.resolvedGroupId == null }
        if (pendingConversation != null) {
            _state.update {
                it.copy(
                    selectedConversationId = id,
                    messages = pendingConversation.messages.map { message -> message.asUiMessage() },
                    hasMoreBefore = false,
                    error = null,
                )
            }
            return
        }

        val account = _state.value.account ?: return
        _state.update { it.copy(selectedConversationId = id, messages = emptyList(), error = null) }
        scope.launch {
            refreshMessages(account, id, replaceLatest = true)
            if (_state.value.selectedConversationId == id) observeMessages(account, id)
        }
    }

    fun closeConversation() {
        messageSubscription?.cancel()
        messageSubscription = null
        _state.update {
            it.copy(
                selectedConversationId = null,
                messages = emptyList(),
                hasMoreBefore = false,
                loadingOlder = false,
            )
        }
    }

    fun sendMessage(text: String) {
        val body = text.trim()
        if (body.isEmpty()) return
        if (body.length > MAX_MESSAGE_LENGTH) {
            _state.update { it.copy(error = "Messages are limited to $MAX_MESSAGE_LENGTH characters.") }
            return
        }

        val selectedId = _state.value.selectedConversationId ?: return
        val pendingConversation = pending.value.firstOrNull {
            it.id == selectedId && it.resolvedGroupId == null
        }
        if (pendingConversation != null) {
            if (pendingConversation.messages.size >= MAX_QUEUED_MESSAGES) {
                _state.update { it.copy(error = "This pending chat queue is full.") }
                return
            }
            val pendingMessage = PendingMessage(
                id = idFactory(),
                text = body,
                createdAtSeconds = nowSeconds(),
            )
            pending.update { conversations ->
                conversations.map {
                    if (it.id == selectedId) {
                        it.copy(messages = it.messages + pendingMessage, setupError = null)
                    } else {
                        it
                    }
                }
            }
            _state.update {
                it.copy(
                    messages = it.messages + pendingMessage.asUiMessage(),
                    conversations = mergedConversations(),
                    error = null,
                )
            }
            scope.launch {
                persistPending()
                drivePending(selectedId)
            }
            return
        }

        val account = _state.value.account ?: return
        val optimistic = DarkmatterMessage(
            id = idFactory(),
            text = body,
            sender = account.npub,
            isOwn = true,
            timestampSeconds = nowSeconds(),
            delivery = DarkmatterDelivery.SENDING,
        )
        _state.update { it.copy(messages = it.messages + optimistic, error = null) }
        scope.launch {
            try {
                ensureConnected()
                backend.sendText(account.reference, selectedId, body)
                _state.update { current ->
                    current.copy(messages = current.messages.filterNot { it.id == optimistic.id })
                }
                refreshMessages(account, selectedId, replaceLatest = true)
                refreshConversations(account)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update {
                    it.copy(
                        messages = it.messages.map { message ->
                            if (message.id == optimistic.id) {
                                message.copy(delivery = DarkmatterDelivery.FAILED)
                            } else {
                                message
                            }
                        },
                        error = error.safeMessage(),
                    )
                }
            }
        }
    }

    fun retryPending(id: String) {
        val pendingId = pending.value.firstOrNull {
            it.id == id || it.resolvedGroupId == id
        }?.id ?: id
        pending.update { conversations ->
            conversations.map { conversation ->
                if (conversation.id == pendingId) {
                    conversation.copy(
                        setupError = null,
                        messages = conversation.messages.map { message ->
                            if (message.delivery == DarkmatterDelivery.FAILED) {
                                message.copy(delivery = DarkmatterDelivery.QUEUED, error = null)
                            } else {
                                message
                            }
                        },
                    )
                } else {
                    conversation
                }
            }
        }
        _state.update { it.copy(conversations = mergedConversations(), error = null) }
        scope.launch {
            persistPending()
            drivePending(pendingId)
        }
    }

    fun acceptInvite(groupId: String) {
        val account = _state.value.account ?: return
        scope.launch {
            try {
                ensureConnected()
                backend.acceptInvite(account.reference, groupId)
                refreshConversations(account)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(error = error.safeMessage()) }
            }
        }
    }

    fun declineInvite(groupId: String) {
        val account = _state.value.account ?: return
        scope.launch {
            try {
                ensureConnected()
                backend.declineInvite(account.reference, groupId)
                if (_state.value.selectedConversationId == groupId) closeConversation()
                refreshConversations(account)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(error = error.safeMessage()) }
            }
        }
    }

    fun loadOlder() {
        val current = _state.value
        val account = current.account ?: return
        val groupId = current.selectedConversationId ?: return
        if (current.loadingOlder || !current.hasMoreBefore || current.messages.isEmpty()) return
        if (pending.value.any { it.id == groupId && it.resolvedGroupId == null }) return

        val oldest = current.messages.minWithOrNull(
            compareBy<DarkmatterMessage> { it.timestampSeconds }.thenBy { it.id },
        ) ?: return
        _state.update { it.copy(loadingOlder = true) }
        scope.launch {
            try {
                val page = backend.localMessages(
                    accountReference = account.reference,
                    groupId = groupId,
                    beforeTimestampSeconds = oldest.timestampSeconds,
                    beforeMessageId = oldest.id,
                    limit = PAGE_SIZE,
                )
                val combined = (page.messages + _state.value.messages)
                    .distinctBy { it.id }
                    .sortedWith(messageOrder)
                    .takeLast(MAX_RENDERED_MESSAGES)
                _state.update { latest ->
                    if (latest.selectedConversationId != groupId) return@update latest
                    latest.copy(
                        messages = combined,
                        hasMoreBefore = page.hasMoreBefore,
                        loadingOlder = false,
                    )
                }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(loadingOlder = false, error = error.safeMessage()) }
            }
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun close() {
        scope.launch {
            try {
                backend.shutdown()
            } finally {
                scope.cancel()
            }
        }
    }

    private suspend fun connectAndObserve(account: DarkmatterAccount?) {
        try {
            ensureConnected()
            if (account != null) {
                refreshConversations(account)
                observeConversations(account)
                resumePendingWork()
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            _state.update {
                it.copy(connecting = false, connected = false, error = error.safeMessage())
            }
        }
    }

    private suspend fun ensureConnected() {
        connectionMutex.withLock {
            if (connected) return
            _state.update { it.copy(connecting = true) }
            backend.connect()
            connected = true
            _state.update { it.copy(connecting = false, connected = true) }
        }
    }

    private fun refreshConversations(account: DarkmatterAccount) {
        val local = backend.localConversations(account.reference)
        _state.update {
            it.copy(
                conversations = mergeLocalAndPending(local),
                account = account,
            )
        }
    }

    private fun mergedConversations(): List<DarkmatterConversation> {
        val local = _state.value.conversations.filterNot { it.isPendingSetup }
        return mergeLocalAndPending(local)
    }

    private fun mergeLocalAndPending(local: List<DarkmatterConversation>): List<DarkmatterConversation> {
        val resolved = pending.value.filter { it.resolvedGroupId != null }
        val resolvedByGroup = resolved.associateBy { requireNotNull(it.resolvedGroupId) }
        val localWithOutbox = local.map { conversation ->
            val queued = resolvedByGroup[conversation.id] ?: return@map conversation
            conversation.withPendingOutbox(queued)
        }
        val localIds = localWithOutbox.mapTo(mutableSetOf()) { it.id }
        val resolvedWithoutLocalRow = resolved.mapNotNull { queued ->
            val groupId = queued.resolvedGroupId ?: return@mapNotNull null
            if (groupId in localIds) return@mapNotNull null
            DarkmatterConversation(
                id = groupId,
                title = queued.title,
                preview = "Encrypted chat",
                updatedAtSeconds = queued.createdAtSeconds,
            ).withPendingOutbox(queued)
        }
        val unresolved = pending.value
            .filter { it.resolvedGroupId == null }
            .map { conversation ->
                DarkmatterConversation(
                    id = conversation.id,
                    title = conversation.title,
                    preview = conversation.messages.lastOrNull()?.text ?: "Setting up encrypted chat…",
                    updatedAtSeconds = conversation.messages.lastOrNull()?.createdAtSeconds
                        ?: conversation.createdAtSeconds,
                    isPendingSetup = true,
                    setupError = conversation.setupError,
                )
            }
        return (localWithOutbox + resolvedWithoutLocalRow + unresolved)
            .distinctBy { it.id }
            .sortedByDescending { it.updatedAtSeconds }
    }

    private fun DarkmatterConversation.withPendingOutbox(
        queued: PendingConversation,
    ): DarkmatterConversation {
        val latest = queued.messages.lastOrNull()
        return copy(
            preview = latest?.text ?: preview,
            updatedAtSeconds = maxOf(updatedAtSeconds, latest?.createdAtSeconds ?: queued.createdAtSeconds),
            setupError = queued.setupError,
        )
    }

    private fun refreshMessages(
        account: DarkmatterAccount,
        groupId: String,
        replaceLatest: Boolean,
    ) {
        if (_state.value.selectedConversationId != groupId) return
        val page = backend.localMessages(
            accountReference = account.reference,
            groupId = groupId,
            limit = PAGE_SIZE,
        )
        val queued = pending.value.firstOrNull { it.resolvedGroupId == groupId }
            ?.messages
            .orEmpty()
            .map { it.asUiMessage() }
        _state.update { current ->
            if (current.selectedConversationId != groupId) return@update current
            val base = if (replaceLatest) current.messages + page.messages + queued else page.messages + queued
            current.copy(
                messages = base
                    .distinctBy { it.id }
                    .sortedWith(messageOrder)
                    .takeLast(MAX_RENDERED_MESSAGES),
                hasMoreBefore = page.hasMoreBefore,
                loadingOlder = false,
            )
        }
    }

    private fun observeConversations(account: DarkmatterAccount) {
        conversationSubscription?.cancel()
        conversationSubscription = scope.launch {
            while (isActive) {
                try {
                    backend.conversationChanges(account.reference).collect {
                        refreshConversations(account)
                    }
                    break
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    delay(SUBSCRIPTION_RETRY_MS)
                }
            }
        }
    }

    private fun observeMessages(account: DarkmatterAccount, groupId: String) {
        messageSubscription?.cancel()
        messageSubscription = scope.launch {
            while (isActive && _state.value.selectedConversationId == groupId) {
                try {
                    backend.messageChanges(account.reference, groupId).collect {
                        refreshMessages(account, groupId, replaceLatest = true)
                    }
                    break
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    delay(SUBSCRIPTION_RETRY_MS)
                }
            }
        }
    }

    private suspend fun resumePendingWork() {
        pending.value.forEach { drivePending(it.id) }
    }

    private suspend fun drivePending(id: String) {
        pendingDriveMutex.withLock {
            var conversation = pending.value.firstOrNull { it.id == id } ?: return
            val account = _state.value.account ?: return
            try {
                ensureConnected()
                var groupId = conversation.resolvedGroupId
                if (groupId == null) {
                    groupId = backend.createGroup(
                        accountReference = account.reference,
                        memberReference = conversation.memberReference,
                        title = conversation.title,
                    )
                    pending.update { conversations ->
                        conversations.map {
                            if (it.id == id) it.copy(resolvedGroupId = groupId, setupError = null) else it
                        }
                    }
                    if (_state.value.selectedConversationId == id) {
                        _state.update { it.copy(selectedConversationId = groupId) }
                    }
                    persistPending()
                    refreshConversations(account)
                    refreshMessages(account, groupId, replaceLatest = true)
                    observeMessages(account, groupId)
                }

                conversation = pending.value.firstOrNull { it.id == id } ?: return
                for (message in conversation.messages) {
                    if (message.delivery == DarkmatterDelivery.DELIVERED) continue
                    updatePendingMessage(id, message.id) {
                        it.copy(delivery = DarkmatterDelivery.SENDING, error = null)
                    }
                    persistPending()
                    try {
                        backend.sendText(account.reference, groupId, message.text)
                        removePendingMessage(id, message.id)
                        persistPending()
                        refreshMessages(account, groupId, replaceLatest = true)
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        updatePendingMessage(id, message.id) {
                            it.copy(delivery = DarkmatterDelivery.FAILED, error = error.safeMessage())
                        }
                        persistPending()
                        refreshMessages(account, groupId, replaceLatest = true)
                        throw error
                    }
                }

                if (pending.value.firstOrNull { it.id == id }?.messages.isNullOrEmpty()) {
                    pending.update { conversations -> conversations.filterNot { it.id == id } }
                    persistPending()
                    refreshConversations(account)
                }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                pending.update { conversations ->
                    conversations.map {
                        if (it.id == id) it.copy(setupError = error.safeMessage()) else it
                    }
                }
                persistPending()
                _state.update {
                    it.copy(
                        conversations = mergedConversations(),
                        error = error.safeMessage(),
                    )
                }
            }
        }
    }

    private fun updatePendingMessage(
        conversationId: String,
        messageId: String,
        transform: (PendingMessage) -> PendingMessage,
    ) {
        pending.update { conversations ->
            conversations.map { conversation ->
                if (conversation.id == conversationId) {
                    conversation.copy(
                        messages = conversation.messages.map { message ->
                            if (message.id == messageId) transform(message) else message
                        },
                    )
                } else {
                    conversation
                }
            }
        }
    }

    private fun removePendingMessage(conversationId: String, messageId: String) {
        pending.update { conversations ->
            conversations.map { conversation ->
                if (conversation.id == conversationId) {
                    conversation.copy(messages = conversation.messages.filterNot { it.id == messageId })
                } else {
                    conversation
                }
            }
        }
    }

    private suspend fun persistPending() {
        pendingStoreMutex.withLock {
            pendingStore.save(pending.value.take(MAX_PENDING_CONVERSATIONS))
        }
    }

    private fun sanitizePendingConversation(value: PendingConversation): PendingConversation = value.copy(
        memberReference = value.memberReference.take(MAX_MEMBER_REFERENCE_LENGTH),
        title = value.title.take(MAX_TITLE_LENGTH),
        messages = value.messages
            .takeLast(MAX_QUEUED_MESSAGES)
            .map { it.copy(text = it.text.take(MAX_MESSAGE_LENGTH)) },
    )

    private fun PendingMessage.asUiMessage(): DarkmatterMessage = DarkmatterMessage(
        id = id,
        text = text,
        sender = _state.value.account?.npub ?: "You",
        isOwn = true,
        timestampSeconds = createdAtSeconds,
        delivery = delivery,
    )

    private fun Throwable.safeMessage(): String = message
        ?.takeIf { it.isNotBlank() }
        ?.take(MAX_ERROR_LENGTH)
        ?: "Darkmatter operation failed."

    companion object {
        const val PAGE_SIZE = 50
        const val MAX_RENDERED_MESSAGES = 250
        const val MAX_QUEUED_MESSAGES = 32
        const val MAX_PENDING_CONVERSATIONS = 16
        const val MAX_MESSAGE_LENGTH = 10_000
        const val MAX_MEMBER_REFERENCE_LENGTH = 512
        const val MAX_TITLE_LENGTH = 120
        private const val MAX_ERROR_LENGTH = 500
        private const val SUBSCRIPTION_RETRY_MS = 2_000L
        private val messageOrder = compareBy<DarkmatterMessage> { it.timestampSeconds }.thenBy { it.id }
    }
}
