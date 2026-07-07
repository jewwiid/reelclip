// FileDocument wrapper that lets SwiftUI's `.fileExporter` present a
// `.reelclip` file for the user to save. Reads bytes from a temp URL
// the viewmodel prepared; on save the system writes those bytes to the
// user-chosen destination and we delete the temp file.

import SwiftUI
import UniformTypeIdentifiers

struct ReelClipProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.reelClipProject] }
    static var writableContentTypes: [UTType] { [UTType.reelClipProject] }

    /// The temp URL holding the encoded envelope bytes. The exporter
    /// reads from here when the user picks a destination.
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
        // Read the temp bytes and hand them to FileWrapper so the system
        // can write them to the user-chosen destination. The viewmodel
        // deletes the temp file in the export completion handler.
        let data = try Data(contentsOf: url)
        return FileWrapper(regularFileWithContents: data)
    }
}