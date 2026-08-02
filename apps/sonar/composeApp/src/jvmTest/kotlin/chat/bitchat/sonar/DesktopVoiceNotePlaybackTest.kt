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
        DesktopExec.pathOverride = null
        AudioNotePlayer.resetPlayerCacheForTest()
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
        DesktopExec.pathOverride = dir.absolutePath
        AudioNotePlayer.resetPlayerCacheForTest()

        assertNull(
            AudioNotePlayer.unavailableReason(),
            "a player is on PATH, so notes must not be marked unplayable",
        )

        val done = CountDownLatch(1)
        val started = System.nanoTime()
        AudioNotePlayer.play(ByteArray(2048) { it.toByte() }) { done.countDown() }
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
        stubPlayer(dir, "ffplay", File(dir, "argv.log"), holdMs = 50)
        DesktopExec.pathOverride = dir.absolutePath
        AudioNotePlayer.resetPlayerCacheForTest()

        // Snapshot first: a temp file stranded by an earlier run of the real app
        // would otherwise fail this for something this playback did not do.
        val before = tempNotes()
        val done = CountDownLatch(1)
        AudioNotePlayer.play(ByteArray(1024)) { done.countDown() }
        assertTrue(done.await(15, TimeUnit.SECONDS), "onComplete never fired")

        // The note is E2EE on the wire; the temp copy handed to the player is not.
        assertEquals(
            emptyList(), (tempNotes() - before).toList(),
            "decrypted voice-note temp files must not survive playback",
        )
    }

    @Test
    fun prefersFfplayWhenSeveralPlayersAreInstalled() {
        if (!linux) return
        val dir = createTempDir("sonar-player-")
        val log = File(dir, "argv.log")
        stubPlayer(dir, "cvlc", log, holdMs = 50)
        stubPlayer(dir, "ffplay", log, holdMs = 50)
        DesktopExec.pathOverride = dir.absolutePath
        AudioNotePlayer.resetPlayerCacheForTest()

        val done = CountDownLatch(1)
        AudioNotePlayer.play(ByteArray(512)) { done.countDown() }
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
        DesktopExec.pathOverride = createTempDir("sonar-empty-").absolutePath
        AudioNotePlayer.resetPlayerCacheForTest()

        val reason = AudioNotePlayer.unavailableReason()
        assertNotNull(reason, "with nothing on PATH the UI must be told notes cannot play")
        // The reason is shown verbatim in the bubble, so it has to say what to do
        // about it, not just that something is wrong.
        assertTrue(
            reason.contains("ffmpeg") || reason.contains("mpv") || reason.contains("vlc"),
            "the reason must name a package that fixes it: $reason",
        )
    }

    private fun tempNotes(): Set<String> =
        File(System.getProperty("java.io.tmpdir"))
            .listFiles { f -> f.name.startsWith("sonar-vn-") && f.name.endsWith(".m4a") }
            ?.map { it.name }?.toSet().orEmpty()

    @Suppress("DEPRECATION")
    private fun createTempDir(prefix: String): File =
        kotlin.io.createTempDir(prefix).apply { deleteOnExit() }
}
