// FileDocument wrapper used by SwiftUI's `.fileExporter`. V3 exports are
// directory FileWrappers (document packages); legacy flat files remain valid.

import SwiftUI
import UniformTypeIdentifiers

struct ReelClipProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.reelClipProject] }
    static var writableContentTypes: [UTType] { [UTType.reelClipProject] }

    /// Temp package or legacy flat-file URL prepared by the view model.
    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        // We don't need to read .reelclip files here — that's handled by
        // the fileImporter flow + ReelClipProjectURLRouter. This stub
        /// satisfies the FileDocument protocol.
        self.url = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else {
            throw NSError(domain: "ReelClipProjectDocument", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No project file to export."])
        }
        // Empty reading options keep large media lazy instead of loading a
        // multi-GB package into memory before the system copies it.
        return try FileWrapper(url: url, options: [])
    }
}
