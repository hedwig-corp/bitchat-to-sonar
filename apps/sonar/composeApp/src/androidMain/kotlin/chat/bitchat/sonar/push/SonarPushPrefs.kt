package chat.bitchat.sonar.push

import android.content.Context
import chat.bitchat.sonar.SonarCore
import chat.bitchat.sonar.SonarNotificationPrefs
import chat.bitchat.sonar.sonarNotificationDisplayEnabled

internal object SonarPushPrefs {
    private const val PREFS = "sonar"

    fun notificationsEnabled(context: Context): Boolean =
        bool(context, "notifs", true)

    fun backgroundPushEnabled(context: Context): Boolean =
        bool(context, "pushEnabled", true)

    fun effectivePushEnabled(context: Context): Boolean =
        notificationsEnabled(context) && backgroundPushEnabled(context)

    fun notificationPrefs(context: Context): SonarNotificationPrefs =
        SonarNotificationPrefs(
            enabled = sonarNotificationDisplayEnabled(notificationsEnabled(context)),
            showNames = bool(context, "notifNames", true),
            showPreview = bool(context, "notifPreview", false),
            showPaymentAmount = true,
        )

    /** Stable, non-secret owner for durable notification work. Derivation is
     * local and does not open/start the node; only the canonical public npub is
     * persisted in WorkManager/admission metadata, matching Apple. */
    fun accountOwnerId(): String? {
        return SonarCore.notificationAccountOwnerId()
    }

    private fun bool(context: Context, key: String, default: Boolean): Boolean {
        val value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("blob.pref.$key", "")
            .orEmpty()
        return if (value.isEmpty()) default else value == "1"
    }
}
