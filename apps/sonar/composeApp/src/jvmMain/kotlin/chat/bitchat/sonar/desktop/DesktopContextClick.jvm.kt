package chat.bitchat.sonar.desktop

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.PointerMatcher
import androidx.compose.foundation.onClick
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerButton

/** Desktop right-click opens the row-actions sheet (mute/delete). */
@OptIn(ExperimentalFoundationApi::class)
actual fun Modifier.desktopContextClick(onRowActions: (() -> Unit)?): Modifier =
    if (onRowActions != null) {
        onClick(matcher = PointerMatcher.mouse(PointerButton.Secondary), onClick = onRowActions)
    } else {
        this
    }
