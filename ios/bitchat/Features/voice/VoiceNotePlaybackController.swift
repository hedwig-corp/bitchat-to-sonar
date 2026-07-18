//
// VoiceNotePlaybackController.swift
// bitchat
//
// One app-scoped voice-message playback session (Signal-parity): a single
// active item app-wide, driven entirely by commands, observed by rows that
// never own an engine and never stop playback on disappearance. Every seam
// (engine, tick clock, per-conversation rate, listened state, bounded
// successor/previous queue) is injected so the state machine is unit
// testable with fakes — see ios/bitchatTests/VoiceMessagePlaybackControllerTests.swift.
//
// `VoiceNotePlaybackController.shared` is the one process-wide instance rows
// observe (`SNAudioBubble`, `VoiceNoteView`); `SonarAppStore` wires its
// fold-aware queue in via `configure(queue:onPlaybackStarted:)` and calls
// `stop(reason:)`/`clearAll()` on call/record preemption and wipe/erase.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import AVFoundation
import BitLogger
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Item / phase / rate

/// One playable voice note. `logicalConversationId` scopes rate persistence
/// and the next/previous queue (the canonical/folded UI conversation);
/// `sourceConversationId` is the exact transport/group the local file came
/// from (a Marmot group id, or the mesh/legacy conversation id). Both may be
/// equal for a simple 1:1 chat.
struct VoicePlaybackItem {
    let logicalConversationId: String
    let sourceConversationId: String
    let messageId: String
    let attachmentId: String
    let localFile: URL
    let durationHint: TimeInterval?

    /// Stable identity for playhead-cache / queue lookups. Two loads of "the
    /// same" voice note (e.g. once a duration hint has been filled in) must
    /// compare equal even if `durationHint` differs, so identity is keyed on
    /// message + attachment, never on the whole struct.
    var key: String { messageId + "#" + attachmentId }
}

enum VoicePlaybackPhase: Equatable {
    case idle
    case loading
    case playing
    case paused
    case ended
    case failed
}

/// Why the item is currently paused. Only `.transientInterruption` (a system
/// audio interruption that reports `.shouldResume`) is allowed to auto-resume;
/// every other reason requires an explicit user command. Calls and recording
/// preempt via `stop(reason:)` (below) rather than pause, so they clear the
/// item outright and have no auto-resume path to guard against.
enum VoicePlaybackInterruptionReason: Equatable {
    case userPause
    case transientInterruption
    case routeChanged
    case error
}

/// Why an item was fully torn down (item cleared, Now Playing cleared).
enum VoicePlaybackStopReason: Equatable {
    case completed
    case call
    case recording
    case deleted
    case wiped
    case replaced
    case error
}

/// Signal-style rates a voice note cycles through. Kept as a plain `Double`
/// (not an enum) on `VoicePlaybackState` — call sites format/compare it
/// directly (`%g×`, `abs(rate - 1.0)`).
enum VoicePlaybackRates {
    static let all: [Double] = [0.5, 1.0, 1.5, 2.0]
    static let `default`: Double = 1.0

    static func next(after rate: Double) -> Double {
        let i = all.firstIndex(where: { abs($0 - rate) < 0.01 }) ?? 1
        return all[(i + 1) % all.count]
    }
}

/// The single app-wide observable playback state. Rows read this; they never
/// hold their own copy of `phase`/`position`/`duration`.
struct VoicePlaybackState {
    var item: VoicePlaybackItem?
    var phase: VoicePlaybackPhase = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate: Double = VoicePlaybackRates.default
    var interruptionReason: VoicePlaybackInterruptionReason?
    /// Bumped on every load/stop. Engine callbacks captured a generation at
    /// dispatch time; a stale generation is dropped instead of mutating a
    /// newer item's state.
    var generation: Int = 0

