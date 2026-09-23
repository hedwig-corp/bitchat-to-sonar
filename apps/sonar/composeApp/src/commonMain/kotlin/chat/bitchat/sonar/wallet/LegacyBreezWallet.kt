package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.a_payment_in_the_old_wallet_hasn_t
import chat.bitchat.sonar.resources.a_payment_is_still_arriving_in_the_old
import chat.bitchat.sonar.resources.a_payment_is_still_leaving_the_old
import chat.bitchat.sonar.resources.connect_to_the_internet_so_sonar_can
import chat.bitchat.sonar.resources.it_still_holds_send_it_out_first
import chat.bitchat.sonar.resources.sonar_can_t_confirm_the_old_wallet_is
import chat.bitchat.sonar.resources.still_checking_the_old_wallet_try_again
import chat.bitchat.sonar.resources.the_old_wallet_has_a_refund_waiting_to
import kotlinx.coroutines.flow.SharedFlow
import org.jetbrains.compose.resources.StringResource
import kotlinx.coroutines.flow.StateFlow

/**
 * The Breez SDK Liquid wallet that shipped before Cashu, kept as a LEGACY
 * wallet (docs/WALLET-INTEGRATION.md "Legacy Breez"):
 *
 *  - NEVER created for a new install: opened only when its store already
 *    exists on this device ([isPresent] is a pure disk check that never
 *    creates `sonar-wallet/`).
 *  - Visible while present (balance + pending), spendable through the send
 *    flow, deletable only when [legacyDeleteGate] says the funds are provably
 *    safe. Never auto-deleted.
 *  - A restored account gets ONE background check ([runRestoreCheck]) on
 *    builds with a Breez API key.
 *  - Its NDS webhook / invoice_request push path runs only while it exists,
 *    against its OWN offer (never the published Cashu offer).
 *
 * Breez stays on its native Kotlin SDK: its forked plain-sqlite
 * `libsqlite3-sys` cannot share a binary with the SQLCipher core.
 */
expect object LegacyBreezWallet {
    /** True when this build carries a Breez API key (needed to open it at all). */
    fun hasApiKey(): Boolean

    /**
     * A legacy store exists on disk for [accountId]. Restores this account's
     * archive (from a previous account replacement) when there is one. Never
     * creates anything and never touches the network.
     */
    fun isPresent(accountId: String): Boolean

    /** What the legacy card shows. `present = false` hides it. */
    val snapshot: StateFlow<LegacyWalletSnapshot>

    fun state(): WalletState

    val balanceFlow: StateFlow<Long>

    /** Settled legacy payments (the Breez listener). */
    val paymentEvents: SharedFlow<WalletPaymentEvent>

    /** Connect the legacy wallet iff its store exists. Never creates one. */
    suspend fun openIfPresent(nsec: String): Boolean

    /**
     * The one-time check after an account restore: open Breez from the
     * derived seed, sync, keep it if it has any balance or history, otherwise
     * delete what the check created. Needs an API key.
     */
    suspend fun runRestoreCheck(nsec: String): LegacyRestoreCheckOutcome

    suspend fun refreshBalance(): Long

    /** The legacy wallet's OWN BOLT12 offer (for its NDS webhook only). */
    suspend fun createOffer(): String

    /** Spend from the legacy wallet (0.5% `Max` reserve applies here only). */
    suspend fun send(destination: String, amountSats: Long, note: String): SendResult

    suspend fun registerWebhook(url: String)
    suspend fun unregisterWebhook()

    /** Connect, sync, read the facts and evaluate the delete gate. */
    suspend fun deleteGate(): LegacyDeleteGate

    /**
     * Re-check the gate → unregister the webhook → disconnect → crash-safe
     * marker → delete the Breez store → clear the marker. Returns the gate it
     * acted on; nothing is deleted unless it is [LegacyDeleteGate.Safe].
     */
    suspend fun deleteIfSafe(): LegacyDeleteGate

    /**
     * Account replacement. Deletes the store only when the gate passes;
     * otherwise renames it to `sonar-wallet-archive/<oldAccountId>/` so the
     * old account gets it back if it is ever restored here.
     */
    suspend fun releaseForAccountReplacement(oldAccountId: String)

    suspend fun shutdown()

    /** Panic wipe: the live store AND every archive. Throws if any remains. */
    suspend fun wipeLocalStorage()
}

/** What the "Old Lightning wallet" card renders. */
data class LegacyWalletSnapshot(
    val present: Boolean = false,
    val connected: Boolean = false,
    val balanceSats: Long = 0L,
    val pendingSendSats: Long = 0L,
    val pendingReceiveSats: Long = 0L,
)

