@preconcurrency import AVFoundation
import Foundation

struct WaveformSample: Identifiable, Equatable, Codable {
    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    let level: Double
}

enum WaveformAnalyzerError: LocalizedError {
    case unableToReadAudio

    var errorDescription: String? {
        switch self {
        case .unableToReadAudio:
            return "The audio waveform could not be analyzed."
        }
    }
}

struct WaveformAnalyzer {
    func samples(
        for sourceURL: URL,
        durationSeconds: Double,
        targetSampleCount: Int = 72
    ) async throws -> [WaveformSample] {
        guard durationSeconds.isFinite, durationSeconds > 0, targetSampleCount > 0 else { return [] }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else { return [] }

        let windowDuration = max(durationSeconds / Double(targetSampleCount), 0.05)
        let windows = try analyzeAudioEnergy(asset: asset, audioTrack: audioTrack, windowDuration: windowDuration)
        return Self.normalizedSamples(windows, targetCount: targetSampleCount)
    }

    static func normalizedSamples(_ windows: [AudioEnergyWindow], targetCount: Int) -> [WaveformSample] {
        guard targetCount > 0, let maxRMS = windows.map(\.rms).max(), maxRMS > 0 else {
            return windows.prefix(targetCount).enumerated().map { index, window in
                WaveformSample(
                    id: index,
                    startSeconds: window.startSeconds,
                    endSeconds: window.endSeconds,
                    level: 0
                )
            }
        }

        return windows.prefix(targetCount).enumerated().map { index, window in
            WaveformSample(
                id: index,
                startSeconds: window.startSeconds,
                endSeconds: window.endSeconds,
                level: min(max(Double(window.rms / maxRMS), 0), 1)
            )
        }
    }

    private func analyzeAudioEnergy(
        asset: AVAsset,
        audioTrack: AVAssetTrack,
        windowDuration: Double
    ) throws -> [AudioEnergyWindow] {
        guard windowDuration.isFinite, windowDuration > 0 else {
            throw WaveformAnalyzerError.unableToReadAudio
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
            throw WaveformAnalyzerError.unableToReadAudio
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? WaveformAnalyzerError.unableToReadAudio
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
            throw reader.error ?? WaveformAnalyzerError.unableToReadAudio
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

        // Verify the sample buffer is actually Float32 PCM before
        // interpreting raw bytes. If the format doesn't match (e.g.
        // integer PCM delivered despite our output settings), return 0
        // instead of producing garbage RMS values.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 0
        }
        guard asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.pointee.mBitsPerChannel == 32 else {
            // Not Float32 — can't interpret bytes safely.
            return 0
        }

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
}
