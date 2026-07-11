@preconcurrency import AVFoundation
import Foundation

struct ClipRange: Equatable, Codable {
    let startSeconds: Double
    let endSeconds: Double
    var reason: String?  // AI-provided explanation for why this clip was selected
    /// When true, the clip is locked on the timeline — its position
    /// can't be moved and its handles can't be trimmed. Toggled via
    /// long-press on the clip in the timeline. Persists with the
    /// project so reopening the project restores the lock state.
    var isLocked: Bool = false
    /// Which cut mode this range was planned in. Stamped at generation
    /// time (fixed/highlight/smartPause/aiAssist) and preserved through
    /// all subsequent edits and the project round-trip. Drives the
    /// `liveTimelineRanges` filter so a highlight clip doesn't appear
    /// in fixed mode, a smart-cut clip doesn't show up in highlight,
    /// and switching modes doesn't destroy work the user planned in
    /// another mode. Default `.highlight` so legacy projects (pre-cutMode
    /// field) show their planned ranges in highlight — the new default
    /// mode — and the user can switch to recover them if they were
    /// planned in another mode.
    var cutMode: CutMode = .highlight

    var duration: Double {
        endSeconds - startSeconds
    }

    init(startSeconds: Double, endSeconds: Double, reason: String? = nil, isLocked: Bool = false, cutMode: CutMode = .highlight) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.reason = reason
        self.isLocked = isLocked
        self.cutMode = cutMode
    }

    /// Stable identifier for use in SwiftUI `ForEach` lists that
    /// show this range. ClipRange doesn't conform to
    /// `Identifiable` because its identity is positional (start +
    /// end + cutMode) rather than a UUID — multiple equal
    /// `ClipRange` values can legitimately exist (e.g. the same
    /// range planned twice in different sessions). Sections that
    /// render a list of `ClipRange` (planned clips, saved clips)
    /// key off this composite id so SwiftUI can animate inserts
    /// / removes / moves correctly.
    var savedRowID: String {
        "\(startSeconds)|\(endSeconds)|\(cutMode.rawValue)|\(reason ?? "")"
    }

    private enum CodingKeys: String, CodingKey {
        case startSeconds
        case endSeconds
        case reason
        case isLocked
        case cutMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // isLocked is added in a later schema — old project files
        // (saved before this field existed) simply decode as unlocked.
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        // cutMode is added in a later schema — old project files
        // (saved before this field existed) decode as highlight, the
        // current default mode. Users can switch modes to recover
        // ranges planned in other modes.
        cutMode = try container.decodeIfPresent(CutMode.self, forKey: .cutMode) ?? .highlight
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startSeconds, forKey: .startSeconds)
        try container.encode(endSeconds, forKey: .endSeconds)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(cutMode, forKey: .cutMode)
    }
}

struct SmartCutSettings: Equatable {
    var minClipDuration = 1.0
    var maxClipDuration = 8.0
    var silenceThreshold: Float = 0.035
    var minimumSilenceDuration = 0.35
    var analysisWindowDuration = 0.20
}

struct AudioEnergyWindow: Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let rms: Float
}

enum SmartCutAnalyzerError: LocalizedError {
    case unableToReadAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .unableToReadAudio:
            return "The audio track could not be analyzed."
        case .noSpeechDetected:
            return "No voice or audible content was detected in the selected range."
        }
    }
}

struct SmartCutAnalyzer {
    func ranges(
        for sourceURL: URL,
        fallbackSegmentLength: Double,
        settings: SmartCutSettings = SmartCutSettings()
    ) async throws -> [ClipRange] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let audioTrack = audioTracks.first else {
            return Self.equalRanges(totalDuration: totalSeconds, segmentLength: fallbackSegmentLength)
        }

        let windows = try analyzeAudioEnergy(
            asset: asset,
            audioTrack: audioTrack,
            windowDuration: settings.analysisWindowDuration,
            timeRange: nil
        )

