package chat.bitchat.sonar.darkmatter

import kotlinx.coroutines.flow.Flow

interface DarkmatterBackend {
    fun localAccounts(): List<DarkmatterAccount>

    fun localConversations(accountReference: String): List<DarkmatterConversation>

    fun localMessages(
        accountReference: String,
        groupId: String,
        beforeTimestampSeconds: Long? = null,
        beforeMessageId: String? = null,
        limit: Int = 50,
    ): DarkmatterMessagePage

    suspend fun connect()

    suspend fun createIdentity(): DarkmatterAccount

    suspend fun createGroup(
        accountReference: String,
        memberReference: String,
        title: String,
    ): String

    suspend fun sendText(accountReference: String, groupId: String, text: String)

    suspend fun acceptInvite(accountReference: String, groupId: String)

    suspend fun declineInvite(accountReference: String, groupId: String)

    fun conversationChanges(accountReference: String): Flow<Unit>

    fun messageChanges(accountReference: String, groupId: String): Flow<Unit>

    suspend fun shutdown()
}
interface PendingConversationStore {
    suspend fun load(): List<PendingConversation>

    suspend fun save(conversations: List<PendingConversation>)
}
