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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.GeoChannel
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.conversationSearchMatches
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.search
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

/** Close Search before [startChat] pushes its pending/existing chat screen. */
internal fun startSecureChatFromSearch(
    closeSearch: () -> Unit,
    startChat: () -> Unit,
) {
    closeSearch()
    startChat()
}

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
    // Title + avatar seed come from the same cached row model as the home list
    // (`marmotRow`, O(1)): the raw group name is blank for npub-only DMs, which
    // painted an untitled row with a different avatar than Home (QA-A13/A14),
    // and made the shown name unsearchable. Recovered 0.8 1:1s also carry a
    // blank MLS name after hide — match the painted title too.
    val chats: List<Pair<SonarChat, String>> = state.visibleChats
        .map { it to state.marmotRow(it.id).title }
        .let { titled ->
            if (ql.isEmpty()) titled
            else titled.filter { (chat, title) ->
                conversationSearchMatches(query, storedName = chat.name, displayTitle = title)
            }
        }

    // An invite link/token pasted (or shared) into search → request to join.
    // Matches the bare token, the sonar:// scheme, and the https universal link;
    // the core normalizes whichever form before sending the join request. Require
    // a hex payload so ordinary text mentioning "sinvite1" doesn't offer to join.
    val looksLikeInvite = chat.bitchat.sonar.INVITE_TOKEN_IN_TEXT.containsMatchIn(query)
    // Offer "Start secure chat" only for a complete npub. Any `npub1` prefix
    // used to raise the call-to-action mid-typing, and a 9-char prefix is also
    // valid geohash alphabet, so "npub14mrp" offered to join channel
    // "#npub14mrp" as well (QA-A18).
    val looksLikeNpub = !looksLikeInvite && isCompleteNpub(query)
    val looksLikeGeohash = !looksLikeInvite && ql.isNotEmpty() && ql.length in 2..9 &&
        !ql.startsWith("npub1") &&
        ql.all { it in "0123456789bcdefghjkmnpqrstuvwxyz" } &&
        channels.none { it.geohash == ql }
    // A typed nickname (`vincenzo`) or full handle (`alice@example.com`) can be
    // resolved to an npub via NIP-05. Pure string gate per keystroke; the
    // network lookup happens only when the user taps the action row, so local
    // results always paint immediately.
    // No extra length floor: the registrar accepts one-character handles, so
    // the search gate must match the claim validator or valid handles become
    // undiscoverable.
    val looksLikeHandle = !looksLikeInvite && !looksLikeNpub && query.isNotEmpty() &&
        remember(query) { SonarCore.handleLooksValid(query) }
    val handleAddress = if ('@' in ql) ql else "$ql@${state.handleDomain}"
    val scope = rememberCoroutineScope()
    var resolvingHandle by remember(query) { mutableStateOf(false) }
    var handleMiss by remember(query) { mutableStateOf(false) }

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
                    if (query.isEmpty()) Text("Search chats, channels, name, npub…", color = s.text3, fontSize = 15.sp)
                    // Opening Search means "I want to type": focus the field like
                    // iOS's search sheet does, and give it a spoken label — it was an
                    // unfocused, anonymous edit box (QA-A21).
                    val searchLabel = stringResource(Res.string.search)
                    val focus = remember { FocusRequester() }
                    LaunchedEffect(Unit) { focus.requestFocus() }
                    BasicTextField(
                        value = q, onValueChange = { q = it }, singleLine = true,
                        textStyle = TextStyle(color = s.text, fontSize = 15.sp),
                        cursorBrush = SolidColor(s.accent),
                        modifier = Modifier.fillMaxWidth().focusRequester(focus)
                            .semantics { contentDescription = searchLabel }
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
                    startSecureChatFromSearch(
                        closeSearch = state::back,
                        startChat = { state.startChat(query) },
                    )
                }
            }
            if (looksLikeGeohash) item {
                ActionResult(SNIconName.Pin, "Join channel", "#$query · public, over the internet", net = true) {
                    state.joinChannel(query)
                }
            }
            // Start-a-chat-by-handle: resolve the typed name via NIP-05 on tap.
            if (looksLikeHandle) item {
                val current = query
                ActionResult(
                    SNIconName.Key,
                    when {
                        resolvingHandle -> "Looking up $handleAddress…"
                        handleMiss -> "No one found for $handleAddress"
                        else -> "Start secure chat with $query"
                    },
                    if (resolvingHandle) "Looking up this username…" else "Encrypted chat over the internet",
                    net = true,
                ) {
                    if (!resolvingHandle) {
                        resolvingHandle = true
                        handleMiss = false
                        scope.launch {
                            val npub = state.resolveHandleForChat(current)
                            // The user may have edited the query while the
                            // lookup was in flight — a stale result must not
                            // open a chat for the previously typed handle.
                            if (q.trim() != current) return@launch
                            resolvingHandle = false
                            if (npub != null) {
                                startSecureChatFromSearch(
                                    closeSearch = state::back,
                                    startChat = { state.startChat(npub) },
                                )
                            } else {
                                handleMiss = true
                            }
                        }
                    }
                }
            }

            if (channels.isNotEmpty()) {
                item { chat.bitchat.sonar.ui.SNSectionLabel("Channels") }
                items(channels, key = { "ch:" + it.geohash + it.level.name }) { c ->
                    ResultRow(
                        avatar = { ChannelTile(c.geohash) },
                        // The mesh is not a place: labelling it with the
                        // placeholder GeoLevel read "city" (QA-A8).
                        title = c.name, sub = if (c.geohash == "mesh") "Nearby · Bluetooth" else c.level.label,
                    ) { state.openChannel(c.geohash) }
                }
            }
            if (chats.isNotEmpty()) {
                item { chat.bitchat.sonar.ui.SNSectionLabel("Messages") }
                items(chats, key = { "dm:" + it.first.id }) { (chat, title) ->
                    ResultRow(
                        avatar = { SonarAvatar(title, 44.dp, presence = false) },
                        title = title, sub = "Secure chat",
                    ) { state.openChat(chat) }
                }
            }
            if (channels.isEmpty() && chats.isEmpty() && !looksLikeNpub && !looksLikeGeohash && !looksLikeInvite) {
                item {
                    Text(
                        if (query.isEmpty()) "Search your chats and channels, or type a name (vincenzo, alice@example.com) or npub to start a secure chat."
                        else "No matches. Type a name or npub to start a chat, or a geohash to join a channel.",
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

private val COMPLETE_NPUB = Regex("^npub1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$")

/** A full bech32 npub (63 chars, bech32 alphabet). Checksum is left to the
 *  core, which rejects a mistyped key when the chat starts. */
internal fun isCompleteNpub(query: String): Boolean = COMPLETE_NPUB.matches(query.trim().lowercase())
