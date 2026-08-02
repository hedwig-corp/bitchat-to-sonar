package chat.bitchat.sonar

import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Resolves helper binaries on `PATH` without executing them.
 *
 * Extracted from [DesktopSecrets], which needed the same answer for `secret-tool`
 * and `security`, and got it wrong twice before this shape settled. Both mistakes
 * are worth keeping in one place rather than re-making in each caller:
 *
 * - **Do not probe by running it.** Exit status is not an availability signal
 *   (`secret-tool --version` exits 2 while working perfectly), and the first probe
 *   can land on the AWT event thread, where a helper that hangs (wedged D-Bus, a
 *   `PATH` entry on a stalled network mount) freezes the UI with no recovery.
 * - **Catch per entry, not per scan.** One malformed `PATH` entry raises
 *   `InvalidPathException`; catching around the whole loop would abort the scan and
 *   report the binary missing on a machine where it is installed.
 */
internal object DesktopExec {
    /**
     * Overrides the `PATH` consulted by [which]. Tests only, and it exists so they
     * can drive the real resolution against a directory of stub binaries instead of
     * asserting against whatever happens to be installed on the runner.
     */
    @Volatile
    internal var pathOverride: String? = null

    fun which(binary: String): String? {
        val path = pathOverride ?: System.getenv("PATH") ?: return null
        for (dir in path.split(File.pathSeparatorChar)) {
            if (dir.isEmpty()) continue
            val hit = runCatching {
                val p = Paths.get(dir).resolve(binary)
                if (Files.isExecutable(p)) p.toString() else null
            }.getOrNull()
            if (hit != null) return hit
        }
        return null
    }

    fun onPath(binary: String): Boolean = which(binary) != null
}
