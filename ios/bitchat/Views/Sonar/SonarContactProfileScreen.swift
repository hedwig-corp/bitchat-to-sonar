//
// SonarContactProfileScreen.swift
// bitchat
//
// Contact profile screen: hero section, action buttons (message/call/verify),
// identity & safety cards, shared groups, block/delete. Ported from the
// Compose Multiplatform SonarContactProfileScreen.
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

struct SonarContactProfileScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String
    let peerName: String

    @State private var showVerify = false
    @State private var toast: String?

    private var effectiveChatId: String {
        guard peerId.hasPrefix("npub1") else { return peerId }
        if let group = store.marmotGroup(forNpub: peerId) {
            return SonarAppStore.marmotIDPrefix + group.id
        }
        if let peerKey = store.sonarPeerKey(forNpub: peerId) {
            return peerKey
        }
        return peerId
    }

    private var resolvedNpub: String {
        if peerId.hasPrefix("npub1") { return peerId }
        if let npub = store.sonarProfile(peerId)?.npub, !npub.isEmpty {
            return npub
        }
        if let group = store.marmotGroup(forConversationId: peerId),
           store.marmot.isDirectGroup(group),
           let otherNpub = store.marmot.otherMembers(in: group).first {
            return otherNpub
        }
        return ""
    }

    private var verified: Bool { store.isVerified(effectiveChatId) }
    private var info: SNVerifyInfo { store.verifyInfo(for: effectiveChatId) }

    private var peerFullKey: String {
        let npub = resolvedNpub
        return npub.isEmpty ? (store.sonarProfile(peerId)?.npub ?? "") : npub
    }

    private var peerShortKey: String {
        let npub = peerFullKey
        guard npub.count > 16 else { return "n/a" }
        return "\(npub.prefix(10))…\(npub.suffix(4))"
    }

    private var sharedGroups: [SNDMRow] {
        let npub = resolvedNpub
        guard !npub.isEmpty else { return [] }
        return store.dmRows.filter { row in
            guard row.isMarmot, store.isMultiMemberMarmotGroupId(row.id) else { return false }
            let members = store.groupMemberContacts(forConversationId: row.id)
            return members.contains { $0.npub == npub }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                EmptyView()
            }

            ScrollView {
                VStack(spacing: 0) {
                    // ── Hero ──
                    VStack(spacing: 0) {
                        SonarAvatar(name: peerName, size: 96)
                        Text(verbatim: peerName)
                            .font(SonarTheme.uiFont(size: 24, weight: .black))
                            .foregroundColor(SonarTheme.text)
                            .padding(.top, 8)
                        Text(verbatim: peerShortKey)
                            .font(SonarTheme.monoFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(SonarTheme.surface2))
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.horizontal, 28)

                    // ── Action buttons ──
                    HStack(spacing: 28) {
                        profileAction(icon: .lock, label: "Message") {
                            store.pop()
                        }
                        profileAction(icon: .phone, label: "Call", enabled: store.canCall(effectiveChatId)) {
                            if store.canCall(effectiveChatId) {
                                store.placeCall(effectiveChatId, video: false)
                            }
                        }
                        profileAction(
                            icon: verified ? .shieldCheck : .shield,
                            label: verified ? "Verified" : "Verify"
                        ) {
                            showVerify.toggle()
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 20)

                    // ── Verify inline ──
                    if showVerify {
                        verifySection
                            .padding(.bottom, 12)
                    }

                    // ── Identity ──
                    SNSectionLabel("Identity")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .key, tone: .cyan, label: "Public key",
                            value: peerShortKey, valueMono: true
                        ) {
                            copyKey()
                        }
                        SNSettingsRow(
                            icon: .lock, label: "Key fingerprint",
                            value: info.safety.first.map { "\($0.prefix(10))…" } ?? "n/a",
                            valueMono: true, trail: .none, divider: false
                        ) {}
                    }

                    // ── Safety ──
                    SNSectionLabel("Safety")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: verified ? .shieldCheck : .shield,
                            tone: verified ? .cyan : .neutral,
                            label: "Safety number",
                            value: verified ? "Verified" : "Not verified"
                        ) { showVerify.toggle() }
                        SNSettingsRow(
                            icon: .lock, tone: .cyan,
                            label: "End-to-end encrypted",
                            sub: "Messages are encrypted with the Signal protocol",
                            trail: .none, divider: false
                        ) {}
                    }

                    // ── Shared groups ──
                    SNSectionLabel("Shared groups")
                    if sharedGroups.isEmpty {
                        Text("No shared groups")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 18)
                            .padding(.bottom, 8)
                    } else {
                        SNSettingsCard {
                            ForEach(Array(sharedGroups.enumerated()), id: \.element.id) { i, group in
                                Button {
                                    store.push(.dm(group.id))
                                } label: {
                                    HStack(spacing: 12) {
                                        SonarAvatar(name: group.title, size: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: group.title)
                                                .font(SonarTheme.uiFont(size: 16, weight: .medium))
                                                .foregroundColor(SonarTheme.text)
                                            Text(verbatim: "Group")
                                                .font(SonarTheme.uiFont(size: 12.5))
                                                .foregroundColor(SonarTheme.text3)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottom) {
                                        if i < sharedGroups.count - 1 {
                                            Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 60)
                                        }
                                    }
                                }
                                .buttonStyle(SNRowPressStyle())
                            }
                        }
                    }

                    // ── Actions ──
                    SNSectionLabel("Actions")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .x, tone: .red, label: "Block contact",
                            danger: true, trail: .none
                        ) { showToast("Coming soon") }
                        SNSettingsRow(
                            icon: .trash, tone: .red, label: "Delete chat",
                            danger: true, trail: .none, divider: false
                        ) { showToast("Coming soon") }
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast {
                Text(verbatim: toast)
                    .font(SonarTheme.uiFont(size: 13.5, weight: .medium))
                    .foregroundColor(SonarTheme.text)
                    .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(SonarTheme.surface2)
                            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 88)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    private func copyKey() {
        let key = peerFullKey
        guard !key.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = key
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #endif
        showToast("Public key copied")
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == text { toast = nil }
        }
    }

    private func profileAction(icon: SNIconName, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Circle()
                    .fill(enabled ? SonarTheme.accentSoft : SonarTheme.surface2)
                    .frame(width: 52, height: 52)
                    .overlay(
                        SNIcon(name: icon, size: 22, weight: 2.1)
                            .foregroundColor(enabled ? SonarTheme.accentDeep : SonarTheme.text3)
                    )
            }
            .buttonStyle(SNScaleStyle(scale: 0.94))
            .disabled(!enabled)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 11, weight: .medium))
                .foregroundColor(SonarTheme.text2)
        }
    }

    @ViewBuilder
    private var verifySection: some View {
        VStack(spacing: 0) {
            Text("Verify safety numbers")
                .font(SonarTheme.uiFont(size: 18, weight: .bold))
                .foregroundColor(SonarTheme.text)
                .padding(.bottom, 14)

            HStack(spacing: 28) {
                VStack(spacing: 4) {
                    SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 48)
                    Text(verbatim: store.nick.isEmpty ? "you" : store.nick)
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text2)
                }
                VStack(spacing: 4) {
                    SonarAvatar(name: peerName, size: 48)
                    Text(verbatim: peerName)
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text2)
                }
            }
            .padding(.bottom, 16)

            if info.available {
                Text("Compare these numbers with \(peerName) in person or on a call. If they match, this chat is end-to-end encrypted and nobody is in the middle.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)

                VStack(spacing: 0) {
                    ForEach([0, 4, 8], id: \.self) { row in
                        Text(verbatim: info.safety[row..<(row + 4)].joined(separator: "\u{2002}"))
                            .font(SonarTheme.monoFont(size: 15))
                            .kerning(15 * 0.06)
                            .foregroundColor(SonarTheme.text)
                            .frame(height: 15 * 2)
                    }
                }
                .padding(.bottom, 18)

                if verified {
                    HStack(spacing: 6) {
                        SNIcon(name: .shieldCheck, size: 16)
                            .foregroundColor(SonarTheme.green)
                        Text("Verified")
                            .font(SonarTheme.uiFont(size: 15, weight: .bold))
                            .foregroundColor(SonarTheme.green)
                    }
                } else {
                    SNPrimaryButton(label: "They match — mark as verified") {
                        store.markVerified(effectiveChatId)
                    }
                    .padding(.horizontal, 8)
                }
            } else {
                Text(verbatim: info.note ?? "Safety numbers aren\u{2019}t available yet.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
            }

            Button { showVerify = false } label: {
                Text("Close")
                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                    .foregroundColor(SonarTheme.text2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SNRowPressStyle(cornerRadius: 12))
            .padding(.top, 8)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SonarTheme.surface)
        )
        .padding(.horizontal, 14)
    }
}
