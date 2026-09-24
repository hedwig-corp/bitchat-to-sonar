package chat.bitchat.sonar

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

@Composable
internal actual fun SystemBarAppearance(dark: Boolean) {
    val view = LocalView.current
    // Keyed on the theme so the insets controller is touched only when the
    // theme flips, never on every recomposition of the app root.
    LaunchedEffect(view, dark) {
        val window = view.context.findActivity()?.window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, view)
        // "Light" bars = dark icons, which belong on a light app surface only.
        controller.isAppearanceLightStatusBars = !dark
        controller.isAppearanceLightNavigationBars = !dark
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
