package chat.bitchat.sonar.wallet

/**
 * Which wallet the claimed handle (`name@sonarprivacy.xyz`) pays: the offer
 * its BIP-353 DNS record at the Sonar registrar carries. The handle is a
 * public address that can be printed or shared outside the app, so moving it
 * from the legacy Breez wallet to the Cashu wallet (custody at the mint) is
 * the user's decision, never a side effect of an app update.
 * docs/WALLET-INTEGRATION.md "The handle's payment address". iOS mirror:
 * `SonarHandleAddressWallet`.
 */
enum class HandleAddressWallet(val wire: String) {
    Legacy("legacy"),
    Cashu("cashu");

    companion object {
        fun fromWire(value: String?): HandleAddressWallet? = entries.firstOrNull { it.wire == value }
    }
}

/** Whether a legacy Breez wallet exists on this device, as far as the app has established it. */
enum class LegacyWalletPresence { Present, Absent, Unknown }

/** What the app may do with the handle when the Cashu offer is known. */
enum class HandleOfferAction {
    /** Nothing to register. */
    None,

    /** Re-register the handle with the Cashu offer, with no prompt. */
    ReclaimWithCashu,

    /**
     * The handle pays the old wallet and one exists here: leave it, and
     * show "still pays your old wallet" with a confirmed move.
     */
    AskToMove,
}

/**
 * The handle decision (iOS: `SonarHandleOfferPolicy.action`).
 *
 * - No claimed handle: nothing.
 * - Recorded as paying Cashu: re-register when the Cashu offer differs from
 *   the one last registered (a rotated offer, or a chat-only claim made
 *   before the wallet had one).
 * - Otherwise (recorded as paying the old wallet, or not known yet — an
 *   install that claimed its handle before Cashu):
 *   - a legacy wallet is present: [HandleOfferAction.AskToMove]. The app
 *     never retargets it on its own;
 *   - presence not established yet: nothing, until it is;
 *   - no legacy wallet: nothing to move away from, so re-register as above.
 */
fun handleOfferAction(
    claimedHandle: String?,
    legacyPresence: LegacyWalletPresence,
    addressWallet: HandleAddressWallet?,
    cashuOffer: String?,
    lastRegisteredOffer: String?,
): HandleOfferAction {
    if (claimedHandle.isNullOrBlank()) return HandleOfferAction.None
    val offerChanged = !cashuOffer.isNullOrBlank() && cashuOffer != lastRegisteredOffer
    if (addressWallet == HandleAddressWallet.Cashu) {
        return if (offerChanged) HandleOfferAction.ReclaimWithCashu else HandleOfferAction.None
    }
    return when (legacyPresence) {
        LegacyWalletPresence.Present -> HandleOfferAction.AskToMove
        LegacyWalletPresence.Unknown -> HandleOfferAction.None
        LegacyWalletPresence.Absent -> if (offerChanged) HandleOfferAction.ReclaimWithCashu else HandleOfferAction.None
    }
}

/** "Move back to your old wallet" is offered while the handle pays Cashu and the old wallet is here. */
fun canMoveHandleBackToLegacy(
    claimedHandle: String?,
    legacyPresence: LegacyWalletPresence,
    addressWallet: HandleAddressWallet?,
): Boolean =
    !claimedHandle.isNullOrBlank() &&
        legacyPresence == LegacyWalletPresence.Present &&
        addressWallet == HandleAddressWallet.Cashu

/** Backoff for a failed automatic re-registration: 30 s, doubling, capped at 15 min (iOS parity). */
fun handleReclaimRetryDelayMs(attempt: Int): Long =
    minOf(30_000L shl minOf(maxOf(attempt, 0), 5), 15 * 60_000L)

/** What the handle's notice shows. */
sealed interface HandleAddressNotice {
    data object None : HandleAddressNotice

    /** "Your address … still pays your old wallet." + Move. */
    data class PaysOldWallet(val address: String) : HandleAddressNotice

    /** An automatic re-registration failed; it is retried with backoff. */
    data class UpdateFailing(val address: String) : HandleAddressNotice
}

/** In-flight state of a user-confirmed move. */
sealed interface HandleMoveState {
    data object Idle : HandleMoveState
    data object Moving : HandleMoveState
    data class Failed(val message: String) : HandleMoveState
}

/**
 * The per-account record, in [WalletPrefs]: which wallet the handle pays,
 * and the offer last registered with it (so a re-claim runs once per offer,
 * not once per launch).
 */
data class HandleAddressRecord(val wallet: HandleAddressWallet?, val registeredOffer: String?) {
    companion object {
        fun walletKey(accountId: String) = "wallet.handle.pays.$accountId"
        fun offerKey(accountId: String) = "wallet.handle.registeredOffer.$accountId"

        fun load(prefs: WalletPrefs, accountId: String): HandleAddressRecord = HandleAddressRecord(
            wallet = HandleAddressWallet.fromWire(prefs.get(walletKey(accountId))),
            registeredOffer = prefs.get(offerKey(accountId))?.takeIf { it.isNotBlank() },
        )

        fun save(prefs: WalletPrefs, accountId: String, record: HandleAddressRecord) {
            val wallet = record.wallet
            if (wallet == null) prefs.remove(walletKey(accountId)) else prefs.put(walletKey(accountId), wallet.wire)
            val offer = record.registeredOffer
            if (offer.isNullOrBlank()) prefs.remove(offerKey(accountId)) else prefs.put(offerKey(accountId), offer)
        }
    }
}
