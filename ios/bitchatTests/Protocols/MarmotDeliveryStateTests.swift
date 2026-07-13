//
// MarmotDeliveryStateTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

@MainActor
struct MarmotDeliveryStateTests {
    private func message(
        id: String = "canonical-message",
        isMine: Bool = true,
        deliveryState: String?,
        media: [MarmotService.MarmotMedia] = []
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: id,
            senderNpub: "npub1sender",
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 100),
            isMine: isMine,
            deliveryState: deliveryState,
            media: media
        )
    }

    private var image: MarmotService.MarmotMedia {
        MarmotService.MarmotMedia(
            url: "https://blossom.test/image",
            mimeType: "image/jpeg",
            filename: "image.jpg",
            width: nil,
            height: nil,
            durationMs: nil
        )
    }

    @Test
    func coreDeliveryTransitionsRenderWithoutRelayEcho() {
        #expect(MarmotChatModel.stateText(for: message(deliveryState: "pending")) == "Sending")
        #expect(MarmotChatModel.stateText(for: message(deliveryState: "sent")) == "Sent")
        #expect(MarmotChatModel.stateText(for: message(deliveryState: "failed")) == "Couldn't send")
    }

    @Test
    func pendingMediaUsesUploadingLabel() {
        #expect(
            MarmotChatModel.stateText(
                for: message(deliveryState: "pending", media: [image])
            ) == "Uploading"
        )
    }

    @Test
    func localEchoAndIncomingRowsKeepTheirExistingSemantics() {
        #expect(
            MarmotChatModel.stateText(
                for: message(id: "optimistic-local", deliveryState: nil)
            ) == "Sending"
        )
        #expect(MarmotChatModel.stateText(for: message(isMine: false, deliveryState: "received")) == nil)
    }
}
