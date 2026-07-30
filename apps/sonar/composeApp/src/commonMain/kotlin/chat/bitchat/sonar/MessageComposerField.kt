package chat.bitchat.sonar

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue

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
 * Tracks the last text this field handed to the caller.
 *
 * The caller owns the draft too — it clears it after a send, completes a slash
 * hint, appends an emoji — and those changes arrive as a [value] that differs
 * from what we pushed. Anything else is the caller's copy still catching up and
 * must not be pulled back over what the user has typed since.
 *
 * Deliberately **not** snapshot state: nothing reads it during composition, and
 * making it observable would invalidate the composer on every keystroke for a
 * value only the sync path cares about.
 *
 * Note this decides what the field *shows*, never what a send *commits* — that
 * is `currentDraft`, read straight from the caller's store. A wrong guess here
 * shows stale text for one frame, which the user can see and fix; the same guess
 * on the send path was what R-022 is about.
 */
private class ComposerPushedText(var value: String)

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
 *
 * The field owns its [TextFieldValue] so a send can blank it *now* rather than
 * waiting for the caller's clear to compose. Otherwise a keystroke from the same
 * input batch edits a buffer that still holds the sent message — `[h, i, Enter,
 * !]` would leave the composer holding `"hi!"`, the message it just sent glued
 * to the next one.
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
    var field by remember { mutableStateOf(TextFieldValue(value, TextRange(value.length))) }
    val pushed = remember { ComposerPushedText(value) }

    // Adopt draft changes the caller made itself. Caret goes to the end: every
    // such change either empties the draft or rewrites it wholesale (completion,
    // emoji append), and the end is where typing continues from.
    SideEffect {
        if (value != pushed.value) {
            field = TextFieldValue(value, TextRange(value.length))
            pushed.value = value
        }
    }

    BasicTextField(
        value = field,
        onValueChange = { edited ->
            field = edited
            // Selection-only moves are not draft changes; do not wake the store.
            if (edited.text != pushed.value) {
                pushed.value = edited.text
                onValueChange(edited.text)
            }
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
                        // Blank before the callback so anything still queued in
                        // this input batch edits an empty field, not the message
                        // being sent. If the caller keeps the draft rather than
                        // clearing it, the next SideEffect restores it.
                        field = TextFieldValue("")
                        pushed.value = ""
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
