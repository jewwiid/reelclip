import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Binding var selectedTab: RootView.AppTab
    @State private var isFileImporterPresented = false
    @State private var isReelClipImporterPresented = false
    @State private var isReelClipExporterPresented = false
    @State private var reelClipExportURL: URL?
    @State private var showPaywall: Bool = false
    // Drives the "where should we import from?" chooser shown when
    // the user taps an empty state that needs a source video
    // (Photos or Files). Set to true by the empty-state tap
    // handler, cleared by the confirmationDialog's dismiss.
    @State private var isSourceChooserPresented: Bool = false
    // Drives the PhotosPicker presented by the source chooser
    // dialog. Separate from `homePickerItem` (the toolbar's
    // binding) so the two flows don't race — both write to the
    // same `homePickerItem` for the import handler, but only one
    // triggers the picker UI at a time.
    @State private var isHomePhotosPickerPresented: Bool = false
    @State private var renamingProject: MediaProject?
    @State private var projectRenameDraft: String = ""
    @State private var homePickerItem: PhotosPickerItem? = nil
    @State private var pendingImport: ImportTrimRequest?
    @State private var isPreparingImport = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                homeScroll

                if isPreparingImport {
                    importPreparationOverlay
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ReelClipProjectURLRouter.shared.attach(viewModel)
            }
            .onDisappear {
                ReelClipProjectURLRouter.shared.detach(viewModel)
            }
        }
        .tint(AppPalette.accent)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    guard !viewModel.isImportingMedia else { return }
                    prepareFileForNewProject(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isReelClipImporterPresented,
            allowedContentTypes: [UTType.reelClipProject],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    ReelClipProjectURLRouter.shared.handle(url: url)
                    selectedTab = .clip
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isReelClipExporterPresented,
            document: ReelClipProjectDocument(url: reelClipExportURL),
            contentType: UTType.reelClipProject,
            defaultFilename: reelClipExportURL?.deletingPathExtension().lastPathComponent ?? "ReelClip Project"
        ) { result in
            // Tidy up the temp file regardless of outcome.
            if let url = reelClipExportURL {
                try? FileManager.default.removeItem(at: url)
            }
            reelClipExportURL = nil
            switch result {
            case .success:
                viewModel.statusMessage = "Exported project file."
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionStore)
        }
        .sheet(item: $pendingImport) { request in
            ImportTrimSheet(
                request: request,
                onImport: { range in
                    commitNewProjectImport(request, trimRange: range)
                },
                onCancel: {
                    discardPendingImport(request)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Pick a source",
            isPresented: $isSourceChooserPresented,
            titleVisibility: .visible
        ) {
            // Photos — uses the same `homePickerItem` binding the
            // toolbar's "Media" button uses, so the picker UI and
            // import flow are identical. The PhotosPicker is
            // declared inline in the toolbar; tapping "Photos" here
            // just toggles a separate PhotosPicker that we'll
            // present via a fresh picker item.
            Button("Photos") {
                guard !viewModel.isImportingMedia, !isPreparingImport else { return }
                // Use a dedicated picker item so we don't race with
                // the toolbar's binding. Re-set the existing one —
                // it already drives the import flow on `.onChange`.
                homePickerItem = nil
                // Schedule the picker presentation: the
                // confirmationDialog dismissal animation must
                // finish before the PhotosPicker sheet starts,
                // otherwise iOS cancels one with the other. A
                // microsecond DispatchQueue.main.async gives the
                // dialog time to dismiss cleanly.
                DispatchQueue.main.async {
                    isHomePhotosPickerPresented = true
                }
            }
            Button("Files") {
                guard !viewModel.isImportingMedia, !isPreparingImport else { return }
                isFileImporterPresented = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $isHomePhotosPickerPresented,
            selection: $homePickerItem,
            matching: .videos,
            photoLibrary: .shared()
        )
    }

    private var homeScroll: AnyView {
        AnyView(
            ScrollView {
                VStack(spacing: 18) {
                    projectHub

                    if subscriptionStore.tier == .free {
                        upgradeFooter
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        )
    }

    private var importPreparationOverlay: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppPalette.accent)
                Text("Preparing clip")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Text("Making the source available for trimming.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing clip for trimming")
    }

    private var upgradeFooter: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.background)
                    .frame(width: 36, height: 36)
                    .background(AppPalette.accent, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock AI cuts + 4K export")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Creator from $2.99/wk. Annual and lifetime options available.")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.mutedText)
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var projectHub: AnyView {
        AnyView(
            VStack(spacing: 18) {
                projectHero
                continueLatestCard
                projectLibrary
            }
        )
    }

    private var projectHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                AppBrandLockup(
                    iconSize: 46,
                    titleFont: .system(.title2, design: .rounded).weight(.black)
                )

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Projects")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("Continue a saved cut plan or start fresh from Photos, Files, or a connected drive.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    guard !viewModel.isImportingMedia, !isPreparingImport else { return }
                    isFileImporterPresented = true
                } label: {
                    Label("Files", systemImage: "externaldrive")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isImportingMedia || isPreparingImport)
                .foregroundStyle(AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .accessibilityLabel("Create a new project from Files or connected drive")

                PhotosPicker(
                    selection: $homePickerItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    Label("Media", systemImage: "photo.on.rectangle")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.background)
                .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(viewModel.isImportingMedia || isPreparingImport)
                .onChange(of: homePickerItem) { _, newItem in
                    guard newItem != nil else { return }
                    guard !viewModel.isImportingMedia, !isPreparingImport else {
                        homePickerItem = nil
                        return
                    }
                    preparePhotoForNewProject(from: newItem!)
                    homePickerItem = nil
                }
            }

            // .reelclip project import/export row — survives reinstalls
            // because the file lives in the user's Files / iCloud Drive.
            HStack(spacing: 10) {
                Button {
                    isReelClipImporterPresented = true
                } label: {
                    Label("Import .reelclip", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

                Button {
                    prepareExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.currentProjectID == nil ? AppPalette.mutedText : AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .disabled(viewModel.currentProjectID == nil)
            }
        }
        .premiumSurface()
    }

    private func preparePhotoForNewProject(from item: PhotosPickerItem) {
        guard !isPreparingImport else { return }
        isPreparingImport = true
        viewModel.statusMessage = "Preparing clip..."

        Task { @MainActor in
            do {
                guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                    throw NSError(
                        domain: "HomeViewImport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Choose a valid video file."]
                    )
                }
                let request = ImportTrimRequest(
                    url: video.url,
                    photoLibraryIdentifier: item.photoLibraryLocalIdentifier ?? video.photoLibraryLocalIdentifier,
                    sourceName: video.sourceName,
                    canDiscardSourceOnCancel: video.isWorkspaceCopyNew
                )
                pendingImport = request
                isPreparingImport = false
            } catch is CancellationError {
                isPreparingImport = false
                viewModel.statusMessage = "Import cancelled."
            } catch {
                isPreparingImport = false
                viewModel.errorMessage = error.localizedDescription
                viewModel.statusMessage = "Could not prepare video."
            }
        }
    }

    private func prepareFileForNewProject(from url: URL) {
        guard !isPreparingImport else { return }
        isPreparingImport = true
        viewModel.statusMessage = "Preparing clip..."
        let didAccess = url.startAccessingSecurityScopedResource()

        Task { @MainActor in
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let copied = try await viewModel.prepareImportCopy(from: url)
                pendingImport = ImportTrimRequest(
                    url: copied.url,
                    photoLibraryIdentifier: nil,
                    sourceName: url.lastPathComponent,
                    canDiscardSourceOnCancel: copied.wasCreated
                )
                isPreparingImport = false
            } catch is CancellationError {
                isPreparingImport = false
                viewModel.statusMessage = "Import cancelled."
            } catch {
                isPreparingImport = false
                viewModel.errorMessage = error.localizedDescription
                viewModel.statusMessage = "Could not prepare file."
            }
        }
    }

    private func commitNewProjectImport(_ request: ImportTrimRequest, trimRange: ClipRange?) {
        pendingImport = nil
        DispatchQueue.main.async {
            viewModel.startNewProject()
            viewModel.importPreparedVideo(
                from: request.url,
                photoLibraryIdentifier: request.photoLibraryIdentifier,
                sourceName: request.sourceName,
                canDiscardPreparedSource: request.canDiscardSourceOnCancel,
                trimRange: trimRange
            )
            selectedTab = .clip
        }
    }

    private func discardPendingImport(_ request: ImportTrimRequest) {
        if request.canDiscardSourceOnCancel {
            viewModel.discardPreparedImport(at: request.url)
        }
        pendingImport = nil
    }

    /// Build a temp file containing the current project's `.reelclip`
    /// snapshot, then surface the system export sheet so the user can
    /// pick a destination (Files, iCloud Drive, AirDrop, etc.).
    private func prepareExport() {
        do {
            let prepared = try viewModel.exportCurrentProjectToTemporaryFile()
            reelClipExportURL = prepared.url
            isReelClipExporterPresented = true
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var continueLatestCard: some View {
        Group {
            if let latest = viewModel.latestProject {
                Button {
                    viewModel.continueLatestProject()
                    selectedTab = .clip
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VideoThumbnailView(
                            id: latest.id,
                            url: latest.sourceURL,
                            fallbackSymbol: latest.cutMode.symbolName,
                            midpointSeconds: latest.durationSeconds / 2,
                            cornerRadius: 14,
                            iconFont: .title.weight(.black)
                        )
                        .frame(width: 86, height: 86)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text("Continue latest")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppPalette.accent)
                                    .textCase(.uppercase)
                                    .tracking(0.8)
                            }
                            Text(latest.title)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AppPalette.primaryText)
                                .lineLimit(1)
                            Text(latest.sourceFileName)
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryText)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                projectChip(latest.cutMode.shortTitle)
                                projectChip(latest.plannedRanges.isEmpty ? "No plan" : "\(latest.plannedRanges.count) clips")
                                projectChip(ClipRangeFormatter.formatTime(latest.durationSeconds))
                            }
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
            } else {
                // Tappable empty state. Tap → "Pick a source" dialog
                // with Photos / Files options. Same chooser flow
                // the toolbar's Files+Media buttons trigger, so the
                // user gets a consistent import experience
                // regardless of where they tap. Copy is action-
                // oriented (the previous "your latest cut plan
                // will land here..." is implicit once they tap).
                PolishKit.EmptyStateView(
                    systemImage: "play.rectangle.on.rectangle",
                    title: "Tap to start a project",
                    message: "Pick a video from your Photos library or from Files. Your latest cut plan will save here so you can come back to it.",
                    accent: AppPalette.secondaryText,
                    actionTitle: nil,
                    action: nil,
                    onTap: {
                        guard !viewModel.isImportingMedia else { return }
                        isSourceChooserPresented = true
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var projectLibrary: some View {
        projectLibraryContent
            .alert("Rename project", isPresented: renameAlertBinding) {
                renameAlertContents
            } message: {
                renameAlertMessage
            }
    }

    @ViewBuilder
    private var projectLibraryContent: some View {
        if viewModel.projects.isEmpty {
            // Tappable empty state. Tap → opens the system file
            // importer filtered to .reelclip. Different intent from
            // the "Tap to start a project" card above: that one
            // creates a NEW project from a video, this one
            // restores an EXISTING project from a portable file.
            // Copy is action-oriented — "import a .reelclip file
            // you've shared or backed up".
            PolishKit.EmptyStateView(
                systemImage: "square.stack.3d.up.slash",
                title: "Tap to import a .reelclip file",
                message: "Restored projects come back with every scene, planned clip, mode, and prompt intact. Use this for backups or files you've shared.",
                accent: AppPalette.accent,
                actionTitle: nil,
                action: nil,
                onTap: {
                    guard !viewModel.isImportingMedia else { return }
                    isReelClipImporterPresented = true
                }
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    "Recent projects",
                    detail: viewModel.projects.count == 1
                        ? "1 saved draft"
                        : "\(viewModel.projects.count) saved drafts"
                )

                VStack(spacing: 10) {
                    ForEach(viewModel.projects) { project in
                        projectRow(project)
                    }
                }
            }
            .premiumSurface()
        }
    }

    @ViewBuilder
    private var renameAlertContents: some View {
        TextField("Project name", text: $projectRenameDraft)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .onSubmit { commitProjectRename() }
        Button("Cancel", role: .cancel) {
            renamingProject = nil
        }
        Button("Save") {
            commitProjectRename()
        }
    }

    @ViewBuilder
    private var renameAlertMessage: some View {
        if let renamingProject {
            Text("Renames “\(renamingProject.title)”.")
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingProject != nil },
            set: { newValue in
                if !newValue { renamingProject = nil }
            }
        )
    }

    private func startProjectRename(_ project: MediaProject) {
        projectRenameDraft = project.title
        renamingProject = project
    }

    private func commitProjectRename() {
        guard let renamingProject else { return }
        let trimmed = projectRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.renameStoredProject(id: renamingProject.id, to: trimmed)
        self.renamingProject = nil
    }

    private func projectRow(_ project: MediaProject) -> some View {
        let sourceMissing = !FileManager.default.fileExists(atPath: project.sourceURL.path)

        return HStack(spacing: 10) {
            Button {
                PolishKit.Haptics.tap(.light).play()
                viewModel.openProject(project)
                selectedTab = .clip
            } label: {
                HStack(spacing: 12) {
                    if sourceMissing {
                        ZStack {
                            AppPalette.mediaWell
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AppPalette.mutedText)
                        }
                        .frame(width: 38, height: 38)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppPalette.hairline, lineWidth: 1)
                        }
                    } else {
                        VideoThumbnailView(
                            id: project.id,
                            url: project.sourceURL,
                            fallbackSymbol: project.cutMode.symbolName,
                            midpointSeconds: project.durationSeconds / 2,
                            cornerRadius: 10,
                            iconFont: .headline.weight(.bold)
                        )
                        .frame(width: 38, height: 38)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                            .lineLimit(1)

                        Text(project.sourceFileName)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if sourceMissing {
                                projectChip("Source missing")
                            } else {
                                projectChip(project.cutMode.shortTitle)
                                projectChip(project.plannedRanges.isEmpty ? "No plan" : "\(project.plannedRanges.count) clips")
                                projectChip(ClipRangeFormatter.formatTime(project.durationSeconds))
                            }
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .polishPressFeedback()

            Button {
                PolishKit.Haptics.warning.play()
                viewModel.deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.secondaryText)
            .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Delete project \(project.title)")
            .polishPressFeedback()
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .contextMenu {
            Button {
                startProjectRename(project)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                PolishKit.Haptics.warning.play()
                viewModel.deleteProject(project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func projectChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppPalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AppPalette.raisedSurface, in: Capsule())
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            Spacer()
            Text(detail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
        }
    }
}
