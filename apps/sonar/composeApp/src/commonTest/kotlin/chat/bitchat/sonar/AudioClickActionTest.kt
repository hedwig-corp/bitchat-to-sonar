package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The voice-note button's decision.
 *
 * This exists because deleting the "is it playable" check from the bubble left the
 * entire suite green while restoring the silent-playback bug on every Linux desktop
 * without a decoder installed. The player-level tests could not see it: the gate is
 * at the call site, and `docs/REGRESSIONS.md` rule 2 asks for the call site.
 */
class AudioClickActionTest {

    @Test
    fun anUnplayableNoteDoesNothingRatherThanPretendingToPlay() {
        assertEquals(
            AudioAction.Nothing,
            audioClickAction(
                MediaTransferPhase.Available,
                unavailable = "no audio player found; install ffmpeg or vlc",
                hasBytes = true,
                playing = false,
            ),
            "with no decoder installed the button must not start a playback that cannot happen",
        )
    }

    @Test
    fun anUnplayableNoteCannotGetStuckShowingPause() {
        assertEquals(
            AudioAction.Nothing,
            audioClickAction(MediaTransferPhase.Available, "no player", hasBytes = true, playing = true),
        )
    }

    @Test
    fun aPlayableNoteStillPlaysAndStops() {
        assertEquals(
            AudioAction.Play,
            audioClickAction(MediaTransferPhase.Available, null, hasBytes = true, playing = false),
        )
        assertEquals(
            AudioAction.Stop,
            audioClickAction(MediaTransferPhase.Available, null, hasBytes = true, playing = true),
        )
    }

    @Test
    fun aNoteWhoseBytesAreNotLoadedYetDoesNothing() {
        assertEquals(
            AudioAction.Nothing,
            audioClickAction(MediaTransferPhase.Available, null, hasBytes = false, playing = false),
        )
    }

    @Test
    fun transferPhasesAreUnaffectedByPlayability() {
        for (reason in listOf(null, "no player")) {
            assertEquals(
                AudioAction.Download,
                audioClickAction(MediaTransferPhase.NotDownloaded, reason, hasBytes = false, playing = false),
            )
            assertEquals(
                AudioAction.Download,
                audioClickAction(MediaTransferPhase.Failed, reason, hasBytes = false, playing = false),
            )
            assertEquals(
                AudioAction.CancelDownload,
                audioClickAction(MediaTransferPhase.Downloading, reason, hasBytes = false, playing = false),
            )
        }
    }
}
