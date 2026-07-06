package chat.bitchat.sonar

internal actual fun sonarLog(tag: String, message: String) {
    println("[$tag] $message")
    // Tee into the bounded diagnostics file so "Share debug bundle" works on
    // installs we can't attach to (async, never blocks the caller).
    SonarFileLog.append(tag, message)
}
