import Foundation

struct StoredClipOutput: Identifiable, Codable, Equatable {
    let id: UUID
    var index: Int
    var path: String
    var startSeconds: Double
    var endSeconds: Double
    var photoLibraryLocalIdentifier: String?

    var url: URL {
        URL(fileURLWithPath: path)
    }

    init(
        id: UUID = UUID(),
        index: Int,
        path: String,
        startSeconds: Double,
        endSeconds: Double,
        photoLibraryLocalIdentifier: String? = nil
    ) {
        self.id = id
        self.index = index
        self.path = path
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.photoLibraryLocalIdentifier = photoLibraryLocalIdentifier
    }

    init(clip: SegmentOutput) {
        self.id = clip.id
        self.index = clip.index
        self.path = clip.url.standardizedFileURL.path
        self.startSeconds = clip.startSeconds
        self.endSeconds = clip.endSeconds
        self.photoLibraryLocalIdentifier = clip.photoLibraryLocalIdentifier
    }

    var segmentOutput: SegmentOutput {
        SegmentOutput(
            id: id,
            index: index,
            url: url,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: photoLibraryLocalIdentifier
        )
    }
}

struct MediaProject: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourcePath: String
    var sourceFileName: String
    var durationSeconds: Double
    var sourceAspectRatio: Double
    var frameDurationSeconds: Double
    var cutMode: CutMode
    var segmentLengthText: String
    var editPrompt: String
    var plannedRanges: [ClipRange]
    var exportedClips: [StoredClipOutput]
    var scrubPositionSeconds: Double
    var createdAt: Date
    var updatedAt: Date

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    init(
        id: UUID,
        title: String,
        sourcePath: String,
        sourceFileName: String,
        durationSeconds: Double,
        sourceAspectRatio: Double,
        frameDurationSeconds: Double,
        cutMode: CutMode,
        segmentLengthText: String,
        editPrompt: String,
        plannedRanges: [ClipRange],
        exportedClips: [StoredClipOutput] = [],
        scrubPositionSeconds: Double,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.sourcePath = sourcePath
        self.sourceFileName = sourceFileName
        self.durationSeconds = durationSeconds
        self.sourceAspectRatio = sourceAspectRatio
        self.frameDurationSeconds = frameDurationSeconds
        self.cutMode = cutMode
        self.segmentLengthText = segmentLengthText
        self.editPrompt = editPrompt
        self.plannedRanges = plannedRanges
        self.exportedClips = exportedClips
        self.scrubPositionSeconds = scrubPositionSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourcePath
        case sourceFileName
        case durationSeconds
        case sourceAspectRatio
        case frameDurationSeconds
        case cutMode
        case segmentLengthText
        case editPrompt
        case plannedRanges
        case exportedClips
        case scrubPositionSeconds
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.sourcePath = try container.decode(String.self, forKey: .sourcePath)
        self.sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        self.durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        self.sourceAspectRatio = try container.decode(Double.self, forKey: .sourceAspectRatio)
        self.frameDurationSeconds = try container.decode(Double.self, forKey: .frameDurationSeconds)
        self.cutMode = try container.decode(CutMode.self, forKey: .cutMode)
        self.segmentLengthText = try container.decode(String.self, forKey: .segmentLengthText)
        self.editPrompt = try container.decode(String.self, forKey: .editPrompt)
        self.plannedRanges = try container.decode([ClipRange].self, forKey: .plannedRanges)
        self.exportedClips = try container.decodeIfPresent([StoredClipOutput].self, forKey: .exportedClips) ?? []
        self.scrubPositionSeconds = try container.decode(Double.self, forKey: .scrubPositionSeconds)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct MediaProjectStore {
    let workspace: MediaWorkspace

    private var indexURL: URL {
        workspace.projectsDirectory.appendingPathComponent("projects.json")
    }

    init(workspace: MediaWorkspace = MediaWorkspace()) {
        self.workspace = workspace
    }

    func loadProjects() throws -> [MediaProject] {
        guard workspace.fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }

        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MediaProject].self, from: data)
            .sortedByRecentUpdate()
    }

    @discardableResult
    func upsert(_ project: MediaProject) throws -> [MediaProject] {
        var projects = try loadProjects()

        if let existingIndex = projects.firstIndex(where: { $0.id == project.id }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }

        try saveProjects(projects)
        return projects.sortedByRecentUpdate()
    }

    @discardableResult
    func deleteProject(id: UUID) throws -> [MediaProject] {
        let projects = try loadProjects().filter { $0.id != id }
        try saveProjects(projects)
        return projects.sortedByRecentUpdate()
    }

    func saveProjects(_ projects: [MediaProject]) throws {
        try workspace.prepareBaseDirectories()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects.sortedByRecentUpdate())
        try data.write(to: indexURL, options: [.atomic])
    }
}

private extension Array where Element == MediaProject {
    func sortedByRecentUpdate() -> [MediaProject] {
        sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
