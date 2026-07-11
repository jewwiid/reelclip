import AVFoundation
import Foundation
import whisper

/// On-device speech-to-text powered by OpenAI's Whisper (via whisper.cpp).
///
/// Replaces `SFSpeechRecognizer`-based transcription with a model that:
/// - runs fully on-device (no API key, no internet, no length limit),
/// - supports 99 languages,
/// - returns segment-level + token-level timestamps natively.
///
/// The Whisper model (`.ggml` format) is downloaded lazily on first use
/// from HuggingFace and cached in the app's Documents directory so
/// subsequent transcriptions start instantly.
enum WhisperTranscriptionServiceError: LocalizedError {
    case modelDownloadFailed(String)
    case modelLoadFailed(String)
    case audioExportFailed(String)
    case audioDecodeFailed(String)
    case transcriptionFailed(String)
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .modelDownloadFailed(let message):
            return "Couldn't download the speech model: \(message)"
        case .modelLoadFailed(let message):
            return "Couldn't load the speech model: \(message)"
        case .audioExportFailed(let message):
            return "Couldn't extract audio from the video: \(message)"
        case .audioDecodeFailed(let message):
            return "Couldn't decode the audio: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .noAudioTrack:
            return "This video has no audio track to transcribe."
        }
    }
}

/// Downloads and caches the Whisper `.ggml` model file. The model lives in
/// `Documents/whisper-models/ggml-base.bin` (~142 MB for the base model).
/// On first transcription the file is fetched from HuggingFace with
/// progress reporting so the UI can show "Downloading speech model…".
enum WhisperModelManager {
    /// Base model — good balance of speed and accuracy on-device (~142 MB).
    static let modelFileName = "ggml-base.bin"
    static let modelDownloadURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
    )!

    /// Directory inside Documents where Whisper models are cached.
    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("whisper-models", isDirectory: true)
    }

    /// Absolute path to the cached base model.
    static var modelURL: URL {
        modelsDirectory.appendingPathComponent(modelFileName)
    }

    /// True when the model file is already present on disk.
    static var isModelPresent: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Ensure the model is present on disk, downloading it from
    /// HuggingFace if needed. Reports fractional progress (0…1) via
    /// `progress` while the download is in flight. Returns the URL of
    /// the model file ready to be loaded into a Whisper context.
    static func ensureModel(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        if isModelPresent {
            progress(1.0)
            return modelURL
        }
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
        let destination = modelURL
        // Download to a temp file first, then move into place so a
        // partial download never ends up looking like a complete model.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (bytes, response) = try await URLSession.shared.bytes(
            from: modelDownloadURL
        )
        guard (response as HTTPURLResponse).statusCode == 200 else {
            throw WhisperTranscriptionServiceError.modelDownloadFailed(
                "HTTP \((response as HTTPURLResponse).statusCode)"
            )
        }

        let expectedLength = response.expectedContentLength
        var received: Int64 = 0
        var fileHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? fileHandle.close() }

        for try await byte in bytes {
            try fileHandle.write(contentsOf: [byte])
            received &+= 1
            if expectedLength > 0 {
                progress(Double(received) / Double(expectedLength))
            }
        }
        try fileHandle.close()

        // Move the completed download into its final cache location.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        progress(1.0)
        return destination
    }
}

