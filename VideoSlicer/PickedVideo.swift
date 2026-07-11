import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Photos
import PhotosUI

struct PickedVideo: Transferable {
    let url: URL
    let sourceName: String
    let isWorkspaceCopyNew: Bool
    /// The PHAsset localIdentifier, if the picker item came from
    /// the Photos library. Used to persist the source reference in
    /// `.reelclip` project files so the recipient can resolve the
    /// source video on their device. `nil` when the video was
    /// imported from a file (Files app, AirDrop) rather than Photos.
    let photoLibraryLocalIdentifier: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // `received.file` is owned by PhotosUI and can disappear as soon
            // as this closure returns. Materialize it here, not from the outer
            // `loadTransferable` completion handler.
            try materialize(receivedFile: received.file)
        }
    }

    static func materialize(
        receivedFile: URL,
        workspace: MediaWorkspace = MediaWorkspace()
    ) throws -> PickedVideo {
        guard workspace.fileManager.fileExists(atPath: receivedFile.path) else {
            throw PickedVideoImportError.photosDownloadUnavailable
        }

        do {
            let imported = try workspace.importSourceCopyResult(from: receivedFile)
            return PickedVideo(
                url: imported.url,
                sourceName: receivedFile.lastPathComponent,
                isWorkspaceCopyNew: imported.wasCreated,
                photoLibraryLocalIdentifier: nil
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile
            || error.code == .fileReadNoSuchFile {
            throw PickedVideoImportError.photosDownloadUnavailable
        }
    }
}

enum PickedVideoImportError: LocalizedError {
    case photosDownloadUnavailable

    var errorDescription: String? {
        switch self {
        case .photosDownloadUnavailable:
            return "Photos could not finish downloading this video. Keep ReelClip open, check your connection and free storage, then try again."
        }
    }
}

extension PhotosPickerItem {
    /// Resolve the PHAsset localIdentifier for this picker item.
    /// Returns `nil` if the item isn't from the Photos library.
    var photoLibraryLocalIdentifier: String? {
        // PhotosPickerItem exposes the underlying PHAsset identifier
        // via `itemIdentifier` — but only when the item was picked
        // from the Photos library (not from Files). We try to fetch
        // the PHAsset to confirm the identifier is valid.
        guard let id = self.itemIdentifier else { return nil }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        return result.firstObject != nil ? id : nil
    }
}
