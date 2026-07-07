# ReelClip Paywall Design — Pricing Strategy & StoreKit 2 Wiring

_Date: 2026-07-06. Author: Mavis. Status: proposal (waiting on user sign-off)._

---

## 1. What competitors charge (2026)

| App | Free | Entry paid | Mid | Top | Billing unit |
|-----|------|------------|-----|-----|--------------|
| **OpusClip** | 60 min/mo, watermark | **Starter $15** (150 min) | **Pro $29** (~3,600 min/yr) | Business (custom) | minutes of source video |
| **Captions** | 0 AI credits | **Pro $9.99** (200 cred) | **Max $24.99** (500) | **Scale $69.99–$279.99** (1.4k–5.6k cred) | AI credits |
| **Submagic** | 3 short videos/mo | **Starter $19** (15 videos) | **Pro $39** (40) | **Business+API $69** | videos/month |
| **VEED** | 720p watermark | **Lite $12** | **Pro $24** | **Business $60** | flat |
| **Munch** | — | — | **Creator $49** | — | flat |
| **VEED Shorts (mobile)** | — | **Mobile PRO $29.99** | **Ultra $300/yr** | — | flat mobile-only |

The **median paid entry-tier is $9.99–$19/mo**; the **median mid-tier is $24.99–$39/mo**. Annual savings vs monthly sit around 35–50%.

Apple takes a 30% cut on the first year (drops to 15% after Year 1 for retained subscribers; 15% from day one if you qualify for the Small Business Program — which ReelClip does given < $1M/yr revenue).

---

## 2. What ReelClip actually spends on AI

The AI layer is routed through `AIProviderRegistry` to one of {Apple Intelligence, MiniMax-M3, Claude, OpenAI, Gemini, Ollama}. The fixed-mode NL parser (`ClipQuery.swift`) is **on-device** — it walks tokens, no API call.

### Per-cost estimates (cloud path)

| Provider | $/1M input | $/1M output | Typical request size | Cost per "AI Plan" tap |
|----------|-----------:|------------:|----------------------:|----------------------:|
| **Apple Intelligence** | $0 (Apple absorbs) | $0 | up to 4k ctx | **$0** — ReelClip can't meter, Apple does |
| **MiniMax-M3** (global plan) | ~$0.30 | ~$1.20 | 2–5k in, 0.3–1k out | **$0.001–$0.003** |
| **Claude Sonnet 4.6** | $3 | $15 | 2–5k in, 0.5–1.5k out | **$0.01–$0.03** |
| **GPT-5.4** | $2.50 | $15 | 2–5k in, 0.5–1.5k out | **$0.01–$0.02** |
| **Gemini 3.1 Pro** | $2 | $12 | 2–5k in, 0.5–1.5k out | **$0.005–$0.015** |

A heavy user doing ~50 AI plans/month through MiniMax-M3 costs us **~$0.10/mo**. Through Claude Sonnet, ~$0.50–$1.00/mo. Comfortable margin at any price point above $4.99.

### Two structural facts about our stack

1. **Apple Intelligence (on iOS 26+)** is free at point of use — Apple pays for compute. If the user has it, ReelClip never sees a bill, but the user still needs the **app to allow them through** — that's what the paywall gates.
2. **BYOK (Bring Your Own Key)** lets the user plug in their own Claude/OpenAI/Gemini key. We charge $0 for AI compute; they pay their provider directly. So the paywall needs a separate meaning here: we should **not** lock BYOK behind the paywall — that would be punitive and Apple might reject it.

---

## 3. Three-tier proposal

| Tier | Monthly | **Annual** (40% off) | What changes |
|------|--------:|---------------------:|--------------|
| **Free** | $0 | — | SmartPause, Highlight (CoreML), on-device STT transcript, Fixed-mode batch cut, **3 AI plans/month** under our pooled MiniMax route, **standard quality** export with small watermark, source ≤ 5 min |
| **Creator** | **$9.99** | **$59.99/yr (~$5/mo)** | Unlimited AI plans · unlimited text-recipe refinement · **Apple Intelligence path** unlocked · 4K export · no watermark · all five BYOK providers usable without watermark interference · source ≤ 15 min |
| **Studio** | **$19.99** | **$119.99/yr (~$10/mo)** | All Creator + **priority render queue** · **TikTok direct share** · Team library · bulk export (zip) · source ≤ 30 min · transcript export (SRT/VTT) · custom brand kit |

