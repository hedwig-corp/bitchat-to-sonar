package chat.bitchat.sonar

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Observer detach must never stop the app-scoped session or reset the playhead
 * (the scroll-offscreen / recompose bug from issue #320).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceMessagePlaybackUiTest {
    @Test
    fun detachingObserverDoesNotStopOrResetPlayhead() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = RecordingEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = object : VoicePlaybackQueue {
                override fun next(item: VoicePlaybackItem): VoicePlaybackItem? = null
                override fun previous(item: VoicePlaybackItem): VoicePlaybackItem? = null
            },
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        val item = VoicePlaybackItem(
            logicalConversationId = "chat",
            sourceConversationId = "chat",
            messageId = "m1",
            attachmentId = "a1",
            localFile = "/tmp/note.m4a",
            durationHintMs = 4_000L,
        )
        controller.dispatchSync(VoicePlaybackCommand.Play(item))
        runCurrent()
        engine.positionMs = 900L
        controller.dispatchSync(VoicePlaybackCommand.Pause)
        runCurrent()

        // Simulate bubble leave + re-enter: observers detach; no Stop command.
        var observed: VoicePlaybackState? = controller.state
        observed = null
        observed = controller.state

        assertEquals(VoicePlaybackPhase.Paused, observed!!.phase)
        assertEquals(900L, observed.positionMs)
        assertEquals(0, engine.releaseCount)
        } finally {
            controller.close()
        }
    }

    private class RecordingEngine : VoicePlaybackEngine {
        var positionMs = 0L
        var duration = 4_000L
        var releaseCount = 0
        override suspend fun prepare(item: VoicePlaybackItem, generation: Long) {
            duration = item.durationHintMs ?: 4_000L
        }
        override fun play() {}
        override fun pause() {}
        override fun seekTo(positionMs: Long) { this.positionMs = positionMs }
        override fun setRate(rate: Float) {}
        override fun release() { releaseCount += 1 }
        override fun currentPositionMs(): Long = positionMs
        override fun durationMs(): Long = duration
    }
}
