package chat.bitchat.sonar

internal actual fun sonarLog(tag: String, message: String) {
    android.util.Log.i(tag, message)
}
