package chat.bitchat.sonar

import chat.bitchat.sonar.BleBridge.MeshRx
import chat.bitchat.sonar.BleBridge.SERVER_LINK
import chat.bitchat.sonar.crypto.Sha256
import uniffi.sonar_ffi.MeshEngineCommand
import uniffi.sonar_ffi.MeshEngineEvent
import uniffi.sonar_ffi.MeshEngineOutput
import uniffi.sonar_ffi.MeshLinkEngine
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.meshBuildAnnounce
import uniffi.sonar_ffi.meshBuildPacket
import uniffi.sonar_ffi.meshDecodePacket
import uniffi.sonar_ffi.meshParseAnnounce
import uniffi.sonar_ffi.noiseGenerateKeypair
import java.nio.file.Files
import java.security.SecureRandom
import java.util.PriorityQueue
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The desktop's Noise-over-GATT engine ([MeshLink]) against the REAL phone
 * engine, headlessly.
 *
 * Android's mesh protocol lives in the Rust `MeshLinkEngine` (`mesh_engine.rs`),
 * exported over UniFFI, so the JVM can run the exact state machine a Pixel runs.
 * [SimRadio] stands in for Bluetooth: it carries bytes between [MeshLink] and
 * one engine per simulated phone, with per-hop latency and virtual time, and
 * speaks both GATT roles:
 *  - **central link** — the desktop dialed the phone's GATT server (Linux, when
 *    the controller refuses to advertise). The phone is the server side.
 *  - **server path** — the phone dialed the desktop's GATT server (macOS, and
 *    Linux when it advertises). The phone is a client, packets from it arrive on
 *    link [SERVER_LINK].
 *
 * What it cannot cover: real radios (MTU, controller quirks, connection drops
 * the stack never reports), and iOS, whose Noise code is Swift. The iOS
 * simultaneous-open behaviour is modelled by [FakeIosPeer] from
 * `NoiseSessionManager.swift` (an incoming m1 makes it abandon its initiator).
 * The hardware legs are QA-080…QA-084 in docs/QA-SCENARIOS.md.
 */
class DesktopMeshInteropTest {

    private lateinit var radio: SimRadio
    private lateinit var desktopFp: String

    @BeforeTest
    fun isolate() {
        // Never the real keystore namespace: MeshIdentity mints and persists keys.
        DesktopSecrets.useTestService("chat.bitchat.sonar.meshinterop")
        DesktopEnv.useTestRoot(Files.createTempDirectory("sonar-mesh-interop").toFile())
        MeshIdentity.resetCachesForTest()
        MeshLink.stop()
        MeshLink.wipe()
        radio = SimRadio()
        MeshLink.wire = radio
        MeshLink.clock = { radio.now }
        desktopFp = MeshIdentity.fingerprintOf(meshParseAnnounce(MeshIdentity.announce("desk"))!!.noisePublicKeyHex)
    }

    @AfterTest
    fun restore() {
        MeshLink.wipe()
        MeshLink.wire = defaultWire
        MeshLink.clock = System::currentTimeMillis
        runCatching { DesktopSecrets.clear(*DesktopSecrets.MANAGED_KEYS.toTypedArray()) }
        DesktopSecrets.resetService()
        DesktopEnv.useTestRoot(null)
        MeshIdentity.resetCachesForTest()
    }

    private fun linked(phone: SimRadio.Phone) =
        MeshLink.hasLink(phone.fp) && phone.engine.hasLink(desktopFp)

    /** DMs both ways once linked: the proof that a session is real at both ends. */
    private fun assertDmsFlowBothWays(phone: SimRadio.Phone, tag: String) {
        assertTrue(MeshLink.sendDm(phone.fp, "d-$tag", "desk→${phone.name} $tag"), "desktop refused to send")
        phone.send(desktopFp, "p-$tag", "${phone.name}→desk $tag")
        radio.run(2_000)
        assertTrue("desk→${phone.name} $tag" in phone.texts, "${phone.name} never got the desktop's DM ($tag): ${phone.texts}")
        val got = MeshLink.drainDms().map { it.text }
        assertTrue("${phone.name}→desk $tag" in got, "the desktop never got ${phone.name}'s DM ($tag): $got")
    }

