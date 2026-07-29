package chat.bitchat.sonar

import androidx.compose.runtime.Composable

internal enum class SystemBackAction {
    /** Leave Back unhandled so Android can finish/background the root Activity. */
    System,

    /** Pop exactly one entry from Sonar's app-owned route stack. */
    Navigate,

    /** Keep a modal route visible without performing a destructive action. */
    Consume,
}

/** Calls are modal routes: only their explicit Decline/End controls may leave them. */
internal fun systemBackAction(isAtRoot: Boolean, isCallScreen: Boolean): SystemBackAction = when {
    isCallScreen -> SystemBackAction.Consume
    isAtRoot -> SystemBackAction.System
    else -> SystemBackAction.Navigate
}

/** Platform hook for system Back. Desktop has no activity Back dispatcher. */
@Composable
internal expect fun PlatformBackHandler(
    enabled: Boolean,
    onBack: () -> Unit,
)

/** Connect Android's dispatcher to Sonar's route stack without popping modal calls. */
@Composable
internal fun SonarSystemBackHandler(
    enabled: Boolean,
    isAtRoot: Boolean,
    isCallScreen: Boolean,
    onNavigate: () -> Unit,
) {
    val action = systemBackAction(isAtRoot = isAtRoot, isCallScreen = isCallScreen)
    PlatformBackHandler(
        enabled = enabled && action != SystemBackAction.System,
        onBack = {
            if (action == SystemBackAction.Navigate) onNavigate()
        },
    )
}

/**
 * Give a visible Compose-owned overlay priority over the route-level handler.
 * AndroidX dispatches Back to the last enabled composed handler, so a handler
 * installed by the overlay dismisses that surface before app navigation runs.
 */
@Composable
internal fun TransientBackHandler(onBack: () -> Unit) {
    PlatformBackHandler(
        enabled = true,
        onBack = onBack,
    )
}
