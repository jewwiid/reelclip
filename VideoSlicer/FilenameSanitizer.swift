import Foundation

/// Filename + filesystem helpers used by the segmenter when naming clip exports
/// and the share helper when staging files for AirDrop / Files / iMessage.
enum FilenameSanitizer {
    /// Characters Photos + APFS treat as illegal or unsafe in a single filename
    /// component. We replace each with a space and collapse later, instead of
    /// silently deleting characters — losing information about what the user
    /// typed makes the filename feel arbitrary.
    private static let illegalCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        set.formUnion(.controlCharacters)
        return set
    }()

    /// Sanitize an arbitrary user-typed string into something safe to use as
    /// a filename. Returns `fallback` if the result would otherwise be empty.
    static func sanitize(_ raw: String, fallback: String = "clip") -> String {
        let replaced = raw.unicodeScalars.map { scalar -> Character in
            illegalCharacters.contains(scalar) ? " " : Character(scalar)
        }

        // Collapse runs of 3+ spaces down to a single space. The previous
        // single-pass `replacingOccurrences(of: "  ")` left double spaces
        // from runs of 3+.
        let collapsed = String(replaced)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if collapsed.isEmpty { return fallback }

        // APFS caps filenames at 255 BYTES, not characters. 100 emoji
        // (≈4 bytes each) = 400 bytes → ENAMETOOLONG. Trim by UTF-8 byte
        // count, then cut back to a grapheme boundary so we don't split
        // a multi-byte character.
        let maxBytes = 200 // leave room for extension + " (N)" suffix
        let precomposed = collapsed.precomposedStringWithCanonicalMapping
        guard let utf8 = precomposed.data(using: .utf8) else { return fallback }
        if utf8.count <= maxBytes { return precomposed }

        // Walk the string, accumulating UTF-8 bytes until we hit the limit.
        var byteCount = 0
        var cutIndex = precomposed.startIndex
        for index in precomposed.indices {
            let char = precomposed[index]
            let charBytes = String(char).utf8.count
            if byteCount + charBytes > maxBytes { break }
            byteCount += charBytes
            cutIndex = precomposed.index(after: index)
        }
        let trimmed = String(precomposed[..<cutIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Filesystem-safe version of `sanitize` with an extension appended.
    static func sanitizedFileName(
        from title: String,
        fallbackBase: String = "clip",
        fileExtension: String
    ) -> String {
        let base = sanitize(title, fallback: fallbackBase)
        let trimmedExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmedExt.isEmpty ? base : "\(base).\(trimmedExt)"
    }

    /// Returns a URL inside `directory` that does not collide with any
    /// existing file. If `desired` already exists, appends ` (2)`, ` (3)` …
    /// before the extension. Used so re-renders of the same project don't
    /// overwrite the previous export.
    static func uniqueURL(for desired: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(desired)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let nsDesired = desired as NSString
        let ext = nsDesired.pathExtension
        let base = nsDesired.deletingPathExtension

        var counter = 2
        while true {
            let nextName = ext.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(ext)"
            let url = directory.appendingPathComponent(nextName)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            counter += 1
        }
    }
}

/// Turns machine-generated camera, Photos, and workspace filenames into a
/// compact label appropriate for project and scene UI. This is deliberately a
/// deterministic formatter rather than an AI guess: descriptive filenames
/// stay intact, while timestamps, UUIDs, and provider identifiers collapse to
/// a stable human-readable footage name.
enum FootageTitleFormatter {
    static func projectTitle(from sourceName: String) -> String {
        let rawStem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let sourceStem = stripWorkspacePrefix(from: rawStem)
        let normalized = normalizedWords(from: sourceStem)
        guard !normalized.isEmpty else { return "Untitled project" }

        let lower = normalized.lowercased()
        let date = dateLabel(in: sourceStem)

        if lower.contains("screenrecording") || lower.contains("screen recording") {
            return date.map { "Screen Recording - \($0)" } ?? "Screen Recording"
        }

        if lower.hasPrefix("dji") {
            let provider = lower.contains("mimo") || lower.contains("mi mo") ? "DJI Mimo" : "DJI"
            return date.map { "\(provider) Footage - \($0)" } ?? "\(provider) Footage"
        }

        let words = normalized.split(separator: " ").map(String.init)
        let firstWord = words.first?.lowercased() ?? ""
        if ["img", "image", "vid", "video", "movie", "mov", "clip"].contains(firstWord) {
            if let sequence = words.last(where: isShortNumericSequence) {
                return "Footage \(sequence)"
            }
            return date.map { "Footage - \($0)" } ?? "Untitled Footage"
        }

        let readableWords = words.filter { word in
            let lowercased = word.lowercased()
            return !isTimestampOrIdentifier(word) &&
                !["video", "movie", "mov"].contains(lowercased)
        }
        let readable = readableWords.joined(separator: " ")
        if readable.count >= 3 {
            return readable.localizedCapitalized
        }

        return date.map { "Footage - \($0)" } ?? "Untitled Footage"
    }

    static func displayName(from sourceName: String?) -> String {
        projectTitle(from: sourceName ?? "")
    }

    /// Older builds saved the cleaned filename directly as the project title.
    /// Upgrade only that exact automated fallback; an intentional user title
    /// is never rewritten when the project is reopened.
    static func upgradedLegacyTitle(_ title: String, sourceName: String) -> String {
        let sourceStem = stripWorkspacePrefix(
            from: URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        )
        let legacyTitles = [
            normalizedWords(from: sourceStem),
            FilenameSanitizer.sanitize(sourceStem, fallback: "")
                .replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        ]
        let suggested = projectTitle(from: sourceName)
        guard legacyTitles.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }),
              !legacyTitles.contains(where: { suggested.caseInsensitiveCompare($0) == .orderedSame }) else {
            return title
        }
        return suggested
    }

    private static func stripWorkspacePrefix(from fileStem: String) -> String {
        let components = fileStem.components(separatedBy: "-")
        guard components.count > 7,
              components[0].count == 8,
              components[1].count == 6
        else {
            return fileStem
        }

        let uuidCandidate = components[2...6].joined(separator: "-")
        guard UUID(uuidString: uuidCandidate) != nil else { return fileStem }
        return components[7...].joined(separator: "-")
    }

    private static func normalizedWords(from raw: String) -> String {
        FilenameSanitizer.sanitize(raw, fallback: "")
            .replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isShortNumericSequence(_ word: String) -> Bool {
        guard (3...6).contains(word.count) else { return false }
        return word.allSatisfy(\.isNumber)
    }

    private static func isTimestampOrIdentifier(_ word: String) -> Bool {
        let digitsOnly = word.allSatisfy(\.isNumber)
        if digitsOnly, word.count >= 7 { return true }
        let compact = word.replacingOccurrences(of: "-", with: "")
        return compact.count >= 20 && compact.allSatisfy { $0.isHexDigit }
    }

    private static func dateLabel(in raw: String) -> String? {
        guard let match = raw.range(of: #"20\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])"#, options: .regularExpression) else {
            return nil
        }
        let value = raw[match]
        guard value.count == 8,
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        let monthSymbols = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(monthSymbols[month - 1]) \(day)"
    }
}
