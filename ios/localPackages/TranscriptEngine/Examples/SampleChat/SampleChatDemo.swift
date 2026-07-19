#if canImport(UIKit) && !os(macOS)
import SwiftUI
import TranscriptEngine
import UIKit

/// SPM example: fake string rows via the generic TranscriptEngine UIKit host.
/// Exercises LiveEdge and UnreadDivider open modes (shared golden contract).
@MainActor
public enum SampleChatDemo {
    public enum OpenMode: Sendable {
        case liveEdge
        /// Opens with an unread capture of `unreadCount` trailing rows.
        case unreadDivider(unreadCount: UInt64)
    }

    public static func makeViewController(
        messages: [String],
        openMode: OpenMode = .liveEdge
    ) -> UIViewController {
        let entries = messages.enumerated().map { index, _ in
            TranscriptHostEntry(
                id: "msg-\(index)",
                date: Date().addingTimeInterval(Double(index) * -3600)
            )
        }
        let textByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, messages[$0.offset]) })

        let unreadCount: UInt64? = {
            switch openMode {
            case .liveEdge: return 0
            case .unreadDivider(let count): return count
            }
        }()

        let callbacks = TranscriptCollectionHostCallbacks(
            configureCell: { _, cell, _, item in
                switch item {
                case .unreadDivider:
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text("Unread")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .margins(.all, 0)
                case .message(let id):
                    let text = textByID[id] ?? ""
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(verbatim: text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                    .margins(.all, 0)
                }
                cell.backgroundConfiguration = .clear()
            },
            itemHeight: { item, _, _ in
                switch item {
                case .unreadDivider: return 28
                case .message(let id):
                    let text = textByID[id] ?? ""
                    return max(44, CGFloat(text.count / 30 + 1) * 22)
                }
            },
            headerHeight: { _, _ in 32 },
            configureHeader: { _, header, _, label in
                header.contentConfiguration = UIHostingConfiguration {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity)
                }
                .margins(.all, 0)
                header.backgroundConfiguration = .clear()
            },
            unreadAnchorResolver: { entries, count in
                guard count > 0, !entries.isEmpty else { return nil }
                let offset = max(0, entries.count - Int(count))
                return entries[offset].id
            }
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
            unreadCountAtOpen: unreadCount,
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
public enum SampleChatDemo {
    public enum OpenMode: Sendable {
        case liveEdge
        case unreadDivider(unreadCount: UInt64)
    }
}
#endif
