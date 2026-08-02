package chat.bitchat.sonar

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Desktop voice-note playback.
 *
 * The bug: `play()` opened with `if (!os.contains("mac")) { onComplete(); return }`,
 * so on Linux every received note rendered a working play button that completed
 * instantly in silence. Nothing distinguished that from a zero-length recording, so
 * it read as the sender's fault.
 *
 * These drive the real [AudioNotePlayer.play] entry point against stub players on an
 * injected `PATH`, rather than a helper or whatever happens to be installed on the
 * runner. Stubs, not real ffplay, because CI has no audio sink: a real player exits
 * immediately with an error there, which is precisely the "completes instantly"
 * symptom under test and would make the regression invisible. What the stub cannot
 * prove is that ffplay's own flags decode AAC audibly; that is verified by hand
 * against a real clip and recorded in the PR.
 */
class DesktopVoiceNotePlaybackTest {

    private val linux = System.getProperty("os.name").lowercase().contains("linux")

    @AfterTest
    fun restore() {
        AudioNotePlayer.searchPath = null
    }

    /** A fake player that logs its argv, lingers [holdMs], then exits cleanly. */
    private fun stubPlayer(dir: File, name: String, log: File, holdMs: Int = 400): File {
        val f = File(dir, name)
        f.writeText(
            """
            #!/bin/sh
            printf '%s\n' "$@" >> "${log.absolutePath}"
            # Record whether the note file the app passed actually exists at spawn
            # time: a player that starts before the bytes land plays nothing.
            for a in "$@"; do
              case "${'$'}a" in *.m4a) [ -s "${'$'}a" ] && echo "NOTE_PRESENT" >> "${log.absolutePath}" ;; esac
            done
            sleep ${holdMs / 1000.0}
            exit 0
            """.trimIndent()
        )
        f.setExecutable(true)
        return f
    }

    @Test
    fun playSpawnsTheResolvedPlayerWithTheNoteAndWaitsForItToFinish() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        stubPlayer(dir, "ffplay", log)
        AudioNotePlayer.searchPath = dir.absolutePath

        assertNull(
            AudioNotePlayer.unavailableReason(),
            "a player is on PATH, so notes must not be marked unplayable",
        )

        val done = CountDownLatch(1)
        val started = System.nanoTime()
        AudioNotePlayer.play(fakeM4a(2048)) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        val argv = log.readText()
        assertTrue(argv.contains("-autoexit"), "ffplay must get its exit-at-EOF flag: $argv")
        assertTrue(argv.contains("-nodisp"), "ffplay must not open a video window: $argv")
        assertTrue(argv.contains(".m4a"), "the note file must be passed to the player: $argv")
        assertTrue(argv.contains("NOTE_PRESENT"), "the note bytes must be written before spawn: $argv")