    /** The PR's headline: a desktop that can only dial out still links. */
    @Test
    fun aDesktopThatDialsAPhoneStartsTheHandshake() {
        val pixel = radio.phone("pixel")
        radio.linkOut(pixel)
        radio.run(3_000)
        assertTrue(linked(pixel), "no Noise session after dialing the phone")
        assertDmsFlowBothWays(pixel, "first")
    }

    /**
     * Android drops its Noise state with the GATT connection and never initiates
     * toward a central. A desktop that kept its session across the drop showed
     * the phone as linked forever while the phone silently discarded every DM.
     */
    @Test
    fun aDroppedLinkIsRehandshakenNotLeftHalfDead() {
        val pixel = radio.phone("pixel")
        val first = radio.linkOut(pixel)
        radio.run(3_000)
        assertTrue(linked(pixel))
        radio.dropLink(first)
        radio.run(500)
        assertFalse(MeshLink.hasLink(pixel.fp), "the session must go with the link")
        radio.linkOut(pixel)
        radio.run(3_000)
        assertTrue(linked(pixel), "no fresh handshake on the new link")
        assertDmsFlowBothWays(pixel, "after-relink")
    }

    /** One lost m1 used to leave the handshake "in flight" forever. */
    @Test
    fun aLostHandshakeMessageIsRetried() {
        val pixel = radio.phone("pixel")
        var dropped = 0
        radio.dropToPhone = { bytes ->
            (meshDecodePacket(bytes)?.packetType?.toInt() == 0x10 && dropped == 0).also { if (it) dropped++ }
        }
        radio.linkOut(pixel)
        radio.run(MeshLink.HANDSHAKE_TIMEOUT_MS + 3_000)
        assertEquals(1, dropped, "the harness should have eaten exactly one handshake packet")
        assertTrue(linked(pixel), "a lost m1 must not wedge the link")
        assertDmsFlowBothWays(pixel, "after-retry")
    }

    /**
     * Android answers a 0x10 whatever its recipient id says, and a second m1
     * resets its in-flight responder. Every m1 therefore has to go to its own
     * phone's link only.
     */
    @Test
    fun twoPhonesLinkIndependently() {
        val a = radio.phone("pixel-a")
        val b = radio.phone("pixel-b")
        radio.linkOut(a)
        radio.linkOut(b)
        radio.run(3_000)
        assertTrue(linked(a), "phone A did not link")
        assertTrue(linked(b), "phone B did not link")
        assertDmsFlowBothWays(a, "a")
        assertDmsFlowBothWays(b, "b")
        assertFalse(a.texts.any { "pixel-b" in it }, "B's DM reached A: ${a.texts}")
    }

    /**
     * The verified macOS path: the phone dials our GATT server and initiates on
     * its client link. The desktop must stay the responder there; an m1 from us
     * resets the phone's own in-flight initiator, which then waits 8 s to retry.
     */
    @Test
    fun aPhoneThatDialsTheDesktopLinksWithoutAStall() {
        val pixel = radio.phone("pixel")
        radio.dialDesktop(pixel)
        radio.run(3_000)
        assertTrue(linked(pixel), "the phone-initiated handshake did not complete promptly")
        assertDmsFlowBothWays(pixel, "server-path")
    }