    var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

// MARK: - Injected seams

/// Wraps one decoder/output unit. The default is file-backed `AVAudioPlayer`;
/// tests use a fake that never touches disk or `AVAudioSession`. Callbacks
/// are `@MainActor` closures: a conforming engine is responsible for hopping
/// onto the main actor itself (real `AVAudioPlayerDelegate` callbacks can
/// arrive on a background thread) so the controller can call them
/// synchronously and stale-generation checks race against nothing else.
protocol VoicePlaybackEngine: AnyObject {
    var onFinish: (@MainActor (Bool) -> Void)? { get set }
    var onDecodeError: (@MainActor (Error?) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func load(url: URL) throws -> TimeInterval
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    func seek(to time: TimeInterval)
    func setRate(_ rate: Float)
}

/// Drives periodic UI progress updates. Default uses a `Timer` on the main
/// run loop; tests fire ticks manually via a fake.
protocol VoicePlaybackTicker: AnyObject {
    func start(interval: TimeInterval, _ tick: @escaping () -> Void)
    func stop()
}

/// Per-logical-conversation playback rate, persisted locally (never synced).
protocol VoicePlaybackRateStore {
    func rate(forLogicalConversationId id: String) -> Double
    func setRate(_ rate: Double, forLogicalConversationId id: String)
}

/// Bounded local "has this voice note been opened" state — reuses existing
/// receipt semantics conceptually, but is intentionally local-only; there is
/// no dedicated cross-device wire event for this yet.
protocol VoicePlaybackListenedStore {
    func hasListened(messageId: String) -> Bool
    func markListened(messageId: String)
    func clearAll()
}

/// Bounded successor/predecessor resolution *within one logical conversation*.
/// `SonarAppStore` installs a concrete instance (`SonarVoicePlaybackQueue`)
/// via `configure(queue:)`, built from the already-loaded transcript window;
/// the controller never asks it to fetch anything.
protocol VoicePlaybackQueue: AnyObject {
    func next(after item: VoicePlaybackItem) -> VoicePlaybackItem?
    func previous(before item: VoicePlaybackItem) -> VoicePlaybackItem?
}

/// No-op queue used until `SonarAppStore` installs the real one at startup.
private final class NullVoicePlaybackQueue: VoicePlaybackQueue {
    func next(after item: VoicePlaybackItem) -> VoicePlaybackItem? { nil }
    func previous(before item: VoicePlaybackItem) -> VoicePlaybackItem? { nil }
}

// MARK: - Default engine (AVAudioPlayer, file-backed)

/// File-backed (never `Data`-backed) `AVAudioPlayer` wrapper. `enableRate`
/// gives pitch-preserving 0.5×–2× playback per Apple's own player, so no
/// separate `AVAudioEngine` + time-pitch unit is required for this v1.
final class AVAudioPlayerVoicePlaybackEngine: NSObject, VoicePlaybackEngine, AVAudioPlayerDelegate {
    var onFinish: (@MainActor (Bool) -> Void)?
    var onDecodeError: (@MainActor (Error?) -> Void)?

    private var player: AVAudioPlayer?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func load(url: URL) throws -> TimeInterval {
        #if os(iOS)
        try Self.activateSession()
        #endif
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.enableRate = true
        p.prepareToPlay()
        player = p
        return p.duration
    }

    @discardableResult
    func play() -> Bool {
        #if os(iOS)
        try? Self.activateSession()
        #endif
        return player?.play() ?? false
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
        #if os(iOS)
        Self.deactivateSession()
        #endif
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = max(0, time)
    }

    func setRate(_ rate: Float) {
        player?.rate = rate
    }

