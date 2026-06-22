package chat.bitchat.sonar

enum class SonarNotificationKind {
    Message,
    Payment,
    Call,
    Invite,
    Mention,
    Geohash,
    Network,
}

data class SonarNotificationPrefs(
    val enabled: Boolean = true,
    val showNames: Boolean = false,
    val showPreview: Boolean = false,
)

data class SonarNotification(
    val id: Int,
    val title: String,
    val body: String,
    val kind: SonarNotificationKind,
)

object SonarNotificationRouter {
    fun classifyContent(
        content: String,
        isCallControl: (String) -> Boolean = { false },
    ): SonarNotificationKind =
        when {
            isCallControl(content) -> SonarNotificationKind.Call
            PayLine.decode(content) != null -> SonarNotificationKind.Payment
            else -> SonarNotificationKind.Message
        }

    fun build(
        idKey: String,
        kind: SonarNotificationKind,
        conversationTitle: String? = null,
        preview: String? = null,
        prefs: SonarNotificationPrefs = SonarNotificationPrefs(),
    ): SonarNotification? {
        if (!prefs.enabled) return null
        return SonarNotification(
            id = idKey.hashCode(),
            title = title(kind, conversationTitle, prefs),
            body = body(kind, preview, prefs),
            kind = kind,
        )
    }

    private fun title(
        kind: SonarNotificationKind,
        conversationTitle: String?,
        prefs: SonarNotificationPrefs,
    ): String =
        when (kind) {
            SonarNotificationKind.Message ->
                if (prefs.showNames && !conversationTitle.isNullOrBlank()) conversationTitle else "New Sonar message"
            SonarNotificationKind.Payment -> "Payment received"
            SonarNotificationKind.Call -> "Incoming Sonar call"
            SonarNotificationKind.Invite -> "New Sonar invite"
            SonarNotificationKind.Mention -> "You were mentioned"
            SonarNotificationKind.Geohash ->
                if (!conversationTitle.isNullOrBlank()) conversationTitle else "New channel activity"
            SonarNotificationKind.Network -> "People nearby on Sonar"
        }

    private fun body(
        kind: SonarNotificationKind,
        preview: String?,
        prefs: SonarNotificationPrefs,
    ): String =
        when (kind) {
            SonarNotificationKind.Message ->
                if (prefs.showPreview) sanitizePreview(preview).ifBlank { "Open Sonar to read it." }
                else "Open Sonar to read it."
            SonarNotificationKind.Payment -> "Open Sonar to view the payment."
            SonarNotificationKind.Call -> "Open Sonar to answer."
            SonarNotificationKind.Invite -> "Open Sonar to review the invite."
            SonarNotificationKind.Mention -> "Open Sonar to read it."
            SonarNotificationKind.Geohash -> "Open Sonar to view the channel."
            SonarNotificationKind.Network -> "Open Sonar to see who is nearby."
        }

    private fun sanitizePreview(value: String?): String =
        value
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.let { if (it.length > 80) it.take(80) + "..." else it }
            ?: ""
}
