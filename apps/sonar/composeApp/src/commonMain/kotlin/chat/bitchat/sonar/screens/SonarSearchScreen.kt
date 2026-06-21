package chat.bitchat.sonar.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.GeoChannel
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar

/**
 * Search screen behind the home Search bar (the prototype's `sn-search`).
 * Filters the user's channels + secure chats by query, and — since there's no
 * live mesh to populate peers — accepts an `npub` to start a secure chat or a
 * geohash to join a public channel.
 */
@Composable
fun SonarSearchScreen(state: SonarAppState) {
    val s = sonar
    var q by remember { mutableStateOf("") }
    LaunchedEffect(state.sharedText) {
        state.consumeSharedText()?.let { q = it }
    }
    val query = q.trim()
    val ql = query.lowercase()

    // Channel candidates: Mesh + GPS location channels + manually-joined.
    val channels: List<GeoChannel> = remember(state.locationChannels, state.channels, query) {
        val out = ArrayList<GeoChannel>()
        out.add(GeoChannel("mesh", "Bluetooth mesh", chat.bitchat.sonar.GeoLevel.City))
        out.addAll(state.locationChannels)
        state.channels.filter { gh -> state.locationChannels.none { it.geohash == gh } && gh != "mesh" }
            .forEach { out.add(GeoChannel(it, "#$it", chat.bitchat.sonar.GeoLevel.City)) }
        if (ql.isEmpty()) out
        else out.filter { it.name.lowercase().contains(ql) || it.geohash.lowercase().contains(ql) }
    }
    val chats: List<SonarChat> = remember(state.chats, query) {
        if (ql.isEmpty()) state.chats else state.chats.filter { it.name.lowercase().contains(ql) }
    }

    // An invite link/token pasted (or shared) into search → request to join.
    // Matches the bare token, the sonar:// scheme, and the https universal link;
    // the core normalizes whichever form before sending the join request.
    val looksLikeInvite = query.contains("sinvite1")
    val looksLikeNpub = !looksLikeInvite && ql.startsWith("npub1") && query.length > 8
    val looksLikeGeohash = !looksLikeInvite && ql.isNotEmpty() && ql.length in 2..9 &&
        ql.all { it in "0123456789bcdefghjkmnpqrstuvwxyz" } &&
        channels.none { it.geohash == ql }

    Column(Modifier.fillMaxSize().background(s.bg)) {
        // header: back + search field
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 14.dp, top = 10.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = { state.back() })
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(999.dp)).background(s.surface2)
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SNIcon(SNIconName.Search, 16.dp, s.text3, weight = 2f)
                Spacer(Modifier.width(9.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text("Search chats, channels, npub…", color = s.text3, fontSize = 15.sp)
                    BasicTextField(
                        value = q, onValueChange = { q = it }, singleLine = true,
                        textStyle = TextStyle(color = s.text, fontSize = 15.sp),
                        cursorBrush = SolidColor(s.accent),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }

        LazyColumn(Modifier.fillMaxSize()) {
            // Join-a-group action when an invite link/token is pasted or shared in.
            if (looksLikeInvite) item {
                ActionResult(SNIconName.Link, "Join group", "Request to join via invite link", net = true) {
                    state.requestJoinViaLink(query); state.back()
                }
            }
            // Start-a-chat-by-npub / join-by-geohash actions when the query matches.
            if (looksLikeNpub) item {
                ActionResult(SNIconName.Key, "Start secure chat", query, net = false) {
                    state.startChat(query); state.back()
                }
            }
            if (looksLikeGeohash) item {
                ActionResult(SNIconName.Pin, "Join channel", "#$query · public, over the internet", net = true) {
                    state.joinChannel(query)
                }
            }

            if (channels.isNotEmpty()) {
                item { chat.bitchat.sonar.ui.SNSectionLabel("Channels") }
                items(channels, key = { "ch:" + it.geohash + it.level.name }) { c ->
                    ResultRow(
                        avatar = { ChannelTile(c.geohash) },
                        title = c.name, sub = c.level.label,
                    ) { state.openChannel(c.geohash) }
                }
            }
            if (chats.isNotEmpty()) {
                item { chat.bitchat.sonar.ui.SNSectionLabel("Messages") }
                items(chats, key = { "dm:" + it.id }) { chat ->
                    ResultRow(
                        avatar = { SonarAvatar(chat.name, 44.dp, presence = false) },
                        title = chat.name, sub = "Secure chat",
                    ) { state.openChat(chat) }
                }
            }
            if (channels.isEmpty() && chats.isEmpty() && !looksLikeNpub && !looksLikeGeohash && !looksLikeInvite) {
                item {
                    Text(
                        if (query.isEmpty()) "Search your chats and channels, or paste an npub to start a secure chat."
                        else "No matches. Paste an npub to start a chat, or a geohash to join a channel.",
                        color = s.text3, fontSize = 13.5.sp, lineHeight = 18.sp,
                        modifier = Modifier.fillMaxWidth().padding(24.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun ChannelTile(geohash: String) {
    val s = sonar
    Box(
        Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(s.accentSoft),
        contentAlignment = Alignment.Center
    ) { SNIcon(if (geohash == "mesh") SNIconName.Mesh else SNIconName.Pin, 20.dp, s.accentDeep, weight = 2f) }
}

@Composable
private fun ResultRow(avatar: @Composable () -> Unit, title: String, sub: String, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        avatar()
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(sub, color = s.text3, fontSize = 12.5.sp)
        }
    }
}

@Composable
private fun ActionResult(icon: SNIconName, label: String, sub: String, net: Boolean, onClick: () -> Unit) {
    val s = sonar
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(if (net) s.netSoft else s.accentSoft),
                contentAlignment = Alignment.Center
            ) { SNIcon(icon, 20.dp, if (net) s.netDeep else s.accentDeep) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(label, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(sub, color = s.text3, fontSize = 12.5.sp, maxLines = 1)
            }
        }
        Spacer(Modifier.height(8.dp))
        SNPrimaryButton(label, net = net) { onClick() }
    }
}
