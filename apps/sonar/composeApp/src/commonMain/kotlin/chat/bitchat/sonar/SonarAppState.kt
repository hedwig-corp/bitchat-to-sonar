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
import chat.bitchat.sonar.wallet.SendResult
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

private const val SONAR_DESCRIPTOR_TTL_SECS = 15 * 60L
private const val SONAR_DESCRIPTOR_MISS_TTL_SECS = 60L
private const val PROFILE_REFRESH_TTL_SECS = 30 * 60L
private const val LOCAL_TRANSCRIPT_PAGE_LIMIT = 100
private const val LOCAL_SUMMARY_PAGE_LIMIT = 20
private const val LOCAL_SUMMARY_CHAT_LIMIT = 5

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

private fun messagePreview(content: String, stickerRef: SonarStickerRef? = null): String {
    if (stickerRef != null) return "Sticker"
    if (content.trimStart().startsWith("☎CALL") && SonarCore.callParseControl(content) != null) {
        return "Voice call"
    }
    return if (PayLine.decode(content) != null) "₿ Payment" else content
}

internal fun canonicalConversationTitle(title: String): String =
    title.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

internal fun inferUniquePeerByTitle(
    groupTitle: String,
    peerTitles: Map<String, String>,
    allGroupTitles: List<String>,
): String? {
    val title = canonicalConversationTitle(groupTitle).takeIf { it.isNotEmpty() } ?: return null
    if (allGroupTitles.count { canonicalConversationTitle(it) == title } != 1) return null
    return peerTitles.entries
        .filter { canonicalConversationTitle(it.value) == title }
        .map { it.key }
        .singleOrNull()
}

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
)

/** Verify-sheet model: the safety groups (empty ⇒ show [note]) + verified flag. */
data class SonarVerify(val safety: List<String>, val verified: Boolean, val note: String?)

/**
 * Shared (commonMain) UI state for the Sonar app. Drives White Noise (Marmot)
 * encrypted DMs through [SonarCore]; the same logic will back the iOS app once
 * it shifts to Compose Multiplatform.
 */
class SonarAppState(private val scope: CoroutineScope) {
    private val initialChatSnapshotBlob = SonarCore.loadBlob(CHAT_SNAPSHOT_BLOB_KEY)
    private val initialChatSnapshot = decodeChatSnapshot(initialChatSnapshotBlob)
    var npub by mutableStateOf("")
        private set
    var started by mutableStateOf(false)
        private set
    var connecting by mutableStateOf(false)
        private set
    var chats by mutableStateOf<List<SonarChat>>(initialChatSnapshot.first)
        private set
    private var chatSnapshotMessagesByChat: Map<String, List<SonarMsg>> = initialChatSnapshot.second
    var groupInvites by mutableStateOf<List<SonarGroupInvite>>(emptyList())
        private set
    private val pendingInviteTokens = mutableListOf<String>()
    /** Resolved kind-0 profiles by npub — fills human names for Marmot members. */
    var profilesByNpub by mutableStateOf(decodeProfileCache(SonarCore.loadBlob(PROFILE_CACHE_BLOB_KEY)))
        private set
    private val profileFetches = mutableSetOf<String>()
    private val profileFetchedAt = mutableMapOf<String, Long>()

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

    fun push(s: Screen) { stack = stack + s }
    fun toggleDark() { dark = !dark; SonarCore.setDark(dark) }