        let plannedRanges = Self.planRanges(totalDuration: totalSeconds, windows: windows, settings: settings)

        if plannedRanges.count <= 1 {
            return Self.equalRanges(totalDuration: totalSeconds, segmentLength: fallbackSegmentLength)
        }

        return plannedRanges
    }

    /// Returns only audible portions of the requested scopes. This is the
    /// destructive/"remove pauses" behavior used by Smart Pause when the
    /// user taps Add: each returned range is safe to export without the
    /// detected silent gaps.
    func nonSilentRanges(
        for sourceURL: URL,
        within scopes: [ClipRange] = [],
        fallbackSegmentLength: Double,
        settings: SmartCutSettings = SmartCutSettings()
    ) async throws -> [ClipRange] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        let normalizedScopes = Self.normalizedScopes(scopes, totalDuration: totalSeconds)
        let effectiveScopes = normalizedScopes.isEmpty
            ? [ClipRange(startSeconds: 0, endSeconds: totalSeconds)]
            : normalizedScopes

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            return effectiveScopes.flatMap { scope in
                Self.equalRanges(
                    totalDuration: scope.duration,
                    segmentLength: fallbackSegmentLength
                ).map { range in
                    ClipRange(
                        startSeconds: range.startSeconds + scope.startSeconds,
                        endSeconds: range.endSeconds + scope.startSeconds
                    )
                }
            }
        }

        // Read only the selected scopes. Previously this decoded the entire
        // source audio and filtered the result afterward, which made a small
        // highlighted range cost as much as a full-length analysis.
        let windows = try effectiveScopes.flatMap { scope in
            try analyzeAudioEnergy(
                asset: asset,
                audioTrack: audioTrack,
                windowDuration: settings.analysisWindowDuration,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: scope.startSeconds, preferredTimescale: 600),
                    duration: CMTime(seconds: scope.duration, preferredTimescale: 600)
                )
            )
        }

        return effectiveScopes.flatMap { scope in
            audibleRanges(in: scope, windows: windows, settings: settings)
        }
    }

    private static func normalizedScopes(_ scopes: [ClipRange], totalDuration: Double) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        return scopes.compactMap { scope in
            let start = min(max(scope.startSeconds, 0), totalDuration)
            let end = min(max(scope.endSeconds, 0), totalDuration)
            guard end - start > 0.05 else { return nil }
            return ClipRange(startSeconds: start, endSeconds: end)
        }
    }

    private func audibleRanges(
        in scope: ClipRange,
        windows: [AudioEnergyWindow],
        settings: SmartCutSettings
    ) -> [ClipRange] {
        var result: [ClipRange] = []
        var audibleStart: Double?
        var audibleEnd: Double?
        var silenceStart: Double?

        for window in windows {
            let start = max(window.startSeconds, scope.startSeconds)
            let end = min(window.endSeconds, scope.endSeconds)
            guard end > start else { continue }

            if window.rms > settings.silenceThreshold {
                audibleStart = audibleStart ?? start
                audibleEnd = end
                silenceStart = nil
            } else {
                guard audibleStart != nil else { continue }
                silenceStart = silenceStart ?? start
                if end - (silenceStart ?? end) >= settings.minimumSilenceDuration {
                    if let audibleStart,
                       let audibleEnd,
                       audibleEnd - audibleStart >= settings.minClipDuration {
                        result.append(ClipRange(startSeconds: audibleStart, endSeconds: audibleEnd))
                    }
                    audibleStart = nil
                    audibleEnd = nil
                    silenceStart = nil
                }
            }
        }

        if let audibleStart,
           let audibleEnd,
           audibleEnd - audibleStart >= settings.minClipDuration {
            result.append(ClipRange(startSeconds: audibleStart, endSeconds: audibleEnd))
        }

        return result
    }

    static func planRanges(
        totalDuration: Double,
        windows: [AudioEnergyWindow],
        settings: SmartCutSettings
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        guard settings.minClipDuration > 0, settings.maxClipDuration >= settings.minClipDuration else {
            return [ClipRange(startSeconds: 0, endSeconds: totalDuration)]
        }

        var cutPoints: [Double] = [0]
        var silenceStart: Double?

        for window in windows {
            let isSilent = window.rms <= settings.silenceThreshold

            if isSilent, silenceStart == nil {
                silenceStart = window.startSeconds
            }

            if !isSilent, let start = silenceStart {
                appendCutIfUseful(
                    at: (start + window.startSeconds) / 2,
                    cutPoints: &cutPoints,
                    totalDuration: totalDuration,
                    settings: settings,
                    silenceDuration: window.startSeconds - start
                )
                silenceStart = nil
            }

            while window.endSeconds - (cutPoints.last ?? 0) >= settings.maxClipDuration {
                let nextCut = (cutPoints.last ?? 0) + settings.maxClipDuration
                appendCutIfUseful(
                    at: nextCut,
                    cutPoints: &cutPoints,
                    totalDuration: totalDuration,
                    settings: settings,
                    silenceDuration: settings.minimumSilenceDuration
                )
            }
        }

        if let start = silenceStart {
            appendCutIfUseful(
                at: (start + totalDuration) / 2,
                cutPoints: &cutPoints,
                totalDuration: totalDuration,
                settings: settings,
                silenceDuration: totalDuration - start
            )
        }

        if cutPoints.last != totalDuration {
            cutPoints.append(totalDuration)
        }

        return zip(cutPoints, cutPoints.dropFirst())
            .compactMap { start, end in
                guard end - start > 0.05 else { return nil }
                return ClipRange(startSeconds: start, endSeconds: end)
            }
    }

    static func equalRanges(
        totalDuration: Double,
        segmentLength: Double,
        minimumFinalSegmentLength: Double = 0.05
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        guard segmentLength.isFinite, segmentLength >= 1 else { return [] }
        guard minimumFinalSegmentLength.isFinite, minimumFinalSegmentLength >= 0 else { return [] }

        let rawClipCount = ceil(totalDuration / segmentLength)
        guard rawClipCount.isFinite, rawClipCount > 0 else { return [] }
        let clipCount = Int(rawClipCount)

        var ranges = (0..<clipCount).map { index in
            let startSeconds = Double(index) * segmentLength
            let endSeconds = min(startSeconds + segmentLength, totalDuration)
            return ClipRange(startSeconds: startSeconds, endSeconds: endSeconds)
        }

        if ranges.count > 1,
           let finalRange = ranges.last,
           finalRange.duration < minimumFinalSegmentLength {
            ranges.removeLast()
            let previous = ranges.removeLast()
            ranges.append(
                ClipRange(
                    startSeconds: previous.startSeconds,
                    endSeconds: finalRange.endSeconds
                )
            )
        }

        return ranges
    }

    private func analyzeAudioEnergy(
        asset: AVAsset,
        audioTrack: AVAssetTrack,
        windowDuration: Double,
        timeRange: CMTimeRange?
    ) throws -> [AudioEnergyWindow] {
        guard windowDuration.isFinite, windowDuration > 0 else {
            throw SmartCutAnalyzerError.unableToReadAudio
        }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange {
            reader.timeRange = timeRange
        }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw SmartCutAnalyzerError.unableToReadAudio
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? SmartCutAnalyzerError.unableToReadAudio
        }

        var buckets: [Int: (sum: Double, count: Int)] = [:]
        let originSeconds = timeRange.map { CMTimeGetSeconds($0.start) } ?? 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw VideoSegmenterError.cancelled
            }

            let startSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard startSeconds.isFinite else { continue }

            let rms = rmsValue(for: sampleBuffer)
            let relativeStartSeconds = startSeconds - originSeconds
            let rawBucketIndex = relativeStartSeconds / windowDuration
            guard rawBucketIndex.isFinite, rawBucketIndex >= 0 else { continue }
            let bucketIndex = Int(rawBucketIndex)
            let existing = buckets[bucketIndex] ?? (sum: 0, count: 0)
            buckets[bucketIndex] = (sum: existing.sum + Double(rms), count: existing.count + 1)
        }

        if reader.status == .failed {
            throw reader.error ?? SmartCutAnalyzerError.unableToReadAudio
        }

        return buckets.keys.sorted().compactMap { index in
            guard let bucket = buckets[index], bucket.count > 0 else { return nil }
            let start = originSeconds + Double(index) * windowDuration
            return AudioEnergyWindow(
                startSeconds: start,
                endSeconds: start + windowDuration,
                rms: Float(bucket.sum / Double(bucket.count))
            )
        }
    }

    private func rmsValue(for sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return 0 }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }

        guard status == noErr else { return 0 }

        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerSample = streamDescription.pointee.mBitsPerChannel

        if flags & kAudioFormatFlagIsFloat != 0, bitsPerSample == 32 {
            let sampleCount = length / MemoryLayout<Float32>.size
            guard sampleCount > 0 else { return 0 }
            return data.withUnsafeBytes { bytes in
                var squareSum: Float = 0
                for index in 0..<sampleCount {
                    let byteOffset = index * MemoryLayout<Float32>.size
                    let sample = bytes.loadUnaligned(fromByteOffset: byteOffset, as: Float32.self)
                    squareSum += sample * sample
                }
                let rms = sqrt(squareSum / Float(sampleCount))
                return rms.isFinite ? rms : 0
            }
        }

        // Some assets are delivered as signed integer PCM despite the
        // requested Float32 output. Decode the common 16-bit form rather
        // than interpreting integer bytes as floating-point samples.
        if flags & kAudioFormatFlagIsSignedInteger != 0, bitsPerSample == 16 {
            let sampleCount = length / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return 0 }
            return data.withUnsafeBytes { bytes in
                var squareSum: Float = 0
                for index in 0..<sampleCount {
                    let byteOffset = index * MemoryLayout<Int16>.size
                    let raw = bytes.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                    let sample = Float(raw) / Float(Int16.max)
                    squareSum += sample * sample
                }
                let rms = sqrt(squareSum / Float(sampleCount))
                return rms.isFinite ? rms : 0
            }
        }

        if flags & kAudioFormatFlagIsSignedInteger != 0, bitsPerSample == 32 {
            let sampleCount = length / MemoryLayout<Int32>.size
            guard sampleCount > 0 else { return 0 }
            return data.withUnsafeBytes { bytes in
                var squareSum: Float = 0
                for index in 0..<sampleCount {
                    let byteOffset = index * MemoryLayout<Int32>.size
                    let raw = bytes.loadUnaligned(fromByteOffset: byteOffset, as: Int32.self)
                    let sample = Float(raw) / Float(Int32.max)
                    squareSum += sample * sample
                }
                let rms = sqrt(squareSum / Float(sampleCount))
                return rms.isFinite ? rms : 0
            }
        }

        return 0
    }

    private static func appendCutIfUseful(
        at cutPoint: Double,
        cutPoints: inout [Double],
        totalDuration: Double,
        settings: SmartCutSettings,
        silenceDuration: Double
    ) {
        guard silenceDuration >= settings.minimumSilenceDuration else { return }

        let lastCut = cutPoints.last ?? 0
        let clampedCut = min(max(cutPoint, lastCut), totalDuration)
        let remaining = totalDuration - clampedCut

        guard clampedCut - lastCut >= settings.minClipDuration else { return }
        guard remaining == 0 || remaining >= settings.minClipDuration else { return }
        guard clampedCut < totalDuration else { return }

        cutPoints.append(clampedCut)
    }
}
