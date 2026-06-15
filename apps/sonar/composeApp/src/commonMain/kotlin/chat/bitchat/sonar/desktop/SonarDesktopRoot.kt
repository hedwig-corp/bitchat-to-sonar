package chat.bitchat.sonar.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import chat.bitchat.sonar.Screen
import chat.bitchat.sonar.SonarAppState
import chat.bitchat.sonar.SonarChat
import chat.bitchat.sonar.SonarLifecycle
import chat.bitchat.sonar.SonarScreenHost
import chat.bitchat.sonar.screens.SonarOnboardingScreen
import chat.bitchat.sonar.ui.SonarTheme
import chat.bitchat.sonar.ui.SNDot
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.sonar

/**
 * Desktop application root: theme + boot + onboarding gating around
 * [SonarDesktopRoot]. The desktop twin of [chat.bitchat.sonar.App] — same
 * SonarAppState, same onboarding screen, but the persistent split-view shell
 * instead of the phone's single-screen stack. App lock is unavailable on desktop
 * (see [chat.bitchat.sonar.AppLock]) so there is no lock gate here.
 */
@Composable
fun DesktopApp() {
    val scope = rememberCoroutineScope()
    val state = remember { SonarAppState(scope) }
    LaunchedEffect(state) { SonarLifecycle.onForeground = { state.setForeground(it) } }
    LaunchedEffect(Unit) { state.boot() }
    SonarTheme(dark = state.dark) {
        val s = sonar
        Surface(Modifier.fillMaxSize(), color = s.bg) {
            if (!state.onboarded) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Box(Modifier.width(420.dp)) { SonarOnboardingScreen(state) }
                }
            } else {
                SonarDesktopRoot(state)
            }
        }
    }
}

/**
 * Sonar Desktop — the split-view shell from design/handoff `Sonar Desktop.html`:
 * a persistent sidebar (status chip, channels & messages, you + settings) beside
 * a content pane. The content pane reuses the exact same feature-complete mobile
 * screens via [SonarScreenHost] (one UI codebase), so a desktop user can drive
 * every internet-backed function the iOS/Android apps have — secure DMs, geohash
 * channels, presence, media, profiles, verify and settings.
 *
 * Selection is master-detail: clicking a sidebar item collapses the nav stack to
 * Home and pushes the chosen screen, so a screen's Back acts as "deselect".
 */
@Composable
fun SonarDesktopRoot(state: SonarAppState) {
    val s = sonar
    Surface(Modifier.fillMaxSize(), color = s.bg) {
        Row(Modifier.fillMaxSize()) {
            DesktopSidebar(state)
            // Hairline divider between sidebar and content.
            Box(Modifier.fillMaxHeight().width(1.dp).background(s.hairline))
            Box(Modifier.weight(1f).fillMaxHeight()) {
                if (state.isHome) DesktopWelcome() else SonarScreenHost(state)
            }
        }
    }
}

/** Select a sidebar destination without growing the nav stack. */
private fun SonarAppState.select(open: SonarAppState.() -> Unit) {
    resetToHome()
    open()
}

@Composable
private fun DesktopSidebar(state: SonarAppState) {
    val s = sonar
    val savedChannels = state.channels.filter { gh ->
        gh != "mesh" && state.locationChannels.none { it.geohash == gh }
    }
    Column(Modifier.width(300.dp).fillMaxHeight().background(s.surface.copy(alpha = 0.4f))) {
        // brand row + compose (new chat → search)
        Row(
            Modifier.fillMaxWidth().padding(start = 18.dp, end = 12.dp, top = 16.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Rings, 20.dp, s.accent, weight = 1.8f)
            Spacer(Modifier.width(8.dp))
            Text("sonar", color = s.text, fontSize = 19.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            SNIconButton(SNIconName.Search, size = 18.dp, weight = 2f, tint = s.text2) {
                state.select { push(Screen.Search) }
            }
        }

        // status chip
        Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
            StatusBanner(online = state.started, connecting = state.connecting)
        }

        // search affordance
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp)
                .clip(RoundedCornerShape(10.dp)).background(s.surface2)
                .clickable { state.select { push(Screen.Search) } }
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIcon(SNIconName.Search, 14.dp, s.text3, weight = 2.2f)
            Spacer(Modifier.width(8.dp))
            Text("Search & start a chat", color = s.text3, fontSize = 13.5.sp)
        }

        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(top = 6.dp, bottom = 10.dp)) {
            // Sonar radar entry
            item {
                DiscoverRow(
                    selected = state.screen is Screen.Nearby,
                    title = "Sonar",
                    sub = "${state.meshPeers.size} people in range",
                ) { state.select { push(Screen.Nearby) } }
            }

            // Around you (GPS location channels — empty on desktop without location)
            if (state.locationChannels.isNotEmpty()) {
                item { SNSectionLabel("Around you") }
                items(state.locationChannels, key = { it.geohash + it.level.name }) { c ->
                    val here = state.presence(c.geohash)
                    ChannelRow(
                        selected = (state.screen as? Screen.Channel)?.geohash == c.geohash,
                        title = c.name,
                        sub = if (here > 0) "$here here now · ${c.level.label}" else c.level.label,
                    ) { state.select { openChannel(c.geohash) } }
                }
            }

            // Channels (Bluetooth mesh + any joined geohash channels)
            item { SNSectionLabel("Channels") }
            item {
                ChannelRow(
                    selected = (state.screen as? Screen.Channel)?.geohash == "mesh",
                    title = "Bluetooth mesh",
                    sub = "Public · nearby phones",
                    mesh = true,
                ) { state.select { openChannel("mesh") } }
            }
            items(savedChannels, key = { it }) { gh ->
                ChannelRow(
                    selected = (state.screen as? Screen.Channel)?.geohash == gh,
                    title = "#$gh",
                    sub = "joined channel",
                ) { state.select { openChannel(gh) } }
            }

            // Messages (mesh DMs — empty on desktop — + White Noise secure chats)
            item { SNSectionLabel("Messages") }
            if (state.chats.isEmpty() && state.meshDmRows.isEmpty()) {
                item { EmptyHint("No secure chats yet — use Search to paste an npub and start one.") }
            }
            items(state.meshDmRows, key = { "mesh:" + it.peerId }) { row ->
                DmRow(
                    selected = (state.screen as? Screen.Chat)?.id == "mesh:" + row.peerId,
                    name = row.name, preview = row.preview, mesh = true, verified = false,
                ) { state.select { openDm(row.peerId, row.name) } }
            }
            items(state.chats, key = { it.id }) { chat ->
                val title = state.chatTitle(chat)
                DmRow(
                    selected = (state.screen as? Screen.Chat)?.id == chat.id,
                    name = title, preview = "Tap to open", mesh = false,
                    verified = state.isVerified(chat.id),
                ) { state.select { openChat(chat) } }
            }
        }

        // me + settings
        Box(Modifier.fillMaxWidth().height(1.dp).background(s.hairline))
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SonarAvatar(state.nick.ifBlank { "you" }, 36.dp)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(state.nick.ifBlank { "you" }, color = s.text, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val key = state.npub.ifBlank { "connecting…" }
                Text(
                    if (key.length > 18) key.take(14) + "…" else key,
                    color = s.text3, fontSize = 10.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = chat.bitchat.sonar.ui.SonarType.mono(10.5)
                )
            }
            SNIconButton(SNIconName.Chevron, size = 18.dp, tint = s.text2) { state.select { push(Screen.Settings) } }
        }
    }
}

