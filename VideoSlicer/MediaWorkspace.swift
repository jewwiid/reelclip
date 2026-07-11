import CryptoKit
import Foundation
import UIKit

struct ImportedSourceCopy: Sendable {
    let url: URL
    let wasCreated: Bool
}

typealias MediaImportProgressHandler = @Sendable (Double) -> Void

enum MediaImportError: LocalizedError {
    case iCloudDownloadFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .iCloudDownloadFailed(let reason):
            return reason
        }
    }
}

/// Resolves a possibly-cloud-backed file URL to a local copy before
/// downstream code reads its bytes. iOS Files returns placeholder URLs
/// for iCloud Drive (and other cloud-backed providers) where the file
/// metadata is local but the actual content lives in the cloud. Reading
/// such a URL before iOS has finished downloading it produces a
/// "file doesn't exist" error even though the file is reachable.
///
/// Throws `MediaImportError.iCloudDownloadFailed` if the URL doesn't
/// materialise within the timeout, if iOS refuses to start the download
/// (file removed from cloud, user signed out, etc.), or if the download
/// status flips back to `.notDownloaded` mid-flight.
enum MediaImportPreparation {
    /// Returns once the URL points at locally-available bytes, or throws if
    /// the file can't be materialised before `timeout`. Ten minutes allows a
    /// multi-GB portable project to download without treating a slow but
    /// healthy iCloud transfer as a missing file.
    static func ensureFileIsLocal(
        _ url: URL,
        timeout: TimeInterval = 600,
        progress: @escaping MediaImportProgressHandler
    ) async throws {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])

        // Not an iCloud URL — file is already local, nothing to do.
        guard values.isUbiquitousItem == true else {
            progress(1)
            return
        }

        // Already downloaded — confirm and move on.
        if values.ubiquitousItemDownloadingStatus == .current {
            progress(1)
            return
        }

        // Kick off the download. Throws if the file was removed from
        // iCloud or the user is signed out — surface that as a clear error.
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw MediaImportError.iCloudDownloadFailed(
                reason: "Couldn't start the iCloud download. Make sure you're signed in and the file is still in iCloud Drive. (\(error.localizedDescription))"
            )
        }

        let safeTimeout = min(max(timeout, 1), 3_600)
        let deadline = Date().addingTimeInterval(safeTimeout)
        var lastFraction: Double = 0
        while Date() < deadline {
            let v = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey
            ])

            // While the file is still in the cloud (i.e. not yet
            // downloaded), linearly interpolate progress so the UI
            // shows movement. The status only flips from
            // `.notDownloaded` to `.current` once the bytes are
            // actually local, so any "in flight" state reads back as
            // `.notDownloaded` here.
            if v?.ubiquitousItemDownloadingStatus == .notDownloaded,
               lastFraction < 0.9 {
                lastFraction = min(lastFraction + 0.1, 0.9)
                progress(lastFraction)
            }

            switch v?.ubiquitousItemDownloadingStatus {
            case .current:
                progress(1)
                return
            case .notDownloaded:
                // Still in the cloud; keep polling.
                break
            default:
                break
            }

            try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        throw MediaImportError.iCloudDownloadFailed(
            reason: "iCloud download timed out. Keep ReelClips open and try again with a stronger connection."
        )
    }
}

enum MediaWorkspaceError: LocalizedError {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let required = formatter.string(fromByteCount: requiredBytes)
            let available = formatter.string(fromByteCount: availableBytes)
            return "ReelClips needs about \(required) of free space for this operation. \(available) is currently available."
        }
    }
}

struct MediaWorkspace {
    private static let thumbnailCacheVersion = 2

