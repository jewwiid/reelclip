import Foundation

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

    func prepareBaseDirectories() throws {
        try createDirectoryIfNeeded(rootDirectory)
        try createDirectoryIfNeeded(importsDirectory)
        try createDirectoryIfNeeded(exportsDirectory)
        try createDirectoryIfNeeded(projectsDirectory)
        try? excludeFromBackup(exportsDirectory)
    }

    func importSourceCopy(from sourceURL: URL) throws -> URL {
        try prepareBaseDirectories()

        let fileName = "\(Self.timestampString())-\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destinationURL = importsDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
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
