package chat.bitchat.sonar

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.screens.SonarOnboardingScreen
import chat.bitchat.sonar.ui.SNDot
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarTheme
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.sin

/** Bridges Android activity foreground state into the commonMain UI without
 *  pulling Android lifecycle APIs into commonMain. */
object SonarLifecycle {
    @Volatile var onForeground: ((Boolean) -> Unit)? = null
    @Volatile private var onInviteLink: ((String) -> Unit)? = null
    private val pendingInviteLinks = mutableListOf<String>()

    fun submitInviteLink(token: String) {
        val handler = onInviteLink
        if (handler != null) {
            handler(token)
        } else {
            pendingInviteLinks.add(token)
        }
    }

    fun installInviteLinkHandler(handler: (String) -> Unit) {
        onInviteLink = handler
        val queued = pendingInviteLinks.toList()
        pendingInviteLinks.clear()
        queued.forEach(handler)
    }

    @Volatile private var onSharedText: ((String) -> Unit)? = null
    private val pendingSharedTexts = mutableListOf<String>()

    fun submitSharedText(text: String) {
        val handler = onSharedText
        if (handler != null) handler(text) else pendingSharedTexts.add(text)
    }

    fun installSharedTextHandler(handler: (String) -> Unit) {
        onSharedText = handler
        val queued = pendingSharedTexts.toList()
        pendingSharedTexts.clear()
        queued.forEach(handler)
    }
}

@Composable
fun App() {
    val scope = rememberCoroutineScope()
    val state = remember { SonarAppState(scope) }
    LaunchedEffect(state) {
        SonarLifecycle.onForeground = { state.setForeground(it) }
        SonarLifecycle.installInviteLinkHandler { state.requestJoinViaLink(it) }
        SonarLifecycle.installSharedTextHandler { state.handleSharedText(it) }
    }
    LaunchedEffect(Unit) { state.boot() }
    SonarTheme(dark = state.dark) {
        val s = sonar

        Surface(Modifier.fillMaxSize(), color = s.bg) {
            if (state.locked) {
                LockScreen(onUnlock = { state.unlock() })
            } else if (!state.onboarded) {
                Box(Modifier.statusBarsPadding().imePadding()) { SonarOnboardingScreen(state) }
            } else {
                Box(Modifier.statusBarsPadding().imePadding()) {
                    SonarScreenHost(state)
                }
            }
        }
    }
}

/**
 * Renders the screen on top of [SonarAppState]'s navigation stack. Extracted from
 * [App] so the desktop three-pane shell can reuse the exact same feature-complete
 * screens (chat, channel, radar, settings, profile, search, geo-DM) inside its
 * content pane — one UI codebase across phone and desktop.
 */
@Composable
internal fun SonarScreenHost(state: SonarAppState) {
    when (val sc = state.screen) {
        is Screen.Home -> HomeScreen(state)
        is Screen.Chat -> ChatScreen(state, sc)
        is Screen.Settings -> chat.bitchat.sonar.screens.SonarSettingsScreen(state)
        is Screen.Profile -> chat.bitchat.sonar.screens.SonarProfileScreen(state)
        is Screen.Nearby -> chat.bitchat.sonar.screens.SonarRadarScreen(state)
        is Screen.Search -> chat.bitchat.sonar.screens.SonarSearchScreen(state)
        is Screen.Channel -> chat.bitchat.sonar.screens.SonarChannelScreen(state, sc)
        is Screen.GeoDm -> GeoDmScreen(state, sc)
        is Screen.Call -> CallScreen(state, sc)
        is Screen.ContactProfile -> chat.bitchat.sonar.screens.SonarContactProfileScreen(state, sc)
        is Screen.GroupInfo -> chat.bitchat.sonar.screens.SonarGroupInfoScreen(state, sc)
        is Screen.WalletActivity -> chat.bitchat.sonar.screens.SonarWalletActivityScreen(state)
    }
}

@Composable
private fun HomeScreen(state: SonarAppState) {
    val s = sonar
    var composeSheet by remember { mutableStateOf(false) }
    var connSheet by remember { mutableStateOf(false) }
    var wipeAsk by remember { mutableStateOf(false) }
    var titleTaps by remember { mutableStateOf(0) }
    var pendingDelete by remember { mutableStateOf<DeleteTarget?>(null) }
    var pendingInvite by remember { mutableStateOf<SonarGroupInvite?>(null) }
    val meshCount = state.meshPeers.size
    // Triple-tap the title within 1.2s → emergency wipe (1:1 with iOS).
    LaunchedEffect(titleTaps) { if (titleTaps in 1..2) { kotlinx.coroutines.delay(1200); titleTaps = 0 } }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // bc-header: avatar (→settings) · "sonar" centered (triple-tap) · rings (→nearby)
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).clickable { state.push(Screen.Settings) },
                    contentAlignment = Alignment.Center
                ) { SonarAvatar(state.nick.ifBlank { "you" }, 32.dp) }
                Text(
                    "sonar", color = s.text, fontSize = 27.sp, fontWeight = FontWeight.Black,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f).clickable(
                        indication = null, interactionSource = remember { MutableInteractionSource() }
                    ) { titleTaps++; if (titleTaps >= 3) { titleTaps = 0; wipeAsk = true } }
                )
                SNIconButton(SNIconName.Rings, size = 22.dp, weight = 2f, tint = s.text2) { state.push(Screen.Nearby) }
            }

            // status chip — centered pill
            Box(Modifier.fillMaxWidth().padding(bottom = 10.dp), contentAlignment = Alignment.Center) {
                StatusChipPill(state.started, state.connecting, meshCount) { connSheet = true }
            }

            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 110.dp)) {
                item { SNSectionLabel("Around you") }
                // "Around you" collapses the geohash precision ladder (+ Mesh) into one
                // card with a tier picker (design: HereCard) instead of a flat list.
                item {
                    val hereItems = remember(state.locationChannels, meshCount, state.presenceByGeohash) {
                        buildList {
                            add(HereItem("mesh", "Mesh", "Mesh", meshCount))
                            state.locationChannels.forEach { c ->
                                add(HereItem(c.geohash, c.name, c.level.label, state.presence(c.geohash)))
                            }
                        }
                    }
                    HereCard(hereItems) { state.openChannel(it) }
                }
                if (state.locationChannels.isEmpty()) item { LocationHint() }
                // "Saved channels" (design): channels you explicitly pinned (the
                // bookmark in a channel header), each a one-tap row with its live
                // "N here now" count. This is the pin/favorite the HereCard lacks.
                // Exclude channels already shown in the "Around you" ladder so a
                // pinned current-location channel doesn't appear twice (design:
                // Saved = "NOT every place you pass through"); it reappears here
                // once you move out of its area.
                val saved = state.savedChannels.filter { gh -> state.locationChannels.none { it.geohash == gh } }
                if (saved.isNotEmpty()) {
                    item { SNSectionLabel("Saved channels") }
                    items(saved, key = { "saved:" + it }) { gh ->
                        val here = state.presence(gh)
                        val gc = state.locationChannels.firstOrNull { it.geohash == gh }
                        ConvRow(
                            avatar = { PlaceTile(52.dp) },
                            title = gc?.name ?: channelName(gh),
                            sub = if (here > 0) "$here here now" else "Saved channel",
                            onLongClick = { state.toggleSaved(gh) }, // long-press to unpin
                        ) { state.openChannel(gh) }
                    }
                }
                item { SNSectionLabel("Messages") }
                if (state.groupInvites.isEmpty() && state.visibleChats.isEmpty() && state.meshDmRows.isEmpty()) item { EmptyMessages() }
                items(state.groupInvites, key = { "invite:" + it.id }) { invite ->
                    val title = invite.groupName.ifBlank { "Group chat" }
                    ConvRow(
                        avatar = { SonarAvatar(title, 52.dp, presence = false) },
                        title = title,
                        sub = "${invite.memberCount} members · invite",
                        lock = true,
                    ) { pendingInvite = invite }
                }
                // BLE-mesh DMs (incl. ones started by a peer messaging us) — over
                // Bluetooth, so a cyan dot instead of the internet lock. A Sonar
                // peer's White Noise leg is folded into this row (one row/person).
                items(state.meshDmRows, key = { "mesh:" + it.peerId }) { row ->
                    ConvRow(
                        avatar = { SonarAvatar(row.name, 52.dp, presence = state.dmInRange(row.peerId)) },
                        title = row.name, sub = row.preview, lock = false,
                        onLongClick = { pendingDelete = DeleteTarget(row.peerId, row.name, isMesh = true, isGroup = false) },
                    ) { state.openDm(row.peerId, row.name) }
                }
                items(state.visibleChats, key = { it.id }) { chat ->
                    val chatTitle = state.chatTitle(chat)
                    ConvRow(
                        avatar = { SonarAvatar(chatTitle, 52.dp, presence = false) },
                        title = chatTitle, sub = "Tap to open", lock = true,
                        verified = state.isVerified(chat.id),
                        unread = (state.unreadByChat[chat.id] ?: 0) > 0,
                        onLongClick = { pendingDelete = DeleteTarget(chat.id, chatTitle, isMesh = false, isGroup = state.isMultiMemberChat(chat.id)) },
                    ) { state.openChat(chat) }
                }
            }
        }

        // sn-fab: Search pill + compose rings
        Row(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .padding(start = 14.dp, end = 14.dp, bottom = 28.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(999.dp)).background(s.surface)
                    .clickable { state.push(Screen.Search) }.padding(horizontal = 16.dp, vertical = 13.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SNIcon(SNIconName.Search, 17.dp, s.text3, weight = 2f)
                Spacer(Modifier.width(9.dp))
                Text("Search", color = s.text3, fontSize = 15.sp)
            }
            // sn-compose → "Start a chat" sheet (1:1 with iOS SonarHomeScreen).
            Box(
                Modifier.size(48.dp).clip(CircleShape).background(s.accentFill)
                    .clickable { composeSheet = true },
                contentAlignment = Alignment.Center
            ) { SNIcon(SNIconName.Rings, 23.dp, s.onAccent, weight = 1.9f) }
        }
    }

    if (composeSheet) ComposeSheet(state) { composeSheet = false }
    if (connSheet) ConnectivitySheet(online = state.started, meshCount = meshCount) { connSheet = false }
    if (wipeAsk) WipeConfirmSheet(onWipe = { wipeAsk = false; state.wipe() }, onClose = { wipeAsk = false })
    pendingInvite?.let { invite ->
        GroupInviteSheet(
            invite = invite,
            onAccept = { state.acceptGroupInvite(invite.id); pendingInvite = null },
            onDecline = { state.declineGroupInvite(invite.id); pendingInvite = null },
            onClose = { pendingInvite = null }
        )
    }
    pendingDelete?.let { t ->
        DeleteChatSheet(
            name = t.name,
            isGroup = t.isGroup,
            onDelete = {
                if (t.isMesh) state.deleteMeshDm(t.id) else state.deleteMarmotChat(t.id)
                pendingDelete = null
            },
            onClose = { pendingDelete = null }
        )
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

private fun channelName(geohash: String): String =
    if (geohash.equals("mesh", true)) "Bluetooth mesh" else "#$geohash"

/** bc-chip — centered status pill: dot + "<b>Online</b> · reaches anyone". */
@Composable
private fun StatusChipPill(online: Boolean, connecting: Boolean, meshCount: Int, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.clip(RoundedCornerShape(999.dp)).background(s.surface)
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SNDot(if (online) s.green else s.accent, 9.dp)
        Spacer(Modifier.width(8.dp))
        val label = if (online) "Online" else "Offline"
        val desc = when {
            online -> "reaches anyone"
            connecting -> "connecting…"
            else -> "$meshCount nearby on Bluetooth"
        }
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = s.text, fontWeight = FontWeight.Bold)) { append(label) }
                withStyle(SpanStyle(color = s.text2)) { append(" · $desc") }
            },
            fontSize = 13.sp
        )
    }
}

