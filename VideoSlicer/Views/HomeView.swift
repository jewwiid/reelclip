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
    @State private var renamingProject: MediaProject?
    @State private var projectRenameDraft: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                homeScroll
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
                    viewModel.importVideoFile(from: url)
                    selectedTab = .clip
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
    }

    @ViewBuilder
    private var homeScroll: some View {
        if subscriptionStore.tier == .free {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectHub
                    upgradeFooter
                }
                .padding(18)
            }
        } else {
            projectHub
        }
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
                    Text("Creator from $9.99/mo · Studio from $19.99/mo. Annual saves 40%.")
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

    private var projectHub: some View {
        ScrollView {
            VStack(spacing: 18) {
                projectHero
                continueLatestCard
                projectLibrary
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var projectHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Creator workspace")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.1)
                    }
                    .foregroundStyle(AppPalette.accent)

                    Text("Projects")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("Continue a saved cut plan or start fresh from Photos, Files, or a connected drive.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.startNewProject()
                    isFileImporterPresented = true
                } label: {
                    Label("Files", systemImage: "externaldrive")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .accessibilityLabel("Create a new project from Files or connected drive")

                PhotosPicker(
                    selection: $viewModel.selectedItem,
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
                .onChange(of: viewModel.selectedItem) { _, newItem in
                    guard newItem != nil else { return }
                    viewModel.startNewProjectFromCurrentSelection()
                    viewModel.importSelectedVideo()
                    selectedTab = .clip
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
                    HStack(alignment: .center, spacing: 14) {
                        VideoThumbnailView(
                            id: latest.id,
                            url: latest.sourceURL,
                            fallbackSymbol: latest.cutMode.symbolName,
                            midpointSeconds: latest.durationSeconds / 2,
                            cornerRadius: 14,
                            iconFont: .title.weight(.black)
                        )
                        .frame(width: 86, height: 86)

                        VStack(alignment: .leading, spacing: 6) {
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
                    .padding(14)
                }
                .buttonStyle(.plain)
                .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
            } else {
                PolishKit.EmptyStateView(
                    systemImage: "play.rectangle.on.rectangle",
                    title: "No project to continue yet",
                    message: "Pick a video from your Photos or Files — your latest cut plan will land here so you can keep going on the same draft.",
                    accent: AppPalette.secondaryText,
                    actionTitle: nil,
                    action: nil
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
            PolishKit.EmptyStateView(
                systemImage: "square.stack.3d.up.slash",
                title: "No saved projects yet",
                message: "Each source video becomes one project. Cut plan, mode, prompt, and trim handles all save to this list.",
                accent: AppPalette.accent
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
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
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