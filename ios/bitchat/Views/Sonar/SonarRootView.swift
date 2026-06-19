//
// SonarRootView.swift
// bitchat
//
// Root of the Sonar prototype reproduction: onboarding gate + stack
// navigation (home → channel/dm/nearby/settings/profile), mirroring
// design/handoff/project/sonar/app.jsx.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarRootView: View {
    @EnvironmentObject private var store: SonarAppStore

    var body: some View {
        Group {
            if store.onboarded {
                #if os(macOS)
                SonarMacRootView()
                #else
                NavigationStack(path: $store.path) {
                    SonarHomeScreen()
                        .sonarBareScreen()
                        .navigationDestination(for: SonarRoute.self) { route in
                            destination(for: route)
                                .sonarBareScreen()
                        }
                }
                #endif
            } else {
                #if os(macOS)
                SonarMacRootView()
                #else
                SonarOnboardingScreen()
                #endif
            }
        }
        .preferredColorScheme(store.isDarkMode ? .dark : .light)
        .tint(SonarTheme.accent)
    }

    @ViewBuilder
    private func destination(for route: SonarRoute) -> some View {
        switch route {
        case .channel(let id):
            SonarChannelScreen(chId: id)
        case .dm(let id):
            SonarDMScreen(peerId: id)
        case .nearby:
            SonarRadarScreen()
        case .settings:
            SonarSettingsScreen()
        case .profile:
            SonarProfileScreen()
        case .call(let id, let video):
            SonarCallScreen(peerId: id, video: video)
        case .contactProfile(let id, let name):
            SonarContactProfileScreen(peerId: id, peerName: name)
        case .groupInfo(let id):
            SonarGroupInfoScreen(peerId: id)
        case .walletActivity:
            SonarWalletActivityScreen()
        }
    }
}

// MARK: - Chrome-less navigation pages (custom Sonar headers replace nav bars)

private struct SonarBareScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
    }
}

private extension View {
    func sonarBareScreen() -> some View {
        modifier(SonarBareScreen())
    }
}
