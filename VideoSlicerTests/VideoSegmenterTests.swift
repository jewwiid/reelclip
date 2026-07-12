@preconcurrency import AVFoundation
@testable import VideoSlicer
import XCTest

final class VideoSegmenterTests: XCTestCase {
    func testClipQueryParserParsesHyphenatedWordDurationRecipe() throws {
        let query = try XCTUnwrap(ClipQueryParser.parse("5 five-second clips every 10 seconds"))

        XCTAssertTrue(query.isValid)
        XCTAssertEqual(query.count, 5)
        XCTAssertEqual(query.durationSeconds, 5)
        XCTAssertEqual(query.intervalSeconds, 10)
    }

    func testClipQueryParserParsesFormatterOutput() throws {
        let text = FixedModeQueryFormatter.phrase(count: 4, duration: 5, interval: 10)
        let query = try XCTUnwrap(ClipQueryParser.parse(text))

        XCTAssertTrue(query.isValid)
        XCTAssertEqual(query.count, 4)
        XCTAssertEqual(query.durationSeconds, 5)
        XCTAssertEqual(query.intervalSeconds, 10)
    }

    func testClipQueryParserKeepsSameValueDurationAndInterval() throws {
        let query = try XCTUnwrap(ClipQueryParser.parse("4 five-second clips every five seconds"))

        XCTAssertTrue(query.isValid)
        XCTAssertEqual(query.count, 4)
        XCTAssertEqual(query.durationSeconds, 5)
        XCTAssertEqual(query.intervalSeconds, 5)
    }

    func testClipQueryParserParsesHyphenatedCompoundNumbers() throws {
        let query = try XCTUnwrap(ClipQueryParser.parse("2 twenty-five-second clips 30s apart"))

        XCTAssertTrue(query.isValid)
        XCTAssertEqual(query.count, 2)
        XCTAssertEqual(query.durationSeconds, 25)
        XCTAssertEqual(query.intervalSeconds, 30)
    }

    func testAIEditIntentParsesExactCountAndDuration() {
        let intent = AIEditIntentParser.parse(
            prompt: "3 clips 20 seconds long",
            fallbackDuration: 28
        )

        XCTAssertEqual(intent.requestedClipCount, 3)
        XCTAssertEqual(intent.targetClipDurationSeconds, 20)
        XCTAssertTrue(intent.requiresExactCount)
        XCTAssertTrue(intent.requiresExactDuration)
        XCTAssertEqual(intent.expectedTotalDuration, 60)
        XCTAssertEqual(intent.summary, "3 clips · 20s each")
    }

    func testAIEditPlanResolverEnforcesExactCountDurationAndNoOverlap() throws {
        let intent = AIEditIntentParser.parse(
            prompt: "Create exactly 3 clips, 20 seconds long",
            fallbackDuration: 28
        )
        let features = TimelineFeaturePack(
            sourceDurationSeconds: 90,
            fallbackSegmentLengthSeconds: 20,
            requestedMaxClips: 3,
            targetPlatform: "Reels/TikTok",
            analysisPoints: [],
            fallbackRanges: [],
            videoFrames: [],
            editIntent: intent
        )
        let candidates = [
            ClipRange(startSeconds: 8, endSeconds: 13, reason: "Opening"),
            ClipRange(startSeconds: 38, endSeconds: 44, reason: "Middle"),
            ClipRange(startSeconds: 68, endSeconds: 74, reason: "Ending")
        ]

        let resolved = try AIEditPlanResolver.resolve(
            candidates: candidates,
            features: features
        )

        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(resolved.allSatisfy { abs($0.duration - 20) < 0.001 })
        XCTAssertTrue(zip(resolved, resolved.dropFirst()).allSatisfy {
            $0.endSeconds <= $1.startSeconds
        })
    }

    func testAIEditPlanResolverRejectsImpossibleExactRequest() {
        let intent = AIEditIntentParser.parse(
            prompt: "3 clips 20 seconds long",
            fallbackDuration: 28
        )
        let features = TimelineFeaturePack(
            sourceDurationSeconds: 45,
            fallbackSegmentLengthSeconds: 20,
            requestedMaxClips: 3,
            targetPlatform: "Reels/TikTok",
            analysisPoints: [],
            fallbackRanges: [],
            videoFrames: [],
            editIntent: intent
        )

        XCTAssertThrowsError(
            try AIEditPlanResolver.resolve(candidates: [], features: features)
        ) { error in
            XCTAssertEqual(
                error as? AIEditIntentError,
                .insufficientSource(required: 60, available: 45)
            )
        }
    }

    func testAIEditPlanResolverScalesFallbackDurationForCountOnlyRequest() throws {
        let intent = AIEditIntentParser.parse(
            prompt: "Create 3 clips",
            fallbackDuration: 28
        )
        let features = TimelineFeaturePack(
            sourceDurationSeconds: 60,
            fallbackSegmentLengthSeconds: 28,
            requestedMaxClips: 3,
            targetPlatform: "Reels/TikTok",
            analysisPoints: [],
            fallbackRanges: [],
            videoFrames: [],
            editIntent: intent
        )

        let resolved = try AIEditPlanResolver.resolve(
            candidates: [],
            features: features
        )

        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(resolved.allSatisfy { abs($0.duration - 20) < 0.001 })
    }

    func testCompactTimelineFeaturesPreserveAIEditIntent() {
        let intent = AIEditIntentParser.parse(
            prompt: "3 clips 20 seconds long",
            fallbackDuration: 28
        )
        let snippets = (0..<40).map { index in
            TimelineTranscriptSnippet(
                startSeconds: Double(index),
                endSeconds: Double(index + 1),
                text: String(repeating: "spoken context ", count: 20)
            )
        }
        let features = TimelineFeaturePack(
            sourceDurationSeconds: 90,
            fallbackSegmentLengthSeconds: 20,
            requestedMaxClips: 3,
            targetPlatform: "Reels/TikTok",
            analysisPoints: [],
            fallbackRanges: [],
            videoFrames: [],
            transcriptSnippets: snippets,
            editIntent: intent
        )

        let compact = features.compactForLanguageModel()
        XCTAssertEqual(compact.editIntent, intent)
        XCTAssertEqual(compact.transcriptSnippets.count, 20)
        XCTAssertTrue(compact.transcriptSnippets.allSatisfy { $0.text.count <= 160 })
    }

