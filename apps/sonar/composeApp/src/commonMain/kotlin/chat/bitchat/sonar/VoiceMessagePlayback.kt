package chat.bitchat.sonar

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.max

/** Stable identity for one voice attachment in a logical conversation. */
data class VoicePlaybackItem(
    val logicalConversationId: String,
    val sourceConversationId: String,
    val messageId: String,
    val attachmentId: String,
    val localFile: String,
    val durationHintMs: Long? = null,
) {
    val key: String
        get() = "$logicalConversationId|$sourceConversationId|$messageId|$attachmentId"
}

enum class VoicePlaybackPhase {
    Idle,
    Loading,
    Playing,
    Paused,
    Ended,
    Failed,
}

enum class VoicePlaybackInterruption {
    TransientSystem,
    Call,
    Recording,
    RouteLost,
    Deleted,
    Wipe,
    UserStop,
    Error,
}

enum class VoicePlaybackStopReason {
    User,
    Completed,
    Call,
    Recording,
    Deleted,
    Wipe,
    Error,
    Superseded,
    RouteLost,
}

data class VoicePlaybackState(
    val item: VoicePlaybackItem? = null,
    val phase: VoicePlaybackPhase = VoicePlaybackPhase.Idle,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val rate: Float = 1.0f,
    val interruptionReason: VoicePlaybackInterruption? = null,
    val generation: Long = 0L,
    val listenedKeys: Set<String> = emptySet(),
) {
    val isActive: Boolean
        get() = phase == VoicePlaybackPhase.Loading ||
            phase == VoicePlaybackPhase.Playing ||
            phase == VoicePlaybackPhase.Paused

    val progress: Float
        get() = if (durationMs > 0L) (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f) else 0f
}

sealed interface VoicePlaybackCommand {
    data class Play(val item: VoicePlaybackItem) : VoicePlaybackCommand
    /** Play [item] then seek — one ordered reducer step so Seek cannot race ahead of Play. */
    data class PlayAt(val item: VoicePlaybackItem, val positionMs: Long) : VoicePlaybackCommand
    data object Pause : VoicePlaybackCommand
    data object Resume : VoicePlaybackCommand
    data class Seek(val positionMs: Long) : VoicePlaybackCommand
    data object CycleRate : VoicePlaybackCommand
    data object Next : VoicePlaybackCommand
    data object Previous : VoicePlaybackCommand
    data class Stop(val reason: VoicePlaybackStopReason) : VoicePlaybackCommand
}

interface VoicePlaybackEngine {
    suspend fun prepare(item: VoicePlaybackItem, generation: Long)
    fun play()
    fun pause()
    fun seekTo(positionMs: Long)
    fun setRate(rate: Float)
    fun release()
    fun currentPositionMs(): Long
    fun durationMs(): Long
}

interface VoicePlaybackClock {
    fun nowMs(): Long
}

interface VoicePlaybackRateStore {
    fun rateFor(logicalConversationId: String): Float
    fun setRate(logicalConversationId: String, rate: Float)
}

interface VoicePlaybackQueue {
    fun next(item: VoicePlaybackItem): VoicePlaybackItem?
    fun previous(item: VoicePlaybackItem): VoicePlaybackItem?
}

interface VoicePlaybackListenedStore {
    fun isListened(key: String): Boolean
    fun markListened(key: String)
    fun clearConversation(logicalConversationId: String)
    fun clearAll()
}

fun interface VoicePlaybackListener {
    fun onPlaybackStarted(item: VoicePlaybackItem)
}

class InMemoryVoicePlaybackRateStore : VoicePlaybackRateStore {
    private val rates = linkedMapOf<String, Float>()
    override fun rateFor(logicalConversationId: String): Float =
        rates[logicalConversationId] ?: 1.0f

    override fun setRate(logicalConversationId: String, rate: Float) {
        rates[logicalConversationId] = rate
    }

    fun clear() = rates.clear()
}