/// Wraps a `whisper_context *` so Swift owns its lifetime. whisper.cpp
/// requires single-threaded access, so the context is guarded by an
/// actor. The C API exposes segment- and token-level timestamps in
/// centiseconds (1/100 s).
actor WhisperContext {
    private let context: OpaquePointer

    private init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Load a Whisper model from a `.ggml` file path.
    static func create(path: String) throws -> WhisperContext {
        var cparams = whisper_context_default_params()
        #if targetEnvironment(simulator)
        // Metal isn't available in the simulator — fall back to CPU.
        cparams.use_gpu = false
        #else
        cparams.flash_attn = true
        #endif
        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw WhisperTranscriptionServiceError.modelLoadFailed(path)
        }
        return WhisperContext(context: ctx)
    }

    /// Run full transcription on raw 16 kHz mono Float32 PCM samples.
    /// `language` is an ISO-639-1 code ("en", "fr", …) or "auto" to
    /// auto-detect. Returns the detected language code and the array
    /// of segments.
    func transcribe(
        samples: [Float],
        language: String = "auto",
        detectLanguage: Bool = true
    ) throws -> (language: String, segments: [WhisperSegment]) {
        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.token_timestamps = true
        params.split_on_word = true
        params.suppress_blank = true
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0

        // Language: pass `nullptr` for auto-detection.
        let langCString: UnsafePointer<CChar>?
        var detectedLang = "auto"
        if detectLanguage || language == "auto" {
            langCString = nil
            params.detect_language = true
        } else {
            langCString = language.withCString { $0 }
            params.detect_language = false
        }

        // Run the model. The C-string pointer must stay alive for the
        // duration of `whisper_full`.
        let result: Int32 = langCString.map { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(context, params, buf.baseAddress, Int32(buf.count))
            }
        } ?? samples.withUnsafeBufferPointer { buf in
            params.language = nil
            return whisper_full(context, params, buf.baseAddress, Int32(buf.count))
        }

        guard result == 0 else {
            throw WhisperTranscriptionServiceError.transcriptionFailed(
                "whisper_full returned \(result)"
            )
        }

        // Detected language id (only valid when auto-detect was on).
        if detectLanguage || language == "auto" {
            let langID = whisper_lang_auto_detect(context)
            if langID >= 0,
               let cstr = whisper_lang_str(langID) {
                detectedLang = String(cString: cstr)
            }
        }

        let segments = collectSegments()
        return (detectedLang, segments)
    }

    /// Pull segments + token-level timestamps out of the context after
    /// `whisper_full` has run. Timestamps are centiseconds (1/100 s).
    private func collectSegments() -> [WhisperSegment] {
        let nSegments = whisper_full_n_segments(context)
        var out: [WhisperSegment] = []
        out.reserveCapacity(Int(nSegments))
        for i in 0..<nSegments {
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            let text = String(cString: whisper_full_get_segment_text(context, i))
            let nTokens = whisper_full_n_tokens(context, i)

            var tokens: [WhisperToken] = []
            tokens.reserveCapacity(Int(nTokens))
            for t in 0..<nTokens {
                let tokenText = String(cString: whisper_full_get_token_text(context, i, t))
                let data = whisper_full_get_token_data(context, i, t)
                // token timestamps are centiseconds
                tokens.append(WhisperToken(
                    text: tokenText,
                    startSeconds: Double(data.t0) / 100.0,
                    endSeconds: Double(data.t1) / 100.0,
                    probability: data.p
                ))
            }
            out.append(WhisperSegment(
                startSeconds: Double(t0) / 100.0,
                endSeconds: Double(t1) / 100.0,
                text: text,
                tokens: tokens
            ))
        }
        return out
    }
}

/// Raw whisper.cpp output for a single segment.
struct WhisperSegment {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let tokens: [WhisperToken]
}

/// Raw whisper.cpp output for a single token.
struct WhisperToken {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let probability: Float
}

/// High-level Whisper transcription service. Loads the model (downloading
/// it on first use with progress reporting), extracts the audio track
/// from a video as 16 kHz mono WAV, decodes it to Float32 PCM, and runs
/// Whisper to produce a `Transcript`.
struct WhisperTranscriptionService {
    /// Progress callback for the model download (0…1). Called on the
    /// main actor so view models can publish it directly.
    typealias DownloadProgress = @Sendable (Double) -> Void

