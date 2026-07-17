package chat.bitchat.sonar

import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction

/**
 * The shared text-input contract for every Compose message composer.
 *
 * Sending is deliberately owned by the adjacent send button. Asking the IME
 * for no action keeps its Return key available for inserting a newline instead
 * of letting each keyboard reinterpret the default action as Send or Done.
 */
internal val messageComposerKeyboardOptions = KeyboardOptions(imeAction = ImeAction.None)

@Composable
internal fun MessageComposerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    cursorBrush: Brush,
    modifier: Modifier = Modifier,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        textStyle = textStyle,
        cursorBrush = cursorBrush,
        singleLine = false,
        maxLines = 5,
        keyboardOptions = messageComposerKeyboardOptions,
        modifier = modifier,
    )
}
