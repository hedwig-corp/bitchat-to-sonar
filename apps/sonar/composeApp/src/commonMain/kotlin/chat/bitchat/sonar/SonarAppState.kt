package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.crypto.Bech32
import chat.bitchat.sonar.store.MessageMerge
import chat.bitchat.sonar.store.MessageStore
import chat.bitchat.sonar.unify.UnifyBIP321
import chat.bitchat.sonar.unify.UnifyPeer
import chat.bitchat.sonar.unify.UnifyRadio
import chat.bitchat.sonar.wallet.ExchangeRate
import chat.bitchat.sonar.wallet.FiatCurrency
import chat.bitchat.sonar.wallet.Money
import chat.bitchat.sonar.wallet.PaymentActivityStore
import chat.bitchat.sonar.wallet.SendResult
import chat.bitchat.sonar.wallet.SonarPaymentActivity
import chat.bitchat.sonar.wallet.WalletActivityItem
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import chat.bitchat.sonar.wallet.mergeWalletActivity
import chat.bitchat.sonar.wallet.paymentDestinationHash
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

private const val SONAR_DESCRIPTOR_TTL_SECS = 15 * 60L
private const val SONAR_DESCRIPTOR_MISS_TTL_SECS = 60L
private const val PROFILE_MISS_TTL_SECS = 60L
/** How long after BLE activity the mesh drain loop stays at 150ms. */
private const val MESH_REALTIME_HOT_WINDOW_MS = 30_000L
private const val PROFILE_REFRESH_TTL_SECS = 30 * 60L
private const val LOCAL_TRANSCRIPT_PAGE_LIMIT = 100
private const val LOCAL_SUMMARY_PAGE_LIMIT = 20
private const val LOCAL_SUMMARY_CHAT_LIMIT = 5

// ── Event-driven refresh cadence ──
// The old poll ran a full cycle every 4 s. Now the cycle is driven by the core
// `conversationChanged` flow (primary) plus a slow fallback heartbeat that only
// covers time-based upkeep the core can't signal (presence, BLE policy, unify,
// profile TTLs). Foreground idle CPU is set by the heartbeat cadence.
private const val HEARTBEAT_FG_MS = 30_000L
private const val HEARTBEAT_BG_MS = 60_000L
/** Relay `sync()` cadence (was every ~60 s on the old 4 s tick). */
private const val SYNC_INTERVAL_MS = 60_000L
/** Coarse geohash presence beat (was `tick % 15` ≈ every 60 s). */
private const val PRESENCE_BEAT_MS = 60_000L
/** Stale kind-0 profile sweep (was `tick % 450` ≈ every 30 min). */
private const val PROFILE_SWEEP_MS = 30 * 60_000L
private const val GROUP_FOLDS_BLOB_KEY = "sonar.groupFolds"
private const val NPUB_BLOB_KEY = "sonar.npub"
private const val MESH_NAMES_BLOB_KEY = "sonar.meshNames"
private const val FAVORITED_CONTROL = "[FAVORITED]"
private const val UNFAVORITED_CONTROL = "[UNFAVORITED]"
private const val MESH_MEDIA_URL_PREFIX = "mesh-media:"
private const val PENDING_MARMOT_CHAT_PREFIX = "npub:"
private const val PENDING_MARMOT_GROUP_PREFIX = "group-pending:"
private const val PENDING_MARMOT_DIRECT_SEND_QUEUE_LIMIT = 100
private const val PENDING_MARMOT_GROUP_SEND_QUEUE_LIMIT = 100
internal const val BLE_DISCOVER_NEW_PEOPLE_PREF = "bleDiscoverNewPeople"

internal fun shortNpubLabel(value: String): String =
    if (value.length > 16) value.take(10) + "…" + value.takeLast(4) else value

internal fun resolveGroupAuthorName(
    message: SonarMsg,
    isGroup: Boolean,
    profilesByNpub: Map<String, SonarProfile>,
    fetchMissingProfile: (String) -> Unit,
): String? {
    if (!isGroup || message.mine || message.senderNpub.isBlank()) return null
    profilesByNpub[canonicalProfileKey(message.senderNpub)]?.bestName?.let { return it }
    fetchMissingProfile(message.senderNpub)
    return shortNpubLabel(message.senderNpub)
}

sealed interface Screen {
    data object Home : Screen
    data object Settings : Screen
    data object Profile : Screen
    data object Nearby : Screen
    data object Search : Screen
    // id "mesh:<peerId>" = a BLE-mesh DM (Noise link); otherwise a Marmot group.
    // pay=true auto-opens the payment sheet (radar "Send sats").
    data class Chat(val id: String, val name: String, val pay: Boolean = false) : Screen
    data class Channel(val geohash: String) : Screen
    data class GeoDm(val geohash: String, val peerHex: String, val name: String) : Screen
    // Full-screen voice/video call. [peerId] is the folded backing chat id
    // ("mesh:<id>" for a Sonar peer) so the call log appends to the right
    // conversation; [video] picks voice vs video layout.
    data class Call(val peerId: String, val name: String, val video: Boolean) : Screen
    data class ContactProfile(val chatId: String, val name: String) : Screen
    data class GroupInfo(val chatId: String) : Screen
    data object WalletActivity : Screen
}

/** A BLE-mesh DM conversation row for the home Messages list. */
data class MeshDmRow(val peerId: String, val name: String, val preview: String, val tsSecs: Long)

/** A local contact that can be invited into a Marmot group. */
data class GroupContact(val id: String, val title: String, val subtitle: String, val npub: String)

private fun messagePreview(content: String, stickerRef: SonarStickerRef? = null, media: List<SonarMedia> = emptyList()): String {
    media.firstOrNull()?.let {
        return when {
            it.mimeType.startsWith("image/") -> "Image"
            it.mimeType.startsWith("audio/") -> "Voice note"
            it.filename.isNotBlank() -> it.filename
            else -> "File"
        }
    }
    if (stickerRef != null) return "Sticker"
    if (content.trimStart().startsWith("☎CALL") && SonarCore.callParseControl(content) != null) {
        return "Voice call"
    }
    return if (PayLine.decode(content) != null) "₿ Payment" else content
}

internal fun canonicalConversationTitle(title: String): String =
    title.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

/** A direct Marmot DM owns its profile title even when it is folded into a
 * mesh row. BLE nicknames are transport metadata, not conversation identity. */
internal fun homeListTitleForFoldedMeshRow(
    directMarmotTitle: String?,
    meshDerivedName: String,
): String = directMarmotTitle ?: meshDerivedName

/** Fold only when both transports identify the same cryptographic account. */
internal fun peerNpubHexMatchesLinkedPeer(
    groupCounterpartyNpubHex: String,
    linkedPeerNpubHex: String?,
): Boolean = linkedPeerNpubHex?.equals(groupCounterpartyNpubHex, ignoreCase = true) == true

/** Resolve an incoming Nostr sender through cryptographic links only. Live
 * announces win, then the restart-persisted link is used. Display names never
 * participate, so two contacts called Vincenzo/Sara cannot absorb each other's
 * messages when profiles or BLE aliases refresh. */
internal fun resolvePeerIdForNpubHex(
    senderNpubHex: String,
    livePeerIds: Iterable<String>,
    liveNpubHexForPeer: (String) -> String?,
    persistedNpubHexByPeer: Map<String, String>,
): String? = livePeerIds.firstOrNull { peerId ->
    liveNpubHexForPeer(peerId)?.equals(senderNpubHex, ignoreCase = true) == true
} ?: persistedNpubHexByPeer.entries.firstOrNull { (_, npubHex) ->
    npubHex.equals(senderNpubHex, ignoreCase = true)
}?.key

internal fun directMarmotPeerKey(chat: SonarChat, ownNpub: String): String? {
    val mine = canonicalProfileKey(ownNpub)
    val others = chat.members
        .map { canonicalProfileKey(it) }
        .filter { it.isNotBlank() && it != mine }
        .distinct()
    return others.singleOrNull()
}

internal fun dedupeDirectMarmotChats(
    chats: List<SonarChat>,
    ownNpub: String,
    latestSecs: (String) -> Long = { 0L },
): List<SonarChat> {
    val selectedByKey = LinkedHashMap<String, SonarChat>()
    for (chat in chats) {
        val key = directMarmotPeerKey(chat, ownNpub) ?: "\u0000${chat.id}"
        val current = selectedByKey[key]
        if (current == null || latestSecs(chat.id) > latestSecs(current.id)) {
            selectedByKey[key] = chat
        }
    }
    val selectedIds = selectedByKey.values.map { it.id }.toSet()
    return chats.filter { it.id in selectedIds }
}

/** Stable conversation identity for BLE fingerprints that advertise the same
 *  Sonar account. Unlinked peers remain isolated by their Noise fingerprint. */
internal fun meshConversationIdentityKey(peerId: String, linkedNpubHex: String?): String {
    val linked = linkedNpubHex
        ?.trim()
        ?.lowercase()
        ?.takeIf { value -> value.length == 64 && value.all { it in "0123456789abcdef" } }
    return linked?.let { "npub:$it" } ?: "peer:$peerId"
}

internal fun groupMeshPeerIdsByIdentity(
    peerIds: Collection<String>,
    linkedNpubByPeer: Map<String, String>,
): List<List<String>> =
    peerIds.distinct()
        .groupBy { meshConversationIdentityKey(it, linkedNpubByPeer[it]) }
        .values
        .map { it.sorted() }

internal fun groupMeshConversationAliases(
    knownPeerIds: Collection<String>,
    peerIdsWithMessages: Set<String>,
    linkedNpubByPeer: Map<String, String>,
): List<List<String>> =
    groupMeshPeerIdsByIdentity(knownPeerIds, linkedNpubByPeer)
        .filter { aliases -> aliases.any { it in peerIdsWithMessages } }

/** Prefer an already-persisted fold target so a row key stays stable; otherwise
 *  choose a deterministic fingerprint from the alias set. */
internal fun selectCanonicalMeshPeerId(
    aliases: Collection<String>,
    persistedFoldPeerIds: Set<String>,
): String? =
    aliases.filter { it in persistedFoldPeerIds }.minOrNull()
        ?: aliases.minOrNull()

/** Prefer the active Noise fingerprint for transport/capability lookup while
 * preserving deterministic alias order when the peer is offline. */
internal fun orderMeshAliasesByLiveRoute(
    aliases: Collection<String>,
    livePeerId: String?,
): List<String> = buildList {
    if (livePeerId != null && livePeerId in aliases) add(livePeerId)
    addAll(aliases.filter { it != livePeerId }.sorted())
}

/** True when a drain touched any fingerprint folded into the open contact. */
internal fun meshAliasGroupWasTouched(
    aliases: Collection<String>,
    touchedPeerIds: Collection<String>,
): Boolean {
    if (aliases.isEmpty() || touchedPeerIds.isEmpty()) return false
    val touched = touchedPeerIds.toSet()
    return aliases.any { it in touched }
}

/** A folded contact is blocked when any known fingerprint or its durable npub
 * identity is blocked. The npub check also covers aliases learned later. */
internal fun isMeshAliasGroupBlocked(
    aliases: Collection<String>,
    isPeerBlocked: (String) -> Boolean,
    linkedNpubHex: (String) -> String?,
    isNpubBlocked: (String) -> Boolean,
): Boolean =
    aliases.any(isPeerBlocked) ||
        aliases.asSequence().mapNotNull(linkedNpubHex).any(isNpubBlocked)

/** Composite scan watermark: the newest-message SECOND plus the message COUNT.
 *  Timestamps are second-resolution, so a message landing in the SAME second as
 *  the last scanned one (common for ⚡PAY PAY/DONE pairs or a call control sent
 *  right after a text) leaves `secs` unchanged — the count catches it. */
internal data class ScanMark(val secs: Long, val count: Long)

/** Per-chat probe used to decide, from the single `conversationSummaries()` FFI
 *  call, which chats actually gained a newer message since the last scan. Only
 *  those chats need the expensive `messagesPage` fetch + re-parse for call/pay
 *  scanning; everything else is skipped. Pure so it can be unit-tested. */
internal fun chatsNeedingPageScan(
    latestByChat: Map<String, ScanMark>,
    scannedWatermark: Map<String, ScanMark>,
): Set<String> = buildSet {
    for ((chatId, latest) in latestByChat) {
        val seen = scannedWatermark[chatId] ?: ScanMark(Long.MIN_VALUE, Long.MIN_VALUE)
        // A later second, OR the same second with more messages, means unseen
        // content — either way the chat needs a rescan.
        if (latest.secs > seen.secs || (latest.secs == seen.secs && latest.count > seen.count)) {
            add(chatId)
        }
    }
}

/** Whether a per-chat notification should fire, derived purely from the cheap
 *  `conversationSummaries()` probe. Mirrors the guard inside `notifyChatIfNew`:
 *  the newest message must be incoming, strictly newer than what we last saw
 *  AND last notified, the seed pass must be done, and the chat must not be the
 *  one currently open. Kept pure for unit tests. */
internal fun shouldNotifyIncoming(
    latestAtSecs: Long,
    latestMine: Boolean,
    prevSeenSecs: Long?,
    lastNotifiedSecs: Long,
    seeded: Boolean,
    isOpen: Boolean,
): Boolean {
    if (!seeded || isOpen || latestMine) return false
    if (latestAtSecs <= 0L) return false
    val prev = prevSeenSecs ?: return false
    return latestAtSecs > prev && latestAtSecs > lastNotifiedSecs
}

/** Immutable fingerprint of every input `visibleChats` depends on. The getter
 *  memoizes its result keyed by this value: two reads with an equal key return
 *  the identical cached list without recomputing dedupe/fold/pending work, so
 *  Compose recompositions that don't change conversation state are O(1). */
internal data class VisibleChatsKey(
    val chatsIdentity: Int,
    val foldedGroupIds: Set<String>,
    val pendingChatNpubs: Map<String, String>,
    val pendingGroupIds: Set<String>,
    val socialVersion: Int,
    val snapshotVersion: Int,
    val ownNpub: String,
    val holdVersion: Int,
)

private fun decodeGroupFoldMap(blob: String): Map<String, String> =
    blob.lineSequence()
        .mapNotNull { line ->
            val i = line.indexOf('=')
            if (i <= 0) null else line.substring(0, i) to line.substring(i + 1).trim()
        }
        .filter { (groupId, peerId) -> groupId.isNotBlank() && peerId.isNotBlank() }
        .toMap()

internal const val CAPABILITY_SETTLE_MS = 1_500L

internal fun shouldWaitForCapabilities(
    firstSeenMs: Long?,
    nowMs: Long,
    hasProfile: Boolean,
    hasMessages: Boolean,
    settleMs: Long = CAPABILITY_SETTLE_MS,
): Boolean {
    if (hasProfile || hasMessages) return false
    val first = firstSeenMs ?: return false
    return nowMs - first < settleMs
}

internal fun hasRecentMarmotActivityForCapabilitySettle(
    latestMessageTsSecs: Long?,
    nowMs: Long,
    settleMs: Long = CAPABILITY_SETTLE_MS,
): Boolean {
    val latest = latestMessageTsSecs ?: return false
    if (latest <= 0) return false
    val ageMs = nowMs - (latest * 1_000L)
    return ageMs > -settleMs && ageMs < settleMs
}

/** Peers allowed through restricted BLE discovery must already be backed by
 *  local conversation state. Passive Sonar 0x53 links are intentionally omitted:
 *  they can include people who were only seen during discovery. */
internal fun knownBlePeerIdsForPolicy(
    meshChatPeerIds: Iterable<String>,
    persistedFoldPeerIds: Iterable<String>,
    liveFoldPeerIds: Iterable<String>,
): Set<String> = buildSet {
    meshChatPeerIds.forEach { add(it.lowercase()) }
    persistedFoldPeerIds.forEach { add(it.lowercase()) }
    liveFoldPeerIds.forEach { add(it.lowercase()) }
}

/** A call-log record appended to a DM transcript when a call ends. Lives in
 *  memory only (no MessageStore/SonarCore/Marmot write). [durSecs] == 0 ⇒ the call never connected
 *  (rendered as "Missed"); otherwise it's the connected duration. */
data class CallRecord(
    val video: Boolean,
    val mine: Boolean,
    val durSecs: Int,
    val tsSecs: Long,
) {
    val missed: Boolean get() = durSecs == 0
}

/** The in-flight P2P call the [CallScreen] renders. [incoming] true ⇒ we are the
 *  callee (show Accept/Decline); [phase] tracks the engine state machine. */
data class ActiveCall(
    val callId: String,
    val chatId: String,
    val peerName: String,
    val video: Boolean,
    val incoming: Boolean,
    val phase: SonarCallState,
    val connectedSecs: Int = 0,
    val muted: Boolean = false,
    val speakerOn: Boolean = true,
    val camOn: Boolean = false,
    /** Which camera feeds the local PiP (iOS `frontCamera` parity). */
    val frontCamera: Boolean = true,
)

/** Verify-sheet model: the safety groups (empty ⇒ show [note]) + verified flag. */
data class SonarVerify(val safety: List<String>, val verified: Boolean, val note: String?)

/** Precomputed home chat-list row (Signal-style cached row view model): all the
 *  fields the design ConvRow needs, resolved off the render path so the home
 *  LazyColumn reads O(1) per row instead of walking `chats` + hitting disk. */
data class MarmotRowModel(
    val id: String,
    val title: String,
    val sub: String,
    val tsSecs: Long,
    val verified: Boolean,
    val unread: Boolean,
    val pending: Boolean,
    val multiMember: Boolean,
)

/**
 * Shared (commonMain) UI state for the Sonar app. Drives White Noise (Marmot)
 * encrypted DMs through [SonarCore]; the same logic will back the iOS app once
 * it shifts to Compose Multiplatform.
 */
class SonarAppState(private val scope: CoroutineScope) {
    private val initialChatSnapshotBlob = SonarCore.loadBlob(CHAT_SNAPSHOT_BLOB_KEY)
    private val initialChatSnapshot = decodeChatSnapshot(initialChatSnapshotBlob)
    private val initialChatSnapshotLatest = decodeChatSnapshotLatest(initialChatSnapshotBlob)
    private val initialGroupFoldMap = decodeGroupFoldMap(SonarCore.loadBlob(GROUP_FOLDS_BLOB_KEY))
    private val initialFoldedGroupIds: Set<String> = initialChatSnapshot.first
        .mapTo(hashSetOf()) { it.id }
        .let { activeChatIds -> initialGroupFoldMap.keys.filterTo(hashSetOf()) { it in activeChatIds } }
    // Local-first: the account npub is public and stable — restore it from the
    // last session so chat titles/dedupe can identify "me" BEFORE the core
    // starts (SonarCore.start() re-derives and overwrites it authoritatively).
    var npub by mutableStateOf(SonarCore.loadBlob(NPUB_BLOB_KEY))
        private set
    var started by mutableStateOf(false)
        private set
    var connecting by mutableStateOf(false)
        private set
    /** True only after mesh storage and the encrypted Marmot database have been
     *  combined into one coherent local Home model. Relay state is irrelevant. */
    var homeMessagesHydrated by mutableStateOf(false)
        private set
    private var localCoreReady = false
    var chats by mutableStateOf<List<SonarChat>>(initialChatSnapshot.first)
        private set
    /** Monotonic counter bumped whenever [chatSnapshotMessagesByChat] is
     *  reassigned. Feeds the [visibleChats] memo key so the dedupe ordering
     *  (which depends on per-chat latest ts) re-runs when the snapshot changes. */
    private var snapshotVersion = 0
    private var chatSnapshotMessagesByChatBacking: Map<String, List<SonarMsg>> = initialChatSnapshot.second
    private var chatSnapshotMessagesByChat: Map<String, List<SonarMsg>>
        get() = chatSnapshotMessagesByChatBacking
        set(value) {
            if (value !== chatSnapshotMessagesByChatBacking) {
                chatSnapshotMessagesByChatBacking = value
                snapshotVersion++
            }
        }
    /** Thread-style local sort metadata restored before the encrypted core opens.
     *  Message bodies remain in the core database; this map only prevents the
     *  mixed mesh/Marmot Home list from treating every restored Marmot row as 0. */
    private var chatSnapshotLatestByChat: Map<String, Long> = initialChatSnapshotLatest

    private fun localLatestTs(chatId: String): Long =
        chatSnapshotMessagesByChat[chatId]?.lastOrNull()?.tsSecs
            ?: chatSnapshotLatestByChat[chatId]
            ?: 0L
    /** Pending 1:1 secure chats keyed by local id (`npub:…`). Value carries
     *  the peer npub plus [PendingMarmotDirect.createdAtSecs] so the Home list
     *  can sort by creation time (iOS `pending.createdAt` / `dmRows` parity)
     *  instead of treating them as epoch-zero after the recency merge. */
    private var pendingMarmotChatNpubs by mutableStateOf<Map<String, PendingMarmotDirect>>(emptyMap())
    private var pendingMarmotGroups by mutableStateOf<Map<String, PendingMarmotGroup>>(emptyMap())
    var groupInvites by mutableStateOf<List<SonarGroupInvite>>(emptyList())
        private set
    private val pendingInviteTokens = mutableListOf<String>()
    /** Resolved kind-0 profiles by npub — fills human names for Marmot members.
     *  Normalized on load so legacy key formats can't miss lookups (which would
     *  paint npubs until a relay re-fetch — a local-first violation). */
    var profilesByNpub by mutableStateOf(
        normalizedProfileCache(decodeProfileCache(SonarCore.loadBlob(PROFILE_CACHE_BLOB_KEY)))
    )
        private set
    private var socialStateBacking by mutableStateOf(decodeSonarSocialState(SonarCore.loadBlob(SOCIAL_STATE_BLOB_KEY)))
    /** Bumped on every [socialState] reassignment so memo keys can compare an
     *  Int instead of hashing the four favorite/blocked Sets on every read. */
    private var socialVersion = 0
    private var socialState: SonarSocialState
        get() = socialStateBacking
        set(value) { socialStateBacking = value; socialVersion++ }
    private val profileFetches = mutableSetOf<String>()
    private val profileFetchedAt = mutableMapOf<String, Long>()
    /** Last kind-0 fetch MISS per npub — throttles per-render refetch spam. */
    private val profileMissedAt = mutableMapOf<String, Long>()

    init {
        if (initialChatSnapshotBlob.isNotEmpty()) {
            persistChatSnapshot()
        }
    }

    /** Public Sonar descriptors by raw npub hex, used for out-of-BLE call parity. */
    var sonarDescriptorsByNpubHex by mutableStateOf<Map<String, SonarDescriptor>>(emptyMap())
        private set
    private val sonarDescriptorFetches = mutableSetOf<String>()
    private val sonarDescriptorFetchedAt = mutableMapOf<String, Long>()
    private val sonarDescriptorMissedAt = mutableMapOf<String, Long>()
    private var stack by mutableStateOf<List<Screen>>(listOf(Screen.Home))
    val screen: Screen get() = stack.last()

    var dark by mutableStateOf(SonarCore.isDark())
        private set
    var discoverNewPeople by mutableStateOf(SonarCore.loadBlob("pref.$BLE_DISCOVER_NEW_PEOPLE_PREF").let { it.isEmpty() || it == "1" })
        private set
    var batterySaving by mutableStateOf(BatterySaver.enabled())
        private set

    var callOverlay = false

    fun push(s: Screen) {
        if (s is Screen.Chat && (screen as? Screen.Chat)?.id != s.id) {
            cleanupPreviewTempFiles()
        }
        if (callOverlay && s is Screen.Call) return
        stack = stack + s
    }

    private fun popCallScreenIfNeeded() {
        if (screen is Screen.Call && stack.size > 1) stack = stack.dropLast(1)
    }
    fun toggleDark() { dark = !dark; SonarCore.setDark(dark) }

    fun wipe() {
        scope.launch {
            cancelPendingMarmotSetups()
            cancelPendingMarmotGroupSetups()
            WalletBridge.shutdown()
            UnifyRadio.stopScanning()
            UnifyRadio.stopAdvertising()
            unifyOffer = null; unifyPeers = emptyList()
            MeshRadio.setMeshNickname("")
            MeshRadio.setLocalSonarAnnounce(null); sonarPeerProfiles = emptyMap()
            linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
            meshChats.clear(); meshChatNames.clear(); meshDmRows = emptyList(); meshBroadcast = emptyList()
            foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            persistLinks(); persistLinkCaps(); persistGroupFolds()
            updateBleDiscoveryPolicy()
            sonarDescriptorsByNpubHex = emptyMap()
            sonarDescriptorFetches.clear(); sonarDescriptorFetchedAt.clear(); sonarDescriptorMissedAt.clear()
            publishedSonarDescriptor = false; publishedSonarDescriptorBolt12Offer = null; publishingSonarDescriptor = false
            needsSonarDescriptorPublish = false
            rawMeshPeerIds = emptySet(); meshPeerFirstSeenMs.clear(); pendingCapabilityRefreshPeers.clear()
            profilesByNpub = emptyMap(); profileFetches.clear()
            socialState = SonarSocialState(); persistSocialState()
            pendingMarmotChatNpubs = emptyMap()
            pendingMarmotGroups = emptyMap()
            pendingDirectMarmotSends.clear()
            pendingMarmotGroupSends.clear()
            outbox.clear()
            MessageStore.wipe()
            SonarCore.wipe()
            stack = listOf(Screen.Home)
            chats = emptyList(); chatSnapshotMessagesByChat = emptyMap(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); groupInvites = emptyList(); messages = emptyList()
            clearChatSnapshot()
            onboarded = false; nick = ""; npub = ""; started = false
            localCoreReady = false; homeMessagesHydrated = false
            walletState = WalletState.NotConfigured
            presenceByGeohash = emptyMap()
            payLedger = SonarPayLedger(); payVersion++
            PaymentActivityStore.wipe() // iOS wipes both payment ledgers together
            mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
            callLogs.clear(); callVersion++
            resetCallState()
            pollJob?.cancel(); pollJob = null
            stopMarmotWakeLoop()
        }
    }

