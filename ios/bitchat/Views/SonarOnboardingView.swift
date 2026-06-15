//
// SonarOnboardingView.swift
// bitchat
//
// 3-step first-run onboarding from the Sonar prototype:
// 1. "Sense who's nearby before you see them" + feature rows
// 2. Pick a nickname (with a "Surprise me" suggestion chip)
// 3. "You're in" + key fingerprint card
// No accounts, no phone numbers — the identity already lives on this phone.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarOnboardingView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    let onDone: () -> Void

    @State private var step = 0
    @State private var nick = ""
    @FocusState private var nickFocused: Bool

    private static let suggestions = [
        "quietfox", "tram12", "lakeswim", "verdigris",
        "morningstatic", "papercrane", "northpine", "softsignal",
    ]

    private var canContinue: Bool {
        nick.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back affordance
            HStack {
                if step > 0 {
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { step -= 1 } }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(SonarTheme.text2)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 40)

            Spacer()

            Group {
                switch step {
                case 0: introStep
                case 1: nicknameStep
                default: doneStep
                }
            }

            Spacer()

            // Footer: progress dots + primary button
            VStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == step ? SonarTheme.accent : SonarTheme.hairline)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)

                primaryButton
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear {
            // Seed with the existing (auto-generated) nickname when sensible
            let current = viewModel.nickname
            if !current.isEmpty && !current.hasPrefix("anon") {
                nick = current
            }
        }
    }

    // MARK: - Steps

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(SonarTheme.accentFill)
                .frame(width: 74, height: 74)
                .overlay(
                    Image(systemName: "circle.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(SonarTheme.onAccent)
                )
                .padding(.bottom, 28)

            Text("Sense who’s nearby before you see them.")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)

            Text("Sonar connects phones directly — no phone number, no account, no servers.")
                .font(SonarTheme.uiFont(size: 16))
                .foregroundColor(SonarTheme.text2)
                .padding(.bottom, 22)

            featureRow(
                icon: "dot.radiowaves.left.and.right",
                title: "Works without internet",
                desc: "Bluetooth finds people around you, even offline."
            )
            featureRow(
                icon: "globe",
                title: "Out of range? Still reachable",
                desc: "Messages travel encrypted over the open internet instead."
            )
            featureRow(
                icon: "lock",
                title: "Private by design",
                desc: "Direct messages are end-to-end encrypted. Always."
            )
        }
    }

    private var nicknameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pick a nickname")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)

            Text("It’s just what people see — change it anytime.")
                .font(SonarTheme.uiFont(size: 16))
                .foregroundColor(SonarTheme.text2)
                .padding(.bottom, 22)

            HStack(spacing: 16) {
                SonarAvatar(name: nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "?" : nick, size: 72)

                TextField("nickname", text: $nick)
                    .textFieldStyle(.plain)
                    .font(SonarTheme.uiFont(size: 21, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .focused($nickFocused)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { if canContinue { advanceFromNickname() } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SonarTheme.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(nickFocused ? SonarTheme.accent : Color.clear, lineWidth: 1.5)
                    )
            }
            .padding(.bottom, 12)

            Button(action: {
                nick = Self.suggestions.randomElement() ?? "quietfox"
            }) {
                HStack(spacing: 7) {
                    Image(systemName: "dice")
                        .font(.system(size: 13, weight: .bold))
                    Text("Surprise me")
                        .font(SonarTheme.uiFont(size: 14, weight: .bold))
                }
                .foregroundColor(SonarTheme.accentDeep)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(SonarTheme.accentSoft))
            }
            .buttonStyle(.plain)

            Text("No signup. Your identity is a private key created on this phone — nobody else ever sees it.")
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 18)
        }
    }

    private var doneStep: some View {
        let finalNick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            SonarAvatar(name: finalNick, size: 92)
                .padding(.bottom, 22)

            Text("You’re in, \(finalNick).")
                .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 10)

            Text("No account was created anywhere — your identity lives on this phone.")
                .font(SonarTheme.uiFont(size: 16))
                .foregroundColor(SonarTheme.text2)
                .padding(.bottom, 24)

            // Fingerprint card — mono is reserved for technical bits like this
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR KEY FINGERPRINT")
                    .font(SonarTheme.uiFont(size: 12, weight: .bold))
                    .foregroundColor(SonarTheme.text3)
                    .kerning(0.6)
                Text(shortFingerprint)
                    .font(SonarTheme.monoFont(size: 15))
                    .kerning(1.2)
                    .foregroundColor(SonarTheme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SonarTheme.surface2)
            )

            Text("Friends can verify this fingerprint in person to be sure it’s really you.")
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text3)
                .padding(.top, 18)
        }
    }

    private var shortFingerprint: String {
        let fp = viewModel.getMyFingerprint().lowercased()
        guard fp.count >= 16 else { return fp }
        return stride(from: 0, to: 16, by: 4).map { offset -> String in
            let start = fp.index(fp.startIndex, offsetBy: offset)
            let end = fp.index(start, offsetBy: 4)
            return String(fp[start..<end])
        }.joined(separator: " ")
    }

    // MARK: - Pieces

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SonarTheme.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(SonarTheme.accentDeep)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SonarTheme.uiFont(size: 16, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                Text(desc)
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    private var primaryButton: some View {
        Button(action: advance) {
            Text(step == 0 ? "Get started" : (step == 1 ? "Continue" : "Start chatting"))
                .font(SonarTheme.uiFont(size: 17, weight: .bold))
                .foregroundColor(SonarTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(SonarTheme.accentFill)
                )
                .opacity(step == 1 && !canContinue ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(step == 1 && !canContinue)
    }

    // MARK: - Actions

    private func advance() {
        switch step {
        case 0:
            withAnimation(.easeOut(duration: 0.2)) { step = 1 }
        case 1:
            advanceFromNickname()
        default:
            onDone()
        }
    }

    private func advanceFromNickname() {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        nick = trimmed
        viewModel.nickname = trimmed
        viewModel.validateAndSaveNickname()
        nickFocused = false
        withAnimation(.easeOut(duration: 0.2)) { step = 2 }
    }
}
