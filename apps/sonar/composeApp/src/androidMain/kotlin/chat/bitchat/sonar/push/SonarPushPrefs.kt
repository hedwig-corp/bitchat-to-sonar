package chat.bitchat.sonar.push

import android.content.Context
import chat.bitchat.sonar.SonarNotificationPrefs

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
            enabled = effectivePushEnabled(context),
            showNames = bool(context, "notifNames", true),
            showPreview = bool(context, "notifPreview", false),
            showPaymentAmount = true,
        )

    private fun bool(context: Context, key: String, default: Boolean): Boolean {
        val value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("blob.pref.$key", "")
            .orEmpty()
        return if (value.isEmpty()) default else value == "1"
    }
}
