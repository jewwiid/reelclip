import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var showPaywall: Bool = false
    @State private var isFeedbackPresented = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Brand wordmark lives in StickyBrandHeader
                        // (applied below). settingsHeader previously
                        // held the AppBrandLockup; replaced with the
                        // section break + a single subtitle line so
                        // the page still reads as a Settings stack.
                        Text("Manage your account, subscription, and on-device AI defaults.")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryText)
                        subscriptionCard
                        // AI runtime card — collapsed to a single
                        // status row now that ReelClip is strictly
                        // an iOS-Apple-native app. The previous
                        // "AI Provider" picker (with API-key editors
                        // for Claude, OpenAI, Gemini, MiniMax,
                        // Ollama) is gone — there is no
                        // bring-your-own-key path.
                        aiRuntimeCard
                        clipDefaultsCard
                        feedbackCard
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    StickyBrandHeader()
                }
            }
        }
        .tint(AppPalette.accent)
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSupportSheet()
        }
    }

    // MARK: - AI runtime

    /// Single card explaining the on-device AI runtime. As of
    /// the v72 180 there is exactly one AI runtime — Apple
    /// Intelligence — so this card is informational rather than
    /// configurable. The card shows the runtime name, a status
    /// pill ("Ready" / "Unavailable"), and a one-line note about
    /// the on-device guarantee.
    private var aiRuntimeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "apple.intelligence")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Intelligence")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Powers the AI Assist cut planner")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                appleIntelligenceStatusPill
            }

            Text("ReelClips is strictly an iOS-Apple-native app: every AI run starts and finishes on your device. No API key, no cloud round-trip, nothing leaves your phone. Requires iPhone 15 Pro or later with Apple Intelligence enabled in iOS Settings.")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .premiumSurface()
    }

    @ViewBuilder
    private var appleIntelligenceStatusPill: some View {
        if isAppleIntelligenceAvailable {
            statusPill("Ready", accent: AppPalette.accent)
        } else {
            statusPill("Unavailable", accent: AppPalette.mutedText)
        }
    }

    private var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    private func statusPill(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.black))
            .foregroundStyle(accent == AppPalette.accent ? AppPalette.background : AppPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(accent.opacity(0.85), in: Capsule())
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Feedback")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Report a bug or request a feature")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }

            Text("Send a note directly to the ReelClip team. Nothing is shared until you choose Send.")
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                PolishKit.Haptics.tap(.light).play()
                isFeedbackPresented = true
            } label: {
                Label("Send feedback", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .foregroundStyle(AppPalette.background)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .polishPressFeedback()
        }
        .premiumSurface()
    }

    // MARK: - Default clip settings

    private var clipDefaultsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            defaultsHeader
            defaultModeSelector

            Divider().background(AppPalette.hairline)

            // Mode-specific options — only the controls the
            // selected default mode actually uses. Previously this
            // rendered ALL default fields (Smart/AI length, Splice
            // length, Fixed recipe, AI prompt) regardless of which
            // default mode was chosen, so the user saw options
            // that had no effect on their chosen mode. Mapping:
            //   • Cut       → Fixed recipe (count/duration/space)
            //   • Silence   → Smart/AI clip length
            //   • Splice    → Splice clip length
            //   • AI        → Smart/AI clip length + AI prompt
            // Reset button stays visible in all modes so the user
            // can clear saved defaults without re-picking a mode.
            switch viewModel.defaultCutMode {
            case .fixed:
                fixedModeDefaults
            case .smartPause:
                silenceClipLengthField
            case .highlight:
                spliceClipLengthField
            case .aiAssist:
                aiClipLengthField
                aiPromptDefaults
            }

            resetDefaultsButton
        }
        .premiumSurface()
    }

    /// "Silence clip length" duration selector. Owned by the
    /// Smart Pause (Silence) recipe — independent of the AI
    /// recipe so each can hold its own default.
    private var silenceClipLengthField: some View {
        RecipeDurationSelector(
            title: "Silence clip length",
            systemImage: "timer",
            value: Binding(
                get: { Double(viewModel.defaultSilenceClipDuration) },
                set: { viewModel.setDefaultSilenceClipDuration(Int($0.rounded())) }
            ),
            range: 5...120,
            detail: "Used by Smart Pause when a new project starts. Stored per-recipe so changing it doesn't affect other modes."
        )
    }

    /// "AI clip length" duration selector. Owned by the AI
    /// recipe — independent of the Silence recipe.
    private var aiClipLengthField: some View {
        RecipeDurationSelector(
            title: "AI clip length",
            systemImage: "timer",
            value: Binding(
                get: { Double(viewModel.defaultAiClipDuration) },
                set: { viewModel.setDefaultAiClipDuration(Int($0.rounded())) }
            ),
            range: 5...120,
            detail: "Used by Apple Intelligence when a new project starts. Stored per-recipe so changing it doesn't affect other modes."
        )
    }

    /// "Splice clip length" duration selector. Single use — only
    /// the Splice default mode needs the initial draggable-length
    /// value.
    private var spliceClipLengthField: some View {
        RecipeDurationSelector(
            title: "Splice clip length",
            systemImage: "ruler",
            value: Binding(
                get: { Double(viewModel.defaultHighlightDuration) },
                set: { viewModel.setDefaultHighlightDuration(Int($0.rounded())) }
            ),
            range: 1...120,
            detail: "Initial draggable splice length."
        )
    }

    private var defaultsHeader: some View {
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
                Text("Applied to new projects and Reset Recipe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Spacer(minLength: 0)

            defaultsStatusPill
        }
    }

    private var defaultModeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default mode")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            HStack(spacing: 8) {
                ForEach(CutMode.allCases) { mode in
                    Button {
                        viewModel.setDefaultCutMode(mode)
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
                        .background(
                            viewModel.defaultCutMode == mode ? AppPalette.accent : AppPalette.controlSurface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Default cut mode \(mode.shortTitle)")
                }
            }
        }
    }

    private var fixedModeDefaults: some View {
        FixedRecipeEditor(
            title: "Fixed recipe",
            inputStyle: Binding(
                get: { viewModel.defaultFixedModeInputStyle },
                set: { viewModel.setDefaultFixedModeInputStyle($0) }
            ),
            queryDraft: Binding(
                get: { viewModel.defaultFixedModeQueryDraft },
                set: { viewModel.setDefaultFixedModeQueryDraft($0) }
            ),
            buttonCount: Binding(
                get: { viewModel.defaultFixedModeButtonCount },
                set: { viewModel.setDefaultFixedModeButtonCount($0) }
            ),
            buttonDuration: Binding(
                get: { viewModel.defaultFixedModeButtonDuration },
                set: { viewModel.setDefaultFixedModeButtonDuration($0) }
            ),
            buttonInterval: Binding(
                get: { viewModel.defaultFixedModeButtonInterval },
                set: { viewModel.setDefaultFixedModeButtonInterval($0) }
            ),
            durationRange: 1...120,
            durationDetail: fixedButtonsSummary,
            intervalDetail: fixedButtonsSummary
        )
    }

    private var aiPromptDefaults: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsLabel("AI edit intent", systemImage: "wand.and.stars")

            TextField(
                "Make a fast reel",
                text: Binding(
                    get: { viewModel.defaultEditPrompt },
                    set: { viewModel.setDefaultEditPrompt($0) }
                ),
                axis: .vertical
            )
            .lineLimit(2...4)
            .textInputAutocapitalization(.sentences)
            .font(.subheadline)
            .foregroundStyle(AppPalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
    }

    private var resetDefaultsButton: some View {
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

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 20)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)
        }
    }

    private var fixedButtonsSummary: String {
        "\(viewModel.defaultFixedModeButtonCount) clip\(viewModel.defaultFixedModeButtonCount == 1 ? "" : "s") at \(viewModel.defaultFixedModeButtonDuration)s, every \(viewModel.defaultFixedModeButtonInterval)s"
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AppBrandLockup(
                    iconSize: 40,
                    titleFont: .system(.title3, design: .rounded).weight(.black)
                )

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Manage AI providers, subscription status, and default cut settings.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var subscriptionPlanStatusTitle: String {
        subscriptionStore.tier == .free ? "Current" : "Active"
    }

    private var subscriptionPlanSummary: String {
        switch subscriptionStore.tier {
        case .free:
            return "Starter tools are active. Upgrade for AI planning, clean exports, and longer source clips."
        case .creator:
            return "Creator is active with unlimited AI planning, source-quality exports, 30-min sources, and SRT/VTT handoff."
        }
    }

    private var subscriptionBenefitsTitle: String {
        subscriptionStore.tier == .free ? "Creator unlocks" : "Included benefits"
    }

    private var subscriptionBenefitsPreview: [SettingsPlanBenefit] {
        switch subscriptionStore.tier {
        case .free:
            return [
                SettingsPlanBenefit(systemImage: "brain.head.profile", title: "AI clip planning", body: "Generate cut recipes without the free monthly cap."),
                SettingsPlanBenefit(systemImage: "wand.and.stars", title: "Clean exports", body: "Remove the free-tier watermark at source quality."),
                SettingsPlanBenefit(systemImage: "timer", title: "30-minute sources", body: "Work with longer raw clips in one project."),
                SettingsPlanBenefit(systemImage: "square.stack.3d.up", title: "Multi-scene projects", body: "Stack scenes with separate source videos and export them as a batch.")
            ]
        case .creator:
            return [
                SettingsPlanBenefit(systemImage: "brain.head.profile", title: "Unlimited AI cuts", body: "Plan creator-ready clips without monthly AI limits."),
                SettingsPlanBenefit(systemImage: "4k.tv", title: "Source-quality export", body: "Export clean clips without the free-tier watermark."),
                SettingsPlanBenefit(systemImage: "timer", title: "30-minute sources", body: "Bring in longer footage without splitting first."),
                SettingsPlanBenefit(systemImage: "square.stack.3d.up", title: "Multi-scene projects", body: "Add scenes, switch between them, batch-export the whole project."),
                SettingsPlanBenefit(systemImage: "captions.bubble.fill", title: "SRT/VTT transcripts", body: "Export subtitle files for handoff.")
            ]
        }
    }

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
                    subscriptionPlanStatusTitle,
                    isActive: subscriptionStore.tier != .free
                )
            }

            Text(subscriptionPlanSummary)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text(subscriptionBenefitsTitle)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AppPalette.mutedText)
                    .textCase(.uppercase)
                    .tracking(0.7)

                VStack(spacing: 9) {
                    ForEach(subscriptionBenefitsPreview) { benefit in
                        planBenefitPreviewRow(benefit)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }

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

    private func planBenefitPreviewRow(_ benefit: SettingsPlanBenefit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: benefit.systemImage)
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 24, height: 24)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(benefit.body)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SettingsPlanBenefit: Identifiable {
    var id: String { title }
    let systemImage: String
    let title: String
    let body: String
}