    /** Tear down call state on wipe so calling rebinds cleanly after re-onboarding
     *  (the node is recreated, so the iroh endpoint must be re-bound). */
    private fun resetCallState() {
        callTicker?.cancel(); callTicker = null
        CallAudioRoute.configure(active = false, speakerOn = false)
        activeCall = null
        callStarted = false
        scannedCall.clear()
    }
    /** Erase every conversation — BLE-mesh DMs, public/channel transcripts and
     *  White Noise (Marmot) secure chats — WITHOUT logging the user out. The
     *  identity (npub/nsec), nickname, onboarding and wallet are preserved; only
     *  message history is removed. Use this to start fresh (e.g. drop a broken
     *  Marmot group) without re-running onboarding. Mirrors iOS `eraseAllChats`. */
    fun eraseAllChats() {
        scope.launch {
            cancelPendingMarmotSetups()
            cancelPendingMarmotGroupSetups()
            // Local transcripts on disk (mesh DMs, channels, geo DMs).
            MessageStore.wipe()
            // In-memory conversation state.
            meshChats.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); pendingDirectMarmotSends.clear(); pendingMarmotGroupSends.clear(); outbox.clear()
            persistMeshNames() // clear the on-disk name cache too, else boot resurrects erased names
            pendingMarmotChatNpubs = emptyMap()
            pendingMarmotGroups = emptyMap()
            linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
            persistLinks(); persistLinkCaps(); persistGroupFolds()
            profilesByNpub = emptyMap(); profileFetches.clear(); persistProfileCache()
            foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            meshBroadcast = emptyList(); meshDmRows = emptyList()
            updateBleDiscoveryPolicy()
            messages = emptyList(); channelMsgs = emptyList(); chats = emptyList(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); clearChatSnapshot()
            lastWnGroups = -1; lastWnMsgs = -1
            // ⚡PAY coins live inside the erased chats — reset the ledger. The
            // Lightning wallet seed/balance is separate and is NOT touched.
            // iOS eraseChatsKeepIdentity also wipes the activity ledger.
            payLedger = SonarPayLedger(); persistPay(); payVersion++
            PaymentActivityStore.wipe()
            mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
            callLogs.clear(); callVersion++
            lastSeenTs.clear(); lastNotifiedTs.clear(); seededSeen = false
            scanWatermark.clear()
            // White Noise / Marmot DB: wipe + reconnect with the SAME identity.
            runCatching { SonarCore.eraseChats() }
            localCoreReady = true
            homeMessagesHydrated = true
            // The node is recreated → re-bind the iroh call endpoint on next use.
            resetCallState()
            ensureCallStarted()
            refreshChats()
            stack = listOf(Screen.Home)
            toast = "All chats erased"
        }
    }

    var messages by mutableStateOf<List<SonarMsg>>(emptyList())
        private set
    var unreadByChat by mutableStateOf<Map<String, Long>>(emptyMap())
        private set

    // ── Mocked voice/video call log (in-memory only) ──
    /** Call records per chat id, merged into that DM's transcript by timestamp. */
    private val callLogs = mutableMapOf<String, MutableList<CallRecord>>()
    /** Bumped on every call-log change so the open chat recomposes. */
    var callVersion by mutableStateOf(0)
        private set

    /** Call-log records for [chatId] (oldest first). */
    fun callRecords(chatId: String): List<CallRecord> = callLogs[chatId].orEmpty()

    // ── Real P2P voice calls (iroh transport; ☎CALL over the chat) ──
    /** The in-flight call the [CallScreen] renders, or null. [phase] tracks the
     *  engine state; [connectedSecs] is the live duration once Connected. */
    var activeCall by mutableStateOf<ActiveCall?>(null)
        private set
    private var callStarted = false
    private var callLoopRunning = false
    private var callTicker: kotlinx.coroutines.Job? = null
    private var meshRealtimeLoopRunning = false
    /** Live Marmot drain loop job (see [startMarmotWakeLoop]). Cancelled on
     *  [wipe] / account restore so a dead node cannot keep a parked waiter. */
    private var marmotWakeJob: Job? = null
    private var pollJob: Job? = null
    /** Consumer of the event-driven housekeeping cycle. Triggered by the core
     *  `conversationChanged` flow (primary) and a slow heartbeat (fallback);
     *  the [housekeepingTrigger] channel conflates bursts into one pass. */
    private var housekeepingJob: Job? = null
    /** Conflated trigger for [runHousekeepingCycle]: many signals within one
     *  cycle collapse to a single trailing run (Signal-style: react to database
     *  invalidation, don't busy-poll). */
    private val housekeepingTrigger = Channel<Unit>(Channel.CONFLATED)
    private val refreshMutex = Mutex()
    private var refreshRunning = false
    private var refreshPending = false
    private var refreshCompletion: CompletableDeferred<Unit>? = null
    /** Ids of ☎CALL control messages already routed to the engine (dedup). */
    private val scannedCall = mutableSetOf<String>()
    /** Per-chat high-water mark of the newest message ts we have already fetched
     *  a page for and scanned for ☎CALL / pay lines. The cheap
     *  `conversationSummaries()` probe compares against this to skip the
     *  expensive `messagesPage` fetch for chats whose latest ts hasn't moved. */
    private val scanWatermark = HashMap<String, ScanMark>()

    /** Bind the iroh endpoint once + start the event loop (idempotent). */
    private suspend fun ensureCallStarted() {
        if (callStarted) return
        runCatching { SonarCore.callStart() }
            .onSuccess { callStarted = true; startCallLoop(); sonarLog("SonarCall", "call endpoint bound") }
            .onFailure { sonarLog("SonarCall", "callStart FAILED: ${it.message}") }
    }

    /** Place an outgoing call from [chatId]: register it, push the call screen,
     *  and send the ☎CALL OFFER (with our dialable address) over BLE when live,
     *  otherwise over the folded White Noise group for the same Sonar peer. */
    fun placeCall(chatId: String, peerName: String, video: Boolean) {
        if (activeCall != null) { toast = "Already in a call"; return }
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before calling."; return }
        if (!canCall(chatId)) { toast = "No call route to this Sonar peer yet."; return }
        val callId = randomMeshId()
        // Show the ringing screen IMMEDIATELY so the tap is responsive; the iroh
        // setup (bind/offer) runs below. (ensureCallStarted is idempotent — it
        // guards on callStarted, so unlike the old iOS path it never re-binds.)
        // iOS parity: video defaults to speaker, voice to earpiece (+ proximity).
        CallAudioRoute.configure(active = true, speakerOn = video, voiceProximity = !video)
        activeCall = ActiveCall(
            callId, chatId, peerName, video, incoming = false, phase = SonarCallState.Ringing,
            speakerOn = video, camOn = video,
        )
        push(Screen.Call(chatId, peerName, video))
        scope.launch {
            ensureCallStarted()
            if (!callStarted) {
                toast = "Calling isn’t available right now"
                CallAudioRoute.configure(active = false, speakerOn = false)
                activeCall = null
                popCallScreenIfNeeded()
                return@launch
            }
            try {
                val addr = SonarCore.callLocalAddress()
                SonarCore.callPlace(callId, video)
                if (activeCall?.callId == callId && activeCall?.muted == true) {
                    runCatching { SonarCore.callSetMuted(callId, true) }
                }
                sonarLog("SonarCall", "TX OFFER callId=${callId.take(8)} video=$video addrLen=${addr.length} → $chatId")
                if (activeCall?.callId == callId) { // user may have ended already
                    val sent = sendCallControl(chatId, SonarCore.callEncodeOffer(callId, video, addr, SonarClock.nowSecs()))
                    if (!sent) {
                        runCatching { SonarCore.callHangup(callId) }
                        if (activeCall?.callId == callId) {
                            CallAudioRoute.configure(active = false, speakerOn = false)
                            activeCall = null
                            popCallScreenIfNeeded()
                        }
                    }
                }
            } catch (e: Throwable) {
                toast = "call failed: ${e.message}"
                if (activeCall?.callId == callId) {
                    CallAudioRoute.configure(active = false, speakerOn = false)
                    activeCall = null
                    popCallScreenIfNeeded()
                }
            }
        }
    }

    /** Accept the incoming call: send ANSWER|accept (with our address), then dial. */
    fun acceptCall() {
        val c = activeCall ?: return
        activeCall = c.copy(phase = SonarCallState.Connecting)
        CallAudioRoute.configure(active = true, speakerOn = c.speakerOn, voiceProximity = !c.video)
        scope.launch {
            try {
                val addr = SonarCore.callLocalAddress()
                val sent = sendCallControl(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Accept, addr))
                if (!sent) {
                    runCatching { SonarCore.callHangup(c.callId) }
                    failAccept(c)
                    return@launch
                }
                if (activeCall?.callId == c.callId && activeCall?.muted == true) {
                    runCatching { SonarCore.callSetMuted(c.callId, true) }
                }
                sonarLog("SonarCall", "TX ANSWER accept + dialing callId=${c.callId.take(8)}")
                SonarCore.callAccept(c.callId)
                sonarLog("SonarCall", "callAccept returned (dialed) callId=${c.callId.take(8)}")
            } catch (e: Throwable) {
                sonarLog("SonarCall", "accept FAILED: ${e.message}")
                toast = "couldn’t accept: ${e.message}"
                // Mirror placeCall's failure teardown — without this a thrown
                // callAccept() leaves MODE_IN_COMMUNICATION + the proximity
                // lock held with the UI stuck in Connecting (no terminal
                // engine event ever finalizes a call the engine never had).
                runCatching { SonarCore.callHangup(c.callId) }
                failAccept(c)
            }
        }
    }

    /** Shared accept-failure teardown: release audio/proximity, drop the call. */
    private fun failAccept(c: ActiveCall) {
        if (activeCall?.callId != c.callId) return
        CallAudioRoute.configure(active = false, speakerOn = false)
        activeCall = null
        popCallScreenIfNeeded()
    }

    /** Decline incoming call: dismiss immediately (Signal pattern), then engine
     *  cleanup in the background. */
    fun declineCall() {
        val c = activeCall ?: return
        callTicker?.cancel(); callTicker = null
        CallAudioRoute.configure(active = false, speakerOn = false)
        callLogs.getOrPut(c.chatId) { mutableListOf() }.add(
            CallRecord(video = c.video, mine = false, durSecs = 0, tsSecs = SonarClock.nowSecs())
        )
        callVersion++
        activeCall = null
        popCallScreenIfNeeded()
        scope.launch {
            runCatching { sendCallControl(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Decline, "")) }
            runCatching { SonarCore.callHangup(c.callId) }
        }
    }

    /** Hang up an outgoing/connected call: dismiss immediately (Signal pattern),
     *  then engine teardown + END signal in the background. */
    fun hangupCall() {
        val c = activeCall ?: return
        callTicker?.cancel(); callTicker = null
        CallAudioRoute.configure(active = false, speakerOn = false)
        callLogs.getOrPut(c.chatId) { mutableListOf() }.add(
            CallRecord(video = c.video, mine = !c.incoming, durSecs = c.connectedSecs, tsSecs = SonarClock.nowSecs())
        )
        callVersion++
        activeCall = null
        popCallScreenIfNeeded()
        scope.launch {
            runCatching { SonarCore.callHangup(c.callId) }
            runCatching { sendCallControl(c.chatId, SonarCore.callEncodeEnd(c.callId, "hangup")) }
        }
    }

    fun toggleCallMute() {
        val c = activeCall ?: return
        val next = !c.muted
        activeCall = c.copy(muted = next)
        scope.launch {
            runCatching { SonarCore.callSetMuted(c.callId, next) }
                .onFailure { sonarLog("SonarCall", "mute toggle deferred/failed: ${it.message}") }
        }
    }

    fun toggleCallSpeaker() {
        val c = activeCall ?: return
        val next = !c.speakerOn
        activeCall = c.copy(speakerOn = next)
        // configure (not setSpeaker) so the proximity lock tracks earpiece
        // use: iOS drops proximity monitoring while the speaker is on.
        CallAudioRoute.configure(active = true, speakerOn = next, voiceProximity = !c.video && !next)
    }

    fun toggleCallCam() {
        val c = activeCall ?: return
        activeCall = c.copy(camOn = !c.camOn)
    }

    /** iOS parity (SonarCallScreen flip button): switch the local PiP camera. */
    fun flipCallCamera() {
        val c = activeCall ?: return
        activeCall = c.copy(frontCamera = !c.frontCamera)
    }

    private fun startCallLoop() {
        if (callLoopRunning) return
        callLoopRunning = true
        scope.launch {
            while (true) {
                val ev = try { SonarCore.callWaitEvent(20) } catch (e: Throwable) { delay(1000); null }
                if (ev != null) onCallEvent(ev)
            }
        }
    }

    private fun onCallEvent(ev: SonarCallEvent) {
        sonarLog("SonarCall", "engine event: ${ev.state} callId=${ev.callId.take(8)} dur=${ev.durationSecs}")
        val c = activeCall ?: return
        if (ev.callId != c.callId) return
        when (ev.state) {
            SonarCallState.Ringing -> {}
            SonarCallState.Connecting -> activeCall = c.copy(phase = SonarCallState.Connecting)
            SonarCallState.Connected -> { activeCall = c.copy(phase = SonarCallState.Connected, connectedSecs = 0); startCallTicker() }
            SonarCallState.Ended, SonarCallState.Failed, SonarCallState.Declined,
            SonarCallState.Busy, SonarCallState.Missed -> finalizeCall(c, ev)
        }
    }

    private fun startCallTicker() {
        callTicker?.cancel()
        callTicker = scope.launch {
            while (true) { delay(1000); activeCall?.let { activeCall = it.copy(connectedSecs = it.connectedSecs + 1) } }
        }
    }

    /** Record the call-log entry, clear state, and pop the call screen. */
    private fun finalizeCall(c: ActiveCall, ev: SonarCallEvent) {
        callTicker?.cancel(); callTicker = null
        CallAudioRoute.configure(active = false, speakerOn = false)
        val connected = ev.durationSecs > 0
        callLogs.getOrPut(c.chatId) { mutableListOf() }.add(
            CallRecord(video = c.video, mine = !c.incoming, durSecs = ev.durationSecs.toInt(), tsSecs = SonarClock.nowSecs())
        )
        callVersion++
        activeCall = null
        popCallScreenIfNeeded()
    }

    /** Scan [msgs] for ☎CALL control lines (deduped by message id) and route them
     *  to the engine. Called wherever new chat messages arrive (open chat, the
     *  global poll, mesh DMs) so a call rings even when the chat isn't open. */
    private fun processCallLines(chatId: String, msgs: List<SonarMsg>) {
        for (m in msgs) {
            if (m.id in scannedCall) continue
            scannedCall.add(m.id)
            if (m.mine) continue // our own control line — we already drive our side
            // Cheap prefilter (mirrors Rust CallControl::is_control): skip the FFI
            // for every non-☎CALL message so we don't re-marshal all chat each poll.
            if (!m.content.trimStart().startsWith("☎CALL")) continue
            val ctrl = SonarCore.callParseControl(m.content) ?: continue
            scope.launch { onCallControl(chatId, m, ctrl) }
        }
    }

    private suspend fun onCallControl(chatId: String, m: SonarMsg, ctrl: SonarCallControl) {
        val callChatId = callChatIdFor(chatId)
        sonarLog("SonarCall", "RX ${ctrl::class.simpleName} from $chatId as $callChatId (started=$callStarted)")
        if (isContactBlocked(callChatId)) {
            sonarLog("SonarCall", "ignoring blocked call control chatId=$callChatId")
            return
        }
        if (ctrl is SonarCallControl.Offer && !canCall(callChatId)) {
            if (shouldDeferOfferForSonarDescriptor(callChatId)) {
                sonarLog("SonarCall", "deferring offer until Sonar descriptor lookup completes chatId=$chatId folded=$callChatId")
                scannedCall.remove(m.id) // retry on the next scan pass once the fetch lands
                return
            }
            sonarLog("SonarCall", "ignoring offer without Sonar call route chatId=$chatId folded=$callChatId")
            runCatching { sendCallControl(chatId, SonarCore.callEncodeAnswer(ctrl.callId, SonarAnswer.Decline, "")) }
            return
        }
        ensureCallStarted()
        if (!callStarted) {
            sonarLog("SonarCall", "ignoring call control because call endpoint is unavailable")
            if (ctrl is SonarCallControl.Offer) {
                runCatching { sendCallControl(callChatId, SonarCore.callEncodeAnswer(ctrl.callId, SonarAnswer.Decline, "")) }
            }
            return
        }
        when (ctrl) {
            is SonarCallControl.Offer -> {
                if (activeCall != null) { // busy: auto-decline
                    runCatching { sendCallControl(callChatId, SonarCore.callEncodeAnswer(ctrl.callId, SonarAnswer.Busy, "")) }
                    return
                }
                runCatching { SonarCore.callIncomingOffer(ctrl.callId, ctrl.addrB64, ctrl.video) }
                // A stale offer (peer rang while we were offline) is a missed call.
                if (SonarClock.nowSecs() - ctrl.unixSecs > 60) {
                    runCatching { SonarCore.callHangup(ctrl.callId) }
                    callLogs.getOrPut(callChatId) { mutableListOf() }
                        .add(CallRecord(video = ctrl.video, mine = false, durSecs = 0, tsSecs = SonarClock.nowSecs()))
                    callVersion++
                    return
                }
                val name = callPeerName(callChatId)
                // iOS parity (SNActiveCall(speakerOn: video)): video rings on
                // speaker with the camera armed; voice rings for the earpiece.
                activeCall = ActiveCall(
                    ctrl.callId, callChatId, name, ctrl.video, incoming = true, phase = SonarCallState.Ringing,
                    speakerOn = ctrl.video, camOn = ctrl.video,
                )
                notifyIncoming(
                    idKey = callChatId,
                    conversationTitle = name,
                    content = m.content,
                    forcedKind = SonarNotificationKind.Call,
                    senderName = name,
                )
                push(Screen.Call(callChatId, name, ctrl.video))
            }
            is SonarCallControl.Answer ->
                if (activeCall?.callId == ctrl.callId) runCatching { SonarCore.callAnswer(ctrl.callId, ctrl.answer, ctrl.addrB64) }
            is SonarCallControl.Cancel, is SonarCallControl.End ->
                if (activeCall?.callId == ctrl.callId) runCatching { SonarCore.callHangup(ctrl.callId) }
        }
    }

    /** A human name for the chat the incoming call arrived on. */
    private fun callPeerName(chatId: String): String {
        val folded = callChatIdFor(chatId)
        if (isMeshChat(folded)) {
            val peerId = meshPeerId(folded)
            val group = npubRawFor(peerId)?.let { marmotGroupForNpub(it) }
            return foldedPeerName(peerId, group)
        }
        val mine = canonicalProfileKey(npub)
        return chats.firstOrNull { it.id == chatId }
            ?.members?.firstOrNull { canonicalProfileKey(it) != mine && it.isNotBlank() }
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName ?: (it.take(10) + "…") } ?: "secure chat"
    }
    /** In-memory BLE-mesh DM transcripts, keyed by bitchat peerID. Mesh chats
     *  don't live in the Rust core (that's Marmot/Nostr) — they ride the Noise
     *  link, so the app holds them. Chat id on the nav stack is "mesh:<peerId>". */
    private var meshChats = mutableMapOf<String, List<SonarMsg>>()
    // Observability for the White Noise (Marmot) fallback (logged in poll()).
    private var lastWnGroups = -1
    private var lastWnMsgs = -1
    /** Mesh DM conversations shown in the home "Messages" list (observable so the
     *  list updates when a DM arrives from a peer we haven't opened yet). */
    var meshDmRows by mutableStateOf<List<MeshDmRow>>(emptyList())
        private set
    /** Remembered display names for mesh peers we've chatted with (they can leave
     *  range, so we can't always re-derive the name from the live radar list). */
    private val meshChatNames = mutableMapOf<String, String>()

    /** Remember a mesh peer's display name and persist it (change-only) so
     *  restart paints names instead of key fallbacks — local-first parity with
     *  iOS, whose nickname cache survives relaunch. */
    private fun rememberMeshName(peerId: String, name: String) {
        // Never remember a key-shaped fallback ("mesh·…", "npub1…") as a real
        // name: callers pass through row labels that can themselves be
        // fallbacks, and a persisted fallback MASKS later resolution (the
        // remembered name short-circuits profile/announce lookups).
        if (name.isKeyFallbackName()) return
        if (meshChatNames[peerId] == name) return
        meshChatNames[peerId] = name
        persistMeshNames()
    }

    private fun persistMeshNames() {
        // Value is hex-encoded (like the kind-0 profile cache): a peer's
        // advertised nickname is arbitrary attacker-controlled unicode, so a
        // raw newline would inject a fake `peerId=name` line on reload and
        // poison a DIFFERENT peer's label. Hex framing makes that impossible
        // and preserves emoji/whitespace byte-for-byte.
        SonarCore.saveBlob(
            MESH_NAMES_BLOB_KEY,
            meshChatNames.entries.joinToString("\n") { "${it.key}=${hexEncodeUtf8(it.value)}" },
        )
    }

    private fun loadMeshNames() {
        SonarCore.loadBlob(MESH_NAMES_BLOB_KEY).lineSequence().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0) {
                val raw = line.substring(i + 1)
                // Tolerate legacy plain-text blobs (pre-hex builds): decode
                // hex, fall back to the raw value if it isn't hex.
                val name = hexDecodeUtf8(raw) ?: raw
                // Drop key-shaped fallbacks persisted by earlier builds — they
                // mask real resolution.
                if (!name.isKeyFallbackName()) meshChatNames.putIfAbsent(line.substring(0, i), name)
            }
        }
    }
    /** Public BLE "Mesh" channel transcript (broadcast messages, not Nostr). */
    private var meshBroadcast = listOf<SonarChannelMsg>()
    var channels by mutableStateOf(SonarCore.joinedChannels())
        private set
    var channelMsgs by mutableStateOf<List<SonarChannelMsg>>(emptyList())
        private set
    var meshPeers by mutableStateOf<List<MeshPeer>>(emptyList())
        private set
    private var rawMeshPeerIds: Set<String> = emptySet()
    private val meshPeerFirstSeenMs = mutableMapOf<String, Long>()
    private val pendingCapabilityRefreshPeers = mutableSetOf<String>()
    /** Nearby Unify Wallet users (payments-only, gold badge on the radar). */
    var unifyPeers by mutableStateOf<List<UnifyPeer>>(emptyList())
        private set
    /** Sonar Discovery profiles received over mesh links, keyed by peer id. */
    var sonarPeerProfiles by mutableStateOf<Map<String, SonarAnnounce>>(emptyMap())
        private set

    /** The Sonar Discovery profile for a mesh peer (its BLE id), if any. */
    fun sonarProfile(peerId: String): SonarAnnounce? = sonarPeerProfiles[peerId]

    private fun refreshSonarDiscoveryProfiles() {
        sonarPeerProfiles = MeshRadio.sonarPeers()
            .mapNotNull { (id, raw) -> SonarAnnounce.decode(raw)?.let { id to it } }
            .toMap()
        sonarPeerProfiles.forEach { (peerId, ann) -> rememberLink(peerId, ann) }
        // 0x53 profiles / links feed the capability-settle hold in [visibleChats].
        bumpHoldInputs()
    }

    private fun updateMeshPeersFromRadio(nowMs: Long = SonarClock.nowMillis()) {
        val rawPeers = MeshRadio.peers()
        val previousPeerIds = rawMeshPeerIds
        rawMeshPeerIds = rawPeers.map { meshPeerId(it.id) }.toSet()
        meshPeerFirstSeenMs.keys.retainAll(rawMeshPeerIds + meshChats.keys + linkByFp.keys)
        meshPeers = rawPeers.filter { peer ->
            val peerId = meshPeerId(peer.id)
            if (isMeshContactBlocked(peerId)) return@filter false
            if (peer.name.isNotBlank()) rememberMeshName(peerId, peer.name)
            val first = meshPeerFirstSeenMs.getOrPut(peerId) { nowMs }
            val hasProfile = peer.sonar || sonarPeerProfiles.containsKey(peerId) || linkByFp.containsKey(peerId)
            val hasMessages = meshChats[peerId]?.isNotEmpty() == true
            val wait = shouldWaitForCapabilities(first, nowMs, hasProfile, hasMessages)
            if (wait) scheduleCapabilitySettleRefresh(peerId, first, nowMs)
            !wait
        }
        // When a peer (re)appears on the BLE mesh, flush any queued messages.
        // This mirrors iOS MessageRouter's flush-on-transport-available path.
        for (peerId in rawMeshPeerIds) {
            if (peerId !in previousPeerIds && outbox.contains(peerId)) {
                flushOutbox(peerId)
            }
        }
        // Mesh peer set / first-seen / names feed the [visibleChats] hold filter.
        bumpHoldInputs()
    }

    private fun scheduleCapabilitySettleRefresh(peerId: String, firstSeenMs: Long, nowMs: Long) {
        val remaining = CAPABILITY_SETTLE_MS - (nowMs - firstSeenMs)
        if (remaining <= 0 || !pendingCapabilityRefreshPeers.add(peerId)) return
        scope.launch {
            delay(remaining + 50)
            pendingCapabilityRefreshPeers.remove(peerId)
            refreshSonarDiscoveryProfiles()
            updateMeshPeersFromRadio()
            recomputeConversations()
        }
    }

    private fun shouldHoldStandaloneMarmotChat(chat: SonarChat, nowMs: Long = SonarClock.nowMillis()): Boolean {
        if (!isDirectMarmotChat(chat)) return false
        val title = canonicalConversationTitle(chatTitle(chat)).takeIf { it.isNotEmpty() } ?: return false
        // Hold if a name-matched peer is still settling capabilities.
        val nameMatched = meshChatNames.any { (peerId, name) ->
            canonicalConversationTitle(name) == title &&
                shouldWaitForCapabilities(
                    firstSeenMs = meshPeerFirstSeenMs[peerId],
                    nowMs = nowMs,
                    hasProfile = sonarPeerProfiles.containsKey(peerId) || linkByFp.containsKey(peerId),
                    hasMessages = false,
                ).also { if (it) scheduleCapabilitySettleRefresh(peerId, meshPeerFirstSeenMs[peerId] ?: nowMs, nowMs) }
        }
        if (nameMatched) return true
        if (!hasRecentMarmotActivityForCapabilitySettle(localLatestTs(chat.id), nowMs)) {
            return false
        }
        // Also hold if ANY mesh peer is still within its settle window and
        // hasn't resolved capabilities yet — the pending 0x53 announce may be
        // the one that provides the name we need to fold by.  This broad fallback
        // is limited to fresh Marmot activity so old standalone rows do not blink.
        return meshPeerFirstSeenMs.any { (peerId, firstMs) ->
            shouldWaitForCapabilities(
                firstSeenMs = firstMs,
                nowMs = nowMs,
                hasProfile = sonarPeerProfiles.containsKey(peerId) || linkByFp.containsKey(peerId),
                hasMessages = meshChats[peerId]?.isNotEmpty() == true,
            ).also { if (it) scheduleCapabilitySettleRefresh(peerId, firstMs, nowMs) }
        }
    }

    /** Durable BLE-fingerprint → Nostr-npub(hex) links, learned from 0x53 Sonar
     *  announces and PERSISTED (blob "sonar.links"). This is what makes one
     *  conversation survive the transport switch: a Sonar peer met over Bluetooth
     *  keeps the SAME thread when they leave range and we reach them over White
     *  Noise (internet) — and after an app restart. Mirrors iOS's persisted
     *  Noise↔Nostr mapping (FavoritesPersistenceService / sonarProfilesByFingerprint). */
    private val linkByFp = mutableMapOf<String, String>()
    /** Persisted 0x53 capability bits for the same fingerprint→npub links. Android
     *  only keeps live Sonar announces in memory, so this preserves CAP_CALLS after
     *  the peer leaves BLE range or the app restarts. */
    private val linkCapsByFp = mutableMapOf<String, Int>()

    /** Marmot groups currently FOLDED into a BLE-mesh DM row (same person via
     *  [linkByFp]) — hidden from the standalone White Noise list so a person never
     *  shows up twice. Display-only: the group still lives in [chats]. */
    private var foldedGroupIds by mutableStateOf<Set<String>>(initialFoldedGroupIds)
    /** Folded Marmot group id → mesh peer fingerprint. Kept with [foldedGroupIds]
     *  so openChat/refreshOpenDm can route a White Noise group back to the
     *  canonical mesh conversation even while BLE is unavailable. */
    private var foldedGroupPeerIds: Map<String, String> =
        initialGroupFoldMap.filterKeys { it in initialFoldedGroupIds }
    /** Persisted Marmot group id → mesh peer fingerprint. Unlike the ephemeral
     *  [foldedGroupPeerIds] (recomputed each cycle), this map survives BLE state
     *  changes and app restarts — matching iOS's `marmotGroupIdsByConversationId`.
     *  It acts as a durable fallback in [peerIdForMarmotGroup] so a conversation
     *  that was folded once stays folded even when BLE is off and the live profile
     *  lookup chain fails. */
    private val groupFoldMap = initialGroupFoldMap.toMutableMap()

    /** Memo cache for [visibleChats]. The home LazyColumn reads the getter on
     *  every recomposition, so recomputing dedupe/fold/pending each read burned
     *  CPU. We cache the result keyed by [VisibleChatsKey]; the getter returns
     *  the cached list in O(1) when nothing it depends on changed. */
    private var visibleChatsCacheKey: VisibleChatsKey? = null
    private var visibleChatsCache: List<SonarChat> = emptyList()

    /** Bumped whenever a hold-input map ([meshPeerFirstSeenMs], [meshChatNames],
     *  [sonarPeerProfiles], [linkByFp], [foldedGroupPeerIds]) changes, so the
     *  [visibleChats] memo re-runs the settle-hold filter. Call [bumpHoldInputs]
     *  from the mutation sites. */
    private var holdInputsVersion = 0
    private fun bumpHoldInputs() { holdInputsVersion++ }

    /** Reference-identity tracking for the immutable [chats] list: a fresh list
     *  object is assigned on every change, so an `!==` comparison detects it
     *  without hashing every chat. */
    private var lastChatsRef: List<SonarChat>? = null
    private var chatsIdentityCounter = 0

    private fun currentVisibleChatsKey(): VisibleChatsKey {
        val current = chats
        if (current !== lastChatsRef) {
            lastChatsRef = current
            chatsIdentityCounter++
        }
        return VisibleChatsKey(
            chatsIdentity = chatsIdentityCounter,
            foldedGroupIds = foldedGroupIds,
            pendingChatNpubs = pendingMarmotChatNpubs.mapValues { it.value.peerNpub },
            pendingGroupIds = pendingMarmotGroups.keys,
            socialVersion = socialVersion,
            snapshotVersion = snapshotVersion,
            ownNpub = npub,
            holdVersion = holdInputsVersion,
        )
    }

    /** White Noise chats to render on their own row: every Marmot group EXCEPT the
     *  ones folded into a mesh DM. The Messages list uses this instead of [chats].
     *
     *  Memoized: while no standalone chat is inside its brief capability-settle
     *  window, the result is cached keyed by [VisibleChatsKey]. If a hold is
     *  active (a newly-met peer is still settling, ≤ [CAPABILITY_SETTLE_MS]),
     *  the result is time-dependent so we recompute and skip the cache — that
     *  window is short and rare, so steady-state reads stay O(1). */
    val visibleChats: List<SonarChat> get() {
        val key = currentVisibleChatsKey()
        visibleChatsCacheKey?.let { if (it == key) return visibleChatsCache }
        var holdActive = false
        val standalone = chats.filterNot {
            val held = shouldHoldStandaloneMarmotChat(it)
            if (held) holdActive = true
            it.id in foldedGroupIds || held || isBlockedMarmotChat(it)
        }
        val result = pendingMarmotChats() + pendingMarmotGroupChats() + dedupeDirectMarmotChats(
            chats = standalone,
            ownNpub = npub,
            latestSecs = ::localLatestTs,
        )
        // Only cache the stable (no active settle window) computation. A held
        // chat can flip to visible purely by time passing, which the key can't
        // capture, so leave the cache untouched until the window closes.
        if (!holdActive) {
            visibleChatsCacheKey = key
            visibleChatsCache = result
        } else {
            visibleChatsCacheKey = null
        }
        return result
    }

    private fun pendingMarmotChats(): List<SonarChat> =
        pendingMarmotChatNpubs.mapNotNull { (id, pending) ->
            val peerNpub = pending.peerNpub
            val npubHex = canonicalNpubHex(peerNpub) ?: return@mapNotNull null
            if (marmotGroupForNpub(npubHex.hexToBytesOrEmpty()) != null) return@mapNotNull null
            if (socialState.isBlockedNostr(npubHex)) return@mapNotNull null
            SonarChat(id = id, name = "", members = listOf(npub, peerNpub))
        }

    /** Creation time for a pending secure chat/group, used as the Home-list
     *  sort key while setup is in flight (iOS `lastDate = pending.createdAt`). */
    private fun pendingCreatedAtSecs(chatId: String): Long? =
        pendingMarmotChatNpubs[chatId]?.createdAtSecs
            ?: pendingMarmotGroups[chatId]?.createdAtSecs

    /** Upsert a pending 1:1 row, preserving [PendingMarmotDirect.createdAtSecs]
     *  if the same id is re-armed during setup retries. */
    private fun putPendingMarmotChat(pendingId: String, peerNpub: String) {
        val existing = pendingMarmotChatNpubs[pendingId]
        val created = existing?.createdAtSecs ?: SonarClock.nowSecs()
        pendingMarmotChatNpubs = pendingMarmotChatNpubs + (
            pendingId to PendingMarmotDirect(peerNpub = peerNpub, createdAtSecs = created)
            )
    }

    private fun pendingMarmotGroupChats(): List<SonarChat> =
        pendingMarmotGroups.entries.sortedByDescending { it.value.createdAtSecs }.map { (id, pending) ->
            SonarChat(id = id, name = pending.name, members = listOf(npub) + pending.members)
        }

    private fun pendingMarmotChatId(peer: String): String? {
        val clean = canonicalProfileKey(peer)
        return if (canonicalNpubHex(clean) != null) PENDING_MARMOT_CHAT_PREFIX + clean else null
    }

    private fun pendingMarmotNpub(chatId: String): String? =
        chatId.takeIf { it.startsWith(PENDING_MARMOT_CHAT_PREFIX) }
            ?.drop(PENDING_MARMOT_CHAT_PREFIX.length)
            ?.takeIf { canonicalNpubHex(it) != null }

    private fun isPendingMarmotChat(chatId: String): Boolean =
        pendingMarmotNpub(chatId) != null

    private fun isPendingMarmotGroup(chatId: String): Boolean =
        chatId.startsWith(PENDING_MARMOT_GROUP_PREFIX) && pendingMarmotGroups.containsKey(chatId)

    fun isPendingSecureChat(chatId: String): Boolean =
        isPendingMarmotChat(chatId) || isPendingMarmotGroup(chatId)

    private fun persistSocialState() {
        SonarCore.saveBlob(SOCIAL_STATE_BLOB_KEY, encodeSonarSocialState(socialState))
    }

    fun isFavorite(peerId: String): Boolean =
        socialState.isFavoritePeer(peerId)

    fun isMutualFavorite(peerId: String): Boolean =
        socialState.isMutualFavorite(peerId)

    fun isBlockedPeer(peerId: String): Boolean =
        isMeshContactBlocked(peerId)

    fun isBlockedNostrPubkey(value: String): Boolean =
        socialState.isBlockedNostr(value)

    fun isContactFavorite(chatId: String): Boolean =
        socialPeerIdForChat(chatId)?.let { isFavorite(it) } == true

    fun isContactBlocked(chatId: String): Boolean {
        socialPeerIdForChat(chatId)?.let { if (isBlockedPeer(it)) return true }
        socialNpubHexForChat(chatId)?.let { if (isBlockedNostrPubkey(it)) return true }
        return false
    }

    fun canFavoriteContact(chatId: String): Boolean =
        socialPeerIdForChat(chatId) != null

    fun toggleFavorite(peerId: String, name: String = "") {
        val key = normalizeSocialPeerId(peerId)
        setFavoritePeer(key, name, !socialState.isFavoritePeer(key))
    }

    fun setFavoritePeer(peerId: String, name: String = "", favorite: Boolean) {
        val key = normalizeSocialPeerId(peerId)
        if (favorite && isMeshContactBlocked(key)) {
            toast = "Unblock ${name.ifBlank { "this contact" }} before favoriting."
            return
        }
        socialState = socialState.withFavoritePeer(key, favorite)
        persistSocialState()
        sendFavoriteStatusNotification(key, favorite)
        toast = if (favorite) {
            "Added ${name.ifBlank { "contact" }} to favorites"
        } else {
            "Removed ${name.ifBlank { "contact" }} from favorites"
        }
        recomputeSociallyFilteredRows()
    }

    private fun sendFavoriteStatusNotification(peerId: String, favorite: Boolean) {
        val payload = buildString {
            append(if (favorite) FAVORITED_CONTROL else UNFAVORITED_CONTROL)
            npub.takeIf { it.isNotBlank() }?.let {
                append(":")
                append(it)
            }
        }
        MeshRadio.sendMeshDm(peerId, randomMeshId(), payload)
        val raw = npubRawFor(peerId) ?: return
        scope.launch {
            runCatching {
                SonarCore.sendDirectDm(
                    recipientHex = raw.toHexLower(),
                    senderPeerIdHex = MeshRadio.localPeerIdHex(),
                    recipientPeerIdHex = "",
                    messageId = randomMeshId(),
                    text = payload,
                )
            }.onFailure {
                sonarLog("SonarDirect", "favorite notify failed peer=${peerId.take(10)} err=${it.message}")
            }
        }
    }

    fun toggleFavoriteContact(chatId: String, name: String) {
        val peerId = socialPeerIdForChat(chatId)
        if (peerId == null) {
            toast = "Favorite works after meeting this contact over Bluetooth."
            return
        }
        toggleFavorite(peerId, name)
    }

    fun setContactBlocked(chatId: String, name: String, blocked: Boolean) {
        val peerId = socialPeerIdForChat(chatId)
        val npubHex = socialNpubHexForChat(chatId)
        if (peerId == null && npubHex == null) {
            toast = "No stable identity to block yet."
            return
        }
        if (peerId != null) setMeshContactBlocked(peerId, blocked)
        if (npubHex != null) socialState = socialState.withBlockedNostr(npubHex, blocked)
        persistSocialState()
        toast = if (blocked) "Blocked ${name.ifBlank { "contact" }}" else "Unblocked ${name.ifBlank { "contact" }}"
        recomputeSociallyFilteredRows()
        if ((screen as? Screen.Chat)?.id == chatId) {
            if (blocked) {
                messages = visibleMessagesForChat(chatId, messages)
            } else if (peerId != null && isMeshChat(chatId)) {
                scope.launch { refreshOpenDm(peerId) }
            } else {
                scope.launch {
                    setCurrentVisibleMessages(
                        chatId,
                        withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))),
                        processCalls = true,
                    )
                }
            }
        }
    }

    fun setPeerBlocked(peerId: String, name: String, blocked: Boolean) {
        val key = normalizeSocialPeerId(peerId)
        setMeshContactBlocked(key, blocked)
        persistSocialState()
        toast = if (blocked) "Blocked ${name.ifBlank { "contact" }}" else "Unblocked ${name.ifBlank { "contact" }}"
        recomputeSociallyFilteredRows()
        channelMsgs = visibleChannelMessages(channelMsgs)
        val chatId = meshChatId(key)
        if ((screen as? Screen.Chat)?.id == chatId) {
            if (blocked) {
                messages = visibleMessagesForChat(chatId, messages)
            } else {
                scope.launch { refreshOpenDm(key) }
            }
        }
    }

    fun setChannelAuthorBlocked(senderKey: String, name: String, blocked: Boolean) {
        val nostrKey = normalizeSocialNostrKey(senderKey)
        if (nostrKey != null) {
            socialState = socialState.withBlockedNostr(nostrKey, blocked)
        } else {
            val peerKey = normalizeSocialPeerId(senderKey)
            if (peerKey.isBlank()) {
                toast = "No stable key to block for ${name.ifBlank { "this author" }}."
                return
            }
            socialState = socialState.withBlockedPeer(peerKey, blocked)
            if (blocked) socialState = socialState.withFavoritePeer(peerKey, false)
        }
        persistSocialState()
        toast = if (blocked) "Blocked ${name.ifBlank { "channel author" }}" else "Unblocked ${name.ifBlank { "channel author" }}"
        recomputeSociallyFilteredRows()
        channelMsgs = visibleChannelMessages(channelMsgs)
        (screen as? Screen.GeoDm)?.let { geoDm ->
            if (
                geoDm.peerHex.equals(senderKey, ignoreCase = true) ||
                normalizeSocialNostrKey(geoDm.peerHex) == nostrKey ||
                normalizeSocialPeerId(geoDm.peerHex) == normalizeSocialPeerId(senderKey)
            ) {
                messages = visibleGeoDmMessages(geoDm.peerHex, messages)
                if (!blocked) scope.launch { refreshGeoDm(geoDm.geohash, geoDm.peerHex) }
            }
        }
    }

    fun isChannelAuthorBlocked(senderKey: String): Boolean {
        val nostrKey = normalizeSocialNostrKey(senderKey)
        return if (nostrKey != null) {
            socialState.isBlockedNostr(nostrKey)
        } else {
            socialState.isBlockedPeer(senderKey)
        }
    }

    fun isGeoDmBlocked(peerHex: String): Boolean =
        isChannelAuthorBlocked(peerHex)

    fun unblockChannelAuthor(senderKey: String, name: String = "") {
        if (normalizeSocialNostrKey(senderKey) == null && normalizeSocialPeerId(senderKey).isBlank()) {
            toast = "No stable key to unblock."
            return
        }
        setChannelAuthorBlocked(senderKey, name, blocked = false)
    }

    private fun recomputeSociallyFilteredRows() {
        updateMeshPeersFromRadio()
        refreshMeshDmRows()
    }

    private fun socialPeerIdForChat(chatId: String): String? =
        when {
            isMeshChat(chatId) -> meshPeerId(chatId)
            else -> peerIdForMarmotGroup(chatId)
        }

    private fun socialNpubHexForChat(chatId: String): String? {
        pendingMarmotNpub(chatId)?.let { pending ->
            canonicalNpubHex(pending)?.let { return it }
        }
        if (isPendingMarmotGroup(chatId)) return null
        val peerId = socialPeerIdForChat(chatId)
        if (peerId != null) npubRawFor(peerId)?.toHexLower()?.let { return it }
        marmotChatPeerNpubHex(chatId)?.let { return it }
        return normalizeSocialNostrKey(chatId)
    }

    private fun isBlockedMarmotChat(chat: SonarChat): Boolean =
        isDirectMarmotChat(chat) &&
            socialNpubHexForChat(chat.id)?.let { socialState.isBlockedNostr(it) } == true

    private fun visibleMessagesForChat(chatId: String, source: List<SonarMsg>): List<SonarMsg> =
        if (isMeshChat(chatId) && isMeshContactBlocked(meshPeerId(chatId))) emptyList()
        else source.filter { msg -> socialState.allowsChatMessage(chatId, msg.senderNpub, msg.mine) }

    private fun setCurrentVisibleMessages(chatId: String, source: List<SonarMsg>, processCalls: Boolean = false) {
        val visible = visibleMessagesForChat(chatId, source)
        messages = visible
        processPayLines(chatId, visible)
        if (processCalls) processCallLines(chatId, visible)
    }

    private fun visibleChannelMessages(source: List<SonarChannelMsg>): List<SonarChannelMsg> =
        source.filter { msg -> socialState.allowsChannelSender(msg.senderPubkey, msg.mine) }

    private fun visibleGeoDmMessages(peerHex: String, source: List<SonarMsg>): List<SonarMsg> =
        if (isGeoDmBlocked(peerHex)) source.filter { it.mine } else source

    private fun otherMembers(chat: SonarChat): List<String> {
        val mine = canonicalProfileKey(npub)
        return chat.members
            .map { canonicalProfileKey(it) }
            .filter { it != mine && it.isNotBlank() }
            .distinct()
    }

    fun isDirectMarmotChat(chat: SonarChat): Boolean =
        directMarmotPeerKey(chat, npub) != null

    private fun directMarmotPeerKey(chat: SonarChat): String? =
        directMarmotPeerKey(chat, npub)

    private fun duplicateDirectMarmotChats(chat: SonarChat): List<SonarChat> {
        val peerKey = directMarmotPeerKey(chat) ?: return listOf(chat)
        val groups = chats.filter { directMarmotPeerKey(it) == peerKey }
        return groups.ifEmpty { listOf(chat) }
    }

    private fun duplicateDirectMarmotChats(chatId: String): List<SonarChat> {
        val chat = chats.firstOrNull { it.id == chatId } ?: return emptyList()
        return duplicateDirectMarmotChats(chat)
    }

    private fun directMarmotChatIds(chatId: String): List<String> {
        val groups = duplicateDirectMarmotChats(chatId)
        return groups.map { it.id }.ifEmpty { listOf(chatId) }
    }

    private fun isSameDirectMarmotChat(leftId: String, rightId: String): Boolean {
        val left = chats.firstOrNull { it.id == leftId } ?: return false
        val right = chats.firstOrNull { it.id == rightId } ?: return false
        val leftKey = directMarmotPeerKey(left) ?: return false
        return leftKey == directMarmotPeerKey(right)
    }

    fun isMultiMemberChat(chatId: String): Boolean =
        if (isPendingMarmotChat(chatId)) false
        else if (isPendingMarmotGroup(chatId)) true
        else chats.firstOrNull { it.id == chatId }?.let { !isDirectMarmotChat(it) } == true

    fun canManageGroup(chatId: String): Boolean =
        !isPendingMarmotGroup(chatId) &&
            chats.firstOrNull { it.id == chatId }?.let { !isDirectMarmotChat(it) } == true

    fun hasDirectPaymentRoute(chatId: String): Boolean {
        if (directPaymentOffer(chatId) != null) return true
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val aliases = preferredMeshAliases(peerId)
            if (aliases.any { sonarProfile(it)?.speaksPay == true }) return true
            if (aliases.any { ((linkCapsByFp[it] ?: 0) and SonarAnnounce.CAP_PAY) != 0 }) return true
        }
        paymentNpubHex(chatId)?.let {
            if (sonarDescriptorsByNpubHex[it]?.bolt12Offer?.isNotBlank() == true) return true
        }
        return false
    }

    fun refreshDescriptorForChat(chatId: String) {
        val keys = mutableSetOf<String>()
        paymentNpubHex(chatId)?.let { keys.add(it.lowercase()) }
        callDescriptorNpubHex(chatId)?.let { keys.add(it.lowercase()) }
        keys.forEach { ensureSonarDescriptorHex(it) }
    }

    fun groupInviteContacts(excluding: Set<String> = emptySet()): List<GroupContact> {
        val excludedClean = excluding.map { it.trim() }.toSet() + setOf(npub).filter { it.isNotBlank() }
        val byNpub = linkedMapOf<String, GroupContact>()

        fun insert(title: String, subtitle: String, inviteNpub: String?) {
            val clean = inviteNpub?.trim().orEmpty()
            if (!clean.startsWith("npub1") || clean in excludedClean || clean in byNpub) return
            val display = title.ifBlank { profilesByNpub[canonicalProfileKey(clean)]?.bestName ?: shortNpub(clean) }
            byNpub[clean] = GroupContact(clean, display, subtitle, clean)
        }

        meshPeers.forEach { peer ->
            val peerId = meshPeerId(peer.id)
            insert(peer.name, "Nearby · Bluetooth", npubStringForPeer(peerId))
        }
        meshDmRows.forEach { row ->
            insert(row.name, "Known Sonar contact", npubStringForPeer(row.peerId))
        }
        chats.filter { isDirectMarmotChat(it) }.forEach { chat ->
            val other = otherMembers(chat).singleOrNull()
            insert(chatTitle(chat), "White Noise chat", other)
        }

        return byNpub.values.sortedBy { it.title.lowercase() }
    }

    fun groupMemberContacts(chatId: String): List<GroupContact> {
        val members = pendingMarmotGroups[chatId]?.members
            ?: chats.firstOrNull { it.id == chatId }?.let { otherMembers(it) }
            ?: emptyList()
        return members.map { member ->
            ensureProfile(member)
            val key = canonicalProfileKey(member)
            GroupContact(
                id = member,
                title = profilesByNpub[key]?.bestName ?: shortNpub(member),
                subtitle = shortNpub(member),
                npub = member,
            )
        }
    }

    fun allGroupMemberContacts(chatId: String): List<GroupContact> {
        val chat = chats.firstOrNull { it.id == chatId } ?: return emptyList()
        return chat.members
            .map { canonicalProfileKey(it) }
            .filter { it.isNotBlank() }
            .distinct()
            .map { member ->
                ensureProfile(member)
                val key = canonicalProfileKey(member)
                GroupContact(
                    id = member,
                    title = profilesByNpub[key]?.bestName ?: shortNpub(member),
                    subtitle = shortNpub(member),
                    npub = member,
                )
            }
    }

    fun groupMemberNpubs(chatId: String): Set<String> =
        pendingMarmotGroups[chatId]?.members?.toSet()
            ?: chats.firstOrNull { it.id == chatId }?.members.orEmpty().toSet()

    /** This peer's npub (32 raw bytes) if known — from a live 0x53 OR the persisted
     *  [linkByFp] (so it still resolves out of range / after restart). The bridge
     *  that unifies the BLE-Noise and White-Noise legs of one conversation. */
    private fun exactNpubRawFor(peerId: String): ByteArray? =
        sonarProfile(peerId)?.npub
            ?: linkByFp[peerId]?.hexToBytesOrEmpty()?.takeIf { it.size == 32 }

    /** Every historical/live Noise fingerprint known to represent the same npub. */
    private fun meshPeerAliases(peerId: String): List<String> {
        val identity = meshConversationIdentityKey(peerId, linkByFp[peerId])
        val candidates = buildSet {
            add(peerId)
            addAll(meshChats.keys)
            addAll(meshChatNames.keys)
            addAll(linkByFp.keys)
            addAll(rawMeshPeerIds)
            addAll(foldedGroupPeerIds.values)
            addAll(groupFoldMap.values)
        }
        return candidates
            .filter { meshConversationIdentityKey(it, linkByFp[it]) == identity }
            .sorted()
    }

    /** Alias groups for conversations that have a persisted mesh transcript.
     *  Include name/link/fold-only aliases too: the transcript may live under
     *  an old fingerprint while the stable fold target uses a newer one. */
    private fun meshConversationAliasGroups(): List<List<String>> {
        val candidates = buildSet {
            addAll(meshChats.keys)
            addAll(meshChatNames.keys)
            addAll(linkByFp.keys)
            addAll(foldedGroupPeerIds.values)
            addAll(groupFoldMap.values)
        }
        val messagePeerIds = meshChats.filterValues { it.isNotEmpty() }.keys
        return groupMeshConversationAliases(candidates, messagePeerIds, linkByFp)
    }

    private fun canonicalMeshPeerId(peerId: String): String =
        selectCanonicalMeshPeerId(meshPeerAliases(peerId), groupFoldMap.values.toSet()) ?: peerId

    private fun preferredMeshAliases(peerId: String): List<String> {
        val aliases = meshPeerAliases(peerId)
        val live = aliases.firstOrNull { MeshRadio.hasMeshLink(it) }
        return orderMeshAliasesByLiveRoute(aliases, live)
    }

    private fun npubRawFor(peerId: String): ByteArray? =
        preferredMeshAliases(peerId).firstNotNullOfOrNull(::exactNpubRawFor)

    private fun isMeshContactBlocked(peerId: String): Boolean =
        isMeshAliasGroupBlocked(
            aliases = meshPeerAliases(peerId),
            isPeerBlocked = socialState::isBlockedPeer,
            linkedNpubHex = { alias -> exactNpubRawFor(alias)?.toHexLower() },
            isNpubBlocked = socialState::isBlockedNostr,
        )

    private fun setMeshContactBlocked(peerId: String, blocked: Boolean) {
        for (alias in meshPeerAliases(peerId)) {
            socialState = socialState.withBlockedPeer(alias, blocked)
            exactNpubRawFor(alias)?.toHexLower()?.let { npubHex ->
                socialState = socialState.withBlockedNostr(npubHex, blocked)
            }
            if (blocked) socialState = socialState.withFavoritePeer(alias, false)
        }
    }

    private fun mergedMeshMessages(peerId: String): List<SonarMsg> =
        meshPeerAliases(peerId)
            .flatMap { meshChats[it].orEmpty() }
            .distinctBy { it.id }
            .sortedBy { it.tsSecs }

    private fun liveMeshRoutePeerId(peerId: String): String? =
        meshPeerAliases(peerId).firstOrNull { MeshRadio.hasMeshLink(it) }

    fun npubStringForPeer(peerId: String): String? =
        npubRawFor(peerId)?.let { Bech32.encode("npub", it) }

    private fun loadLinks() {
        SonarCore.loadBlob("sonar.links").lineSequence().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0) linkByFp[line.substring(0, i)] = line.substring(i + 1).trim()
        }
        SonarCore.loadBlob("sonar.linkCaps").lineSequence().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0) linkCapsByFp[line.substring(0, i)] = line.substring(i + 1).trim().toIntOrNull() ?: 0
        }
        groupFoldMap.clear()
        groupFoldMap.putAll(decodeGroupFoldMap(SonarCore.loadBlob(GROUP_FOLDS_BLOB_KEY)))
    }

    private fun persistLinks() {
        SonarCore.saveBlob("sonar.links", linkByFp.entries.joinToString("\n") { "${it.key}=${it.value}" })
    }

    private fun persistLinkCaps() {
        SonarCore.saveBlob("sonar.linkCaps", linkCapsByFp.entries.joinToString("\n") { "${it.key}=${it.value}" })
    }

    private fun persistGroupFolds() {
        SonarCore.saveBlob(GROUP_FOLDS_BLOB_KEY, groupFoldMap.entries.joinToString("\n") { "${it.key}=${it.value}" })
    }

    /** Record fingerprint→npub from a 0x53 (persisted on change). When a new
     *  mapping is learned this is also the trigger to flush any queued outbox
     *  messages — the peer now has a reachable npub route (mirrors iOS
     *  MessageRouter's NotificationCenter observation on favoriteStatusChanged). */
    private fun rememberLink(peerId: String, ann: SonarAnnounce) {
        val npubHex = ann.npub.toHexLower()
        val isNewLink = npubHex.length == 64 && !linkByFp[peerId].equals(npubHex, ignoreCase = true)
        if (isNewLink) {
            linkByFp[peerId] = npubHex
            persistLinks()
        }
        if (linkCapsByFp[peerId] != ann.capabilities) {
            linkCapsByFp[peerId] = ann.capabilities
            persistLinkCaps()
        }
        updateBleDiscoveryPolicy()
        ensureSonarDescriptorHex(npubHex)
        // A new or updated link means we can now reach this peer via White Noise
        // — flush any queued messages that were waiting for this route.
        if (isNewLink || outbox.contains(peerId)) {
            flushOutbox(peerId)
        }
    }
    /** GPS-derived location channels (Mesh + Ottaviano…Italy), like iOS. */
    var locationChannels by mutableStateOf<List<GeoChannel>>(emptyList())
        private set
    /** Live "here now" counts per geohash (kind-20001 presence), like iOS. */
    var presenceByGeohash by mutableStateOf<Map<String, Int>>(emptyMap())
        private set
    var toast by mutableStateOf<String?>(null)

    /** "N here now" for a geohash channel (0 ⇒ unknown / nobody). */
    fun presence(geohash: String): Int = presenceByGeohash[geohash] ?: 0

    fun refreshLocationChannels() {
        scope.launch { runCatching { locationChannels = LocationChannels.current() } }
    }

    // ── Lightning wallet ──
    val walletAvailable: Boolean = WalletBridge.isAvailable()
    var walletState by mutableStateOf<WalletState>(WalletBridge.state())
        private set
    var showFiat by mutableStateOf(WalletBridge.showFiat())
        private set
    var currency by mutableStateOf(WalletBridge.currency())
        private set
    private var rate: ExchangeRate? = WalletBridge.cachedRate(currency)
    private var publishedSonarDescriptor = false
    private var publishedSonarDescriptorBolt12Offer: String? = null
    private var publishingSonarDescriptor = false
    private var needsSonarDescriptorPublish = false

    /** Money label honoring the fiat/sats preference + live rate (iOS rule). */
    fun money(sats: Long): String = Money.format(sats, showFiat, currency, rate)

    /** Spendable balance in sats (0 unless the wallet is Ready). */
    fun walletBalanceSats(): Long = (walletState as? WalletState.Ready)?.balanceSats ?: 0L

    /** Live-rate fiat string for [sats], or null when no rate is available. */
    fun fiatOrNull(sats: Long): String? = Money.formatFiat(sats, currency, rate)

    fun toggleShowFiat() {
        showFiat = !showFiat
        WalletBridge.setShowFiat(showFiat)
    }

    fun selectCurrency(c: FiatCurrency) {
        currency = c
        WalletBridge.setCurrency(c)
        rate = WalletBridge.cachedRate(c)
    }

    private var balanceFlowCollecting = false

    private fun setupWallet() {
        if (!walletAvailable) {
            scope.launch { publishSonarDescriptorIfNeeded(force = true) }
            return
        }
        if (!balanceFlowCollecting) {
            balanceFlowCollecting = true
            // Collect the background-produced balance stream (iOS balanceTask
            // parity). WalletBridge.balanceFlow is fed from Breez SDK events on
            // an IO scope — never the render path; we only collect state here.
            scope.launch {
                WalletBridge.balanceFlow.collect { sats ->
                    if (WalletBridge.state() is WalletState.Ready) {
                        walletState = WalletState.Ready(sats)
                    }
                }
            }
            // Record incoming external wallet payments (iOS
            // recordIncomingWalletPayment): fed by the Breez event listener on
            // an IO scope; we only collect + write the local ledger here. The
            // merge layer folds chat ⚡PAY receipts by preimage so an incoming
            // chat payment never appears twice.
            scope.launch {
                // WalletBridge already records incoming payments at the event
                // source (headless-safe). Collecting here is the live-UI path
                // for events that arrive while the app is open; recordPending is
                // idempotent by wallet payment id, so this never double-records.
                WalletBridge.paymentEvents.collect { ev ->
                    PaymentActivityStore.recordIncomingWalletPayment(ev)
                }
            }
        }
        scope.launch {
            WalletBridge.setupIfNeeded(SonarCore.identityNsec())
            walletState = WalletBridge.state()
            WalletBridge.fetchRates()
            rate = WalletBridge.cachedRate(currency)
            publishSonarDescriptorIfNeeded(force = true)
            if (walletState is WalletState.Ready) Notifier.onWalletReady()
        }
    }

    private suspend fun publishSonarDescriptorIfNeeded(force: Boolean = false) {
        if (publishingSonarDescriptor) {
            needsSonarDescriptorPublish = true
            return
        }
        publishingSonarDescriptor = true
        try {
            val offer = when (walletState) {
                is WalletState.Ready -> {
                    val created = runCatching { WalletBridge.createOffer() }.getOrNull()
                    if (created == null && !publishedSonarDescriptor) return
                    created ?: publishedSonarDescriptorBolt12Offer
                }
                WalletState.SettingUp -> return
                else -> {
                    if (publishedSonarDescriptorBolt12Offer != null) return
                    null
                }
            }
            // Keep the Breez webhook registration independent from descriptor
            // publishing. The descriptor may already be current, but the swap
            // server's offer-scoped webhook can still need a per-launch
            // unregister -> register refresh.
            if (offer != null) Notifier.onPaymentOfferReady(offer)
            if (!force && publishedSonarDescriptor && publishedSonarDescriptorBolt12Offer == offer) return
            val published = runCatching {
                SonarCore.publishSonarDescriptor(callsEnabled = true, bolt12Offer = offer)
            }.isSuccess
            if (published) {
                publishedSonarDescriptor = true
                publishedSonarDescriptorBolt12Offer = offer
            }
        } finally {
            publishingSonarDescriptor = false
            if (needsSonarDescriptorPublish) {
                needsSonarDescriptorPublish = false
                publishSonarDescriptorIfNeeded(force = true)
            }
        }
    }

    // ── ⚡PAY ledger (direct BOLT12 receipts, 1:1 with iOS) ──
    private var payLedger = SonarPayLedger(SonarCore.loadBlob("pay.ledger"))
    /** Bumped whenever the ledger changes, so pay bubbles recompose. */
    var payVersion by mutableStateOf(0)
        private set

    fun payStatus(uuid: String): PayStatus? = payLedger.get(uuid)?.status

    fun walletPayEntries(): List<PayEntry> = payLedger.all()

    /** Recomposition key for [walletActivity] (the direct-ledger leg; ⚡PAY
     *  receipts bump [payVersion]). Screens read it through state so all
     *  wallet-facing reads flow through app state. */
    val paymentActivityVersion get() = PaymentActivityStore.version

    /** Merged wallet activity for the Wallet screen: chat ⚡PAY receipts +
     *  direct/Unify/incoming ledger rows, deduped, newest-first. The ONLY
     *  read path for the activity ledger — the UI never touches
     *  [PaymentActivityStore] directly. */
    fun walletActivity(): List<WalletActivityItem> =
        mergeWalletActivity(walletPayEntries(), PaymentActivityStore.sorted())

    private fun persistPay() { SonarCore.saveBlob("pay.ledger", payLedger.serialize()) }

    private fun paymentNpubHex(chatId: String): String? =
        if (isMeshChat(chatId)) {
            npubRawFor(meshPeerId(chatId))?.toHexLower()
        } else {
            chats.firstOrNull { it.id == chatId }
                ?.takeIf { isDirectMarmotChat(it) }
                ?.let { otherMembers(it).singleOrNull() }
                ?.let { canonicalNpubHex(it) }
        }

    private fun directPaymentOffer(chatId: String): String? {
        if (isMeshChat(chatId)) {
            preferredMeshAliases(meshPeerId(chatId)).firstNotNullOfOrNull { alias ->
                sonarProfile(alias)?.bolt12Offer?.takeIf { it.isNotBlank() }
            }?.let { return it }
        }
        val npubHex = paymentNpubHex(chatId) ?: return null
        return sonarDescriptorsByNpubHex[npubHex]?.bolt12Offer?.takeIf { it.isNotBlank() }
    }

    suspend fun paymentDetailsUnavailableMessage(chatId: String): String? {
        val npubHex = paymentNpubHex(chatId) ?: return "Fetching payment details — try again in a moment."
        val key = npubHex.lowercase()
        val cached = sonarDescriptorsByNpubHex[key]
        val hasBolt12 = cached?.bolt12Offer?.isNotBlank() == true
        if (hasBolt12) {
            ensureSonarDescriptorHex(npubHex)
            return null
        }
        fetchSonarDescriptorSync(npubHex)
        val fetched = sonarDescriptorsByNpubHex[key]
        if (fetched?.bolt12Offer?.isNotBlank() == true) return null
        return "Fetching payment details — try again in a moment."
    }

    suspend fun sendPay(chatId: String, sats: Long): String? {
        if (sats <= 0) return null
        if (isContactBlocked(chatId)) return "Unblock this contact before paying."
        if (!walletAvailable || walletState !is WalletState.Ready) {
            return "Set up the wallet first."
        }
        val npubHex = paymentNpubHex(chatId)
        if (npubHex != null) {
            val key = npubHex.lowercase()
            val hasBolt12 = sonarDescriptorsByNpubHex[key]?.bolt12Offer?.isNotBlank() == true
            if (!hasBolt12) {
                fetchSonarDescriptorSync(npubHex)
            }
        }
        val offer = directPaymentOffer(chatId)
        if (offer == null) return "Fetching payment details — try again in a moment."
        val payId = randomPayId()
        // iOS parity (SonarAppStore.sendPay → SonarPaymentActivityLedger):
        // record a pending sonarDirect activity BEFORE the wallet send, then
        // settle or fail it below so the Wallet screen shows direct sends.
        PaymentActivityStore.recordPending(
            SonarPaymentActivity(
                id = payId,
                kind = SonarPaymentActivity.Kind.SonarDirect,
                peerKey = chatId,
                peerName = callPeerName(chatId),
                direction = SonarPaymentActivity.Direction.Outgoing,
                sats = sats,
                via = if (isMeshChat(chatId) && hasLiveMeshRoute(meshPeerId(chatId))) "mesh" else "internet",
                createdAtSecs = SonarClock.nowSecs(),
                destinationHash = paymentDestinationHash(offer),
                status = SonarPaymentActivity.Status.Pending,
            )
        )
        scope.launch {
            var failureMessage: String? = null
            val result = runCatching { WalletBridge.send(offer, sats, "Sonar payment $payId") }
                .getOrElse {
                    failureMessage = "Payment failed: ${it.message}"
                    SendResult(false)
                }
            walletState = WalletBridge.state()
            if (result.ok) {
                // Wallet settled — record locally before the receipt lines so
                // the ledger stays consistent even if chat delivery fails.
                PaymentActivityStore.markPaid(
                    payId, result.paymentId, result.feesSats,
                    result.settledAtSecs ?: SonarClock.nowSecs(),
                )
                if (payLedger.recordReceipt(payId, sats, mine = true, tsSecs = SonarClock.nowSecs())) {
                    persistPay()
                    payVersion++
                }
                val receiptOk = sendPaymentReceiptLines(
                    chatId,
                    listOf(
                        PayLine.Pay(payId, sats).encoded(),
                        PayLine.Done(payId, result.preimage).encoded(),
                    ),
                )
                if (!receiptOk) {
                    toast = "Payment sent but receipt delivery failed"
                }
            } else {
                PaymentActivityStore.markFailed(payId, failureMessage ?: "Payment failed")
                toast = failureMessage ?: "Payment failed"
            }
        }
        return null
    }

    private suspend fun sendPaymentReceiptLines(chatId: String, lines: List<String>): Boolean {
        val clean = lines.map { it.trim() }.filter { it.isNotEmpty() }
        if (clean.isEmpty()) return true
        if (isContactBlocked(chatId)) return false
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val routePeerId = liveMeshRoutePeerId(peerId)
            if (routePeerId != null) {
                return clean.all { sendMesh(routePeerId, it) }
            }
            val raw = npubRawFor(peerId) ?: return false
            return sendPaymentReceiptLinesOverMarmot(
                ensureMarmotGroupForOutbox(peerId, raw) ?: return false,
                clean,
                refreshPeerId = peerId,
            )
        }
        return sendPaymentReceiptLinesOverMarmot(chatId, clean, refreshPeerId = null)
    }

    private suspend fun sendPaymentReceiptLinesOverMarmot(
        groupId: String,
        lines: List<String>,
        refreshPeerId: String?,
    ): Boolean = try {
        for (line in lines) {
            SonarCore.send(groupId, line)
        }
        if (refreshPeerId != null) {
            refreshOpenDm(refreshPeerId)
        } else if ((screen as? Screen.Chat)?.id == groupId) {
            setCurrentVisibleMessages(groupId, withSendEchoes(groupId, mergePendingMediaUploads(groupId, marmotMessagesPageForChat(groupId))))
        }
        true
    } catch (_: Throwable) {
        false
    }

    /** Scan a chat's transcript for ⚡PAY control lines and drive the state machine. */
    fun processPayLines(chatId: String, msgs: List<SonarMsg>) {
        var changed = false
        for (m in msgs) {
            when (val line = PayLine.decode(m.content)) {
                is PayLine.Pay -> if (payLedger.recordReceipt(line.uuid, line.sats, m.mine, tsSecs = m.tsSecs)) changed = true
                is PayLine.Done -> if (payLedger.markClaimedOrPending(line.uuid, line.preimage)) changed = true
                null -> {}
            }
        }
        if (changed) { persistPay(); payVersion++ }
    }

    /** Start the BLE mesh radio (call once permissions are granted). */
    fun startMesh() {
        refreshMeshIdentity()
        refreshBatterySaving()
        updateBleDiscoveryPolicy()
        MeshRadio.start()
        refreshSonarDiscoveryProfiles()
        updateMeshPeersFromRadio()
    }

    // ── Unify nearby payments (separate BLE service; payments-only) ──
    /** Cached amountless BOLT12 offer we advertise as the Unify receiver. */
    private var unifyOffer: String? = null

    /** Start scanning for Unify peers (payer role). Idempotent; no-op until
     *  onboarded or while BLE permissions are missing. */
    private fun startUnify() {
        if (!onboarded) return
        if (bleDiscoveryRestricted) {
            UnifyRadio.stopScanning()
            unifyPeers = emptyList()
            return
        }
        UnifyRadio.startScanning()
    }

    /** Advertise our receivable BOLT12 offer iff the wallet is ready AND we are
     *  in the foreground — mirrors the iOS receiver policy (foreground-only). */
    private suspend fun updateUnifyReceiver() {
        val shouldServe = walletAvailable && onboarded && foreground && !bleDiscoveryRestricted &&
            walletState is WalletState.Ready
        if (shouldServe) {
            if (unifyOffer == null) unifyOffer = runCatching { WalletBridge.createOffer() }.getOrNull()
            val offer = unifyOffer
            if (offer != null && !UnifyRadio.isAdvertising()) {
                UnifyRadio.startAdvertising(offer, nick.ifBlank { "Sonar user" })
            }
        } else if (UnifyRadio.isAdvertising()) {
            UnifyRadio.stopAdvertising()
        }
    }

    /** Pay a nearby Unify user [amountSats] over Lightning: read their offer,
     *  parse the BIP321 destination, and send. Surfaces the outcome via toast. */
    fun sendSatsToUnify(peerId: String, amountSats: Long) {
        if (!walletAvailable || walletState !is WalletState.Ready) {
            toast = "Set up the wallet first"; return
        }
        if (amountSats <= 0) return
        scope.launch {
            val raw = UnifyRadio.fetchOffer(peerId)
            val dest = raw?.let { UnifyBIP321.parse(it) }?.lightning
            if (dest == null) { toast = "Couldn't read that user's payment request"; return@launch }
            // iOS parity (SonarAppStore.payUnify): a direct Lightning send —
            // Unify peers don't chat, so this shows up ONLY in the wallet
            // activity ledger, not as a ⚡PAY chat receipt.
            val activityId = randomPayId()
            PaymentActivityStore.recordPending(
                SonarPaymentActivity(
                    id = activityId,
                    kind = SonarPaymentActivity.Kind.UnifyNearby,
                    peerKey = peerId,
                    peerName = unifyPeers.firstOrNull { it.id == peerId }?.name ?: "Nearby user",
                    direction = SonarPaymentActivity.Direction.Outgoing,
                    sats = amountSats,
                    via = "internet",
                    createdAtSecs = SonarClock.nowSecs(),
                    destinationHash = paymentDestinationHash(dest),
                    status = SonarPaymentActivity.Status.Pending,
                )
            )
            val result = WalletBridge.send(dest, amountSats, "Sonar nearby")
            walletState = WalletBridge.state()
            if (result.ok) {
                PaymentActivityStore.markPaid(
                    activityId, result.paymentId, result.feesSats,
                    result.settledAtSecs ?: SonarClock.nowSecs(),
                )
            } else {
                PaymentActivityStore.markFailed(activityId, "Payment failed")
            }
            toast = if (result.ok) "Sent ${amountSats} sats" else "Payment failed"
        }
    }

    fun joinChannel(geohash: String) {
        val g = geohash.trim().lowercase()
        if (g.isEmpty()) return
        SonarCore.joinChannel(g)
        channels = SonarCore.joinedChannels()
        openChannel(g)
    }

    /** Explicitly saved/joined channels (design: home "Saved channels"), minus the
     *  always-present Mesh. These get a permanent one-tap row on the home. */
    val savedChannels: List<String> get() = channels.filter { it != "mesh" }

    /** True iff [geohash] is pinned to the home "Saved channels" list. */
    fun isSaved(geohash: String): Boolean {
        val g = geohash.trim().lowercase()
        return g != "mesh" && channels.contains(g)
    }

    /** Pin/unpin a channel to the home "Saved channels" list WITHOUT navigating
     *  (the channel header bookmark + the home long-press use this). Mesh is always
     *  present, so it is never savable. */
    fun toggleSaved(geohash: String) {
        val g = geohash.trim().lowercase()
        if (g.isEmpty() || g == "mesh") return
        if (channels.contains(g)) { SonarCore.leaveChannel(g); toast = "Removed from saved channels" }
        else { SonarCore.joinChannel(g); toast = "Channel saved" }
        channels = SonarCore.joinedChannels()
    }

    /** True iff [geohash] is the channel currently on screen. Guards async loads
     *  so a stale refresh for a channel the user already left can't overwrite the
     *  visible list (that made different channels look "mixed"). */
    private fun isOpenChannel(geohash: String) = (screen as? Screen.Channel)?.geohash == geohash

    fun openChannel(geohash: String) {
        push(Screen.Channel(geohash))
        channelMsgs = emptyList()
        // The "mesh" channel is the BLE Bluetooth mesh — NO geohash, NEVER Nostr
        // (bitchat's .mesh geohash is nil). It's driven by BLE broadcasts, so just
        // show what we have; new messages arrive via drainMeshBroadcasts().
        if (geohash == "mesh") { channelMsgs = visibleChannelMessages(meshBroadcast); return }
        scope.launch {
            val disk = MessageStore.loadChannel(geohash) // disk hydrate (off-main), survives restart
            if (isOpenChannel(geohash)) channelMsgs = visibleChannelMessages(disk)
            refreshChannel(geohash)
            // Announce our presence right away and pull the current count so the
            // header shows "N here now" without waiting for the next poll tick.
            beatPresence(geohash)
            refreshPresenceCounts()
        }
    }

    /** Fetch the channel from the core, merge with what's on disk, persist. */
    private suspend fun refreshChannel(geohash: String) {
        if (geohash == "mesh") return // BLE mesh — not a Nostr channel
        val fresh = SonarCore.channelMessages(geohash)
        val merged = MessageMerge.channels(MessageStore.loadChannel(geohash), fresh)
        MessageStore.saveChannel(geohash, merged)
        // Only touch the visible list if THIS channel is still open.
        if (isOpenChannel(geohash)) channelMsgs = visibleChannelMessages(merged)
    }

    fun sendChannelMsg(geohash: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        // The Bluetooth mesh channel is a BLE broadcast (NOT Nostr): send it to
        // every connected mesh peer + echo locally. No relay round-trip.
        if (geohash == "mesh") {
            val reached = MeshRadio.sendMeshBroadcast(t)
            val msg = SonarChannelMsg(randomMeshId(), nick.ifBlank { "you" }, "", t, mine = true, MeshRadio.nowSecs())
            meshBroadcast = (meshBroadcast + msg).takeLast(200)
            channelMsgs = visibleChannelMessages(meshBroadcast)
            if (!reached) toast = "No one in Bluetooth range yet — your message will reach people as they connect."
            return
        }
        scope.launch {
            try {
                SonarCore.sendChannel(geohash, t)
                refreshChannel(geohash)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    fun openGeoDm(geohash: String, peerHex: String, name: String) {
        if (peerHex.isBlank()) return
        push(Screen.GeoDm(geohash, peerHex, name))
        messages = emptyList()
        scope.launch {
            messages = visibleGeoDmMessages(peerHex, MessageStore.loadGeoDm(geohash, peerHex)) // disk hydrate (off-main)
            refreshGeoDm(geohash, peerHex)
        }
    }

    private suspend fun refreshGeoDm(geohash: String, peerHex: String) {
        val fresh = SonarCore.geoDmMessages(geohash, peerHex)
        val merged = MessageMerge.dms(MessageStore.loadGeoDm(geohash, peerHex), fresh)
        MessageStore.saveGeoDm(geohash, peerHex, merged)
        messages = visibleGeoDmMessages(peerHex, merged)
    }

    fun sendGeoDmMsg(geohash: String, peerHex: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (isGeoDmBlocked(peerHex)) {
            toast = "Unblock this author before sending."
            return
        }
        scope.launch {
            try {
                SonarCore.sendGeoDm(geohash, peerHex, t)
                refreshGeoDm(geohash, peerHex)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    private fun initialOnboardingComplete(): Boolean {
        val stored = SonarCore.onboardingComplete()
        if (stored) return true
        if (!SonarCore.hasIdentity()) return false
        SonarCore.setOnboardingComplete(true)
        return true
    }

    var onboarded by mutableStateOf(initialOnboardingComplete())
        private set
    var nick by mutableStateOf(SonarCore.nickname())
        private set

    fun fingerprint(): String = SonarCore.fingerprint()

    // ── Sonar Discovery profile (BIP-353 payment address) ──
    var bip353 by mutableStateOf(SonarCore.loadBlob("bip353"))
        private set

    fun updateBip353(value: String) {
        val t = value.trim()
        SonarCore.saveBlob("bip353", t)
        bip353 = t
    }

    /** Capabilities this node advertises in its Sonar announce (0x53). This build
     *  speaks Sonar voice/video calls, so it always advertises CAP_CALLS. */
    private fun capabilities(): Int =
        SonarAnnounce.CAP_MARMOT or SonarAnnounce.CAP_CALLS or
            (if (walletAvailable) SonarAnnounce.CAP_PAY else 0)

    /** Build our local Sonar Discovery announce from the current identity. The
     *  rich Sonar identity: npub + capabilities + (when set) BIP-353 payment
     *  address + the BOLT12 offer, so a peer Sonar can pay us without a
     *  round-trip. */
    fun localSonarAnnounce(): SonarAnnounce? {
        val raw = chat.bitchat.sonar.crypto.Bech32.decode(npub)?.takeIf { it.hrp == "npub" }?.data
            ?: return null
        if (raw.size != 32) return null
        return SonarAnnounce(1, raw, bip353.ifBlank { null }, capabilities(), unifyOffer)
    }

    private fun refreshMeshIdentity() {
        MeshRadio.setMeshNickname(nick)
        MeshRadio.setLocalSonarAnnounce(localSonarAnnounce()?.encode())
    }

    // ── Verify safety numbers (1:1 with iOS) ──
    /** Verified chat ids held in memory so [isVerified] (read per home row) is an
     *  O(1) set lookup, not a synchronous per-id `loadBlob` on the render path.
     *  Seeded from disk once in [boot]; the `verified.<id>` blobs stay the
     *  source of truth. [verifiedVersion] keys the row-model memo. */
    private val verifiedChatIds = mutableSetOf<String>()
    private var verifiedVersion = 0

    /** One-time boot seed: read the persisted verify flag for each known chat id
     *  (off the render path). Blobs have no enumeration, so we probe the ids we
     *  actually have from the restored snapshot. */
    private fun seedVerifiedChatIds() {
        for (chat in chats) {
            for (id in directMarmotChatIds(chat.id)) {
                if (SonarCore.loadBlob("verified.$id") == "1") verifiedChatIds += id
            }
        }
        verifiedVersion++
    }

    fun isVerified(chatId: String): Boolean =
        directMarmotChatIds(chatId).any { it in verifiedChatIds }

    fun markVerified(chatId: String) {
        for (id in directMarmotChatIds(chatId)) {
            SonarCore.saveBlob("verified.$id", "1")
            verifiedChatIds += id
        }
        verifiedVersion++
        payVersion++ // recompose verify-dependent UI
        toast = "Marked as verified"
    }

    /** Verify info for a Marmot chat: the 12 safety groups, or an honest note. */
    fun verifyInfo(chatId: String): SonarVerify {
        val chat = chats.firstOrNull { it.id == chatId }
        if (chat != null && !isDirectMarmotChat(chat)) {
            return SonarVerify(emptyList(), false, "Safety numbers are available for 1:1 chats.")
        }
        val peer = chat?.let { otherMembers(it).firstOrNull() }
        return if (peer.isNullOrBlank() || npub.isBlank()) {
            SonarVerify(emptyList(), isVerified(chatId), "Connecting to the secure chat service — try again in a moment.")
        } else {
            SonarVerify(SafetyNumber.of(npub, peer), isVerified(chatId), null)
        }
    }

    fun completeOnboarding(nickname: String) {
        scope.launch {
            val result = runCatching {
                SonarCore.setNickname(nickname)
                npub = SonarCore.prepareIdentityForOnboarding()
                SonarCore.setOnboardingComplete(true)
                nick = nickname
                onboarded = true
                refreshMeshIdentity()
            }
            result.exceptionOrNull()?.let {
                toast = "Couldn't save your account key. Try again."
            }
        }
    }

    fun exportNsec(): String = SonarCore.identityNsec()

    fun restoreAccount(nsec: String, onResult: (Result<Unit>) -> Unit) {
        scope.launch {
            val result = runCatching {
                val restoredNpub = SonarCore.importIdentity(nsec)

                WalletBridge.shutdown()
                UnifyRadio.stopScanning()
                UnifyRadio.stopAdvertising()
                unifyOffer = null; unifyPeers = emptyList()
                pollJob?.cancel(); pollJob = null
                stopMarmotWakeLoop()
                resetCallState()
                cancelPendingMarmotSetups()
                cancelPendingMarmotGroupSetups()

                MessageStore.wipe()
                meshChats.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); pendingDirectMarmotSends.clear(); pendingMarmotGroupSends.clear(); outbox.clear()
                pendingMarmotChatNpubs = emptyMap()
                pendingMarmotGroups = emptyMap()
                linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
                persistLinks(); persistLinkCaps(); persistGroupFolds()
                updateBleDiscoveryPolicy()
                foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
                sonarPeerProfiles = emptyMap()
                sonarDescriptorsByNpubHex = emptyMap()
                sonarDescriptorFetches.clear(); sonarDescriptorFetchedAt.clear(); sonarDescriptorMissedAt.clear()
                meshBroadcast = emptyList(); meshDmRows = emptyList()
                chats = emptyList(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); messages = emptyList(); channelMsgs = emptyList()
                lastWnGroups = -1; lastWnMsgs = -1
                payLedger = SonarPayLedger(); persistPay(); payVersion++
                PaymentActivityStore.wipe()
                mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
                callLogs.clear(); callVersion++

                npub = restoredNpub
                // Keep the persisted npub consistent with the restored identity
                // now, so a crash before start()'s re-save can't restore the OLD
                // npub as "me" on the next launch's local-first paint.
                SonarCore.saveBlob(NPUB_BLOB_KEY, restoredNpub)
                started = false
                connecting = false
                localCoreReady = false
                homeMessagesHydrated = false
                SonarCore.setOnboardingComplete(true)
                onboarded = true
                nick = SonarCore.nickname()
                stack = listOf(Screen.Home)
                walletState = WalletBridge.state()
                refreshMeshIdentity()
                boot()
            }
            onResult(result.map { Unit })
        }
    }

    fun updateNickname(value: String) {
        SonarCore.setNickname(value)
        nick = value
        refreshMeshIdentity()
        // Re-publish our kind-0 profile so peers see the new name.
        if (started) scope.launch { runCatching { SonarCore.publishProfile(value) } }
    }

    // ── Local notifications (fire on new incoming message while backgrounded) ──
    private var foreground = true
    private val lastSeenTs = HashMap<String, Long>()
    private val lastNotifiedTs = HashMap<String, Long>()
    private var seededSeen = false

    // ── App lock ──
    val appLockAvailable: Boolean = AppLock.isAvailable()
    var appLockOn by mutableStateOf(AppLock.isEnabled())
        private set
    var locked by mutableStateOf(AppLock.isEnabled())
        private set

    fun setAppLock(value: Boolean) {
        AppLock.setEnabled(value)
        appLockOn = AppLock.isEnabled()
    }

    // The credential prompt backgrounds us; the foreground return it triggers
    // must NOT re-lock — otherwise a successful unlock immediately re-locks.
    private var bypassRelock = false

    fun unlock() {
        bypassRelock = true
        AppLock.authenticate { ok -> if (ok) locked = false }
    }

    // ── Generic persisted preferences (Settings toggles + choices) ──
    var prefsVersion by mutableStateOf(0)
        private set

    fun prefBool(key: String, default: Boolean = false): Boolean {
        val v = SonarCore.loadBlob("pref.$key")
        return if (v.isEmpty()) default else v == "1"
    }

    fun setPref(key: String, on: Boolean) {
        SonarCore.saveBlob("pref.$key", if (on) "1" else "0")
        prefsVersion++
    }

    fun togglePref(key: String, default: Boolean = false) = setPref(key, !prefBool(key, default))

    fun prefStr(key: String, default: String): String =
        SonarCore.loadBlob("pref.$key").ifEmpty { default }

    fun setPrefStr(key: String, value: String) {
        SonarCore.saveBlob("pref.$key", value)
        prefsVersion++
    }

    val bleDiscoveryRestricted: Boolean
        get() = batterySaving || !discoverNewPeople

    val bleDiscoveryStatusLine: String
        get() = when {
            batterySaving -> "Battery saving · chats only"
            discoverNewPeople -> "Discovering nearby people"
            else -> "Chats only"
        }

    val radarDiscoveryStatusLine: String
        get() = if (bleDiscoveryRestricted) {
            "${meshPeers.size} in range · chats only"
        } else {
            "${meshPeers.size} in range · scanning"
        }

    fun setBleDiscoverNewPeople(enabled: Boolean) {
        if (discoverNewPeople == enabled) return
        discoverNewPeople = enabled
        setPref(BLE_DISCOVER_NEW_PEOPLE_PREF, enabled)
        updateBleDiscoveryPolicy()
        if (bleDiscoveryRestricted) {
            UnifyRadio.stopScanning()
            unifyPeers = emptyList()
        }
    }

    private fun refreshBatterySaving() {
        val enabled = BatterySaver.enabled()
        if (batterySaving == enabled) return
        batterySaving = enabled
        updateBleDiscoveryPolicy()
        if (bleDiscoveryRestricted) {
            UnifyRadio.stopScanning()
            unifyPeers = emptyList()
        }
    }

    private fun knownBlePeerIds(): Set<String> =
        knownBlePeerIdsForPolicy(
            meshChatPeerIds = meshChats.keys,
            persistedFoldPeerIds = groupFoldMap.values,
            liveFoldPeerIds = foldedGroupPeerIds.values,
        )

    private fun updateBleDiscoveryPolicy() {
        val known = knownBlePeerIds()
        MeshRadio.setKnownPeerIds(known)
        MeshRadio.setDiscoveryMode(if (bleDiscoveryRestricted) BleDiscoveryMode.KnownOnly else BleDiscoveryMode.Normal)
    }

    /** Count of chats the user has marked verified (for the Settings row). */
    fun verifiedCount(): Int =
        dedupeDirectMarmotChats(
            chats = chats,
            ownNpub = npub,
            latestSecs = ::localLatestTs,
        ).count { isVerified(it.id) }

    fun unreadForChat(chatId: String): Long =
        directMarmotChatIds(chatId).sumOf { unreadByChat[it] ?: 0L }

    /** Last-message preview + timestamp for a chat-list row (design ConvRow):
     *  replaces the static "Tap to open" with the real transcript tail, read
     *  from the in-memory snapshot only (local-first, no DB/relay work).
     *  Filters control lines (☎CALL/⚡PAY/…) exactly like the transcript and
     *  humanizes media/sticker previews — a raw wire line must never be a row
     *  subtitle. */
    fun chatRowMeta(chatId: String): Pair<String, Long>? =
        directMarmotChatIds(chatId)
            .mapNotNull { id ->
                visibleMessagesForChat(id, chatSnapshotMessagesByChat[id].orEmpty()).lastOrNull()
            }
            .maxByOrNull { it.tsSecs }
            ?.let { messagePreview(it.content, it.stickerRef, it.media) to it.tsSecs }

    // ── Home Marmot-row view models (Signal "cache row view models") ──
    // The home LazyColumn used to call chatTitle + chatRowMeta + isVerified +
    // unreadForChat PER ROW during composition; each walked `chats` (O(chats)),
    // so a home paint was O(chats²) plus a per-row disk read for verify. These
    // are now precomputed ONCE per input change (peer-key grouping built a
    // single time) and read O(1) by the row via [marmotRow].
    private var marmotRowsKey: VisibleChatsKey? = null
    private var marmotRowsUnread: Map<String, Long>? = null
    private var marmotRowsProfiles: Map<String, SonarProfile>? = null
    private var marmotRowsVerified = -1
    private var marmotRowsCache: Map<String, MarmotRowModel> = emptyMap()

    private fun marmotRowModels(): Map<String, MarmotRowModel> {
        val vkey = currentVisibleChatsKey()
        val unread = unreadByChat
        val profiles = profilesByNpub
        // Reassigned-map identity (===) detects change without hashing entries.
        if (marmotRowsKey == vkey && marmotRowsUnread === unread &&
            marmotRowsProfiles === profiles && marmotRowsVerified == verifiedVersion
        ) return marmotRowsCache
        val models = computeMarmotRowModels(visibleChats)
        marmotRowsKey = vkey; marmotRowsUnread = unread
        marmotRowsProfiles = profiles; marmotRowsVerified = verifiedVersion
        marmotRowsCache = models
        return models
    }

    private fun computeMarmotRowModels(rows: List<SonarChat>): Map<String, MarmotRowModel> {
        // Peer-key → all its chat ids, built ONCE (was recomputed per row).
        val idsByPeerKey = HashMap<String, MutableList<String>>()
        for (c in chats) {
            val pk = directMarmotPeerKey(c) ?: continue
            idsByPeerKey.getOrPut(pk) { mutableListOf() }.add(c.id)
        }
        fun groupedIds(chat: SonarChat): List<String> =
            directMarmotPeerKey(chat)?.let { idsByPeerKey[it] } ?: listOf(chat.id)
        return rows.associate { chat ->
            val pending = isPendingSecureChat(chat.id)
            val ids = if (pending) listOf(chat.id) else groupedIds(chat)
            val newest = if (pending) null else ids
                .mapNotNull { visibleMessagesForChat(it, chatSnapshotMessagesByChat[it].orEmpty()).lastOrNull() }
                .maxByOrNull { it.tsSecs }
            chat.id to MarmotRowModel(
                id = chat.id,
                title = chatTitle(chat),
                sub = when {
                    pending -> "Setting up secure chat…"
                    newest != null -> messagePreview(newest.content, newest.stickerRef, newest.media)
                    else -> "Tap to open"
                },
                // Pending rows use creation time so recency merge does not sink
                // a freshly-started chat under older history (iOS dmRows parity).
                tsSecs = newest?.tsSecs ?: pendingCreatedAtSecs(chat.id) ?: localLatestTs(chat.id),
                verified = ids.any { it in verifiedChatIds },
                unread = ids.sumOf { unreadByChat[it] ?: 0L } > 0,
                pending = pending,
                multiMember = isMultiMemberChat(chat.id),
            )
        }
    }

    /** O(1) precomputed home-row view model for [chatId] (see [marmotRowModels]). */
    fun marmotRow(chatId: String): MarmotRowModel =
        marmotRowModels()[chatId] ?: MarmotRowModel(chatId, chatId, "Tap to open", 0L, false, false, false, false)

    fun setForeground(value: Boolean) {
        val cameToForeground = value && !foreground
        foreground = value
        if (cameToForeground) {
            if (bypassRelock) bypassRelock = false        // return from our own unlock prompt
            else if (AppLock.isEnabled()) locked = true   // genuine app-switch → re-lock
            if (started) {
                refreshKnownContactDescriptors(clearMisses = false)
                scope.launch {
                    publishSonarDescriptorIfNeeded(force = true)
                    SonarCore.sync()
                    drainDirectDms()
                    refreshChats()
                    recomputeConversations()
                    (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
                    refreshPresenceCounts()
                }
                // Run a full housekeeping pass now rather than waiting for the
                // next heartbeat (the old 4 s poll would have run within 4 s).
                requestHousekeeping()
            }
        }
        // Unify receiver is foreground-only (matches iOS) — react immediately.
        scope.launch { updateUnifyReceiver() }
    }

    fun requestImmediateSync() {
        if (!started) return
        scope.launch {
            runCatching { SonarCore.sync() }
            drainDirectDms()
            refreshChats()
            recomputeConversations()
            (screen as? Screen.Chat)?.let { sc ->
                if (isMeshChat(sc.id)) refreshOpenDm(meshPeerId(sc.id))
                else {
                    setCurrentVisibleMessages(
                        sc.id,
                        withSendEchoes(sc.id, mergePendingMediaUploads(sc.id, marmotMessagesPageForChat(sc.id))),
                        processCalls = true,
                    )
                }
            }
        }
    }

    private fun notificationPrefs(): SonarNotificationPrefs =
        SonarNotificationPrefs(
            enabled = prefBool("notifs", true),
            showNames = prefBool("notifNames", true),
            showPreview = prefBool("notifPreview", false),
            showPaymentAmount = true,
        )

    private fun isCallNotificationContent(content: String): Boolean =
        content.trimStart().startsWith("☎CALL") && SonarCore.callParseControl(content) != null

    private fun notifyIncoming(
        idKey: String,
        conversationTitle: String?,
        content: String,
        forcedKind: SonarNotificationKind? = null,
        senderName: String? = null,
        groupName: String? = null,
        unreadCount: Long = 1,
    ) {
        if (foreground) return
        val kind = forcedKind ?: SonarNotificationRouter.classifyContent(content, ::isCallNotificationContent)
        val notification = SonarNotificationRouter.build(
            idKey = idKey,
            kind = kind,
            conversationTitle = conversationTitle,
            senderName = senderName,
            groupName = groupName,
            preview = content,
            unreadCount = unreadCount,
            prefs = notificationPrefs(),
        ) ?: return
        Notifier.notify(notification.id, notification.title, notification.body)
    }

    /** Notify for any chat whose newest incoming message is newer than last seen.
     *  Uses [lastNotifiedTs] to prevent double-fire when the conversationChanged
     *  flow and poll loop both process the same message within one cycle.
     *
     *  Driven by the single `conversationSummaries()` probe passed in as
     *  [summaryByChat] — one FFI call for every chat's newest message, replacing
     *  the old per-chat `messagesPage(chatId, 1)` (O(chats) FFI calls per cycle). */
    private fun maybeNotify(summaryByChat: Map<String, SonarConversationSummary>) {
        val openChatId = (screen as? Screen.Chat)?.id
        val knownChatIds = chats.map { it.id }.toSet()
        val snapshot = visibleChats.filter { it.id in knownChatIds }
        for (c in snapshot) {
            val chatIds = if (isDirectMarmotChat(c)) directMarmotChatIds(c.id) else listOf(c.id)
            notifyChatIfNew(
                c,
                scanIds = chatIds,
                suppressIds = chatIds,
                openChatId = openChatId,
                idKey = c.id,
                title = chatTitle(c),
                summaryByChat = summaryByChat,
            )
        }
        // A White Noise group folded into a mesh row is hidden from
        // [visibleChats], so scan it here and notify under the mesh
        // conversation identity (iOS folds the notification the same way).
        // Open-chat suppression must match BOTH the mesh row and the folded
        // group id so an open merged transcript never rings for itself.
        val chatsById = chats.associateBy { it.id }
        for ((groupId, peerId) in foldedGroupPeerIds) {
            val c = chatsById[groupId] ?: continue
            val meshId = meshChatId(peerId)
            notifyChatIfNew(
                c,
                scanIds = listOf(groupId),
                suppressIds = listOf(groupId, meshId),
                openChatId = openChatId,
                idKey = meshId,
                title = meshPeerName(peerId),
                summaryByChat = summaryByChat,
            )
        }
        seededSeen = true
    }

    private fun notifyChatIfNew(
        c: SonarChat,
        scanIds: List<String>,
        suppressIds: List<String>,
        openChatId: String?,
        idKey: String,
        title: String?,
        summaryByChat: Map<String, SonarConversationSummary>,
    ) {
        val prev = scanIds.mapNotNull { lastSeenTs[it] }.maxOrNull()
        val alreadyNotified = scanIds.map { lastNotifiedTs[it] ?: 0L }.maxOrNull() ?: 0L
        // Reconstruct the newest incoming message per chat from the summary
        // probe (the summary's latest == what messagesPage(chatId, 1) returned).
        // A summary whose newest line is our own send, or from a blocked sender,
        // yields no incoming — matching the old visibleMessagesForChat filter.
        var newestIncoming: SonarMsg? = null
        for (chatId in scanIds) {
            val s = summaryByChat[chatId] ?: continue
            lastSeenTs[chatId] = s.latestAtSecs
            if (s.latestMine) continue
            if (!socialState.allowsChatMessage(chatId, s.latestSenderNpub, mine = false)) continue
            if (newestIncoming == null || s.latestAtSecs > newestIncoming!!.tsSecs) {
                newestIncoming = SonarMsg(
                    id = chatId,
                    senderNpub = s.latestSenderNpub,
                    content = s.latestContent,
                    mine = false,
                    tsSecs = s.latestAtSecs,
                )
            }
        }
        if (seededSeen && prev != null && newestIncoming != null &&
            newestIncoming.tsSecs > prev && newestIncoming.tsSecs > alreadyNotified &&
            (openChatId == null || openChatId !in suppressIds)
        ) {
            val groupName = c.name.takeIf { c.members.size > 2 && it.isNotBlank() }
            notifyIncoming(
                idKey = idKey,
                conversationTitle = title,
                content = newestIncoming.content,
                senderName = notificationSenderName(c, newestIncoming),
                groupName = groupName,
                unreadCount = unreadForChat(idKey).coerceAtLeast(1L),
            )
            for (chatId in scanIds) {
                lastNotifiedTs[chatId] = newestIncoming.tsSecs
            }
        }
    }

    private fun notificationSenderName(chat: SonarChat, message: SonarMsg): String? {
        if (message.senderNpub.isBlank()) return null
        if (chat.members.size > 2) {
            return resolveGroupAuthorName(message, isGroup = true, profilesByNpub, ::ensureProfile)
        }
        val key = canonicalProfileKey(message.senderNpub)
        return profilesByNpub[key]?.bestName ?: chatTitle(chat)
    }

    fun boot() {
        if (started || connecting) return
        connecting = true
        homeMessagesHydrated = false
        localCoreReady = false
        Notifier.ensureChannel()
        scope.launch {
            // ── LOCAL-FIRST PAINT (Signal/iOS parity): this block reads disk
            // and blobs only — no core start, no relay. The home list must be
            // fully hydrated (mesh rows, names, links, folds) BEFORE
            // SonarCore.start(), which can take seconds on a cold relay path.
            // chats snapshot / profiles / npub already restore at construction.
            meshChats.putAll(MessageStore.loadAllMeshDms())
            loadLinks() // durable fingerprint↔npub so BLE chats stay unified after restart
            loadMeshNames() // announce nicknames survive restart — names, not keys
            seedVerifiedChatIds() // in-memory verify set (off render path)
            try {
                // Open the encrypted database with NO relays first, matching the
                // native iOS MarmotService.connectLocal path. This makes the
                // authoritative groups + summary index available before any
                // network timeout can delay or reorder Home.
                npub = SonarCore.start()
                SonarCore.saveBlob(NPUB_BLOB_KEY, npub) // restored at next construction
                localCoreReady = true
                refreshChats()
                recomputeConversations()
                homeMessagesHydrated = true

                // Relay attach replaces the local-only node in the background
                // using the same encrypted DB. The already-painted Home model
                // remains authoritative while sockets connect.
                npub = SonarCore.connectRelays()
                SonarCore.saveBlob(NPUB_BLOB_KEY, npub)
                SonarCore.installConversationListener()
                collectConversationChanges()
                started = true
                refreshMeshIdentity()
                // Publish our kind-0 profile so peers see our nickname, not npub.
                launch { runCatching { SonarCore.publishProfile(nick) } }
                // Descriptor publish runs after wallet setup so call metadata is
                // discoverable without racing a wallet-ready BOLT12 offer.
                updateBleDiscoveryPolicy()
                refreshKnownContactDescriptors(clearMisses = true)
                // Kind-0 names: boot-time fetches raced the relay connect and
                // missed — retry now, and once more after the sockets settle.
                launch {
                    refreshChatMemberProfiles(clearMisses = true)
                    delay(6_000)
                    refreshChatMemberProfiles(clearMisses = true)
                }
                setupWallet()
                refreshLocationChannels()
                refreshChats()
                recomputeConversations() // fold White Noise legs into mesh rows at launch
                drainPendingInviteTokens()
                // Bind the iroh call endpoint + start the call event loop early so
                // an incoming call rings without us having to place one first.
                launch { ensureCallStarted() }
                startMeshRealtimeLoop()
                startMarmotWakeLoop()
                poll()
                // Run the first housekeeping pass now instead of waiting a full
                // heartbeat — seeds notifications/unread/profiles at launch (the
                // old 4 s poll ran its first full cycle ~4 s in).
                requestHousekeeping()
            } catch (t: Throwable) {
                toast = "connect failed: ${t.message}"
            } finally {
                // If the encrypted DB itself failed to open, fall back to the
                // metadata snapshot rather than leaving Home in a loading state.
                homeMessagesHydrated = true
                connecting = false
            }
        }
    }

    /** Display title for a White Noise (Marmot) chat. A 1:1 group's stored name
     *  is blank, so fall back to the counterpart's short npub — never an empty
     *  title. Mirrors iOS `MarmotChatModel.title(for:)`. */
    fun chatTitle(chat: SonarChat): String {
        pendingMarmotNpub(chat.id)?.let { pending ->
            profilesByNpub[canonicalProfileKey(pending)]?.bestName?.let { return it }
            return shortNpub(pending)
        }
        pendingMarmotGroups[chat.id]?.let { return it.name }
        if (chat.name.isNotBlank()) return chat.name
        val others = otherMembers(chat)
        if (others.size != 1) return "Group chat"
        val other = others.first()
        // Prefer the counterpart's resolved kind-0 profile name; fetch it once if
        // not cached; fall back to a short npub until it lands.
        profilesByNpub[canonicalProfileKey(other)]?.bestName?.let { return it }
        ensureProfile(other)
        return shortNpub(other)
    }

    private fun shortNpub(value: String): String = shortNpubLabel(value)

    fun groupAuthorName(message: SonarMsg, isGroup: Boolean): String? {
        return resolveGroupAuthorName(message, isGroup, profilesByNpub, ::ensureProfile)
    }

    /** Re-fetch kind-0 profiles for every conversation member, optionally
     *  clearing the miss throttles first. Fetches fired while the relays were
     *  still connecting MISS and get throttled — this gives them a prompt
     *  second chance once connectivity arrives, instead of leaving npub
     *  titles until the ~30min housekeeping sweep. Bounded: distinct members
     *  of current chats + mesh links only. */
    private fun refreshChatMemberProfiles(clearMisses: Boolean) {
        if (clearMisses) {
            profileMissedAt.clear()
            profileFetches.clear()
        }
        val mine = canonicalProfileKey(npub)
        (chats.asSequence().flatMap { it.members.asSequence() } +
            meshChats.keys.asSequence().mapNotNull { npubStringForPeer(it) })
            .map { canonicalProfileKey(it) }
            .filter { it.isNotBlank() && it != mine }
            .distinct()
            .forEach { ensureProfile(it) }
    }

    /** Fetch + cache a peer's kind-0 profile, so their name replaces the
     *  raw npub in the chat list/header. */
    fun ensureProfile(otherNpub: String) {
        val key = canonicalProfileKey(otherNpub)
        if (key.isBlank() || key == canonicalProfileKey(npub)) return
        // Throttle re-fetches after a miss: chatTitle() calls this on every
        // list render, so without a TTL a peer with no kind-0 profile (or an
        // offline relay window) triggers a relay query per recomposition.
        val missedAt = profileMissedAt[key]
        if (missedAt != null && SonarClock.nowSecs() - missedAt < PROFILE_MISS_TTL_SECS) return
        val hadCachedProfile = profilesByNpub.containsKey(key) || profilesByNpub.containsKey(otherNpub)
        if (!profileFetches.add(key)) return        // fetch already in flight
        scope.launch {
            val p = SonarCore.fetchProfile(key)
            // Log the outcome only — a resolved display name is PII and this
            // tees into the user-shareable diagnostics bundle.
            sonarLog("SonarProfile", "kind-0 fetch ${key.take(12)}… → ${if (p?.bestName != null) "HIT" else "MISS"}")
            if (p?.bestName != null) {
                // Drop a legacy entry under the caller's ORIGINAL key only when
                // it differs from the canonical one — when the caller already
                // passed the canonical npub, `- otherNpub` would remove the
                // entry we just added (this kept the cache empty on every
                // device: names re-fetched from relays on each launch).
                val updated = profilesByNpub + (key to p)
                profilesByNpub = normalizedProfileCache(
                    if (otherNpub != key) updated - otherNpub else updated
                )
                profileFetchedAt[key] = SonarClock.nowSecs()
                profileMissedAt.remove(key)
                persistProfileCache()
                if (isMeshRelevantNpub(key)) recomputeConversations()
            } else {
                profileMissedAt[key] = SonarClock.nowSecs()
                if (!hadCachedProfile) profileFetches.remove(key)
            }
        }
    }

    private fun isMeshRelevantNpub(npubKey: String): Boolean =
        (meshChats.keys.asSequence() + foldedGroupPeerIds.values.asSequence()).any { pid ->
            npubStringForPeer(pid)?.let { canonicalProfileKey(it) } == npubKey
        }

    private fun canonicalNpubHex(value: String): String? {
        val t = value.trim()
        if (t.length == 64 && t.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            return t.lowercase()
        }
        return chat.bitchat.sonar.crypto.Bech32.decode(t)
            ?.takeIf { it.hrp == "npub" && it.data.size == 32 }
            ?.data
            ?.toHexLower()
    }

    private fun ensureSonarDescriptor(npubOrHex: String) {
        val npubHex = canonicalNpubHex(npubOrHex) ?: return
        ensureSonarDescriptorHex(npubHex)
    }

    private fun ensureSonarDescriptorHex(npubHex: String) {
        val key = npubHex.lowercase()
        val now = SonarClock.nowSecs()
        val fetchedAt = sonarDescriptorFetchedAt[key]
        if (sonarDescriptorsByNpubHex[key] != null && fetchedAt != null && now - fetchedAt < SONAR_DESCRIPTOR_TTL_SECS) {
            return
        }
        val missedAt = sonarDescriptorMissedAt[key]
        if (missedAt != null && now - missedAt < SONAR_DESCRIPTOR_MISS_TTL_SECS) return
        if (!sonarDescriptorFetches.add(key)) return
        scope.launch {
            performDescriptorFetch(key)
        }
    }

    private suspend fun fetchSonarDescriptorSync(
        npubHex: String,
        bypassRecentMiss: Boolean = true,
    ): SonarDescriptor? {
        val key = npubHex.lowercase()
        val now = SonarClock.nowSecs()
        val cached = sonarDescriptorsByNpubHex[key]
        val hasBolt12 = cached?.bolt12Offer?.isNotBlank() == true
        val fetchedAt = sonarDescriptorFetchedAt[key]
        if (hasBolt12 && fetchedAt != null && now - fetchedAt < SONAR_DESCRIPTOR_TTL_SECS) {
            return cached
        }
        val missedAt = sonarDescriptorMissedAt[key]
        if (!bypassRecentMiss && missedAt != null && now - missedAt < SONAR_DESCRIPTOR_MISS_TTL_SECS) {
            return sonarDescriptorsByNpubHex[key]
        }
        sonarDescriptorFetches.add(key)
        performDescriptorFetch(key)
        return sonarDescriptorsByNpubHex[key]
    }

    private suspend fun performDescriptorFetch(key: String) {
        val descriptor = runCatching { SonarCore.fetchSonarDescriptor(key) }.getOrNull()
        if (descriptor != null) {
            sonarDescriptorsByNpubHex = sonarDescriptorsByNpubHex + (key to descriptor)
            sonarDescriptorFetchedAt[key] = SonarClock.nowSecs()
            sonarDescriptorMissedAt.remove(key)
        } else {
            sonarDescriptorMissedAt[key] = SonarClock.nowSecs()
        }
        sonarDescriptorFetches.remove(key)
    }

    private fun refreshKnownContactDescriptors(clearMisses: Boolean = false) {
        for (npubHex in linkByFp.values) {
            if (clearMisses) {
                sonarDescriptorMissedAt.remove(npubHex.lowercase())
            }
            ensureSonarDescriptorHex(npubHex)
        }
    }

    private fun persistProfileCache() {
        val encoded = encodeProfileCache(profilesByNpub)
        sonarLog("SonarProfile", "persist cache: ${profilesByNpub.size} profiles → ${encoded.length} chars")
        SonarCore.saveBlob(PROFILE_CACHE_BLOB_KEY, encoded)
    }

    fun openChat(chat: SonarChat) {
        push(Screen.Chat(chat.id, chatTitle(chat)))
        pendingMarmotNpub(chat.id)?.let { pendingNpub ->
            messages = visibleMessagesForChat(chat.id, withSendEchoes(chat.id, emptyList()))
            ensureProfile(pendingNpub)
            ensureSonarDescriptor(pendingNpub)
            startPendingMarmotChat(pendingNpub, chat.id)
            return
        }
        if (isPendingMarmotGroup(chat.id)) {
            messages = visibleMessagesForChat(chat.id, withSendEchoes(chat.id, emptyList()))
            return
        }
        val readChatIds = directMarmotChatIds(chat.id)
        unreadByChat = unreadByChat - readChatIds.toSet()
        // Local-first paint (Signal-Comparable Performance Rule): show the
        // cached snapshot synchronously so the transcript never opens empty;
        // the bounded DB page + media/echo merge below replaces it async.
        messages = visibleMessagesForChat(
            chat.id,
            withSendEchoes(chat.id, chatSnapshotMessagesByChat[chat.id].orEmpty()),
        )
        scope.launch {
            for (readId in readChatIds) {
                runCatching { SonarCore.markConversationRead(readId) }
            }
            val local = withSendEchoes(chat.id, mergePendingMediaUploads(chat.id, marmotMessagesPageForChat(chat.id)))
            val visibleLocal = visibleMessagesForChat(chat.id, local)
            messages = visibleLocal
            processPayLines(chat.id, visibleLocal)
            for (m in visibleLocal) if (!m.mine && m.senderNpub.isNotBlank()) ensureProfile(m.senderNpub)
            runCatching { refreshChats() }
            if ((screen as? Screen.Chat)?.id == chat.id) {
                val fresh = withSendEchoes(chat.id, mergePendingMediaUploads(chat.id, marmotMessagesPageForChat(chat.id)))
                val visibleFresh = visibleMessagesForChat(chat.id, fresh)
                messages = visibleFresh
                processPayLines(chat.id, visibleFresh)
            }
        }
    }

    /** Open the 1:1 DM with a radar peer. The conversation auto-picks transport:
     *  BLE mesh (Noise) while in Bluetooth range, White Noise (Marmot) when out of
     *  range for a Sonar peer — both legs merged into one thread. [pay] auto-opens
     *  the payment sheet (radar "Send sats"). */
    fun openDm(peerId: String, name: String, pay: Boolean = false) {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        val id = meshChatId(canonicalPeerId)
        if (name.isNotBlank()) rememberMeshName(canonicalPeerId, name)
        push(Screen.Chat(id, name, pay))
        messages = visibleMessagesForChat(id, mergedMeshMessages(canonicalPeerId)) // immediate merged alias view; Marmot leg merges in async
        processPayLines(id, messages)
        scope.launch {
            refreshOpenDm(canonicalPeerId) // hydrate local Marmot transcript before chat list refresh
            refreshChats()
            // Reconcile the open transcript after chat-list refresh may discover
            // the peer's Marmot group mapping.
            refreshOpenDm(canonicalPeerId)
        }
    }

    private fun meshChatId(peerId: String) = "mesh:$peerId"
    private fun meshPeerId(chatId: String) = chatId.removePrefix("mesh:")
    private fun isMeshChat(chatId: String) = chatId.startsWith("mesh:")

    fun back() {
        cleanupPreviewTempFiles()
        if (stack.size > 1) stack = stack.dropLast(1)
        if (stack.lastOrNull() !is Screen.Chat) messages = emptyList()
        scope.launch { refreshChats() }
    }

    /** Desktop master-detail helper: collapse the nav stack to [Screen.Home] so
     *  the content pane shows the welcome placeholder. Called before selecting a
     *  sidebar item so the stack never grows unbounded and a screen's Back button
     *  deselects (returns to the welcome pane) instead of walking history. */
    fun resetToHome() {
        cleanupPreviewTempFiles()
        if (stack.size > 1) { stack = listOf(Screen.Home); messages = emptyList() }
    }

    /** True when the desktop content pane should show the welcome placeholder. */
    val isHome: Boolean get() = stack.size == 1

    /** Delete a 1:1 Marmot chat locally, or leave a multi-member Marmot group. */
    fun deleteMarmotChat(chatId: String) {
        if (isPendingMarmotGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        val wasOpen = (stack.lastOrNull() as? Screen.Chat)?.id == chatId
        val isGroup = chats.firstOrNull { it.id == chatId }?.let { !isDirectMarmotChat(it) } == true
        // A deduped direct row can represent several duplicate Marmot groups for
        // the same peer; delete the whole set so hidden duplicates don't resurface.
        val deleteIds = if (isGroup) listOf(chatId) else directMarmotChatIds(chatId)
        val deleteIdSet = deleteIds.toSet()
        chats = chats.filterNot { it.id in deleteIdSet }
        for (id in deleteIds) { lastSeenTs.remove(id); lastNotifiedTs.remove(id) }
        if (wasOpen && stack.size > 1) stack = stack.dropLast(1) // pop WITHOUT refresh
        scope.launch {
            try {
                if (isGroup) {
                    SonarCore.leaveGroup(chatId)
                } else {
                    for (id in deleteIds) SonarCore.deleteChat(id)
                }
            } catch (t: Throwable) {
                toast = if (isGroup) "couldn't leave group: ${t.message}" else "couldn't delete chat: ${t.message}"
            }
            refreshChats()
        }
    }

    /** Delete ONE BLE-mesh private conversation locally (in-memory + on-disk). */
    fun deleteMeshDm(peerId: String) {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        val aliases = meshPeerAliases(canonicalPeerId)
        val chatId = meshChatId(canonicalPeerId)
        val wasOpen = (stack.lastOrNull() as? Screen.Chat)?.id == chatId
        val foldedGroups = (
            npubRawFor(canonicalPeerId)?.let { marmotGroupsForNpub(it) }.orEmpty() +
                chats.filter { group ->
                    isDirectMarmotChat(group) &&
                        peerIdForMarmotGroup(group)?.let { it in aliases } == true
                }
            ).distinctBy { it.id }
        val foldedGroupIdsToDelete = foldedGroups.mapTo(hashSetOf()) { it.id }
        aliases.forEach { alias ->
            meshChats.remove(alias)
            meshChatNames.remove(alias)
        }
        meshDmRows = meshDmRows.filterNot { row -> row.peerId in aliases }
        if (foldedGroupIdsToDelete.isNotEmpty()) {
            chats = chats.filterNot { it.id in foldedGroupIdsToDelete }
            foldedGroupIds = foldedGroupIds - foldedGroupIdsToDelete
            foldedGroupPeerIds = foldedGroupPeerIds.filterKeys { it !in foldedGroupIdsToDelete }
            foldedGroupIdsToDelete.forEach {
                groupFoldMap.remove(it)
                lastSeenTs.remove(it)
                lastNotifiedTs.remove(it)
                unreadByChat = unreadByChat - it
            }
            persistGroupFolds()
            clearChatSnapshot()
        }
        updateBleDiscoveryPolicy()
        if (wasOpen && stack.size > 1) stack = stack.dropLast(1)
        scope.launch {
            aliases.forEach { MessageStore.deleteMeshDm(it) }
            foldedGroups.forEach { group ->
                runCatching { SonarCore.deleteChat(group.id) }
                    .onFailure { toast = "couldn't delete chat: ${it.message}" }
            }
            if (foldedGroups.isNotEmpty()) refreshChats()
        }
    }

    fun startChat(peer: String) {
        val p = peer.trim()
        if (p.isEmpty()) return
        val pendingId = pendingMarmotChatId(p)
        val canonicalPeer = canonicalProfileKey(p)
        val npubHex = canonicalNpubHex(canonicalPeer)
        if (pendingId != null && npubHex != null) {
            marmotGroupForNpub(npubHex.hexToBytesOrEmpty())?.let { existing ->
                openChat(existing)
                return
            }
            putPendingMarmotChat(pendingId, canonicalPeer)
            ensureProfile(canonicalPeer)
            ensureSonarDescriptor(canonicalPeer)
            push(Screen.Chat(pendingId, profilesByNpub[canonicalProfileKey(canonicalPeer)]?.bestName ?: shortNpub(canonicalPeer)))
            messages = visibleMessagesForChat(pendingId, withSendEchoes(pendingId, emptyList()))
            startPendingMarmotChat(canonicalPeer, pendingId)
            return
        }
        scope.launch {
            try {
                val chatId = SonarCore.startChat(p)
                refreshChats()
                val chat = chats.firstOrNull { it.id == chatId }
                if (chat != null) {
                    openChat(chat)
                } else {
                    push(Screen.Chat(chatId, shortNpub(p)))
                    messages = marmotMessagesPageForChat(chatId)
                }
            } catch (t: Throwable) {
                toast = "couldn't start: ${t.message}"
            }
        }
    }

    private fun startPendingMarmotChat(peerNpub: String, pendingChatId: String) {
        val canonicalPeer = canonicalProfileKey(peerNpub)
        val npubHex = canonicalNpubHex(canonicalPeer) ?: return
        ensureProfile(canonicalPeer)
        putPendingMarmotChat(pendingChatId, canonicalPeer)
        marmotGroupForNpub(npubHex.hexToBytesOrEmpty())?.let { existing ->
            scope.launch { finishPendingMarmotChat(npubHex, canonicalPeer, pendingChatId, existing.id) }
            return
        }
        if (!startingMarmotChats.add(npubHex)) return
        val setupToken = nextPendingMarmotSetupToken(pendingChatId)
        val setupJob = scope.launch {
            try {
                val chatId = SonarCore.startChat(npubHex)
                finishPendingMarmotChat(npubHex, canonicalPeer, pendingChatId, chatId, setupToken = setupToken)
            } catch (t: Throwable) {
                if (failPendingMarmotChat(npubHex, pendingChatId, setupToken)) {
                    toast = "couldn't start secure chat: ${t.message}"
                }
            } finally {
                clearPendingMarmotSetup(pendingChatId, npubHex, setupToken)
            }
        }
        pendingMarmotSetupJobs[pendingChatId] = setupJob
    }

    private suspend fun finishPendingMarmotChat(
        npubHex: String,
        peerNpub: String,
        pendingChatId: String,
        chatId: String,
        refreshFirst: Boolean = true,
        setupToken: Long? = null,
    ) {
        if (!isActivePendingMarmotSetup(pendingChatId, peerNpub, setupToken)) return
        if (setupToken == null) cancelPendingMarmotSetup(pendingChatId, npubHex)
        pendingMarmotChatNpubs = pendingMarmotChatNpubs - pendingChatId
        if (refreshFirst) refreshChats()
        val chat = chats.firstOrNull { it.id == chatId }
            ?: SonarChat(id = chatId, name = "", members = listOf(npub, peerNpub))
        moveSendEchoes(pendingChatId, chatId)
        stack = stack.map { screen ->
            if (screen is Screen.Chat && screen.id == pendingChatId) {
                screen.copy(id = chatId, name = chatTitle(chat))
            } else {
                screen
            }
        }
        flushPendingDirectMarmot(npubHex, chatId)
        val openChatId = (screen as? Screen.Chat)?.id
        if (openChatId == chatId) {
            messages = visibleMessagesForChat(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))))
            processPayLines(chatId, messages)
            processCallLines(chatId, messages)
        }
    }

    private suspend fun resolvePendingMarmotChats() {
        if (pendingMarmotChatNpubs.isEmpty()) return
        for ((pendingChatId, pending) in pendingMarmotChatNpubs.toMap()) {
            val canonicalPeer = canonicalProfileKey(pending.peerNpub)
            val npubHex = canonicalNpubHex(canonicalPeer) ?: continue
            val existing = marmotGroupForNpub(npubHex.hexToBytesOrEmpty()) ?: continue
            finishPendingMarmotChat(npubHex, canonicalPeer, pendingChatId, existing.id, refreshFirst = false)
        }
    }

    private fun failPendingMarmotChat(npubHex: String, pendingChatId: String, setupToken: Long? = null): Boolean {
        if (!isActivePendingMarmotSetup(pendingChatId, pendingMarmotChatNpubs[pendingChatId]?.peerNpub, setupToken)) return false
        pendingMarmotChatNpubs = pendingMarmotChatNpubs - pendingChatId
        pendingDirectMarmotSends.remove(npubHex)
        pendingSendEchoes[pendingChatId].orEmpty().map { it.id }.forEach { echoId ->
            failSendEcho(pendingChatId, echoId)
        }
        pendingSendEchoes.remove(pendingChatId)
        return true
    }

    private fun sendPendingMarmotChat(chatId: String, peerNpub: String, text: String) {
        val npubHex = canonicalNpubHex(peerNpub) ?: return
        val echo = createSendEcho(chatId, text)
        messages = (messages + echo).sortedBy { it.tsSecs }
        val queue = pendingDirectMarmotSends.getOrPut(npubHex) { mutableListOf() }
        queue.add(PendingDirectMarmotSend(chatId, text, echo.id))
        if (queue.size > PENDING_MARMOT_DIRECT_SEND_QUEUE_LIMIT) {
            val dropped = queue.removeAt(0)
            failSendEcho(dropped.pendingChatId, dropped.echoId)
            toast = "Still setting up this chat — wait before sending more."
        }
        startPendingMarmotChat(peerNpub, chatId)
    }

    private suspend fun flushPendingDirectMarmot(npubHex: String, chatId: String) {
        val queued = pendingDirectMarmotSends.remove(npubHex).orEmpty()
        for (send in queued) {
            runCatching { SonarCore.send(chatId, send.text) }
                .onSuccess { clearSendEcho(chatId, send.echoId) }
                .onFailure {
                    failSendEcho(chatId, send.echoId)
                    toast = "send failed: ${it.message}"
                }
        }
    }

    private fun pendingMarmotGroupId(seed: String = randomMeshId()): String =
        PENDING_MARMOT_GROUP_PREFIX + seed

    private fun openPendingMarmotGroup(pendingId: String, pending: PendingMarmotGroup) {
        pendingMarmotGroups = pendingMarmotGroups + (pendingId to pending)
        push(Screen.Chat(pendingId, pending.name))
        messages = visibleMessagesForChat(pendingId, withSendEchoes(pendingId, emptyList()))
    }

    private fun startPendingMarmotGroupCreation(pendingChatId: String) {
        val pending = pendingMarmotGroups[pendingChatId] ?: return
        if (pendingMarmotGroupSetupJobs.containsKey(pendingChatId)) return
        val setupToken = nextPendingMarmotGroupSetupToken(pendingChatId)
        val setupJob = scope.launch {
            try {
                val chatId = SonarCore.startGroup(pending.members, pending.name)
                finishPendingMarmotGroup(pendingChatId, chatId, setupToken = setupToken)
            } catch (t: Throwable) {
                if (failPendingMarmotGroup(pendingChatId, setupToken)) {
                    toast = "couldn’t create group: ${t.message}"
                }
            } finally {
                clearPendingMarmotGroupSetup(pendingChatId, setupToken)
            }
        }
        pendingMarmotGroupSetupJobs[pendingChatId] = setupJob
    }

    private fun startPendingMarmotGroupAccept(pendingChatId: String, inviteId: String) {
        if (pendingMarmotGroupSetupJobs.containsKey(pendingChatId)) return
        val setupToken = nextPendingMarmotGroupSetupToken(pendingChatId)
        val setupJob = scope.launch {
            try {
                val chatId = SonarCore.acceptGroupInvite(inviteId)
                finishPendingMarmotGroup(pendingChatId, chatId, setupToken = setupToken)
            } catch (t: Throwable) {
                if (failPendingMarmotGroup(pendingChatId, setupToken)) {
                    toast = "couldn’t accept invite: ${t.message}"
                    refreshChats()
                }
            } finally {
                clearPendingMarmotGroupSetup(pendingChatId, setupToken)
            }
        }
        pendingMarmotGroupSetupJobs[pendingChatId] = setupJob
    }

    private suspend fun finishPendingMarmotGroup(
        pendingChatId: String,
        chatId: String,
        setupToken: Long? = null,
    ) {
        val pending = pendingMarmotGroups[pendingChatId] ?: return
        if (!isActivePendingMarmotGroupSetup(pendingChatId, setupToken)) return
        if (setupToken == null) cancelPendingMarmotGroupSetup(pendingChatId)
        pendingMarmotGroups = pendingMarmotGroups - pendingChatId
        refreshChats()
        val chat = chats.firstOrNull { it.id == chatId }
            ?: SonarChat(id = chatId, name = pending.name, members = listOf(npub) + pending.members)
        moveSendEchoes(pendingChatId, chatId)
        stack = stack.map { screen ->
            if (screen is Screen.Chat && screen.id == pendingChatId) {
                screen.copy(id = chatId, name = chatTitle(chat))
            } else {
                screen
            }
        }
        flushPendingMarmotGroupSends(pendingChatId, chatId)
        if ((screen as? Screen.Chat)?.id == chatId) {
            messages = visibleMessagesForChat(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))))
            processPayLines(chatId, messages)
            processCallLines(chatId, messages)
        }
    }

    private fun failPendingMarmotGroup(pendingChatId: String, setupToken: Long? = null): Boolean {
        if (!isActivePendingMarmotGroupSetup(pendingChatId, setupToken)) return false
        pendingMarmotGroups = pendingMarmotGroups - pendingChatId
        pendingMarmotGroupSends.remove(pendingChatId)
        pendingSendEchoes[pendingChatId].orEmpty().map { it.id }.forEach { echoId ->
            failSendEcho(pendingChatId, echoId)
        }
        pendingSendEchoes.remove(pendingChatId)
        if ((screen as? Screen.Chat)?.id == pendingChatId && stack.size > 1) {
            stack = stack.dropLast(1)
        }
        return true
    }

    private fun sendPendingMarmotGroup(chatId: String, text: String) {
        if (!isPendingMarmotGroup(chatId)) return
        val echo = createSendEcho(chatId, text)
        messages = (messages + echo).sortedBy { it.tsSecs }
        val queue = pendingMarmotGroupSends.getOrPut(chatId) { mutableListOf() }
        queue.add(PendingMarmotGroupSend(text, echo.id))
        if (queue.size > PENDING_MARMOT_GROUP_SEND_QUEUE_LIMIT) {
            val dropped = queue.removeAt(0)
            failSendEcho(chatId, dropped.echoId)
            toast = "Still setting up this group — wait before sending more."
        }
    }

    private suspend fun flushPendingMarmotGroupSends(pendingChatId: String, chatId: String) {
        val queued = pendingMarmotGroupSends.remove(pendingChatId).orEmpty()
        for (send in queued) {
            runCatching { SonarCore.send(chatId, send.text) }
                .onSuccess { clearSendEcho(chatId, send.echoId) }
                .onFailure {
                    failSendEcho(chatId, send.echoId)
                    toast = "send failed: ${it.message}"
                }
        }
    }

    /**
     * Handle a slash command (mirrors the iOS command autocomplete surface).
     * Returns true if [text] was recognized and consumed; false => send as text.
     * `target` is the current channel/peer label used when an emote omits args.
     */
    fun handleCommand(text: String, target: String, channelGeohash: String?, chatId: String?): Boolean {
        val parsed = SonarSlashCommands.parse(text)
        if (parsed == null) {
            // iOS parity (CommandProcessor default case): any slash-prefixed
            // draft is a command attempt — surface "unknown command" instead
            // of leaking it to the timeline as plaintext.
            val trimmed = text.trim()
            if (trimmed.startsWith("/")) {
                toast = "unknown command: /" + trimmed.drop(1).trimStart().substringBefore(' ')
                return true
            }
            return false
        }
        return when (parsed.command) {
            SonarSlashCommand.Who -> {
                push(Screen.Nearby)
                true
            }
            SonarSlashCommand.Message -> {
                handleMessageCommand(parsed.args)
                true
            }
            SonarSlashCommand.Clear -> {
                clearCurrentTimeline(channelGeohash, chatId)
                true
            }
            SonarSlashCommand.Hug -> {
                sendCommandEmote(parsed.args, target, channelGeohash, chatId, "hugs", "")
                true
            }
            SonarSlashCommand.Slap -> {
                sendCommandEmote(parsed.args, target, channelGeohash, chatId, "slaps", " around a bit with a large trout")
                true
            }
            SonarSlashCommand.Block,
            SonarSlashCommand.Unblock -> {
                handleBlockCommand(
                    args = parsed.args,
                    fallbackTarget = target,
                    channelGeohash = channelGeohash,
                    chatId = chatId,
                    blocked = parsed.command == SonarSlashCommand.Block,
                )
                true
            }
            SonarSlashCommand.Favorite,
            SonarSlashCommand.Unfavorite -> {
                handleFavoriteCommand(
                    args = parsed.args,
                    channelGeohash = channelGeohash,
                    chatId = chatId,
                    favorite = parsed.command == SonarSlashCommand.Favorite,
                )
                true
            }
        }
    }

    private data class CommandMeshTarget(val peerId: String, val name: String)

    private fun handleFavoriteCommand(args: String, channelGeohash: String?, chatId: String?, favorite: Boolean) {
        if (chatId == null && channelGeohash != "mesh") {
            toast = "Favorites are only for mesh peers."
            return
        }
        val target = resolveMeshCommandTarget(args, chatId)
        if (target == null) {
            toast = "Favorites are only for mesh peers."
            return
        }
        setFavoritePeer(target.peerId, target.name, favorite)
    }

    private fun handleBlockCommand(
        args: String,
        fallbackTarget: String,
        channelGeohash: String?,
        chatId: String?,
        blocked: Boolean,
    ) {
        val subject = args.trim().substringBefore(' ').trimCommandSubject()
        if (subject.isBlank()) {
            if (chatId != null) {
                if (isMultiMemberChat(chatId)) {
                    toast = "Choose a member to ${if (blocked) "block" else "unblock"}."
                    return
                }
                setContactBlocked(chatId, fallbackTarget, blocked)
            } else {
                toast = blockedSummary()
            }
            return
        }

        val openAuthor = resolveChannelAuthorTarget(subject)
        if (openAuthor != null) {
            setChannelAuthorBlocked(openAuthor.senderPubkey, openAuthor.author, blocked)
            return
        }
        if (!blocked && channelGeohash != null && channelGeohash != "mesh") {
            scope.launch {
                val author = resolveStoredChannelAuthorTarget(channelGeohash, subject)
                if (author != null) {
                    setChannelAuthorBlocked(author.senderPubkey, author.author, blocked = false)
                } else {
                    toast = "'$subject' not found"
                }
            }
            return
        }
        resolveMeshCommandTarget(subject, chatId)?.let {
            setPeerBlocked(it.peerId, it.name, blocked)
            return
        }
        if (normalizeSocialNostrKey(subject) != null) {
            setChannelAuthorBlocked(subject, subject.take(10), blocked)
            return
        }
        if (channelGeohash == "mesh") {
            setChannelAuthorBlocked(subject, subject.take(10), blocked)
            return
        }
        toast = "'$subject' not found"
    }

    private fun resolveMeshCommandTarget(args: String, chatId: String?): CommandMeshTarget? {
        val subject = args.trim().substringBefore(' ').trimCommandSubject()
        if (subject.isBlank()) {
            if (chatId != null && isMeshChat(chatId)) {
                val peerId = meshPeerId(chatId)
                return CommandMeshTarget(peerId, meshPeerName(peerId))
            }
            return null
        }
        return meshCommandTargets().firstOrNull { target ->
            target.name.equals(subject, ignoreCase = true) ||
                target.peerId.equals(subject, ignoreCase = true) ||
                target.peerId.startsWith(subject, ignoreCase = true)
        }
    }

    private fun resolveChannelAuthorTarget(subject: String): SonarChannelMsg? =
        channelMsgs.firstOrNull {
            !it.mine && (
                it.author.equals(subject, ignoreCase = true) ||
                    it.senderPubkey.equals(subject, ignoreCase = true) ||
                    it.senderPubkey.startsWith(subject, ignoreCase = true)
                )
        }

    private suspend fun resolveStoredChannelAuthorTarget(geohash: String, subject: String): SonarChannelMsg? =
        MessageStore.loadChannel(geohash).firstOrNull {
            !it.mine && (
                it.author.equals(subject, ignoreCase = true) ||
                    it.senderPubkey.equals(subject, ignoreCase = true) ||
                    it.senderPubkey.startsWith(subject, ignoreCase = true)
                )
        }

    private fun meshCommandTargets(): List<CommandMeshTarget> {
        val peerIds = linkedSetOf<String>()
        meshPeers.forEach { peerIds += meshPeerId(it.id) }
        peerIds += meshChatNames.keys
        peerIds += meshChats.keys
        peerIds += linkByFp.keys
        return peerIds.map { peerId ->
            val name = meshPeers.firstOrNull { meshPeerId(it.id) == peerId }?.name
                ?: meshChatNames[peerId]
                ?: ("mesh·" + peerId.take(6))
            CommandMeshTarget(peerId, name)
        }
    }

    private fun blockedSummary(): String {
        val peerCount = socialState.blockedPeers.size
        val nostrCount = socialState.blockedNostrPubkeys.size
        return if (peerCount == 0 && nostrCount == 0) {
            "No blocked contacts"
        } else {
            "Blocked: $peerCount mesh, $nostrCount channel"
        }
    }

    private fun handleMessageCommand(args: String) {
        val parts = args.split(Regex("\\s+"), limit = 2).filter { it.isNotBlank() }
        if (parts.isEmpty()) {
            push(Screen.Nearby)
            toast = SonarSlashCommands.usage(SonarSlashCommand.Message)
            return
        }
        val name = parts[0].trimCommandSubject()
        val body = parts.getOrNull(1).orEmpty().trim()
        val peer = meshPeers.firstOrNull {
            val peerId = meshPeerId(it.id)
            it.name.equals(name, ignoreCase = true) ||
                peerId.equals(name, ignoreCase = true) ||
                peerId.startsWith(name, ignoreCase = true)
        }
        if (peer != null) {
            val peerId = meshPeerId(peer.id)
            openDm(peerId, peer.name)
            if (body.isNotBlank()) sendDmAuto(peerId, body)
            return
        }
        if (name.startsWith("npub1") || canonicalNpubHex(name) != null) {
            startChat(name)
            if (body.isNotBlank()) toast = "Opening chat. Send the message after the secure chat is ready."
            return
        }
        toast = "'$name' not found"
    }

    private fun clearCurrentTimeline(channelGeohash: String?, chatId: String?) {
        when {
            channelGeohash != null -> {
                if (channelGeohash == "mesh") {
                    meshBroadcast = emptyList()
                    channelMsgs = emptyList()
                    toast = "Cleared this channel on this device"
                } else {
                    toast = "Geohash channels sync from relays; local clear is only available in Bluetooth mesh."
                }
            }
            chatId != null && isMeshChat(chatId) -> {
                val peerId = meshPeerId(chatId)
                val aliases = meshPeerAliases(peerId)
                val hasWhiteNoiseLeg = npubRawFor(peerId)?.let { marmotGroupsForNpub(it).isNotEmpty() }
                    ?: chats.any { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
                if (hasWhiteNoiseLeg) {
                    toast = "Use Delete chat to remove White Noise history"
                    return
                }
                aliases.forEach { alias ->
                    meshChats[alias] = emptyList()
                    persistMesh(alias)
                }
                messages = emptyList()
                refreshMeshDmRows()
                toast = "Cleared this chat on this device"
            }
            chatId != null -> {
                toast = "Use Delete chat to remove White Noise history"
            }
            else -> {
                toast = "Nothing to clear here"
            }
        }
    }

    private fun sendCommandEmote(
        args: String,
        fallbackTarget: String,
        channelGeohash: String?,
        chatId: String?,
        action: String,
        suffix: String,
    ) {
        val subject = commandSubject(args, fallbackTarget)
        if (subject.isNullOrBlank()) {
            toast = if (action == "hugs") {
                SonarSlashCommands.usage(SonarSlashCommand.Hug)
            } else {
                SonarSlashCommands.usage(SonarSlashCommand.Slap)
            }
            return
        }
        val who = nick.ifBlank { "you" }
        val line = "* $who $action $subject$suffix *"
        when {
            channelGeohash != null -> sendChannelMsg(channelGeohash, line)
            chatId != null -> send(chatId, line)
            else -> toast = "No active conversation for this command"
        }
    }

    private fun commandSubject(args: String, fallbackTarget: String): String? =
        args.trim().substringBefore(' ').trimCommandSubject()
            .takeIf { it.isNotBlank() }
            ?: fallbackTarget.trim().takeIf { it.isNotBlank() }

    private fun String.trimCommandSubject(): String =
        trim().removePrefix("@").trim()

    fun send(chatId: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (isContactBlocked(chatId)) {
            toast = "Unblock this contact before sending."
            return
        }
        if (isMeshChat(chatId)) { sendDmAuto(meshPeerId(chatId), t); return }
        pendingMarmotNpub(chatId)?.let { pendingNpub ->
            sendPendingMarmotChat(chatId, pendingNpub, t)
            return
        }
        if (isPendingMarmotGroup(chatId)) {
            sendPendingMarmotGroup(chatId, t)
            return
        }
        val echo = createSendEcho(chatId, t)
        messages = (messages + echo).sortedBy { it.tsSecs }
        scope.launch {
            try {
                SonarCore.send(chatId, t)
                clearSendEcho(chatId, echo.id)
                messages = visibleMessagesForChat(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))))
                processPayLines(chatId, messages)
                processCallLines(chatId, messages)
            } catch (e: Throwable) {
                failSendEcho(chatId, echo.id)
                toast = "send failed: ${e.message}"
            }
        }
    }

    // ── Optimistic send echoes ──
    // Mirrors iOS local echo: show the message immediately in the transcript
    // while the MLS encrypt + relay publish runs in the background. Keyed by
    // the UI chat ID (Marmot group hex for direct chats, "mesh:<peerId>" for
    // mesh-routed DMs).
    private val pendingSendEchoes = mutableMapOf<String, MutableList<SonarMsg>>()
    private val echoIdPrefix = "echo-"

    private fun createSendEcho(chatId: String, text: String, viaInternet: Boolean = true): SonarMsg {
        val echo = privateDmMessage(
            id = "$echoIdPrefix${randomMeshId()}",
            senderNpub = npub,
            text = text,
            mine = true,
            tsSecs = SonarClock.nowSecs(),
            viaInternet = viaInternet,
            state = "Sending",
        )
        pendingSendEchoes.getOrPut(chatId) { mutableListOf() }.add(echo)
        return echo
    }

    private fun clearSendEcho(chatId: String, echoId: String) {
        pendingSendEchoes[chatId]?.removeAll { it.id == echoId }
        if (pendingSendEchoes[chatId].isNullOrEmpty()) pendingSendEchoes.remove(chatId)
    }

    private fun failSendEcho(chatId: String, echoId: String) {
        val list = pendingSendEchoes[chatId] ?: return
        val idx = list.indexOfFirst { it.id == echoId }
        if (idx >= 0) list[idx] = list[idx].copy(state = "Couldn't send")
        messages = messages.map { if (it.id == echoId) it.copy(state = "Couldn't send") else it }
    }

    private fun moveSendEchoes(fromChatId: String, toChatId: String) {
        val moving = pendingSendEchoes.remove(fromChatId).orEmpty()
        if (moving.isEmpty()) return
        pendingSendEchoes.getOrPut(toChatId) { mutableListOf() }.addAll(moving)
    }

    private fun withSendEchoes(chatId: String, published: List<SonarMsg>): List<SonarMsg> {
        val echoes = pendingSendEchoes[chatId] ?: return published
        val fulfilled = mutableSetOf<String>()
        val consumedPublished = mutableSetOf<String>()
        val ownPublished = published.filter { it.mine }.groupBy { it.content }
        for (echo in echoes) {
            if (echo.state == "Couldn't send") continue
            val match = ownPublished[echo.content]
                ?.filter { it.id !in consumedPublished }
                ?.firstOrNull {
                    it.viaInternet == echo.viaInternet &&
                        it.tsSecs > echo.tsSecs && it.tsSecs - echo.tsSecs < 30
                }
            if (match != null) {
                fulfilled.add(echo.id)
                consumedPublished.add(match.id)
            }
        }
        echoes.removeAll { it.id in fulfilled }
        if (echoes.isEmpty()) {
            pendingSendEchoes.remove(chatId)
            return published
        }
        return (published.filterNot { it.id.startsWith(echoIdPrefix) } + echoes)
            .distinctBy { it.id }
            .sortedBy { it.tsSecs }
    }

    // ── Media preview (confirmation before send) ──
    data class PendingMediaPreview(
        val chatId: String,
        val tempPath: String,
        val filename: String,
        val mime: String,
        val caption: String = "",
    )

    var pendingMediaPreviews by mutableStateOf<List<PendingMediaPreview>>(emptyList())
    private var mediaPreviewGeneration = 0L

    private fun nextMediaPreviewGeneration(): Long {
        mediaPreviewGeneration += 1
        return mediaPreviewGeneration
    }

    private fun deletePreviewTempFilesAsync(previews: List<PendingMediaPreview>) {
        if (previews.isEmpty()) return
        scope.launch {
            withContext(Dispatchers.IO) {
                for (preview in previews) {
                    deleteTempMediaFile(preview.tempPath)
                }
            }
        }
    }

    private fun cleanupPreviewTempFiles() {
        nextMediaPreviewGeneration()
        val previews = pendingMediaPreviews
        pendingMediaPreviews = emptyList()
        deletePreviewTempFilesAsync(previews)
    }

    fun stageMediaPreview(chatId: String, data: ByteArray, filename: String, mime: String) {
        stageMediaPreviews(chatId, listOf(PickedPhoto(data, filename, mime)))
    }

    /** Stage one or more picked photos for the pre-send preview. All items are
     *  written to temp files off the UI thread (Signal-style: full quality
     *  until send confirmation); the batch replaces prior staged previews. */
    fun stageMediaPreviews(chatId: String, items: List<PickedPhoto>) {
        if ((screen as? Screen.Chat)?.id != chatId || items.isEmpty()) return
        val generation = nextMediaPreviewGeneration()
        val previous = pendingMediaPreviews
        pendingMediaPreviews = emptyList()
        deletePreviewTempFilesAsync(previous)
        scope.launch {
            val written = withContext(Dispatchers.IO) {
                items.map { item ->
                    val suffix = if (item.mime == "image/gif") ".gif" else ".img"
                    PendingMediaPreview(chatId, writeTempMediaFile(item.bytes, suffix), item.filename, item.mime)
                }
            }
            if (mediaPreviewGeneration != generation || (screen as? Screen.Chat)?.id != chatId) {
                withContext(Dispatchers.IO) { for (p in written) deleteTempMediaFile(p.tempPath) }
                return@launch
            }
            pendingMediaPreviews = written
        }
    }

    fun confirmSendPreview(chatId: String? = null) {
        val items = if (chatId == null) {
            pendingMediaPreviews
        } else {
            pendingMediaPreviews.filter { it.chatId == chatId }
        }
        if (items.isEmpty()) return
        nextMediaPreviewGeneration()
        pendingMediaPreviews = if (chatId == null) {
            emptyList()
        } else {
            pendingMediaPreviews.filterNot { it.chatId == chatId }
        }
        scope.launch {
            // Finalize every staged item IN ORDER (lazy jpeg re-encode happens
            // here, on send confirmation — Signal-style).
            val prepared = mutableListOf<Triple<String, PickedPhoto, Boolean>>()
            var encodeFailed = false
            for (preview in items) {
                val raw = withContext(Dispatchers.IO) {
                    readTempMediaFile(preview.tempPath).also { deleteTempMediaFile(preview.tempPath) }
                } ?: continue
                if (preview.mime == "image/gif") {
                    prepared += Triple(preview.chatId, PickedPhoto(raw, preview.filename, preview.mime), true)
                } else {
                    val jpeg = withContext(Dispatchers.Default) { reencodeToJpeg(raw) }
                    if (jpeg == null) {
                        encodeFailed = true
                    } else {
                        prepared += Triple(preview.chatId, PickedPhoto(jpeg, "photo.jpg", "image/jpeg"), false)
                    }
                }
            }
            if (encodeFailed) toast = "Couldn't encode image."
            // Group per chat: 2+ items send as ONE album message (card deck);
            // a single item keeps the exact pre-album behavior.
            val chatsInOrder = prepared.map { it.first }.distinct()
            for (chat in chatsInOrder) {
                val list = prepared.filter { it.first == chat }.map { it.second }
                if (list.size > 1) {
                    val numbered = list.mapIndexed { idx, p ->
                        PickedPhoto(p.bytes, numberedFilename(p.filename, idx + 1), p.mime)
                    }
                    sendImageAlbum(chat, numbered)
                } else {
                    list.firstOrNull()?.let { sendImage(chat, it.bytes, it.filename, it.mime) }
                }
            }
        }
    }

    /** "photo.jpg" + 2 → "photo-2.jpg". Distinct per-item filenames keep the
     *  pending-upload echo reconciliation (matched by filename) deterministic
     *  across an album's attachments. */
    private fun numberedFilename(filename: String, index: Int): String {
        val dot = filename.lastIndexOf('.')
        return if (dot <= 0) "$filename-$index"
        else "${filename.substring(0, dot)}-$index${filename.substring(dot)}"
    }

    fun cancelPreview(chatId: String? = null) {
        nextMediaPreviewGeneration()
        val toRemove = if (chatId == null) {
            pendingMediaPreviews
        } else {
            pendingMediaPreviews.filter { it.chatId == chatId }
        }
        pendingMediaPreviews = if (chatId == null) {
            emptyList()
        } else {
            pendingMediaPreviews.filterNot { it.chatId == chatId }
        }
        deletePreviewTempFilesAsync(toRemove)
    }

    // ── Media (White Noise / Marmot MIP-04) ──
    /** Decrypted-media cache (raw bytes), keyed by the ciphertext's Blossom URL. */
    private val mediaCache = mutableMapOf<String, ByteArray>()
    private val stickerPackCache = linkedMapOf<String, SonarStickerPack>()
    private val stickerImageCache = linkedMapOf<String, ByteArray>()
    private val installedPackCoordinates = mutableSetOf<String>()
    private val pendingMediaUrlPrefix = "pending-media-"

    private data class PendingMediaUpload(
        val message: SonarMsg,
        val data: ByteArray,
        val filename: String,
        val mime: String,
        val startedAtSecs: Long,
        val pendingUrl: String,
        val existingMediaUrls: Set<String>,
        val completedOrder: Long? = null,
    )

    private val pendingMediaUploads = mutableMapOf<String, MutableList<PendingMediaUpload>>()
    private var pendingMediaCompletionOrder = 0L

    private fun rememberPendingMediaUpload(chatId: String, upload: PendingMediaUpload) {
        rememberPendingMediaUploads(chatId, listOf(upload))
    }

    /** Track a batch of uploads that share one pending echo message (an album):
     *  prior entries for the same message id are replaced once, then every
     *  per-attachment entry is appended so each reconciles independently. */
    private fun rememberPendingMediaUploads(chatId: String, uploads: List<PendingMediaUpload>) {
        if (uploads.isEmpty()) return
        val pending = pendingMediaUploads.getOrPut(chatId) { mutableListOf() }
        val ids = uploads.mapTo(mutableSetOf()) { it.message.id }
        pending.removeAll { it.message.id in ids }
        pending += uploads
    }

    private fun markPendingMediaCompleted(chatId: String, pendingId: String) {
        val pending = pendingMediaUploads[chatId] ?: return
        // An album shares one echo message across N per-attachment entries —
        // mark every entry so each reconciles against the canonical message.
        for (index in pending.indices) {
            if (pending[index].message.id == pendingId && pending[index].completedOrder == null) {
                pendingMediaCompletionOrder += 1
                pending[index] = pending[index].copy(completedOrder = pendingMediaCompletionOrder)
            }
        }
    }

    private fun markPendingMediaFailed(chatId: String, pendingId: String) {
        val pending = pendingMediaUploads[chatId] ?: return
        for (index in pending.indices) {
            if (pending[index].message.id == pendingId) {
                val upload = pending[index]
                pending[index] = upload.copy(message = upload.message.copy(state = "Couldn't send"))
            }
        }
    }

    private fun mergePendingMediaUploads(chatId: String, published: List<SonarMsg>): List<SonarMsg> {
        val pending = pendingMediaUploads[chatId] ?: return published.sortedBy { it.tsSecs }
        // Track matched entries INDIVIDUALLY, not by message id: an album's N
        // attachments share one echo message id, so removing by id would drop the
        // whole echo (and its not-yet-cached siblings) the instant one attachment
        // reconciles. An echo survives until every one of its entries matches.
        // Key matches on the unique per-entry pendingUrl (a data class with a
        // ByteArray field hashes on array identity, which is fragile in a Set).
        val matchedUrls = mutableSetOf<String>()
        val usedCanonicalUrls = mutableSetOf<String>()
        val completedUploads = pending
            .filter { it.message.state != "Couldn't send" && it.completedOrder != null }
            .sortedBy { it.completedOrder }
        for (upload in completedUploads) {
            val ok = cacheUploadedMediaBytes(
                published,
                upload.data,
                upload.filename,
                upload.mime,
                upload.startedAtSecs,
                upload.pendingUrl,
                upload.existingMediaUrls,
                usedCanonicalUrls,
            )
            if (ok) matchedUrls += upload.pendingUrl
        }
        val survivors = pending.filterNot { it.pendingUrl in matchedUrls }
        if (survivors.isEmpty()) {
            pendingMediaUploads.remove(chatId)
            return published.sortedBy { it.tsSecs }
        }
        pendingMediaUploads[chatId] = survivors.toMutableList()
        // Distinct by id: an album echo appears once per surviving attachment.
        val survivorMessages = survivors.map { it.message }.distinctBy { it.id }
        val survivorIds = survivorMessages.mapTo(mutableSetOf()) { it.id }
        return (published.filterNot { it.id in survivorIds } + survivorMessages)
            .distinctBy { it.id }
            .sortedBy { it.tsSecs }
    }

    private suspend fun existingPublishedMediaUrls(groupId: String): Set<String> =
        runCatching { SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT) }
            .getOrDefault(messages)
            .asSequence()
            .flatMap { it.media.asSequence() }
            .map { it.url }
            .filterNot { it.startsWith(pendingMediaUrlPrefix) }
            .toSet()

    /** The Marmot group id backing [chatId]: the chat id itself for a White Noise
     *  chat, or the Sonar peer's group for a mesh-routed DM. null ⇒ no group yet. */
    private fun resolveMarmotGroupId(chatId: String): String? {
        if (chatId.startsWith(PENDING_MARMOT_CHAT_PREFIX) || chatId.startsWith(PENDING_MARMOT_GROUP_PREFIX)) return null
        if (!isMeshChat(chatId)) return chatId
        val raw = npubRawFor(meshPeerId(chatId)) ?: return null
        return marmotGroupForNpub(raw)?.id
    }

    private fun meshMediaUrl(peerId: String, messageId: String, filename: String): String =
        "$MESH_MEDIA_URL_PREFIX$peerId:$messageId:$filename"

    private fun mediaPreviewLabel(mime: String, filename: String): String = when {
        mime.startsWith("image/") -> "Image"
        mime.startsWith("audio/") -> "Voice note"
        filename.isNotBlank() -> filename
        else -> "File"
    }

    /** True if [chatId] can carry media over live BLE mesh or an existing Marmot group. */
    fun canSendMedia(chatId: String): Boolean =
        !isContactBlocked(chatId) && (
            (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) ||
                resolveMarmotGroupId(chatId) != null
            )

    /** Send an image to a White Noise chat: encrypt + Blossom upload + publish. */
    fun sendImage(chatId: String, data: ByteArray, filename: String, mime: String) {
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        if (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            if (sendMeshMedia(meshPeerId(chatId), data, filename, mime)) return
            if (resolveMarmotGroupId(chatId) == null) return
        }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) { toast = "Start the secure chat first, then send a photo."; return@launch }
            val pendingId = "pending-media-${randomMeshId()}"
            val pendingUrl = "$pendingMediaUrlPrefix${randomMeshId()}"
            val startedAtSecs = SonarClock.nowSecs()
            val existingMediaUrls = existingPublishedMediaUrls(groupId)
            val pending = SonarMsg(
                id = pendingId,
                senderNpub = npub,
                content = "",
                mine = true,
                tsSecs = startedAtSecs,
                viaInternet = true,
                media = listOf(SonarMedia(pendingUrl, mime, filename, null, null, null)),
                state = "Uploading",
            )
            rememberPendingMediaUpload(
                chatId,
                PendingMediaUpload(
                    message = pending,
                    data = data,
                    filename = filename,
                    mime = mime,
                    startedAtSecs = startedAtSecs,
                    pendingUrl = pendingUrl,
                    existingMediaUrls = existingMediaUrls,
                )
            )
            mediaCache[pendingUrl] = data
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            try {
                SonarCore.sendMedia(groupId, data, filename, mime, "")
                markPendingMediaCompleted(chatId, pendingId)
                // Refresh the open conversation so the sent image shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val mesh = mergedMeshMessages(peerId)
                            val wn = marmotMessagesForPeer(peerId)
                            val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
                            setCurrentVisibleMessages(chatId, merged)
                        } else {
                            val fresh = SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (e: Throwable) {
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
                }
                toast = "couldn't send photo: ${e.message}"
            }
        }
    }

    /** Send N images to one chat as ONE album message (single event, N imeta
     *  tags) that renders as the swipeable card deck. BLE mesh has no album
     *  packet, so a mesh-linked peer gets N individual image sends. */
    fun sendImageAlbum(chatId: String, items: List<PickedPhoto>) {
        if (items.size <= 1) {
            items.firstOrNull()?.let { sendImage(chatId, it.bytes, it.filename, it.mime) }
            return
        }
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        if (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            // Mesh has no album packet — send each over mesh and return. Sending
            // per-item (not `all {}`, which short-circuits mid-batch) avoids a
            // partial mesh send that then double-sends via the Marmot album path.
            for (item in items) sendMeshMedia(meshPeerId(chatId), item.bytes, item.filename, item.mime)
            return
        }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) { toast = "Start the secure chat first, then send a photo."; return@launch }
            val pendingId = "pending-media-${randomMeshId()}"
            val startedAtSecs = SonarClock.nowSecs()
            val existingMediaUrls = existingPublishedMediaUrls(groupId)
            // One echo message carrying every attachment (the card deck paints
            // immediately); one per-attachment upload entry for reconciliation.
            val pendingUrls = items.map { "$pendingMediaUrlPrefix${randomMeshId()}" }
            val pending = SonarMsg(
                id = pendingId,
                senderNpub = npub,
                content = "",
                mine = true,
                tsSecs = startedAtSecs,
                viaInternet = true,
                media = items.mapIndexed { idx, item ->
                    SonarMedia(pendingUrls[idx], item.mime, item.filename, null, null, null)
                },
                state = "Uploading",
            )
            rememberPendingMediaUploads(
                chatId,
                items.mapIndexed { idx, item ->
                    PendingMediaUpload(
                        message = pending,
                        data = item.bytes,
                        filename = item.filename,
                        mime = item.mime,
                        startedAtSecs = startedAtSecs,
                        pendingUrl = pendingUrls[idx],
                        existingMediaUrls = existingMediaUrls,
                    )
                }
            )
            items.forEachIndexed { idx, item -> mediaCache[pendingUrls[idx]] = item.bytes }
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            try {
                SonarCore.sendMediaMulti(
                    groupId,
                    items.map { AlbumUpload(it.bytes, it.filename, it.mime) },
                    "",
                )
                markPendingMediaCompleted(chatId, pendingId)
                // Refresh the open conversation so the sent album shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val mesh = mergedMeshMessages(peerId)
                            val wn = marmotMessagesForPeer(peerId)
                            val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
                            setCurrentVisibleMessages(chatId, merged)
                        } else {
                            val fresh = SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (e: Throwable) {
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
                }
                toast = "couldn't send photos: ${e.message}"
            }
        }
    }

    private fun cacheUploadedMediaBytes(
        messages: List<SonarMsg>,
        data: ByteArray,
        filename: String,
        mime: String,
        startedAtSecs: Long,
        pendingUrl: String,
        existingMediaUrls: Set<String>,
        usedCanonicalUrls: MutableSet<String>,
    ): Boolean {
        val published = messages.asSequence()
            .filter { it.mine }
            .filter { it.tsSecs >= startedAtSecs }
            .sortedBy { it.tsSecs }
            .flatMap { it.media.asSequence() }
            .firstOrNull {
                it.filename == filename &&
                    it.mimeType == mime &&
                    !it.url.startsWith(pendingMediaUrlPrefix) &&
                    mediaCache[it.url] == null &&
                    it.url !in existingMediaUrls &&
                    it.url !in usedCanonicalUrls
            }
        if (published != null) {
            usedCanonicalUrls += published.url
            mediaCache[published.url] = data
            mediaCache.remove(pendingUrl)
            return true
        }
        return false
    }

    /** Send a recorded voice note (AAC .m4a bytes) to a White Noise chat or a
     *  live BLE mesh peer, using the same media bubble model as photos. */
    fun sendVoiceNote(chatId: String, bytes: ByteArray) {
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        val filename = "vn-${(1000..99999).random()}.m4a"
        val mime = "audio/mp4"
        if (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            if (sendMeshMedia(meshPeerId(chatId), bytes, filename, mime)) return
            if (resolveMarmotGroupId(chatId) == null) return
        }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) { toast = "Start the secure chat first to send a voice note."; return@launch }
            val pendingId = "pending-media-${randomMeshId()}"
            val pendingUrl = "$pendingMediaUrlPrefix${randomMeshId()}"
            val startedAtSecs = SonarClock.nowSecs()
            val existingMediaUrls = existingPublishedMediaUrls(groupId)
            val pending = SonarMsg(
                id = pendingId,
                senderNpub = npub,
                content = "",
                mine = true,
                tsSecs = startedAtSecs,
                viaInternet = true,
                media = listOf(SonarMedia(pendingUrl, mime, filename, null, null, null)),
                state = "Uploading",
            )
            rememberPendingMediaUpload(
                chatId,
                PendingMediaUpload(
                    message = pending,
                    data = bytes,
                    filename = filename,
                    mime = mime,
                    startedAtSecs = startedAtSecs,
                    pendingUrl = pendingUrl,
                    existingMediaUrls = existingMediaUrls,
                )
            )
            mediaCache[pendingUrl] = bytes
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            try {
                SonarCore.sendMedia(groupId, bytes, filename, mime, "")
                markPendingMediaCompleted(chatId, pendingId)
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val mesh = mergedMeshMessages(peerId)
                            val wn = marmotMessagesForPeer(peerId)
                            val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
                            setCurrentVisibleMessages(chatId, merged)
                        } else {
                            val fresh = SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (e: Throwable) {
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
                }
                toast = "couldn't send voice note: ${e.message}"
            }
        }
    }

    fun sendGifItem(chatId: String, item: SonarGifItem) {
        send(chatId, item.mediaUrl)
    }

    fun sendStickerItem(chatId: String, sticker: SonarStickerItem, packCoordinate: String) {
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val content = meshStickerContent(packCoordinate, sticker.shortcode, sticker.sha256)
            liveMeshRoutePeerId(peerId)?.let { route -> sendMesh(route, content); return }
            val raw = npubRawFor(peerId)
            if (raw != null) {
                when {
                    shouldUseMarmotRoute(peerId, raw) -> sendStickerOverMarmot(peerId, raw, packCoordinate, sticker)
                    canUseDirectNip17(peerId, raw) -> sendDirectNip17(peerId, raw, content)
                    else -> toast = "Out of range — add each other as favorites to continue over Nostr."
                }
                return
            }
            toast = "Not connected — stay close and try again"
            return
        }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) {
                toast = "Stickers require an encrypted chat"
                return@launch
            }
            try {
                SonarCore.sendSticker(groupId, packCoordinate, sticker.shortcode, sticker.sha256)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    suspend fun stickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: List<String> = emptyList(),
    ): SonarStickerPack? {
        val cacheKey = "30031:${authorPubkeyHex.lowercase()}:$identifier"
        stickerPackCache.remove(cacheKey)?.let { stickerPackCache[cacheKey] = it; return it }
        return try {
            SonarCore.fetchStickerPack(authorPubkeyHex, identifier, relayUrls).also {
                if (stickerPackCache.size >= 20) stickerPackCache.remove(stickerPackCache.keys.first())
                stickerPackCache[cacheKey] = it
            }
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun stickerImage(url: String, expectedSha256: String): ByteArray? {
        val cacheKey = "${expectedSha256.lowercase()}|$url"
        stickerImageCache.remove(cacheKey)?.let { stickerImageCache[cacheKey] = it; return it }
        return try {
            SonarCore.fetchStickerImage(url, expectedSha256).also {
                if (stickerImageCache.size >= 500) stickerImageCache.remove(stickerImageCache.keys.first())
                stickerImageCache[cacheKey] = it
            }
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun stickerImage(ref: SonarStickerRef): ByteArray? {
        val (author, identifier) = ref.packAddressParts() ?: return null
        val pack = stickerPack(author, identifier) ?: return null
        val sticker = pack.stickerMatching(ref) ?: return null
        return stickerImage(sticker.url, ref.plaintextSha256)
    }

    fun isPackInstalled(coordinate: String): Boolean =
        installedPackCoordinates.contains(coordinate.lowercase())

    suspend fun refreshInstalledPacks() {
        val coords = try { SonarCore.fetchInstalledPacks() } catch (_: Throwable) { emptyList() }
        installedPackCoordinates.clear()
        installedPackCoordinates.addAll(coords.map { it.lowercase() })
    }

    suspend fun installStickerPack(coordinate: String): Boolean {
        return try {
            SonarCore.installStickerPack(coordinate)
            installedPackCoordinates.add(coordinate.lowercase())
            true
        } catch (_: Throwable) {
            false
        }
    }

    suspend fun uninstallStickerPack(coordinate: String): Boolean {
        return try {
            SonarCore.uninstallStickerPack(coordinate)
            installedPackCoordinates.remove(coordinate.lowercase())
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** Download + decrypt a media attachment, cached by URL. */
    suspend fun mediaData(chatId: String, media: SonarMedia): ByteArray? {
        mediaCache[media.url]?.let { return it }
        if (media.url.startsWith(MESH_MEDIA_URL_PREFIX)) {
            val bytes = MessageStore.loadMeshMedia(media.url) ?: return null
            mediaCache[media.url] = bytes
            return bytes
        }
        val groupId = resolveMarmotGroupId(chatId) ?: return null
        return try {
            val bytes = SonarCore.fetchMedia(groupId, media.url)
            mediaCache[media.url] = bytes
            bytes
        } catch (e: Throwable) {
            null
        }
    }

    /** Auto-pick the transport for a radar-peer DM (mirrors iOS `sendDm`): a live
     *  Noise link ⇒ BLE mesh; otherwise White Noise (Marmot) for a Sonar peer, or
     *  account-level NIP-17 for a mutual-favorite plain bitchat peer. When neither
     *  route is available the message is queued in the outbox (mirrors iOS
     *  MessageRouter) and auto-sent when a route becomes available. */
    private fun sendDmAuto(peerId: String, text: String) {
        if (isMeshContactBlocked(peerId)) {
            toast = "Unblock this contact before sending."
            return
        }
        if (outbox.contains(peerId)) {
            enqueueOutbox(peerId, text)
            flushOutbox(peerId)
            toast = "Message queued and will send in order."
            return
        }
        liveMeshRoutePeerId(peerId)?.let { route -> sendMesh(route, text); return }
        val raw = npubRawFor(peerId)
        if (raw != null) {
            when {
                shouldUseMarmotRoute(peerId, raw) -> sendOverMarmot(peerId, raw, text)
                canUseDirectNip17(peerId, raw) -> sendDirectNip17(peerId, raw, text)
                else -> {
                    enqueueOutbox(peerId, text)
                    toast = "Out of range — add each other as favorites to continue over Nostr."
                }
            }
            return
        }
        // Neither BLE mesh link nor npub available — queue for later delivery.
        enqueueOutbox(peerId, text)
        toast = "Out of range — message queued and will send automatically."
    }

    /** ☎CALL signaling uses the lowest-latency route available for the SAME Sonar
     *  conversation: immediate BLE when the Noise link is live, otherwise the
     *  folded White Noise group learned during discovery. */
    private suspend fun sendCallControl(chatId: String, text: String): Boolean {
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val routePeerId = liveMeshRoutePeerId(peerId)
            if (routePeerId != null) {
                val ok = MeshRadio.sendMeshDmNow(routePeerId, randomMeshId(), text)
                if (!ok) {
                    toast = "Call route dropped — try again in a moment."
                    sonarLog("SonarCall", "failed to send call control on live mesh route chatId=$chatId")
                }
                return ok
            }
        }
        val groupId = resolveMarmotGroupId(chatId)
        if (groupId != null) {
            return sendCallOverMarmot(groupId, text)
        }
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val raw = npubRawFor(peerId)
            if (raw != null) return sendCallOverMarmot(peerId, raw, text)
        }
        toast = "No call route to this Sonar peer yet."
        sonarLog("SonarCall", "refusing call control without BLE or White Noise route chatId=$chatId")
        return false
    }

    private suspend fun sendCallOverMarmot(groupId: String, text: String): Boolean =
        try {
            SonarCore.send(groupId, text)
            true
        } catch (e: Throwable) {
            toast = "call signaling failed: ${e.message}"
            sonarLog("SonarCall", "failed to send call control over White Noise group=$groupId err=${e.message}")
            false
        }

    private suspend fun sendCallOverMarmot(peerId: String, npubRaw: ByteArray, text: String): Boolean {
        return try {
            refreshChats()
            val groupId = marmotGroupForNpub(npubRaw)?.id ?: SonarCore.startChat(npubRaw.toHexLower()).also {
                refreshChats()
                recomputeConversations()
            }
            SonarCore.send(groupId, text)
            refreshOpenDm(peerId)
            true
        } catch (e: Throwable) {
            toast = "call signaling failed: ${e.message}"
            sonarLog("SonarCall", "failed to send call control over White Noise peer=$peerId err=${e.message}")
            false
        }
    }

    /** Send a BLE-mesh DM over the Noise link + optimistically echo it. */
    private fun sendMesh(peerId: String, text: String): Boolean {
        if (isMeshContactBlocked(peerId)) {
            toast = "Unblock this contact before sending."
            return false
        }
        val mid = randomMeshId()
        val ok = MeshRadio.sendMeshDm(peerId, mid, text)
        if (!ok) { toast = "Not connected over Bluetooth yet — stay close and try again"; return false }
        val stickerRef = meshParseStickerContent(text)?.let {
            SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
        }
        val msg = SonarMsg(mid, npub, if (stickerRef != null) "" else text, mine = true, MeshRadio.nowSecs(), stickerRef = stickerRef)
        meshChats[peerId] = meshChats[peerId].orEmpty() + msg
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        processPayLines(meshChatId(canonicalPeerId), listOf(msg))
        persistMesh(peerId)
        scope.launch { refreshOpenDm(canonicalPeerId) }
        refreshMeshDmRows()
        return true
    }

    private fun sendMeshMedia(peerId: String, data: ByteArray, filename: String, mime: String): Boolean {
        if (isMeshContactBlocked(peerId)) {
            toast = "Unblock this contact before sending."
            return false
        }
        val routePeerId = liveMeshRoutePeerId(peerId) ?: peerId
        val mid = randomMeshId()
        val mediaUrl = meshMediaUrl(routePeerId, mid, filename)
        val ok = MeshRadio.sendMeshMedia(routePeerId, mid, data, filename, mime)
        if (!ok) {
            toast = "Not connected over Bluetooth yet — stay close and try again"
            return false
        }
        val media = SonarMedia(mediaUrl, mime, filename, null, null, null)
        mediaCache[mediaUrl] = data
        scope.launch { MessageStore.saveMeshMedia(mediaUrl, data) }
        val msg = SonarMsg(mid, npub, "", mine = true, tsSecs = MeshRadio.nowSecs(), media = listOf(media))
        meshChats[routePeerId] = meshChats[routePeerId].orEmpty() + msg
        persistMesh(routePeerId)
        scope.launch { refreshOpenDm(canonicalMeshPeerId(routePeerId)) }
        refreshMeshDmRows()
        return true
    }

    /** Write-through a peer's BLE-mesh transcript so it survives an app restart
     *  (parity with the iOS MessageStore). Marmot/White Noise legs are NOT written
     *  here — they already persist in the encrypted SQLCipher DB. */
    private fun persistMesh(peerId: String) {
        val msgs = meshChats[peerId].orEmpty()
        updateBleDiscoveryPolicy()
        scope.launch { MessageStore.saveMeshDm(peerId, msgs) }
    }

    private fun shouldUseMarmotRoute(peerId: String, npubRaw: ByteArray): Boolean {
        val npubHex = npubRaw.toHexLower()
        return marmotGroupForNpub(npubRaw) != null ||
            sonarProfile(peerId) != null ||
            ((linkCapsByFp[peerId] ?: 0) and SonarAnnounce.CAP_MARMOT) != 0 ||
            sonarDescriptorsByNpubHex[npubHex] != null
    }

    private fun canUseDirectNip17(peerId: String, npubRaw: ByteArray): Boolean =
        !socialState.isBlockedNostr(npubRaw.toHexLower()) && socialState.isMutualFavorite(peerId)

    private suspend fun sendDirectNip17Now(
        peerId: String,
        npubRaw: ByteArray,
        messageId: String,
        text: String,
    ): Boolean {
        return try {
            SonarCore.sendDirectDm(
                recipientHex = npubRaw.toHexLower(),
                senderPeerIdHex = MeshRadio.localPeerIdHex(),
                recipientPeerIdHex = "",
                messageId = messageId,
                text = text,
            )
            true
        } catch (e: Throwable) {
            toast = "send failed: ${e.message}"
            sonarLog("SonarDirect", "failed direct NIP-17 send peer=${peerId.take(10)} err=${e.message}")
            false
        }
    }

    private fun sendDirectNip17(peerId: String, npubRaw: ByteArray, text: String) {
        if (isMeshContactBlocked(peerId)) {
            toast = "Unblock this contact before sending."
            return
        }
        val chatId = meshChatId(peerId)
        val messageId = randomMeshId()
        val echo = createSendEcho(chatId, text)
        messages = (messages + echo).sortedBy { it.tsSecs }
        scope.launch {
            val delivered = sendDirectNip17Now(peerId, npubRaw, messageId, text)
            if (delivered) {
                clearSendEcho(chatId, echo.id)
                val msg = privateDmMessage(
                    id = messageId,
                    senderNpub = npub,
                    text = text,
                    mine = true,
                    tsSecs = SonarClock.nowSecs(),
                    viaInternet = true,
                )
                appendMeshMessage(peerId, msg)
                processPayLines(chatId, listOf(msg))
                refreshOpenDm(peerId)
            } else {
                failSendEcho(chatId, echo.id)
            }
        }
    }

    private fun appendMeshMessage(peerId: String, msg: SonarMsg): Boolean {
        val existing = meshChats[peerId].orEmpty()
        if (existing.any { it.id == msg.id }) return false
        meshChats[peerId] = (existing + msg).sortedBy { it.tsSecs }
        persistMesh(peerId)
        refreshMeshDmRows()
        return true
    }

    private fun privateDmMessage(
        id: String,
        senderNpub: String,
        text: String,
        mine: Boolean,
        tsSecs: Long,
        viaInternet: Boolean,
        state: String? = null,
    ): SonarMsg {
        val stickerRef = meshParseStickerContent(text)?.let {
            SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
        }
        return SonarMsg(
            id = id,
            senderNpub = senderNpub,
            content = if (stickerRef != null) "" else text,
            mine = mine,
            tsSecs = tsSecs,
            viaInternet = viaInternet,
            state = state,
            stickerRef = stickerRef,
        )
    }

    /** Texts queued for a Sonar peer (keyed by npub hex) while their White Noise
     *  group is created on the first out-of-range send. Flushed by
     *  [flushPendingMarmot] once the group appears in [chats]. */
    private val pendingMarmotSends = mutableMapOf<String, MutableList<String>>()
    private val startingMarmotChats = mutableSetOf<String>()
    private val pendingMarmotSetupJobs = mutableMapOf<String, Job>()
    private val pendingMarmotSetupTokens = mutableMapOf<String, Long>()
    private var pendingMarmotSetupNonce = 0L
    private data class PendingMarmotDirect(
        val peerNpub: String,
        val createdAtSecs: Long,
    )
    private data class PendingMarmotGroup(
        val name: String,
        val members: List<String>,
        val createdAtSecs: Long,
    )
    private data class PendingDirectMarmotSend(
        val pendingChatId: String,
        val text: String,
        val echoId: String,
    )
    private data class PendingMarmotGroupSend(
        val text: String,
        val echoId: String,
    )
    private val pendingDirectMarmotSends = mutableMapOf<String, MutableList<PendingDirectMarmotSend>>()
    private val pendingMarmotGroupSends = mutableMapOf<String, MutableList<PendingMarmotGroupSend>>()
    private val pendingMarmotGroupSetupJobs = mutableMapOf<String, Job>()
    private val pendingMarmotGroupSetupTokens = mutableMapOf<String, Long>()
    private var pendingMarmotGroupSetupNonce = 0L

    private fun nextPendingMarmotSetupToken(pendingChatId: String): Long {
        val token = ++pendingMarmotSetupNonce
        pendingMarmotSetupTokens[pendingChatId] = token
        return token
    }

    private fun isActivePendingMarmotSetup(
        pendingChatId: String,
        peerNpub: String?,
        setupToken: Long?,
    ): Boolean {
        val activePeer = pendingMarmotChatNpubs[pendingChatId]?.peerNpub ?: return false
        if (activePeer != peerNpub) return false
        return setupToken == null || pendingMarmotSetupTokens[pendingChatId] == setupToken
    }

    private fun clearPendingMarmotSetup(pendingChatId: String, npubHex: String, setupToken: Long) {
        if (pendingMarmotSetupTokens[pendingChatId] != setupToken) return
        pendingMarmotSetupTokens.remove(pendingChatId)
        pendingMarmotSetupJobs.remove(pendingChatId)
        startingMarmotChats.remove(npubHex)
    }

    private fun cancelPendingMarmotSetup(pendingChatId: String, npubHex: String) {
        pendingMarmotSetupJobs.remove(pendingChatId)?.cancel()
        pendingMarmotSetupTokens.remove(pendingChatId)
        startingMarmotChats.remove(npubHex)
    }

    private fun cancelPendingMarmotSetups() {
        pendingMarmotSetupJobs.values.forEach { it.cancel() }
        pendingMarmotSetupJobs.clear()
        pendingMarmotSetupTokens.clear()
        startingMarmotChats.clear()
    }

    private fun nextPendingMarmotGroupSetupToken(pendingChatId: String): Long {
        val token = ++pendingMarmotGroupSetupNonce
        pendingMarmotGroupSetupTokens[pendingChatId] = token
        return token
    }

    private fun isActivePendingMarmotGroupSetup(pendingChatId: String, setupToken: Long?): Boolean {
        if (!pendingMarmotGroups.containsKey(pendingChatId)) return false
        return setupToken == null || pendingMarmotGroupSetupTokens[pendingChatId] == setupToken
    }

    private fun clearPendingMarmotGroupSetup(pendingChatId: String, setupToken: Long) {
        if (pendingMarmotGroupSetupTokens[pendingChatId] != setupToken) return
        pendingMarmotGroupSetupTokens.remove(pendingChatId)
        pendingMarmotGroupSetupJobs.remove(pendingChatId)
    }

    private fun cancelPendingMarmotGroupSetup(pendingChatId: String) {
        pendingMarmotGroupSetupJobs.remove(pendingChatId)?.cancel()
        pendingMarmotGroupSetupTokens.remove(pendingChatId)
    }

    private fun cancelPendingMarmotGroupSetups() {
        pendingMarmotGroupSetupJobs.values.forEach { it.cancel() }
        pendingMarmotGroupSetupJobs.clear()
        pendingMarmotGroupSetupTokens.clear()
    }

    // ── Outbox: per-peer message queue for offline/unreachable peers ──
    // Mirrors iOS MessageRouter outbox. When neither BLE mesh link nor npub is
    // available, messages are queued here instead of being dropped. Flushed
    // automatically when the peer reconnects over BLE or their npub is learned.
    private val outbox = SonarOutbox()
    private val flushingOutboxPeers = mutableSetOf<String>()

    /** Continue a Sonar-peer conversation over White Noise (Marmot) when out of
     *  Bluetooth range, creating the 1:1 group on first send (mirrors iOS
     *  `sendOverMarmot`). */
    private fun sendOverMarmot(peerId: String, npubRaw: ByteArray, text: String) {
        val group = marmotGroupForNpub(npubRaw)
        if (group != null) {
            val chatId = meshChatId(peerId)
            val echo = createSendEcho(chatId, text)
            messages = (messages + echo).sortedBy { it.tsSecs }
            scope.launch {
                try {
                    SonarCore.send(group.id, text)
                    clearSendEcho(chatId, echo.id)
                    processPayLines(group.id, marmotMessagesPage(group.id))
                    refreshOpenDm(peerId)
                } catch (e: Throwable) {
                    failSendEcho(chatId, echo.id)
                    toast = "send failed: ${e.message}"
                }
            }
            return
        }
        val npubHex = npubRaw.toHexLower()
        pendingMarmotSends.getOrPut(npubHex) { mutableListOf() }.add(text)
        toast = "Out of range — continuing over White Noise…"
        if (!startingMarmotChats.add(npubHex)) return
        scope.launch {
            try {
                SonarCore.startChat(npubHex) // start_dm accepts a hex pubkey
                refreshChats(); flushPendingMarmot(); flushOutbox(peerId); refreshOpenDm(peerId)
            } catch (e: Throwable) { toast = "couldn’t start secure chat: ${e.message}" }
            finally { startingMarmotChats.remove(npubHex) }
        }
    }

    /** Flush texts queued for Sonar peers whose White Noise group now exists. */
    private fun sendStickerOverMarmot(
        peerId: String, npubRaw: ByteArray,
        packCoordinate: String, sticker: SonarStickerItem,
    ) {
        val group = marmotGroupForNpub(npubRaw)
        if (group != null) {
            scope.launch {
                runCatching { SonarCore.sendSticker(group.id, packCoordinate, sticker.shortcode, sticker.sha256) }
                    .onFailure { toast = "send failed: ${it.message}" }
            }
            return
        }
        val npubHex = npubRaw.toHexLower()
        val encoded = meshStickerContent(packCoordinate, sticker.shortcode, sticker.sha256)
        pendingMarmotSends.getOrPut(npubHex) { mutableListOf() }.add(encoded)
        toast = "Out of range — continuing over White Noise…"
        if (!startingMarmotChats.add(npubHex)) return
        scope.launch {
            try {
                SonarCore.startChat(npubHex)
                refreshChats(); flushPendingMarmot(); refreshOpenDm(peerId)
            } catch (e: Throwable) { toast = "couldn't start secure chat: ${e.message}" }
            finally { startingMarmotChats.remove(npubHex) }
        }
    }

    private fun flushPendingMarmot() {
        if (pendingMarmotSends.isEmpty()) return
        for ((npubHex, texts) in pendingMarmotSends.toMap()) {
            if (socialState.isBlockedNostr(npubHex)) continue
            val group = marmotGroupForNpub(npubHex.hexToBytesOrEmpty()) ?: continue
            pendingMarmotSends.remove(npubHex)
            scope.launch {
                for (tx in texts) {
                    val ref = meshParseStickerContent(tx)
                    if (ref != null) {
                        runCatching { SonarCore.sendSticker(group.id, ref.packCoordinate, ref.shortcode, ref.plaintextSha256) }
                    } else {
                        runCatching { SonarCore.send(group.id, tx) }
                    }
                }
            }
        }
    }

    // ── Outbox queue (mirrors iOS MessageRouter outbox) ──

    /** Queue a message for [peerId] when no transport is available. Enforces
     *  per-peer size limit (FIFO eviction) matching iOS behaviour. */
    private fun enqueueOutbox(peerId: String, text: String) {
        val result = outbox.enqueue(peerId, text, randomMeshId(), SonarClock.nowSecs())
        result.evicted?.let { evicted ->
            sonarLog("SonarOutbox", "overflow for ${peerId.take(10)}… — evicted oldest id=${evicted.messageId.take(8)}…")
        }
        sonarLog("SonarOutbox", "queued for ${peerId.take(10)}… id=${result.message.messageId.take(8)}… queue=${result.depth}")
    }

    /** Try to deliver all queued messages for [peerId]. Expired messages (>24h)
     *  are silently dropped. Messages that still can't be sent remain queued. */
    private fun flushOutbox(peerId: String) {
        if (!outbox.contains(peerId) || !flushingOutboxPeers.add(peerId)) return
        scope.launch {
            try {
                flushOutboxNow(peerId)
            } finally {
                flushingOutboxPeers.remove(peerId)
            }
        }
    }

    private suspend fun flushOutboxNow(peerId: String) {
        val queue = outbox.snapshot(peerId)
        if (queue.isEmpty()) { outbox.finishFlush(peerId, 0, emptyList()); return }
        if (isMeshContactBlocked(peerId)) {
            sonarLog("SonarOutbox", "paused blocked outbox peer=${peerId.take(10)}…")
            return
        }
        val now = SonarClock.nowSecs()
        val remaining = mutableListOf<QueuedMessage>()
        var marmotGroupId: String? = null

        sonarLog("SonarOutbox", "flushing ${queue.size} message(s) for ${peerId.take(10)}…")

        for ((index, msg) in queue.withIndex()) {
            // TTL check: drop messages older than 24 hours.
            if (outbox.isExpired(msg, now)) {
                sonarLog("SonarOutbox", "expired id=${msg.messageId.take(8)}… age=${now - msg.timestampSecs}s")
                continue
            }
            // Try to send via the best available transport.
            val routePeerId = liveMeshRoutePeerId(peerId)
            val delivered = if (routePeerId != null) {
                sendMesh(routePeerId, msg.content)
            } else {
                val raw = npubRawFor(peerId)
                if (raw != null) {
                    when {
                        shouldUseMarmotRoute(peerId, raw) -> {
                            val groupId = marmotGroupId ?: ensureMarmotGroupForOutbox(peerId, raw)
                            marmotGroupId = groupId
                            groupId != null && sendOutboxOverMarmot(peerId, groupId, msg.content)
                        }
                        canUseDirectNip17(peerId, raw) -> sendOutboxOverDirectNip17(peerId, raw, msg)
                        else -> false
                    }
                } else {
                    false
                }
            }
            if (!delivered) {
                remaining.addAll(outbox.remainingAfterFailure(queue, index, now))
                sonarLog("SonarOutbox", "kept ${remaining.size} message(s) queued for ${peerId.take(10)}…")
                break
            }
            sonarLog("SonarOutbox", "delivered id=${msg.messageId.take(8)}… to ${peerId.take(10)}…")
        }

        outbox.finishFlush(peerId, queue.size, remaining)
    }

    private suspend fun ensureMarmotGroupForOutbox(peerId: String, npubRaw: ByteArray): String? {
        marmotGroupForNpub(npubRaw)?.id?.let { return it }
        val npubHex = npubRaw.toHexLower()
        return try {
            refreshChats()
            marmotGroupForNpub(npubRaw)?.id ?: run {
                if (!startingMarmotChats.add(npubHex)) return null
                try {
                    SonarCore.startChat(npubHex).also {
                        refreshChats()
                        recomputeConversations()
                        flushPendingMarmot()
                        refreshOpenDm(peerId)
                    }
                } finally {
                    startingMarmotChats.remove(npubHex)
                }
            }
        } catch (e: Throwable) {
            startingMarmotChats.remove(npubHex)
            toast = "couldn’t start secure chat: ${e.message}"
            sonarLog("SonarOutbox", "failed to start White Noise group for ${peerId.take(10)}… err=${e.message}")
            null
        }
    }

    private suspend fun sendOutboxOverMarmot(peerId: String, groupId: String, text: String): Boolean {
        if (isMeshContactBlocked(peerId)) return false
        return try {
            SonarCore.send(groupId, text)
            refreshOpenDm(peerId)
            true
        } catch (e: Throwable) {
            toast = "send failed: ${e.message}"
            sonarLog("SonarOutbox", "failed to send queued White Noise message for ${peerId.take(10)}… err=${e.message}")
            false
        }
    }

    private suspend fun sendOutboxOverDirectNip17(
        peerId: String,
        npubRaw: ByteArray,
        queued: QueuedMessage,
    ): Boolean {
        if (isMeshContactBlocked(peerId)) return false
        val delivered = sendDirectNip17Now(peerId, npubRaw, queued.messageId, queued.content)
        if (!delivered) return false
        val msg = privateDmMessage(
            id = queued.messageId,
            senderNpub = npub,
            text = queued.content,
            mine = true,
            tsSecs = SonarClock.nowSecs(),
            viaInternet = true,
        )
        appendMeshMessage(peerId, msg)
        refreshOpenDm(peerId)
        return true
    }

    /** Flush outbox for ALL peers that now have a reachable transport. Called
     *  periodically and on transport-change events. */
    private fun flushAllOutbox() {
        if (outbox.isEmpty()) return
        for (peerId in outbox.peerIds()) {
            flushOutbox(peerId)
        }
    }

    fun createGroup(name: String, members: List<String>) {
        val cleanName = name.trim().ifBlank { "Group chat" }
        val cleanMembers = members.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (cleanMembers.size < 2) {
            toast = "Add at least two people"
            return
        }
        val pendingChatId = pendingMarmotGroupId()
        val pending = PendingMarmotGroup(
            name = cleanName,
            members = cleanMembers,
            createdAtSecs = SonarClock.nowSecs(),
        )
        openPendingMarmotGroup(pendingChatId, pending)
        startPendingMarmotGroupCreation(pendingChatId)
    }

    fun addGroupMembers(chatId: String, members: List<String>) {
        if (!canManageGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        val existing = groupMemberNpubs(chatId)
        val cleanMembers = members.map { it.trim() }
            .filter { it.isNotEmpty() && it !in existing }
            .distinct()
        if (cleanMembers.isEmpty()) {
            toast = "Add at least one new person"
            return
        }
        scope.launch {
            try {
                SonarCore.addGroupMembers(chatId, cleanMembers)
                refreshChats()
                if ((screen as? Screen.Chat)?.id == chatId) {
                    setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))))
                }
            } catch (e: Throwable) {
                toast = "couldn't add people: ${e.message}"
            }
        }
    }

    fun removeGroupMembers(chatId: String, members: List<String>) {
        if (!canManageGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        val cleanMembers = members.map { it.trim() }
            .filter { it.isNotEmpty() && it != npub }
            .distinct()
        if (cleanMembers.isEmpty()) return
        scope.launch {
            try {
                SonarCore.removeGroupMembers(chatId, cleanMembers)
                refreshChats()
                if ((screen as? Screen.Chat)?.id == chatId) {
                    setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId))))
                }
            } catch (e: Throwable) {
                toast = "couldn't remove people: ${e.message}"
            }
        }
    }

    fun createInviteLink(chatId: String, groupName: String, onResult: (String) -> Unit) {
        if (!canManageGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        scope.launch {
            try {
                val token = SonarCore.createInviteLink(chatId, groupName)
                onResult(token)
            } catch (e: Throwable) {
                toast = "couldn't create invite link: ${e.message}"
            }
        }
    }

    fun loadPendingJoinRequests(chatId: String, onResult: (List<SonarJoinRequest>) -> Unit) {
        if (!canManageGroup(chatId)) {
            onResult(emptyList())
            return
        }
        scope.launch {
            try {
                onResult(SonarCore.pendingJoinRequests(chatId))
            } catch (e: Throwable) {
                toast = "couldn't load join requests: ${e.message}"
                onResult(emptyList())
            }
        }
    }

    fun approveJoinRequest(chatId: String, requesterNpub: String, onDone: () -> Unit = {}) {
        if (!canManageGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        scope.launch {
            try {
                SonarCore.approveJoinRequest(chatId, requesterNpub)
                refreshChats()
                toast = "Member added"
                onDone()
            } catch (e: Throwable) {
                toast = "couldn't approve: ${e.message}"
            }
        }
    }

    fun declineJoinRequest(chatId: String, requesterNpub: String, onDone: () -> Unit = {}) {
        if (!canManageGroup(chatId)) {
            toast = "Group is still setting up."
            return
        }
        scope.launch {
            try {
                SonarCore.declineJoinRequest(chatId, requesterNpub)
                toast = "Request declined"
                onDone()
            } catch (e: Throwable) {
                toast = "couldn't decline: ${e.message}"
            }
        }
    }

    fun requestJoinViaLink(token: String) {
        if (!started) {
            if (pendingInviteTokens.none { it == token }) pendingInviteTokens.add(token)
            if (!connecting) boot()
            return
        }
        scope.launch {
            try {
                SonarCore.requestJoinViaLink(token)
                toast = "Join request sent"
            } catch (e: Throwable) {
                toast = "couldn't join: ${e.message}"
            }
        }
    }

    private fun drainPendingInviteTokens() {
        if (pendingInviteTokens.isEmpty()) return
        val queued = pendingInviteTokens.toList()
        pendingInviteTokens.clear()
        queued.forEach { requestJoinViaLink(it) }
    }

    var sharedText: String? by mutableStateOf(null)
        private set

    fun handleSharedText(text: String) {
        sharedText = text
        push(Screen.Search)
    }

    fun consumeSharedText(): String? {
        val text = sharedText
        sharedText = null
        return text
    }

    fun acceptGroupInvite(inviteId: String) {
        val invite = groupInvites.firstOrNull { it.id == inviteId } ?: return
        val pendingChatId = pendingMarmotGroupId("invite:$inviteId")
        val pending = PendingMarmotGroup(
            name = invite.groupName.ifBlank { "Group chat" },
            members = emptyList(),
            createdAtSecs = SonarClock.nowSecs(),
        )
        groupInvites = groupInvites.filterNot { it.id == inviteId }
        openPendingMarmotGroup(pendingChatId, pending)
        startPendingMarmotGroupAccept(pendingChatId, inviteId)
    }

    fun declineGroupInvite(inviteId: String) {
        scope.launch {
            try {
                SonarCore.declineGroupInvite(inviteId)
                refreshChats()
            } catch (e: Throwable) {
                toast = "couldn’t decline invite: ${e.message}"
            }
        }
    }

    private fun npubHexForGroup(group: SonarChat): String? =
        otherMembers(group).singleOrNull()
            ?.let { chat.bitchat.sonar.crypto.Bech32.decode(it)?.takeIf { d -> d.hrp == "npub" }?.data }
            ?.takeIf { it.size == 32 }
            ?.toHexLower()

    /** Counterparty npub hex for a direct Marmot group whose member may be
     * represented as either npub or raw hex. */
    private fun npubHexForDirectGroup(group: SonarChat): String? =
        npubHexForGroup(group) ?: directMarmotPeerKey(group, npub)?.let(::canonicalNpubHex)

    private fun linkedNpubHexForPeer(peerId: String): String? =
        npubRawFor(peerId)?.toHexLower()

    private fun peerLinkMatchesGroup(group: SonarChat, peerId: String): Boolean {
        val groupNpubHex = npubHexForDirectGroup(group) ?: return false
        return peerNpubHexMatchesLinkedPeer(groupNpubHex, linkedNpubHexForPeer(peerId))
    }

    private fun pruneStaleGroupFold(groupId: String) {
        if (groupFoldMap.remove(groupId) == null) return
        persistGroupFolds()
        updateBleDiscoveryPolicy()
    }

    private fun peerIdForNpubHex(npubHex: String): String? =
        resolvePeerIdForNpubHex(
            senderNpubHex = npubHex,
            livePeerIds = sonarPeerProfiles.keys,
            liveNpubHexForPeer = { peerId -> sonarPeerProfiles[peerId]?.npub?.toHexLower() },
            persistedNpubHexByPeer = linkByFp,
        )

    private fun peerIdForMarmotGroup(groupId: String): String? {
        val group = chats.firstOrNull { it.id == groupId }
        foldedGroupPeerIds[groupId]?.let { peerId ->
            if (group == null || peerLinkMatchesGroup(group, peerId)) return peerId
        }
        groupFoldMap[groupId]?.let { peerId ->
            if (group == null || peerLinkMatchesGroup(group, peerId)) return peerId
            pruneStaleGroupFold(groupId)
        }
        return group?.let(::peerIdForMarmotGroup)
    }

    private fun peerIdForMarmotGroup(group: SonarChat): String? {
        val npubHex = npubHexForDirectGroup(group) ?: return null
        return peerIdForNpubHex(npubHex)?.takeIf { peerLinkMatchesGroup(group, it) }
    }

    private fun marmotGroupsForNpub(npubRaw: ByteArray): List<SonarChat> {
        if (npubRaw.isEmpty()) return emptyList()
        return chats.filter { c ->
            isDirectMarmotChat(c) &&
            c.members.any { m ->
                chat.bitchat.sonar.crypto.Bech32.decode(canonicalProfileKey(m))
                    ?.takeIf { it.hrp == "npub" }?.data?.contentEquals(npubRaw) == true
            }
        }
    }

    private fun marmotGroupForNpub(npubRaw: ByteArray): SonarChat? =
        preferredDirectMarmotChat(marmotGroupsForNpub(npubRaw))

    private fun preferredDirectMarmotChat(groups: List<SonarChat>): SonarChat? =
        groups.maxWithOrNull(
            compareBy<SonarChat> { localLatestTs(it.id) }
                .thenBy { it.id }
        )

    private suspend fun marmotMessages(groupId: String): List<SonarMsg> {
        val loaded = runCatching { SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT) }.getOrNull()
        if (!started && loaded.isNullOrEmpty()) {
            return chatSnapshotMessagesByChat[groupId].orEmpty()
        }
        return loaded ?: chatSnapshotMessagesByChat[groupId].orEmpty()
    }

    private suspend fun marmotMessagesPage(groupId: String): List<SonarMsg> {
        val loaded = runCatching {
            SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
        }.getOrNull()
        if (!started && loaded.isNullOrEmpty()) {
            return chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(LOCAL_TRANSCRIPT_PAGE_LIMIT)
        }
        return loaded ?: chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(LOCAL_TRANSCRIPT_PAGE_LIMIT)
    }

    private suspend fun marmotMessagesPageForChat(chatId: String): List<SonarMsg> {
        val groups = duplicateDirectMarmotChats(chatId)
        if (groups.size <= 1) return marmotMessagesPage(chatId)
        val merged = ArrayList<SonarMsg>()
        for (group in groups) {
            merged += marmotMessagesPage(group.id)
        }
        return merged.distinctBy { it.id }.sortedBy { it.tsSecs }.takeLast(LOCAL_TRANSCRIPT_PAGE_LIMIT)
    }

    private suspend fun marmotMessagesForPeer(peerId: String): List<SonarMsg> {
        val aliases = meshPeerAliases(peerId)
        val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
        val merged = ArrayList<SonarMsg>()
        for (group in groups) {
            val msgs = marmotMessages(group.id)
            merged += msgs.map { it.copy(viaInternet = true) }
        }
        return merged.distinctBy { it.id }
    }

    private fun latestMarmotMessage(groups: List<SonarChat>): SonarMsg? {
        var latest: SonarMsg? = null
        for (group in groups) {
            val msg = chatSnapshotMessagesByChat[group.id]?.lastOrNull()
            val current = latest
            if (msg != null && (current == null || msg.tsSecs > current.tsSecs)) latest = msg
        }
        return latest
    }

    private fun callChatIdFor(chatId: String): String =
        if (isMeshChat(chatId)) chatId else peerIdForMarmotGroup(chatId)?.let { meshChatId(it) } ?: chatId

    /** Rebuild the open Sonar-peer DM transcript: the mesh leg plus, for a Sonar
     *  peer with a Marmot group, the White Noise leg merged chronologically. The
     *  White Noise leg renders as internet (indigo). No-op if that DM isn't open. */
    private suspend fun refreshOpenDm(peerId: String) {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        if ((screen as? Screen.Chat)?.id != meshChatId(canonicalPeerId)) return
        val chatId = meshChatId(canonicalPeerId)
        val mesh = mergedMeshMessages(canonicalPeerId)
        val wn = marmotMessagesForPeer(canonicalPeerId)
        val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
        val visible = visibleMessagesForChat(chatId, merged)
        messages = visible
        processPayLines(chatId, visible)
        val aliases = meshPeerAliases(canonicalPeerId)
        val groups = npubRawFor(canonicalPeerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
        for (group in groups) {
            unreadByChat = unreadByChat - group.id
            runCatching { SonarCore.markConversationRead(group.id) }
        }
    }

    private fun observedMeshPeer(peerId: String): Boolean =
        meshPeerAliases(peerId).any { it in rawMeshPeerIds }

    private fun hasLiveMeshRoute(peerId: String): Boolean =
        observedMeshPeer(peerId) && liveMeshRoutePeerId(peerId) != null

    /** True while a live Noise link to [peerId] exists (peer is in Bluetooth range). */
    fun dmInRange(peerId: String): Boolean = hasLiveMeshRoute(peerId)

    /** True if we know this peer's **White Noise account** (npub) — from a live
     *  0x53 OR the persisted link (so it stays true out of Bluetooth range). An
     *  npub IS a White Noise account, so this gates White-Noise *reachability*, not
     *  a "Sonar app" tier: any account we know is reachable over the internet. */
    fun hasWhiteNoiseAccount(peerId: String): Boolean = npubRawFor(peerId) != null

    /** True if [chatId]'s peer can be voice/video called: calls are Sonar-only
     *  (CAP_CALLS from 0x53) and require either live BLE or the npub needed to
     *  create/reuse White Noise signaling for that same discovered peer. */
    fun canCall(chatId: String): Boolean {
        val peerId = if (isMeshChat(chatId)) meshPeerId(chatId) else peerIdForMarmotGroup(chatId)
        if (peerId == null) return marmotChatCallCapable(chatId)
        return callCapablePeer(peerId) &&
            (hasLiveMeshRoute(peerId) || npubRawFor(peerId) != null)
    }

    private fun marmotChatCallCapable(chatId: String): Boolean {
        val npubHex = marmotChatPeerNpubHex(chatId) ?: return false
        sonarDescriptorsByNpubHex[npubHex]?.let { if (it.supportsCurrentCalls) return true }
        return false
    }

    private fun callCapablePeer(peerId: String): Boolean {
        val aliases = meshPeerAliases(peerId)
        if (aliases.any { sonarProfile(it)?.speaksCalls == true }) return true
        if (aliases.any { ((linkCapsByFp[it] ?: 0) and SonarAnnounce.CAP_CALLS) != 0 }) return true
        val npubHex = npubRawFor(peerId)?.toHexLower() ?: return false
        sonarDescriptorsByNpubHex[npubHex]?.let { if (it.supportsCurrentCalls) return true }
        return false
    }

    /** Mirrors iOS `shouldDeferOfferForSonarDescriptor`: BLE discovery is
     *  authoritative when present; only defer for npub-only Marmot contacts
     *  whose public Sonar descriptor is still unknown (and not recently
     *  missed). Kicks the background fetch so a later scan pass can ring. */
    private fun shouldDeferOfferForSonarDescriptor(chatId: String): Boolean {
        val peerId = if (isMeshChat(chatId)) meshPeerId(chatId) else peerIdForMarmotGroup(chatId)
        if (peerId != null && sonarProfile(peerId) != null) return false
        val key = callDescriptorNpubHex(chatId)?.lowercase() ?: return false
        if (sonarDescriptorsByNpubHex[key] != null) return false
        val missedAt = sonarDescriptorMissedAt[key]
        if (missedAt != null && SonarClock.nowSecs() - missedAt < SONAR_DESCRIPTOR_MISS_TTL_SECS) return false
        ensureSonarDescriptorHex(key)
        return true
    }

    private fun callDescriptorNpubHex(chatId: String): String? {
        val peerId = if (isMeshChat(chatId)) meshPeerId(chatId) else peerIdForMarmotGroup(chatId)
        return if (peerId == null) marmotChatPeerNpubHex(chatId) else npubRawFor(peerId)?.toHexLower()
    }

    private fun marmotChatPeerNpubHex(chatId: String): String? {
        val mine = canonicalProfileKey(npub)
        val other = chats.firstOrNull { it.id == chatId }
            ?.members
            ?.map { canonicalProfileKey(it) }
            ?.firstOrNull { it != mine && it.isNotBlank() }
            ?: return null
        return canonicalNpubHex(other)
    }

    private fun randomMeshId(): String =
        (0 until 16).joinToString("") { "0123456789abcdef"[kotlin.random.Random.nextInt(16)].toString() }

    private fun ByteArray.toHexLower(): String =
        joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }

    private fun String.hexToBytesOrEmpty(): ByteArray =
        if (length % 2 != 0) ByteArray(0)
        else runCatching { chunked(2).map { it.toInt(16).toByte() }.toByteArray() }.getOrDefault(ByteArray(0))

    private fun handleFavoriteControl(peerId: String, text: String): Boolean {
        val favorite = when {
            text.startsWith(FAVORITED_CONTROL) -> true
            text.startsWith(UNFAVORITED_CONTROL) -> false
            else -> return false
        }
        val payloadNpub = text.substringAfter(':', missingDelimiterValue = "").trim()
        canonicalNpubHex(payloadNpub)?.let { npubHex ->
            if (!linkByFp[peerId].equals(npubHex, ignoreCase = true)) {
                linkByFp[peerId] = npubHex
                persistLinks()
                refreshKnownContactDescriptors()
            }
        }
        socialState = socialState.withRemoteFavoritePeer(peerId, favorite)
        persistSocialState()
        recomputeSociallyFilteredRows()
        if (favorite) flushOutbox(peerId)
        return true
    }

    /** Drain mesh DMs received since last poll into the per-peer transcripts,
     *  surface them as Messages rows, and notify for ones we're not looking at. */
    private fun drainMeshDms(): Boolean {
        val incoming = MeshRadio.drainMeshDm()
        if (incoming.isEmpty()) return false
        val touched = mutableSetOf<String>()
        for (m in incoming) {
            if (isMeshContactBlocked(m.peerId)) continue
            if (handleFavoriteControl(m.peerId, m.text)) continue
            val stickerRef = meshParseStickerContent(m.text)?.let {
                SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
            }
            val msg = SonarMsg(
                m.messageId.ifBlank { randomMeshId() }, m.peerId,
                if (stickerRef != null) "" else m.text,
                mine = false, m.tsSecs, stickerRef = stickerRef,
            )
            val chatId = meshChatId(m.peerId)
            if (stickerRef == null && SonarCore.callParseControl(m.text) != null) {
                processCallLines(chatId, listOf(msg))
                continue
            }
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
            processPayLines(chatId, listOf(msg))
            touched += m.peerId
            val preview = if (stickerRef != null) "Sticker" else m.text
            val sender = meshPeerName(m.peerId)
            notifyIncoming(
                idKey = chatId,
                conversationTitle = sender,
                content = preview,
                senderName = sender,
            )
        }
        touched.forEach { persistMesh(it) } // write-through so received DMs survive restart
        refreshMeshDmRows()
        // Refresh the open conversation (merged mesh + White Noise) if it's one we
        // just appended to.
        (screen as? Screen.Chat)?.let { sc ->
            if (isMeshChat(sc.id)) {
                val pid = meshPeerId(sc.id)
                if (meshAliasGroupWasTouched(meshPeerAliases(pid), touched)) scope.launch { refreshOpenDm(pid) }
            }
        }
        return true
    }

    private suspend fun drainDirectDms() {
        val incoming = runCatching { SonarCore.drainDirectDms() }.getOrDefault(emptyList())
        if (incoming.isEmpty()) return
        val touched = mutableSetOf<String>()
        val ackEventIds = linkedSetOf<String>()
        for (m in incoming) {
            val peerId = peerIdForNpubHex(m.senderPubkeyHex)
            if (peerId == null) {
                ackEventIds += m.eventId
                continue
            }
            if (isMeshContactBlocked(peerId) || socialState.isBlockedNostr(m.senderPubkeyHex)) {
                ackEventIds += m.eventId
                continue
            }
            if (handleFavoriteControl(peerId, m.content)) {
                ackEventIds += m.eventId
                continue
            }
            if (!socialState.isMutualFavorite(peerId)) {
                ackEventIds += m.eventId
                continue
            }
            val id = m.id.ifBlank { randomMeshId() }
            if (meshChats[peerId].orEmpty().any { it.id == id }) {
                ackEventIds += m.eventId
                continue
            }
            val msg = privateDmMessage(
                id = id,
                senderNpub = m.senderPubkeyHex,
                text = m.content,
                mine = false,
                tsSecs = m.tsSecs,
                viaInternet = true,
            )
            val chatId = meshChatId(peerId)
            if (msg.stickerRef == null && SonarCore.callParseControl(m.content) != null) {
                processCallLines(chatId, listOf(msg))
                ackEventIds += m.eventId
                continue
            }
            meshChats[peerId] = meshChats[peerId].orEmpty() + msg
            processPayLines(chatId, listOf(msg))
            touched += peerId
            ackEventIds += m.eventId
            val preview = if (msg.stickerRef != null) "Sticker" else m.content
            notifyIncoming(chatId, meshPeerName(peerId), preview)
        }
        for (peerId in touched) {
            MessageStore.saveMeshDm(peerId, meshChats[peerId].orEmpty())
        }
        if (ackEventIds.isNotEmpty()) {
            SonarCore.acknowledgeDirectDms(ackEventIds.toList())
        }
        if (touched.isNotEmpty()) {
            refreshMeshDmRows()
            recomputeConversations()
            (screen as? Screen.Chat)?.let { sc ->
                if (isMeshChat(sc.id)) {
                    val pid = meshPeerId(sc.id)
                    if (meshAliasGroupWasTouched(meshPeerAliases(pid), touched)) refreshOpenDm(pid)
                }
            }
        }
    }

    /** Drain private BLE file transfers into the same mesh transcript model as
     * text DMs. The raw bytes are stored in MessageStore and referenced by a
     * local `mesh-media:` URL so bubbles survive an app restart. */
    private fun drainMeshMedia(): Boolean {
        val incoming = MeshRadio.drainMeshMedia()
        if (incoming.isEmpty()) return false
        val touched = mutableSetOf<String>()
        for (m in incoming) {
            if (isMeshContactBlocked(m.peerId)) continue
            val id = m.messageId.ifBlank { randomMeshId() }
            if (meshChats[m.peerId].orEmpty().any { it.id == id }) continue
            val mediaUrl = meshMediaUrl(m.peerId, id, m.filename)
            val media = SonarMedia(mediaUrl, m.mimeType, m.filename, null, null, null)
            mediaCache[mediaUrl] = m.bytes
            scope.launch { MessageStore.saveMeshMedia(mediaUrl, m.bytes) }
            val msg = SonarMsg(id, m.peerId, "", mine = false, tsSecs = m.tsSecs, media = listOf(media))
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
            touched += m.peerId
            notifyIncoming(meshChatId(m.peerId), meshPeerName(m.peerId), mediaPreviewLabel(m.mimeType, m.filename))
        }
        if (touched.isEmpty()) return false
        touched.forEach { persistMesh(it) }
        refreshMeshDmRows()
        (screen as? Screen.Chat)?.let { sc ->
            if (isMeshChat(sc.id)) {
                val pid = meshPeerId(sc.id)
                if (meshAliasGroupWasTouched(meshPeerAliases(pid), touched)) scope.launch { refreshOpenDm(pid) }
            }
        }
        return true
    }

    /** Drain incoming public Mesh-channel broadcasts into the mesh transcript.
     *  The wire carries sender peerID + content; resolve the display nickname. */
    private fun drainMeshBroadcasts(): Boolean {
        val incoming = MeshRadio.drainMeshBroadcast()
        if (incoming.isEmpty()) return false
        val seen = meshBroadcast.mapTo(HashSet()) { it.id }
        val add = incoming
            .filter { socialState.allowsChannelSender(it.senderId, mine = false) }
            .map {
                val id = "${it.senderId}-${it.tsSecs}"
                SonarChannelMsg(id, meshPeerName(it.senderId), it.senderId, it.content, mine = false, it.tsSecs)
            }
            .filter { it.id !in seen }
        if (add.isEmpty()) return false
        meshBroadcast = (meshBroadcast + add).sortedBy { it.tsSecs }.takeLast(200)
        if ((screen as? Screen.Channel)?.geohash == "mesh") channelMsgs = visibleChannelMessages(meshBroadcast)
        return true
    }

    /** Display name for a mesh peer: prefer the live radar name, else a remembered
     *  one, else a short id. Remembers whatever it resolves. Triggers an async
     *  profile fetch when the name isn't cached yet. */
    private fun meshPeerName(peerId: String): String {
        val live = meshPeers.firstOrNull { it.id == "mesh:$peerId" }?.name
        val peerNpub = npubStringForPeer(peerId)
        val profileName = peerNpub
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
        val remembered = meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }
        if (profileName == null && peerNpub != null) ensureProfile(peerNpub)
        val name = live ?: profileName ?: remembered ?: ("mesh·" + peerId.take(6))
        if (!name.isKeyFallbackName()) rememberMeshName(peerId, name) else meshChatNames[peerId] = name
        return name
    }

    private fun foldedPeerName(peerId: String, group: SonarChat?): String {
        val directMarmotTitle = group?.takeIf(::isDirectMarmotChat)?.let(::chatTitle)
        if (directMarmotTitle != null) {
            return homeListTitleForFoldedMeshRow(directMarmotTitle, "")
        }
        meshPeers.firstOrNull { it.id == meshChatId(peerId) }?.name?.let {
            rememberMeshName(peerId, it)
            return it
        }
        meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }?.let { return it }
        val peerNpub = npubStringForPeer(peerId)
        peerNpub
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
            ?.let { name ->
                meshChatNames[peerId] = name
                return name
            }
        if (peerNpub != null) ensureProfile(peerNpub)
        return homeListTitleForFoldedMeshRow(null, meshChatNames[peerId] ?: ("mesh·" + peerId.take(6)))
    }

    private fun String.isKeyFallbackName(): Boolean = isKeyFallbackNameValue(this)

    /** Recompute the observable mesh DM rows (newest conversation first). Fast,
     *  BLE-leg only — for immediate feedback on send/receive. [recomputeConversations]
     *  later folds in the White Noise leg. */
    private fun refreshMeshDmRows() {
        val groups = meshConversationAliasGroups()
        meshDmRows = groups.mapNotNull { aliases ->
            val peerId = selectCanonicalMeshPeerId(aliases, groupFoldMap.values.toSet()) ?: return@mapNotNull null
            if (isMeshContactBlocked(peerId)) return@mapNotNull null
            val last = aliases.flatMap { meshChats[it].orEmpty() }
                .distinctBy { it.id }
                .maxByOrNull { it.tsSecs }
                ?: return@mapNotNull null
            MeshDmRow(peerId, meshPeerName(peerId), messagePreview(last.content, last.stickerRef, last.media), last.tsSecs)
        }
            .sortedByDescending { it.tsSecs }
    }

    /** Unify the Messages list into one row per PERSON. For each BLE-mesh peer,
     *  resolve its npub (live 0x53 or persisted link) and, if a White Noise (Marmot)
     *  group for that npub exists, FOLD it in: the row's preview/timestamp reflect
     *  the latest message across BOTH transports, and the group is hidden from the
     *  standalone White Noise list ([visibleChats]). This is what stops a Bluetooth
     *  chat that continued over the internet from showing as two separate chats. */
    private suspend fun recomputeConversations() {
        val rowsByPeer = LinkedHashMap<String, MeshDmRow>()
        val folded = HashSet<String>()
        fun upsert(peerId: String, row: MeshDmRow) {
            val existing = rowsByPeer[peerId]
            if (existing == null || row.tsSecs >= existing.tsSecs) rowsByPeer[peerId] = row
        }
        val groupPeers = LinkedHashMap<String, String>()
        val meshGroups = meshConversationAliasGroups()
        for (aliases in meshGroups) {
            val peerId = selectCanonicalMeshPeerId(aliases, groupFoldMap.values.toSet()) ?: continue
            if (isMeshContactBlocked(peerId)) continue
            var last = aliases.flatMap { meshChats[it].orEmpty() }
                .distinctBy { it.id }
                .maxByOrNull { it.tsSecs }
                ?: continue
            val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }.orEmpty()
            if (groups.isNotEmpty()) {
                groups.forEach { g -> folded += g.id; groupPeers[g.id] = peerId }
                latestMarmotMessage(groups)?.let { if (it.tsSecs > last.tsSecs) last = it }
            }
            upsert(peerId, MeshDmRow(peerId, foldedPeerName(peerId, groups.firstOrNull()), messagePreview(last.content, last.stickerRef, last.media), last.tsSecs))
        }
        for (group in chats) {
            if (!isDirectMarmotChat(group)) continue
            if (isBlockedMarmotChat(group)) continue
            val rawPeerId = peerIdForMarmotGroup(group) ?: continue
            val peerId = canonicalMeshPeerId(rawPeerId)
            if (!peerLinkMatchesGroup(group, peerId)) {
                pruneStaleGroupFold(group.id)
                continue
            }
            if (isMeshContactBlocked(peerId)) continue
            folded += group.id
            groupPeers[group.id] = peerId
            val last = latestMarmotMessage(listOf(group))
            upsert(
                peerId,
                MeshDmRow(
                    peerId,
                    foldedPeerName(peerId, group),
                    last?.let { messagePreview(it.content, it.stickerRef, it.media) } ?: "Secure chat · reaches anywhere",
                    last?.tsSecs ?: 0L,
                )
            )
        }
        foldedGroupIds = folded
        foldedGroupPeerIds = groupPeers
        bumpHoldInputs()
        // Merge discovered folds into the persisted map (parity with iOS
        // marmotGroupIdsByConversationId). Prune entries for groups that no
        // longer exist so stale mappings don't accumulate.
        val activeGroupIds = chats.mapTo(hashSetOf()) { it.id }
        var foldMapChanged = false
        for ((gid, pid) in groupPeers) {
            if (groupFoldMap[gid] != pid) { groupFoldMap[gid] = pid; foldMapChanged = true }
        }
        val stale = groupFoldMap.keys.filter { it !in activeGroupIds }
        if (stale.isNotEmpty()) { stale.forEach { groupFoldMap.remove(it) }; foldMapChanged = true }
        if (foldMapChanged) {
            persistGroupFolds()
            updateBleDiscoveryPolicy()
        }
        meshDmRows = rowsByPeer.values.sortedByDescending { it.tsSecs }
    }

    private fun persistChatSnapshot() {
        SonarCore.saveBlob(
            CHAT_SNAPSHOT_BLOB_KEY,
            encodeChatSnapshot(chats, chatSnapshotMessagesByChat, chatSnapshotLatestByChat),
        )
    }

    private fun clearChatSnapshot() {
        chatSnapshotMessagesByChat = emptyMap()
        chatSnapshotLatestByChat = emptyMap()
        SonarCore.saveBlob(CHAT_SNAPSHOT_BLOB_KEY, "")
    }

    /** Coalesce concurrent refresh requests: one owner refreshes, other callers
     *  await the same completion, and burst arrivals become one trailing pass. */
    private suspend fun refreshChats() {
        var owner = false
        var completion: CompletableDeferred<Unit>? = null
        refreshMutex.withLock {
            if (refreshRunning) {
                refreshPending = true
                completion = refreshCompletion ?: CompletableDeferred<Unit>().also { refreshCompletion = it }
            } else {
                refreshRunning = true
                completion = CompletableDeferred()
                refreshCompletion = completion
                owner = true
            }
        }
        val currentCompletion = completion ?: return
        if (!owner) {
            currentCompletion.await()
            return
        }

        var completed = false
        var failure: Throwable? = null
        try {
            while (true) {
                refreshChatsInner()
                val finishedCompletion = refreshMutex.withLock {
                    if (refreshPending) {
                        refreshPending = false
                        null
                    } else {
                        refreshRunning = false
                        refreshCompletion.also { refreshCompletion = null }
                    }
                }
                if (finishedCompletion != null) {
                    finishedCompletion.complete(Unit)
                    completed = true
                    return
                }
            }
        } catch (t: Throwable) {
            failure = t
            throw t
        } finally {
            if (!completed) {
                withContext(NonCancellable) {
                    val failedCompletion = refreshMutex.withLock {
                        refreshRunning = false
                        refreshPending = false
                        refreshCompletion.also { refreshCompletion = null }
                    }
                    if (failedCompletion != null) {
                        val error = failure
                        if (error == null) failedCompletion.complete(Unit)
                        else failedCompletion.completeExceptionally(error)
                    }
                }
            }
        }
    }

    private suspend fun refreshChatsInner() {
        val previousOrder = chats.map { it.id }
        val loadedChats = SonarCore.chats()
        val localChats = if (localCoreReady || started || loadedChats.isNotEmpty()) loadedChats else chats
        val activeIds = localChats.mapTo(hashSetOf()) { it.id }
        val summaries = if (localChats.isEmpty()) emptyList() else runCatching {
            SonarCore.conversationSummaries()
        }.getOrDefault(emptyList())
        val pages = if (localChats.isEmpty()) emptyList() else runCatching {
                SonarCore.recentMessagePages(LOCAL_SUMMARY_CHAT_LIMIT, LOCAL_SUMMARY_PAGE_LIMIT)
        }.getOrDefault(emptyList())
        val hydration = hydrateLocalConversationRows(
            activeChatIds = activeIds,
            existingMessagesByChat = chatSnapshotMessagesByChat,
            existingLatestByChat = chatSnapshotLatestByChat,
            summaries = summaries,
            pages = pages,
        )

        // Publish one coherent local snapshot. Previously `chats = loadedChats`
        // rendered the core's raw order, then a suspension in
        // `recentMessagePages()` let Compose paint again before the recency sort.
        // That two-step hydrate was the visible startup reorder.
        chatSnapshotMessagesByChat = hydration.messagesByChat
        chatSnapshotLatestByChat = hydration.latestByChat
        chats = orderChatsByLocalRecency(
            chats = localChats,
            latestSecs = { hydration.latestByChat[it] ?: 0L },
            previousOrder = previousOrder,
        )
        persistChatSnapshot()
        refreshUnreadCounts()
        for (c in chats) {
            c.members.forEach {
                if (it != npub && it.isNotBlank()) ensureSonarDescriptor(it)
            }
        }
        groupInvites = runCatching { SonarCore.pendingGroupInvites() }.getOrDefault(emptyList())
        resolvePendingMarmotChats()
    }

    @OptIn(kotlinx.coroutines.FlowPreview::class)
    /** Per-key debounce jobs for [collectConversationChanges]: rapid changes to
     *  the SAME chat coalesce, but a burst across DIFFERENT chats no longer
     *  drops the losers (a stream-wide `debounce` kept only the last groupId,
     *  deferring the others' call/pay ring to a housekeeping cycle). */
    private val conversationChangeJobs = mutableMapOf<String, Job>()

    private fun collectConversationChanges() {
        SonarCore.conversationChanged
            .onEach { groupIdHex ->
                conversationChangeJobs.remove(groupIdHex)?.cancel()
                conversationChangeJobs[groupIdHex] = scope.launch {
                    delay(50)
                    handleConversationChange(groupIdHex)
                    conversationChangeJobs.remove(groupIdHex)
                }
            }
            .launchIn(scope)
    }

    private suspend fun handleConversationChange(groupIdHex: String) {
                // PRIMARY delivery path: refresh + process the CHANGED chat
                // immediately so a call rings / pay processes / the open
                // transcript updates without waiting for the heartbeat.
                refreshChats()
                val changedMessages = marmotMessagesPage(groupIdHex)
                val visibleChangedMessages = visibleMessagesForChat(groupIdHex, changedMessages)
                processPayLines(groupIdHex, visibleChangedMessages)
                processCallLines(groupIdHex, visibleChangedMessages)
                // The changed chat's newest ts is now handled; advance its scan
                // watermark (secs + processed count) so the housekeeping cycle
                // won't re-fetch its page for content we just processed.
                changedMessages.lastOrNull()?.tsSecs?.let { ts ->
                    val mark = ScanMark(ts, changedMessages.size.toLong())
                    val prev = scanWatermark[groupIdHex]
                    if (prev == null || mark.secs > prev.secs ||
                        (mark.secs == prev.secs && mark.count > prev.count)
                    ) scanWatermark[groupIdHex] = mark
                }
                (screen as? Screen.Chat)?.let { sc ->
                    if (!isMeshChat(sc.id) && (sc.id == groupIdHex || isSameDirectMarmotChat(sc.id, groupIdHex))) {
                        val mergedMessages = marmotMessagesPageForChat(sc.id)
                        setCurrentVisibleMessages(
                            sc.id,
                            withSendEchoes(sc.id, mergePendingMediaUploads(sc.id, mergedMessages)),
                            processCalls = true,
                        )
                    } else if (isMeshChat(sc.id)) {
                        val peerId = peerIdForMarmotGroup(groupIdHex)
                        if (peerId != null && sc.id == meshChatId(peerId)) {
                            refreshOpenDm(peerId)
                        }
                    }
                }
                // Fan the rest of the maintenance work (notifications, unread
                // counts, profile/presence/mesh upkeep) to the conflated
                // housekeeping consumer instead of doing it inline per event.
                requestHousekeeping()
    }

    private suspend fun refreshUnreadCounts() {
        val summaries = runCatching { SonarCore.conversationSummaries() }.getOrDefault(emptyList())
        applyUnreadCounts(summaries)
    }

    private fun applyUnreadCounts(summaries: List<SonarConversationSummary>) {
        val counts = mutableMapOf<String, Long>()
        for (s in summaries) {
            if (s.unreadCount > 0) counts[s.groupIdHex] = s.unreadCount
        }
        unreadByChat = counts
    }

    /** Request a housekeeping pass. Conflated: many requests within one in-flight
     *  cycle collapse to a single trailing run (Signal-style — react to database
     *  invalidation, don't busy-poll). Cheap and non-blocking; safe to call from
     *  the event flow and the heartbeat. */
    private fun requestHousekeeping() {
        housekeepingTrigger.trySend(Unit)
    }

    /** Event-driven consumer + slow fallback heartbeat.
     *
     *  Topology:
     *
     *      conversationChanged ─debounce─▶ requestHousekeeping ─┐
     *      heartbeat (30s fg / 60s bg) ── requestHousekeeping ──┤
     *                                                            ▼
     *                                        housekeepingTrigger (CONFLATED)
     *                                                            │
     *                                              runHousekeepingCycle()
     *
     *  The old 4 s poll ran the FULL cycle every 4 s forever. Now the cycle runs
     *  only when the core signals a conversation change (primary) or the slow
     *  heartbeat fires (fallback for time-based housekeeping the core can't
     *  signal: presence, BLE policy, unify, profile TTLs). Message delivery /
     *  call ringing / pay processing for the changed chat stay on the prompt
     *  `conversationChanged` path in [collectConversationChanges]. */
    private fun poll() {
        if (pollJob?.isActive == true) return
        startHousekeepingConsumer()
        pollJob = scope.launch {
            var beat = 0L
            while (true) {
                // Slow heartbeat: 30 s foreground, 60 s background. Foreground
                // events already drive the cycle, so idle-foreground CPU is set
                // by this cadence, not the old 4 s tick.
                delay(if (foreground) HEARTBEAT_FG_MS else HEARTBEAT_BG_MS)
                beat++
                // ensureSubscriptions / sync are relay-connection upkeep — keep a
                // wall-clock cadence (was every 4 s / every 60 s on the old tick).
                runCatching { SonarCore.ensureSubscriptions() }
                if (beat == 1L || (beat * effectiveHeartbeatMs()) % SYNC_INTERVAL_MS < effectiveHeartbeatMs()) {
                    runCatching { SonarCore.sync() }
                }
                // Coarse presence beat (~every 60 s), profile TTL sweep (~30 min).
                if (beat * effectiveHeartbeatMs() % PRESENCE_BEAT_MS < effectiveHeartbeatMs()) {
                    beatGlobalPresence()
                }
                if (beat * effectiveHeartbeatMs() % PROFILE_SWEEP_MS < effectiveHeartbeatMs()) {
                    sweepStaleProfiles()
                }
                requestHousekeeping()
            }
        }
    }

    private fun effectiveHeartbeatMs(): Long = if (foreground) HEARTBEAT_FG_MS else HEARTBEAT_BG_MS

    /** Drop cached kind-0 fetch state for profiles older than the refresh TTL so
     *  they get re-fetched. Was inlined in the old poll's `tick % 450` branch. */
    private fun sweepStaleProfiles() {
        val now = SonarClock.nowSecs()
        val stale = profileFetchedAt.entries
            .filter { now - it.value >= PROFILE_REFRESH_TTL_SECS }
            .map { it.key }
        stale.forEach { profileFetches.remove(it); profileFetchedAt.remove(it) }
        // Prune expired MISS markers too (they only throttle re-fetch, but grew
        // unbounded for npubs that came and went across a long-lived session).
        profileMissedAt.entries
            .filter { now - it.value >= PROFILE_MISS_TTL_SECS }
            .map { it.key }
            .forEach { profileMissedAt.remove(it) }
    }

    private fun startHousekeepingConsumer() {
        if (housekeepingJob?.isActive == true) return
        housekeepingJob = scope.launch {
            for (unit in housekeepingTrigger) {
                runCatching { runHousekeepingCycle() }
            }
        }
    }

    /** The periodic maintenance pass — everything the old 4 s poll did EXCEPT
     *  the relay-upkeep bits (moved to the heartbeat). Runs on the conflated
     *  trigger, so it fires promptly on a conversation change and otherwise at
     *  the slow heartbeat cadence. FFI is off the main thread (each SonarCore
     *  suspend hops to Dispatchers.IO), and per-chat page scanning is now
     *  incremental via the [scanWatermark]. */
    private suspend fun runHousekeepingCycle() {
        refreshChats()
        drainDirectDms()
        // One cheap FFI probe of every chat's newest message + unread count.
        val summaries = runCatching { SonarCore.conversationSummaries() }.getOrDefault(emptyList())
        val summaryByChat = summaries.associateBy { it.groupIdHex }
        applyUnreadCounts(summaries)
        // Incremental scan: only chats whose newest ts moved past the watermark
        // need a page fetch + ☎CALL / pay re-scan. Everything else is skipped —
        // this replaces the old O(chats) messagesPage()+re-parse every 4 s.
        scanChangedChatsForCallPay(summaryByChat)
        // Resolve kind-0 profiles for chat members so chats show names, not npubs.
        for (c in chats) c.members.forEach { if (it != npub) ensureProfile(it) }
        flushPendingMarmot() // a queued out-of-range send whose group just landed
        flushAllOutbox() // retry any outbox messages whose peer is now reachable
        maybeNotify(summaryByChat)
        // Marmot/Nostr chats refresh from the core; mesh chats are local and
        // refreshed by drainMeshDms(). A mesh-route DM merges both legs.
        (screen as? Screen.Chat)?.let {
            if (isMeshChat(it.id)) refreshOpenDm(meshPeerId(it.id))
            else {
                setCurrentVisibleMessages(it.id, withSendEchoes(it.id, mergePendingMediaUploads(it.id, marmotMessagesPageForChat(it.id))))
            }
        }
        (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
        (screen as? Screen.GeoDm)?.let { refreshGeoDm(it.geohash, it.peerHex) }
        // Sonar Discovery (0x53): keep our announce current for outgoing links
        // and decode any peers' announces received over the mesh.
        refreshBatterySaving()
        refreshMeshIdentity()
        updateBleDiscoveryPolicy()
        // Persist each peer's fingerprint→npub so its conversation stays unified
        // after it leaves range / after a restart, then re-fold the White Noise
        // legs into the mesh rows (one row per person).
        refreshSonarDiscoveryProfiles()
        updateMeshPeersFromRadio()
        recomputeConversations()
        // Unify nearby: keep the payer scan alive and refresh peers + receiver.
        startUnify()
        unifyPeers = UnifyRadio.peers()
        updateUnifyReceiver()
        if (locationChannels.isEmpty()) refreshLocationChannels()
        refreshPresenceCounts()
        if (walletAvailable && walletState is WalletState.Ready) {
            WalletBridge.refreshBalance()
            walletState = WalletBridge.state()
        }
    }

    /** Fetch + scan for ☎CALL / ⚡PAY lines only the chats whose newest message
     *  advanced past [scanWatermark]. So a call rings and a pay receipt processes
     *  even when the chat isn't open, but idle chats cost nothing beyond the
     *  single summaries() probe. Also emits the White Noise observability log. */
    private suspend fun scanChangedChatsForCallPay(
        summaryByChat: Map<String, SonarConversationSummary>,
    ) {
        val latestByChat = chats.associate { c ->
            val s = summaryByChat[c.id]
            c.id to ScanMark(s?.latestAtSecs ?: 0L, s?.messageCount ?: 0L)
        }
        val toScan = chatsNeedingPageScan(latestByChat, scanWatermark)
        var wnMsgs = 0
        val senders = mutableSetOf<String>()
        for (c in chats) {
            val summaryCount = summaryByChat[c.id]?.messageCount?.toInt()
            if (c.id !in toScan) {
                // Unchanged chat: no page fetch. Reuse the summary's count so the
                // observability total still reflects every group.
                wnMsgs += summaryCount ?: 0
                continue
            }
            val ms = runCatching { SonarCore.messagesPage(c.id, LOCAL_TRANSCRIPT_PAGE_LIMIT) }.getOrDefault(emptyList())
            val visibleMs = visibleMessagesForChat(c.id, ms)
            wnMsgs += summaryCount ?: ms.size
            processCallLines(c.id, visibleMs)
            processPayLines(c.id, visibleMs)
            if (c.members.size > 2) {
                for (m in visibleMs) {
                    if (!m.mine && m.senderNpub.isNotBlank()) senders.add(m.senderNpub)
                }
            }
            scanWatermark[c.id] = latestByChat[c.id] ?: ScanMark(0L, 0L)
        }
        // Prune watermarks for chats that no longer exist.
        if (scanWatermark.size > latestByChat.size) {
            scanWatermark.keys.retainAll(latestByChat.keys)
        }
        senders.forEach { ensureProfile(it) }
        if (chats.size != lastWnGroups || wnMsgs != lastWnMsgs) {
            sonarLog("SonarWN", "White Noise: ${chats.size} group(s), $wnMsgs message(s)")
            lastWnGroups = chats.size; lastWnMsgs = wnMsgs
        }
    }

    /** Live Marmot delivery (iOS `MarmotChatView.startPolling` parity): the
     *  relay subscriptions push welcomes/group messages into a core buffer that
     *  the host must drain — and `sync()` deliberately skips the kind-445 fetch
     *  while live subscriptions are active, so WITHOUT this loop pushed
     *  messages never reach local storage and an open transcript never
     *  refreshes. Park on [SonarCore.waitForMarmotEvent] (blocks one IO thread,
     *  no MLS state), then drain on wake; the drain writes to local storage and
     *  fires [SonarCore.conversationChanged] per chat, which the existing
     *  collector turns into transcript/chat-list repaints. On the idle timeout
     *  re-subscribe to self-heal dropped relay sockets. Cancelled by
     *  [stopMarmotWakeLoop] on wipe / account restore. */
    private fun startMarmotWakeLoop() {
        if (marmotWakeJob?.isActive == true) return
        marmotWakeJob = scope.launch {
            while (isActive) {
                val woke = SonarCore.waitForMarmotEvent(25)
                if (!isActive) return@launch
                if (woke) {
                    runCatching { SonarCore.drainPendingMarmot() }
                } else {
                    runCatching { SonarCore.ensureSubscriptions() }
                }
            }
        }
    }

    private fun stopMarmotWakeLoop() {
        marmotWakeJob?.cancel()
        marmotWakeJob = null
    }

    /** BLE mesh is the real-time rail for calls, so it must not wait for the
     *  heavier White Noise/Nostr sync poll. Drain lightweight mesh queues often
     *  enough that ANSWER/END controls reach the call engine without UI-visible
     *  delay. */
    private fun startMeshRealtimeLoop() {
        if (meshRealtimeLoopRunning) return
        meshRealtimeLoopRunning = true
        scope.launch {
            // Adaptive cadence (Signal-grade idle cost): the 150ms realtime
            // tick only earns its keep while BLE traffic is actually possible
            // — a peer in range or a recent drain hit. Otherwise 20 FFI
            // calls/sec burn CPU draining empty queues forever. Idle backs
            // off to 1s; any drain hit or in-range peer snaps back to 150ms.
            var lastActivityMs = 0L
            while (true) {
                val drained = drainMeshDms() or drainMeshMedia() or drainMeshBroadcasts()
                val nowMs = SonarClock.nowMillis()
                // hasActivePeer() is a cheap link/announce probe — unlike
                // peers() it doesn't build+sort the whole list every tick.
                if (drained || MeshRadio.hasActivePeer()) lastActivityMs = nowMs
                val fast = nowMs - lastActivityMs < MESH_REALTIME_HOT_WINDOW_MS
                delay(if (fast) 150 else 1000)
            }
        }
    }

    /** Broadcast our presence heartbeat (kind-20001) in [geohash]. Skips "mesh"
     *  (the Bluetooth channel has no Nostr presence) and throttles to once per
     *  beat so we don't spam the relays. */
    private suspend fun beatPresence(geohash: String) {
        if (geohash.isBlank() || geohash == "mesh") return
        runCatching { SonarCore.sendChannelPresence(geohash) }
    }

    /** Broadcast presence to the low-precision location channels, mirroring iOS
     *  `GeohashPresenceService`: region(2)/province(4)/city(5) ONLY — never
     *  neighborhood/block/building (privacy). This is what makes other apps
     *  (iOS/bitchat) count this device in "N here now" for those channels. */
    private suspend fun beatGlobalPresence() {
        val coarse = setOf(GeoLevel.Region, GeoLevel.Province, GeoLevel.City)
        locationChannels
            .filter { it.level in coarse && it.geohash != "mesh" }
            .forEach { beatPresence(it.geohash) }
    }

    /** Refresh "N here now" counts for the open channel + the location channels
     *  shown on Home, so people see live participation without opening each. */
    private suspend fun refreshPresenceCounts() {
        val targets = LinkedHashSet<String>()
        (screen as? Screen.Channel)?.let { if (it.geohash != "mesh") targets.add(it.geohash) }
        locationChannels.forEach { if (it.geohash != "mesh") targets.add(it.geohash) }
        if (targets.isEmpty()) return
        val next = presenceByGeohash.toMutableMap()
        for (gh in targets) next[gh] = SonarCore.channelPresenceCount(gh)
        presenceByGeohash = next
    }
}