        // The regression in one assertion: completion is driven by the player
        // exiting, not fired the instant the button is pressed. Pre-fix this was
        // ~0ms on Linux because play() returned before spawning anything.
        assertTrue(
            elapsedMs >= 300,
            "completion must wait for the player (stub holds 400ms), took ${elapsedMs}ms",
        )
    }

    @Test
    fun playbackLeavesNoDecryptedAudioBehind() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        stubPlayer(dir, "ffplay", log, holdMs = 50)
        AudioNotePlayer.searchPath = dir.absolutePath

        // Snapshot first: a temp file stranded by an earlier run of the real app
        // would otherwise fail this for something this playback did not do.
        val before = tempNotes()
        val done = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(1024)) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")

        // Without this the test passes vacuously: if nothing is ever spawned, no
        // temp file is created and "nothing left behind" is trivially true.
        assertTrue(log.readText().contains("NOTE_PRESENT"), "no player was spawned at all")
        // The note is E2EE on the wire; the temp copy handed to the player is not.
        assertEquals(
            emptyList(), (tempNotes() - before).toList(),
            "decrypted voice-note temp files must not survive playback",
        )
    }

    @Test
    fun theDecryptedNoteIsNeverReadableByOtherLocalUsers() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val perms = File(dir, "perms.log")
        // This stub reports the mode of the note file it was handed, which is the
        // only moment the decrypted plaintext exists on disk.
        val f = File(dir, "ffplay")
        f.writeText(
            """
            #!/bin/sh
            for a in "$@"; do
              case "${'$'}a" in *.m4a) stat -c '%a' "${'$'}a" >> "${perms.absolutePath}" ;; esac
            done
            exit 0
            """.trimIndent()
        )
        f.setExecutable(true)
        AudioNotePlayer.searchPath = dir.absolutePath

        val done = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(4096)) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")

        // File.createTempFile honors the umask and yields rw-rw-r-- under a common
        // 0002, which would leave decrypted E2EE audio in a shared /tmp readable by
        // every local user for the length of the clip.
        assertEquals(
            "600", perms.readText().trim(),
            "the decrypted voice note must be owner-only while it exists on disk",
        )
    }

    @Test
    fun prefersFfplayWhenSeveralPlayersAreInstalled() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        stubPlayer(dir, "cvlc", log, holdMs = 50)
        stubPlayer(dir, "ffplay", log, holdMs = 50)
        AudioNotePlayer.searchPath = dir.absolutePath

        val done = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(512)) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")

        val argv = log.readText()
        assertTrue(argv.contains("-autoexit"), "expected ffplay to win the preference order: $argv")
        assertTrue(
            !argv.contains("--play-and-exit"),
            "only one player may be spawned per note: $argv",
        )
    }

    @Test
    fun notesAreMarkedUnplayableWhenNoPlayerIsInstalled() {
        if (!linux) return
        AudioNotePlayer.searchPath = createTempDir("sonar-empty-").absolutePath

        val reason = AudioNotePlayer.unavailableReason()
        assertNotNull(reason, "with nothing on PATH the UI must be told notes cannot play")
        // The reason is shown verbatim in the bubble, so it has to say what to do
        // about it, not just that something is wrong.
        assertTrue(
            reason.contains("ffmpeg") || reason.contains("mpv") || reason.contains("vlc"),
            "the reason must name a package that fixes it: $reason",
        )
    }

    @Test
    fun aPlaylistDisguisedAsAVoiceNoteIsNeverHandedToAPlayer() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        stubPlayer(dir, "ffplay", log, holdMs = 50)
        AudioNotePlayer.searchPath = dir.absolutePath

        // VLC content-sniffs and ignores the .m4a suffix, so these bytes made cvlc
        // fetch the URL and exit 0 while the app reported a normal play: an IP
        // disclosure and SSRF probe driven by whoever sent the message.
        val playlist = "#EXTM3U\nhttp://127.0.0.1:1/beacon\n".toByteArray()
        val done = CountDownLatch(1)
        AudioNotePlayer.play(playlist) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")

        assertEquals(
            "", log.let { if (it.exists()) it.readText() else "" },
            "a non-MP4 payload must never reach an external media stack",
        )
    }

    @Test
    fun aDirectoryNamedLikeAPlayerIsNotMistakenForOne() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        // Files.isExecutable is access(2) X_OK, which is true for any searchable
        // directory. This one used to win resolution, so the app claimed it could
        // play, the spawn failed with EACCES, and the note completed in silence.
        File(dir, "ffplay").mkdirs()
        AudioNotePlayer.searchPath = dir.absolutePath

        assertNotNull(
            AudioNotePlayer.unavailableReason(),
            "a directory is not a player; the UI must be told notes cannot play",
        )
    }

    @Test
    fun switchingNotesTearsDownTheFirstPlayerAndItsPlaintext() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        // Long enough that the first player is still running when the second starts.
        stubPlayer(dir, "ffplay", log, holdMs = 5000)
        AudioNotePlayer.searchPath = dir.absolutePath

        val before = tempNotes()
        val firstDone = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(2048)) { firstDone.countDown() }
        Thread.sleep(300)
        val secondDone = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(2048)) { secondDone.countDown() }

        // Removing the teardown() call in play() leaves both players running and
        // the first bubble stuck on Pause forever, with its decrypted note on disk.
        assertTrue(
            firstDone.await(15, TimeUnit.SECONDS),
            "starting a second note must complete the first, not orphan it",
        )
        AudioNotePlayer.stop()
        assertTrue(secondDone.await(15, TimeUnit.SECONDS), "stop() must complete the second")
        assertEquals(
            emptyList(), (tempNotes() - before).toList(),
            "neither note may leave decrypted audio behind",
        )
    }

    @Test
    fun aPlayerThatIgnoresSigtermDoesNotWedgePlaybackForever() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val f = File(dir, "ffplay")
        // Ignores SIGTERM. teardown() used to waitFor() this with no timeout on the
        // single control thread, so every later play()/stop() queued behind it for
        // the rest of the session.
        f.writeText(
            """
            #!/bin/sh
            trap "" TERM
            sleep 3600
            """.trimIndent()
        )
        f.setExecutable(true)
        AudioNotePlayer.searchPath = dir.absolutePath

        val stubborn = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(1024)) { stubborn.countDown() }
        Thread.sleep(300)
        AudioNotePlayer.stop()
        assertTrue(
            stubborn.await(20, TimeUnit.SECONDS),
            "stop() must escalate to SIGKILL rather than wait forever",
        )

        // And the player must still work afterwards.
        stubPlayer(dir, "ffplay", File(dir, "argv2.log"), holdMs = 50)
        val after = CountDownLatch(1)
        AudioNotePlayer.play(fakeM4a(1024)) { after.countDown() }
        assertTrue(after.await(20, TimeUnit.SECONDS), "the control thread is wedged")
    }

    /** Minimal bytes that pass the MP4 container check: `....ftyp`. */
    private fun fakeM4a(size: Int): ByteArray = ByteArray(maxOf(size, 12)).also {
        "ftyp".forEachIndexed { i, c -> it[4 + i] = c.code.toByte() }
    }

    private fun tempNotes(): Set<String> =
        File(System.getProperty("java.io.tmpdir"))
            .listFiles { f -> f.name.startsWith("sonar-vn-") && f.name.endsWith(".m4a") }
            ?.map { it.name }?.toSet().orEmpty()

    @Suppress("DEPRECATION")
    private fun createTempDir(prefix: String): File =
        kotlin.io.createTempDir(prefix).apply { deleteOnExit() }
}
