package chat.bitchat.sonar.darkmatter

import dev.ipf.marmotkit.Marmot
import dev.ipf.marmotkit.TimelineMessageQueryFfi
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MarmotDarkmatterBackend(
    private val rootDirectory: File,
    private val relayUrls: List<String>,
) : DarkmatterBackend {
    private val lifecycleMutex = Mutex()
    private var runtimeStarted = false
    private val marmot: Marmot by lazy {
        rootDirectory.mkdirs()
        Marmot(rootDirectory.absolutePath, relayUrls)
    }

    override fun localAccounts(): List<DarkmatterAccount> = marmot.listAccounts()
        .asSequence()
        .filter { it.localSigning && !it.signedOut }
        .map { account ->
            DarkmatterAccount(
                reference = account.label,
                accountIdHex = account.accountIdHex,
                npub = marmot.npub(account.accountIdHex) ?: account.accountIdHex,
            )
        }
        .toList()

    override fun localConversations(accountReference: String): List<DarkmatterConversation> =
        marmot.chatList(accountReference, includeArchived = false).map { row ->
            val preview = row.lastMessage?.let { message ->
                when {
                    message.deleted -> "Message deleted"
                    message.plaintext.isBlank() -> "Encrypted activity"
                    else -> message.plaintext
                }
            }.orEmpty()
            DarkmatterConversation(
                id = row.groupIdHex,
                title = row.title.ifBlank { row.groupName.ifBlank { "Darkmatter group" } },
                preview = preview,
                updatedAtSeconds = row.updatedAt.saturatedLong(),
                unreadCount = row.unreadCount.saturatedLong(),
                pendingConfirmation = row.pendingConfirmation,
            )
        }

    override fun localMessages(
        accountReference: String,
        groupId: String,
        beforeTimestampSeconds: Long?,
        beforeMessageId: String?,
        limit: Int,
    ): DarkmatterMessagePage {
        val boundedLimit = limit.coerceIn(1, DarkmatterController.PAGE_SIZE).toUInt()
        val page = marmot.timelineMessages(
            accountReference,
            TimelineMessageQueryFfi(
                groupIdHex = groupId,
                search = null,
                before = beforeTimestampSeconds?.coerceAtLeast(0)?.toULong(),
                beforeMessageId = beforeMessageId,
                after = null,
                afterMessageId = null,
                limit = boundedLimit,
            ),
        )
        return DarkmatterMessagePage(
            messages = page.messages.map { record ->
                val own = record.direction.equals("sent", ignoreCase = true)
                val delivery = when {
                    record.invalidationStatus != null -> DarkmatterDelivery.FAILED
                    own && record.sourceMessageIdHex == null -> DarkmatterDelivery.QUEUED
                    else -> DarkmatterDelivery.DELIVERED
                }
                DarkmatterMessage(
                    id = record.messageIdHex,
                    text = when {
                        record.deleted -> "Message deleted"
                        record.plaintext.isNotBlank() -> record.plaintext
                        record.groupSystem != null -> "Group updated"
                        else -> "Encrypted activity"
                    },
                    sender = marmot.displayName(record.sender)
                        ?: marmot.npub(record.sender)
                        ?: record.sender.take(12),
                    isOwn = own,
                    timestampSeconds = record.timelineAt.saturatedLong(),
                    delivery = delivery,
                    invalidationReason = record.invalidationStatus,
                )
            },
            hasMoreBefore = page.hasMoreBefore,
        )
    }

    override suspend fun connect() {
        lifecycleMutex.withLock {
            if (runtimeStarted) return
            marmot.start()
            runtimeStarted = true
        }
    }

    override suspend fun createIdentity(): DarkmatterAccount {
        connect()
        val account = marmot.createIdentity(relayUrls, relayUrls)
        return DarkmatterAccount(
            reference = account.label,
            accountIdHex = account.accountIdHex,
            npub = marmot.npub(account.accountIdHex) ?: account.accountIdHex,
        )
    }

    override suspend fun createGroup(
        accountReference: String,
        memberReference: String,
        title: String,
    ): String {
        connect()
        val member = marmot.normalizeMemberRef(memberReference)
        return marmot.createGroup(
            accountRef = accountReference,
            name = title,
            memberRefs = listOf(member.memberRef),
            description = null,
        )
    }

    override suspend fun sendText(accountReference: String, groupId: String, text: String) {
        connect()
        marmot.sendText(accountReference, groupId, text)
    }

    override suspend fun acceptInvite(accountReference: String, groupId: String) {
        connect()
        marmot.acceptGroupInvite(accountReference, groupId)
    }

    override suspend fun declineInvite(accountReference: String, groupId: String) {
        connect()
        marmot.declineGroupInvite(accountReference, groupId)
    }

    override fun conversationChanges(accountReference: String): Flow<Unit> = flow {
        connect()
        val subscription = marmot.subscribeChatList(accountReference, includeArchived = false)
        try {
            while (currentCoroutineContext().isActive) {
                if (subscription.nextUpdate() == null) break
                emit(Unit)
            }
        } catch (error: CancellationException) {
            throw error
        } finally {
            subscription.close()
        }
    }

    override fun messageChanges(accountReference: String, groupId: String): Flow<Unit> = flow {
        connect()
        val subscription = marmot.subscribeTimelineMessages(
            accountRef = accountReference,
            groupIdHex = groupId,
            limit = DarkmatterController.PAGE_SIZE.toUInt(),
        )
        try {
            while (currentCoroutineContext().isActive) {
                if (subscription.nextUpdate() == null) break
                emit(Unit)
            }
        } catch (error: CancellationException) {
            throw error
        } finally {
            subscription.close()
        }
    }

    override suspend fun shutdown() {
        lifecycleMutex.withLock {
            if (runtimeStarted) {
                marmot.shutdown()
                runtimeStarted = false
            }
            marmot.close()
        }
    }

    private fun ULong.saturatedLong(): Long = coerceAtMost(Long.MAX_VALUE.toULong()).toLong()
}
