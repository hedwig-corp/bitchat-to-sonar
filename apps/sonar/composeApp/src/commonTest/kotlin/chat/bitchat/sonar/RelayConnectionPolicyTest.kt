package chat.bitchat.sonar

import kotlin.test.Test
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
    fun backgrounded_heartbeat_does_not_rebuild_the_node_on_invalidating_platforms() {
        // The heartbeat re-enters startRelayConnection() from scratch every beat,
        // so shouldRetrySupersededAttach — which only guards the retry loop inside
        // an already-running job — cannot hold it back. Ungated it reads the latch
        // that onProcessBackgrounded() deliberately dropped as "reconnect now" and
        // rebuilds the node every 60 s for as long as the app stays backgrounded,
        // closing the node the live wake loop and conversation listener hold.
        assertFalse(
            RelayConnectionPolicy.shouldReconnectOnHeartbeat(
                foreground = false,
                invalidatesOnBackground = true,
            ),
        )
    }

    @Test
    fun foreground_heartbeat_still_recovers_a_dead_connection() {
        assertTrue(
            RelayConnectionPolicy.shouldReconnectOnHeartbeat(
                foreground = true,
                invalidatesOnBackground = true,
            ),
        )
    }

    @Test
    fun unfocused_heartbeat_still_reconnects_where_background_never_invalidates() {
        // Desktop: focus loss reports foreground=false but keeps its node, so a
        // down latch is a genuine failure and nothing else recovers it.
        assertTrue(
            RelayConnectionPolicy.shouldReconnectOnHeartbeat(
                foreground = false,
                invalidatesOnBackground = false,
            ),
        )
    }
}