    /**
     * iOS initiates when it has something to send, and on a link we dialed our
     * announce-driven m1 can cross its m1 in flight. iOS abandons its own on
     * receiving ours; the desktop must keep its initiator rather than answer
     * theirs too, or each end ends up waiting on the other's abandoned attempt.
     */
    @Test
    fun aSimultaneousOpenWithIosConverges() {
        val ios = FakeIosPeer("iphone")
        radio.linkOut(ios)
        radio.run(3_000)
        assertTrue(MeshLink.hasLink(ios.fp), "desktop never established with the iPhone")
        assertTrue(ios.established, "the iPhone never established")
        assertTrue(MeshLink.sendDm(ios.fp, "d-ios", "desk→ios"))
        radio.run(500)
        assertEquals(listOf("desk→ios"), ios.texts, "the two ends hold different sessions")
    }

    /**
     * A DM of a couple of hundred characters pads past one GATT value. Android
     * sends it as 0x20 fragments, which MeshLink dropped (every long DM from a
     * phone vanished), and MeshLink sent its own as one oversized write, which a
     * radio refuses (modelled here by [MAX_WRITE_BYTES]).
     */
    @Test
    fun aLongDmCrossesInBothDirections() {
        val pixel = radio.phone("pixel")
        radio.linkOut(pixel)
        radio.run(3_000)
        assertTrue(linked(pixel))
        val long = "long message ".repeat(60).trim()
        assertTrue(MeshLink.sendDm(pixel.fp, "d-long", long))
        pixel.send(desktopFp, "p-long", long.uppercase())
        radio.run(2_000)
        assertEquals(listOf(long), pixel.texts, "the phone never got the desktop's long DM")
        assertEquals(listOf(long.uppercase()), MeshLink.drainDms().map { it.text }, "the desktop never got the phone's long DM")
    }

    /**
     * The bridge's RX shape, byte for byte as `sonar-ble`'s `rx_items_name_their_link`
     * pins it. Parsed by hand on this side, so the two tests are the contract.
     */
    @Test
    fun theBridgeRxJsonNamesEachLink() {
        val rx = BleBridge.parseRx("""[{"l":0,"p":"ab01"},{"l":7,"p":"ff"},{"d":true,"l":7}]""")
        assertEquals(listOf(0L, 7L, 7L), rx.map { it.link })
        assertEquals(listOf("ab01", "ff", null), rx.map { r -> r.bytes?.let { hex(it) } })
    }

    // ── the simulated radio ──

    /** A peer reachable over the simulated radio, as the GATT server side. */
    private abstract class Peer(val name: String) {
        abstract val fp: String
        abstract fun onServerLinkUp(link: Long)
        abstract fun onServerLinkDown(link: Long)
        abstract fun onServerRx(link: Long, bytes: ByteArray)
        open fun tick() {}
    }

