import SwiftUI
import StoreKit

/// Custom ReelClip subscription sheet. The layout mirrors a compact
/// upgrade popup while still using StoreKit's localized Product data
/// and the app's existing verified purchase path.
struct PaywallView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedProductID: String?
    @State private var hasSeededSelection = false
    @State private var isPurchasing = false
    @State private var isRestoring = false

    /// Single paid tier. Kept as a constant rather than a `@State`
    /// because there's nothing to switch — the Studio tier was
    /// dropped in v2.0 in favour of a simpler two-tier model where
    /// every paid feature lives on Creator.
    private let paywallTier: SubscriptionStore.Tier = .creator

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    topBar
                    hero
                    tierComparisonCard
                    planSelector
                    continueButton
                    legalFooter
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 26)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(AppPalette.accent)
        .presentationBackground(AppPalette.background)
        .presentationDragIndicator(.hidden)
        .task {
            seedSelectionIfNeeded()
        }
        .onChange(of: store.products.map(\.id)) { _, _ in
            seedSelectionIfNeeded()
        }
        .onChange(of: store.tier) { _, newTier in
            if newTier != .free {
                dismiss()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(width: 40, height: 40)
                    .background(AppPalette.controlSurface, in: Circle())
                    .overlay {
                        Circle().stroke(AppPalette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close paywall")

            Spacer(minLength: 0)

            if store.tier != .free {
                Text("\(store.tier.displayName) active")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AppPalette.background)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppPalette.accent, in: Capsule())
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            AppBrandIcon(size: 58)
                .shadow(color: AppPalette.accent.opacity(0.25), radius: 18, x: 0, y: 10)

            VStack(spacing: 5) {
                Text("Upgrade ReelClip")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Unlock AI planning, longer sources, clean exports, and transcript-ready handoff.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
    }

    /// Single Creator-styled card that doubles as the
    /// comparison grid + the headline benefits list. The
    /// accent-filled header carries the section title and
    /// anchors the eye to the upgrade; the body holds the
    /// Free vs Creator row-by-row comparison so the user
    /// can see exactly what they gain — no separate
    /// "Compare plans" card and no separate per-benefit
    /// Single Creator-styled card that doubles as the
    /// comparison grid + the headline benefits list. The
    /// accent-filled header carries the section title and
    /// anchors the eye to the upgrade; the body holds the
    /// Free vs Creator row-by-row comparison so the user
    /// can see exactly what they gain — no separate
    /// "Compare plans" card and no separate per-benefit
    /// body. Both columns are styled neutrally so the
    /// comparison reads as an even-handed info table; the
    /// per-cell check / x / text values tell the upgrade
    /// story without per-column tinting.
    private var tierComparisonCard: some View {
        VStack(spacing: 0) {
            // Accent header — same visual weight as the
            // old standalone "Creator benefits" card.
            // Plain centered text, no icon, no per-column
            // tint — the section reads as a clean
            // comparison card.
            Text("Creator vs Free")
                .font(.headline.weight(.black))
                .foregroundStyle(AppPalette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AppPalette.accent)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Spacer aligns with the icon column in
                    // the rows below.
                    Color.clear
                        .frame(width: 26, height: 1)
                    Text("Feature")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    Text("Free")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .frame(width: 86, alignment: .center)
                    Text("Creator")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .frame(width: 86, alignment: .center)
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 14)
                .background(AppPalette.surface.opacity(0.6))

                ForEach(Array(tierComparisonRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(AppPalette.hairline.opacity(0.6))
                            .frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                    HStack(spacing: 0) {
                        Image(systemName: row.icon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.accent)
                            .frame(width: 26)
                        Text(row.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        tierComparisonCell(value: row.freeValue)
                            .frame(width: 86, alignment: .center)
                        tierComparisonCell(value: row.creatorValue)
                            .frame(width: 86, alignment: .center)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppPalette.accent.opacity(0.45), lineWidth: 1.5)
        }
        .shadow(color: AppPalette.accent.opacity(0.10), radius: 18, x: 0, y: 12)
    }

    /// One cell in the comparison grid. Renders the per-tier
    /// value with a check / x / short text label. `isHighlighted`
    /// is kept on the signature for future per-column tinting
    /// — both columns currently render neutrally so the
    /// check / x / text values tell the upgrade story
    /// without leaning on color.
    @ViewBuilder
    private func tierComparisonCell(value: TierComparisonValue, isHighlighted: Bool = false) -> some View {
        switch value {
        case .yes:
            Image(systemName: "checkmark")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.success)
        case .no:
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.mutedText)
        case .text(let label):
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var planSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose billing")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.mutedText)
                .textCase(.uppercase)
                .tracking(0.8)

            if store.isLoading && store.products.isEmpty {
                loadingPlans
            }

            if !store.isLoading && store.products.isEmpty {
                appStoreUnavailableNotice
            } else if selectedTierOptions.contains(where: { !$0.isPurchasable }) {
                partialPlansNotice
            }

            ForEach(selectedTierOptions) { option in
                Button {
                    selectedProductID = option.id
                    PolishKit.Haptics.selection.play()
                } label: {
                    PaywallPlanRow(
                        option: option,
                        isSelected: selectedProductID == option.id,
                        badge: badge(for: option)
                    )
                }
                .buttonStyle(.plain)
            }

            if let message = store.lastError, !message.isEmpty, !store.products.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption.weight(.bold))
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AppPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var loadingPlans: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppPalette.accent)
            Text("Loading App Store prices...")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var appStoreUnavailableNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(AppPalette.accent)
                Text("App Store connection needed")
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
            }

            Text(store.lastError ?? "TestFlight purchases require live App Store pricing from App Store Connect.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(AppPalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var partialPlansNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.accent)
            Text("Some billing options are still connecting to the App Store. Any option with live pricing can be purchased now.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var continueButton: some View {
        Button {
            if selectedOption?.isPurchasable == true {
                purchaseSelectedProduct()
            } else {
                retryProducts()
            }
        } label: {
            HStack(spacing: 10) {
                if isPurchasing || (store.isLoading && selectedOption?.isPurchasable != true) {
                    ProgressView()
                        .tint(AppPalette.background)
                }
                Text(continueButtonTitle)
                    .font(.headline.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(AppPalette.background)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                selectedOption == nil || isPurchasing || store.isLoading ? AppPalette.disabledSurface : AppPalette.accent,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedOption == nil || isPurchasing || store.isLoading)
        .polishPressFeedback()
        .accessibilityHint(selectedOption?.isPurchasable == true ? "Purchases the selected ReelClip plan" : "Retries loading App Store pricing")
    }

    private var legalFooter: some View {
        VStack(spacing: 10) {
            Button {
                restorePurchases()
            } label: {
                HStack(spacing: 6) {
                    if isRestoring {
                        ProgressView()
                            .tint(AppPalette.accent)
                    }
                    Text(isRestoring ? "Restoring..." : "Restore purchases")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)

            HStack(spacing: 12) {
                Button("Terms") {
                    openURL(PaywallLegalLinks.termsOfUseURL)
                }
                Button("Privacy") {
                    openURL(PaywallLegalLinks.privacyPolicyURL)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppPalette.secondaryText)

            Text(selectedOption?.cadence == .lifetime ? "Lifetime is a one-time purchase and does not renew." : "Subscription can be canceled anytime.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppPalette.mutedText)
                .multilineTextAlignment(.center)

            Text(selectedOption?.cadence == .lifetime ? "Lifetime unlock stays tied to your Apple ID and can be restored on supported devices." : "Auto-renews unless canceled at least 24 hours before the end of the current period.")
                .font(.caption2)
                .foregroundStyle(AppPalette.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private var productOptions: [PaywallPlanOption] {
        let productsByID = Dictionary(uniqueKeysWithValues: store.products.map { ($0.id, $0) })
        return PaywallPlanCatalog.all.map { catalog in
            PaywallPlanOption(catalog: catalog, product: productsByID[catalog.productID.rawValue])
        }
    }

    private var selectedTierOptions: [PaywallPlanOption] {
        // Only one tier now — the Studio options were dropped in
        // v2.0. Sort by cadence so weekly/monthly/yearly/lifetime
        // appear in a predictable order for the user.
        productOptions
            .filter { $0.tier == paywallTier }
            .sorted { $0.cadence.sortIndex < $1.cadence.sortIndex }
    }

    private var selectedOption: PaywallPlanOption? {
        guard let selectedProductID else { return nil }
        return selectedTierOptions.first { $0.id == selectedProductID }
    }

    private var continueButtonTitle: String {
        if isPurchasing {
            return "Purchasing..."
        }
        if selectedOption?.isPurchasable == true {
            return "Continue with \(paywallTier.displayName)"
        }
        if store.isLoading {
            return "Loading App Store..."
        }
        return "Retry App Store"
    }

    private func seedSelectionIfNeeded() {
        if !hasSeededSelection {
            hasSeededSelection = true
        }
        selectDefaultProduct(preferCurrent: true)
    }

    private func selectDefaultProduct(preferCurrent: Bool) {
        let options = selectedTierOptions
        guard !options.isEmpty else {
            selectedProductID = nil
            return
        }

        if preferCurrent,
           let selectedProductID,
           options.contains(where: { $0.id == selectedProductID }) {
            return
        }

        // Default to the best-value option. Yearly saves 50% vs
        // monthly and is the recommended pick in nearly every
        // subscription app — surfacing it first nudges users
        // toward the higher-LTV plan without hiding the other
        // cadences. Falls back to monthly / weekly / lifetime
        // depending on which the user has configured in App Store
        // Connect.
        selectedProductID = options.first(where: { $0.cadence == .yearly })?.id
            ?? options.first(where: { $0.cadence == .monthly })?.id
            ?? options.first?.id
    }

    private func purchaseSelectedProduct() {
        guard let product = selectedOption?.product, !isPurchasing else {
            retryProducts()
            return
        }
        isPurchasing = true
        PolishKit.Haptics.tap(.medium).play()

        Task {
            let purchased = await store.purchase(product)
            await MainActor.run {
                isPurchasing = false
                if purchased {
                    PolishKit.Haptics.tap(.medium).play()
                    dismiss()
                } else {
                    PolishKit.Haptics.tap(.light).play()
                }
            }
        }
    }

    private func retryProducts() {
        guard !store.isLoading else { return }
        PolishKit.Haptics.tap(.light).play()
        Task {
            await store.refresh()
            await MainActor.run {
                seedSelectionIfNeeded()
            }
        }
    }

    private func restorePurchases() {
        guard !isRestoring else { return }
        isRestoring = true
        PolishKit.Haptics.tap(.light).play()

        Task {
            await store.restore()
            await MainActor.run {
                isRestoring = false
                if store.tier != .free {
                    dismiss()
                }
            }
        }
    }

    private func badge(for option: PaywallPlanOption) -> String? {
        // Lifetime: the "Pay once. Own it forever." affordance is
        // the badge — the user is opting out of any future price
        // changes, so call it out explicitly.
        if option.cadence == .lifetime {
            return "Pay once"
        }

        guard option.cadence == .yearly else {
            return option.hasIntroOffer ? "Trial" : nil
        }

        guard let monthly = productOptions.first(where: { $0.tier == option.tier && $0.cadence == .monthly }) else {
            return "Best value"
        }

        let monthlyPrice = monthly.priceValue
        let annualPrice = option.priceValue
        let yearlyMonthlyTotal = monthlyPrice * 12

        guard yearlyMonthlyTotal > 0, annualPrice > 0, annualPrice < yearlyMonthlyTotal else {
            return "Best value"
        }

        let percent = Int(((1 - (annualPrice / yearlyMonthlyTotal)) * 100).rounded())
        return "Save \(percent)%"
    }

    private func tierShortLine(for tier: SubscriptionStore.Tier) -> String {
        switch tier {
        case .free:
            return "Starter"
        case .creator:
            return "AI + 4K"
        }
    }

    /// Side-by-side Free vs Creator comparison rows. Each
    /// row carries the feature label + a per-tier value
    /// (yes / no / short text like "3/mo"). Order here is
    /// the order the user sees them in the comparison card.
    /// Keep it tight — 6-7 rows is the sweet spot; the
    /// deeper benefit explanations that used to live in
    /// `PaywallBenefit` were collapsed into the per-row
    /// `tierComparisonCell` text (e.g. "5 min" / "30 min"
    /// instead of separate "30-minute sources" cards).
    private var tierComparisonRows: [TierComparisonRow] {
        [
            TierComparisonRow(
                id: "ai",
                icon: "brain.head.profile",
                label: "AI plans",
                freeValue: .text("3 / mo"),
                creatorValue: .text("Unlimited")
            ),
            TierComparisonRow(
                id: "watermark",
                icon: "rectangle.dashed",
                label: "Watermark",
                freeValue: .yes,
                creatorValue: .no
            ),
            TierComparisonRow(
                id: "source-duration",
                icon: "timer",
                label: "Source length",
                freeValue: .text("5 min"),
                creatorValue: .text("30 min")
            ),
            TierComparisonRow(
                id: "resolution",
                icon: "4k.tv",
                label: "Export quality",
                freeValue: .text("720p"),
                creatorValue: .text("Source")
            ),
            TierComparisonRow(
                id: "multi-scene",
                icon: "square.stack.3d.up",
                label: "Multi-scene",
                freeValue: .no,
                creatorValue: .yes
            ),
            TierComparisonRow(
                id: "srt-vtt",
                icon: "captions.bubble.fill",
                label: "SRT / VTT",
                freeValue: .no,
                creatorValue: .yes
            )
        ]
    }
}

/// One row in the Free vs Creator comparison grid. Carries
/// the feature icon + label + a per-tier value. The
/// `freeValue` and `creatorValue` use the same enum so the
/// cell renderer can pick the right visual treatment
/// (check, x, or short text) without per-row branching.
private struct TierComparisonRow: Identifiable {
    let id: String
    let icon: String
    let label: String
    let freeValue: TierComparisonValue
    let creatorValue: TierComparisonValue
}

/// Cell value in the comparison grid. Three states:
///   .yes      → green check (or accent when on Creator side)
///   .no       → muted x
///   .text(s)  → short label (e.g. "3 / mo", "720p",
///               "30 min"). The renderer keeps it one line
///               with a minimum scale factor so long values
///               still fit on the iPhone SE width.
private enum TierComparisonValue {
    case yes
    case no
    case text(String)
}

private struct PaywallPlanRow: View {
    let option: PaywallPlanOption
    let isSelected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(option.title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(AppPalette.background)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(AppPalette.accent, in: Capsule())
                    }
                }

                Text(option.subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(option.displayPrice)
                    .font(.headline.monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(option.cadence.priceSuffix)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AppPalette.mutedText)

                if !option.isPurchasable {
                    Text("pending")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.accent)
                        .lineLimit(1)
                }
            }

            ZStack {
                Circle()
                    .stroke(isSelected ? AppPalette.accent : AppPalette.secondaryText.opacity(0.7), lineWidth: 2)
                    .frame(width: 24, height: 24)

                if isSelected {
                    Circle()
                        .fill(AppPalette.accent)
                        .frame(width: 12, height: 12)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? AppPalette.accent : AppPalette.hairline, lineWidth: isSelected ? 1.8 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private enum PaywallCadence {
    case weekly
    case monthly
    case yearly
    case lifetime

    var sortIndex: Int {
        switch self {
        case .weekly:  return 0
        case .monthly: return 1
        case .yearly:  return 2
        case .lifetime: return 3
        }
    }

    var titlePrefix: String {
        switch self {
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Annual"
        case .lifetime: return "Lifetime"
        }
    }

    var priceSuffix: String {
        switch self {
        case .weekly:  return "/ week"
        case .monthly: return "/ month"
        case .yearly:  return "/ year"
        case .lifetime: return "one-time"
        }
    }

    var billingLine: String {
        switch self {
        case .weekly:  return "Renews weekly. Cancel anytime."
        case .monthly: return "Renews monthly. Cancel anytime."
        case .yearly:  return "Renews yearly. Cancel anytime."
        case .lifetime: return "Pay once. Own it forever."
        }
    }
}

private struct PaywallPlanCatalog: Identifiable {
    let productID: SubscriptionStore.ProductID
    let tier: SubscriptionStore.Tier
    let cadence: PaywallCadence
    let displayPrice: String
    let priceValue: Double
    let hasIntroOffer: Bool

    var id: String { productID.rawValue }

    /// Active Creator SKUs. Studio weekly/monthly/yearly/lifetime
    /// were dropped in v2.0 — see `SubscriptionStore.ProductID` for
    /// the legacy recognition shim (Studio lifetime buyers still
    /// resolve to Creator via `tierForProductID`).
    static let all: [PaywallPlanCatalog] = [
        PaywallPlanCatalog(productID: .creatorWeekly, tier: .creator, cadence: .weekly, displayPrice: "$2.99", priceValue: 2.99, hasIntroOffer: false),
        PaywallPlanCatalog(productID: .creatorMonthly, tier: .creator, cadence: .monthly, displayPrice: "$9.99", priceValue: 9.99, hasIntroOffer: true),
        PaywallPlanCatalog(productID: .creatorYearly, tier: .creator, cadence: .yearly, displayPrice: "$59.99", priceValue: 59.99, hasIntroOffer: false),
        PaywallPlanCatalog(productID: .creatorLifetime, tier: .creator, cadence: .lifetime, displayPrice: "$149.99", priceValue: 149.99, hasIntroOffer: false)
    ]
}

private struct PaywallPlanOption: Identifiable {
    let catalog: PaywallPlanCatalog
    let product: Product?
    let tier: SubscriptionStore.Tier
    let cadence: PaywallCadence

    var id: String { catalog.productID.rawValue }
    var displayPrice: String { product?.displayPrice ?? catalog.displayPrice }
    var priceValue: Double {
        if let product {
            return Double(truncating: NSDecimalNumber(decimal: product.price))
        }
        return catalog.priceValue
    }
    var isPurchasable: Bool { product != nil }

    init(catalog: PaywallPlanCatalog, product: Product?) {
        self.catalog = catalog
        self.product = product
        self.tier = catalog.tier
        self.cadence = catalog.cadence
    }

    var title: String {
        cadence.titlePrefix
    }

    var subtitle: String {
        let base: String
        if cadence == .lifetime {
            base = "One-time purchase. \(cadence.billingLine)"
        } else if hasIntroOffer {
            base = "Free trial available. \(cadence.billingLine)"
        } else {
            base = cadence.billingLine
        }

        return isPurchasable ? base : "\(base) App Store pricing pending."
    }

    var hasIntroOffer: Bool {
        product?.subscription?.introductoryOffer != nil || catalog.hasIntroOffer
    }
}

private enum PaywallLegalLinks {
    // Replace with ReelClip-hosted URLs before App Store submission if
    // product-specific legal pages live elsewhere.
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://www.apple.com/legal/privacy/en-ww/")!
}
