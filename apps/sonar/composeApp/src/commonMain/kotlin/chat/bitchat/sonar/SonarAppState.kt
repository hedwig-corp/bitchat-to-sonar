package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.currentCoroutineContext
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
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.TimeSource
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.account_restored_chat_backup_restore
import chat.bitchat.sonar.resources.account_restored_chats_recovered_from
import chat.bitchat.sonar.resources.account_restored_chats_start_empty
import chat.bitchat.sonar.resources.backup_failed_try_again_when_online
import chat.bitchat.sonar.resources.chat_backup_uploaded
import org.jetbrains.compose.resources.getString

private const val SONAR_DESCRIPTOR_TTL_SECS = 15 * 60L
private const val SONAR_DESCRIPTOR_MISS_TTL_SECS = 60L
private const val PROFILE_MISS_TTL_SECS = 60L
/** How long after BLE activity the mesh drain loop stays at 150ms. */
private const val MESH_REALTIME_HOT_WINDOW_MS = 30_000L
private const val PROFILE_REFRESH_TTL_SECS = 30 * 60L
/** Non-render scan budget used by pay/call reconciliation and media matching. */
private const val BACKGROUND_TRANSCRIPT_SCAN_LIMIT = 100
/** Two local pages of IDs cover overlap between incremental notification scans. */
private const val NOTIFICATION_SEEN_MESSAGE_LIMIT = BACKGROUND_TRANSCRIPT_SCAN_LIMIT * 2
/** Local re-read cadence for a transcript that opened blank on a conversation
 *  known to have messages. Short first step so the common case (core finishing
 *  its boot) repaints in well under a second; the budget bounds the whole thing
 *  so a genuinely unreadable store cannot spin. */
private const val BLANK_TRANSCRIPT_RETRY_START_MS = 100L
private const val BLANK_TRANSCRIPT_RETRY_MAX_STEP_MS = 800L
private const val BLANK_TRANSCRIPT_RETRY_BUDGET_MS = 8_000L
private const val LOCAL_SUMMARY_PAGE_LIMIT = 20
private const val LOCAL_SUMMARY_CHAT_LIMIT = 5

/** Backoff before rebuilding an attach that an invalidate superseded mid-flight.
 *  Short on purpose — the user is back in the foreground and the sockets we just
 *  built are suspect — but non-zero so a fast background/foreground flap settles
 *  before we spend another attach on it. */
private const val RELAY_SUPERSEDED_RETRY_MS = 1_000L
private const val MARMOT_ECHO_RECONCILE_POLL_MS = 100L
private const val MARMOT_ECHO_RECONCILE_MAX_ATTEMPTS = 10

/** Debug-device benchmark input supplied by the platform launcher. Keeping the
 * pack address explicit avoids shipping a user-visible fallback pack. */
data class StickerBenchmarkRequest(
    val authorPubkeyHex: String,
    val identifier: String,
    val imageLimit: Int = 8,
    val imageOffset: Int = 0,
    val relayUrls: List<String> = emptyList(),
)

// ── Event-driven refresh cadence ──
// The old poll ran a full cycle every 4 s. Now the cycle is driven by the core
// `conversationChanged` flow (primary) plus a slow fallback heartbeat that only
// covers time-based upkeep the core can't signal (presence, BLE policy, unify,
// profile TTLs). Foreground idle CPU is set by the heartbeat cadence.
private const val HEARTBEAT_FG_MS = 30_000L
private const val HEARTBEAT_BG_MS = 60_000L
/** Visible-Radar cadence for publishing BLE mesh + payment scan results to UI. */
private const val NEARBY_PEER_REFRESH_MS = 1_000L
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

internal fun shouldScanForNearbyPayments(
    isNearbyVisible: Boolean,
    isForeground: Boolean,
    isOnboarded: Boolean,
    isDiscoveryRestricted: Boolean,
): Boolean = isNearbyVisible && isForeground && isOnboarded && !isDiscoveryRestricted

internal fun shouldRefreshNearbyPeers(
    isNearbyVisible: Boolean,
    isForeground: Boolean,
    isOnboarded: Boolean,
): Boolean = isNearbyVisible && isForeground && isOnboarded

/** Radar presence follows the verified bitchat announce immediately. The later
 *  Sonar 0x53 profile upgrades the same stable peer in place; capability
 *  settling belongs only to conversation folding. */
internal fun visibleRadarMeshPeers(
    rawPeers: List<MeshPeer>,
    isBlocked: (String) -> Boolean,
): List<MeshPeer> = rawPeers.filterNot { peer ->
    isBlocked(peer.id.removePrefix("mesh:"))
}

/** Compact percent-encoding for Debug SONAR_BENCH nick tokens (spaces/emoji-safe). */
internal fun benchNickToken(nick: String): String {
    if (nick.isEmpty()) return "_"
    val out = StringBuilder(nick.length)
    for (ch in nick) {
        when {
            ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == '.' || ch == '~' -> out.append(ch)
            else -> {
                val bytes = ch.toString().encodeToByteArray()
                for (b in bytes) out.append('%').append(((b.toInt() and 0xFF)).toString(16).padStart(2, '0').uppercase())
            }
        }
    }
    return out.toString()
}

/** A burst of radio/profile invalidations needs at most one refresh in flight
 * and one follow-up refresh. Conflation prevents BLE callback volume from
 * turning into an unbounded main-thread coroutine queue — the same 1+1 trailing
 * shape used by [chat.bitchat.sonar.wallet.WalletBridge] balance refresh and
 * Signal-style DB invalidation (react once, don't enqueue every callback). */
internal class ConflatedRefreshQueue(
    scope: CoroutineScope,
    refresh: suspend () -> Unit,
) {
    private val requests = Channel<Unit>(Channel.CONFLATED)
    /** Requests dropped because a trailing refresh was already pending. Bench-only. */
    private var droppedRequests = 0L
    private val worker = scope.launch {
        for (ignored in requests) {
            // A transient UniFFI/radio failure must not kill the sole worker —
            // later invalidations still need to be consumed from the channel.
            try {
                refresh()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Best-effort: the next request retries.
            }
        }
    }

    fun request() {
        if (!requests.isEmpty) droppedRequests++
        requests.trySend(Unit)
    }

    /** Consume and reset the conflation counter (Debug SONAR_BENCH mesh_refresh_end). */
    fun takeDroppedRequests(): Long {
        val n = droppedRequests
        droppedRequests = 0
        return n
    }

    fun cancel() {
        requests.close()
        worker.cancel()
    }
}

internal fun <M, U> CoroutineScope.launchNearbyPeerRefresh(
    intervalMs: Long = NEARBY_PEER_REFRESH_MS,
    readMeshPeers: suspend () -> List<M>,
    publishMeshPeers: (List<M>) -> Unit,
    readUnifyPeers: suspend () -> List<U>,
    publishUnifyPeers: (List<U>) -> Unit,
): Job = launch {
    // Mesh publishes every tick: other writers (push invalidation, housekeeping,
    // capability settle) also call updateMeshPeersFromRadio, so a job-local
    // lastMeshPeers cache can suppress a real A→empty→A recovery. The publisher
    // itself is change-only. Unify has a single writer, so it keeps the cache.
    var lastUnifyPeers: List<U>? = null
    while (isActive) {
        publishMeshPeers(readMeshPeers().toList())
        val unifyPeers = readUnifyPeers().toList()
        if (unifyPeers != lastUnifyPeers) {
            lastUnifyPeers = unifyPeers
            publishUnifyPeers(unifyPeers)
        }
        delay(intervalMs)
    }
}

/** The core send decides whether a message reached the durable local outbox.
 * Transcript reconciliation is best-effort and must not turn a queued send
 * into a failed send. */
internal suspend fun runMarmotSendWithBestEffortReconciliation(
    send: suspend () -> Unit,
    reconcile: suspend () -> Unit,
    onSendAccepted: () -> Unit,
    onSendFailure: (Throwable) -> Unit,
    onReconciliationFailure: (Throwable) -> Unit,
) {
    try {
        send()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        onSendFailure(error)
        return
    }
    onSendAccepted()

    try {
        reconcile()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        onReconciliationFailure(error)
    }
}

/**
 * Mesh→White Noise send echoes must stay on the open mesh transcript until a
 * folded canonical White Noise row is present. Clearing first made the
 * "Sending · internet" bubble vanish for seconds while refreshOpenDm caught up.
 */
internal fun shouldClearMeshMarmotSendEcho(hasCanonicalRow: Boolean): Boolean = hasCanonicalRow

internal data class SendEchoDisplayPlan(
    val visibleEchoes: List<SonarMsg>,
    val terminalAcceptedEchoIds: Set<String>,
    /** Fulfilling rows the render window excluded; re-add them or the send vanishes. */
    val admittedCanonical: List<SonarMsg> = emptyList(),
)

internal fun planSendEchoDisplay(
    echoes: List<SonarMsg>,
    published: List<SonarMsg>,
    excludedPublishedIdsByEcho: Map<String, Set<String>> = emptyMap(),
    // Deliberately NOT defaulted — see reconcileSendEchoes. `withSendEchoes`
    // dropping this argument is the exact regression #290 fixed, and no
    // helper-level test can catch it. Make the compiler catch it instead.
    freshCanonical: List<SonarMsg>,
): SendEchoDisplayPlan {
    val reconciliation = reconcileSendEchoes(
        echoes,
        published,
        excludedPublishedIdsByEcho,
        freshCanonical,
    )
    val fulfilled = reconciliation.fulfilledEchoIds
    return SendEchoDisplayPlan(
        visibleEchoes = echoes.filterNot { it.id in fulfilled },
        terminalAcceptedEchoIds = echoes
            .asSequence()
            .filter { it.state == "Accepted" && it.id in fulfilled }
            .mapTo(mutableSetOf()) { it.id },
        admittedCanonical = reconciliation.admittedCanonical,
    )
}

internal fun sendEchoAwaitsCanonicalRow(echo: SonarMsg): Boolean =
    echo.state == "Sending" || echo.state == "Accepted"

/** A media drop may wait for a direct White Noise group that chat startup has
 * already begun creating. This is deliberately separate from send readiness:
 * it keeps the desktop drop target usable without duplicating group setup. */
internal fun canPrepareAttachmentRoute(
    hasMeshRoute: Boolean,
    hasExistingMarmotRoute: Boolean,
    hasPendingDirectMarmotRoute: Boolean,
): Boolean = hasMeshRoute || hasExistingMarmotRoute || hasPendingDirectMarmotRoute

internal sealed interface AttachmentRoutePreparation {
    data class Ready(val chatId: String) : AttachmentRoutePreparation
    data object Unavailable : AttachmentRoutePreparation
    data object Failed : AttachmentRoutePreparation
}

internal fun shortNpubLabel(value: String): String =
    if (value.length > 16) value.take(10) + "…" + value.takeLast(4) else value

internal fun sonarSendEchoMatches(published: SonarMsg, echo: SonarMsg): Boolean =
    published.content == echo.content &&
        published.stickerRef == echo.stickerRef &&
        published.viaInternet == echo.viaInternet &&
        published.tsSecs > echo.tsSecs && published.tsSecs - echo.tsSecs < 30

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
    /** Recipient picker for content arriving from the system share sheet. */
    data object ShareTo : Screen
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
    /** Standalone send-payment picker (new-chat sheet → "Send a payment"). */
    data object SendPayment : Screen
}

/** A BLE-mesh DM conversation row for the home Messages list. */
data class MeshDmRow(val peerId: String, val name: String, val preview: String, val tsSecs: Long)

/** A local contact that can be invited into a Marmot group. */
data class GroupContact(val id: String, val title: String, val subtitle: String, val npub: String)

/**
 * A contact we already hold a BOLT12 offer for, so the send-payment picker can
 * pay them without opening the chat first (pay.jsx `SendPaymentScreen`, the
 * "People you can pay" list). [chatId] is the conversation the payment belongs
 * to — paying through it keeps the in-chat ⚡PAY receipt.
 */
data class PayableContact(
    val chatId: String,
    val name: String,
    val subtitle: String,
    val nearby: Boolean,
)

internal fun messagePreview(content: String, stickerRef: SonarStickerRef? = null, media: List<SonarMedia> = emptyList()): String {
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
    if (TrillLine.isTrillLine(content)) return "Nudge"
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

/** Rename-signal decision: force a kind-0 refetch only when the BLE name is
 *  real, differs from the cached profile name, and no fetch is in flight or
 *  recently done. */
internal fun shouldForceProfileRefetch(cachedName: String?, liveName: String?, fetchInFlightOrRecent: Boolean): Boolean =
    !liveName.isNullOrBlank() && cachedName != null && cachedName != liveName && !fetchInFlightOrRecent

/** Row title for a 1:1 Marmot chat: the counterpart's live kind-0 profile
 *  name wins; the creation-time MLS group name is only a placeholder until the
 *  profile lands, and a short npub is the last resort. */
internal fun directChatRowTitle(profileName: String?, groupName: String, npubFallback: String): String =
    profileName?.takeIf { it.isNotBlank() } ?: groupName.ifBlank { npubFallback }

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

/** Folded transport routing must inspect every fingerprint for the account, not
 * only the canonical row id. */
internal fun aliasesSupportMarmotRoute(
    aliases: Iterable<String>,
    hasSonarProfile: (String) -> Boolean,
    capabilitiesForAlias: (String) -> Int,
): Boolean = aliases.any { alias ->
    hasSonarProfile(alias) ||
        (capabilitiesForAlias(alias) and SonarAnnounce.CAP_MARMOT) != 0
}

internal fun aliasesHaveMutualFavorite(
    aliases: Iterable<String>,
    isFavorite: (String) -> Boolean,
    isRemoteFavorite: (String) -> Boolean,
): Boolean {
    val stableAliases = aliases.toList()
    return stableAliases.any(isFavorite) && stableAliases.any(isRemoteFavorite)
}

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

internal fun sameMeshConversationIdentity(
    firstPeerId: String,
    secondPeerId: String,
    linkedNpubByPeer: Map<String, String>,
): Boolean = meshConversationIdentityKey(firstPeerId, linkedNpubByPeer[firstPeerId]) ==
    meshConversationIdentityKey(secondPeerId, linkedNpubByPeer[secondPeerId])

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
    stagedPageChatIds: Set<String> = emptySet(),
): Set<String> = buildSet {
    for ((chatId, latest) in latestByChat) {
        val seen = scannedWatermark[chatId] ?: ScanMark(Long.MIN_VALUE, Long.MIN_VALUE)
        // A later second, OR the same second with more messages, means unseen
        // content — either way the chat needs a rescan.
        if (latest.secs > seen.secs || (latest.secs == seen.secs && latest.count > seen.count)) {
            add(chatId)
        }
    }
    // The event-driven fast path may already have fetched the changed page.
    // Consume it even if an older implementation/predecessor advanced the
    // scan mark first, and avoid a duplicate local FFI page read.
    addAll(stagedPageChatIds.intersect(latestByChat.keys))
}

/** Newest eligible message in a bounded local page that was not present in a
 * previous page. The timestamp floor rejects old out-of-order/backfilled rows;
 * stable message IDs still distinguish two real arrivals in the same second. */
