package chat.bitchat.sonar

enum class SonarNotificationSound {
    Default,
    Ble,
}

internal fun accountNotificationsAllowed(
    suspended: Boolean,
    panicWipePending: Boolean,
): Boolean = !suspended && !panicWipePending

/**
 * Local notifications for incoming messages — the Android twin of the iOS
 * local-notification path (no push server; fires while the process is alive,
 * like iOS local notifications). [ensureChannel] must run once at startup.
 */
expect object Notifier {
    fun ensureChannel()
    fun canNotify(): Boolean
    fun notify(
        id: Int,
        title: String,
        body: String,
        sound: SonarNotificationSound = SonarNotificationSound.Default,
    )
    /** Synchronous panic boundary: serialize with notification publication and
     * cancel every platform notification owned by this app/account. */
    fun suspendAndCancelAll()
    /** Open a fresh account notification generation after replacement commits.
     * Returns false while the durable panic-wipe marker still fences account UI. */
    fun reactivateAccountNotifications(): Boolean
    /** Called after the wallet reaches Ready — retries push webhook registration
     *  that was deferred because the wallet was not connected at startup. */
    fun onWalletReady()
    /** Called after a BOLT12 receive offer is published so mobile push can bind
     *  the Breez NDS webhook to the exact offer used by offline payers. */
    fun onPaymentOfferReady(offer: String)
    /** Clear account-bound push and wallet-offer state while preserving the
     *  device token so the replacement account can register immediately. */
    suspend fun prepareForAccountReplacement()
    /** Re-register or unregister push tokens when the user toggles push in settings. */
    fun setPushEnabled(enabled: Boolean)
}
