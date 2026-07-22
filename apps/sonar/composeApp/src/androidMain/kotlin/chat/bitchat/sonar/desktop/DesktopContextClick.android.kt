package chat.bitchat.sonar.desktop

import androidx.compose.ui.Modifier

/** No-op on Android — row actions there come from the phone HomeScreen long-press. */
actual fun Modifier.desktopContextClick(onRowActions: (() -> Unit)?): Modifier = this