/** bc-placetile — accent-soft rounded square with a pin glyph (channel avatar). */
@Composable
private fun PlaceTile(size: Dp) {
    val s = sonar
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * 0.31f)).background(s.accentSoft),
        contentAlignment = Alignment.Center
    ) { SNIcon(SNIconName.Pin, size * 0.46f, s.accentDeep) }
}

/** Mesh channel avatar — accent-soft tile with the mesh (signal) glyph. */
@Composable
private fun MeshTile(size: Dp) {
    val s = sonar
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * 0.31f)).background(s.accentSoft),
        contentAlignment = Alignment.Center
    ) { SNIcon(SNIconName.Mesh, size * 0.5f, s.accentDeep, weight = 2f) }
}

@Composable
private fun LocationHint() {
    val s = sonar
    Text(
        "Turn on location to see public channels for your area (neighborhood → country).",
        color = s.text3, fontSize = 13.sp, lineHeight = 18.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 4.dp)
    )
}

/** bc-row — avatar · (title [+verified]) / (lock? + sub) · time/unread. */
@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun ConvRow(
    avatar: @Composable () -> Unit,
    title: String,
    sub: String,
    time: String? = null,
    lock: Boolean = false,
    verified: Boolean = false,
    unread: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        avatar()
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, color = s.text, fontSize = 16.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (verified) { Spacer(Modifier.width(5.dp)); SNIcon(SNIconName.ShieldCheck, 14.dp, s.green, weight = 2.1f) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (lock) { SNIcon(SNIconName.Lock, 12.dp, s.text3, weight = 2.2f); Spacer(Modifier.width(4.dp)) }
                Text(sub, color = s.text2, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            if (time != null) Text(time, color = s.text3, fontSize = 12.sp)
            if (unread) Box(Modifier.size(11.dp).clip(CircleShape).background(s.accent))
        }
    }
}

