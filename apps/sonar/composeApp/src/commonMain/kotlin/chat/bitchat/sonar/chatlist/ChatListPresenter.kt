package chat.bitchat.sonar.chatlist

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.HomeMessageRow
import chat.bitchat.sonar.isNoteToSelfChat
import chat.bitchat.sonar.mergeHomeMessageRows
import chat.bitchat.sonar.pinNoteToSelfHomeRows
import kotlinx.coroutines.flow.Flow

/**
 * Presenter for the Messages list (Cash App's Molecule pattern): a
 * `@Composable` function that takes UI [ChatListEvent]s and returns one
 * immutable [ChatListModel], using only the Compose *runtime* — `remember`,
 * state and effects — plus plain Kotlin.
 *
 * Production calls [present] from the UI composition (phone Home, desktop
 * sidebar), so it recomposes on the UI frame clock with no second recomposer.
 * Tests run it headless with Molecule (`RecompositionMode.Immediate`) and
 * assert on the emitted models with Turbine.
 *
 * Rules it keeps:
 * - Local-first: every input is local state ([ChatListRepository] and
 *   [ChatListSources]); nothing here waits on a relay, so the first model is
 *   painted from what is already on the device.
 * - No side effects in composition: events are handled in a [LaunchedEffect].
 * - Both chat kinds: unread is summed over each row's folded group set —
 *   duplicate direct groups for a Marmot row, the npub-resolved groups for a
 *   mesh row — the same sets the open path read-marks.
 */
internal class ChatListPresenter(
    private val repository: ChatListRepository,
    private val sources: ChatListSources,
    /**
     * Phone Home holds the list behind a loading row until the local model
     * is coherent. The desktop sidebar has no launch splash and paints the
     * restored snapshot straight away, so it passes false.
     */
    private val waitForHydration: Boolean = true,
) {
    @Composable
    fun present(events: Flow<ChatListEvent>): ChatListModel {
        var query by remember { mutableStateOf("") }

        LaunchedEffect(events) {
            events.collect { event ->
                when (event) {
                    is ChatListEvent.Open -> open(event.row)
                    is ChatListEvent.Filter -> query = event.query
                    is ChatListEvent.AcceptInvite -> sources.acceptGroupInvite(event.inviteId)
                    is ChatListEvent.DeclineInvite -> sources.declineGroupInvite(event.inviteId)
                    is ChatListEvent.Mute -> sources.muteChat(event.conversationId, event.durationSecs)
                    is ChatListEvent.Unmute -> sources.unmuteChat(event.conversationId)
                    is ChatListEvent.Delete ->
                        if (event.mesh) sources.deleteMeshDm(event.id) else sources.deleteMarmotChat(event.id)
                }
            }
        }

        val catchingUp = sources.catchingUp
        // Local-first gate. Until the local model is coherent the list shows a
        // loading row and reads nothing else, so an incomplete Home never
        // paints (and never subscribes to state it would not render).
        if (waitForHydration && !sources.homeMessagesHydrated) {
            return ChatListModel(
                hydrated = false,
                catchingUp = catchingUp,
                invites = emptyList(),
                rows = emptyList(),
                query = query,
            )
        }
        return ChatListModel(
            hydrated = true,
            catchingUp = catchingUp,
            invites = sources.groupInvites,
            rows = rows(query),
            query = query,
        )
    }

    private fun rows(query: String): List<ChatListRow> {
        val noteToSelfId = sources.noteToSelfGroupId
        val unread = repository.unreadByChat
        fun anyUnread(groupIds: List<String>): Boolean = groupIds.any { (unread[it] ?: 0L) > 0L }

        // One recency-ordered list across transports (Signal-style / iOS
        // SonarAppStore.dmRows), Note to Self pinned first. Sort keys are O(1):
        // mesh rows are precomputed, Marmot rows read the cached row model.
        val ordered = pinNoteToSelfHomeRows(
            mergeHomeMessageRows(sources.meshRows, sources.marmotChats) { chatId ->
                sources.marmotRow(chatId).tsSecs
            },
            noteToSelfGroupId = noteToSelfId,
        )
        val rows = ordered.map { row ->
            when (row) {
                is HomeMessageRow.Mesh -> ChatListRow.Mesh(
                    peerId = row.row.peerId,
                    title = row.row.name,
                    preview = row.row.preview,
                    tsSecs = row.row.tsSecs,
                    unread = false,
                    verified = false,
                )
                is HomeMessageRow.Marmot -> {
                    val model = sources.marmotRow(row.chat.id)
                    val noteToSelf = isNoteToSelfChat(row.chat, noteToSelfId)
                    ChatListRow.Marmot(
                        chat = row.chat,
                        title = model.title,
                        preview = model.sub,
                        tsSecs = model.tsSecs,
                        // Your own notes are never unread.
                        unread = !noteToSelf && anyUnread(model.groupIds),
                        verified = model.verified,
                        pending = model.pending,
                        group = model.multiMember,
                        noteToSelf = noteToSelf,
                    )
                }
            }
        }
        val needle = query.trim()
        if (needle.isEmpty()) return rows
        return rows.filter { row ->
            row.title.contains(needle, ignoreCase = true) ||
                (row is ChatListRow.Marmot && row.chat.name.contains(needle, ignoreCase = true))
        }
    }

    private fun open(row: ChatListRow) {
        when (row) {
            is ChatListRow.Mesh -> sources.openDm(row.peerId, row.title)
            is ChatListRow.Marmot -> sources.openChat(row.chat)
        }
    }
}
