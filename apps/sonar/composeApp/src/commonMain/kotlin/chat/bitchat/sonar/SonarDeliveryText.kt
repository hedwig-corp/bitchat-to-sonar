package chat.bitchat.sonar

internal fun sonarDeliveryLabel(state: String?): String? {
    val trimmed = state?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    sonarPartialDeliveryLabel(trimmed)?.let { return it }
    return when (trimmed.lowercase()) {
        "sending" -> "Sending"
        "uploading" -> "Uploading"
        "sent" -> "Sent"
        "delivered" -> "Delivered"
        "read" -> "Read"
        "couldn't send", "couldnt send", "failed" -> "Couldn't send"
        else -> trimmed
    }
}

/** Group sends confirmed by only a subset of members carry a machine state of
 *  the form `partial:<reached>:<total>` and render like the iOS
 *  `stateText()` `.partiallyDelivered` case: "Delivered to X of Y".
 *  Note: the Compose core bridge does not emit this state yet (`toUiState`
 *  in `SonarCore.android.kt` maps delivery to Sending/Couldn't send/Sent
 *  only) — the producer side is a tracked parity gap; this keeps the label
 *  layer ready and matched to iOS copy. Malformed counts fall through to the
 *  raw-state passthrough. */
private fun sonarPartialDeliveryLabel(trimmed: String): String? {
    val parts = trimmed.split(':')
    if (parts.size != 3 || !parts[0].equals("partial", ignoreCase = true)) return null
    val reached = parts[1].toIntOrNull()?.takeIf { it >= 0 } ?: return null
    val total = parts[2].toIntOrNull()?.takeIf { it >= 0 } ?: return null
    return "Delivered to $reached of $total"
}

internal fun sonarDeliveryPending(state: String?): Boolean =
    when (sonarDeliveryLabel(state)) {
        "Sending", "Uploading" -> true
        else -> false
    }

internal fun sonarDeliveryFailed(state: String?): Boolean =
    sonarDeliveryLabel(state) == "Couldn't send"
