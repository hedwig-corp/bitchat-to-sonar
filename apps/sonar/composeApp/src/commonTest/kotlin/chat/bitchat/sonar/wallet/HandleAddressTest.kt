package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Which wallet the public handle pays. A user who claimed the handle on the
 * Breez wallet and updates the app must not find it silently pointed at the
 * Cashu mint: the app re-registers it with the Cashu offer only when it
 * already pays Cashu, or when no old wallet exists here. iOS mirror:
 * SonarHandleAddressTests.
 */
class HandleAddressTest {

    private val handle = "alice@sonarprivacy.xyz"
    private val cashu = "lno1cashu"

    private fun action(
        claimed: String? = handle,
        presence: LegacyWalletPresence,
        wallet: HandleAddressWallet?,
        offer: String? = cashu,
        registered: String? = null,
    ) = handleOfferAction(claimed, presence, wallet, offer, registered)

    @Test
    fun noClaimedHandleMeansNothing() {
        for (presence in LegacyWalletPresence.entries) {
            for (wallet in listOf(null, HandleAddressWallet.Legacy, HandleAddressWallet.Cashu)) {
                assertEquals(HandleOfferAction.None, action(claimed = null, presence = presence, wallet = wallet))
                assertEquals(HandleOfferAction.None, action(claimed = "  ", presence = presence, wallet = wallet))
            }
        }
    }

    @Test
    fun aHandleOnTheOldWalletIsNeverMovedWhileThatWalletIsHere() {
        // The upgrade: claimed on Breez, nothing recorded, Breez still here.
        assertEquals(HandleOfferAction.AskToMove, action(presence = LegacyWalletPresence.Present, wallet = null))
        assertEquals(
            HandleOfferAction.AskToMove,
            action(presence = LegacyWalletPresence.Present, wallet = HandleAddressWallet.Legacy, registered = "lno1breez"),
        )
        assertEquals(
            HandleOfferAction.AskToMove,
            action(presence = LegacyWalletPresence.Present, wallet = null, offer = null),
            "the notice needs no Cashu offer",
        )
    }

    @Test
    fun unknownPresenceIsNeverAbsent() {
        assertEquals(HandleOfferAction.None, action(presence = LegacyWalletPresence.Unknown, wallet = null))
        assertEquals(HandleOfferAction.None, action(presence = LegacyWalletPresence.Unknown, wallet = HandleAddressWallet.Legacy))
    }

    @Test
    fun withNoOldWalletTheHandleFollowsTheCashuOffer() {
        assertEquals(HandleOfferAction.ReclaimWithCashu, action(presence = LegacyWalletPresence.Absent, wallet = null))
        assertEquals(
            HandleOfferAction.ReclaimWithCashu,
            action(presence = LegacyWalletPresence.Absent, wallet = HandleAddressWallet.Legacy, registered = "lno1breez"),
        )
        assertEquals(HandleOfferAction.None, action(presence = LegacyWalletPresence.Absent, wallet = null, offer = null))
        assertEquals(
            HandleOfferAction.None,
            action(presence = LegacyWalletPresence.Absent, wallet = HandleAddressWallet.Legacy, registered = cashu),
        )
    }

    @Test
    fun aHandleOnCashuFollowsTheOfferOncePerOffer() {
        for (presence in LegacyWalletPresence.entries) {
            val w = HandleAddressWallet.Cashu
            assertEquals(HandleOfferAction.ReclaimWithCashu, action(presence = presence, wallet = w), "chat-only claim upgrade")
            assertEquals(
                HandleOfferAction.ReclaimWithCashu,
                action(presence = presence, wallet = w, offer = "lno1rotated", registered = cashu),
                "rotated offer",
            )
            assertEquals(HandleOfferAction.None, action(presence = presence, wallet = w, registered = cashu), "already registered")
            assertEquals(HandleOfferAction.None, action(presence = presence, wallet = w, offer = null, registered = cashu))
        }
    }

    @Test
    fun moveBackIsOfferedOnlyWhileTheHandlePaysCashuAndTheOldWalletIsHere() {
        assertTrue(canMoveHandleBackToLegacy(handle, LegacyWalletPresence.Present, HandleAddressWallet.Cashu))
        assertFalse(canMoveHandleBackToLegacy(handle, LegacyWalletPresence.Absent, HandleAddressWallet.Cashu))
        assertFalse(canMoveHandleBackToLegacy(handle, LegacyWalletPresence.Unknown, HandleAddressWallet.Cashu))
        assertFalse(canMoveHandleBackToLegacy(handle, LegacyWalletPresence.Present, HandleAddressWallet.Legacy))
        assertFalse(canMoveHandleBackToLegacy(handle, LegacyWalletPresence.Present, null))
        assertFalse(canMoveHandleBackToLegacy(null, LegacyWalletPresence.Present, HandleAddressWallet.Cashu))
    }

    @Test
    fun theRecordIsPerAccount() {
        val prefs = MapWalletPrefs()
        assertEquals(HandleAddressRecord(null, null), HandleAddressRecord.load(prefs, "a"))
        HandleAddressRecord.save(prefs, "a", HandleAddressRecord(HandleAddressWallet.Cashu, "lno1x"))
        HandleAddressRecord.save(prefs, "b", HandleAddressRecord(HandleAddressWallet.Legacy, "lno1breez"))
        assertEquals(HandleAddressRecord(HandleAddressWallet.Cashu, "lno1x"), HandleAddressRecord.load(prefs, "a"))
        assertEquals(HandleAddressRecord(HandleAddressWallet.Legacy, "lno1breez"), HandleAddressRecord.load(prefs, "b"))
        HandleAddressRecord.save(prefs, "a", HandleAddressRecord(null, null))
        assertEquals(HandleAddressRecord(null, null), HandleAddressRecord.load(prefs, "a"))
    }

    @Test
    fun aFailedUpdateBacksOff() {
        assertEquals(30_000L, handleReclaimRetryDelayMs(0))
        assertEquals(60_000L, handleReclaimRetryDelayMs(1))
        assertEquals(15 * 60_000L, handleReclaimRetryDelayMs(20))
    }
}
