import SwiftUI
import UIKit

/// Short-form video editor apps that can be handed a clip from ReelClips.
///
/// The flow is: ReelClips saves the clip to Photos, then opens the target
/// app via its URL scheme. The target app's "import from Photos" /
/// "create new project" picks up the latest video. Universal handoff —
/// works on every device with the target app installed, no partner
/// integration required.
enum EditorTarget: String, CaseIterable, Identifiable {
    case capcut
    case tiktok
    case instagram
    case youtubeShorts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .capcut: return "CapCut"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram Reels"
        case .youtubeShorts: return "YouTube Shorts"
        }
    }

    /// Short, action-oriented subtitle. Keeps the picker dense — one
    /// line of context per target, no marketing copy.
    var subtitle: String {
        switch self {
        case .capcut: return "Add templates, captions, and trending sounds"
        case .tiktok: return "Post to your TikTok with the latest video"
        case .instagram: return "Open Reels with the latest video ready"
        case .youtubeShorts: return "Open Shorts with the latest video ready"
        }
    }

    /// SF Symbol used in the picker row. Intentionally generic so the
    /// picker doesn't pretend to know the official app icon.
    var systemImage: String {
        switch self {
        case .capcut: return "scissors.bob.pointer"
        case .tiktok: return "music.note.tv"
        case .instagram: return "camera.aperture"
        case .youtubeShorts: return "play.rectangle.on.rectangle"
        }
    }

    /// URL scheme registered by the target app. Opening it lands the
    /// user on the app's "create new" entry point — they then import
    /// from Photos (where ReelClips just wrote the clip).
    ///
    /// `nil` means the target's scheme isn't reliably registered; the
    /// picker hides those entries.
    var urlScheme: String? {
        switch self {
        case .capcut: return "capcut://"
        case .tiktok: return "tiktok://"
        case .instagram: return "instagram-stories://share"
        case .youtubeShorts: return "youtube://"
        }
    }

    /// Returns true if we can attempt to open this target. The OS will
    /// silently fail on the open if the app isn't installed — the
    /// caller handles the fallback UI.
    var canAttemptOpen: Bool {
        guard let scheme = urlScheme, let url = URL(string: scheme) else {
            return false
        }
        var canOpen = false
        if UIApplication.shared.responds(to: #selector(UIApplication.canOpenURL(_:))) {
            canOpen = UIApplication.shared.canOpenURL(url)
        }
        return canOpen
    }

    /// Open the target app. The Photos-save step happens before this
    /// (handled by the caller) so the target app picks up the latest
    /// clip on its "import from Photos" flow.
    @MainActor
    func open() {
        guard let scheme = urlScheme, let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// SwiftUI wrapper that renders the 4-target picker as a small
/// action sheet. Each row calls `target.open()` after the caller has
/// persisted the clip to Photos.
struct EditorTargetSheet: View {
    let onSelect: (EditorTarget) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Send to…")
                        .font(.title3.weight(.black))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("ReelClips will save the clips to Photos, then open the editor.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 8) {
                ForEach(EditorTarget.allCases) { target in
                    targetRow(target)
                }
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(AppPalette.primaryText)
                    .background(
                        AppPalette.controlSurface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: 560)
        .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private func targetRow(_ target: EditorTarget) -> some View {
        let enabled = target.canAttemptOpen
        return Button {
            guard enabled else { return }
            onSelect(target)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: target.systemImage)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(enabled ? AppPalette.accent : AppPalette.mutedText)
                    .frame(width: 40, height: 40)
                    .background(
                        (enabled ? AppPalette.accent : AppPalette.mutedText).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(enabled ? AppPalette.primaryText : AppPalette.mutedText)
                    Text(target.subtitle)
                        .font(.caption)
                        .foregroundStyle(enabled ? AppPalette.secondaryText : AppPalette.mutedText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !enabled {
                    Text("Not installed")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                AppPalette.controlSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