    fun wipe() {
        scope.launch {
            WalletBridge.shutdown()
            UnifyRadio.stopScanning()
            UnifyRadio.stopAdvertising()
            unifyOffer = null; unifyPeers = emptyList()
            MeshRadio.setMeshNickname("")
            MeshRadio.setLocalSonarAnnounce(null); sonarPeerProfiles = emptyMap()
            linkByFp.clear(); linkCapsByFp.clear(); foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            sonarDescriptorsByNpubHex = emptyMap()
            sonarDescriptorFetches.clear(); sonarDescriptorFetchedAt.clear(); sonarDescriptorMissedAt.clear()
            publishedSonarDescriptor = false; publishedSonarDescriptorBolt12Offer = null; publishingSonarDescriptor = false
            needsSonarDescriptorPublish = false
            rawMeshPeerIds = emptySet(); meshPeerFirstSeenMs.clear(); pendingCapabilityRefreshPeers.clear()
            profilesByNpub = emptyMap(); profileFetches.clear()
            outbox.clear()
            MessageStore.wipe()
            SonarCore.wipe()
            stack = listOf(Screen.Home)
            chats = emptyList(); chatSnapshotMessagesByChat = emptyMap(); groupInvites = emptyList(); messages = emptyList()
            clearChatSnapshot()
            onboarded = false; nick = ""; npub = ""; started = false
            walletState = WalletState.NotConfigured
            presenceByGeohash = emptyMap()
            payLedger = SonarPayLedger(); payVersion++
            mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
            callLogs.clear(); callVersion++
            resetCallState()
            pollJob?.cancel(); pollJob = null
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
            // Local transcripts on disk (mesh DMs, channels, geo DMs).
            MessageStore.wipe()
            // In-memory conversation state.
            meshChats.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); outbox.clear()
            linkByFp.clear(); linkCapsByFp.clear(); persistLinks(); persistLinkCaps()
            profilesByNpub = emptyMap(); profileFetches.clear(); persistProfileCache()
            foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
            meshBroadcast = emptyList(); meshDmRows = emptyList()
            messages = emptyList(); channelMsgs = emptyList(); chats = emptyList(); clearChatSnapshot()
            lastWnGroups = -1; lastWnMsgs = -1
            // ⚡PAY coins live inside the erased chats — reset the ledger. The
            // Lightning wallet seed/balance is separate and is NOT touched.
            payLedger = SonarPayLedger(); persistPay(); payVersion++
            mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
            callLogs.clear(); callVersion++
            // White Noise / Marmot DB: wipe + reconnect with the SAME identity.
            runCatching { SonarCore.eraseChats() }
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
    private var pollJob: Job? = null
    /** Ids of ☎CALL control messages already routed to the engine (dedup). */
    private val scannedCall = mutableSetOf<String>()

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
        if (video) { toast = "Video calls are coming soon."; return }
        if (!canCall(chatId)) { toast = "No call route to this Sonar peer yet."; return }
        val callId = randomMeshId()
        // Show the ringing screen IMMEDIATELY so the tap is responsive; the iroh
        // setup (bind/offer) runs below. (ensureCallStarted is idempotent — it
        // guards on callStarted, so unlike the old iOS path it never re-binds.)
        CallAudioRoute.configure(active = true, speakerOn = true)
        activeCall = ActiveCall(callId, chatId, peerName, video, incoming = false, phase = SonarCallState.Ringing)
        push(Screen.Call(chatId, peerName, video))
        scope.launch {
            ensureCallStarted()
            if (!callStarted) {
                toast = "Calling isn’t available right now"
                CallAudioRoute.configure(active = false, speakerOn = false)
                activeCall = null
                back()
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
                            back()
                        }
                    }
                }
            } catch (e: Throwable) {
                toast = "call failed: ${e.message}"
                if (activeCall?.callId == callId) {
                    CallAudioRoute.configure(active = false, speakerOn = false)
                    activeCall = null
                    back()
                }
            }
        }
    }

    /** Accept the incoming call: send ANSWER|accept (with our address), then dial. */
    fun acceptCall() {
        val c = activeCall ?: return
        activeCall = c.copy(phase = SonarCallState.Connecting)
        CallAudioRoute.configure(active = true, speakerOn = c.speakerOn)
        scope.launch {
            try {
                val addr = SonarCore.callLocalAddress()
                val sent = sendCallControl(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Accept, addr))
                if (!sent) {
                    runCatching { SonarCore.callHangup(c.callId) }
                    CallAudioRoute.configure(active = false, speakerOn = false)
                    return@launch
                }
                if (activeCall?.callId == c.callId && activeCall?.muted == true) {
                    runCatching { SonarCore.callSetMuted(c.callId, true) }
                }
                sonarLog("SonarCall", "TX ANSWER accept + dialing callId=${c.callId.take(8)}")
                SonarCore.callAccept(c.callId)
                sonarLog("SonarCall", "callAccept returned (dialed) callId=${c.callId.take(8)}")
            } catch (e: Throwable) { sonarLog("SonarCall", "accept FAILED: ${e.message}"); toast = "couldn’t accept: ${e.message}" }
        }
    }

    /** Decline the incoming call: send ANSWER|decline + tear down the local slot. */
    fun declineCall() {
        val c = activeCall ?: return
        scope.launch {
            runCatching { sendCallControl(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Decline, "")) }
            runCatching { SonarCore.callHangup(c.callId) } // engine Ended event finalizes
        }
    }

    /** Hang up an outgoing/connected call: tear down media + signal END. The
     *  engine's Ended event records the call-log entry and pops the screen. */
    fun hangupCall() {
        val c = activeCall ?: return
        CallAudioRoute.configure(active = false, speakerOn = false)
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
        CallAudioRoute.setSpeaker(next)
    }

    fun toggleCallCam() {
        val c = activeCall ?: return
        activeCall = c.copy(camOn = !c.camOn)
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
        if (screen is Screen.Call && stack.size > 1) stack = stack.dropLast(1)
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
        if (ctrl is SonarCallControl.Offer && !canCall(callChatId)) {
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
                if (ctrl.video) {
                    runCatching { sendCallControl(callChatId, SonarCore.callEncodeAnswer(ctrl.callId, SonarAnswer.Decline, "")) }
                    sonarLog("SonarCall", "declined unsupported video offer callId=${ctrl.callId.take(8)}")
                    return
                }
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
                activeCall = ActiveCall(ctrl.callId, callChatId, name, ctrl.video, incoming = true, phase = SonarCallState.Ringing)
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
    }

    private fun updateMeshPeersFromRadio(nowMs: Long = SonarClock.nowMillis()) {
        val rawPeers = MeshRadio.peers()
        val previousPeerIds = rawMeshPeerIds
        rawMeshPeerIds = rawPeers.map { meshPeerId(it.id) }.toSet()
        meshPeerFirstSeenMs.keys.retainAll(rawMeshPeerIds + meshChats.keys + linkByFp.keys)
        meshPeers = rawPeers.filter { peer ->
            val peerId = meshPeerId(peer.id)
            if (peer.name.isNotBlank()) meshChatNames[peerId] = peer.name
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
        if (!hasRecentMarmotActivityForCapabilitySettle(chatSnapshotMessagesByChat[chat.id]?.lastOrNull()?.tsSecs, nowMs)) {
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
    private var foldedGroupIds by mutableStateOf<Set<String>>(emptySet())
    /** Folded Marmot group id → mesh peer fingerprint. Kept with [foldedGroupIds]
     *  so openChat/refreshOpenDm can route a White Noise group back to the
     *  canonical mesh conversation even while BLE is unavailable. */
    private var foldedGroupPeerIds: Map<String, String> = emptyMap()

    /** White Noise chats to render on their own row: every Marmot group EXCEPT the
     *  ones folded into a mesh DM. The Messages list uses this instead of [chats]. */
    val visibleChats: List<SonarChat> get() =
        chats.filterNot { it.id in foldedGroupIds || shouldHoldStandaloneMarmotChat(it) }

    private fun otherMembers(chat: SonarChat): List<String> {
        val mine = canonicalProfileKey(npub)
        return chat.members
            .map { canonicalProfileKey(it) }
            .filter { it != mine && it.isNotBlank() }
            .distinct()
    }

    fun isDirectMarmotChat(chat: SonarChat): Boolean =
        otherMembers(chat).size == 1

    fun isMultiMemberChat(chatId: String): Boolean =
        chats.firstOrNull { it.id == chatId }?.let { !isDirectMarmotChat(it) } == true

    fun hasDirectPaymentRoute(chatId: String): Boolean {
        if (directPaymentOffer(chatId) != null) return true
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            if (sonarProfile(peerId)?.speaksPay == true) return true
            if (((linkCapsByFp[peerId] ?: 0) and SonarAnnounce.CAP_PAY) != 0) return true
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

    fun groupMemberContacts(chatId: String): List<GroupContact> =
        chats.firstOrNull { it.id == chatId }
            ?.let { otherMembers(it) }
            .orEmpty()
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
        chats.firstOrNull { it.id == chatId }?.members.orEmpty().toSet()

    /** This peer's npub (32 raw bytes) if known — from a live 0x53 OR the persisted
     *  [linkByFp] (so it still resolves out of range / after restart). The bridge
     *  that unifies the BLE-Noise and White-Noise legs of one conversation. */
    private fun npubRawFor(peerId: String): ByteArray? =
        sonarProfile(peerId)?.npub
            ?: linkByFp[peerId]?.hexToBytesOrEmpty()?.takeIf { it.size == 32 }

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
    }

    private fun persistLinks() {
        SonarCore.saveBlob("sonar.links", linkByFp.entries.joinToString("\n") { "${it.key}=${it.value}" })
    }

    private fun persistLinkCaps() {
        SonarCore.saveBlob("sonar.linkCaps", linkCapsByFp.entries.joinToString("\n") { "${it.key}=${it.value}" })
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

    private fun setupWallet() {
        if (!walletAvailable) {
            scope.launch { publishSonarDescriptorIfNeeded(force = true) }
            return
        }
        scope.launch {
            WalletBridge.setupIfNeeded(SonarCore.identityNsec())
            walletState = WalletBridge.state()
            WalletBridge.fetchRates()
            rate = WalletBridge.cachedRate(currency)
            publishSonarDescriptorIfNeeded(force = true)
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
            sonarProfile(meshPeerId(chatId))?.bolt12Offer?.takeIf { it.isNotBlank() }?.let { return it }
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
        scope.launch {
            var failureMessage: String? = null
            val result = runCatching { WalletBridge.send(offer, sats, "Sonar payment $payId") }
                .getOrElse {
                    failureMessage = "Payment failed: ${it.message}"
                    SendResult(false)
                }
            walletState = WalletBridge.state()
            if (result.ok) {
                if (payLedger.recordReceipt(payId, sats, mine = true)) {
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
                toast = failureMessage ?: "Payment failed"
            }
        }
        return null
    }

    private suspend fun sendPaymentReceiptLines(chatId: String, lines: List<String>): Boolean {
        val clean = lines.map { it.trim() }.filter { it.isNotEmpty() }
        if (clean.isEmpty()) return true
        if (isMeshChat(chatId)) {
            val peerId = meshPeerId(chatId)
            if (hasLiveMeshRoute(peerId)) {
                return clean.all { sendMesh(peerId, it) }
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
            messages = withSendEchoes(groupId, mergePendingMediaUploads(groupId, marmotMessagesPage(groupId)))
            processPayLines(groupId, messages)
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
                is PayLine.Pay -> if (payLedger.recordReceipt(line.uuid, line.sats, m.mine)) changed = true
                is PayLine.Done -> if (payLedger.markClaimedOrPending(line.uuid, line.preimage)) changed = true
                null -> {}
            }
        }
        if (changed) { persistPay(); payVersion++ }
    }

    /** Start the BLE mesh radio (call once permissions are granted). */
    fun startMesh() {
        refreshMeshIdentity()
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
        UnifyRadio.startScanning()
    }

    /** Advertise our receivable BOLT12 offer iff the wallet is ready AND we are
     *  in the foreground — mirrors the iOS receiver policy (foreground-only). */
    private suspend fun updateUnifyReceiver() {
        val shouldServe = walletAvailable && onboarded && foreground &&
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
            val result = WalletBridge.send(dest, amountSats, "Sonar nearby")
            walletState = WalletBridge.state()
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
        if (geohash == "mesh") { channelMsgs = meshBroadcast; return }
        scope.launch {
            val disk = MessageStore.loadChannel(geohash) // disk hydrate (off-main), survives restart
            if (isOpenChannel(geohash)) channelMsgs = disk
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
        if (isOpenChannel(geohash)) channelMsgs = merged
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
            channelMsgs = meshBroadcast
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
            messages = MessageStore.loadGeoDm(geohash, peerHex) // disk hydrate (off-main)
            refreshGeoDm(geohash, peerHex)
        }
    }

    private suspend fun refreshGeoDm(geohash: String, peerHex: String) {
        val fresh = SonarCore.geoDmMessages(geohash, peerHex)
        val merged = MessageMerge.dms(MessageStore.loadGeoDm(geohash, peerHex), fresh)
        MessageStore.saveGeoDm(geohash, peerHex, merged)
        messages = merged
    }

    fun sendGeoDmMsg(geohash: String, peerHex: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        scope.launch {
            try {
                SonarCore.sendGeoDm(geohash, peerHex, t)
                refreshGeoDm(geohash, peerHex)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    var onboarded by mutableStateOf(SonarCore.onboardingComplete())
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
    fun isVerified(chatId: String): Boolean = SonarCore.loadBlob("verified.$chatId") == "1"

    fun markVerified(chatId: String) {
        SonarCore.saveBlob("verified.$chatId", "1")
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
        SonarCore.setNickname(nickname)
        SonarCore.setOnboardingComplete(true)
        nick = nickname
        onboarded = true
        refreshMeshIdentity()
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
                resetCallState()

                MessageStore.wipe()
                meshChats.clear(); meshChatNames.clear(); pendingMarmotSends.clear(); outbox.clear()
                linkByFp.clear(); linkCapsByFp.clear(); persistLinks(); persistLinkCaps()
                foldedGroupIds = emptySet(); foldedGroupPeerIds = emptyMap()
                sonarPeerProfiles = emptyMap()
                sonarDescriptorsByNpubHex = emptyMap()
                sonarDescriptorFetches.clear(); sonarDescriptorFetchedAt.clear(); sonarDescriptorMissedAt.clear()
                meshBroadcast = emptyList(); meshDmRows = emptyList()
                chats = emptyList(); messages = emptyList(); channelMsgs = emptyList()
                lastWnGroups = -1; lastWnMsgs = -1
                payLedger = SonarPayLedger(); persistPay(); payVersion++
                mediaCache.clear(); stickerPackCache.clear(); stickerImageCache.clear(); installedPackCoordinates.clear()
                callLogs.clear(); callVersion++

                npub = restoredNpub
                started = false
                connecting = false
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

    /** Count of chats the user has marked verified (for the Settings row). */
    fun verifiedCount(): Int = chats.count { isVerified(it.id) }

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
                    refreshChats()
                    recomputeConversations()
                    (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
                    refreshPresenceCounts()
                }
            }
        }
        // Unify receiver is foreground-only (matches iOS) — react immediately.
        scope.launch { updateUnifyReceiver() }
    }

    private fun notifPreview(content: String): String =
        if (PayLine.decode(content) != null) "₿ Payment"
        else content.replace("\n", " ").let { if (it.length > 80) it.take(80) + "…" else it }

    /** Notify for any chat whose newest incoming message is newer than last seen. */
    private suspend fun maybeNotify() {
        val enabled = prefBool("notifs", true) // master switch (Settings → Notifications)
        val showNames = prefBool("notifNames", true)
        val showPreview = prefBool("notifPreview", true)
        val openChatId = (screen as? Screen.Chat)?.id
        for (c in chats) {
            val msgs = SonarCore.messagesPage(c.id, 1)
            val newestIncoming = msgs.lastOrNull { !it.mine }
            val prev = lastSeenTs[c.id]
            if (enabled && seededSeen && prev != null && newestIncoming != null &&
                newestIncoming.tsSecs > prev && !foreground && c.id != openChatId
            ) {
                val title = if (showNames) chatTitle(c) else "New message"
                val body = if (showPreview) notifPreview(newestIncoming.content) else "Tap to open"
                Notifier.notify(c.id.hashCode(), title, body)
            }
            lastSeenTs[c.id] = msgs.lastOrNull()?.tsSecs ?: (prev ?: 0L)
        }
        seededSeen = true
    }

    fun boot() {
        if (started || connecting) return
        connecting = true
        Notifier.ensureChannel()
        scope.launch {
            try {
                npub = SonarCore.start()
                SonarCore.installConversationListener()
                collectConversationChanges()
                started = true
                refreshMeshIdentity()
                // Publish our kind-0 profile so peers see our nickname, not npub.
                launch { runCatching { SonarCore.publishProfile(nick) } }
                // Descriptor publish runs after wallet setup so call metadata is
                // discoverable without racing a wallet-ready BOLT12 offer.
                // Hydrate BLE-mesh transcripts from disk so private mesh chats
                // survive a restart (parity with the iOS MessageStore). Precedes
                // refreshMeshDmRows so the Messages list is populated at launch.
                meshChats.putAll(MessageStore.loadAllMeshDms())
                loadLinks() // durable fingerprint↔npub so BLE chats stay unified after restart
                refreshKnownContactDescriptors(clearMisses = true)
                refreshMeshDmRows()
                setupWallet()
                refreshLocationChannels()
                refreshChats()
                recomputeConversations() // fold White Noise legs into mesh rows at launch
                drainPendingInviteTokens()
                // Bind the iroh call endpoint + start the call event loop early so
                // an incoming call rings without us having to place one first.
                launch { ensureCallStarted() }
                startMeshRealtimeLoop()
                poll()
            } catch (t: Throwable) {
                toast = "connect failed: ${t.message}"
            } finally {
                connecting = false
            }
        }
    }

    /** Display title for a White Noise (Marmot) chat. A 1:1 group's stored name
     *  is blank, so fall back to the counterpart's short npub — never an empty
     *  title. Mirrors iOS `MarmotChatModel.title(for:)`. */
    fun chatTitle(chat: SonarChat): String {
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

    private fun shortNpub(value: String): String =
        if (value.length > 16) value.take(10) + "…" + value.takeLast(4) else value

    fun groupAuthorName(message: SonarMsg, isGroup: Boolean): String? {
        if (!isGroup || message.mine || message.senderNpub.isBlank()) return null
        return profilesByNpub[canonicalProfileKey(message.senderNpub)]?.bestName
            ?: shortNpub(message.senderNpub)
    }

    /** Fetch + cache a peer's kind-0 profile, so their name replaces the
     *  raw npub in the chat list/header. */
    fun ensureProfile(otherNpub: String) {
        val key = canonicalProfileKey(otherNpub)
        if (key.isBlank() || key == canonicalProfileKey(npub)) return
        val hadCachedProfile = profilesByNpub.containsKey(key) || profilesByNpub.containsKey(otherNpub)
        if (!profileFetches.add(key)) return        // fetch already in flight
        scope.launch {
            val p = SonarCore.fetchProfile(key)
            if (p?.bestName != null) {
                profilesByNpub = normalizedProfileCache(profilesByNpub + (key to p) - otherNpub)
                profileFetchedAt[key] = SonarClock.nowSecs()
                persistProfileCache()
            } else {
                if (!hadCachedProfile) profileFetches.remove(key)
            }
        }
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
        SonarCore.saveBlob(PROFILE_CACHE_BLOB_KEY, encodeProfileCache(profilesByNpub))
    }

    fun openChat(chat: SonarChat) {
        push(Screen.Chat(chat.id, chatTitle(chat)))
        unreadByChat = unreadByChat - chat.id
        scope.launch {
            runCatching { SonarCore.markConversationRead(chat.id) }
            val local = withSendEchoes(chat.id, mergePendingMediaUploads(chat.id, marmotMessagesPage(chat.id)))
            messages = local
            processPayLines(chat.id, local)
            runCatching { refreshChats() }
            if ((screen as? Screen.Chat)?.id == chat.id) {
                val fresh = withSendEchoes(chat.id, mergePendingMediaUploads(chat.id, marmotMessagesPage(chat.id)))
                messages = fresh
                processPayLines(chat.id, fresh)
            }
        }
    }

    /** Open the 1:1 DM with a radar peer. The conversation auto-picks transport:
     *  BLE mesh (Noise) while in Bluetooth range, White Noise (Marmot) when out of
     *  range for a Sonar peer — both legs merged into one thread. [pay] auto-opens
     *  the payment sheet (radar "Send sats"). */
    fun openDm(peerId: String, name: String, pay: Boolean = false) {
        val id = meshChatId(peerId)
        if (name.isNotBlank()) meshChatNames[peerId] = name
        push(Screen.Chat(id, name, pay))
        messages = meshChats[peerId].orEmpty() // immediate mesh view; Marmot leg merges in async
        processPayLines(id, messages)
        scope.launch {
            refreshOpenDm(peerId) // hydrate local Marmot transcript before chat list refresh
            refreshChats()
            // Reconcile the open transcript after chat-list refresh may discover
            // the peer's Marmot group mapping.
            refreshOpenDm(peerId)
        }
    }

    private fun meshChatId(peerId: String) = "mesh:$peerId"
    private fun meshPeerId(chatId: String) = chatId.removePrefix("mesh:")
    private fun isMeshChat(chatId: String) = chatId.startsWith("mesh:")

    fun back() {
        pendingMediaPreviews = emptyList()
        if (stack.size > 1) stack = stack.dropLast(1)
        if (stack.lastOrNull() !is Screen.Chat) messages = emptyList()
        scope.launch { refreshChats() }
    }

    /** Desktop master-detail helper: collapse the nav stack to [Screen.Home] so
     *  the content pane shows the welcome placeholder. Called before selecting a
     *  sidebar item so the stack never grows unbounded and a screen's Back button
     *  deselects (returns to the welcome pane) instead of walking history. */
    fun resetToHome() {
        pendingMediaPreviews = emptyList()
        if (stack.size > 1) { stack = listOf(Screen.Home); messages = emptyList() }
    }

    /** True when the desktop content pane should show the welcome placeholder. */
    val isHome: Boolean get() = stack.size == 1

    /** Delete a 1:1 Marmot chat locally, or leave a multi-member Marmot group. */
    fun deleteMarmotChat(chatId: String) {
        val wasOpen = (stack.lastOrNull() as? Screen.Chat)?.id == chatId
        val isGroup = chats.firstOrNull { it.id == chatId }?.let { !isDirectMarmotChat(it) } == true
        chats = chats.filterNot { it.id == chatId }
        if (wasOpen && stack.size > 1) stack = stack.dropLast(1) // pop WITHOUT refresh
        scope.launch {
            try {
                if (isGroup) {
                    SonarCore.leaveGroup(chatId)
                } else {
                    SonarCore.deleteChat(chatId)
                }
            } catch (t: Throwable) {
                toast = if (isGroup) "couldn't leave group: ${t.message}" else "couldn't delete chat: ${t.message}"
            }
            refreshChats()
        }
    }

    /** Delete ONE BLE-mesh private conversation locally (in-memory + on-disk). */
    fun deleteMeshDm(peerId: String) {
        val wasOpen = (stack.lastOrNull() as? Screen.Chat)?.id == peerId
        meshChats.remove(peerId)
        meshChatNames.remove(peerId)
        meshDmRows = meshDmRows.filterNot { it.peerId == peerId }
        if (wasOpen && stack.size > 1) stack = stack.dropLast(1)
        scope.launch { MessageStore.deleteMeshDm(peerId) }
    }

    fun startChat(peer: String) {
        val p = peer.trim()
        if (p.isEmpty()) return
        scope.launch {
            try {
                val chatId = SonarCore.startChat(p)
                refreshChats()
                val chat = chats.firstOrNull { it.id == chatId }
                if (chat != null) {
                    openChat(chat)
                } else {
                    push(Screen.Chat(chatId, shortNpub(p)))
                    messages = marmotMessagesPage(chatId)
                }
            } catch (t: Throwable) {
                toast = "couldn't start: ${t.message}"
            }
        }
    }

    /**
     * Handle a slash command (1:1 with iOS snCommands). Returns true if [text]
     * was a recognized command and consumed; false ⇒ send as normal text.
     * `target` is the channel/peer display name for the /slap action.
     */
    fun handleCommand(text: String, target: String, channelGeohash: String?, chatId: String?): Boolean {
        if (!text.startsWith("/")) return false
        return when (text.drop(1).trim().substringBefore(' ').lowercase()) {
            "who", "msg" -> { push(Screen.Nearby); true }
            "slap" -> {
                val who = nick.ifBlank { "you" }
                val line = "* $who slaps $target around a bit with a large trout"
                if (channelGeohash != null) sendChannelMsg(channelGeohash, line)
                else if (chatId != null) send(chatId, line)
                true
            }
            else -> false
        }
    }

    fun send(chatId: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (isMeshChat(chatId)) { sendDmAuto(meshPeerId(chatId), t); return }
        val echo = createSendEcho(chatId, t)
        messages = (messages + echo).sortedBy { it.tsSecs }
        scope.launch {
            try {
                SonarCore.send(chatId, t)
                clearSendEcho(chatId, echo.id)
                messages = withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPage(chatId)))
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
        val echo = SonarMsg(
            id = "$echoIdPrefix${randomMeshId()}",
            senderNpub = npub,
            content = text,
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
        val data: ByteArray,
        val filename: String,
        val mime: String,
        val caption: String = "",
    )

    var pendingMediaPreviews by mutableStateOf<List<PendingMediaPreview>>(emptyList())

    fun stageMediaPreview(chatId: String, data: ByteArray, filename: String, mime: String) {
        pendingMediaPreviews = listOf(PendingMediaPreview(chatId, data, filename, mime))
    }

    fun confirmSendPreview() {
        val items = pendingMediaPreviews
        if (items.isEmpty()) return
        pendingMediaPreviews = emptyList()
        for (preview in items) {
            sendImage(preview.chatId, preview.data, preview.filename, preview.mime)
        }
    }

    fun cancelPreview() {
        pendingMediaPreviews = emptyList()
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
        val pending = pendingMediaUploads.getOrPut(chatId) { mutableListOf() }
        pending.removeAll { it.message.id == upload.message.id }
        pending += upload
    }

    private fun markPendingMediaCompleted(chatId: String, pendingId: String) {
        val pending = pendingMediaUploads[chatId] ?: return
        val index = pending.indexOfFirst { it.message.id == pendingId }
        if (index >= 0 && pending[index].completedOrder == null) {
            pendingMediaCompletionOrder += 1
            pending[index] = pending[index].copy(completedOrder = pendingMediaCompletionOrder)
        }
    }

    private fun markPendingMediaFailed(chatId: String, pendingId: String) {
        val pending = pendingMediaUploads[chatId] ?: return
        val index = pending.indexOfFirst { it.message.id == pendingId }
        if (index >= 0) {
            val upload = pending[index]
            pending[index] = upload.copy(message = upload.message.copy(state = "Couldn't send"))
        }
    }

    private fun mergePendingMediaUploads(chatId: String, published: List<SonarMsg>): List<SonarMsg> {
        val pending = pendingMediaUploads[chatId] ?: return published.sortedBy { it.tsSecs }
        val matchedIds = mutableSetOf<String>()
        val usedCanonicalUrls = mutableSetOf<String>()
        val completedUploads = pending
            .filter { it.message.state != "Couldn't send" && it.completedOrder != null }
            .sortedBy { it.completedOrder }
        for (upload in completedUploads) {
            val matched = cacheUploadedMediaBytes(
                published,
                upload.data,
                upload.filename,
                upload.mime,
                upload.startedAtSecs,
                upload.pendingUrl,
                upload.existingMediaUrls,
                usedCanonicalUrls,
            )
            if (matched) matchedIds += upload.message.id
        }
        val survivors = pending.filterNot { it.message.id in matchedIds }
        if (survivors.isEmpty()) {
            pendingMediaUploads.remove(chatId)
            return published.sortedBy { it.tsSecs }
        }
        pendingMediaUploads[chatId] = survivors.toMutableList()
        val survivorMessages = survivors.map { it.message }
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
        if (!isMeshChat(chatId)) return chatId
        val raw = npubRawFor(meshPeerId(chatId)) ?: return null
        return marmotGroupForNpub(raw)?.id
    }

    /** True if [chatId] can carry media (an existing Marmot group backs it). */
    fun canSendMedia(chatId: String): Boolean = resolveMarmotGroupId(chatId) != null

    /** Send an image to a White Noise chat: encrypt + Blossom upload + publish. */
    fun sendImage(chatId: String, data: ByteArray, filename: String, mime: String) {
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
                messages = mergePendingMediaUploads(chatId, messages)
            }
            try {
                SonarCore.sendMedia(groupId, data, filename, mime, "")
                markPendingMediaCompleted(chatId, pendingId)
                // Refresh the open conversation so the sent image shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val mesh = meshChats[peerId].orEmpty()
                            val wn = marmotMessagesForPeer(peerId)
                            val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
                            messages = merged
                            processPayLines(chatId, merged)
                        } else {
                            val fresh = SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
                            messages = withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh))
                            processPayLines(chatId, messages)
                        }
                    }
                }
            } catch (e: Throwable) {
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = mergePendingMediaUploads(chatId, messages)
                }
                toast = "couldn't send photo: ${e.message}"
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

    /** Send a recorded voice note (AAC .m4a bytes) to a White Noise chat — same
     *  media path as a photo, audio mime. (Android has no BLE file transfer yet,
     *  so voice notes ride White Noise / Marmot only.) */
    fun sendVoiceNote(chatId: String, bytes: ByteArray) {
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) { toast = "Start the secure chat first to send a voice note."; return@launch }
            val filename = "vn-${(1000..99999).random()}.m4a"
            val mime = "audio/mp4"
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
                messages = mergePendingMediaUploads(chatId, messages)
            }
            try {
                SonarCore.sendMedia(groupId, bytes, filename, mime, "")
                markPendingMediaCompleted(chatId, pendingId)
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) {
                            val peerId = meshPeerId(chatId)
                            val mesh = meshChats[peerId].orEmpty()
                            val wn = marmotMessagesForPeer(peerId)
                            val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
                            messages = merged
                            processPayLines(chatId, merged)
                        } else {
                            val fresh = SonarCore.messagesPage(groupId, LOCAL_TRANSCRIPT_PAGE_LIMIT)
                            messages = withSendEchoes(chatId, mergePendingMediaUploads(chatId, fresh))
                            processPayLines(chatId, messages)
                        }
                    }
                }
            } catch (e: Throwable) {
                markPendingMediaFailed(chatId, pendingId)
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = mergePendingMediaUploads(chatId, messages)
                }
                toast = "couldn't send voice note: ${e.message}"
            }
        }
    }

    fun sendGifItem(chatId: String, item: SonarGifItem) {
        send(chatId, item.mediaUrl)
    }

    fun sendStickerItem(chatId: String, sticker: SonarStickerItem, packCoordinate: String) {
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
        val cacheKey = "30030:${authorPubkeyHex.lowercase()}:$identifier"
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
     *  Noise link ⇒ BLE mesh; otherwise White Noise (Marmot) for a Sonar peer. When
     *  neither route is available the message is queued in the outbox (mirrors iOS
     *  MessageRouter) and auto-sent when the peer reconnects or their npub is learned. */
    private fun sendDmAuto(peerId: String, text: String) {
        if (outbox.contains(peerId)) {
            enqueueOutbox(peerId, text)
            flushOutbox(peerId)
            toast = "Message queued and will send in order."
            return
        }
        if (MeshRadio.hasMeshLink(peerId)) { sendMesh(peerId, text); return }
        val raw = npubRawFor(peerId)
        if (raw != null) { sendOverMarmot(peerId, raw, text); return }
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
            if (hasLiveMeshRoute(peerId)) {
                val ok = MeshRadio.sendMeshDmNow(peerId, randomMeshId(), text)
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
        val ok = MeshRadio.sendMeshDm(peerId, randomMeshId(), text)
        if (!ok) { toast = "Not connected over Bluetooth yet — stay close and try again"; return false }
        val msg = SonarMsg(randomMeshId(), npub, text, mine = true, MeshRadio.nowSecs())
        meshChats[peerId] = meshChats[peerId].orEmpty() + msg
        processPayLines(meshChatId(peerId), listOf(msg))
        persistMesh(peerId)
        scope.launch { refreshOpenDm(peerId) }
        refreshMeshDmRows()
        return true
    }

    /** Write-through a peer's BLE-mesh transcript so it survives an app restart
     *  (parity with the iOS MessageStore). Marmot/White Noise legs are NOT written
     *  here — they already persist in the encrypted SQLCipher DB. */
    private fun persistMesh(peerId: String) {
        val msgs = meshChats[peerId].orEmpty()
        scope.launch { MessageStore.saveMeshDm(peerId, msgs) }
    }

    /** Texts queued for a Sonar peer (keyed by npub hex) while their White Noise
     *  group is created on the first out-of-range send. Flushed by
     *  [flushPendingMarmot] once the group appears in [chats]. */
    private val pendingMarmotSends = mutableMapOf<String, MutableList<String>>()
    private val startingMarmotChats = mutableSetOf<String>()

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
    private fun flushPendingMarmot() {
        if (pendingMarmotSends.isEmpty()) return
        for ((npubHex, texts) in pendingMarmotSends.toMap()) {
            val group = marmotGroupForNpub(npubHex.hexToBytesOrEmpty()) ?: continue
            pendingMarmotSends.remove(npubHex)
            scope.launch { for (tx in texts) runCatching { SonarCore.send(group.id, tx) } }
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
            val delivered = if (MeshRadio.hasMeshLink(peerId)) {
                sendMesh(peerId, msg.content)
            } else {
                val raw = npubRawFor(peerId)
                if (raw != null) {
                    val groupId = marmotGroupId ?: ensureMarmotGroupForOutbox(peerId, raw)
                    marmotGroupId = groupId
                    groupId != null && sendOutboxOverMarmot(peerId, groupId, msg.content)
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

    private suspend fun sendOutboxOverMarmot(peerId: String, groupId: String, text: String): Boolean =
        try {
            SonarCore.send(groupId, text)
            refreshOpenDm(peerId)
            true
        } catch (e: Throwable) {
            toast = "send failed: ${e.message}"
            sonarLog("SonarOutbox", "failed to send queued White Noise message for ${peerId.take(10)}… err=${e.message}")
            false
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
        scope.launch {
            try {
                val chatId = SonarCore.startGroup(cleanMembers, cleanName)
                refreshChats()
                push(Screen.Chat(chatId, cleanName))
            } catch (e: Throwable) {
                toast = "couldn’t create group: ${e.message}"
            }
        }
    }

    fun addGroupMembers(chatId: String, members: List<String>) {
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
                    messages = withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPage(chatId)))
                    processPayLines(chatId, messages)
                }
            } catch (e: Throwable) {
                toast = "couldn't add people: ${e.message}"
            }
        }
    }

    fun removeGroupMembers(chatId: String, members: List<String>) {
        val cleanMembers = members.map { it.trim() }
            .filter { it.isNotEmpty() && it != npub }
            .distinct()
        if (cleanMembers.isEmpty()) return
        scope.launch {
            try {
                SonarCore.removeGroupMembers(chatId, cleanMembers)
                refreshChats()
                if ((screen as? Screen.Chat)?.id == chatId) {
                    messages = withSendEchoes(chatId, mergePendingMediaUploads(chatId, marmotMessagesPage(chatId)))
                    processPayLines(chatId, messages)
                }
            } catch (e: Throwable) {
                toast = "couldn't remove people: ${e.message}"
            }
        }
    }

    fun createInviteLink(chatId: String, groupName: String, onResult: (String) -> Unit) {
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
        scope.launch {
            try {
                val chatId = SonarCore.acceptGroupInvite(inviteId)
                refreshChats()
                chats.firstOrNull { it.id == chatId }?.let { push(Screen.Chat(chatId, chatTitle(it))) }
            } catch (e: Throwable) {
                toast = "couldn’t accept invite: ${e.message}"
            }
        }
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

    private fun peerIdForNpubHex(npubHex: String): String? =
        sonarPeerProfiles.entries.firstOrNull { (_, ann) -> ann.npub.toHexLower().equals(npubHex, ignoreCase = true) }?.key
            ?: linkByFp.entries.firstOrNull { it.value.equals(npubHex, ignoreCase = true) }?.key

    private fun peerIdForMarmotGroup(groupId: String): String? =
        foldedGroupPeerIds[groupId]
            ?: chats.firstOrNull { it.id == groupId }?.let { peerIdForMarmotGroup(it) }

    private fun peerIdForMarmotGroup(group: SonarChat): String? {
        val npubHex = npubHexForGroup(group) ?: return null
        return peerIdForNpubHex(npubHex) ?: inferPeerLinkByUniqueTitle(group, npubHex)
    }

    private fun inferPeerLinkByUniqueTitle(group: SonarChat, npubHex: String): String? {
        val groupTitle = chatTitle(group)
        val groupTitles = chats.map { chatTitle(it) }
        val peerTitles = (meshChats.keys + meshChatNames.keys)
            .distinct()
            .mapNotNull { peerId ->
                val existing = linkByFp[peerId]
                if (existing != null && !existing.equals(npubHex, ignoreCase = true)) return@mapNotNull null
                if (sonarProfile(peerId)?.npub?.toHexLower()?.equals(npubHex, ignoreCase = true) == false) return@mapNotNull null
                val name = meshChatNames[peerId]?.takeUnless { it.startsWith("mesh·") } ?: return@mapNotNull null
                peerId to name
            }
            .toMap()
        val peerId = inferUniquePeerByTitle(groupTitle, peerTitles, groupTitles) ?: return null
        linkByFp[peerId] = npubHex
        persistLinks()
        sonarLog("SonarWN", "Recovered BLE↔White Noise link by unique title peer=${peerId.take(10)} group=${group.id.take(10)} title=$groupTitle")
        return peerId
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
        marmotGroupsForNpub(npubRaw).firstOrNull()

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

    private suspend fun marmotMessagesForPeer(peerId: String): List<SonarMsg> {
        val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { peerIdForMarmotGroup(it) == peerId }
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
        if ((screen as? Screen.Chat)?.id != meshChatId(peerId)) return
        val chatId = meshChatId(peerId)
        val mesh = meshChats[peerId].orEmpty()
        val wn = marmotMessagesForPeer(peerId)
        val merged = withSendEchoes(chatId, mergePendingMediaUploads(chatId, mesh + wn))
        messages = merged
        processPayLines(chatId, merged)
        val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }
            ?: chats.filter { peerIdForMarmotGroup(it) == peerId }
        for (group in groups) {
            unreadByChat = unreadByChat - group.id
            runCatching { SonarCore.markConversationRead(group.id) }
        }
    }

    private fun observedMeshPeer(peerId: String): Boolean =
        peerId in rawMeshPeerIds

    private fun hasLiveMeshRoute(peerId: String): Boolean =
        observedMeshPeer(peerId) && MeshRadio.hasMeshLink(peerId)

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
        if (sonarProfile(peerId)?.speaksCalls == true) return true
        if (((linkCapsByFp[peerId] ?: 0) and SonarAnnounce.CAP_CALLS) != 0) return true
        val npubHex = npubRawFor(peerId)?.toHexLower() ?: return false
        sonarDescriptorsByNpubHex[npubHex]?.let { if (it.supportsCurrentCalls) return true }
        return false
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

    /** Drain mesh DMs received since last poll into the per-peer transcripts,
     *  surface them as Messages rows, and notify for ones we're not looking at. */
    private fun drainMeshDms() {
        val incoming = MeshRadio.drainMeshDm()
        if (incoming.isEmpty()) return
        val openChatId = (screen as? Screen.Chat)?.id
        val notifsOn = prefBool("notifs", true)
        val touched = mutableSetOf<String>()
        for (m in incoming) {
            val msg = SonarMsg(m.messageId.ifBlank { randomMeshId() }, m.peerId, m.text, mine = false, m.tsSecs)
            val chatId = meshChatId(m.peerId)
            // A ☎CALL control line arriving over the mesh link: route it to the
            // engine, never store/show it as a chat message.
            if (SonarCore.callParseControl(m.text) != null) {
                processCallLines(chatId, listOf(msg))
                continue
            }
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
            processPayLines(chatId, listOf(msg))
            touched += m.peerId
            if (notifsOn && !foreground && chatId != openChatId) {
                Notifier.notify(chatId.hashCode(), meshPeerName(m.peerId), notifPreview(m.text))
            }
        }
        touched.forEach { persistMesh(it) } // write-through so received DMs survive restart
        refreshMeshDmRows()
        // Refresh the open conversation (merged mesh + White Noise) if it's one we
        // just appended to.
        (screen as? Screen.Chat)?.let { sc ->
            if (isMeshChat(sc.id)) {
                val pid = meshPeerId(sc.id)
                if (incoming.any { it.peerId == pid }) scope.launch { refreshOpenDm(pid) }
            }
        }
    }

    /** Drain incoming public Mesh-channel broadcasts into the mesh transcript.
     *  The wire carries sender peerID + content; resolve the display nickname. */
    private fun drainMeshBroadcasts() {
        val incoming = MeshRadio.drainMeshBroadcast()
        if (incoming.isEmpty()) return
        val seen = meshBroadcast.mapTo(HashSet()) { it.id }
        val add = incoming
            .map {
                val id = "${it.senderId}-${it.tsSecs}"
                SonarChannelMsg(id, meshPeerName(it.senderId), it.senderId, it.content, mine = false, it.tsSecs)
            }
            .filter { it.id !in seen }
        if (add.isEmpty()) return
        meshBroadcast = (meshBroadcast + add).sortedBy { it.tsSecs }.takeLast(200)
        if ((screen as? Screen.Channel)?.geohash == "mesh") channelMsgs = meshBroadcast
    }

    /** Display name for a mesh peer: prefer the live radar name, else a remembered
     *  one, else a short id. Remembers whatever it resolves. */
    private fun meshPeerName(peerId: String): String {
        val live = meshPeers.firstOrNull { it.id == "mesh:$peerId" }?.name
        val profileName = npubStringForPeer(peerId)
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
        val remembered = meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }
        val name = live ?: profileName ?: remembered ?: ("mesh·" + peerId.take(6))
        meshChatNames[peerId] = name
        return name
    }

    private fun foldedPeerName(peerId: String, group: SonarChat?): String {
        meshPeers.firstOrNull { it.id == meshChatId(peerId) }?.name?.let {
            meshChatNames[peerId] = it
            return it
        }
        meshChatNames[peerId]?.takeUnless { it.isKeyFallbackName() }?.let { return it }
        npubStringForPeer(peerId)
            ?.let { profilesByNpub[canonicalProfileKey(it)]?.bestName }
            ?.let { name ->
                meshChatNames[peerId] = name
                return name
            }
        group?.let { return chatTitle(it) }
        return meshChatNames[peerId] ?: ("mesh·" + peerId.take(6))
    }

    private fun String.isKeyFallbackName(): Boolean =
        startsWith("mesh·") || startsWith("npub1")

    /** Recompute the observable mesh DM rows (newest conversation first). Fast,
     *  BLE-leg only — for immediate feedback on send/receive. [recomputeConversations]
     *  later folds in the White Noise leg. */
    private fun refreshMeshDmRows() {
        meshDmRows = meshChats.entries
            .filter { it.value.isNotEmpty() }
            .map { (pid, msgs) ->
                val last = msgs.last()
                MeshDmRow(pid, meshPeerName(pid), messagePreview(last.content), last.tsSecs)
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
        for ((peerId, msgs) in meshChats) {
            if (msgs.isEmpty()) continue
            var last = msgs.last()
            val groups = npubRawFor(peerId)?.let { marmotGroupsForNpub(it) }.orEmpty()
            if (groups.isNotEmpty()) {
                groups.forEach { folded += it.id }
                latestMarmotMessage(groups)?.let { if (it.tsSecs > last.tsSecs) last = it }
            }
            upsert(peerId, MeshDmRow(peerId, foldedPeerName(peerId, groups.firstOrNull()), messagePreview(last.content, last.stickerRef), last.tsSecs))
        }
        val groupPeers = LinkedHashMap<String, String>()
        for (group in chats) {
            if (!isDirectMarmotChat(group)) continue
            val peerId = peerIdForMarmotGroup(group) ?: continue
            folded += group.id
            groupPeers[group.id] = peerId
            val last = latestMarmotMessage(listOf(group))
            upsert(
                peerId,
                MeshDmRow(
                    peerId,
                    foldedPeerName(peerId, group),
                    last?.let { messagePreview(it.content, it.stickerRef) } ?: "Secure chat · reaches anywhere",
                    last?.tsSecs ?: 0L,
                )
            )
        }
        foldedGroupIds = folded
        foldedGroupPeerIds = groupPeers
        meshDmRows = rowsByPeer.values.sortedByDescending { it.tsSecs }
    }

    private fun persistChatSnapshot() {
        SonarCore.saveBlob(CHAT_SNAPSHOT_BLOB_KEY, encodeChatSnapshot(chats, chatSnapshotMessagesByChat))
    }

    private fun clearChatSnapshot() {
        chatSnapshotMessagesByChat = emptyMap()
        SonarCore.saveBlob(CHAT_SNAPSHOT_BLOB_KEY, "")
    }

    private suspend fun refreshChats() {
        val loadedChats = SonarCore.chats()
        if (started || loadedChats.isNotEmpty()) {
            chats = loadedChats
            val activeIds = loadedChats.mapTo(hashSetOf()) { it.id }
            chatSnapshotMessagesByChat = chatSnapshotMessagesByChat.filterKeys { it in activeIds }
            persistChatSnapshot()
        }
        refreshTopChatLocalSummaries()
        for (c in chats) {
            c.members.forEach {
                if (it != npub && it.isNotBlank()) ensureSonarDescriptor(it)
            }
        }
        groupInvites = runCatching { SonarCore.pendingGroupInvites() }.getOrDefault(emptyList())
    }

    private suspend fun refreshTopChatLocalSummaries() {
        if (chats.isEmpty()) return
        val updated = chatSnapshotMessagesByChat.toMutableMap()
        val pages = runCatching {
            SonarCore.recentMessagePages(LOCAL_SUMMARY_CHAT_LIMIT, LOCAL_SUMMARY_PAGE_LIMIT)
        }.getOrDefault(emptyList())
        for (page in pages) {
            if (page.messages.isNotEmpty()) {
                updated[page.chatId] = page.messages
            }
        }
        chatSnapshotMessagesByChat = updated
        orderChatsByLocalRecency()
        persistChatSnapshot()
        refreshUnreadCounts()
    }

    private fun orderChatsByLocalRecency() {
        chats = chats.withIndex()
            .sortedWith(
                compareByDescending<IndexedValue<SonarChat>> {
                    chatSnapshotMessagesByChat[it.value.id]?.lastOrNull()?.tsSecs ?: 0L
                }.thenBy { it.index }
            )
            .map { it.value }
    }

    @OptIn(kotlinx.coroutines.FlowPreview::class)
    private fun collectConversationChanges() {
        SonarCore.conversationChanged
            .debounce(50)
            .onEach { groupIdHex ->
                refreshChats()
                val changedMessages = marmotMessagesPage(groupIdHex)
                processPayLines(groupIdHex, changedMessages)
                processCallLines(groupIdHex, changedMessages)
                (screen as? Screen.Chat)?.let { sc ->
                    if (!isMeshChat(sc.id) && sc.id == groupIdHex) {
                        messages = withSendEchoes(sc.id, mergePendingMediaUploads(sc.id, changedMessages))
                    } else if (isMeshChat(sc.id)) {
                        val peerId = peerIdForMarmotGroup(groupIdHex)
                        if (peerId != null && sc.id == meshChatId(peerId)) {
                            refreshOpenDm(peerId)
                        }
                    }
                }
            }
            .launchIn(scope)
    }

    private suspend fun refreshUnreadCounts() {
        val summaries = runCatching { SonarCore.conversationSummaries() }.getOrDefault(emptyList())
        val counts = mutableMapOf<String, Long>()
        for (s in summaries) {
            if (s.unreadCount > 0) counts[s.groupIdHex] = s.unreadCount
        }
        unreadByChat = counts
    }

    private fun poll() {
        if (pollJob?.isActive == true) return
        pollJob = scope.launch {
            var tick = 0
            while (true) {
                delay(4000)
                tick++
                SonarCore.sync()
                refreshChats()
                // Observability for the BLE→White Noise fallback: a new Marmot
                // group (a Welcome received over relays) or a grown transcript is
                // the signal that White Noise delivery reached us. Logged only on
                // change so a cross-device round trip shows up in logcat.
                // Fetch each chat's messages once: sum sizes (observability) AND
                // scan for inbound ☎CALL lines so a call rings even when the chat
                // isn't open (the offer arrives over White Noise/Marmot).
                var wnMsgs = 0
                val senders = mutableSetOf<String>()
                for (c in chats) {
                    val ms = runCatching { SonarCore.messagesPage(c.id, LOCAL_TRANSCRIPT_PAGE_LIMIT) }.getOrDefault(emptyList())
                    wnMsgs += ms.size
                    processCallLines(c.id, ms)
                    processPayLines(c.id, ms)
                    if (c.members.size > 2) {
                        for (m in ms) {
                            if (!m.mine && m.senderNpub.isNotBlank()) senders.add(m.senderNpub)
                        }
                    }
                }
                if (chats.size != lastWnGroups || wnMsgs != lastWnMsgs) {
                    sonarLog("SonarWN", "White Noise: ${chats.size} group(s), $wnMsgs message(s)")
                    lastWnGroups = chats.size; lastWnMsgs = wnMsgs
                }
                // Resolve kind-0 profiles for chat members and message senders
                // so chats show human names, not raw npubs.
                for (c in chats) c.members.forEach { if (it != npub) ensureProfile(it) }
                senders.forEach { ensureProfile(it) }
                // Re-fetch stale profiles every ~30 minutes (450 ticks × 4s).
                if (tick % 450 == 0) {
                    val now = SonarClock.nowSecs()
                    val stale = profileFetchedAt.entries
                        .filter { now - it.value >= PROFILE_REFRESH_TTL_SECS }
                        .map { it.key }
                    stale.forEach { profileFetches.remove(it); profileFetchedAt.remove(it) }
                }
                flushPendingMarmot() // a queued out-of-range send whose group just landed
                flushAllOutbox() // retry any outbox messages whose peer is now reachable
                maybeNotify()
                // Marmot/Nostr chats refresh from the core; mesh chats are local
                // and refreshed by drainMeshDms() below. A mesh-route DM merges
                // both legs (mesh + White Noise) via refreshOpenDm.
                (screen as? Screen.Chat)?.let {
                    if (isMeshChat(it.id)) refreshOpenDm(meshPeerId(it.id))
                    else {
                        messages = withSendEchoes(it.id, mergePendingMediaUploads(it.id, marmotMessagesPage(it.id)))
                        processPayLines(it.id, messages)
                    }
                }
                (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
                (screen as? Screen.GeoDm)?.let { refreshGeoDm(it.geohash, it.peerHex) }
                // Sonar Discovery (0x53): keep our announce current for outgoing
                // links and decode any peers' announces received over the mesh.
                refreshMeshIdentity()
                // Persist each peer's fingerprint→npub so its conversation stays
                // unified after it leaves range / after a restart, then re-fold the
                // White Noise legs into the mesh rows (one row per person).
                refreshSonarDiscoveryProfiles()
                updateMeshPeersFromRadio()
                recomputeConversations()
                // Unify nearby: keep the payer scan alive and refresh peers +
                // the receiver advertising (wallet/foreground gated).
                startUnify()
                unifyPeers = UnifyRadio.peers()
                updateUnifyReceiver()
                if (locationChannels.isEmpty()) refreshLocationChannels()
                // Presence: like iOS GeohashPresenceService, broadcast to the
                // low-precision channels (region/province/city) on a ~60s
                // heartbeat so others count us; then refresh "here now" counts.
                if (tick % 15 == 1) beatGlobalPresence()
                refreshPresenceCounts()
                if (walletAvailable && walletState is WalletState.Ready) {
                    WalletBridge.refreshBalance()
                    walletState = WalletBridge.state()
                }
            }
        }
    }

    /** BLE mesh is the real-time rail for calls, so it must not wait for the
     *  heavier White Noise/Nostr sync poll. Drain lightweight mesh queues often
     *  enough that ANSWER/END controls reach the call engine without UI-visible
     *  delay. */
    private fun startMeshRealtimeLoop() {
        if (meshRealtimeLoopRunning) return
        meshRealtimeLoopRunning = true
        scope.launch {
            while (true) {
                drainMeshDms()
                drainMeshBroadcasts()
                delay(150)
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
