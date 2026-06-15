import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    private var backgroundColor: Color {
        SonarTheme.bg
    }

    private var textColor: Color {
        SonarTheme.text
    }

    private var secondaryTextColor: Color {
        SonarTheme.text2
    }
    
    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"

        enum Features {
            static let title: LocalizedStringKey = "app_info.features.title"
            static let offlineComm = AppInfoFeatureInfo(
                icon: "wifi.slash",
                title: "app_info.features.offline.title",
                description: "app_info.features.offline.description"
            )
            static let encryption = AppInfoFeatureInfo(
                icon: "lock.shield",
                title: "app_info.features.encryption.title",
                description: "app_info.features.encryption.description"
            )
            static let extendedRange = AppInfoFeatureInfo(
                icon: "antenna.radiowaves.left.and.right",
                title: "app_info.features.extended_range.title",
                description: "app_info.features.extended_range.description"
            )
            static let mentions = AppInfoFeatureInfo(
                icon: "at",
                title: "app_info.features.mentions.title",
                description: "app_info.features.mentions.description"
            )
            static let favorites = AppInfoFeatureInfo(
                icon: "star.fill",
                title: "app_info.features.favorites.title",
                description: "app_info.features.favorites.description"
            )
            static let geohash = AppInfoFeatureInfo(
                icon: "number",
                title: "app_info.features.geohash.title",
                description: "app_info.features.geohash.description"
            )
        }

        enum Privacy {
            static let title: LocalizedStringKey = "app_info.privacy.title"
            static let noTracking = AppInfoFeatureInfo(
                icon: "eye.slash",
                title: "app_info.privacy.no_tracking.title",
                description: "app_info.privacy.no_tracking.description"
            )
            static let ephemeral = AppInfoFeatureInfo(
                icon: "shuffle",
                title: "app_info.privacy.ephemeral.title",
                description: "app_info.privacy.ephemeral.description"
            )
            static let panic = AppInfoFeatureInfo(
                icon: "hand.raised.fill",
                title: "app_info.privacy.panic.title",
                description: "app_info.privacy.panic.description"
            )
        }

        enum HowToUse {
            static let title: LocalizedStringKey = "app_info.how_to_use.title"
            static let instructions: [LocalizedStringKey] = [
                "app_info.how_to_use.set_nickname",
                "app_info.how_to_use.change_channels",
                "app_info.how_to_use.open_sidebar",
                "app_info.how_to_use.start_dm",
                "app_info.how_to_use.clear_chat",
                "app_info.how_to_use.commands"
            ]
        }

    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("app_info.close")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Sonar mark + name + tagline
            VStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(SonarTheme.accentFill)
                    .frame(width: 74, height: 74)
                    .overlay(
                        Image(systemName: "circle.circle")
                            .font(.system(size: 38, weight: .light))
                            .foregroundColor(SonarTheme.onAccent)
                    )

                Text(Strings.appName)
                    .font(SonarTheme.uiFont(size: 30, weight: .heavy))
                    .foregroundColor(textColor)

                Text(Strings.tagline)
                    .font(SonarTheme.uiFont(size: 15))
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)

            // How to Use
            SectionHeader(Strings.HowToUse.title)
            AppInfoCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Strings.HowToUse.instructions.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction)
                    }
                }
                .font(SonarTheme.uiFont(size: 14))
                .foregroundColor(textColor)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Features
            SectionHeader(Strings.Features.title)
            AppInfoCard {
                VStack(alignment: .leading, spacing: 0) {
                    FeatureRow(info: Strings.Features.offlineComm)
                    FeatureRow(info: Strings.Features.encryption)
                    FeatureRow(info: Strings.Features.extendedRange)
                    FeatureRow(info: Strings.Features.favorites)
                    FeatureRow(info: Strings.Features.geohash)
                    FeatureRow(info: Strings.Features.mentions, isLast: true)
                }
            }

            // Privacy
            SectionHeader(Strings.Privacy.title)
            AppInfoCard {
                VStack(alignment: .leading, spacing: 0) {
                    FeatureRow(info: Strings.Privacy.noTracking)
                    FeatureRow(info: Strings.Privacy.ephemeral)
                    FeatureRow(info: Strings.Privacy.panic, isLast: true)
                }
            }
        }
        .padding(14)
    }
}

/// Grouped settings card (st-card pattern from the Sonar prototype).
struct AppInfoCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: SonarTheme.cardRadius, style: .continuous)
                    .fill(SonarTheme.surface)
                    .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
            )
            .padding(.bottom, 8)
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(SonarTheme.uiFont(size: 12.5, weight: .bold))
            .foregroundColor(SonarTheme.text3)
            .textCase(.uppercase)
            .kerning(0.6)
            .padding(.top, 8)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }
}

struct FeatureRow: View {
    let info: AppInfoFeatureInfo
    var isLast: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SonarTheme.accentSoft)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: info.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SonarTheme.accentDeep)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(SonarTheme.uiFont(size: 15, weight: .semibold))
                    .foregroundColor(SonarTheme.text)

                Text(info.description)
                    .font(SonarTheme.uiFont(size: 12.5))
                    .foregroundColor(SonarTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(SonarTheme.hairline)
                    .frame(height: 1)
                    .padding(.leading, 56)
            }
        }
    }
}

#Preview("Default") {
    AppInfoView()
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environment(\.sizeCategory, .extraSmall)
}
