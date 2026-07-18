package chat.bitchat.sonar

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceMessagePlaybackControllerTest {
    private fun item(
        id: String = "m1",
        logical: String = "chat-a",
        source: String = "group-a",
        file: String = "/tmp/a.m4a",
        attachment: String = "att-$id",
    ) = VoicePlaybackItem(
        logicalConversationId = logical,
        sourceConversationId = source,
        messageId = id,
        attachmentId = attachment,
        localFile = file,
        durationHintMs = 5_000L,
    )

    @Test
    fun playPauseResumePreservesPlayhead() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        val a = item()
        controller.dispatchSync(VoicePlaybackCommand.Play(a))
        runCurrent()
        assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
        engine.positionMs = 1_200L
        controller.dispatchSync(VoicePlaybackCommand.Pause)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Paused, controller.state.phase)
        assertEquals(1_200L, controller.state.positionMs)
        controller.dispatchSync(VoicePlaybackCommand.Resume)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
        assertEquals(1_200L, controller.state.positionMs)
        assertEquals(1_200L, engine.positionMs)
        } finally {
            controller.close()
        }
    }

    @Test
    fun routeLostDoesNotAutoResumeOnFocusGain() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
            controller.dispatchSync(VoicePlaybackCommand.Play(item()))
            runCurrent()
            controller.onSystemPaused(controller.state.generation)
            runCurrent()
            assertEquals(VoicePlaybackPhase.Paused, controller.state.phase)
            assertEquals(VoicePlaybackInterruption.RouteLost, controller.state.interruptionReason)
            controller.onTransientInterruptionEnded(controller.state.generation)
            runCurrent()
            assertEquals(VoicePlaybackPhase.Paused, controller.state.phase)
            assertFalse(engine.playing)
        } finally {
            controller.close()
        }
    }

    @Test
    fun userPauseDoesNotAutoResumeAfterTransientInterruption() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(item()))
        runCurrent()
        controller.dispatchSync(VoicePlaybackCommand.Pause)
        runCurrent()
        val gen = controller.state.generation
        controller.onTransientInterruptionBegan(gen)
        runCurrent()
        controller.onTransientInterruptionEnded(gen)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Paused, controller.state.phase)
        assertFalse(engine.playing)
        } finally {
            controller.close()
        }
    }

    @Test
    fun transientInterruptionResumesOnlyWhenWasPlaying() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(item()))
        runCurrent()
        val gen = controller.state.generation
        controller.onTransientInterruptionBegan(gen)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Paused, controller.state.phase)
        assertEquals(VoicePlaybackInterruption.TransientSystem, controller.state.interruptionReason)
        controller.onTransientInterruptionEnded(gen)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
        assertTrue(engine.playing)
        } finally {
            controller.close()
        }
    }

    @Test
    fun staleTransientInterruptionDoesNotPauseNewerItem() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
            controller.dispatchSync(VoicePlaybackCommand.Play(item(id = "a")))
            runCurrent()
            val staleGen = controller.state.generation
            controller.dispatchSync(VoicePlaybackCommand.Play(item(id = "b")))
            runCurrent()
            assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
            controller.onTransientInterruptionBegan(staleGen)
            runCurrent()
            assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
            assertEquals(null, controller.state.interruptionReason)
            assertTrue(engine.playing)
        } finally {
            controller.close()
        }
    }

    @Test
    fun staleEngineCallbackDoesNotMutateNewerItem() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        val first = item("m1", file = "/tmp/1.m4a")
        val second = item("m2", file = "/tmp/2.m4a", attachment = "att-m2")
        controller.dispatchSync(VoicePlaybackCommand.Play(first))
        runCurrent()
        val staleGen = controller.state.generation
        controller.dispatchSync(VoicePlaybackCommand.Play(second))
        runCurrent()
        controller.onEngineEnded(staleGen)
        runCurrent()
        assertEquals(second.key, controller.state.item?.key)
        assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
        } finally {
            controller.close()
        }
    }

    @Test
    fun completionAutoplaysNextInQueueThenEnds() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val a = item("m1", attachment = "a")
        val b = item("m2", attachment = "b", file = "/tmp/b.m4a")
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = ListQueue(listOf(a, b)),
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(a))
        runCurrent()
        controller.onEngineEnded(controller.state.generation)
        runCurrent()
        assertEquals(b.key, controller.state.item?.key)
        assertEquals(VoicePlaybackPhase.Playing, controller.state.phase)
        controller.onEngineEnded(controller.state.generation)
        runCurrent()
        assertTrue(
            controller.state.phase == VoicePlaybackPhase.Ended ||
                controller.state.phase == VoicePlaybackPhase.Idle
        )
        assertNull(controller.state.item?.takeIf { controller.state.phase == VoicePlaybackPhase.Idle })
        } finally {
            controller.close()
        }
    }

    @Test
    fun cycleRatePersistsPerLogicalConversation() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val rates = InMemoryVoicePlaybackRateStore()
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = rates,
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(item(logical = "fold-1")))
        runCurrent()
        controller.dispatchSync(VoicePlaybackCommand.CycleRate)
        runCurrent()
        assertEquals(1.5f, controller.state.rate)
        assertEquals(1.5f, rates.rateFor("fold-1"))
        assertEquals(1.0f, rates.rateFor("fold-2"))
        assertEquals(1.5f, engine.playbackRate)
        } finally {
            controller.close()
        }
    }

    @Test
    fun callPreemptionDoesNotAutoResume() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(item()))
        runCurrent()
        controller.dispatchSync(VoicePlaybackCommand.Stop(VoicePlaybackStopReason.Call))
        runCurrent()
        assertEquals(VoicePlaybackPhase.Idle, controller.state.phase)
        controller.dispatchSync(VoicePlaybackCommand.Resume)
        runCurrent()
        assertEquals(VoicePlaybackPhase.Idle, controller.state.phase)
        } finally {
            controller.close()
        }
    }

    @Test
    fun marksListenedOnFirstPlayOnly() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val listened = InMemoryVoicePlaybackListenedStore()
        var starts = 0
        val engine = FakeVoicePlaybackEngine()
        val a = item()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = listened,
            listener = VoicePlaybackListener { starts += 1 },
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(a))
        runCurrent()
        assertTrue(listened.isListened(a.key))
        assertEquals(1, starts)
        controller.dispatchSync(VoicePlaybackCommand.Pause)
        controller.dispatchSync(VoicePlaybackCommand.Resume)
        runCurrent()
        assertEquals(1, starts)
        } finally {
            controller.close()
        }
    }

    @Test
    fun seekWhilePausedUpdatesCachedPlayhead() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val engine = FakeVoicePlaybackEngine()
        val controller = VoiceMessagePlaybackController(
            engine = engine,
            rateStore = InMemoryVoicePlaybackRateStore(),
            queue = EmptyQueue,
            listenedStore = InMemoryVoicePlaybackListenedStore(),
            dispatcher = dispatcher,
            progressIntervalMs = 1_000L,
        )
        try {
        controller.dispatchSync(VoicePlaybackCommand.Play(item()))
        runCurrent()
        controller.dispatchSync(VoicePlaybackCommand.Pause)
        controller.dispatchSync(VoicePlaybackCommand.Seek(2_500L))
        runCurrent()
        assertEquals(2_500L, controller.state.positionMs)
        assertEquals(2_500L, engine.lastSeekMs)
        } finally {
            controller.close()
        }
    }

    @Test
    fun voiceAttachmentIdStableAcrossEmptyUrl() {
        val a = voiceAttachmentId("m1", 0, "note.m4a", "")
        val b = voiceAttachmentId("m1", 0, "note.m4a", "")
        val c = voiceAttachmentId("m1", 1, "note.m4a", "")
        assertEquals(a, b)
        assertTrue(a != c)
    }

    @Test
    fun voiceAttachmentIdStableAcrossUrlPromotion() {
        val pending = voiceAttachmentId("m1", 0, "note.m4a", "pending-media-abc")
        val published = voiceAttachmentId("m1", 0, "note.m4a", "https://cdn.example/note.m4a")
        assertEquals(pending, published)
    }

    private object EmptyQueue : VoicePlaybackQueue {
        override fun next(item: VoicePlaybackItem): VoicePlaybackItem? = null
        override fun previous(item: VoicePlaybackItem): VoicePlaybackItem? = null
    }

    private class ListQueue(private val items: List<VoicePlaybackItem>) : VoicePlaybackQueue {
        override fun next(item: VoicePlaybackItem): VoicePlaybackItem? {
            val idx = items.indexOfFirst { it.key == item.key }
            return items.getOrNull(idx + 1)
        }

        override fun previous(item: VoicePlaybackItem): VoicePlaybackItem? {
            val idx = items.indexOfFirst { it.key == item.key }
            return items.getOrNull(idx - 1)
        }
    }

    private class FakeVoicePlaybackEngine : VoicePlaybackEngine {
        var playing = false
        var positionMs = 0L
        var duration = 5_000L
        var playbackRate = 1.0f
        var lastSeekMs = 0L
        var prepared: VoicePlaybackItem? = null
        var released = false

        override suspend fun prepare(item: VoicePlaybackItem, generation: Long) {
            prepared = item
            released = false
            duration = item.durationHintMs ?: 5_000L
        }

        override fun play() {
            playing = true
            released = false
        }

        override fun pause() {
            playing = false
        }

        override fun seekTo(positionMs: Long) {
            lastSeekMs = positionMs
            this.positionMs = positionMs
        }

        override fun setRate(rate: Float) {
            this.playbackRate = rate
        }

        override fun release() {
            playing = false
            released = true
        }

        override fun currentPositionMs(): Long = positionMs
        override fun durationMs(): Long = duration
    }
}
