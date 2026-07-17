package chat.bitchat.sonar

internal actual fun sonarLog(tag: String, message: String) {
    println("[$tag] $message")
    // Tee into the bounded diagnostics file so "Share debug bundle" works on
    // installs we can't attach to (async, never blocks the caller).
    SonarFileLog.append(tag, message)
}

// Desktop has no debug/release split; markers are opt-in per run:
// ./gradlew :composeApp:run -Dsonar.bench.markers=1
internal actual val sonarBenchMarkersEnabled: Boolean =
    System.getProperty("sonar.bench.markers") == "1"
