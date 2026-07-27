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

func snShouldRevealLocalHome(onboarded: Bool, initialLocalHomeReady: Bool) -> Bool {
    !onboarded || initialLocalHomeReady
}

/// MSN-style nudge choreography (docs/SONAR-TRILL.md): 620 ms whole-view
/// shake — translate ±7-9 pt with ±1° rotation about the view centre,
/// decaying over the run. Identity outside (0, 1) so the settled frame is
/// untouched between buzzes.
struct SNTrillShakeEffect: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard progress > 0, progress < 1 else { return ProjectionTransform(.identity) }
        let decay = 1 - progress
        let dx = sin(progress * .pi * 9) * 8.5 * decay
        let dy = cos(progress * .pi * 7) * 4 * decay
        let rot = sin(progress * .pi * 8) * (.pi / 180) * decay
        var transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        transform = transform.rotated(by: rot)
        transform = transform.translatedBy(x: -size.width / 2 + dx, y: -size.height / 2 + dy)
        return ProjectionTransform(transform)
    }
}

struct SonarRootView: View {
    @EnvironmentObject private var store: SonarAppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trillShakeProgress: CGFloat = 0

    var body: some View {
        Group {
            if store.onboarded {
                if snShouldRevealLocalHome(
                    onboarded: store.onboarded,
                    initialLocalHomeReady: store.marmot.initialLocalHomeReady
                ) {
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
                    SonarLocalLaunchSurface()
                        .transition(.identity)
                }
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
        // Whole-app nudge shake, any screen. Skipped under Reduce Motion
        // (the bell + haptics still fire from the store).
        .modifier(SNTrillShakeEffect(progress: trillShakeProgress))
        .onChange(of: store.trillShakeTick) { _ in
            guard !reduceMotion else { return }
            trillShakeProgress = 0
            withAnimation(.easeOut(duration: 0.62)) {
                trillShakeProgress = 1
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { store.activeCall != nil },
            set: { showing in
                if !showing { store.hangupCall() }
            }
        )) {
            if let call = store.activeCall {
                SonarCallScreen(peerId: call.convId, video: call.video)
                    .environmentObject(store)
                    .environment(\.colorScheme, .dark)
            } else {
                Color.clear.ignoresSafeArea()
            }
        }
        #endif
        // Presented at the root so a share hand-off reaches the picker from any
        // screen — the extension opens the app wherever the user left it.
        .snSheet(
            isPresented: Binding(
                get: { store.pendingShare != nil },
                set: { showing in
                    if !showing { store.cancelPendingShare() }
                }
            ),
            title: "Send to…"
        ) {
            if let share = store.pendingShare {
                SNShareSheetContent(share: share) {
                    // `sendPendingShare` already cleared it; this only covers
                    // a close that did not send.
                    store.pendingShare = nil
                    store.rescanPendingSharesAfterDismiss()
                }
                .environmentObject(store)
            }
        }
    }

    private struct SonarLocalLaunchSurface: View {
        var body: some View {
            ZStack {
                Color(sonarHex: 0x060809).ignoresSafeArea()
                Text("sonar")
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundColor(Color(sonarHex: 0xEFF3F4))
            }
            .accessibilityIdentifier("sonar.localLaunchSurface")
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            Text(verbatim: toast)
                .font(SonarTheme.uiFont(size: 13.5, weight: .semibold))
                .foregroundColor(SonarTheme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(SonarTheme.accentFill))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
        case .sendPayment:
            SonarSendPaymentScreen()
        case .paymentStatus(let activityId):
            SonarPaymentStatusScreen(activityId: activityId)
        case .backup:
            SonarBackupScreen()
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
