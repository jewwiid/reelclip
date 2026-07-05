import Foundation
import UIKit

#if canImport(TikTokOpenSDKCore)
import TikTokOpenSDKCore
#endif

#if canImport(TikTokOpenShareSDK)
import TikTokOpenShareSDK
#endif

enum TikTokDirectShareError: LocalizedError {
    case sdkUnavailable
    case missingConfiguration
    case missingPhotoLibraryAsset
    case tikTokNotInstalled
    case unableToStart
    case invalidResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "TikTok Share Kit is not linked in this build."
        case .missingConfiguration:
            return "Add a TikTok client key and universal-link redirect URI before using direct TikTok share."
        case .missingPhotoLibraryAsset:
            return "Export this clip to Photos again before sharing directly to TikTok."
        case .tikTokNotInstalled:
            return "TikTok is not installed on this device. Use the iOS share button or install TikTok first."
        case .unableToStart:
            return "TikTok did not accept the share request. Check the TikTok app, client key, and redirect URI."
        case .invalidResponse:
            return "TikTok returned a response the app could not read."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class TikTokDirectShareService {
#if canImport(TikTokOpenShareSDK)
    private var activeRequest: TikTokShareRequest?
#endif

    static var isConfigured: Bool {
        TikTokShareConfiguration.current.isComplete
    }

    func shareVideoClip(_ clip: SegmentOutput) async throws -> String {
        guard let localIdentifier = clip.photoLibraryLocalIdentifier,
              !localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TikTokDirectShareError.missingPhotoLibraryAsset
        }

        let configuration = TikTokShareConfiguration.current

        guard configuration.isComplete else {
            throw TikTokDirectShareError.missingConfiguration
        }

        guard Self.isTikTokInstalled else {
            throw TikTokDirectShareError.tikTokNotInstalled
        }

#if canImport(TikTokOpenShareSDK)
        return try await withCheckedThrowingContinuation { continuation in
            let request = TikTokShareRequest(
                localIdentifiers: [localIdentifier],
                mediaType: .video,
                redirectURI: configuration.redirectURI
            )
            request.state = clip.id.uuidString
            request.customConfig = TikTokShareRequest.CustomConfiguration(
                clientKey: configuration.clientKey,
                callerUrlScheme: configuration.clientKey
            )
            activeRequest = request

            let didStart = request.send { [weak self] response in
                Task { @MainActor in
                    defer {
                        self?.activeRequest = nil
                    }

                    guard let shareResponse = response as? TikTokShareResponse else {
                        continuation.resume(throwing: TikTokDirectShareError.invalidResponse)
                        return
                    }

                    guard shareResponse.errorCode == .noError else {
                        continuation.resume(throwing: TikTokDirectShareError.failed(Self.failureMessage(for: shareResponse)))
                        return
                    }

                    continuation.resume(returning: "Opened TikTok for \(clip.title).")
                }
            }

            if !didStart {
                activeRequest = nil
                continuation.resume(throwing: TikTokDirectShareError.unableToStart)
            }
        }
#else
        throw TikTokDirectShareError.sdkUnavailable
#endif
    }

    private static var isTikTokInstalled: Bool {
        ["snssdk1233", "snssdk1180", "tiktoksharesdk"].contains { scheme in
            guard let url = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

#if canImport(TikTokOpenShareSDK)
    private static func failureMessage(for response: TikTokShareResponse) -> String {
        let description = response.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let description, !description.isEmpty {
            return "TikTok share failed: \(description)"
        }

        return "TikTok share failed with error \(response.errorCode.rawValue), state \(response.shareState.rawValue)."
    }
#endif
}

private struct TikTokShareConfiguration {
    let clientKey: String
    let redirectURI: String

    var isComplete: Bool {
        !clientKey.isEmpty && !redirectURI.isEmpty
    }

    static var current: TikTokShareConfiguration {
        TikTokShareConfiguration(
            clientKey: configuredValue(for: "TikTokClientKey"),
            redirectURI: configuredValue(for: "TikTokRedirectURI")
        )
    }

    private static func configuredValue(for key: String) -> String {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty || value.contains("$(") {
            return ""
        }

        return value
    }
}

enum TikTokOpenSDKURLRouter {
    @discardableResult
    static func handle(_ url: URL?) -> Bool {
#if canImport(TikTokOpenSDKCore)
        TikTokURLHandler.handleOpenURL(url)
#else
        false
#endif
    }
}
