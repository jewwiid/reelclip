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
/// Entitlement resolution order (when a user owns both): Studio always wins
/// over Creator.
@MainActor
final class SubscriptionStore: ObservableObject {

    enum Tier: String, Codable, CaseIterable {
        case free
        case creator
        case studio
    }

    enum ProductID: String, CaseIterable {
        case creatorMonthly = "rc.creator.monthly"
        case creatorYearly  = "rc.creator.yearly"
        case studioMonthly  = "rc.studio.monthly"
        case studioYearly   = "rc.studio.yearly"
    }

    static let groupID = "reelclip.subscription"

    @Published private(set) var tier: Tier = .free
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Self.listenForTransactions()
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
        do {
            // Pass our stable appAccountToken so Apple's signed JWS carries
            // it — the Convex backend uses it as the iOS user identifier.
            let token = AppAccountTokenStore.loadOrCreate()
            // StoreKit 2's appAccountToken option takes a UUID, not a string.
            let uuid = UUID(uuidString: token) ?? UUID()
            let options: Set<Product.PurchaseOption> = [.appAccountToken(uuid)]
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    // Mirror the verified transaction to Convex so the
                    // server-side entitlement matches what iOS granted.
                    // jwsRepresentation lives on the VerificationResult
                    // wrapper, not on the underlying Transaction.
                    await reportVerifiedPurchase(
                        signedTransactionJWS: verification.jwsRepresentation,
                    )
                    await txn.finish()
                }
                await refreshTier()
                return true
            case .userCancelled:
                return false
            case .pending:
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
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription }
        await refreshTier()
    }

    /// Returns true when the active `tier` satisfies the `required` minimum.
    func hasAccess(to required: Tier) -> Bool {
        switch (tier, required) {
        case (.studio, _): return true
        case (.creator, .creator): return true
        case (.creator, .free): return true
        case (_, .free): return true
        default: return false
        }
    }

    // MARK: - Internals

    private func loadProducts() async {
        do {
            let ids = ProductID.allCases.map(\.rawValue)
            products = try await Product.products(for: Set(ids))
                .sorted { lhs, rhs in
                    lhs.price < rhs.price
                }
        } catch {
            products = []
            lastError = error.localizedDescription
        }
    }

    /// Resolves the effective tier by combining:
    ///   1. StoreKit 2 `.verified` entitlements (canonical local truth)
    ///   2. The Convex entitlement mirror (catches web-side Stripe subs
    ///      and any renewals that happened while the app was closed, once
    ///      we wire App Store Server Notifications + the Convex webhook).
    /// We take the higher of the two — Convex can only match what iOS
    /// reports, so it can't lower a verified StoreKit subscription.
    private func refreshTier() async {
        let localTier = await localStoreKitTier()
        tier = max(localTier, await convexTier())
    }

    /// Walk StoreKit 2's `currentEntitlements` and pick the highest tier
    /// among `.verified` transactions. Failed verifications are skipped —
    /// the user can `Restore` to retry, and the server will catch any
    /// genuine ownership via `/iap/verify`.
    private func localStoreKitTier() async -> Tier {
        var resolved: Tier = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result else { continue }
            resolved = max(resolved, tierForProductID(txn.productID))
        }
        return resolved
    }

    /// Ask the Convex backend for the user's resolved tier. Returns `.free`
    /// on any failure (network down, server not configured, etc.) so the
    /// StoreKit-derived tier still wins — never block the user from their
    /// paid features because the server is unreachable.
    private func convexTier() async -> Tier {
        let token = AppAccountTokenStore.loadOrCreate()
        do {
            let result = try await convexClient.lookupTier(appAccountToken: token)
            return Self.tier(from: result.tier)
        } catch {
            // Surface the failure but don't escalate to lastError — the
            // local StoreKit tier is still authoritative.
            #if DEBUG
            print("[ConvexEntitlement] lookup failed: \(error.localizedDescription)")
            #endif
            return .free
        }
    }

    /// Map the Convex backend's tier enum (string-raw-valued) to ours.
    /// Both enums share rawValues so this is a one-line coercion — kept
    /// explicit so future divergence is visible.
    private static func tier(from raw: ConvexEntitlementClient.Tier) -> Tier {
        switch raw {
        case .free: return .free
        case .creator: return .creator
        case .studio: return .studio
        }
    }

    /// Verify a StoreKit 2 verified transaction against Apple's
    /// `getTransactionInfo` via Convex. Called from `purchase(_:)` after
    /// the local StoreKit purchase completes successfully.
    func reportVerifiedPurchase(signedTransactionJWS: String) async {
        let token = AppAccountTokenStore.loadOrCreate()
        do {
            let result = try await convexClient.verifyPurchase(
                signedTransactionJWS: signedTransactionJWS,
                appAccountToken: token,
            )
            // Take the max so we don't downgrade from a higher local tier
            // if the server returns a stale value.
            tier = max(tier, Self.tier(from: result.tier))
        } catch {
            // Non-fatal — StoreKit verified the transaction; we just lost
            // the chance to mirror it server-side. The next launch's
            // refreshTier() will retry.
            #if DEBUG
            print("[ConvexEntitlement] verify failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func tierForProductID(_ productID: String) -> Tier {
        switch productID {
        case ProductID.studioMonthly.rawValue, ProductID.studioYearly.rawValue:
            return .studio
        case ProductID.creatorMonthly.rawValue, ProductID.creatorYearly.rawValue:
            return .creator
        default:
            return .free
        }
    }

    private static func listenForTransactions() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await update in Transaction.updates {
                guard case .verified(_) = update else { continue }
                await MainActor.run {
                    NotificationCenter.default.post(name: .subscriptionTierDidChange, object: nil)
                }
            }
        }
    }

    /// Shared HTTP client. Lazily initialized so unit tests can swap the
    /// base URL by injecting a custom instance.
    private lazy var convexClient = ConvexEntitlementClient()
}

// MARK: - Tier ordering

extension SubscriptionStore.Tier: Comparable {
    /// Studio > Creator > Free. Used by `max(_:_:)` in `refreshTier` and
    /// `reportVerifiedPurchase` to take the higher of two sources.
    static func < (lhs: SubscriptionStore.Tier, rhs: SubscriptionStore.Tier) -> Bool {
        let order: [SubscriptionStore.Tier] = [.free, .creator, .studio]
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
        case .studio:  return "Studio"
        }
    }

    /// Marketing badge shown above the paywall when the user is currently
    /// on this tier.
    var tagline: String {
        switch self {
        case .free:    return "Get started"
        case .creator: return "Unlimited AI cuts + 4K export"
        case .studio:  return "Priority renders + direct share"
        }
    }
}