@Composable
private fun WipeConfirmSheet(onWipe: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("Emergency wipe", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "This deletes your identity, wallet, all chats and your nickname from this phone. It can’t be undone.",
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                )
                Spacer(Modifier.height(16.dp))
                SNPrimaryButton("Wipe everything", net = false) { onWipe() }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Cancel", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

/** A chat the user long-pressed to delete or leave. */
private data class DeleteTarget(val id: String, val name: String, val isMesh: Boolean, val isGroup: Boolean)

@Composable
private fun DeleteChatSheet(name: String, isGroup: Boolean, onDelete: () -> Unit, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text(if (isGroup) "Leave this group?" else "Delete this chat?", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(
                    if (isGroup) {
                        "Sends a leave update to “$name” and removes the conversation from this device."
                    } else {
                        "Removes “$name” from this device only. The other person isn’t notified, and you can start the chat again later."
                    },
                    color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                )
                Spacer(Modifier.height(16.dp))
                SNPrimaryButton(if (isGroup) "Leave group" else "Delete chat", net = false) { onDelete() }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Cancel", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun ConnectivitySheet(online: Boolean, meshCount: Int, onClose: () -> Unit) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp)) {
                Text(
                    "Connections", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)
                )
                Spacer(Modifier.height(6.dp))
                chat.bitchat.sonar.ui.SNSettingsRow(
                    icon = SNIconName.Globe, tone = if (online) SNTone.Cyan else SNTone.Default,
                    label = "Internet",
                    sub = if (online) "Connected · Nostr relays" else "Offline — messages wait or travel over Bluetooth",
                    value = if (online) "Online" else "Offline", trail = SNTrail.None,
                )
                chat.bitchat.sonar.ui.SNSettingsRow(
                    icon = SNIconName.Mesh, tone = SNTone.Cyan, label = "Bluetooth mesh",
                    sub = "$meshCount people in range", trail = SNTrail.None, divider = false,
                )
                Spacer(Modifier.height(10.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Done", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun GroupInviteSheet(
    invite: SonarGroupInvite,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    val title = invite.groupName.ifBlank { "Group chat" }
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 22.dp, bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SonarAvatar(title, 64.dp, presence = false)
                Spacer(Modifier.height(12.dp))
                Text(title, color = s.text, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(5.dp))
                Text(
                    "${invite.memberCount} members · invited by ${shortNpub(invite.welcomerNpub)}",
                    color = s.text2,
                    fontSize = 13.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(14.dp))
                Text(
                    "End-to-end encrypted — only group members can read this",
                    color = s.text3,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    lineHeight = 18.sp,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(18.dp))
                SNPrimaryButton("Accept") { onAccept() }
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.fillMaxWidth().height(50.dp).clip(RoundedCornerShape(15.dp)).background(s.surface2)
                        .clickable(onClick = onDecline),
                    contentAlignment = Alignment.Center
                ) {
                    Text("Decline", color = s.text2, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
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
            "Tap Search and paste someone’s npub to start an end-to-end encrypted chat over the internet.",
            color = s.text3, fontSize = 13.sp, lineHeight = 18.sp
        )
    }
}

@Composable
private fun ChannelHint() {
    val s = sonar
    Text(
        "Tap Search to join a channel and chat publicly with people in an area.",
        color = s.text3, fontSize = 13.sp, lineHeight = 18.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 4.dp)
    )
}

@Composable
private fun ChatScreen(state: SonarAppState, screen: Screen.Chat) {
    val s = sonar
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf("") }
    var emojiTray by remember { mutableStateOf(false) }
    var paySheet by remember { mutableStateOf(false) }
    var verifySheet by remember { mutableStateOf(false) }
    var addSheet by remember { mutableStateOf(false) }
    var addPeopleSheet by remember { mutableStateOf(false) }
    var removePeopleSheet by remember { mutableStateOf(false) }
    var mediaViewer by remember { mutableStateOf<SonarMedia?>(null) }
    var previewPackCoordinate by remember { mutableStateOf<String?>(null) }
    val mediaActions = rememberMediaActions()
    val pickPhoto = rememberPhotoPicker { bytes, name, mime ->
        state.stageMediaPreview(screen.id, bytes, name, mime)
    }
    // Voice-note recorder (hold the mic to record; drag left to cancel).
    val recorder = remember { VoiceRecorder() }
    var recording by remember { mutableStateOf(false) }
    var recElapsed by remember { mutableStateOf(0) }
    var recLevel by remember { mutableStateOf(0f) }
    var recDragX by remember { mutableStateOf(0f) }
    val recScope = rememberCoroutineScope()
    LaunchedEffect(recording) {
        while (recording) {
            recElapsed = recorder.elapsed(); recLevel = recorder.level()
            kotlinx.coroutines.delay(80)
        }
    }
    // Radar "Send sats" opens the chat with pay=true → jump straight to the sheet.
    fun openPaySheetOrRetry() {
        scope.launch {
            val message = state.paymentDetailsUnavailableMessage(screen.id)
            if (message != null) state.toast = message else paySheet = true
        }
    }
    LaunchedEffect(screen.id) {
        state.refreshDescriptorForChat(screen.id)
        if (screen.pay) openPaySheetOrRetry()
    }
    val listState = rememberLazyListState()
    // Transcript feed = chat messages (pay control lines collapsed) + mocked
    // call-log records, merged chronologically.
    val visible = state.messages.filter {
        val p = PayLine.decode(it.content)
        // Hide ⚡PAY control lines (Claim/Done) and ☎CALL signaling lines. The
        // cheap ☎CALL prefix check avoids an FFI call for ordinary chat.
        val isCall = it.content.trimStart().startsWith("☎CALL") &&
            SonarCore.callParseControl(it.content) != null
        (p == null || p is PayLine.Pay) && !isCall
    }
    val calls = run { state.callVersion; state.callRecords(screen.id) }
    val feed: List<Any> = (visible + calls).sortedBy { if (it is CallRecord) it.tsSecs else (it as SonarMsg).tsSecs }
    LaunchedEffect(feed.size) {
        if (feed.isNotEmpty()) listState.animateScrollToItem(feed.size - 1)
    }
    val currentChat = state.chats.firstOrNull { it.id == screen.id }
    val isGroup = state.isMultiMemberChat(screen.id)
    // Resolve a human name for the peer or group (Marmot names can be blank).
    val peerName = screen.name.ifBlank {
        currentChat?.let { state.chatTitle(it) } ?: "secure chat"
    }
    val verified = !isGroup && run { state.payVersion; state.isVerified(screen.id) }
    // A radar-peer DM is a "mesh:" route that auto-picks transport: BLE mesh
    // (cyan/"Bluetooth") while in range, White Noise (indigo/"internet") when out
    // of range. A pure Marmot chat (non-mesh route) is always internet. Per-message
    // bubbles colour by the leg they travelled (`m.viaInternet`).
    val isMeshRoute = screen.id.startsWith("mesh:")
    val peerId = screen.id.removePrefix("mesh:")
    val inRange = run { state.payVersion; isMeshRoute && state.dmInRange(peerId) }
    // Do we know this peer's White Noise account (npub)? Then a Bluetooth chat
    // continues over the internet when out of range — they're a White Noise
    // account, not a "Sonar-only" peer. A plain bitchat peer (no npub) can't.
    val hasAccount = isMeshRoute && state.hasWhiteNoiseAccount(peerId)
    // Transport the NEXT message will take (drives header + composer + send button).
    val sendOverMesh = isMeshRoute && inRange
    val transport = if (sendOverMesh) "Bluetooth" else "internet"

    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize()) {
        // bc-header (DM): avatar + name + verified shield + lock·"Via internet"
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 12.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = { state.back() })
            SonarAvatar(peerName, 36.dp, presence = false)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).clickable {
                if (isGroup) state.push(Screen.GroupInfo(screen.id))
                else state.push(Screen.ContactProfile(screen.id, peerName))
            }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        peerName, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis
                    )
                    if (verified) { Spacer(Modifier.width(5.dp)); SNIcon(SNIconName.ShieldCheck, 14.dp, s.green, weight = 2.1f) }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.Lock, 11.dp, s.text2, weight = 2.4f)
                    Spacer(Modifier.width(4.dp))
                    Text(
                        (if (verified) "Verified · " else "") + "Via $transport",
                        color = s.text3, fontSize = 11.5.sp
                    )
                }
            }
            // Audio call button. Calls are Sonar-only and use live BLE when
            // available, otherwise White Noise signaling for that peer.
            if (state.canCall(screen.id)) {
                SNIconButton(SNIconName.Phone, size = 20.dp, weight = 2f, tint = s.text2) {
                    state.placeCall(screen.id, peerName, video = false)
                }
            }
        }

        if (isMeshRoute && !inRange) {
            if (hasAccount) {
                chat.bitchat.sonar.ui.SNBanner(
                    icon = SNIconName.Globe, tone = chat.bitchat.sonar.ui.SNBannerTone.Net,
                    bold = "Out of range", rest = " — continuing over White Noise"
                )
            } else {
                chat.bitchat.sonar.ui.SNBanner(
                    icon = SNIconName.Mesh, tone = chat.bitchat.sonar.ui.SNBannerTone.Neutral,
                    bold = "Out of range", rest = " — messages will wait until you meet again"
                )
            }
        } else if (verified) {
            chat.bitchat.sonar.ui.SNBanner(
                icon = SNIconName.ShieldCheck, tone = chat.bitchat.sonar.ui.SNBannerTone.Enc,
                bold = "Verified", rest = " — you confirmed $peerName’s safety number"
            )
        } else if (isGroup) {
            chat.bitchat.sonar.ui.SNBanner(
                icon = SNIconName.Lock, tone = chat.bitchat.sonar.ui.SNBannerTone.Enc,
                bold = "End-to-end encrypted", rest = " — only group members can read this"
            )
        } else {
            chat.bitchat.sonar.ui.SNBanner(
                icon = SNIconName.Lock, tone = chat.bitchat.sonar.ui.SNBannerTone.Enc,
                bold = "End-to-end encrypted", rest = " — only you and $peerName can read this",
                actionLabel = "Verify", onAction = { verifySheet = true }
            )
        }

        if (feed.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                chat.bitchat.sonar.ui.SNEmptyState(
                    icon = SNIconName.Lock,
                    title = "Say hi to $peerName",
                    desc = if (isGroup) {
                        "Messages here are end-to-end encrypted. Only group members can read them."
                    } else {
                        "Messages here are end-to-end encrypted. Only the two of you can read them."
                    }
                )
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                state = listState,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
            ) {
                itemsIndexed(
                    feed,
                    // Index-keyed call records avoid duplicate keys when two calls end
                    // in the same second (identical ts/dur/kind would otherwise collide).
                    key = { i, it -> if (it is CallRecord) "c:$i" else "m:${(it as SonarMsg).id}" }
                ) { i, item ->
                    if (item is CallRecord) {
                        CallLogRow(item)
                    } else {
                        val m = item as SonarMsg
                        // Colour each bubble by the leg it travelled: mesh route + this
                        // message went over mesh ⇒ cyan; otherwise indigo (internet).
                        val msgMesh = isMeshRoute && !m.viaInternet
                        val pay = PayLine.decode(m.content) as? PayLine.Pay
                        if (pay != null) {
                            val status = run { state.payVersion; state.payStatus(pay.uuid) }
                            PayBubble(m, pay, status, peerName, mesh = msgMesh, fiatOf = { state.fiatOrNull(it) })
                        } else if (m.media.isNotEmpty()) {
                            MediaBubble(
                                m,
                                state,
                                screen.id,
                                mesh = msgMesh,
                                author = state.groupAuthorName(m, isGroup),
                                showState = m.mine && i == feed.lastIndex,
                                onOpen = { mediaViewer = it }
                            )
                        } else if (m.stickerRef != null) {
                            StickerBubble(
                                m,
                                state = state,
                                mesh = msgMesh,
                                author = state.groupAuthorName(m, isGroup),
                                showState = m.mine && i == feed.lastIndex,
                                onTap = { coord -> previewPackCoordinate = coord },
                            )
                        } else MessageBubble(
                            m,
                            msgMesh,
                            author = state.groupAuthorName(m, isGroup),
                            showState = m.mine && i == feed.lastIndex,
                        )
                    }
                }
            }
        }

        if (draft.startsWith("/")) SlashHints(draft) { draft = it }
        if (emojiTray && !recording) chat.bitchat.sonar.screens.SonarEmojiPicker(
            onEmoji = { draft += it },
            onGif = { item ->
                emojiTray = false
                state.sendGifItem(screen.id, item)
            },
            onSticker = { sticker, packCoordinate ->
                emojiTray = false
                state.sendStickerItem(screen.id, sticker, packCoordinate)
            },
            loadStickerPack = { author, identifier, relays ->
                state.stickerPack(author, identifier, relays)
            },
            loadStickerImage = { url, expectedSha256 -> state.stickerImage(url, expectedSha256) },
            onClose = { emojiTray = false }
        )
        // ONE composer row in BOTH states. Only the left (plus↔trash) and middle
        // (text field↔recording pill) swap; the mic Box on the right MUST stay
        // mounted while recording, or Compose cancels its hold-to-record gesture
        // (the @RestrictsSuspension pointer coroutine dies with its layout node)
        // and the finger-release is never seen — the note never sends.
        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.Bottom) {
            if (recording) {
                // Slide-left-far OR tap the trash to discard.
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { recorder.cancel(); recording = false; recDragX = 0f },
                    contentAlignment = Alignment.Center
                ) { SNIcon(SNIconName.Trash, 19.dp, s.danger, weight = 2f) }
                Spacer(Modifier.width(8.dp))
                RecordingPill(recElapsed, recLevel, recDragX, Modifier.weight(1f))
            } else {
                // bc-plus: "Add to your message" sheet (bitcoin / location / verify / reactions)
                Box(
                    Modifier.size(40.dp).clip(CircleShape).background(s.surface2).clickable { addSheet = true },
                    contentAlignment = Alignment.Center
                ) { SNIcon(SNIconName.Plus, 20.dp, s.text2, weight = 2.4f) }
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.weight(1f).clip(RoundedCornerShape(22.dp)).background(s.surface2)
                        .heightIn(min = 46.dp)
                        .padding(horizontal = 16.dp, vertical = 12.dp)
                ) {
                    if (draft.isEmpty()) Text("Message $peerName · via $transport", color = s.text3, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    BasicTextField(
                        value = draft, onValueChange = { draft = it },
                        textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                        cursorBrush = SolidColor(s.accent),
                        singleLine = false,
                        maxLines = 5,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
            if (!recording) {
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.size(40.dp).clip(CircleShape).background(if (emojiTray) s.accentSoft else s.surface2)
                        .clickable { emojiTray = !emojiTray },
                    contentAlignment = Alignment.Center
                ) { SNIcon(SNIconName.Smile, 20.dp, if (emojiTray) s.accent else s.text2, weight = 2f) }
            }
            Spacer(Modifier.width(8.dp))
            if (draft.isEmpty() && state.canSendMedia(screen.id)) {
                // Hold-to-record mic (design: bc-sendbtn mic). Drag left past the
                // threshold to cancel; release to send. STAYS mounted across the
                // recording toggle (draft is empty + canSendMedia is unchanged), so
                // the gesture coroutine below survives — this is load-bearing.
                val micBg = if (recording) (if (transport == "internet") s.netFill else s.accentFill) else s.surface2
                val micFg = if (recording) (if (transport == "internet") s.onNet else s.onAccent) else s.text2
                Box(
                    Modifier.size(46.dp).clip(CircleShape).background(micBg)
                        .pointerInput(screen.id) {
                            // The pointer scope is @RestrictsSuspension, so the recorder
                            // lifecycle runs in recScope: launch start() at down, join it on
                            // release so finish()/cancel() can never race ahead of start().
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false)
                                recDragX = 0f; recElapsed = 0; recording = true
                                var startedOk = false
                                val startJob = recScope.launch { startedOk = recorder.start() }
                                var dx = 0f
                                var pressed = true
                                while (pressed) {
                                    val ev = awaitPointerEvent()
                                    val ch = ev.changes.firstOrNull { it.id == down.id } ?: ev.changes.first()
                                    dx += ch.positionChange().x; recDragX = dx
                                    if (!ch.pressed) pressed = false
                                }
                                val cancel = dx < -240f
                                recScope.launch {
                                    startJob.join()
                                    if (!startedOk) state.toast = "Allow microphone access to record voice notes."
                                    else if (cancel) recorder.cancel()
                                    else { val b = recorder.finish(); if (b != null) state.sendVoiceNote(screen.id, b) }
                                    recording = false; recDragX = 0f
                                }
                            }
                        },
                    contentAlignment = Alignment.Center
                ) { SNIcon(SNIconName.Mic, 20.dp, micFg, weight = 2f) }
            } else {
                val sendEnabled = draft.isNotBlank()
                val sendBg = if (!sendEnabled) s.surface2 else if (sendOverMesh) s.accentFill else s.netFill
                val sendFg = if (!sendEnabled) s.text3 else if (sendOverMesh) s.onAccent else s.onNet
                Box(
                    Modifier.size(46.dp).clip(CircleShape).background(sendBg)
                        .clickable(enabled = sendEnabled) {
                            val d = draft; draft = ""
                            emojiTray = false
                            if (!state.handleCommand(d, peerName, channelGeohash = null, chatId = screen.id)) {
                                state.send(screen.id, d)
                            }
                        },
                    contentAlignment = Alignment.Center
                ) { Text("↑", color = sendFg, fontSize = 20.sp, fontWeight = FontWeight.Bold) }
            }
        }
    }
    mediaViewer?.let { media ->
        MediaViewer(
            media = media,
            state = state,
            chatId = screen.id,
            actions = mediaActions,
            onClose = { mediaViewer = null },
            modifier = Modifier.matchParentSize()
        )
    }
    state.pendingMediaPreviews.firstOrNull { it.chatId == screen.id }?.let { preview ->
        val data by androidx.compose.runtime.produceState<ByteArray?>(null, preview.tempPath) {
            value = withContext(Dispatchers.IO) { readTempMediaFile(preview.tempPath) }
        }
        val previewData = data
        if (previewData != null) {
            MediaSendPreview(
                data = previewData,
                isGif = preview.mime == "image/gif",
                onSend = { state.confirmSendPreview(screen.id) },
                onCancel = { state.cancelPreview(screen.id) },
                modifier = Modifier.matchParentSize()
            )
        }
    }
    }
    if (addSheet) AddToMessageSheet(
        peerName = peerName,
        onBitcoin = { addSheet = false; openPaySheetOrRetry() },
        onLocation = { addSheet = false; state.toast = "Location sharing is coming soon." },
        onVerify = { addSheet = false; verifySheet = true },
        onReactions = { addSheet = false; state.toast = "Reactions are coming soon." },
        onAddPeople = { addSheet = false; addPeopleSheet = true },
        onRemovePeople = { addSheet = false; removePeopleSheet = true },
        onClose = { addSheet = false },
        canSendPhoto = state.canSendMedia(screen.id),
        canSendPayment = state.hasDirectPaymentRoute(screen.id),
        canVerify = !state.isMultiMemberChat(screen.id),
        canShareLocation = !state.isMultiMemberChat(screen.id),
        canManageGroup = isGroup,
        onPhoto = { addSheet = false; pickPhoto() }
    )
    if (addPeopleSheet) GroupAddPeopleSheet(
        state = state,
        chatId = screen.id,
        onClose = { addPeopleSheet = false }
    )
    if (removePeopleSheet) GroupRemovePeopleSheet(
        state = state,
        chatId = screen.id,
        onClose = { removePeopleSheet = false }
    )
    if (paySheet) PaySheet(
        peerName = peerName,
        balanceSats = state.walletBalanceSats(),
        // The receipt follows the chat route; the actual payment settles over Lightning.
        mesh = screen.id.startsWith("mesh:"),
        fiatOf = { state.fiatOrNull(it) },
        onSend = { sats -> scope.launch { state.sendPay(screen.id, sats)?.let { state.toast = it } } },
        onClose = { paySheet = false }
    )
    if (verifySheet) VerifySheet(
        peerName = peerName,
        info = state.verifyInfo(screen.id),
        myName = state.nick.ifBlank { "you" },
        onVerify = { state.markVerified(screen.id); verifySheet = false },
        onDismiss = { verifySheet = false }
    )
    previewPackCoordinate?.let { coord ->
        StickerPackPreviewSheet(state, coord) { previewPackCoordinate = null }
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

/** "Add to your message" sheet — 1:1 with the iOS/prototype DM "+" sheet. */
@Composable
private fun AddToMessageSheet(
    peerName: String,
    onBitcoin: () -> Unit,
    onLocation: () -> Unit,
    onVerify: () -> Unit,
    onReactions: () -> Unit,
    onAddPeople: () -> Unit,
    onRemovePeople: () -> Unit,
    onClose: () -> Unit,
    canSendPhoto: Boolean = false,
    canSendPayment: Boolean = true,
    canVerify: Boolean = true,
    canShareLocation: Boolean = true,
    canManageGroup: Boolean = false,
    onPhoto: () -> Unit = {},
) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)
            ) {
                Text("Add to your message", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                if (canSendPhoto) {
                    ActionRow(SNIconName.Lock, "Send photo or GIF", "Encrypted end-to-end over White Noise", onPhoto)
                }
                if (canSendPayment) ActionRow(SNIconName.Coin, "Send bitcoin", "Instant over Lightning", onBitcoin)
                if (canShareLocation) ActionRow(SNIconName.NavArrow, "Share location", "Only $peerName will see it", onLocation)
                if (canManageGroup) {
                    ActionRow(SNIconName.People, "Add people", "Invite local contacts or paste npubs", onAddPeople)
                    ActionRow(SNIconName.Trash, "Remove people", "Manage current group members", onRemovePeople)
                }
                if (canVerify) ActionRow(SNIconName.Shield, "Verify safety number", "Confirm this chat is secure", onVerify)
                ActionRow(SNIconName.People, "Reactions", "A little fun, no noise", onReactions)
            }
        }
    }
}

