import Foundation

// `ClipRange` lives in `SmartCutAnalyzer.swift`. We extend it from here with
// convenience accessors that don't fit naturally next to the analyzer.

/// A user's intended recipe before it's clamped to what's actually possible.
/// `count` and `interval` are both optional — when not provided the planner
/// picks sensible defaults.
struct ClipQuery: Equatable {
    var count: Int?
    var durationSeconds: Double?
    var intervalSeconds: Double?

    /// Default the interval to the duration so missing-interval = contiguous cuts.
    var resolvedInterval: Double {
        intervalSeconds ?? durationSeconds ?? 0
    }

    /// True if the parser extracted at least a duration.
    var isValid: Bool {
        guard let d = durationSeconds, d.isFinite, d > 0 else { return false }
        return true
    }

    /// Per-field detection flags — drive the "green when recognised" UI chips.
    var detectedCount: Bool { count != nil }
    var detectedDuration: Bool { durationSeconds != nil }
    var detectedInterval: Bool { intervalSeconds != nil }

    /// Cap the user's count by what's physically achievable inside the source.
    /// A 30-second source can hold at most `ceil(sourceDuration / interval)`
    /// evenly-spaced clips of duration `duration`. If the user asked for 100
    /// clips on a 30s source with a 5s duration, this returns 6 — never a
    /// silent surprise inside `ranges(forSourceDuration:)`.
    ///
    /// Returns 0 when the configuration is invalid (zero / negative duration
    /// or non-finite inputs).
    func achievableCount(forSourceDuration sourceDuration: Double) -> Int {
        guard isValid, let duration = durationSeconds else { return 0 }
        let interval = max(duration, resolvedInterval)
        guard interval > 0, interval.isFinite,
              sourceDuration.isFinite, sourceDuration > 0 else { return 0 }

        let maximumsItCanEverFit = Int((sourceDuration / duration).rounded(.up))
        let spacingCapped = interval > 0 ? Int((sourceDuration / interval).rounded(.down)) : maximumsItCanEverFit
        let natural = max(0, min(maximumsItCanEverFit, spacingCapped))
        guard let requested = count else {
            // No user-supplied count — use the natural ceiling.
            return natural
        }
        let requestedClamped = max(0, requested)
        return min(requestedClamped, natural)
    }

    /// Snapshot describing how the user's recipe will actually behave when run.
    /// Drives the live feasibility badge in the UI: green when fitted, amber
    /// when truncated, red when zero clips would result.
    struct Feasibility: Equatable {
        enum Severity: Equatable {
            case fits        // achievable === requested
            case truncated   // achievable < requested
            case tooShort    // source can't fit even one clip
        }

        /// 0 when the recipe is invalid. Same as `achievableCount(_:)`.
        var achievableCount: Int
        /// The count the user typed, or nil when they didn't specify one.
        var requestedCount: Int?
        /// The first clip will be at most this long (relevant when source < duration).
        var actualClipSpan: Double
        /// Source remainder that will be left unused as raw seconds.
        var leftoverSeconds: Double

        var severity: Severity {
            if achievableCount == 0 { return .tooShort }
            if let requestedCount, achievableCount < requestedCount { return .truncated }
            return .fits
        }
    }

    /// Compute the feasibility snapshot for a given source duration. Cheap,
    /// safe to call from a SwiftUI view body on every keystroke.
    func feasibility(forSourceDuration sourceDuration: Double) -> Feasibility {
        let achievable = achievableCount(forSourceDuration: sourceDuration)
        guard achievable > 0 else {
            // Even one clip doesn't fit. Report the requested clip span as
            // how much of the source a single clip would consume.
            let spanned = isValid ? max(min(sourceDuration, durationSeconds ?? 0), 0) : 0
            return Feasibility(
                achievableCount: 0,
                requestedCount: count,
                actualClipSpan: spanned,
                leftoverSeconds: max(0, sourceDuration - spanned)
            )
        }

        // Walk the planned loop and report where the last clip lands + leftover.
        let ranges = ranges(forSourceDuration: sourceDuration)
        let actualSpan = ranges.last.map { $0.endSeconds - $0.startSeconds } ?? 0
        let lastEnd = ranges.last?.endSeconds ?? 0
        let leftover = max(0, sourceDuration - lastEnd)

        return Feasibility(
            achievableCount: achievable,
            requestedCount: count,
            actualClipSpan: actualSpan,
            leftoverSeconds: leftover
        )
    }

