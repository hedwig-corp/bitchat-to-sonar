package chat.bitchat.sonar

import android.content.Intent
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder

actual fun shareInviteText(text: String) {
    val ctx = AppContextHolder.ctx
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    // Started from a non-Activity context, so a new task is required.
    val chooser = Intent.createChooser(send, "Share invite link")
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { ctx.startActivity(chooser) }
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
