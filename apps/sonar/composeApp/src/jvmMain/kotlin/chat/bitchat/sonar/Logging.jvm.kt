package chat.bitchat.sonar

internal actual fun sonarLog(tag: String, message: String) {
    println("[$tag] $message")
}
