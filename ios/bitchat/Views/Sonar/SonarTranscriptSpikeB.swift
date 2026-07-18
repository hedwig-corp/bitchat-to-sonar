//
// SonarTranscriptSpikeB.swift
// bitchat
//
// Spike B — Signal-Android reverse / stack-from-end short-feed host.
// Distinct from Spike A (top-aligned Signal-iOS). Does not rewrite SNMsgList.
//
// Enable (DEBUG only):
//   UserDefaults.standard.set(true, forKey: SonarTranscriptSpikeB.userDefaultsKey)
//   — or open Settings → Developer → "Transcript Spike B"
//   — or flip SonarTranscriptSpikeB.forceEnableInDebug while iterating
//
// This is free and unencumbered software released into the public domain.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Feature flag + entry points for Spike B. Release always disabled.
enum SonarTranscriptSpikeB {
    static let userDefaultsKey = "SONAR_TRANSCRIPT_SPIKE_B"

    /// Local iteration latch. Keep false in shared WIP.
    static let forceEnableInDebug = false

    static var isEnabled: Bool {
        #if DEBUG
        if forceEnableInDebug { return true }
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: userDefaultsKey)
        }
        return false
        #else
        return false
        #endif
    }

    static var entryVisible: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

struct SpikeBMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let mine: Bool
    var isUnreadAnchor: Bool = false
}

enum SpikeBTailPinAction: Equatable {
    case none
    case snap
    case animate
}

/// R-009-shaped latch for inverted / newest-at-0 lists. "Tail" = newest = index 0.
struct SNTailPinLatchSpikeB {
    private(set) var wasPinned = false
    private(set) var lastItemCount = 0

    mutating func tailVisible(itemCount: Int) {
        wasPinned = true
        lastItemCount = itemCount
    }

    mutating func openInHistory(itemCount: Int) {
        wasPinned = false
        lastItemCount = itemCount
    }

    mutating func userScrolled(isNearTail: Bool) {
        if !isNearTail { wasPinned = false }
    }

    mutating func viewportShrank(userScrolling: Bool, isPrepending: Bool) -> SpikeBTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    mutating func viewportExpanded(userScrolling: Bool, isPrepending: Bool) -> SpikeBTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    mutating func itemsChanged(
        itemCount: Int,
        appendedAtTail: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SpikeBTailPinAction {
        lastItemCount = itemCount
        if isPrepending || userScrolling {
            wasPinned = false
            return .none
        }
        guard wasPinned, appendedAtTail else { return .none }
        return .animate
    }

    private mutating func viewportResized(userScrolling: Bool, isPrepending: Bool) -> SpikeBTailPinAction {
        if userScrolling || isPrepending {
            wasPinned = false
            return .none
        }
        return wasPinned ? .snap : .none
    }
}

/// Newest-first feed (index 0 = newest / visual bottom under inverted table).
func spikeBBuildReverseFeed(
    chronologicalOldestFirst: [SpikeBMessage],
    unreadFromNewest: Int
) -> [SpikeBMessage] {
    guard !chronologicalOldestFirst.isEmpty else { return [] }
    let newestFirst = Array(chronologicalOldestFirst.reversed())
    guard unreadFromNewest > 0 else {
        return newestFirst.map {
            var copy = $0
            copy.isUnreadAnchor = false
            return copy
        }
    }
    var remaining = unreadFromNewest
    var anchorID: String?
    for m in newestFirst where !m.mine {
        remaining -= 1
        if remaining == 0 {
            anchorID = m.id
            break
        }
    }
    return newestFirst.map {
        var copy = $0
        copy.isUnreadAnchor = ($0.id == anchorID)
        return copy
    }
}

func spikeBInitialScrollIndex(unreadAnchorIndex: Int, itemCount: Int) -> Int {
    guard itemCount > 0 else { return 0 }
    if unreadAnchorIndex >= 0 && unreadAnchorIndex < itemCount { return unreadAnchorIndex }
    return 0
}

/// Inverted table: visual top ≈ high indices. Load older near that edge.
func spikeBShouldLoadOlder(
    didInitialScroll: Bool,
    totalItems: Int,
    highestVisibleIndex: Int,
    edgeSlop: Int = 2
) -> Bool {
    guard didInitialScroll, totalItems > 0 else { return false }
    return highestVisibleIndex >= max(0, totalItems - 1 - edgeSlop)
}

#if os(iOS)

/// Isolated Spike B demo: inverted UITableView + IME-attached composer sibling.
struct SonarTranscriptSpikeBDemo: View {
    var onClose: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case shortRead = "Short"
        case unreadOpen = "Unread"
        case longHistory = "Long"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .shortRead
    @State private var rows: [SpikeBMessage] = []
    @State private var draft: String = ""
    @State private var olderPage = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Text("←")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(SonarTheme.surface2)
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript Spike B")
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                    Text("inverted table · newest@0 · stack-from-end")
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text2)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(SonarTheme.hairline).frame(height: 1)

