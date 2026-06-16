//
// VoiceNoteRecorder.swift
// Records a voice note to an AAC .m4a file for the Sonar composer's hold-to-record
// mic button (design: components.jsx VoiceRecorder). Sent over the SAME media
// path as photos (mime "audio/mp4"), so no core/wire change — a voice note is
// just media with an audio mime.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// What the recorder exposes to the UI: a small observable state the recorder
/// view renders + drives. Behind a protocol so the composer can be previewed /
/// unit-tested with `FakeVoiceRecording` (no real mic / AVAudioSession).
@MainActor
protocol VoiceRecording: ObservableObject {
    /// Seconds elapsed since `start()`.
    var elapsed: Int { get }
    /// Normalized input level 0…1 for the live waveform.
    var level: CGFloat { get }
    /// Request mic permission + begin recording. No-op if already recording.
    func start() async -> Bool
    /// Stop + keep the file; returns its URL (nil if nothing was recorded).
    func finish() -> URL?
    /// Stop + discard the file.
    func cancel()
}

#if os(iOS)
/// Real recorder: AAC `.m4a` via `AVAudioRecorder`, with metering for the waveform.
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, VoiceRecording {
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var level: CGFloat = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?

    func start() async -> Bool {
        guard recorder == nil else { return true }
        let granted = await Self.requestPermission()
        guard granted else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vn-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        rec.isMeteringEnabled = true
        guard rec.record() else { return false }
        recorder = rec
        fileURL = url
        elapsed = 0
        startTimer()
        return true
    }

    func finish() -> URL? {
        guard let rec = recorder else { return nil }
        rec.stop()
        stopTimer()
        let url = fileURL
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Drop empty/instant taps (< ~0.3s of audio) — they aren't useful notes.
        if let url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 < 1500 {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            return nil
        }
        fileURL = nil
        return url
    }

    func cancel() {
        recorder?.stop()
        stopTimer()
        recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        // AVAudioRecorder power is in dBFS (~ -60 silence … 0 loud) → 0…1.
        let db = rec.averagePower(forChannel: 0)
        let norm = max(0, (db + 55) / 55)
        level = CGFloat(min(1, norm))
        elapsed = Int(rec.currentTime)
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }
}
#endif

/// Test/preview double: a deterministic, mic-free recorder.
@MainActor
final class FakeVoiceRecording: ObservableObject, VoiceRecording {
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var level: CGFloat = 0.5
    private var timer: Timer?

    func start() async -> Bool {
        elapsed = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }
    func finish() -> URL? { timer?.invalidate(); timer = nil; return nil }
    func cancel() { timer?.invalidate(); timer = nil }
}
