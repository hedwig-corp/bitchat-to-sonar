package chat.bitchat.sonar

/**
 * Local notifications for incoming messages — the Android twin of the iOS
 * local-notification path (no push server; fires while the process is alive,
 * like iOS local notifications). [ensureChannel] must run once at startup.
 */
expect object Notifier {
    fun ensureChannel()
    fun canNotify(): Boolean
    fun notify(id: Int, title: String, body: String)
    /** Called after the wallet reaches Ready — retries push webhook registration
     *  that was deferred because the wallet was not connected at startup. */
    fun onWalletReady()
    /** Called after a BOLT12 receive offer is published so mobile push can bind
     *  the Breez NDS webhook to the exact offer used by offline payers. */
    fun onPaymentOfferReady(offer: String)
    /** Re-register or unregister push tokens when the user toggles push in settings. */
    fun setPushEnabled(enabled: Boolean)
}
