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
    /** Called after the LEGACY Breez wallet connects — retries push webhook
     *  registration that was deferred because it was not connected at startup. */
    fun onWalletReady()
    /** Called with the LEGACY Breez wallet's own BOLT12 offer so mobile push can
     *  bind the Breez NDS webhook to it. Never called with the Cashu offer. */
    fun onPaymentOfferReady(offer: String)
    /** The legacy Breez wallet was deleted: forget its webhook state. */
    suspend fun onLegacyWalletRemoved()
    /** Clear account-bound push and wallet-offer state while preserving the
     *  device token so the replacement account can register immediately. */
    suspend fun prepareForAccountReplacement()
    /** Re-register or unregister push tokens when the user toggles push in settings. */
    fun setPushEnabled(enabled: Boolean)
}
