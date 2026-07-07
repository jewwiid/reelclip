import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var showPaywall: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHeader
                        subscriptionCard
                        clipDefaultsCard
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(AppPalette.accent)
    }

    // MARK: - Default clip settings

    private var clipDefaultsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Default clip settings")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Applied to every new project")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                defaultsStatusPill
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cut mode")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)

                HStack(spacing: 8) {
                    ForEach(CutMode.allCases) { mode in
                        Button {
                            viewModel.defaultCutMode = mode
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.symbolName)
                                    .font(.subheadline.weight(.bold))
                                Text(mode.shortTitle)
                                    .font(.caption.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(viewModel.defaultCutMode == mode ? AppPalette.background : AppPalette.primaryText)
                            .background(viewModel.defaultCutMode == mode ? AppPalette.accent : AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Default cut mode \(mode.shortTitle)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default seconds per clip")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryText)
                    Spacer()
                    Text("\(viewModel.defaultSegmentLength)s")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                }

                Slider(
                    value: Binding(
                        get: { Double(viewModel.defaultSegmentLength) },
                        set: { viewModel.defaultSegmentLength = Int($0.rounded()) }
                    ),
                    in: 5...120,
                    step: 1
                )
                .tint(AppPalette.accent)
            }

            Button {
                viewModel.resetClipDefaults()
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(AppPalette.primaryText)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .premiumSurface()
    }

    private var defaultsStatusPill: some View {
        Text("Auto-applied")
            .font(.caption2.weight(.black))
            .foregroundStyle(AppPalette.background)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AppPalette.accent, in: Capsule())
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            Text("Preferences")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)

            Text("Manage your subscription and default clip settings.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(3)
        }
        .premiumSurface()
    }

    private func settingsStatusPill(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.black))
            .foregroundStyle(isActive ? AppPalette.background : AppPalette.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isActive ? AppPalette.accent : AppPalette.raisedSurface, in: Capsule())
    }

    // MARK: - Subscription

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                Text("Plan")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(subscriptionStore.tier.displayName)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 0)
                settingsStatusPill(
                    subscriptionStore.tier == .free ? "Free" : "Active",
                    isActive: subscriptionStore.tier != .free
                )
            }

            Text(subscriptionStore.tier.tagline)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if subscriptionStore.tier == .free {
                Button {
                    PolishKit.Haptics.tap(.medium).play()
                    showPaywall = true
                } label: {
                    Label("Upgrade to Creator", systemImage: "arrow.up.right.circle.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(AppPalette.background)
                        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .polishPressFeedback()
            } else {
                Button {
                    showPaywall = true
                } label: {
                    Label("Manage subscription", systemImage: "creditcard")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(AppPalette.primaryText)
                        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .polishPressFeedback()

                Button {
                    Task { await subscriptionStore.restore() }
                } label: {
                    Text("Restore purchases")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.mutedText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionStore)
        }
    }
}