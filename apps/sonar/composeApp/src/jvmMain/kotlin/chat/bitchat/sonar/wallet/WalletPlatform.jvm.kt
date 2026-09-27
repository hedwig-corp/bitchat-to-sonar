package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.DesktopEnv
import java.io.File

actual fun platformWalletFiles(): WalletFileOps = JavaFileWalletOps

/** java.io.File implementation, identical on both JVM targets. */
internal object JavaFileWalletOps : WalletFileOps {
    override fun exists(path: String): Boolean = File(path).exists()

    override fun hasEntries(path: String): Boolean =
        File(path).let { it.isDirectory && !it.list().isNullOrEmpty() }

    override fun deleteTree(path: String): Boolean {
        val f = File(path)
        if (!f.exists()) return true
        f.deleteRecursively()
        return !f.exists()
    }

    override fun rename(from: String, to: String): Boolean {
        val src = File(from)
        val dst = File(to)
        dst.parentFile?.mkdirs()
        return src.renameTo(dst)
    }

    override fun readText(path: String): String? =
        runCatching { File(path).takeIf { it.isFile }?.readText() }.getOrNull()

    override fun writeText(path: String, text: String): Boolean = runCatching {
        val f = File(path)
        f.parentFile?.mkdirs()
        f.writeText(text)
        true
    }.getOrDefault(false)
}

/** The `DesktopEnv` prefs these keys have always lived in. */
actual object WalletDisplayPrefs {
    actual fun showFiat(): Boolean = DesktopEnv.getBoolean("wallet.showFiat", false)
    actual fun setShowFiat(value: Boolean) { DesktopEnv.putBoolean("wallet.showFiat", value) }
    actual fun currencyCode(): String? = DesktopEnv.getString("wallet.currency", "USD")
    actual fun setCurrencyCode(value: String) { DesktopEnv.putString("wallet.currency", value) }
}
