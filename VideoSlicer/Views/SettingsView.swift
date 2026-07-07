import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var selectedProvider: AIProvider = .appleIntelligence
    @State private var keyDraft: String = ""
    @State private var ollamaHost: String = "http://localhost:11434"
    @State private var saveStatus: String?
    @State private var showPaywall: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHeader
                        subscriptionCard
                        aiProviderCard
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
        .onAppear {
            selectedProvider = viewModel.selectedAIProvider
            keyDraft = viewModel.credential(for: selectedProvider) ?? ""
            if let host = viewModel.credential(for: .ollama), !host.isEmpty {
                ollamaHost = host
            }
        }
    }

    // MARK: - AI Provider

    private var aiProviderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "brain")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI provider")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Powers the AI Assist cut planner")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                providerStatusPill
            }

            ForEach(AIProvider.allCases) { provider in
                providerRow(provider)
            }

            if selectedProvider.requiresAPIKey {
                Divider().background(AppPalette.hairline)
                providerKeyEditor
            } else if selectedProvider == .ollama {
                Divider().background(AppPalette.hairline)
                ollamaEditor
            }
        }
        .premiumSurface()
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let isSelected = selectedProvider == provider
        let configured = viewModel.hasConfiguredCredential(for: provider)
        let available = isProviderAvailable(provider)

        return Button {
            selectedProvider = provider
            keyDraft = viewModel.credential(for: provider) ?? ""
            viewModel.selectedAIProvider = provider
            saveStatus = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? AppPalette.accent : AppPalette.controlSurface)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.background)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                        if configured {
                            statusPill("Ready", accent: AppPalette.accent)
                        } else if provider.requiresAPIKey {
                            statusPill("Needs key", accent: AppPalette.mutedText)
                        } else if !available {
                            statusPill("Unavailable", accent: AppPalette.mutedText)
                        } else {
                            statusPill("Free", accent: AppPalette.accent)
                        }
                    }
                    Text(provider.blurb)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                (isSelected ? AppPalette.accent.opacity(0.10) : AppPalette.controlSurface),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? AppPalette.accent : AppPalette.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName) provider\(isSelected ? ", selected" : "")")
    }

    private var providerStatusPill: some View {
        let configured = viewModel.hasConfiguredCredential(for: selectedProvider)
        let available = isProviderAvailable(selectedProvider)
        let label: String
        let accent: Color
        if configured {
            label = "Ready"; accent = AppPalette.accent
        } else if selectedProvider.requiresAPIKey {
            label = "Needs key"; accent = AppPalette.mutedText
        } else if !available {
            label = "Unavailable"; accent = AppPalette.mutedText
        } else {
            label = "Free"; accent = AppPalette.accent
        }
        return statusPill(label, accent: accent)
    }

    private func statusPill(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.black))
            .foregroundStyle(accent == AppPalette.accent ? AppPalette.background : AppPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(accent.opacity(0.85), in: Capsule())
    }

    @ViewBuilder
    private var providerKeyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API key")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer()
                if let url = selectedProvider.signupURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2.weight(.bold))
                            Text("Get \(selectedProvider.displayName) key")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.accent)
                    }
                }
            }

            SecureField(placeholderForSelected, text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .foregroundStyle(AppPalette.primaryText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

            HStack(spacing: 10) {
                Button {
                    saveKey()
                } label: {
                    Label("Save Key", systemImage: "key.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(trimmedKey.isEmpty ? AppPalette.mutedText : AppPalette.background)
                .background(trimmedKey.isEmpty ? AppPalette.disabledSurface : AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(trimmedKey.isEmpty)

                Button {
                    try? viewModel.saveCredential("", for: selectedProvider)
                    keyDraft = ""
                    saveStatus = "Removed."
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("Remove key")
            }

            if let saveStatus {
                Text(saveStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }
        }
    }

    @ViewBuilder
    private var ollamaEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ollama endpoint")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            TextField("http://localhost:11434", text: $ollamaHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .foregroundStyle(AppPalette.primaryText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

            Button {
                let trimmed = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
                try? viewModel.saveCredential(trimmed, for: .ollama)
                saveStatus = "Saved."
            } label: {
                Label("Save Endpoint", systemImage: "network")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(AppPalette.background)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(ollamaHost.isEmpty)

            Text("Make sure Ollama is running locally and you've pulled a model: `ollama pull llama3.2-vision`")
                .font(.caption)
                .foregroundStyle(AppPalette.mutedText)
        }
    }

    private var placeholderForSelected: String {
        switch selectedProvider {
        case .minimax: return "Paste MiniMax API key"
        case .claude: return "Paste Anthropic API key (sk-ant-…)"
        case .openai: return "Paste OpenAI API key (sk-…)"
        case .gemini: return "Paste Gemini API key"
        case .ollama: return "Endpoint URL"
        case .appleIntelligence: return ""
        }
    }

    private var trimmedKey: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey() {
        do {
            try viewModel.saveCredential(trimmedKey, for: selectedProvider)
            saveStatus = "Saved."
        } catch {
            saveStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    private func isProviderAvailable(_ provider: AIProvider) -> Bool {
        switch provider {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) { return true }
            #endif
            return false
        default:
            return true
        }
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
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .bold))
                Text("Secure credentials")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            Text("API Keys")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)

            Text("User-owned AI keys are saved in the iOS Keychain and kept on this device. Apple Intelligence runs on-device for free.")
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