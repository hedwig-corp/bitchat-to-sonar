package chat.bitchat.sonar

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import chat.hedwig.transcript.compose.anchorTranscriptTail
import chat.hedwig.transcript.compose.isTranscriptTailAtLiveEdge
import chat.hedwig.transcript.compose.transcriptTailOverflowPx
import chat.hedwig.transcript.TranscriptOpenAction
import chat.hedwig.transcript.TranscriptScrollPolicy
import chat.hedwig.transcript.TranscriptTailPinSession
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.content_message_collapsed
import chat.bitchat.sonar.resources.content_message_expanded
import chat.bitchat.sonar.resources.content_message_show_less
import chat.bitchat.sonar.resources.content_message_show_more
import chat.bitchat.sonar.resources.sonar_icon
import chat.bitchat.sonar.screens.SonarOnboardingScreen
import chat.bitchat.sonar.screens.shouldCloseEmojiTrayOnComposerFocus
import chat.bitchat.sonar.screens.shouldDismissKeyboardWhenOpeningEmojiTray
import chat.bitchat.sonar.ui.authorColor
import chat.bitchat.sonar.ui.bcHue
import chat.bitchat.sonar.ui.SNDot
import org.jetbrains.compose.resources.painterResource
import org.jetbrains.compose.resources.stringResource
import chat.bitchat.sonar.ui.SNSettingsRow
import chat.bitchat.sonar.ui.SNTone
import chat.bitchat.sonar.ui.SNTrail
import chat.bitchat.sonar.ui.SNIcon
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.crypto.Bech32
import chat.bitchat.sonar.ui.SNGhostButton
import chat.bitchat.sonar.ui.SNPrimaryButton
import chat.bitchat.sonar.ui.SNSectionLabel
import chat.bitchat.sonar.ui.SonarAvatar
import chat.bitchat.sonar.ui.SonarTheme
import chat.bitchat.sonar.ui.SonarType
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.sin

/** Bridges Android activity foreground state into the commonMain UI without
 *  pulling Android lifecycle APIs into commonMain. */
object SonarLifecycle {
    @Volatile var onForeground: ((Boolean) -> Unit)? = null

    /**
     * Android only: true between `MainActivity.onStart` and `onStop`. Read by
     * the push wake, which must not tear down a healthy relay node while the
     * user is actively in the app.
     *
     * Compose Desktop never writes this — window focus is not visibility, and
     * desktop has no push wake to gate. Do not read it off Android without
     * first giving that platform a real visibility signal; it is permanently
     * false there.
     */
    @Volatile var appVisible: Boolean = false

    /** Real process background (Android `onStop`), not a transient pause. */
    @Volatile var onProcessBackground: (() -> Unit)? = null
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

    @Volatile private var onSharedContent: ((SharedContent) -> Unit)? = null
    private val pendingSharedContent = mutableListOf<SharedContent>()

    internal fun submitSharedContent(content: SharedContent) {
        val handler = onSharedContent
        if (handler != null) handler(content) else pendingSharedContent.add(content)
    }

    internal fun installSharedContentHandler(handler: (SharedContent) -> Unit) {
        onSharedContent = handler
        val queued = pendingSharedContent.toList()
        pendingSharedContent.clear()
        queued.forEach(handler)
    }

    @Volatile private var onOpenConversation: ((PendingOpenConversation) -> Unit)? = null
    private val pendingOpenConversations = mutableListOf<PendingOpenConversation>()

    fun submitOpenConversation(conversationId: String, jumpMessageId: String? = null) {
        val id = conversationId.trim()
        if (id.isEmpty()) return
        val req = PendingOpenConversation(
            conversationId = id,
            jumpMessageId = SonarNotificationHandoff.normalizeJumpMessageId(jumpMessageId),
        )
        val handler = onOpenConversation
        if (handler != null) {
            handler(req)
        } else {
            // Dedupe: cold-start / locked taps may retry the same id.
            pendingOpenConversations.removeAll { it.conversationId == id }
            pendingOpenConversations.add(req)
        }
    }

    fun installOpenConversationHandler(handler: (PendingOpenConversation) -> Unit) {
        onOpenConversation = handler
        val queued = pendingOpenConversations.toList()
        pendingOpenConversations.clear()
        queued.forEach(handler)
    }

    /** Drop the live handler so later taps re-enter [pendingOpenConversations]
     *  until a live composition owns them again (Activity recreate / lock). */
    fun clearOpenConversationHandler(handler: ((PendingOpenConversation) -> Unit)? = null) {
        if (handler == null || onOpenConversation === handler) {
            onOpenConversation = null
        }
    }
}

@Composable
fun App(
    onFirstLocalStateReady: () -> Unit = {},
    stickerBenchmarkRequest: StickerBenchmarkRequest? = null,
) {
    val scope = rememberCoroutineScope()
    val state = remember { SonarAppState(scope) }
    DisposableEffect(state) {
        MeshRadio.setPeerUpdateListener(state::onMeshPeersChanged)
        onDispose {
            MeshRadio.setPeerUpdateListener(null)
            SonarLifecycle.clearOpenConversationHandler()
        }
    }
    LaunchedEffect(state) {
        SonarLifecycle.onForeground = { state.setForeground(it) }
        SonarLifecycle.onProcessBackground = { state.onProcessBackgrounded() }
        SonarLifecycle.installInviteLinkHandler { state.requestJoinViaLink(it) }
        SonarLifecycle.installSharedContentHandler { state.handleSharedContent(it) }
    }
    // Notification taps must wait for a coherent local chat list so folded
    // group → mesh remapping and openChat paint from real rows. Clear the
    // handler whenever this effect leaves (lock / dispose / recreate) so taps
    // re-queue instead of hitting a dead SonarAppState.
    LaunchedEffect(state, state.onboarded, state.locked, state.homeMessagesHydrated) {
        if (!state.onboarded || state.locked || !state.homeMessagesHydrated) {
            SonarLifecycle.clearOpenConversationHandler()
            return@LaunchedEffect
        }
        val handler: (PendingOpenConversation) -> Unit = {
            state.openConversationFromNotification(
                conversationId = it.conversationId,
                jumpMessageId = it.jumpMessageId,
            )
        }
        try {
            SonarLifecycle.installOpenConversationHandler(handler)
            awaitCancellation()
        } finally {
            SonarLifecycle.clearOpenConversationHandler(handler)
        }
    }
    LaunchedEffect(state.onboarded) {
        if (state.onboarded) state.boot()
    }
    LaunchedEffect(state, stickerBenchmarkRequest) {
        stickerBenchmarkRequest?.let { state.runStickerBenchmark(it) }
    }
    val firstLocalStateReady = isFirstLocalStateReady(
        onboarded = state.onboarded,
        locked = state.locked,
        homeMessagesHydrated = state.homeMessagesHydrated,
    )
    LaunchedEffect(firstLocalStateReady) {
        if (firstLocalStateReady) onFirstLocalStateReady()
    }
    SonarTheme(dark = state.dark) {
        val s = sonar

        Surface(Modifier.fillMaxSize(), color = s.bg) {
            if (state.locked) {
                LockScreen(onUnlock = { state.unlock() })
            } else if (!state.onboarded) {
                Box(Modifier.statusBarsPadding().navigationBarsPadding().imePadding()) {
                    SonarOnboardingScreen(state)
                }
            } else if (!state.homeMessagesHydrated) {
                // Never paint an incomplete Home shell. Android keeps its native
                // launch window above this branch; it remains as a safe fallback
                // for older Android versions and any future commonMain host.
                LocalStateLaunchSurface()
            } else {
                Box(Modifier.statusBarsPadding().navigationBarsPadding().imePadding()) {
                    // Trill (nudge) shake: any received/sent trill shakes the
                    // whole app content, whichever screen is on top.
                    TrillShakeHost(state.trillShakeTick) {
                        SonarScreenHost(state)
                    }
                }
            }
        }
    }
}

/**
 * A locked or not-yet-onboarded app has a complete first screen without chat
 * hydration. An unlocked account must wait for the coherent local Home model;
 * relay connectivity is deliberately not part of this boundary.
 */
internal fun isFirstLocalStateReady(
    onboarded: Boolean,
    locked: Boolean,
    homeMessagesHydrated: Boolean,
): Boolean = !onboarded || locked || homeMessagesHydrated

@Composable
private fun LocalStateLaunchSurface() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Image(
            painter = painterResource(Res.drawable.sonar_icon),
            contentDescription = null,
            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(18.dp)),
        )
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
        is Screen.ShareTo -> chat.bitchat.sonar.screens.SonarShareToScreen(state)
        is Screen.Channel -> chat.bitchat.sonar.screens.SonarChannelScreen(state, sc)
        is Screen.GeoDm -> GeoDmScreen(state, sc)
        is Screen.Call -> CallScreen(state, sc)
        is Screen.ContactProfile -> chat.bitchat.sonar.screens.SonarContactProfileScreen(state, sc)
        is Screen.GroupInfo -> chat.bitchat.sonar.screens.SonarGroupInfoScreen(state, sc)
        is Screen.WalletActivity -> chat.bitchat.sonar.screens.SonarWalletActivityScreen(state)
        is Screen.SendPayment -> chat.bitchat.sonar.screens.SonarSendPaymentScreen(state)
    }
}

