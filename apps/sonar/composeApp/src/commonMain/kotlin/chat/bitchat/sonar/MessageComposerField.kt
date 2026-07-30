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

/**
 * The shared message composer text field.
 *
 * [currentDraft] is read when Enter is pressed and is what gets sent — never the
 * [value] this composition was passed. Key events are dispatched as they arrive
 * while recomposition waits for the next frame, so [value] is only a snapshot of
 * the last completed frame: a laggy frame queues a burst of key events plus the
 * Enter behind them, and sending [value] drops everything typed since. It must
 * return the caller's stored draft, which every keystroke updates synchronously
 * through [onValueChange].
 *
 * Reading the store rather than tracking the text here also means anything else
 * that owns the draft is seen immediately: a send button that just committed and
 * cleared it, a slash-hint completion, an emoji appended by the tray. A second
 * Enter from the same input batch reads the cleared draft and sends nothing,
 * instead of sending the message again.
 */
@Composable
internal fun MessageComposerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    cursorBrush: Brush,
    currentDraft: () -> String,
    modifier: Modifier = Modifier,
    onSend: ((String) -> Unit)? = null,
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
                    val isEnter = event.key == Key.Enter || event.key == Key.NumPadEnter
                    if (
                        event.type == KeyEventType.KeyDown &&
                        isEnter &&
                        !event.isShiftPressed
                    ) {
                        onSend?.invoke(currentDraft())
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
