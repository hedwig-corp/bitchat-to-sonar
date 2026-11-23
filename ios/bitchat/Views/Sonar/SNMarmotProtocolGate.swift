import SwiftUI

// Marmot v1 → v2 flag day (MDK 0.8 → v0.14). Core classifies each contact from
// their KeyPackages and refuses a send nobody in the chat can read any more
// (`core/sonar-core/src/marmot_protocol.rs`); this is what the chat screens on
// iPhone and Mac show for its answer. Mirror of the Compose
// `MarmotProtocolGate.kt`.

/// What a chat's composer area shows.
enum SNComposerGate: Equatable, Hashable {
    /// Normal composer, no note.
    case open
    /// Every other member moved: the composer is replaced by the update panel.
    case updateRequired
    /// Some group members moved: a note above the transcript, composer stays.
    case partlyUpdated(count: Int)
}

/// The screens' decision. A mesh-folded chat with a live Bluetooth link sends
/// over BLE, which the Marmot version does not touch, so it stays open; out of
/// range it falls back to Marmot and is gated like a pure Marmot chat.
func snComposerGate(_ gate: MarmotService.MarmotChatGate?, sendsOverMesh: Bool) -> SNComposerGate {
    guard let gate, !sendsOverMesh else { return .open }
    switch gate {
    case .open:
        return .open
    case .blocked:
        return .updateRequired
    case .partlyUpdated(let updated):
        return .partlyUpdated(count: updated.count)
    }
}

enum SNMarmotGateCopy {
    static func updateRequired(_ name: String) -> String {
        "\(name) has updated Sonar. Update the app to keep chatting"
    }

    static func partlyUpdatedBold(_ count: Int) -> String {
        count == 1 ? "1 member has updated Sonar" : "\(count) members have updated Sonar"
    }

    static let partlyUpdatedRest = " — they can't read new messages until you update the app"
}

/// Where this build gets its updates. iPhone and Mac both ship through the
/// same TestFlight group (web/src/lib/links.js).
enum SNAppUpdate {
    static let url = URL(string: "https://testflight.apple.com/join/7pr7S9Me")!
}

/// Stands in for the composer when the gate is `.updateRequired` (Signal's
/// pattern for a recipient you can no longer message: the input is replaced,
/// not just disabled, so no media, sticker or voice path is left).
struct SNMarmotComposerSlot<Composer: View>: View {
    let gate: SNComposerGate
    let peerName: String
    let onUpdate: () -> Void
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        if gate == .updateRequired {
            SNMarmotUpdateRequiredPanel(peerName: peerName, onUpdate: onUpdate)
        } else {
            composer()
        }
    }
}

struct SNMarmotUpdateRequiredPanel: View {
    let peerName: String
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(verbatim: SNMarmotGateCopy.updateRequired(peerName))
                .font(SonarTheme.uiFont(size: 14))
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Button(action: onUpdate) {
                Text("Update Sonar")
                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                    .foregroundColor(SonarTheme.onNet)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 18)
                    .background(Capsule().fill(SonarTheme.netFill))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("marmot-update-required")
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
        .accessibilityElement(children: .contain)
    }
}
