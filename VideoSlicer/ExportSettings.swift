import Foundation
import AVFoundation
import CoreMedia

/// User-configurable export settings for a project. Saved on
/// `MediaProject.exportSettings` so a `.reelclip` round-trip
/// preserves the user's chosen quality. Tier-gated: Free projects
/// are pinned to `hd720` + `source`; Creator+ projects can pick
/// any combination.
///
/// `source` for resolution means "match the input's pixel
/// dimensions" (no re-encode scale). `source` for frame rate means
/// "match the input's frame rate" (no time-base change). Both
/// settings always round-trip through the codec — even Free
/// projects store them, they're just constrained to the cheap
/// option so a Creative+ upgrade re-exports at native quality
/// without the user having to re-pick the settings.
struct ExportSettings: Codable, Equatable, Hashable {
    var resolution: Resolution
    var frameRate: FrameRate

    enum Resolution: String, Codable, CaseIterable, Hashable {
        /// Match the source's native pixel dimensions. Highest
        /// quality — what the user expects for an "export" — but
        /// requires Creator+.
        case source
        /// 1920x1080. The standard paid-tier choice.
        case hd1080
        /// 1280x720. Cheap to render; the only resolution Free
        /// tier can pick.
        case hd720

        var displayName: String {
            switch self {
            case .source:  return "Source"
            case .hd1080:  return "1080p"
            case .hd720:   return "720p"
            }
        }

        /// AVAssetExportPreset* constant. The segmenter uses
        /// this to pick the encoder. `source` falls through to
        /// the highest-quality preset, which already renders at
        /// the source's native dimensions.
        var presetName: String {
            switch self {
            case .source:  return AVAssetExportPresetHighestQuality
            case .hd1080:  return AVAssetExportPreset1920x1080
            case .hd720:   return AVAssetExportPreset1280x720
            }
        }

        /// True when this option requires Creator+ to pick.
        /// Free projects are silently coerced to `.hd720`.
        var isPremium: Bool {
            self != .hd720
        }
    }

    enum FrameRate: String, Codable, CaseIterable, Hashable {
        /// Match the source's frame rate. No time-base change
        /// in the composition. The default for any project
        /// that hasn't been explicitly overridden.
        case source
        /// 30 fps — the safe mid-tier choice. AVFoundation
        /// re-times frames on render.
        case fps30
        /// 60 fps — for action footage / slow-mo source.
        /// Creator+ only.
        case fps60

        var displayName: String {
            switch self {
            case .source:  return "Source"
            case .fps30:   return "30 fps"
            case .fps60:   return "60 fps"
            }
        }

        /// Frame duration for `AVMutableVideoComposition.frameDuration`.
        /// `source` returns nil — caller falls back to the
        /// source's native time-base (no resample).
        var frameDuration: CMTime? {
            switch self {
            case .source:  return nil
            case .fps30:   return CMTime(value: 1, timescale: 30)
            case .fps60:   return CMTime(value: 1, timescale: 60)
            }
        }

        var isPremium: Bool {
            self != .source
        }
    }

    /// Settings the user gets on a brand-new project. Free
    /// tier is pinned to the cheap defaults so a freshly-created
    /// project doesn't have to make a choice. The settings are
    /// still written to the project so a later upgrade doesn't
    /// need to re-pick anything.
    static func defaults(for tier: SubscriptionStore.Tier) -> ExportSettings {
        switch tier {
        case .free:
            return ExportSettings(resolution: .hd720, frameRate: .source)
        case .creator:
            return ExportSettings(resolution: .source, frameRate: .source)
        }
    }
}

extension ExportSettings {
    /// Effective settings for a render. Takes the user's saved
    /// settings and silently coerces premium options down to the
    /// tier-appropriate fallback when the user's current tier
    /// can't honour the saved choice. The source-of-truth project
    /// record is NOT mutated — the user keeps their choice in
    /// `.reelclip` so a later upgrade resumes native quality.
    func resolved(for tier: SubscriptionStore.Tier) -> ExportSettings {
        switch tier {
        case .free:
            // Coerce any premium option to the cheap fallback.
            return ExportSettings(
                resolution: resolution.isPremium ? .hd720 : resolution,
                frameRate: frameRate.isPremium ? .source : frameRate
            )
        case .creator:
            return self
        }
    }
}