enum class LegacyRestoreCheckOutcome {
    /** No API key in this build: nothing was checked (and nothing recorded). */
    Skipped,
    /** A legacy store already existed; nothing to check. */
    AlreadyPresent,
    /** The derived wallet had funds or history: kept as legacy. */
    Kept,
    /** Empty: everything the check created was deleted. */
    Discarded,
    /** Could not complete (network / SDK); what it created was removed. Retry later. */
    Failed,
}

/**
 * The facts the delete gate reads. `null` = unknown (a read failed or was
 * not possible), and anything unknown blocks the delete.
 */
data class LegacyGateFacts(
    val connected: Boolean,
    /** A sync completed after the current connect. */
    val syncedSinceConnect: Boolean,
    val confirmedSats: Long?,
    val pendingSendSats: Long?,
    val pendingReceiveSats: Long?,
    val refundableSwaps: Int?,
    /** Payments in any non-terminal state (pending, refundable, …). */
    val unsettledPayments: Int?,
)

enum class LegacyDeleteBlock {
    NotConnected,
    NotSynced,
    Unknown,
    HasBalance,
    PendingSend,
    PendingReceive,
    RefundableSwaps,
    UnsettledPayments,
    /** The wallet is not present (nothing to delete). */
    Absent,
}

sealed interface LegacyDeleteGate {
    data object Safe : LegacyDeleteGate
    data class Blocked(val reason: LegacyDeleteBlock) : LegacyDeleteGate
}

/**
 * The legacy delete gate. Pure: ALL of connected, synced since connecting,
 * zero confirmed / pending-send / pending-receive, no refundable swaps and no
 * unsettled payments. Anything unknown is NOT safe.
 */
fun legacyDeleteGate(f: LegacyGateFacts): LegacyDeleteGate {
    fun blocked(r: LegacyDeleteBlock) = LegacyDeleteGate.Blocked(r)
    if (!f.connected) return blocked(LegacyDeleteBlock.NotConnected)
    if (!f.syncedSinceConnect) return blocked(LegacyDeleteBlock.NotSynced)
    val confirmed = f.confirmedSats ?: return blocked(LegacyDeleteBlock.Unknown)
    val pendingSend = f.pendingSendSats ?: return blocked(LegacyDeleteBlock.Unknown)
    val pendingReceive = f.pendingReceiveSats ?: return blocked(LegacyDeleteBlock.Unknown)
    val refundables = f.refundableSwaps ?: return blocked(LegacyDeleteBlock.Unknown)
    val unsettled = f.unsettledPayments ?: return blocked(LegacyDeleteBlock.Unknown)
    return when {
        confirmed != 0L -> blocked(LegacyDeleteBlock.HasBalance)
        pendingSend != 0L -> blocked(LegacyDeleteBlock.PendingSend)
        pendingReceive != 0L -> blocked(LegacyDeleteBlock.PendingReceive)
        refundables != 0 -> blocked(LegacyDeleteBlock.RefundableSwaps)
        unsettled != 0 -> blocked(LegacyDeleteBlock.UnsettledPayments)
        else -> LegacyDeleteGate.Safe
    }
}

/**
 * Why the old wallet cannot be deleted yet — shown under the delete action.
 * The same catalog keys as iOS `LegacyBreezWallet.message(for:)`; the
 * [LegacyDeleteBlock.HasBalance] string takes the formatted amount as `%1$s`.
 */
fun legacyDeleteBlockMessage(reason: LegacyDeleteBlock): StringResource = when (reason) {
    LegacyDeleteBlock.Unknown, LegacyDeleteBlock.Absent -> Res.string.sonar_can_t_confirm_the_old_wallet_is
    LegacyDeleteBlock.NotConnected -> Res.string.connect_to_the_internet_so_sonar_can
    LegacyDeleteBlock.NotSynced -> Res.string.still_checking_the_old_wallet_try_again
    LegacyDeleteBlock.HasBalance -> Res.string.it_still_holds_send_it_out_first
    LegacyDeleteBlock.PendingSend -> Res.string.a_payment_is_still_leaving_the_old
    LegacyDeleteBlock.PendingReceive -> Res.string.a_payment_is_still_arriving_in_the_old
    LegacyDeleteBlock.RefundableSwaps -> Res.string.the_old_wallet_has_a_refund_waiting_to
    LegacyDeleteBlock.UnsettledPayments -> Res.string.a_payment_in_the_old_wallet_hasn_t
}

/**
 * Disk rules for the legacy store, shared by both platform actuals:
 *
 *  - live store: `<root>/sonar-wallet/` (Breez working dir `mainnet/`), with
 *    a `sonar-owner` file naming the account it belongs to (written the first
 *    time this build opens it; older stores have none and belong to the
 *    signed-in account, because earlier builds deleted the store on every
 *    account replacement);
 *  - archives: `<root>/sonar-wallet-archive/<accountId>/`.
 *
 * Presence is decided WITHOUT creating anything: an empty `mainnet/` left by
 * a failed first connect is not a store.
 */
