package chat.bitchat.sonar.darkmatter

data class DarkmatterAccount(
    val reference: String,
    val accountIdHex: String,
    val npub: String,
)
data class DarkmatterConversation(
    val id: String,
    val title: String,
    val preview: String,
    val updatedAtSeconds: Long,
    val unreadCount: Long = 0,
    val pendingConfirmation: Boolean = false,
    val isPendingSetup: Boolean = false,
    val setupError: String? = null,
)

enum class DarkmatterDelivery {
    QUEUED,
    SENDING,
    DELIVERED,
    FAILED,
}

data class DarkmatterMessage(
    val id: String,
    val text: String,
    val sender: String,
    val isOwn: Boolean,
    val timestampSeconds: Long,
    val delivery: DarkmatterDelivery,
    val invalidationReason: String? = null,
)

data class DarkmatterMessagePage(
    val messages: List<DarkmatterMessage>,
    val hasMoreBefore: Boolean,
)

data class PendingMessage(
    val id: String,
    val text: String,
    val createdAtSeconds: Long,
    val delivery: DarkmatterDelivery = DarkmatterDelivery.QUEUED,
    val error: String? = null,
)

data class PendingConversation(
    val id: String,
    val memberReference: String,
    val title: String,
    val createdAtSeconds: Long,
    val resolvedGroupId: String? = null,
    val messages: List<PendingMessage> = emptyList(),
    val setupError: String? = null,
)

data class DarkmatterUiState(
    val localReady: Boolean = false,
    val connecting: Boolean = false,
    val connected: Boolean = false,
    val creatingIdentity: Boolean = false,
    val account: DarkmatterAccount? = null,
    val conversations: List<DarkmatterConversation> = emptyList(),
    val selectedConversationId: String? = null,
    val messages: List<DarkmatterMessage> = emptyList(),
    val hasMoreBefore: Boolean = false,
    val loadingOlder: Boolean = false,
    val error: String? = null,
)