> Why these numbers: Creator at $9.99 hits the Sweet-Spot median ($9.99 Captions Pro / $12 VEED Lite / $15 Opus Starter). Studio at $19.99 stays under the "pro-tools" threshold ($24.99 VEED Pro / $29 Opus Pro / $39 Submagic Pro) but is meaningfully more powerful than Creator so we have a real upsell path. Annual discount 40% (in line with OpusClip's 35–50%).

### What each tier maps to in the current code

| Capability (file) | Free | Creator | Studio |
|-------------------|:----:|:-------:|:------:|
| `SmartCutAnalyzer` (SmartPause mode) | ✅ | ✅ | ✅ |
| `HighlightAnalyzer` + `CoreMLHighlightScorer` (Highlight mode) | ✅ | ✅ | ✅ |
| On-device STT (`TranscriptService`) | ✅ | ✅ | ✅ |
| Fixed-mode batch cut + number/spacing query (`ClipQuery`) | ✅ (3/day cap) | ✅ | ✅ |
| `AppleIntelligenceEditProvider` (Apple's free compute) | 🔒 | ✅ | ✅ |
| `AIProviderRegistry.resolvedProvider` with our pooled MiniMax route | 🔒 (3/mo) | ✅ | ✅ |
| BYOK providers (`Claude`, `OpenAI`, `Gemini`, `MiniMax`, `Ollama`) | ✅ (no watermark) | ✅ | ✅ |
| 4K + watermark-free export | 🔒 | ✅ | ✅ |
| Source duration > 5 min | 🔒 | 15 min | 30 min |
| Priority render queue (kick off background export faster) | 🔒 | 🔒 | ✅ |
| TikTok direct share (`TikTokDirectShareService`) | 🔒 | 🔒 | ✅ |
| Transcript export (`.srt` / `.vtt`) | 🔒 | 🔒 | ✅ |

> **Note**: BYOK providers work on **Free** because the user already pays their provider directly; gating that would be predatory and probably violate Apple's IAP guidelines (you can't gate features the user can already get elsewhere by just plugging in a key). The paywall gates the **pooled, our-side AI route** and the **Apple Intelligence unlock** — those are the things only ReelClip can give them.

---

## 4. Where the paywall shows up

Five places, only on transitions into a gated action:

1. **AI-Assist analyze button** → "Plan with AI" tap → paywall sheet
2. **Natural-language recipe input** (`fixedModeQueryControl` text mode) → first time user types a query → soft prompt "Refine with AI" → paywall sheet on tap
3. **Apple Intelligence provider** selection → paywall sheet on toggle (since gated)
4. **Export → 4K / no watermark** → paywall sheet
5. **Settings → "Upgrade to Creator / Studio"** section, plus a footer card on Home and Clip views if not subscribed

The paywall never appears inside the actual editing flow — only on the action that needs it. Once a subscription lands, the sheet disappears and never interrupts again.

---

## 5. Implementation: StoreKit 2

Use Apple's **StoreKit 2 SwiftUI views** (`SubscriptionStoreView` / `StoreView`) since they're WCAG-correct, support intro offers, family sharing, refund handling, and review-screenshot policy without us writing UI for them. Wire a `SubscriptionStore` `@MainActor ObservableObject` that:

- Loads products for our group ID via `Product.products(for:)`
- Tracks entitlements via `Transaction.currentEntitlements`
- Exposes a `tier: AccessTier` property for `@Environment`
- Handles the **.success / .userCancelled / .pending** `Product.PurchaseResult` cleanly
- Listens to `Transaction.updates` for renewals/refunds outside the app
- Stashes an `originalTransactionID` in `Keychain` so we can restore

Then make every paywall-gated view read `subscription.tier` and either render or not. Gate via a thin `Paywall(...) { }` view modifier that takes the lock screen — never modifies the underlying views.

### Pricing products (App Store Connect) — exact configuration

Group: `reelclip.subscription` (auto-renewing)

| Product ID | Period | Tier | Monthly equiv. |
|-----------|--------|------|---------------:|
| `rc.creator.monthly` | 1 month | Creator | $9.99 |
| `rc.creator.yearly` | 1 year | Creator | $4.999/mo (effective) |
| `rc.studio.monthly` | 1 month | Studio | $19.99 |
| `rc.studio.yearly` | 1 year | Studio | $9.999/mo (effective) |

Plus an intro offer on the monthly Creator product: **3-day free trial**, then $9.99 — captures the price-sensitive user without permanently flattening revenue.

> Note on Apple's 30% cut: at $9.99/mo Creator, Apple takes ~$3.00 first year, $1.50 thereafter. AI COGS = ~$0.10–1.00. **Net margin per Creator is ~$7.00 first year, ~$8.50 thereafter.** Annual lock-ins materially improve LTV because Apple drops to 15% after Year 1.

---

## 6. Code sketch (skeleton — not shipping)

```swift
// ReelClip/Store/SubscriptionStore.swift
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
    enum Tier: String, Codable { case free, creator, studio }
    enum Period: String { case monthly, yearly }

    @Published private(set) var tier: Tier = .free
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false

    static let productIDs: Set<String> = [
        "rc.creator.monthly", "rc.creator.yearly",
        "rc.studio.monthly",  "rc.studio.yearly",
    ]
    static let groupID = "reelclip.subscription"

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let _ = refreshProducts()
        async let _ = refreshTier()
    }

    func purchase(_ product: Product) async throws -> Bool {
        let res = try await product.purchase()
        switch res {
        case .success(let v):
            await v.finish()
            await refreshTier()
            return true
        case .userCancelled, .pending: return false
        @unknown default: return false
        }
    }

    func restore() async { await refreshTier() }

    private func refreshProducts() async {
        do { products = try await Product.products(for: Self.productIDs) }
        catch { products = [] }
    }

    private func refreshTier() async {
        var best: Tier = .free
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let txn) = entitlement else { continue }
            switch txn.productID {
            case "rc.studio.monthly", "rc.studio.yearly": best = .studio; break
            case "rc.creator.monthly", "rc.creator.yearly": if best == .free { best = .creator }
            default: continue
            }
        }
        tier = best
        // mirror to Keychain for offline resume / Share Sheet extension
    }
}

// ReelClip/Store/PaywallView.swift
struct PaywallView: View {
    @EnvironmentObject var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Use Apple's view to avoid reinventing
        SubscriptionStoreView(productIDs: Array(store.products.map(\.id)))
            .tint(AppPalette.accent)
            .onChange(of: store.tier) { _, t in
                if t != .free { dismiss() }   // auto-dismiss on successful purchase
            }
    }
}

// View-level gating
extension View {
    @ViewBuilder
    func paywalled(_ tier: SubscriptionStore.Tier, action: @escaping () -> Void) -> some View {
        self.modifier(PaywalledModifier(required: tier, action: action))
    }
}

// ReelClip/Store/EntitlementGate.swift
struct EntitlementGate<Value, Placeholder: View>: View {
    @EnvironmentObject var store: SubscriptionStore
    let required: SubscriptionStore.Tier
    let value: () -> Value
    let placeholder: () -> Placeholder
    @State private var showPaywall = false

    var body: some View {
        Group {
            if hasAccess { value() }
            else {
                Button { showPaywall = true } label: { placeholder() }
                    .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(store) }
    }

    private var hasAccess: Bool {
        switch (store.tier, required) {
        case (.studio, _): true
        case (.creator, .creator), (.creator, .free): true
        case (_, .free): true
        default: false
        }
    }
}
```

Then in `ClipView.swift`:

```swift
// Before — every user can hit AI Assist
Button("Ask AI") { viewModel.runAIAssist() }

// After — gated. Tap → if no entitlement, sheet slides up first
aiAssistButton
    .paywalled(.creator) {
        viewModel.runAIAssist()
    }
```

---

## 7. Open questions for you

1. **Annual discount** — propose 40%. OpusClip does ~50%, Captions does ~30%. 40% feels right but lmk if you want different.
2. **3-day free trial** — yes/no? Industry standard and Apple pushes it as a "good citizen" pattern.
3. **Source duration limits** — 5/15/30 min on Free/Creator/Studio feels right for vertical-video creators. Raise if your target is podcasters.
4. **iPhone-only or iPad?** StoreKit 2 Family Sharing and Picker sync — I'll enable both.
5. **Server-side entitlement check?** For now: client-only via StoreKit 2 (transaction signed by Apple, no backend needed). Can add App Store Server Notifications later when we wire a Convex web hook for fraud signal.

Once you greenlight, I'll:

1. Add `SubscriptionStore.swift` + `PaywallView.swift` + `EntitlementGate.swift`
2. Wire `EntitlementGate` into the 5 spots in `ClipView`, `HomeView`, and `SettingsView`
3. Add IAP capability to the Xcode project (`Signing & Capabilities` → `In-App Purchase`)
4. Create `rc.creator.monthly/yearly` and `rc.studio.monthly/yearly` in App Store Connect under `app.reelclip.ios` (id `6787742864`)
5. Add a `reelclip.subscription.storekit` configuration file for offline testing
6. TestFlight v20 with the paywall, intro-trial enabled in App Store Connect sandbox
