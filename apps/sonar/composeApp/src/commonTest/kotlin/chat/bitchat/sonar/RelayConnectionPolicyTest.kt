package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RelayConnectionPolicyTest {
    @Test
    fun latched_attach_skips_connect() {
        assertTrue(RelayConnectionPolicy.wouldSkipConnect(latched = true))
    }

    @Test
    fun invalidate_clears_latch_so_push_wake_reconnects() {
        assertFalse(RelayConnectionPolicy.afterInvalidate())
        assertFalse(
            RelayConnectionPolicy.wouldSkipConnect(
                latched = RelayConnectionPolicy.afterInvalidate(),
            ),
        )
    }

    @Test
    fun invalidate_during_attach_keeps_latch_down() {
        // Epoch bumped mid-attach: the completing connect must not restore the
        // latch, or the next push wake syncs against background-staled sockets.
        assertFalse(RelayConnectionPolicy.latchAfterAttach(startEpoch = 4L, currentEpoch = 5L))
    }

    @Test
    fun undisturbed_attach_latches_connected() {
        assertTrue(RelayConnectionPolicy.latchAfterAttach(startEpoch = 4L, currentEpoch = 4L))
    }

    @Test
    fun push_while_ui_visible_keeps_healthy_node() {
        assertFalse(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible = true))
        assertTrue(RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible = false))
    }

    @Test
    fun superseded_attach_retries_only_in_foreground() {
        // Foreground: the invalidate was a background blip we already returned
        // from, so ending the relay job with the latch down would strand us on
        // dead sockets until the 30 s heartbeat.
        assertTrue(RelayConnectionPolicy.shouldRetrySupersededAttach(foreground = true))
        // Backgrounded: the push wake / next foreground resume retrigger instead
        // of rebuilding sockets the OS is suspending.
        assertFalse(RelayConnectionPolicy.shouldRetrySupersededAttach(foreground = false))
    }

    @Test
    fun first_connect_failure_retries_fast_in_foreground() {
        // The core's quorum window is a fixed 5 s, which a radio waking from
        // doze routinely misses, so the first failure is a network that is about
        // to work — not an outage. Waiting the slow interval left a resumed app
        // detached for up to 10 s with nothing on screen explaining it.
        assertEquals(
            1_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 1, foreground = true),
        )
        assertTrue(
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 1, foreground = true) <
                RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 3, foreground = true),
        )
    }

    @Test
    fun sustained_connect_failure_backs_off() {
        assertEquals(
            3_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 2, foreground = true),
        )
        assertEquals(
            10_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 3, foreground = true),
        )
        // Monotonic and capped: a long outage must not spin, nor grow unbounded
        // past the heartbeat that re-triggers the job anyway.
        assertEquals(
            10_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 50, foreground = true),
        )
    }

    @Test
    fun backgrounded_attach_never_uses_the_fast_retries() {
        // Every retry is a full SonarNode.connect. Backgrounded, that rebuilds
        // sockets the OS is suspending — the same reason
        // shouldRetrySupersededAttach refuses to loop there. The fast head is a
        // foreground affordance ("the user just came back"), so it must not
        // survive a background transition.
        assertEquals(
            10_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 1, foreground = false),
        )
        assertEquals(
            10_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 2, foreground = false),
        )
    }

    @Test
    fun retry_delay_is_positive_for_a_zeroed_counter() {
        // Defensive: a caller that has not incremented yet must still back off,
        // never busy-loop rebuilding sockets.
        assertTrue(
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 0, foreground = true) > 0L,
        )
        assertTrue(
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 0, foreground = false) > 0L,
        )
    }
}
