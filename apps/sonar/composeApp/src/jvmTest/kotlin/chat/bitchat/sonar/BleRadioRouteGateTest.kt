package chat.bitchat.sonar

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BleRadioRouteGateTest {
    @Test
    fun adapterTeardownCannotRaceLateAnnouncePublication() {
        val gate = BleRadioRouteGate()
        val peers = mutableSetOf<String>()
        val publicationEntered = CountDownLatch(1)
        val releasePublication = CountDownLatch(1)
        gate.activate()

        val publisher = thread(name = "late-ble-announce") {
            gate.publishIfUsable {
                publicationEntered.countDown()
                releasePublication.await(5, TimeUnit.SECONDS)
                peers += "peer"
            }
        }
        assertTrue(publicationEntered.await(5, TimeUnit.SECONDS))

        val releaser = thread(name = "release-late-ble-announce") {
            Thread.sleep(100)
            releasePublication.countDown()
        }
        // On the fixed gate this blocks until the in-flight publication exits,
        // then clears it. With the former check-then-publish race it clears
        // immediately and the released callback adds the stale peer afterward.
        gate.retire { peers.clear() }

        publisher.join(5_000)
        releaser.join(5_000)

        assertFalse(publisher.isAlive)
        assertFalse(releaser.isAlive)
        assertFalse(gate.isUsable)
        assertTrue(peers.isEmpty())
    }
}