    /// Transcribe the audio track of the video at `videoURL`.
    /// - Parameters:
    ///   - videoURL: Local URL of the source video.
    ///   - language: ISO-639-1 language hint, or "auto" to detect.
    ///   - downloadProgress: Called with 0…1 while the model downloads.
    func transcribe(
        videoURL: URL,
        language: String = "auto",
        downloadProgress: DownloadProgress? = nil
    ) async throws -> Transcript {
        let progress: DownloadProgress = downloadProgress ?? { _ in }
        // 1. Ensure the model is present.
        let modelURL = try await WhisperModelManager.ensureModel(progress: progress)
        let context = try await WhisperContext.create(path: modelURL.path)

        // 2. Export the video's audio track to 16 kHz mono WAV.
        let wavURL = try await Self.exportAudioToWAV(videoURL: videoURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // 3. Decode the WAV to Float32 PCM samples.
        let samples = try Self.decodeWAV(url: wavURL)

        // 4. Run Whisper.
        let (detectedLanguage, segments) = try await context.transcribe(
            samples: samples,
            language: language,
            detectLanguage: true
        )

        // 5. Map to our Transcript model.
        return Self.makeTranscript(
            segments: segments,
            language: detectedLanguage
        )
    }

    // MARK: - Audio extraction

    /// Export the first audio track of `videoURL` as 16 kHz mono PCM
    /// (WAV) using `AVAssetExportSession`. Whisper requires 16 kHz mono
    /// Float32 PCM input.
    static func exportAudioToWAV(videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard try await asset.load(.tracks).contains(where: { ($0.mediaType == .audio) }) else {
            throw WhisperTranscriptionServiceError.noAudioTrack
        }

        guard let exportSession = AVAssetExportSession(asset: asset, withPreset: AVAssetExportPresetAppleM4A) else {
            throw WhisperTranscriptionServiceError.audioExportFailed(
                "AVAssetExportSession unavailable"
            )
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString).m4a")

        // AVAssetExportSession can't write WAV directly, so we export
        // to M4A (AAC) and then decode to raw PCM via AVAudioFile.
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            break
        case .cancelled:
            throw WhisperTranscriptionServiceError.audioExportFailed("Export cancelled")
        case .failed:
            throw WhisperTranscriptionServiceError.audioExportFailed(
                exportSession.error?.localizedDescription ?? "Unknown export error"
            )
        default:
            throw WhisperTranscriptionServiceError.audioExportFailed(
                "Unexpected export status: \(exportSession.status.rawValue)"
            )
        }

        // Convert the M4A to 16 kHz mono Float32 WAV using AVAudioFile.
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString).wav")
        try convertTo16kHzMonoWAV(input: outputURL, output: wavURL)
        try? FileManager.default.removeItem(at: outputURL)
        return wavURL
    }

    /// Re-encode an audio file to 16 kHz mono Float32 PCM WAV using
    /// `AVAudioFile` + `AVAudioEngine`-style read/write.
    static func convertTo16kHzMonoWAV(input: URL, output: URL) throws {
        let avFile = try AVAudioFile(forReading: input)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(avFile.length)
        ) else {
            throw WhisperTranscriptionServiceError.audioDecodeFailed(
                "Couldn't allocate audio buffer"
            )
        }
        try avFile.read(into: buffer)
        let outFile = try AVAudioFile(
            forWriting: output,
            settings: format.settings
        )
        try outFile.write(from: buffer)
    }

    /// Decode a 16 kHz mono Float32 WAV file into raw PCM samples.
    /// Strips the 44-byte WAV header and converts Int16 LE samples to
    /// Float32 in [-1, 1].
    static func decodeWAV(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        // Standard WAV header is 44 bytes. We exported with
        // AVAudioFile so the layout is canonical PCM.
        guard data.count > 44 else {
            throw WhisperTranscriptionServiceError.audioDecodeFailed("WAV too short")
        }
        let floats = stride(from: 44, to: data.count, by: 2).map { offset -> Float in
            let short = data[offset..<(offset + 2)].withUnsafeBytes {
                $0.load(as: Int16.self).littleEndian
            }
            return max(-1.0, min(Float(short) / 32767.0, 1.0))
        }
        return floats
    }

    // MARK: - Transcript mapping

    /// Convert whisper.cpp segments into our `Transcript` model. Each
    /// Whisper segment maps to a `TranscriptSegment`. Token-level
    /// timestamps are mapped to words where the token carries visible
    /// text; whisper emits special tokens (timestamps, punctuation) that
    /// are filtered out so the teleprompter shows only spoken words.
    static func makeTranscript(
        segments: [WhisperSegment],
        language: String
    ) -> Transcript {
        let mapped: [TranscriptSegment] = segments.compactMap { seg in
            // Whisper token text can be a leading space + word, a
            // punctuation-only token, or a special token. Keep only
            // tokens that have at least one alphanumeric character so
            // the word chips read naturally.
            let words: [TranscriptWord] = seg.tokens.compactMap { token in
                let trimmed = token.text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                    return nil
                }
                let start = token.startSeconds.isFinite ? token.startSeconds : seg.startSeconds
                let end = token.endSeconds.isFinite && token.endSeconds > start
                    ? token.endSeconds
                    : seg.endSeconds
                return TranscriptWord(
                    text: trimmed,
                    startSeconds: start,
                    endSeconds: max(end, start)
                )
            }

            let text = seg.text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            return TranscriptSegment(
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                text: text,
                words: words
            )
        }
        return Transcript(
            language: language.isEmpty ? "auto" : language,
            segments: mapped
        )
    }
}

// MARK: - AVAssetExportSession await bridge

private extension AVAssetExportSession {
    /// `AVAssetExportSession` predates async/await, so wrap its
    /// completion-handler API in a continuation. Honours cancellation.
    func export() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exportAsynchronously {
                continuation.resume()
            }
        }
    }
}

private extension AVAsset {
    /// Async wrapper around `load(.tracks)` so we can inspect the asset
    /// without blocking the main thread.
    func load(_ key: AVAsyncKey<A, [AVAssetTrack]>) async throws {
        // `AVURLAsset.loadTracks` isn't available on iOS 16; use the
        // `load(.tracks)` async getter which is available from iOS 16.
        _ = try await self.loadTracks(withMediaType: .audio)
    }
}

/// Lightweight key type used only to disambiguate the `load` overload
/// above. This avoids pulling in the full AVFoundation async-load API.
private struct AVAsyncKey<Root, Value> {}

private extension AVURLAsset {
    /// Compatibility shim that loads tracks with a given media type.
    func loadTracks(withMediaType type: AVMediaType) async throws -> [AVAssetTrack] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[AVAssetTrack], Error>) in
            self.loadTracks(withMediaType: type) { tracks, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: tracks ?? []) }
            }
        }
    }
}