//
// MeshStickerContentTests.swift
// bitchatTests
//

import XCTest
import SonarCore
@testable import Sonar

final class MeshStickerContentTests: XCTestCase {
    func testRoundTrip() {
        let encoded = SonarCore.meshStickerContent(
            packCoordinate: "30030:abc123:pack",
            shortcode: "wave",
            plaintextSha256: "deadbeef"
        )
        let decoded = SonarCore.meshParseStickerContent(content: encoded)

        XCTAssertEqual(decoded?.packCoordinate, "30030:abc123:pack")
        XCTAssertEqual(decoded?.shortcode, "wave")
        XCTAssertEqual(decoded?.plaintextSha256, "deadbeef")
    }

    func testRejectsPlainText() {
        XCTAssertNil(SonarCore.meshParseStickerContent(content: "hello world"))
        XCTAssertNil(SonarCore.meshParseStickerContent(content: ""))
        XCTAssertNil(SonarCore.meshParseStickerContent(content: "sticker:fake"))
    }
}
