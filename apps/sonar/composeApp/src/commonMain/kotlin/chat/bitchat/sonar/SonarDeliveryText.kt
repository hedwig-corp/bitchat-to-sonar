package chat.bitchat.sonar

internal fun sonarDeliveryLabel(state: String?): String? {
    val trimmed = state?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
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

internal fun sonarDeliveryPending(state: String?): Boolean =
    when (sonarDeliveryLabel(state)) {
        "Sending", "Uploading" -> true
        else -> false
    }

internal fun sonarDeliveryFailed(state: String?): Boolean =
    sonarDeliveryLabel(state) == "Couldn't send"
