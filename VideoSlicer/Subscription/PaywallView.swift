import SwiftUI
import StoreKit

/// Paywall sheet. Wraps the system `SubscriptionStoreView` so we inherit
/// StoreKit 2's intro-offer handling, family-share UI, refund handling, and
/// App Store screenshot policy.
///
/// On a successful purchase (or restore) the sheet auto-dismisses.
struct PaywallView: View {
    @EnvironmentObject var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Use a black scrim behind the system store view so the abrupt
            // white background Apple ships doesn't flash.
            AppPalette.background.ignoresSafeArea()
            content
        }
        .tint(AppPalette.accent)
        .onChange(of: store.tier) { _, newTier in
            // Any non-free tier means they bought something → close sheet.
            if newTier != .free { dismiss() }
        }
        .task {
            await store.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        SubscriptionStoreView(groupID: SubscriptionStore.groupID)
            .backgroundStyle(AppPalette.controlSurface)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppPalette.primaryText)
                }
            }
            .overlay(alignment: .bottom) {
                legalFooter
            }
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Auto-renews unless cancelled at least 24 hours before the end of the period.")
                .font(.caption2)
                .foregroundStyle(AppPalette.mutedText)
                .multilineTextAlignment(.center)
            Button("Restore purchases") {
                Task { await store.restore() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppPalette.accent)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [AppPalette.background.opacity(0), AppPalette.background],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Custom product card styling applied via `SubscriptionStoreView`'s
/// `subscriptionIcon` / backgroundStyle closures. Because we want a totally
/// bespoke look that matches ReelClip's palette, we render our own card and
/// pass it through `ProductView` style instead.
struct ProductCardStyle: View {
    let subscription: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: tierIcon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.background)
                    .frame(width: 28, height: 28)
                    .background(AppPalette.accent, in: Circle())
                Text(tierName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 0)
                if isYearly {
                    Text("Save 40%")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.background)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppPalette.accent, in: Capsule())
                }
            }
            Text(tierTagline)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(subscription.displayPrice)
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                Text(period)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.mutedText)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var isYearly: Bool {
        subscription.id.contains("yearly")
    }

    private var tierName: String {
        switch subscription.id {
        case let id where id.hasPrefix("rc.studio"): return "Studio"
        default: return "Creator"
        }
    }

    private var tierIcon: String {
        switch subscription.id {
        case let id where id.hasPrefix("rc.studio"): return "sparkles"
        default: return "scissors"
        }
    }

    private var tierTagline: String {
        switch subscription.id {
        case let id where id.hasPrefix("rc.studio"):
            return "Priority renders, 30-min sources, SRT/VTT transcripts."
        default:
            return "Unlimited AI plans, Apple Intelligence, 4K export, all providers."
        }
    }

    private var period: String {
        isYearly ? "/year" : "/month"
    }
}
