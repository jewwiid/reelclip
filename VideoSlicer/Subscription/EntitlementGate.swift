import SwiftUI

/// A wrapping view that either renders its child as-is (when the user has
/// the required tier) or renders the child inside a button that surfaces
/// the paywall. The user-friendly path is:
///     let view = ActionButton(...)                  // gated action
///     EntitlementGate(required: .creator) { view }  // wraps it
struct EntitlementGate<Content: View>: View {
    @EnvironmentObject var store: SubscriptionStore
    let required: SubscriptionStore.Tier
    let content: Content
    @State private var showPaywall = false

    init(required: SubscriptionStore.Tier, @ViewBuilder content: () -> Content) {
        self.required = required
        self.content = content()
    }

    var body: some View {
        Group {
            if store.hasAccess(to: required) {
                content
            } else {
                Button {
                    showPaywall = true
                } label: {
                    content
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(store)
        }
    }
}

/// Convenience for the common "tap a button to do a gated action" pattern.
///
/// Usage:
///     Button("Plan with AI") { ... }
///         .paywalled(.creator, store: store, action: { viewModel.runAI() })
extension View {
    /// Tap-to-act view that surfaces the paywall when the user lacks the
    /// required tier. When the gate is satisfied, the closure runs normally.
    /// Tap before subscribing always surfaces the paywall first.
    func paywalled(
        _ required: SubscriptionStore.Tier,
        store: SubscriptionStore,
        perform action: @escaping () -> Void
    ) -> some View {
        self.modifier(PaywalledTapModifier(required: required, store: store, action: action))
    }
}

struct PaywalledTapModifier: ViewModifier {
    let required: SubscriptionStore.Tier
    let store: SubscriptionStore
    let action: () -> Void
    @State private var showPaywall = false

    func body(content: Content) -> some View {
        Button {
            if store.hasAccess(to: required) {
                action()
            } else {
                showPaywall = true
            }
        } label: { content }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(store)
        }
    }
}