internal fun newestUnseenIncoming(
    messages: List<SonarMsg>,
    seenMessageIds: Set<String>,
    previousLatestSecs: Long?,
    isOpen: Boolean,
    allowsMessage: (SonarMsg) -> Boolean = { true },
): SonarMsg? {
    if (isOpen || previousLatestSecs == null) return null
    return messages.asSequence()
        .filter { !it.mine }
        .filter { it.id !in seenMessageIds }
        .filter { it.tsSecs >= previousLatestSecs }
        .filter(allowsMessage)
        .maxWithOrNull(compareBy<SonarMsg> { it.tsSecs }.thenBy { it.id })
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

internal fun shouldExposeCachedStickerPack(
    coordinate: String,
    installedCoordinates: Set<String>,
): Boolean = normalizeStickerPackCoordinate(coordinate) in installedCoordinates

internal fun normalizeStickerPackCoordinate(coordinate: String): String {
    val firstSeparator = coordinate.indexOf(':')
    if (firstSeparator < 0) return coordinate
    val secondSeparator = coordinate.indexOf(':', startIndex = firstSeparator + 1)
    if (secondSeparator < 0) return coordinate
    return buildString(coordinate.length) {
        append(coordinate, 0, firstSeparator + 1)
        append(coordinate.substring(firstSeparator + 1, secondSeparator).lowercase())
        append(coordinate, secondSeparator, coordinate.length)
    }
}

internal fun stickerPackInstalledState(
    coordinate: String,
    refreshedCoordinates: List<String>?,
    cachedInstalled: Boolean,
): Boolean = refreshedCoordinates?.any {
    normalizeStickerPackCoordinate(it) == normalizeStickerPackCoordinate(coordinate)
} ?: cachedInstalled

internal enum class StickerCacheLookupState { HIT, MISS, INVALIDATED }

private const val STICKER_IMAGE_MEMORY_BUDGET_BYTES = 25 * 1024 * 1024
private const val STICKER_IMAGE_MEMORY_ENTRY_LIMIT = 100

/** Cap on remembered unresolvable refs. A peer can mint refs freely, so the
 *  negative cache that protects the relay must itself be bounded. */
private const val STICKER_UNRESOLVABLE_REF_LIMIT = 256

/** Stable identity of a sticker reference. Only the hash is case-normalized:
 *  identifier and shortcode are case-sensitive per the pack model. */
internal fun stickerRefMemoryKey(
    packCoordinate: String,
    shortcode: String,
    plaintextSha256: String,
): String =
    "${normalizeStickerPackCoordinate(packCoordinate)}|$shortcode|${plaintextSha256.lowercase()}"

/** Delay before retry [attempt] (0-based) of a failed transcript sticker load,
 *  or null when attempts are exhausted. Bubbles keep the failed placeholder
 *  visible while these run, so the schedule stays short and bounded. */
internal fun stickerLoadRetryDelayMs(attempt: Int): Long? = when (attempt) {
    0 -> 2_000L
    1 -> 8_000L
    else -> null
}

internal fun stickerCacheLookupState(
    hasBytes: Boolean,
    startedGeneration: Long,
    currentGeneration: Long,
): StickerCacheLookupState = when {
    startedGeneration != currentGeneration -> StickerCacheLookupState.INVALIDATED
    hasBytes -> StickerCacheLookupState.HIT
    else -> StickerCacheLookupState.MISS
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
    val id: String,
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

/** Lifecycle of a handle claim (`vincenzo@sonarprivacy.xyz`) driven from the
 *  profile screen. One state machine, no concurrent claims. */
sealed interface HandleClaimState {
    data object Idle : HandleClaimState
    data object Claiming : HandleClaimState
    data class Claimed(val address: String) : HandleClaimState
    data class Failed(val message: String) : HandleClaimState
}

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
class SonarAccountRestoreException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

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
    /** Mirrors [SonarCore.isRelayConnected] for the UI.
     *
     * The status chip, the Connections sheet and the Settings row all describe
     * *internet* reachability ("Online · reaches anyone" vs "Offline — messages
     * wait or travel over Bluetooth"), so they must follow the relay latch.
     * They used to read [started], which only means the local encrypted core
     * booted, so a relay outage still rendered "Online · Connected · Nostr
     * relays". Matches iOS `SonarAppStore.online`, which is already gated on
     * `marmot.relayConnected`. */
    var relayOnline by mutableStateOf(false)
        private set
    /** True while a relay attach is in flight, so the chip can say
     *  "Offline · connecting…" instead of implying a dead network. */
    var relayConnecting by mutableStateOf(false)
        private set
    /** Number of catch-up syncs in flight. Overlap-safe: concurrent
     *  foreground-cycle + immediate-sync jobs each increment/decrement so the
     *  first one to finish cannot clear the chip while another still runs. */
    private var activeCatchupSyncs by mutableStateOf(0)
    /** True while a foreground/push-tap catch-up sync is running. Passive UI
     *  signal only (status chip subtitle); never gates paint or sending. */
    val syncing: Boolean get() = activeCatchupSyncs > 0
    /** Single-flight guard for the forced gap-recovery sync so overlapping
     *  foreground/immediate-sync requests don't double-enqueue syncForce on the
     *  serial engine queue (which is shared with sends). Confined to the Main
     *  dispatcher (all callers run on `scope`, which is a UI scope). */
    private var forcedCatchupInFlight = false
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

    /** Public Sonar descriptors by raw npub hex, used for out-of-BLE call parity
     *  and for the BOLT12 offer that unlocks "Send bitcoin". Hydrated from the
     *  persisted cache so a cold start paints the payment affordance from local
     *  state instead of waiting on a relay round-trip. */
    var sonarDescriptorsByNpubHex by mutableStateOf(
        boundedSonarDescriptorCache(
            decodeSonarDescriptorCache(SonarCore.loadBlob(SONAR_DESCRIPTOR_CACHE_BLOB_KEY))
        )
    )
        private set
    private val sonarDescriptorFetches = mutableSetOf<String>()
    private val sonarDescriptorFetchedAt = mutableMapOf<String, Long>()
    private val sonarDescriptorMissedAt = mutableMapOf<String, Long>()
    /** Bumped on identity teardown so a descriptor fetch started under the old
     *  account cannot land — and persist — after the wipe. */
    private var descriptorCacheGeneration = 0
    private var stack by mutableStateOf<List<Screen>>(listOf(Screen.Home))
    val screen: Screen get() = stack.last()

    var dark by mutableStateOf(SonarCore.isDark())
        private set
    var discoverNewPeople by mutableStateOf(SonarCore.loadBlob("pref.$BLE_DISCOVER_NEW_PEOPLE_PREF").let { it.isEmpty() || it == "1" })
        private set
    var batterySaving by mutableStateOf(BatterySaver.enabled())
        private set

    var callOverlay = false

    // Debug-only SONAR_BENCH clock: armed when a chat screen is pushed, read
    // (and disarmed) by ChatScreen's first composed frame. Always null in
    // Release (sonarBenchMarkersEnabled gates the write and the read).
    var chatOpenBenchMark: kotlin.time.TimeSource.Monotonic.ValueTimeMark? = null

    fun push(s: Screen) {
        if (s is Screen.Chat && (screen as? Screen.Chat)?.id != s.id) {
            cleanupPreviewTempFiles()
            if (sonarBenchMarkersEnabled) {
                chatOpenBenchMark = kotlin.time.TimeSource.Monotonic.markNow()
            }
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
            endTranscriptSession()
            relayConnectJob?.cancel(); relayConnectJob = null
            resetStartupFlags()
            refreshRelayOnline()
            val marmotDeliveryGeneration = cancelPendingMarmotPeerDeliveryJobs { MeshRadio.stop() }
            try {
            cancelPendingMarmotSetups()
            cancelPendingMarmotGroupSetups()
            val walletShutdownFailure = runCatching { WalletBridge.shutdown() }.exceptionOrNull()
            val walletWipeFailure = runCatching { WalletBridge.wipeLocalStorage() }.exceptionOrNull()
            UnifyRadio.stopScanning()
            UnifyRadio.stopAdvertising()
            unifyOffer = null; unifyPeers = emptyList()
            nearbyPeerRefreshJob?.cancel(); nearbyPeerRefreshJob = null
            // Gate push invalidation before MeshRadio.stop() — stop notifies the
            // peer listener, which must not re-persist wiped mesh names/links.
            onboarded = false; started = false
            MeshRadio.stop()
            MeshRadio.setMeshNickname("")
            MeshRadio.discardPendingDeliverySignals()
            MeshRadio.setLocalSonarAnnounce(null); sonarPeerProfiles = emptyMap()
            meshPeers = emptyList()
            linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
            meshChats.clear(); meshEchoIds.clear(); meshChatNames.clear(); meshDmRows = emptyList(); meshBroadcast = emptyList()
            foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            persistLinks(); persistLinkCaps(); persistGroupFolds()
            updateBleDiscoveryPolicy()
            // Bump BEFORE the suspending write: persistSonarDescriptorCacheNow()
            // suspends, and an in-flight fetch resuming in that window would
            // otherwise still pass performDescriptorFetch's generation guard and
            // repopulate the map we just cleared.
            sonarDescriptorsByNpubHex = emptyMap(); descriptorCacheGeneration++; persistSonarDescriptorCacheNow()
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
            // Redact all visible/account-bound host state before the fallible
            // durable wipe. A filesystem error must never leave old chats or
            // sticker bytes painted after credentials have been cleared.
            stack = listOf(Screen.Home)
            chats = emptyList(); chatSnapshotMessagesByChat = emptyMap(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); groupInvites = emptyList(); messages = emptyList(); retainedTranscriptByChat.clear()
            clearChatSnapshot()
            cancelAllMediaDownloads(); MediaCache.wipe(); clearOpenChatTransientState()
            mediaCache.clear(); clearStickerCaches()
            val coreWipeFailure = runCatching { SonarCore.wipe() }.exceptionOrNull()
            nick = ""; npub = ""
            localCoreReady = false; homeMessagesHydrated = false
            walletState = WalletState.NotConfigured
            presenceByGeohash = emptyMap()
            payLedger = SonarPayLedger(); payVersion++
            PaymentActivityStore.wipe() // iOS wipes both payment ledgers together
            mutedUntilByChat = emptyMap() // blob dies with SonarCore.wipe()
            bip353 = ""
            callLogs.clear(); callVersion++
            resetCallState()
            pollJob?.cancel(); pollJob = null
            housekeepingJob?.cancel(); housekeepingJob = null
            stopMarmotWakeLoop()
            if (coreWipeFailure != null || walletShutdownFailure != null || walletWipeFailure != null) {
                toast = "Local storage wipe was incomplete; Sonar will retry before reusing caches."
            }
            } finally {
                resumePendingMarmotPeerDelivery(marmotDeliveryGeneration)
            }
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
            endTranscriptSession()
            val marmotDeliveryGeneration = cancelPendingMarmotPeerDeliveryJobs { MeshRadio.stop() }
            try {
            cancelPendingMarmotSetups()
            cancelPendingMarmotGroupSetups()
            // Local transcripts on disk (mesh DMs, channels, geo DMs).
            MessageStore.wipe()
            // In-memory conversation state. Undrained BLE failure/receipt
            // signals reference erased rows, so drop them here (never in the
            // ordinary MeshRadio.stop() path).
            MeshRadio.discardPendingDeliverySignals()
            meshChats.clear(); meshEchoIds.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); pendingDirectMarmotSends.clear(); pendingMarmotGroupSends.clear(); outbox.clear()
            persistMeshNames() // clear the on-disk name cache too, else boot resurrects erased names
            pendingMarmotChatNpubs = emptyMap()
            pendingMarmotGroups = emptyMap()
            linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
            persistLinks(); persistLinkCaps(); persistGroupFolds()
            profilesByNpub = emptyMap(); profileFetches.clear(); persistProfileCacheNow()
            foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            meshBroadcast = emptyList(); meshDmRows = emptyList()
            updateBleDiscoveryPolicy()
            messages = emptyList(); channelMsgs = emptyList(); chats = emptyList(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); clearChatSnapshot()
            retainedTranscriptByChat.clear()
            transcriptWindows.clear()
            // Leave the old composer before the delivery suspension is lifted.
            stack = listOf(Screen.Home)
            lastWnGroups = -1; lastWnMsgs = -1
            // ⚡PAY coins live inside the erased chats — reset the ledger. The
            // Lightning wallet seed/balance is separate and is NOT touched.
            // iOS eraseChatsKeepIdentity also wipes the activity ledger.
            payLedger = SonarPayLedger(); persistPay(); payVersion++
            PaymentActivityStore.wipe()
            cancelAllMediaDownloads(); MediaCache.wipe(); clearOpenChatTransientState()
            mediaCache.clear(); clearStickerCaches()
            callLogs.clear(); callVersion++
            notificationSeenMessageIds.clear(); notificationLatestSecs.clear()
            scanWatermark.clear(); stagedChangedPages.clear(); failedChangedPageReads.clear()
            // White Noise / Marmot DB: wipe + reconnect with the SAME identity.
            runCatching { SonarCore.eraseChats() }
            } finally {
                resumePendingMarmotPeerDelivery(marmotDeliveryGeneration)
            }
            resetStartupFlags()
            refreshRelayOnline()
            localCoreReady = true
            homeMessagesHydrated = true
            // The node is recreated → re-bind the iroh call endpoint on next use.
            resetCallState()
            startRelayConnection()
            ensureCallStarted()
            refreshMeshIdentity()
            MeshRadio.start()
            refreshChats()
            toast = "All chats erased"
        }
    }

    var messages by mutableStateOf<List<SonarMsg>>(emptyList())
        private set

    /**
     * Last painted transcript per chat (Signal-Android keeps adapter contents
     * across leave/reopen). Reopen paints this synchronously *before* [push]
     * so ChatScreen's first frame is never an empty/home leftover rebuild.
     */
    private val retainedTranscriptByChat = mutableMapOf<String, List<SonarMsg>>()

    /** One bounded canonical DB window per folded Marmot source group. */
    private data class TranscriptGroupWindow(
        val rows: List<SonarMsg>,
        val hasMore: Boolean,
        val loadingOlder: Boolean = false,
        val pinnedToOlderEdge: Boolean = false,
    )

    private val transcriptWindows = mutableMapOf<String, TranscriptGroupWindow>()
    private var meshTranscriptRows: List<SonarMsg> = emptyList()
    private var meshTranscriptHasMore = false
    private var meshTranscriptPinnedToOlderEdge = false
    private var conversationTranscriptRows: List<SonarMsg> = emptyList()
    private var conversationVisibleRowLimit = TRANSCRIPT_PAGE_SIZE
    private var conversationPinnedToOlderEdge by mutableStateOf(false)
    private var transcriptGeneration = 0L
    private var activeTranscriptChatId: String? = null

    private fun isCurrentTranscriptSession(chatId: String, generation: Long): Boolean =
        generation == transcriptGeneration &&
            activeTranscriptChatId == chatId &&
            (screen as? Screen.Chat)?.id == chatId

    /** Session still owned while the first local page loads *before* [push]. */
    private fun isActiveTranscriptGeneration(chatId: String, generation: Long): Boolean =
        generation == transcriptGeneration && activeTranscriptChatId == chatId

    private fun beginTranscriptSession(chatId: String): Long {
        transcriptGeneration += 1
        activeTranscriptChatId = chatId
        // Reopening starts from a viewport-sized local page. Older pages are a
        // property of the live view, not an account-wide plaintext cache.
        transcriptWindows.clear()
        freshCanonicalByGroup.clear()
        meshTranscriptRows = emptyList()
        meshTranscriptHasMore = false
        meshTranscriptPinnedToOlderEdge = false
        conversationTranscriptRows = emptyList()
        conversationVisibleRowLimit = TRANSCRIPT_PAGE_SIZE
        conversationPinnedToOlderEdge = false
        return transcriptGeneration
    }

    private fun endTranscriptSession() {
        transcriptGeneration += 1
        activeTranscriptChatId = null
        transcriptWindows.clear()
        freshCanonicalByGroup.clear()
        meshTranscriptRows = emptyList()
        meshTranscriptHasMore = false
        meshTranscriptPinnedToOlderEdge = false
        conversationTranscriptRows = emptyList()
        conversationVisibleRowLimit = TRANSCRIPT_PAGE_SIZE
        conversationPinnedToOlderEdge = false
    }

    /** True when the active 500-row window has moved away from the newest edge. */
    fun canLoadNewestMessages(chatId: String): Boolean =
        conversationPinnedToOlderEdge &&
            activeTranscriptChatId == chatId &&
            (screen as? Screen.Chat)?.id == chatId

    /**
     * Reset this live conversation to its bounded newest edge. Advancing the
     * generation invalidates any older-page query still suspended in the core.
     */
    suspend fun loadNewestMessages(chatId: String): Boolean {
        if (!canLoadNewestMessages(chatId)) return false
        val generation = beginTranscriptSession(chatId)

        // Paint a bounded local tail immediately, before any FFI cursor read.
        val snapshot = if (isMeshChat(chatId)) {
            refreshMeshTranscriptWindow(meshPeerId(chatId))
        } else {
            chatSnapshotMessagesByChat[chatId].orEmpty().takeLast(TRANSCRIPT_PAGE_SIZE)
        }
        val immediate = refreshConversationRows(snapshot, chatId, generation)
        setCurrentVisibleMessages(
            chatId,
            withSendEchoes(chatId, mergePendingMediaUploads(chatId, immediate)),
            processCalls = true,
        )

        val newest = when {
            isMeshChat(chatId) -> {
                val peerId = meshPeerId(chatId)
                refreshMeshTranscriptWindow(peerId) + marmotMessagesForPeer(peerId, chatId, generation)
            }
            pendingMarmotNpub(chatId) != null || isPendingMarmotGroup(chatId) -> emptyList()
            else -> marmotMessagesPageForChat(chatId, generation)
        }
        if (!isCurrentTranscriptSession(chatId, generation)) return false
        val visibleNewest = refreshConversationRows(newest, chatId, generation)
        setCurrentVisibleMessages(
            chatId,
            withSendEchoes(chatId, mergePendingMediaUploads(chatId, visibleNewest)),
            processCalls = true,
        )
        return true
    }

    /** Sending owns its transport path; newest-edge restoration is independent. */
    private fun reloadNewestAfterSendIfNeeded(chatId: String) {
        if (canLoadNewestMessages(chatId)) scope.launch { loadNewestMessages(chatId) }
    }
    var unreadByChat by mutableStateOf<Map<String, Long>>(emptyMap())
        private set

    /**
     * In-flight mark-read suppress only. Summary refresh must not restore
     * badges while `markConversationRead` is still running. Viewing suppress
     * is applied ephemerally in [applyUnreadCounts] from the open chat id —
     * never stored here (storing it let prune keep failed marks forever).
     */
    private val unreadSuppressGroupIds = linkedSetOf<String>()

    /** Unread count per chat captured at open time — BEFORE opening zeroes the
     *  core unread counter — so the transcript can anchor at the first unread
     *  row with a divider (Signal-style) instead of force-pinning the tail.
     *  The entry lives while the chat is on the nav stack. */
    var openChatUnread by mutableStateOf<Map<String, Long>>(emptyMap())
        private set

    /** Frozen unread-anchor row ID per chat. Once the transcript resolves the
     *  divider row, revisits of the same open (back from a pushed profile
     *  screen) reuse it instead of recounting against a feed that has since
     *  grown — new arrivals were already marked read and must not drift it. */
    var openChatUnreadAnchor by mutableStateOf<Map<String, String>>(emptyMap())

    /** Search / deep-link jump target for the current open (#372). Wins over
     *  unread/live-edge in [TranscriptScrollPolicy.resolveOpenAction]. */
    var openChatJumpMessageId by mutableStateOf<Map<String, String>>(emptyMap())
        private set

    /**
     * Capture the chat's unread count before opening clears it.
     *
     * [unreadByChat] is keyed by Marmot group id hex, so the sources MUST be
     * resolved through [transcriptGroupIds] — a mesh route's chat id
     * ("mesh:<peerId>") is not a group id, and looking it up directly always
     * read 0, leaving radar/BLE-folded conversations with no divider while
     * plain Marmot chats got one. That resolver is also what the read-marking
     * paths use, so capture and clear always cover the same groups.
     */
    private fun captureOpenChatUnread(chatId: String, jumpMessageId: String? = null) {
        val unreadAtOpen = transcriptGroupIds(chatId).sumOf { unreadByChat[it] ?: 0L }
        openChatUnreadAnchor = openChatUnreadAnchor - chatId
        // Always publish a settled value (including 0). Missing key means
        // capture has not run — hosts must not coerce that to live-edge.
        openChatUnread = openChatUnread + (chatId to unreadAtOpen)
        openChatJumpMessageId = if (jumpMessageId != null) {
            openChatJumpMessageId + (chatId to jumpMessageId)
        } else {
            openChatJumpMessageId - chatId
        }
    }

    /** Give up on a pending unread divider for this open: the transcript is
     *  fully hydrated but no anchor row is placeable (e.g. every unread event
     *  is a filtered control line). Settles to 0 so open policy becomes
     *  live-edge and tail following resumes. */
    fun retireOpenChatUnread(chatId: String) {
        openChatUnread = openChatUnread + (chatId to 0L)
        openChatUnreadAnchor = openChatUnreadAnchor - chatId
        openChatJumpMessageId = openChatJumpMessageId - chatId
    }

    /** Drop a one-shot Jump target after the host applied (or soft-failed) it. */
    fun clearOpenChatJump(chatId: String) {
        openChatJumpMessageId = openChatJumpMessageId - chatId
    }

    /** Account wipe/erase: per-open transcript state must not outlive the
     *  chats it is keyed by. */
    private fun clearOpenChatTransientState() {
        openChatUnread = emptyMap()
        openChatUnreadAnchor = emptyMap()
        openChatJumpMessageId = emptyMap()
        hydratedTranscripts = emptySet()
        unreadSuppressGroupIds.clear()
    }

    /** Optimistically clear badges and ask core to zero unread for [groupIds]. */
    private fun markGroupsRead(groupIds: Collection<String>) {
        if (groupIds.isEmpty()) return
        val marked = groupIds.toSet()
        unreadSuppressGroupIds.addAll(marked)
        unreadByChat = unreadByChat - marked
        scope.launch {
            for (groupId in marked) {
                runCatching { SonarCore.markConversationRead(groupId) }
            }
            // End in-flight suppress for this batch, then reconcile from core.
            // Open-session suppress is re-applied inside applyUnreadCounts so a
            // failed mark (or a message that landed after mark) cannot hide a
            // real badge for the rest of the process.
            val summaries = runCatching { SonarCore.conversationSummaries() }
                .getOrNull()
            unreadSuppressGroupIds.removeAll(marked)
            // null = FFI failure — keep the current map (do not wipe every badge).
            // emptyList() is a real empty inbox and must clear badges.
            if (summaries != null) applyUnreadCounts(summaries)
        }
    }

    /**
     * Chats whose async local hydrate has published for the CURRENT open.
     *
     * Opening paints synchronously from partial local state (a mesh chat shows
     * only its BLE window; the White Noise leg merges a beat later), so until
     * this flips the visible feed can still gain rows — including OLDER ones,
     * which shift every index and move the tail. Position changes in that
     * window are hydration, not new messages: they must be applied instantly,
     * never animated, or the transcript visibly scrolls on every open.
     */
    var hydratedTranscripts by mutableStateOf<Set<String>>(emptySet())
        private set

    fun isTranscriptHydrated(chatId: String): Boolean = chatId in hydratedTranscripts

    private fun markTranscriptHydrated(chatId: String) {
        if (chatId in hydratedTranscripts) return
        hydratedTranscripts = hydratedTranscripts + chatId
    }

    private fun clearTranscriptHydrated(chatId: String) {
        if (chatId !in hydratedTranscripts) return
        hydratedTranscripts = hydratedTranscripts - chatId
    }

    /**
     * Cached White Noise rows to seed a mesh chat's synchronous first paint,
     * so it lands on the true tail instead of the BLE tail (see [openDm]).
     *
     * Synthetic chat-list placeholders are stripped: only the newest
     * [LOCAL_SUMMARY_CHAT_LIMIT] chats carry real rows here, and a placeholder's
     * id can never dedupe against the real row the async page brings, so
     * seeding one renders a permanent duplicate bubble. A chat without real
     * cached rows simply gets no seed and settles via the catch-up gate.
     */
    private fun meshWhiteNoiseSeed(chatId: String): List<SonarMsg> =
        transcriptGroupIds(chatId).flatMap { groupId ->
            chatSnapshotMessagesByChat[groupId].orEmpty()
                .withoutSyntheticSummaryRows()
                .map { it.copy(viaInternet = true) }
        }

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
    /** Relay attach is independent from local startup. Failure retries here
     * while BLE, wallet, and local database services remain usable. */
    private var relayConnectJob: Job? = null

    /** Relay-dependent one-shot startup has run — see [completeRelayStartup].
     *  Separate from [localStartupCompleted] because a superseded attach
     *  installs the node without attaching, and firing the publishes there would
     *  burn the only chance to run them. */
    private var relayStartupCompleted: Boolean = false

    /** Local one-shot startup has run — see [completeLocalStartup]. Runs whatever
     *  the attach produced, since the node is installed either way. */
    private var localStartupCompleted: Boolean = false
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
    private val meshPersistenceMutex = Mutex()
    /** Match Apple's sendChain: preserve composer order across text, sticker,
     * control, receipt, and queued Marmot sends without serializing downloads. */
    private val marmotSendMutex = Mutex()
    private var marmotAccountGeneration = 0L
    private var marmotAccountMutationSuspended = false
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
    /** Pages fetched by the immediate conversationChanged path, handed to the
     * next housekeeping pass for notification selection without a second FFI read. */
    private val stagedChangedPages = HashMap<String, List<SonarMsg>>()
    /** Newer invalidations whose fast-path page read failed. These force a
     * fresh scan so an older staged page/watermark cannot mask the failure. */
    private val failedChangedPageReads = HashSet<String>()

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
            CallRecord(id = c.callId, video = c.video, mine = false, durSecs = 0, tsSecs = SonarClock.nowSecs())
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
            CallRecord(id = c.callId, video = c.video, mine = !c.incoming, durSecs = c.connectedSecs, tsSecs = SonarClock.nowSecs())
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
            CallRecord(id = c.callId, video = c.video, mine = !c.incoming, durSecs = ev.durationSecs.toInt(), tsSecs = SonarClock.nowSecs())
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
                        .add(CallRecord(id = ctrl.callId, video = ctrl.video, mine = false, durSecs = 0, tsSecs = SonarClock.nowSecs()))
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
                    sound = if (isMeshChat(chatId) && !m.viaInternet) {
                        SonarNotificationSound.Ble
                    } else {
                        SonarNotificationSound.Default
                    },
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
    /** O(1) lookup for active mesh echo message IDs — avoids O(chats×msgs)
     *  scan in [sendMesh]'s dedup check on the outbox-flush path. */
    private val meshEchoIds = mutableSetOf<String>()
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
    private val meshPeerRefreshQueue = ConflatedRefreshQueue(scope, ::refreshMeshRadioState)
    /** Bumped at the start of every mesh snapshot refresh; older concurrent
     *  readers discard their result so a stale Default-dispatcher decode cannot
     *  overwrite a newer publish (queue + housekeeping + settle overlap). */
    private var meshRadioRefreshEpoch = 0
    private val meshRadioRefreshLock = Mutex()

    /** The Sonar Discovery profile for a mesh peer (its BLE id), if any. */
    fun sonarProfile(peerId: String): SonarAnnounce? = sonarPeerProfiles[peerId]

    private data class MeshRadioSnapshot(
        val peers: List<MeshPeer>,
        val profiles: Map<String, SonarAnnounce>,
    )

    /** Read and decode the native radio snapshot away from the UI thread. */
    private suspend fun refreshMeshRadioState() {
        if (!onboarded) return
        val dropped = meshPeerRefreshQueue.takeDroppedRequests()
        val started = if (sonarBenchMarkersEnabled) TimeSource.Monotonic.markNow() else null
        if (sonarBenchMarkersEnabled) {
            sonarLog("SonarCore", "SONAR_BENCH mesh_refresh_begin dropped=$dropped")
        }
        val epoch = meshRadioRefreshLock.withLock { ++meshRadioRefreshEpoch }
        val snapshot = withContext(Dispatchers.Default) {
            MeshRadioSnapshot(
                peers = MeshRadio.peers(),
                profiles = MeshRadio.sonarPeers()
                    .mapNotNull { (id, raw) -> SonarAnnounce.decode(raw)?.let { id to it } }
                    .toMap(),
            )
        }
        val offMainMs = started?.elapsedNow()?.inWholeMicroseconds?.div(1000.0)
        val published = meshRadioRefreshLock.withLock {
            if (!onboarded || epoch != meshRadioRefreshEpoch) return@withLock null
            val beforePeers = meshPeers
            val beforeProfiles = sonarPeerProfiles
            applySonarDiscoveryProfiles(snapshot.profiles)
            updateMeshPeersFromRadio(rawPeers = snapshot.peers)
            meshPeers != beforePeers || sonarPeerProfiles != beforeProfiles
        } ?: return
        if (sonarBenchMarkersEnabled && started != null && offMainMs != null) {
            val totalMs = started.elapsedNow().inWholeMicroseconds / 1000.0
            sonarLog(
                "SonarCore",
                "SONAR_BENCH mesh_refresh_end peers=${snapshot.peers.size} " +
                    "profiles=${snapshot.profiles.size} off_main_ms=$offMainMs " +
                    "total_ms=$totalMs published=${if (published) 1 else 0} dropped=$dropped",
            )
        }
        // Fold mesh + White Noise legs as soon as a 0x53 profile/link lands —
        // do not wait for the next housekeeping heartbeat (Radar may be open).
        if (published) recomputeConversations()
    }

    private fun applySonarDiscoveryProfiles(profiles: Map<String, SonarAnnounce>) {
        if (sonarPeerProfiles == profiles) return
        sonarPeerProfiles = profiles
        profiles.forEach { (peerId, ann) -> rememberLink(peerId, ann) }
        // 0x53 profiles / links feed the capability-settle hold in [visibleChats].
        bumpHoldInputs()
    }

    private fun updateMeshPeersFromRadio(
        rawPeers: List<MeshPeer> = MeshRadio.peers(),
        nowMs: Long = SonarClock.nowMillis(),
    ) {
        val previousPeerIds = rawMeshPeerIds
        val previousVisibleIds = meshPeers.map { it.id }.toSet()
        rawMeshPeerIds = rawPeers.map { meshPeerId(it.id) }.toSet()
        meshPeerFirstSeenMs.keys.retainAll(rawMeshPeerIds + meshChats.keys + linkByFp.keys)
        val visiblePeers = visibleRadarMeshPeers(rawPeers, ::isMeshContactBlocked)
        visiblePeers.forEach { peer ->
            val peerId = meshPeerId(peer.id)
            if (peer.name.isNotBlank()) rememberMeshName(peerId, peer.name)
            meshPeerFirstSeenMs.putIfAbsent(peerId, nowMs)
        }
        if (meshPeers != visiblePeers) meshPeers = visiblePeers
        if (sonarBenchMarkersEnabled) {
            for (peer in visiblePeers) {
                if (peer.id in previousVisibleIds) continue
                val nick = benchNickToken(peer.name)
                val fp = meshPeerId(peer.id).take(8)
                val sonar = if (peer.sonar) 1 else 0
                sonarLog(
                    "SonarCore",
                    "SONAR_BENCH radar_peer_paint nick=$nick fp=$fp sonar=$sonar",
                )
            }
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
            if (!onboarded) return@launch
            // Route through the conflated queue so settle does not race a
            // concurrent push/housekeeping snapshot publish.
            meshPeerRefreshQueue.request()
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
        meshPeerAliases(peerId).any(socialState::isFavoritePeer)

    fun isMutualFavorite(peerId: String): Boolean =
        meshAliasGroupIsMutualFavorite(peerId)

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
        setFavoritePeer(key, name, !isFavorite(key))
    }

    fun setFavoritePeer(peerId: String, name: String = "", favorite: Boolean) {
        val key = normalizeSocialPeerId(peerId)
        if (favorite && isMeshContactBlocked(key)) {
            toast = "Unblock ${name.ifBlank { "this contact" }} before favoriting."
            return
        }
        socialState = meshPeerAliases(key).fold(socialState) { state, alias ->
            state.withFavoritePeer(alias, favorite)
        }
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
        MeshRadio.sendMeshDm(liveMeshRoutePeerId(peerId) ?: peerId, randomMeshId(), payload)
        val raw = npubRawFor(peerId) ?: return
        scope.launch {
            runCatching {
                runMarmotAccountOperation {
                    SonarCore.sendDirectDm(
                        recipientHex = raw.toHexLower(),
                        senderPeerIdHex = MeshRadio.localPeerIdHex(),
                        recipientPeerIdHex = "",
                        messageId = randomMeshId(),
                        text = payload,
                    )
                }
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
        // Local cursor reads race navigation. A late page from chat A must not
        // overwrite chat B's render state after the user switches screens.
        if ((screen as? Screen.Chat)?.id != chatId || activeTranscriptChatId != chatId) return
        publishOpenTranscript(chatId, visibleMessagesForChat(chatId, source), processCalls)
    }

    /**
     * Publish the open transcript only when paint-relevant rows change.
     * Identical hydration pages (snapshot → DB → fresh) must not rewrite
     * [messages] — that forces a LazyColumn rebuild Signal-Android never shows.
     */
    private fun publishOpenTranscript(
        chatId: String,
        visible: List<SonarMsg>,
        processCalls: Boolean = false,
    ) {
        if ((screen as? Screen.Chat)?.id != chatId || activeTranscriptChatId != chatId) return
        if (!sameTranscriptPaint(messages, visible)) {
            messages = visible
        }
        retainOpenTranscript(chatId, visible)
        processPayLines(chatId, visible)
        if (processCalls) processCallLines(chatId, visible)
    }

    private fun retainOpenTranscript(chatId: String, rows: List<SonarMsg>) {
        if (rows.isEmpty()) {
            retainedTranscriptByChat.remove(chatId)
        } else {
            retainedTranscriptByChat[chatId] = rows
        }
    }

    /** Drop leave/reopen paint cache when a conversation is deleted or erased. */
    private fun discardRetainedTranscript(chatId: String) {
        retainedTranscriptByChat.remove(chatId)
        transcriptWindows.remove(chatId)
    }

    /** Prefer last leave paint, else snapshot — never open on empty when we can avoid it. */
    private fun firstOpenTranscriptPaint(chatId: String, snapshotPaint: List<SonarMsg>): List<SonarMsg> {
        val retained = retainedTranscriptByChat[chatId]
        return when {
            retained != null && retained.isNotEmpty() -> retained
            else -> snapshotPaint
        }
    }

    /**
     * Signal-Android list bind: warm disk thumbs into [MediaImageMemoryCache]
     * so the first composed frame paints pixels instead of blank surfaces.
     * Only reads already-sized thumb files — never full attachment bytes.
     */
    private fun warmOpenTranscriptThumbs(rows: List<SonarMsg>) {
        val urls = rows.asReversed()
            .asSequence()
            .flatMap { it.media.asSequence() }
            .filter { it.isImage && !it.isGif }
            .map { it.url }
            .distinct()
            .take(12)
            .filter { MediaImageMemoryCache.get(it) == null }
            .toList()
        if (urls.isEmpty()) return
        scope.launch(Dispatchers.Default) {
            for (url in urls) {
                val thumb = MediaThumbnailDiskCache.load(url) ?: continue
                withContext(Dispatchers.Main) {
                    if (MediaImageMemoryCache.get(url) == null) {
                        MediaImageMemoryCache.put(
                            url,
                            DecodedTranscriptMedia(bitmap = thumb.bitmap, gifBytes = null),
                        )
                    }
                }
            }
        }
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
        if (isNewLink) updateBleDiscoveryPolicy()
        ensureSonarDescriptorHex(npubHex)
        // A new or updated link means we can now reach this peer via White Noise
        // — flush any queued messages that were waiting for this route.
        if (isNewLink || outbox.contains(peerId)) {
            flushOutbox(peerId)
        }
        if (isNewLink || mediaOutbox.contains(peerId)) {
            flushMediaOutbox(peerId)
        }
    }
    /** GPS-derived location channels (Mesh + Ottaviano…Italy), like iOS. */
    var locationChannels by mutableStateOf<List<GeoChannel>>(emptyList())
        private set
    /** Live "here now" counts per geohash (kind-20001 presence), like iOS. */
    var presenceByGeohash by mutableStateOf<Map<String, Int>>(emptyMap())
        private set
    var toast by mutableStateOf<String?>(null)

    /**
     * In-memory composer drafts keyed by chat id (DM, channel, geo-DM).
     * Survives leaving a chat and returning within the same process; cleared on send.
     */
    private val composerDrafts = mutableStateMapOf<String, String>()

    fun composerDraft(chatId: String): String = composerDrafts[chatId].orEmpty()

    fun setComposerDraft(chatId: String, text: String) {
        val current = composerDrafts.toMap()
        val next = updatedComposerDrafts(current, chatId, text)
        if (next == current) return
        if (!next.containsKey(chatId)) {
            composerDrafts.remove(chatId)
        } else {
            composerDrafts[chatId] = next.getValue(chatId)
        }
    }

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
            // BuildConfig.BREEZ_API_KEY was empty in this APK — not an nsec/restore
            // failure. Settings shows "Unavailable"; Lightning stays off.
            sonarLog("SonarWallet", "wallet unavailable: Breez API key missing from this build")
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
            if (offer != null) refreshHandleOfferIfNeeded(offer)
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
            // NOTE: a pending chat (XChat-Style Chat Startup Rule) is deliberately
            // NOT payable even though we know the peer's npub: the ⚡PAY receipt
            // lines need a real Marmot group, so paying here would settle on
            // Lightning with no in-chat receipt. Tracked follow-up: queue the
            // receipt through pendingDirectMarmotSends, then allow it.
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

    /**
     * Fire-and-forget wrappers for the send-payment picker, which pops itself
     * as soon as the amount is confirmed. The screen's `rememberCoroutineScope`
     * dies with the screen, so launching there and popping in the same frame
     * would cancel the payment mid-flight (the descriptor fetch inside
     * [sendPay] suspends). These run on the app scope instead, and surface the
     * outcome through [toast] / the Wallet activity screen.
     */
    fun sendPayDetached(chatId: String, sats: Long) {
        scope.launch { sendPay(chatId, sats)?.let { toast = it } }
    }

    fun payDestinationDetached(destination: String, sats: Long, displayName: String) {
        scope.launch { payDestination(destination, sats, displayName)?.let { toast = it } }
    }

    /**
     * Contacts the send-payment picker can pay right now: every direct
     * conversation (mesh DM or 1:1 Marmot chat) whose peer publishes a BOLT12
     * offer. Mirrors the design's "People you can pay" list, which is
     * explicitly filtered to people who publish a payment address.
     *
     * Deliberately read-only and cache-only — it never fetches a descriptor, so
     * opening the picker cannot block on the relay (Signal-Comparable
     * Performance Rule). A contact whose descriptor has not arrived yet simply
     * is not listed; typing their address in the field still works.
     */
    fun payableContacts(): List<PayableContact> {
        val seen = HashSet<String>()
        val out = ArrayList<PayableContact>()
        fun add(chatId: String) {
            if (!seen.add(chatId)) return
            if (isContactBlocked(chatId)) return
            if (directPaymentOffer(chatId).isNullOrBlank()) return
            val nearby = isMeshChat(chatId) && hasLiveMeshRoute(meshPeerId(chatId))
            // Design pay.jsx: nearby peers read "Nearby · Bluetooth"; everyone
            // else shows their published payment address, falling back to
            // "over Lightning" when we do not hold one.
            val address = if (isMeshChat(chatId)) {
                preferredMeshAliases(meshPeerId(chatId)).firstNotNullOfOrNull { alias ->
                    sonarProfile(alias)?.bip353?.takeIf { it.isNotBlank() }
                }
            } else null
            out += PayableContact(
                chatId = chatId,
                name = callPeerName(chatId),
                subtitle = if (nearby) "Nearby · Bluetooth" else (address ?: "over Lightning"),
                nearby = nearby,
            )
        }
        meshPeers.forEach { add("mesh:" + meshPeerId(it.id)) }
        meshDmRows.forEach { add("mesh:" + it.peerId) }
        chats.filter { isDirectMarmotChat(it) }.forEach { add(it.id) }
        return out.sortedWith(compareByDescending<PayableContact> { it.nearby }.thenBy { it.name.lowercase() })
    }

    /**
     * Pay an arbitrary Lightning destination typed into the send-payment picker
     * — a BOLT12 offer, a BOLT11 invoice, or a `name@domain` Lightning address.
     * Breez resolves the destination, so this only records the wallet-side
     * activity: there is no conversation to post a ⚡PAY receipt into.
     *
     * Returns a message to surface to the user, or null when the send was
     * accepted (the outcome then lands on the Wallet activity screen).
     */
    suspend fun payDestination(destination: String, sats: Long, displayName: String): String? {
        val dest = destination.trim()
        if (sats <= 0 || dest.isEmpty()) return null
        if (!walletAvailable || walletState !is WalletState.Ready) {
            return "Set up the wallet first."
        }
        val payId = randomPayId()
        PaymentActivityStore.recordPending(
            SonarPaymentActivity(
                id = payId,
                kind = SonarPaymentActivity.Kind.SonarDirect,
                // No conversation backs this one — "wallet" is the documented
                // peerKey for payments that do not belong to a chat.
                peerKey = "wallet",
                peerName = displayName.ifBlank { shortNpubLabel(dest) },
                direction = SonarPaymentActivity.Direction.Outgoing,
                sats = sats,
                via = "internet",
                createdAtSecs = SonarClock.nowSecs(),
                destinationHash = paymentDestinationHash(dest),
                status = SonarPaymentActivity.Status.Pending,
            )
        )
        scope.launch {
            var failureMessage: String? = null
            val result = runCatching { WalletBridge.send(dest, sats, "Sonar payment $payId") }
                .getOrElse {
                    failureMessage = "Payment failed: ${it.message}"
                    SendResult(false)
                }
            walletState = WalletBridge.state()
            if (result.ok) {
                PaymentActivityStore.markPaid(
                    payId, result.paymentId, result.feesSats,
                    result.settledAtSecs ?: SonarClock.nowSecs(),
                )
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
            sendMarmotTextOrdered(groupId, line)
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
        meshPeerRefreshQueue.request()
    }

    /** Radio callbacks may arrive on BLE/native worker threads. Conflate bursts,
     *  read native state off-main, then publish Compose state on the app scope. */
    internal fun onMeshPeersChanged() {
        if (!onboarded) return
        meshPeerRefreshQueue.request()
    }

    // ── Unify nearby payments (separate BLE service; payments-only) ──
    /** Cached amountless BOLT12 offer we advertise as the Unify receiver. */
    private var unifyOffer: String? = null

    /** Keep the payment-only scan and bounded visible-Radar peer refresh aligned
     *  with navigation, foreground, onboarding, and discovery restrictions. */
    private fun updateNearbyScanning() {
        val shouldScan = shouldScanForNearbyPayments(
            isNearbyVisible = isNearbyVisible,
            isForeground = foreground,
            isOnboarded = onboarded,
            isDiscoveryRestricted = bleDiscoveryRestricted,
        )
        if (shouldScan) {
            UnifyRadio.startScanning()
        } else {
            UnifyRadio.stopScanning()
            unifyPeers = emptyList()
        }
        val shouldRefresh = shouldRefreshNearbyPeers(
            isNearbyVisible = isNearbyVisible,
            isForeground = foreground,
            isOnboarded = onboarded,
        )
        if (!shouldRefresh) {
            nearbyPeerRefreshJob?.cancel()
            nearbyPeerRefreshJob = null
        } else if (nearbyPeerRefreshJob?.isActive != true) {
            nearbyPeerRefreshJob = scope.launchNearbyPeerRefresh(
                readMeshPeers = { withContext(Dispatchers.Default) { MeshRadio.peers() } },
                publishMeshPeers = { updateMeshPeersFromRadio(rawPeers = it) },
                readUnifyPeers = {
                    if (bleDiscoveryRestricted) {
                        emptyList()
                    } else {
                        withContext(Dispatchers.Default) { UnifyRadio.peers() }
                    }
                },
                publishUnifyPeers = { unifyPeers = it },
            )
        }
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
        // Optimistic local echo in the same frame as the tap (like the mesh
        // path above and the Apple composers' rebuildNow); refreshChannel
        // replaces it with the canonical row from core/storage.
        val echo = SonarChannelMsg(randomMeshId(), nick.ifBlank { "you" }, "", t, mine = true, MeshRadio.nowSecs())
        channelMsgs = visibleChannelMessages(channelMsgs + echo)
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
        // Optimistic local echo; refreshGeoDm replaces it with the
        // canonical row from core/storage.
        messages = visibleGeoDmMessages(peerHex, messages + SonarMsg(randomMeshId(), npub, t, mine = true, SonarClock.nowSecs()))
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

    // ── Unified handle claim (NIP-05 chat + BIP-353 payments) ──
    var handleClaimState by mutableStateOf<HandleClaimState>(HandleClaimState.Idle)
        private set

    /** The address actually claimed at the Sonar registrar (core sidecar is
     *  the durable record). Distinct from [bip353], which may also hold an
     *  external payment address from another wallet: only a core-claimed
     *  address gets the verified-claim checkmark and kind-0 `nip05`. */
    var coreClaimedHandle by mutableStateOf<String?>(null)
        private set

    /** Core-owned default handle domain, fetched once (pure FFI constant). */
    val handleDomain: String by lazy { SonarCore.defaultHandleDomain() }

    /** Claim (or refresh) `handle` at the Sonar registrar. Chat-only claims are
     *  supported: when the wallet isn't ready the BIP-353 payment record is
     *  skipped and a later re-claim adds the offer. On success the address is
     *  persisted (core sidecar + bip353 blob), announced over BLE, and the
     *  kind-0 profile republishes so peers see the handle immediately. */
    fun claimHandle(handle: String) {
        val name = handle.trim().lowercase()
        if (name.isEmpty() || handleClaimState is HandleClaimState.Claiming) return
        handleClaimState = HandleClaimState.Claiming
        scope.launch {
            val offer = if (walletState is WalletState.Ready) {
                runCatching { WalletBridge.createOffer() }.getOrNull()
            } else null
            runCatching { SonarCore.claimHandle(name, offer) }
                .onSuccess { address ->
                    coreClaimedHandle = address
                    if (offer != null) lastClaimedOffer = offer
                    updateBip353(address)
                    refreshMeshIdentity()
                    runCatching { SonarCore.publishProfile(nick) }
                    handleClaimState = HandleClaimState.Claimed(address)
                }
                .onFailure { e ->
                    val msg = e.message.orEmpty()
                    handleClaimState = HandleClaimState.Failed(
                        when {
                            msg.contains("handle taken:") -> "That name is already taken"
                            msg.contains("invalid handle") -> "Names can use a-z, 0-9, dots, dashes"
                            else -> "Couldn't claim the name — check your connection and try again"
                        }
                    )
                }
        }
    }

    /** Reset the claim state machine (e.g. when the user edits the input). */
    fun resetHandleClaimState() {
        handleClaimState = HandleClaimState.Idle
    }

    /** The BOLT12 offer last registered with the handle this session. */
    private var lastClaimedOffer: String? = null

    /** Upgrade a chat-only claim once a wallet offer exists: a claim made
     *  before the wallet was ready has no BIP-353 DNS record, so the handle
     *  looks payable but isn't until re-registered. Re-claims from the same
     *  key are idempotent; once per offer per session keeps this quiet. */
    private suspend fun refreshHandleOfferIfNeeded(offer: String) {
        val claimed = coreClaimedHandle ?: return
        if (offer == lastClaimedOffer) return
        runCatching { SonarCore.claimHandle(claimed.substringBefore('@'), offer) }
            .onSuccess { lastClaimedOffer = offer }
    }

    /** Resolve a typed handle (`vincenzo` / `alice@example.com`) to an npub for
     *  starting a chat. null when unregistered or offline. Network-bounded;
     *  call only from a user-initiated action, never per keystroke. */
    suspend fun resolveHandleForChat(input: String): String? =
        SonarCore.resolveHandle(input)?.npub

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
                retryPushRegistrationAfterAccountReady()
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
            var marmotDeliveryGeneration: Long? = null
            val result = runCatching {
                val key = nsec.trim()
                val expectedNpub = try {
                    SonarCore.validateIdentity(key)
                } catch (error: Throwable) {
                    throw SonarAccountRestoreException(
                        "That key couldn't be imported. Check you pasted the full nsec1... key.",
                        error,
                    )
                }

                // Unregister the old offer while its node is still available, but
                // preserve the device token for immediate registration by the new
                // account. Wallet teardown/storage removal are strict: no identity
                // mutation happens unless the previous database is definitely gone.
                Notifier.prepareForAccountReplacement()
                try {
                    WalletBridge.shutdown()
                    WalletBridge.wipeLocalStorage()
                } catch (error: Throwable) {
                    throw SonarAccountRestoreException(
                        "Wallet storage couldn't be cleared. Restart Sonar and try again.",
                        error,
                    )
                }

                // Clear every account-bound host cache before committing the new
                // nsec. A crash after import must never paint the previous account's
                // chats, contacts, payment rows, offers, or local-first snapshot.
                endTranscriptSession()
                UnifyRadio.stopScanning()
                UnifyRadio.stopAdvertising()
                unifyOffer = null; unifyPeers = emptyList()
                // Match backupAccountNow: cancel AND join so wake/poll cannot race
                // wipe + Blossom stage/commit under a live node.
                val toJoin = listOfNotNull(pollJob, relayConnectJob, housekeepingJob, marmotWakeJob)
                pollJob = null
                relayConnectJob = null
                housekeepingJob = null
                marmotWakeJob = null
                resetStartupFlags()
                refreshRelayOnline()
                toJoin.forEach { it.cancel() }
                toJoin.forEach { job ->
                    runCatching { withTimeoutOrNull(3_000) { job.join() } }
                }
                resetCallState()
                marmotDeliveryGeneration = cancelPendingMarmotPeerDeliveryJobs { MeshRadio.stop() }
                cancelPendingMarmotSetups()
                cancelPendingMarmotGroupSetups()

                MessageStore.wipe()
                MeshRadio.discardPendingDeliverySignals()
                meshChats.clear(); meshEchoIds.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); pendingDirectMarmotSends.clear(); pendingMarmotGroupSends.clear(); outbox.clear()
                persistMeshNames()
                pendingMarmotChatNpubs = emptyMap()
                pendingMarmotGroups = emptyMap()
                pendingInviteTokens.clear()
                linkByFp.clear(); linkCapsByFp.clear(); groupFoldMap.clear()
                persistLinks(); persistLinkCaps(); persistGroupFolds()
                updateBleDiscoveryPolicy()
                foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
                sonarPeerProfiles = emptyMap()
                // Generation first — see wipe(): the write below suspends.
                sonarDescriptorsByNpubHex = emptyMap(); descriptorCacheGeneration++; persistSonarDescriptorCacheNow()
                sonarDescriptorFetches.clear(); sonarDescriptorFetchedAt.clear(); sonarDescriptorMissedAt.clear()
                publishedSonarDescriptor = false
                publishedSonarDescriptorBolt12Offer = null
                publishingSonarDescriptor = false
                needsSonarDescriptorPublish = false
                rawMeshPeerIds = emptySet(); meshPeerFirstSeenMs.clear(); pendingCapabilityRefreshPeers.clear()
                profilesByNpub = emptyMap(); profileFetches.clear(); profileFetchedAt.clear(); profileMissedAt.clear(); persistProfileCacheNow()
                socialState = SonarSocialState(); persistSocialState()
                bip353 = ""; SonarCore.saveBlob("bip353", "")
                coreClaimedHandle = null
                handleClaimState = HandleClaimState.Idle
                // Drop the previous account's nickname. The restored identity's
                // kind-0 on relays is authoritative; publishing the old nick
                // would clobber it. hydrateOwnProfileFromRelays() fills this
                // after relay connect.
                SonarCore.setNickname("")
                nick = ""
                meshBroadcast = emptyList(); meshDmRows = emptyList()
                verifiedChatIds.forEach { SonarCore.saveBlob("verified.$it", "") }
                verifiedChatIds.clear(); verifiedVersion++
                chats = emptyList(); chatSnapshotMessagesByChat = emptyMap(); pendingMarmotChatNpubs = emptyMap(); pendingMarmotGroups = emptyMap(); groupInvites = emptyList(); messages = emptyList(); retainedTranscriptByChat.clear(); channelMsgs = emptyList()
                clearChatSnapshot()
                lastWnGroups = -1; lastWnMsgs = -1
                payLedger = SonarPayLedger(); persistPay(); payVersion++
                PaymentActivityStore.wipe()
                cancelAllMediaDownloads(); MediaCache.wipe(); clearOpenChatTransientState()
                mediaCache.clear(); clearStickerCaches()
                callLogs.clear(); callVersion++
                notificationSeenMessageIds.clear(); notificationLatestSecs.clear()
                scanWatermark.clear()
                SonarCore.saveBlob(NPUB_BLOB_KEY, "")
                npub = ""
                started = false
                connecting = false
                localCoreReady = false
                homeMessagesHydrated = false

                val restoredNpub = try {
                    SonarCore.importIdentity(key)
                } catch (error: Throwable) {
                    // The core restores the prior durable identity when it can. Its
                    // chats were intentionally erased above, so restart that clean
                    // account and reconstruct its deterministic wallet.
                    boot()
                    throw SonarAccountRestoreException(
                        "Account storage couldn't be replaced. Restart Sonar and try again.",
                        error,
                    )
                }
                if (restoredNpub != expectedNpub) {
                    throw SonarAccountRestoreException(
                        "Account storage couldn't be replaced. Restart Sonar and try again.",
                    )
                }

                npub = restoredNpub
                // Keep the persisted npub consistent with the restored identity
                // now, so a crash before start()'s re-save can't restore the OLD
                // npub as "me" on the next launch's local-first paint.
                SonarCore.saveBlob(NPUB_BLOB_KEY, restoredNpub)
                SonarCore.setOnboardingComplete(true)
                retryPushRegistrationAfterAccountReady()
                val needsExplicitBoot = onboarded
                onboarded = true
                nick = SonarCore.nickname()
                stack = listOf(Screen.Home)
                walletState = WalletState.NotConfigured
                refreshMeshIdentity()
                // From Settings, onboarded was already true so LaunchedEffect(onboarded)
                // will not re-fire — boot explicitly. From onboarding, false→true
                // triggers App.kt's LaunchedEffect; avoid a concurrent double boot.
                if (needsExplicitBoot) boot()
                toast = when (SonarCore.lastImportBackupOutcome()) {
                    AccountBackupRestoreOutcome.Restored ->
                        getString(Res.string.account_restored_chats_recovered_from)
                    AccountBackupRestoreOutcome.Missing ->
                        getString(Res.string.account_restored_chats_start_empty)
                    AccountBackupRestoreOutcome.Failed ->
                        getString(Res.string.account_restored_chat_backup_restore)
                }
            }
            marmotDeliveryGeneration?.let(::resumePendingMarmotPeerDelivery)
            onResult(result.map { Unit })
        }
    }

    fun backupAccountNow() {
        scope.launch {
            val result = runCatching {
                // Match wipe: cancel AND join so in-flight node FFI cannot race
                // closeNode + wal_checkpoint(TRUNCATE) during backup.
                val toJoin = listOfNotNull(pollJob, relayConnectJob, housekeepingJob, marmotWakeJob)
                pollJob = null
                relayConnectJob = null
                housekeepingJob = null
                marmotWakeJob = null
                resetStartupFlags()
                refreshRelayOnline()
                toJoin.forEach { it.cancel() }
                toJoin.forEach { job ->
                    runCatching { withTimeoutOrNull(3_000) { job.join() } }
                }
                started = false
                connecting = false
                localCoreReady = false
                SonarCore.backupAccountToBlossom()
            }
            // Always reboot — a failed backup must not leave Marmot unreconnected.
            runCatching { boot() }
            toast = if (result.isSuccess) {
                getString(Res.string.chat_backup_uploaded)
            } else {
                getString(Res.string.backup_failed_try_again_when_online)
            }
        }
    }

    fun updateNickname(value: String) {
        SonarCore.setNickname(value)
        nick = value
        refreshMeshIdentity()
        // Re-publish our kind-0 profile so peers see the new name — but never
        // when a local handle pref exists without the core sidecar. That emit
        // would omit `nip05` and replace the durable kind-0 after restore.
        if (SonarCore.isRelayConnected()) scope.launch {
            val claimed = coreClaimedHandle ?: SonarCore.claimedHandle()
            if (!canPublishOwnProfile(bip353, claimed)) return@launch
            runCatching { SonarCore.publishProfile(value) }
        }
    }

    // ── Local notifications (fire on new incoming message while backgrounded) ──
    private var foreground = true
    /** The payment-only nearby scan is scoped to the visible Radar screen. */
    private var isNearbyVisible = false
    /** Copies scan callbacks' radio cache into Compose state only while useful. */
    private var nearbyPeerRefreshJob: Job? = null
    /** Bounded stable-ID history for background notification dedupe. */
    private val notificationSeenMessageIds = HashMap<String, LinkedHashSet<String>>()
    /** Latest timestamp observed per chat; older backfills must not notify. */
    private val notificationLatestSecs = HashMap<String, Long>()

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

    val bleDiscoverySettingsDescription: String
        get() = when {
            batterySaving && discoverNewPeople -> "On, but paused by battery saving; existing chats still reconnect"
            batterySaving -> "Off; existing chats can still reconnect"
            discoverNewPeople -> "Show nearby people you haven't chatted with yet"
            else -> "Only people from existing chats can appear"
        }

    val radarDiscoveryStatusLine: String
        get() = when {
            batterySaving -> "${meshPeers.size} in range · battery saving"
            bleDiscoveryRestricted -> "${meshPeers.size} in range · new people off"
            else -> "${meshPeers.size} in range · scanning"
        }

    fun nearbyAppeared() {
        isNearbyVisible = true
        updateNearbyScanning()
    }

    fun nearbyDisappeared() {
        isNearbyVisible = false
        updateNearbyScanning()
    }

    fun setBleDiscoverNewPeople(enabled: Boolean) {
        if (discoverNewPeople == enabled) return
        discoverNewPeople = enabled
        setPref(BLE_DISCOVER_NEW_PEOPLE_PREF, enabled)
        updateBleDiscoveryPolicy()
        updateNearbyScanning()
    }

    private fun refreshBatterySaving() {
        val enabled = BatterySaver.enabled()
        if (batterySaving == enabled) return
        batterySaving = enabled
        updateBleDiscoveryPolicy()
        updateNearbyScanning()
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
        updateNearbyScanning()
        if (cameToForeground) {
            if (bypassRelock) bypassRelock = false        // return from our own unlock prompt
            else if (AppLock.isEnabled()) locked = true   // genuine app-switch → re-lock
            if (started) {
                startRelayConnection()
                scope.launch {
                    // Local-first: never gate chat-list / channel paint on relay
                    // reconnect. The relay wait below is bounded and background.
                    repaintFromLocal()

                    activeCatchupSyncs++
                    try {
                        // Foreground resume is a real wake event: force the
                        // batched gap-recovery fetch. Single-flight-guarded so a
                        // notification tap's requestImmediateSync() coalesces
                        // with this instead of double-enqueuing syncForce on the
                        // serial engine queue. awaitRelay kicks the reconnect
                        // needed after a background invalidate and waits bounded,
                        // so an offline resume cannot hang here.
                        forcedCatchupSync(awaitRelay = true)
                        repaintFromLocal()
                        if (SonarCore.isRelayConnected()) {
                            refreshKnownContactDescriptors(clearMisses = false)
                        }
                    } finally {
                        activeCatchupSyncs--
                    }
                }
                // Run a full housekeeping pass now rather than waiting for the
                // next heartbeat (the old 4 s poll would have run within 4 s).
                requestHousekeeping()
            }
        }
        // Unify receiver is foreground-only (matches iOS) — react immediately.
        scope.launch { updateUnifyReceiver() }
    }

    /** Repaint every visible surface from local storage only — no relay work.
     *  Run once before the relay wait (first paint) and again after gap
     *  recovery lands (repaint), so both passes stay in sync when a new
     *  surface is added. */
    private suspend fun repaintFromLocal() {
        drainDirectDms()
        refreshChats()
        recomputeConversations()
        (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
        refreshPresenceCounts()
    }

    /**
     * The process left the foreground for real (Android `onStop`, iOS scene
     * background) — not a transient pause behind a picker or permission dialog.
     *
     * Mobile can tear down websockets while we stay process-alive, so drop the
     * host relay latch: the next push wake / foreground resume then reconnects
     * instead of syncForce-ing against a dead node. Desktop window focus loss
     * never reaches here ([RelayConnectionPolicy.shouldInvalidateOnBackground]
     * is false on JVM and the desktop root does not install the hook).
     */
    fun onProcessBackgrounded() {
        if (!RelayConnectionPolicy.shouldInvalidateOnBackground()) return
        SonarCore.invalidateRelayConnection()
        refreshRelayOnline()
    }

    fun requestImmediateSync() {
        if (!started) return
        startRelayConnection()
        scope.launch {
            activeCatchupSyncs++
            try {
                // Explicit immediate sync (chat open / manual refresh) is a wake-like
                // event: force the gap-recovery fetch, don't let it short-circuit.
                // Single-flight-guarded so it coalesces with a concurrent
                // foreground-cycle catch-up instead of double-enqueuing syncForce.
                forcedCatchupSync(awaitRelay = false)
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
            } finally {
                activeCatchupSyncs--
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

    // ── Per-chat mute (docs/SONAR-TRILL.md) ──
    // chatId → mute-until epoch seconds (MUTE_FOREVER_SECS = until turned back
    // on). Local to the install; rows and unread counts keep accruing — only
    // alerts (notification/sound/haptic/shake) are suppressed.
    var mutedUntilByChat by mutableStateOf(decodeMuteMap(SonarCore.loadBlob(MUTE_BLOB_KEY)))
        private set

    private fun persistMutes() {
        SonarCore.saveBlob(MUTE_BLOB_KEY, encodeMuteMap(mutedUntilByChat))
    }

    /** All ids a chat's alerts can arrive under (mirrors the folded-id set used
     *  by [clearNotificationsForChat]): the row id itself, duplicate direct
     *  groups, folded White Noise groups, and the mesh row of a folded group. */
    private fun muteIdsFor(chatId: String): Set<String> = buildSet {
        add(chatId)
        addAll(directMarmotChatIds(chatId))
        addAll(transcriptGroupIds(chatId))
        foldedGroupPeerIds[chatId]?.let { add(meshChatId(it)) }
        if (isMeshChat(chatId)) {
            meshPeerAliases(meshPeerId(chatId)).forEach { add(meshChatId(it)) }
        }
    }

    /** Pure read (safe on the render path): expired mutes read as unmuted and
     *  are pruned lazily by the mutating paths, never here. */
    fun isChatMuted(chatId: String): Boolean {
        val mutes = mutedUntilByChat
        if (mutes.isEmpty()) return false
        val now = SonarClock.nowSecs()
        if (isMutedAt(mutes[chatId], now)) return true
        return muteIdsFor(chatId).any { isMutedAt(mutes[it], now) }
    }

    /** Mute [chatId] for [durationSecs] (null = until turned back on). The
     *  whole folded-id set is stored so id-only readers — notably the
     *  killed-app push-wake drain, which cannot resolve folding — match the
     *  mute by direct lookup. */
    fun muteChat(chatId: String, durationSecs: Long?) {
        val now = SonarClock.nowSecs()
        val until = muteUntilFor(durationSecs, now)
        mutedUntilByChat = withExpiredMutesCleared(mutedUntilByChat, now) +
            muteIdsFor(chatId).associateWith { until }
        persistMutes()
    }

    fun unmuteChat(chatId: String) {
        val now = SonarClock.nowSecs()
        mutedUntilByChat = withExpiredMutesCleared(mutedUntilByChat, now) - muteIdsFor(chatId)
        persistMutes()
    }

    // ── Trill (nudge) — docs/SONAR-TRILL.md ──
    /** Bumped when a received (or sent) trill should shake the app content;
     *  observed by TrillShakeHost in App.kt. */
    var trillShakeTick by mutableStateOf(0L)
        private set

    // Sender cooldown (monotonic ms): the nudge action is disabled for 8 s per
    // chat after sending — MSN's own guard.
    private var trillCooldownUntilMs by mutableStateOf<Map<String, Long>>(emptyMap())

    // Receiver alert throttle: one buzz/notification per chat per 8 s window.
    private val trillAlertThrottle = TrillAlertThrottle()

    fun canSendTrill(chatId: String): Boolean =
        SonarClock.monotonicMillis() >= (trillCooldownUntilMs[chatId] ?: 0L)

    /** Send a nudge through the exact same path a text message takes (local
     *  echo, transport auto-pick, outbox). The sender's own send also triggers
     *  the local buzz effect (design parity). */
    fun sendTrill(chatId: String) {
        if (!canSendTrill(chatId)) return
        // Mirror send()'s blocked-contact guard before burning the cooldown or
        // buzzing locally — otherwise a blocked nudge locks the button for 8s
        // and shakes the sender while never leaving the device.
        if (isContactBlocked(chatId)) {
            toast = "Unblock to send a nudge"
            return
        }
        trillCooldownUntilMs = trillCooldownUntilMs +
            (chatId to SonarClock.monotonicMillis() + TRILL_SEND_COOLDOWN_MS)
        send(chatId, TrillLine(randomTrillId()).encoded())
        triggerTrillBuzz()
    }

    /** Shake + bell + haptic. Never called from composition — only from send
     *  actions and receive callbacks. The shake itself honors reduce-motion in
     *  TrillShakeHost; TrillEffects dispatches sound/haptic off-thread. */
    private fun triggerTrillBuzz() {
        // Never disturb an active call's audio session or UI (iOS parity).
        if (activeCall != null) return
        trillShakeTick++
        TrillEffects.buzz()
    }

    /** One incoming trill worth alerting for landed in [idKey]. Applies the
     *  silence ladder (docs/SONAR-TRILL.md): blocked was dropped at ingest,
     *  muted alerts nothing, throttled trills stay silent rows; then foreground
     *  buzzes and background posts the distinct trill notification. */
    private fun onTrillReceived(
        idKey: String,
        conversationTitle: String?,
        content: String,
        senderName: String?,
        groupName: String? = null,
    ) {
        if (isChatMuted(idKey)) return
        if (!trillAlertThrottle.tryAlert(idKey, SonarClock.monotonicMillis())) return
        if (foreground) {
            triggerTrillBuzz()
        } else {
            notifyIncoming(
                idKey = idKey,
                conversationTitle = conversationTitle,
                content = content,
                forcedKind = SonarNotificationKind.Trill,
                senderName = senderName,
                groupName = groupName,
                sound = SonarNotificationSound.Trill,
            )
        }
    }

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
        sound: SonarNotificationSound = SonarNotificationSound.Default,
        messageId: String? = null,
    ) {
        if (foreground) return
        // Muted chats never notify (any kind); rows and unread still accrue.
        if (isChatMuted(idKey)) return
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
        Notifier.notify(
            id = notification.id,
            title = notification.title,
            body = notification.body,
            // A trill always rings with its distinct bell, whichever path
            // classified it.
            sound = if (kind == SonarNotificationKind.Trill) SonarNotificationSound.Trill else sound,
            conversationId = idKey,
            messageId = messageId,
        )
    }

    /** Dismiss OS notifications for this chat and every folded/duplicate id. */
    private fun clearNotificationsForChat(chatId: String) {
        val related = buildList {
            addAll(directMarmotChatIds(chatId))
            addAll(transcriptGroupIds(chatId))
            foldedGroupPeerIds[chatId]?.let { add(meshChatId(it)) }
            for ((groupId, peerId) in foldedGroupPeerIds) {
                if (meshChatId(peerId) == chatId) add(groupId)
            }
        }
        Notifier.clearConversations(
            SonarNotificationHandoff.conversationIdsToClear(chatId, related)
        )
    }

    /**
     * Open the conversation named by a notification tap. Resolves folded
     * White Noise groups onto their mesh home-row id so the user lands on the
     * same transcript the notification was posted for.
     *
     * Unknown ids never invent a blank chat screen: refresh once and retry,
     * otherwise stay on Home and clear the shade entry.
     */
    fun openConversationFromNotification(
        conversationId: String,
        jumpMessageId: String? = null,
    ) {
        val id = conversationId.trim()
        if (id.isEmpty()) return
        requestImmediateSync()
        val jump = SonarNotificationHandoff.normalizeJumpMessageId(jumpMessageId)
        if (openResolvedNotificationTarget(id, jump)) return
        scope.launch {
            runCatching { refreshChats() }
            if (openResolvedNotificationTarget(id, jump)) return@launch
            clearNotificationsForChat(id)
            toast = "That chat isn’t ready yet — try again from Messages."
        }
    }

    private fun openResolvedNotificationTarget(
        conversationId: String,
        jumpMessageId: String? = null,
    ): Boolean {
        val target = SonarNotificationHandoff.resolveOpenTarget(
            conversationId = conversationId,
            knownChatIds = chats.mapTo(hashSetOf()) { it.id },
            foldedGroupPeerIds = foldedGroupPeerIds,
            foldedGroupIds = foldedGroupIds,
        ) ?: return false
        when (target) {
            is SonarNotificationOpenTarget.MeshPeer ->
                openDm(target.peerId, meshPeerName(target.peerId), jumpMessageId = jumpMessageId)
            is SonarNotificationOpenTarget.Chat -> {
                val chat = chats.firstOrNull { it.id == target.chatId } ?: return false
                openChat(chat, jumpMessageId = jumpMessageId)
            }
        }
        return true
    }

    /** Notify from pages already fetched by the incremental call/pay scan.
     * Stable message IDs avoid timestamp-only false dedupe, while scanning the
     * bounded page preserves an incoming message followed by an own/blocked row. */
    private fun maybeNotify(
        changedPages: Map<String, List<SonarMsg>>,
        summaryByChat: Map<String, SonarConversationSummary>,
    ) {
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
                changedPages = changedPages,
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
                changedPages = changedPages,
                summaryByChat = summaryByChat,
            )
        }
        // Seed hidden/blocked/newly-removed rows too. Otherwise the first later
        // visible change could be mistaken for a never-seen chat and suppressed.
        for ((chatId, page) in changedPages) {
            rememberNotificationPage(
                chatId = chatId,
                page = page,
                observedLatestSecs = summaryByChat[chatId]?.latestAtSecs ?: 0L,
            )
        }
        notificationSeenMessageIds.keys.retainAll(knownChatIds)
        notificationLatestSecs.keys.retainAll(knownChatIds)
    }

    private fun notifyChatIfNew(
        c: SonarChat,
        scanIds: List<String>,
        suppressIds: List<String>,
        openChatId: String?,
        idKey: String,
        title: String?,
        changedPages: Map<String, List<SonarMsg>>,
        summaryByChat: Map<String, SonarConversationSummary>,
    ) {
        var newestIncoming: SonarMsg? = null
        var newestTrill: SonarMsg? = null
        val isOpen = openChatId != null && openChatId in suppressIds
        fun newer(candidate: SonarMsg, current: SonarMsg?): Boolean =
            current == null || candidate.tsSecs > current.tsSecs ||
                (candidate.tsSecs == current.tsSecs && candidate.id > current.id)
        for (chatId in scanIds) {
            val page = changedPages[chatId] ?: continue
            val candidate = newestUnseenIncoming(
                messages = page,
                seenMessageIds = notificationSeenMessageIds[chatId].orEmpty(),
                previousLatestSecs = notificationLatestSecs[chatId],
                isOpen = isOpen,
                allowsMessage = { message ->
                    !TrillLine.isTrillLine(message.content) &&
                        socialState.allowsChatMessage(chatId, message.senderNpub, message.mine)
                },
            )
            // A trill buzzes for ANY chat, including the open one, so its scan
            // ignores the open-chat suppression (throttle/mute gate the alert).
            val trillCandidate = newestUnseenIncoming(
                messages = page,
                seenMessageIds = notificationSeenMessageIds[chatId].orEmpty(),
                previousLatestSecs = notificationLatestSecs[chatId],
                isOpen = false,
                allowsMessage = { message ->
                    TrillLine.isTrillLine(message.content) &&
                        socialState.allowsChatMessage(chatId, message.senderNpub, message.mine)
                },
            )
            rememberNotificationPage(
                chatId = chatId,
                page = page,
                observedLatestSecs = summaryByChat[chatId]?.latestAtSecs ?: 0L,
            )
            if (candidate != null && newer(candidate, newestIncoming)) {
                newestIncoming = candidate
            }
            if (trillCandidate != null && newer(trillCandidate, newestTrill)) {
                newestTrill = trillCandidate
            }
        }
        val groupName = c.name.takeIf { c.members.size > 2 && it.isNotBlank() }
        newestIncoming?.let { incoming ->
            notifyIncoming(
                idKey = idKey,
                conversationTitle = title,
                content = incoming.content,
                senderName = notificationSenderName(c, incoming),
                groupName = groupName,
                unreadCount = unreadForChat(idKey).coerceAtLeast(1L),
                messageId = newestIncoming.id,
            )
        }
        newestTrill?.let { trill ->
            onTrillReceived(
                idKey = idKey,
                conversationTitle = title,
                content = trill.content,
                senderName = notificationSenderName(c, trill),
                groupName = groupName,
            )
        }
    }

    private fun rememberNotificationPage(
        chatId: String,
        page: List<SonarMsg>,
        observedLatestSecs: Long,
    ) {
        val seen = notificationSeenMessageIds.getOrPut(chatId) { LinkedHashSet() }
        for (message in page) {
            // Refresh insertion order so the bounded set retains IDs that are
            // still present in the newest local window.
            seen.remove(message.id)
            seen.add(message.id)
        }
        while (seen.size > NOTIFICATION_SEEN_MESSAGE_LIMIT) {
            val iterator = seen.iterator()
            if (!iterator.hasNext()) break
            iterator.next()
            iterator.remove()
        }
        val latest = maxOf(observedLatestSecs, page.maxOfOrNull { it.tsSecs } ?: 0L)
        notificationLatestSecs[chatId] = maxOf(notificationLatestSecs[chatId] ?: latest, latest)
    }

    private fun notificationSenderName(chat: SonarChat, message: SonarMsg): String? {
        if (message.senderNpub.isBlank()) return null
        if (chat.members.size > 2) {
            return resolveGroupAuthorName(message, isGroup = true, profilesByNpub, ::ensureProfile)
        }
        val key = canonicalProfileKey(message.senderNpub)
        return profilesByNpub[key]?.bestName ?: chatTitle(chat)
    }

    /** Start or resume the relay attach without owning local app readiness.
     * Failures retry while BLE, wallet, and the encrypted local database keep
     * running. */
    private fun startRelayConnection() {
        if (!started || relayConnectJob?.isActive == true) return
        relayConnecting = true
        lateinit var job: Job
        job = scope.launch {
            var consecutiveFailures = 0
            try {
                while (isActive && started) {
                    if (!SonarCore.isRelayConnected()) {
                        val result = runCatching { SonarCore.connectRelays() }
                        if (result.isFailure) {
                            consecutiveFailures++
                            // Log, never toast. The failed attach leaves the
                            // previously installed node in place, so the open chat
                            // keeps sending and receiving, and since the background
                            // invalidate every ordinary resume re-runs this attach —
                            // a raw "relay connect failed: no relay connected within
                            // timeout" toast fired over a conversation that was
                            // visibly working. The status chip carries the real state
                            // now ([relayOnline]). iOS only logs here too
                            // (MarmotChatView "⚠️ Marmot relay connect failed").
                            sonarLog(
                                "SonarRelay",
                                "relay attach failed (attempt $consecutiveFailures): " +
                                    "${result.exceptionOrNull()?.message}",
                            )
                            // Same reason as the superseded case below: the node is
                            // installed regardless of the attach outcome, so the local
                            // half of startup must not wait on sockets. Skipping it
                            // here left an offline cold start without the conversation
                            // listener, the wake loop or the invite drain until relays
                            // finally came up.
                            completeLocalStartup()
                            // "connecting…" is a claim that this is about to work.
                            // After the first failure it is not: the job retries
                            // for as long as relays are down, and while the flag
                            // stays up the chip can never reach its offline copy
                            // ("N nearby on Bluetooth") — the one useful thing it
                            // has to say in exactly this state.
                            if (consecutiveFailures == 1) relayConnecting = false
                            refreshRelayOnline()
                            delay(
                                RelayConnectionPolicy.connectRetryDelayMs(
                                    consecutiveFailures,
                                    foreground,
                                ),
                            )
                            continue
                        }
                        consecutiveFailures = 0
                        // Re-arm for the superseded case below: the attach
                        // succeeded but an invalidate may have left the latch
                        // down, and looping there we genuinely ARE still
                        // connecting. On a clean attach this is cleared by the
                        // `finally` a few lines later, so it costs nothing.
                        relayConnecting = true
                        npub = result.getOrThrow()
                        SonarCore.saveBlob(NPUB_BLOB_KEY, npub)
                    }
                    // The node is installed even when the attach was superseded, so
                    // local startup (listener, collectors, local refreshes) is correct
                    // either way and must not wait on a healthy latch.
                    completeLocalStartup()
                    refreshRelayOnline()
                    // A successful connect that left the latch down was superseded by
                    // an invalidate landing mid-attach
                    // ([RelayConnectionPolicy.latchAfterAttach]), so we are not
                    // attached: the relay-dependent one-shots stay pending (see
                    // [completeRelayStartup]) until a real attach lands. Nothing else
                    // re-triggers this job in time either: every caller goes through
                    // startRelayConnection(), which no-ops while the job is alive, so a
                    // foreground resume racing the attach waits out
                    // awaitRelayConnectionBounded() and then sits on dead sockets until
                    // the heartbeat (up to 30 s). Retry while foreground; once genuinely
                    // backgrounded, stop — looping would rebuild sockets the OS is
                    // suspending, and the push wake / next resume start a fresh job.
                    if (!SonarCore.isRelayConnected()) {
                        if (RelayConnectionPolicy.shouldRetrySupersededAttach(foreground)) {
                            delay(RELAY_SUPERSEDED_RETRY_MS)
                            continue
                        }
                        return@launch
                    }
                    completeRelayStartup()
                    return@launch
                }
            } finally {
                // A cancel() flips isActive false BEFORE this runs, so
                // startRelayConnection() can already have launched a
                // replacement. Only the current owner may clear the flag —
                // same ownership shape as marmotWakeOwnerGeneration.
                if (relayConnectJob === job) {
                    relayConnecting = false
                    refreshRelayOnline()
                }
            }
        }
        relayConnectJob = job
    }

    /** Republish the relay latch into UI state. The chip and the Connections
     *  sheet read [relayOnline], so every place that can change the latch —
     *  attach outcomes, the invalidate on background, the heartbeat — refreshes
     *  it rather than letting the UI drift from the core. */
    private fun refreshRelayOnline() {
        relayOnline = SonarCore.isRelayConnected()
    }

    /** Wait for KeyPackage/relay-dependent operations without blocking local
     * startup. Pending chat rows remain visible while this suspends. */
    private suspend fun awaitRelayConnection(): Boolean {
        if (!started) return false
        startRelayConnection()
        while (started && !SonarCore.isRelayConnected()) delay(100)
        return started && SonarCore.isRelayConnected()
    }

    /** Bounded variant used by the catch-up path: kick relay reconnection and
     *  wait up to [timeoutMs] for it to attach. Never blocks paint/send — this
     *  only runs inside a background catch-up job whose sole visible effect is
     *  the passive "catching up…" chip. Returns false on timeout so the chip
     *  clears instead of hanging while offline. */
    private suspend fun awaitRelayConnectionBounded(timeoutMs: Long = 8_000): Boolean {
        if (!started) return false
        startRelayConnection()
        var waited = 0L
        while (started && !SonarCore.isRelayConnected() && waited < timeoutMs) {
            delay(100)
            waited += 100
        }
        return started && SonarCore.isRelayConnected()
    }

    /** Single-flight forced gap-recovery sync. If [awaitRelay] is set and relays
     *  are down, wait bounded for reconnection before forcing the batched fetch
     *  (fixes the "chip shows Online while catch-up never ran" race when relays
     *  are disconnected at foreground time). Returns immediately if a forced
     *  catch-up is already running so overlapping requests don't double-enqueue
     *  syncForce on the serial engine queue. */
    private suspend fun forcedCatchupSync(awaitRelay: Boolean) {
        if (forcedCatchupInFlight) return
        forcedCatchupInFlight = true
        try {
            val connected = SonarCore.isRelayConnected() || (awaitRelay && awaitRelayConnectionBounded())
            if (connected) {
                publishSonarDescriptorIfNeeded(force = true)
                runCatching { SonarCore.syncForce() }
            }
        } finally {
            forcedCatchupInFlight = false
        }
    }

    /** Clear both one-shot startup gates. Teardown / wipe / restart must reset
     *  them together — leaving [localStartupCompleted] set across a wipe would
     *  skip reinstalling the conversation listener. */
    private fun resetStartupFlags() {
        relayStartupCompleted = false
        localStartupCompleted = false
    }

    /**
     * One-shot startup that only needs the installed node, not live sockets.
     *
     * Runs on every attach outcome, including one an invalidate superseded: the
     * node is installed either way and local reads already work through it, so
     * the listener, the collectors and the local refreshes must not wait on a
     * healthy latch. Nothing here publishes or fetches.
     */
    private suspend fun completeLocalStartup() {
        if (localStartupCompleted) return
        localStartupCompleted = true
        SonarCore.installConversationListener()
        collectConversationChanges()
        startMarmotWakeLoop()
        updateBleDiscoveryPolicy()
        runCatching { refreshChats() }
        runCatching { recomputeConversations() }
        drainPendingInviteTokens()
        requestHousekeeping()
    }

    /**
     * One-shot startup that needs live relays: profile hydrate/publish,
     * descriptor publish, staged-media resume, and the `clearMisses` descriptor /
     * member refreshes.
     *
     * Gated on an actually-attached node. Firing these after an attach a
     * mid-attach invalidate superseded would spend the only attempt they get —
     * [relayStartupCompleted] blocks a rerun, `runCatching` swallows their
     * failures, and the retry replaces and closes the node under them. The
     * session would then silently never publish its profile/descriptor or resume
     * staged media.
     */
    private suspend fun completeRelayStartup() {
        if (relayStartupCompleted) return
        relayStartupCompleted = true
        // Fetch own kind-0 before any publish: after nsec restore the local
        // nick/handle sidecars are empty, and publishing blank/stale metadata
        // would replace the durable relay profile.
        scope.launch {
            if (hydrateOwnProfileFromRelays() && nick.isNotBlank()) {
                runCatching { SonarCore.publishProfile(nick) }
            }
        }
        scope.launch { publishSonarDescriptorIfNeeded(force = true) }
        // Durable pre-Blossom media staging left by mid-upload kill/disconnect.
        scope.launch {
            runCatching { SonarCore.resumePendingMediaUploads() }
        }
        refreshKnownContactDescriptors(clearMisses = true)
        scope.launch {
            refreshChatMemberProfiles(clearMisses = true)
            delay(6_000)
            refreshChatMemberProfiles(clearMisses = true)
        }
    }

    /**
     * Pull our own kind-0 from relays into local profile state. Used after
     * nsec restore (and whenever local nick/handle prefs were lost) so the
     * Profile screen shows the durable name + NIP-05 instead of a blank/"you"
     * placeholder. Re-claims the handle when the core sidecar is empty so a
     * later publish cannot drop `nip05`.
     *
     * @return true when it is safe to republish kind-0 (non-blank nick, and
     *   either no remote nip05 needed seeding or the sidecar was re-claimed).
     */
    private suspend fun hydrateOwnProfileFromRelays(): Boolean {
        val claimedNow = coreClaimedHandle ?: SonarCore.claimedHandle()
        if (!needsOwnProfileRelayFetch(nick, bip353, claimedNow, handleDomain)) {
            return nick.isNotBlank() && canPublishOwnProfile(bip353, claimedNow)
        }
        val me = npub.takeIf { it.isNotBlank() } ?: return nick.isNotBlank()
        val profile = runCatching { SonarCore.fetchProfile(me) }.getOrNull()
        if (profile == null) return nick.isNotBlank() && canPublishOwnProfile(bip353, claimedNow)
        val key = canonicalProfileKey(me)
        val updated = profilesByNpub + (key to profile)
        profilesByNpub = normalizedProfileCache(updated)
        profileFetchedAt[key] = SonarClock.nowSecs()
        persistProfileCache()

        val plan = planOwnProfileHydration(
            localNickname = nick,
            localBip353 = bip353,
            localClaimedHandle = coreClaimedHandle ?: SonarCore.claimedHandle(),
            remote = profile,
            handleDomain = handleDomain,
        )
        plan.nicknameToAdopt?.let { name ->
            SonarCore.setNickname(name)
            nick = name
            refreshMeshIdentity()
        }
        // Mirror remote nip05 into prefs for Profile UI only — do not mark the
        // core claim / registrar seal until claimHandle actually seeds the sidecar.
        plan.nip05ToAdopt?.let { address -> updateBip353(address) }
        var handleSeeded = plan.handleLocalToClaim == null
        plan.handleLocalToClaim?.let { local ->
            // Prefer a wallet offer when ready so restore reclaim also seeds
            // BIP-353 payment DNS (chat-only claim is still valid if not).
            val offer = if (walletState is WalletState.Ready) {
                runCatching { WalletBridge.createOffer() }.getOrNull()
            } else null
            runCatching { SonarCore.claimHandle(local, offer) }
                .onSuccess { address ->
                    coreClaimedHandle = address
                    handleSeeded = true
                    if (offer != null) lastClaimedOffer = offer
                    if (bip353.isBlank()) updateBip353(address)
                    if (handleClaimState is HandleClaimState.Idle) {
                        handleClaimState = HandleClaimState.Claimed(address)
                    }
                }
        }
        // Skip publish when a remote nip05 still has no sidecar — a replaceable
        // kind-0 without nip05 would wipe the durable handle on relays.
        return plan.shouldPublishNickname && handleSeeded
    }

    fun boot() {
        if (started || connecting) return
        connecting = true
        resetStartupFlags()
        refreshRelayOnline()
        homeMessagesHydrated = false
        localCoreReady = false
        Notifier.ensureChannel()
        scope.launch {
            // ── LOCAL-FIRST PAINT (Signal/iOS parity): hydrate disk state and
            // open the encrypted database without any relay dependency.
            meshChats.putAll(MessageStore.loadAllMeshDms())
            // Legacy-media repair reads image files back from disk; that must
            // not sit between disk hydrate and core start on the local-first
            // paint path (Signal-Comparable Performance Rule). Run it beside
            // the startup sequence, not inside it.
            scope.launch { backfillMeshMediaBounds() }
            loadLinks()
            loadMeshNames()
            seedVerifiedChatIds()
            try {
                npub = SonarCore.start()
                SonarCore.saveBlob(NPUB_BLOB_KEY, npub)
                localCoreReady = true
                refreshChats()
                recomputeConversations()
                homeMessagesHydrated = true

                // Local usability begins here. These services must work through
                // a relay outage; relay attach/retry runs independently below.
                started = true
                // Adopt a core-claimed handle when the bip353 blob is blank
                // (fresh install restored from nsec, or lost prefs): the core
                // sidecar is the durable record, prefs are a mirror.
                coreClaimedHandle = SonarCore.claimedHandle()
                if (bip353.isBlank()) coreClaimedHandle?.let { updateBip353(it) }
                refreshMeshIdentity()
                updateBleDiscoveryPolicy()
                setupWallet()
                refreshLocationChannels()
                startMeshRealtimeLoop()
                poll()
                requestHousekeeping()
                launch { ensureCallStarted() }
                startRelayConnection()
            } catch (t: Throwable) {
                toast = "local startup failed: ${t.message}"
            } finally {
                // If the encrypted DB itself failed to open, reveal the metadata
                // snapshot instead of leaving the launch surface visible.
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
        val others = otherMembers(chat)
        if (others.size != 1) return chat.name.ifBlank { "Group chat" }
        val other = others.first()
        // A 1:1 chat is titled by the counterpart's LIVE kind-0 profile name.
        // The MLS group name is a creation-time snapshot (hosts may pass one,
        // e.g. sonar-cli --group-name) and must not freeze the row, shadow a
        // rename, or make two different contacts share one titled row.
        return directChatRowTitle(
            profileName = profilesByNpub[canonicalProfileKey(other)]?.bestName,
            groupName = chat.name,
            npubFallback = shortNpub(other),
        ).also { if (profilesByNpub[canonicalProfileKey(other)] == null) ensureProfile(other) }
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
                if (hadCachedProfile) {
                    // A cached profile's forced refetch missed (offline relay
                    // window). Stamp the attempt so sweepStaleProfiles() re-arms
                    // the in-flight guard after the refresh TTL — matching iOS,
                    // which stamps profileFetchedAt on cached-miss. Without this
                    // the key wedges in profileFetches forever and rename
                    // detection silently dies for that peer.
                    profileFetchedAt[key] = SonarClock.nowSecs()
                } else {
                    profileFetches.remove(key)
                }
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
        // Capture the generation HERE, not inside the coroutine: a wipe between
        // launch and start would otherwise let this fetch adopt the new
        // account's generation and persist the old account's contact.
        val generation = descriptorCacheGeneration
        scope.launch {
            performDescriptorFetch(key, generation)
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
        performDescriptorFetch(key, descriptorCacheGeneration)
        return sonarDescriptorsByNpubHex[key]
    }

    private suspend fun performDescriptorFetch(key: String, generation: Int) {
        val descriptor = runCatching { SonarCore.fetchSonarDescriptor(key) }.getOrNull()
        // The cache is durable now, so a fetch started under the previous
        // identity must not write (and persist) its contacts into the new
        // account after a wipe/restore.
        if (generation != descriptorCacheGeneration) {
            sonarDescriptorFetches.remove(key)
            return
        }
        if (descriptor != null) {
            // Stamp the fetch time BEFORE pruning so this key counts as the most
            // recently used, and pin it via `keep` — otherwise a peer whose
            // descriptor was published long ago is evicted the moment we cache
            // them and stays unpayable however often we refetch.
            sonarDescriptorFetchedAt[key] = SonarClock.nowSecs()
            sonarDescriptorsByNpubHex = boundedSonarDescriptorCache(
                sonarDescriptorsByNpubHex + (key to descriptor),
                lastFetchedAtSecs = sonarDescriptorFetchedAt,
                keep = key,
            )
            sonarDescriptorMissedAt.remove(key)
            persistSonarDescriptorCache()
        } else {
            // A miss is transient (relay reconnecting, FETCH_TIMEOUT, a relay
            // that just doesn't hold the event) — never evict an already
            // resolved descriptor, or the peer's BOLT12 offer disappears and a
            // payable chat silently loses "Send bitcoin".
            sonarDescriptorMissedAt[key] = SonarClock.nowSecs()
        }
        sonarDescriptorFetches.remove(key)
    }

    // ── Contact-cache persistence (profiles + Sonar descriptors) ──
    //
    // Both caches re-encode their WHOLE map on every successful fetch, and this
    // state's scope is a `rememberCoroutineScope()` (App.kt) — i.e. Main. A
    // relay-startup sweep (`refreshKnownContactDescriptors` /
    // `refreshChatMemberProfiles`) resolves N contacts, so the naive form did N
    // full-map encodes on the render path. On desktop it is worse than it looks:
    // `SonarCore.saveBlob` → `DesktopEnv.putString` writes the properties file
    // synchronously, so the write itself blocks too.
    //
    // So the per-fetch path snapshots the (immutable) map on Main and does the
    // encode AND the write on IO. Wipe/teardown must NOT use that path: it has
    // to observe the blob cleared before the account is replaced, so it writes
    // through [writeContactCacheNow], which is awaited.
    //
    // The mutex + generation are what keep a deferred write from landing after a
    // wipe and resurrecting erased contact data (an Account Key Durability-class
    // failure). Every synchronous write bumps the generation under the lock, so
    // any deferred write that encoded before the wipe is dropped rather than
    // committed.
    private val contactCacheWriteMutex = Mutex()
    /** Per-blob-key, NOT global. `eraseAllChats()` clears the profile cache but
     *  deliberately retains descriptors, so a global counter would let the
     *  profile write invalidate an in-flight descriptor write — and since the
     *  retained map is never re-persisted, that descriptor would silently
     *  vanish on the next restart. */
    private val contactCacheWriteGenerations = mutableMapOf<String, Int>()
    /** Per-key schedule order. Encodes run concurrently and finish out of
     *  order, so the mutex alone would serialize commits by *encode-completion*
     *  order and let an older snapshot overwrite a newer one — losing the newest
     *  profile or BOLT12 offer from disk until the next fetch. */
    private val contactCacheScheduledSeq = mutableMapOf<String, Int>()
    private val contactCacheCommittedSeq = mutableMapOf<String, Int>()

    /** Snapshot now on the caller's thread, encode + write on IO. Use for the
     *  per-fetch paths, never for wipe/teardown. */
    private fun scheduleContactCacheWrite(key: String, encode: () -> String) {
        val generation = contactCacheWriteGenerations[key] ?: 0
        val seq = (contactCacheScheduledSeq[key] ?: 0) + 1
        contactCacheScheduledSeq[key] = seq
        scope.launch(Dispatchers.IO) {
            val encoded = encode()
            contactCacheWriteMutex.withLock {
                if (generation != (contactCacheWriteGenerations[key] ?: 0)) return@withLock
                // A newer snapshot already landed — this one is stale.
                if (seq <= (contactCacheCommittedSeq[key] ?: 0)) return@withLock
                contactCacheCommittedSeq[key] = seq
                SonarCore.saveBlob(key, encoded)
            }
        }
    }

    /** Write immediately and invalidate every deferred write queued so far.
     *  Wipe/teardown only — callers must await this before replacing the
     *  account. */
    private suspend fun writeContactCacheNow(key: String, encoded: String) {
        contactCacheWriteMutex.withLock {
            // Invalidates deferred writes for THIS key only — a teardown that
            // clears one cache must not discard an in-flight write for a cache
            // it deliberately retains.
            contactCacheWriteGenerations[key] = (contactCacheWriteGenerations[key] ?: 0) + 1
            contactCacheCommittedSeq.remove(key)
            contactCacheScheduledSeq.remove(key)
            withContext(Dispatchers.IO) { SonarCore.saveBlob(key, encoded) }
        }
    }

    private fun persistSonarDescriptorCache() {
        val snapshot = sonarDescriptorsByNpubHex
        scheduleContactCacheWrite(SONAR_DESCRIPTOR_CACHE_BLOB_KEY) {
            encodeSonarDescriptorCache(snapshot)
        }
    }

    private suspend fun persistSonarDescriptorCacheNow() {
        writeContactCacheNow(
            SONAR_DESCRIPTOR_CACHE_BLOB_KEY,
            encodeSonarDescriptorCache(sonarDescriptorsByNpubHex),
        )
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
        val snapshot = profilesByNpub
        scheduleContactCacheWrite(PROFILE_CACHE_BLOB_KEY) {
            val encoded = encodeProfileCache(snapshot)
            sonarLog("SonarProfile", "persist cache: ${snapshot.size} profiles → ${encoded.length} chars")
            encoded
        }
    }

    private suspend fun persistProfileCacheNow() {
        val encoded = encodeProfileCache(profilesByNpub)
        sonarLog("SonarProfile", "persist cache (sync): ${profilesByNpub.size} profiles → ${encoded.length} chars")
        writeContactCacheNow(PROFILE_CACHE_BLOB_KEY, encoded)
    }

    fun openChat(chat: SonarChat, jumpMessageId: String? = null) {
        // Paint BEFORE push (Signal-Android): ChatScreen must never mount on
        // empty home leftover messages, then rebuild when the page lands.
        clearNotificationsForChat(chat.id)
        val generation = beginTranscriptSession(chat.id)
        resolveMarmotGroupId(chat.id)?.let { groupId ->
            scope.launch { runCatching { SonarCore.preferCatchupGroup(groupId) } }
        }
        pendingMarmotNpub(chat.id)?.let { pendingNpub ->
            messages = visibleMessagesForChat(chat.id, withSendEchoes(chat.id, emptyList()))
            push(Screen.Chat(chat.id, chatTitle(chat)))
            ensureProfile(pendingNpub)
            ensureSonarDescriptor(pendingNpub)
            startPendingMarmotChat(pendingNpub, chat.id)
            return
        }
        if (isPendingMarmotGroup(chat.id)) {
            messages = visibleMessagesForChat(chat.id, withSendEchoes(chat.id, emptyList()))
            push(Screen.Chat(chat.id, chatTitle(chat)))
            return
        }
        val readChatIds = directMarmotChatIds(chat.id)
        captureOpenChatUnread(chat.id, jumpMessageId = jumpMessageId)
        clearTranscriptHydrated(chat.id)
        // Mark read immediately — do not wait for the local page. Housekeeping
        // can otherwise restore unreadByChat from still-nonzero summaries.
        markGroupsRead(readChatIds)
        val title = chatTitle(chat)

        // Reopen: retained paint is already the last leave frame — push now.
        retainedTranscriptByChat[chat.id]?.takeIf { it.isNotEmpty() }?.let { retained ->
            messages = retained
            warmOpenTranscriptThumbs(messages)
            push(Screen.Chat(chat.id, title))
            scope.launch {
                val local = withSendEchoes(
                    chat.id,
                    mergePendingMediaUploads(chat.id, marmotMessagesPageForChat(chat.id, generation)),
                )
                val visibleLocal = visibleMessagesForChat(chat.id, local)
                if (!isCurrentTranscriptSession(chat.id, generation)) return@launch
                publishOpenTranscript(chat.id, visibleLocal)
                for (m in visibleLocal) if (!m.mine && m.senderNpub.isNotBlank()) ensureProfile(m.senderNpub)
                runCatching { refreshChats() }
                if (isCurrentTranscriptSession(chat.id, generation)) markTranscriptHydrated(chat.id)
                if (messages.isEmpty()) scheduleBlankTranscriptRecovery(chat.id, generation)
            }
            return
        }

        // First open (Signal-Android): load the bounded local page *before*
        // ChatScreen mounts. Snapshot→async replace was the rebuild flash.
        // Home stays up for the local read; Chat's frame 0 is the final page.
        scope.launch {
            val local = withSendEchoes(
                chat.id,
                mergePendingMediaUploads(chat.id, marmotMessagesPageForChat(chat.id, generation)),
            )
            if (!isActiveTranscriptGeneration(chat.id, generation)) return@launch
            val visibleLocal = visibleMessagesForChat(chat.id, local)
            messages = visibleLocal
            retainOpenTranscript(chat.id, visibleLocal)
            warmOpenTranscriptThumbs(visibleLocal)
            push(Screen.Chat(chat.id, title))
            if (isCurrentTranscriptSession(chat.id, generation)) {
                markTranscriptHydrated(chat.id)
            }
            // Opened blank on a conversation we know has history: the store was
            // not readable yet. Re-read it locally instead of leaving the chat
            // black until an unrelated sync event repaints it.
            if (visibleLocal.isEmpty()) scheduleBlankTranscriptRecovery(chat.id, generation)
            for (m in visibleLocal) if (!m.mine && m.senderNpub.isNotBlank()) ensureProfile(m.senderNpub)
            runCatching { refreshChats() }
        }
    }

    /** Open the 1:1 DM with a radar peer. The conversation auto-picks transport:
     *  BLE mesh (Noise) while in Bluetooth range, White Noise (Marmot) when out of
     *  range for a Sonar peer — both legs merged into one thread. [pay] auto-opens
     *  the payment sheet (radar "Send sats"). */
    fun openDm(peerId: String, name: String, pay: Boolean = false, jumpMessageId: String? = null) {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        val id = meshChatId(canonicalPeerId)
        if (name.isNotBlank()) rememberMeshName(canonicalPeerId, name)
        clearNotificationsForChat(id)
        captureOpenChatUnread(id, jumpMessageId = jumpMessageId)
        clearTranscriptHydrated(id)
        // Mesh route ids are not group keys — resolve before clearing badges.
        markGroupsRead(transcriptGroupIds(id))
        val generation = beginTranscriptSession(id)
        resolveMarmotGroupId(id)?.let { groupId ->
            scope.launch { runCatching { SonarCore.preferCatchupGroup(groupId) } }
        }

        // Reopen: retained leave paint → push now; hydrate quietly.
        retainedTranscriptByChat[id]?.takeIf { it.isNotEmpty() }?.let { retained ->
            messages = retained
            processPayLines(id, messages)
            warmOpenTranscriptThumbs(messages)
            push(Screen.Chat(id, name, pay))
            scope.launch {
                refreshOpenDm(canonicalPeerId)
                refreshChats()
                refreshOpenDm(canonicalPeerId)
                if (isCurrentTranscriptSession(id, generation)) markTranscriptHydrated(id)
            }
            return
        }

        // First open: merge mesh + White Noise local page before Chat mounts
        // so frame 0 is not a seed that later jumps when WN merges.
        scope.launch {
            val mesh = refreshMeshTranscriptWindow(canonicalPeerId)
            val wn = marmotMessagesForPeer(canonicalPeerId, id, generation)
            if (!isActiveTranscriptGeneration(id, generation)) return@launch
            val bounded = refreshConversationRows(mesh + wn, id, generation)
            val visible = visibleMessagesForChat(
                id,
                withSendEchoes(id, mergePendingMediaUploads(id, bounded)),
            )
            if (!isActiveTranscriptGeneration(id, generation)) return@launch
            messages = visible
            retainOpenTranscript(id, visible)
            processPayLines(id, visible)
            warmOpenTranscriptThumbs(visible)
            push(Screen.Chat(id, name, pay))
            if (isCurrentTranscriptSession(id, generation)) markTranscriptHydrated(id)
            // Opened blank on a conversation we know has history: re-read local
            // storage rather than leaving the chat black until the next sync.
            if (visible.isEmpty()) scheduleBlankTranscriptRecovery(id, generation)
            // markGroupsRead already ran before the local page; refreshOpenDm
            // (reopen path / housekeeping) re-marks if folded groups appear later.
            refreshChats()
        }
    }

    /**
     * Build a BLE-mesh [SonarMedia], deriving image dimensions from the bytes.
     *
     * Marmot media carries width/height as MIP-04 metadata, so its bubbles
     * reserve their final box before decode (Signal pre-sizing) and the
     * transcript never reflows. Mesh media has no metadata, so without this the
     * bubble reserves the fixed 216x150dp skeleton and visibly grows — and
     * shifts everything below it — the moment the image decodes. The header
     * read is cheap (no pixel buffer) and happens once, off the render path,
     * while we still hold the bytes.
     */
    private fun meshMediaFor(url: String, mime: String, filename: String, bytes: ByteArray): SonarMedia {
        val bounds = if (mime.startsWith("image/")) decodeImageBounds(bytes) else null
        return SonarMedia(url, mime, filename, bounds?.first, bounds?.second, null)
    }

    /**
     * One-time migration: mesh image media persisted before [meshMediaFor]
     * derived dimensions has null width/height, so its bubbles still reserve the
     * skeleton box and grow on decode. Recover the dimensions from the stored
     * bytes on the IO path at startup and rewrite the affected transcripts.
     */
    private suspend fun backfillMeshMediaBounds() {
        val repaired = mutableListOf<String>()
        for ((peerId, msgs) in meshChats.entries.toList()) {
            var changed = false
            val patched = msgs.map { msg ->
                if (msg.media.isEmpty()) return@map msg
                val media = msg.media.map { m ->
                    val needsBounds = m.mimeType.startsWith("image/") &&
                        (m.width == null || m.height == null) &&
                        m.url.startsWith(MESH_MEDIA_URL_PREFIX)
                    if (!needsBounds) return@map m
                    val bytes = mediaCache[m.url] ?: MessageStore.loadMeshMedia(m.url) ?: return@map m
                    val bounds = decodeImageBounds(bytes) ?: return@map m
                    changed = true
                    m.copy(width = bounds.first, height = bounds.second)
                }
                if (changed) msg.copy(media = media) else msg
            }
            if (changed) {
                meshChats[peerId] = patched
                repaired += peerId
            }
        }
        for (peerId in repaired) {
            MessageStore.saveMeshDm(peerId, meshChats[peerId].orEmpty())
        }
        if (repaired.isNotEmpty()) {
            sonarLog("SonarMedia", "backfilled mesh image bounds for ${repaired.size} peer transcript(s)")
        }
    }

    private fun meshChatId(peerId: String) = "mesh:$peerId"
    private fun meshPeerId(chatId: String) = chatId.removePrefix("mesh:")
    private fun isMeshChat(chatId: String) = chatId.startsWith("mesh:")

    /** Recreate bounded transcript state when Back reveals an earlier chat in the stack. */
    private fun restoreTranscriptSession(chat: Screen.Chat) {
        val generation = beginTranscriptSession(chat.id)
        clearTranscriptHydrated(chat.id)
        if (isMeshChat(chat.id)) {
            val peerId = meshPeerId(chat.id)
            // Seed the White Noise leg from the cached snapshot so the restored
            // paint is already complete (see openDm) — otherwise back-revealing
            // a mesh chat repeats the BLE-tail-then-jump on every navigation.
            val wnSnapshot = meshWhiteNoiseSeed(chat.id)
            val seedPaint = visibleMessagesForChat(
                chat.id,
                refreshConversationRows(
                    refreshMeshTranscriptWindow(peerId) + wnSnapshot,
                    chat.id,
                    generation,
                ),
            )
            messages = firstOpenTranscriptPaint(chat.id, seedPaint)
            retainOpenTranscript(chat.id, messages)
            warmOpenTranscriptThumbs(messages)
            scope.launch {
                refreshOpenDm(peerId)
                if (isCurrentTranscriptSession(chat.id, generation)) markTranscriptHydrated(chat.id)
                if (messages.isEmpty()) scheduleBlankTranscriptRecovery(chat.id, generation)
            }
            return
        }
        if (pendingMarmotNpub(chat.id) != null || isPendingMarmotGroup(chat.id)) {
            messages = visibleMessagesForChat(chat.id, withSendEchoes(chat.id, emptyList()))
            return
        }
        val snapshotPaint = visibleMessagesForChat(
            chat.id,
            withSendEchoes(
                chat.id,
                boundedTranscriptRows(
                    chatSnapshotMessagesByChat[chat.id].orEmpty(),
                    TRANSCRIPT_PAGE_SIZE,
                    pinnedToOlderEdge = false,
                ),
            ),
        )
        messages = firstOpenTranscriptPaint(chat.id, snapshotPaint)
        retainOpenTranscript(chat.id, messages)
        warmOpenTranscriptThumbs(messages)
        scope.launch {
            val local = withSendEchoes(
                chat.id,
                mergePendingMediaUploads(chat.id, marmotMessagesPageForChat(chat.id, generation)),
            )
            if (!isCurrentTranscriptSession(chat.id, generation)) return@launch
            setCurrentVisibleMessages(chat.id, local, processCalls = true)
            markTranscriptHydrated(chat.id)
            if (messages.isEmpty()) scheduleBlankTranscriptRecovery(chat.id, generation)
        }
    }

    private fun restoreRevealedChatOrClear() {
        val restoredChat = stack.lastOrNull() as? Screen.Chat
        if (restoredChat == null) {
            if (activeTranscriptChatId != null) endTranscriptSession()
            messages = emptyList()
        } else if (activeTranscriptChatId != restoredChat.id) {
            restoreTranscriptSession(restoredChat)
        }
    }

    fun back() {
        cleanupPreviewTempFiles()
        val popped = stack.lastOrNull()
        // Keep the leave paint so the next open of this chat is frame-0 ready
        // (Signal adapter retention), before we clear the live [messages] list.
        (popped as? Screen.Chat)?.let {
            retainOpenTranscript(it.id, messages)
            openChatUnread = openChatUnread - it.id
            openChatUnreadAnchor = openChatUnreadAnchor - it.id
            openChatJumpMessageId = openChatJumpMessageId - it.id
        }
        if (stack.size > 1) stack = stack.dropLast(1)
        restoreRevealedChatOrClear()
        scope.launch { refreshChats() }
    }

    /** Desktop master-detail helper: collapse the nav stack to [Screen.Home] so
     *  the content pane shows the welcome placeholder. Called before selecting a
     *  sidebar item so the stack never grows unbounded and a screen's Back button
     *  deselects (returns to the welcome pane) instead of walking history. */
    fun resetToHome() {
        cleanupPreviewTempFiles()
        if (stack.size > 1) {
            endTranscriptSession()
            stack = listOf(Screen.Home)
            messages = emptyList()
            openChatUnread = emptyMap()
            openChatUnreadAnchor = emptyMap()
            openChatJumpMessageId = emptyMap()
        }
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
        for (id in deleteIds) {
            notificationSeenMessageIds.remove(id)
            notificationLatestSecs.remove(id)
            stagedChangedPages.remove(id)
            failedChangedPageReads.remove(id)
            discardRetainedTranscript(id)
        }
        if (wasOpen && stack.size > 1) {
            endTranscriptSession()
            stack = stack.dropLast(1) // pop WITHOUT refresh
            restoreRevealedChatOrClear()
        }
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
            discardRetainedTranscript(meshChatId(alias))
        }
        discardRetainedTranscript(chatId)
        meshDmRows = meshDmRows.filterNot { row -> row.peerId in aliases }
        if (foldedGroupIdsToDelete.isNotEmpty()) {
            chats = chats.filterNot { it.id in foldedGroupIdsToDelete }
            foldedGroupIds = foldedGroupIds - foldedGroupIdsToDelete
            foldedGroupPeerIds = foldedGroupPeerIds.filterKeys { it !in foldedGroupIdsToDelete }
            foldedGroupIdsToDelete.forEach {
                groupFoldMap.remove(it)
                notificationSeenMessageIds.remove(it)
                notificationLatestSecs.remove(it)
                stagedChangedPages.remove(it)
                failedChangedPageReads.remove(it)
                unreadByChat = unreadByChat - it
                discardRetainedTranscript(it)
            }
            persistGroupFolds()
            clearChatSnapshot()
        }
        updateBleDiscoveryPolicy()
        if (wasOpen && stack.size > 1) {
            endTranscriptSession()
            stack = stack.dropLast(1)
            restoreRevealedChatOrClear()
        }
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
            beginTranscriptSession(pendingId)
            messages = visibleMessagesForChat(pendingId, withSendEchoes(pendingId, emptyList()))
            startPendingMarmotChat(canonicalPeer, pendingId)
            return
        }
        scope.launch {
            if (!awaitRelayConnection()) return@launch
            try {
                val chatId = runMarmotAccountOperation { SonarCore.startChat(p) }
                refreshChats()
                val chat = chats.firstOrNull { it.id == chatId }
                if (chat != null) {
                    openChat(chat)
                } else {
                    push(Screen.Chat(chatId, shortNpub(p)))
                    val generation = beginTranscriptSession(chatId)
                    val local = marmotMessagesPageForChat(chatId, generation)
                    if (isCurrentTranscriptSession(chatId, generation)) {
                        setCurrentVisibleMessages(chatId, local, processCalls = true)
                    }
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
                if (!awaitRelayConnection()) return@launch
                val chatId = runMarmotAccountOperation { SonarCore.startChat(npubHex) }
                finishPendingMarmotChat(npubHex, canonicalPeer, pendingChatId, chatId, setupToken = setupToken)
            } catch (error: CancellationException) {
                throw error
            } catch (t: Throwable) {
                if (failPendingMarmotChat(npubHex, pendingChatId, setupToken)) {
                    toast = "couldn’t start secure chat: ${t.message}"
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
            val generation = beginTranscriptSession(chatId)
            val local = withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId, generation)))
            if (isCurrentTranscriptSession(chatId, generation)) {
                setCurrentVisibleMessages(chatId, local, processCalls = true)
            }
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
        pendingDirectMarmotSends.remove(npubHex)
        pendingSendEchoes[pendingChatId].orEmpty().map { it.id }.forEach { echoId ->
            failSendEcho(pendingChatId, echoId)
        }
        // Keep the pending route + failed echoes. Tapping Retry replaces just
        // that echo, rebuilds the queue, and starts secure-chat setup again.
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
            runCatching { sendQueuedMarmotContent(chatId, send.text) }
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
        beginTranscriptSession(pendingId)
        messages = visibleMessagesForChat(pendingId, withSendEchoes(pendingId, emptyList()))
    }

    private fun startPendingMarmotGroupCreation(pendingChatId: String) {
        val pending = pendingMarmotGroups[pendingChatId] ?: return
        if (pendingMarmotGroupSetupJobs.containsKey(pendingChatId)) return
        val setupToken = nextPendingMarmotGroupSetupToken(pendingChatId)
        val setupJob = scope.launch {
            try {
                if (!awaitRelayConnection()) return@launch
                val chatId = runMarmotAccountOperation { SonarCore.startGroup(pending.members, pending.name) }
                finishPendingMarmotGroup(pendingChatId, chatId, setupToken = setupToken)
            } catch (error: CancellationException) {
                throw error
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
                if (!awaitRelayConnection()) return@launch
                val chatId = runMarmotAccountOperation { SonarCore.acceptGroupInvite(inviteId) }
                finishPendingMarmotGroup(pendingChatId, chatId, setupToken = setupToken)
            } catch (error: CancellationException) {
                throw error
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
            val generation = beginTranscriptSession(chatId)
            val local = withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId, generation)))
            if (isCurrentTranscriptSession(chatId, generation)) {
                setCurrentVisibleMessages(chatId, local, processCalls = true)
            }
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
            endTranscriptSession()
            stack = stack.dropLast(1)
            restoreRevealedChatOrClear()
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
            runCatching { sendQueuedMarmotContent(chatId, send.text) }
                .onSuccess { clearSendEcho(chatId, send.echoId) }
                .onFailure {
                    failSendEcho(chatId, send.echoId)
                    toast = "send failed: ${it.message}"
                }
        }
    }

    private suspend fun sendQueuedMarmotContent(chatId: String, text: String) {
        val sticker = meshParseStickerContent(text)
        if (sticker != null) {
            sendMarmotStickerOrdered(
                chatId,
                sticker.packCoordinate,
                sticker.shortcode,
                sticker.plaintextSha256,
            )
        } else {
            sendMarmotTextOrdered(chatId, text)
        }
    }

    private suspend fun sendMarmotTextOrdered(chatId: String, text: String) {
        runMarmotAccountOperation { SonarCore.send(chatId, text) }
    }

    private suspend fun sendMarmotStickerOrdered(
        chatId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
    ) {
        runMarmotAccountOperation {
            SonarCore.sendSticker(chatId, packCoordinate, shortcode, plaintextSha256)
        }
    }

    /** Serialize every plaintext-publishing Marmot operation with account
     * mutation. Capturing the generation before waiting prevents a send that
     * was queued against the old account from running after erase/restore. */
    private suspend inline fun <T> runMarmotAccountOperation(block: () -> T): T {
        if (marmotAccountMutationSuspended) {
            throw CancellationException("Marmot account state is being replaced")
        }
        val generation = marmotAccountGeneration
        return marmotSendMutex.withLock {
            if (marmotAccountMutationSuspended || generation != marmotAccountGeneration) {
                throw CancellationException("Marmot account state is being replaced")
            }
            block()
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
        if (isMeshChat(chatId)) {
            sendDmAuto(meshPeerId(chatId), t)
            reloadNewestAfterSendIfNeeded(chatId)
            return
        }
        pendingMarmotNpub(chatId)?.let { pendingNpub ->
            sendPendingMarmotChat(chatId, pendingNpub, t)
            reloadNewestAfterSendIfNeeded(chatId)
            return
        }
        if (isPendingMarmotGroup(chatId)) {
            sendPendingMarmotGroup(chatId, t)
            reloadNewestAfterSendIfNeeded(chatId)
            return
        }
        val echo = createSendEcho(chatId, t)
        messages = (messages + echo).sortedBy { it.tsSecs }
        scope.launch {
            runMarmotSendWithBestEffortReconciliation(
                send = { sendMarmotTextOrdered(chatId, t) },
                onSendAccepted = { markSendEchoAccepted(chatId, echo.id) },
                reconcile = {
                    val refreshGeneration = transcriptGeneration
                    val published = mergePendingMediaUploads(
                        chatId,
                        marmotMessagesPageForChat(chatId, refreshGeneration),
                    )
                    val hasCanonicalRow = reserveSuccessfulEchoCanonicalRows(chatId, echo, published)
                    if (!hasCanonicalRow) {
                        markSendEchoAccepted(chatId, echo.id)
                    }
                    val local = withSendEchoes(chatId, published)
                    if (isCurrentTranscriptSession(chatId, refreshGeneration)) {
                        setCurrentVisibleMessages(chatId, local, processCalls = true)
                    }
                    if (hasCanonicalRow) {
                        clearSendEcho(chatId, echo.id)
                    }
                },
                onSendFailure = { error ->
                    failSendEcho(chatId, echo.id)
                    toast = "send failed: ${error.message}"
                },
                onReconciliationFailure = { markSendEchoAccepted(chatId, echo.id) },
            )
        }
        reloadNewestAfterSendIfNeeded(chatId)
    }

    /** Signal-style retry for one failed outgoing row. Core-backed messages
     *  republish their original encrypted event; optimistic setup/media rows
     *  reuse the local plaintext/bytes that are already held for that row. */
    fun retryMessage(chatId: String, message: SonarMsg) {
        if (marmotAccountMutationSuspended || !sonarCanRetryMessage(message)) return
        val mediaUploads = pendingMediaUploads[chatId]
            ?.filter { it.message.id == message.id }
            .orEmpty()
        if (mediaUploads.isNotEmpty()) {
            retryPendingMedia(chatId, message.id)
            return
        }

        if (message.id.startsWith(echoIdPrefix)) {
            retrySendEcho(chatId, message.id)
            return
        }

        val current = messages.firstOrNull { it.id == message.id } ?: return
        val retrying = sonarMessageForRetry(current, "Sending") ?: return
        messages = messages.map {
            if (it.id == message.id) retrying else it
        }
        scope.launch {
            runCatching { runMarmotAccountOperation { SonarCore.retryMessage(message.id) } }
                .onSuccess { refreshRetriedMarmotMessage(chatId) }
                .onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    if ((screen as? Screen.Chat)?.id == chatId) {
                        messages = messages.map {
                            if (it.id == message.id) it.copy(state = "Couldn't send") else it
                        }
                    }
                    toast = "retry failed: ${error.message}"
                }
        }
    }

    private fun retryPendingMedia(
        chatId: String,
        pendingId: String,
    ) {
        val pending = pendingMediaUploads[chatId] ?: return
        val matchingIndices = pending.indices.filter { pending[it].message.id == pendingId }
        val firstIndex = matchingIndices.firstOrNull() ?: return
        val retryState =
            if (pending[firstIndex].mime.startsWith("image/")) "Uploading" else "Sending"
        val retryingMessage = sonarMessageForRetry(pending[firstIndex].message, retryState) ?: return
        for (index in matchingIndices) {
            pending[index] = pending[index].copy(
                message = retryingMessage,
                completedOrder = null,
            )
        }
        messages = messages.map {
            if (it.id == pendingId) retryingMessage else it
        }
        val uploads = matchingIndices.map { pending[it] }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) {
                markPendingMediaFailed(chatId, pendingId)
                toast = "This media is no longer available to retry."
                return@launch
            }
            val listener = MediaUploadControl { id, fraction ->
                noteMediaUploadProgress(id, fraction)
            }
            registerMediaUploadControl(pendingId, listener)
            mediaUploadProgress[pendingId] = 0f
            try {
                if (uploads.size == 1) {
                    val upload = uploads.single()
                    SonarCore.sendMediaWithProgress(
                        groupId,
                        upload.data,
                        upload.filename,
                        upload.mime,
                        upload.message.content,
                        pendingId,
                        listener,
                    )
                } else {
                    SonarCore.sendMediaMultiWithProgress(
                        groupId,
                        uploads.map { AlbumUpload(it.data, it.filename, it.mime) },
                        uploads.first().message.content,
                        pendingId,
                        listener,
                    )
                }
                markPendingMediaCompleted(chatId, pendingId)
                clearMediaUploadProgress(pendingId)
                refreshRetriedMarmotMessage(chatId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isMediaUploadInFlight(error)) {
                    // Owner still uploading — keep Uploading UI / progress.
                    return@launch
                }
                if (isMediaUploadCancelled(error)) {
                    discardPendingMediaUpload(pendingId)
                    return@launch
                }
                clearMediaUploadProgress(pendingId)
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = visibleMessagesForChat(
                        chatId,
                        mergePendingMediaUploads(chatId, messages),
                    )
                }
                toast = "retry failed: ${error.message}"
            }
        }
    }

    /** Retry a platform-local echo in place. Keeping the same retained row as
     * the authority makes retry consume-once and prevents a transcript gap if
     * route setup or the replacement send fails. */
    private fun retrySendEcho(chatId: String, echoId: String) {
        val echoes = pendingSendEchoes[chatId] ?: return
        val index = echoes.indexOfFirst { it.id == echoId }
        if (index < 0) return
        val source = echoes[index]
        val content = sonarRetryContent(source)
        if (content == null) {
            toast = "This message is no longer available to retry."
            return
        }
        val retrying = sonarMessageForRetry(source, "Sending") ?: return
        val matchEcho = retrying.copy(tsSecs = SonarClock.nowSecs())

        // Replace the retained row before any asynchronous work. A stale second
        // tap now sees Sending and cannot enqueue another replacement.
        echoes[index] = retrying
        messages = messages.map { if (it.id == echoId) retrying else it }
        previouslyPublishedMessageIdsByEcho[echoId] = messages
            .asSequence()
            .filter { candidate ->
                candidate.mine &&
                    candidate.id != echoId &&
                    candidate.content == retrying.content &&
                    candidate.stickerRef == retrying.stickerRef &&
                    candidate.viaInternet == retrying.viaInternet &&
                    !candidate.id.startsWith(echoIdPrefix)
            }
            .map { it.id }
            .toSet()

        pendingMarmotNpub(chatId)?.let { pendingNpub ->
            val npubHex = canonicalNpubHex(pendingNpub)
            if (npubHex == null) {
                failSendEcho(chatId, echoId)
                toast = "This message is no longer available to retry."
                return
            }
            val queue = pendingDirectMarmotSends.getOrPut(npubHex) { mutableListOf() }
            queue.removeAll { it.echoId == echoId }
            queue.add(PendingDirectMarmotSend(chatId, content, echoId))
            if (queue.size > PENDING_MARMOT_DIRECT_SEND_QUEUE_LIMIT) {
                val dropped = queue.removeAt(0)
                failSendEcho(dropped.pendingChatId, dropped.echoId)
                toast = "Still setting up this chat — wait before retrying more."
            }
            startPendingMarmotChat(pendingNpub, chatId)
            return
        }

        if (isPendingMarmotGroup(chatId)) {
            val queue = pendingMarmotGroupSends.getOrPut(chatId) { mutableListOf() }
            queue.removeAll { it.echoId == echoId }
            queue.add(PendingMarmotGroupSend(content, echoId))
            if (queue.size > PENDING_MARMOT_GROUP_SEND_QUEUE_LIMIT) {
                val dropped = queue.removeAt(0)
                failSendEcho(chatId, dropped.echoId)
                toast = "Still setting up this group — wait before retrying more."
            }
            startPendingMarmotGroupCreation(chatId)
            return
        }

        val groupId = resolveMarmotGroupId(chatId)
        if (groupId != null) {
            scope.launch {
                try {
                    sendQueuedMarmotContent(groupId, content)
                    val generation = transcriptGeneration
                    val published = if (isMeshChat(chatId)) {
                        marmotMessagesForPeer(meshPeerId(chatId), chatId, generation)
                    } else {
                        marmotMessagesPageForChat(chatId, generation)
                    }
                    reserveSuccessfulEchoCanonicalRows(chatId, matchEcho, published)
                    clearSendEcho(chatId, echoId)
                    refreshRetriedMarmotMessage(chatId)
                } catch (error: Throwable) {
                    failSendEcho(chatId, echoId)
                    toast = "retry failed: ${error.message}"
                }
            }
            return
        }

        // A failed direct NIP-17 echo has no Marmot group. Reuse the retained
        // payload and clear it only after the replacement row is persisted.
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            val raw = npubRawFor(peerId)
            if (raw != null && canUseDirectNip17(peerId, raw)) {
                scope.launch {
                    val messageId = randomMeshId()
                    if (sendDirectNip17Now(peerId, raw, messageId, content)) {
                        val sent = privateDmMessage(
                            id = messageId,
                            senderNpub = npub,
                            text = content,
                            mine = true,
                            tsSecs = SonarClock.nowSecs(),
                            viaInternet = true,
                        )
                        appendMeshMessage(peerId, sent)
                        processPayLines(chatId, listOf(sent))
                        clearSendEcho(chatId, echoId)
                        refreshOpenDm(peerId)
                    } else {
                        failSendEcho(chatId, echoId)
                    }
                }
                return
            }
        }

        failSendEcho(chatId, echoId)
        toast = "This message is no longer available to retry."
    }

    private suspend fun refreshRetriedMarmotMessage(chatId: String) {
        if ((screen as? Screen.Chat)?.id != chatId) return
        val generation = transcriptGeneration
        val fresh = if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            refreshConversationRows(
                refreshMeshTranscriptWindow(peerId) + marmotMessagesForPeer(peerId, chatId, generation),
                chatId,
                generation,
            )
        } else {
            marmotMessagesPageForChat(chatId, generation)
        }
        if (isCurrentTranscriptSession(chatId, generation)) {
            setCurrentVisibleMessages(
                chatId,
                withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)),
                processCalls = true,
            )
        }
    }

    // ── Optimistic send echoes ──
    // Mirrors iOS local echo: show the message immediately in the transcript
    // while the MLS encrypt + relay publish runs in the background. Keyed by
    // the UI chat ID (Marmot group hex for direct chats, "mesh:<peerId>" for
    // mesh-routed DMs).
    private val pendingSendEchoes = mutableMapOf<String, MutableList<SonarMsg>>()
    // Matching uses whole-second timestamps. Remember already visible canonical
    // rows so an earlier identical send in that second cannot consume a new echo.
    private val previouslyPublishedMessageIdsByEcho = mutableMapOf<String, Set<String>>()
    private val echoIdPrefix = SEND_ECHO_ID_PREFIX
    // Newest rows read from local storage per group, kept before the render
    // window bounds them so echo reconciliation can still see an outgoing row.
    private val freshCanonicalByGroup = mutableMapOf<String, List<SonarMsg>>()

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
        previouslyPublishedMessageIdsByEcho[echo.id] = messages
            .asSequence()
            .filter { message ->
                message.mine &&
                    message.content == echo.content &&
                    message.viaInternet == echo.viaInternet &&
                    !message.id.startsWith(echoIdPrefix)
            }
            .map { it.id }
            .toSet()
        pendingSendEchoes.getOrPut(chatId) { mutableListOf() }.add(echo)
        return echo
    }

    private fun clearSendEcho(chatId: String, echoId: String) {
        previouslyPublishedMessageIdsByEcho.remove(echoId)
        pendingSendEchoes[chatId]?.removeAll { it.id == echoId }
        if (pendingSendEchoes[chatId].isNullOrEmpty()) pendingSendEchoes.remove(chatId)
        if ((screen as? Screen.Chat)?.id == chatId) {
            messages = messages.filterNot { it.id == echoId }
        }
    }

    private fun markSendEchoAccepted(chatId: String, echoId: String) {
        val list = pendingSendEchoes[chatId] ?: return
        val idx = list.indexOfFirst { it.id == echoId }
        if (idx < 0) return
        list[idx] = list[idx].copy(state = "Accepted")
        messages = messages.map { if (it.id == echoId) it.copy(state = "Accepted") else it }
    }

    /**
     * A successful send's local canonical copy can appear before an older,
     * identical send completes. Reserve every eligible new row for the older
     * pending echo so its later failure stays visible instead of being
     * heuristically fulfilled by this confirmed send.
     */
    private fun reserveSuccessfulEchoCanonicalRows(
        chatId: String,
        succeededEcho: SonarMsg,
        published: List<SonarMsg>,
    ): Boolean {
        val canonicalIds = eligibleCanonicalRowsForSendEcho(
            echo = succeededEcho,
            published = published,
            excludedPublishedIds = previouslyPublishedMessageIdsByEcho[succeededEcho.id].orEmpty(),
        ).mapTo(mutableSetOf()) { it.id }
        if (canonicalIds.isEmpty()) return false

        pendingSendEchoes[chatId].orEmpty()
            .asSequence()
            .filter {
                it.id != succeededEcho.id &&
                    sendEchoAwaitsCanonicalRow(it) &&
                    it.content == succeededEcho.content &&
                    it.viaInternet == succeededEcho.viaInternet
            }
            .forEach { pendingEcho ->
                previouslyPublishedMessageIdsByEcho[pendingEcho.id] =
                    previouslyPublishedMessageIdsByEcho[pendingEcho.id].orEmpty() + canonicalIds
            }
        return true
    }

    private fun failSendEcho(chatId: String, echoId: String) {
        previouslyPublishedMessageIdsByEcho.remove(echoId)
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
        val plan = planSendEchoDisplay(
            echoes,
            published,
            previouslyPublishedMessageIdsByEcho,
            freshCanonicalForChat(chatId),
        )
        if (plan.terminalAcceptedEchoIds.isNotEmpty()) {
            echoes.removeAll { it.id in plan.terminalAcceptedEchoIds }
            plan.terminalAcceptedEchoIds.forEach(previouslyPublishedMessageIdsByEcho::remove)
            if (echoes.isEmpty()) pendingSendEchoes.remove(chatId)
        }
        // A canonical row can suppress a duplicate bubble before the send
        // coroutine reports its exact outcome. Keep the echo pending until
        // clearSendEcho/failSendEcho receives that outcome so a late failure
        // still renders "Couldn't send" instead of disappearing.
        return (
            published.filterNot { it.id.startsWith(echoIdPrefix) } +
                plan.admittedCanonical +
                plan.visibleEchoes
            )
            .distinctBy { it.id }
            .sortedBy { it.tsSecs }
    }

    /** Newest locally stored rows for every source folded into [chatId]. */
    private fun freshCanonicalForChat(chatId: String): List<SonarMsg> {
        val groupIds = transcriptGroupIds(chatId)
        if (groupIds.isEmpty()) return freshCanonicalByGroup[chatId].orEmpty()
        val fresh = ArrayList<SonarMsg>()
        for (groupId in groupIds) {
            val rows = freshCanonicalByGroup[groupId] ?: continue
            // A mesh-folded conversation reads its Marmot legs as internet rows.
            fresh += if (isMeshChat(chatId)) rows.map { it.copy(viaInternet = true) } else rows
        }
        return fresh
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
            // A temp write can throw mid-batch (disk full): never leak the
            // files already written, and tell the user instead of dying quietly.
            val written = withContext(Dispatchers.IO) {
                val done = mutableListOf<PendingMediaPreview>()
                for (item in items) {
                    val suffix = when {
                        item.mime == "image/gif" -> ".gif"
                        isVideoMime(item.mime) -> ".vid"
                        else -> ".img"
                    }
                    val path = runCatching { writeTempMediaFile(item.bytes, suffix) }.getOrNull()
                    if (path == null) {
                        for (p in done) deleteTempMediaFile(p.tempPath)
                        return@withContext null
                    }
                    done += PendingMediaPreview(chatId, path, item.filename, item.mime)
                }
                done
            }
            if (written == null) {
                toast = "Couldn't prepare media."
                return@launch
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
            // here, on send confirmation — Signal-style). GIFs and videos pass
            // through untouched: `reencodeToJpeg` cannot decode them, and a
            // video is already bounded by the pick-time size cap.
            val prepared = mutableListOf<Triple<String, PickedPhoto, Boolean>>()
            var encodeFailed = false
            for (preview in items) {
                val raw = withContext(Dispatchers.IO) {
                    readTempMediaFile(preview.tempPath).also { deleteTempMediaFile(preview.tempPath) }
                } ?: continue
                if (preview.mime == "image/gif") {
                    prepared += Triple(preview.chatId, PickedPhoto(raw, preview.filename, preview.mime), true)
                } else if (isVideoMime(preview.mime)) {
                    // Normalize to the MDK-accepted MIME/filename set so an
                    // exotic container degrades to a file send, never an error.
                    val safeMime = encryptedAttachmentMime(preview.mime)
                    val safeFilename = encryptedAttachmentFilename(preview.filename)
                    prepared += Triple(preview.chatId, PickedPhoto(raw, safeFilename, safeMime), true)
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
    private var mediaTransfers by mutableStateOf<Map<String, MediaTransferState>>(emptyMap())
    private val mediaDownloadJobs = mutableMapOf<String, Job>()
    private val mediaDownloadControls = mutableMapOf<String, MediaDownloadControl>()
    private val mediaDownloadGenerations = mutableMapOf<String, Long>()
    private var nextMediaDownloadGeneration = 0L
    private val stickerPackCache = linkedMapOf<String, SonarStickerPack>()
    private val stickerImageCache = linkedMapOf<String, ByteArray>()
    /** Refs the latest relay-refreshed pack does not contain. Bounded; entries
     *  stop a removed/bogus ref from re-driving eviction + relay refetch on
     *  every bubble mount, retry tick, and tap. */
    private val unresolvableStickerRefKeys = linkedSetOf<String>()
    private var stickerImageMemoryBytes = 0
    private var stickerBenchmarkRecording = false
    /** Last locally-authoritative installed set. Generic pack metadata also
     *  contains previews/transcript packs and must never grant picker access. */
    private val installedPackCoordinates = mutableSetOf<String>()
    private var stickerCacheGeneration = 0L

    private sealed interface CachedStickerImageResult {
        data class Hit(val bytes: ByteArray) : CachedStickerImageResult
        data object Miss : CachedStickerImageResult
        data object Invalidated : CachedStickerImageResult
    }

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
    /** Blossom upload progress (0f..1f) keyed by optimistic pending message id. */
    private val mediaUploadProgress = mutableStateMapOf<String, Float>()
    private val mediaUploadControls = mutableMapOf<String, MediaUploadControl>()

    /** Live upload fraction for [pendingId], if an upload is in flight. */
    fun mediaUploadFraction(pendingId: String): Float? = mediaUploadProgress[pendingId]

    /** Cancel an in-flight Blossom upload for the optimistic bubble [pendingId]. */
    fun cancelMediaUpload(pendingId: String) {
        mediaUploadControls[pendingId]?.cancel()
        discardPendingMediaUpload(pendingId)
    }

    private fun isMediaUploadCancelled(error: Throwable): Boolean {
        var cur: Throwable? = error
        while (cur != null) {
            val msg = cur.message.orEmpty()
            if (msg.contains("upload cancelled", ignoreCase = true)) return true
            cur = cur.cause
        }
        return false
    }

    private fun isMediaUploadInFlight(error: Throwable): Boolean {
        var cur: Throwable? = error
        while (cur != null) {
            val msg = cur.message.orEmpty()
            if (msg.contains("already in flight", ignoreCase = true)) return true
            cur = cur.cause
        }
        return false
    }

    /** Drop a cancelled/abandoned optimistic media echo from host state. */
    private fun discardPendingMediaUpload(pendingId: String) {
        clearMediaUploadProgress(pendingId)
        val chatId = pendingMediaUploads.entries
            .firstOrNull { (_, pending) -> pending.any { it.message.id == pendingId } }
            ?.key
            ?: return
        val pending = pendingMediaUploads[chatId] ?: return
        pending.removeAll { it.message.id == pendingId }
        if (pending.isEmpty()) pendingMediaUploads.remove(chatId)
        if ((screen as? Screen.Chat)?.id == chatId) {
            messages = visibleMessagesForChat(
                chatId,
                mergePendingMediaUploads(chatId, messages.filterNot { it.id == pendingId }),
            )
        }
    }

    private fun registerMediaUploadControl(pendingId: String, control: MediaUploadControl) {
        // Do not cancel an existing control for the same id — a retry that races
        // an in-flight owner must not abort the owner's progress listener.
        if (mediaUploadControls.containsKey(pendingId)) return
        mediaUploadControls[pendingId] = control
    }

    private fun unregisterMediaUploadControl(pendingId: String) {
        mediaUploadControls.remove(pendingId)
    }

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
        val survivorMessages = survivors.map { it.message }.distinctBy { it.id }.map { msg ->
            val progress = mediaUploadProgress[msg.id]
            if (progress != null) msg.copy(uploadProgress = progress) else msg
        }
        val survivorIds = survivorMessages.mapTo(mutableSetOf()) { it.id }
        return (published.filterNot { it.id in survivorIds } + survivorMessages)
            .distinctBy { it.id }
            .sortedBy { it.tsSecs }
    }

    private fun noteMediaUploadProgress(pendingId: String, fraction: Float) {
        // Update the reactive map only — MediaUploadBar reads
        // mediaUploadFraction(id) so we avoid rebuilding the full transcript
        // on every ~100ms tick.
        scope.launch(Dispatchers.Main) {
            if (pendingId !in mediaUploadControls && pendingId !in mediaUploadProgress) {
                return@launch
            }
            mediaUploadProgress[pendingId] = fraction
        }
    }

    private fun clearMediaUploadProgress(pendingId: String) {
        unregisterMediaUploadControl(pendingId)
        mediaUploadProgress.remove(pendingId)
    }

    private suspend fun existingPublishedMediaUrls(groupId: String): Set<String> =
        runCatching { SonarCore.messagesPage(groupId, BACKGROUND_TRANSCRIPT_SCAN_LIMIT) }
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

    /** True if [chatId] can carry media now, or is a pending direct secure chat
     * whose existing setup task can establish the group before the first send. */
    fun canPrepareMedia(chatId: String): Boolean =
        !isContactBlocked(chatId) && canPrepareAttachmentRoute(
            hasMeshRoute = isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null,
            hasExistingMarmotRoute = resolveMarmotGroupId(chatId) != null,
            hasPendingDirectMarmotRoute = pendingMarmotNpub(chatId) != null,
        )

    /** Wait for the local pending-DM setup task rather than racing it with a
     * second group creation. The caller receives the resolved group id, so the
     * first dropped file survives the screen's pending-id replacement. */
    internal suspend fun prepareMediaRoute(chatId: String): AttachmentRoutePreparation {
        if (isContactBlocked(chatId)) return AttachmentRoutePreparation.Unavailable
        if (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            return AttachmentRoutePreparation.Ready(chatId)
        }
        resolveMarmotGroupId(chatId)?.let { return AttachmentRoutePreparation.Ready(it) }

        val pendingNpub = pendingMarmotNpub(chatId)
            ?: return AttachmentRoutePreparation.Unavailable
        pendingMarmotSetupJobs[chatId]?.join()
        val groupId = canonicalNpubHex(pendingNpub)
            ?.let { marmotGroupForNpub(it.hexToBytesOrEmpty()) }
            ?.id
            ?: return AttachmentRoutePreparation.Failed
        return AttachmentRoutePreparation.Ready(groupId)
    }

    /** Import results arrive after platform file IO. Queue the first selected
     * attachment behind the pre-existing direct-chat setup, then send using the
     * resolved group id rather than the transient pending chat id. */
    internal fun sendDroppedAttachments(
        chatId: String,
        dropped: DroppedFiles,
        onRouteReady: (() -> Unit)? = null,
        onRouteFailure: (() -> Unit)? = null,
    ) {
        if (dropped.files.isEmpty()) {
            toast = "Couldn't attach that file."
            return
        }
        scope.launch {
            when (val route = prepareMediaRoute(chatId)) {
                is AttachmentRoutePreparation.Ready -> {
                    dropped.files.forEach { file ->
                        sendAttachment(route.chatId, file.bytes, file.filename, file.mime)
                    }
                    // The files are dispatched — the share is genuinely resolved.
                    onRouteReady?.invoke()
                    if (dropped.rejectedCount > 0) {
                        toast = "Some files couldn't be attached."
                    }
                }
                AttachmentRoutePreparation.Unavailable -> {
                    toast = "This contact must be online to receive files."
                    onRouteFailure?.invoke()
                }
                AttachmentRoutePreparation.Failed -> {
                    toast = "Couldn't set up a secure file transfer."
                    onRouteFailure?.invoke()
                }
            }
        }
    }

    /** True if [chatId] can carry media over live BLE mesh or an existing Marmot group. */
    fun canSendMedia(chatId: String): Boolean =
        !isContactBlocked(chatId) && (
            (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) ||
                resolveMarmotGroupId(chatId) != null
            )

    /** Send an image to a White Noise chat: encrypt + Blossom upload + publish. */
    fun sendImage(chatId: String, data: ByteArray, filename: String, mime: String) {
        sendMediaAttachment(
            chatId = chatId,
            data = data,
            filename = filename,
            mime = mime,
            missingRouteMessage = "Start the secure chat first, then send a photo.",
            failureLabel = "photo",
        )
    }

    /** Send an arbitrary file through the same encrypted media transport. */
    private fun sendAttachment(chatId: String, data: ByteArray, filename: String, mime: String) {
        val safeFilename = encryptedAttachmentFilename(filename)
        val safeMime = encryptedAttachmentMime(mime)
        sendMediaAttachment(
            chatId = chatId,
            data = data,
            filename = safeFilename,
            mime = safeMime,
            missingRouteMessage = "Start the secure chat first, then send a file.",
            failureLabel = "file",
        )
    }

    private fun sendMediaAttachment(
        chatId: String,
        data: ByteArray,
        filename: String,
        mime: String,
        missingRouteMessage: String,
        failureLabel: String,
        skipMesh: Boolean = false,
    ) {
        if (marmotAccountMutationSuspended) return
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        if (!skipMesh && isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            // Only attempt the BLE route for payloads the file packet can
            // carry — a doomed attempt surfaces the misleading "Not connected
            // over Bluetooth" toast before the White Noise fallback runs.
            val fitsMesh = data.size.toLong() <= MAX_MESH_ATTACHMENT_BYTES
            if (fitsMesh && sendMeshMedia(meshPeerId(chatId), data, filename, mime)) return
            if (resolveMarmotGroupId(chatId) == null) {
                // No BLE delivery and no Marmot route — echo the image locally
                // so it's visible in the chat and can be retried later.
                queueMeshMediaForRetry(chatId, data, filename, mime)
                toast = if (!fitsMesh) {
                    "Image saved locally — too large for Bluetooth, resend when connected"
                } else {
                    "Image saved locally — resend when Bluetooth reconnects"
                }
                return
            }
        }
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) {
                if (isMeshChat(chatId)) {
                    queueMeshMediaForRetry(chatId, data, filename, mime)
                    toast = "Image saved locally — resend when connected"
                } else {
                    toast = missingRouteMessage
                }
                return@launch
            }
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
            mediaUploadProgress[pendingId] = 0f
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            val listener = MediaUploadControl { id, fraction ->
                noteMediaUploadProgress(id, fraction)
            }
            registerMediaUploadControl(pendingId, listener)
            try {
                SonarCore.sendMediaWithProgress(
                    groupId,
                    data,
                    filename,
                    mime,
                    "",
                    pendingId,
                    listener,
                )
                markPendingMediaCompleted(chatId, pendingId)
                clearMediaUploadProgress(pendingId)
                // Refresh the open conversation so the sent image shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val generation = transcriptGeneration
                            val mesh = refreshMeshTranscriptWindow(peerId)
                            val wn = marmotMessagesForPeer(peerId, chatId, generation)
                            if (isCurrentTranscriptSession(chatId, generation)) {
                                val rows = refreshConversationRows(mesh + wn, chatId, generation)
                                val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, rows))
                                setCurrentVisibleMessages(chatId, merged)
                            }
                        } else {
                            val fresh = marmotMessagesPageForChat(chatId)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (e: Throwable) {
                if (isMediaUploadInFlight(e)) {
                    return@launch
                }
                if (isMediaUploadCancelled(e)) {
                    discardPendingMediaUpload(pendingId)
                    return@launch
                }
                clearMediaUploadProgress(pendingId)
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
                }
                toast = "couldn't send $failureLabel: ${e.message}"
            }
        }
    }

    /** Send N images to one chat as ONE album message (single event, N imeta
     *  tags) that renders as the swipeable card deck. BLE mesh has no album
     *  packet, so a mesh-linked peer gets N individual image sends. */
    fun sendImageAlbum(chatId: String, items: List<PickedPhoto>) {
        if (marmotAccountMutationSuspended) return
        if (items.size <= 1) {
            items.firstOrNull()?.let { sendImage(chatId, it.bytes, it.filename, it.mime) }
            return
        }
        if (isContactBlocked(chatId)) { toast = "Unblock this contact before sending."; return }
        if (isMeshChat(chatId) && liveMeshRoutePeerId(meshPeerId(chatId)) != null) {
            // Mesh has no album packet and its file packets cap at
            // MAX_MESH_ATTACHMENT_BYTES. When an item (e.g. a video) exceeds
            // that and a White Noise route exists, prefer the Marmot album
            // path below instead of dropping items on the floor.
            val oversize = items.count { it.bytes.size.toLong() > MAX_MESH_ATTACHMENT_BYTES }
            if (oversize == 0 || resolveMarmotGroupId(chatId) == null) {
                // Send each over mesh and return. Sending per-item (not
                // `all {}`, which short-circuits mid-batch) avoids a partial
                // mesh send that then double-sends via the Marmot album path.
                var skipped = 0
                for (item in items) {
                    if (item.bytes.size.toLong() > MAX_MESH_ATTACHMENT_BYTES) {
                        skipped += 1
                        continue
                    }
                    if (!sendMeshMedia(meshPeerId(chatId), item.bytes, item.filename, item.mime)) {
                        if (resolveMarmotGroupId(chatId) != null) {
                            sendMediaAttachment(
                                chatId = chatId,
                                data = item.bytes,
                                filename = item.filename,
                                mime = item.mime,
                                missingRouteMessage = "Start the secure chat first, then send this attachment.",
                                failureLabel = "attachment",
                                skipMesh = true,
                            )
                        } else {
                            skipped += 1
                        }
                    }
                }
                if (skipped > 0) {
                    toast = if (skipped == 1) {
                        "1 attachment couldn't be sent over Bluetooth."
                    } else {
                        "$skipped attachments couldn't be sent over Bluetooth."
                    }
                }
                return
            }
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
            mediaUploadProgress[pendingId] = 0f
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            val listener = MediaUploadControl { id, fraction ->
                noteMediaUploadProgress(id, fraction)
            }
            registerMediaUploadControl(pendingId, listener)
            try {
                SonarCore.sendMediaMultiWithProgress(
                    groupId,
                    items.map { AlbumUpload(it.bytes, it.filename, it.mime) },
                    "",
                    pendingId,
                    listener,
                )
                markPendingMediaCompleted(chatId, pendingId)
                clearMediaUploadProgress(pendingId)
                // Refresh the open conversation so the sent album shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val generation = transcriptGeneration
                            val mesh = refreshMeshTranscriptWindow(peerId)
                            val wn = marmotMessagesForPeer(peerId, chatId, generation)
                            if (isCurrentTranscriptSession(chatId, generation)) {
                                val rows = refreshConversationRows(mesh + wn, chatId, generation)
                                val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, rows))
                                setCurrentVisibleMessages(chatId, merged)
                            }
                        } else {
                            val fresh = marmotMessagesPageForChat(chatId)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (e: Throwable) {
                if (isMediaUploadInFlight(e)) {
                    return@launch
                }
                if (isMediaUploadCancelled(e)) {
                    discardPendingMediaUpload(pendingId)
                    return@launch
                }
                clearMediaUploadProgress(pendingId)
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
        if (marmotAccountMutationSuspended) return
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
                // Signal-style: voice uses Sending + control spinner, not Uploading bar.
                state = "Sending",
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
            mediaUploadProgress[pendingId] = 0f
            if ((screen as? Screen.Chat)?.id == chatId) {
                messages = visibleMessagesForChat(chatId, mergePendingMediaUploads(chatId, messages))
            }
            val listener = MediaUploadControl { id, fraction ->
                noteMediaUploadProgress(id, fraction)
            }
            registerMediaUploadControl(pendingId, listener)
            try {
                SonarCore.sendMediaWithProgress(
                    groupId,
                    bytes,
                    filename,
                    mime,
                    "",
                    pendingId,
                    listener,
                )
                markPendingMediaCompleted(chatId, pendingId)
                clearMediaUploadProgress(pendingId)
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val generation = transcriptGeneration
                            val mesh = refreshMeshTranscriptWindow(peerId)
                            val wn = marmotMessagesForPeer(peerId, chatId, generation)
                            if (isCurrentTranscriptSession(chatId, generation)) {
                                val rows = refreshConversationRows(mesh + wn, chatId, generation)
                                val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, rows))
                                setCurrentVisibleMessages(chatId, merged)
                            }
                        } else {
                            val fresh = marmotMessagesPageForChat(chatId)
                            setCurrentVisibleMessages(chatId, withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh)))
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (e: Throwable) {
                if (isMediaUploadInFlight(e)) {
                    return@launch
                }
                if (isMediaUploadCancelled(e)) {
                    discardPendingMediaUpload(pendingId)
                    return@launch
                }
                clearMediaUploadProgress(pendingId)
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
        val encoded = meshStickerContent(packCoordinate, sticker.shortcode, sticker.sha256)
        reloadNewestAfterSendIfNeeded(chatId)
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            liveMeshRoutePeerId(peerId)?.let { route ->
                if (sendMesh(route, encoded)) return
            }
            val raw = npubRawFor(peerId)
            if (raw != null) {
                when {
                    shouldUseMarmotRoute(peerId, raw) -> sendStickerOverMarmot(peerId, raw, packCoordinate, sticker)
                    canUseDirectNip17(peerId, raw) -> sendDirectNip17(peerId, raw, encoded)
                    else -> toast = "Out of range — add each other as favorites to continue over Nostr."
                }
                return
            }
            toast = "Not connected — stay close and try again"
            return
        }
        pendingMarmotNpub(chatId)?.let { pendingNpub ->
            sendPendingMarmotChat(chatId, pendingNpub, encoded)
            return
        }
        if (isPendingMarmotGroup(chatId)) {
            sendPendingMarmotGroup(chatId, encoded)
            return
        }
        val groupId = resolveMarmotGroupId(chatId)
        if (groupId == null) {
            toast = "Stickers require an encrypted chat"
            return
        }
        val echo = createSendEcho(chatId, encoded)
        messages = (messages + echo).sortedBy { it.tsSecs }
        scope.launch {
            try {
                sendMarmotStickerOrdered(groupId, packCoordinate, sticker.shortcode, sticker.sha256)
                clearSendEcho(chatId, echo.id)
                val generation = transcriptGeneration
                val local = withSendEchoes(
                    chatId,
                    mergePendingMediaUploads(chatId, marmotMessagesPageForChat(chatId, generation)),
                )
                if (isCurrentTranscriptSession(chatId, generation)) {
                    setCurrentVisibleMessages(chatId, local, processCalls = true)
                }
            } catch (e: Throwable) {
                failSendEcho(chatId, echo.id)
                toast = "send failed: ${e.message}"
            }
        }
    }

    suspend fun stickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: List<String> = emptyList(),
        expectedGeneration: Long? = null,
    ): SonarStickerPack? {
        val generation = expectedGeneration ?: stickerCacheGeneration
        if (stickerCacheGeneration != generation) return null
        val cacheKey = "30031:${authorPubkeyHex.lowercase()}:$identifier"
        stickerPackCache.remove(cacheKey)?.let { stickerPackCache[cacheKey] = it; return it }
        return try {
            // Do not wait on relay connect first: core is local-first for
            // validated disk metadata, and a warm cache must not stall on relays.
            if (stickerCacheGeneration != generation) return null
            val pack = SonarCore.fetchStickerPack(authorPubkeyHex, identifier, relayUrls)
            if (stickerCacheGeneration != generation) return null
            if (stickerPackCache.size >= 20) stickerPackCache.remove(stickerPackCache.keys.first())
            stickerPackCache[cacheKey] = pack
            pack
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            null
        }
    }

    fun cachedStickerPacks(): List<SonarStickerPack> = stickerPackCache
        .filterKeys {
            shouldExposeCachedStickerPack(
                coordinate = it,
                installedCoordinates = installedPackCoordinates,
            )
        }
        .values
        .toList()

    suspend fun stickerImage(
        url: String,
        expectedSha256: String,
        expectedGeneration: Long? = null,
    ): ByteArray? {
        val generation = expectedGeneration ?: stickerCacheGeneration
        if (stickerCacheGeneration != generation) return null
        stickerImageFromMemory(expectedSha256)?.let { return it }
        return try {
            val bytes = SonarCore.fetchStickerImage(url, expectedSha256)
            if (stickerCacheGeneration != generation) return null
            rememberStickerImage(expectedSha256, bytes)
            bytes
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    /** Resolve a received sticker. Never gated on the pack being installed:
     *  the picker's installed list decides what you can SEND, while anything a
     *  peer sends must render from the reference alone (pack metadata off the
     *  relay, bytes off Blossom, both hash-verified).
     *
     *  [userInitiated] marks an explicit tap on the failed placeholder, which
     *  always retries even a ref previously judged unresolvable. */
    suspend fun stickerImage(ref: SonarStickerRef, userInitiated: Boolean = false): ByteArray? {
        val generation = stickerCacheGeneration
        val refKey = stickerRefMemoryKey(ref.packCoordinate, ref.shortcode, ref.plaintextSha256)
        // The core is the sole authority on whether the LATEST validated pack
        // still authorizes this exact ref, so every ref lookup asks it. There is
        // deliberately no host-side memory shortcut here: the byte LRU is keyed
        // by sha alone and cannot answer "does the current pack still contain
        // this sticker", which is what the core's validated read enforces.
        when (val cached = cachedStickerImage(ref, generation)) {
            is CachedStickerImageResult.Hit -> return cached.bytes
            CachedStickerImageResult.Invalidated -> return null
            CachedStickerImageResult.Miss -> Unit
        }
        if (stickerCacheGeneration != generation) return null
        // A ref the latest pack has already disowned must not re-drive relay
        // work on every bubble mount and retry tick — but a human tap is
        // bounded by the human, so it always gets a fresh attempt.
        if (userInitiated) {
            unresolvableStickerRefKeys.remove(refKey)
        } else if (refKey in unresolvableStickerRefKeys) {
            return null
        }
        val (author, identifier) = ref.packAddressParts() ?: return null
        val pack = stickerPack(
            authorPubkeyHex = author,
            identifier = identifier,
            expectedGeneration = generation,
        ) ?: return null
        // Session pack metadata can be stale: a sticker published to the pack
        // after this session cached its metadata — or a copy served by the
        // offline validated-local fallback — is missing from the cached copy
        // while every older sticker still renders. Evict and refetch once so
        // one early failed relay fetch cannot pin a stale pack for the session.
        val sticker = pack.stickerMatching(ref) ?: run {
            if (stickerCacheGeneration != generation) return null
            stickerPackCache.remove("30031:${author.lowercase()}:$identifier")
            val refreshed = stickerPack(
                authorPubkeyHex = author,
                identifier = identifier,
                expectedGeneration = generation,
            ) ?: return null
            refreshed.stickerMatching(ref) ?: run {
                // Only trust "not in pack" when we actually reached a relay.
                // The core falls back to stale validated-local metadata when the
                // fetch fails, so negative-caching an offline answer would keep
                // a perfectly good sticker black for the rest of the session —
                // exactly the stale-metadata failure this PR exists to fix.
                if (stickerCacheGeneration == generation && SonarCore.isRelayConnected()) {
                    rememberUnresolvableStickerRef(refKey)
                }
                return null
            }
        }
        return stickerImage(
            url = sticker.url,
            expectedSha256 = ref.plaintextSha256,
            expectedGeneration = generation,
        )
    }

    /** Run one representative device cache ladder through the production host
     * APIs: relay metadata, initial image load, memory hit, disk hit, then the
     * full-reference local transcript lookup. The launcher only supplies this
     * request in Debug builds. No pack is installed and no account data is
     * erased. */
    suspend fun runStickerBenchmark(request: StickerBenchmarkRequest) {
        val restoreVerbose = prefBool("diagVerbose")
        SonarCore.setDiagnosticsVerbose(true)
        try {
            runStickerBenchmarkRecording(request)
        } finally {
            SonarCore.setDiagnosticsVerbose(restoreVerbose)
        }
    }

    private suspend fun runStickerBenchmarkRecording(request: StickerBenchmarkRequest) {
        val connected = withTimeoutOrNull(60_000) {
            while (!started) delay(100)
            while (!SonarCore.isRelayConnected()) {
                startRelayConnection()
                delay(100)
            }
            true
        } == true
        if (!connected) {
            sonarLog("SonarCore", "SONAR_BENCH device_sticker_batch_failed phase=relay_timeout")
            return
        }

        val imageLimit = request.imageLimit.coerceIn(1, 20)
        val imageOffset = request.imageOffset.coerceAtLeast(0)
        val cacheKey = "30031:${request.authorPubkeyHex.lowercase()}:${request.identifier}"
        val totalStarted = TimeSource.Monotonic.markNow()
        sonarLog(
            "SonarCore",
            "SONAR_BENCH device_sticker_batch_begin image_limit=$imageLimit " +
                "image_offset=$imageOffset",
        )

        // Force the benchmark's metadata call through the relay path, while
        // retaining every installed-authority value and all durable data.
        stickerPackCache.remove(cacheKey)
        clearStickerImageMemoryCache()
        val pack = try {
            SonarCore.fetchStickerPack(
                request.authorPubkeyHex,
                request.identifier,
                request.relayUrls,
            ).also {
                if (stickerPackCache.size >= 20) {
                    stickerPackCache.remove(stickerPackCache.keys.first())
                }
                stickerPackCache[cacheKey] = it
            }
        } catch (error: Throwable) {
            sonarLog(
                "SonarCore",
                "SONAR_BENCH device_sticker_batch_failed phase=pack_fetch " +
                    "error=${error::class.simpleName}",
            )
            return
        }
        val stickers = pack.stickers.drop(imageOffset).take(imageLimit)
        if (stickers.isEmpty()) {
            sonarLog("SonarCore", "SONAR_BENCH device_sticker_batch_failed phase=empty_pack")
            return
        }

        suspend fun fetchPass(): Int {
            var loaded = 0
            for (sticker in stickers) {
                if (stickerImage(sticker.url, sticker.sha256) != null) loaded++
            }
            return loaded
        }

        stickerBenchmarkRecording = true
        try {
            val initial = fetchPass()       // network on cold cache, disk otherwise
            val memory = fetchPass()        // host LRU
            clearStickerImageMemoryCache()
            val disk = fetchPass()          // verified Rust disk cache
            clearStickerImageMemoryCache()
            var refs = 0
            for (sticker in stickers) {
                if (stickerImage(
                    SonarStickerRef(pack.packCoordinate, sticker.shortcode, sticker.sha256),
                ) != null) {
                    refs++
                }
            }
            sonarLog(
                "SonarCore",
                "SONAR_BENCH device_sticker_batch_finished stickers=${stickers.size} " +
                    "image_offset=$imageOffset " +
                    "initial=$initial memory=$memory disk=$disk refs=$refs " +
                    "total_us=${totalStarted.elapsedNow().inWholeMicroseconds}",
            )
        } finally {
            stickerBenchmarkRecording = false
        }
    }

    private suspend fun cachedStickerImage(
        ref: SonarStickerRef,
        generation: Long,
    ): CachedStickerImageResult {
        return try {
            val bytes = SonarCore.cachedStickerImageForRef(ref)
            when (stickerCacheLookupState(bytes != null, generation, stickerCacheGeneration)) {
                StickerCacheLookupState.HIT -> {
                    val verifiedBytes = requireNotNull(bytes)
                    rememberStickerImage(ref.plaintextSha256, verifiedBytes)
                    CachedStickerImageResult.Hit(verifiedBytes)
                }
                StickerCacheLookupState.MISS -> CachedStickerImageResult.Miss
                StickerCacheLookupState.INVALIDATED -> CachedStickerImageResult.Invalidated
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            if (stickerCacheGeneration == generation) {
                CachedStickerImageResult.Miss
            } else {
                CachedStickerImageResult.Invalidated
            }
        }
    }

    private fun stickerImageFromMemory(expectedSha256: String): ByteArray? {
        val started = if (stickerBenchmarkRecording) TimeSource.Monotonic.markNow() else null
        val cacheKey = expectedSha256.lowercase()
        return stickerImageCache.remove(cacheKey)?.also {
            stickerImageCache[cacheKey] = it
            started?.let { mark ->
                sonarLog(
                    "SonarCore",
                    "SONAR_BENCH sticker_image_fetch purpose=foreground source=memory " +
                        "bytes=${it.size} total_us=${mark.elapsedNow().inWholeMicroseconds}",
                )
            }
        }
    }

    private fun rememberStickerImage(expectedSha256: String, bytes: ByteArray) {
        val cacheKey = expectedSha256.lowercase()
        stickerImageCache.remove(cacheKey)?.let { stickerImageMemoryBytes -= it.size }
        if (bytes.size > STICKER_IMAGE_MEMORY_BUDGET_BYTES) return
        while (
            stickerImageCache.size >= STICKER_IMAGE_MEMORY_ENTRY_LIMIT ||
            stickerImageMemoryBytes + bytes.size > STICKER_IMAGE_MEMORY_BUDGET_BYTES
        ) {
            val oldest = stickerImageCache.keys.firstOrNull() ?: break
            stickerImageCache.remove(oldest)?.let { stickerImageMemoryBytes -= it.size }
        }
        stickerImageCache[cacheKey] = bytes
        stickerImageMemoryBytes += bytes.size
    }

    private fun clearStickerImageMemoryCache() {
        stickerImageCache.clear()
        stickerImageMemoryBytes = 0
    }

    private fun rememberUnresolvableStickerRef(refKey: String) {
        while (unresolvableStickerRefKeys.size >= STICKER_UNRESOLVABLE_REF_LIMIT) {
            val oldest = unresolvableStickerRefKeys.firstOrNull() ?: break
            unresolvableStickerRefKeys.remove(oldest)
        }
        unresolvableStickerRefKeys += refKey
    }

    private fun clearStickerCaches() {
        stickerCacheGeneration++
        stickerPackCache.clear()
        unresolvableStickerRefKeys.clear()
        clearStickerImageMemoryCache()
        installedPackCoordinates.clear()
    }

    fun isPackInstalled(coordinate: String): Boolean =
        installedPackCoordinates.contains(normalizeStickerPackCoordinate(coordinate))

    suspend fun fetchInstalledPacks(): List<String>? {
        val generation = stickerCacheGeneration
        return try {
            val coordinates = SonarCore.fetchInstalledPacks()
            if (stickerCacheGeneration != generation) return null
            replaceInstalledPacks(coordinates)
            coordinates
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            null
        }
    }

    private fun replaceInstalledPacks(coords: List<String>) {
        installedPackCoordinates.clear()
        installedPackCoordinates.addAll(coords.map(::normalizeStickerPackCoordinate))
    }

    suspend fun installStickerPack(coordinate: String): Boolean {
        val generation = stickerCacheGeneration
        return try {
            SonarCore.installStickerPack(coordinate)
            if (stickerCacheGeneration != generation) return false
            installedPackCoordinates.add(normalizeStickerPackCoordinate(coordinate))
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            false
        }
    }

    suspend fun uninstallStickerPack(coordinate: String): Boolean {
        val generation = stickerCacheGeneration
        return try {
            SonarCore.uninstallStickerPack(coordinate)
            if (stickerCacheGeneration != generation) return false
            val normalized = normalizeStickerPackCoordinate(coordinate)
            installedPackCoordinates.remove(normalized)
            stickerPackCache.remove(normalized)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            false
        }
    }

    fun mediaTransferState(media: SonarMedia): MediaTransferState {
        mediaTransfers[media.url]?.let { return it }
        // Synthesise Available from disk without writing mediaTransfers —
        // same as iOS mediaTransferState + existingMediaURL. Publishing every
        // local hit on bubble appear rebuilds the transcript during open.
        val path = MediaCache.finalPath(media.url)
        if (MediaCache.existsSync(path)) return MediaTransferState.available(path)
        return MediaTransferState.NotDownloaded
    }

    /** True once [prepareMedia] or a download has produced a definite phase for
     *  this attachment. An un-probed attachment also reads NotDownloaded, but
     *  should render a quiet placeholder — not the download skeleton — until
     *  the local-cache check lands. Local disk hits synthesised by
     *  [mediaTransferState] do not count as "known" in the map (and already
     *  paint as Available, so they never need the download skeleton). */
    fun mediaTransferKnown(media: SonarMedia): Boolean = mediaTransfers.containsKey(media.url)

    /** Hydrate local transfer state without network work when the file is on
     * disk; optionally auto-download images. Documents/videos pass false.
     *
     * Disk hits skip observable writes (nil / Available) — [mediaTransferState]
     * already synthesises Available. Only Downloading/Failed recover into the
     * map. Signal avoids open-time transfer-state churn the same way. */
    fun prepareMedia(chatId: String, media: SonarMedia, autoDownload: Boolean) {
        val key = media.url
        if (mediaTransfers[key]?.phase == MediaTransferPhase.Downloading) return
        val finalPath = MediaCache.finalPath(key)
        if (MediaCache.existsSync(finalPath)) {
            if (shouldPublishDiskHit(mediaTransfers[key]?.phase)) {
                setMediaTransfer(key, MediaTransferState.available(finalPath))
            }
            return
        }
        if (autoDownload || mediaCache[key] != null) {
            requestMediaDownload(chatId, media)
        }
        // Probe miss: leave the map unset. mediaTransferState stays
        // NotDownloaded; the chip/skeleton treat unknown vs known via
        // mediaTransferKnown (images auto-download instead).
    }

    fun requestMediaDownload(chatId: String, media: SonarMedia) {
        val key = media.url
        if (mediaDownloadJobs[key]?.isActive == true) return
        val generation = ++nextMediaDownloadGeneration
        val finalPath = MediaCache.finalPath(key)
        val partialPath = MediaCache.partialPath(key, generation.toString())
        mediaDownloadGenerations[key] = generation
        setMediaTransfer(key, MediaTransferState.downloading(null))

        // Signal-Android TransferControlView throttles PartProgressEvent ~100ms
        // so download ticks do not invalidate the whole conversation list.
        var lastProgressPublishMs = 0L
        val control = MediaDownloadControl { received, total ->
            scope.launch {
                if (mediaDownloadGenerations[key] != generation) return@launch
                val progress = total?.takeIf { it > 0uL }?.let {
                    (received.toDouble() / it.toDouble()).toFloat().coerceIn(0f, 1f)
                }
                val now = SonarClock.nowMillis()
                val terminal = progress != null && progress >= 0.99f
                if (!terminal && now - lastProgressPublishMs < 100L) return@launch
                lastProgressPublishMs = now
                setMediaTransfer(key, MediaTransferState.downloading(progress))
            }
        }
        mediaDownloadControls[key] = control

        mediaDownloadJobs[key] = scope.launch {
            var succeeded = false
            try {
                MediaCache.prepare()
                if (MediaCache.exists(finalPath)) {
                    succeeded = true
                } else {
                    val cached = mediaCache[key]
                    val wrotePartial = when {
                        cached != null -> MediaCache.write(partialPath, cached)
                        key.startsWith(MESH_MEDIA_URL_PREFIX) -> {
                            val bytes = MessageStore.loadMeshMedia(key)
                            bytes != null && MediaCache.write(partialPath, bytes)
                        }
                        else -> {
                            val groupId = resolveMarmotGroupId(chatId)
                                ?: throw IllegalStateException("attachment has no secure media route")
                            SonarCore.fetchMediaToFile(groupId, key, partialPath, control)
                            true
                        }
                    }
                    if (!wrotePartial) throw IllegalStateException("could not write attachment cache")
                    if (control.isCancelled()) throw CancellationException("media download cancelled")
                    succeeded = MediaCache.promote(partialPath, finalPath)
                    if (!succeeded) throw IllegalStateException("could not finalize attachment cache")
                }
                if (mediaDownloadGenerations[key] == generation) {
                    setMediaTransfer(key, MediaTransferState.available(finalPath))
                    mediaCache[key]?.takeIf { it.size > 1024 * 1024 }?.let { mediaCache.remove(key) }
                    if (!media.isGif) {
                        scope.launch { warmTranscriptThumbnail(key, finalPath) }
                    }
                }
            } catch (_: CancellationException) {
                if (mediaDownloadGenerations[key] == generation) {
                    setMediaTransfer(key, MediaTransferState.NotDownloaded)
                }
            } catch (_: Throwable) {
                if (mediaDownloadGenerations[key] == generation) {
                    setMediaTransfer(
                        key,
                        if (control.isCancelled()) MediaTransferState.NotDownloaded else MediaTransferState.Failed,
                    )
                }
            } finally {
                withContext(NonCancellable) {
                    if (!succeeded) MediaCache.remove(partialPath)
                }
                if (mediaDownloadGenerations[key] == generation) {
                    mediaDownloadJobs.remove(key)
                    mediaDownloadControls.remove(key)
                    mediaDownloadGenerations.remove(key)
                }
            }
        }
    }

    fun cancelMediaDownload(media: SonarMedia) {
        val key = media.url
        mediaDownloadControls.remove(key)?.cancel()
        mediaDownloadJobs.remove(key)?.cancel()
        mediaDownloadGenerations.remove(key)
        setMediaTransfer(key, MediaTransferState.NotDownloaded)
    }

    private fun setMediaTransfer(key: String, state: MediaTransferState) {
        if (mediaTransfers[key] == state) return
        mediaTransfers = mediaTransfers + (key to state)
    }

    /** Best-effort: write a transcript thumbnail beside the attachment so cold
     * open binds ~1kpx pixels. Uses path-sampled decode (Signal-Android Glide
     * RESOURCE cache shape) — never reads the full attachment into a ByteArray. */
    private suspend fun warmTranscriptThumbnail(url: String, path: String) {
        val thumbPath = MediaCache.thumbnailPath(url)
        if (MediaCache.exists(thumbPath)) return
        val thumb = withContext(Dispatchers.Default) {
            decodeThumbnailFromPath(path, TRANSCRIPT_THUMB_MAX_EDGE_PX)
        } ?: return
        thumb.encoded?.let { MediaThumbnailDiskCache.store(url, it) }
    }

    private fun cancelAllMediaDownloads() {
        mediaDownloadControls.values.forEach(MediaDownloadControl::cancel)
        mediaDownloadJobs.values.forEach(Job::cancel)
        mediaDownloadControls.clear()
        mediaDownloadJobs.clear()
        mediaDownloadGenerations.clear()
        mediaTransfers = emptyMap()
        MediaImageMemoryCache.clear()
    }

    /** Read an already-local attachment for image decode or voice playback.
     * This function deliberately never starts network work. */
    suspend fun mediaData(chatId: String, media: SonarMedia): ByteArray? {
        mediaCache[media.url]?.let { return it }
        val path = mediaTransfers[media.url]?.localPath ?: MediaCache.finalPath(media.url)
        if (!MediaCache.exists(path)) return null
        val bytes = MediaCache.read(path) ?: return null
        if (bytes.size <= 1024 * 1024) mediaCache[media.url] = bytes
        return bytes
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
            val mid = randomMeshId()
            echoMeshMessage(peerId, text, mid)
            enqueueOutbox(peerId, text, mid)
            flushOutbox(peerId)
            toast = "Message queued and will send in order."
            return
        }
        liveMeshRoutePeerId(peerId)?.let { route ->
            if (sendMesh(route, text)) return
        }
        val raw = npubRawFor(peerId)
        if (raw != null) {
            when {
                shouldUseMarmotRoute(peerId, raw) -> sendOverMarmot(peerId, raw, text)
                canUseDirectNip17(peerId, raw) -> sendDirectNip17(peerId, raw, text)
                else -> {
                    val mid = randomMeshId()
                    echoMeshMessage(peerId, text, mid)
                    enqueueOutbox(peerId, text, mid)
                    toast = "Out of range — add each other as favorites to continue over Nostr."
                }
            }
            return
        }
        // Neither BLE mesh link nor npub available — queue for later delivery.
        val mid = randomMeshId()
        echoMeshMessage(peerId, text, mid)
        enqueueOutbox(peerId, text, mid)
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
            sendMarmotTextOrdered(groupId, text)
            true
        } catch (e: Throwable) {
            toast = "call signaling failed: ${e.message}"
            sonarLog("SonarCall", "failed to send call control over White Noise group=$groupId err=${e.message}")
            false
        }

    private suspend fun sendCallOverMarmot(peerId: String, npubRaw: ByteArray, text: String): Boolean {
        return try {
            refreshChats()
            val groupId = marmotGroupForNpub(npubRaw)?.id ?: run {
                if (!awaitRelayConnection()) return false
                runMarmotAccountOperation { SonarCore.startChat(npubRaw.toHexLower()) }
            }.also {
                refreshChats()
                recomputeConversations()
            }
            sendMarmotTextOrdered(groupId, text)
            refreshOpenDm(peerId)
            true
        } catch (e: Throwable) {
            toast = "call signaling failed: ${e.message}"
            sonarLog("SonarCall", "failed to send call control over White Noise peer=$peerId err=${e.message}")
            false
        }
    }

    /** Send a BLE-mesh DM over the Noise link + optimistically echo it.
     *  When [messageId] is provided (outbox delivery path), the echo was
     *  already created by [echoMeshMessage]; we skip the duplicate row but
     *  still send via BLE. */
    private fun sendMesh(peerId: String, text: String, messageId: String? = null): Boolean {
        if (isMeshContactBlocked(peerId)) {
            toast = "Unblock this contact before sending."
            return false
        }
        val mid = messageId ?: randomMeshId()
        val ok = MeshRadio.sendMeshDm(peerId, mid, text)
        if (!ok) { toast = "Not connected over Bluetooth yet — stay close and try again"; return false }
        // Direct send (messageId == null): create the local echo now.
        // Outbox delivery (messageId != null): the echo was already created by
        // echoMeshMessage when the message was first queued, so never create a
        // second row here — just stop tracking the id. Branching on null (not on
        // a meshEchoIds membership test) closes a duplicate-on-restart hole:
        // meshEchoIds is in-memory and empty after boot, but the echo survives in
        // persisted meshChats, so a membership test would wrongly re-create it.
        if (messageId == null) {
            val stickerRef = meshParseStickerContent(text)?.let {
                SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
            }
            // "Sent" = local transport accepted only; a recipient receipt
            // upgrades it to "Delivered" in drainMeshDeliveryReceipts.
            val msg = SonarMsg(mid, npub, if (stickerRef != null) "" else text, mine = true, MeshRadio.nowSecs(), stickerRef = stickerRef, state = "Sent")
            meshChats[peerId] = meshChats[peerId].orEmpty() + msg
            val canonicalPeerId = canonicalMeshPeerId(peerId)
            processPayLines(meshChatId(canonicalPeerId), listOf(msg))
        } else {
            meshEchoIds.remove(messageId)
            // The queued echo was painted with no transport; BLE has now accepted
            // the frame, so promote it the same way a direct send is tagged.
            markMeshRowState(peerId, messageId, "Sent")
        }
        persistMesh(peerId)
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        scope.launch { refreshOpenDm(canonicalPeerId) }
        refreshMeshDmRows()
        return true
    }

    /** Retag an existing local mesh row. Used to promote a queued outbox echo to
     *  "Sent" once BLE accepted the frame. No-op when the row is gone or already
     *  carries that state, so it is safe to call on every flush. */
    private fun markMeshRowState(peerId: String, messageId: String, state: String) {
        val existing = meshChats[peerId].orEmpty()
        if (existing.none { it.id == messageId && it.state != state }) return
        meshChats[peerId] = existing.map { if (it.id == messageId) it.copy(state = state) else it }
    }

    /** Create a local mesh-DM echo so the message is visible in the chat
     *  immediately, even when BLE is disconnected and the message is queued
     *  in the outbox. The same [messageId] is stored in the outbox so
     *  [flushOutboxNow] can deliver via BLE without creating a duplicate row. */
    private fun echoMeshMessage(
        peerId: String,
        text: String,
        messageId: String,
        timestampSecs: Long = MeshRadio.nowSecs(),
    ) {
        val stickerRef = meshParseStickerContent(text)?.let {
            SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
        }
        val msg = SonarMsg(messageId, npub, if (stickerRef != null) "" else text, mine = true, timestampSecs, stickerRef = stickerRef)
        meshChats[peerId] = meshChats[peerId].orEmpty() + msg
        meshEchoIds.add(messageId)
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        processPayLines(meshChatId(canonicalPeerId), listOf(msg))
        persistMesh(peerId)
        scope.launch { refreshOpenDm(canonicalPeerId) }
        refreshMeshDmRows()
    }

    /** Create a local mesh-DM media echo so the image is visible in the chat
     *  immediately, even when no transport (BLE or Marmot) is available. Bytes
     *  are cached + persisted so the image renders from local storage
     *  (Signal-style local-first). Returns the messageId. */
    private fun echoMeshMedia(peerId: String, data: ByteArray, filename: String, mime: String): String {
        val routePeerId = liveMeshRoutePeerId(peerId) ?: peerId
        val mid = randomMeshId()
        val mediaUrl = meshMediaUrl(routePeerId, mid, filename)
        val media = meshMediaFor(mediaUrl, mime, filename, data)
        // Hold bytes in memory until the durable save completes, then free
        // large payloads (>1 MB) to avoid unbounded mediaCache growth. Small
        // images stay cached for fast transcript rendering.
        mediaCache[mediaUrl] = data
        scope.launch {
            MessageStore.saveMeshMedia(mediaUrl, data)
            if (data.size > 1024 * 1024) mediaCache.remove(mediaUrl)
        }
        val msg = SonarMsg(mid, npub, "", mine = true, tsSecs = MeshRadio.nowSecs(), media = listOf(media))
        meshChats[routePeerId] = meshChats[routePeerId].orEmpty() + msg
        persistMesh(routePeerId)
        scope.launch { refreshOpenDm(canonicalMeshPeerId(routePeerId)) }
        refreshMeshDmRows()
        return mid
    }

    /** Remove a mesh-DM echo after it was delivered via Marmot (White Noise) to
     *  avoid a duplicate bubble in the merged mesh + White Noise view. The BLE
     *  path deduplicates via [sendMesh]'s messageId skip; the NIP-17 path
     *  deduplicates via appendMeshMessage's id guard. Only Marmot writes to a
     *  separate store with a different ID, leaving the echo unreconciled. */
    /** Mark a mesh echo as "Couldn't send" when its outbox entry is evicted
     *  (per-peer queue overflow). Without this the echo looks like a normal
     *  sent message even though it will never be delivered. */
    private fun failMeshEcho(peerId: String, messageId: String) {
        meshEchoIds.remove(messageId)
        val msgs = meshChats[peerId] ?: return
        meshChats[peerId] = msgs.map {
            if (it.id == messageId) it.copy(state = "Couldn't send") else it
        }
        persistMesh(peerId)
        refreshMeshDmRows()
    }

    private fun removeMeshEcho(peerId: String, messageId: String) {
        meshEchoIds.remove(messageId)
        val msgs = meshChats[peerId] ?: return
        val filtered = msgs.filterNot { it.id == messageId }
        if (filtered.size != msgs.size) {
            meshChats[peerId] = filtered
            persistMesh(peerId)
            refreshMeshDmRows()
        } else {
            sonarLog("SonarMesh", "removeMeshEcho: no echo found for peer=${peerId.take(10)}… id=${messageId.take(8)}…")
        }
    }

    /** Echo a mesh-DM media attachment locally and enqueue it for retry.
     *  Shared by the sync and async paths of [sendMediaAttachment] to avoid
     *  duplicating the echo+enqueue sequence. Returns the messageId. */
    private fun queueMeshMediaForRetry(chatId: String, data: ByteArray, filename: String, mime: String): String {
        val mid = echoMeshMedia(meshPeerId(chatId), data, filename, mime)
        mediaOutbox.enqueue(
            peerId = meshPeerId(chatId),
            messageId = mid,
            mediaUrl = meshMediaUrl(meshPeerId(chatId), mid, filename),
            filename = filename,
            mime = mime,
            timestampSecs = SonarClock.nowSecs(),
        )
        return mid
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
        val media = meshMediaFor(mediaUrl, mime, filename, data)
        mediaCache[mediaUrl] = data
        scope.launch { MessageStore.saveMeshMedia(mediaUrl, data) }
        val msg = SonarMsg(
            mid,
            npub,
            "",
            mine = true,
            tsSecs = MeshRadio.nowSecs(),
            media = listOf(media),
            state = "Sent",
        )
        meshChats[routePeerId] = meshChats[routePeerId].orEmpty() + msg
        persistMesh(routePeerId)
        scope.launch { refreshOpenDm(canonicalMeshPeerId(routePeerId)) }
        refreshMeshDmRows()
        return true
    }

    /** Write-through a peer's BLE-mesh transcript so it survives an app restart
     *  (parity with the iOS MessageStore). Marmot/White Noise legs are NOT written
     *  here — they already persist in the encrypted SQLCipher DB. */
    private fun persistMesh(
        peerId: String,
        deliveredMessageIds: List<String> = emptyList(),
        mediaFiles: List<Pair<String, ByteArray>> = emptyList(),
    ) {
        updateBleDiscoveryPolicy()
        scope.launch {
            meshPersistenceMutex.withLock {
                val latestMessages = meshChats[peerId].orEmpty()
                val mediaSaved = mediaFiles.all { (url, bytes) -> MessageStore.saveMeshMedia(url, bytes) }
                val transcriptSaved = MessageStore.saveMeshDm(peerId, latestMessages)
                if (!mediaSaved || !transcriptSaved) {
                    sonarLog(
                        "MeshDelivery",
                        "local persistence failed peer=${peerId.take(10)} media=$mediaSaved transcript=$transcriptSaved",
                    )
                    return@withLock
                }
                deliveredMessageIds.forEach { messageId ->
                    if (!MeshRadio.sendMeshDeliveryAck(peerId, messageId)) {
                        sonarLog(
                            "MeshDelivery",
                            "ack route unavailable peer=${peerId.take(10)} message=${messageId.take(12)}",
                        )
                    }
                }
            }
        }
    }

    private fun shouldUseMarmotRoute(peerId: String, npubRaw: ByteArray): Boolean {
        val npubHex = npubRaw.toHexLower()
        return marmotGroupForNpub(npubRaw) != null ||
            aliasesSupportMarmotRoute(
                aliases = preferredMeshAliases(peerId),
                hasSonarProfile = { alias -> sonarProfile(alias) != null },
                capabilitiesForAlias = { alias -> linkCapsByFp[alias] ?: 0 },
            ) ||
            sonarDescriptorsByNpubHex[npubHex] != null
    }

    private fun canUseDirectNip17(peerId: String, npubRaw: ByteArray): Boolean =
        !socialState.isBlockedNostr(npubRaw.toHexLower()) &&
            meshAliasGroupIsMutualFavorite(peerId)

    private fun meshAliasGroupIsMutualFavorite(peerId: String): Boolean =
        aliasesHaveMutualFavorite(
            aliases = meshPeerAliases(peerId),
            isFavorite = socialState::isFavoritePeer,
            isRemoteFavorite = socialState::isRemoteFavoritePeer,
        )

    private suspend fun sendDirectNip17Now(
        peerId: String,
        npubRaw: ByteArray,
        messageId: String,
        text: String,
    ): Boolean {
        return try {
            runMarmotAccountOperation {
                SonarCore.sendDirectDm(
                    recipientHex = npubRaw.toHexLower(),
                    senderPeerIdHex = MeshRadio.localPeerIdHex(),
                    recipientPeerIdHex = "",
                    messageId = messageId,
                    text = text,
                )
            }
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
     *  [flushPendingMarmot] once the group appears in [chats]. Each entry keeps
     *  the mesh chat id + optimistic echo id so the bubble paints immediately
     *  (same shape as [sendPendingMarmotChat]) instead of waiting on startChat. */
    private val pendingMarmotSends = mutableMapOf<String, MutableList<PendingMeshMarmotSend>>()
    /** One owner per peer keeps the failed head ahead of sends appended while
     * its core call was in flight. Both maps are joined before deletion. */
    private val pendingMarmotFlushJobs = mutableMapOf<String, Job>()
    private val startingMarmotChatJobs = mutableMapOf<String, Job>()
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
    private data class PendingMeshMarmotSend(
        val meshChatId: String,
        val text: String,
        val echoId: String,
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

    private suspend fun cancelPendingMarmotSetups() {
        val jobs = pendingMarmotSetupJobs.values.toList()
        jobs.forEach { it.cancel() }
        jobs.forEach { it.join() }
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

    private suspend fun cancelPendingMarmotGroupSetups() {
        val jobs = pendingMarmotGroupSetupJobs.values.toList()
        jobs.forEach { it.cancel() }
        jobs.forEach { it.join() }
        pendingMarmotGroupSetupJobs.clear()
        pendingMarmotGroupSetupTokens.clear()
    }

    /** Cancellation is joined before any host/core state is erased. A core
     * send already inside FFI may not be interruptible, so clearing first and
     * merely cancelling would still let that old plaintext publish afterward. */
    private suspend fun cancelPendingMarmotPeerDeliveryJobs(onSuspended: () -> Unit = {}): Long {
        val generation = ++marmotAccountGeneration
        marmotAccountMutationSuspended = true
        // Invalidate accepted GATT deliveries immediately after the account
        // gate closes, before awaiting any non-cancellable core operation.
        onSuspended()
        val setupPeers = startingMarmotChatJobs.keys.toSet()
        val jobs = (
            pendingMarmotFlushJobs.values +
                startingMarmotChatJobs.values +
                outboxFlushJobs.values
            ).distinct()
        jobs.forEach { it.cancel() }
        jobs.forEach { it.join() }
        pendingMarmotFlushJobs.clear()
        startingMarmotChatJobs.clear()
        outboxFlushJobs.clear()
        flushingOutboxPeers.clear()
        startingMarmotChats.removeAll(setupPeers)
        pendingMarmotSends.clear()
        // Join any direct/receipt send that was already inside the serialized
        // FFI section. Older waiters observe the generation change and abort.
        marmotSendMutex.withLock {}
        return generation
    }

    private fun resumePendingMarmotPeerDelivery(generation: Long) {
        if (marmotAccountGeneration == generation) {
            marmotAccountMutationSuspended = false
        }
    }

    // ── Outbox: per-peer message queue for offline/unreachable peers ──
    // Mirrors iOS MessageRouter outbox. When neither BLE mesh link nor npub is
    // available, messages are queued here instead of being dropped. Flushed
    // automatically when the peer reconnects over BLE or their npub is learned.
    private val outbox = SonarOutbox()
    private val flushingOutboxPeers = mutableSetOf<String>()
    private val outboxFlushJobs = mutableMapOf<String, Job>()
    private val mediaOutbox = SonarMediaOutbox()
    private val flushingMediaOutboxPeers = mutableSetOf<String>()

    /** Continue a Sonar-peer conversation over White Noise (Marmot) when out of
     *  Bluetooth range, creating the 1:1 group on first send (mirrors iOS
     *  `sendOverMarmot`).
     *
     *  Always paint an optimistic echo on the mesh chat id first. Clearing the
     *  echo before [refreshOpenDm] can merge the White Noise canonical row made
     *  the bubble vanish for a couple of seconds ("Sending · internet" gap). */
    private fun sendOverMarmot(peerId: String, npubRaw: ByteArray, text: String) {
        val chatId = meshChatId(peerId)
        val group = marmotGroupForNpub(npubRaw)
        if (group != null) {
            val echo = createSendEcho(chatId, text)
            messages = (messages + echo).sortedBy { it.tsSecs }
            scope.launch {
                runMarmotSendWithBestEffortReconciliation(
                    send = { sendMarmotTextOrdered(group.id, text) },
                    onSendAccepted = { markSendEchoAccepted(chatId, echo.id) },
                    reconcile = { reconcileMeshMarmotSendEcho(peerId, chatId, echo) },
                    onSendFailure = { error ->
                        failSendEcho(chatId, echo.id)
                        toast = "send failed: ${error.message}"
                    },
                    onReconciliationFailure = { markSendEchoAccepted(chatId, echo.id) },
                )
            }
            return
        }
        val echo = createSendEcho(chatId, text)
        messages = (messages + echo).sortedBy { it.tsSecs }
        val npubHex = npubRaw.toHexLower()
        pendingMarmotSends.getOrPut(npubHex) { mutableListOf() }
            .add(PendingMeshMarmotSend(meshChatId = chatId, text = text, echoId = echo.id))
        toast = "Out of range — continuing over White Noise…"
        startMarmotChatForPendingPeer(npubHex, peerId)
    }

    private fun sendStickerOverMarmot(
        peerId: String, npubRaw: ByteArray,
        packCoordinate: String, sticker: SonarStickerItem,
    ) {
        val chatId = meshChatId(peerId)
        val encoded = meshStickerContent(packCoordinate, sticker.shortcode, sticker.sha256)
        val group = marmotGroupForNpub(npubRaw)
        if (group != null) {
            val echo = createSendEcho(chatId, encoded)
            messages = (messages + echo).sortedBy { it.tsSecs }
            scope.launch {
                runMarmotSendWithBestEffortReconciliation(
                    send = {
                        sendMarmotStickerOrdered(group.id, packCoordinate, sticker.shortcode, sticker.sha256)
                    },
                    onSendAccepted = { markSendEchoAccepted(chatId, echo.id) },
                    reconcile = { reconcileMeshMarmotSendEcho(peerId, chatId, echo) },
                    onSendFailure = { error ->
                        failSendEcho(chatId, echo.id)
                        toast = "send failed: ${error.message}"
                    },
                    onReconciliationFailure = { markSendEchoAccepted(chatId, echo.id) },
                )
            }
            return
        }
        val echo = createSendEcho(chatId, encoded)
        messages = (messages + echo).sortedBy { it.tsSecs }
        val npubHex = npubRaw.toHexLower()
        pendingMarmotSends.getOrPut(npubHex) { mutableListOf() }
            .add(PendingMeshMarmotSend(meshChatId = chatId, text = encoded, echoId = echo.id))
        toast = "Out of range — continuing over White Noise…"
        startMarmotChatForPendingPeer(npubHex, peerId)
    }

    private fun startMarmotChatForPendingPeer(npubHex: String, peerId: String) {
        if (marmotAccountMutationSuspended) return
        if (startingMarmotChatJobs[npubHex]?.isActive == true) return
        if (!startingMarmotChats.add(npubHex)) return
        val generation = marmotAccountGeneration
        val job = scope.launch {
            try {
                if (!awaitRelayConnection()) {
                    failPendingMeshMarmotSends(npubHex)
                    return@launch
                }
                if (marmotAccountMutationSuspended || marmotAccountGeneration != generation) return@launch
                runMarmotAccountOperation { SonarCore.startChat(npubHex) } // start_dm accepts a hex pubkey
                refreshChats()
                flushPendingMarmot()
                flushOutbox(peerId)
                refreshOpenDm(peerId)
            } catch (error: CancellationException) {
                // A wipe/erase cancels this job and joins it; letting the
                // catch-all below swallow it would report a fake chat failure.
                throw error
            } catch (e: Throwable) {
                failPendingMeshMarmotSends(npubHex)
                toast = "couldn't start secure chat: ${e.message}"
            } finally {
                val owner = currentCoroutineContext()[Job]
                if (startingMarmotChatJobs[npubHex] === owner) {
                    startingMarmotChatJobs.remove(npubHex)
                }
                startingMarmotChats.remove(npubHex)
            }
        }
        startingMarmotChatJobs[npubHex] = job
    }

    private fun failPendingMeshMarmotSends(npubHex: String) {
        val pending = pendingMarmotSends.remove(npubHex).orEmpty()
        for (send in pending) {
            failSendEcho(send.meshChatId, send.echoId)
        }
    }

    private suspend fun reconcileMeshMarmotSendEcho(
        peerId: String,
        chatId: String,
        echo: SonarMsg,
    ) {
        val refreshGeneration = transcriptGeneration
        val published = mergePendingMediaUploads(
            chatId,
            marmotMessagesForPeer(peerId, chatId, refreshGeneration),
        )
        val hasCanonicalRow = reserveSuccessfulEchoCanonicalRows(chatId, echo, published)
        if (!hasCanonicalRow) {
            markSendEchoAccepted(chatId, echo.id)
        }
        refreshOpenDm(peerId)
        if (shouldClearMeshMarmotSendEcho(hasCanonicalRow)) {
            clearSendEcho(chatId, echo.id)
            refreshOpenDm(peerId)
        }
        processPayLines(chatId, messages)
    }

    private fun flushPendingMarmot() {
        if (marmotAccountMutationSuspended || pendingMarmotSends.isEmpty()) return
        for ((npubHex, sends) in pendingMarmotSends.toMap()) {
            if (socialState.isBlockedNostr(npubHex)) continue
            if (pendingMarmotFlushJobs[npubHex]?.isActive == true) continue
            val group = marmotGroupForNpub(npubHex.hexToBytesOrEmpty()) ?: continue
            pendingMarmotSends.remove(npubHex)
            val job = scope.launch {
                var drainedQueueEmpty = false
                try {
                    for (send in sends) {
                        val peerId = meshPeerId(send.meshChatId)
                        val echo = pendingSendEchoes[send.meshChatId]
                            ?.firstOrNull { it.id == send.echoId }
                        runMarmotSendWithBestEffortReconciliation(
                            send = { sendQueuedMarmotContent(group.id, send.text) },
                            onSendAccepted = {
                                if (echo != null) markSendEchoAccepted(send.meshChatId, echo.id)
                            },
                            reconcile = {
                                if (echo != null) {
                                    reconcileMeshMarmotSendEcho(peerId, send.meshChatId, echo)
                                } else {
                                    refreshOpenDm(peerId)
                                }
                            },
                            onSendFailure = { error ->
                                if (echo != null) failSendEcho(send.meshChatId, echo.id)
                                toast = "send failed: ${error.message}"
                            },
                            onReconciliationFailure = {
                                if (echo != null) markSendEchoAccepted(send.meshChatId, echo.id)
                            },
                        )
                    }
                } finally {
                    val owner = currentCoroutineContext()[Job]
                    if (pendingMarmotFlushJobs[npubHex] === owner) {
                        pendingMarmotFlushJobs.remove(npubHex)
                        // Job.isActive is still true while this finally runs, so a
                        // send enqueued during the drain was skipped by
                        // flushPendingMarmot and left with no owner. Re-arm now.
                        // Unconditionally safe in this shape: the snapshot was
                        // removed up front and a failed send marks its echo
                        // "Couldn't send" instead of being requeued, so the
                        // re-arm cannot spin on a permanently failing head.
                        if (!pendingMarmotSends[npubHex].isNullOrEmpty()) flushPendingMarmot()
                    }
                }
            }
            pendingMarmotFlushJobs[npubHex] = job
        }
    }

    // ── Outbox queue (mirrors iOS MessageRouter outbox) ──

    /** Queue a message for [peerId] when no transport is available. Enforces
     *  per-peer size limit (FIFO eviction) matching iOS behaviour. Pass the
     *  same [messageId] used by [echoMeshMessage] so [flushOutboxNow] delivers
     *  via BLE without creating a duplicate transcript row. A re-entering BLE
     *  send failure passes the original [timestampSecs] so the requeued row
     *  keeps its place in the transcript instead of jumping to now. */
    private fun enqueueOutbox(
        peerId: String,
        text: String,
        messageId: String,
        timestampSecs: Long = SonarClock.nowSecs(),
    ) {
        val result = outbox.enqueue(peerId, text, messageId, timestampSecs)
        result.evicted?.let { evicted ->
            failMeshEcho(peerId, evicted.messageId)
            sonarLog("SonarOutbox", "overflow for ${peerId.take(10)}… — evicted oldest id=${evicted.messageId.take(8)}…")
        }
        sonarLog("SonarOutbox", "queued for ${peerId.take(10)}… id=${result.message.messageId.take(8)}… queue=${result.depth}")
    }

    /** Try to deliver all queued messages for [peerId]. Expired messages (>24h)
     *  are silently dropped. Messages that still can't be sent remain queued. */
    private fun flushOutbox(peerId: String) {
        if (marmotAccountMutationSuspended || !outbox.contains(peerId) || !flushingOutboxPeers.add(peerId)) return
        val job = scope.launch {
            try {
                flushOutboxNow(peerId)
            } finally {
                val owner = currentCoroutineContext()[Job]
                if (outboxFlushJobs[peerId] === owner) {
                    outboxFlushJobs.remove(peerId)
                    flushingOutboxPeers.remove(peerId)
                }
            }
        }
        outboxFlushJobs[peerId] = job
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
                // Pass the existing messageId so sendMesh skips echo creation
                // (the echo was already created by echoMeshMessage in sendDmAuto).
                sendMesh(routePeerId, msg.content, msg.messageId)
            } else {
                val raw = npubRawFor(peerId)
                if (raw != null) {
                    when {
                        shouldUseMarmotRoute(peerId, raw) -> {
                            val groupId = marmotGroupId ?: ensureMarmotGroupForOutbox(peerId, raw)
                            marmotGroupId = groupId
                            val marmotOk = groupId != null && sendOutboxOverMarmot(peerId, groupId, msg.content)
                            if (marmotOk && groupId != null) {
                                // Reconcile: poll for the canonical Marmot row before
                                // removing the echo. Durable — if the process dies during
                                // polling, the echo survives in persisted meshChats rather
                                // than leaving a permanent duplicate from a blind delay.
                                val chatId = meshChatId(canonicalMeshPeerId(peerId))
                                scope.launch {
                                    for (i in 0 until MARMOT_ECHO_RECONCILE_MAX_ATTEMPTS) {
                                        delay(MARMOT_ECHO_RECONCILE_POLL_MS)
                                        val canonicalExists = marmotMessagesForPeer(
                                            peerId, chatId, transcriptGeneration
                                        ).any { it.content == msg.content && it.senderNpub == npub }
                                        if (canonicalExists) {
                                            removeMeshEcho(peerId, msg.messageId)
                                            return@launch
                                        }
                                    }
                                    // Row not found after max attempts — keep echo (sticky > gap)
                                }
                            }
                            marmotOk
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
        if (!SonarCore.isRelayConnected()) {
            startRelayConnection()
            return null
        }
        val npubHex = npubRaw.toHexLower()
        return try {
            refreshChats()
            marmotGroupForNpub(npubRaw)?.id ?: run {
                if (!startingMarmotChats.add(npubHex)) return null
                try {
                    runMarmotAccountOperation { SonarCore.startChat(npubHex) }.also {
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
            // Sticker control payloads must become a Marmot sticker event, not
            // leak into the transcript as their raw mesh control string.
            sendQueuedMarmotContent(groupId, text)
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
        meshEchoIds.remove(queued.messageId) // delivered over NIP-17; no longer pending
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

    /** Flush media outbox for ALL peers that now have a reachable transport.
     *  Mirrors [flushAllOutbox] so queued images retry on relay/Marmot route
     *  availability, not only on BLE reconnect. */
    private fun flushAllMediaOutbox() {
        if (mediaOutbox.isEmpty()) return
        for (peerId in mediaOutbox.peerIds()) {
            flushMediaOutbox(peerId)
        }
    }

    // ── Media outbox: per-peer image/attachment retry queue ──
    // Mirrors [flushOutbox] but rehydrates raw bytes from the media cache /
    // file-backed store (the outbox holds metadata only, never bytes).

    /** Try to deliver all queued media for [peerId]. Expired items (>24h) or
     *  items whose bytes were evicted from local storage are silently dropped.
     *  Items that still can't be sent remain queued. */
    private fun flushMediaOutbox(peerId: String) {
        if (!mediaOutbox.contains(peerId) || !flushingMediaOutboxPeers.add(peerId)) return
        scope.launch {
            try {
                flushMediaOutboxNow(peerId)
            } finally {
                flushingMediaOutboxPeers.remove(peerId)
            }
        }
    }

    private suspend fun flushMediaOutboxNow(peerId: String) {
        val queue = mediaOutbox.snapshot(peerId)
        if (queue.isEmpty()) { mediaOutbox.finishFlush(peerId, 0, emptyList()); return }
        if (isMeshContactBlocked(peerId)) {
            sonarLog("SonarMediaOutbox", "paused blocked outbox peer=${peerId.take(10)}…")
            return
        }
        val now = SonarClock.nowSecs()
        val remaining = mutableListOf<QueuedMedia>()
        var marmotGroupId: String? = null

        sonarLog("SonarMediaOutbox", "flushing ${queue.size} media item(s) for ${peerId.take(10)}…")

        for ((index, item) in queue.withIndex()) {
            // TTL check: drop media older than 24 hours.
            if (mediaOutbox.isExpired(item, now)) {
                sonarLog("SonarMediaOutbox", "expired media id=${item.messageId.take(8)}… age=${now - item.timestampSecs}s")
                continue
            }
            // Raw bytes are NOT stored in the outbox — rehydrate from the
            // in-memory cache (≤1 MB) or the file-backed MessageStore.
            val data = mediaCache[item.mediaUrl] ?: MessageStore.loadMeshMedia(item.mediaUrl)
            if (data == null) {
                sonarLog("SonarMediaOutbox", "missing bytes for id=${item.messageId.take(8)}… — dropping")
                continue
            }
            val routePeerId = liveMeshRoutePeerId(peerId)
            val delivered = if (routePeerId != null) {
                // Pass the existing messageId so the receiver deduplicates the
                // echo that was already created by echoMeshMedia.
                MeshRadio.sendMeshMedia(routePeerId, item.messageId, data, item.filename, item.mime)
            } else {
                val raw = npubRawFor(peerId)
                if (raw != null && shouldUseMarmotRoute(peerId, raw)) {
                    val groupId = marmotGroupId ?: ensureMarmotGroupForOutbox(peerId, raw)
                    marmotGroupId = groupId
                    val marmotOk = groupId != null &&
                        sendMediaOutboxOverMarmot(peerId, groupId, data, item.filename, item.mime)
                    if (marmotOk) {
                        // Marmot delivery creates its own row with a different ID;
                        // remove the mesh echo to avoid a duplicate in the merged view.
                        removeMeshEcho(peerId, item.messageId)
                    }
                    marmotOk
                } else {
                    false
                }
            }
            if (!delivered) {
                remaining.addAll(mediaOutbox.remainingAfterFailure(queue, index, now))
                sonarLog("SonarMediaOutbox", "kept ${remaining.size} media item(s) queued for ${peerId.take(10)}…")
                break
            }
            sonarLog("SonarMediaOutbox", "delivered media id=${item.messageId.take(8)}… to ${peerId.take(10)}…")
        }

        mediaOutbox.finishFlush(peerId, queue.size, remaining)
    }

    private suspend fun sendMediaOutboxOverMarmot(
        peerId: String,
        groupId: String,
        data: ByteArray,
        filename: String,
        mime: String,
    ): Boolean {
        if (isMeshContactBlocked(peerId)) return false
        return try {
            val clientPendingId = "outbox-media-${randomMeshId()}"
            SonarCore.sendMediaWithProgress(
                groupId,
                data,
                filename,
                mime,
                "",
                clientPendingId,
                MediaUploadControl { _, _ -> },
            )
            refreshOpenDm(peerId)
            true
        } catch (e: Throwable) {
            sonarLog("SonarMediaOutbox", "failed to send queued media over White Noise for ${peerId.take(10)}… err=${e.message}")
            false
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
            if (!awaitRelayConnection()) return@launch
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

    /** Content from the system share sheet awaiting a recipient. */
    internal var pendingShare: SharedContent? by mutableStateOf(null)
        private set

    /**
     * Shares that arrived while another was still being resolved. iOS keeps
     * these as committed payloads in its App Group inbox and takes them
     * oldest-first; this is the in-memory equivalent, so a second ACTION_SEND
     * cannot destroy the first.
     */
    private val queuedShares = ArrayDeque<SharedContent>()

    /**
     * Route content shared into Sonar to the recipient picker.
     *
     * This used to drop the shared text into the Search *query field*, which
     * looked like a search for the link rather than a way to send it, and had
     * no path at all for files.
     */
    internal fun handleSharedContent(content: SharedContent) {
        // A Sonar invite link shared back into Sonar means "join", not "send".
        val token = content.text?.let { INVITE_TOKEN_IN_TEXT.find(it)?.value }
        if (token != null && content.files.files.isEmpty()) {
            requestJoinViaLink(token)
            return
        }
        if (content.isEmpty) {
            toast = if (content.files.rejectedCount > 0) {
                "Couldn't attach that file."
            } else {
                "Nothing to share."
            }
            return
        }
        if (pendingShare != null) {
            // A picker is already up — queue behind it rather than replacing it.
            queuedShares.addLast(content)
            return
        }
        pendingShare = content
        // Never stack two ShareTo pickers: a second share arriving while one is
        // already up would leave a stale ShareTo behind after sendPendingShare's
        // single back(). Drop any existing ShareTo entries before pushing.
        if (stack.any { it is Screen.ShareTo }) {
            stack = stack.filterNot { it is Screen.ShareTo }
        }
        push(Screen.ShareTo)
    }

    fun cancelPendingShare() {
        markShareResolved(pendingShare)
        pendingShare = null
        promoteQueuedShare()
    }

    /**
     * Record durably that the user resolved this share, so a task restored
     * after process death recognises the redelivered intent instead of
     * offering it again.
     *
     * Written at RESOLUTION, never at hand-off: a process killed while the
     * picker was still open must re-offer the share, because `pendingShare`
     * itself does not survive that death.
     */
    private fun markShareResolved(content: SharedContent?) {
        content?.consumedMarker?.let { SonarCore.saveBlob(CONSUMED_SHARE_BLOB_KEY, it) }
    }

    /** Record that this share's TEXT is spoken for, while its files may not be. */
    private fun markShareTextSent(content: SharedContent) {
        content.consumedMarker?.let { SonarCore.saveBlob(CONSUMED_SHARE_TEXT_BLOB_KEY, it) }
    }

    /** Promote the next queued share, if any, once the current one resolves. */
    private fun promoteQueuedShare() {
        if (pendingShare != null) return
        val next = queuedShares.removeFirstOrNull() ?: return
        pendingShare = next
        if (screen !is Screen.ShareTo) push(Screen.ShareTo)
    }

    /**
     * Send the pending share into [chatId], then open that chat.
     *
     * Text goes first so a link with attachments reads as a caption above its
     * files, matching the order a composer send produces.
     */
    fun sendPendingShare(chatId: String, open: () -> Unit) {
        val content = pendingShare ?: return
        pendingShare = null
        // Picking a recipient makes the TEXT unrepeatable: a process death
        // mid-send must not let the restored intent re-deliver text that
        // already went out. The share as a whole is only "resolved" once its
        // files finish too — see markShareResolved below — because a route
        // failure must still re-offer the files for retry.
        markShareTextSent(content)
        // Leave the picker before opening the chat so Back from the chat lands
        // on Home rather than re-showing the resolved share.
        back()
        open()
        content.text?.takeIf { it.isNotBlank() }?.let { send(chatId, it) }
        if (content.files.files.isNotEmpty()) {
            sendDroppedAttachments(
                chatId,
                content.files,
                onRouteReady = { markShareResolved(content) },
            ) {
                // Transient route failure (out-of-range mesh peer, failed
                // secure-chat setup). Keep the files and reopen the picker so
                // the user can retry — the picker deliberately lists
                // out-of-range rows, so this is reachable by design. Apple does
                // the same in `SonarShareIntake.sendPendingShare`.
                //
                // Text is dropped from the retry: it was already sent above,
                // and re-offering it would deliver it twice. The share is left
                // NOT marked resolved so a process death here still re-offers
                // the files.
                //
                // This callback is async and fires AFTER promoteQueuedShare()
                // below has possibly installed the next queued share, so it must
                // never assign `pendingShare` blind — doing so would destroy that
                // share, which is the very bug the queue exists to prevent. The
                // retry goes to the HEAD of the queue because it is older than
                // whatever was promoted.
                val retry = content.copy(text = null)
                if (pendingShare != null) {
                    queuedShares.addFirst(retry)
                } else {
                    pendingShare = retry
                    if (screen !is Screen.ShareTo) push(Screen.ShareTo)
                }
            }
        } else {
            // No files pending — the share is fully resolved.
            markShareResolved(content)
            if (content.files.rejectedCount > 0) {
                toast = "Some files couldn't be attached."
            }
        }
        // Promote the next queued share once this one has been dispatched.
        // sendDroppedAttachments is async; its route-failure callback assigns
        // pendingShare itself, and this runs before that callback, so the
        // guard here keeps them from fighting over the slot.
        promoteQueuedShare()
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

    private suspend fun latestCursorPage(groupId: String): List<SonarMsg>? = runCatching {
        SonarCore.messagesCursorPage(
            chatId = groupId,
            beforeSecs = null,
            beforeIdHex = null,
            limit = TRANSCRIPT_PAGE_FETCH_SIZE,
        )
    }.getOrNull()

    /** Refresh the newest local rows without replacing pages already prepended. */
    private suspend fun refreshTranscriptGroupWindow(
        groupId: String,
        sessionChatId: String,
        generation: Long,
    ): List<SonarMsg> {
        val fetched = latestCursorPage(groupId)
        val untrusted = transcriptReadIsUntrusted(fetched, started, localLatestTs(groupId))
        if (!isCurrentTranscriptSession(sessionChatId, generation)) {
            return when {
                untrusted -> chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(TRANSCRIPT_PAGE_SIZE)
                else -> visibleTranscriptPage(fetched.orEmpty())
            }
        }

        val current = transcriptWindows[groupId]
        if (untrusted) {
            // Keep whatever is already painted; only fall through to the
            // snapshot when there is nothing to keep.
            if (current != null && current.rows.isNotEmpty()) return current.rows
            val fallback = chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(TRANSCRIPT_PAGE_SIZE)
            // Never cache an empty window. A cached blank is indistinguishable
            // from a real one at the `current != null` check above, so it would
            // shadow the store on every later refresh and pin the chat black.
            if (fallback.isNotEmpty()) {
                transcriptWindows[groupId] = TranscriptGroupWindow(fallback, hasMore = false)
            }
            return fallback
        }
        // Trusted from here: `untrusted` already covered null and the ambiguous
        // empty page, so an empty list now means the conversation really is empty.
        val page = fetched.orEmpty()

        val newest = visibleTranscriptPage(page)
        // Remember the freshly read page before any pinned/bounded filtering can
        // drop it: send-echo reconciliation must still see an outgoing row that
        // the render window refuses to admit.
        freshCanonicalByGroup[groupId] = newest
        val unboundedCount = (current?.rows.orEmpty() + newest).distinctBy { it.id }.size
        val merged = refreshTranscriptRows(
            existing = current?.rows.orEmpty(),
            newest = newest,
            pinnedToOlderEdge = current?.pinnedToOlderEdge == true,
        )
        val hasMore = when {
            unboundedCount > TRANSCRIPT_RETAINED_ROWS -> true
            current != null -> current.hasMore || page.size > TRANSCRIPT_PAGE_SIZE
            else -> page.size > TRANSCRIPT_PAGE_SIZE
        }
        transcriptWindows[groupId] = TranscriptGroupWindow(
            rows = merged,
            hasMore = hasMore,
            loadingOlder = current?.loadingOlder == true,
            pinnedToOlderEdge = current?.pinnedToOlderEdge == true,
        )
        return merged
    }

    private suspend fun marmotMessagesPage(groupId: String): List<SonarMsg> {
        val loaded = runCatching {
            SonarCore.messagesPage(groupId, BACKGROUND_TRANSCRIPT_SCAN_LIMIT)
        }.getOrNull()
        if (!started && loaded.isNullOrEmpty()) {
            return chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(BACKGROUND_TRANSCRIPT_SCAN_LIMIT)
        }
        return loaded ?: chatSnapshotMessagesByChat[groupId].orEmpty().takeLast(BACKGROUND_TRANSCRIPT_SCAN_LIMIT)
    }

    /** True when local metadata remembers messages for this conversation, even
     *  if the encrypted store cannot be read right now. Survives a cold launch,
     *  so it is the signal that a blank transcript is wrong rather than empty. */
    private fun transcriptKnownNonEmpty(chatId: String): Boolean =
        localLatestTs(chatId) > 0L || transcriptGroupIds(chatId).any { localLatestTs(it) > 0L }

    /** Whether this conversation's transport legs are known yet. A mesh route
     *  resolves its folded White Noise groups through `chats` / `npubRawFor`,
     *  neither of which is populated on a cold launch; a plain Marmot chat id is
     *  its own source, so it is always resolved. */
    private fun transcriptSourcesResolved(chatId: String): Boolean =
        !isMeshChat(chatId) || transcriptGroupIds(chatId).isNotEmpty()

    /**
     * The same local rows the open path would read for [chatId].
     *
     * A mesh conversation's id is a route id (`mesh:<peerId>`), not a Marmot
     * group id, so it cannot be handed to [marmotMessagesPageForChat] — that
     * would query a group that does not exist and answer "no messages" forever.
     * Mirror `openDm`: merge the BLE window with the folded White Noise leg.
     */
    private suspend fun localTranscriptRowsForChat(
        chatId: String,
        generation: Long,
    ): List<SonarMsg> {
        if (!isMeshChat(chatId)) return marmotMessagesPageForChat(chatId, generation)
        val peerId = canonicalMeshPeerId(meshPeerId(chatId))
        val mesh = refreshMeshTranscriptWindow(peerId)
        val wn = marmotMessagesForPeer(peerId, chatId, generation)
        return refreshConversationRows(mesh + wn, chatId, generation)
    }

    /**
     * Re-read local storage for a transcript that opened blank on a conversation
     * we know has messages.
     *
     * The store can be briefly unreadable (core still booting after a cold
     * launch, node being replaced), and the open path has no way to wait for it
     * without holding the user on Home. Without this, the chat sits black until
     * an unrelated sync event happens to repaint it — the reported "black screen,
     * then the bubbles appear after a while".
     *
     * Bounded and local-only by construction: it re-reads the same local rows
     * the open used ([localTranscriptRowsForChat], so mesh conversations resolve
     * their own sources), never touches relay/sync, and stops at the first
     * non-empty read, on session change, or after
     * [BLANK_TRANSCRIPT_RETRY_BUDGET_MS].
     */
    private fun scheduleBlankTranscriptRecovery(chatId: String, generation: Long) {
        val shouldRecover = shouldRecoverBlankTranscript(
            knownNonEmpty = transcriptKnownNonEmpty(chatId),
            coreStarted = started,
            sourcesResolved = transcriptSourcesResolved(chatId),
        )
        if (!shouldRecover) return
        scope.launch {
            var waitedMs = 0L
            var stepMs = BLANK_TRANSCRIPT_RETRY_START_MS
            while (waitedMs < BLANK_TRANSCRIPT_RETRY_BUDGET_MS) {
                delay(stepMs)
                waitedMs += stepMs
                stepMs = (stepMs * 2).coerceAtMost(BLANK_TRANSCRIPT_RETRY_MAX_STEP_MS)
                if (!isCurrentTranscriptSession(chatId, generation)) return@launch
                // Someone else (sync drain, send echo) already painted it.
                if (messages.isNotEmpty()) return@launch
                val local = withSendEchoes(
                    chatId,
                    mergePendingMediaUploads(chatId, localTranscriptRowsForChat(chatId, generation)),
                )
                val visible = visibleMessagesForChat(chatId, local)
                if (visible.isEmpty()) {
                    // Rows exist but the social filter hides all of them (blocked
                    // contact). The store answered — retrying cannot change it.
                    if (local.isNotEmpty()) return@launch
                    continue
                }
                if (!isCurrentTranscriptSession(chatId, generation)) return@launch
                publishOpenTranscript(chatId, visible)
                markTranscriptHydrated(chatId)
                return@launch
            }
        }
    }

    private suspend fun marmotMessagesPageForChat(
        chatId: String,
        generation: Long = transcriptGeneration,
    ): List<SonarMsg> {
        val groups = duplicateDirectMarmotChats(chatId)
        if (groups.isEmpty()) {
            return refreshConversationRows(
                refreshTranscriptGroupWindow(chatId, chatId, generation),
                chatId,
                generation,
            )
        }
        val merged = ArrayList<SonarMsg>()
        for (group in groups) {
            merged += refreshTranscriptGroupWindow(group.id, chatId, generation)
        }
        return refreshConversationRows(merged, chatId, generation)
    }

    private suspend fun marmotMessagesForPeer(
        peerId: String,
        sessionChatId: String,
        generation: Long,
    ): List<SonarMsg> {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        val aliases = meshPeerAliases(canonicalPeerId)
        val groups = npubRawFor(canonicalPeerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
        val merged = ArrayList<SonarMsg>()
        for (group in groups) {
            val msgs = refreshTranscriptGroupWindow(group.id, sessionChatId, generation)
            merged += msgs.map { it.copy(viaInternet = true) }
        }
        return mergeAllTranscriptRows(merged)
    }

    private fun refreshConversationRows(
        source: List<SonarMsg>,
        chatId: String,
        generation: Long,
    ): List<SonarMsg> {
        val merged = mergeAllTranscriptRows(source)
        if (!isCurrentTranscriptSession(chatId, generation)) {
            return boundedTranscriptRows(merged, TRANSCRIPT_PAGE_SIZE, pinnedToOlderEdge = false)
        }
        conversationTranscriptRows = if (conversationTranscriptRows.isEmpty()) {
            boundedTranscriptRows(merged, conversationVisibleRowLimit, conversationPinnedToOlderEdge)
        } else {
            refreshTranscriptRows(
                existing = conversationTranscriptRows,
                newest = merged,
                pinnedToOlderEdge = conversationPinnedToOlderEdge,
                retainedRows = conversationVisibleRowLimit,
                pinOlderEdgeAtCapacity = !conversationPinnedToOlderEdge &&
                    conversationVisibleRowLimit >= TRANSCRIPT_RETAINED_ROWS,
            )
        }
        if (!conversationPinnedToOlderEdge &&
            conversationVisibleRowLimit >= TRANSCRIPT_RETAINED_ROWS &&
            shouldPinOlderTranscriptEdge(conversationTranscriptRows.size)
        ) {
            pinConversationToOlderEdge()
        }
        return conversationTranscriptRows
    }

    private fun pinConversationToOlderEdge() {
        conversationPinnedToOlderEdge = true
        meshTranscriptPinnedToOlderEdge = true
        for (groupId in transcriptWindows.keys.toList()) {
            val window = transcriptWindows[groupId] ?: continue
            transcriptWindows[groupId] = window.copy(pinnedToOlderEdge = true)
        }
    }

    /** Select only the closest globally older page, even when every folded source fetched 30 rows. */
    private fun prependConversationRows(source: List<SonarMsg>): Boolean {
        val merged = mergeAllTranscriptRows(source)
        val current = conversationTranscriptRows
        if (current.isEmpty()) {
            conversationTranscriptRows = boundedTranscriptRows(
                merged,
                conversationVisibleRowLimit,
                pinnedToOlderEdge = false,
            )
            return conversationTranscriptRows.isNotEmpty()
        }
        val oldest = current.first()
        val nearestOlder = nearestOlderTranscriptPage(merged, oldest)
        if (nearestOlder.isEmpty()) return false

        conversationVisibleRowLimit =
            (conversationVisibleRowLimit + TRANSCRIPT_PAGE_SIZE).coerceAtMost(TRANSCRIPT_RETAINED_ROWS)
        conversationTranscriptRows = prependTranscriptRows(
            existing = current,
            older = nearestOlder,
            retainedRows = conversationVisibleRowLimit,
        )
        if (shouldPinOlderTranscriptEdge(conversationTranscriptRows.size)) {
            // A folded source must not keep moving its own cursor toward live
            // rows while the conversation-wide window stays on older history.
            // Pin every source in the same transition; newest reload resets all
            // of them through beginTranscriptSession().
            pinConversationToOlderEdge()
        }
        return true
    }

    private fun transcriptGroupIds(chatId: String): List<String> {
        if (!isMeshChat(chatId)) return directMarmotChatIds(chatId).distinct()
        val peerId = canonicalMeshPeerId(meshPeerId(chatId))
        val aliases = meshPeerAliases(peerId)
        val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
        return groups.map { it.id }.distinct()
    }

    /** Keep only the active viewport's BLE history; the complete transcript remains in MessageStore. */
    private fun refreshMeshTranscriptWindow(peerId: String): List<SonarMsg> {
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        val mergedAliases = mergedMeshMessages(canonicalPeerId)
        val activeSessionChatId = activeTranscriptChatId
        val activePeerId = activeSessionChatId
            ?.takeIf(::isMeshChat)
            ?.let(::meshPeerId)
        if (activePeerId == null ||
            !sameMeshConversationIdentity(activePeerId, canonicalPeerId, linkByFp)
        ) {
            return mergedAliases.takeLast(TRANSCRIPT_PAGE_SIZE)
        }
        val newest = mergedAliases.takeLast(TRANSCRIPT_PAGE_SIZE)
        meshTranscriptRows = refreshTranscriptRows(
            existing = meshTranscriptRows,
            newest = newest,
            pinnedToOlderEdge = meshTranscriptPinnedToOlderEdge,
        )
        val oldestId = meshTranscriptRows.firstOrNull()?.id
        meshTranscriptHasMore = oldestId != null &&
            mergedAliases.indexOfFirst { it.id == oldestId } > 0
        return meshTranscriptRows
    }

    /** Move the BLE window toward older rows, evicting its newer edge at the 500-row cap. */
    private fun prependOlderMeshRows(peerId: String): Boolean {
        val allRows = mergedMeshMessages(canonicalMeshPeerId(peerId))
            .sortedWith(compareBy<SonarMsg>({ it.tsSecs }, { it.id }))
        val current = if (meshTranscriptRows.isEmpty()) refreshMeshTranscriptWindow(peerId) else meshTranscriptRows
        val oldest = current.firstOrNull() ?: return false
        val cursorIndex = allRows.indexOfFirst { it.id == oldest.id }
        if (cursorIndex <= 0) {
            meshTranscriptHasMore = false
            return false
        }
        val pageStart = (cursorIndex - TRANSCRIPT_PAGE_SIZE).coerceAtLeast(0)
        val older = allRows.subList(pageStart, cursorIndex)
        val trimsNewerEdge = current.size >= TRANSCRIPT_RETAINED_ROWS &&
            older.any { candidate -> current.none { it.id == candidate.id } }
        val merged = prependTranscriptRows(current, older)
        val changed = merged.map { it.id } != current.map { it.id }
        meshTranscriptRows = merged
        meshTranscriptHasMore = pageStart > 0
        meshTranscriptPinnedToOlderEdge = meshTranscriptPinnedToOlderEdge || trimsNewerEdge
        return changed
    }

    private fun hasOlderMeshRows(peerId: String): Boolean {
        if (meshTranscriptRows.isEmpty()) refreshMeshTranscriptWindow(peerId)
        return meshTranscriptHasMore
    }

    /**
     * Advance only sources whose global merge frontier lacks a complete older
     * candidate page, then publish one globally adjacent page. Repeated
     * top-edge callbacks coalesce through each source window's loading flag.
     */
    suspend fun loadOlderMessages(chatId: String): Boolean {
        val generation = transcriptGeneration
        if (activeTranscriptChatId != chatId || (screen as? Screen.Chat)?.id != chatId) return false

        val groupIds = transcriptGroupIds(chatId)
        for (groupId in groupIds) {
            var window = transcriptWindows[groupId]
            if (window == null) {
                refreshTranscriptGroupWindow(groupId, chatId, generation)
                if (!isCurrentTranscriptSession(chatId, generation)) return false
                window = transcriptWindows[groupId]
            }
        }

        val oldestVisible = conversationTranscriptRows.firstOrNull() ?: return false
        val peerId = chatId.takeIf(::isMeshChat)?.let(::meshPeerId)
        var sourcesReady = false
        for (attempt in 0..<3) {
            val sources = buildList {
                if (peerId != null) {
                    if (meshTranscriptRows.isEmpty()) refreshMeshTranscriptWindow(peerId)
                    add(
                        TranscriptSourceWindow(
                            id = MESH_TRANSCRIPT_SOURCE_ID,
                            rows = meshTranscriptRows,
                            hasMore = hasOlderMeshRows(peerId),
                        ),
                    )
                }
                for (groupId in groupIds) {
                    val window = transcriptWindows[groupId] ?: continue
                    add(TranscriptSourceWindow(groupId, window.rows, window.hasMore))
                }
            }
            val sourceIds = transcriptSourceIdsNeedingExpansion(sources, oldestVisible)
            if (sourceIds.isEmpty()) {
                sourcesReady = true
                break
            }

            if (peerId != null && MESH_TRANSCRIPT_SOURCE_ID in sourceIds) {
                prependOlderMeshRows(peerId)
            }
            for (groupId in groupIds) {
                if (groupId !in sourceIds) continue
                val current = transcriptWindows[groupId] ?: continue
                if (current.loadingOlder || !current.hasMore || current.rows.isEmpty()) continue

                if (!isCurrentTranscriptSession(chatId, generation)) return false
                transcriptWindows[groupId] = current.copy(loadingOlder = true)
                val cursor = current.rows.first()
                val fetched = runCatching {
                    SonarCore.messagesCursorPage(
                        chatId = groupId,
                        beforeSecs = cursor.tsSecs,
                        beforeIdHex = cursor.id,
                        limit = TRANSCRIPT_PAGE_FETCH_SIZE,
                    )
                }.getOrNull()

                if (!isCurrentTranscriptSession(chatId, generation)) return false

                if (fetched == null) {
                    val latest = transcriptWindows[groupId] ?: current
                    transcriptWindows[groupId] = latest.copy(loadingOlder = false)
                    continue
                }
                val older = visibleTranscriptPage(fetched)
                // A newest-page refresh can finish while this older query is
                // suspended. Merge into the latest window so it cannot overwrite
                // a new canonical row or clear the in-flight state prematurely.
                val latest = transcriptWindows[groupId] ?: current
                val trimsNewerEdge = latest.rows.size >= TRANSCRIPT_RETAINED_ROWS &&
                    older.any { candidate -> latest.rows.none { it.id == candidate.id } }
                val merged = prependTranscriptRows(latest.rows, older)
                transcriptWindows[groupId] = TranscriptGroupWindow(
                    rows = merged,
                    hasMore = fetched.size > TRANSCRIPT_PAGE_SIZE,
                    pinnedToOlderEdge = latest.pinnedToOlderEdge || trimsNewerEdge,
                )
            }
        }

        if (!sourcesReady) {
            val sources = buildList {
                if (peerId != null) {
                    add(TranscriptSourceWindow(MESH_TRANSCRIPT_SOURCE_ID, meshTranscriptRows, hasOlderMeshRows(peerId)))
                }
                for (groupId in groupIds) {
                    val window = transcriptWindows[groupId] ?: continue
                    add(TranscriptSourceWindow(groupId, window.rows, window.hasMore))
                }
            }
            if (transcriptSourceIdsNeedingExpansion(sources, oldestVisible).isNotEmpty()) return false
        }

        if (!isCurrentTranscriptSession(chatId, generation)) return false

        val canonical = groupIds.flatMap { transcriptWindows[it]?.rows.orEmpty() }
        val source = if (isMeshChat(chatId)) {
            meshTranscriptRows + canonical
        } else {
            canonical
        }
        if (!prependConversationRows(source)) return false
        setCurrentVisibleMessages(
            chatId,
            withSendEchoes(chatId, mergePendingMediaUploads(chatId, conversationTranscriptRows)),
            processCalls = true,
        )
        return true
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
        val activeChat = screen as? Screen.Chat ?: return
        if (!isMeshChat(activeChat.id)) return
        val activePeerId = meshPeerId(activeChat.id)
        val canonicalPeerId = canonicalMeshPeerId(peerId)
        if (!sameMeshConversationIdentity(activePeerId, canonicalPeerId, linkByFp)) return
        // Keep publication keyed to the screen/session the user actually
        // opened. Canonical aliases select sources; they do not re-key UI state.
        val chatId = activeChat.id
        val generation = transcriptGeneration
        if (!isCurrentTranscriptSession(chatId, generation)) return
        val mesh = refreshMeshTranscriptWindow(canonicalPeerId)
        val wn = marmotMessagesForPeer(canonicalPeerId, chatId, generation)
        if (!isCurrentTranscriptSession(chatId, generation)) return
        val bounded = refreshConversationRows(mesh + wn, chatId, generation)
        val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, bounded))
        val visible = visibleMessagesForChat(chatId, merged)
        publishOpenTranscript(chatId, visible)
        val aliases = meshPeerAliases(canonicalPeerId)
        val groups = npubRawFor(canonicalPeerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { group -> peerIdForMarmotGroup(group)?.let { it in aliases } == true }
        markGroupsRead(groups.map { it.id })
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
        socialState = meshPeerAliases(peerId).fold(socialState) { state, alias ->
            state.withRemoteFavoritePeer(alias, favorite)
        }
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
        val deliveredByPeer = mutableMapOf<String, MutableList<String>>()
        for (m in incoming) {
            if (isMeshContactBlocked(m.peerId)) continue
            if (handleFavoriteControl(m.peerId, m.text)) {
                MeshRadio.sendMeshDeliveryAck(m.peerId, m.messageId)
                continue
            }
            // The wire message id is sender-chosen, so only a peer's own earlier
            // row may satisfy this — never one of ours. Re-ACK rather than drop
            // silently: the peer is most likely re-sending because our first
            // receipt was lost, and a second ack is what unsticks their row.
            val incomingId = m.messageId.ifBlank { randomMeshId() }
            if (m.messageId.isNotBlank() &&
                meshChats[m.peerId].orEmpty().any { it.id == incomingId && !it.mine }
            ) {
                MeshRadio.sendMeshDeliveryAck(m.peerId, m.messageId)
                continue
            }
            val stickerRef = meshParseStickerContent(m.text)?.let {
                SonarStickerRef(it.packCoordinate, it.shortcode, it.plaintextSha256)
            }
            val msg = SonarMsg(
                incomingId, m.peerId,
                if (stickerRef != null) "" else m.text,
                mine = false, m.tsSecs, stickerRef = stickerRef,
            )
            val chatId = meshChatId(m.peerId)
            if (stickerRef == null && SonarCore.callParseControl(m.text) != null) {
                processCallLines(chatId, listOf(msg))
                MeshRadio.sendMeshDeliveryAck(m.peerId, msg.id)
                continue
            }
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
            processPayLines(chatId, listOf(msg))
            touched += m.peerId
            deliveredByPeer.getOrPut(m.peerId) { mutableListOf() }.add(msg.id)
            val sender = meshPeerName(m.peerId)
            if (stickerRef == null && TrillLine.isTrillLine(m.text)) {
                // The row is already appended above; a trill alerts through its
                // own funnel (foreground buzz / background trill notification,
                // mute + 8 s receiver throttle applied).
                onTrillReceived(
                    idKey = chatId,
                    conversationTitle = sender,
                    content = m.text,
                    senderName = sender,
                )
                continue
            }
            val preview = if (stickerRef != null) "Sticker" else m.text
            notifyIncoming(
                idKey = chatId,
                conversationTitle = sender,
                content = preview,
                senderName = sender,
                sound = SonarNotificationSound.Ble,
                messageId = msg.id,
            )
        }
        touched.forEach { persistMesh(it, deliveredByPeer[it].orEmpty()) }
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

    /** Apply encrypted recipient receipts to optimistic BLE rows. */
    private fun drainMeshDeliveryReceipts(): Boolean {
        val receipts = MeshRadio.drainMeshDeliveryReceipts()
        if (receipts.isEmpty()) return false
        val touched = mutableSetOf<String>()
        for (receipt in receipts) {
            for (alias in meshPeerAliases(receipt.peerId)) {
                val before = meshChats[alias].orEmpty()
                var changed = false
                val after = before.map { message ->
                    if (message.mine && message.id == receipt.messageId && message.state != "Delivered") {
                        changed = true
                        message.copy(state = "Delivered")
                    } else {
                        message
                    }
                }
                if (changed) {
                    meshChats[alias] = after
                    touched += alias
                }
            }
        }
        touched.forEach(::persistMesh)
        if (touched.isNotEmpty()) {
            refreshMeshDmRows()
            (screen as? Screen.Chat)?.let { open ->
                val peerId = open.id.takeIf(::isMeshChat)?.let(::meshPeerId)
                if (peerId != null && meshAliasGroupWasTouched(meshPeerAliases(peerId), touched)) {
                    scope.launch { refreshOpenDm(peerId) }
                }
            }
        }
        return true
    }

    /** Re-enter the router after Android accepted a mesh send synchronously but
     * a later GATT callback failed. The optimistic BLE echo is removed before
     * the same id/plaintext enters the ordered app outbox. */
    private fun drainMeshSendFailures(): Boolean {
        val failures = MeshRadio.drainMeshSendFailures()
        if (failures.isEmpty()) return false
        val touched = mutableSetOf<String>()
        for (failure in failures) {
            val peerId = normalizeSocialPeerId(failure.peerId)
            val aliases = meshPeerAliases(peerId)
            // A recipient receipt can land before Android's stuck-operation
            // timeout reports the lost GATT callback. That row really did
            // arrive, so keep it and do not retry it over another route.
            if (aliases.any { alias ->
                    meshChats[alias].orEmpty().any {
                        it.id == failure.messageId && it.mine && it.state == "Delivered"
                    }
                }
            ) continue
            for (alias in aliases) {
                val before = meshChats[alias].orEmpty()
                val after = before.filterNot { it.mine && it.id == failure.messageId }
                if (after.size != before.size) {
                    meshChats[alias] = after
                    touched += alias
                }
            }
            if (isMeshContactBlocked(peerId)) continue
            when {
                failure.text.startsWith(FAVORITED_CONTROL) ||
                    failure.text.startsWith(UNFAVORITED_CONTROL) -> Unit
                SonarCore.callParseControl(failure.text) != null -> {
                    toast = "Call route dropped — try again in a moment."
                }
                else -> {
                    val canonicalPeerId = canonicalMeshPeerId(peerId)
                    // The optimistic row was withdrawn above. Re-paint it as a
                    // queued echo under the same id and original timestamp:
                    // flushOutboxNow -> sendMesh takes its `messageId != null`
                    // branch, which deliberately creates no row, so without this
                    // the retried message is delivered but never painted again.
                    echoMeshMessage(canonicalPeerId, failure.text, failure.messageId, failure.tsSecs)
                    enqueueOutbox(canonicalPeerId, failure.text, failure.messageId, failure.tsSecs)
                    flushOutbox(canonicalPeerId)
                }
            }
        }
        touched.forEach(::persistMesh)
        if (touched.isNotEmpty()) {
            refreshMeshDmRows()
            (screen as? Screen.Chat)?.let { open ->
                val peerId = open.id.takeIf(::isMeshChat)?.let(::meshPeerId)
                if (peerId != null && meshAliasGroupWasTouched(meshPeerAliases(peerId), touched)) {
                    scope.launch { refreshOpenDm(peerId) }
                }
            }
        }
        return true
    }

    /** Remove a failed optimistic BLE media bubble, then retry the original
     * bytes over White Noise without selecting the still-stale BLE route. */
    private fun drainMeshMediaSendFailures(): Boolean {
        val failures = MeshRadio.drainMeshMediaSendFailures()
        if (failures.isEmpty()) return false
        val touched = mutableSetOf<String>()
        val orphanedMediaUrls = mutableSetOf<String>()
        for (failure in failures) {
            val peerId = normalizeSocialPeerId(failure.peerId)
            val aliases = meshPeerAliases(peerId)
            // A recipient receipt can land before Android's stuck-operation
            // timeout reports the lost GATT callback. That row (and its cached
            // media bytes) really did arrive, so keep them and do not retry.
            if (aliases.any { alias ->
                    meshChats[alias].orEmpty().any {
                        it.id == failure.messageId && it.mine && it.state == "Delivered"
                    }
                }
            ) continue
            for (alias in aliases) {
                val before = meshChats[alias].orEmpty()
                before.filter { it.mine && it.id == failure.messageId }
                    .flatMap { it.media }
                    .forEach { media ->
                        mediaCache.remove(media.url)
                        orphanedMediaUrls += media.url
                    }
                val after = before.filterNot { it.mine && it.id == failure.messageId }
                if (after.size != before.size) {
                    meshChats[alias] = after
                    touched += alias
                }
            }
            if (isMeshContactBlocked(peerId)) continue
            val label = when {
                failure.mimeType.startsWith("audio/") -> "voice note"
                failure.mimeType.startsWith("image/") -> "photo"
                else -> "file"
            }
            sendMediaAttachment(
                chatId = meshChatId(canonicalMeshPeerId(peerId)),
                data = failure.bytes,
                filename = failure.filename,
                mime = failure.mimeType,
                missingRouteMessage = "Media wasn't sent — stay close and try again.",
                failureLabel = label,
                skipMesh = true,
            )
        }
        if (orphanedMediaUrls.isNotEmpty()) {
            scope.launch { orphanedMediaUrls.forEach { MessageStore.deleteMeshMedia(it) } }
        }
        touched.forEach(::persistMesh)
        if (touched.isNotEmpty()) {
            refreshMeshDmRows()
            (screen as? Screen.Chat)?.let { open ->
                val peerId = open.id.takeIf(::isMeshChat)?.let(::meshPeerId)
                if (peerId != null && meshAliasGroupWasTouched(meshPeerAliases(peerId), touched)) {
                    scope.launch { refreshOpenDm(peerId) }
                }
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
            // Rejected events are acknowledged below, so use the same
            // account-level predicate as the send path. Favorite controls can
            // legitimately land on different rotated fingerprints.
            if (!meshAliasGroupIsMutualFavorite(peerId)) {
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
            if (msg.stickerRef == null && TrillLine.isTrillLine(m.content)) {
                val sender = meshPeerName(peerId)
                onTrillReceived(
                    idKey = chatId,
                    conversationTitle = sender,
                    content = m.content,
                    senderName = sender,
                )
                continue
            }
            val preview = if (msg.stickerRef != null) "Sticker" else m.content
            notifyIncoming(chatId, meshPeerName(peerId), preview, messageId = id)
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
        val deliveredByPeer = mutableMapOf<String, MutableList<String>>()
        val mediaByPeer = mutableMapOf<String, MutableList<Pair<String, ByteArray>>>()
        for (m in incoming) {
            if (isMeshContactBlocked(m.peerId)) continue
            val id = m.messageId.ifBlank { randomMeshId() }
            // id is sender-chosen: a peer must not suppress its own incoming media
            // by reusing one of our outgoing row ids.
            if (m.messageId.isNotBlank() &&
                meshChats[m.peerId].orEmpty().any { it.id == id && !it.mine }
            ) {
                // Already persisted by the first delivery, so ack immediately
                // instead of routing through persistMesh's post-write ack.
                MeshRadio.sendMeshDeliveryAck(m.peerId, m.messageId)
                continue
            }
            val mediaUrl = meshMediaUrl(m.peerId, id, m.filename)
            val media = meshMediaFor(mediaUrl, m.mimeType, m.filename, m.bytes)
            mediaCache[mediaUrl] = m.bytes
            val msg = SonarMsg(id, m.peerId, "", mine = false, tsSecs = m.tsSecs, media = listOf(media))
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
            touched += m.peerId
            deliveredByPeer.getOrPut(m.peerId) { mutableListOf() }.add(id)
            mediaByPeer.getOrPut(m.peerId) { mutableListOf() }.add(mediaUrl to m.bytes)
            notifyIncoming(
                meshChatId(m.peerId),
                meshPeerName(m.peerId),
                mediaPreviewLabel(m.mimeType, m.filename),
                sound = SonarNotificationSound.Ble,
                messageId = id,
            )
        }
        if (touched.isEmpty()) return false
        touched.forEach { peerId ->
            persistMesh(peerId, deliveredByPeer[peerId].orEmpty(), mediaByPeer[peerId].orEmpty())
        }
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

    /** BLE-name vs kind-0 mismatch is a rename signal: refetch past the
     *  in-flight guard. Capped to one forced refetch per 30-min stale-sweep
     *  window (the profileFetches in-flight guard is the gate), so a
     *  permanently-different BLE handle cannot loop relay queries. */
    private fun refreshProfileOnNameMismatch(npubValue: String, liveName: String?) {
        val key = canonicalProfileKey(npubValue)
        if (!shouldForceProfileRefetch(profilesByNpub[key]?.bestName, liveName, profileFetches.contains(key))) return
        // Do NOT evict profileFetches first: a fetch may be in flight, and a
        // duplicate completion could overwrite a fresher name. ensureProfile's
        // in-flight guard + the 30-min stale sweep cap the forced refetch to
        // one per sweep window — matching the iOS 30-min TTL.
        ensureProfile(key)
    }

    /** Display name for a mesh peer: the linked account's kind-0 profile name
     *  wins over the BLE nickname (transport metadata); falls back to the live
     *  radar name, a remembered name, then a short id. Remembers whatever it
     *  resolves and triggers an async profile fetch when the name isn't cached. */
    private fun meshPeerName(peerId: String): String {
        val live = meshPeers.firstOrNull { it.id == "mesh:$peerId" }?.name
        val peerNpub = npubStringForPeer(peerId)
        val profileName = peerNpub
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
        val remembered = meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }
        if (peerNpub != null) refreshProfileOnNameMismatch(peerNpub, live)
        if (profileName == null && peerNpub != null) ensureProfile(peerNpub)
        // The linked account's LIVE kind-0 profile name wins over the BLE
        // nickname (transport metadata): a rename must reach the row both in
        // range and after the peer drops out of range.
        val name = profileName ?: live ?: remembered ?: ("mesh·" + peerId.take(6))
        if (!name.isKeyFallbackName()) rememberMeshName(peerId, name) else meshChatNames[peerId] = name
        return name
    }

    private fun foldedPeerName(peerId: String, group: SonarChat?): String {
        val directMarmotTitle = group?.takeIf(::isDirectMarmotChat)?.let(::chatTitle)
        if (directMarmotTitle != null) {
            return homeListTitleForFoldedMeshRow(directMarmotTitle, "")
        }
        // The linked account's LIVE kind-0 profile name wins over the BLE
        // nickname (transport metadata): a rename must reach the row both in
        // range and after the peer drops out of range.
        val peerNpub = npubStringForPeer(peerId)
        val live = meshPeers.firstOrNull { it.id == meshChatId(peerId) }?.name
        // Check the rename signal BEFORE the profile early-return below —
        // otherwise a cached bestName short-circuits and the mismatch refetch
        // never fires on folded rows.
        peerNpub?.let { refreshProfileOnNameMismatch(it, live) }
        peerNpub
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
            ?.let { name ->
                meshChatNames[peerId] = name
                return name
            }
        if (peerNpub != null) ensureProfile(peerNpub)
        live?.let {
            rememberMeshName(peerId, it)
            return it
        }
        meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }?.let { return it }
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
    private var conversationChangesCollecting = false

    private fun collectConversationChanges() {
        if (conversationChangesCollecting) return
        conversationChangesCollecting = true
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
                val freshChangedMessages = runCatching {
                    SonarCore.messagesPage(groupIdHex, BACKGROUND_TRANSCRIPT_SCAN_LIMIT)
                }.getOrNull()
                val changedMessages = if (freshChangedMessages == null ||
                    (!started && freshChangedMessages.isEmpty())
                ) {
                    chatSnapshotMessagesByChat[groupIdHex]
                        .orEmpty()
                        .takeLast(BACKGROUND_TRANSCRIPT_SCAN_LIMIT)
                } else {
                    freshChangedMessages
                }
                val visibleChangedMessages = visibleMessagesForChat(groupIdHex, changedMessages)
                processPayLines(groupIdHex, visibleChangedMessages)
                processCallLines(groupIdHex, visibleChangedMessages)
                // Hand the page to housekeeping before requesting it. That pass
                // owns the shared scan watermark so call/pay and notification
                // consumers cannot race by independently marking work complete.
                // A snapshot fallback is suitable for immediate UI/call replay,
                // but never counts as a successful read of this change. Only a
                // fresh core page may advance the shared scan watermark.
                if (freshChangedMessages != null) {
                    stagedChangedPages[groupIdHex] = freshChangedMessages
                    failedChangedPageReads.remove(groupIdHex)
                } else {
                    // Supersede any older staged page. The next housekeeping
                    // pass must read the newer invalidation from core before it
                    // is allowed to advance this chat's watermark.
                    stagedChangedPages.remove(groupIdHex)
                    failedChangedPageReads.add(groupIdHex)
                }
                (screen as? Screen.Chat)?.let { sc ->
                    if (!isMeshChat(sc.id) && (sc.id == groupIdHex || isSameDirectMarmotChat(sc.id, groupIdHex))) {
                        val mergedMessages = marmotMessagesPageForChat(sc.id)
                        setCurrentVisibleMessages(
                            sc.id,
                            withSendEchoes(sc.id, mergePendingMediaUploads(sc.id, mergedMessages)),
                            processCalls = true,
                        )
                        // Viewing the chat: new arrivals must not leave a badge.
                        markGroupsRead(directMarmotChatIds(sc.id))
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
        // null = FFI failure — keep the current map (same guard as markGroupsRead).
        val summaries = runCatching { SonarCore.conversationSummaries() }.getOrNull()
            ?: return
        applyUnreadCounts(summaries)
    }

    private fun applyUnreadCounts(summaries: List<SonarConversationSummary>) {
        // Viewing suppress is session-scoped and must NOT enter
        // unreadSuppressGroupIds. Prune keeps still-unread in-flight ids; if
        // openIds were folded into that set, a failed mark while viewing would
        // leave the group suppressed forever after the user leaves (goose/glm
        // NO-GO on #383). iOS keeps the same split via viewingUnreadGroupIds.
        val openIds = (screen as? Screen.Chat)?.id
            ?.let { transcriptGroupIds(it) }
            .orEmpty()
            .toSet()
        val pruned = pruneConfirmedUnreadSuppressions(
            unreadSuppressGroupIds.toSet(),
            summaries,
        )
        unreadSuppressGroupIds.clear()
        unreadSuppressGroupIds.addAll(pruned)
        unreadByChat = unreadCountsFromSummaries(summaries, unreadSuppressGroupIds + openIds)
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
                refreshRelayOnline()
                if (SonarCore.isRelayConnected()) {
                    runCatching { SonarCore.ensureSubscriptions() }
                    if (beat == 1L || (beat * effectiveHeartbeatMs()) % SYNC_INTERVAL_MS < effectiveHeartbeatMs()) {
                        runCatching { SonarCore.sync() }
                    }
                } else {
                    startRelayConnection()
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
        val summariesResult = runCatching { SonarCore.conversationSummaries() }
        val summaries = summariesResult.getOrDefault(emptyList())
        val summaryByChat = summaries.associateBy { it.groupIdHex }
        // Only publish unread on a successful probe — getOrDefault(emptyList())
        // on failure would wipe every badge until the next cycle.
        if (summariesResult.isSuccess) applyUnreadCounts(summaries)
        // Incremental scan: only chats whose newest ts moved past the watermark
        // need a page fetch + ☎CALL / pay re-scan. Everything else is skipped —
        // this replaces the old O(chats) messagesPage()+re-parse every 4 s.
        val changedPages = scanChangedChatsForCallPay(summaryByChat)
        // Resolve kind-0 profiles for chat members so chats show names, not npubs.
        for (c in chats) c.members.forEach { if (it != npub) ensureProfile(it) }
        flushPendingMarmot() // a queued out-of-range send whose group just landed
        flushAllOutbox() // retry any outbox messages whose peer is now reachable
        flushAllMediaOutbox() // retry any queued media whose peer is now reachable
        maybeNotify(changedPages, summaryByChat)
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
        // legs into the mesh rows (one row per person). Route through the same
        // conflated queue as push invalidation so snapshot publishes serialize.
        if (onboarded) {
            meshPeerRefreshQueue.request()
            recomputeConversations()
        }
        // Unify nearby: scan + publish only while Radar is visible and foregrounded.
        updateNearbyScanning()
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
    ): Map<String, List<SonarMsg>> {
        val latestByChat = chats.associate { c ->
            val s = summaryByChat[c.id]
            c.id to ScanMark(s?.latestAtSecs ?: 0L, s?.messageCount ?: 0L)
        }
        val toScan = chatsNeedingPageScan(
            latestByChat,
            scanWatermark,
            stagedPageChatIds = stagedChangedPages.keys + failedChangedPageReads,
        )
        var wnMsgs = 0
        val senders = mutableSetOf<String>()
        val changedPages = mutableMapOf<String, List<SonarMsg>>()
        for (c in chats) {
            val summaryCount = summaryByChat[c.id]?.messageCount?.toInt()
            if (c.id !in toScan) {
                // Unchanged chat: no page fetch. Reuse the summary's count so the
                // observability total still reflects every group.
                wnMsgs += summaryCount ?: 0
                continue
            }
            val forceFreshRead = c.id in failedChangedPageReads
            val stagedPage = if (forceFreshRead) null else stagedChangedPages.remove(c.id)
            val pageResult = if (stagedPage != null) {
                Result.success(stagedPage)
            } else {
                runCatching { SonarCore.messagesPage(c.id, BACKGROUND_TRANSCRIPT_SCAN_LIMIT) }
            }
            val ms = pageResult.getOrNull()
            if (ms == null) {
                // Preserve the watermark so a transient local read failure is
                // retried instead of permanently losing call/pay/notification.
                wnMsgs += summaryCount ?: 0
                continue
            }
            if (ms.isEmpty() && (summaryCount ?: 0) > 0) {
                // The index is ahead of the transcript read. Treat this like a
                // transient failure so the newly indexed row is retried.
                failedChangedPageReads.add(c.id)
                wnMsgs += summaryCount ?: 0
                continue
            }
            failedChangedPageReads.remove(c.id)
            changedPages[c.id] = ms
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
        stagedChangedPages.keys.retainAll(latestByChat.keys)
        failedChangedPageReads.retainAll(latestByChat.keys)
        senders.forEach { ensureProfile(it) }
        if (chats.size != lastWnGroups || wnMsgs != lastWnMsgs) {
            sonarLog("SonarWN", "White Noise: ${chats.size} group(s), $wnMsgs message(s)")
            lastWnGroups = chats.size; lastWnMsgs = wnMsgs
        }
        return changedPages
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
                    // Do not call retryOutbox here: it republishes in-flight
                    // Pending and can stack fanouts / burn attempt budget.
                    // Failed rows self-heal via core auto-retry; stranded
                    // Pending is flushed on connect and idle ensureSubscriptions.
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
                val drained = drainMeshDms() or drainMeshDeliveryReceipts() or drainMeshSendFailures() or
                    drainMeshMediaSendFailures() or drainMeshMedia() or drainMeshBroadcasts()
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
