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
}
