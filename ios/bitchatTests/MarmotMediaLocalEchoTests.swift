#if os(iOS)
import Testing
import UIKit
@testable import Sonar

/// QA-A11: an optimistic upload echo built with nil width/height reserved the
/// max media box, then collapsed to the real aspect when the canonical MIP-04
/// row replaced it. The echo must carry the dimensions of the bytes it shows.
struct MarmotMediaLocalEchoTests {
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test
    func imageEchoCarriesPixelDimensions() {
        let media = MarmotService.MarmotMedia.localEcho(
            url: "pending-media-x",
            mimeType: "image/png",
            filename: "photo.png",
            data: png(width: 500, height: 230)
        )
        #expect(media.width == 500)
        #expect(media.height == 230)
    }

    @Test
    func nonImageEchoHasNoDimensions() {
        let media = MarmotService.MarmotMedia.localEcho(
            url: "pending-media-x",
            mimeType: "video/mp4",
            filename: "clip.mp4",
            data: png(width: 10, height: 10)
        )
        #expect(media.width == nil)
        #expect(media.height == nil)
    }

    @Test
    func undecodableImageBytesDegradeToNoDimensions() {
        let media = MarmotService.MarmotMedia.localEcho(
            url: "pending-media-x",
            mimeType: "image/jpeg",
            filename: "broken.jpg",
            data: Data("not an image".utf8)
        )
        #expect(media.width == nil)
        #expect(media.height == nil)
    }
}
#endif
