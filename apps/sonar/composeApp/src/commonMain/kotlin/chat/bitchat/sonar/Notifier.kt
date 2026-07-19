package chat.bitchat.sonar

enum class SonarNotificationSound {
    Default,
    Ble,
    /** MSN-style trill (nudge) — the distinct double-bell alert. */
    Trill,
}

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
        conversationId: String? = null,
        messageId: String? = null,
    )
    /** Dismiss delivered notifications that belong to any of [conversationIds]. */
    fun clearConversations(conversationIds: Collection<String>)
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
