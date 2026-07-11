// Handles `.reelclip` file URLs delivered via Files app, AirDrop, share
// sheets, or the app's own "Import" button. The actual decode happens
// elsewhere — this layer just resolves incoming URLs into a decoded
// project and pushes the result into the shared viewmodel.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Viewmodel-facing API for incoming project files. The main viewmodel
/// conforms to this protocol so the router can be unit-tested with a
/// stub.
@MainActor
protocol ReelClipProjectImportSink: AnyObject {
    /// Caller has resolved a `.reelclip` URL into a project. The viewmodel
    /// is responsible for storing it and surfacing any "source missing"
    /// banners.
    func ingestImportedProject(_ result: ReelClipImportResult)

    /// Quick Toast-style message surfaced in the status line.
    func setStatusMessage(_ text: String)
}

/// Singleton router. Lives for the app's lifetime so cold-launch URLs
/// delivered before any view appears can still find the viewmodel.
@MainActor
final class ReelClipProjectURLRouter {
    static let shared = ReelClipProjectURLRouter()
    private init() {}

    private weak var sink: ReelClipProjectImportSink?

    /// URLs that arrived before the sink was attached (cold launch via
    /// AirDrop / Files / Universal Link). Drained in `attach(_:)`.
    private var pendingURLs: [URL] = []

    /// Wire the active viewmodel into the router. Called from the root
    /// view on appear. Drains any pending URLs that arrived during cold
    /// launch before the sink was attached.
    func attach(_ sink: ReelClipProjectImportSink) {
        self.sink = sink
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued {
            handle(url: url)
        }
    }

    /// Detach on disappear so we don't leak a stale viewmodel reference.
    func detach(_ sink: ReelClipProjectImportSink) {
        if self.sink === sink { self.sink = nil }
    }

    /// Called by `.onOpenURL` in the app entry point.
    func handle(url: URL) {
        guard url.pathExtension.lowercased() == "reelclip" else {
            // Not for us — ignore silently.
            return
        }

        // If the sink isn't attached yet (cold launch, pre-onAppear),
        // queue the URL for later. Previously, the decode ran and the
        // result was silently discarded — freezing the main thread for
        // nothing and losing the user's project.
        guard let sink else {
            pendingURLs.append(url)
            return
        }

        // Security-scoped access stays active until the package's embedded
        // media has been copied into the private workspace. Stopping after
        // reading only the manifest made package children disappear midway
        // through imports from Files and iCloud providers.
        let didStart = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let result = try await ReelClipProjectCodec.decode(contentsOf: url)
                await MainActor.run {
                    sink.ingestImportedProject(result)
                    switch result.sourceResolution {
                    case .resolvedViaPackage(let sourceCount):
                        sink.setStatusMessage(
                            "Imported complete project with \(sourceCount) source\(sourceCount == 1 ? "" : "s")."
                        )
                    case .resolvedViaPhotos:
                        sink.setStatusMessage("Imported project — source video ready.")
                    case .resolvedViaFilename:
                        sink.setStatusMessage("Imported project — verify the source clip matches.")
                    case .missing:
                        sink.setStatusMessage("Imported project — source video not found. Pick a replacement.")
                    }
                }
            } catch {
                await MainActor.run {
                    sink.setStatusMessage("Couldn't import: \(error.localizedDescription)")
                }
            }
        }
    }
}
