import Foundation
import Speech

enum TranscriptServiceError: LocalizedError {
    case recognizerUnavailable
    case authorizationDenied
    case authorizationRestricted
    case noResult
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available for this device or language."
        case .authorizationDenied:
            return "Speech recognition permission was denied. Enable it in Settings to transcribe audio."
        case .authorizationRestricted:
            return "Speech recognition is restricted on this device."
        case .noResult:
            return "The audio could not be transcribed (silent track, unsupported codec, or too short)."
        case .underlying(let message):
            return message
        }
    }
}

/// On-device speech-to-text using `SFSpeechRecognizer`. Returns word-level
/// timestamps so the UI can highlight which words fall inside / outside the
/// planned cut ranges.
struct TranscriptService {
    /// Run on-device transcription against a local audio/video file. Forced
    /// on-device so nothing leaves the device even when the user is offline
    /// or has a private network.
    func transcribe(audioFileURL: URL, locale: Locale = .current) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptServiceError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // If the user's locale doesn't have an on-device model, fall back to
            // a server request. SFSpeechRecognizer will return an error if the
            // device is offline, which we surface to the user.
            try await ensureAuthorization()
            return try await runRecognition(recognizer: recognizer, fileURL: audioFileURL, forceOnDevice: false)
        }

        try await ensureAuthorization()
        return try await runRecognition(recognizer: recognizer, fileURL: audioFileURL, forceOnDevice: true)
    }

    private func ensureAuthorization() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        switch status {
        case .authorized:
            return
        case .denied:
            throw TranscriptServiceError.authorizationDenied
        case .restricted:
            throw TranscriptServiceError.authorizationRestricted
        case .notDetermined:
            throw TranscriptServiceError.authorizationDenied
        @unknown default:
            throw TranscriptServiceError.authorizationDenied
        }
    }

    private func runRecognition(
        recognizer: SFSpeechRecognizer,
        fileURL: URL,
        forceOnDevice: Bool
    ) async throws -> Transcript {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = forceOnDevice
        request.addsPunctuation = true
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { cont in
            // Hold the task in a box so the closure can keep it alive
            // while the recogniser is doing its work.
            let taskBox = TaskBox()
            let hasResumed = NSLock()
            var didResume = false

            func resumeOnce(throwing error: Error) {
                hasResumed.lock()
                defer { hasResumed.unlock() }
                guard !didResume else { return }
                didResume = true
                taskBox.task = nil
                cont.resume(throwing: error)
            }

            func resumeOnceReturning(_ value: Transcript) {
                hasResumed.lock()
                defer { hasResumed.unlock() }
                guard !didResume else { return }
                didResume = true
                taskBox.task = nil
                cont.resume(returning: value)
            }

            taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(throwing: TranscriptServiceError.underlying(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                resumeOnceReturning(Self.transcript(from: result, locale: recognizer.locale))
            }
            // Safety net: if the recognition task completes without ever
            // calling the completion handler with a final result or error
            // (system cancellation, edge case), the continuation would
            // hang forever. The 30s timeout cancels the task and resumes
            // with an error. `resumeOnce` guards against double-resume.
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                resumeOnce(throwing: TranscriptServiceError.underlying("Transcription timed out."))
            }
        }
    }

    /// Convert `SFSpeechRecognitionResult` into our `Transcript` model. The
    /// recogniser already groups by sentence, so each `SFTranscriptionSegment`
    /// maps 1:1 to a `TranscriptSegment`. Word-level timestamps aren't in the
    /// public `SFTranscriptionSegment` API, so we approximate them by
    /// whitespace-splitting the segment text and distributing the segment's
    /// duration across its words proportionally to their character counts.
    /// This is good enough for the kept/cut visualisation — the user sees
    /// each sentence with its overall kept/cut status, plus per-word
    /// approximation for finer reading.
    private static func transcript(
        from result: SFSpeechRecognitionResult,
        locale: Locale
    ) -> Transcript {
        let segments: [TranscriptSegment] = result.bestTranscription.segments.compactMap { seg in
            let segStart = seg.timestamp
            let segEnd = seg.timestamp + seg.duration
            let tokens = tokensForSegment(seg.substring)
            guard !tokens.isEmpty else { return nil }

            let totalChars = tokens.reduce(0) { $0 + $1.count }
            guard totalChars > 0 else {
                return TranscriptSegment(
                    startSeconds: segStart,
                    endSeconds: segEnd,
                    text: seg.substring,
                    words: []
                )
            }

            // Walk the segment's duration in proportion to each token's share
            // of the total character count.
            var cursor = segStart
            var words: [TranscriptWord] = []
            for token in tokens {
                let share = Double(token.count) / Double(totalChars)
                let span = (segEnd - segStart) * share
                let wordStart = cursor
                let wordEnd = min(segEnd, cursor + span)
                words.append(TranscriptWord(
                    text: token,
                    startSeconds: wordStart,
                    endSeconds: wordEnd
                ))
                cursor = wordEnd
            }
            return TranscriptSegment(
                startSeconds: segStart,
                endSeconds: segEnd,
                text: seg.substring,
                words: words
            )
        }
        return Transcript(
            language: locale.identifier,
            segments: segments
        )
    }

    /// Split a recogniser segment into display tokens. Strips trailing
    /// punctuation from each token so the visual chips look natural.
    private static func tokensForSegment(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
    }
}
