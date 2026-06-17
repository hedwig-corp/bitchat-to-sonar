//
// SonarProfileScreen.swift
// bitchat
//
// Profile screen + scannable key-share QR, ported from
// ProfileScreen/ShareCode in design/handoff/project/sonar/settings.jsx.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct SonarProfileScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var editing = false
    @State private var draft = ""
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

                    // Your key — KeyShareCard (QR + copy/share + expand)
                    SNSectionLabel("Your key")
                    SNSettingsCard {
                        if let npub = store.npub {
                            SNKeyShareCard(key: npub)
                        } else {
                            Text(verbatim: "Your key isn't ready yet — connecting to the secure chat service.")
                                .font(SonarTheme.uiFont(size: 12.5))
                                .lineSpacing(12.5 * 0.45)
                                .foregroundColor(SonarTheme.text2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(EdgeInsets(top: 22, leading: 18, bottom: 22, trailing: 18))
                        }
                    }

                    SNSectionLabel("Safety")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .key, tone: .cyan, label: "Fingerprint",
                            sub: "Read this aloud to verify in person",
                            value: store.myFingerprintDisplay, valueMono: true,
                            trail: .none, divider: false
                        ) {}
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

// MARK: - Scannable key share QR

struct SNShareCode: View {
    let seed: String
    var size: CGFloat = 164

    var body: some View {
        QRCodeImage(data: seed, size: size)
        .frame(width: size, height: size)
        .accessibilityLabel("Key share QR code")
    }
}

// MARK: - Key sharing card (QR + copy/share + expand), ported from KeyShareCard in settings.jsx

struct SNKeyShareCard: View {
    let key: String
    var compact: Bool = false

    @State private var full = false
    @State private var copied = false

    /// First 18 + "…" + last 8, matching the prototype's shortKey.
    private var shortKey: String {
        guard key.count > 18 + 8 + 1 else { return key }
        return String(key.prefix(18)) + "\u{2026}" + String(key.suffix(8))
    }

    private func copyKey() {
        #if canImport(UIKit)
        UIPasteboard.general.string = key
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #endif
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // keyshare-qr — dark cells on a white rounded plate
            SNShareCode(seed: key, size: compact ? 150 : 184)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Color(sonarHex: 0x081E28, opacity: 0.12), radius: 5, y: 2)
                )

            Text("Let someone scan this to add you — keys are exchanged directly, never through a server.")
                .font(SonarTheme.uiFont(size: 12.5))
                .lineSpacing(12.5 * 0.45)
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.top, 14)

            // keyshare-keyrow — tap to expand to the full key
            Button { full.toggle() } label: {
                Text(verbatim: full ? key : shortKey)
                    .font(SonarTheme.monoFont(size: full ? 11.5 : 12.5))
                    .tracking(0.25)
                    .lineSpacing(full ? 11.5 * 0.6 : 0)
                    .foregroundColor(full ? SonarTheme.text : SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(SNScaleStyle(scale: 0.99))
            .accessibilityLabel(full ? "Hide full key" : "Show full key")
            .padding(.top, 12)

            // keyshare-btns — copy + native share
            HStack(spacing: 10) {
                Button(action: copyKey) {
                    keyShareButtonLabel(
                        icon: copied ? .check : .copy,
                        iconWeight: 2.2,
                        text: copied ? "Copied" : "Copy key",
                        fg: SonarTheme.onAccent,
                        bg: copied ? SonarTheme.green : SonarTheme.accentFill
                    )
                }
                .buttonStyle(SNScaleStyle(scale: 0.97))

                ShareLink(item: key) {
                    keyShareButtonLabel(
                        icon: .share,
                        iconWeight: 2,
                        text: "Share",
                        fg: SonarTheme.text,
                        bg: SonarTheme.surface2
                    )
                }
                .buttonStyle(SNScaleStyle(scale: 0.97))
            }
            .padding(.top, 10)
        }
        .padding(EdgeInsets(
            top: compact ? 8 : 14,
            leading: compact ? 8 : 16,
            bottom: compact ? 6 : 8,
            trailing: compact ? 8 : 16
        ))
    }

    private func keyShareButtonLabel(icon: SNIconName, iconWeight: CGFloat, text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 7) {
            SNIcon(name: icon, size: 17, weight: iconWeight)
            Text(verbatim: text)
                .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
        }
        .foregroundColor(fg)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(bg))
    }
}