@Composable
private fun GroupAddPeopleSheet(state: SonarAppState, chatId: String, onClose: () -> Unit) {
    val s = sonar
    var draft by remember(chatId) { mutableStateOf("") }
    var selected by remember(chatId) { mutableStateOf(setOf<String>()) }
    val existing = state.groupMemberNpubs(chatId)
    val pasted = remember(draft, existing) { parsedNpubs(draft).filter { it !in existing } }
    val members = remember(pasted, selected) { mergedNpubs(pasted, selected) }
    val contacts = state.groupInviteContacts(excluding = existing)

    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)
            ) {
                Text("Add people", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))
                SheetField(draft, "npub1… npub1…") { draft = it }
                Spacer(Modifier.height(8.dp))
                contacts.forEach { contact ->
                    GroupContactRow(contact, selected = contact.npub in selected) {
                        selected = if (contact.npub in selected) selected - contact.npub else selected + contact.npub
                    }
                }
                Spacer(Modifier.height(10.dp))
                SNPrimaryButton("Add people", disabled = members.isEmpty()) {
                    state.addGroupMembers(chatId, members)
                    onClose()
                }
            }
        }
    }
}

@Composable
private fun GroupRemovePeopleSheet(state: SonarAppState, chatId: String, onClose: () -> Unit) {
    val s = sonar
    val members = state.groupMemberContacts(chatId)
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)
            ) {
                Text("Remove people", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                if (members.isEmpty()) {
                    Text("No removable members.", color = s.text2, fontSize = 13.5.sp, modifier = Modifier.padding(vertical = 12.dp))
                } else {
                    members.forEach { member ->
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
                                .clickable { state.removeGroupMembers(chatId, listOf(member.npub)) }
                                .padding(vertical = 9.dp, horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            SonarAvatar(member.title, 38.dp)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(member.title, color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(member.subtitle, color = s.text2, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            SNIcon(SNIconName.Trash, 17.dp, s.danger, weight = 2f)
                        }
                    }
                }
            }
        }
    }
}

