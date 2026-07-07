import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Photos
import PhotosUI

struct PickedVideo: Transferable {
    let url: URL
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
            let copiedURL = try MediaWorkspace().importSourceCopy(from: received.file)
            return PickedVideo(
                url: copiedURL,
                photoLibraryLocalIdentifier: nil
            )
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