@Composable
private fun HomeScreen(state: SonarAppState) {
    val s = sonar
    var composeSheet by remember { mutableStateOf(false) }
    var connSheet by remember { mutableStateOf(false) }
    var wipeAsk by remember { mutableStateOf(false) }
    var titleTaps by remember { mutableStateOf(0) }
    var pendingRowActions by remember { mutableStateOf<DeleteTarget?>(null) }
    var pendingMute by remember { mutableStateOf<DeleteTarget?>(null) }
    var pendingDelete by remember { mutableStateOf<DeleteTarget?>(null) }
    var pendingInvite by remember { mutableStateOf<SonarGroupInvite?>(null) }
    val meshCount = state.meshPeers.size
    // Triple-tap the title within 1.2s → emergency wipe (1:1 with iOS).
    LaunchedEffect(titleTaps) { if (titleTaps in 1..2) { kotlinx.coroutines.delay(1200); titleTaps = 0 } }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // bc-header: avatar (→settings) · sn-wordmark = brand chip + "sonar"
            // centered (triple-tap → wipe) · rings (→nearby). Design screens.jsx
            // HomeScreen header + theme.css .sn-wordmark/.sn-brandchip.lg.
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).clickable { state.push(Screen.Settings) },
                    contentAlignment = Alignment.Center
                ) { SonarAvatar(state.nick.ifBlank { "you" }, 32.dp) }
                Row(
                    Modifier.weight(1f).clickable(
                        indication = null, interactionSource = remember { MutableInteractionSource() }
                    ) { titleTaps++; if (titleTaps >= 3) { titleTaps = 0; wipeAsk = true } },
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // sn-brandchip.lg: 30×30, radius 9, hairline inset ring.
                    Image(
                        painterResource(Res.drawable.sonar_icon), contentDescription = null,
                        modifier = Modifier.size(30.dp).clip(RoundedCornerShape(9.dp))
                            .border(1.dp, s.hairline, RoundedCornerShape(9.dp))
                    )
                    Spacer(Modifier.width(9.dp))
                    // bc-htitle: 27px, weight 800, letter-spacing -0.02em.
                    Text(
                        "sonar", color = s.text, fontSize = 27.sp,
                        fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.54).sp
                    )
                }
                SNIconButton(SNIconName.Rings, size = 22.dp, weight = 2f, tint = s.text2) { state.push(Screen.Nearby) }
            }

            // status chip — centered pill
            Box(Modifier.fillMaxWidth().padding(bottom = 10.dp), contentAlignment = Alignment.Center) {
                // Online == relays attached, not "the local core booted": this pill
                // says "reaches anyone", which is only true over the internet.
                StatusChipPill(
                    online = state.relayOnline,
                    connecting = state.connecting || state.relayConnecting,
                    meshCount = meshCount,
                    syncing = state.syncing,
                ) { connSheet = true }
            }

            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 120.dp)) {
                item { SNSectionLabel("Around you") }
                // "Around you" collapses the geohash precision ladder (+ Mesh) into one
                // card with a tier picker (design: HereCard) instead of a flat list.
                item {
                    val hereItems = remember(state.locationChannels, meshCount, state.presenceByGeohash) {
                        buildList {
                            add(HereItem("mesh", "Bluetooth mesh", "Mesh", "Mesh", meshCount))
                            state.locationChannels.forEach { c ->
                                add(HereItem(c.geohash, c.name, c.level.label, geoShort(c.level), state.presence(c.geohash)))
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
                    itemsIndexed(saved, key = { _, gh -> "saved:" + gh }) { i, gh ->
                        val here = state.presence(gh)
                        val gc = state.locationChannels.firstOrNull { it.geohash == gh }
                        ConvRow(
                            avatar = { PlaceTile(52.dp) },
                            title = gc?.name ?: channelName(gh),
                            sub = if (here > 0) "$here here now" else "Saved channel",
                            divider = i != saved.lastIndex,
                            onLongClick = { state.toggleSaved(gh) }, // long-press to unpin
                        ) { state.openChannel(gh) }
                    }
                }
                item { SNSectionLabel("Messages") }
                if (!state.homeMessagesHydrated) {
                    item { LocalMessagesLoading() }
                } else {
                    val invites = state.groupInvites
                    val meshRows = state.meshDmRows
                    val chatRows = state.visibleChats
                    if (invites.isEmpty() && chatRows.isEmpty() && meshRows.isEmpty()) item { EmptyMessages() }
                    // ONE recency-ordered list across transports (Signal-style /
                    // iOS SonarAppStore.dmRows): mesh/folded + Marmot-only were two
                    // separately-sorted segments. Shared merge helper; invites stay
                    // pinned on top as actionable banners. Sort keys are O(1)
                    // cached (meshDmRows precomputed, marmotRow cached row VM —
                    // pending rows use creation time, not epoch zero).
                    val mergedRows = mergeHomeMessageRows(meshRows, chatRows) { chatId ->
                        state.marmotRow(chatId).tsSecs
                    }
                    // The hairline hides under the last row of the list (design
                    // .bc-list .bc-row:last-child::after { display: none }).
                    val lastRowKey = mergedRows.lastOrNull()?.listKey
                        ?: invites.lastOrNull()?.let { "invite:" + it.id }
                    items(invites, key = { "invite:" + it.id }) { invite ->
                        val title = invite.groupName.ifBlank { "Group chat" }
                        ConvRow(
                            avatar = { SonarAvatar(title, 52.dp, presence = false) },
                            title = title,
                            sub = "${invite.memberCount} members · invite",
                            lock = true,
                            divider = "invite:" + invite.id != lastRowKey,
                        ) { pendingInvite = invite }
                    }
                    items(mergedRows, key = { it.listKey }) { homeRow ->
                        when (homeRow) {
                            is HomeMessageRow.Mesh -> {
                                val mesh = homeRow.row
                                // BLE-mesh DM (incl. ones started by a peer messaging us)
                                // — over Bluetooth, so a cyan dot instead of the internet
                                // lock. A Sonar peer's White Noise leg is folded into
                                // this row (one row/person).
                                ConvRow(
                                    avatar = { SonarAvatar(mesh.name, 52.dp, presence = state.dmInRange(mesh.peerId)) },
                                    title = mesh.name, sub = mesh.preview, lock = false,
                                    time = rowTimeLabel(mesh.tsSecs),
                                    muted = state.isChatMuted("mesh:" + mesh.peerId),
                                    divider = homeRow.listKey != lastRowKey,
                                    onLongClick = { pendingRowActions = DeleteTarget(mesh.peerId, mesh.name, isMesh = true, isGroup = false) },
                                ) { state.openDm(mesh.peerId, mesh.name) }
                            }
                            is HomeMessageRow.Marmot -> {
                                val chat = homeRow.chat
                                // O(1) precomputed row model — no per-row disk read or
                                // O(chats) walk during composition (Signal cached row VM).
                                val row = state.marmotRow(chat.id)
                                ConvRow(
                                    avatar = { SonarAvatar(row.title, 52.dp, presence = false) },
                                    title = row.title,
                                    sub = row.sub,
                                    lock = true,
                                    time = if (row.tsSecs > 0L) rowTimeLabel(row.tsSecs) else "",
                                    verified = row.verified,
                                    unread = row.unread,
                                    muted = state.isChatMuted(chat.id),
                                    divider = homeRow.listKey != lastRowKey,
                                    onLongClick = if (row.pending) null else {
                                        { pendingRowActions = DeleteTarget(chat.id, row.title, isMesh = false, isGroup = row.multiMember) }
                                    },
                                ) { state.openChat(chat) }
                            }
                        }
                    }
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
                    .border(1.dp, s.hairline, RoundedCornerShape(999.dp))
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
    if (connSheet) ConnectivitySheet(online = state.relayOnline, meshCount = meshCount) { connSheet = false }
    if (wipeAsk) WipeConfirmSheet(onWipe = { wipeAsk = false; state.wipe() }, onClose = { wipeAsk = false })
    pendingInvite?.let { invite ->
        GroupInviteSheet(
            invite = invite,
            onAccept = { state.acceptGroupInvite(invite.id); pendingInvite = null },
            onDecline = { state.declineGroupInvite(invite.id); pendingInvite = null },
            onClose = { pendingInvite = null }
        )
    }
    pendingRowActions?.let { t ->
        ChatRowActionsSheet(
            name = t.name,
            isGroup = t.isGroup,
            muted = state.isChatMuted(muteChatIdFor(t)),
            onMute = { pendingRowActions = null; pendingMute = t },
            onDelete = { pendingRowActions = null; pendingDelete = t },
            onClose = { pendingRowActions = null }
        )
    }
    pendingMute?.let { t ->
        val muteId = muteChatIdFor(t)
        MuteSheet(
            name = t.name,
            muted = state.isChatMuted(muteId),
            onMute = { durationSecs -> state.muteChat(muteId, durationSecs); pendingMute = null },
            onUnmute = { state.unmuteChat(muteId); pendingMute = null },
            onClose = { pendingMute = null }
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

/** The id mute state is keyed on: the same conversation id notifications use
 *  (`mesh:<peerId>` for a mesh-folded row, the group id for a Marmot chat). */
internal fun muteChatIdFor(t: DeleteTarget): String =
    if (t.isMesh) "mesh:" + t.id else t.id

private fun channelName(geohash: String): String =
    if (geohash.equals("mesh", true)) "Bluetooth mesh" else "#$geohash"

/** bc-chip — centered status pill: dot + "<b>Online</b> · reaches anyone". */
@Composable
private fun StatusChipPill(online: Boolean, connecting: Boolean, meshCount: Int, syncing: Boolean = false, onClick: () -> Unit) {
    val s = sonar
    Row(
        Modifier.clip(RoundedCornerShape(999.dp)).background(s.surface)
            .border(1.dp, s.hairline, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SNDot(if (online) s.green else s.accent, 9.dp)
        Spacer(Modifier.width(8.dp))
        val label = if (online) "Online" else "Offline"
        val desc = when {
            online && syncing -> "catching up…"
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

/** bc-meshnote — the small informational note style from theme.css. */
@Composable
private fun LocationHint() {
    val s = sonar
    Text(
        "Turn on location to see public channels for your area (neighborhood → country).",
        color = s.text2, fontSize = 12.5.sp, lineHeight = 18.sp,
        modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 2.dp, bottom = 8.dp)
    )
}

/** Design short labels for the HereCard precision scale (data.js `here[].short`). */
private fun geoShort(level: GeoLevel): String = when (level) {
    GeoLevel.Building -> "Building"
    GeoLevel.Block -> "Block"
    GeoLevel.Neighborhood -> "Area"
    GeoLevel.City -> "City"
    GeoLevel.Province -> "Province"
    GeoLevel.Region -> "Region"
}

/** bc-row (components.jsx ConvRow / theme.css .bc-row) — avatar · (title
 *  [+verified]) / (lock? + sub) · right column with time + unread dot, and a
 *  hairline under the row inset to the text column (hidden on the last row). */
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
    muted: Boolean = false,
    divider: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val s = sonar
    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                .padding(horizontal = 16.dp, vertical = 11.dp), // --row-py: 11px
            verticalAlignment = Alignment.CenterVertically
        ) {
            avatar()
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                // bc-rowtitle: 16.5 / 650 / -0.01em, verified shield gap 5.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title, color = s.text, fontSize = 16.5.sp, fontWeight = FontWeight.SemiBold,
                        letterSpacing = (-0.17).sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (verified) { Spacer(Modifier.width(5.dp)); SNIcon(SNIconName.ShieldCheck, 14.dp, s.green, weight = 2.1f) }
                }
                Spacer(Modifier.height(2.dp))
                // bc-rowsub: 14 text2, single line, ellipsized (npubs must never wrap).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (lock) { SNIcon(SNIconName.Lock, 12.dp, s.text3, weight = 2.2f); Spacer(Modifier.width(4.dp)) }
                    Text(
                        sub, color = s.text2, fontSize = 14.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                }
            }
            // bc-rowend: time (12 text3) over the 11dp accent unread dot, gap 5.
            // A muted chat swaps the dot for a bell-off glyph (unread still
            // accrues internally, the dot is just suppressed).
            if (!time.isNullOrEmpty() || unread || muted) {
                Spacer(Modifier.width(8.dp))
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (!time.isNullOrEmpty()) Text(time, color = s.text3, fontSize = 12.sp)
                    if (muted) SNIcon(SNIconName.BellOff, 14.dp, s.text3, weight = 2f)
                    else if (unread) Box(Modifier.size(11.dp).clip(CircleShape).background(s.accent))
                }
            }
        }
        // bc-row::after — hairline from x=72 to the right edge.
        if (divider) Box(
            Modifier.align(Alignment.BottomStart).padding(start = 72.dp)
                .fillMaxWidth().height(1.dp).background(s.hairline)
        )
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

/** A chat the user long-pressed (phone) or right-clicked (desktop) to delete or leave. */
internal data class DeleteTarget(val id: String, val name: String, val isMesh: Boolean, val isGroup: Boolean)

@Composable
internal fun DeleteChatSheet(name: String, isGroup: Boolean, onDelete: () -> Unit, onClose: () -> Unit) {
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

/** Long-press actions for a home chat row: mute (new) + the pre-existing
 *  delete/leave entry point, so muting does not displace deleting. */
@Composable
internal fun ChatRowActionsSheet(
    name: String,
    isGroup: Boolean,
    muted: Boolean,
    onMute: () -> Unit,
    onDelete: () -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)) {
                Text(name, color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(8.dp))
                if (muted) {
                    ActionRow(SNIconName.BellOff, "Muted", "You won't get notifications for this conversation.", onMute)
                } else {
                    ActionRow(SNIconName.Bell, "Mute", "Silence notifications for this conversation", onMute)
                }
                ActionRow(
                    SNIconName.Trash,
                    if (isGroup) "Leave group" else "Delete chat",
                    if (isGroup) "Send a leave update and remove it from this device" else "Remove this chat from this device only",
                    onDelete,
                )
            }
        }
    }
}

/** Per-chat mute sheet (design MuteSheet): the duration ladder, or — when
 *  already muted — the bell-off state with Unmute/Cancel. */
@Composable
internal fun MuteSheet(
    name: String,
    muted: Boolean,
    onMute: (Long?) -> Unit,
    onUnmute: () -> Unit,
    onClose: () -> Unit,
) {
    val s = sonar
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(color = s.surface, shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)) {
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)) {
                if (muted) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SNIcon(SNIconName.BellOff, 20.dp, s.text2, weight = 2f)
                        Spacer(Modifier.width(9.dp))
                        Text("Muted", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "You won't get notifications for this conversation.",
                        color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                    )
                    Spacer(Modifier.height(16.dp))
                    SNPrimaryButton("Unmute") { onUnmute() }
                } else {
                    Text("Mute “$name”", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "New messages still arrive and count as unread — they just won't make a sound.",
                        color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    MUTE_DURATIONS.forEach { duration ->
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .clickable { onMute(duration.secs) }
                                .padding(horizontal = 6.dp, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            SNIcon(SNIconName.BellOff, 17.dp, s.text2, weight = 2f)
                            Spacer(Modifier.width(11.dp))
                            Text(duration.label, color = s.text, fontSize = 15.5.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
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
    var showRelayStatus by remember { mutableStateOf(false) }
    Box(
        Modifier.fillMaxSize().background(s.scrim).clickable(onClick = onClose),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(
            color = s.surface,
            shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp),
            modifier = Modifier.clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = {},
            ),
        ) {
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp)) {
                if (showRelayStatus) {
                    Text(
                        "Internet", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)
                    )
                    Spacer(Modifier.height(6.dp))
                    chat.bitchat.sonar.screens.SonarRelayStatusSheetContent(
                        online = online,
                        onClose = { showRelayStatus = false },
                    )
                } else {
                    Text(
                        "Connections", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp)
                    )
                    Spacer(Modifier.height(6.dp))
                    chat.bitchat.sonar.ui.SNSettingsRow(
                        icon = SNIconName.Globe, tone = if (online) SNTone.Cyan else SNTone.Default,
                        label = "Internet",
                        sub = if (online) "Connected · Nostr relays" else "Offline — messages wait or travel over Bluetooth",
                        value = if (online) "Online" else "Offline",
                        trail = SNTrail.Chevron,
                    ) { showRelayStatus = true }
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
    chat.bitchat.sonar.ui.SNEmptyState(
        icon = SNIconName.Lock,
        title = "No secure chats yet",
        desc = "Tap Search and paste someone’s npub to start an end-to-end encrypted chat over the internet."
    )
}

@Composable
private fun LocalMessagesLoading() {
    Text(
        "Loading chats from this device…",
        color = sonar.text3,
        fontSize = 14.sp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 18.dp),
    )
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

internal fun transcriptFeedKey(item: Any): String =
    if (item is CallRecord) "c:${item.id}" else "m:${(item as SonarMsg).id}"

/** Flattened LazyColumn rows so day chips / unread own stable keys (Signal).
 *  Internal (not private) so tests pin the real feed-flattening call site. */
internal sealed interface ChatFeedListItem {
    data class Day(val epochDay: Long, val label: String) : ChatFeedListItem
    data object Unread : ChatFeedListItem
    data class Row(val payload: Any, val feedIndex: Int) : ChatFeedListItem
}

internal fun chatFeedListKey(item: ChatFeedListItem): String = when (item) {
    is ChatFeedListItem.Day -> "day:${item.epochDay}"
    ChatFeedListItem.Unread -> "unread"
    is ChatFeedListItem.Row -> transcriptFeedKey(item.payload)
}

internal fun buildChatFeedListItems(
    feed: List<Any>,
    unreadAnchorIndex: Int,
): List<ChatFeedListItem> {
    val out = ArrayList<ChatFeedListItem>(feed.size + 8)
    feed.forEachIndexed { i, item ->
        val ts = if (item is CallRecord) item.tsSecs else (item as SonarMsg).tsSecs
        val prevAny = feed.getOrNull(i - 1)
        val prevTs = if (prevAny is CallRecord) prevAny.tsSecs else (prevAny as? SonarMsg)?.tsSecs
        val newDay = prevTs == null || localDayDelta(prevTs) != localDayDelta(ts)
        if (newDay) {
            val epochDay = localEpochDayToday() + localDayDelta(ts)
            out += ChatFeedListItem.Day(epochDay, dayLabel(ts))
        }
        if (i == unreadAnchorIndex) out += ChatFeedListItem.Unread
        out += ChatFeedListItem.Row(item, i)
    }
    return out
}

/** LazyColumn index for a feed row after Day/Unread items are interleaved. */
internal fun chatFeedListIndexForFeedRow(listItems: List<ChatFeedListItem>, feedIndex: Int): Int =
    listItems.indexOfFirst { it is ChatFeedListItem.Row && it.feedIndex == feedIndex }

internal fun chatFeedListIndexForKey(listItems: List<ChatFeedListItem>, key: String): Int =
    listItems.indexOfFirst { chatFeedListKey(it) == key }

internal fun chatFeedListTailIndex(listItems: List<ChatFeedListItem>): Int =
    listItems.indexOfLast { it is ChatFeedListItem.Row }.coerceAtLeast(0)

/** Prefer the Unread chip; else the unread message row; else the live-edge row. */
internal fun chatFeedListOpenIndex(
    listItems: List<ChatFeedListItem>,
    unreadFeedKey: String?,
    unreadFeedIndex: Int,
): Int {
    val unreadChip = listItems.indexOfFirst { it is ChatFeedListItem.Unread }
    if (unreadChip >= 0) return unreadChip
    if (unreadFeedKey != null) {
        val byKey = chatFeedListIndexForKey(listItems, unreadFeedKey)
        if (byKey >= 0) return byKey
    }
    if (unreadFeedIndex >= 0) {
        val byFeed = chatFeedListIndexForFeedRow(listItems, unreadFeedIndex)
        if (byFeed >= 0) return byFeed
    }
    return chatFeedListTailIndex(listItems)
}

/** Bounds an image bubble renders within (design: .bc-msg media). */
internal val MAX_MEDIA_BUBBLE_WIDTH = 240.dp
internal val MAX_MEDIA_BUBBLE_HEIGHT = 300.dp

/**
 * The box a decoded image bubble occupies: [intrinsic] scaled down to fit
 * [maxWidth]×[maxHeight] with the aspect ratio preserved, never upscaled.
 * This mirrors how `MediaImage` lays out (ContentScale.Fit under widthIn/heightIn
 * maxes) — reserving it up front keeps the transcript from reflowing when the
 * bytes arrive. Coercing each axis independently would NOT match: a 360×803dp
 * portrait fits to 135×300, not 240×300, and the extra width would show as
 * background bars beside the image.
 */
internal fun mediaBubbleFittedSize(intrinsic: DpSize, maxWidth: Dp, maxHeight: Dp): DpSize {
    if (intrinsic.width <= 0.dp || intrinsic.height <= 0.dp) return DpSize(0.dp, 0.dp)
    val scale = minOf(maxWidth / intrinsic.width, maxHeight / intrinsic.height, 1f)
    // Clamp: scaling by a Float can land a hair over the bound (800dp * 240/800
    // = 240.00002dp), and the reserved box must never exceed what Fit renders.
    return DpSize(
        (intrinsic.width * scale).coerceAtMost(maxWidth),
        (intrinsic.height * scale).coerceAtMost(maxHeight),
    )
}

/** One observed frame of transcript tail state for [TranscriptTailPinner].
 *  [viewportHeight] keeps successive IME-resize frames distinct so a
 *  `distinctUntilChanged` flow never swallows a shrink step. */
internal data class TranscriptTailFrame(
    val itemCount: Int,
    val viewportHeight: Int,
    val tailFullyVisible: Boolean,
    val scrolling: Boolean,
    val prepending: Boolean,
    /** Included so Spike A chrome/IME contentPadding changes are not swallowed. */
    val afterContentPadding: Int = 0,
)

internal enum class TranscriptTailPin { None, Snap, Animate }

/**
 * Production adapter over [TranscriptTailPinSession] / [TranscriptScrollPolicy].
 * Preserves Snap / Animate / None behavior for [TranscriptTailPinning]; policy
 * is the named API (Phase 1). Lockstep from [TranscriptScrollPolicy.decideInsetChange]
 * is applied only by [TranscriptPhase2ScrollEffects] when the Phase 2 flag is on.
 */
internal class TranscriptTailPinner {
    private val session = TranscriptTailPinSession()

    fun onFrame(frame: TranscriptTailFrame): TranscriptTailPin =
        transcriptDecisionToLegacyPin(
            session.onLayoutFrame(
                itemCount = frame.itemCount,
                tailFullyVisible = frame.tailFullyVisible,
                scrolling = frame.scrolling,
                prepending = frame.prepending,
            ),
        )
}

/** Wire [TranscriptTailPinner] to a transcript list: re-anchor the newest row
 *  whenever layout (IME shrink, media growth) — not the user's scroll and not
 *  a history prepend — steals a fully visible tail. */
@Composable
internal fun TranscriptTailPinning(
    listState: LazyListState,
    key: Any? = null,
    isPrepending: () -> Boolean = { false },
) {
    LaunchedEffect(key, listState) {
        val pinner = TranscriptTailPinner()
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()
            val pad = info.afterContentPadding
            TranscriptTailFrame(
                itemCount = info.totalItemsCount,
                viewportHeight = info.viewportSize.height,
                // Tail is "fully visible" only when its bottom clears the
                // owned bottom chrome (afterContentPadding), Signal-style.
                tailFullyVisible = last != null && last.index == info.totalItemsCount - 1 &&
                    last.offset + last.size <= info.viewportEndOffset - pad,
                scrolling = listState.isScrollInProgress,
                prepending = isPrepending(),
                afterContentPadding = pad,
            )
        }.distinctUntilChanged().collect { frame ->
            val pin = pinner.onFrame(frame)
            if (pin == TranscriptTailPin.None) return@collect
            // These frames are produced *during* layout, so scrolling straight
            // from here can re-enter measure ("performMeasureAndLayout called
            // during measure layout"). Land on the next frame boundary first,
            // the way the history-prepend path does. The IME emits a frame per
            // animation step, so the tail still tracks the keyboard.
            withFrameNanos { }
            listState.anchorTranscriptTail(
                frame.itemCount - 1,
                animate = pin == TranscriptTailPin.Animate,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatScreen(state: SonarAppState, screen: Screen.Chat) {
    val s = sonar
    val scope = rememberCoroutineScope()
    val draft = state.composerDraft(screen.id)
    var emojiTray by remember { mutableStateOf(false) }
    var stickerPacks by remember { mutableStateOf(state.cachedStickerPacks()) }
    var paySheet by remember { mutableStateOf(false) }
    var verifySheet by remember { mutableStateOf(false) }
    var addSheet by remember { mutableStateOf(false) }
    var addPeopleSheet by remember { mutableStateOf(false) }
    var removePeopleSheet by remember { mutableStateOf(false) }
    var mediaViewer by remember { mutableStateOf<SonarMedia?>(null) }
    // Album opened fullscreen: the message's media + the tapped start index.
    var mediaGallery by remember { mutableStateOf<Pair<List<SonarMedia>, Int>?>(null) }
    var previewPackCoordinate by remember { mutableStateOf<String?>(null) }
    val mediaActions = rememberMediaActions()
    val pickPhoto = rememberPhotoPicker { items, rejectedTooLarge ->
        if (rejectedTooLarge > 0) {
            state.toast = if (rejectedTooLarge == 1) {
                "Video is too large to send (max 25 MB)."
            } else {
                "$rejectedTooLarge videos are too large to send (max 25 MB)."
            }
        }
        if (items.isNotEmpty()) state.stageMediaPreviews(screen.id, items)
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
    // Transcript feed = chat messages (pay control lines collapsed) + mocked
    // call-log records, merged chronologically. Memoized on its inputs: the
    // filter runs PayLine.decode per row (and an FFI call for ☎CALL rows) and
    // the merge sorts — per-recomposition work the render path must not repeat
    // when unrelated state (media decode, presence) invalidates the screen.
    val calls = run { state.callVersion; state.callRecords(screen.id) }
    val feed: List<Any> = remember(state.messages, calls) {
        // Hide ⚡PAY control lines (Claim/Done) and ☎CALL signaling lines.
        // Core rows answer from their precomputed classification, which is also
        // what decides whether they counted as unread — so the divider can
        // never anchor on a row the transcript refuses to show. Only rows
        // without one (mesh, optimistic echoes) pay the string decode, and the
        // cheap ☎CALL prefix check keeps ordinary chat off the FFI path.
        val visible = state.messages.filter { msg ->
            isTranscriptVisibleRow(msg) { content ->
                content.trimStart().startsWith("☎CALL") &&
                    SonarCore.callParseControl(content) != null
            }
        }
        (visible + calls).sortedBy { if (it is CallRecord) it.tsSecs else (it as SonarMsg).tsSecs }
    }
    val newestFeedKey = feed.lastOrNull()?.let(::transcriptFeedKey)
    val currentFeed by rememberUpdatedState(feed)
    // Debug-only SONAR_BENCH marker (issue #305): time from the chat-open push
    // to the end of the transcript's first composed frame. Parsed by
    // scripts/bench/android-chat-open-bench.sh; see docs/PERFORMANCE.md.
    if (sonarBenchMarkersEnabled) {
        LaunchedEffect(screen.id) {
            val mark = state.chatOpenBenchMark ?: return@LaunchedEffect
            state.chatOpenBenchMark = null
            val rows = currentFeed.size
            withFrameNanos { }
            val ms = mark.elapsedNow().inWholeMicroseconds / 1000.0
            sonarLog(
                "SonarCore",
                "SONAR_BENCH chat_open_first_frame chat=${screen.id.take(12)} rows=$rows ms=$ms",
            )
        }
    }
    // Signal-style unread anchoring: opening a chat with unread messages lands
    // on the oldest unread row (with a divider) instead of force-pinning the
    // tail; only a fully-read chat opens at the bottom. The anchor freezes by
    // row ID at first computation so messages arriving while the chat is open
    // (already marked read in core) cannot drift the divider down. The frozen
    // ID persists in state so back-revealing this chat reuses it verbatim.
    var unreadAnchorId by remember(screen.id) {
        mutableStateOf(state.openChatUnreadAnchor[screen.id])
    }
    var userScrolled by remember(screen.id) { mutableStateOf(false) }
    val unreadAnchorIndex = unreadAnchorId
        ?.let { id -> feed.indexOfFirst { transcriptFeedKey(it) == id } }
        ?: -1
    val listItems = remember(feed, unreadAnchorIndex) {
        buildChatFeedListItems(feed, unreadAnchorIndex)
    }
    val currentListItems by rememberUpdatedState(listItems)
    // A MESH feed is only trustworthy once the open's async local hydrate has
    // published: it paints the BLE window first and merges the White Noise leg
    // a beat later, which can add OLDER rows — shifting every index and moving
    // the tail. A timestamp comparison cannot detect this (a nearby peer's BLE
    // rows are newer than anything in the White-Noise-only index), so ask the
    // store whether hydration actually finished. A pure Marmot open needs no
    // gate: its first paint is the complete snapshot, and waiting for the
    // async page would turn the instant unread anchor into a visible
    // tail-then-divider snap.
    fun feedCaughtUp(rows: List<Any>): Boolean =
        rows.isNotEmpty() &&
            (!screen.id.startsWith("mesh:") || state.isTranscriptHydrated(screen.id))
    // Open pinned at the first unread row, or at the newest row for a read
    // chat (Signal parity): start the list state there so the first frame
    // never shows the wrong page and then visibly jumps.
    val listState = remember(screen.id) {
        val feedAnchor = unreadAnchorId
            ?.let { id -> feed.indexOfFirst { transcriptFeedKey(it) == id } }
            ?.takeIf { it >= 0 }
            ?: firstUnreadTranscriptIndex(feed, state.openChatUnread[screen.id] ?: 0L)
                .takeIf { feedCaughtUp(feed) }
            ?: -1
        val items = buildChatFeedListItems(feed, feedAnchor)
        val start = if (feedAnchor >= 0) {
            chatFeedListOpenIndex(items, unreadAnchorId, feedAnchor)
        } else {
            chatFeedListTailIndex(items)
        }
        LazyListState(firstVisibleItemIndex = start.coerceAtLeast(0))
    }
    // Phase 1+: name the open intent via policy (divider vs live edge).
    // Production (flag off) still uses historical unread-count gates below.
    // Phase 2 flagged host drives open from [TranscriptOpenAction] only.
    val transcriptOpenAction = TranscriptScrollPolicy.resolveOpenAction(
        unreadAnchorId = unreadAnchorId,
        unreadCountAtOpen = state.openChatUnread[screen.id],
        jumpMessageId = state.openChatJumpMessageId[screen.id],
    )
    val phase2Host = SonarTranscriptPolicyHost.isEnabled()
    var isNearBottom by remember(screen.id) { mutableStateOf(true) }
    var didInitialScroll by remember(screen.id) { mutableStateOf(false) }
    var didLeaveTail by remember(screen.id) { mutableStateOf(false) }
    var isPrepending by remember(screen.id) { mutableStateOf(false) }
    // Fully-read / provisional-live-edge open: keep re-anchoring across
    // hydration index shifts until the newest row is actually on screen.
    // Without this, agent DMs land mid-history after older rows prepend.
    var needsLiveEdgeOpen by remember(screen.id) {
        mutableStateOf(transcriptOpenAction == TranscriptOpenAction.LiveEdge)
    }

    // The divider must not resurrect or re-scroll once the reader takes over.
    LaunchedEffect(screen.id, listState) {
        listState.interactionSource.interactions.first { it is DragInteraction.Start }
        userScrolled = true
    }
    // Freeze the unread anchor on the first CAUGHT-UP feed that can resolve
    // it, and re-resolve only if its row vanishes (a snapshot row replaced by
    // the canonical DB page) before the user scrolls.
    LaunchedEffect(screen.id, feed) {
        val unreadAtOpen = state.openChatUnread[screen.id] ?: 0L
        if (unreadAtOpen <= 0L || feed.isEmpty()) return@LaunchedEffect
        val current = unreadAnchorId
        if (current != null && feed.any { transcriptFeedKey(it) == current }) return@LaunchedEffect
        if (current != null && userScrolled) return@LaunchedEffect
        if (!feedCaughtUp(feed)) return@LaunchedEffect
        val anchor = firstUnreadTranscriptIndex(feed, unreadAtOpen)
        if (anchor < 0) {
            // The caught-up feed cannot place a divider (e.g. every unread
            // event is a filtered ☎CALL/⚡PAY control line). Retire the pending
            // unread state, or unreadAnchorPending() would suppress tail
            // following for the rest of this open.
            state.retireOpenChatUnread(screen.id)
            return@LaunchedEffect
        }
        val anchorKey = transcriptFeedKey(feed[anchor])
        unreadAnchorId = anchorKey
        state.openChatUnreadAnchor = state.openChatUnreadAnchor + (screen.id to anchorKey)
        if (!userScrolled) {
            withFrameNanos { }
            val items = buildChatFeedListItems(feed, anchor)
            listState.scrollToItem(chatFeedListOpenIndex(items, anchorKey, anchor))
        }
    }

    // Observe the position independently of transcript publication. A newly
    // appended row follows only when the user was already reading the tail.
    LaunchedEffect(screen.id, listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            info.totalItemsCount == 0 || lastVisible >= info.totalItemsCount - 2
        }.distinctUntilChanged().collect {
            isNearBottom = it
            if (didInitialScroll && !it) didLeaveTail = true
        }
    }
    // True while an unread open is still waiting for its divider row: the
    // pending anchor owns the next programmatic scroll, so tail-following must
    // not race it to the bottom when the White Noise leg merges in.
    fun unreadAnchorPending(): Boolean {
        val count = state.openChatUnread[screen.id]
        if (userScrolled) return false
        // Only settled unread (>0) without a divider owns the next scroll.
        // Unset capture is provisional live edge (keep pinning).
        return count != null && count > 0L && unreadAnchorId == null
    }
    // Keyed on the feed SIZE as well as its newest row: hydration merges the
    // White Noise leg in, which can insert only OLDER rows. That leaves the
    // newest key untouched while shifting every index — the tail moves and the
    // viewport is left showing older content until something re-anchors it.
    LaunchedEffect(screen.id, newestFeedKey, feed.size, state.openChatUnread[screen.id]) {
        if (feed.isEmpty()) return@LaunchedEffect
        val hydrated = feedCaughtUp(feed)
        // Settled unread takes over from provisional live edge. Do NOT force
        // needsLiveEdgeOpen=true on every feed change — that re-snapped the
        // whole list after identical hydration and looked like a rebuild.
        if (transcriptOpenAction == TranscriptOpenAction.UnreadDivider) {
            needsLiveEdgeOpen = false
        }
        if (!didInitialScroll) {
            val tailIndex = chatFeedListTailIndex(listItems)
            if (phase2Host) {
                // Flagged host: open from TranscriptOpenAction only (no unread-count gate).
                when (transcriptOpenAction) {
                    TranscriptOpenAction.LiveEdge -> {
                        listState.anchorTranscriptTail(tailIndex, animate = false)
                        needsLiveEdgeOpen = true
                        didInitialScroll = true
                    }
                    TranscriptOpenAction.UnreadDivider -> {
                        val feedIdx = transcriptPhase2OpenIndex(
                            openAction = transcriptOpenAction,
                            unreadAnchorIndex = unreadAnchorIndex,
                            itemCount = feed.size,
                        )
                        // Pending unread: do not mark initial scroll or pin tail;
                        // freeze effect resolves the divider, then we retry.
                        if (feedIdx >= 0) {
                            listState.scrollToItem(
                                chatFeedListOpenIndex(listItems, unreadAnchorId, feedIdx)
                            )
                            needsLiveEdgeOpen = false
                            didInitialScroll = true
                        }
                    }
                    is TranscriptOpenAction.Jump -> {
                        val jumpIdx = feed.indexOfFirst {
                            transcriptFeedKey(it) == transcriptOpenAction.id
                        }
                        val feedIdx = transcriptPhase2OpenIndex(
                            openAction = transcriptOpenAction,
                            unreadAnchorIndex = unreadAnchorIndex,
                            itemCount = feed.size,
                            jumpIndex = jumpIdx,
                        )
                        val idx = if (jumpIdx >= 0) {
                            chatFeedListIndexForFeedRow(listItems, jumpIdx).coerceAtLeast(0)
                        } else {
                            // Soft-fail: id not in newest local page → unread/live-edge.
                            chatFeedListOpenIndex(listItems, unreadAnchorId, feedIdx)
                        }
                        listState.scrollToItem(idx)
                        needsLiveEdgeOpen = false
                        didInitialScroll = true
                        state.clearOpenChatJump(screen.id)
                    }
                }
            } else {
                // Production: unread-anchored open keeps its position; the freeze
                // effect above owns that scroll. Fully-read / provisional live
                // edge pins the tail once, then recovers only when layout proof fails.
                when (transcriptOpenAction) {
                    TranscriptOpenAction.LiveEdge -> {
                        listState.anchorTranscriptTail(tailIndex, animate = false)
                        needsLiveEdgeOpen = true
                        didInitialScroll = true
                    }
                    TranscriptOpenAction.UnreadDivider -> {
                        needsLiveEdgeOpen = false
                        didInitialScroll = true
                    }
                    is TranscriptOpenAction.Jump -> {
                        needsLiveEdgeOpen = false
                        didInitialScroll = true
                        state.clearOpenChatJump(screen.id)
                    }
                }
            }
        } else if (!isPrepending && !unreadAnchorPending() && !userScrolled &&
            // Follow the tail when the reader is already there, while hydration
            // can still shift indices, or while a fully-read open has not yet
            // landed the newest row on screen (agent DM mid-history bug).
            (isNearBottom || !hydrated || needsLiveEdgeOpen)
        ) {
            val lastIndex = chatFeedListTailIndex(listItems)
            val atLiveEdge = listState.isTranscriptTailAtLiveEdge(lastIndex)
            if (needsLiveEdgeOpen) {
                // Open recovery: correct only when layout is wrong; never animate.
                // Phase 2 host also owns append/IME pin via TranscriptPhase2ScrollEffects;
                // this branch must still recover a mistargeted fully-read open.
                if (!atLiveEdge) {
                    listState.anchorTranscriptTail(lastIndex, animate = false)
                }
                if (hydrated && listState.isTranscriptTailAtLiveEdge(lastIndex)) {
                    needsLiveEdgeOpen = false
                }
            } else if (!phase2Host) {
                // Legacy shell only: Phase 2's TranscriptPhase2ScrollEffects owns
                // post-settle append pin / lockstep — double-anchoring here races it.
                listState.anchorTranscriptTail(lastIndex, animate = hydrated)
            }
        }
    }

    // Load one local cursor page when the reader reaches the top. Capture a
    // stable visible message and pixel offset, then restore it after prepend so
    // the existing content does not jump under the reader's finger.
    LaunchedEffect(screen.id, listState) {
        snapshotFlow {
            didInitialScroll && listState.layoutInfo.totalItemsCount > 0 &&
                listState.firstVisibleItemIndex <= 2
        }.distinctUntilChanged().filter { it }.collect {
            val visibleInfo = listState.layoutInfo.visibleItemsInfo
            val anchor = visibleInfo.firstOrNull { it.key.toString().startsWith("m:") }
                ?: visibleInfo.firstOrNull()
                ?: return@collect
            val continuity = TranscriptScrollPolicy.captureContinuityToken(
                anchorId = anchor.key.toString(),
                pixelOffset = anchor.offset,
            )
            isPrepending = true
            if (!state.loadOlderMessages(screen.id)) {
                isPrepending = false
                return@collect
            }
            withFrameNanos { }
            val newIndex = chatFeedListIndexForKey(currentListItems, continuity.anchorId)
            val offset = continuity.pixelOffset ?: 0
            if (newIndex >= 0) {
                listState.scrollToItem(newIndex, scrollOffset = -offset)
            }
            isPrepending = false
        }
    }

    // A 500-row window can move away from the tail. Reaching its bottom after
    // the reader has left the tail resets to a fresh bounded newest page.
    LaunchedEffect(screen.id, listState) {
        snapshotFlow {
            didInitialScroll && didLeaveTail && state.canLoadNewestMessages(screen.id) &&
                listState.layoutInfo.totalItemsCount > 0 &&
                listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ==
                    listState.layoutInfo.totalItemsCount - 1
        }.distinctUntilChanged().filter { it }.collect {
            isPrepending = true
            if (state.loadNewestMessages(screen.id)) {
                withFrameNanos { }
                if (currentListItems.isNotEmpty()) {
                    listState.anchorTranscriptTail(
                        chatFeedListTailIndex(currentListItems),
                        animate = false,
                    )
                }
                didLeaveTail = false
            }
            isPrepending = false
        }
    }

    // Bottom-anchor the tail (Signal parity): the IME opening shrinks the
    // transcript viewport and decoded media grows tail rows after first paint;
    // both would otherwise hide the newest messages behind the keyboard or
    // below the fold. Re-anchor whenever layout — not the user — steals the tail.
    // A pending unread anchor also suppresses the layout pinner: the White
    // Noise merge growing the item count must jump to the divider, not the tail.
    // Phase 2 host owns scroll effects (full-height + owned bottom pad + Lockstep).
    // Production TranscriptTailPinning maps Lockstep→None. Spike A is not a ChatScreen swap.
    if (!phase2Host) {
        TranscriptTailPinning(
            listState,
            key = screen.id,
            isPrepending = { isPrepending || unreadAnchorPending() },
        )
    }
    val currentChat = state.chats.firstOrNull { it.id == screen.id }
    val isGroup = state.isMultiMemberChat(screen.id)
    val canManageGroup = state.canManageGroup(screen.id)
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
    val attachmentLimit = if (sendOverMesh) {
        MAX_MESH_ATTACHMENT_BYTES
    } else {
        MAX_INTERNET_ATTACHMENT_BYTES
    }
    val pickFile = rememberFilePicker(attachmentLimit) { files ->
        state.sendDroppedAttachments(screen.id, files)
    }

    @Composable
    fun ChatFeedList(listModifier: Modifier, bottomPad: Dp) {
        // BoxWithConstraints (once, not per row) gives the .bc-msg max-width: 78%.
        BoxWithConstraints(listModifier) {
            val bubbleMax = maxWidth * 0.78f
            LazyColumn(
                Modifier.fillMaxSize(),
                state = listState,
                contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 6.dp, bottom = bottomPad)
            ) {
                    // Signal-style sticky day markers: each Day item is a
                    // stickyHeader so the current day pins while its rows
                    // scroll. Emission order matches `listItems` exactly —
                    // every entry still occupies one lazy index, so the
                    // continuity/open index math is unchanged.
                    listItems.forEach { listItem ->
                        when (listItem) {
                            is ChatFeedListItem.Day -> stickyHeader(
                                key = chatFeedListKey(listItem)
                            ) { StickyDayHeader(listItem.label) }
                            ChatFeedListItem.Unread -> item(
                                key = chatFeedListKey(listItem)
                            ) { UnreadDivider() }
                            is ChatFeedListItem.Row -> item(
                                key = chatFeedListKey(listItem)
                            ) {
                                val item = listItem.payload
                                val feedIndex = listItem.feedIndex
                                val prevAny = feed.getOrNull(feedIndex - 1)
                                val ts = if (item is CallRecord) item.tsSecs else (item as SonarMsg).tsSecs
                                val prevTs = if (prevAny is CallRecord) prevAny.tsSecs
                                    else (prevAny as? SonarMsg)?.tsSecs
                                val newDay = prevTs == null || localDayDelta(prevTs) != localDayDelta(ts)
                                if (item is CallRecord) {
                                    CallLogRow(item)
                                } else {
                                    val m = item as SonarMsg
                                    val msgMesh = isMeshRoute && !m.viaInternet
                                    // Contiguity from adjacent feed message rows only.
                                    val prevMsg = prevAny as? SonarMsg
                                    val cont = !newDay && prevMsg != null && prevMsg.mine == m.mine &&
                                        prevMsg.senderNpub == m.senderNpub &&
                                        PayLine.decode(prevMsg.content) !is PayLine.Pay &&
                                        !TrillLine.isTrillLine(prevMsg.content)
                                    val pay = PayLine.decode(m.content) as? PayLine.Pay
                                    val failedSend = sonarCanRetryMessage(m)
                                    if (TrillLine.isTrillLine(m.content)) {
                                        // Centered nudge pill — never the raw ⚡TRILL line.
                                        TrillLogRow(
                                            mine = m.mine,
                                            who = if (m.mine) null
                                            else state.groupAuthorName(m, isGroup) ?: peerName,
                                        )
                                    } else if (pay != null) {
                                        val status = run { state.payVersion; state.payStatus(pay.uuid) }
                                        PayBubble(m, pay, status, peerName, mesh = msgMesh, fiatOf = { state.fiatOrNull(it) })
                                    } else if (m.media.isNotEmpty()) {
                                        MediaBubble(
                                            m,
                                            state,
                                            screen.id,
                                            mesh = msgMesh,
                                            author = if (cont) null else state.groupAuthorName(m, isGroup),
                                            cont = cont,
                                            showState = m.mine && (feedIndex == feed.lastIndex || failedSend),
                                            onRetry = if (failedSend) { { state.retryMessage(screen.id, m) } } else null,
                                            maxBubbleWidth = bubbleMax,
                                            onOpen = { mediaViewer = it },
                                            onOpenAlbum = { items, idx -> mediaGallery = items to idx }
                                        )
                                    } else if (m.stickerRef != null) {
                                        StickerBubble(
                                            m,
                                            state = state,
                                            mesh = msgMesh,
                                            author = if (cont) null else state.groupAuthorName(m, isGroup),
                                            showState = m.mine && (feedIndex == feed.lastIndex || failedSend),
                                            onRetry = if (failedSend) { { state.retryMessage(screen.id, m) } } else null,
                                            onTap = { coord -> previewPackCoordinate = coord },
                                        )
                                    } else MessageBubble(
                                        m,
                                        msgMesh,
                                        author = if (cont) null else state.groupAuthorName(m, isGroup),
                                        cont = cont,
                                        showState = m.mine && (feedIndex == feed.lastIndex || failedSend),
                                        onRetry = if (failedSend) { { state.retryMessage(screen.id, m) } } else null,
                                        maxBubbleWidth = bubbleMax,
                                    )
                                }
                            }
                        }
                    }
                }
        }
    }

    @Composable
    fun ChatBottomChrome() {
        val keyboardController = LocalSoftwareKeyboardController.current
        val focusManager = LocalFocusManager.current
        // Phase-2 hosts bottomContent in a Box (overlay sibling). Multiple root
        // children would stack at top-start and overlap — tray tabs under the
        // composer, "Loading stickers…" frozen in the crushed remainder, IME
        // still visible. One Column root keeps tray + composer vertically stacked
        // in both the legacy Column shell and the Phase-2 Box host.
        Column(Modifier.fillMaxWidth()) {
            if (draft.startsWith("/")) SlashHints(draft) { state.setComposerDraft(screen.id, it) }
            if (emojiTray && !recording) chat.bitchat.sonar.screens.SonarEmojiPicker(
                onEmoji = { state.setComposerDraft(screen.id, draft + it) },
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
                fetchInstalledPacks = { state.fetchInstalledPacks() },
                initialStickerPacks = stickerPacks,
                onStickerPacksLoaded = { stickerPacks = it },
                onClose = { emojiTray = false }
            )
            // ONE composer row in BOTH states. Only the left (plus↔trash) and middle
            // (text field↔recording pill) swap; the mic Box on the right MUST stay
            // mounted while recording, or Compose cancels its hold-to-record gesture
            // (the @RestrictsSuspension pointer coroutine dies with its layout node)
            // and the finger-release is never seen — the note never sends.
            // bc-composer (theme.css): plus 36 · field min-h 36/r 19/p 7×14 · send 34.
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 10.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                if (recording) {
                    // voice-trash: slide-left-far OR tap the trash to discard.
                    Box(
                        Modifier.size(36.dp).clip(CircleShape).background(s.surface2)
                            .clickable { recorder.cancel(); recording = false; recDragX = 0f },
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Trash, 19.dp, s.danger, weight = 2f) }
                    Spacer(Modifier.width(8.dp))
                    RecordingPill(recElapsed, recLevel, recDragX, Modifier.weight(1f))
                } else {
                    // bc-plusbtn: "Add to your message" sheet (bitcoin / location / verify / reactions)
                    Box(
                        Modifier.size(36.dp).clip(CircleShape).background(s.surface2).clickable { addSheet = true },
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Plus, 19.dp, s.text2, weight = 2.1f) }
                    Spacer(Modifier.width(8.dp))
                    Box(
                        Modifier.weight(1f).clip(RoundedCornerShape(19.dp)).background(s.surface2)
                            .heightIn(min = 36.dp)
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                        contentAlignment = Alignment.CenterStart
                    ) {
                        if (draft.isEmpty()) Text(
                            "Message $peerName" + (if (sendOverMesh) "" else " · via internet"),
                            color = s.text3, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                        MessageComposerTextField(
                            value = draft, onValueChange = { state.setComposerDraft(screen.id, it) },
                            textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                            cursorBrush = SolidColor(s.accent),
                            modifier = Modifier
                                .fillMaxWidth()
                                .onFocusChanged { focusState ->
                                    if (
                                        shouldCloseEmojiTrayOnComposerFocus(
                                            composerFocused = focusState.isFocused,
                                            trayOpen = emojiTray,
                                            // Desktop Enter-sends ⇒ hardware keyboard; do not
                                            // auto-close the tray when the field is focused.
                                            usesSoftKeyboard = !messageComposerEnterSends,
                                        )
                                    ) {
                                        emojiTray = false
                                    }
                                },
                            onSend = {
                                if (draft.isBlank()) return@MessageComposerTextField
                                val d = draft
                                state.setComposerDraft(screen.id, "")
                                emojiTray = false
                                if (!state.handleCommand(d, peerName, channelGeohash = null, chatId = screen.id)) {
                                    state.send(screen.id, d)
                                }
                            },
                        )
                    }
                }
                if (!recording) {
                    Spacer(Modifier.width(8.dp))
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).background(if (emojiTray) s.accentSoft else s.surface2)
                            .clickable {
                                val opening = !emojiTray
                                val usesSoftKeyboard = !messageComposerEnterSends
                                if (
                                    shouldDismissKeyboardWhenOpeningEmojiTray(
                                        openingTray = opening,
                                        usesSoftKeyboard = usesSoftKeyboard,
                                    )
                                ) {
                                    focusManager.clearFocus(force = true)
                                    keyboardController?.hide()
                                }
                                if (opening) {
                                    stickerPacks = state.cachedStickerPacks()
                                }
                                emojiTray = opening
                            },
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Smile, 18.dp, if (emojiTray) s.accent else s.text2, weight = 2f) }
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
                        Modifier.size(34.dp).clip(CircleShape).background(micBg)
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
                    ) { SNIcon(SNIconName.Mic, 18.dp, micFg, weight = 2f) }
                } else {
                    val sendEnabled = draft.isNotBlank()
                    val sendBg = if (!sendEnabled) s.surface2 else if (sendOverMesh) s.accentFill else s.netFill
                    val sendFg = if (!sendEnabled) s.text3 else if (sendOverMesh) s.onAccent else s.onNet
                    // bc-sendbtn: 34dp circle, send glyph 17/w2.3, cyan over mesh /
                    // indigo over internet when armed.
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).background(sendBg)
                            .clickable(enabled = sendEnabled) {
                                val d = draft
                                state.setComposerDraft(screen.id, "")
                                emojiTray = false
                                if (!state.handleCommand(d, peerName, channelGeohash = null, chatId = screen.id)) {
                                    state.send(screen.id, d)
                                }
                            },
                        contentAlignment = Alignment.Center
                    ) { SNIcon(SNIconName.Send, 17.dp, sendFg, weight = 2.3f) }
                }
            }
        } // Column — single root for Phase-2 Box host
    }

    Box(
        Modifier.fillMaxSize().fileDropTarget(
            enabled = state.canPrepareMedia(screen.id),
            maxTotalBytes = attachmentLimit,
        ) { dropped ->
            if ((state.screen as? Screen.Chat)?.id != screen.id) return@fileDropTarget
            state.sendDroppedAttachments(screen.id, dropped)
        }
    ) {
    Column(Modifier.fillMaxSize()) {
        // bc-header.hl (DM, screens.jsx NavHeader): back · avatar 36 (+presence) ·
        // name 17/700 + shield · lock + "Nearby · Bluetooth"/"Via internet" ·
        // phone/videocam trailing, with a bottom hairline.
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                SNIconButton(SNIconName.Back, onClick = { state.back() })
                Row(
                    Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).clickable(enabled = canManageGroup || !isGroup) {
                        if (canManageGroup) state.push(Screen.GroupInfo(screen.id))
                        else state.push(Screen.ContactProfile(screen.id, peerName))
                    },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    SonarAvatar(peerName, 36.dp, presence = if (inRange) true else null)
                    Column(Modifier.weight(1f)) {
                        // bc-hname: 17 / 700 / -0.01em.
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                peerName, color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                                letterSpacing = (-0.17).sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f, fill = false)
                            )
                            if (verified) { Spacer(Modifier.width(5.dp)); SNIcon(SNIconName.ShieldCheck, 15.dp, s.green, weight = 2.1f) }
                        }
                        Spacer(Modifier.height(1.dp))
                        // bc-hsub: 12 text2 — 'Verified · ' + Nearby·Bluetooth /
                        // Offline — will send later / Via internet (screens.jsx DMScreen).
                        val subTransport = when {
                            sendOverMesh -> "Nearby · Bluetooth"
                            isMeshRoute && !inRange && !hasAccount -> "Offline — will send later"
                            else -> "Via internet"
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            SNIcon(SNIconName.Lock, 11.dp, s.text2, weight = 2.4f)
                            Spacer(Modifier.width(5.dp))
                            Text(
                                (if (verified) "Verified · " else "") + subTransport,
                                color = s.text2, fontSize = 12.sp,
                                maxLines = 1, overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
                // Audio + video call buttons (iOS SonarDMScreen parity). Calls are
                // Sonar-only and use live BLE when available, otherwise White
                // Noise signaling for that peer.
                if (state.canCall(screen.id)) {
                    SNIconButton(SNIconName.Phone, size = 20.dp, weight = 2f, tint = s.text2) {
                        state.placeCall(screen.id, peerName, video = false)
                    }
                    SNIconButton(SNIconName.Videocam, size = 21.dp, weight = 2f, tint = s.text2) {
                        state.placeCall(screen.id, peerName, video = true)
                    }
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(s.hairline))
        }

        if (isMeshRoute && !inRange) {
            if (hasAccount) {
                // Design DMScreen out-of-range banner (verbatim copy) + Verify action.
                chat.bitchat.sonar.ui.SNBanner(
                    icon = SNIconName.Globe, tone = chat.bitchat.sonar.ui.SNBannerTone.Net,
                    bold = "Out of Bluetooth range", rest = " — encrypted over the internet instead",
                    actionLabel = "Verify", onAction = { verifySheet = true }
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
            ChatBottomChrome()
        } else if (phase2Host) {
            // Phase 2: owned pad + IME overlay; Pin+Lockstep; top-align (not reverseLayout).
            TranscriptPhase2HostScaffold(
                listState = listState,
                listKey = screen.id,
                isPrepending = { isPrepending || unreadAnchorPending() },
                suppressPin = { unreadAnchorPending() },
                modifier = Modifier.weight(1f).fillMaxWidth(),
                listContent = { bottomInset ->
                    ChatFeedList(Modifier.fillMaxSize(), bottomInset)
                },
                bottomContent = { ChatBottomChrome() },
            )
        } else {
            ChatFeedList(Modifier.weight(1f).fillMaxWidth(), 10.dp)
            ChatBottomChrome()
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
    mediaGallery?.let { (items, start) ->
        MediaGalleryViewer(
            items = items,
            startIndex = start,
            state = state,
            chatId = screen.id,
            actions = mediaActions,
            onClose = { mediaGallery = null },
            modifier = Modifier.matchParentSize()
        )
    }
    val chatPreviews = state.pendingMediaPreviews.filter { it.chatId == screen.id }
    if (chatPreviews.isNotEmpty()) {
        val previewKey = chatPreviews.joinToString("|") { it.tempPath }
        val loaded by androidx.compose.runtime.produceState<List<SendPreviewItem>?>(null, previewKey) {
            value = withContext(Dispatchers.IO) {
                chatPreviews.mapNotNull { p ->
                    if (isVideoMime(p.mime)) {
                        // Poster frame only — never buffer the full video for preview.
                        SendPreviewItem(
                            bytes = null,
                            isGif = false,
                            isVideo = true,
                            poster = decodeVideoPosterFrame(p.tempPath),
                            filename = p.filename,
                        )
                    } else {
                        readTempMediaFile(p.tempPath)?.let {
                            SendPreviewItem(it, p.mime == "image/gif", false, null, p.filename)
                        }
                    }
                }
            }
        }
        val items = loaded
        if (!items.isNullOrEmpty()) {
            MediaSendPreview(
                items = items,
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
        canSendFile = state.canPrepareMedia(screen.id),
        canSendPayment = state.hasDirectPaymentRoute(screen.id),
        canVerify = !state.isMultiMemberChat(screen.id),
        canShareLocation = !state.isMultiMemberChat(screen.id),
        canManageGroup = canManageGroup,
        isGroup = isGroup,
        nudgeEnabled = state.canSendTrill(screen.id),
        onPhoto = { addSheet = false; pickPhoto() },
        onFile = { addSheet = false; pickFile() },
        onNudge = { addSheet = false; state.sendTrill(screen.id) },
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
    canSendFile: Boolean = false,
    canSendPayment: Boolean = true,
    canVerify: Boolean = true,
    canShareLocation: Boolean = true,
    canManageGroup: Boolean = false,
    isGroup: Boolean = false,
    nudgeEnabled: Boolean = true,
    onPhoto: () -> Unit = {},
    onFile: () -> Unit = {},
    onNudge: () -> Unit = {},
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
                    ActionRow(SNIconName.Lock, "Send photo or video", "Encrypted end-to-end over White Noise", onPhoto)
                }
                if (canSendFile) {
                    ActionRow(SNIconName.Data, "Send file", "PDFs, documents, and other files", onFile)
                }
                if (canSendPayment) ActionRow(SNIconName.Coin, "Send bitcoin", "Instant over Lightning", onBitcoin)
                // MSN-style trill: disabled (not hidden) during the 8 s
                // per-chat sender cooldown. Geohash channels never show this
                // sheet, so the nudge stays DM/group-only by construction.
                Box(Modifier.alpha(if (nudgeEnabled) 1f else 0.45f)) {
                    ActionRow(
                        SNIconName.Bell,
                        "Nudge",
                        if (isGroup) "Buzz everyone to get their attention"
                        else "Buzz $peerName’s screen to get their attention",
                        if (nudgeEnabled) onNudge else ({}),
                    )
                }
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
    val draftKey = composerDraftKeyForGeoDm(screen.geohash, screen.peerHex)
    val draft = state.composerDraft(draftKey)
    val blocked = state.isGeoDmBlocked(screen.peerHex)
    // Open pinned at the newest row and snap (not animate) the first local fill,
    // exactly like ChatScreen: the transcript must not open at old history and
    // visibly scroll down to the tail.
    val listState = remember(screen.peerHex) {
        LazyListState(firstVisibleItemIndex = (state.messages.size - 1).coerceAtLeast(0))
    }
    var didInitialGeoScroll by remember(screen.peerHex) { mutableStateOf(false) }
    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) {
            listState.anchorTranscriptTail(state.messages.size - 1, animate = didInitialGeoScroll)
            didInitialGeoScroll = true
        }
    }
    // Same tail pinning as the main transcript: the IME opening must not hide
    // the newest rows behind the keyboard.
    TranscriptTailPinning(listState, key = screen.peerHex)
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, onClick = { state.back() })
            SonarAvatar(screen.name, 36.dp, presence = false)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    screen.name, color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = (-0.17).sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(1.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SNIcon(SNIconName.Lock, 11.dp, s.text2, weight = 2.4f)
                    Spacer(Modifier.width(5.dp))
                    Text(if (blocked) "Blocked" else "Sonar · end-to-end encrypted", color = s.text2, fontSize = 12.sp)
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
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 10.dp),
            verticalAlignment = Alignment.Bottom
        ) {
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(19.dp)).background(s.surface2)
                    .heightIn(min = 36.dp).padding(horizontal = 14.dp, vertical = 7.dp),
                contentAlignment = Alignment.CenterStart
            ) {
                if (draft.isEmpty()) Text("Message", color = s.text3, fontSize = 16.sp)
                MessageComposerTextField(
                    value = draft, onValueChange = { state.setComposerDraft(draftKey, it) },
                    textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                    cursorBrush = SolidColor(s.accent),
                    modifier = Modifier.fillMaxWidth(),
                    onSend = {
                        if (draft.isBlank()) return@MessageComposerTextField
                        val d = draft
                        state.setComposerDraft(draftKey, "")
                        state.sendGeoDmMsg(screen.geohash, screen.peerHex, d)
                    },
                )
            }
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(if (draft.isBlank()) s.surface2 else s.netFill)
                    .clickable(enabled = draft.isNotBlank()) {
                        val d = draft
                        state.setComposerDraft(draftKey, "")
                        state.sendGeoDmMsg(screen.geohash, screen.peerHex, d)
                    },
                contentAlignment = Alignment.Center
            ) { SNIcon(SNIconName.Send, 17.dp, if (draft.isBlank()) s.text3 else s.onNet, weight = 2.3f) }
        }
    }
    state.toast?.let { ToastBar(it) { state.toast = null } }
}

