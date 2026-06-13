package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.screens.SonarOnboardingScreen
import chat.bitchat.sonar.ui.SNDot
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarTheme
import chat.bitchat.sonar.ui.sonar

@Composable
fun App() {
    SonarTheme(dark = true) {
        val s = sonar
        val scope = rememberCoroutineScope()
        val state = remember { SonarAppState(scope) }
        LaunchedEffect(Unit) { state.boot() }

        Surface(Modifier.fillMaxSize(), color = s.bg) {
            if (!state.onboarded) {
                Box(Modifier.statusBarsPadding()) { SonarOnboardingScreen(state) }
            } else {
                Box(Modifier.statusBarsPadding()) {
                    when (val sc = state.screen) {
                        is Screen.Home -> HomeScreen(state)
                        is Screen.Chat -> ChatScreen(state, sc)
                        is Screen.Settings -> chat.bitchat.sonar.screens.SonarSettingsScreen(state)
                        is Screen.Profile -> chat.bitchat.sonar.screens.SonarProfileScreen(state)
                        is Screen.Nearby -> chat.bitchat.sonar.screens.SonarRadarScreen(state)
                        is Screen.Channel -> chat.bitchat.sonar.screens.SonarChannelScreen(state, sc)
                    }
                }
            }
        }
    }
}

@Composable
private fun HomeScreen(state: SonarAppState) {
    val s = sonar
    var showNew by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        // bc-header
        Row(
            Modifier.fillMaxWidth().padding(start = 18.dp, end = 12.dp, top = 14.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("Sonar", color = s.text, fontSize = 27.sp, fontWeight = FontWeight.Black)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNDot(if (state.started) s.green else s.text3, 7.dp)
                    Spacer(Modifier.width(5.dp))
                    Text(
                        if (state.started) "Online · reaches anyone"
                        else if (state.connecting) "connecting…" else "Offline",
                        color = s.text2, fontSize = 12.sp
                    )
                }
            }
            SNIconButton(SNIconName.Rings, size = 22.dp, weight = 2f, tint = s.text2) { state.push(Screen.Nearby) }
            Spacer(Modifier.width(2.dp))
            Box(Modifier.clickable { state.push(Screen.Settings) }) {
                SonarAvatar(state.nick.ifBlank { "you" }, 34.dp)
            }
            Spacer(Modifier.width(6.dp))
            SNIconButton(SNIconName.Plus, size = 22.dp, weight = 2.4f, tint = s.accent) { showNew = true }
        }

        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp)) {
            item { SNSectionLabel("Nearby channels") }
            if (state.channels.isEmpty()) {
                item { ChannelHint() }
            } else {
                items(state.channels, key = { it }) { gh -> ChannelRow(gh) { state.openChannel(gh) } }
            }
            item { SNSectionLabel("Messages") }
            if (state.chats.isEmpty()) {
                item { EmptyMessages() }
            } else {
                items(state.chats, key = { it.id }) { chat -> ChatRow(chat) { state.openChat(chat) } }
            }
        }
    }

    if (showNew) NewChatSheet(
        onStart = { showNew = false; state.startChat(it) },
        onJoin = { showNew = false; state.joinChannel(it) },
        onDismiss = { showNew = false }
    )
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun EmptyMessages() {
    val s = sonar
    Column(
        Modifier.fillMaxWidth().padding(top = 80.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        SNIcon(SNIconName.Lock, 24.dp, s.text3)
        Spacer(Modifier.height(10.dp))
        Text("No secure chats yet", color = s.text2, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            "Tap + and paste someone’s npub to start an end-to-end encrypted chat over the internet.",
            color = s.text3, fontSize = 13.sp, lineHeight = 18.sp
        )
    }
}

@Composable
private fun ChannelHint() {
    val s = sonar
    Text(
        "Join a channel from + to chat publicly with people in an area.",
        color = s.text3, fontSize = 13.sp, lineHeight = 18.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 4.dp)
    )
}

@Composable
private fun ChannelRow(geohash: String, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.size(46.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(SNIconName.Pin, 22.dp, s.accentDeep) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("#$geohash", color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("Public channel · over the internet", color = s.text3, fontSize = 12.sp)
        }
    }
}

