package chat.bitchat.sonar

import androidx.compose.runtime.Composable

@Suppress("UNUSED_PARAMETER")
@Composable
internal actual fun PlatformBackHandler(
    enabled: Boolean,
    onBack: () -> Unit,
) = Unit