/** Meta (time + via-transport icon) inline id — design .bc-meta. */
private const val BUBBLE_META_ICON = "sn.meta.via"

/** bc-msg / bc-bubble (components.jsx MsgBubble): max-width 78%, transport-
 *  colored own bubbles (cyan mesh / indigo internet), tail corner at 28% of the
 *  18dp radius, and the time + via icon inlined at the end of the text. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    m: SonarMsg,
    mesh: Boolean = false,
    author: String? = null,
    cont: Boolean = false,
    showState: Boolean = false,
    onRetry: (() -> Unit)? = null,
    maxBubbleWidth: Dp = Dp.Infinity,
) {
    val s = sonar
    // Own bubble is cyan over BLE mesh, indigo over Nostr/internet (the design's
    // transport-colored bubbles); the other party's bubble is always the surface.
    val mineBg = if (mesh) s.accentFill else s.netFill
    val onMine = if (mesh) s.onAccent else s.onNet
    val linkColor = if (m.mine) onMine else s.accent
    // .bc-meta color: on own bubbles the on-color at 72%/75%, else text3.
    val metaColor = if (m.mine) onMine.copy(alpha = if (mesh) 0.72f else 0.75f) else s.text3
    val timeLabel = remember(m.tsSecs) { SonarClock.hourMinute(m.tsSecs) }
    val preview = remember(m.content) { transcriptPreview(m.content) }
    var expanded by remember(m.id) { mutableStateOf(false) }
    val visibleText = if (expanded || !preview.truncated) m.content else preview.text
    val annotated = remember(visibleText, m.mine, mesh, timeLabel, s) {
        buildAnnotatedString {
            append(linkify(visibleText, linkColor))
            // bc-meta: 10.5px time + transport glyph riding the last line.
            withStyle(SpanStyle(fontSize = 10.5.sp, color = metaColor)) { append(" " + timeLabel) }
            appendInlineContent(BUBBLE_META_ICON, "·")
        }
    }
    var textLayout by remember(annotated) { mutableStateOf<TextLayoutResult?>(null) }
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    val inline = mapOf(
        BUBBLE_META_ICON to InlineTextContent(
            Placeholder(14.sp, 11.sp, PlaceholderVerticalAlign.TextCenter)
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterEnd) {
                SNIcon(if (mesh) SNIconName.Mesh else SNIconName.Globe, 11.dp, metaColor, weight = 2.2f)
            }
        }
    )
    val tail = 5.dp // calc(var(--r) * 0.28)
    val shape = RoundedCornerShape(
        topStart = 18.dp, topEnd = 18.dp,
        bottomStart = if (m.mine) 18.dp else tail,
        bottomEnd = if (m.mine) tail else 18.dp,
    )
    Column(
        Modifier.fillMaxWidth().padding(top = if (cont) 2.dp else 9.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            // bc-author: 12/700 in the author's deterministic hue.
            Text(
                author,
                color = authorColor(author, s.isDark),
                fontSize = 12.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 12.dp, bottom = 3.dp)
            )
        }
        Box(
            Modifier.widthIn(max = maxBubbleWidth).clip(shape)
                .background(if (m.mine) mineBg else s.bubbleOther)
                .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 9.dp)
        ) {
            Column {
                // Selectable (long-press → Copy); each visible link keeps its own target.
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text(
                        annotated, color = if (m.mine) onMine else s.text,
                        fontSize = 16.sp, lineHeight = 22.4.sp,
                        inlineContent = inline,
                        onTextLayout = { textLayout = it },
                        modifier = Modifier.pointerInput(annotated) {
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false)
                                val up = waitForUpOrCancellation()
                                if (up != null && !down.isConsumed) {
                                    val offset = textLayout?.getOffsetForPosition(down.position)
                                    offset?.let {
                                        annotated.getStringAnnotations(URL_ANNOTATION_TAG, it, it)
                                            .firstOrNull()
                                            ?.let { link -> uriHandler.openUri(link.item) }
                                    }
                                }
                            }
                        },
                    )
                }
                if (preview.truncated) {
                    // Deliberately inside the truncated branch: only these rows
                    // have the control, so hoisting to the top of MessageBubble
                    // would turn two lookups on *some* rows into four on *every*
                    // row. `stringResource` is remember-backed and synchronous on
                    // Android/JVM (CMP 1.7.3 uses the blocking resource state),
                    // so two per truncated row is already the floor. `semantics {}`
                    // is not a composable scope, hence the local vals.
                    val expandLabel = stringResource(
                        if (expanded) Res.string.content_message_show_less
                        else Res.string.content_message_show_more,
                    )
                    val expandState = stringResource(
                        if (expanded) Res.string.content_message_expanded
                        else Res.string.content_message_collapsed,
                    )
                    Text(
                        expandLabel,
                        color = if (m.mine) onMine else s.accentDeep,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            // heightIn stays OUTSIDE clickable so the 44pt
                            // constraint propagates into the clickable node —
                            // the structural equivalent of iOS keeping frame +
                            // contentShape inside the Button label (#358).
                            .heightIn(min = 44.dp)
                            .semantics { stateDescription = expandState }
                            .clickable(role = Role.Button) { expanded = !expanded }
                            .padding(top = 8.dp),
                    )
                }
            }
        }
        if (showState) MessageStatusFooter(m, mesh, onRetry)
    }
}

/** bc-datechip — centered day marker in the transcript. */
@Composable
private fun DateChip(label: String) {
    val s = sonar
    Box(Modifier.fillMaxWidth().padding(vertical = 5.dp), contentAlignment = Alignment.Center) {
        Text(label, color = s.text3, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Floating day pill for sticky transcript headers (Signal's sticky date
 *  header): pinned while its day scrolls, so it needs its own capsule
 *  background instead of DateChip's transparent inline text. */
@Composable
private fun StickyDayHeader(label: String) {
    val s = sonar
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
        Text(
            label,
            color = s.text2,
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .clip(RoundedCornerShape(11.dp))
                .background(s.surface2.copy(alpha = 0.94f))
                .padding(horizontal = 11.dp, vertical = 4.dp),
        )
    }
}

/** Signal-style unread marker: hairlines around a centered label, attached
 *  above the oldest unread row captured at chat-open time. */
@Composable
private fun UnreadDivider() {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(Modifier.weight(1f).height(1.dp).background(s.text3.copy(alpha = 0.25f)))
        Text("Unread messages", color = s.text2, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
        Box(Modifier.weight(1f).height(1.dp).background(s.text3.copy(alpha = 0.25f)))
    }
}

/** MSN-style nudge transcript row (design NudgeMsg / .bc-nudgemsg): centered
 *  pill on the accent-soft background with the bell glyph wiggling on appear.
 *  The raw ⚡TRILL wire line is never rendered. */
@Composable
private fun TrillLogRow(mine: Boolean, who: String?) {
    val s = sonar
    val label = if (mine) "You sent a nudge" else "${who ?: "Someone"} nudged you — 👋"
    val wiggle = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(Unit) {
        if (TrillEffects.reduceMotionEnabled()) return@LaunchedEffect
        // Bell wiggle on appear: quick alternating rotation that settles.
        for (deg in listOf(-16f, 14f, -10f, 7f, -4f, 0f)) {
            wiggle.animateTo(deg, tween(55, easing = LinearEasing))
        }
    }
    Box(Modifier.fillMaxWidth().padding(vertical = 5.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.clip(RoundedCornerShape(999.dp)).background(s.accentSoft)
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(Modifier.graphicsLayer { rotationZ = wiggle.value }) {
                SNIcon(SNIconName.Bell, 15.dp, s.accentDeep, weight = 2.1f)
            }
            Text(label, color = s.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Whole-app viewport shake for an incoming (or just-sent) trill — the design's
 *  bcShake choreography: 620 ms, translate ±7-9 dp with ±1° rotation on the
 *  cubic-bezier(.36,.07,.19,.97) curve. Honors the platform reduce-motion
 *  setting (sound/haptic still fire from TrillEffects). */
@Composable
internal fun TrillShakeHost(shakeTick: Long, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val translate = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(shakeTick) {
        if (shakeTick == 0L) return@LaunchedEffect
        if (TrillEffects.reduceMotionEnabled()) return@LaunchedEffect
        val easing = androidx.compose.animation.core.CubicBezierEasing(0.36f, 0.07f, 0.19f, 0.97f)
        val steps = listOf(-9f, 8f, -8f, 9f, -7f, 7f, 0f)
        val stepMs = 620 / steps.size
        translate.snapTo(0f)
        for (target in steps) {
            translate.animateTo(
                with(density) { target.dp.toPx() },
                tween(stepMs, easing = easing),
            )
        }
        translate.snapTo(0f)
    }
    Box(
        Modifier.graphicsLayer {
            translationX = translate.value
            // ±1° rotation proportional to the ±9 dp travel.
            rotationZ = if (translate.value == 0f) 0f else {
                (translate.value / with(density) { 9.dp.toPx() }).coerceIn(-1f, 1f)
            }
        }
    ) { content() }
}

@Composable
private fun MessageStatusFooter(m: SonarMsg, mesh: Boolean, onRetry: (() -> Unit)? = null) {
    val state = sonarDeliveryLabel(m.state) ?: return
    val s = sonar
    val pending = sonarDeliveryPending(state)
    val failed = sonarDeliveryFailed(state)
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
        if (failed && onRetry != null) {
            Text(
                "Retry",
                color = s.danger,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .heightIn(min = 32.dp)
                    .clickable(role = Role.Button, onClick = onRetry)
                    .padding(horizontal = 7.dp, vertical = 7.dp),
            )
        }
    }
}

@Composable
private fun StickerBubble(
    m: SonarMsg,
    state: SonarAppState,
    mesh: Boolean = false,
    author: String? = null,
    showState: Boolean = false,
    onRetry: (() -> Unit)? = null,
    onTap: ((String) -> Unit)? = null,
) {
    val ref = m.stickerRef ?: return
    var imageBytes by remember(ref) { mutableStateOf<ByteArray?>(null) }
    var failed by remember(ref) { mutableStateOf(false) }
    var retryToken by remember(ref) { mutableStateOf(0) }
    LaunchedEffect(ref, retryToken) {
        failed = false
        // The failed placeholder shows after the first miss, but keep retrying
        // on a short bounded schedule: cold opens race the relay connection and
        // the core's receive-time prefetch may land moments later.
        var attempt = 0
        while (true) {
            // retryToken > 0 means the user tapped the failed placeholder: that
            // overrides a cached "unresolvable" verdict, which may have been
            // recorded off stale pack metadata.
            imageBytes = state.stickerImage(ref, userInitiated = retryToken > 0)
            if (imageBytes != null) {
                failed = false
                return@LaunchedEffect
            }
            failed = true
            delay(stickerLoadRetryDelayMs(attempt) ?: return@LaunchedEffect)
            attempt++
        }
    }
    Column(
        Modifier.fillMaxWidth().padding(top = 9.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            Text(
                author,
                color = authorColor(author, sonar.isDark),
                fontSize = 12.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 12.dp, bottom = 3.dp)
            )
        }
        val image = remember(imageBytes) {
            imageBytes?.let { runCatching { decodeImageBitmap(it) }.getOrNull() }
        }
        val displayFailed = failed || (imageBytes != null && image == null)
        if (image != null) {
            val tapModifier = if (onTap != null) {
                Modifier.clickable { onTap(ref.packCoordinate) }
            } else Modifier
            androidx.compose.foundation.Image(
                bitmap = image,
                contentDescription = ref.shortcode,
                modifier = tapModifier.size(120.dp).padding(4.dp),
            )
        } else if (displayFailed) {
            Box(
                Modifier.clickable { retryToken++ }
                    .size(120.dp).padding(4.dp).clip(RoundedCornerShape(12.dp)).background(sonar.surface2),
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
        if (showState) MessageStatusFooter(m, mesh, onRetry)
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
        val refreshed = state.fetchInstalledPacks()
        installed = stickerPackInstalledState(
            coordinate = coordinate,
            refreshedCoordinates = refreshed,
            cachedInstalled = state.isPackInstalled(coordinate),
        )
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
    cont: Boolean = false,
    showState: Boolean = false,
    onRetry: (() -> Unit)? = null,
    maxBubbleWidth: Dp = Dp.Infinity,
    onOpen: (SonarMedia) -> Unit,
    onOpenAlbum: (List<SonarMedia>, Int) -> Unit = { _, _ -> },
) {
    val s = sonar
    val media = m.media.first()
    val tail = 5.dp
    val bubbleShape = RoundedCornerShape(
        topStart = 18.dp, topEnd = 18.dp,
        bottomStart = if (m.mine) 18.dp else tail,
        bottomEnd = if (m.mine) tail else 18.dp,
    )
    Column(
        Modifier.fillMaxWidth().padding(top = if (cont) 2.dp else 9.dp),
        horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start
    ) {
        if (!author.isNullOrBlank()) {
            Text(
                author,
                color = authorColor(author, s.isDark),
                fontSize = 12.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 12.dp, bottom = 3.dp)
            )
        }
        if (m.media.size > 1 && m.media.all { it.isImage }) {
            // Photo album: render a swipeable stacked-card deck (xChat-style). A
            // mixed image+audio/file message keeps the single-first rendering
            // below (so audio still gets its player).
            Box(Modifier.widthIn(max = maxBubbleWidth)) {
                MediaDeck(
                    media = m.media,
                    state = state,
                    chatId = chatId,
                    maxBubbleWidth = maxBubbleWidth,
                    onOpen = { idx -> onOpenAlbum(m.media, idx) },
                )
                if (m.state == "Uploading") {
                    MediaUploadBar(
                        progress = state.mediaUploadFraction(m.id) ?: m.uploadProgress ?: 0f,
                        onCancel = { state.cancelMediaUpload(m.id) },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(horizontal = 4.dp, vertical = 3.dp),
                    )
                }
            }
        } else if (media.isImage) {
            val transfer = state.mediaTransferState(media)
            androidx.compose.runtime.LaunchedEffect(media.url, chatId) {
                state.prepareMedia(chatId, media, autoDownload = true)
            }
            val load = rememberTranscriptMediaLoad(state, chatId, media, transfer)
            val decoded = (load as? TranscriptMediaLoad.Ready)?.decoded
            val failed = transfer.phase == MediaTransferPhase.Failed ||
                load is TranscriptMediaLoad.Missing
            // Signal pre-sizes media cells from stored attachment dimensions so
            // the decoded image never reflows the transcript (Signal-Android
            // ThumbnailView measures EXACTLY from DB width/height; Signal-iOS
            // CVMediaAlbumView measures from sourceMediaSizePixels). Reserve the
            // box MediaImage will occupy once decoded, so it holds its place
            // before any bytes arrive. Dimension-less media keeps the skeleton.
            val density = LocalDensity.current
            // Always reserve a stable box (Signal-Android ThumbnailView EXACT
            // measure). Missing MIP-04 dims use the max bubble so decode never
            // grows a 216×150 placeholder and rebuilds the list.
            val reservedSize = remember(media.width, media.height, maxBubbleWidth, density) {
                val maxW = minOf(MAX_MEDIA_BUBBLE_WIDTH, maxBubbleWidth)
                val w = media.width ?: 0
                val h = media.height ?: 0
                if (w > 0 && h > 0) with(density) {
                    mediaBubbleFittedSize(
                        intrinsic = DpSize(w.toDp(), h.toDp()),
                        maxWidth = maxW,
                        maxHeight = MAX_MEDIA_BUBBLE_HEIGHT,
                    )
                } else {
                    DpSize(maxW, MAX_MEDIA_BUBBLE_HEIGHT)
                }
            }
            Box(
                Modifier.size(reservedSize)
                    .clip(bubbleShape).background(s.surface2)
                    .clickable {
                        when (transfer.phase) {
                            MediaTransferPhase.NotDownloaded, MediaTransferPhase.Failed ->
                                state.requestMediaDownload(chatId, media)
                            MediaTransferPhase.Downloading -> state.cancelMediaDownload(media)
                            MediaTransferPhase.Available -> if (decoded != null) onOpen(media)
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                val placeholderModifier = Modifier.fillMaxSize()
                when {
                    decoded?.gifBytes != null -> {
                        MediaImage(
                            bytes = decoded.gifBytes,
                            isGif = true,
                            modifier = Modifier.fillMaxSize()
                        )
                        GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
                        // media-chip: glass time + via pill bottom-right.
                        MediaMetaChip(m.tsSecs, mesh, Modifier.align(Alignment.BottomEnd).padding(8.dp))
                    }
                    decoded?.bitmap != null -> {
                        Image(
                            decoded.bitmap,
                            contentDescription = null,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                        // media-chip: glass time + via pill bottom-right.
                        MediaMetaChip(m.tsSecs, mesh, Modifier.align(Alignment.BottomEnd).padding(8.dp))
                    }
                    decoded != null -> InlineMediaFileChip(media, transfer) { onOpen(media) }
                    failed -> MediaUnavailable(media)
                    showsMediaDownloadSkeleton(state, media, transfer) ->
                        MediaLoadingSkeleton(media, placeholderModifier)
                    // Locally available image still decoding: keep the bubble a
                    // quiet surface for the frame or two before pixels land.
                    else -> Spacer(placeholderModifier)
                }
                if (transfer.phase == MediaTransferPhase.Downloading) {
                    MediaTransferOverlay(transfer, Modifier.align(Alignment.Center))
                }
                if (m.state == "Uploading") {
                    MediaUploadBar(
                        progress = state.mediaUploadFraction(m.id) ?: m.uploadProgress ?: 0f,
                        onCancel = { state.cancelMediaUpload(m.id) },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(horizontal = 4.dp, vertical = 3.dp),
                    )
                }
                if (media.isGif && decoded == null) GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
        } else if (media.mimeType.startsWith("audio/")) {
            AudioBubble(m, state, chatId, media, mesh = mesh)
        } else {
            val transfer = state.mediaTransferState(media)
            androidx.compose.runtime.LaunchedEffect(media.url, chatId) {
                state.prepareMedia(chatId, media, autoDownload = false)
            }
            InlineMediaFileChip(media, transfer) {
                when (transfer.phase) {
                    MediaTransferPhase.NotDownloaded, MediaTransferPhase.Failed ->
                        state.requestMediaDownload(chatId, media)
                    MediaTransferPhase.Downloading -> state.cancelMediaDownload(media)
                    MediaTransferPhase.Available -> onOpen(media)
                }
            }
        }
        if (m.content.isNotEmpty()) {
            // media-cap: caption in its own bubble under the media.
            val capBg = if (m.mine) (if (mesh) s.accentFill else s.netFill) else s.bubbleOther
            val capFg = if (m.mine) (if (mesh) s.onAccent else s.onNet) else s.text
            Spacer(Modifier.height(4.dp))
            Box(
                Modifier.widthIn(max = maxBubbleWidth).clip(RoundedCornerShape(18.dp)).background(capBg)
                    .padding(start = 12.dp, end = 12.dp, top = 7.dp, bottom = 8.dp)
            ) { Text(m.content, color = capFg, fontSize = 15.5.sp, lineHeight = 21.7.sp) }
        }
        if (showState) MessageStatusFooter(m, mesh, onRetry)
    }
}

/**
 * Album deck (xChat-style): the front photo card rests on the ACTUAL next
 * photos, peeking out offset + dimmed + shadowed like a real stack of prints.
 * Every card shares one uniform frame (fill-cropped) so the pile edges line
 * up. Swipe left/right to page, tap to open the fullscreen gallery. Paints
 * from the already-loaded local media list; the only extra work is the 1–2
 * peeked thumbnails, which are the pages the user swipes to next anyway.
 */
@Composable
private fun MediaDeck(
    media: List<SonarMedia>,
    state: SonarAppState,
    chatId: String,
    maxBubbleWidth: Dp,
    onOpen: (Int) -> Unit,
) {
    val s = sonar
    val deckWidth = if (maxBubbleWidth == Dp.Infinity) 250.dp else minOf(250.dp, maxBubbleWidth)
    val deckHeight = 240.dp
    val pagerState = androidx.compose.foundation.pager.rememberPagerState(pageCount = { media.size })
    val current = pagerState.currentPage
    val peek = minOf(2, media.size - 1 - current).coerceAtLeast(0)
    // Reserve the deepest-possible overhang so the deck's footprint (and the row
    // below it) stays put while paging, even as the visible peek count shrinks.
    val maxPeek = minOf(2, media.size - 1)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.padding(end = (maxPeek * 6).dp, bottom = (maxPeek * 5).dp)) {
            // Real next-photo thumbnails behind the front card, deepest first, so
            // the pile shows what's coming and shrinks toward the last photo.
            for (depth in peek downTo 1) {
                MediaDeckCard(
                    media = media[current + depth],
                    state = state,
                    chatId = chatId,
                    dim = 0.12f + 0.10f * depth,
                    onOpen = null,
                    modifier = Modifier
                        .padding(start = (depth * 6).dp, top = (depth * 5).dp)
                        .size(width = deckWidth, height = deckHeight),
                )
            }
            androidx.compose.foundation.pager.HorizontalPager(
                state = pagerState,
                modifier = Modifier.size(width = deckWidth, height = deckHeight),
                pageSpacing = 8.dp,
            ) { page ->
                MediaDeckCard(
                    media = media[page],
                    state = state,
                    chatId = chatId,
                    onOpen = { onOpen(page) },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        // Dots BELOW the deck (matches iOS) so they never cover the photo.
        Row(
            Modifier.padding(start = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            repeat(media.size) { i ->
                Box(
                    Modifier.size(6.dp).clip(CircleShape)
                        .background(if (i == pagerState.currentPage) s.accent else s.text3.copy(alpha = 0.4f))
                )
            }
        }
    }
}

/** One image card inside a [MediaDeck]: loads + decodes its own bytes and
 *  FILL-CROPS the image into the uniform card frame; falls back to skeleton /
 *  unavailable / file chip like the single media bubble. [dim] darkens peek
 *  cards (which are not tappable — [onOpen] null). Tap opens the gallery (or
 *  retries a failed load). */
@Composable
private fun MediaDeckCard(
    media: SonarMedia,
    state: SonarAppState,
    chatId: String,
    onOpen: (() -> Unit)?,
    modifier: Modifier = Modifier,
    dim: Float = 0f,
) {
    val s = sonar
    val transfer = state.mediaTransferState(media)
    androidx.compose.runtime.LaunchedEffect(media.url, chatId) {
        state.prepareMedia(chatId, media, autoDownload = true)
    }
    val load = rememberTranscriptMediaLoad(state, chatId, media, transfer)
    val decoded = (load as? TranscriptMediaLoad.Ready)?.decoded
    val failed = transfer.phase == MediaTransferPhase.Failed ||
        load is TranscriptMediaLoad.Missing
    Box(
        modifier.clip(RoundedCornerShape(18.dp)).background(s.surface2)
            .border(1.dp, Color.Black.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
            .let { m ->
                if (onOpen != null) {
                    m.clickable {
                        when (transfer.phase) {
                            MediaTransferPhase.NotDownloaded, MediaTransferPhase.Failed ->
                                state.requestMediaDownload(chatId, media)
                            MediaTransferPhase.Downloading -> state.cancelMediaDownload(media)
                            MediaTransferPhase.Available -> if (decoded != null) onOpen()
                        }
                    }
                } else m
            },
        contentAlignment = Alignment.Center
    ) {
        when {
            decoded?.gifBytes != null -> {
                MediaImage(bytes = decoded.gifBytes, isGif = true, modifier = Modifier.fillMaxSize())
                GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
            decoded?.bitmap != null -> Image(
                decoded.bitmap,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
            decoded != null -> InlineMediaFileChip(media, transfer) { onOpen?.invoke() }
            failed -> MediaUnavailable(media)
            showsMediaDownloadSkeleton(state, media, transfer) -> MediaLoadingSkeleton(media)
            // Locally available image still decoding: stay a quiet surface.
            else -> Spacer(Modifier.fillMaxSize())
        }
        if (transfer.phase == MediaTransferPhase.Downloading) {
            MediaTransferOverlay(transfer, Modifier.align(Alignment.Center))
        }
        if (media.isGif && decoded == null) GifBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
        if (dim > 0f) {
            Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = dim)))
        }
    }
}

/** Fullscreen, swipeable gallery across a message's album. Each page is a full
 *  [MediaViewer] (lazy load, pinch-zoom, share, save); opens at the tapped
 *  card's index. */
@Composable
private fun MediaGalleryViewer(
    items: List<SonarMedia>,
    startIndex: Int,
    state: SonarAppState,
    chatId: String,
    actions: MediaActions,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pagerState = androidx.compose.foundation.pager.rememberPagerState(
        initialPage = startIndex.coerceIn(0, (items.size - 1).coerceAtLeast(0)),
        pageCount = { items.size }
    )
    Box(modifier.background(Color.Black)) {
        androidx.compose.foundation.pager.HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxSize(),
        ) { page ->
            MediaViewer(
                media = items[page],
                state = state,
                chatId = chatId,
                actions = actions,
                onClose = onClose,
                modifier = Modifier.fillMaxSize(),
            )
        }
        Row(
            Modifier.align(Alignment.BottomCenter).padding(bottom = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            repeat(items.size) { i ->
                Box(
                    Modifier.size(7.dp).clip(CircleShape)
                        .background(if (i == pagerState.currentPage) Color.White else Color.White.copy(alpha = 0.4f))
                )
            }
        }
    }
}

/** media-chip — glass pill (time + via glyph) over an image/video bubble. */
@Composable
private fun MediaMetaChip(tsSecs: Long, mesh: Boolean, modifier: Modifier = Modifier) {
    Row(
        modifier.clip(RoundedCornerShape(999.dp)).background(Color.Black.copy(alpha = 0.42f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Text(SonarClock.hourMinute(tsSecs), color = Color.White, fontSize = 10.5.sp)
        SNIcon(if (mesh) SNIconName.Mesh else SNIconName.Globe, 11.dp, Color.White, weight = 2.2f)
    }
}

/** media-ph — the design's gradient placeholder (photo glyph + filename chip),
 *  shown while the encrypted blob downloads. Hue is the filename hash, exactly
 *  like the prototype's `--ph`/`--ph2`. */
@Composable
private fun MediaLoadingSkeleton(
    media: SonarMedia,
    modifier: Modifier = Modifier.size(width = 216.dp, height = 150.dp),
) {
    val phue = remember(media.filename) { bcHue(media.filename) }
    val ph = Color.hsl(phue, 0.34f, 0.52f)
    val ph2 = Color.hsl((phue + 36f) % 360f, 0.38f, 0.42f)
    Box(
        modifier.background(Brush.linearGradient(listOf(ph, ph2))),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SNIcon(SNIconName.Camera, 26.dp, Color.White.copy(alpha = 0.92f), weight = 1.6f)
            Text(
                media.filename,
                color = Color.White.copy(alpha = 0.78f),
                style = SonarType.mono(10.5),
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clip(RoundedCornerShape(6.dp))
                    .background(Color.Black.copy(alpha = 0.22f))
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .widthIn(max = 170.dp)
            )
        }
    }
}

/** Failed/unavailable media — quiet surface tile with an explicit retry
 *  affordance (the whole bubble tap retries). */
@Composable
private fun MediaUnavailable(media: SonarMedia) {
    val s = sonar
    Box(
        Modifier.size(width = 216.dp, height = 150.dp).background(s.surface2),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SNIcon(SNIconName.Camera, 24.dp, s.text3, weight = 1.7f)
            Text("Media unavailable", color = s.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text("Tap to retry", color = s.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
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

/** Transcript image load state: [Loading] while the local check/read/decode is
 *  in flight, [Missing] when core reports the attachment Available but its
 *  bytes cannot be read, [Ready] with the decoded result otherwise. */
private sealed interface TranscriptMediaLoad {
    data object Loading : TranscriptMediaLoad
    data object Missing : TranscriptMediaLoad
    data class Ready(val decoded: DecodedTranscriptMedia) : TranscriptMediaLoad
}

/**
 * Load + decode a transcript image once, off the UI thread, and keep the result
 * in [MediaImageMemoryCache].
 *
 * Mirrors Signal-Android `ThumbnailView` / `V2ConversationItemThumbnail`:
 * memory hit → RESOURCE-sized disk thumb → **file-path sampled decode**
 * (never a full attachment `ByteArray` on the list path). GIFs still need
 * original bytes to animate. Fullscreen uses a separate viewer decode.
 */
@Composable
private fun rememberTranscriptMediaLoad(
    state: SonarAppState,
    chatId: String,
    media: SonarMedia,
    transfer: MediaTransferState,
): TranscriptMediaLoad {
    // Prefer memory cache on every entry so localPath churn cannot clear Ready.
    val cached = MediaImageMemoryCache.get(media.url)
    val load by androidx.compose.runtime.produceState<TranscriptMediaLoad>(
        cached?.let { TranscriptMediaLoad.Ready(it) } ?: TranscriptMediaLoad.Loading,
        media.url, chatId, transfer.phase, transfer.localPath,
    ) {
        MediaImageMemoryCache.get(media.url)?.let {
            value = TranscriptMediaLoad.Ready(it)
            return@produceState
        }
        if (value is TranscriptMediaLoad.Ready) return@produceState
        if (transfer.phase != MediaTransferPhase.Available) {
            value = TranscriptMediaLoad.Loading
            return@produceState
        }
        // A GIF needs its original bytes to animate, so it has no thumbnail
        // tier — the disk / path hits below are for static images only.
        val animates = media.isGif
        if (!animates) {
            val thumb = withContext(Dispatchers.Default) {
                MediaThumbnailDiskCache.load(media.url)
            }
            if (thumb != null) {
                val decoded = DecodedTranscriptMedia(bitmap = thumb.bitmap, gifBytes = null)
                MediaImageMemoryCache.put(media.url, decoded)
                value = TranscriptMediaLoad.Ready(decoded)
                return@produceState
            }
            // Signal-Android: Glide loads DecryptableUri from disk with
            // override(bubbleW, bubbleH) — sample the file, do not read-all.
            val path = transfer.localPath ?: MediaCache.finalPath(media.url)
            val fromPath = withContext(Dispatchers.Default) {
                decodeThumbnailFromPath(path, TRANSCRIPT_THUMB_MAX_EDGE_PX)
            }
            if (fromPath != null) {
                fromPath.encoded?.let { MediaThumbnailDiskCache.store(media.url, it) }
                val decoded = DecodedTranscriptMedia(bitmap = fromPath.bitmap, gifBytes = null)
                MediaImageMemoryCache.put(media.url, decoded)
                value = TranscriptMediaLoad.Ready(decoded)
                return@produceState
            }
        }
        val bytes = state.mediaData(chatId, media)
        if (bytes == null) {
            value = TranscriptMediaLoad.Missing
            return@produceState
        }
        val decoded = withContext(Dispatchers.Default) {
            if (animates && bytes.looksLikeGifBytes()) {
                DecodedTranscriptMedia(bitmap = null, gifBytes = bytes)
            } else {
                val thumb = decodeThumbnail(bytes, TRANSCRIPT_THUMB_MAX_EDGE_PX)
                thumb?.encoded?.let { MediaThumbnailDiskCache.store(media.url, it) }
                DecodedTranscriptMedia(bitmap = thumb?.bitmap, gifBytes = null)
            }
        }
        MediaImageMemoryCache.put(media.url, decoded)
        value = TranscriptMediaLoad.Ready(decoded)
    }
    return load
}

/** True when the bubble should show the loud gradient download skeleton: the
 *  attachment is genuinely remote (probed NotDownloaded) or downloading. While
 *  the local check/decode is still pending the bubble stays a quiet surface —
 *  locally available images must not flash a download card on chat open. */
private fun showsMediaDownloadSkeleton(
    state: SonarAppState,
    media: SonarMedia,
    transfer: MediaTransferState,
): Boolean = transfer.phase == MediaTransferPhase.Downloading ||
    (transfer.phase == MediaTransferPhase.NotDownloaded && state.mediaTransferKnown(media))

@Composable
private fun InlineMediaFileChip(
    media: SonarMedia,
    transfer: MediaTransferState,
    onAction: () -> Unit,
) {
    val s = sonar
    Row(
        Modifier.clip(RoundedCornerShape(14.dp)).background(s.surface2)
            .clickable { onAction() }
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                media.filename,
                color = s.text,
                fontSize = 13.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                mediaTransferLabel(transfer, media.mimeType),
                color = if (transfer.phase == MediaTransferPhase.Failed) s.danger else s.text3,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(10.dp))
        when (transfer.phase) {
            MediaTransferPhase.Downloading -> MediaTransferProgress(transfer, 22.dp)
            MediaTransferPhase.NotDownloaded -> Text("↓", color = s.accent, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            MediaTransferPhase.Available -> Text("↗", color = s.accent, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            MediaTransferPhase.Failed -> Text("↻", color = s.danger, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        }
    }
}

private fun mediaTransferLabel(transfer: MediaTransferState, fallback: String): String =
    when (transfer.phase) {
        MediaTransferPhase.NotDownloaded -> "Tap to download"
        MediaTransferPhase.Downloading -> transfer.progress?.let { "Downloading ${(it * 100).toInt()}%" } ?: "Downloading"
        MediaTransferPhase.Available -> fallback
        MediaTransferPhase.Failed -> "Download failed · tap to retry"
    }

@Composable
private fun MediaTransferProgress(transfer: MediaTransferState, size: Dp) {
    val s = sonar
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        val progress = transfer.progress
        if (progress != null) {
            androidx.compose.material3.CircularProgressIndicator(
                progress = { progress },
                color = s.accent,
                trackColor = s.text3.copy(alpha = 0.22f),
                strokeWidth = 2.dp,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            androidx.compose.material3.CircularProgressIndicator(
                color = s.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.fillMaxSize(),
            )
        }
        Text("×", color = s.text2, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun MediaTransferOverlay(transfer: MediaTransferState, modifier: Modifier = Modifier) {
    Box(
        modifier.size(48.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.58f)),
        contentAlignment = Alignment.Center,
    ) {
        MediaTransferProgress(transfer, 30.dp)
    }
}

/** XChat-style thin horizontal bar under an uploading media bubble. Tap cancels. */
@Composable
private fun MediaUploadBar(
    progress: Float,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val s = sonar
    val clamped = progress.coerceIn(0f, 1f)
    Box(
        modifier
            .fillMaxWidth()
            .height(3.dp)
            .clip(RoundedCornerShape(50))
            .background(Color.Black.copy(alpha = 0.28f))
            .clickable(onClick = onCancel),
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(clamped.coerceAtLeast(0.02f))
                .background(s.accent),
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
    val scope = rememberCoroutineScope()
    var chrome by remember(media.url) { mutableStateOf(true) }
    var status by remember(media.url) { mutableStateOf<String?>(null) }
    var autoOpenedNative by remember(media.url, chatId) { mutableStateOf(false) }
    val transfer = state.mediaTransferState(media)
    val localPath = transfer.localPath
    val loadedBytes by androidx.compose.runtime.produceState<ByteArray?>(
        null, media.url, localPath
    ) {
        status = null
        value = if (media.isImage && localPath != null) state.mediaData(chatId, media) else null
    }
    val image = remember(loadedBytes, media.url) {
        if (media.isImage) loadedBytes?.let { decodeImageBitmap(it) } else null
    }
    val prefix by androidx.compose.runtime.produceState<ByteArray?>(null, localPath) {
        value = localPath?.let { MediaCache.readPrefix(it, 16) }
    }
    val actionMime = remember(prefix, media.mimeType, media.filename) {
        prefix?.let { effectiveAttachmentMime(media.mimeType, media.filename, it) }
            ?: media.mimeType.substringBefore(';').trim().ifBlank { "application/octet-stream" }
    }
    val displayMedia = remember(media, actionMime) { media.copy(mimeType = actionMime) }

    // File-chip taps only reach this viewer once a complete local stream exists.
    // Documents, video and other native formats open immediately from that file.
    LaunchedEffect(localPath, actionMime) {
        val path = localPath ?: return@LaunchedEffect
        if (!media.isImage && !autoOpenedNative) {
            autoOpenedNative = true
            val ok = actions.open(path, media.filename, actionMime)
            status = if (ok) "Opened" else "Couldn't open media"
        }
    }

    Box(modifier.background(Color.Black)) {
        when {
            image != null -> ZoomableMediaImage(
                image = image,
                description = media.filename,
                onSingleTap = { chrome = !chrome },
                modifier = Modifier.fillMaxSize()
            )
            localPath != null -> MediaFilePreview(
                media = displayMedia,
                onOpen = {
                    scope.launch {
                        val ok = actions.open(localPath, media.filename, actionMime)
                        status = if (ok) "Opened" else "Couldn't open media"
                    }
                },
                onSingleTap = { chrome = !chrome },
                modifier = Modifier.fillMaxSize()
            )
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "Attachment isn't available locally",
                        color = Color.White.copy(alpha = 0.82f),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
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
                        Text(actionMime, color = Color.White.copy(alpha = 0.62f), fontSize = 12.sp)
                    }
                    if (actions.canShare) {
                        MediaActionText("Share", enabled = localPath != null) {
                            scope.launch {
                                val ok = actions.share(localPath ?: return@launch, media.filename, actionMime)
                                status = if (ok) "Opening share sheet" else "Couldn't share media"
                            }
                        }
                        Spacer(Modifier.width(12.dp))
                    }
                    MediaActionText("Save", enabled = localPath != null) {
                        scope.launch {
                            val ok = actions.save(localPath ?: return@launch, media.filename, actionMime)
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

/** One staged attachment in the pre-send preview pager. Images/GIFs carry
 *  their bytes; videos carry only a poster frame (never the full payload). */
private class SendPreviewItem(
    val bytes: ByteArray?,
    val isGif: Boolean,
    val isVideo: Boolean,
    val poster: androidx.compose.ui.graphics.ImageBitmap?,
    val filename: String,
)

@Composable
private fun MediaSendPreview(
    items: List<SendPreviewItem>,
    onSend: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val s = sonar
    val pagerState = androidx.compose.foundation.pager.rememberPagerState(pageCount = { items.size })
    Box(modifier.background(Color.Black)) {
        androidx.compose.foundation.pager.HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxSize(),
        ) { page ->
            val item = items[page]
            val data = item.bytes
            val image = remember(data) {
                if (data != null && !item.isGif && !item.isVideo) decodeImageBitmap(data) else null
            }
            when {
                item.isVideo -> Box(
                    Modifier.fillMaxSize().padding(bottom = 80.dp),
                    contentAlignment = Alignment.Center
                ) {
                    item.poster?.let { poster ->
                        androidx.compose.foundation.Image(
                            bitmap = poster,
                            contentDescription = item.filename,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("▶", color = Color.White, fontSize = 44.sp)
                        if (item.poster == null) {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                item.filename,
                                color = Color.White.copy(alpha = 0.75f),
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
                data != null && (item.isGif || image != null) -> MediaImage(
                    bytes = data,
                    isGif = item.isGif,
                    modifier = Modifier.fillMaxSize().padding(bottom = 80.dp)
                )
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Couldn't decode image", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().align(Alignment.TopStart).padding(horizontal = 8.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SNIconButton(SNIconName.Back, tint = Color.White, onClick = onCancel)
            if (items.size > 1) {
                Spacer(Modifier.weight(1f))
                Text(
                    "${pagerState.currentPage + 1} of ${items.size}",
                    color = Color.White.copy(alpha = 0.85f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(end = 12.dp)
                )
            }
        }
        Row(
            Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(16.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                Modifier.height(52.dp).clip(RoundedCornerShape(999.dp)).background(s.accent)
                    .clickable { onSend() }
                    .padding(horizontal = if (items.size > 1) 18.dp else 0.dp)
                    .widthIn(min = 52.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center
            ) {
                if (items.size > 1) {
                    Text(
                        "${items.size}",
                        color = Color.White,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(end = 6.dp)
                    )
                }
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
    val onTint = if (net) s.onNet else s.onAccent
    val transfer = state.mediaTransferState(media)
    val isSending = m.mine && (m.state == "Sending" || m.state == "Uploading")
    androidx.compose.runtime.LaunchedEffect(media.url, chatId) {
        state.prepareMedia(chatId, media, autoDownload = true)
    }
    val bytes by androidx.compose.runtime.produceState<ByteArray?>(null, media.url, transfer.localPath) {
        value = if (transfer.phase == MediaTransferPhase.Available) state.mediaData(chatId, media) else null
    }
    var playing by remember { mutableStateOf(false) }
    // Stop playback if the bubble leaves composition.
    androidx.compose.runtime.DisposableEffect(media.url) {
        onDispose { if (playing) AudioNotePlayer.stop() }
    }
    val durText = remember(media.durationMs) {
        media.durationMs?.let { fmtDur((it / 1000).toInt()) } ?: ""
    }
    val tail = 5.dp
    // .media-audio: own notes ride the FULL transport fill (cyan/indigo), theirs
    // the surface bubble; radius 18 with the tail corner; padding 11/15/11/11.
    Row(
        Modifier.widthIn(min = 196.dp)
            .clip(
                RoundedCornerShape(
                    topStart = 18.dp, topEnd = 18.dp,
                    bottomStart = if (m.mine) 18.dp else tail,
                    bottomEnd = if (m.mine) tail else 18.dp,
                )
            )
            .background(if (m.mine) tint else s.bubbleOther)
            .padding(start = 11.dp, end = 15.dp, top = 11.dp, bottom = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // media-playbtn: 34dp — white 24% on own bubbles, accent-soft on theirs.
        // Outbound send: Signal-style indeterminate spinner (no horizontal upload bar).
        Box(
            Modifier.size(34.dp).clip(CircleShape)
                .background(if (m.mine) Color.White.copy(alpha = 0.24f) else s.accentSoft)
                .then(
                    if (isSending) Modifier else Modifier.clickable {
                        when (transfer.phase) {
                            MediaTransferPhase.NotDownloaded, MediaTransferPhase.Failed ->
                                state.requestMediaDownload(chatId, media)
                            MediaTransferPhase.Downloading -> state.cancelMediaDownload(media)
                            MediaTransferPhase.Available -> {
                                val b = bytes ?: return@clickable
                                // onComplete resets `playing` when the note ends, is stopped, or
                                // another note steals the shared player.
                                if (playing) AudioNotePlayer.stop()
                                else { playing = true; AudioNotePlayer.play(b) { playing = false } }
                            }
                        }
                    }
                ),
            contentAlignment = Alignment.Center
        ) {
            if (isSending) {
                androidx.compose.material3.CircularProgressIndicator(
                    color = if (m.mine) Color.White else s.accent,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(18.dp),
                )
            } else when (transfer.phase) {
                MediaTransferPhase.NotDownloaded -> Text("↓", color = if (m.mine) Color.White else s.accentDeep, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                MediaTransferPhase.Downloading -> MediaTransferProgress(transfer, 24.dp)
                MediaTransferPhase.Failed -> Text("↻", color = if (m.mine) Color.White else s.accentDeep, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                MediaTransferPhase.Available -> SNIcon(
                    if (playing) SNIconName.Pause else SNIconName.Play, 14.dp,
                    if (m.mine) Color.White else s.accentDeep,
                    weight = 2.2f
                )
            }
        }
        Spacer(Modifier.width(11.dp))
        MediaWaveStatic(
            media.filename,
            color = if (m.mine) Color.White.copy(alpha = 0.6f) else s.accent.copy(alpha = 0.55f),
            modifier = Modifier.width(124.dp).height(26.dp)
        )
        if (durText.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Text(
                durText, style = SonarType.mono(11.5, FontWeight.SemiBold),
                color = if (m.mine) onTint.copy(alpha = 0.8f) else s.text2.copy(alpha = 0.8f)
            )
        }
    }
}

/** Static waveform (design: `MediaWave`) — deterministic hash bars from a seed. */
@Composable
private fun MediaWaveStatic(seed: String, color: Color, modifier: Modifier = Modifier) {
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
            Box(Modifier.width(2.dp).fillMaxHeight(v).clip(CircleShape).background(color))
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
    // voice-bar: height 38, radius 19, rec dot 11, mono timer, live wave.
    Row(
        modifier.heightIn(min = 38.dp).clip(RoundedCornerShape(19.dp)).background(s.surface2)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        Box(Modifier.size(11.dp).clip(CircleShape).background(s.danger))
        Text(fmtDur(elapsed), style = SonarType.mono(14.0, FontWeight.SemiBold), color = s.text, modifier = Modifier.width(38.dp))
        LiveWave(level, Modifier.weight(1f))
        Row(
            Modifier.alpha((1f + dragX / 110f).coerceIn(0f, 1f)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            SNIcon(SNIconName.Back, 12.dp, if (armed) s.danger else s.text3, weight = 2.4f)
            Text(
                if (armed) "release to cancel" else "slide to cancel",
                color = if (armed) s.danger else s.text3, fontSize = 12.5.sp, maxLines = 1
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
    // .media-wave.live — accent-tinted bars while recording.
    Row(modifier.height(22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 0 until 22) {
            val p = phase * 6 + i * 0.5f
            val v = (sin(p * 0.7f) + sin(p * 1.9f + i)) * 0.5f
            val h = 4f + abs(v) * 14f * maxOf(0.25f, level)
            Box(Modifier.width(2.dp).height(h.dp).clip(CircleShape).background(s.accent.copy(alpha = 0.7f)))
        }
    }
}

/** m:ss like the design's fmtDur. */
private fun fmtDur(sec: Int): String = "${sec / 60}:${(sec % 60).toString().padStart(2, '0')}"

// ── Local-day helpers for row times + transcript date chips ──────────────
// commonMain has no timezone API; local midnight is derived from the platform
// "HH:MM" that SonarClock already provides (≤59s of error, invisible here).

private val WEEKDAYS = arrayOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
private val MONTHS = arrayOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

/** Epoch seconds of the most recent local midnight. */
private fun localMidnightEpoch(): Long {
    val now = SonarClock.nowSecs()
    val hm = SonarClock.hourMinute(now)
    val h = hm.substringBefore(':').toIntOrNull() ?: 0
    val m = hm.substringAfter(':').toIntOrNull() ?: 0
    return now - (h * 3600L + m * 60L)
}

/** Whole local days between [tsSecs] and today (0 = today, -1 = yesterday…). */
private fun localDayDelta(tsSecs: Long): Long =
    (tsSecs - localMidnightEpoch()).floorDiv(86_400L)

/** Local civil epoch-day of today (local noon trick keeps any UTC offset ≤12h safe). */
private fun localEpochDayToday(): Long = (localMidnightEpoch() + 43_200L).floorDiv(86_400L)

/** y/m/d from an epoch day (Howard Hinnant's civil_from_days). */
private fun civilFromEpochDay(epochDay: Long): Triple<Int, Int, Int> {
    val z = epochDay + 719_468L
    val era = (if (z >= 0) z else z - 146_096L).floorDiv(146_097L)
    val doe = z - era * 146_097L
    val yoe = (doe - doe / 1460L + doe / 36_524L - doe / 146_096L) / 365L
    val y = yoe + era * 400L
    val doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
    val mp = (5L * doy + 2L) / 153L
    val d = doy - (153L * mp + 2L) / 5L + 1L
    val mo = if (mp < 10L) mp + 3L else mp - 9L
    return Triple((if (mo <= 2L) y + 1L else y).toInt(), mo.toInt(), d.toInt())
}

private fun weekdayName(epochDay: Long): String =
    WEEKDAYS[(((epochDay + 3L) % 7L + 7L) % 7L).toInt()] // 1970-01-01 = Thu

private fun shortDate(epochDay: Long): String {
    val (_, mo, d) = civilFromEpochDay(epochDay)
    return "$d ${MONTHS[mo - 1]}"
}

/** bc-time — chat-list right column: today → HH:MM, last week → weekday, older → date. */
internal fun rowTimeLabel(tsSecs: Long): String {
    if (tsSecs <= 0L) return ""
    val delta = localDayDelta(tsSecs)
    return when {
        delta >= 0L -> SonarClock.hourMinute(tsSecs)
        delta >= -6L -> weekdayName(localEpochDayToday() + delta)
        else -> shortDate(localEpochDayToday() + delta)
    }
}

/** bc-datechip label: Today / Yesterday / weekday / date. */
internal fun dayLabel(tsSecs: Long): String {
    val delta = localDayDelta(tsSecs)
    return when {
        delta == 0L -> "Today"
        delta == -1L -> "Yesterday"
        delta in -6L..-2L -> weekdayName(localEpochDayToday() + delta)
        else -> shortDate(localEpochDayToday() + delta)
    }
}

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
            icon = SNIconName.Pin, iconSize = 22.dp, amber = true,
            title = "Nothing around you yet",
            desc = "Turn on location to see public channels nearby, or use the radar to find people over Bluetooth."
        )
        return
    }
    val defaultIdx = items.indexOfFirst { it.count > 0 }.let { if (it >= 0) it else items.lastIndex }
    var idx by remember(items.size) { mutableStateOf(defaultIdx) }
    val sel = items[idx.coerceIn(0, items.lastIndex)]
    val cardShape = RoundedCornerShape(20.dp)
    // here-card: surface card, radius 20, hairline inset ring, margin 2/14/6.
    Column(
        Modifier.fillMaxWidth()
            .padding(start = 14.dp, end = 14.dp, top = 2.dp, bottom = 6.dp)
            .clip(cardShape).background(s.surface).border(1.dp, s.hairline, cardShape)
    ) {
        // here-main: tile 52 · name 16.5/700 · "tier · N here now" · chevron.
        Row(
            Modifier.fillMaxWidth().clickable { onEnter(sel.geohash) }
                .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (sel.geohash == "mesh") MeshTile(52.dp) else PlaceTile(52.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    sel.name, color = s.text, fontSize = 16.5.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = (-0.17).sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "${sel.tier} · ${sel.count} here now",
                    color = s.text2, fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(12.dp))
            SNIcon(SNIconName.Chevron, 15.dp, s.text3, weight = 2.2f)
        }
        // here-scale: pill ticks — surface2/text2, selected accent-soft/accent-deep,
        // 6dp green live dot when someone's there.
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            items.forEachIndexed { i, ch ->
                val on = i == idx
                Row(
                    Modifier.clip(RoundedCornerShape(999.dp))
                        .background(if (on) s.accentSoft else s.surface2)
                        .clickable { idx = i }
                        .padding(horizontal = 11.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                ) {
                    Text(
                        ch.short, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold,
                        color = if (on) s.accentDeep else s.text2, maxLines = 1
                    )
                    if (ch.count > 0) Box(Modifier.size(6.dp).clip(CircleShape).background(s.green))
                }
            }
        }
    }
}

/** One precision tick on the "Around you" ladder (data.js `here[]`). */
data class HereItem(val geohash: String, val name: String, val tier: String, val short: String, val count: Int)

private val URL_REGEX = Regex("""(https?://|www\.)\S+""")
private const val URL_ANNOTATION_TAG = "url"

private fun linkify(text: String, linkColor: androidx.compose.ui.graphics.Color) =
    androidx.compose.ui.text.buildAnnotatedString {
        var last = 0
        for (match in URL_REGEX.findAll(text)) {
            append(text.substring(last, match.range.first))
            val url = if (match.value.startsWith("www.")) "https://${match.value}" else match.value
            pushStringAnnotation(URL_ANNOTATION_TAG, url)
            pushStyle(
                androidx.compose.ui.text.SpanStyle(
                    color = linkColor,
                    textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline
                )
            )
            append(match.value)
            pop()
            pop()
            last = match.range.last + 1
        }
        append(text.substring(last))
    }

/**
 * "Start a chat" sheet — nearby peers, new discussion (username/NIP-05/key), and new group.
 */
@Composable
private fun ComposeSheet(state: SonarAppState, onClose: () -> Unit) {
    val s = sonar
    val scope = rememberCoroutineScope()
    var groupEntry by remember { mutableStateOf(false) }
    var findUsername by remember { mutableStateOf(false) }
    var findDraft by remember { mutableStateOf("") }
    var findResolving by remember { mutableStateOf(false) }
    var findNpub by remember { mutableStateOf<String?>(null) }
    var findMiss by remember { mutableStateOf(false) }
    var findStartError by remember { mutableStateOf<String?>(null) }
    var findLookupGeneration by remember { mutableStateOf(0) }
    var findLookupJob by remember { mutableStateOf<Job?>(null) }
    var groupName by remember { mutableStateOf("") }
    var groupMembers by remember { mutableStateOf("") }
    var selectedGroupNpubs by remember { mutableStateOf(setOf<String>()) }
    val inRange = state.meshPeers

    fun resetFind() {
        findLookupJob?.cancel()
        findLookupJob = null
        findLookupGeneration += 1
        findUsername = false
        findDraft = ""
        findResolving = false
        findNpub = null
        findMiss = false
        findStartError = null
    }

    fun isValidNpub(value: String): Boolean {
        val decoded = Bech32.decode(value.trim()) ?: return false
        return decoded.hrp == "npub" && decoded.data.size == 32
    }

    fun startChatFromFind(npub: String) {
        findStartError = null
        if (!isValidNpub(npub)) {
            findStartError = "That key isn't a valid npub — check it and try again."
            findNpub = null
            return
        }
        state.startChat(npub)
        onClose()
    }

    fun lookupUsername() {
        val trimmed = findDraft.trim()
        if (trimmed.isEmpty() || findResolving) return
        findStartError = null
        if (trimmed.lowercase().startsWith("npub1")) {
            if (isValidNpub(trimmed)) {
                findNpub = trimmed
                findMiss = false
            } else {
                findNpub = null
                findMiss = false
                findStartError = "That key isn't a valid npub — check it and try again."
            }
            return
        }
        if (!SonarCore.handleLooksValid(trimmed)) return
        findLookupJob?.cancel()
        findLookupGeneration += 1
        val generation = findLookupGeneration
        findResolving = true
        findMiss = false
        findNpub = null
        findLookupJob = scope.launch {
            val npub = state.resolveHandleForChat(trimmed)
            if (generation != findLookupGeneration) return@launch
            findResolving = false
            if (npub != null) findNpub = npub else findMiss = true
        }
    }

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
                if (findUsername) {
                    Text("Find by username", color = s.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Type a username — just vincenzo for @${state.handleDomain}, a full name@domain, or paste a key.",
                        color = s.text2, fontSize = 13.5.sp, lineHeight = 18.sp
                    )
                    Spacer(Modifier.height(12.dp))
                    val trimmed = findDraft.trim().lowercase()
                    val showSuffix = trimmed.isNotEmpty() && '@' !in trimmed && !trimmed.startsWith("npub1")
                    val preview = when {
                        trimmed.startsWith("npub1") -> trimmed
                        '@' in trimmed -> trimmed
                        else -> "$trimmed@${state.handleDomain}"
                    }
                    val looksValid = SonarCore.handleLooksValid(findDraft.trim()) ||
                        findDraft.trim().lowercase().startsWith("npub1")
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        SNIcon(SNIconName.Key, 16.dp, s.text3, weight = 2f)
                        Spacer(Modifier.width(8.dp))
                        Box(Modifier.weight(1f)) {
                            if (findDraft.isEmpty()) Text("vincenzo", color = s.text3, fontSize = 14.sp)
                            BasicTextField(
                                value = findDraft,
                                onValueChange = {
                                    findDraft = it
                                    findNpub = null
                                    findMiss = false
                                    findResolving = false
                                    findStartError = null
                                    findLookupJob?.cancel()
                                    findLookupJob = null
                                    findLookupGeneration += 1
                                },
                                singleLine = true,
                                textStyle = TextStyle(color = s.text, fontSize = 14.sp),
                                cursorBrush = SolidColor(s.accent),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        if (showSuffix) {
                            Text("@${state.handleDomain}", color = s.text3, style = SonarType.mono(12.0), maxLines = 1)
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    when {
                        findResolving -> Text("Looking up $preview…", color = s.text2, fontSize = 13.sp)
                        findStartError != null -> Text(findStartError!!, color = s.danger, fontSize = 13.sp)
                        findMiss -> Text("No Sonar user found at that address.", color = s.danger, fontSize = 13.sp)
                        findNpub != null -> {
                            val npub = findNpub!!
                            Row(
                                Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(s.surface2)
                                    .clickable { startChatFromFind(npub) }
                                    .padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                SonarAvatar(trimmed.substringBefore('@').ifBlank { "user" }, 46.dp)
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        trimmed.substringBefore('@').ifBlank { trimmed },
                                        color = s.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold
                                    )
                                    Text(preview, color = s.text2, style = SonarType.mono(12.0), maxLines = 1)
                                    Text(
                                        if (npub.length > 22) npub.take(22) + "…" else npub,
                                        color = s.text3, style = SonarType.mono(11.5), maxLines = 1
                                    )
                                }
                                SNIcon(SNIconName.Chevron, 16.dp, s.text3, weight = 2.4f)
                            }
                            Spacer(Modifier.height(10.dp))
                        }
                    }
                    if (findNpub != null) {
                        SNPrimaryButton("Start encrypted chat") { startChatFromFind(findNpub!!) }
                    } else {
                        SNPrimaryButton(
                            if (findResolving) "Looking up…" else "Look up",
                            disabled = !looksValid || findResolving,
                            net = true
                        ) { lookupUsername() }
                    }
                    Spacer(Modifier.height(6.dp))
                    SNGhostButton("Back") { resetFind() }
                } else {
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
                ActionRow(SNIconName.Key, "Find by username", "Username, name@domain, or paste a key — reaches anywhere") {
                    findUsername = true; groupEntry = false
                    findDraft = ""; findNpub = null; findMiss = false
                }
                ActionRow(SNIconName.Coin, "Send a payment", "Pay a contact, Lightning address or Bolt12 offer") {
                    onClose(); state.push(Screen.SendPayment)
                }
                ActionRow(SNIconName.People, "New group", "Invite contacts or paste keys") {
                    groupEntry = true; findUsername = false
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
