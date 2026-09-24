package chat.bitchat.sonar

import androidx.compose.runtime.Composable

/**
 * Keep the OS status/navigation bar icons legible against Sonar's own theme.
 *
 * Sonar's light/dark theme is an app setting, not the system one, so the
 * platform's automatic bar styling (Android `enableEdgeToEdge()` follows the
 * system night mode) painted dark icons over the dark app on a light-mode
 * phone — clock, battery and signal were invisible (QA-A2). Desktop has no
 * system bars.
 */
@Composable
internal expect fun SystemBarAppearance(dark: Boolean)

