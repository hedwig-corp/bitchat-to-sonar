import CoreGraphics
import Testing
@testable import Sonar

/// Fitted sheets hug short content, cap long content at `maxHeight`, and
/// never exceed what the parent offers (keyboard up, landscape, short window):
/// a fixed height pushed the bottom-aligned sheet's title off screen.
struct SNFittedSheetHeightTests {
    @Test
    func shortContentHugs() {
        #expect(snFittedSheetHeight(content: 300, maxHeight: 560, available: 800) == 300)
    }

    @Test
    func longContentCapsAtMax() {
        #expect(snFittedSheetHeight(content: 900, maxHeight: 560, available: 800) == 560)
    }

    @Test
    func aSmallerOfferWins() {
        // Keyboard up: 250 pt left for a 400 pt body — it must scroll, not overflow.
        #expect(snFittedSheetHeight(content: 400, maxHeight: 560, available: 250) == 250)
        #expect(snFittedSheetHeight(content: 0, maxHeight: 560, available: 250) == 250)
    }

    @Test
    func unmeasuredContentStartsAtTheCap() {
        #expect(snFittedSheetHeight(content: 0, maxHeight: 560, available: nil) == 560)
        #expect(snFittedSheetHeight(content: 0, maxHeight: 560, available: .infinity) == 560)
    }
}
