import Foundation

/// A single recognised segment from the speech recogniser (typically a
/// sentence or short phrase). `SFSpeechRecognizer` doesn't expose
/// word-level timestamps in the public API, so we model the segment
/// as the smallest addressable unit. Each segment has its own start/end
/// time range and a `words` array of approximations derived from
/// whitespace-splitting the segment text and distributing time evenly
/// across the range. This gives the teleprompter UI a finer-grained
/// kept/cut visualisation than per-segment alone.
struct TranscriptSegment: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let words: [TranscriptWord]

    init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        words: [TranscriptWord]
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.words = words
    }
}

struct TranscriptWord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let text: String
    /// Approximate start time (distributed across the parent segment).
    let startSeconds: Double
    /// Approximate end time (distributed across the parent segment).
    let endSeconds: Double

    init(
        id: UUID = UUID(),
        text: String,
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

struct Transcript: Codable, Equatable {
    let language: String
    let segments: [TranscriptSegment]
    let generatedAt: Date

    init(language: String, segments: [TranscriptSegment], generatedAt: Date = Date()) {
        self.language = language
        self.segments = segments
        self.generatedAt = generatedAt
    }

    var isEmpty: Bool { segments.isEmpty }
    var segmentCount: Int { segments.count }
    var wordCount: Int { segments.reduce(0) { $0 + $1.words.count } }
}

// MARK: - Subtitle exports (Creator feature since v2.0)

extension Transcript {
    /// Format the transcript as SubRip (`.srt`). Each segment maps to one cue;
    /// the cue body is the segment's `text` (joined on whitespace so the SRT
    /// timestamp formats stay clean).
    func exportSRT() -> String {
        segments.enumerated()
            .map { index, segment in
                let start = Self.formatSRTTime(segment.startSeconds)
                let end = Self.formatSRTTime(segment.endSeconds)
                let body = segment.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                return "\(index + 1)\n\(start) --> \(end)\n\(body)\n"
            }
            .joined(separator: "\n")
    }

    /// Format the transcript as WebVTT (`.vtt`). Includes the required
    /// `WEBVTT` header block and a small index header.
    func exportVTT() -> String {
        var output = "WEBVTT\n"
        output += "NOTE ReelClips transcript export\n\n"
        for (index, segment) in segments.enumerated() {
            let start = Self.formatVTTTime(segment.startSeconds)
            let end = Self.formatVTTTime(segment.endSeconds)
            let body = segment.text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            output += "\(index + 1)\n"
            output += "\(start) --> \(end)\n"
            output += "\(body)\n\n"
        }
        return output
    }

    /// Format seconds as `HH:MM:SS,mmm` for SRT.
    private static func formatSRTTime(_ seconds: Double) -> String {
        let (h, m, s, ms) = Self.decompose(seconds)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Format seconds as `HH:MM:SS.mmm` for VTT (uses `.` instead of `,`).
    private static func formatVTTTime(_ seconds: Double) -> String {
        let (h, m, s, ms) = Self.decompose(seconds)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func decompose(_ seconds: Double) -> (Int, Int, Int, Int) {
        guard seconds.isFinite, seconds >= 0 else { return (0, 0, 0, 0) }
        let totalMillis = Int((seconds * 1000).rounded())
        let totalSeconds = totalMillis / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let millis = totalMillis % 1000
        return (hours, minutes, secs, millis)
    }
}

enum TranscriptState: Equatable {
    case idle
    case processing
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .idle: return ""
        case .processing: return "Transcribing…"
        case .ready: return "Transcript ready"
        case .failed(let message): return message
        }
    }

    var isBusy: Bool {
        if case .processing = self { return true }
        return false
    }
}
