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
    val showNames: Boolean = true,
    val showPreview: Boolean = false,
    val showPaymentAmount: Boolean = true,
)

data class SonarNotificationRenderInput(
    val enabled: Boolean,
    val kindHint: SonarNotificationKind? = null,
    val conversationTitle: String? = null,
    val senderName: String? = null,
    val groupName: String? = null,
    val contentPreview: String? = null,
    val unreadCount: Long = 1,
    val showNames: Boolean,
    val showPreview: Boolean,
    val showPaymentAmount: Boolean,
)

data class SonarNotificationEnvelope(
    val kind: SonarNotificationKind,
    val title: String,
    val body: String,
    val paymentSats: Long? = null,
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
    ): SonarNotificationKind {
        val local = classifyContentLocal(content, isCallControl)
        return runCatching { SonarCore.classifyNotificationContent(content) }
            .getOrElse { local }
            .let { classified ->
                if (classified == SonarNotificationKind.Message &&
                    local != SonarNotificationKind.Message
                ) local else classified
            }
    }

    fun build(
        idKey: String,
        kind: SonarNotificationKind,
        conversationTitle: String? = null,
        senderName: String? = null,
        groupName: String? = null,
        preview: String? = null,
        unreadCount: Long = 1,
        prefs: SonarNotificationPrefs = SonarNotificationPrefs(),
    ): SonarNotification? {
        val input = SonarNotificationRenderInput(
            enabled = prefs.enabled,
            kindHint = kind,
            conversationTitle = conversationTitle,
            senderName = senderName,
            groupName = groupName,
            contentPreview = preview,
            unreadCount = unreadCount.coerceAtLeast(1L),
            showNames = prefs.showNames,
            showPreview = prefs.showPreview,
            showPaymentAmount = prefs.showPaymentAmount,
        )
        val envelope = runCatching { SonarCore.renderNotification(input) }
            .getOrNull()
            ?: renderLocal(input)
            ?: return null
        return SonarNotification(
            id = idKey.hashCode(),
            title = envelope.title,
            body = envelope.body,
            kind = envelope.kind,
        )
    }

    private fun classifyContentLocal(
        content: String,
        isCallControl: (String) -> Boolean,
    ): SonarNotificationKind =
        when {
            isCallControl(content) ||
                content.trimStart().startsWith("\u260eCALL|") -> SonarNotificationKind.Call
            PayLine.decode(content) != null -> SonarNotificationKind.Payment
            else -> SonarNotificationKind.Message
        }

    private fun renderLocal(input: SonarNotificationRenderInput): SonarNotificationEnvelope? {
        if (!input.enabled) return null
        val kind = input.kindHint ?: classifyContentLocal(input.contentPreview.orEmpty()) { false }
        val label = visibleLabel(input.conversationTitle, input.senderName, input.showNames)
        val group = visibleGroup(input.groupName, input.senderName, input.showNames)
        return SonarNotificationEnvelope(
            kind = kind,
            title = title(kind, label, group),
            body = body(kind, input.contentPreview, input.unreadCount, input, label, group),
            paymentSats = (PayLine.decode(input.contentPreview.orEmpty()) as? PayLine.Pay)?.sats,
        )
    }

    private fun title(
        kind: SonarNotificationKind,
        label: String?,
        group: String?,
    ): String =
        when (kind) {
            SonarNotificationKind.Message ->
                when {
                    !label.isNullOrBlank() && !group.isNullOrBlank() -> "$label in $group"
                    !label.isNullOrBlank() -> label
                    !group.isNullOrBlank() -> group
                    else -> "New Sonar message"
                }
            SonarNotificationKind.Payment ->
                if (!label.isNullOrBlank()) "Payment from $label" else "Payment received"
            SonarNotificationKind.Call ->
                if (!label.isNullOrBlank()) "Incoming call from $label" else "Incoming Sonar call"
            SonarNotificationKind.Invite ->
                if (!label.isNullOrBlank()) "Invite from $label" else "New Sonar invite"
            SonarNotificationKind.Mention ->
                if (!label.isNullOrBlank()) "$label mentioned you" else "You were mentioned"
            SonarNotificationKind.Geohash ->
                group ?: label ?: "New channel activity"
            SonarNotificationKind.Network -> "People nearby on Sonar"
        }

    private fun body(
        kind: SonarNotificationKind,
        preview: String?,
        unreadCount: Long,
        input: SonarNotificationRenderInput,
        label: String?,
        group: String?,
    ): String =
        when (kind) {
            SonarNotificationKind.Message, SonarNotificationKind.Mention, SonarNotificationKind.Geohash ->
                if (input.showPreview) sanitizePreview(preview).ifBlank { "Open Sonar to read it." }
                else if (unreadCount > 1) "$unreadCount unread messages."
                else if (kind == SonarNotificationKind.Geohash) "Open Sonar to view the channel."
                else "Open Sonar to read it."
            SonarNotificationKind.Payment -> paymentBody(preview, input, label, group)
            SonarNotificationKind.Call -> "Tap to answer."
            SonarNotificationKind.Invite ->
                if (!group.isNullOrBlank()) "Open Sonar to review the invite to $group."
                else "Open Sonar to review the invite."
            SonarNotificationKind.Network -> "Open Sonar to see who is nearby."
        }

    private fun sanitizePreview(value: String?): String =
        value
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.let { if (it.length > 80) it.take(80) + "..." else it }
            ?: ""

    private fun paymentBody(
        preview: String?,
        input: SonarNotificationRenderInput,
        label: String?,
        group: String?,
    ): String {
        val amount = (PayLine.decode(preview.orEmpty()) as? PayLine.Pay)
            ?.sats
            ?.takeIf { input.showPaymentAmount }
            ?.let(::formatSats)
        return when {
            amount != null && !label.isNullOrBlank() && !group.isNullOrBlank() ->
                "$amount received from $label in $group."
            amount != null && !label.isNullOrBlank() ->
                "$amount received from $label."
            amount != null && !group.isNullOrBlank() ->
                "$amount received in $group."
            amount != null -> "$amount received."
            else -> "Open Sonar to view the payment."
        }
    }

    private fun visibleLabel(
        conversationTitle: String?,
        senderName: String?,
        showNames: Boolean,
    ): String? {
        if (!showNames) return null
        return senderName?.trim()?.takeIf { it.isNotEmpty() }
            ?: conversationTitle?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun visibleGroup(
        groupName: String?,
        senderName: String?,
        showNames: Boolean,
    ): String? {
        if (!showNames) return null
        val group = groupName?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val sender = senderName?.trim()?.takeIf { it.isNotEmpty() }
        return group.takeUnless { sender != null && it == sender }
    }

    private fun formatSats(sats: Long): String =
        sats.toString().reversed().chunked(3).joinToString(",").reversed() + " sats"
}
