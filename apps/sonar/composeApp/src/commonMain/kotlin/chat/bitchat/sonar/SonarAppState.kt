package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.store.MessageMerge
import chat.bitchat.sonar.store.MessageStore
import chat.bitchat.sonar.unify.UnifyBIP321
import chat.bitchat.sonar.unify.UnifyPeer
import chat.bitchat.sonar.unify.UnifyRadio
import chat.bitchat.sonar.wallet.ExchangeRate
import chat.bitchat.sonar.wallet.FiatCurrency
import chat.bitchat.sonar.wallet.Money
import chat.bitchat.sonar.wallet.WalletBridge
import chat.bitchat.sonar.wallet.WalletState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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
    // Full-screen voice/video call (MOCK — no real audio/video). [peerId] is the
    // backing chat id (e.g. "mesh:<id>" or a Marmot group id) so the call log
    // appends to the right conversation; [video] picks voice vs video layout.
    data class Call(val peerId: String, val name: String, val video: Boolean) : Screen
}

/** A BLE-mesh DM conversation row for the home Messages list. */
data class MeshDmRow(val peerId: String, val name: String, val preview: String, val tsSecs: Long)

/** A MOCKED call-log record appended to a DM transcript when a call ends. Lives
 *  in memory only (no MessageStore/SonarCore/Marmot write) — the next step
 *  replaces the mock with real P2P. [durSecs] == 0 ⇒ the call never connected
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
)

/** Verify-sheet model: the safety groups (empty ⇒ show [note]) + verified flag. */
data class SonarVerify(val safety: List<String>, val verified: Boolean, val note: String?)

/**
 * Shared (commonMain) UI state for the Sonar app. Drives White Noise (Marmot)
 * encrypted DMs through [SonarCore]; the same logic will back the iOS app once
 * it shifts to Compose Multiplatform.
 */
