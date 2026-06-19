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

struct SonarEmojiPickerView: View {
    let onEmoji: (String) -> Void
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
            default: placeholderTab("Sticker packs coming soon")
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
