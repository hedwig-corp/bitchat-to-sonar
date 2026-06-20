//
// SonarEmojiPickerView.swift
// bitchat
//
// Full tabbed emoji picker with categories, search, GIF placeholder, and
// sticker placeholder. Ported from the Compose Multiplatform SonarEmojiPicker.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import SonarCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct SonarEmojiPickerView: View {
    let onEmoji: (String) -> Void
    let onSticker: (StickerInfo, String) -> Void
    let loadStickerPack: (String, String, [String]) async -> StickerPackInfo?
    let loadStickerImage: (String, String) async -> Data?
    let onClose: () -> Void

    @State private var tab = 0
    @State private var search = ""
    @State private var category = 0

    private let tabs = ["Emoji", "GIF", "Sticker"]

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab bar ──
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, label in
                    Button {
                        tab = i
                    } label: {
                        Text(verbatim: label)
                            .font(SonarTheme.uiFont(size: 14, weight: i == tab ? .bold : .regular))
                            .foregroundColor(i == tab ? SonarTheme.accent : SonarTheme.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if i == tab {
                                    Rectangle()
                                        .fill(SonarTheme.accent)
                                        .frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onClose) {
                    SNIcon(name: .x, size: 16, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .background(SonarTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SonarTheme.hairline).frame(height: 1)
            }

            // ── Content ──
            switch tab {
            case 0: emojiTab
            case 1: placeholderTab("GIF search coming soon")
            default: StickerTabContent(
                onSticker: onSticker,
                loadPack: loadStickerPack,
                loadImage: loadStickerImage
            )
            }
        }
        .frame(height: 320)
        .background(SonarTheme.bg)
    }

    // MARK: - Emoji tab

    private var filteredEmojis: [String] {
        if search.isEmpty {
            return emojiCategories[category].emojis
        }
        let q = search.lowercased()
        return emojiCategories.flatMap(\.emojis).filter { emoji in
            emoji.unicodeScalars.contains { scalar in
                String(scalar).lowercased().contains(q)
            } || emoji == q
        }
    }

    private var emojiTab: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 8) {
                SNIcon(name: .search, size: 16, weight: 2)
                    .foregroundColor(SonarTheme.text3)
                TextField("", text: $search, prompt: Text("Search emoji").foregroundColor(SonarTheme.text3))
                    .textFieldStyle(.plain)
                    .font(SonarTheme.uiFont(size: 14))
                    .foregroundColor(SonarTheme.text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 10))

            // Grid
            ScrollView {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(filteredEmojis, id: \.self) { emoji in
                        Button {
                            onEmoji(emoji)
                        } label: {
                            Text(verbatim: emoji)
                                .font(.system(size: 26))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(SNScaleStyle(scale: 0.90))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            // Category selector
            if search.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(emojiCategories.enumerated()), id: \.offset) { i, cat in
                            Button {
                                category = i
                            } label: {
                                Text(verbatim: cat.icon)
                                    .font(.system(size: 18))
                                    .frame(width: 36, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(i == category ? SonarTheme.accentSoft : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.bottom, 4)
                .background(SonarTheme.surface)
                .overlay(alignment: .top) {
                    Rectangle().fill(SonarTheme.hairline).frame(height: 1)
                }
            }
        }
    }

    private func placeholderTab(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(verbatim: text)
                .font(SonarTheme.uiFont(size: 14))
                .foregroundColor(SonarTheme.text3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sticker tab

private let testPackAuthor = "b653c822dfbec71697d379658a58909c3bef59d71b1cf5c1f7035451cde2e9f7"
private let testPackId = "signal-8fa42aa13ec8f0efebe4b038f41afbd1"
private let testPackRelays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]

private struct StickerTabContent: View {
    let onSticker: (StickerInfo, String) -> Void
    let loadPack: (String, String, [String]) async -> StickerPackInfo?
    let loadImage: (String, String) async -> Data?

    @State private var packs: [StickerPackInfo] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .tint(SonarTheme.accent)
                    Text("Loading stickers…")
                        .font(SonarTheme.uiFont(size: 13))
                        .foregroundColor(SonarTheme.text3)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Spacer()
                    Text("Couldn't load stickers")
                        .font(SonarTheme.uiFont(size: 14, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    Text(error)
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text3)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if !packs.isEmpty {
                ScrollView {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(packs, id: \.packCoordinate) { pack in
                            Section {
                                ForEach(pack.stickers, id: \.shortcode) { sticker in
                                    StickerCell(sticker: sticker, loadImage: loadImage) {
                                        onSticker(sticker, pack.packCoordinate)
                                    }
                                }
                            } header: {
                                Text(pack.title)
                                    .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                                    .foregroundColor(SonarTheme.text3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .task {
            await loadPacks()
        }
    }

    private func loadPacks() async {
        let coordinates = (try? await MarmotService.shared.fetchInstalledPacks()) ?? []
        let toFetch = coordinates.isEmpty ? ["30030:\(testPackAuthor):\(testPackId)"] : coordinates
        var loaded: [StickerPackInfo] = []
        for coord in toFetch {
            let parts = coord.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let relays = coord.contains(testPackAuthor) ? testPackRelays : []
            if let p = await loadPack(parts[1], parts[2], relays), !p.stickers.isEmpty {
                loaded.append(p)
            }
        }
        if loaded.isEmpty {
            if let fallback = await loadPack(testPackAuthor, testPackId, testPackRelays) {
                loaded.append(fallback)
            }
        }
        packs = loaded
        if loaded.isEmpty { self.error = "Failed to load sticker packs" }
        loading = false
    }
}

#if os(iOS)
private typealias StickerImage = UIImage
#else
private typealias StickerImage = NSImage
#endif

private struct StickerCell: View {
    let sticker: StickerInfo
    let loadImage: (String, String) async -> Data?
    let onTap: () -> Void

    @State private var image: StickerImage?
    @State private var failed = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                    #endif
                } else if failed {
                    Text(verbatim: sticker.emoji ?? sticker.shortcode)
                        .font(SonarTheme.uiFont(size: 11))
                        .foregroundColor(SonarTheme.text3)
                        .frame(width: 60, height: 60)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SonarTheme.surface2)
                        .frame(width: 60, height: 60)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .task {
            await fetchImage()
        }
    }

    private func fetchImage() async {
        failed = false
        guard let data = await loadImage(sticker.url, sticker.sha256),
              let decoded = StickerImage(data: data)
        else {
            failed = true
            return
        }
        image = decoded
    }
}

// MARK: - Sticker Pack Preview

struct StickerPackPreviewSheet: View {
    let coordinate: String
    let loadPack: (String, String, [String]) async -> StickerPackInfo?
    let loadImage: (String, String) async -> Data?
    let installPack: (String) async -> Bool
    let uninstallPack: (String) async -> Bool
    let isInstalled: (String) async -> Bool
    let onClose: () -> Void

    @State private var pack: StickerPackInfo?
    @State private var loading = true
    @State private var installed = false
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 0) {
                    if loading {
                        ProgressView()
                            .tint(SonarTheme.text3)
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                    } else if let pack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: pack.title)
                                .font(SonarTheme.uiFont(size: 18, weight: .bold))
                                .foregroundColor(SonarTheme.text)
                                .padding(.bottom, 4)
                            if let desc = pack.description, !desc.isEmpty {
                                Text(verbatim: desc)
                                    .font(SonarTheme.uiFont(size: 13))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(2)
                                    .padding(.bottom, 4)
                            }
                            Text(verbatim: "\(pack.stickers.count) stickers")
                                .font(SonarTheme.uiFont(size: 12))
                                .foregroundColor(SonarTheme.text3)
                                .padding(.bottom, 12)
                            ScrollView {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                                    ForEach(pack.stickers.indices, id: \.self) { i in
                                        PreviewStickerCell(
                                            sticker: pack.stickers[i],
                                            loadImage: loadImage
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: 280)
                            .padding(.bottom, 16)
                            Button(action: {
                                Task {
                                    busy = true
                                    if installed {
                                        if await uninstallPack(coordinate) {
                                            installed = false
                                        }
                                    } else {
                                        if await installPack(coordinate) {
                                            installed = true
                                        }
                                    }
                                    busy = false
                                }
                            }) {
                                Text(verbatim: busy ? (installed ? "Removing..." : "Installing...") : (installed ? "Remove pack" : "Install pack"))
                                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                                    .foregroundColor(installed ? .white : SonarTheme.onAccent)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(installed ? Color.red.opacity(0.8) : SonarTheme.accent)
                                    .cornerRadius(12)
                            }
                            .disabled(busy)
                            .padding(.bottom, 8)
                            Button(action: onClose) {
                                Text("Close")
                                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                                    .foregroundColor(SonarTheme.text2)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                        .padding(20)
                    } else {
                        VStack(spacing: 16) {
                            Text("Could not load sticker pack")
                                .font(SonarTheme.uiFont(size: 14))
                                .foregroundColor(SonarTheme.text2)
                            Button(action: onClose) {
                                Text("Close")
                                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                                    .foregroundColor(SonarTheme.text2)
                            }
                        }
                        .padding(20)
                    }
                }
                .background(SonarTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .task {
            loading = true
            installed = await isInstalled(coordinate)
            let parts = coordinate.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                pack = await loadPack(parts[1], parts[2], [])
            }
            loading = false
        }
    }
}

private struct PreviewStickerCell: View {
    let sticker: StickerInfo
    let loadImage: (String, String) async -> Data?

    @State private var image: StickerImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SonarTheme.surface2)
            if let image {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                #else
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                #endif
            } else {
                Text(verbatim: sticker.emoji ?? sticker.shortcode)
                    .font(SonarTheme.uiFont(size: 11))
                    .foregroundColor(SonarTheme.text3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            if let data = await loadImage(sticker.url, sticker.sha256),
               let decoded = StickerImage(data: data) {
                image = decoded
            }
        }
    }
}

// MARK: - Emoji data

private struct EmojiCategory {
    let icon: String
    let emojis: [String]
}

private let emojiCategories: [EmojiCategory] = [
    EmojiCategory(icon: "😀", emojis: [
        "😀","😃","😄","😁","😆","🥹","😅","😂","🤣","🥲",
        "☺️","😊","😇","🙂","🙃","😉","😌","😍","🥰","😘",
        "😗","😙","😚","😋","😛","😝","😜","🤪","🤨","🧐",
        "🤓","😎","🥸","🤩","🥳","😏","😒","😞","😔","😟",
        "😕","🙁","☹️","😣","😖","😫","😩","🥺","😢","😭",
    ]),
    EmojiCategory(icon: "👋", emojis: [
        "👋","🤚","🖐️","✋","🖖","👌","🤌","🤏","✌️","🤞",
        "🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","👍",
        "👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝",
        "🙏","✍️","💅","🤳","💪","🦾","🦿","🦵","🦶","👂",
        "🦻","👃","🧠","🫀","🫁","🦷","🦴","👀","👁️","👅",
    ]),
    EmojiCategory(icon: "❤️", emojis: [
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔",
        "❤️‍🔥","❤️‍🩹","💕","💞","💓","💗","💖","💘","💝","💟",
        "☮️","✝️","☪️","🕉️","☸️","✡️","🔯","🕎","☯️","☦️",
        "🛐","⛎","♈","♉","♊","♋","♌","♍","♎","♏",
        "♐","♑","♒","♓","🆔","⚛️","🉑","☢️","☣️","📴",
    ]),
    EmojiCategory(icon: "🐶", emojis: [
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨",
        "🐯","🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐒",
        "🐔","🐧","🐦","🐤","🐣","🐥","🦆","🦅","🦉","🦇",
        "🐺","🐗","🐴","🦄","🐝","🪱","🐛","🦋","🐌","🐞",
        "🐜","🪰","🪲","🪳","🦟","🦗","🕷️","🕸️","🦂","🐢",
    ]),
    EmojiCategory(icon: "🍎", emojis: [
        "🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈",
        "🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦",
        "🥬","🥒","🌶️","🫑","🌽","🥕","🫒","🧄","🧅","🥔",
        "🍠","🥐","🥯","🍞","🥖","🥨","🧀","🥚","🍳","🧈",
        "🥞","🧇","🥓","🥩","🍗","🍖","🦴","🌭","🍔","🍟",
    ]),
    EmojiCategory(icon: "⚽", emojis: [
        "⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱",
        "🪀","🏓","🏸","🏒","🏑","🥍","🏏","🪃","🥅","⛳",
        "🪁","🏹","🎣","🤿","🥊","🥋","🎽","🛹","🛼","🛷",
        "⛸️","🥌","🎿","⛷️","🏂","🪂","🏋️","🤼","🤸","⛹️",
        "🤺","🤾","🏌️","🏇","🧘","🏄","🏊","🤽","🚣","🧗",
    ]),
    EmojiCategory(icon: "🚗", emojis: [
        "🚗","🚕","🚙","🚌","🚎","🏎️","🚓","🚑","🚒","🚐",
        "🛻","🚚","🚛","🚜","🦯","🦽","🦼","🛴","🚲","🛵",
        "🏍️","🛺","🚨","🚔","🚍","🚘","🚖","🚡","🚠","🚟",
        "🚃","🚋","🚞","🚝","🚄","🚅","🚈","🚂","🚆","🚇",
        "🚊","🚉","✈️","🛫","🛬","🛩️","💺","🛰️","🚀","🛸",
    ]),
    EmojiCategory(icon: "💡", emojis: [
        "💡","🔦","🏮","🪔","📱","💻","⌨️","🖥️","🖨️","🖱️",
        "🖲️","💽","💾","💿","📀","🧮","🎥","🎞️","📽️","🎬",
        "📺","📷","📸","📹","📼","🔍","🔎","🕯️","⚡","🔋",
        "🔌","🪫","💰","💴","💵","💶","💷","🪙","💸","💳",
        "🧾","✉️","📧","📨","📩","📤","📥","📦","📫","📪",
    ]),
    EmojiCategory(icon: "🏁", emojis: [
        "🏁","🚩","🎌","🏴","🏳️","🏳️‍🌈","🏳️‍⚧️","🏴‍☠️","🇺🇸","🇬🇧",
        "🇫🇷","🇩🇪","🇮🇹","🇪🇸","🇯🇵","🇰🇷","🇨🇳","🇷🇺","🇧🇷","🇦🇺",
        "🇨🇦","🇲🇽","🇮🇳","🇦🇷","🇸🇦","🇿🇦","🇳🇬","🇪🇬","🇹🇷","🇵🇱",
        "🇳🇱","🇧🇪","🇸🇪","🇳🇴","🇩🇰","🇫🇮","🇨🇭","🇦🇹","🇵🇹","🇬🇷",
        "🇮🇪","🇮🇱","🇹🇭","🇻🇳","🇵🇭","🇮🇩","🇲🇾","🇸🇬","🇳🇿","🇨🇴",
    ]),
]
