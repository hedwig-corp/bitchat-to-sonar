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
    data class Chat(val id: String, val name: String) : Screen
    data class Channel(val geohash: String) : Screen
    data class GeoDm(val geohash: String, val peerHex: String, val name: String) : Screen
}

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
            MessageStore.wipe()
            SonarCore.wipe()
            stack = listOf(Screen.Home)
            chats = emptyList(); messages = emptyList()
            onboarded = false; nick = ""; npub = ""; started = false
            walletState = WalletState.NotConfigured
            presenceByGeohash = emptyMap()
            payLedger = SonarPayLedger(); scannedPay.clear(); payVersion++
        }
    }
    var messages by mutableStateOf<List<SonarMsg>>(emptyList())
        private set
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

    fun openChannel(geohash: String) {
        push(Screen.Channel(geohash))
        channelMsgs = emptyList()
        scope.launch {
            channelMsgs = MessageStore.loadChannel(geohash) // disk hydrate (off-main), survives restart
            refreshChannel(geohash)
            // Announce our presence right away and pull the current count so the
            // header shows "N here now" without waiting for the next poll tick.
            beatPresence(geohash)
            refreshPresenceCounts()
        }
    }

    /** Fetch the channel from the core, merge with what's on disk, persist. */
    private suspend fun refreshChannel(geohash: String) {
        val fresh = SonarCore.channelMessages(geohash)
        val merged = MessageMerge.channels(MessageStore.loadChannel(geohash), fresh)
        MessageStore.saveChannel(geohash, merged)
        channelMsgs = merged
    }

    fun sendChannelMsg(geohash: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
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

    /** Capabilities this node advertises in its Sonar announce (0x53). */
    private fun capabilities(): Int =
        SonarAnnounce.CAP_MARMOT or (if (walletAvailable) SonarAnnounce.CAP_PAY else 0)

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
                val title = if (showNames) c.name.ifBlank { "Secure chat" } else "New message"
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
                setupWallet()
                refreshLocationChannels()
                refreshChats()
                poll()
            } catch (t: Throwable) {
                toast = "connect failed: ${t.message}"
            } finally {
                connecting = false
            }
        }
    }

    fun openChat(chat: SonarChat) {
        push(Screen.Chat(chat.id, chat.name))
        scope.launch {
            messages = SonarCore.messages(chat.id)
            processPayLines(chat.id, messages)
        }
    }

    fun back() {
        if (stack.size > 1) stack = stack.dropLast(1)
        messages = emptyList()
        scope.launch { refreshChats() }
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
        scope.launch {
            try {
                SonarCore.send(chatId, t)
                messages = SonarCore.messages(chatId)
                processPayLines(chatId, messages)
            } catch (e: Throwable) {
                toast = "send failed: ${e.message}"
            }
        }
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
                maybeNotify()
                (screen as? Screen.Chat)?.let { messages = SonarCore.messages(it.id); processPayLines(it.id, messages) }
                (screen as? Screen.Channel)?.let { refreshChannel(it.geohash) }
                (screen as? Screen.GeoDm)?.let { refreshGeoDm(it.geohash, it.peerHex) }
                meshPeers = MeshRadio.peers()
                // Sonar Discovery (0x53): keep our announce current for outgoing
                // links and decode any peers' announces received over the mesh.
                MeshRadio.setLocalSonarAnnounce(localSonarAnnounce()?.encode())
                MeshRadio.setMeshNickname(nick)
                sonarPeerProfiles = MeshRadio.sonarPeers()
                    .mapNotNull { (id, raw) -> SonarAnnounce.decode(raw)?.let { id to it } }
                    .toMap()
                // Unify nearby: keep the payer scan alive and refresh peers +
                // the receiver advertising (wallet/foreground gated).
                startUnify()
                unifyPeers = UnifyRadio.peers()
                updateUnifyReceiver()
                if (locationChannels.isEmpty()) refreshLocationChannels()
                // Presence: announce ourselves in the open channel on a ~60s
                // heartbeat, then refresh "here now" counts (cheap in-memory read).
                (screen as? Screen.Channel)?.let { if (tick % 15 == 1) beatPresence(it.geohash) }
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
