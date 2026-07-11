import CryptoKit
import Foundation
import UIKit

struct ImportedSourceCopy: Sendable {
    let url: URL
    let wasCreated: Bool
}

struct MediaWorkspace {
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

    func prepareBaseDirectories() throws {
        try createDirectoryIfNeeded(rootDirectory)
        try createDirectoryIfNeeded(importsDirectory)
        try createDirectoryIfNeeded(exportsDirectory)
        try createDirectoryIfNeeded(projectsDirectory)
        try createDirectoryIfNeeded(derivedMediaDirectory)
        try? excludeFromBackup(exportsDirectory)
        try? excludeFromBackup(derivedMediaDirectory)
    }

    /// Stable cache key for derived media. The source path is included so a
    /// replaced import cannot reuse another scene's artifacts; file metadata
    /// invalidates the cache when the source changes.
    func derivedMediaKey(
        for sourceURL: URL,
        kind: String,
        variant: String
    ) -> String {
        let values = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let fingerprint = [
            sourceURL.standardizedFileURL.path,
            String(values?.fileSize ?? 0),
            String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
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
            variant: "\(durationSeconds)-\(targetCount)-\(Int(maximumSize.width))x\(Int(maximumSize.height))"
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
            variant: "\(durationSeconds)-\(targetCount)-\(Int(maximumSize.width))x\(Int(maximumSize.height))"
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

    /// Copies a source into the private Imports directory and records whether
    /// this call created the file. The ownership bit lets the optional
    /// pre-import trim flow remove a cancelled candidate without touching a
    /// deduplicated source already used by another project.
    func importSourceCopyResult(from sourceURL: URL) throws -> ImportedSourceCopy {
        try prepareBaseDirectories()

        let sourceFingerprint = try quickFileFingerprint(sourceURL)
        let existingImports = try fileManager.contentsOfDirectory(
            at: importsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        for existingURL in existingImports {
            guard existingURL.pathExtension != "json",
                  (try? existingURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard (try? quickFileFingerprint(existingURL)) == sourceFingerprint else { continue }
            return ImportedSourceCopy(url: existingURL, wasCreated: false)
        }

        let fileName = "\(Self.timestampString())-\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destinationURL = importsDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
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

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
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
