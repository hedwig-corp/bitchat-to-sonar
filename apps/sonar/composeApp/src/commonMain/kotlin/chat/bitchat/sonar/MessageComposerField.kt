package chat.bitchat.sonar

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction

/**
 * True on desktop JVM where the hardware Return key should send the draft.
 * Mobile soft keyboards keep Return as newline (send button owns sending).
 */
internal expect val messageComposerEnterSends: Boolean

/**
 * The shared text-input contract for every Compose message composer.
 *
 * On mobile, [ImeAction.None] keeps Return available for newlines and sending
 * stays on the adjacent send button. On desktop, bare Enter calls [onSend]
 * when provided; Shift+Enter newline shortcuts are deferred to #334.
 */
internal val messageComposerKeyboardOptions = KeyboardOptions(imeAction = ImeAction.None)

@Composable
internal fun MessageComposerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    cursorBrush: Brush,
    modifier: Modifier = Modifier,
    onSend: (() -> Unit)? = null,
) {
    val enterSends = messageComposerEnterSends && onSend != null
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        textStyle = textStyle,
        cursorBrush = cursorBrush,
        singleLine = false,
        maxLines = 5,
        keyboardOptions = messageComposerKeyboardOptions,
        modifier = modifier.then(
            if (enterSends) {
                Modifier.onPreviewKeyEvent { event ->
                    if (
                        event.type == KeyEventType.KeyDown &&
                        event.key == Key.Enter &&
                        !event.isShiftPressed
                    ) {
                        onSend?.invoke()
                        true
                    } else {
                        false
                    }
                }
            } else {
                Modifier
            },
        ),
    )
}
