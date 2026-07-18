import SwiftUI
import AVFoundation

struct VoiceNoteView: View {
    private let url: URL
    private let isSending: Bool
    private let sendProgress: Double?
    private let onCancel: (() -> Void)?
    private let logicalConversationId: String
    private let sourceConversationId: String
    private let messageId: String
    private let attachmentId: String

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var playback = VoiceNotePlaybackController.shared
    @State private var waveform: [Float] = []

    init(
        url: URL,
        isSending: Bool,
        sendProgress: Double?,
        onCancel: (() -> Void)?,
        logicalConversationId: String = "mesh",
        sourceConversationId: String = "mesh",
        messageId: String? = nil,
        attachmentId: String? = nil
    ) {
        self.url = url
        self.isSending = isSending
        self.sendProgress = sendProgress
        self.onCancel = onCancel
        self.logicalConversationId = logicalConversationId
        self.sourceConversationId = sourceConversationId
        self.messageId = messageId ?? url.lastPathComponent
        self.attachmentId = attachmentId ?? url.lastPathComponent
    }

    private var item: VoicePlaybackItem {
        VoicePlaybackItem(
            logicalConversationId: logicalConversationId,
            sourceConversationId: sourceConversationId,
            messageId: messageId,
            attachmentId: attachmentId,
            localFile: url,
            durationHint: nil
        )
    }

    private var isCurrent: Bool { playback.isCurrent(item) }
    private var isPlaying: Bool { isCurrent && playback.isPlaying }
    private var progress: Double { isCurrent ? playback.progress : 0 }

    private var samples: [Float] {
        if waveform.isEmpty {
            return Array(repeating: 0.25, count: 64)
        }
        return waveform
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.6) : Color.white
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.3) : Color.green.opacity(0.2)
    }

    private var durationText: String {
        let duration = isCurrent ? playback.duration : 0
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var currentText: String {
        let current = isCurrent ? playback.currentTime : 0
        guard current.isFinite, current > 0 else { return "00:00" }
        let minutes = Int(current) / 60
        let seconds = Int(current) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var playbackLabel: String {
        isPlaying ? currentText + "/" + durationText : durationText
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle(item)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.green))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isPlaying
                    ? String(localized: "content.accessibility.voice_pause")
                    : String(localized: "content.accessibility.voice_play")
            )

            WaveformView(
                samples: samples,
                playbackProgress: progress,
                sendProgress: sendProgress,
                onSeek: { fraction in
                    if !isCurrent { playback.play(item) }
                    playback.seek(fraction: fraction)
                },
                isInteractive: true
            )
            .accessibilityLabel(String(localized: "content.accessibility.voice_seek"))

            Text(playbackLabel)
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .foregroundColor(Color.secondary)

            if let onCancel = onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(backgroundColor)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: 1)
        )
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await withCheckedContinuation { continuation in
                WaveformCache.shared.waveform(for: url, completion: { bins in
                    waveform = bins
                    continuation.resume()
                })
            }
        }
        .onChange(of: url) { newValue in
            WaveformCache.shared.waveform(for: newValue, completion: { bins in
                self.waveform = bins
            })
            // Intentionally do not stop the app-scoped session on URL remaps
            // while this row is offscreen — only update if this item is current.
            if isCurrent {
                playback.replaceURL(newValue)
            }
        }
        // Row disposal must never stop app-scoped playback.
    }
}
