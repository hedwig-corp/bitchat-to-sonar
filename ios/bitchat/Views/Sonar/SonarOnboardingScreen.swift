//
// SonarOnboardingScreen.swift
// bitchat
//
// 3-step onboarding, ported from the Onboarding component in
// design/handoff/project/sonar/screens.jsx.
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

struct SonarOnboardingScreen: View {
    @EnvironmentObject private var store: SonarAppStore

    @State private var step = 0
    @State private var nick = ""
    @FocusState private var nickFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // "I already have a key" — restore an existing identity from an nsec backup.
    @State private var restoring = false
    @State private var nsec = ""
    @State private var restoreError: String?
    @State private var restoreInFlight = false
    @FocusState private var nsecFocused: Bool

    private var can: Bool { nick.trimmingCharacters(in: .whitespaces).count >= 2 }
    private var trimmedNick: String { nick.trimmingCharacters(in: .whitespaces) }

    /// Matches the prototype's nsec validation: bech32 `nsec1…`.
    private var nsecOk: Bool {
        let t = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^nsec1[0-9a-z]{20,}$", options: .regularExpression) != nil
    }

    /// Nickname suggestions from the design handoff (data.js) — design copy,
    /// not demo data: tapping "Surprise me" picks one as the user's real nick.
    private static let suggestions = ["quietfox", "tram12", "lakeswim", "verdigris", "morningstatic", "papercrane", "northpine", "softsignal"]

    private func surprise() {
        nick = Self.suggestions.randomElement() ?? "quietfox"
    }

    var body: some View {
        VStack(spacing: 0) {
            // bc-obtop
            HStack {
                if step > 0 || restoring {
                    SNIconButton(action: {
                        if restoring { restoring = false; restoreError = nil }
                        else { advance(to: step - 1) }
                    }) {
                        SNIcon(name: .back, size: 21, weight: 2.1)
                    }
                }
                Spacer()
            }
            .frame(height: 40)
            .padding(.leading, -10)

            // bc-obbody
            Group {
                if restoring {
                    stepRestore
                } else {
                    switch step {
                    case 0: stepIntro
                    case 1: stepNickname
                    default: stepDone
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .transition(reduceMotion ? .opacity : .offset(y: 10).combined(with: .opacity))
            .id(restoring ? -1 : step)

            // bc-obfooter
            VStack(spacing: 16) {
                if !restoring {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(step == i ? SonarTheme.accent : SonarTheme.hairline)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                if restoring {
                    SNPrimaryButton(label: restoreInFlight ? "Restoring\u{2026}" : "Restore account", disabled: !nsecOk || restoreInFlight) {
                        restore()
                    }
                } else {
                    switch step {
                    case 0:
                        SNPrimaryButton(label: "Get started") { advance(to: 1) }
                        SNGhostButton(label: "I already have a key") {
                            nsec = ""
                            restoreError = nil
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { restoring = true }
                        }
                    case 1:
                        SNPrimaryButton(label: "Continue", disabled: !can) { advance(to: 2) }
                    default:
                        SNPrimaryButton(label: "Start chatting") {
                            store.completeOnboarding(nick: trimmedNick)
                        }
                    }
                }
            }
            .padding(.top, 18)
        }
        .padding(EdgeInsets(top: 10, leading: 28, bottom: 12, trailing: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SonarTheme.bg.ignoresSafeArea())
    }

    private func advance(to newStep: Int) {
        if reduceMotion {
            step = newStep
        } else {
            withAnimation(.easeOut(duration: 0.35)) { step = newStep }
        }
    }

    // Step 1 — intro
    private var stepIntro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(SonarTheme.accentFill)
                .frame(width: 74, height: 74)
                .overlay(
                    SNIcon(name: .rings, size: 40, weight: 1.5)
                        .foregroundColor(SonarTheme.onAccent)
                )
                .padding(.bottom, 28)
            Text("Sense who\u{2019}s nearby before you see them.")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .kerning(-30 * 0.02)
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)
            Text("Sonar connects phones directly — no phone number, no account, no servers.")
                .font(SonarTheme.uiFont(size: 16))
                .lineSpacing(16 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .padding(.bottom, 22)
            featureRow(icon: .mesh, title: "Works without internet", desc: "Bluetooth finds people around you, even offline.")
            featureRow(icon: .globe, title: "Out of range? Still reachable", desc: "Messages travel encrypted over the open internet instead.")
            featureRow(icon: .lock, title: "Private by design", desc: "Direct messages are end-to-end encrypted. Always.")
            Spacer()
        }
    }

    private func featureRow(icon: SNIconName, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SonarTheme.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(
                    SNIcon(name: icon, size: 20)
                        .foregroundColor(SonarTheme.accentDeep)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(SonarTheme.uiFont(size: 16, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                Text(verbatim: desc)
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.25)
                    .foregroundColor(SonarTheme.text2)
            }
        }
        .padding(.vertical, 11)
    }

    // Step 2 — nickname
    private var stepNickname: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Pick a nickname")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .kerning(-30 * 0.02)
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)
            Text("It\u{2019}s just what people see — change it anytime.")
                .font(SonarTheme.uiFont(size: 16))
                .lineSpacing(16 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .padding(.bottom, 22)
            HStack(spacing: 16) {
                SonarAvatar(name: trimmedNick.isEmpty ? "?" : trimmedNick, size: 72)
                TextField("", text: $nick, prompt: Text("nickname").foregroundColor(SonarTheme.text3).fontWeight(.medium))
                    .textFieldStyle(.plain)
                    .font(SonarTheme.uiFont(size: 21, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .focused($nickFocused)
                    .onSubmit { if can { advance(to: 2) } }
                    .onChange(of: nick) { v in
                        if v.count > 20 { nick = String(v.prefix(20)) }
                    }
                    .padding(EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(nickFocused ? SonarTheme.accent : Color.clear, lineWidth: 1.5)
                    )
            }
            .padding(.bottom, 18)
            Button(action: surprise) {
                HStack(spacing: 7) {
                    SNIcon(name: .dice, size: 16, weight: 2)
                    Text("Surprise me")
                        .font(SonarTheme.uiFont(size: 14, weight: .bold))
                }
                .foregroundColor(SonarTheme.accentDeep)
                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                .background(Capsule().fill(SonarTheme.accentSoft))
            }
            .buttonStyle(SNScaleStyle(scale: 0.96))
            .padding(.top, 12)
            Text("No signup. Your identity is a private key created on this phone — nobody else ever sees it.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.3)
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 18)
            Spacer()
        }
    }

    // Step 3 — you're in
    private var stepDone: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            SonarAvatar(name: trimmedNick, size: 92)
                .padding(.bottom, 22)
            Text(verbatim: "You\u{2019}re in, \(trimmedNick).")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .kerning(-30 * 0.02)
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)
            Text("No account was created anywhere — your identity lives on this phone.")
                .font(SonarTheme.uiFont(size: 16))
                .lineSpacing(16 * 0.3)
                .foregroundColor(SonarTheme.text2)
            SNFingerprintCard(label: "Your key fingerprint", value: store.myFingerprintDisplay)
                .padding(.top, 24)
            Text("Friends can verify this fingerprint in person to be sure it\u{2019}s really you.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.3)
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 18)
            Spacer()
        }
    }