@Composable
private fun StatusBanner(online: Boolean, connecting: Boolean) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
            .background(if (online) s.greenSoft else s.surface2)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SNDot(if (online) s.green else if (connecting) s.accent else s.text3, 9.dp)
        Spacer(Modifier.width(8.dp))
        Text(
            buildAnnotatedString {
                val label = if (online) "Online" else if (connecting) "Connecting…" else "Offline"
                withStyle(SpanStyle(color = s.text, fontWeight = FontWeight.Bold)) { append(label) }
                withStyle(SpanStyle(color = s.text2)) {
                    append(if (online) " · reaches anyone over the internet" else " · waiting for relays")
                }
            },
            fontSize = 12.5.sp
        )
    }
}

@Composable
private fun DiscoverRow(selected: Boolean, title: String, sub: String, onClick: () -> Unit) {
    val s = sonar
    SidebarRow(selected, onClick) {
        Box(
            Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(SNIconName.Rings, 18.dp, s.accentDeep) }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = s.text, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold)
            Text(sub, color = s.text2, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun ChannelRow(selected: Boolean, title: String, sub: String, mesh: Boolean = false, onClick: () -> Unit) {
    val s = sonar
    SidebarRow(selected, onClick) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(if (mesh) SNIconName.Mesh else SNIconName.Pin, if (mesh) 20.dp else 18.dp, s.accentDeep, weight = if (mesh) 2f else 1.8f) }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = s.text, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(sub, color = s.text2, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun DmRow(selected: Boolean, name: String, preview: String, mesh: Boolean, verified: Boolean, onClick: () -> Unit) {
    val s = sonar
    SidebarRow(selected, onClick) {
        SonarAvatar(name, 40.dp, presence = if (mesh) true else null)
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, color = s.text, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (verified) { Spacer(Modifier.width(5.dp)); SNIcon(SNIconName.ShieldCheck, 13.dp, s.green, weight = 2.1f) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!mesh) { SNIcon(SNIconName.Lock, 11.dp, s.text3, weight = 2.2f); Spacer(Modifier.width(4.dp)) }
                Text(preview, color = s.text2, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun SidebarRow(
    selected: Boolean,
    onClick: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 1.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) s.accentSoft else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

@Composable
private fun EmptyHint(text: String) {
    Text(
        text, color = sonar.text3, fontSize = 12.5.sp, lineHeight = 17.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)
    )
}

/** Welcome placeholder shown in the content pane when nothing is selected. */
@Composable
private fun DesktopWelcome() {
    val s = sonar
    Box(Modifier.fillMaxSize().background(s.bg), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(72.dp).clip(CircleShape).background(s.accentSoft),
                contentAlignment = Alignment.Center
            ) { SNIcon(SNIconName.Rings, 36.dp, s.accentDeep, weight = 1.6f) }
            Spacer(Modifier.height(18.dp))
            Text("Welcome to Sonar", color = s.text, fontSize = 22.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.height(8.dp))
            Text(
                "Pick a conversation or channel on the left, open Sonar to see who's\nnearby, or search to start a new end-to-end encrypted chat.",
                color = s.text2, fontSize = 14.sp, lineHeight = 21.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
        }
    }
}
