import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copiedURL = try MediaWorkspace().importSourceCopy(from: received.file)
            return PickedVideo(url: copiedURL)
        }
    }
}
