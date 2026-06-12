package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.SonarColors

private val sonarScheme = darkColorScheme(
    primary = SonarColors.accent,
    onPrimary = SonarColors.onAccent,
    background = SonarColors.bg,
    onBackground = SonarColors.text,
    surface = SonarColors.surface,
    onSurface = SonarColors.text,
    error = SonarColors.danger,
)

@Composable
fun App() {
    MaterialTheme(colorScheme = sonarScheme) {
        val scope = rememberCoroutineScope()
        val state = remember { SonarAppState(scope) }
        LaunchedEffect(Unit) { state.boot() }

        Surface(Modifier.fillMaxSize(), color = SonarColors.bg) {
            when (val s = state.screen) {
                is Screen.Home -> HomeScreen(state)
                is Screen.Chat -> ChatScreen(state, s)
            }
        }
    }
}

@Composable
private fun HomeScreen(state: SonarAppState) {
    var showNew by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        // Header
        Row(
            Modifier.fillMaxWidth().padding(start = 18.dp, end = 12.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("Sonar", color = SonarColors.text, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text(
                    if (state.started) "you · ${shortNpub(state.npub)}"
                    else if (state.connecting) "connecting…" else "offline",
                    color = SonarColors.text3, fontSize = 12.sp
                )
            }
            FilledIcon("+", onClick = { showNew = true })
        }

        if (state.chats.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No secure chats yet", color = SonarColors.text2, fontSize = 16.sp)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Tap + and paste someone's npub to start an\nend-to-end encrypted chat over the internet.",
                        color = SonarColors.text3, fontSize = 13.sp
                    )
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 6.dp)) {
                items(state.chats, key = { it.id }) { chat ->
                    ChatRow(chat) { state.openChat(chat) }
                }
            }
        }
    }

    if (showNew) {
        NewChatSheet(
            onStart = { peer -> showNew = false; state.startChat(peer) },
            onDismiss = { showNew = false }
        )
    }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun ChatRow(chat: SonarChat, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(chat.name.ifBlank { chat.members.firstOrNull() ?: "?" })
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                chat.name.ifBlank { shortNpub(chat.members.firstOrNull() ?: "secure chat") },
                color = SonarColors.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis
            )
            Text("White Noise · end-to-end encrypted", color = SonarColors.text3, fontSize = 12.sp)
        }
    }
}

@Composable
private fun ChatScreen(state: SonarAppState, screen: Screen.Chat) {
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.size - 1)
    }

    Column(Modifier.fillMaxSize()) {
        // Header
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, top = 14.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { state.back() }) {
                Text("‹", color = SonarColors.text, fontSize = 28.sp)
            }
            Avatar(screen.name)
            Spacer(Modifier.width(10.dp))
            Column {
                Text(
                    screen.name.ifBlank { "secure chat" },
                    color = SonarColors.text, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                Text("White Noise · end-to-end encrypted", color = SonarColors.text3, fontSize = 11.5.sp)
            }
        }

        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            state = listState,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
        ) {
            items(state.messages, key = { it.id }) { m -> MessageBubble(m) }
        }

        // Composer
        Row(
            Modifier.fillMaxWidth().padding(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message", color = SonarColors.text3) },
                shape = RoundedCornerShape(22.dp),
                maxLines = 4
            )
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = { state.send(screen.id, draft); draft = "" },
                shape = CircleShape,
                contentPadding = PaddingValues(0.dp),
                modifier = Modifier.size(46.dp),
                colors = ButtonDefaults.buttonColors(containerColor = SonarColors.netFill)
            ) { Text("↑", color = SonarColors.onNet, fontSize = 20.sp) }
        }
    }

    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun MessageBubble(m: SonarMsg) {
    val align = if (m.mine) Alignment.End else Alignment.Start
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = align) {
        Box(
            Modifier
                .widthIn(max = 300.dp)
                .background(
                    if (m.mine) SonarColors.netFill else SonarColors.bubbleOther,
                    RoundedCornerShape(18.dp)
                )
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            Text(
                m.content,
                color = if (m.mine) SonarColors.onNet else SonarColors.text,
                fontSize = 16.sp
            )
        }
    }
}

@Composable
private fun NewChatSheet(onStart: (String) -> Unit, onDismiss: () -> Unit) {
    var peer by remember { mutableStateOf("") }
    Box(
        Modifier.fillMaxSize().background(SonarColors.bg.copy(alpha = 0.6f)).clickable(onClick = onDismiss),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = SonarColors.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("New secure chat", color = SonarColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text("Paste their npub. They need to have opened Sonar at least once.", color = SonarColors.text3, fontSize = 12.5.sp)
                Spacer(Modifier.height(14.dp))
                OutlinedTextField(
                    value = peer,
                    onValueChange = { peer = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("npub1…", color = SonarColors.text3) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii)
                )
                Spacer(Modifier.height(14.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onDismiss) { Text("Cancel", color = SonarColors.text2) }
                    Spacer(Modifier.width(8.dp))
                    Button(
                        onClick = { onStart(peer) },
                        colors = ButtonDefaults.buttonColors(containerColor = SonarColors.accentFill)
                    ) { Text("Start", color = SonarColors.onAccent) }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun ToastBar(text: String, onDone: () -> Unit) {
    LaunchedEffect(text) { kotlinx.coroutines.delay(2600); onDone() }
    Box(Modifier.fillMaxSize().padding(bottom = 90.dp), contentAlignment = Alignment.BottomCenter) {
        Surface(color = SonarColors.surface2, shape = RoundedCornerShape(13.dp)) {
            Text(text, color = SonarColors.text, fontSize = 13.5.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 11.dp))
        }
    }
}

@Composable
private fun Avatar(seed: String) {
    Box(
        Modifier.size(40.dp).background(SonarColors.surface2, CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Text(initials(seed), color = SonarColors.accent, fontSize = 15.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun FilledIcon(label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).background(SonarColors.surface2, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) { Text(label, color = SonarColors.accent, fontSize = 22.sp, fontWeight = FontWeight.Bold) }
}

private fun shortNpub(npub: String): String =
    if (npub.length > 16) npub.take(10) + "…" + npub.takeLast(4) else npub

private fun initials(s: String): String {
    val t = s.removePrefix("npub").trim()
    return if (t.isEmpty()) "?" else t.take(2).uppercase()
}