@Composable
private fun ChatRow(chat: SonarChat, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SonarAvatar(chat.name.ifBlank { chat.members.firstOrNull() ?: "?" }, 46.dp, presence = false)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                chat.name.ifBlank { shortNpub(chat.members.firstOrNull() ?: "secure chat") },
                color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                SNIcon(SNIconName.Globe, 11.dp, s.net, weight = 2f)
                Spacer(Modifier.width(4.dp))
                Text("Sonar · end-to-end encrypted", color = s.text3, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun ChatScreen(state: SonarAppState, screen: Screen.Chat) {
    val s = sonar
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.size - 1)
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = { state.back() })
            SonarAvatar(screen.name, 36.dp, presence = false)
            Spacer(Modifier.width(10.dp))
            Column {
                Text(
                    screen.name.ifBlank { "secure chat" },
                    color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.Lock, 11.dp, s.text2, weight = 2.4f)
                    Spacer(Modifier.width(4.dp))
                    Text("Sonar · end-to-end encrypted", color = s.text3, fontSize = 11.5.sp)
                }
            }
        }

        chat.bitchat.sonar.ui.SNBanner(
            icon = SNIconName.Lock, tone = chat.bitchat.sonar.ui.SNBannerTone.Enc,
            bold = "End-to-end encrypted",
            rest = " — only you and ${screen.name} can read this"
        )

        if (state.messages.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                chat.bitchat.sonar.ui.SNEmptyState(
                    icon = SNIconName.Lock,
                    title = "Say hi to ${screen.name}",
                    desc = "Messages here are end-to-end encrypted. Only the two of you can read them."
                )
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                state = listState,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
            ) {
                items(state.messages, key = { it.id }) { m -> MessageBubble(m) }
            }
        }

        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(22.dp)).background(s.surface2)
                    .padding(horizontal = 16.dp, vertical = 12.dp)
            ) {
                if (draft.isEmpty()) Text("Message", color = s.text3, fontSize = 16.sp)
                BasicTextField(
                    value = draft, onValueChange = { draft = it },
                    textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                    cursorBrush = SolidColor(s.accent),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.size(46.dp).clip(CircleShape).background(s.netFill)
                    .clickable { state.send(screen.id, draft); draft = "" },
                contentAlignment = Alignment.Center
            ) { Text("↑", color = s.onNet, fontSize = 20.sp, fontWeight = FontWeight.Bold) }
        }
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun MessageBubble(m: SonarMsg) {
    val s = sonar
    val linkColor = if (m.mine) s.onNet else s.accent
    val annotated = remember(m.content, m.mine) { linkify(m.content, linkColor) }
    val firstUrl = remember(m.content) { firstUrl(m.content) }
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    Column(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        Box(
            Modifier.clip(RoundedCornerShape(18.dp))
                .background(if (m.mine) s.netFill else s.bubbleOther)
                .then(if (firstUrl != null) Modifier.clickable { uriHandler.openUri(firstUrl) } else Modifier)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            // Selectable (long-press → Copy); tap opens a link if present —
            // mirrors the iOS deterministic copy + tappable-link behavior.
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(annotated, color = if (m.mine) s.onNet else s.text, fontSize = 16.sp)
            }
        }
    }
}

private val URL_REGEX = Regex("""(https?://|www\.)\S+""")

private fun firstUrl(text: String): String? {
    val m = URL_REGEX.find(text) ?: return null
    val raw = m.value
    return if (raw.startsWith("www.")) "https://$raw" else raw
}

private fun linkify(text: String, linkColor: androidx.compose.ui.graphics.Color) =
    androidx.compose.ui.text.buildAnnotatedString {
        var last = 0
        for (match in URL_REGEX.findAll(text)) {
            append(text.substring(last, match.range.first))
            pushStyle(
                androidx.compose.ui.text.SpanStyle(
                    color = linkColor,
                    textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline
                )
            )
            append(match.value)
            pop()
            last = match.range.last + 1
        }
        append(text.substring(last))
    }

@Composable
private fun NewChatSheet(onStart: (String) -> Unit, onJoin: (String) -> Unit, onDismiss: () -> Unit) {
    val s = sonar
    var peer by remember { mutableStateOf("") }
    var channel by remember { mutableStateOf("") }
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onDismiss),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("New secure chat", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text("Paste their npub. They need to have opened Sonar at least once.", color = s.text3, fontSize = 12.5.sp)
                Spacer(Modifier.height(12.dp))
                SheetField(peer, "npub1…") { peer = it }
                Spacer(Modifier.height(12.dp))
                SNPrimaryButton("Start chat") { onStart(peer) }

                Spacer(Modifier.height(22.dp))
                Text("Join a channel", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text("Enter an area code (geohash) to chat publicly with people there.", color = s.text3, fontSize = 12.5.sp)
                Spacer(Modifier.height(12.dp))
                SheetField(channel, "e.g. u0nd or sr2y…") { channel = it }
                Spacer(Modifier.height(12.dp))
                SNPrimaryButton("Join channel", net = true) { onJoin(channel) }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun SheetField(value: String, placeholder: String, onChange: (String) -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
            .padding(horizontal = 14.dp, vertical = 14.dp)
    ) {
        if (value.isEmpty()) Text(placeholder, color = s.text3, fontSize = 15.sp)
        BasicTextField(
            value = value, onValueChange = onChange, singleLine = true,
            textStyle = TextStyle(color = s.text, fontSize = 15.sp),
            cursorBrush = SolidColor(s.accent),
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun ToastBar(text: String, onDone: () -> Unit) {
    val s = sonar
    LaunchedEffect(text) { kotlinx.coroutines.delay(2600); onDone() }
    Box(Modifier.fillMaxSize().padding(bottom = 90.dp), contentAlignment = Alignment.BottomCenter) {
        Surface(color = s.surface2, shape = RoundedCornerShape(13.dp)) {
            Text(text, color = s.text, fontSize = 13.5.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 11.dp))
        }
    }
}

private fun shortNpub(npub: String): String =
    if (npub.length > 16) npub.take(10) + "…" + npub.takeLast(4) else npub