    // Restore — paste an existing nsec ("I already have a key")
    private var stepRestore: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(SonarTheme.accentFill)
                .frame(width: 74, height: 74)
                .overlay(
                    SNIcon(name: .importKey, size: 34, weight: 1.7)
                        .foregroundColor(SonarTheme.onAccent)
                )
                .padding(.bottom, 28)
            Text("Restore your account")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .kerning(-30 * 0.02)
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)
            (Text("Paste the ") + Text("nsec").fontWeight(.bold)
                + Text(" private key from your old device or another Nostr app. Your nickname, contacts and balance come back with it."))
                .font(SonarTheme.uiFont(size: 16))
                .lineSpacing(16 * 0.3)
                .foregroundColor(SonarTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
            ZStack(alignment: .topLeading) {
                if nsec.isEmpty {
                    Text(verbatim: "nsec1\u{2026}")
                        .font(SonarTheme.monoFont(size: 15))
                        .foregroundColor(SonarTheme.text3)
                        .padding(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
                        .allowsHitTesting(false)
                }
                TextEditor(text: $nsec)
                    .font(SonarTheme.monoFont(size: 15))
                    .foregroundColor(SonarTheme.text)
                    .focused($nsecFocused)
                    .frame(minHeight: 84)
                    .scrollContentBackground(.hidden)
                    .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(nsecFocused ? SonarTheme.accent : Color.clear, lineWidth: 1.5)
            )
            Button(action: pasteFromClipboard) {
                HStack(spacing: 7) {
                    SNIcon(name: .copy, size: 15, weight: 2)
                    Text("Paste from clipboard")
                        .font(SonarTheme.uiFont(size: 14, weight: .bold))
                }
                .foregroundColor(SonarTheme.accentDeep)
                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                .background(Capsule().fill(SonarTheme.accentSoft))
            }
            .buttonStyle(SNScaleStyle(scale: 0.96))
            .padding(.top, 12)
            if let restoreError {
                Text(verbatim: restoreError)
                    .font(SonarTheme.uiFont(size: 13))
                    .lineSpacing(13 * 0.3)
                    .foregroundColor(SonarTheme.danger)
                    .padding(.top, 12)
            }
            Text("Sonar never sends this key anywhere — it\u{2019}s decoded on this phone to unlock your identity.")
                .font(SonarTheme.uiFont(size: 13))
                .lineSpacing(13 * 0.3)
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 18)
            Spacer()
        }
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let s = UIPasteboard.general.string {
            nsec = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #elseif canImport(AppKit)
        if let s = NSPasteboard.general.string(forType: .string) {
            nsec = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }

    private func restore() {
        let key = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nsecOk, !restoreInFlight else { return }
        restoreInFlight = true
        restoreError = nil
        Task { @MainActor in
            do {
                try await store.restoreAccount(nsec: key)
                // store.restoreAccount flips `onboarded`; the root view swaps to home.
            } catch {
                restoreError = "That key couldn\u{2019}t be imported. Check you pasted the full nsec1\u{2026} key."
                restoreInFlight = false
            }
        }
    }
}

/// bc-fpcard — fingerprint card used by onboarding step 3 and the profile screen.
struct SNFingerprintCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label.uppercased())
                .font(SonarTheme.uiFont(size: 12, weight: .bold))
                .kerning(12 * 0.05)
                .foregroundColor(SonarTheme.text3)
            Text(verbatim: value)
                .font(SonarTheme.monoFont(size: 15))
                .kerning(15 * 0.08)
                .foregroundColor(SonarTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
    }
}
