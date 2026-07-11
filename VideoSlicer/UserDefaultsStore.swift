import Foundation

struct UserDefaultsStore {
    static let fallbackCutMode: CutMode = .highlight
    static let fallbackSegmentLengthSeconds = 30
    static let fallbackHighlightDurationSeconds = 30
    static let fallbackEditPrompt = "Make a fast reel"
    static let fallbackFixedModeInputStyle: FixedModeInputStyle = .buttons
    static let fallbackFixedModeButtonCount = 4
    static let fallbackFixedModeButtonDuration = 5
    static let fallbackFixedModeButtonInterval = 10

    private let defaults: UserDefaults

    private enum Key {
        static let defaultCutMode = "settings.defaultCutMode"
        // Legacy shared key used by v1.0.0–v1.x. Kept for
        // read-only migration seeding of the per-mode keys
        // below. Do not write to it from new code.
        static let legacyDefaultSegmentLengthSeconds = "settings.defaultSegmentLengthSeconds"
        static let defaultSilenceClipDurationSeconds = "settings.defaultSilenceClipDurationSeconds"
        static let defaultAiClipDurationSeconds = "settings.defaultAiClipDurationSeconds"
        static let defaultHighlightDurationSeconds = "settings.defaultHighlightDurationSeconds"
        static let defaultEditPrompt = "settings.defaultEditPrompt"
        static let defaultFixedModeInputStyle = "settings.defaultFixedModeInputStyle"
        static let defaultFixedModeQueryDraft = "settings.defaultFixedModeQueryDraft"
        static let defaultFixedModeButtonCount = "settings.defaultFixedModeButtonCount"
        static let defaultFixedModeButtonDuration = "settings.defaultFixedModeButtonDuration"
        static let defaultFixedModeButtonInterval = "settings.defaultFixedModeButtonInterval"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultCutMode: CutMode {
        get {
            guard let raw = defaults.string(forKey: Key.defaultCutMode),
                  let mode = CutMode(rawValue: raw) else {
                return Self.fallbackCutMode
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.defaultCutMode)
        }
    }

    /// Per-mode default for the Silence ("Smart Pause") clip
    /// length. Sealed from AI's `defaultAiClipDurationSeconds` —
    /// changing one no longer affects the other. Pre-existing
    /// installs that only have the legacy shared
    /// `defaultSegmentLengthSeconds` value see it used as the
    /// seed for both modes (last write wins), which matches what
    /// they had before this split shipped.
    var defaultSilenceClipDurationSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultSilenceClipDurationSeconds)
            if stored > 0 { return Self.clamped(stored, range: 5...120) }
            let legacy = defaults.integer(forKey: Key.legacyDefaultSegmentLengthSeconds)
            if legacy > 0 { return Self.clamped(legacy, range: 5...120) }
            return Self.fallbackSegmentLengthSeconds
        }
        set {
            defaults.set(Self.clamped(newValue, range: 5...120), forKey: Key.defaultSilenceClipDurationSeconds)
        }
    }

    /// Per-mode default for the AI ("Apple Intelligence") clip
    /// length. Sealed from Silence's
    /// `defaultSilenceClipDurationSeconds` — changing one no
    /// longer affects the other. Same legacy-seed behaviour.
    var defaultAiClipDurationSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultAiClipDurationSeconds)
            if stored > 0 { return Self.clamped(stored, range: 5...120) }
            let legacy = defaults.integer(forKey: Key.legacyDefaultSegmentLengthSeconds)
            if legacy > 0 { return Self.clamped(legacy, range: 5...120) }
            return Self.fallbackSegmentLengthSeconds
        }
        set {
            defaults.set(Self.clamped(newValue, range: 5...120), forKey: Key.defaultAiClipDurationSeconds)
        }
    }

    var defaultHighlightDurationSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultHighlightDurationSeconds)
            guard stored > 0 else {
                // Splice's clip length is per-mode already, so
                // there's no per-mode fallback. Reuse Silence's
                // stored value (or its legacy seed) — better a
                // matching pre-bug number than a fresh 30s
                // surprise.
                return defaultSilenceClipDurationSeconds
            }
            return Self.clamped(stored, range: 1...120)
        }
        set {
            defaults.set(Self.clamped(newValue, range: 1...120), forKey: Key.defaultHighlightDurationSeconds)
        }
    }

    var defaultEditPrompt: String {
        get {
            let stored = defaults.string(forKey: Key.defaultEditPrompt)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? Self.fallbackEditPrompt : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Self.fallbackEditPrompt : trimmed, forKey: Key.defaultEditPrompt)
        }
    }

    var defaultFixedModeInputStyle: FixedModeInputStyle {
        get {
            guard let raw = defaults.string(forKey: Key.defaultFixedModeInputStyle),
                  let style = FixedModeInputStyle(rawValue: raw) else {
                return Self.fallbackFixedModeInputStyle
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.defaultFixedModeInputStyle)
        }
    }

    var defaultFixedModeQueryDraft: String {
        get {
            let stored = defaults.string(forKey: Key.defaultFixedModeQueryDraft)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty {
                return stored
            }
            return FixedModeQueryFormatter.phrase(
                count: defaultFixedModeButtonCount,
                duration: defaultFixedModeButtonDuration,
                interval: defaultFixedModeButtonInterval
            )
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.defaultFixedModeQueryDraft)
            } else {
                defaults.set(trimmed, forKey: Key.defaultFixedModeQueryDraft)
            }
        }
    }

    var defaultFixedModeButtonCount: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultFixedModeButtonCount)
            guard stored > 0 else { return Self.fallbackFixedModeButtonCount }
            return Self.clamped(stored, range: 1...50)
        }
        set {
            defaults.set(Self.clamped(newValue, range: 1...50), forKey: Key.defaultFixedModeButtonCount)
        }
    }

    var defaultFixedModeButtonDuration: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultFixedModeButtonDuration)
            guard stored > 0 else { return Self.fallbackFixedModeButtonDuration }
            return Self.clamped(stored, range: 1...120)
        }
        set {
            defaults.set(Self.clamped(newValue, range: 1...120), forKey: Key.defaultFixedModeButtonDuration)
        }
    }

    var defaultFixedModeButtonInterval: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultFixedModeButtonInterval)
            guard stored > 0 else { return Self.fallbackFixedModeButtonInterval }
            return Self.clamped(stored, range: 1...120)
        }
        set {
            defaults.set(Self.clamped(newValue, range: 1...120), forKey: Key.defaultFixedModeButtonInterval)
        }
    }

    func resetAll() {
        defaults.removeObject(forKey: Key.defaultCutMode)
        defaults.removeObject(forKey: Key.legacyDefaultSegmentLengthSeconds)
        defaults.removeObject(forKey: Key.defaultSilenceClipDurationSeconds)
        defaults.removeObject(forKey: Key.defaultAiClipDurationSeconds)
        defaults.removeObject(forKey: Key.defaultHighlightDurationSeconds)
        defaults.removeObject(forKey: Key.defaultEditPrompt)
        defaults.removeObject(forKey: Key.defaultFixedModeInputStyle)
        defaults.removeObject(forKey: Key.defaultFixedModeQueryDraft)
        defaults.removeObject(forKey: Key.defaultFixedModeButtonCount)
        defaults.removeObject(forKey: Key.defaultFixedModeButtonDuration)
        defaults.removeObject(forKey: Key.defaultFixedModeButtonInterval)
    }

    private static func clamped(_ value: Int, range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
