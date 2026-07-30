package chat.bitchat.sonar

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
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
 * The composer's own text, owned so a send can blank it *now* instead of waiting
 * for the caller's clear to compose.
 *
 * [pushed] is the last text handed to the caller. The caller owns the draft too —
 * it clears it after a send, completes a slash hint, appends an emoji — and those
 * changes arrive as a `value` that differs from [pushed]. Anything equal to
 * [pushed] is the caller's copy still catching up and must not be pulled back
 * over what the user has typed since.
 *
 * [pushed] is deliberately **not** snapshot state: nothing reads it during
 * composition, and making it observable would invalidate the composer on every
 * keystroke for a value only the sync path cares about.
 *
 * All of this decides what the field *shows*, never what a send *commits* — that
 * is `currentDraft`, read straight from the caller's store. A wrong guess here
 * shows stale text for one frame, which the user can see and fix; the same guess
 * on the send path was what R-022 is about.
 */
@Stable
internal class MessageComposerState(initial: String = "") {
    internal var field by mutableStateOf(TextFieldValue(initial, TextRange(initial.length)))
        private set
    internal var pushed: String = initial
        private set

    /** An edit from the field. Returns true when the draft text actually moved. */
    internal fun onEdited(edited: TextFieldValue): Boolean {
        field = edited
        // Selection-only moves are not draft changes; do not wake the store.
        if (edited.text == pushed) return false
        pushed = edited.text
        return true
    }

    /** Take the caller's text. Caret to the end — that is where typing resumes. */
    internal fun adopt(value: String) {
        field = TextFieldValue(value, TextRange(value.length))
        pushed = value
    }

    /**
     * A send committed the draft: blank the field now, so anything still queued
     * in this input batch edits an empty field rather than the message that just
     * went out.
     *
     * **Every** send path must call this, not just the composer's own Enter
     * handler — the send buttons clear the stored draft themselves, and on
     * Android the button is the only send path there is (Return inserts a
     * newline). If the caller keeps the draft instead of clearing it, the next
     * composition adopts it straight back.
     */
    fun committed() {
        adopt("")
    }
}

@Composable
internal fun rememberMessageComposerState(initial: String): MessageComposerState =
    remember { MessageComposerState(initial) }

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
    state: MessageComposerState,
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    cursorBrush: Brush,
    currentDraft: () -> String,
    modifier: Modifier = Modifier,
    onSend: ((String) -> Unit)? = null,
) {
    val enterSends = messageComposerEnterSends && onSend != null

    // Adopt draft changes the caller made itself.
    SideEffect {
        if (value != state.pushed) state.adopt(value)
    }

    BasicTextField(
        value = state.field,
        onValueChange = { edited ->
            if (state.onEdited(edited)) onValueChange(edited.text)
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
                        val outgoing = currentDraft()
                        state.committed()
                        onSend?.invoke(outgoing)
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
