//
// ImageMetadataStripTests.swift
// bitchatTests
//
// A photo sent from the picker was re-encoded through `UIImage` and lost its
// metadata, but a photo sent as a file, dropped onto the Mac window, shared
// from Photos, or picked on macOS went out byte for byte, GPS and camera
// serial included. `snImageBytesForSend` closes every path; these tests read
// the sent bytes back through ImageIO, the same way a recipient would.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Sonar

struct ImageMetadataStripTests {
    /// A 24×16 image tagged the way a phone camera tags a photo.
    private func makeImage(_ type: UTType, orientation: Int = 6) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 16))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "LEAKMAKE",
                kCGImagePropertyTIFFModel: "LEAKMODEL",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "LEAKCOMMENT",
                kCGImagePropertyExifBodySerialNumber: "LEAKSERIAL",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 45.504,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 9.191,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func hasGPS(_ data: Data) throws -> Bool {
        try properties(data)[kCGImagePropertyGPSDictionary] != nil
    }

    private func contains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    private func sent(_ decision: SNImageSendDecision) throws -> (Data, String, String) {
        guard case let .send(data, filename, mime) = decision else {
            Issue.record("expected the image to be sent, got \(decision)")
            throw CancellationError()
        }
        return (data, filename, mime)
    }

    @Test func aJpegLosesGPSAndDeviceButStaysUpright() throws {
        let original = try makeImage(.jpeg)
        #expect(try hasGPS(original))
        #expect(contains(original, "LEAKMAKE"))

        let (data, filename, mime) = try sent(snImageBytesForSend(original, filename: "IMG_0001.JPG", mime: "image/jpeg"))
        #expect(try !hasGPS(data))
        #expect(!contains(data, "LEAK"))
        #expect(try properties(data)[kCGImagePropertyOrientation] as? Int == 6)
        // Cleaned in place: still the user's file, not a re-encode.
        #expect(filename == "IMG_0001.JPG")
        #expect(mime == "image/jpeg")
    }

    @Test func aPngLosesGPS() throws {
        let original = try makeImage(.png)
        #expect(try hasGPS(original))

        let (data, _, mime) = try sent(snImageBytesForSend(original, filename: "shot.png", mime: "image/png"))
        #expect(try !hasGPS(data))
        #expect(!contains(data, "LEAK"))
        #expect(mime == "image/png")
    }

    @Test func aTiffIsReencodedToAnUprightJpeg() throws {
        let original = try makeImage(.tiff)
        #expect(try hasGPS(original))

        let (data, filename, mime) = try sent(snImageBytesForSend(original, filename: "scan.tiff", mime: "image/tiff"))
        #expect(try !hasGPS(data))
        #expect(!contains(data, "LEAK"))
        #expect(filename == "scan.jpg")
        #expect(mime == "image/jpeg")
        // Orientation 6 is baked into the pixels: 24×16 becomes 16×24.
        let props = try properties(data)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 16)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 24)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func anImageNothingCanDecodeIsRefused() {
        // Looks like a TIFF to the core, so it must be re-encoded; ImageIO
        // cannot decode it, so it is never sent.
        let bogus = Data("MM\0*not really a tiff LEAKMAKE".utf8)
        #expect(snImageBytesForSend(bogus, filename: "x.tiff", mime: "image/tiff") == .refused)
    }

    @Test func otherFilesAreUntouched() throws {
        let pdf = Data("%PDF-1.7\n%LEAK\n".utf8)
        let (data, filename, mime) = try sent(snImageBytesForSend(pdf, filename: "a.pdf", mime: "application/pdf"))
        #expect(data == pdf)
        #expect(filename == "a.pdf")
        #expect(mime == "application/pdf")
    }

    /// The real call site: Send file, Mac drag-drop and the share sheet all
    /// read through `snReadAttachments`.
    @Test func aPhotoSentAsAFileLosesItsLocation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageMetadataStripTests-\(UUID().uuidString).jpg")
        try makeImage(.jpeg).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = snReadAttachments([url], maxTotalBytes: 1 << 20)
        let attachment = try #require(result.attachments.first)
        #expect(result.rejectedCount == 0)
        #expect(try !hasGPS(attachment.data))
        #expect(!contains(attachment.data, "LEAK"))
    }

    @Test func jpegNames() {
        #expect(snJpegFilename("IMG_0001.HEIC") == "IMG_0001.jpg")
        #expect(snJpegFilename("scan.page.tiff") == "scan.page.jpg")
        #expect(snJpegFilename("photo") == "photo.jpg")
        #expect(snJpegFilename(".hidden") == ".hidden.jpg")
        #expect(snJpegFilename("") == "photo.jpg")
    }
}