class SonarAppState(private val scope: CoroutineScope) {
    var npub by mutableStateOf("")
        private set
    var started by mutableStateOf(false)
        private set
    var connecting by mutableStateOf(false)
        private set
    var chats by mutableStateOf<List<SonarChat>>(emptyList())
        private set
    /** Resolved kind-0 profiles by npub — fills human names for Marmot members. */
    var profilesByNpub by mutableStateOf<Map<String, SonarProfile>>(emptyMap())
        private set
    private val profileFetches = mutableSetOf<String>()
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
            MeshRadio.setLocalSonarAnnounce(null); sonarPeerProfiles = emptyMap()
            linkByFp.clear(); foldedGroupIds = emptySet()
            MessageStore.wipe()
            SonarCore.wipe()
            stack = listOf(Screen.Home)
            chats = emptyList(); messages = emptyList()
            onboarded = false; nick = ""; npub = ""; started = false
            walletState = WalletState.NotConfigured
            presenceByGeohash = emptyMap()
            payLedger = SonarPayLedger(); scannedPay.clear(); payVersion++
            mediaCache.clear()
            callLogs.clear(); callVersion++
            resetCallState()
        }
    }

    /** Tear down call state on wipe so calling rebinds cleanly after re-onboarding
     *  (the node is recreated, so the iroh endpoint must be re-bound). */
    private fun resetCallState() {
        callTicker?.cancel(); callTicker = null
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
            meshChats.clear(); meshChatNames.clear(); pendingMarmotSends.clear()
            linkByFp.clear(); persistLinks(); foldedGroupIds = emptySet()
            meshBroadcast = emptyList(); meshDmRows = emptyList()
            messages = emptyList(); channelMsgs = emptyList(); chats = emptyList()
            lastWnGroups = -1; lastWnMsgs = -1
            // ⚡PAY coins live inside the erased chats — reset the ledger. The
            // Lightning wallet seed/balance is separate and is NOT touched.
            payLedger = SonarPayLedger(); persistPay(); scannedPay.clear(); payVersion++
            mediaCache.clear()
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
     *  and send the ☎CALL OFFER (with our dialable address) over the chat. */
    fun placeCall(chatId: String, peerName: String, video: Boolean) {
        if (activeCall != null) { toast = "Already in a call"; return }
        val callId = randomMeshId()
        // Show the ringing screen IMMEDIATELY so the tap is responsive; the iroh
        // setup (bind/offer) runs below. (ensureCallStarted is idempotent — it
        // guards on callStarted, so unlike the old iOS path it never re-binds.)
        activeCall = ActiveCall(callId, chatId, peerName, video, incoming = false, phase = SonarCallState.Ringing)
        push(Screen.Call(chatId, peerName, video))
        scope.launch {
            ensureCallStarted()
            if (!callStarted) { toast = "Calling isn’t available right now"; activeCall = null; back(); return@launch }
            try {
                val addr = SonarCore.callLocalAddress()
                SonarCore.callPlace(callId, video)
                if (activeCall?.callId == callId) // user may have ended already
                    send(chatId, SonarCore.callEncodeOffer(callId, video, addr, SonarClock.nowSecs()))
            } catch (e: Throwable) {
                toast = "call failed: ${e.message}"
                if (activeCall?.callId == callId) { activeCall = null; back() }
            }
        }
    }

    /** Accept the incoming call: send ANSWER|accept (with our address), then dial. */
    fun acceptCall() {
        val c = activeCall ?: return
        scope.launch {
            try {
                val addr = SonarCore.callLocalAddress()
                send(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Accept, addr))
                SonarCore.callAccept(c.callId)
            } catch (e: Throwable) { toast = "couldn’t accept: ${e.message}" }
        }
    }

    /** Decline the incoming call: send ANSWER|decline + tear down the local slot. */
    fun declineCall() {
        val c = activeCall ?: return
        scope.launch {
            runCatching { send(c.chatId, SonarCore.callEncodeAnswer(c.callId, SonarAnswer.Decline, "")) }
            runCatching { SonarCore.callHangup(c.callId) } // engine Ended event finalizes
        }
    }

    /** Hang up an outgoing/connected call: tear down media + signal END. The
     *  engine's Ended event records the call-log entry and pops the screen. */
    fun hangupCall() {
        val c = activeCall ?: return
        scope.launch {
            runCatching { SonarCore.callHangup(c.callId) }
            runCatching { send(c.chatId, SonarCore.callEncodeEnd(c.callId, "hangup")) }
        }
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
        ensureCallStarted()
        when (ctrl) {
            is SonarCallControl.Offer -> {
                if (activeCall != null) { // busy: auto-decline
                    runCatching { send(chatId, SonarCore.callEncodeAnswer(ctrl.callId, SonarAnswer.Busy, "")) }
                    return
                }
                runCatching { SonarCore.callIncomingOffer(ctrl.callId, ctrl.addrB64, ctrl.video) }
                // A stale offer (peer rang while we were offline) is a missed call.
                if (SonarClock.nowSecs() - ctrl.unixSecs > 60) {
                    runCatching { SonarCore.callHangup(ctrl.callId) }
                    callLogs.getOrPut(chatId) { mutableListOf() }
                        .add(CallRecord(video = ctrl.video, mine = false, durSecs = 0, tsSecs = SonarClock.nowSecs()))
                    callVersion++
                    return
                }
                val name = callPeerName(chatId)
                activeCall = ActiveCall(ctrl.callId, chatId, name, ctrl.video, incoming = true, phase = SonarCallState.Ringing)
                push(Screen.Call(chatId, name, ctrl.video))
            }
            is SonarCallControl.Answer ->
                runCatching { SonarCore.callAnswer(ctrl.callId, ctrl.answer, ctrl.addrB64) }
            is SonarCallControl.Cancel, is SonarCallControl.End ->
                if (activeCall?.callId == ctrl.callId) runCatching { SonarCore.callHangup(ctrl.callId) }
        }
    }

    /** A human name for the chat the incoming call arrived on. */
    private fun callPeerName(chatId: String): String =
        if (isMeshChat(chatId)) meshPeerName(meshPeerId(chatId))
        else chats.firstOrNull { it.id == chatId }
            ?.members?.firstOrNull { it != npub && it.isNotBlank() }
            ?.let { profilesByNpub[it]?.bestName ?: (it.take(10) + "…") } ?: "secure chat"
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
    /** Nearby Unify Wallet users (payments-only, gold badge on the radar). */
    var unifyPeers by mutableStateOf<List<UnifyPeer>>(emptyList())
        private set
    /** Sonar Discovery profiles received over mesh links, keyed by peer id. */
    var sonarPeerProfiles by mutableStateOf<Map<String, SonarAnnounce>>(emptyMap())
        private set

    /** The Sonar Discovery profile for a mesh peer (its BLE id), if any. */
    fun sonarProfile(peerId: String): SonarAnnounce? = sonarPeerProfiles[peerId]

    /** Durable BLE-fingerprint → Nostr-npub(hex) links, learned from 0x53 Sonar
     *  announces and PERSISTED (blob "sonar.links"). This is what makes one
     *  conversation survive the transport switch: a Sonar peer met over Bluetooth
     *  keeps the SAME thread when they leave range and we reach them over White
     *  Noise (internet) — and after an app restart. Mirrors iOS's persisted
     *  Noise↔Nostr mapping (FavoritesPersistenceService / sonarProfilesByFingerprint). */
    private val linkByFp = mutableMapOf<String, String>()

    /** Marmot groups currently FOLDED into a BLE-mesh DM row (same person via
     *  [linkByFp]) — hidden from the standalone White Noise list so a person never
     *  shows up twice. Display-only: the group still lives in [chats]. */
    private var foldedGroupIds by mutableStateOf<Set<String>>(emptySet())

    /** White Noise chats to render on their own row: every Marmot group EXCEPT the
     *  ones folded into a mesh DM. The Messages list uses this instead of [chats]. */
    val visibleChats: List<SonarChat> get() = chats.filterNot { it.id in foldedGroupIds }

    /** This peer's npub (32 raw bytes) if known — from a live 0x53 OR the persisted
     *  [linkByFp] (so it still resolves out of range / after restart). The bridge
     *  that unifies the BLE-Noise and White-Noise legs of one conversation. */
    private fun npubRawFor(peerId: String): ByteArray? =
        sonarProfile(peerId)?.npub
            ?: linkByFp[peerId]?.hexToBytesOrEmpty()?.takeIf { it.size == 32 }

    private fun loadLinks() {
        SonarCore.loadBlob("sonar.links").lineSequence().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0) linkByFp[line.substring(0, i)] = line.substring(i + 1).trim()
        }
    }

    private fun persistLinks() {
        SonarCore.saveBlob("sonar.links", linkByFp.entries.joinToString("\n") { "${it.key}=${it.value}" })
    }

    /** Record fingerprint→npub from a 0x53 (persisted on change). */
    private fun rememberLink(peerId: String, npubHex: String) {
        if (npubHex.length == 64 && linkByFp[peerId] != npubHex) {
            linkByFp[peerId] = npubHex
            persistLinks()
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
        if (!walletAvailable) return
        scope.launch {
            WalletBridge.setupIfNeeded(SonarCore.identityNsec())
            walletState = WalletBridge.state()
            WalletBridge.fetchRates()
            rate = WalletBridge.cachedRate(currency)
        }
    }

    // ── ⚡PAY ledger (sealed-coin auto-claim, 1:1 with iOS) ──
    private var payLedger = SonarPayLedger(SonarCore.loadBlob("pay.ledger"))
    private val scannedPay = HashSet<String>()
    /** Bumped whenever the ledger changes, so pay bubbles recompose. */
    var payVersion by mutableStateOf(0)
        private set

    fun payStatus(uuid: String): PayStatus? = payLedger.get(uuid)?.status

    private fun persistPay() { SonarCore.saveBlob("pay.ledger", payLedger.serialize()) }

    /** Scan a chat's transcript for ⚡PAY control lines and drive the state machine. */
    fun processPayLines(chatId: String, msgs: List<SonarMsg>) {
        var changed = false
        for (m in msgs) {
            when (val line = PayLine.decode(m.content)) {
                is PayLine.Pay -> if (payLedger.recordSealed(line.uuid, line.sats, m.mine)) changed = true
                is PayLine.Claim -> if (scannedPay.add("claim:${line.uuid}")) {
                    val e = payLedger.get(line.uuid)
                    // Only the original sender settles a coin they sealed.
                    if (e != null && e.mine && e.status == PayStatus.Sealed) {
                        if (payLedger.markSettling(line.uuid)) changed = true
                        settle(chatId, line.uuid, line.offer, e.sats)
                    }
                }
                is PayLine.Done -> if (payLedger.markClaimed(line.uuid)) changed = true
                null -> {}
            }
        }
        if (changed) { persistPay(); payVersion++ }
    }

    /** Sender side: pay the claimant's BOLT12 offer, then confirm with ⚡PAYDONE. */
    private fun settle(chatId: String, uuid: String, offer: String, sats: Long) {
        scope.launch {
            val ok = walletAvailable && WalletBridge.send(offer, sats, "Sonar coin")
            if (ok) {
                payLedger.markClaimed(uuid)
                runCatching { SonarCore.send(chatId, PayLine.Done(uuid).encoded()) }
                walletState = WalletBridge.state()
            } else {
                payLedger.fail(uuid)
            }
            persistPay(); payVersion++
        }
    }

    /** Receiver side: create a fresh BOLT12 offer and return it via ⚡PAYCLAIM. */
    fun claimPay(chatId: String, uuid: String) {
        if (!walletAvailable || walletState !is WalletState.Ready) {
            toast = "Set up a wallet to claim payments."
            return
        }
        scope.launch {
            try {
                val offer = WalletBridge.createOffer()
                payLedger.markClaiming(uuid)
                SonarCore.send(chatId, PayLine.Claim(uuid, offer).encoded())
                persistPay(); payVersion++
            } catch (e: Throwable) {
                toast = "claim failed: ${e.message}"
            }
        }
    }

    /** Start the BLE mesh radio (call once permissions are granted). */
    fun startMesh() {
        MeshRadio.start()
        meshPeers = MeshRadio.peers()
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
            val ok = WalletBridge.send(dest, amountSats, "Sonar nearby")
            walletState = WalletBridge.state()
            toast = if (ok) "Sent ${amountSats} sats" else "Payment failed"
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

    // ── Verify safety numbers (1:1 with iOS) ──
    fun isVerified(chatId: String): Boolean = SonarCore.loadBlob("verified.$chatId") == "1"

    fun markVerified(chatId: String) {
        SonarCore.saveBlob("verified.$chatId", "1")
        payVersion++ // recompose verify-dependent UI
        toast = "Marked as verified"
    }

    /** Verify info for a Marmot chat: the 12 safety groups, or an honest note. */
    fun verifyInfo(chatId: String): SonarVerify {
        val peer = chats.firstOrNull { it.id == chatId }
            ?.members?.firstOrNull { it != npub && it.isNotBlank() }
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
    }

    fun updateNickname(value: String) {
        SonarCore.setNickname(value)
        nick = value
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
            val msgs = SonarCore.messages(c.id)
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
                started = true
                // Publish our kind-0 profile so peers see our nickname, not npub.
                launch { runCatching { SonarCore.publishProfile(nick) } }
                // Hydrate BLE-mesh transcripts from disk so private mesh chats
                // survive a restart (parity with the iOS MessageStore). Precedes
                // refreshMeshDmRows so the Messages list is populated at launch.
                meshChats.putAll(MessageStore.loadAllMeshDms())
                loadLinks() // durable fingerprint↔npub so BLE chats stay unified after restart
                refreshMeshDmRows()
                setupWallet()
                refreshLocationChannels()
                refreshChats()
                recomputeConversations() // fold White Noise legs into mesh rows at launch
                // Bind the iroh call endpoint + start the call event loop early so
                // an incoming call rings without us having to place one first.
                launch { ensureCallStarted() }
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
        val other = chat.members.firstOrNull { it != npub && it.isNotBlank() } ?: return "Secure chat"
        // Prefer the counterpart's resolved kind-0 profile name; fetch it once if
        // not cached; fall back to a short npub until it lands.
        profilesByNpub[other]?.bestName?.let { return it }
        ensureProfile(other)
        return if (other.length > 16) other.take(10) + "…" + other.takeLast(4) else other
    }

    /** Fetch + cache a peer's kind-0 profile once, so their name replaces the
     *  raw npub in the chat list/header. */
    fun ensureProfile(otherNpub: String) {
        if (otherNpub.isBlank() || otherNpub == npub) return
        if (profilesByNpub.containsKey(otherNpub)) return // already resolved
        if (!profileFetches.add(otherNpub)) return        // fetch already in flight
        scope.launch {
            val p = SonarCore.fetchProfile(otherNpub)
            if (p?.bestName != null) {
                profilesByNpub = profilesByNpub + (otherNpub to p)
            } else {
                // Not published yet — allow a later retry (driven by poll()).
                profileFetches.remove(otherNpub)
            }
        }
    }

    fun openChat(chat: SonarChat) {
        push(Screen.Chat(chat.id, chatTitle(chat)))
        scope.launch {
            messages = SonarCore.messages(chat.id)
            processPayLines(chat.id, messages)
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
        scope.launch { refreshChats(); refreshOpenDm(peerId) }
    }

    private fun meshChatId(peerId: String) = "mesh:$peerId"
    private fun meshPeerId(chatId: String) = chatId.removePrefix("mesh:")
    private fun isMeshChat(chatId: String) = chatId.startsWith("mesh:")

    fun back() {
        if (stack.size > 1) stack = stack.dropLast(1)
        messages = emptyList()
        scope.launch { refreshChats() }
    }

    /** Desktop master-detail helper: collapse the nav stack to [Screen.Home] so
     *  the content pane shows the welcome placeholder. Called before selecting a
     *  sidebar item so the stack never grows unbounded and a screen's Back button
     *  deselects (returns to the welcome pane) instead of walking history. */
    fun resetToHome() {
        if (stack.size > 1) { stack = listOf(Screen.Home); messages = emptyList() }
    }

    /** True when the desktop content pane should show the welcome placeholder. */
    val isHome: Boolean get() = stack.size == 1

    /** Delete ONE White Noise (Marmot) chat locally (messages + MLS keys) and
     *  drop it from the list. Local-only — the peer is not notified. */
    fun deleteMarmotChat(chatId: String) {
        val wasOpen = (stack.lastOrNull() as? Screen.Chat)?.id == chatId
        chats = chats.filterNot { it.id == chatId }
        if (wasOpen && stack.size > 1) stack = stack.dropLast(1) // pop WITHOUT refresh
        scope.launch {
            SonarCore.deleteChat(chatId)
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
                SonarCore.startChat(p)
                refreshChats()
                toast = "chat started"
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
        scope.launch {
            try {
                SonarCore.send(chatId, t)
                messages = SonarCore.messages(chatId)
                processPayLines(chatId, messages)
                processCallLines(chatId, messages)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
    }

    // ── Media (White Noise / Marmot MIP-04) ──
    /** Decrypted-media cache (raw bytes), keyed by the ciphertext's Blossom URL. */
    private val mediaCache = mutableMapOf<String, ByteArray>()

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
            try {
                SonarCore.sendMedia(groupId, data, filename, mime, "")
                // Refresh the open conversation so the sent image shows.
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) {
                        if (isMeshChat(chatId)) refreshOpenDm(meshPeerId(chatId))
                        else { messages = SonarCore.messages(groupId); processPayLines(chatId, messages) }
                    }
                }
            } catch (e: Throwable) {
                toast = "couldn't send photo: ${e.message}"
            }
        }
    }

    /** Send a recorded voice note (AAC .m4a bytes) to a White Noise chat — same
     *  media path as a photo, audio mime. (Android has no BLE file transfer yet,
     *  so voice notes ride White Noise / Marmot only.) */
    fun sendVoiceNote(chatId: String, bytes: ByteArray) {
        scope.launch {
            val groupId = resolveMarmotGroupId(chatId)
            if (groupId == null) { toast = "Start the secure chat first to send a voice note."; return@launch }
            try {
                SonarCore.sendMedia(groupId, bytes, "vn-${(1000..99999).random()}.m4a", "audio/mp4", "")
                (screen as? Screen.Chat)?.let { sc ->
                    if (sc.id == chatId) { messages = SonarCore.messages(groupId); processPayLines(chatId, messages) }
                }
            } catch (e: Throwable) {
                toast = "couldn't send voice note: ${e.message}"
            }
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
     *  Noise link ⇒ BLE mesh; otherwise White Noise (Marmot) for a Sonar peer. A
     *  plain bitchat peer out of range waits (Step 2 adds favorite → NIP-17). */
    private fun sendDmAuto(peerId: String, text: String) {
        if (MeshRadio.hasMeshLink(peerId)) { sendMesh(peerId, text); return }
        val raw = npubRawFor(peerId)
        if (raw != null) { sendOverMarmot(peerId, raw, text); return }
        toast = "Out of range — your message will wait until you’re close again."
    }

    /** Send a BLE-mesh DM over the Noise link + optimistically echo it. */
    private fun sendMesh(peerId: String, text: String) {
        val ok = MeshRadio.sendMeshDm(peerId, randomMeshId(), text)
        if (!ok) { toast = "Not connected over Bluetooth yet — stay close and try again"; return }
        val msg = SonarMsg(randomMeshId(), npub, text, mine = true, MeshRadio.nowSecs())
        meshChats[peerId] = meshChats[peerId].orEmpty() + msg
        persistMesh(peerId)
        scope.launch { refreshOpenDm(peerId) }
        refreshMeshDmRows()
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

    /** Continue a Sonar-peer conversation over White Noise (Marmot) when out of
     *  Bluetooth range, creating the 1:1 group on first send (mirrors iOS
     *  `sendOverMarmot`). */
    private fun sendOverMarmot(peerId: String, npubRaw: ByteArray, text: String) {
        val group = marmotGroupForNpub(npubRaw)
        if (group != null) {
            scope.launch {
                try { SonarCore.send(group.id, text); refreshOpenDm(peerId) }
                catch (e: Throwable) { toast = "send failed: ${e.message}" }
            }
            return
        }
        pendingMarmotSends.getOrPut(npubRaw.toHexLower()) { mutableListOf() }.add(text)
        toast = "Out of range — continuing over White Noise…"
        scope.launch {
            try {
                SonarCore.startChat(npubRaw.toHexLower()) // start_dm accepts a hex pubkey
                refreshChats(); flushPendingMarmot(); refreshOpenDm(peerId)
            } catch (e: Throwable) { toast = "couldn’t start secure chat: ${e.message}" }
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

    /** The White Noise (Marmot) 1:1 group whose member list contains [npubRaw].
     *  Member npubs are bech32, so decode each and compare the raw 32 bytes. */
    private fun marmotGroupForNpub(npubRaw: ByteArray): SonarChat? {
        if (npubRaw.isEmpty()) return null
        return chats.firstOrNull { c ->
            c.members.any { m ->
                chat.bitchat.sonar.crypto.Bech32.decode(m)
                    ?.takeIf { it.hrp == "npub" }?.data?.contentEquals(npubRaw) == true
            }
        }
    }

    /** Rebuild the open Sonar-peer DM transcript: the mesh leg plus, for a Sonar
     *  peer with a Marmot group, the White Noise leg merged chronologically. The
     *  White Noise leg renders as internet (indigo). No-op if that DM isn't open. */
    private suspend fun refreshOpenDm(peerId: String) {
        if ((screen as? Screen.Chat)?.id != meshChatId(peerId)) return
        val mesh = meshChats[peerId].orEmpty()
        val group = npubRawFor(peerId)?.let { marmotGroupForNpub(it) }
        val merged = if (group != null) {
            val wn = SonarCore.messages(group.id).map { it.copy(viaInternet = true) }
            (mesh + wn).sortedBy { it.tsSecs }
        } else mesh
        messages = merged
        processPayLines(meshChatId(peerId), merged)
    }

    /** True while a live Noise link to [peerId] exists (peer is in Bluetooth range). */
    fun dmInRange(peerId: String): Boolean = MeshRadio.hasMeshLink(peerId)

    /** True if we know this peer's **White Noise account** (npub) — from a live
     *  0x53 OR the persisted link (so it stays true out of Bluetooth range). An
     *  npub IS a White Noise account, so this gates White-Noise *reachability*, not
     *  a "Sonar app" tier: any account we know is reachable over the internet. */
    fun hasWhiteNoiseAccount(peerId: String): Boolean = npubRawFor(peerId) != null

    /** True if [chatId]'s peer can be voice/video called: calls are a Sonar-only
     *  feature, so the peer must be a mesh-routed Sonar peer whose 0x53 profile
     *  advertised CAP_CALLS. A White Noise / non-Sonar chat cannot be called. */
    /** A chat is callable when it is a BLE-discovered Sonar peer advertising the
     *  calls capability, OR a White Noise (Marmot) 1:1 chat — both parties there
     *  are Sonar users, the ☎CALL signaling rides the group, and the media goes
     *  over iroh/internet (no Bluetooth proximity required). */
    fun canCall(chatId: String): Boolean =
        if (isMeshChat(chatId)) sonarProfile(meshPeerId(chatId))?.speaksCalls == true
        else chats.any { it.id == chatId }

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
            val msg = SonarMsg(randomMeshId(), m.peerId, m.text, mine = false, m.tsSecs)
            val chatId = meshChatId(m.peerId)
            // A ☎CALL control line arriving over the mesh link: route it to the
            // engine, never store/show it as a chat message.
            if (SonarCore.callParseControl(m.text) != null) {
                processCallLines(chatId, listOf(msg))
                continue
            }
            meshChats[m.peerId] = meshChats[m.peerId].orEmpty() + msg
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
        val name = live ?: meshChatNames[peerId] ?: ("mesh·" + peerId.take(6))
        meshChatNames[peerId] = name
        return name
    }

    /** Recompute the observable mesh DM rows (newest conversation first). Fast,
     *  BLE-leg only — for immediate feedback on send/receive. [recomputeConversations]
     *  later folds in the White Noise leg. */
    private fun refreshMeshDmRows() {
        meshDmRows = meshChats.entries
            .filter { it.value.isNotEmpty() }
            .map { (pid, msgs) ->
                val last = msgs.last()
                MeshDmRow(pid, meshPeerName(pid), last.content, last.tsSecs)
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
        val rows = ArrayList<MeshDmRow>(meshChats.size)
        val folded = HashSet<String>()
        for ((peerId, msgs) in meshChats) {
            if (msgs.isEmpty()) continue
            var last = msgs.last()
            val group = npubRawFor(peerId)?.let { marmotGroupForNpub(it) }
            if (group != null) {
                folded += group.id
                runCatching { SonarCore.messages(group.id) }.getOrDefault(emptyList())
                    .lastOrNull()?.let { if (it.tsSecs > last.tsSecs) last = it }
            }
            rows.add(MeshDmRow(peerId, meshPeerName(peerId), last.content, last.tsSecs))
        }
        foldedGroupIds = folded
        meshDmRows = rows.sortedByDescending { it.tsSecs }
    }

    private suspend fun refreshChats() {
        chats = SonarCore.chats()
    }

    private fun poll() {
        scope.launch {
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
                for (c in chats) {
                    val ms = runCatching { SonarCore.messages(c.id) }.getOrDefault(emptyList())
                    wnMsgs += ms.size
                    processCallLines(c.id, ms)
                }
                if (chats.size != lastWnGroups || wnMsgs != lastWnMsgs) {
                    sonarLog("SonarWN", "White Noise: ${chats.size} group(s), $wnMsgs message(s)")
                    lastWnGroups = chats.size; lastWnMsgs = wnMsgs
                }
                // Resolve each counterpart's kind-0 profile (retries until they
                // publish one) so chats show a human name, not a raw npub.
                for (c in chats) c.members.forEach { if (it != npub) ensureProfile(it) }
                flushPendingMarmot() // a queued out-of-range send whose group just landed
                maybeNotify()
                // Marmot/Nostr chats refresh from the core; mesh chats are local
                // and refreshed by drainMeshDms() below. A mesh-route DM merges
                // both legs (mesh + White Noise) via refreshOpenDm.
                (screen as? Screen.Chat)?.let {
                    if (isMeshChat(it.id)) refreshOpenDm(meshPeerId(it.id))
                    else { messages = SonarCore.messages(it.id); processPayLines(it.id, messages) }
                }
                (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
                (screen as? Screen.GeoDm)?.let { refreshGeoDm(it.geohash, it.peerHex) }
                drainMeshDms()
                drainMeshBroadcasts()
                meshPeers = MeshRadio.peers()
                // Sonar Discovery (0x53): keep our announce current for outgoing
                // links and decode any peers' announces received over the mesh.
                MeshRadio.setLocalSonarAnnounce(localSonarAnnounce()?.encode())
                MeshRadio.setMeshNickname(nick)
                sonarPeerProfiles = MeshRadio.sonarPeers()
                    .mapNotNull { (id, raw) -> SonarAnnounce.decode(raw)?.let { id to it } }
                    .toMap()
                // Persist each peer's fingerprint→npub so its conversation stays
                // unified after it leaves range / after a restart, then re-fold the
                // White Noise legs into the mesh rows (one row per person).
                sonarPeerProfiles.forEach { (peerId, ann) -> rememberLink(peerId, ann.npub.toHexLower()) }
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
