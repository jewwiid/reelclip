import Foundation

protocol EditIntentPlanning {
    func intent(from prompt: String) -> CreatorEditIntent
}

struct CreatorEditIntent: Equatable {
    var targetDuration: Double?
    var clipDuration: Double
    var minClipDuration: Double
    var maxClips: Int
    var prioritizeFaces: Bool
    var pacing: Pacing

    enum Pacing: Equatable {
        case fast
        case balanced
        case calm
    }

    static let `default` = CreatorEditIntent(
        targetDuration: nil,
        clipDuration: 2.0,
        minClipDuration: 1.0,
        maxClips: 12,
        prioritizeFaces: true,
        pacing: .balanced
    )
}

struct EditIntentPlanner: EditIntentPlanning {
    func intent(from prompt: String) -> CreatorEditIntent {
        var intent = CreatorEditIntent.default
        let normalized = prompt.lowercased()

        if normalized.contains("fast") || normalized.contains("energetic") || normalized.contains("tiktok") || normalized.contains("reel") {
            intent.pacing = .fast
            intent.clipDuration = 1.4
            intent.minClipDuration = 0.8
            intent.maxClips = 18
        }

        if normalized.contains("calm") || normalized.contains("cinematic") || normalized.contains("slow") {
            intent.pacing = .calm
            intent.clipDuration = 3.5
            intent.minClipDuration = 1.5
            intent.maxClips = 8
        }

        if normalized.contains("face") || normalized.contains("person") || normalized.contains("talking") {
            intent.prioritizeFaces = true
        }

        if normalized.contains("scenery") || normalized.contains("landscape") || normalized.contains("product") {
            intent.prioritizeFaces = false
        }

        if let targetDuration = Self.firstDuration(in: normalized),
           targetDuration.isFinite,
           targetDuration > 0 {
            intent.targetDuration = targetDuration
            intent.maxClips = max(Int(ceil(targetDuration / intent.clipDuration)), 1)
        }

        return intent
    }

    private static func firstDuration(in text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(s|sec|secs|second|seconds|min|mins|minute|minutes)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3 else {
            return nil
        }

        guard
            let valueRange = Range(match.range(at: 1), in: text),
            let unitRange = Range(match.range(at: 2), in: text),
            let value = Double(text[valueRange])
        else {
            return nil
        }

        let unit = String(text[unitRange])
        return unit.hasPrefix("min") ? value * 60 : value
    }
}
