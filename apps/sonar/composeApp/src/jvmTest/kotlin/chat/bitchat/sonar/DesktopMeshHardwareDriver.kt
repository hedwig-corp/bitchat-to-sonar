package chat.bitchat.sonar

import kotlin.test.Test

/**
 * Drives the desktop mesh stack against a REAL phone, for the hardware legs of
 * QA-128, QA-129 and QA-134 that no simulation can cover.
 *
 * `DesktopMeshInteropTest` runs the same `MeshLink` against the real Android
 * engine, but over a simulated radio: it cannot catch a controller that refuses
 * to advertise, a BlueZ quirk, an MTU negotiation, or a link that drops because
 * someone walked out of range. This does, at the cost of needing a phone.
 *
 * Skipped unless `SONAR_QA_HARDWARE=1`, so CI never sees it. `scripts/qa/desktop-smoke.sh`
 * sets that, picks the scenario with `SONAR_QA_SCENARIO`, and asserts on both this
 * output and the phone's own delivery receipts. Never fails the build itself: the
 * script decides pass or fail, so a missing phone reads as an unrun scenario
 * rather than a red test.
 */
class DesktopMeshHardwareDriver {

    // Gradle captures a test's stdout into the JUnit XML report rather than the
    // console, so a script reading gradle's output sees no QA: lines at all and
    // reports every scenario as unrun. The script also needs them WHILE the test
    // runs, to time the radio drop against a link that actually exists.
    private val sink = System.getenv("SONAR_QA_OUT")?.let { java.io.File(it) }

    /** Written by the script with an `on` line once it has restored the radio. */
    private val resume = System.getenv("SONAR_QA_RESUME")?.let { java.io.File(it) }

    /**
     * True once the script says it put the radio back. With no marker configured
     * — someone running this driver by hand — fall back to the desktop's own view
     * of the link returning, which is then all there is to go on.
     */
    private fun radioIsBack(linkUp: Boolean, dropSeen: Boolean): Boolean =
        resume?.let { f ->
            runCatching { f.readLines().any { it.trim() == "on" } }.getOrDefault(false)
        } ?: (dropSeen && linkUp)

    private fun out(k: String, v: Any) {
        println("QA: $k=$v")
        sink?.appendText("$k=$v\n")
    }

    @Test
    fun driveTheRadioAgainstAPhone() {
        if (System.getenv("SONAR_QA_HARDWARE") != "1") return
        val scenario = System.getenv("SONAR_QA_SCENARIO") ?: "link"
        val budgetSecs = (System.getenv("SONAR_QA_BUDGET_SECS") ?: "120").toInt()

        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-qa-desktop").toFile())
        out("scenario", scenario)
        out("meshSupported", BleBridge.meshSupported)
        out("advertisingSupported", BleBridge.advertisingSupported)
        out("localPeerId", MeshRadio.localPeerIdHex())

        MeshRadio.start()
        try {
            val deadline = System.currentTimeMillis() + budgetSecs * 1000L
            var fp: String? = null
            var linked = false
            var sentId: String? = null
            var dropSeen = false
            var relinked = false
            var backAnnounced = false
            val resumeIds = HashSet<String>()

            while (System.currentTimeMillis() < deadline) {
                Thread.sleep(2_000)
                val peer = runCatching { MeshLink.namedPeers() }.getOrDefault(emptyList()).firstOrNull()
                if (fp == null && peer != null) {
                    fp = peer.id.removePrefix("mesh:")
                    out("peerName", peer.name)
                    out("peerFp", fp!!.take(16))
                    out("peerIsSonar", peer.sonar)
                }
                val f = fp ?: continue
                val has = runCatching { MeshRadio.hasMeshLink(f) }.getOrDefault(false)

                if (has && !linked) {
                    linked = true
                    out("noiseEstablishedAfterSecs", (budgetSecs - (deadline - System.currentTimeMillis()) / 1000))
                    // Written last of the pair: the smoke script waits on this line
                    // before pulling the phone's radio, so it must not appear until
                    // the link really exists.
                    out("noiseEstablished", true)
                }
                // QA-129: a link that dies must not leave a session that swallows
                // DMs. What must hold is that messages flow AGAIN afterwards.
                //
                // Not that `hasMeshLink` goes false first: on the GATT server path
                // (the phone dialing us) bluster stubs the disconnect callback, so
                // `onLinkDown` never fires and MeshLink deliberately keeps the
                // session until the phone's fresh m1 resets it. Asserting the
                // intermediate false therefore failed a link that recovered
                // perfectly well, twice, over 20 s and 45 s outages.
                if (scenario == "drop") {
                    if (linked && !has && !dropSeen) {
                        dropSeen = true
                        out("linkDropped", true)
                    }
                    if (!linked || !radioIsBack(has, dropSeen)) continue
                    if (!backAnnounced) {
                        backAnnounced = true
                        out("radioBack", true)
                    }
                    // Retried every tick: `sendMeshDm` refuses until the session is
                    // established again, and the phone's re-announce can be 30 s out.
                    val id = "qa-resume-" + System.currentTimeMillis()
                    if (runCatching { MeshRadio.sendMeshDm(f, id, "qa after the drop") }
                            .getOrDefault(false)) {
                        resumeIds.add(id)
                    }
                    if (runCatching { MeshLink.drainDeliveryReceipts() }.getOrDefault(emptyList())
                            .any { it.messageId in resumeIds }) {
                        relinked = true
                        out("dmsSentAfterDrop", resumeIds.size)
                        out("relinked", true)
                        break
                    }
                    continue
                }
                if (!linked) continue

                if (sentId == null) {
                    // QA-134 sends over the 480-byte fragment threshold; QA-128 a short one.
                    val text = if (scenario == "longdm") "x".repeat(520) else "qa desktop to phone"
                    val id = "qa-" + System.currentTimeMillis()
                    val ok = runCatching { MeshRadio.sendMeshDm(f, id, text) }.getOrDefault(false)
                    out("dmSent", ok)
                    out("dmChars", text.length)
                    sentId = id
                }
                // The phone's own verdict. `dmSent` only means the local write
                // returned true; a receipt is minted BY THE PHONE after it
                // decrypts (and, over 480 bytes, reassembles) the message, so it
                // is the only proof the far side actually got it.
                val receipts = runCatching { MeshLink.drainDeliveryReceipts() }.getOrDefault(emptyList())
                if (receipts.any { it.messageId == sentId }) {
                    out("dmReceipt", true)
                    break
                }
                val inbound = runCatching { MeshLink.drainDms() }.getOrDefault(emptyList())
                if (inbound.isNotEmpty()) {
                    inbound.forEach { out("dmReceivedChars", it.text.length) }
                    out("dmReceived", true)
                }
            }
            out("linkedFinal", linked)
            if (scenario == "drop") out("dropCycleComplete", dropSeen && relinked)
        } finally {
            MeshRadio.stop()
            DesktopEnv.useTestRoot(null)
            out("done", true)
        }
    }
}
