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
            cutIndex = index
        }
        let trimmed = String(precomposed[precomposed.startIndex...cutIndex])
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