class LegacyBreezStore(private val root: () -> String, private val files: WalletFileOps) {
    private val base: String get() = root().trimEnd('/')
    val liveDir: String get() = "$base/$LIVE_DIR"
    val workingDir: String get() = "$liveDir/mainnet"
    private val ownerFile: String get() = "$liveDir/$OWNER_FILE"
    private val checkMarker: String get() = "$liveDir/$CHECK_MARKER"
    val archiveRoot: String get() = "$base/$ARCHIVE_DIR"
    fun archiveDir(accountId: String): String = "$archiveRoot/$accountId"

    /** A live store with content exists (whoever it belongs to). */
    fun hasLiveStore(): Boolean = files.hasEntries(workingDir) && !files.exists(checkMarker)

    fun owner(): String? = files.readText(ownerFile)?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * True when [accountId] has a legacy store here. Moves another account's
     * live store aside to its archive, and brings [accountId]'s archive back,
     * so a store is never opened with the wrong seed.
     */
    fun resolvePresent(accountId: String): Boolean {
        // A restore check that died mid-way left a store nobody decided to
        // keep: it is not a legacy wallet, and the check will run again.
        if (files.exists(checkMarker) && !files.deleteTree(liveDir)) return false
        if (hasLiveStore()) {
            val owner = owner()
            if (owner == null || owner == accountId) return true
            // Not ours (defensive: replacement archives before switching).
            if (!archive(owner)) return false
        }
        val archived = archiveDir(accountId)
        if (!files.hasEntries(archived)) return false
        // An empty leftover live dir would block the rename.
        if (files.exists(liveDir) && !files.deleteTree(liveDir)) return false
        return files.rename(archived, liveDir) && hasLiveStore()
    }

    /** Record that the live store belongs to [accountId]. */
    fun claim(accountId: String): Boolean =
        owner() == accountId || files.writeText(ownerFile, accountId)

    /**
     * Rename the live store to [accountId]'s archive (same volume). An
     * archive already there may hold funds, so it is never replaced: the
     * store goes to the first free `<accountId>-N` instead (only the exact
     * `<accountId>` archive comes back automatically; a suffixed one waits
     * for a manual restore, which beats deleting it).
     */
    fun archive(accountId: String): Boolean {
        if (!files.exists(liveDir)) return true
        var target = archiveDir(accountId)
        var suffix = 2
        while (files.exists(target)) {
            target = archiveDir("$accountId-$suffix")
            suffix += 1
        }
        return files.rename(liveDir, target)
    }

    /**
     * Start the post-restore check: mark the live dir so a crash mid-check
     * never leaves a store that looks like a kept legacy wallet. Refuses when
     * any live dir already exists.
     */
    fun beginRestoreCheck(): Boolean =
        !files.exists(liveDir) && files.writeText(checkMarker, "1")

    /** The check found funds or history: the store is [accountId]'s legacy wallet. */
    fun keepRestoreCheck(accountId: String): Boolean =
        files.writeText(ownerFile, accountId) && files.deleteTree(checkMarker)

    /** Delete the live store. True when nothing remains. */
    fun deleteLive(): Boolean = files.deleteTree(liveDir)

    /** Delete the live store and every archive (panic wipe). */
    fun deleteEverything(): Boolean = files.deleteTree(liveDir) && files.deleteTree(archiveRoot)

    companion object {
        const val LIVE_DIR = "sonar-wallet"
        const val ARCHIVE_DIR = "sonar-wallet-archive"
        const val OWNER_FILE = "sonar-owner"
        const val CHECK_MARKER = "sonar-restore-check"

        /** Per-account restore-check flag in [WalletPrefs]: [CHECK_PENDING] | [CHECK_DONE]. */
        fun restoreCheckKey(accountId: String) = "wallet.legacy.restoreCheck.$accountId"
        const val CHECK_PENDING = "pending"
        const val CHECK_DONE = "done"

        /**
         * Whether a restore-check outcome settles the per-account flag. Skipped
         * (no API key in this build) and Failed (offline / SDK error) leave it
         * pending so a later launch — or a build with a key — runs it.
         */
        fun settlesRestoreCheck(outcome: LegacyRestoreCheckOutcome): Boolean = when (outcome) {
            LegacyRestoreCheckOutcome.Kept,
            LegacyRestoreCheckOutcome.Discarded,
            LegacyRestoreCheckOutcome.AlreadyPresent -> true
            LegacyRestoreCheckOutcome.Skipped,
            LegacyRestoreCheckOutcome.Failed -> false
        }
    }
}
