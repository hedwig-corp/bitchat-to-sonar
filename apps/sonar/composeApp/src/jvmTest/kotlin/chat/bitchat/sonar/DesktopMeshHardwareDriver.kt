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
 * output and the phone's logcat. Prints `QA: <key>=<value>` lines for the script
 * to read, and never fails the build itself: the script decides pass or fail, so
 * a missing phone reads as an unrun scenario rather than a red test.
 */
class DesktopMeshHardwareDriver {

    private fun out(k: String, v: Any) = println("QA: $k=$v")

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
            var sent = false
            var dropSeen = false
            var relinked = false

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
                    out("noiseEstablished", true)
                    out("noiseEstablishedAfterSecs", (budgetSecs - (deadline - System.currentTimeMillis()) / 1000))
                }
                // QA-129: the session must not outlive its link. Once the phone's
                // Bluetooth goes, `hasMeshLink` has to go false, then come back.
                if (scenario == "drop") {
                    if (linked && !has && !dropSeen) {
                        dropSeen = true
                        out("linkDropped", true)
                    }
                    if (dropSeen && has) {
                        relinked = true
                        out("relinked", true)
                        break
                    }
                    continue
                }
                if (!linked) continue

                if (!sent) {
                    // QA-134 sends over the 480-byte fragment threshold; QA-128 a short one.
                    val text = if (scenario == "longdm") "x".repeat(520) else "qa desktop to phone"
                    val ok = runCatching {
                        MeshRadio.sendMeshDm(f, "qa-" + System.currentTimeMillis(), text)
                    }.getOrDefault(false)
                    out("dmSent", ok)
                    out("dmChars", text.length)
                    sent = true
                }
                val inbound = runCatching { MeshLink.drainDms() }.getOrDefault(emptyList())
                if (inbound.isNotEmpty()) {
                    inbound.forEach { out("dmReceivedChars", it.text.length) }
                    out("dmReceived", true)
                    break
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