            HStack(spacing: 8) {
                ForEach(Mode.allCases) { m in
                    modeChip(m)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Text(
                "Short: messages sit on composer. Unread: divider at viewport top. Long: load-older toward visual top."
            )
            .font(SonarTheme.uiFont(size: 11))
            .foregroundColor(SonarTheme.text3)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            SpikeBInvertedTable(
                rows: rows,
                reloadToken: mode.rawValue,
                onLoadOlder: {
                    guard mode == .longHistory, olderPage < 2 else { return }
                    olderPage += 1
                    let older = spikeBOlderPage(olderPage)
                    let chrono = older + rows.reversed().map {
                        SpikeBMessage(id: $0.id, text: $0.text, mine: $0.mine)
                    }
                    rows = spikeBBuildReverseFeed(
                        chronologicalOldestFirst: chrono,
                        unreadFromNewest: 0
                    )
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField("Spike B composer · IME attached", text: $draft)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(minHeight: 36)
                    .background(SonarTheme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .focused($composerFocused)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    rows.insert(
                        SpikeBMessage(id: "out-\(rows.count)", text: text, mine: true),
                        at: 0
                    )
                } label: {
                    Text("↑")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(draft.isEmpty ? SonarTheme.text3 : SonarTheme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(draft.isEmpty ? SonarTheme.surface2 : SonarTheme.accentFill)
                        .clipShape(Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear { reload(mode) }
    }

    private func modeChip(_ m: Mode) -> some View {
        Button {
            reload(m)
        } label: {
            Text(m.rawValue)
                .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                .foregroundColor(mode == m ? SonarTheme.onAccent : SonarTheme.text2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(mode == m ? SonarTheme.accentFill : SonarTheme.surface2)
                .clipShape(Capsule())
        }
    }

    private func reload(_ next: Mode) {
        mode = next
        olderPage = 0
        let seed = spikeBSeedMessages()
        let unread = next == .unreadOpen ? 3 : 0
        let base: [SpikeBMessage]
        switch next {
        case .shortRead, .unreadOpen: base = Array(seed.suffix(5))
        case .longHistory: base = seed
        }
        rows = spikeBBuildReverseFeed(chronologicalOldestFirst: base, unreadFromNewest: unread)
    }
}

/// UIKit inverted table — position 0 / newest at the visual bottom (stack-from-end).
struct SpikeBInvertedTable: UIViewRepresentable {
    let rows: [SpikeBMessage]
    /// Bumps when the demo mode changes so open/unread scroll re-runs.
    var reloadToken: String
    var onLoadOlder: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadOlder: onLoadOlder)
    }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.transform = CGAffineTransform(scaleX: 1, y: -1)
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.keyboardDismissMode = .interactive
        table.contentInsetAdjustmentBehavior = .never
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.register(SpikeBCell.self, forCellReuseIdentifier: SpikeBCell.reuseID)
        // Composer is a SwiftUI sibling ⇒ owned bottom inset stays 0 (R-009).
        table.contentInset = .zero
        table.scrollIndicatorInsets = .zero
        context.coordinator.tableView = table
        return table
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        let previous = context.coordinator.rows
        let oldTailID = previous.first?.id
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            context.coordinator.didInitialScroll = false
            context.coordinator.userLeftUnread = false
            context.coordinator.latch = SNTailPinLatchSpikeB()
        }
        context.coordinator.rows = rows
        context.coordinator.onLoadOlder = onLoadOlder
        tableView.reloadData()

        let unreadIndex = rows.firstIndex(where: { $0.isUnreadAnchor }) ?? -1
        let target = spikeBInitialScrollIndex(unreadAnchorIndex: unreadIndex, itemCount: rows.count)

        if !context.coordinator.didInitialScroll {
            context.coordinator.didInitialScroll = true
            if unreadIndex >= 0 {
                context.coordinator.latch.openInHistory(itemCount: rows.count)
                DispatchQueue.main.async {
                    guard !rows.isEmpty else { return }
                    tableView.scrollToRow(
                        at: IndexPath(row: target, section: 0),
                        at: .top,
                        animated: false
                    )
                }
            } else if !rows.isEmpty {
                context.coordinator.latch.tailVisible(itemCount: rows.count)
                DispatchQueue.main.async {
                    tableView.scrollToRow(
                        at: IndexPath(row: 0, section: 0),
                        at: .bottom,
                        animated: false
                    )
                }
            }
            return
        }

        let appendedAtTail = rows.first?.id != oldTailID && oldTailID != nil
        let action = context.coordinator.latch.itemsChanged(
            itemCount: rows.count,
            appendedAtTail: appendedAtTail,
            userScrolling: context.coordinator.isUserScrolling,
            isPrepending: context.coordinator.isPrepending
        )
        if action != .none, unreadIndex < 0 || context.coordinator.userLeftUnread {
            DispatchQueue.main.async {
                tableView.scrollToRow(
                    at: IndexPath(row: 0, section: 0),
                    at: .bottom,
                    animated: action == .animate
                )
            }
        }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var rows: [SpikeBMessage] = []
        var onLoadOlder: () -> Void
        var latch = SNTailPinLatchSpikeB()
        var didInitialScroll = false
        var isUserScrolling = false
        var isPrepending = false
        var userLeftUnread = false
        var reloadToken = ""
        weak var tableView: UITableView?
        private var lastViewportHeight: CGFloat = 0

        init(onLoadOlder: @escaping () -> Void) {
            self.onLoadOlder = onLoadOlder
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            rows.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: SpikeBCell.reuseID, for: indexPath) as! SpikeBCell
            // Un-flip cell content so text reads upright under the table transform.
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            cell.configure(rows[indexPath.row])
            return cell
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            if rows.contains(where: { $0.isUnreadAnchor }) {
                userLeftUnread = true
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll(scrollView)
        }

        private func finishUserScroll(_ scrollView: UIScrollView) {
            isUserScrolling = false
            let nearTail = scrollView.contentOffset.y <= 24
            latch.userScrolled(isNearTail: nearTail)
            if nearTail { latch.tailVisible(itemCount: rows.count) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard didInitialScroll, !rows.isEmpty else { return }
            let visible = tableView?.indexPathsForVisibleRows ?? []
            let highest = visible.map(\.row).max() ?? -1
            if spikeBShouldLoadOlder(
                didInitialScroll: didInitialScroll,
                totalItems: rows.count,
                highestVisibleIndex: highest
            ) {
                isPrepending = true
                onLoadOlder()
                isPrepending = false
            }

            // Keyboard / bounds shrink: re-pin when previously at tail.
            let height = scrollView.bounds.height
            if lastViewportHeight > 0, abs(height - lastViewportHeight) > 1 {
                let shrinking = height < lastViewportHeight
                let action = shrinking
                    ? latch.viewportShrank(userScrolling: isUserScrolling, isPrepending: isPrepending)
                    : latch.viewportExpanded(userScrolling: isUserScrolling, isPrepending: isPrepending)
                if action == .snap {
                    tableView?.scrollToRow(
                        at: IndexPath(row: 0, section: 0),
                        at: .bottom,
                        animated: false
                    )
                }
            }
            lastViewportHeight = height
        }
    }
}

private final class SpikeBCell: UITableViewCell {
    static let reuseID = "SpikeBCell"

    private let bubble = UILabel()
    private let divider = UILabel()
    private var mineConstraint: NSLayoutConstraint?
    private var peerConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.text = "— Unread messages —"
        divider.font = .systemFont(ofSize: 11.5, weight: .semibold)
        divider.textColor = UIColor.secondaryLabel
        divider.textAlignment = .center
        divider.isHidden = true

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.numberOfLines = 0
        bubble.font = .systemFont(ofSize: 15)
        bubble.layer.cornerRadius = 16
        bubble.clipsToBounds = true

        contentView.addSubview(divider)
        contentView.addSubview(bubble)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            bubble.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
        ])
        mineConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14)
        peerConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(_ message: SpikeBMessage) {
        bubble.text = "  \(message.text)  "
        divider.isHidden = !message.isUnreadAnchor
        if message.mine {
            bubble.backgroundColor = UIColor.systemTeal
            bubble.textColor = .white
            peerConstraint?.isActive = false
            mineConstraint?.isActive = true
        } else {
            bubble.backgroundColor = UIColor.secondarySystemBackground
            bubble.textColor = .label
            mineConstraint?.isActive = false
            peerConstraint?.isActive = true
        }
    }
}

private func spikeBSeedMessages() -> [SpikeBMessage] {
    (0..<40).map { i in
        SpikeBMessage(
            id: "seed-\(i)",
            text: i % 3 == 0 ? "Peer note #\(i) — longer line to exercise wrap." : "Msg #\(i)",
            mine: i % 2 == 0
        )
    }
}

private func spikeBOlderPage(_ page: Int) -> [SpikeBMessage] {
    let base = page * 20
    return (0..<20).map { i in
        let n = base + i
        return SpikeBMessage(id: "older-\(n)", text: "Older page \(page) · #\(n)", mine: n % 2 == 0)
    }
}

#endif

#if os(macOS)
/// macOS stub — Spike B UIKit host is iOS-only; Settings entry stays hidden via entryVisible.
struct SonarTranscriptSpikeBDemo: View {
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("Transcript Spike B is an iOS UIKit host in this spike.")
                .foregroundColor(SonarTheme.text2)
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SonarTheme.bg)
    }
}
#endif