/** Full-screen lock gate; auto-prompts the device credential on appear. */
@Composable
private fun LockScreen(onUnlock: () -> Unit) {
    val s = sonar
    LaunchedEffect(Unit) { onUnlock() }
    Box(Modifier.fillMaxSize().background(s.bg), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            SNIcon(SNIconName.Lock, 40.dp, s.accent, weight = 2f)
            Spacer(Modifier.height(16.dp))
            Text("Sonar is locked", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text("Unlock with your device PIN or biometrics.", color = s.text2, fontSize = 13.5.sp)
            Spacer(Modifier.height(22.dp))
            Box(
                Modifier.clip(RoundedCornerShape(14.dp)).background(s.accentFill)
                    .clickable(onClick = onUnlock).padding(horizontal = 28.dp, vertical = 12.dp)
            ) { Text("Unlock", color = s.onAccent, fontSize = 15.sp, fontWeight = FontWeight.Bold) }
        }
    }
}

/** Slash-command suggestions (mirrors the iOS command autocomplete surface). */
@Composable
internal fun SlashHints(draft: String, onPick: (String) -> Unit) {
    val s = sonar
    val matches = SonarSlashCommands.matches(draft)
    if (matches.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp)) {
        matches.forEach { command ->
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                    .clickable {
                        onPick("/${command.canonical}${if (command.needsArgument) " " else ""}")
                    }.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("/${command.canonical}", color = s.accent, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(10.dp))
                Text(command.description, color = s.text3, fontSize = 13.sp)
            }
        }
    }
}


@Composable
private fun VerifySheet(
    peerName: String,
    info: SonarVerify,
    myName: String,
    onVerify: () -> Unit,
    onDismiss: () -> Unit,
) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onDismiss),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text("Verify safety numbers", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        SonarAvatar(myName, 48.dp, presence = false)
                        Spacer(Modifier.height(4.dp)); Text(myName, color = s.text2, fontSize = 12.sp)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        SonarAvatar(peerName, 48.dp, presence = false)
                        Spacer(Modifier.height(4.dp)); Text(peerName, color = s.text2, fontSize = 12.sp)
                    }
                }
                Spacer(Modifier.height(16.dp))
                if (info.safety.isEmpty()) {
                    Text(
                        info.note ?: "Safety numbers aren't available yet.",
                        color = s.text2, fontSize = 13.5.sp, textAlign = TextAlign.Center
                    )
                } else {
                    Text(
                        "Compare these numbers with $peerName in person or on a call. If they match, this chat is end-to-end encrypted and nobody is in the middle.",
                        color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp, textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(14.dp))
                    // 3 rows × 4 groups, monospace.
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        listOf(0, 4, 8).forEach { row ->
                            Text(
                                info.safety.subList(row, row + 4).joinToString(" "),
                                color = s.text, style = chat.bitchat.sonar.ui.SonarType.mono(15.0),
                                modifier = Modifier.padding(vertical = 3.dp)
                            )
                        }
                    }
                    Spacer(Modifier.height(18.dp))
                    if (info.verified) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            SNIcon(SNIconName.ShieldCheck, 16.dp, s.green)
                            Spacer(Modifier.width(6.dp))
                            Text("Verified", color = s.green, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        }
                    } else {
                        SNPrimaryButton("They match — mark as verified") { onVerify() }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onDismiss), contentAlignment = Alignment.Center) {
                    Text("Close", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun GeoDmScreen(state: SonarAppState, screen: Screen.GeoDm) {
    val s = sonar
    var draft by remember { mutableStateOf("") }
    val blocked = state.isGeoDmBlocked(screen.peerHex)
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
            Column(Modifier.weight(1f)) {
                Text(screen.name, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.Lock, 11.dp, s.text2, weight = 2.4f)
                    Spacer(Modifier.width(4.dp))
                    Text(if (blocked) "Blocked" else "Sonar · end-to-end encrypted", color = s.text3, fontSize = 11.5.sp)
                }
            }
            SNIconButton(
                SNIconName.X,
                tint = if (blocked) s.danger else s.text3,
                onClick = { state.setChannelAuthorBlocked(screen.peerHex, screen.name, !blocked) }
            )
        }
        chat.bitchat.sonar.ui.SNBanner(
            icon = if (blocked) SNIconName.X else SNIconName.Lock,
            tone = if (blocked) chat.bitchat.sonar.ui.SNBannerTone.Neutral else chat.bitchat.sonar.ui.SNBannerTone.Enc,
            bold = if (blocked) "Blocked" else "End-to-end encrypted",
            rest = if (blocked) " — unblock ${screen.name} to send or receive messages" else " — a private chat with ${screen.name} from the channel"
        )
        if (state.messages.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                chat.bitchat.sonar.ui.SNEmptyState(
                    icon = SNIconName.Lock, title = "Say hi to ${screen.name}",
                    desc = "Private and end-to-end encrypted. Only the two of you can read this."
                )
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(), state = listState,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
            ) { items(state.messages, key = { it.id }) { m -> MessageBubble(m) } }
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
                    cursorBrush = SolidColor(s.accent), modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.size(46.dp).clip(CircleShape).background(s.netFill)
                    .clickable { state.sendGeoDmMsg(screen.geohash, screen.peerHex, draft); draft = "" },
                contentAlignment = Alignment.Center
            ) { Text("↑", color = s.onNet, fontSize = 20.sp, fontWeight = FontWeight.Bold) }
        }
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

@Composable
private fun MessageBubble(m: SonarMsg, mesh: Boolean = false, author: String? = null, showState: Boolean = false) {
    val s = sonar
    // Own bubble is cyan over BLE mesh, indigo over Nostr/internet (the design's
    // transport-colored bubbles); the other party's bubble is always the surface.
    val mineBg = if (mesh) s.accentFill else s.netFill
    val onMine = if (mesh) s.onAccent else s.onNet
    val linkColor = if (m.mine) onMine else s.accent
    val annotated = remember(m.content, m.mine, mesh) { linkify(m.content, linkColor) }
    val firstUrl = remember(m.content) { firstUrl(m.content) }
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    Column(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            Text(
                author,
                color = s.text3,
                fontSize = 11.5.sp,
                modifier = Modifier.padding(start = 6.dp, bottom = 2.dp)
            )
        }
        Box(
            Modifier.clip(RoundedCornerShape(18.dp))
                .background(if (m.mine) mineBg else s.bubbleOther)
                .then(if (firstUrl != null) Modifier.clickable { uriHandler.openUri(firstUrl) } else Modifier)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            // Selectable (long-press → Copy); tap opens a link if present —
            // mirrors the iOS deterministic copy + tappable-link behavior.
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(annotated, color = if (m.mine) onMine else s.text, fontSize = 16.sp)
            }
        }
        if (showState) MessageStatusFooter(m, mesh)
    }
}

@Composable
private fun MessageStatusFooter(m: SonarMsg, mesh: Boolean) {
    val state = m.state ?: return
    val s = sonar
    val pending = state == "Sending" || state == "Uploading"
    val failed = state == "Couldn't send"
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(top = 3.dp, start = 4.dp, end = 4.dp)
    ) {
        if (pending) {
            androidx.compose.material3.CircularProgressIndicator(
                color = s.text3,
                strokeWidth = 1.4.dp,
                modifier = Modifier.size(11.dp),
            )
        } else {
            SNIcon(if (failed) SNIconName.X else SNIconName.Check, 11.dp, if (failed) s.danger else s.text3, weight = 2.6f)
        }
        Text(
            "$state · ${if (mesh) "Bluetooth" else "internet"}",
            color = if (failed) s.danger else s.text3,
            fontSize = 11.sp,
        )
    }
}

