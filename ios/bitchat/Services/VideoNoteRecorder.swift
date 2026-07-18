#if os(iOS)
import AVFoundation
import SwiftUI

/// File-backed, 60-second MP4 capture for Telegram-style video notes.
/// The transcript never owns camera state; the recorder finalizes a temporary
/// file first, then the existing encrypted-media pipeline takes ownership.
@MainActor
final class VideoNoteRecorder: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var elapsed: Int = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var isFrontCamera = true
    @Published private(set) var isReady = false

    private let output = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputURL: URL?
    private var completedURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    private var finishContinuation: CheckedContinuation<URL?, Never>?
    private var discardOnFinish = false
    private var isFinalizing = false

    func start() async -> Bool {
        // AVCaptureMovieFileOutput finalizes asynchronously. A quick cancel →
        // record gesture must wait for that delegate callback before reusing
        // the same output, or the old callback can consume the new clip URL.
        if outputURL != nil || output.isRecording || isFinalizing {
            discardOnFinish = true
            _ = await waitForFinalization()
        }
        cancel()
        guard await requestPermission(for: .video),
              await requestPermission(for: .audio),
              configureSession()
        else { return false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-note-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        completedURL = nil
        discardOnFinish = false
        elapsed = 0
        level = 0
        startedAt = Date()
        if !session.isRunning { session.startRunning() }
        output.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
        output.maxRecordedFileSize = 25 * 1024 * 1024
        output.startRecording(to: url, recordingDelegate: self)
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = min(60, Int(Date().timeIntervalSince(startedAt)))
                // AVCaptureMovieFileOutput exposes no live meter. Keep the
                // visual pulse subtle and deterministic instead of faking audio.
                self.level = self.output.isRecording ? 0.22 : 0
            }
        }
        return true
    }

    func finish() async -> URL? {
        if outputURL == nil, !output.isRecording, !isFinalizing {
            defer { completedURL = nil }
            return completedURL
        }
        return await waitForFinalization()
    }

    func cancel() {
        discardOnFinish = true
        if output.isRecording {
            isFinalizing = true
            output.stopRecording()
        } else if isFinalizing || outputURL != nil {
            // The stop callback owns cleanup. Do not remove a file while
            // AVFoundation is still closing its MP4 atoms.
        } else {
            cleanup(removeFile: true)
        }
    }

    func flipCamera() {
        guard let current = videoInput else { return }
        let target: AVCaptureDevice.Position = current.device.position == .front ? .back : .front
        guard let device = camera(position: target),
              let replacement = try? AVCaptureDeviceInput(device: device)
        else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(replacement) {
            session.addInput(replacement)
            videoInput = replacement
            isFrontCamera = target == .front
        } else {
            session.addInput(current)
        }
        session.commitConfiguration()
        configureVideoConnection()
    }

    private func requestPermission(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func configureSession() -> Bool {
        if isReady { return true }
        guard let videoDevice = camera(position: .front) ?? camera(position: .back),
              let audioDevice = AVCaptureDevice.default(for: .audio),
              let video = try? AVCaptureDeviceInput(device: videoDevice),
              let audio = try? AVCaptureDeviceInput(device: audioDevice)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .cif352x288
        defer { session.commitConfiguration() }
        guard session.canAddInput(video), session.canAddInput(audio), session.canAddOutput(output) else {
            return false
        }
        session.addInput(video)
        session.addInput(audio)
        session.addOutput(output)
        videoInput = video
        audioInput = audio
        isFrontCamera = videoDevice.position == .front
        isReady = true
        configureVideoConnection()
        return true
    }

    private func configureVideoConnection() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isFrontCamera
        }
        output.setOutputSettings(
            [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 192_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
                ]
            ],
            for: connection
        )
        if let audioConnection = output.connection(with: .audio) {
            output.setOutputSettings(
                [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 24_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ],
                for: audioConnection
            )
        }
    }

    private func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    private func waitForFinalization() async -> URL? {
        await withCheckedContinuation { continuation in
            precondition(finishContinuation == nil, "video note finalization already has a waiter")
            finishContinuation = continuation
            if !isFinalizing {
                isFinalizing = true
                output.stopRecording()
            }
        }
    }

    private func takeFinishedURL(_ url: URL) -> URL? {
        if outputURL == url { outputURL = nil }
        guard !discardOnFinish,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 2_000
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func cleanup(removeFile: Bool) {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        elapsed = 0
        level = 0
        if removeFile, let url = outputURL { try? FileManager.default.removeItem(at: url) }
        if removeFile, let url = completedURL { try? FileManager.default.removeItem(at: url) }
        if removeFile { outputURL = nil }
        if removeFile { completedURL = nil }
        if session.isRunning { session.stopRunning() }
    }
}

extension VideoNoteRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            let continuation = finishContinuation
            finishContinuation = nil
            isFinalizing = false
            cleanup(removeFile: false)
            let result = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
                ? takeFinishedURL(outputFileURL)
                : nil
            if outputURL == outputFileURL { outputURL = nil }
            if result == nil { try? FileManager.default.removeItem(at: outputFileURL) }
            if let continuation {
                continuation.resume(returning: result)
            } else {
                completedURL = result
            }
        }
    }
}

final class VideoNotePreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct VideoNotePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> VideoNotePreviewUIView {
        let view = VideoNotePreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: VideoNotePreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}
#endif
