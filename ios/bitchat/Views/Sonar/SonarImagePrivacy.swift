//
// SonarImagePrivacy.swift
// bitchat
//
// Strip location, device and time metadata from images before they are sent.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreGraphics
import Foundation
import ImageIO
import SonarCore
import UniformTypeIdentifiers

/// What a send path may do with a file that may be an image.
enum SNImageSendDecision: Equatable, Sendable {
    /// Send these bytes under this name and MIME type.
    case send(Data, filename: String, mime: String)
    /// An image whose metadata could not be removed: it is never sent.
    case refused
}

/// Remove location, device and time metadata from a file before it leaves the
/// device — the counterpart of Compose `imageBytesForSend`. Called where bytes
/// enter a send path (`snReadAttachments` for files, drag-drop and the share
/// sheet; the picker's GIFs), so the echo, caches and retries hold the clean
/// copy.
///
/// The core recognizes images by their bytes, so a photo sent as a file is
/// cleaned too and every other file passes through untouched. JPEG, PNG, GIF
/// and WebP are cleaned in place: pixels and animation stay as they were. What
/// the core cannot rewrite (HEIC, AVIF, TIFF) or parse is re-encoded to an
/// upright JPEG; if ImageIO cannot decode it either, it is refused rather than
/// sent as-is. CPU-bound: call it off the main actor.
func snImageBytesForSend(
    _ data: Data,
    filename: String,
    mime: String,
    scrub: (Data) -> ImageMetadataScrub = { scrubImageMetadata(data: $0) },
    reencode: (Data) -> Data? = { snReencodeImageToJpeg($0) }
) -> SNImageSendDecision {
    switch scrub(data) {
    case .notImage, .clean:
        return .send(data, filename: filename, mime: mime)
    case .stripped(let clean):
        return .send(clean, filename: filename, mime: mime)
    case .reencode:
        guard let encoded = reencode(data) else { return .refused }
        // ImageIO writes no metadata for a bare CGImage, but the guarantee is
        // the scrub, not the encoder: check the re-encoded copy too.
        switch scrub(encoded) {
        case .clean:
            return .send(encoded, filename: snJpegFilename(filename), mime: "image/jpeg")
        case .stripped(let clean):
            return .send(clean, filename: snJpegFilename(filename), mime: "image/jpeg")
        case .notImage, .reencode:
            return .refused
        }
    }
}

/// `IMG_0001.HEIC` → `IMG_0001.jpg`; a name without an extension gains one.
func snJpegFilename(_ filename: String) -> String {
    let stem: Substring
    if let dot = filename.lastIndex(of: "."), dot != filename.startIndex {
        stem = filename[..<dot]
    } else {
        stem = Substring(filename)
    }
    return "\(stem.trimmingCharacters(in: .whitespaces).isEmpty ? "photo" : String(stem)).jpg"
}

/// Decode anything ImageIO reads (HEIC, AVIF, TIFF, WebP…) and encode an
/// upright JPEG with no metadata. The thumbnail call applies EXIF orientation
/// and HEIF transforms at full size; a bare `CGImage` carries no properties.
/// Works on iOS and macOS alike.
func snReencodeImageToJpeg(_ data: Data, quality: CGFloat = 0.85) -> Data? {
    guard let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { return nil }
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
