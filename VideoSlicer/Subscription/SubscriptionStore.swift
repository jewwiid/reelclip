import StoreKit
import Foundation
import Combine

/// Wraps App Store Connect auto-renewing subscriptions for ReelClip.
///
/// Product identifiers are declared in App Store Connect under
/// `app.reelclip.ios` (id `6787742864`), subscription group
/// `reelclip.subscription`. For local testing we mirror the same IDs in
/// `ReelClip.storekit` so the scheme can run without network.
///
/// Tier model: a single paid tier, **Creator**. The legacy Studio tier
/// (weekly/monthly/yearly/lifetime) was dropped in favour of a simpler
/// two-tier story (Free / Creator) where every paid feature lives on
/// Creator. Existing Studio lifetime buyers' `rc.studio.lifetime2`
/// transactions still resolve to the Creator tier via
/// `tierForProductID(_:)` so they keep their access — the legacy
/// productId just maps to Creator instead of a now-deleted Studio
/// tier.
@MainActor
final class SubscriptionStore: ObservableObject {

    enum Tier: String, Codable, CaseIterable {
        case free
        case creator
    }

    enum ProductID: String, CaseIterable {
        // Weekly — low-commitment entry point alongside the monthly
        // Creator trial configured in StoreKit.
        case creatorWeekly  = "rc.creator.weekly"
        case creatorMonthly = "rc.creator.monthly"
        case creatorYearly  = "rc.creator.yearly"
        // Lifetime — one-time non-consumable purchase. Owns the tier
        // forever and is surfaced in `ReelClip.storekit` under `products`.
        case creatorLifetime = "rc.creator.lifetime2"
        // Legacy Studio productIds kept for entitlement recognition
        // only — no longer surfaced in `ReelClip.storekit` or on the
        // paywall. Existing Studio lifetime buyers still resolve to
        // Creator via `tierForProductID(_:)` so they don't lose
        // access when the v2.0 build rolls out.
        case legacyStudioWeekly   = "rc.studio.weekly"
        case legacyStudioMonthly  = "rc.studio.monthly"
        case legacyStudioYearly   = "rc.studio.yearly"
        case legacyStudioLifetime = "rc.studio.lifetime2"
    }

    static let groupID = "reelclip.subscription"

    static let activeProductIDs: [String] = [
        ProductID.creatorWeekly.rawValue,
        ProductID.creatorMonthly.rawValue,
        ProductID.creatorYearly.rawValue,
        ProductID.creatorLifetime.rawValue
    ]