@Composable
private fun StickerBubble(
    m: SonarMsg,
    state: SonarAppState,
    mesh: Boolean = false,
    author: String? = null,
    showState: Boolean = false,
    onTap: ((String) -> Unit)? = null,
) {
    val ref = m.stickerRef ?: return
    var imageBytes by remember(ref) { mutableStateOf<ByteArray?>(null) }
    var failed by remember(ref) { mutableStateOf(false) }
    LaunchedEffect(ref) {
        failed = false
        imageBytes = state.stickerImage(ref)
        failed = imageBytes == null
    }
    val tapModifier = if (onTap != null) {
        Modifier.clickable { onTap(ref.packCoordinate) }
    } else Modifier
    Column(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            Text(
                author,
                color = sonar.text3,
                fontSize = 11.5.sp,
                modifier = Modifier.padding(start = 6.dp, bottom = 2.dp)
            )
        }
        val image = remember(imageBytes) {
            imageBytes?.let { runCatching { decodeImageBitmap(it) }.getOrNull() }
        }
        val displayFailed = failed || (imageBytes != null && image == null)
        if (image != null) {
            androidx.compose.foundation.Image(
                bitmap = image,
                contentDescription = ref.shortcode,
                modifier = tapModifier.size(120.dp).padding(4.dp),
            )
        } else if (displayFailed) {
            Box(
                tapModifier.size(120.dp).padding(4.dp).clip(RoundedCornerShape(12.dp)).background(sonar.surface2),
                contentAlignment = Alignment.Center,
            ) {
                Text(ref.shortcode, color = sonar.text3, fontSize = 12.sp)
            }
        } else {
            Box(
                Modifier.size(120.dp).padding(4.dp),
                contentAlignment = Alignment.Center,
            ) {
                androidx.compose.material3.CircularProgressIndicator(
                    color = sonar.text3, strokeWidth = 2.dp, modifier = Modifier.size(20.dp),
                )
            }
        }
        if (showState) MessageStatusFooter(m, mesh)
    }
}

