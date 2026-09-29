package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.chatlist.ChatListEvent
import chat.bitchat.sonar.chatlist.ChatListPresenter
import chat.bitchat.sonar.chatlist.ChatListRow
import chat.bitchat.sonar.chatlist.ChatListSources
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * "Send to…" recipient picker for content arriving from the system share sheet.
 *
 * Deliberately a picker rather than an auto-send or a search-box prefill:
 * sharing a link used to land in the Search query field, which read as
 * searching for the link rather than sending it, and had no path at all for
 * photos or documents.
 */
@Composable
fun SonarShareToScreen(state: SonarAppState) {
    val s = sonar
    val share = state.pendingShare
    // The share can resolve (sent or cancelled) while this screen is still
    // composed for one frame. Render nothing rather than crash on null, and pop
    // so this can never become a dead end with no back control. Safe to pop
    // unconditionally: SonarScreenHost renders exactly one screen, so reaching
    // here means ShareTo is the current screen.
    if (share == null) {
        Box(Modifier.fillMaxSize().background(s.bg))
        LaunchedEffect(Unit) { state.back() }
        return
    }

    // The same Messages rows as Home (display titles, Note to Self first), from
    // the chat-list presenter. The search box narrows them with Filter events;
    // picking a row sends the share there, then opens it (ShareToSources).
    // Titling rows by the raw MLS group name left most 1:1s blank here — the
    // QA-A13/A14 bug Search had already fixed (R-053).
    val chatListEvents = remember { MutableSharedFlow<ChatListEvent>(extraBufferCapacity = 16) }
    val presenter = remember(state) {
        ChatListPresenter(state.chatList, ShareToSources(state), waitForHydration = false)
    }
    val rows = presenter.present(chatListEvents).rows
    var q by remember { mutableStateOf("") }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 14.dp, top = 10.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // cancelPendingShare leaves the picker itself (and then offers any
            // queued share in a fresh one).
            SNIconButton(SNIconName.Back, onClick = { state.cancelPendingShare() })
            Spacer(Modifier.width(4.dp))
            Text("Send to…", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        }

        // What is about to be sent. Files are listed by name rather than
        // thumbnailed — decoding every shared item just for a preview would
        // hold the whole payload in bitmaps on top of the bytes.
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(14.dp)).background(s.surface2)
                .padding(horizontal = 13.dp, vertical = 11.dp)
        ) {
            share.text?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = s.text, fontSize = 14.sp, maxLines = 3)
            }
            share.files.files.forEach { file ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.Data, 14.dp, s.text3, weight = 2f)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        file.filename,
                        color = s.text2,
                        fontSize = 13.sp,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    Text(shareByteLabel(file.bytes.size), color = s.text3, fontSize = 12.sp)
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)
                .clip(RoundedCornerShape(999.dp)).background(s.surface2)
                .padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Search, 16.dp, s.text3, weight = 2f)
            Spacer(Modifier.width(9.dp))
            Box(Modifier.weight(1f)) {
                if (q.isEmpty()) Text("Search chats", color = s.text3, fontSize = 15.sp)
                BasicTextField(
                    value = q,
                    onValueChange = {
                        q = it
                        chatListEvents.tryEmit(ChatListEvent.Filter(it))
                    },
                    singleLine = true,
                    textStyle = TextStyle(color = s.text, fontSize = 15.sp),
                    cursorBrush = SolidColor(s.accent),
                    // The placeholder is a sibling Text that disappears on
                    // input, so the field needs its own spoken label (QA-A9).
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search chats" }
                )
            }
        }

        LazyColumn(Modifier.fillMaxSize()) {
            if (rows.isEmpty()) {
                item {
                    Text(
                        if (q.isBlank()) "No chats yet. Start a chat first, then share into it."
                        else "No chat matches that name.",
                        color = s.text3, fontSize = 13.5.sp, lineHeight = 18.sp,
                        modifier = Modifier.fillMaxWidth().padding(24.dp)
                    )
                }
            } else {
                item { SNSectionLabel("Messages") }
                items(rows, key = { it.key }) { row ->
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable { chatListEvents.tryEmit(ChatListEvent.Open(row)) }
                            .padding(horizontal = 16.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Mesh rows carry the in-range dot like Home does: an
                        // out-of-range BLE peer cannot take an attachment, so
                        // the user should see that before picking it.
                        SonarAvatar(
                            row.title,
                            44.dp,
                            presence = row is ChatListRow.Mesh && state.dmInRange(row.peerId),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(row.title, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                if (row is ChatListRow.Mesh) "Bluetooth" else "Secure chat",
                                color = s.text3, fontSize = 12.5.sp
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * The share picker's view of [SonarAppState.chatListSources]: opening a row
 * first sends the pending share to that conversation (which leaves the picker),
 * then opens it. Everything else is the Home list's projection unchanged.
 */
private class ShareToSources(
    private val state: SonarAppState,
    private val base: ChatListSources = state.chatListSources,
) : ChatListSources by base {
    override fun openChat(chat: SonarChat) = state.sendPendingShare(chat.id) { base.openChat(chat) }
    override fun openDm(peerId: String, name: String) =
        state.sendPendingShare("mesh:$peerId") { base.openDm(peerId, name) }
}

/** Short human byte count for the share preview strip. */
internal fun shareByteLabel(bytes: Int): String = when {
    bytes >= 1024 * 1024 -> "${bytes / (1024 * 1024)} MB"
    bytes >= 1024 -> "${bytes / 1024} KB"
    else -> "$bytes B"
}
