//
// VideoLocationStripTests.swift
// bitchatTests
//
// The Photos picker hands over the original video ("Location Is Included"),
// and a video under the size cap used to be sent byte-for-byte — so a clip
// recorded with Location Services on told the recipient where it was shot.
// Photos never had this leak: they are re-encoded through `UIImage`.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Sonar

@Suite(.serialized)
struct VideoLocationStripTests {
    /// A 10-frame 64x64 H.264 QuickTime movie, optionally tagged with an
    /// ISO 6709 location the way an iPhone camera tags it.
    private func makeVideo(withLocation: Bool) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoLocationStripTests-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        if withLocation {
            let location = AVMutableMetadataItem()
            location.identifier = .quickTimeMetadataLocationISO6709
            location.value = "+46.0037+008.9511+273.000/" as NSString
            location.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [location]
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func asset(from data: Data, ext: String) throws -> (AVURLAsset, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoLocationStripTests-out-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return (AVURLAsset(url: url), url)
    }

    @Test
    func aVideoRecordedWithLocationIsSentWithoutIt() async throws {
        let source = try await makeVideo(withLocation: true)
        #expect(await SonarAppStore.videoCarriesLocation(AVURLAsset(url: source)), "fixture must carry a location")

        let result = await SonarAppStore.finalizeVideoForSend(source, filename: "clip.mov", mime: "video/quicktime")
        guard case let .ready(data, filename, mime) = result else {
            Issue.record("expected a sendable video, got \(result)")
            return
        }
        // Passthrough remux: same container, name and type as picked.
        #expect(filename == "clip.mov")
        #expect(mime == "video/quicktime")

        let (sent, sentURL) = try asset(from: data, ext: "mov")
        defer { try? FileManager.default.removeItem(at: sentURL) }
        #expect(await SonarAppStore.videoCarriesLocation(sent) == false)
        let tracks = try await sent.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1, "the picture must survive the remux")
    }

    @Test
    func aVideoWithoutLocationIsSentByteForByte() async throws {
        let source = try await makeVideo(withLocation: false)
        let original = try Data(contentsOf: source)

        let result = await SonarAppStore.finalizeVideoForSend(source, filename: "clip.mov", mime: "video/quicktime")
        guard case let .ready(data, filename, _) = result else {
            Issue.record("expected a sendable video, got \(result)")
            return
        }
        #expect(data == original, "no location to strip: keep the zero-cost passthrough")
        #expect(filename == "clip.mov")
    }
}
