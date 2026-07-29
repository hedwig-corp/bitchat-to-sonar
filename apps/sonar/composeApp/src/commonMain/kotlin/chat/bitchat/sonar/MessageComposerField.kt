package chat.bitchat.sonar

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
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
 * The newest draft text the field itself produced.
 *
 * Key events are dispatched as they arrive, but the hoisted `value` only catches
 * up on the next recomposition. A hardware Enter that lands in the same input
 * batch as the keystrokes before it — routine when a laggy frame queues a burst
 * of AWT key events — would otherwise send whatever the last completed
 * composition held and silently drop the tail of the message.
 *
 * Keystrokes are recorded here synchronously. A hoisted value that differs from
 * what we last reported means the caller changed the draft itself (cleared it
 * after a send, completed a slash hint) and wins.
 */
private class ComposerLiveText(initial: String) {
    var text: String = initial
        private set
    private var reported: String = initial

    fun onHoistedValue(value: String) {
        if (value != reported) {
            text = value
            reported = value
        }
    }

    fun onFieldValue(value: String) {
        text = value
        reported = value
    }
}

/**
 * The shared message composer text field.
 *
 * [onSend] receives the draft as the field currently holds it, which is not
 * necessarily the [value] this composition was passed — see [ComposerLiveText].
 */
@Composable
internal fun MessageComposerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    cursorBrush: Brush,
    modifier: Modifier = Modifier,
    onSend: ((String) -> Unit)? = null,
) {
    val enterSends = messageComposerEnterSends && onSend != null
    val live = remember { ComposerLiveText(value) }
    SideEffect { live.onHoistedValue(value) }
    BasicTextField(
        value = value,
        onValueChange = { typed ->
            live.onFieldValue(typed)
            onValueChange(typed)
        },
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
                        onSend?.invoke(live.text)
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