    /** Carries bytes between [MeshLink] and simulated phones, in virtual time. */
    private inner class SimRadio : MeshWire {
        var now = 1_000_000L
        private val inbox = ArrayList<MeshRx>()
        private val timeline = PriorityQueue<Timed>(compareBy<Timed>({ it.at }, { it.seq }))
        private var seq = 0L
        private val phones = ArrayList<Peer>()
        private val centralLinks = HashMap<Long, Peer>()
        private var nextLink = 1L

        /** Drops a desktop→phone packet when it returns true (a lost write). */
        var dropToPhone: ((ByteArray) -> Boolean)? = null

        private inner class Timed(val at: Long, val seq: Long, val action: () -> Unit)

        fun later(delayMs: Long, action: () -> Unit) {
            timeline += Timed(now + delayMs, seq++, action)
        }

        fun phone(name: String): Phone = Phone(name).also { phones += it }

        /** The desktop dials [peer] as a central (the bridge writes our announce first). */
        fun linkOut(peer: Peer): Long {
            val link = nextLink++
            centralLinks[link] = peer
            peer.onServerLinkUp(link)
            toPeer(link, MeshIdentity.announce("desk"))
            return link
        }

        /** The link drops. The bridge reports it; the phone sees a disconnect. */
        fun dropLink(link: Long) {
            val peer = centralLinks.remove(link) ?: return
            peer.onServerLinkDown(link)
            inbox += MeshRx(link, null)
        }

        /** [phone] dials the desktop's GATT server (the server path). */
        fun dialDesktop(phone: Phone) {
            phones.remove(phone); phones += phone
            phone.handle(phone.engine.onDialRequest(phone.clientConn, now))
        }

        fun toDesktop(link: Long, bytes: ByteArray, afterMs: Long = 0) {
            later(afterMs + HOP_MS) {
                if (link == SERVER_LINK || centralLinks.containsKey(link)) inbox += MeshRx(link, bytes)
            }
        }

        private fun toPeer(link: Long, bytes: ByteArray) {
            if (dropToPhone?.invoke(bytes) == true) return
            // One GATT value per write, bounded by the ATT MTU (517 - 3).
            if (bytes.size > MAX_WRITE_BYTES) return
            val peer = centralLinks[link] ?: return
            later(HOP_MS) { if (centralLinks[link] === peer) peer.onServerRx(link, bytes) }
        }

        override fun drain(): List<MeshRx> = inbox.toList().also { inbox.clear() }

        override fun broadcast(bytes: ByteArray) {
            for (link in centralLinks.keys.toList()) toPeer(link, bytes)
            for (p in phones) if (p is Phone && p.subscribedToDesktop) p.fromDesktopNotify(bytes)
        }

        override fun sendTo(link: Long, bytes: ByteArray): Boolean {
            if (!centralLinks.containsKey(link)) return false
            toPeer(link, bytes)
            return true
        }

        /** Advance virtual time, delivering what falls due and pumping MeshLink. */
        fun run(ms: Long) {
            val end = now + ms
            while (now < end) {
                now += STEP_MS
                while (true) {
                    val next = timeline.peek() ?: break
                    if (next.at > now) break
                    timeline.poll()
                    next.action()
                }
                MeshLink.pumpForTest()
                if (now % 1_000 == 0L) for (p in phones) p.tick()
            }
        }

        /** An Android phone: the real Rust engine, driven like `MeshGatt` drives it. */
        inner class Phone(name: String) : Peer(name) {
            private val kp = noiseGenerateKeypair()
            val engine = MeshLinkEngine(kp.privateHex, kp.publicHex, randomHex(32), name)
            override val fp = MeshIdentity.fingerprintOf(kp.publicHex)
            val texts = ArrayList<String>()
            val clientConn = "desktop-gatt"
            var subscribedToDesktop = false
            private val serverConnByLink = HashMap<Long, String>()

            init {
                engine.setWallClock(now, System.currentTimeMillis())
            }

            override fun onServerLinkUp(link: Long) {
                val conn = "central-$link"
                serverConnByLink[link] = conn
                handle(engine.onServerConnected(conn, now))
                handle(engine.onServerSubscribed(conn, now))
            }

            override fun onServerLinkDown(link: Long) {
                serverConnByLink.remove(link)?.let { handle(engine.onServerDisconnected(it)) }
            }

            override fun onServerRx(link: Long, bytes: ByteArray) {
                val conn = serverConnByLink[link] ?: return
                handle(engine.onServerRx(conn, bytes, now))
            }

            /** Our GATT server notified the subscribed phone (the server path). */
            fun fromDesktopNotify(bytes: ByteArray) {
                if (bytes.size > MAX_WRITE_BYTES) return
                later(HOP_MS) { handle(engine.onClientRx(clientConn, 0, bytes, now)) }
            }

            fun send(toFp: String, id: String, text: String) {
                engine.sendText(toFp, id, text, now)?.let(::handle)
            }

            override fun tick() = handle(engine.onTick(now))

            fun handle(out: MeshEngineOutput) {
                for (c in out.commands) when (c) {
                    is MeshEngineCommand.NotifyConn -> {
                        val link = serverConnByLink.entries.firstOrNull { it.value == c.conn }?.key ?: continue
                        toDesktop(link, c.bytes, c.afterMs)
                    }
                    is MeshEngineCommand.WriteLink -> toDesktop(SERVER_LINK, c.bytes, c.afterMs)
                    // MeshGatt discovers services itself once connected, then
                    // reports the mesh instances it found.
                    is MeshEngineCommand.Dial -> later(HOP_MS) {
                        handle(engine.onClientConnected(c.conn, now))
                        later(HOP_MS) { handle(engine.onInstancesDiscovered(c.conn, listOf(0), now)) }
                    }
                    is MeshEngineCommand.RefreshInstances ->
                        later(HOP_MS) { handle(engine.onInstancesDiscovered(c.conn, listOf(0), now)) }
                    is MeshEngineCommand.Subscribe -> later(HOP_MS) {
                        subscribedToDesktop = true
                        handle(engine.onSubscribeResult(c.conn, c.instance, true, now))
                        // Our advertise loop notifies the announce to subscribers.
                        fromDesktopNotify(MeshIdentity.announce("desk"))
                    }
                    is MeshEngineCommand.Disconnect, is MeshEngineCommand.CancelServer -> Unit
                }
                for (e in out.events) if (e is MeshEngineEvent.TextReceived) texts += e.content
            }
        }
    }

