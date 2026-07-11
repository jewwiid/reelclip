import Foundation
import Photos

/// Resolves and persists the "ReelClip" user album in the
/// device's Photos library. Every clip the user exports lands
/// in this album in addition to their default library, so the
/// exports are easy to find later — same pattern Instagram,
/// TikTok, and CapCut use to keep their "exports" albums
/// separate from the user's camera roll.
///
/// Free for a user-owned album in the user's own library
/// (Apple's `PHAssetCollection` + iCloud sync just work). A
/// truly shared / public album is a different code path that
/// needs a CloudKit container; not used here.
enum ReelClipPhotoAlbum {
    /// The user-visible album name. Kept short so it sorts well
    /// in Photos' album list and matches the app's branding.
    static let albumTitle = "ReelClip"

    /// UserDefaults key for the cached album localIdentifier.
    /// Survives app launches; cleared automatically if the
    /// underlying album is deleted from Photos (resolve() will
    /// return nil and the next export will create a fresh one).
    private static let cachedIDKey = "ReelClipPhotoAlbum.cachedLocalIdentifier"

    /// Returns the live PHAssetCollection for the user's
    /// "ReelClip" album, or nil if it doesn't exist (yet).
    /// Uses three lookup strategies in order:
    ///   1. The cached localIdentifier from UserDefaults.
    ///   2. A fetch by that id (handles the case where Photos
    ///      gave us a transient id that's now stable).
    ///   3. A title search across all user albums (handles the
    ///      case where the user reinstalled the app and the
    ///      cached id is gone but the album still exists).
    ///
    /// This must run on a thread that has Photos access. The
    /// caller is responsible for the auth dance.
    static func resolve() -> PHAssetCollection? {
        // Strategy 1 + 2: try the cached id first. The id can go
        // stale if the user deleted the album from Photos
        // between exports; `fetchAssetCollections` will return
        // nil in that case and we fall through to the title
        // search below.
        if let cached = UserDefaults.standard.string(forKey: cachedIDKey),
           !cached.isEmpty {
            let cachedFetch = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [cached],
                options: nil
            )
            if let existing = cachedFetch.firstObject, existing.localizedTitle == albumTitle {
                return existing
            }
        }

        // Strategy 3: title search. Scoped to user albums (regular
        // sub-albums of the user's library) — never matches
        // shared, system, or smart albums.
        let titleFetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var match: PHAssetCollection?
        titleFetch.enumerateObjects { collection, _, _ in
            if collection.localizedTitle == albumTitle {
                match = collection
                return
            }
        }
        return match
    }

    /// Persist the album's stable localIdentifier for next time.
    /// Called after a successful performChanges block so the
    /// next export skips the title search.
    static func persist(_ collection: PHAssetCollection) {
        UserDefaults.standard.set(collection.localIdentifier, forKey: cachedIDKey)
    }

    /// Returns a `PHAssetCollectionChangeRequest` for the user's
    /// "ReelClip" album, creating it if it doesn't exist yet.
    /// Returns nil if PhotoKit refused to create a change
    /// request (which only happens when the caller has lost
    /// Photos auth mid-flow — the performChanges call would
    /// fail anyway, so we treat it as a soft skip and the
    /// clips still land in the user's default library).
    ///
    /// `cached` is the result of an out-of-block `resolve()`
    /// call. Passing it in lets us avoid the title search
    /// inside the change-request block.
    static func makeChangeRequest(
        cached: PHAssetCollection?
    ) -> PHAssetCollectionChangeRequest? {
        if let cached {
            return PHAssetCollectionChangeRequest(for: cached)
        }
        return PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
            withTitle: albumTitle
        )
    }
}
