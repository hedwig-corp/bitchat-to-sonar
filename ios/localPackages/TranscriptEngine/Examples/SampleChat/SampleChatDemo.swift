#if canImport(UIKit) && !os(macOS)
import SwiftUI
import TranscriptEngine
import UIKit

/// SPM example: fake string rows via the generic TranscriptEngine UIKit host.
@MainActor
public enum SampleChatDemo {
    public static func makeViewController(messages: [String]) -> UIViewController {
        let entries = messages.enumerated().map { index, text in
            TranscriptHostEntry(
                id: "msg-\(index)",
                date: Date().addingTimeInterval(Double(index) * -3600)
            )
        }
        let textByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, messages[$0.offset]) })

        let callbacks = TranscriptCollectionHostCallbacks(
            configureCell: { _, cell, _, item in
                guard case .message(let id) = item, let text = textByID[id] else {
                    cell.contentConfiguration = UIListContentConfiguration.cell()
                    return
                }
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(verbatim: text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .margins(.all, 0)
                cell.backgroundConfiguration = .clear()
            },
            itemHeight: { item, key, width in
                switch item {
                case .unreadDivider: return 28
                case .message(let id):
                    let text = textByID[id] ?? ""
                    return max(44, CGFloat(text.count / 30 + 1) * 22)
                }
            },
            headerHeight: { _, _ in 32 }
        )

        let host = TranscriptCollectionHostView(
            entries: entries,
            heightKey: { item in
                switch item {
                case .unreadDivider: return "u"
                case .message(let id): return "m|\(id)"
                }
            },
            callbacks: callbacks,
            composer: {
                Text("Type a message…")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
            }
        )
        return UIHostingController(rootView: host.ignoresSafeArea(.keyboard, edges: .bottom))
    }
}
#endif

#if !canImport(UIKit) || os(macOS)
/// macOS `swift test` / `swift build` stub — UIKit host is iOS-only.
public enum SampleChatDemo {}
#endif
