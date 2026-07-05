@preconcurrency import AVFoundation
import Foundation

struct ClipRange: Equatable, Codable {
    let startSeconds: Double
    let endSeconds: Double

    var duration: Double {
        endSeconds - startSeconds
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

    var errorDescription: String? {
        switch self {
        case .unableToReadAudio:
            return "The audio track could not be analyzed."
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
            windowDuration: settings.analysisWindowDuration
        )

        let plannedRanges = Self.planRanges(totalDuration: totalSeconds, windows: windows, settings: settings)

        if plannedRanges.count <= 1 {
            return Self.equalRanges(totalDuration: totalSeconds, segmentLength: fallbackSegmentLength)
        }

        return plannedRanges
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
        windowDuration: Double
    ) throws -> [AudioEnergyWindow] {
        guard windowDuration.isFinite, windowDuration > 0 else {
            throw SmartCutAnalyzerError.unableToReadAudio
        }

        let reader = try AVAssetReader(asset: asset)
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

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw VideoSegmenterError.cancelled
            }

            let startSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard startSeconds.isFinite else { continue }

            let rms = rmsValue(for: sampleBuffer)
            let rawBucketIndex = startSeconds / windowDuration
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
            let start = Double(index) * windowDuration
            return AudioEnergyWindow(
                startSeconds: start,
                endSeconds: start + windowDuration,
                rms: Float(bucket.sum / Double(bucket.count))
            )
        }
    }

    private func rmsValue(for sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }

        guard status == noErr else { return 0 }

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
