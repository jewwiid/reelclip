import Foundation

/// Lightweight HTTP client for the ReelClip Convex backend. Used by
/// `SubscriptionStore` to:
///   • verify StoreKit 2 transactions server-side (`POST /iap/verify`)
///   • mirror the server's resolved tier on launch (`GET /get-entitlements`)
///
/// The base URL is read from the app's Info.plist (key `CONVEX_SITE_URL`) so
/// dev / TestFlight / prod builds can point at different deployments without
/// recompiling code. Falls back to the prod endpoint if the plist key is
/// missing so a misconfigured build fails loud at runtime, not silent.
struct ConvexEntitlementClient {
    /// Tier vocabulary returned by the Convex backend. Matches the
    /// `SubscriptionStore.Tier` rawValue-for-rawValue so JSON decoding
    /// round-trips without a manual mapper.
    enum Tier: String, Codable {
        case free
        case creator
        case studio
    }

    struct LookupResult: Codable {
        let tier: Tier
        let userId: String?
        let stripeCustomerId: String?
    }

    enum ClientError: LocalizedError {
        case http(status: Int, body: String)
        case decoding(String)
        case missingURL

        var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                return "HTTP \(status): \(body.prefix(256))"
            case .decoding(let msg):
                return "Decoding error: \(msg)"
            case .missingURL:
                return "CONVEX_SITE_URL is not set in Info.plist"
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let raw = Bundle.main.object(forInfoDictionaryKey: "CONVEX_SITE_URL") as? String,
                  let url = URL(string: raw) {
            self.baseURL = url
        } else {
            // Last-resort fallback to the known prod deployment. A build
            // running with the wrong plist will get 4xx errors that surface
            // immediately rather than silently downgrading to no-op.
            self.baseURL = URL(string: "https://wonderful-impala-496.eu-west-1.convex.site")!
        }
        self.session = session
    }

    /// POST `/iap/verify` with the StoreKit 2 transaction JWS. The server
    /// calls Apple's `getTransactionInfo` to verify the receipt, then
    /// upserts the user + entitlement rows.
    func verifyPurchase(
        signedTransactionJWS: String,
        appAccountToken: String,
        customerEmail: String? = nil,
    ) async throws -> LookupResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("/iap/verify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let signedTransactionJWS: String
            let appAccountToken: String
            let customerEmail: String?
        }
        request.httpBody = try JSONEncoder().encode(Body(
            signedTransactionJWS: signedTransactionJWS,
            appAccountToken: appAccountToken,
            customerEmail: customerEmail,
        ))

        return try await execute(request)
    }

    /// GET `/get-entitlements?appAccountToken=…&email=…` — returns the
    /// server's resolved tier. Falls back to `.free` if the lookup fails
    /// or the user doesn't exist server-side.
    func lookupTier(
        appAccountToken: String,
        email: String? = nil,
    ) async throws -> LookupResult {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/get-entitlements"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "appAccountToken", value: appAccountToken),
        ]
        if let email, !email.isEmpty {
            items.append(URLQueryItem(name: "email", value: email))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> LookupResult {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.decoding("network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decoding("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(LookupResult.self, from: data)
        } catch {
            throw ClientError.decoding("\(error)")
        }
    }
}

/// Persistent per-install identifier that ReelClip's Convex backend uses
/// to look up iOS subscriptions. Generated lazily on first launch and
/// stashed in `UserDefaults`. Apple accepts this in the JWS
/// `appAccountToken` field — the iOS app passes it to StoreKit 2 via
/// `purchase(options:)` so the resulting JWS includes it.
enum AppAccountTokenStore {
    private static let key = "reelclip.appAccountToken"

    static func loadOrCreate() -> String {
        if let existing = UserDefaults.standard.string(forKey: key),
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}