class InMemoryVoicePlaybackListenedStore(
    private val maxEntries: Int = 512,
) : VoicePlaybackListenedStore {
    private val keys = linkedSetOf<String>()

    override fun isListened(key: String): Boolean = key in keys

    override fun markListened(key: String) {
        keys.remove(key)
        keys.add(key)
        while (keys.size > maxEntries) {
            keys.remove(keys.first())
        }
    }

    override fun clearConversation(logicalConversationId: String) {
        keys.removeAll { it.startsWith("$logicalConversationId|") }
    }

    override fun clearAll() = keys.clear()

    fun snapshot(): Set<String> = keys.toSet()
}

class LruPlayheadCache(private val maxEntries: Int = 64) {
    private val values = linkedMapOf<String, Long>()

    fun get(key: String): Long? = values[key]?.also {
        values.remove(key)
        values[key] = it
    }

    fun put(key: String, positionMs: Long) {
        values.remove(key)
        values[key] = max(0L, positionMs)
        while (values.size > maxEntries) {
            values.remove(values.keys.first())
        }
    }

    fun remove(key: String) {
        values.remove(key)
    }

    fun clear() = values.clear()
}

object VoicePlaybackRates {
    val ALL = floatArrayOf(0.5f, 1.0f, 1.5f, 2.0f)

    fun cycle(current: Float): Float {
        val idx = ALL.indexOfFirst { kotlin.math.abs(it - current) < 0.01f }
        return ALL[(if (idx < 0) 0 else idx + 1) % ALL.size]
    }

    fun normalize(rate: Float): Float =
        ALL.minByOrNull { kotlin.math.abs(it - rate) } ?: 1.0f
}

/**
 * Process-scoped holder so Android Activity/`remember` recreation rebinds to
 * the same controller+engine instead of orphaning MediaSession audio.
 */
object AppVoicePlaybackSession {
    @Volatile var controller: VoiceMessagePlaybackController? = null
}

/**
 * App-scoped voice-note playback controller. Rows observe [state] and dispatch
 * commands; disposal must never call [VoicePlaybackCommand.Stop].
 */
