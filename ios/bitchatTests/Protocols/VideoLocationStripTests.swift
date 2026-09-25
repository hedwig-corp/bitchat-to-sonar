//
// VideoLocationStripTests.swift
// bitchatTests
//
// The Photos picker hands over the original video ("Location Is Included"),
// and a video under the size cap used to be sent byte-for-byte — so a clip
// recorded with Location Services on told the recipient where it was shot.
// Photos never had this leak: they are re-encoded through `UIImage`.
//
// A metadata check cannot gate a raw-bytes path either: AVFoundation reports
// asset-level location, but not a track's `udta` location or an XMP `uuid`
// box, so every video is remuxed. The tests look at the sent BYTES as well as
// at what AVFoundation reports.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Sonar

@Suite(.serialized)
struct VideoLocationStripTests {
    enum LocationTag { case none, asset, track }

    /// A 10-frame 64x64 H.264 QuickTime movie, optionally tagged with an
    /// ISO 6709 location: on the asset the way an iPhone camera tags it, or on
    /// the video track, where `AVAsset.metadata` never reports it.
    private func makeVideo(location: LocationTag) async throws -> URL {
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
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = Self.iso6709 as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        switch location {
        case .none: break
        case .asset: writer.metadata = [item]
        case .track: input.metadata = [item]
        }
        writer.add(input)
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

    private static let iso6709 = "+46.0037+008.9511+273.000/"

    /// An XMP packet in a top-level `uuid` box (the XMP box UUID
    /// BE7ACFCB-97A9-42E8-9C71-999491E3AFAC), carrying EXIF GPS the way
    /// editing apps write it. Appended after the other boxes: still a valid file.
    private func appendXmpLocation(to url: URL) throws {
        let xmp = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        exif:GPSLatitude="46,0.222N" exif:GPSLongitude="8,57.066E"/></rdf:RDF></x:xmpmeta>
        """.utf8)
        let uuid: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
                             0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]
        let size = UInt32(8 + uuid.count + xmp.count)
        var box = Data()
        withUnsafeBytes(of: size.bigEndian) { box.append(contentsOf: $0) }
        box.append(contentsOf: Array("uuid".utf8))
        box.append(contentsOf: uuid)
        box.append(xmp)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: box)
    }

    /// Location visible anywhere a reader could find it: asset or track
    /// metadata as AVFoundation reports it, or the raw ISO 6709 string / XMP
    /// GPS fields in the bytes.
    private func carriesLocation(_ data: Data, ext: String) async throws -> Bool {
        if data.range(of: Data(Self.iso6709.utf8)) != nil { return true }
        if data.range(of: Data("GPSLatitude".utf8)) != nil { return true }
        let (sent, url) = try asset(from: data, ext: ext)
        defer { try? FileManager.default.removeItem(at: url) }
        var items = try await sent.load(.metadata)
        for track in try await sent.load(.tracks) {
            items += try await track.load(.metadata)
        }
        return items.contains { item in
            item.commonKey == .commonKeyLocation
                || item.identifier == .quickTimeMetadataLocationISO6709
                || item.identifier == .quickTimeUserDataLocationISO6709
        }
    }

    private func asset(from data: Data, ext: String) throws -> (AVURLAsset, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoLocationStripTests-out-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return (AVURLAsset(url: url), url)
    }

    /// Sends `source` as a picked .mov and returns the bytes that would go out,
    /// after checking the remux kept the container, name, type and picture.
    private func send(_ source: URL) async throws -> Data? {
        let result = await SonarAppStore.finalizeVideoForSend(source, filename: "clip.mov", mime: "video/quicktime")
        guard case let .ready(data, filename, mime) = result else {
            Issue.record("expected a sendable video, got \(result)")
            return nil
        }
        // Passthrough remux: same container, name and type as picked.
        #expect(filename == "clip.mov")
        #expect(mime == "video/quicktime")
        let (sent, sentURL) = try asset(from: data, ext: "mov")
        defer { try? FileManager.default.removeItem(at: sentURL) }
        let tracks = try await sent.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1, "the picture must survive the remux")
        return data
    }

    @Test
    func aVideoRecordedWithLocationIsSentWithoutIt() async throws {
        let source = try await makeVideo(location: .asset)
        #expect(try await carriesLocation(Data(contentsOf: source), ext: "mov"), "fixture must carry a location")
        let data = try #require(try await send(source))
        #expect(try await carriesLocation(data, ext: "mov") == false)
    }

    /// Track-level location is invisible to `AVAsset.metadata`: a check on it
    /// alone let this file through byte-for-byte.
    @Test
    func trackLevelLocationIsStripped() async throws {
        let source = try await makeVideo(location: .track)
        #expect(try await carriesLocation(Data(contentsOf: source), ext: "mov"), "fixture must carry a location")
        let data = try #require(try await send(source))
        #expect(try await carriesLocation(data, ext: "mov") == false)
    }

    /// XMP GPS in a `uuid` box is not surfaced as metadata at all.
    @Test
    func xmpLocationIsStripped() async throws {
        let source = try await makeVideo(location: .none)
        try appendXmpLocation(to: source)
        #expect(try await carriesLocation(Data(contentsOf: source), ext: "mov"), "fixture must carry a location")
        let data = try #require(try await send(source))
        #expect(try await carriesLocation(data, ext: "mov") == false)
    }

    @Test
    func aVideoWithoutLocationIsStillSent() async throws {
        let source = try await makeVideo(location: .none)
        let data = try #require(try await send(source))
        #expect(try await carriesLocation(data, ext: "mov") == false)
    }

    /// A file AVFoundation cannot read is never sent as raw bytes: the
    /// remux and the re-encode both fail, so the send fails.
    @Test
    func unreadableMetadataFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoLocationStripTests-garbage-\(UUID().uuidString).mov")
        try Data("not a movie, but small enough for the fast path".utf8).write(to: url)
        let result = await SonarAppStore.finalizeVideoForSend(url, filename: "clip.mov", mime: "video/quicktime")
        if case .ready = result {
            Issue.record("an unreadable video must never be sent as raw bytes")
        }
    }
}