@Composable
private fun StickerPackPreviewSheet(state: SonarAppState, coordinate: String, onClose: () -> Unit) {
    val s = sonar
    val scope = rememberCoroutineScope()
    val parts = remember(coordinate) { coordinate.split(":", limit = 3) }
    var pack by remember(coordinate) { mutableStateOf<SonarStickerPack?>(null) }
    var loading by remember(coordinate) { mutableStateOf(true) }
    var installed by remember(coordinate) { mutableStateOf(state.isPackInstalled(coordinate)) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(coordinate) {
        loading = true
        state.refreshInstalledPacks()
        installed = state.isPackInstalled(coordinate)
        if (parts.size == 3) {
            pack = state.stickerPack(parts[1], parts[2])
        }
        loading = false
    }
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(
            color = s.surface,
            shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp),
            modifier = Modifier.clickable(enabled = false, onClick = {}),
        ) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                val p = pack
                if (loading) {
                    Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
                        androidx.compose.material3.CircularProgressIndicator(
                            color = s.text3, strokeWidth = 2.dp, modifier = Modifier.size(24.dp),
                        )
                    }
                } else if (p == null) {
                    Text("Could not load sticker pack", color = s.text2, fontSize = 14.sp)
                    Spacer(Modifier.height(16.dp))
                    Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                        Text("Close", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                } else {
                    Text(p.title, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    if (!p.description.isNullOrBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(p.description, color = s.text2, fontSize = 13.sp, maxLines = 2)
                    }
                    Spacer(Modifier.height(4.dp))
                    Text("${p.stickers.size} stickers", color = s.text3, fontSize = 12.sp)
                    Spacer(Modifier.height(12.dp))
                    androidx.compose.foundation.lazy.grid.LazyVerticalGrid(
                        columns = androidx.compose.foundation.lazy.grid.GridCells.Fixed(5),
                        modifier = Modifier.fillMaxWidth().heightIn(max = 280.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        items(p.stickers.size) { i ->
                            val sticker = p.stickers[i]
                            var imageBytes by remember(sticker.url) { mutableStateOf<ByteArray?>(null) }
                            LaunchedEffect(sticker.url) {
                                imageBytes = state.stickerImage(sticker.url, sticker.sha256)
                            }
                            val image = remember(imageBytes) {
                                imageBytes?.let { runCatching { decodeImageBitmap(it) }.getOrNull() }
                            }
                            Box(
                                Modifier.aspectRatio(1f).clip(RoundedCornerShape(8.dp)).background(s.surface2),
                                contentAlignment = Alignment.Center,
                            ) {
                                if (image != null) {
                                    androidx.compose.foundation.Image(
                                        bitmap = image,
                                        contentDescription = sticker.shortcode,
                                        modifier = Modifier.fillMaxSize().padding(4.dp),
                                    )
                                } else {
                                    Text(
                                        sticker.emoji ?: sticker.shortcode,
                                        color = s.text3, fontSize = 11.sp, textAlign = TextAlign.Center,
                                    )
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    if (installed) {
                        SNPrimaryButton(
                            if (busy) "Removing..." else "Remove pack",
                            net = false,
                            disabled = busy,
                        ) {
                            scope.launch {
                                busy = true
                                if (state.uninstallStickerPack(coordinate)) {
                                    installed = false
                                }
                                busy = false
                            }
                        }
                    } else {
                        SNPrimaryButton(
                            if (busy) "Installing..." else "Install pack",
                            net = false,
                            disabled = busy,
                        ) {
                            scope.launch {
                                busy = true
                                if (state.installStickerPack(coordinate)) {
                                    installed = true
                                }
                                busy = false
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Box(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                        Text("Close", color = s.text2, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

/**
 * A media message bubble (Marmot MIP-04). No 1:1 design handoff exists for media,
 * so this is the deliberate, tasteful extension matching Sonar tokens: an inline
 * image (downloaded + decrypted on appear, cached by the store) or a file chip,
 * plus an optional caption.
 */
@Composable
private fun MediaBubble(
    m: SonarMsg,
    state: SonarAppState,
    chatId: String,
    mesh: Boolean,
    author: String? = null,
    showState: Boolean = false,
    onOpen: (SonarMedia) -> Unit,
) {
    val s = sonar
    val media = m.media.first()
    Column(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            Text(
                author,
                color = s.text3,
                fontSize = 11.5.sp,
                modifier = Modifier.padding(start = 6.dp, bottom = 2.dp)
            )
        }
        if (media.isImage) {
            var loadAttempt by remember(media.url, chatId) { mutableStateOf(0) }
            val loadResult by androidx.compose.runtime.produceState<Pair<Boolean, ByteArray?>>(
                false to null, media.url, chatId, loadAttempt
            ) {
                value = true to state.mediaData(chatId, media)
            }
            val mediaBytes = loadResult.second
            val img = androidx.compose.runtime.remember(mediaBytes) {
                mediaBytes?.let { decodeImageBitmap(it) }
            }
            val renderAsGif = media.isGif && mediaBytes?.looksLikeGifBytes() == true
            Box(
                Modifier.widthIn(max = 240.dp).clip(RoundedCornerShape(18.dp)).background(s.surface2)
                    .clickable { onOpen(media) },
                contentAlignment = Alignment.Center
            ) {
                val bmp = img
                val bytes = mediaBytes
                when {
                    bytes != null && (renderAsGif || bmp != null) -> {
                        MediaImage(
                            bytes = bytes,
                            isGif = renderAsGif,
                            modifier = Modifier.widthIn(max = 240.dp).heightIn(max = 300.dp)
                        )
                        if (renderAsGif) GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
                    }
                    bytes != null -> InlineMediaFileChip(media = media, onOpen = { onOpen(media) })
                    loadResult.first -> Box(
                        Modifier.size(width = 180.dp, height = 130.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Couldn't load image", color = s.text3, fontSize = 12.sp)
                            Text(
                                "Retry",
                                color = s.accent,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.clickable { loadAttempt += 1 }
                            )
                        }
                    }
                    else -> Box(
                        Modifier.size(width = 180.dp, height = 130.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        androidx.compose.material3.CircularProgressIndicator(
                            color = s.text3, strokeWidth = 2.dp
                        )
                    }
                }
                if (media.isGif && bytes == null) GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
        } else if (media.mimeType.startsWith("audio/")) {
            AudioBubble(m, state, chatId, media, mesh = mesh)
        } else {
            InlineMediaFileChip(media = media, onOpen = { onOpen(media) })
        }
        if (m.content.isNotEmpty()) {
            Spacer(Modifier.height(3.dp))
            Text(m.content, color = s.text, fontSize = 14.5.sp)
        }
        if (showState) MessageStatusFooter(m, mesh)
    }
}

private fun ByteArray.looksLikeGifBytes(): Boolean =
    size >= 6 &&
        this[0] == 0x47.toByte() &&
        this[1] == 0x49.toByte() &&
        this[2] == 0x46.toByte() &&
        this[3] == 0x38.toByte() &&
        (this[4] == 0x37.toByte() || this[4] == 0x39.toByte()) &&
        this[5] == 0x61.toByte()

@Composable
private fun InlineMediaFileChip(media: SonarMedia, onOpen: () -> Unit) {
    val s = sonar
    Row(
        Modifier.clip(RoundedCornerShape(14.dp)).background(s.surface2)
            .clickable { onOpen() }
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            media.filename,
            color = s.text,
            fontSize = 13.5.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun MediaViewer(
    media: SonarMedia,
    state: SonarAppState,
    chatId: String,
    actions: MediaActions,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val s = sonar
    val scope = rememberCoroutineScope()
    var chrome by remember(media.url) { mutableStateOf(true) }
    var status by remember(media.url) { mutableStateOf<String?>(null) }
    var loadAttempt by remember(media.url, chatId) { mutableStateOf(0) }
    val loadResult by androidx.compose.runtime.produceState<Pair<Boolean, ByteArray?>>(
        false to null, media.url, chatId, loadAttempt
    ) {
        status = null
        value = true to state.mediaData(chatId, media)
    }
    val loadedBytes = loadResult.second
    val image = remember(loadedBytes, media.url) {
        if (media.isImage) loadedBytes?.let { decodeImageBitmap(it) } else null
    }

    Box(modifier.background(Color.Black)) {
        when {
            image != null -> ZoomableMediaImage(
                image = image,
                description = media.filename,
                onSingleTap = { chrome = !chrome },
                modifier = Modifier.fillMaxSize()
            )
            loadedBytes != null -> MediaFilePreview(
                media = media,
                onOpen = {
                    scope.launch {
                        val ok = actions.open(loadedBytes, media.filename, media.mimeType)
                        status = if (ok) "Opened" else "Couldn't open media"
                    }
                },
                onSingleTap = { chrome = !chrome },
                modifier = Modifier.fillMaxSize()
            )
            loadResult.first -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "Couldn't load media",
                        color = Color.White.copy(alpha = 0.82f),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        "Retry",
                        color = Color.White,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.16f))
                            .clickable { loadAttempt += 1 }
                            .padding(horizontal = 18.dp, vertical = 9.dp)
                    )
                }
            }
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator(color = s.text3, strokeWidth = 2.dp)
            }
        }

        if (chrome) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.62f))
                        .padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(38.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                            .clickable { onClose() },
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.X, 18.dp, Color.White, weight = 2.2f) }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            media.filename,
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(media.mimeType, color = Color.White.copy(alpha = 0.62f), fontSize = 12.sp)
                    }
                    if (actions.canShare) {
                        MediaActionText("Share", enabled = loadedBytes != null) {
                            scope.launch {
                                val ok = actions.share(loadedBytes ?: return@launch, media.filename, media.mimeType)
                                status = if (ok) "Opening share sheet" else "Couldn't share media"
                            }
                        }
                        Spacer(Modifier.width(12.dp))
                    }
                    MediaActionText("Save", enabled = loadedBytes != null) {
                        scope.launch {
                            val ok = actions.save(loadedBytes ?: return@launch, media.filename, media.mimeType)
                            status = if (ok) "Saved" else "Couldn't save media"
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                if (status != null) {
                    Box(Modifier.fillMaxWidth().padding(bottom = 24.dp), contentAlignment = Alignment.Center) {
                        Text(
                            status!!,
                            color = Color.White,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.68f))
                                .padding(horizontal = 14.dp, vertical = 9.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MediaSendPreview(
    data: ByteArray,
    isGif: Boolean,
    onSend: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val s = sonar
    val image = remember(data) { if (!isGif) decodeImageBitmap(data) else null }
    Box(modifier.background(Color.Black)) {
        when {
            isGif || image != null -> MediaImage(
                bytes = data,
                isGif = isGif,
                modifier = Modifier.fillMaxSize().padding(bottom = 80.dp)
            )
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Couldn't decode image", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
            }
        }
        Row(
            Modifier.fillMaxWidth().align(Alignment.TopStart).padding(horizontal = 8.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, tint = Color.White, onClick = onCancel)
        }
        Row(
            Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(16.dp),
            horizontalArrangement = Arrangement.End
        ) {
            Box(
                Modifier.size(52.dp).clip(CircleShape).background(s.accent).clickable { onSend() },
                contentAlignment = Alignment.Center
            ) {
                Text("↑", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun ZoomableMediaImage(
    image: androidx.compose.ui.graphics.ImageBitmap,
    description: String,
    onSingleTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var scale by remember(description) { mutableStateOf(1f) }
    var offsetX by remember(description) { mutableStateOf(0f) }
    var offsetY by remember(description) { mutableStateOf(0f) }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        val nextScale = (scale * zoomChange).coerceIn(1f, 8f)
        scale = nextScale
        if (nextScale > 1f) {
            offsetX += panChange.x
            offsetY += panChange.y
        } else {
            offsetX = 0f
            offsetY = 0f
        }
    }
    androidx.compose.foundation.Image(
        bitmap = image,
        contentDescription = description,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offsetX
                translationY = offsetY
            }
            .transformable(transformState)
            .pointerInput(description) {
                detectTapGestures(
                    onTap = { onSingleTap() },
                    onDoubleTap = {
                        if (scale > 1f) {
                            scale = 1f
                            offsetX = 0f
                            offsetY = 0f
                        } else {
                            scale = 2.5f
                        }
                    }
                )
            }
    )
}

@Composable
private fun MediaFilePreview(
    media: SonarMedia,
    onOpen: () -> Unit,
    onSingleTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier.pointerInput(media.url) {
            detectTapGestures(onTap = { onSingleTap() }, onDoubleTap = { onOpen() })
        },
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Box(
                Modifier.size(74.dp).clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.10f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (media.mimeType.startsWith("video/")) "▶" else "·",
                    color = Color.White.copy(alpha = 0.86f),
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Bold
                )
            }
            Spacer(Modifier.height(14.dp))
            Text(
                media.filename,
                color = Color.White,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 28.dp)
            )
            Spacer(Modifier.height(4.dp))
            Text(media.mimeType, color = Color.White.copy(alpha = 0.62f), fontSize = 12.sp)
            Spacer(Modifier.height(14.dp))
            Box(
                Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.16f))
                    .clickable { onOpen() }
                    .padding(horizontal = 18.dp, vertical = 9.dp)
            ) {
                Text("Open", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun MediaActionText(label: String, enabled: Boolean, onClick: () -> Unit) {
    Text(
        label,
        color = if (enabled) Color.White else Color.White.copy(alpha = 0.35f),
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clickable(enabled = enabled) { onClick() }
    )
}

@Composable
private fun GifBadge(modifier: Modifier = Modifier) {
    Text(
        "GIF",
        color = sonar.onNet,
        fontSize = 10.sp,
        fontWeight = FontWeight.Black,
        modifier = modifier.clip(RoundedCornerShape(7.dp)).background(sonar.netFill)
            .padding(horizontal = 6.dp, vertical = 3.dp)
    )
}

/**
 * Audio / voice-note bubble (design: MediaBubble `media-audio` — play button +
 * `MediaWave` + duration). Downloads + decrypts the note on appear, then plays it
 * via [AudioNotePlayer]. Mirrors iOS `SNAudioBubble`. No duration metadata travels
 * with the note, so the static waveform is a deterministic hash of the filename.
 */
@Composable
private fun AudioBubble(m: SonarMsg, state: SonarAppState, chatId: String, media: SonarMedia, mesh: Boolean) {
    val s = sonar
    val net = !mesh
    val tint = if (net) s.netFill else s.accentFill
    val bytes by androidx.compose.runtime.produceState<ByteArray?>(null, media.url) {
        value = state.mediaData(chatId, media)
    }
    var playing by remember { mutableStateOf(false) }
    // Stop playback if the bubble leaves composition.
    androidx.compose.runtime.DisposableEffect(media.url) {
        onDispose { if (playing) AudioNotePlayer.stop() }
    }
    val durText = remember(media.durationMs) {
        media.durationMs?.let { fmtDur((it / 1000).toInt()) } ?: ""
    }
    Row(
        Modifier.clip(RoundedCornerShape(18.dp))
            .background(if (m.mine) tint.copy(alpha = 0.15f) else s.surface2)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.size(34.dp).clip(CircleShape)
                .background(if (m.mine) tint else s.surface)
                .clickable(enabled = bytes != null) {
                    val b = bytes ?: return@clickable
                    // onComplete resets `playing` when the note ends, is stopped, or
                    // another note steals the shared player.
                    if (playing) AudioNotePlayer.stop()
                    else { playing = true; AudioNotePlayer.play(b) { playing = false } }
                },
            contentAlignment = Alignment.Center
        ) {
            SNIcon(
                if (playing) SNIconName.Pause else SNIconName.Play, 14.dp,
                if (m.mine) (if (net) s.onNet else s.onAccent) else s.accent,
                weight = 2.2f
            )
        }
        Spacer(Modifier.width(11.dp))
        MediaWaveStatic(media.filename, Modifier.width(124.dp).height(22.dp))
        if (durText.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Text(durText, style = SonarType.mono(11.5), color = s.text3)
        }
    }
}

/** Static waveform (design: `MediaWave`) — deterministic hash bars from a seed. */
@Composable
private fun MediaWaveStatic(seed: String, modifier: Modifier = Modifier) {
    val s = sonar
    val bars = remember(seed) {
        var h = 2166136261u
        for (b in seed.encodeToByteArray()) { h = (h xor (b.toInt() and 0xFF).toUInt()) * 16777619u }
        (0 until 34).map { i ->
            val v = (h shr (i % 28)) xor (h * (i + 3).toUInt())
            0.22f + (v and 15u).toInt() / 15f * 0.78f
        }
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        bars.forEach { v ->
            Box(Modifier.width(2.dp).fillMaxHeight(v).clip(CircleShape).background(s.text2.copy(alpha = 0.5f)))
        }
    }
}

/**
 * The recording pill (design: VoiceRecorder) shown while the mic is held: rec dot,
 * timer, live waveform, and a slide-to-cancel hint that arms when [dragX] passes
 * the cancel threshold. The trash + mic buttons live in the composer row so the
 * mic (the gesture host) stays mounted across the recording toggle.
 */
@Composable
private fun RecordingPill(elapsed: Int, level: Float, dragX: Float, modifier: Modifier = Modifier) {
    val s = sonar
    val armed = dragX < -240f
    Row(
        modifier.heightIn(min = 46.dp).clip(RoundedCornerShape(22.dp)).background(s.surface2)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(s.danger))
        Text(fmtDur(elapsed), style = SonarType.mono(13.0, FontWeight.Medium), color = s.text, modifier = Modifier.width(38.dp))
        LiveWave(level, Modifier.weight(1f))
        Row(
            Modifier.alpha((1f + dragX / 110f).coerceIn(0f, 1f)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            SNIcon(SNIconName.Back, 12.dp, if (armed) s.danger else s.text3, weight = 2.4f)
            Text(
                if (armed) "release to cancel" else "slide to cancel",
                color = if (armed) s.danger else s.text3, fontSize = 12.sp, maxLines = 1
            )
        }
    }
}

/** Live recording waveform (design: VoiceLive) — bars driven off the mic [level]. */
@Composable
private fun LiveWave(level: Float, modifier: Modifier = Modifier) {
    val s = sonar
    val transition = rememberInfiniteTransition(label = "wave")
    val phase by transition.animateFloat(
        initialValue = 0f, targetValue = 6.2832f,
        animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing)),
        label = "phase"
    )
    Row(modifier.height(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 0 until 22) {
            val p = phase * 6 + i * 0.5f
            val v = (sin(p * 0.7f) + sin(p * 1.9f + i)) * 0.5f
            val h = 4f + abs(v) * 14f * maxOf(0.25f, level)
            Box(Modifier.width(2.dp).height(h.dp).clip(CircleShape).background(s.text2.copy(alpha = 0.55f)))
        }
    }
}

/** m:ss like the design's fmtDur. */
private fun fmtDur(sec: Int): String = "${sec / 60}:${(sec % 60).toString().padStart(2, '0')}"

/**
 * "Around you" card (design: screens.jsx HereCard) — collapses the geohash
 * precision ladder (+ Mesh) into ONE row plus a tier picker. The main row enters
 * the selected channel; the ladder ticks pick precision (live green dot when
 * someone's there). Mirrors iOS `SNHereCard`. [items] is mesh-first, then the
 * geohash levels coarsening outward. Returns the chosen channel's geohash.
 */
@Composable
private fun HereCard(items: List<HereItem>, onEnter: (String) -> Unit) {
    val s = sonar
    if (items.isEmpty()) {
        chat.bitchat.sonar.ui.SNEmptyState(
            icon = SNIconName.Pin, iconSize = 22.dp,
            title = "Nothing around you yet",
            desc = "Turn on location to see public channels nearby, or use the radar to find people over Bluetooth."
        )
        return
    }
    val defaultIdx = items.indexOfFirst { it.count > 0 }.let { if (it >= 0) it else items.lastIndex }
    var idx by remember(items.size) { mutableStateOf(defaultIdx) }
    val sel = items[idx.coerceIn(0, items.lastIndex)]
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clickable { onEnter(sel.geohash) }.padding(horizontal = 16.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (sel.geohash == "mesh") MeshTile(52.dp) else PlaceTile(52.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(sel.name, color = s.text, fontSize = 16.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    if (sel.count > 0) "${sel.tier} · ${sel.count} here now" else sel.tier,
                    color = s.text2, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
            }
            SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
        }
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(start = 14.dp, end = 14.dp, bottom = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            items.forEachIndexed { i, ch ->
                Row(
                    Modifier.clip(CircleShape)
                        .background(if (i == idx) s.surface2 else androidx.compose.ui.graphics.Color.Transparent)
                        .clickable { idx = i }
                        .padding(horizontal = 11.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        ch.tier.ifBlank { ch.name }, fontSize = 12.5.sp,
                        fontWeight = if (i == idx) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (i == idx) s.text else s.text3
                    )
                    if (ch.count > 0) Box(Modifier.size(5.dp).clip(CircleShape).background(s.green))
                }
            }
        }
    }
}

/** One precision tick on the "Around you" ladder. */
data class HereItem(val geohash: String, val name: String, val tier: String, val count: Int)

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

/**
 * "Start a chat" sheet — 1:1 with the iOS SonarHomeScreen compose sheet:
 * nearby Bluetooth peers, a "People nearby" radar entry, and an expandable
 * "Secure chat via npub" field. This is the home compose (cyan) button's action.
 */
@Composable
private fun ComposeSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    var npubEntry by remember { mutableStateOf(false) }
    var groupEntry by remember { mutableStateOf(false) }
    var npubDraft by remember { mutableStateOf("") }
    var groupName by remember { mutableStateOf("") }
    var groupMembers by remember { mutableStateOf("") }
    var selectedGroupNpubs by remember { mutableStateOf(setOf<String>()) }
    val inRange = state.meshPeers
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 620.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 22.dp)
            ) {
                Text("Start a chat", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(10.dp))
                if (inRange.isEmpty()) {
                    Text(
                        "Nobody in Bluetooth range right now.", color = s.text2, fontSize = 13.5.sp,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
                    )
                } else {
                    inRange.take(4).forEach { p ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                state.toast = "Bluetooth chats arrive with the live mesh link."
                            }.padding(vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            SonarAvatar(p.name, 44.dp, presence = true)
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(p.name, color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                                Text(
                                    "${chat.bitchat.sonar.screens.rssiLabel(p.rssi)} · Bluetooth",
                                    color = s.text2, fontSize = 13.sp
                                )
                            }
                        }
                    }
                }
                ActionRow(SNIconName.Rings, "People nearby", "Open the radar to see everyone in range") {
                    onClose(); state.push(Screen.Nearby)
                }
                ActionRow(SNIconName.Key, "Secure chat via npub", "Encrypted chat over the internet — reaches anywhere") {
                    npubEntry = true; groupEntry = false
                }
                ActionRow(SNIconName.People, "New group", "Invite nearby people or paste npubs") {
                    groupEntry = true; npubEntry = false
                }
                if (npubEntry) {
                    Spacer(Modifier.height(8.dp))
                    SheetField(npubDraft, "npub1…") { npubDraft = it }
                    Spacer(Modifier.height(10.dp))
                    SNPrimaryButton(
                        "Start secure chat",
                        disabled = !npubDraft.trim().startsWith("npub1")
                    ) { state.startChat(npubDraft.trim()); onClose() }
                }
                if (groupEntry) {
                    Spacer(Modifier.height(8.dp))
                    SheetField(groupName, "Group name") { groupName = it }
                    Spacer(Modifier.height(8.dp))
                    SheetField(groupMembers, "npub1… npub1…") { groupMembers = it }
                    val contacts = state.groupInviteContacts()
                    if (contacts.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        contacts.forEach { contact ->
                            GroupContactRow(contact, selected = contact.npub in selectedGroupNpubs) {
                                selectedGroupNpubs =
                                    if (contact.npub in selectedGroupNpubs) selectedGroupNpubs - contact.npub
                                    else selectedGroupNpubs + contact.npub
                            }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    val members = remember(groupMembers, selectedGroupNpubs) {
                        mergedNpubs(parsedNpubs(groupMembers), selectedGroupNpubs)
                    }
                    SNPrimaryButton(
                        "Create group",
                        disabled = groupName.trim().isEmpty() || members.size < 2
                    ) { state.createGroup(groupName, members); onClose() }
                }
            }
        }
    }
}

/** st-action-row: tinted icon tile + label/desc, used in the compose sheet. */
@Composable
private fun ActionRow(icon: SNIconName, label: String, desc: String, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(s.accentSoft),
            contentAlignment = Alignment.Center
        ) { SNIcon(icon, 18.dp, s.accentDeep) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(label, color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            Text(desc, color = s.text3, fontSize = 12.5.sp, lineHeight = 16.sp)
        }
        SNIcon(SNIconName.Chevron, 14.dp, s.text3, weight = 2.2f)
    }
}

@Composable
private fun GroupContactRow(contact: GroupContact, selected: Boolean, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 9.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SonarAvatar(contact.title, 38.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(contact.title, color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(contact.subtitle, color = s.text2, fontSize = 12.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(
            Modifier.size(24.dp).clip(CircleShape).background(if (selected) s.accent else s.surface2),
            contentAlignment = Alignment.Center
        ) {
            if (selected) SNIcon(SNIconName.Check, 13.dp, s.onAccent, weight = 2.6f)
        }
    }
}

private fun parsedNpubs(text: String): List<String> =
    text.split(Regex("[,\\s]+")).map { it.trim() }.filter { it.startsWith("npub1") }

private fun mergedNpubs(pasted: List<String>, selected: Set<String>): List<String> {
    val seen = linkedSetOf<String>()
    (pasted + selected.sorted()).forEach { if (it.isNotBlank()) seen += it }
    return seen.toList()
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
internal fun ToastBar(text: String, onDone: () -> Unit) {
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