class VoiceMessagePlaybackController(
    private val engine: VoicePlaybackEngine,
    private var rateStore: VoicePlaybackRateStore,
    private var queue: VoicePlaybackQueue,
    private var listenedStore: VoicePlaybackListenedStore,
    private val clock: VoicePlaybackClock = object : VoicePlaybackClock {
        override fun nowMs(): Long = 0L
    },
    private val playheads: LruPlayheadCache = LruPlayheadCache(),
    private val listener: VoicePlaybackListener? = null,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val progressIntervalMs: Long = 80L,
) {
    // clock reserved for future interruption timing / telemetry
    @Suppress("unused")
    private val unusedClock = clock
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var progressJob: Job? = null
    private var resumeAfterTransient = false

    @Volatile
    var state: VoicePlaybackState = VoicePlaybackState()
        private set

    var onStateChanged: ((VoicePlaybackState) -> Unit)? = null

    /** After Android Activity/UI recreation, point queue/rate/listened seams at
     *  the live [SonarAppState] so Next/Previous read the new transcript window. */
    fun rebindDependencies(
        rateStore: VoicePlaybackRateStore,
        queue: VoicePlaybackQueue,
        listenedStore: VoicePlaybackListenedStore,
    ) {
        this.rateStore = rateStore
        this.queue = queue
        this.listenedStore = listenedStore
    }

    fun dispatch(command: VoicePlaybackCommand) {
        scope.launch { mutex.withLock { applyCommand(command) } }
    }

    suspend fun dispatchSync(command: VoicePlaybackCommand) {
        mutex.withLock { applyCommand(command) }
    }

    fun isCurrent(item: VoicePlaybackItem): Boolean =
        state.item?.key == item.key && state.isActive

    fun listened(item: VoicePlaybackItem): Boolean =
        listenedStore.isListened(item.key) || item.key in state.listenedKeys

    fun onEngineReady(generation: Long, durationMs: Long) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                val item = state.item ?: return@withLock
                val cached = playheads.get(item.key) ?: 0L
                val dur = max(durationMs, item.durationHintMs ?: 0L)
                engine.seekTo(cached)
                engine.setRate(state.rate)
                engine.play()
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Playing,
                        positionMs = cached,
                        durationMs = dur,
                        interruptionReason = null,
                    )
                )
                markListened(item)
                startProgress(generation)
            }
        }
    }

    fun onEngineProgress(generation: Long, positionMs: Long, durationMs: Long) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                if (state.phase != VoicePlaybackPhase.Playing &&
                    state.phase != VoicePlaybackPhase.Paused
                ) {
                    return@withLock
                }
                publish(
                    state.copy(
                        positionMs = max(0L, positionMs),
                        durationMs = max(state.durationMs, durationMs),
                    )
                )
            }
        }
    }

    fun onEngineEnded(generation: Long) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                val item = state.item ?: return@withLock
                stopProgress()
                playheads.remove(item.key)
                engine.release()
                val next = queue.next(item)
                if (next != null) {
                    startItem(next, autoplay = true)
                } else {
                    publish(
                        state.copy(
                            phase = VoicePlaybackPhase.Ended,
                            positionMs = 0L,
                            interruptionReason = null,
                        )
                    )
                    clearActiveItemKeepingListened()
                }
            }
        }
    }

    fun onEngineFailed(generation: Long, reason: VoicePlaybackInterruption = VoicePlaybackInterruption.Error) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                stopProgress()
                state.item?.let { playheads.put(it.key, state.positionMs) }
                engine.release()
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Failed,
                        interruptionReason = reason,
                    )
                )
            }
        }
    }

    fun onSystemPaused(generation: Long) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                if (state.phase != VoicePlaybackPhase.Playing) return@withLock
                resumeAfterTransient = false
                stopProgress()
                val pos = engine.currentPositionMs().coerceAtLeast(state.positionMs)
                engine.pause()
                state.item?.let { playheads.put(it.key, pos) }
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Paused,
                        positionMs = pos,
                        interruptionReason = VoicePlaybackInterruption.RouteLost,
                    )
                )
            }
        }
    }

    fun onTransientInterruptionBegan(generation: Long) {
        scope.launch {
            mutex.withLock {
                // Re-check under the mutex: the host-side generation gate can
                // race a Play of a newer item before this coroutine runs.
                if (generation != state.generation) return@withLock
                if (state.phase != VoicePlaybackPhase.Playing) return@withLock
                resumeAfterTransient = true
                stopProgress()
                engine.pause()
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Paused,
                        interruptionReason = VoicePlaybackInterruption.TransientSystem,
                        positionMs = engine.currentPositionMs().coerceAtLeast(0L),
                    )
                )
            }
        }
    }

    fun onTransientInterruptionEnded(generation: Long) {
        scope.launch {
            mutex.withLock {
                if (generation != state.generation) return@withLock
                if (!resumeAfterTransient) return@withLock
                if (state.phase != VoicePlaybackPhase.Paused) {
                    resumeAfterTransient = false
                    return@withLock
                }
                if (state.interruptionReason != VoicePlaybackInterruption.TransientSystem) {
                    resumeAfterTransient = false
                    return@withLock
                }
                resumeAfterTransient = false
                engine.play()
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Playing,
                        interruptionReason = null,
                    )
                )
                startProgress(state.generation)
            }
        }
    }

    /** Cancel progress + controller scope. Safe to call from wipe / process teardown. */
    fun close() {
        stopProgress()
        runCatching { engine.release() }
        scope.cancel()
    }

    fun shutdown() {
        scope.launch {
            mutex.withLock {
                stopProgress()
                engine.release()
                publish(VoicePlaybackState(listenedKeys = state.listenedKeys))
            }
            scope.cancel()
        }
    }

    private suspend fun applyCommand(command: VoicePlaybackCommand) {
        when (command) {
            is VoicePlaybackCommand.Play -> startItem(command.item, autoplay = false)
            is VoicePlaybackCommand.PlayAt -> {
                startItem(command.item, autoplay = false)
                seek(command.positionMs)
            }
            VoicePlaybackCommand.Pause -> pauseUser()
            VoicePlaybackCommand.Resume -> resumeUser()
            is VoicePlaybackCommand.Seek -> seek(command.positionMs)
            VoicePlaybackCommand.CycleRate -> cycleRate()
            VoicePlaybackCommand.Next -> skip(next = true)
            VoicePlaybackCommand.Previous -> skip(next = false)
            is VoicePlaybackCommand.Stop -> stop(command.reason)
        }
    }

    private suspend fun startItem(item: VoicePlaybackItem, autoplay: Boolean) {
        val previous = state.item
        if (previous != null && previous.key != item.key && state.isActive) {
            playheads.put(previous.key, state.positionMs)
            stopProgress()
            engine.release()
        }
        resumeAfterTransient = false
        val generation = state.generation + 1L
        val rate = VoicePlaybackRates.normalize(rateStore.rateFor(item.logicalConversationId))
        publish(
            state.copy(
                item = item,
                phase = VoicePlaybackPhase.Loading,
                positionMs = playheads.get(item.key) ?: 0L,
                durationMs = item.durationHintMs ?: 0L,
                rate = rate,
                interruptionReason = null,
                generation = generation,
            )
        )
        try {
            engine.prepare(item, generation)
            if (state.generation != generation) return
            val dur = max(engine.durationMs(), item.durationHintMs ?: 0L)
            onEngineReadyLocked(generation, dur)
        } catch (_: Throwable) {
            if (state.generation == generation) {
                publish(
                    state.copy(
                        phase = VoicePlaybackPhase.Failed,
                        interruptionReason = VoicePlaybackInterruption.Error,
                    )
                )
            }
        }
    }

    private fun onEngineReadyLocked(generation: Long, durationMs: Long) {
        if (generation != state.generation) return
        val item = state.item ?: return
        val cached = playheads.get(item.key) ?: state.positionMs
        engine.seekTo(cached)
        engine.setRate(state.rate)
        engine.play()
        publish(
            state.copy(
                phase = VoicePlaybackPhase.Playing,
                positionMs = cached,
                durationMs = max(durationMs, item.durationHintMs ?: 0L),
                interruptionReason = null,
            )
        )
        markListened(item)
        startProgress(generation)
    }

    private fun pauseUser() {
        if (state.phase != VoicePlaybackPhase.Playing &&
            state.phase != VoicePlaybackPhase.Loading
        ) {
            return
        }
        resumeAfterTransient = false
        stopProgress()
        val pos = engine.currentPositionMs().coerceAtLeast(state.positionMs)
        engine.pause()
        state.item?.let { playheads.put(it.key, pos) }
        publish(
            state.copy(
                phase = VoicePlaybackPhase.Paused,
                positionMs = pos,
                interruptionReason = null,
            )
        )
    }

    private fun resumeUser() {
        if (state.phase != VoicePlaybackPhase.Paused) return
        if (state.interruptionReason == VoicePlaybackInterruption.Call ||
            state.interruptionReason == VoicePlaybackInterruption.Recording ||
            state.interruptionReason == VoicePlaybackInterruption.Deleted ||
            state.interruptionReason == VoicePlaybackInterruption.Wipe
        ) {
            return
        }
        resumeAfterTransient = false
        engine.play()
        publish(state.copy(phase = VoicePlaybackPhase.Playing, interruptionReason = null))
        startProgress(state.generation)
    }

    private fun seek(positionMs: Long) {
        val item = state.item ?: return
        if (!state.isActive && state.phase != VoicePlaybackPhase.Ended) return
        val dur = state.durationMs.takeIf { it > 0L } ?: engine.durationMs()
        val clamped = if (dur > 0L) positionMs.coerceIn(0L, dur) else max(0L, positionMs)
        engine.seekTo(clamped)
        playheads.put(item.key, clamped)
        publish(state.copy(positionMs = clamped, durationMs = max(state.durationMs, dur)))
    }

    private fun cycleRate() {
        val item = state.item ?: return
        val next = VoicePlaybackRates.cycle(state.rate)
        rateStore.setRate(item.logicalConversationId, next)
        engine.setRate(next)
        publish(state.copy(rate = next))
    }

    private suspend fun skip(next: Boolean) {
        val item = state.item ?: return
        val target = if (next) queue.next(item) else queue.previous(item)
        if (target == null) {
            if (next) stop(VoicePlaybackStopReason.Completed)
            return
        }
        startItem(target, autoplay = true)
    }

    private fun stop(reason: VoicePlaybackStopReason) {
        stopProgress()
        resumeAfterTransient = false
        val item = state.item
        if (item != null && reason != VoicePlaybackStopReason.Completed) {
            playheads.put(item.key, state.positionMs)
        }
        if (reason == VoicePlaybackStopReason.Completed && item != null) {
            playheads.remove(item.key)
        }
        engine.release()
        val interruption = when (reason) {
            VoicePlaybackStopReason.Call -> VoicePlaybackInterruption.Call
            VoicePlaybackStopReason.Recording -> VoicePlaybackInterruption.Recording
            VoicePlaybackStopReason.Deleted -> VoicePlaybackInterruption.Deleted
            VoicePlaybackStopReason.Wipe -> VoicePlaybackInterruption.Wipe
            VoicePlaybackStopReason.RouteLost -> VoicePlaybackInterruption.RouteLost
            VoicePlaybackStopReason.Error -> VoicePlaybackInterruption.Error
            VoicePlaybackStopReason.User,
            VoicePlaybackStopReason.Completed,
            VoicePlaybackStopReason.Superseded,
            -> null
        }
        val phase = when (reason) {
            VoicePlaybackStopReason.Completed -> VoicePlaybackPhase.Ended
            VoicePlaybackStopReason.Error -> VoicePlaybackPhase.Failed
            else -> VoicePlaybackPhase.Idle
        }
        publish(
            VoicePlaybackState(
                item = if (phase == VoicePlaybackPhase.Ended || phase == VoicePlaybackPhase.Failed) item else null,
                phase = phase,
                positionMs = if (phase == VoicePlaybackPhase.Ended) 0L else state.positionMs,
                durationMs = state.durationMs,
                rate = state.rate,
                interruptionReason = interruption,
                generation = state.generation + 1L,
                listenedKeys = state.listenedKeys,
            )
        )
        if (phase == VoicePlaybackPhase.Idle) {
            publish(VoicePlaybackState(generation = state.generation, listenedKeys = state.listenedKeys, rate = state.rate))
        }
    }

    private fun clearActiveItemKeepingListened() {
        publish(
            VoicePlaybackState(
                generation = state.generation,
                listenedKeys = state.listenedKeys,
            )
        )
    }

    private fun markListened(item: VoicePlaybackItem) {
        if (listenedStore.isListened(item.key)) return
        listenedStore.markListened(item.key)
        publish(state.copy(listenedKeys = state.listenedKeys + item.key))
        listener?.onPlaybackStarted(item)
    }

    private fun startProgress(generation: Long) {
        stopProgress()
        progressJob = scope.launch {
            while (isActive) {
                delay(progressIntervalMs)
                val keepGoing = mutex.withLock {
                    if (generation != state.generation) return@withLock false
                    if (state.phase != VoicePlaybackPhase.Playing) return@withLock false
                    val pos = engine.currentPositionMs()
                    val dur = max(state.durationMs, engine.durationMs())
                    publish(state.copy(positionMs = pos.coerceAtLeast(0L), durationMs = dur))
                    true
                }
                if (!keepGoing) break
            }
        }
    }

    private fun stopProgress() {
        progressJob?.cancel()
        progressJob = null
    }

    private fun publish(next: VoicePlaybackState) {
        state = next
        onStateChanged?.invoke(next)
    }
}

/**
 * Build a stable attachment id that survives optimistic URL → canonical URL
 * remaps (`pending-media-*` → published URL). [url] is accepted for call-site
 * compatibility but must not participate in the key.
 */
fun voiceAttachmentId(
    messageId: String,
    mediaIndex: Int,
    filename: String,
    @Suppress("UNUSED_PARAMETER") url: String,
): String {
    val nameKey = filename.trim().ifEmpty { "audio" }
    return "$messageId#$mediaIndex#$nameKey"
}