    @Published private(set) var tier: Tier = .free
    @Published private(set) var products: [Product] = []
    @Published private(set) var missingProductIDs: Set<String> = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = listenForTransactions()
        Task { await refresh() }
    }

    deinit { transactionListener?.cancel() }

    // MARK: - Public API

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await loadProducts()
        await refreshTier()
    }

    func purchase(_ product: Product) async -> Bool {
        lastError = nil
        do {
            // StoreKit is the local source of truth. No app-account
            // identifier or purchase payload is sent to a ReelClip server.
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let txn) = verification else {
                    lastError = "We could not verify this purchase. Please try again."
                    await refreshTier()
                    return false
                }

                await txn.finish()
                await refreshTier()
                return tier >= tierForProductID(txn.productID)
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase is pending approval. Access unlocks after Apple confirms it."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        lastError = nil
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription }
        await refreshTier()
    }

    /// Returns true when the active `tier` satisfies the `required` minimum.
    func hasAccess(to required: Tier) -> Bool {
        switch (tier, required) {
        case (.creator, .creator): return true
        case (.creator, .free): return true
        case (.free, .free): return true
        default: return false
        }
    }

    // MARK: - Internals

    private func loadProducts() async {
        do {
            // Only request the 4 active Creator productIds from
            // StoreKit — the legacy Studio IDs are kept for
            // `tierForProductID` recognition but must not be loaded
            // into the paywall (they were dropped from the
            // storekit config in v2.0).
            let loadedProducts = try await Product.products(for: Set(Self.activeProductIDs))
                .sorted { lhs, rhs in
                    lhs.price < rhs.price
                }
            let loadedIDs = Set(loadedProducts.map(\.id))
            products = loadedProducts
            missingProductIDs = Set(Self.activeProductIDs).subtracting(loadedIDs)

            if loadedProducts.isEmpty {
                lastError = "No live ReelClip products were returned. Confirm the four product IDs are configured for app.reelclip.ios in App Store Connect."
            } else if !missingProductIDs.isEmpty {
                lastError = "Some ReelClip plans are unavailable in App Store Connect."
            } else {
                lastError = nil
            }
        } catch {
            products = []
            missingProductIDs = Set(Self.activeProductIDs)
            lastError = "StoreKit could not load live pricing: \(error.localizedDescription)"
        }
    }

    /// Resolves the effective tier from StoreKit 2 verified entitlements.
    /// StoreKit receives renewals, restores, refunds, and revocations through
    /// its local entitlement APIs and transaction update stream.
    private func refreshTier() async {
        tier = await localStoreKitTier()
    }

    /// Walk StoreKit 2's `currentEntitlements` and pick the highest tier
    /// among `.verified` transactions. Failed verifications are skipped —
    /// the user can restore purchases to retry.
    private func localStoreKitTier() async -> Tier {
        var resolved: Tier = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result,
                  txn.revocationDate == nil else { continue }
            resolved = max(resolved, tierForProductID(txn.productID))
        }
        return resolved
    }

    /// Resolve a productId to its tier. Both Creator and the legacy
    /// Studio IDs map to `.creator` — Studio is gone as a tier but
    /// the entitlements it granted are absorbed into Creator (30-min
    /// sources, SRT/VTT, etc.) so the user's access is preserved
    /// across the v2.0 transition.
    private func tierForProductID(_ productID: String) -> Tier {
        switch productID {
        case ProductID.creatorWeekly.rawValue,
             ProductID.creatorMonthly.rawValue,
             ProductID.creatorYearly.rawValue,
             ProductID.creatorLifetime.rawValue,
             ProductID.legacyStudioWeekly.rawValue,
             ProductID.legacyStudioMonthly.rawValue,
             ProductID.legacyStudioYearly.rawValue,
             ProductID.legacyStudioLifetime.rawValue:
            return .creator
        default:
            return .free
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                guard let self,
                      case .verified(let transaction) = update else { continue }

                await transaction.finish()
                await self.refreshTier()
            }
        }
    }

}

// MARK: - ProductID helpers

extension SubscriptionStore.ProductID {
    /// True for the legacy Studio productIds — kept in the enum for
    /// entitlement recognition (existing lifetime buyers' transactions
    /// still resolve to Creator) but stripped from the paywall and
    /// from `loadProducts()`'s StoreKit request.
    var isLegacyStudio: Bool {
        switch self {
        case .legacyStudioWeekly, .legacyStudioMonthly,
             .legacyStudioYearly, .legacyStudioLifetime:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tier ordering

extension SubscriptionStore.Tier: Comparable {
    /// Creator > Free. Used by `max(_:_:)` in `refreshTier` and
    /// local StoreKit entitlements.
    static func < (lhs: SubscriptionStore.Tier, rhs: SubscriptionStore.Tier) -> Bool {
        let order: [SubscriptionStore.Tier] = [.free, .creator]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

extension Notification.Name {
    static let subscriptionTierDidChange = Notification.Name("ReelClip.subscriptionTierDidChange")
}

// MARK: - Convenience helpers

extension SubscriptionStore.Tier {
    /// User-facing label shown in paywall + settings.
    var displayName: String {
        switch self {
        case .free:   return "Free"
        case .creator: return "Creator"
        }
    }

    /// Marketing badge shown above the paywall when the user is currently
    /// on this tier.
    var tagline: String {
        switch self {
        case .free:    return "Starter tools included"
        case .creator: return "Unlimited AI cuts + clean exports"
        }
    }
}