    /// Materialise the query into concrete cut ranges for a source of `sourceDuration` seconds.
    /// When `count` is set, the loop terminates at the first clamp — never
    /// producing more than the user asked for. When `count` is nil, the loop
    /// walks the whole source via the `safetyCeiling` guard.
    func ranges(forSourceDuration sourceDuration: Double, safetyCeiling: Int = 999) -> [ClipRange] {
        guard isValid, let duration = durationSeconds else { return [] }
        let interval = max(duration, resolvedInterval)
        guard interval > 0, interval.isFinite,
              sourceDuration.isFinite, sourceDuration > 0 else { return [] }

        let hardLimit = count.map { max(0, $0) } ?? safetyCeiling
        var ranges: [ClipRange] = []
        var position = 0.0
        var iterations = 0

        while iterations < hardLimit {
            let end = min(position + duration, sourceDuration)
            if end - position < 0.05 { break }
            ranges.append(ClipRange(startSeconds: position, endSeconds: end))
            position += interval
            iterations += 1
        }

        return ranges
    }

    /// Compact one-line summary for the UI ("4 clips × 5s every 10s").
    var summary: String {
        guard isValid else { return "Couldn't parse" }
        var parts: [String] = []
        if let c = count { parts.append("\(c) clip\(c == 1 ? "" : "s")") }
        if let d = durationSeconds { parts.append("\(formatSeconds(d))") }
        if let interval = intervalSeconds, abs(interval - (durationSeconds ?? interval)) > 0.01 {
            parts.append("every \(formatSeconds(interval))")
        }
        return parts.joined(separator: " × ")
    }

    private func formatSeconds(_ s: Double) -> String {
        if s == floor(s) {
            return "\(Int(s))s"
        }
        return String(format: "%.1fs", s)
    }
}

enum FixedModeInputStyle: String, CaseIterable, Identifiable, Codable {
    case text
    case buttons

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text"
        case .buttons: return "Buttons"
        }
    }
}

/// Generates the canonical phrase for a (count, duration, interval)
/// tuple — used when the user switches from Buttons to Text so the
/// TextField shows a parseable sentence they can edit, AND used by
/// the Apple Intelligence repairer's instructions to teach the model
/// the expected output shape.
enum FixedModeQueryFormatter {
    /// Produce a phrase like "4 five-second clips cut every 10 seconds".
    /// Mirrors what `ClipQueryParser` accepts so swapping inputs never
    /// silently breaks parsing.
    static func phrase(count: Int, duration: Int, interval: Int) -> String {
        let safeCount = max(1, count)
        let safeDuration = max(1, duration)
        let safeInterval = max(1, interval)
        let clipWord = safeCount == 1 ? "clip" : "clips"
        let durationWord = numberWord(safeDuration)
        // If duration == interval, drop the redundant "every N seconds" tail —
        // the parser treats them as the same anyway and it reads cleaner.
        if safeDuration == safeInterval {
            return "\(safeCount) \(durationWord)-second \(clipWord)"
        }
        let intervalWord = numberWord(safeInterval)
        return "\(safeCount) \(durationWord)-second \(clipWord) cut every \(intervalWord) seconds"
    }

    /// Word form for 1..99. Beyond that we fall back to digits — keeps
    /// the phrase compact and avoids "one hundred and twenty-three"
    /// nonsense.
    static func numberWord(_ n: Int) -> String {
        let ones = ["", "one", "two", "three", "four", "five", "six",
                    "seven", "eight", "nine", "ten", "eleven", "twelve",
                    "thirteen", "fourteen", "fifteen", "sixteen",
                    "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty",
                    "sixty", "seventy", "eighty", "ninety"]
        if n < 0 { return "\(n)" }
        if n < ones.count { return ones[n] }
        if n < 100 {
            let t = tens[n / 10]
            let o = ones[n % 10]
            return o.isEmpty ? t : "\(t)-\(o)"
        }
        return "\(n)"
    }
}

enum ClipQueryParser {
    /// Parse free-form English like "4 five-second clips cut every 10 seconds".
    /// Strategy: pull "every/per/apart K unit" first (interval), then remaining K unit (duration),
    /// then N clip/cut (count). Word numbers ("four", "ten", "twenty") supported.
    static func parse(_ text: String) -> ClipQuery? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lower = raw.lowercased()

        let intervalMatches = extractIntervals(in: lower)
        let durationMatches = extractDurations(in: lower, excluding: intervalMatches.map(\.range))
        let count = extractCount(in: lower, excluding: (intervalMatches + durationMatches).map(\.range))

        guard !durationMatches.isEmpty else { return nil }