    @MainActor
    func testAIEditPromptSynchronizesVisibleRecipeMetrics() {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let viewModel = VideoSplitterViewModel(mediaWorkspace: workspace)
        viewModel.cutMode = .aiAssist
        viewModel.durationSeconds = 90
        viewModel.segmentLengthText = "28"

        viewModel.updateAIEditPrompt("3 clips 20 seconds long")

        XCTAssertEqual(viewModel.segmentLengthText, "20")
        XCTAssertEqual(viewModel.expectedClipCountLabel, "3")
        XCTAssertEqual(viewModel.durationLabel, "1:00")
        XCTAssertEqual(viewModel.resolvedAIEditIntent.summary, "3 clips · 20s each")
    }

    func testFixedCountSurvivesFinalValidationWhenClipsMustScaleDown() throws {
        let ranges = ClipQuery(
            count: 12,
            durationSeconds: 5,
            intervalSeconds: 10
        ).ranges(forSourceDuration: 6)

        let validated = try MediaProcessingLimits.validatedClipPlan(
            ranges,
            totalDuration: 6,
            frameDuration: 1.0 / 30.0,
            minimumDuration: 0.05
        )

        XCTAssertEqual(validated.count, 12)
    }

    @MainActor
    func testFixedRecipeUsesVisibleButtonCountWhenLegacyTextStyleIsRestored() {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let viewModel = VideoSplitterViewModel(mediaWorkspace: workspace)
        viewModel.fixedModeInputStyle = .text
        viewModel.fixedModeQueryDraft = "4 five-second clips every 10 seconds"
        viewModel.fixedModeButtonCount = 12
        viewModel.fixedModeButtonDuration = 5
        viewModel.fixedModeButtonInterval = 10
        viewModel.setFixedModeRandomDuration(false)
        viewModel.setFixedModeRandomInterval(false)

        let ranges = viewModel.fixedModeRanges(forSourceDuration: 120)

        XCTAssertEqual(ranges.count, 12)
        XCTAssertEqual(viewModel.expectedClipCount, nil)
        viewModel.durationSeconds = 120
        XCTAssertEqual(viewModel.expectedClipCount, 12)
    }

    @MainActor
    func testSilenceAndAIDefaultToWholeSourceAfterPreviousPlansExist() {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let viewModel = VideoSplitterViewModel(mediaWorkspace: workspace)
        viewModel.plannedRanges = [
            ClipRange(startSeconds: 10, endSeconds: 20, cutMode: .smartPause),
            ClipRange(startSeconds: 30, endSeconds: 40, cutMode: .aiAssist)
        ]

        viewModel.cutMode = .smartPause
        XCTAssertTrue(viewModel.selectedAnalysisRanges.isEmpty)
        XCTAssertEqual(viewModel.analysisScopeLabel, "Whole source")

        viewModel.cutMode = .aiAssist
        XCTAssertTrue(viewModel.selectedAnalysisRanges.isEmpty)
        XCTAssertEqual(viewModel.analysisScopeLabel, "Whole source")
    }

    func testMediaWorkspaceCopiesImportsIntoImportsFolder() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-source-\(UUID().uuidString).mov")
        let data = Data("source-video-placeholder".utf8)
        try data.write(to: sourceURL)

        let copiedURL = try workspace.importSourceCopy(from: sourceURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertTrue(copiedURL.path.hasPrefix(workspace.importsDirectory.path))
        XCTAssertEqual(try Data(contentsOf: copiedURL), data)
    }

    func testPickedVideoMaterializesBeforePhotosTemporaryFileDisappears() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let receivedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-transfer-\(UUID().uuidString).mov")
        let data = Data("photos-video-placeholder".utf8)
        try data.write(to: receivedURL)

