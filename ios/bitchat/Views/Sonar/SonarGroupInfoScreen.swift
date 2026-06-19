//
// SonarGroupInfoScreen.swift
// bitchat
//
// Group info screen: encryption banner, member list with crown/you badges,
// inline add-member field, leave group with confirmation. Ported from the
// Compose Multiplatform SonarGroupInfoScreen.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarGroupInfoScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String

    @State private var addDraft = ""
    @State private var leaveSheet = false

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var members: [SNGroupContact] { store.groupMemberContacts(forConversationId: peerId) }

    private var groupTitle: String {
        let row = store.dmRows.first { $0.id == peerId }
        return row?.title ?? peer.name
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(hairline: false, onBack: { store.pop() }) {
                SNHeaderName("Group info")
            }

            ScrollView {
                VStack(spacing: 0) {
                    // ── Hero ──
                    VStack(spacing: 0) {
                        SonarAvatar(name: groupTitle, size: 80)
                        Text(verbatim: groupTitle)
                            .font(SonarTheme.uiFont(size: 22, weight: .black))
                            .foregroundColor(SonarTheme.text)
                            .padding(.top, 8)
                        Text(verbatim: "\(members.count + 1) members")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text2)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                    // ── Encryption banner ──
                    SNBanner(
                        icon: .lock, tone: .enc,
                        bold: "End-to-end encrypted",
                        rest: " — only group members can read messages"
                    )
                    .padding(.bottom, 8)

                    // ── Members ──
                    SNSectionLabel("Members")
                    SNSettingsCard {
                        // "You" row
                        HStack(spacing: 12) {
                            SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: store.nick.isEmpty ? "you" : store.nick)
                                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                                        .foregroundColor(SonarTheme.text)
                                    Text("you")
                                        .font(SonarTheme.uiFont(size: 11, weight: .bold))
                                        .foregroundColor(SonarTheme.accentDeep)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(SonarTheme.accentSoft))
                                }
                                Text(verbatim: SonarAppStore.shortNpub(store.marmot.npub ?? ""))
                                    .font(SonarTheme.uiFont(size: 12.5))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 64)
                        }

                        // Other members
                        ForEach(Array(members.enumerated()), id: \.element.id) { i, member in
                            Button {
                                store.push(.contactProfile(member.npub, member.title))
                            } label: {
                                HStack(spacing: 12) {
                                    SonarAvatar(name: member.title, size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: member.title)
                                            .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                                            .foregroundColor(SonarTheme.text)
                                            .lineLimit(1)
                                        Text(verbatim: member.subtitle)
                                            .font(SonarTheme.uiFont(size: 12.5))
                                            .foregroundColor(SonarTheme.text2)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    SNIcon(name: .chevron, size: 14, weight: 2.2)
                                        .foregroundColor(SonarTheme.text3)
                                }
                                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if i < members.count - 1 {
                                        Rectangle().fill(SonarTheme.hairline).frame(height: 1).padding(.leading, 64)
                                    }
                                }
                            }
                            .buttonStyle(SNRowPressStyle())
                        }
                    }

                    // ── Add member ──
                    SNSectionLabel("Add member")
                    HStack(spacing: 8) {
                        TextField(
                            "",
                            text: $addDraft,
                            prompt: Text(verbatim: "npub1\u{2026}").foregroundColor(SonarTheme.text3)
                        )
                        .textFieldStyle(.plain)
                        .font(SonarTheme.monoFont(size: 13))
                        .foregroundColor(SonarTheme.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

                        Button {
                            let npub = addDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard npub.hasPrefix("npub1"),
                                  let groupId = store.marmotGroupId(peerId) else { return }
                            addDraft = ""
                            Task { try? await store.marmot.addGroupMembers([npub], to: groupId) }
                        } label: {
                            SNIcon(name: .plus, size: 19, weight: 2.1)
                                .foregroundColor(addDraft.hasPrefix("npub1") ? SonarTheme.onAccent : SonarTheme.text3)
                                .frame(width: 42, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(addDraft.hasPrefix("npub1") ? SonarTheme.accentFill : SonarTheme.surface2)
                                )
                        }
                        .buttonStyle(SNScaleStyle(scale: 0.94))
                        .disabled(!addDraft.hasPrefix("npub1"))
                    }
                    .padding(.horizontal, 14)

                    // ── Actions ──
                    SNSectionLabel("Actions")
                    SNSettingsCard {
                        SNSettingsRow(
                            icon: .trash, tone: .red, label: "Leave group",
                            danger: true, trail: .none, divider: false
                        ) {
                            leaveSheet = true
                        }
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .snSheet(isPresented: $leaveSheet, title: "Leave group") {
            VStack(spacing: 12) {
                Text("Are you sure you want to leave this group? You won\u{2019}t be able to read or send messages anymore.")
                    .font(SonarTheme.uiFont(size: 14))
                    .lineSpacing(14 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                SNPrimaryButton(label: "Leave group", danger: true) {
                    leaveSheet = false
                    if let groupId = store.marmotGroupId(peerId) {
                        Task { try? await store.marmot.leaveGroup(groupId) }
                    }
                    store.pop()
                    store.pop()
                }
                .padding(.horizontal, 8)
                SNGhostButton(label: "Cancel") {
                    leaveSheet = false
                }
            }
        }
    }
}
