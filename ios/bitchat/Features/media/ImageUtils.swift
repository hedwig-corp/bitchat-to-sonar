import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum ImageUtilsError: Error {
    case invalidImage
    case encodingFailed
}

enum ImageUtils {
    /// Longest edge for an image carried by the bitchat BLE file packet.
    /// 1600 px still reads as a photo (and keeps screenshot text legible) in a
    /// 3x phone bubble; the transcript decodes thumbnails at 1024 px, so this
    /// leaves headroom for the full-screen viewer without paying for pixels
    /// nobody sees.
    static let meshMaxDimension: CGFloat = 1600
    /// Floor for the downscale ladder — a photo that cannot reach
    /// `maxImageBytes` at this edge is not worth sending over BLE at all.
    private static let meshMinDimension: CGFloat = 640
    private static let maxCompressionQuality: CGFloat = 0.85
    private static let minCompressionQuality: CGFloat = 0.6
    private static let compressionQualityStep: CGFloat = 0.05
    /// Soft budget: stop compressing once the JPEG fits here. Well under
    /// `FileTransferLimits.maxImageBytes` because BLE fragments are
    /// fire-and-forget (no retransmit), so a shorter train is a likelier
    /// delivery.
    private static let targetImageBytes: Int = 320_000
    /// Hard ceiling the file packet enforces; over this the send is rejected.
    private static var hardLimitBytes: Int { FileTransferLimits.maxImageBytes }
    /// Source ceiling. The URL path downsamples through ImageIO, so a large
    /// original never materialises as a full ARGB bitmap.
    private static let maxSourceBytes: Int = 32 * 1024 * 1024

    static func processImage(at url: URL, maxDimension: CGFloat = meshMaxDimension) throws -> URL {
        // Security H1: Check file size BEFORE reading into memory
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attrs[.size] as? Int else {
            throw ImageUtilsError.invalidImage
        }
        guard fileSize <= maxSourceBytes else {
            throw ImageUtilsError.invalidImage
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageUtilsError.invalidImage
        }
        let jpegData = try compressToMeshBudget(startingDimension: maxDimension) { dimension in
            downsampled(source, maxDimension: dimension)
        }
        let outputURL = try makeOutputURL()
        try jpegData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    /// Bounded decode: ImageIO scales while decoding instead of materialising
    /// the full-resolution bitmap first. `WithTransform` bakes in the EXIF
    /// orientation, which the re-encode below then drops along with the rest
    /// of the metadata.
    private static func downsampled(_ source: CGImageSource, maxDimension: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Encode at the largest edge and quality that fit the mesh budget: drop
    /// quality first (cheap, keeps detail), and only then halve the edge.
    /// Returns the smallest JPEG produced when nothing fits — the caller still
    /// enforces `FileTransferLimits.maxImageBytes` and can fall back.
    private static func compressToMeshBudget(
        startingDimension: CGFloat,
        render: (CGFloat) -> CGImage?
    ) throws -> Data {
        var dimension = max(meshMinDimension, startingDimension)
        var best: Data?
        while true {
            guard let cgImage = render(dimension) else { break }
            var quality = maxCompressionQuality
            while true {
                guard let encoded = autoreleasepool(invoking: {
                    encodeJPEG(from: cgImage, quality: quality)
                }) else { break }
                best = encoded
                if encoded.count <= targetImageBytes { return encoded }
                if quality <= minCompressionQuality { break }
                quality = max(minCompressionQuality, quality - compressionQualityStep)
            }
            if let candidate = best, candidate.count <= hardLimitBytes { return candidate }
            if dimension <= meshMinDimension { break }
            dimension = max(meshMinDimension, dimension / 2)
        }
        guard let candidate = best else { throw ImageUtilsError.encodingFailed }
        return candidate
    }

    // Shared EXIF-stripping JPEG encoder for both iOS and macOS
    private static func encodeJPEG(from cgImage: CGImage, quality: CGFloat) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0) else {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        // Security: Strip ALL metadata (EXIF, GPS, TIFF, IPTC, XMP)
        // By only specifying compression quality and no metadata keys,
        // we ensure a clean JPEG with no privacy-leaking information
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = meshMaxDimension) throws -> URL {
        return try autoreleasepool {
            let jpegData = try compressToMeshBudget(startingDimension: maxDimension) { dimension in
                // Draw into a new context to get a clean CGImage without metadata
                scaledImage(image, maxDimension: dimension).cgImage
            }
            let outputURL = try makeOutputURL()
            try jpegData.write(to: outputURL, options: .atomic)
            return outputURL
        }
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rendered ?? image
    }
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = meshMaxDimension) throws -> URL {
        return try autoreleasepool {
            let jpegData = try compressToMeshBudget(startingDimension: maxDimension) { dimension in
                redrawn(scaledImage(image, maxDimension: dimension))
            }
            let outputURL = try makeOutputURL()
            try jpegData.write(to: outputURL, options: .atomic)
            return outputURL
        }
    }

    /// Redraw into a fresh sRGB context so the encoded JPEG carries no
    /// metadata from the original representation.
    private static func redrawn(_ image: NSImage) -> CGImage? {
        guard let inputCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: inputCG.width,
            height: inputCG.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(inputCG, in: CGRect(x: 0, y: 0, width: inputCG.width, height: inputCG.height))
        return context.makeImage()
    }

    private static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }
    #endif

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "img_\(formatter.string(from: Date())).jpg"

        let directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent(fileName)
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }
}