        let picked = try PickedVideo.materialize(
            receivedFile: receivedURL,
            workspace: workspace
        )
        try FileManager.default.removeItem(at: receivedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.url.path))
        XCTAssertEqual(try Data(contentsOf: picked.url), data)
        XCTAssertTrue(picked.isWorkspaceCopyNew)
    }

    func testPickedVideoReportsPhotosDownloadFailureForMissingTransfer() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-photos-transfer-\(UUID().uuidString).mov")

        XCTAssertThrowsError(
            try PickedVideo.materialize(receivedFile: missingURL, workspace: workspace)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                PickedVideoImportError.photosDownloadUnavailable.localizedDescription
            )
        }
    }

    func testMediaWorkspaceReportsRealCopyProgress() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-progress-source-\(UUID().uuidString).mov")
        try Data(repeating: 7, count: 3 * 1_048_576).write(to: sourceURL)
        let recorder = ImportProgressRecorder()

        _ = try workspace.importSourceCopyResult(from: sourceURL) { fraction in
            recorder.append(fraction)
        }

        let values = recorder.values
        XCTAssertGreaterThan(values.count, 3)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testMediaWorkspaceMarksDeduplicatedImportAsShared() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-dedup-source-\(UUID().uuidString).mov")
        try Data("deduplicated-source".utf8).write(to: sourceURL)

        let created = try workspace.importSourceCopyResult(from: sourceURL)
        let shared = try workspace.importSourceCopyResult(from: sourceURL)

        XCTAssertTrue(created.wasCreated)
        XCTAssertFalse(shared.wasCreated)
        XCTAssertEqual(created.url, shared.url)
    }

    func testMediaWorkspaceFindsCachedProxyForUnchangedSource() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = workspace.importsDirectory
            .appendingPathComponent("proxy-source.mov")
        try workspace.prepareBaseDirectories()
        try Data("original-media".utf8).write(to: sourceURL)

        let proxyURL = try workspace.proxyURL(for: sourceURL)
        try Data("proxy-media".utf8).write(to: proxyURL)

        XCTAssertEqual(workspace.cachedProxyURL(for: sourceURL), proxyURL)
    }

    func testMediaWorkspaceInvalidatesProxyWhenSourceChanges() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = workspace.importsDirectory
            .appendingPathComponent("changing-proxy-source.mov")
        try workspace.prepareBaseDirectories()
        try Data("first-source".utf8).write(to: sourceURL)

        let firstProxyURL = try workspace.proxyURL(for: sourceURL)
        try Data("proxy-media".utf8).write(to: firstProxyURL)
        try Data("second-source-with-a-different-size".utf8).write(to: sourceURL)

        let secondProxyURL = try workspace.proxyURL(for: sourceURL)
        XCTAssertNotEqual(firstProxyURL, secondProxyURL)
        XCTAssertNil(workspace.cachedProxyURL(for: sourceURL))
    }

    func testMediaWorkspaceRemovesOnlyDirectImportCandidate() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-candidate-source-\(UUID().uuidString).mov")
        try Data("candidate-source".utf8).write(to: sourceURL)
        let imported = try workspace.importSourceCopyResult(from: sourceURL)

        workspace.removeImportedSource(at: imported.url)
        workspace.removeImportedSource(at: sourceURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testMediaWorkspaceCreatesUniqueExportDirectories() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())

        let first = try workspace.makeExportDirectory()
        let second = try workspace.makeExportDirectory()

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(first.path.hasPrefix(workspace.exportsDirectory.path))
        XCTAssertTrue(second.path.hasPrefix(workspace.exportsDirectory.path))
    }

    func testMediaWorkspaceReportsStoredMediaSize() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        try workspace.prepareBaseDirectories()

        let fileURL = workspace.importsDirectory.appendingPathComponent("size-check.bin")
        try Data(repeating: 7, count: 128).write(to: fileURL)

        XCTAssertGreaterThanOrEqual(workspace.storedMediaSizeBytes(), 128)
    }

    func testMediaWorkspaceOnlyRemovesClipDirectoriesInsideWorkspace() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let exportDirectory = try workspace.makeExportDirectory()
        let clipURL = exportDirectory.appendingPathComponent("clip-1.mov")
        try Data("clip".utf8).write(to: clipURL)

        let outsideDirectory = makeTemporaryDirectory()
        let outsideURL = outsideDirectory.appendingPathComponent("clip-2.mov")
        try Data("outside".utf8).write(to: outsideURL)

        let clips = [
            SegmentOutput(index: 0, url: clipURL, startSeconds: 0, endSeconds: 1),
            SegmentOutput(index: 1, url: outsideURL, startSeconds: 1, endSeconds: 2)
        ]

        workspace.removeDirectories(for: clips)

        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }

    func testMediaWorkspaceCleanupPreservesReferencedExportClips() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let protectedExportDirectory = try workspace.makeExportDirectory()
        let staleExportDirectory = try workspace.makeExportDirectory()
        let protectedClipURL = protectedExportDirectory.appendingPathComponent("clip-1.mp4")
        let staleClipURL = staleExportDirectory.appendingPathComponent("clip-2.mp4")
        try Data("protected".utf8).write(to: protectedClipURL)
        try Data("stale".utf8).write(to: staleClipURL)

        let oldDate = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: protectedExportDirectory.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleExportDirectory.path)

        try workspace.cleanupExports(
            olderThan: Date(timeIntervalSince1970: 200),
            preserving: [protectedClipURL]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedClipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleClipURL.path))
    }

    func testPortableReelClipPackageRoundTripsCompleteEditableProject() async throws {
        let senderRoot = makeTemporaryDirectory()
        let sourceA = senderRoot.appendingPathComponent("camera-a.mov")
        let sourceB = senderRoot.appendingPathComponent("camera-b.mov")
        let rendered = senderRoot.appendingPathComponent("rendered-clip.mov")
        let sourceAData = Data("original-source-a".utf8)
        let sourceBData = Data("original-source-b".utf8)
        let renderedData = Data("rendered-output".utf8)
        try sourceAData.write(to: sourceA)
        try sourceBData.write(to: sourceB)
        try renderedData.write(to: rendered)

        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let transcriptA = Transcript(
            language: "en",
            segments: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 2,
                    text: "First scene",
                    words: [TranscriptWord(text: "First", startSeconds: 0, endSeconds: 1)]
                )
            ],
            generatedAt: now
        )
        let transcriptB = Transcript(
            language: "en",
            segments: [
                TranscriptSegment(
                    startSeconds: 4,
                    endSeconds: 7,
                    text: "Second scene",
                    words: [TranscriptWord(text: "Second", startSeconds: 4, endSeconds: 5)]
                )
            ],
            generatedAt: now
        )
        let editorState = MediaProjectSceneEditorState(
            timelineZoom: .ultra,
            selectedAIProvider: .appleIntelligence,
            hasManualHighlightDuration: true,
            fixedModeInputStyle: .buttons,
            fixedModeQueryDraft: "12 clips",
            fixedModeButtonCount: 12,
            fixedModeButtonDuration: 9,
            fixedModeButtonInterval: 8,
            fixedModeRandomDuration: true,
            fixedModeRandomInterval: true,
            fixedModeRandomDurationMinimum: 3,
            fixedModeRandomDurationMaximum: 9,
            fixedModeRandomIntervalMinimum: 2,
            fixedModeRandomIntervalMaximum: 8,
            fixedModeRandomSeed: 42
        )
        let sceneA = MediaProjectScene(
            name: "Interview",
            sourcePath: sourceA.path,
            sourceFileName: sourceA.lastPathComponent,
            sourcePhotoLibraryIdentifier: "sender-photos-a",
            sourceOriginalFilename: sourceA.lastPathComponent,
            durationSeconds: 20,
            sourceAspectRatio: 16.0 / 9.0,
            frameDurationSeconds: 1.0 / 30.0,
            cutMode: .highlight,
            segmentLengthText: "5",
            editPrompt: "Keep the intro",
            plannedRanges: [
                ClipRange(
                    startSeconds: 1,
                    endSeconds: 6,
                    reason: "Opening",
                    isLocked: true,
                    cutMode: .highlight
                )
            ],
            highlightDraftStart: 8,
            highlightDraftDuration: 4,
            transcript: transcriptA,
            editorState: editorState,
            scrubPositionSeconds: 3,
            createdAt: now,
            updatedAt: now
        )
        let sceneB = MediaProjectScene(
            name: "B-roll",
            sourcePath: sourceB.path,
            sourceFileName: sourceB.lastPathComponent,
            sourcePhotoLibraryIdentifier: "sender-photos-b",
            sourceOriginalFilename: sourceB.lastPathComponent,
            durationSeconds: 30,
            sourceAspectRatio: 9.0 / 16.0,
            frameDurationSeconds: 1.0 / 60.0,
            cutMode: .fixed,
            segmentLengthText: "9",
            editPrompt: "Fast inserts",
            plannedRanges: [
                ClipRange(startSeconds: 4, endSeconds: 13, reason: "Action", cutMode: .fixed)
            ],
            transcript: transcriptB,
            editorState: editorState,
            scrubPositionSeconds: 11,
            createdAt: now,
            updatedAt: now
        )
        let storedClip = StoredClipOutput(
            index: 1,
            title: "Approved insert",
            path: rendered.path,
            startSeconds: 4,
            endSeconds: 13,
            photoLibraryLocalIdentifier: "sender-rendered-asset"
        )
        let project = MediaProject(
            id: UUID(),
            title: "Portable campaign",
            sourcePath: sourceB.path,
            sourceFileName: sourceB.lastPathComponent,
            durationSeconds: 30,
            sourceAspectRatio: 9.0 / 16.0,
            frameDurationSeconds: 1.0 / 60.0,
            cutMode: .fixed,
            segmentLengthText: "9",
            editPrompt: "Fast inserts",
            plannedRanges: sceneB.plannedRanges,
            scenes: [sceneA, sceneB],
            activeSceneId: sceneB.id,
            exportedClips: [storedClip],
            projectExportOrder: [1, 0],
            savedClipsOrder: [1, 0],
            savedClips: sceneA.plannedRanges + sceneB.plannedRanges,
            scrubPositionSeconds: 11,
            transcript: transcriptB,
            sourcePhotoLibraryIdentifier: "sender-photos-b",
            exportSettings: ExportSettings(resolution: .source, frameRate: .fps60),
            createdAt: now,
            updatedAt: now
        )

        let packageURL = senderRoot.appendingPathComponent("Campaign.reelclip", isDirectory: true)
        try ReelClipProjectCodec.writePortablePackage(
            project,
            to: packageURL,
            appVersion: "1.0 (130)"
        )

        let packageValues = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(packageValues.isDirectory, true)
        let manifestURL = packageURL.appendingPathComponent(ReelClipProjectCodec.manifestFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("Derived").path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            ReelClipProjectEnvelope.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(envelope.schemaVersion, 3)
        XCTAssertEqual(envelope.formatIdentifier, ReelClipProjectEnvelope.expectedFormatIdentifier)
        XCTAssertEqual(envelope.media?.attachments.filter { $0.role == .source }.count, 2)
        XCTAssertEqual(envelope.media?.attachments.filter { $0.role == .renderedClip }.count, 1)
        XCTAssertTrue(envelope.payload.scenes?.allSatisfy { $0.sourcePath == nil } ?? false)
        XCTAssertNil(envelope.payload.sourcePhotoLibraryIdentifier)
        XCTAssertTrue(
            envelope.payload.scenes?.allSatisfy { $0.sourcePhotoLibraryIdentifier == nil } ?? false
        )
        XCTAssertTrue(envelope.payload.exportedClips.allSatisfy { $0.photoLibraryLocalIdentifier == nil })
        XCTAssertEqual(envelope.payload.transcript, transcriptB)
        XCTAssertEqual(
            envelope.payload.exportSettings,
            ExportSettings(resolution: .source, frameRate: .fps60)
        )

        let recipientWorkspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let result = try await ReelClipProjectCodec.decode(
            contentsOf: packageURL,
            workspace: recipientWorkspace
        )
        XCTAssertEqual(result.sourceResolution, .resolvedViaPackage(importedSourceCount: 2))
        XCTAssertEqual(result.project.id, project.id)
        XCTAssertEqual(result.project.title, project.title)
        XCTAssertEqual(result.project.savedClips, project.savedClips)
        XCTAssertEqual(result.project.projectExportOrder, [1, 0])
        XCTAssertEqual(result.project.savedClipsOrder, [1, 0])
        XCTAssertEqual(result.project.transcript, transcriptB)
        XCTAssertEqual(result.project.exportSettings, project.exportSettings)
        XCTAssertEqual(result.project.scenes.count, 2)

        let importedA = try XCTUnwrap(result.project.scenes.first(where: { $0.id == sceneA.id }))
        let importedB = try XCTUnwrap(result.project.scenes.first(where: { $0.id == sceneB.id }))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(importedA.sourceURL)), sourceAData)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(importedB.sourceURL)), sourceBData)
        XCTAssertEqual(importedA.transcript, transcriptA)
        XCTAssertEqual(importedB.transcript, transcriptB)
        XCTAssertEqual(importedA.editorState, editorState)
        XCTAssertEqual(importedB.editorState, editorState)
        XCTAssertEqual(importedA.plannedRanges, sceneA.plannedRanges)
        XCTAssertEqual(importedB.plannedRanges, sceneB.plannedRanges)
        XCTAssertTrue(try XCTUnwrap(importedA.sourceURL).path.hasPrefix(recipientWorkspace.importsDirectory.path))
        XCTAssertTrue(try XCTUnwrap(importedB.sourceURL).path.hasPrefix(recipientWorkspace.importsDirectory.path))

        let importedRendered = try XCTUnwrap(result.project.exportedClips.first)
        XCTAssertEqual(try Data(contentsOf: importedRendered.url), renderedData)
        XCTAssertTrue(importedRendered.path.hasPrefix(recipientWorkspace.exportsDirectory.path))
    }

    func testLegacyV2FlatReelClipStillImportsItsEditMetadata() async throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let project = makeProject(
            title: "Legacy plan",
            workspace: workspace,
            plannedRanges: [
                ClipRange(startSeconds: 2, endSeconds: 5, reason: "Legacy", cutMode: .highlight)
            ]
        )
        let encoded = try ReelClipProjectCodec.encode(project, appVersion: "0.9")
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        root["schemaVersion"] = 2
        root.removeValue(forKey: "media")
        var payload = try XCTUnwrap(root["payload"] as? [String: Any])
        payload.removeValue(forKey: "sourcePhotoLibraryIdentifier")
        payload.removeValue(forKey: "sourceOriginalFilename")
        payload.removeValue(forKey: "sourceFileSize")
        payload.removeValue(forKey: "transcript")
        payload.removeValue(forKey: "exportSettings")
        payload["scenes"] = []
        root["payload"] = payload
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let result = try await ReelClipProjectCodec.decode(
            legacyData,
            workspace: MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        )

        XCTAssertEqual(result.sourceResolution, .missing)
        XCTAssertEqual(result.project.id, project.id)
        XCTAssertEqual(result.project.title, project.title)
        XCTAssertEqual(result.project.plannedRanges, project.plannedRanges)
    }

    func testPortableReelClipRejectsAttachmentPathTraversal() async throws {
        let root = makeTemporaryDirectory()
        let sourceURL = root.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: sourceURL)
        let scene = MediaProjectScene(
            name: "Scene 1",
            sourcePath: sourceURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            sourceOriginalFilename: sourceURL.lastPathComponent,
            durationSeconds: 5,
            sourceAspectRatio: 16.0 / 9.0,
            frameDurationSeconds: 1.0 / 30.0,
            cutMode: .highlight,
            segmentLengthText: "5",
            editPrompt: "",
            plannedRanges: [],
            scrubPositionSeconds: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let project = MediaProject(
            id: UUID(),
            title: "Unsafe",
            sourcePath: sourceURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            durationSeconds: 5,
            sourceAspectRatio: 16.0 / 9.0,
            frameDurationSeconds: 1.0 / 30.0,
            cutMode: .highlight,
            segmentLengthText: "5",
            editPrompt: "",
            plannedRanges: [],
            scenes: [scene],
            activeSceneId: scene.id,
            scrubPositionSeconds: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let packageURL = root.appendingPathComponent("Unsafe.reelclip", isDirectory: true)
        try ReelClipProjectCodec.writePortablePackage(project, to: packageURL, appVersion: "1.0")

        let manifestURL = packageURL.appendingPathComponent(ReelClipProjectCodec.manifestFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let originalEnvelope = try decoder.decode(
            ReelClipProjectEnvelope.self,
            from: Data(contentsOf: manifestURL)
        )
        var media = try XCTUnwrap(originalEnvelope.media)
        let attachment = try XCTUnwrap(media.attachments.first)
        media.attachments[0] = ReelClipMediaAttachment(
            id: attachment.id,
            role: attachment.role,
            relativePath: "../outside.mov",
            originalFilename: attachment.originalFilename,
            byteCount: attachment.byteCount
        )
        let tampered = ReelClipProjectEnvelope(
            payload: originalEnvelope.payload,
            appVersion: originalEnvelope.appVersion,
            media: media
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(to: manifestURL, options: [.atomic])

        do {
            _ = try await ReelClipProjectCodec.decode(
                contentsOf: packageURL,
                workspace: MediaWorkspace(rootDirectory: makeTemporaryDirectory())
            )
            XCTFail("Expected path traversal validation to reject the package")
        } catch let error as ReelClipProjectCodecError {
            guard case .invalidPackage = error else {
                return XCTFail("Unexpected codec error: \(error)")
            }
        }
    }

    func testProjectStorePersistsAndSortsProjects() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let store = MediaProjectStore(workspace: workspace)
        let exportedClipURL = workspace.exportsDirectory.appendingPathComponent("clip-1.mp4")
        let olderProject = makeProject(
            title: "Older",
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 120)
        )
        let newerProject = makeProject(
            title: "Newer",
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 180),
            plannedRanges: [ClipRange(startSeconds: 1, endSeconds: 4)],
            exportedClips: [
                StoredClipOutput(
                    index: 0,
                    path: exportedClipURL.path,
                    startSeconds: 1,
                    endSeconds: 4,
                    photoLibraryLocalIdentifier: "photos-local-id"
                )
            ]
        )

        try store.saveProjects([olderProject, newerProject])

        let loaded = try MediaProjectStore(workspace: workspace).loadProjects()

        XCTAssertEqual(loaded.map(\.id), [newerProject.id, olderProject.id])
        XCTAssertEqual(loaded.first?.plannedRanges, [ClipRange(startSeconds: 1, endSeconds: 4)])
        XCTAssertEqual(loaded.first?.exportedClips.first?.path, exportedClipURL.path)
        XCTAssertEqual(loaded.first?.exportedClips.first?.photoLibraryLocalIdentifier, "photos-local-id")
        XCTAssertEqual(loaded.first?.exportedClips.first?.segmentOutput.photoLibraryLocalIdentifier, "photos-local-id")
        XCTAssertEqual(loaded.first?.cutMode, .highlight)
    }

    func testProjectStoreLoadsLegacyProjectsWithoutExportedClips() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        try workspace.prepareBaseDirectories()

        let projectID = UUID()
        let sourceURL = workspace.importsDirectory.appendingPathComponent("legacy.mov")
        let json = """
        [
          {
            "id" : "\(projectID.uuidString)",
            "title" : "Legacy",
            "sourcePath" : "\(sourceURL.path)",
            "sourceFileName" : "legacy.mov",
            "durationSeconds" : 12,
            "sourceAspectRatio" : 1.7777777778,
            "frameDurationSeconds" : 0.0333333333,
            "cutMode" : "Highlight",
            "segmentLengthText" : "30",
            "editPrompt" : "Make a fast reel",
            "plannedRanges" : [
              {
                "startSeconds" : 0,
                "endSeconds" : 4
              }
            ],
            "scrubPositionSeconds" : 1,
            "createdAt" : "2026-06-18T00:00:00Z",
            "updatedAt" : "2026-06-18T00:01:00Z"
          }
        ]
        """
        try json.write(
            to: workspace.projectsDirectory.appendingPathComponent("projects.json"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try MediaProjectStore(workspace: workspace).loadProjects()

        XCTAssertEqual(loaded.first?.id, projectID)
        XCTAssertEqual(loaded.first?.exportedClips, [])
    }

    func testProjectStoreUpsertsAndDeletesProjects() throws {
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let store = MediaProjectStore(workspace: workspace)
        var project = makeProject(title: "Draft", workspace: workspace)

        try store.upsert(project)
        project.title = "Updated draft"
        project.plannedRanges = [ClipRange(startSeconds: 0, endSeconds: 2)]
        let updatedProjects = try store.upsert(project)

        XCTAssertEqual(updatedProjects.count, 1)
        XCTAssertEqual(updatedProjects.first?.title, "Updated draft")
        XCTAssertEqual(updatedProjects.first?.plannedRanges.count, 1)

        let remainingProjects = try store.deleteProject(id: project.id)

        XCTAssertTrue(remainingProjects.isEmpty)
        XCTAssertTrue(try store.loadProjects().isEmpty)
    }

    func testProcessingLimitsRejectOverlongSource() {
        let maximum = MediaProcessingLimits.maximumSourceDurationSeconds(for: .free)
        XCTAssertThrowsError(
            try MediaProcessingLimits.validateSourceDuration(
                maximum + 0.1,
                for: .free
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaProcessingLimitError,
                .sourceTooLong(maximumDuration: maximum)
            )
        }
    }

    func testProcessingLimitsRejectTooManyPlannedClips() {
        let ranges = (0..<MediaProcessingLimits.maximumPlannedClips + 1).map { index in
            ClipRange(startSeconds: Double(index), endSeconds: Double(index) + 0.75)
        }

        XCTAssertThrowsError(
            try MediaProcessingLimits.validatedClipPlan(
                ranges,
                totalDuration: Double(MediaProcessingLimits.maximumPlannedClips + 2),
                frameDuration: 1.0 / 30.0
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaProcessingLimitError,
                .tooManyPlannedClips(
                    count: MediaProcessingLimits.maximumPlannedClips + 1,
                    maximum: MediaProcessingLimits.maximumPlannedClips
                )
            )
        }
    }

    func testEqualRangesMergeTinyFinalRemainderWhenRequested() {
        let ranges = SmartCutAnalyzer.equalRanges(
            totalDuration: 10.3,
            segmentLength: 5,
            minimumFinalSegmentLength: 1
        )

        XCTAssertEqual(ranges, [
            ClipRange(startSeconds: 0, endSeconds: 5),
            ClipRange(startSeconds: 5, endSeconds: 10.3)
        ])
    }

    func testEqualRangesKeepUsefulFinalRemainder() {
        let ranges = SmartCutAnalyzer.equalRanges(
            totalDuration: 10.8,
            segmentLength: 5,
            minimumFinalSegmentLength: 0.75
        )

        XCTAssertEqual(ranges, [
            ClipRange(startSeconds: 0, endSeconds: 5),
            ClipRange(startSeconds: 5, endSeconds: 10),
            ClipRange(startSeconds: 10, endSeconds: 10.8)
        ])
    }

    func testSegmentOutputTimeRangeShowsFractionalSeconds() {
        let clip = SegmentOutput(
            index: 0,
            url: URL(fileURLWithPath: "/tmp/clip.mov"),
            startSeconds: 10,
            endSeconds: 10.3
        )

        XCTAssertEqual(clip.timeRangeLabel, "0:10 - 0:10.3")
    }

    func testPreviewGeneratorSampleTimesStayInsideDuration() {
        let times = MediaPreviewGenerator.sampleTimes(durationSeconds: 5, targetCount: 4)

        XCTAssertEqual(times.count, 4)
        XCTAssertTrue(times.allSatisfy { $0 >= 0 && $0 < 5 })
        XCTAssertEqual(times[0], 0.625, accuracy: 0.001)
        XCTAssertEqual(times[3], 4.375, accuracy: 0.001)
    }

    func testPreviewGeneratorCreatesThumbnailsForGeneratedVideo() async throws {
        let sourceURL = try await makeTestVideo(duration: 1.5, frameRate: 10)
        let generator = MediaPreviewGenerator()

        let thumbnails = try await generator.thumbnails(
            for: sourceURL,
            durationSeconds: 1.5,
            targetCount: 3
        )

        XCTAssertFalse(thumbnails.isEmpty)
        XCTAssertTrue(thumbnails.allSatisfy { $0.image.size.width > 0 && $0.image.size.height > 0 })
    }

    func testProxyGeneratorSkipsSmallLowResolutionVideo() async throws {
        let sourceURL = try await makeTestVideo(duration: 1.0, frameRate: 10)
        let workspace = MediaWorkspace(rootDirectory: makeTemporaryDirectory())
        let generator = MediaProxyGenerator(workspace: workspace)
        let shouldGenerate = try await generator.shouldGenerateProxy(for: sourceURL)

        XCTAssertFalse(shouldGenerate)
    }

    func testPreviewGeneratorAspectRatioHonorsPreferredTransform() {
        let ratio = MediaPreviewGenerator.displayAspectRatio(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )

        XCTAssertEqual(ratio ?? 0, 1080.0 / 1920.0, accuracy: 0.001)
    }

    func testClipRangeEditorSnapsDraggedBoundariesToFrame() {
        let range = ClipRange(startSeconds: 0, endSeconds: 2)
        let edited = ClipRangeEditor.updatedRange(
            range,
            totalDuration: 5,
            frameDuration: 0.1,
            startSeconds: 0.26
        )

        XCTAssertEqual(edited.startSeconds, 0.3, accuracy: 0.001)
        XCTAssertEqual(edited.endSeconds, 2.0, accuracy: 0.001)
    }

    func testClipRangeEditorPreservesMinimumDurationWhenDraggingHandle() {
        let range = ClipRange(startSeconds: 1.0, endSeconds: 2.0)
        let edited = ClipRangeEditor.updatedRange(
            range,
            totalDuration: 5,
            frameDuration: 0.1,
            endSeconds: 1.03,
            minimumDuration: 0.5
        )

        XCTAssertEqual(edited.startSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(edited.endSeconds, 1.5, accuracy: 0.001)
    }

    func testClipRangeEditorMovesRangesWithoutChangingTimings() {
        let ranges = [
            ClipRange(startSeconds: 0, endSeconds: 1),
            ClipRange(startSeconds: 1, endSeconds: 2),
            ClipRange(startSeconds: 2, endSeconds: 3)
        ]

        let moved = ClipRangeEditor.movedRanges(ranges, from: 2, direction: -1)

        XCTAssertEqual(moved[0], ranges[0])
        XCTAssertEqual(moved[1], ranges[2])
        XCTAssertEqual(moved[2], ranges[1])
    }

    func testWaveformAnalyzerNormalizesAudioWindows() {
        let windows = [
            AudioEnergyWindow(startSeconds: 0, endSeconds: 1, rms: 0.1),
            AudioEnergyWindow(startSeconds: 1, endSeconds: 2, rms: 0.4),
            AudioEnergyWindow(startSeconds: 2, endSeconds: 3, rms: 0.2)
        ]

        let samples = WaveformAnalyzer.normalizedSamples(windows, targetCount: 3)

        XCTAssertEqual(samples.map(\.level), [0.25, 1.0, 0.5])
    }

    func testWaveformAnalyzerReadsAudioFile() async throws {
        let sourceURL = try makeTestAudioWithPause()
        let analyzer = WaveformAnalyzer()

        let samples = try await analyzer.samples(
            for: sourceURL,
            durationSeconds: 3,
            targetSampleCount: 12
        )

        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThan(samples.map(\.level).min() ?? 1, 0.2)
        XCTAssertGreaterThan(samples.map(\.level).max() ?? 0, 0.8)
    }

    func testFoundationModelsAvailabilityMatchesCurrentSDK() {
        #if canImport(FoundationModels)
        XCTAssertTrue(AIFeatureReadiness.foundationModelsFrameworkAvailable)
        #else
        XCTAssertFalse(AIFeatureReadiness.foundationModelsFrameworkAvailable)
        #endif
    }

    func testSmartCutPlannerUsesSilenceAsCutPoint() {
        let windows = [
            AudioEnergyWindow(startSeconds: 0.0, endSeconds: 0.5, rms: 0.12),
            AudioEnergyWindow(startSeconds: 0.5, endSeconds: 1.0, rms: 0.10),
            AudioEnergyWindow(startSeconds: 1.0, endSeconds: 1.5, rms: 0.01),
            AudioEnergyWindow(startSeconds: 1.5, endSeconds: 2.0, rms: 0.01),
            AudioEnergyWindow(startSeconds: 2.0, endSeconds: 2.5, rms: 0.11),
            AudioEnergyWindow(startSeconds: 2.5, endSeconds: 3.0, rms: 0.10)
        ]
        let settings = SmartCutSettings(
            minClipDuration: 1.0,
            maxClipDuration: 8.0,
            silenceThreshold: 0.035,
            minimumSilenceDuration: 0.5,
            analysisWindowDuration: 0.5
        )

        let ranges = SmartCutAnalyzer.planRanges(totalDuration: 3.0, windows: windows, settings: settings)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(ranges[0].endSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(ranges[1].startSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(ranges[1].endSeconds, 3.0, accuracy: 0.001)
    }

    func testSmartCutPlannerEnforcesMaximumClipDuration() {
        let windows = stride(from: 0.0, to: 5.0, by: 0.5).map { start in
            AudioEnergyWindow(startSeconds: start, endSeconds: start + 0.5, rms: 0.12)
        }
        let settings = SmartCutSettings(
            minClipDuration: 1.0,
            maxClipDuration: 2.0,
            silenceThreshold: 0.035,
            minimumSilenceDuration: 0.5,
            analysisWindowDuration: 0.5
        )

        let ranges = SmartCutAnalyzer.planRanges(totalDuration: 5.0, windows: windows, settings: settings)

        XCTAssertEqual(ranges.map { $0.duration }, [2.0, 2.0, 1.0])
    }

    func testNormalizedRangesClampToDurationAndDropInvalidRanges() {
        let ranges = [
            ClipRange(startSeconds: -1.0, endSeconds: 1.0),
            ClipRange(startSeconds: 2.0, endSeconds: 2.02),
            ClipRange(startSeconds: 3.0, endSeconds: 2.0),
            ClipRange(startSeconds: 4.5, endSeconds: 8.0)
        ]

        let normalized = VideoSegmenter.normalizedRanges(ranges, totalDuration: 5.0)

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(normalized[0].endSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(normalized[1].startSeconds, 4.5, accuracy: 0.001)
        XCTAssertEqual(normalized[1].endSeconds, 5.0, accuracy: 0.001)
    }

    func testSmartCutAnalyzerReadsAudioFileAndFindsPause() async throws {
        let sourceURL = try makeTestAudioWithPause()
        let analyzer = SmartCutAnalyzer()
        let settings = SmartCutSettings(
            minClipDuration: 0.8,
            maxClipDuration: 8.0,
            silenceThreshold: 0.02,
            minimumSilenceDuration: 0.5,
            analysisWindowDuration: 0.2
        )

        let ranges = try await analyzer.ranges(
            for: sourceURL,
            fallbackSegmentLength: 1,
            settings: settings
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].endSeconds, 1.5, accuracy: 0.35)
        XCTAssertEqual(ranges[1].startSeconds, 1.5, accuracy: 0.35)
    }

    func testSmartCutFallsBackToFixedRangesWhenVideoHasNoAudio() async throws {
        let sourceURL = try await makeTestVideo(duration: 2.5, frameRate: 10)
        let analyzer = SmartCutAnalyzer()

        let ranges = try await analyzer.ranges(for: sourceURL, fallbackSegmentLength: 1)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], ClipRange(startSeconds: 0.0, endSeconds: 1.0))
        XCTAssertEqual(ranges[1], ClipRange(startSeconds: 1.0, endSeconds: 2.0))
        XCTAssertEqual(ranges[2].startSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(ranges[2].endSeconds, 2.5, accuracy: 0.25)
    }

    func testSplitsGeneratedVideoIntoExpectedDurations() async throws {
        try skipSimulatorVideoExportTest()
        let sourceURL = try await makeTestVideo(duration: 2.5, frameRate: 10)
        let segmenter = makeSegmenter()
        var progressValues: [Double] = []

        let clips = try await segmenter.segmentVideo(sourceURL: sourceURL, segmentLength: 1) { progress in
            progressValues.append(progress)
        }

        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(progressValues.last ?? 0, 1.0, accuracy: 0.001)
        try await assertClip(clips[0], expectedDuration: 1.0)
        try await assertClip(clips[1], expectedDuration: 1.0)
        try await assertClip(clips[2], expectedDuration: 0.5)
    }

    func testCustomRangesAreClampedBeforeExport() async throws {
        try skipSimulatorVideoExportTest()
        let sourceURL = try await makeTestVideo(duration: 2.5, frameRate: 10)
        let segmenter = makeSegmenter()
        let ranges = [
            ClipRange(startSeconds: -0.5, endSeconds: 1.0),
            ClipRange(startSeconds: 1.0, endSeconds: 10.0),
            ClipRange(startSeconds: 2.2, endSeconds: 2.22)
        ]

        let clips = try await segmenter.segmentVideo(sourceURL: sourceURL, ranges: ranges) { _ in }

        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(clips[0].endSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(clips[1].startSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(clips[1].endSeconds, 2.5, accuracy: 0.25)
        try await assertClip(clips[0], expectedDuration: 1.0)
        try await assertClip(clips[1], expectedDuration: 1.5)
    }

    func testRemoveTemporaryFilesDeletesExportDirectory() async throws {
        try skipSimulatorVideoExportTest()
        let sourceURL = try await makeTestVideo(duration: 1.0, frameRate: 10)
        let segmenter = makeSegmenter()
        let clips = try await segmenter.segmentVideo(sourceURL: sourceURL, segmentLength: 1) { _ in }
        let outputDirectory = try XCTUnwrap(clips.first?.url.deletingLastPathComponent())

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.path))

        segmenter.removeTemporaryFiles(for: clips)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testExactMultipleDoesNotCreateEmptyTrailingClip() async throws {
        try skipSimulatorVideoExportTest()
        let sourceURL = try await makeTestVideo(duration: 2.0, frameRate: 10)
        let segmenter = makeSegmenter()

        let clips = try await segmenter.segmentVideo(sourceURL: sourceURL, segmentLength: 1) { _ in }

        XCTAssertEqual(clips.count, 2)
        try await assertClip(clips[0], expectedDuration: 1.0)
        try await assertClip(clips[1], expectedDuration: 1.0)
    }

    func testRejectsInvalidSegmentLength() async throws {
        let sourceURL = try await makeTestVideo(duration: 1.0, frameRate: 10)
        let segmenter = makeSegmenter()

        do {
            _ = try await segmenter.segmentVideo(sourceURL: sourceURL, segmentLength: 0) { _ in }
            XCTFail("Expected invalid segment length to throw.")
        } catch VideoSegmenterError.invalidSegmentLength {
        } catch {
            XCTFail("Expected invalidSegmentLength, received \(error).")
        }
    }

    private func assertClip(_ clip: SegmentOutput, expectedDuration: Double) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.url.path))

        let asset = AVURLAsset(url: clip.url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        XCTAssertTrue(seconds.isFinite)
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertEqual(seconds, expectedDuration, accuracy: 0.25)
    }

    private func makeSegmenter() -> VideoSegmenter {
        VideoSegmenter(workspace: MediaWorkspace(rootDirectory: makeTemporaryDirectory()))
    }

    private func makeProject(
        title: String,
        workspace: MediaWorkspace,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        updatedAt: Date = Date(timeIntervalSince1970: 100),
        plannedRanges: [ClipRange] = [],
        exportedClips: [StoredClipOutput] = []
    ) -> MediaProject {
        let sourceURL = workspace.importsDirectory.appendingPathComponent("\(title).mov")
        return MediaProject(
            id: UUID(),
            title: title,
            sourcePath: sourceURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            durationSeconds: 12,
            sourceAspectRatio: 16.0 / 9.0,
            frameDurationSeconds: 1.0 / 30.0,
            cutMode: .highlight,
            segmentLengthText: "30",
            editPrompt: "Make a fast reel",
            plannedRanges: plannedRanges,
            exportedClips: exportedClips,
            scrubPositionSeconds: 0,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoSlicerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTestVideo(duration: Double, frameRate: Int) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoSlicerTests-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let size = CGSize(width: 96, height: 96)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoSlicerTests", code: -2)
        }

        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VideoSlicerTests", code: -3)
        }

        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((duration * Double(frameRate)).rounded())
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            let pixelBuffer = try makePixelBuffer(size: size, frameIndex: frameIndex)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? NSError(domain: "VideoSlicerTests", code: -4)
            }
        }

        input.markAsFinished()

        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VideoSlicerTests", code: -5)
        }

        return outputURL
    }

    private func makeTestAudioWithPause() throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoSlicerAudio-\(UUID().uuidString).caf")
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * 3.0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!

        buffer.frameLength = frameCount

        guard let samples = buffer.floatChannelData?[0] else {
            throw NSError(domain: "VideoSlicerTests", code: -6)
        }

        for frame in 0..<Int(frameCount) {
            let seconds = Double(frame) / sampleRate

            if seconds >= 1.0, seconds < 2.0 {
                samples[frame] = 0
            } else {
                samples[frame] = Float(sin(2.0 * Double.pi * 440.0 * seconds) * 0.35)
            }
        }

        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try file.write(from: buffer)
        return outputURL
    }

    private func makePixelBuffer(size: CGSize, frameIndex: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "VideoSlicerTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "VideoSlicerTests", code: -1)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let color = UInt8((frameIndex * 17) % 255)

        for row in 0..<height {
            let rowPointer = baseAddress.advanced(by: row * bytesPerRow)
            let pixels = rowPointer.assumingMemoryBound(to: UInt8.self)

            for column in 0..<width {
                let offset = column * 4
                pixels[offset] = 255
                pixels[offset + 1] = color
                pixels[offset + 2] = UInt8((row * 255) / max(height, 1))
                pixels[offset + 3] = UInt8((column * 255) / max(width, 1))
            }
        }

        return pixelBuffer
    }

    // MARK: - Outro

    func testOutroDurationConstantIsThreeSeconds() {
        XCTAssertEqual(CMTimeGetSeconds(OutroRenderer.duration), 3.0, accuracy: 0.01)
    }

    func testOutroMarkIsCenteredForPortraitAndLandscapeExports() {
        for renderSize in [
            CGSize(width: 1080, height: 1920),
            CGSize(width: 1920, height: 1080)
        ] {
            let frame = OutroRenderer.markFrame(
                in: renderSize,
                imageSize: CGSize(width: 834, height: 1024)
            )

            XCTAssertEqual(frame.midX, renderSize.width / 2, accuracy: 0.001)
            XCTAssertEqual(frame.midY, renderSize.height / 2, accuracy: 0.001)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    func testOutroOverlayContainsOnlyTheIconLayer() {
        let overlay = OutroRenderer.makeOverlayLayer(
            for: CGSize(width: 1280, height: 720),
            contentsScale: 2,
            overlayStartTime: .zero
        )

        XCTAssertEqual(overlay.sublayers?.count, 1)
        XCTAssertFalse(overlay.sublayers?.contains(where: { $0 is CATextLayer }) ?? true)
        XCTAssertNotNil(overlay.sublayers?.first?.contents)
    }

    func testOutroCompositionHasThreeSecondDuration() async throws {
        let result = await OutroRenderer.composition(
            renderSize: CGSize(width: 1280, height: 720),
            frameDuration: CMTime(value: 1, timescale: 30)
        )
        guard let result else {
            XCTFail("OutroRenderer.composition returned nil")
            return
        }
        let duration = try await result.composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.0, accuracy: 0.01)
    }

    func testShouldAppendOutroIsTrueForFreeTier() {
        XCTAssertTrue(VideoSegmenter.shouldAppendOutro(forTier: .free))
    }

    func testShouldAppendOutroIsFalseForCreatorTier() {
        XCTAssertFalse(VideoSegmenter.shouldAppendOutro(forTier: .creator))
    }

    func testFreeTierExportAppendsOutroToClip() async throws {
        try skipSimulatorVideoExportTest()
        let segmenter = makeSegmenter()
        let sourceURL = try await makeTestVideo(duration: 1.0, frameRate: 10)
        let clips = try await segmenter.segmentVideo(
            sourceURL: sourceURL,
            segmentLength: 1,
            progress: { _ in },
            tier: .free
        )

        XCTAssertEqual(clips.count, 1)
        let clip = clips[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.url.path))

        let asset = AVURLAsset(url: clip.url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        // 1.0s source clip + 3.0s outro ≈ 4.0s. Tolerance covers
        // encoder quantization at this small size.
        XCTAssertEqual(seconds, 4.0, accuracy: 0.5)
    }

    func testCreatorTierExportHasNoOutro() async throws {
        let segmenter = makeSegmenter()
        let sourceURL = try await makeTestVideo(duration: 1.0, frameRate: 10)
        let clips = try await segmenter.segmentVideo(
            sourceURL: sourceURL,
            segmentLength: 1,
            progress: { _ in },
            tier: .creator
        )

        XCTAssertEqual(clips.count, 1)
        let clip = clips[0]
        let asset = AVURLAsset(url: clip.url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        // Creator tier is completely clean — no outro appended. Duration
        // should be the raw segment length (~1s).
        XCTAssertEqual(seconds, 1.0, accuracy: 0.4)
    }

    private func skipSimulatorVideoExportTest() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AVAssetExportSession video encoding is unstable in the iOS simulator. Run this export test on a device.")
        #endif
    }
}

private final class ImportProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock {
            storage.append(value)
        }
    }
}
