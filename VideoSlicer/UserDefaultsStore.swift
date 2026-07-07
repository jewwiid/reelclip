import Foundation

struct UserDefaultsStore {
    private let defaults: UserDefaults
    private enum Key {
        static let defaultCutMode = "settings.defaultCutMode"
        static let defaultSegmentLengthSeconds = "settings.defaultSegmentLengthSeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultCutMode: CutMode {
        get {
            guard let raw = defaults.string(forKey: Key.defaultCutMode),
                  let mode = CutMode(rawValue: raw) else {
                return .fixed
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.defaultCutMode)
        }
    }

    var defaultSegmentLengthSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.defaultSegmentLengthSeconds)
            guard stored >= 5, stored <= 120 else { return 30 }
            return stored
        }
        set {
            let clamped = min(max(newValue, 5), 120)
            defaults.set(clamped, forKey: Key.defaultSegmentLengthSeconds)
        }
    }

    func resetAll() {
        defaults.removeObject(forKey: Key.defaultCutMode)
        defaults.removeObject(forKey: Key.defaultSegmentLengthSeconds)
    }
}