    let rootDirectory: URL
    let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootDirectory = applicationSupport.appendingPathComponent("ReelClip", isDirectory: true)
        }
    }

    var importsDirectory: URL {
        rootDirectory.appendingPathComponent("Imports", isDirectory: true)
    }

    var exportsDirectory: URL {
        rootDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    var projectsDirectory: URL {
        rootDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    var derivedMediaDirectory: URL {
        rootDirectory.appendingPathComponent("Derived", isDirectory: true)
    }

    var proxiesDirectory: URL {
        derivedMediaDirectory.appendingPathComponent("Proxies", isDirectory: true)
    }

    func prepareBaseDirectories() throws {
        try createDirectoryIfNeeded(rootDirectory)
        try createDirectoryIfNeeded(importsDirectory)
        try createDirectoryIfNeeded(exportsDirectory)
        try createDirectoryIfNeeded(projectsDirectory)
        try createDirectoryIfNeeded(derivedMediaDirectory)
        try createDirectoryIfNeeded(proxiesDirectory)
        try? excludeFromBackup(exportsDirectory)
        try? excludeFromBackup(derivedMediaDirectory)
    }

    func proxyURL(for sourceURL: URL) throws -> URL {
        try prepareBaseDirectories()
        let key = derivedMediaKey(
            for: sourceURL,
            kind: "proxy",
            variant: "v1-720p-h264"
        )
        return proxiesDirectory.appendingPathComponent("\(key).proxy.mp4")
    }

    func cachedProxyURL(for sourceURL: URL) -> URL? {
        guard let url = try? proxyURL(for: sourceURL),
              fileManager.fileExists(atPath: url.path),
              fileSize(at: url) > 0 else {
            return nil
        }
        return url
    }

    /// Stable cache key for derived media. The source path is included so a
    /// replaced import cannot reuse another scene's artifacts; file metadata
    /// invalidates the cache when the source changes.
    func derivedMediaKey(
        for sourceURL: URL,
        kind: String,
        variant: String
    ) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date
        let fingerprint = [
            sourceURL.standardizedFileURL.path,
            String(fileSize),
            String(modificationDate?.timeIntervalSince1970 ?? 0),
            kind,
            variant
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func loadWaveformCache(
        for sourceURL: URL,
        durationSeconds: Double,
        targetSampleCount: Int
    ) -> [WaveformSample]? {
        let key = derivedMediaKey(
            for: sourceURL,
            kind: "waveform",
            variant: "\(durationSeconds)-\(targetSampleCount)"
        )
        let url = derivedMediaDirectory.appendingPathComponent("\(key).waveform.json")
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([WaveformSample].self, from: data),
              !samples.isEmpty else {
            return nil
        }
        touchCacheFile(url)
        return samples
    }

    func saveWaveformCache(
        _ samples: [WaveformSample],
        for sourceURL: URL,
        durationSeconds: Double,
        targetSampleCount: Int
    ) {
        guard !samples.isEmpty, (try? prepareBaseDirectories()) != nil else { return }
        let key = derivedMediaKey(
            for: sourceURL,
            kind: "waveform",
            variant: "\(durationSeconds)-\(targetSampleCount)"
        )
        let url = derivedMediaDirectory.appendingPathComponent("\(key).waveform.json")
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadThumbnailCache(
        for sourceURL: URL,
        durationSeconds: Double,
        targetCount: Int,
        maximumSize: CGSize
    ) -> [MediaThumbnail]? {
        let key = derivedMediaKey(
            for: sourceURL,
            kind: "thumbnails",
            variant: "v\(Self.thumbnailCacheVersion)-\(durationSeconds)-\(targetCount)-\(Int(maximumSize.width))x\(Int(maximumSize.height))"
        )
        let directory = derivedMediaDirectory.appendingPathComponent("\(key).thumbnails", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let times = try? JSONDecoder().decode([Double].self, from: data),
              !times.isEmpty else {
            return nil
        }

        let thumbnails = times.enumerated().compactMap { index, time -> MediaThumbnail? in
            let imageURL = directory.appendingPathComponent("\(index).jpg")
            guard let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
            return MediaThumbnail(timeSeconds: time, image: image)
        }
        guard thumbnails.count == times.count else { return nil }
        touchCacheFile(manifestURL)
        return thumbnails
    }

    func saveThumbnailCache(
        _ thumbnails: [MediaThumbnail],
        for sourceURL: URL,
        durationSeconds: Double,
        targetCount: Int,
        maximumSize: CGSize
    ) {
        guard !thumbnails.isEmpty, (try? prepareBaseDirectories()) != nil else { return }
        let key = derivedMediaKey(
            for: sourceURL,
            kind: "thumbnails",
            variant: "v\(Self.thumbnailCacheVersion)-\(durationSeconds)-\(targetCount)-\(Int(maximumSize.width))x\(Int(maximumSize.height))"
        )
        let directory = derivedMediaDirectory.appendingPathComponent("\(key).thumbnails", isDirectory: true)
        try? createDirectoryIfNeeded(directory)
        let times = thumbnails.map(\.timeSeconds)
        guard let manifest = try? JSONEncoder().encode(times) else { return }

        for (index, thumbnail) in thumbnails.enumerated() {
            guard let data = thumbnail.image.jpegData(compressionQuality: 0.78) else { continue }
            try? data.write(
                to: directory.appendingPathComponent("\(index).jpg"),
                options: .atomic
            )
        }
        try? manifest.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    /// Keep derived artifacts from becoming an unbounded second media store.
    /// Cache files are disposable and may be regenerated on demand.
    func cleanupDerivedMedia(
        olderThan cutoffDate: Date,
        maximumBytes: Int64 = 250 * 1024 * 1024
    ) {
        guard fileManager.fileExists(atPath: derivedMediaDirectory.path),
              let enumerator = fileManager.enumerator(
                at: derivedMediaDirectory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ]
              ) else { return }

        var files: [(url: URL, date: Date, size: Int64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]),
            values.isRegularFile == true,
            let date = values.contentModificationDate else { continue }
            let size = Int64(values.fileSize ?? 0)
            if date < cutoffDate {
                try? fileManager.removeItem(at: url)
            } else {
                files.append((url, date, size))
            }
        }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maximumBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }

    func importSourceCopy(from sourceURL: URL) throws -> URL {
        try importSourceCopyResult(from: sourceURL).url
    }

    /// Calculates how many new bytes a batch of source attachments will add
    /// after import deduplication. Portable project import uses this for one
    /// up-front capacity check, avoiding both partial multi-scene imports and
    /// false "not enough space" errors when the same originals already exist.
    func additionalBytesRequiredForSourceImports(_ sourceURLs: [URL]) throws -> Int64 {
        try prepareBaseDirectories()
        let existingImports = try fileManager.contentsOfDirectory(
            at: importsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var knownFingerprints = Set<String>()
        for existingURL in existingImports {
            guard existingURL.pathExtension != "json",
                  existingURL.pathExtension != "partial",
                  (try? existingURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let fingerprint = try? quickFileFingerprint(existingURL) else {
                continue
            }
            knownFingerprints.insert(fingerprint)
        }

        var requiredBytes: Int64 = 0
        for sourceURL in sourceURLs {
            let fingerprint = try quickFileFingerprint(sourceURL)
            guard knownFingerprints.insert(fingerprint).inserted else { continue }
            let (sum, overflow) = requiredBytes.addingReportingOverflow(fileSize(at: sourceURL))
            requiredBytes = overflow ? Int64.max : sum
        }
        return requiredBytes
    }

    /// Copies a source into the private Imports directory and records whether
    /// this call created the file. The ownership bit lets the optional
    /// pre-import trim flow remove a cancelled candidate without touching a
    /// deduplicated source already used by another project.
    func importSourceCopyResult(
        from sourceURL: URL,
        progress: MediaImportProgressHandler? = nil
    ) throws -> ImportedSourceCopy {
        progress?(0)
        try prepareBaseDirectories()

        let sourceFingerprint = try quickFileFingerprint(sourceURL)
        let existingImports = try fileManager.contentsOfDirectory(
            at: importsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        for existingURL in existingImports {
            guard existingURL.pathExtension != "json",
                  existingURL.pathExtension != "partial",
                  (try? existingURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard (try? quickFileFingerprint(existingURL)) == sourceFingerprint else { continue }
            progress?(1)
            return ImportedSourceCopy(url: existingURL, wasCreated: false)
        }

        let sourceBytes = fileSize(at: sourceURL)
        try validateAvailableCapacity(additionalBytes: sourceBytes)

        let fileName = "\(Self.timestampString())-\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destinationURL = importsDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try copyFileReportingProgress(
            from: sourceURL,
            to: destinationURL,
            progress: progress
        )
        return ImportedSourceCopy(url: destinationURL, wasCreated: true)
    }

    /// Removes a pre-import source only when it is a direct child of Imports.
    /// Callers must pass `wasCreated == true`; deduplicated sources can belong
    /// to an existing project and must be retained.
    func removeImportedSource(at url: URL) {
        let importPath = importsDirectory.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path
        guard url.deletingLastPathComponent().standardizedFileURL.path == importPath,
              fileManager.fileExists(atPath: sourcePath) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    func makeExportDirectory() throws -> URL {
        try prepareBaseDirectories()

        let directory = exportsDirectory
            .appendingPathComponent(Self.timestampString(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try createDirectoryIfNeeded(directory)
        try? excludeFromBackup(directory)
        return directory
    }

    /// Imports a rendered clip carried inside a portable `.reelclip` package.
    /// Source footage belongs in `Imports`; already-rendered outputs belong in
    /// `Exports` so cleanup and sharing continue to use the normal ownership
    /// rules after a handoff.
    func importPortableRenderedClip(from sourceURL: URL, into directory: URL) throws -> URL {
        try prepareBaseDirectories()
        let sourceBytes = fileSize(at: sourceURL)
        try validateAvailableCapacity(additionalBytes: sourceBytes)
        let destinationURL = FilenameSanitizer.uniqueURL(
            for: sourceURL.lastPathComponent,
            in: directory
        )
        try copyFileReportingProgress(
            from: sourceURL,
            to: destinationURL,
            progress: nil
        )
        return destinationURL
    }

    func removeDirectories(for clips: [SegmentOutput]) {
        let directories = Set(clips.map { $0.url.deletingLastPathComponent() })

        for directory in directories where isInsideWorkspace(directory) {
            try? fileManager.removeItem(at: directory)
        }
    }

    func removeFile(for clip: SegmentOutput) {
        let url = clip.url.standardizedFileURL
        guard isInsideWorkspace(url),
              fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func cleanupExports(olderThan cutoffDate: Date, preserving protectedURLs: [URL] = []) throws {
        guard fileManager.fileExists(atPath: exportsDirectory.path) else { return }

        let protectedPaths = protectedURLs.map(\.standardizedFileURL.path)
        let folders = try fileManager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )

        for folder in folders {
            let values = try folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let children = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
            let childDirectories = children.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let candidateDirectories = childDirectories.isEmpty ? [folder] : childDirectories

            for directory in candidateDirectories {
                let directoryPath = directory.standardizedFileURL.path
                guard !protectedPaths.contains(where: { $0 == directoryPath || $0.hasPrefix(directoryPath + "/") }) else {
                    continue
                }

                let directoryValues = try directory.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = directoryValues.contentModificationDate, modified < cutoffDate else { continue }
                try fileManager.removeItem(at: directory)
            }

            if let remainingChildren = try? fileManager.contentsOfDirectory(atPath: folder.path),
               remainingChildren.isEmpty {
                try fileManager.removeItem(at: folder)
            }
        }
    }

    func storedMediaSizeBytes() -> Int64 {
        sizeOfDirectory(rootDirectory)
    }

    func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return max((attributes?[.size] as? NSNumber)?.int64Value ?? 0, 0)
    }

    /// Keep a reserve beyond the predicted output so AVFoundation and iOS can
    /// still write metadata, thumbnails, and filesystem journals safely.
    func validateAvailableCapacity(
        additionalBytes: Int64,
        reserveBytes: Int64 = 512 * 1024 * 1024
    ) throws {
        guard additionalBytes > 0 else { return }
        try prepareBaseDirectories()

        let required = additionalBytes.addingReportingOverflow(reserveBytes)
        let requiredBytes = required.overflow ? Int64.max : required.partialValue
        guard let available = availableCapacityBytes(), available < requiredBytes else { return }

        // Derived waveforms and thumbnails are disposable. Reclaim them before
        // refusing the operation, then measure the volume one more time.
        cleanupDerivedMedia(olderThan: .distantFuture, maximumBytes: 0)
        let refreshedAvailable = availableCapacityBytes() ?? available
        guard refreshedAvailable < requiredBytes else { return }
        throw MediaWorkspaceError.insufficientStorage(
            requiredBytes: requiredBytes,
            availableBytes: refreshedAvailable
        )
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func availableCapacityBytes() -> Int64? {
        let values = try? rootDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func touchCacheFile(_ url: URL) {
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    /// Fast content identity for import deduplication. It reads at most 128 KB
    /// from each file, while the file size prevents most accidental matches.
    private func quickFileFingerprint(_ url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sampleLength = min(Int64(64 * 1024), max(size, 0))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let first = try handle.read(upToCount: Int(sampleLength)) ?? Data()
        var last = Data()
        if size > sampleLength {
            try handle.seek(toOffset: UInt64(size - sampleLength))
            last = try handle.read(upToCount: Int(sampleLength)) ?? Data()
        }

        var data = Data()
        withUnsafeBytes(of: size.bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
        data.append(first)
        data.append(last)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func copyFileReportingProgress(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: MediaImportProgressHandler?
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = max((attributes[.size] as? NSNumber)?.int64Value ?? 0, 0)
        let partialURL = destinationURL.appendingPathExtension("partial")

        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: partialURL)
        var copiedBytes: Int64 = 0

        do {
            while true {
                try Task.checkCancellation()
                guard let data = try sourceHandle.read(upToCount: 1_048_576), !data.isEmpty else {
                    break
                }
                try destinationHandle.write(contentsOf: data)
                copiedBytes += Int64(data.count)
                if totalBytes > 0 {
                    progress?(min(Double(copiedBytes) / Double(totalBytes), 1))
                }
            }

            try sourceHandle.close()
            try destinationHandle.synchronize()
            try destinationHandle.close()
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            progress?(1)
        } catch {
            try? sourceHandle.close()
            try? destinationHandle.close()
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let rootPath = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func sizeOfDirectory(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }

        var size: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
                continue
            }

            if values.isRegularFile == true {
                size += Int64(values.fileSize ?? 0)
            }
        }

        return size
    }

    private static func timestampString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