    #if os(iOS)
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.playAndRecord` is required for `overrideOutputAudioPort(.none)` to
        // reach the receiver on proximity-near; `.playback` always stays on the
        // loudspeaker path. `.defaultToSpeaker` keeps away-from-ear playback on
        // the speaker until proximity flips the route. Calls/recording still
        // preempt via the controller's `stop(reason:)`.
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true)
    }

    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif

    // AVAudioPlayerDelegate callbacks may arrive on a background thread; hop
    // to the main actor here so `onFinish`/`onDecodeError` can be called
    // synchronously by the (always-main-actor) controller.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.onDecodeError?(error) }
    }
}

/// `Timer` on the main run loop, matching the legacy controller's cadence.
final class RunLoopVoicePlaybackTicker: VoicePlaybackTicker {
    private var timer: Timer?

    func start(interval: TimeInterval, _ tick: @escaping () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// `UserDefaults`-backed rate store, one key per logical conversation.
final class UserDefaultsVoicePlaybackRateStore: VoicePlaybackRateStore {
    private let defaults: UserDefaults
    private static let keyPrefix = "sonar.voice.rate."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func rate(forLogicalConversationId id: String) -> Double {
        let raw = defaults.double(forKey: Self.keyPrefix + id)
        return VoicePlaybackRates.all.contains(where: { abs($0 - raw) < 0.01 }) ? raw : VoicePlaybackRates.default
    }

    func setRate(_ rate: Double, forLogicalConversationId id: String) {
        defaults.set(rate, forKey: Self.keyPrefix + id)
    }
}

/// Bounded local listened set, persisted as an ordered array so the oldest
/// entries fall off instead of growing forever.
final class UserDefaultsVoicePlaybackListenedStore: VoicePlaybackListenedStore {
    private let defaults: UserDefaults
    private let key = "sonar.voice.listened"
    private let capacity: Int

    init(defaults: UserDefaults = .standard, capacity: Int = 500) {
        self.defaults = defaults
        self.capacity = capacity
    }

    func hasListened(messageId: String) -> Bool {
        (defaults.array(forKey: key) as? [String] ?? []).contains(messageId)
    }

    func markListened(messageId: String) {
        var ids = defaults.array(forKey: key) as? [String] ?? []
        guard !ids.contains(messageId) else { return }
        ids.append(messageId)
        if ids.count > capacity {
            ids.removeFirst(ids.count - capacity)
        }
        defaults.set(ids, forKey: key)
    }

    func clearAll() {
        defaults.removeObject(forKey: key)
    }
}

/// Bounded, memory-only LRU of last-known playheads keyed by item key, so
/// switching away and back (without finishing) resumes near where playback
/// left off even after the engine has been torn down and reloaded.
final class VoicePlayheadCache {
    private var order: [String] = []
    private var positions: [String: TimeInterval] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func position(for key: String) -> TimeInterval {
        positions[key] ?? 0
    }

    func set(_ position: TimeInterval, for key: String) {
        if positions[key] == nil {
            order.append(key)
            if order.count > capacity {
                let dropped = order.removeFirst()
                positions.removeValue(forKey: dropped)
            }
        } else {
            order.removeAll { $0 == key }
            order.append(key)
        }
        positions[key] = position
    }

    func clear(for key: String?) {
        guard let key else { return }
        positions.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    func clearAll() {
        order.removeAll()
        positions.removeAll()
    }
}

// MARK: - Controller

/// The single app-scoped voice-playback session. Rows observe `state` (or
/// the compatibility shims below) and send commands; nothing here is torn
/// down when a row disappears — only `stop(reason:)` (explicit preemption /
/// deletion / wipe) or natural completion with no queued successor clears
/// the active item.
@MainActor
final class VoiceNotePlaybackController: ObservableObject {
    /// Process-wide session. Rows use this directly; tests construct their
    /// own instance with fake seams instead of touching this singleton.
    static let shared = VoiceNotePlaybackController()

    @Published private(set) var state = VoicePlaybackState()

    private let engineFactory: () -> VoicePlaybackEngine
    private let ticker: VoicePlaybackTicker
    private let rateStore: VoicePlaybackRateStore
    private let listenedStore: VoicePlaybackListenedStore
    private let playheadCache: VoicePlayheadCache

    private var queueProvider: VoicePlaybackQueue
    private var onPlaybackStarted: ((VoicePlaybackItem) -> Void)?

    private var engine: VoicePlaybackEngine?
    private var generation = 0

    init(
        engineFactory: @escaping () -> VoicePlaybackEngine = { AVAudioPlayerVoicePlaybackEngine() },
        ticker: VoicePlaybackTicker = RunLoopVoicePlaybackTicker(),
        rateStore: VoicePlaybackRateStore = UserDefaultsVoicePlaybackRateStore(),
        listenedStore: VoicePlaybackListenedStore = UserDefaultsVoicePlaybackListenedStore(),
        queueProvider: VoicePlaybackQueue = NullVoicePlaybackQueue(),
        playheadCacheCapacity: Int = 40
    ) {
        self.engineFactory = engineFactory
        self.ticker = ticker
        self.rateStore = rateStore
        self.listenedStore = listenedStore
        self.queueProvider = queueProvider
        self.playheadCache = VoicePlayheadCache(capacity: playheadCacheCapacity)
        #if os(iOS)
        registerInterruptionObservers()
        #endif
        configureRemoteCommands()
    }

    deinit {
        ticker.stop()
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o) }
        #endif
    }

    /// Installed once by `SonarAppStore` at startup with its fold-aware,
    /// transcript-window-backed queue. `onPlaybackStarted` is an optional
    /// hook for side effects (e.g. future read-receipt integration) that
    /// must not gate playback itself.
    func configure(queue: VoicePlaybackQueue, onPlaybackStarted: ((VoicePlaybackItem) -> Void)? = nil) {
        self.queueProvider = queue
        self.onPlaybackStarted = onPlaybackStarted
    }

    // MARK: Compatibility shims (legacy per-row API surface)

    var duration: TimeInterval { state.duration }
    var currentTime: TimeInterval { state.position }
    var isPlaying: Bool { state.phase == .playing }
    var progress: Double { state.progress }

    func isCurrent(_ item: VoicePlaybackItem) -> Bool {
        state.item?.key == item.key
    }

    func isListened(_ item: VoicePlaybackItem) -> Bool {
        listenedStore.hasListened(messageId: item.messageId)
    }

    /// Play if idle/a different item; pause if this item is already playing;
    /// resume if this item is the current, paused one.
    func toggle(_ item: VoicePlaybackItem) {
        if isCurrent(item), state.phase == .playing {
            pause()
        } else {
            play(item)
        }
    }

    /// Legacy single-row API: swap the active item's backing file in place
    /// (e.g. an optimistic voice-note send being promoted to its final local
    /// path). Only meaningful while this item is current; a stale/offscreen
    /// row's remap is a no-op. Because the file itself is changing, this
    /// stops rather than tries to hot-swap a live `AVAudioPlayer`.
    func replaceURL(_ url: URL) {
        guard let item = state.item, item.localFile != url else { return }
        stop(reason: .replaced)
    }

    // MARK: Commands

    /// Play `item`. If it is already the active, paused item this resumes in
    /// place instead of reloading; otherwise it (re)loads from the top or
    /// from a cached playhead and starts a fresh generation.
    func play(_ item: VoicePlaybackItem) {
        if isCurrent(item), state.phase == .paused {
            resume()
            return
        }
        beginLoad(item)
    }

    func pause() {
        guard state.phase == .playing, let engine else { return }
        // Sync the playhead from the engine *before* flipping phase — a row
        // may pause immediately after a UI event with no tick having fired
        // yet, and `state.position` must reflect real elapsed time, not a
        // stale/zero value, so the cached playhead and resume() are correct.
        state.position = engine.currentTime
        engine.pause()
        ticker.stop()
        savePlayhead()
        state.phase = .paused
        state.interruptionReason = .userPause
        clearProximity()
        updateNowPlayingInfo()
    }

    func resume() {
        guard state.phase == .paused, let engine, state.item != nil else { return }
        engine.seek(to: state.position)
        guard engine.play() else {
            failActive()
            return
        }
        state.interruptionReason = nil
        state.phase = .playing
        startTicking()
        updateProximity()
        updateNowPlayingInfo()
    }

    /// `fraction` is 0...1 of the current item's duration.
    func seek(fraction: Double) {
        guard state.item != nil, state.duration > 0 else { return }
        let clamped = max(0, min(1, fraction))
        let time = clamped * state.duration
        engine?.seek(to: time)
        state.position = time
        savePlayhead()
        updateNowPlayingInfo()
    }

    func cycleRate() {
        guard let item = state.item else { return }
        let next = VoicePlaybackRates.next(after: state.rate)
        state.rate = next
        engine?.setRate(Float(next))
        rateStore.setRate(next, forLogicalConversationId: item.logicalConversationId)
        updateNowPlayingInfo()
    }

    func next() {
        guard let item = state.item, let successor = queueProvider.next(after: item) else {
            stop(reason: .completed)
            return
        }
        beginLoad(successor)
    }

    func previous() {
        guard let item = state.item, let predecessor = queueProvider.previous(before: item) else { return }
        beginLoad(predecessor)
    }

    /// Fully clear the session: engine torn down, item cleared, Now Playing
    /// cleared, proximity cleared. Used for preemption (call/recording),
    /// deletion/wipe, natural end-of-queue, and load/playback error — never
    /// called just because a row disappeared.
    func stop(reason: VoicePlaybackStopReason) {
        savePlayhead()
        engine?.stop()
        engine = nil
        ticker.stop()
        generation += 1
        state = VoicePlaybackState(generation: generation)
        clearProximity()
        clearNowPlayingInfo()
        if reason == .error {
            SecureLogger.warning("VoicePlayback: stopped on error", category: .session)
        }
    }

    /// Stop only if the active item matches `predicate` — lets deletion call
    /// sites target exactly the affected conversation/message without
    /// silencing unrelated playback.
    func stopIfActiveItem(matching predicate: (VoicePlaybackItem) -> Bool, reason: VoicePlaybackStopReason) {
        guard let item = state.item, predicate(item) else { return }
        stop(reason: reason)
    }

    /// Full account wipe / erase-all-chats: stop playback and drop every
    /// local playback-adjacent trace (cached playheads, listened markers).
    /// Rate preferences are per-conversation UI polish, not user data, and
    /// are intentionally left alone.
    func clearAll() {
        stop(reason: .wiped)
        playheadCache.clearAll()
        listenedStore.clearAll()
    }

    // MARK: Load

    private func beginLoad(_ item: VoicePlaybackItem) {
        savePlayhead()
        engine?.stop()

        generation += 1
        let myGeneration = generation

        let newEngine = engineFactory()
        engine = newEngine
        let rate = rateStore.rate(forLogicalConversationId: item.logicalConversationId)
        let cachedPosition = playheadCache.position(for: item.key)
        state = VoicePlaybackState(
            item: item,
            phase: .loading,
            position: cachedPosition,
            duration: item.durationHint ?? 0,
            rate: rate,
            interruptionReason: nil,
            generation: myGeneration
        )

        newEngine.onFinish = { [weak self] success in
            self?.handleFinish(generation: myGeneration, success: success)
        }
        newEngine.onDecodeError = { [weak self] error in
            self?.handleDecodeError(generation: myGeneration, error: error)
        }

        do {
            let duration = try newEngine.load(url: item.localFile)
            guard generation == myGeneration else { return } // superseded while loading
            newEngine.setRate(Float(rate))
            if cachedPosition > 0, duration <= 0 || cachedPosition < duration {
                newEngine.seek(to: cachedPosition)
            }
            guard newEngine.play() else {
                fail(generation: myGeneration)
                return
            }
            state.duration = duration > 0 ? duration : state.duration
            state.phase = .playing
            listenedStore.markListened(messageId: item.messageId)
            onPlaybackStarted?(item)
            startTicking()
            updateProximity()
            updateNowPlayingInfo()
        } catch {
            SecureLogger.error("VoicePlayback: load failed: \(error.localizedDescription)", category: .session)
            fail(generation: myGeneration)
        }
    }

    // MARK: Ticking

    private func startTicking() {
        ticker.start(interval: 0.05) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard let engine, state.phase == .playing else { return }
        state.position = engine.currentTime
        if engine.duration > 0 { state.duration = engine.duration }
        updateNowPlayingElapsed()
    }

    // MARK: Engine callbacks (generation-guarded)

    private func handleFinish(generation callbackGeneration: Int, success: Bool) {
        guard callbackGeneration == generation else { return } // stale callback
        ticker.stop()
        guard success else {
            fail(generation: callbackGeneration)
            return
        }
        if let item = state.item { playheadCache.clear(for: item.key) }
        state.phase = .ended
        state.position = state.duration
        clearProximity()
        next()
    }

    private func handleDecodeError(generation callbackGeneration: Int, error: Error?) {
        guard callbackGeneration == generation else { return } // stale callback
        SecureLogger.error("VoicePlayback: decode error: \(error?.localizedDescription ?? "unknown")", category: .session)
        fail(generation: callbackGeneration)
    }

    private func fail(generation callbackGeneration: Int) {
        guard callbackGeneration == generation else { return }
        failActive()
    }

    private func failActive() {
        // Tear down the engine + Now Playing, keep the failed item so the
        // bubble can surface a recoverable error and the user can retry play.
        ticker.stop()
        savePlayhead()
        engine?.stop()
        engine = nil
        generation += 1
        state.phase = .failed
        state.interruptionReason = .error
        state.generation = generation
        clearProximity()
        clearNowPlayingInfo()
    }

    // MARK: Playhead persistence (memory-only, bounded)

    private func savePlayhead() {
        guard let item = state.item, state.phase == .playing || state.phase == .paused else { return }
        let position = engine?.currentTime ?? state.position
        playheadCache.set(position, for: item.key)
    }

    // MARK: Proximity (iOS only — clears on pause/end/error, never left stuck)

    #if os(iOS)
    private func updateProximity() {
        let device = UIDevice.current
        guard !device.isProximityMonitoringEnabled else { return }
        device.isProximityMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProximityChange),
            name: UIDevice.proximityStateDidChangeNotification,
            object: device
        )
        applyProximityRoute()
    }

    private func clearProximity() {
        let device = UIDevice.current
        if device.isProximityMonitoringEnabled {
            NotificationCenter.default.removeObserver(
                self,
                name: UIDevice.proximityStateDidChangeNotification,
                object: device
            )
            device.isProximityMonitoringEnabled = false
        }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }

    @objc private func handleProximityChange() {
        applyProximityRoute()
    }

    private func applyProximityRoute() {
        // Near ear → default (receiver); away → speaker. Matches Signal's
        // voice-note proximity routing on the built-in receiver path.
        let near = UIDevice.current.proximityState
        let port: AVAudioSession.PortOverride = near ? .none : .speaker
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(port)
    }
    #else
    private func updateProximity() {}
    private func clearProximity() {}
    #endif

    // MARK: Interruptions + route changes (iOS only — no AVAudioSession on macOS)

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private func registerInterruptionObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            guard state.phase == .playing, let engine else { return }
            state.position = engine.currentTime
            engine.pause()
            ticker.stop()
            savePlayhead()
            state.phase = .paused
            state.interruptionReason = .transientInterruption
            clearProximity()
            updateNowPlayingInfo()
        case .ended:
            guard state.phase == .paused, state.interruptionReason == .transientInterruption else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable,
              state.phase == .playing,
              let engine
        else { return }
        // Headset/Bluetooth unplugged mid-playback: pause rather than blast
        // the speaker unexpectedly. This is a route change, not a transient
        // interruption, so it never auto-resumes.
        state.position = engine.currentTime
        engine.pause()
        ticker.stop()
        savePlayhead()
        state.phase = .paused
        state.interruptionReason = .routeChanged
        clearProximity()
        updateNowPlayingInfo()
    }
    #endif

    // MARK: Now Playing / remote commands

    #if canImport(MediaPlayer)
    /// `MPRemoteCommandCenter` callbacks are not guaranteed on the main actor;
    /// hop before touching `@MainActor` session state.
    private func onRemoteCommand(
        _ body: @escaping () -> MPRemoteCommandHandlerStatus
    ) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread { return body() }
        var status: MPRemoteCommandHandlerStatus = .commandFailed
        DispatchQueue.main.sync { status = body() }
        return status
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                guard self.state.phase == .paused else { return .noActionableNowPlayingItem }
                self.resume()
                return .success
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                guard self.state.phase == .playing else { return .noActionableNowPlayingItem }
                self.pause()
                return .success
            }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                switch self.state.phase {
                case .playing: self.pause()
                case .paused: self.resume()
                default: return .noActionableNowPlayingItem
                }
                return .success
            }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                guard self.state.item != nil else { return .noActionableNowPlayingItem }
                self.next()
                return .success
            }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                guard self.state.item != nil else { return .noActionableNowPlayingItem }
                self.previous()
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            return self.onRemoteCommand {
                guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                      self.state.duration > 0
                else { return .commandFailed }
                self.seek(fraction: positionEvent.positionTime / self.state.duration)
                return .success
            }
        }
        clearNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        let center = MPRemoteCommandCenter.shared()
        guard let item = state.item, state.phase != .idle else {
            clearNowPlayingInfo()
            return
        }
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = queueProvider.next(after: item) != nil
        center.previousTrackCommand.isEnabled = queueProvider.previous(before: item) != nil
        center.changePlaybackPositionCommand.isEnabled = state.duration > 0

        var info: [String: Any] = [
            // Privacy-safe: never the peer/group name or message content.
            MPMediaItemPropertyTitle: "Voice message",
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
        ]
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.phase == .playing ? state.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // macOS cannot infer play/pause from an audio session; both platforms
        // need this set explicitly for lock-screen/Control Center/Touch Bar.
        MPNowPlayingInfoCenter.default().playbackState = state.phase == .playing ? .playing : .paused
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.position
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }
    #else
    private func configureRemoteCommands() {}
    private func updateNowPlayingInfo() {}
    private func updateNowPlayingElapsed() {}
    private func clearNowPlayingInfo() {}
    #endif
}
