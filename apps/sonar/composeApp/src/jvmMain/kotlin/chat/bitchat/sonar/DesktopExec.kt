package chat.bitchat.sonar

import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Resolves helper binaries on `PATH` without executing them.
 *
 * Extracted from [DesktopSecrets], which needed the same answer for `secret-tool`
 * and `security`, and got it wrong three times before this shape settled. All three
 * are easy to re-make from scratch in a new caller, which is why they live here once:
 *
 * - **Do not probe by running it.** Exit status is not an availability signal
 *   (`secret-tool --version` exits 2 while working perfectly), and the first probe
 *   can land on the AWT event thread, where a helper that hangs (wedged D-Bus, a
 *   `PATH` entry on a stalled network mount) freezes the UI with no recovery.
 * - **Catch per entry, not per scan.** One malformed `PATH` entry raises
 *   `InvalidPathException`; catching around the whole loop would abort the scan and
 *   report the binary missing on a machine where it is installed.
 * - **A directory is executable.** `Files.isExecutable` is `access(2)` with `X_OK`,
 *   which for a directory asks whether it is *searchable*, and it normally is. A
 *   directory named `ffplay` on `PATH` therefore resolved as the audio player: the
 *   app reported itself able to play, `ProcessBuilder.start()` then failed with
 *   `EACCES`, and the note completed in silence. The `isRegularFile` half is what
 *   makes the question "can I run this" instead of "can I cd into this".
 */
internal object DesktopExec {
    /**
     * Absolute path of [binary] on [path], or null when it is not there.
     *
     * [path] is a parameter rather than a process-wide test hook on purpose. This
     * resolver also answers for `secret-tool` and `security`, and those answers are
     * cached for the life of the JVM, so a global override left set by an unrelated
     * test could cache "no keystore" and reach the account-key durability surface.
     */
    fun which(binary: String, path: String? = System.getenv("PATH")): String? {
        // POSIX only: the absolute-entry rule below rejects `C:\\Windows\\System32`
        // and nothing here appends `.exe`. Every current caller is macOS/Linux
        // (`build.gradle.kts` ships only `linux { }` and `macOS { }`), so this is a
        // documented limit rather than a Windows bug waiting to be found.
        if (path == null) return null
        for (dir in path.split(File.pathSeparatorChar)) {
            // Empty AND relative entries are skipped. A relative entry ("." or
            // "bin", and an empty one historically means ".") resolves against the
            // process working directory, so it would let a binary from a directory
            // unrelated to the system PATH answer for a system helper.
            if (dir.isEmpty() || !dir.startsWith('/')) continue
            val hit = runCatching {
                val p = Paths.get(dir).resolve(binary)
                if (Files.isRegularFile(p) && Files.isExecutable(p)) p.toString() else null
            }.getOrNull()
            if (hit != null) return hit
        }
        return null
    }
}
