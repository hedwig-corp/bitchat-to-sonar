package chat.bitchat.sonar

import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder
import java.awt.Toolkit
import java.awt.datatransfer.StringSelection

/** Desktop has no system share sheet — copy the link to the clipboard instead. */
actual fun shareInviteText(text: String) {
    runCatching {
        Toolkit.getDefaultToolkit().systemClipboard
            .setContents(StringSelection(text), null)
    }
}

actual fun qrMatrix(data: String): Array<BooleanArray>? = try {
    val hints = mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")
    val matrix = Encoder.encode(data, ErrorCorrectionLevel.M, hints).matrix
    if (matrix == null) {
        null
    } else {
        Array(matrix.height) { y -> BooleanArray(matrix.width) { x -> matrix.get(x, y).toInt() == 1 } }
    }
} catch (t: Throwable) {
    null
}