    /**
     * iOS's handshake rules, from `NoiseSessionManager.swift`: it initiates when
     * it has something to send, and an incoming m1 makes it abandon its own
     * initiator and answer as responder (`SM:127-134`, no tie-break). Here it
     * opens at link-up, the moment most likely to cross the desktop's m1.
     */
    private inner class FakeIosPeer(name: String) : Peer(name) {
        private val kp = noiseGenerateKeypair()
        private val seed = randomHex(32)
        private val peerId = hex(Sha256.hash(unhex(kp.publicHex)).copyOf(8))
        override val fp = MeshIdentity.fingerprintOf(kp.publicHex)
        private var link = 0L
        private var noise: SonarNoise? = null
        var established = false
        val texts = ArrayList<String>()

        private fun packet(type: Int, payload: ByteArray) =
            meshBuildPacket(type.toUByte(), peerId, MeshIdentity.peerIdHex, 7u, System.currentTimeMillis().toULong(), payload)

        override fun onServerLinkUp(link: Long) {
            this.link = link
            radio.toDesktop(link, meshBuildAnnounce(seed, peerId, name, kp.publicHex, 7u, System.currentTimeMillis().toULong()))
            val i = SonarNoise.initiator(kp.privateHex)
            noise = i
            radio.toDesktop(link, packet(0x10, i.writeMessage()))
        }

        override fun onServerLinkDown(link: Long) {}

        override fun onServerRx(link: Long, bytes: ByteArray) {
            val info = meshDecodePacket(bytes) ?: return
            when (info.packetType.toInt()) {
                0x10 -> {
                    val m = info.payload
                    if (m.size == 32) {
                        // Abandon ours, answer theirs.
                        val r = SonarNoise.responder(kp.privateHex)
                        noise = r
                        r.readMessage(m)
                        radio.toDesktop(link, packet(0x10, r.writeMessage()))
                    } else {
                        val n = noise ?: return
                        runCatching {
                            n.readMessage(m)
                            if (!n.isFinished()) radio.toDesktop(link, packet(0x10, n.writeMessage()))
                            if (n.isFinished()) { n.intoSession(); established = true }
                        }.onFailure { noise = null; established = false }
                    }
                }
                0x11 -> {
                    val n = noise?.takeIf { established } ?: return
                    runCatching { uniffi.sonar_ffi.meshDecodePrivateMessage(n.decrypt(info.payload))?.let { texts += it.content } }
                }
            }
        }
    }

    private companion object {
        const val MAX_WRITE_BYTES = 514
        const val STEP_MS = 10L
        const val HOP_MS = 20L
        val defaultWire: MeshWire = MeshLink.wire

        fun randomHex(bytes: Int) = hex(ByteArray(bytes).also { SecureRandom().nextBytes(it) })
        fun hex(b: ByteArray) = b.joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
        fun unhex(s: String) = ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }
    }
}
