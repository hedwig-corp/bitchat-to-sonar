package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The legacy Breez delete gate: ALL facts must be known and zero. Deleting a
 * wallet that still holds or owes sats loses them, so every unknown blocks.
 */
class LegacyDeleteGateTest {

    private val empty = LegacyGateFacts(
        connected = true,
        syncedSinceConnect = true,
        confirmedSats = 0,
        pendingSendSats = 0,
        pendingReceiveSats = 0,
        refundableSwaps = 0,
        unsettledPayments = 0,
    )

    private fun blocked(r: LegacyDeleteBlock) = LegacyDeleteGate.Blocked(r)

    @Test
    fun onlyAConnectedSyncedEmptyWalletIsSafe() {
        assertEquals(LegacyDeleteGate.Safe, legacyDeleteGate(empty))
    }

    @Test
    fun everyNonZeroFactBlocks() {
        val cases = listOf(
            empty.copy(connected = false) to blocked(LegacyDeleteBlock.NotConnected),
            empty.copy(syncedSinceConnect = false) to blocked(LegacyDeleteBlock.NotSynced),
            empty.copy(confirmedSats = 1) to blocked(LegacyDeleteBlock.HasBalance),
            empty.copy(pendingSendSats = 1) to blocked(LegacyDeleteBlock.PendingSend),
            empty.copy(pendingReceiveSats = 1) to blocked(LegacyDeleteBlock.PendingReceive),
            empty.copy(refundableSwaps = 1) to blocked(LegacyDeleteBlock.RefundableSwaps),
            empty.copy(unsettledPayments = 1) to blocked(LegacyDeleteBlock.UnsettledPayments),
        )
        for ((facts, expected) in cases) assertEquals(expected, legacyDeleteGate(facts), "$facts")
    }

    @Test
    fun anythingUnknownIsNotSafe() {
        val cases = listOf(
            empty.copy(confirmedSats = null),
            empty.copy(pendingSendSats = null),
            empty.copy(pendingReceiveSats = null),
            empty.copy(refundableSwaps = null),
            empty.copy(unsettledPayments = null),
        )
        for (facts in cases) {
            assertEquals(blocked(LegacyDeleteBlock.Unknown), legacyDeleteGate(facts), "$facts")
        }
    }

    @Test
    fun connectionAndSyncAreCheckedBeforeAnyBalance() {
        // A disconnected wallet's zeros are stale, not proof of emptiness.
        val staleZeros = empty.copy(connected = false, syncedSinceConnect = false)
        assertEquals(blocked(LegacyDeleteBlock.NotConnected), legacyDeleteGate(staleZeros))
        val unsyncedWithFunds = empty.copy(syncedSinceConnect = false, confirmedSats = 0)
        assertEquals(blocked(LegacyDeleteBlock.NotSynced), legacyDeleteGate(unsyncedWithFunds))
    }

    @Test
    fun aNegativeReadingIsNeverTreatedAsEmpty() {
        // Defensive: only an exact zero passes.
        assertEquals(blocked(LegacyDeleteBlock.HasBalance), legacyDeleteGate(empty.copy(confirmedSats = -1)))
    }

    @Test
    fun theRestoreCheckFlagSettlesOnlyOnADecision() {
        assertEquals(true, LegacyBreezStore.settlesRestoreCheck(LegacyRestoreCheckOutcome.Kept))
        assertEquals(true, LegacyBreezStore.settlesRestoreCheck(LegacyRestoreCheckOutcome.Discarded))
        assertEquals(true, LegacyBreezStore.settlesRestoreCheck(LegacyRestoreCheckOutcome.AlreadyPresent))
        // No key in this build / offline: it must run again later.
        assertEquals(false, LegacyBreezStore.settlesRestoreCheck(LegacyRestoreCheckOutcome.Skipped))
        assertEquals(false, LegacyBreezStore.settlesRestoreCheck(LegacyRestoreCheckOutcome.Failed))
    }
}
