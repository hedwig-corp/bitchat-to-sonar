package chat.bitchat.sonar

import androidx.compose.runtime.Composable

/**
 * System Back belongs to Sonar when there is transient UI to dismiss or the
 * app-owned navigation stack is away from Home. At the true root, with no
 * transient UI, Android keeps its default Activity-exit behavior.
 */
internal fun shouldHandleSystemBack(
    isAtRoot: Boolean,
    hasTransientUi: Boolean = false,
): Boolean = hasTransientUi || !isAtRoot

/** Platform hook for system Back. Desktop has no activity Back dispatcher. */
@Composable
internal expect fun PlatformBackHandler(
    enabled: Boolean,
    onBack: () -> Unit,
)

/**
 * Give a visible Compose-owned overlay priority over the route-level handler.
 * AndroidX dispatches Back to the last enabled composed handler, so a handler
 * installed by the overlay dismisses that surface before app navigation runs.
 */
@Composable
internal fun TransientBackHandler(onBack: () -> Unit) {
    PlatformBackHandler(
        enabled = shouldHandleSystemBack(isAtRoot = true, hasTransientUi = true),
        onBack = onBack,
    )
}