        return ClipQuery(
            count: count,
            durationSeconds: durationMatches.first?.seconds,
            intervalSeconds: intervalMatches.first?.seconds
        )
    }

    // MARK: - Internal

    private struct NumberUnitMatch {
        let seconds: Double
        let range: Range<String.Index>
    }

    private static let numberTokenPattern = #"\d+(?:\.\d+)?|[a-z]+(?:-[a-z]+)?"#
    private static let unitPattern = #"seconds?|secs?|s|minutes?|mins?|m|min"#

    /// Finds "<number or word-number> <unit>" tokens, returns them as seconds.
    private static func numberUnitMatches(in text: String) -> [NumberUnitMatch] {
        var results: [NumberUnitMatch] = []
        // Accept digit ("5"), word ("five"), and hyphenated duration-adjective
        // forms ("five-second", "twenty-five-second").
        let pattern = "(\(numberTokenPattern))\\s*-?\\s*(\(unitPattern))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }

        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match,
                  let nRange = Range(match.range(at: 1), in: text),
                  let uRange = Range(match.range(at: 2), in: text) else { return }
            let numberToken = String(text[nRange])
            let unit = String(text[uRange])
            guard let number = parseNumber(numberToken) else { return }
            let seconds = toSeconds(number, unit: unit)
            if let fullRange = Range(match.range, in: text) {
                results.append(NumberUnitMatch(seconds: seconds, range: fullRange))
            }
        }
        return results
    }

    /// Interval cue words: "every", "per", "apart", "spaced". "very" alone is also
    /// accepted as a forgiving fallback for the common "every" typo.
    private static let intervalCueWords = ["every", "per", "apart", "spaced", "very"]

    private static func extractIntervals(in text: String) -> [NumberUnitMatch] {
        // Build a single regex matching any of the cue words.
        let cues = intervalCueWords.joined(separator: "|")
        let beforePattern = "(?:\(cues))\\s+(\(numberTokenPattern))\\s*-?\\s*(\(unitPattern))\\b"
        let afterPattern = "(\(numberTokenPattern))\\s*-?\\s*(\(unitPattern))\\s+(?:apart|gap|gaps|spacing|space|spaces)\\b"
        guard let beforeRegex = try? NSRegularExpression(pattern: beforePattern),
              let afterRegex = try? NSRegularExpression(pattern: afterPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        if let match = beforeRegex.firstMatch(in: text, range: range),
           let nRange = Range(match.range(at: 1), in: text),
           let uRange = Range(match.range(at: 2), in: text),
           let fullRange = Range(match.range, in: text),
           let number = parseNumber(String(text[nRange])) {
            return [NumberUnitMatch(seconds: toSeconds(number, unit: String(text[uRange])), range: fullRange)]
        }
        if let match = afterRegex.firstMatch(in: text, range: range),
           let nRange = Range(match.range(at: 1), in: text),
           let uRange = Range(match.range(at: 2), in: text),
           let fullRange = Range(match.range, in: text),
           let number = parseNumber(String(text[nRange])) {
            return [NumberUnitMatch(seconds: toSeconds(number, unit: String(text[uRange])), range: fullRange)]
        }
        return []
    }

    private static func extractDurations(in text: String, excluding excludedRanges: [Range<String.Index>]) -> [NumberUnitMatch] {
        let all = numberUnitMatches(in: text)
        var seen: Set<Double> = []
        var results: [NumberUnitMatch] = []
        for match in all
        where !excludedRanges.contains(where: { rangesOverlap(match.range, $0) })
            && !seen.contains(match.seconds) {
            seen.insert(match.seconds)
            results.append(match)
        }
        return results
    }

    private static func extractCount(in text: String, excluding excludedRanges: [Range<String.Index>]) -> Int? {
        // Match "N clip(s)", "N five-second clip(s)", or "make N".
        // Skip candidate number tokens that are part of a duration match so
        // "five-second clips" is not misread as "5 clips".
        let clipPattern = "(\(numberTokenPattern))\\s+(?:(?:\(numberTokenPattern))\\s*-?\\s*(?:\(unitPattern))\\s+)?(?:clips?|cuts?)\\b"
        let commandPattern = "(?:make|create|cut|export|save)\\s+(\(numberTokenPattern))\\b"
        return firstParsedCount(in: text, pattern: clipPattern, excluding: excludedRanges)
            ?? firstParsedCount(in: text, pattern: commandPattern, excluding: excludedRanges)
    }

    private static func firstParsedCount(
        in text: String,
        pattern: String,
        excluding excludedRanges: [Range<String.Index>]
    ) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var result: Int?
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard result == nil,
                  let match,
                  let nRange = Range(match.range(at: 1), in: text),
                  !excludedRanges.contains(where: { rangesOverlap(nRange, $0) }),
                  let parsed = parseNumber(String(text[nRange])) else { return }
            result = Int(parsed)
            stop.pointee = true
        }
        return result
    }

    private static func parseNumber(_ token: String) -> Double? {
        if let n = Double(token) { return n }
        if let n = wordToInt[token] { return Double(n) }
        // Hyphenated compounds like "twenty-five" → sum the parts.
        let parts = token.split(separator: "-").map(String.init)
        if parts.count > 1 {
            var total = 0
            for part in parts {
                guard let value = wordToInt[part] else { return nil }
                total += value
            }
            return Double(total)
        }
        return nil
    }

    private static func rangesOverlap(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func toSeconds(_ number: Double, unit: String) -> Double {
        let lower = unit.lowercased()
        // "m" alone = minutes (common convention). "min" = minutes.
        // "s"/"sec"/"second" = seconds. Everything else defaults to seconds.
        if lower == "m" || lower.hasPrefix("min") { return number * 60 }
        return number
    }

    private static let wordToInt: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60
    ]
}
