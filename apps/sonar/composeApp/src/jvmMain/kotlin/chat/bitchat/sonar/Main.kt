package chat.bitchat.sonar

import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import chat.bitchat.sonar.desktop.DesktopApp
import java.awt.event.WindowEvent
import java.awt.event.WindowFocusListener

/**
 * Sonar Desktop entry point (Compose Desktop). Loads the bundled Rust-core native
 * library, opens the main window and renders [DesktopApp] (theme + boot +
 * onboarding around the split-view shell). Window focus is bridged into
 * [SonarLifecycle] so foreground-gated behavior matches the mobile apps.
 */
fun main() {
    // Make UniFFI's JNA loader find the bundled libsonar_ffi before any FFI call.
    SonarNativeLoader.ensureLoaded()
    // Bridge the Rust core's `tracing` logs (iroh/call/media) to stderr so call
    // diagnostics are visible. No-op after the first call. (Android wires this
    // through NdkContext.nativeInit; iOS through BitchatApp.init.)
    uniffi.sonar_ffi.initLogging()

    application {
        val windowState = rememberWindowState(width = 1240.dp, height = 820.dp)
        Window(
            onCloseRequest = ::exitApplication,
            state = windowState,
            title = "Sonar",
        ) {
            DisposableEffect(window) {
                val listener = object : WindowFocusListener {
                    override fun windowGainedFocus(e: WindowEvent?) {
                        SonarLifecycle.onForeground?.invoke(true)
                    }
                    override fun windowLostFocus(e: WindowEvent?) {
                        SonarLifecycle.onForeground?.invoke(false)
                    }
                }
                window.addWindowFocusListener(listener)
                onDispose { window.removeWindowFocusListener(listener) }
            }
            DesktopApp()
        }
    }
}
