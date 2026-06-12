//
// SonarProfileScreen.swift
// bitchat
//
// Profile screen + deterministic QR-style share code, ported from
// ProfileScreen/ShareCode in design/handoff/project/sonar/settings.jsx.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarProfileScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var editing = false
    @State private var draft = ""
    @State private var showKey = false
    @State private var bip353Draft = ""
    @FocusState private var draftFocused: Bool

    private var displayNick: String { store.nick.isEmpty ? "you" : store.nick }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 {
            store.rename(trimmed)
        }
        editing = false
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Profile")
            }
            ScrollView {
                VStack(spacing: 0) {
                    // pf-head
                    VStack(spacing: 8) {
                        SonarAvatar(
                            name: editing
                                ? (draft.trimmingCharacters(in: .whitespaces).isEmpty ? "you" : draft.trimmingCharacters(in: .whitespaces))
                                : displayNick,
                            size: 96
                        )
                        if editing {
                            HStack(spacing: 8) {
                                TextField("", text: $draft, prompt: Text("nickname").foregroundColor(SonarTheme.text3))
                                    .textFieldStyle(.plain)
                                    .font(SonarTheme.uiFont(size: 18, weight: .bold))
                                    .foregroundColor(SonarTheme.text)
                                    .focused($draftFocused)
                                    .onSubmit(save)
                                    .onChange(of: draft) { v in
                                        if v.count > 20 { draft = String(v.prefix(20)) }
                                    }
                                    .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(draftFocused ? SonarTheme.accent : Color.clear, lineWidth: 1.5)
                                    )
                                Button(action: save) {
                                    Text("Save")
                                        .font(SonarTheme.uiFont(size: 14, weight: .bold))
                                        .foregroundColor(SonarTheme.onAccent)
                                        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                                        .background(Capsule().fill(SonarTheme.accentFill))
                                }
                                .buttonStyle(SNScaleStyle(scale: 0.97))
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(verbatim: displayNick)
                                    .font(SonarTheme.uiFont(size: 24, weight: .heavy))
                                    .foregroundColor(SonarTheme.text)
                                SNIconButton(size: 30, action: {
                                    draft = store.nick
                                    editing = true
                                    draftFocused = true
                                }) {
                                    SNIcon(name: .pencil, size: 15, weight: 2)
                                }
                                .accessibilityLabel("Edit nickname")
                            }
                        }
                        Text(verbatim: store.shortKey)
                            .font(SonarTheme.monoFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .padding(EdgeInsets(top: 4, leading: 11, bottom: 4, trailing: 11))
                            .background(Capsule().fill(SonarTheme.surface2))
                    }
                    .padding(EdgeInsets(top: 14, leading: 28, bottom: 4, trailing: 28))

                    // pf-codecard
                    VStack(spacing: 12) {
                        SNShareCode(seed: store.npub ?? store.myFingerprintDisplay, size: 164)
                        Text("Show this code to someone nearby to start an encrypted chat.")
                            .font(SonarTheme.uiFont(size: 12.5))
                            .lineSpacing(12.5 * 0.25)
                            .foregroundColor(SonarTheme.text2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 20, leading: 18, bottom: 16, trailing: 18))
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(SonarTheme.surface)
                            .shadow(color: Color(sonarHex: 0x081E28, opacity: 0.04), radius: 1, y: 1)
                    )
                    .padding(14)

                    SNSectionLabel("Keys")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .key, tone: .cyan, label: "Key fingerprint",
                            value: store.myFingerprintDisplay, valueMono: true,
                            trail: .none
                        ) {}
                        SNSettingsRow(
                            icon: .lock, label: "Public key",
                            sub: showKey ? nil : "Tap to reveal",
                            divider: false
                        ) {
                            showKey.toggle()
                        }
                    }
                    if showKey {
                        Text(verbatim: store.npub ?? "npub not available yet — connecting to the secure chat service.")
                            .font(SonarTheme.monoFont(size: 11))
                            .lineSpacing(11 * 0.6)
                            .foregroundColor(SonarTheme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 2, leading: 26, bottom: 8, trailing: 26))
                    }
                    Text("Your nickname is just what people see — your key never leaves this phone.")
                        .font(SonarTheme.uiFont(size: 12))
                        .lineSpacing(12 * 0.3)
                        .foregroundColor(SonarTheme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 0, leading: 24, bottom: 4, trailing: 24))

                    SNSectionLabel("Payments")
                    SNSettingsCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Payment address (BIP-353)")
                                .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                                .foregroundColor(SonarTheme.text)
                            TextField(
                                "",
                                text: $bip353Draft,
                                prompt: Text(verbatim: "user@domain").foregroundColor(SonarTheme.text3)
                            )
                            .textFieldStyle(.plain)
                            .font(SonarTheme.monoFont(size: 13))
                            .foregroundColor(SonarTheme.text)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .onSubmit { store.setBip353(bip353Draft) }
                            .onChange(of: bip353Draft) { v in store.setBip353(v) }
                            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                        }
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    }
                    Text("People nearby can send you money at this address. It's shared with your Sonar announce — leave it empty to share nothing.")
                        .font(SonarTheme.uiFont(size: 12))
                        .lineSpacing(12 * 0.3)
                        .foregroundColor(SonarTheme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 0, leading: 24, bottom: 4, trailing: 24))
                }
                .padding(.bottom, 40)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear { bip353Draft = store.bip353 }
    }
}

// MARK: - Deterministic share code (QR-style, generated from the pubkey)

struct SNShareCode: View {
    let seed: String
    var size: CGFloat = 164

    private static let n = 11
    private static let cellSize = 4.0

    private func isFinder(_ r: Int, _ c: Int) -> Bool {
        (r < 3 && c < 3) || (r < 3 && c >= Self.n - 3) || (r >= Self.n - 3 && c < 3)
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let unit = canvasSize.width / (Double(Self.n) * Self.cellSize)
            for r in 0..<Self.n {
                let rh = snHash(seed + ":" + String(r))
                for c in 0..<Self.n {
                    let on: Bool
                    if isFinder(r, c) {
                        let lr = r < 3 ? r : r - (Self.n - 3)
                        let lc = c < 3 ? c : c - (Self.n - 3)
                        on = !(lr == 1 && lc == 1)
                    } else {
                        on = (rh >> UInt32(c)) & 1 == 1
                    }
                    if on {
                        let rect = CGRect(
                            x: (Double(c) * Self.cellSize + 0.3) * unit,
                            y: (Double(r) * Self.cellSize + 0.3) * unit,
                            width: (Self.cellSize - 0.6) * unit,
                            height: (Self.cellSize - 0.6) * unit
                        )
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 0.9 * unit),
                            with: .color(SonarTheme.text)
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
