import Foundation

enum TimelineZoom: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case detail = "2x"
    case frame = "4x"

    var id: String { rawValue }

    var thumbnailScale: Double {
        switch self {
        case .fit:
            return 1.0
        case .detail:
            return 1.45
        case .frame:
            return 2.0
        }
    }
}

enum ClipRangeEditor {
    static func snap(_ seconds: Double, frameDuration: Double, totalDuration: Double) -> Double {
        guard seconds.isFinite, totalDuration.isFinite, totalDuration > 0 else { return 0 }
        let clamped = min(max(seconds, 0), totalDuration)
        guard frameDuration.isFinite, frameDuration > 0 else { return clamped }
        let snapped = (clamped / frameDuration).rounded() * frameDuration
        return min(max(snapped, 0), totalDuration)
    }

    static func updatedRange(
        _ range: ClipRange,
        totalDuration: Double,
        frameDuration: Double,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        minimumDuration: Double? = nil
    ) -> ClipRange {
        guard totalDuration.isFinite, totalDuration > 0 else { return range }

        let minimum = min(
            max(minimumDuration ?? max(frameDuration, 0.10), 0.05),
            totalDuration
        )
        var start = snap(startSeconds ?? range.startSeconds, frameDuration: frameDuration, totalDuration: totalDuration)
        var end = snap(endSeconds ?? range.endSeconds, frameDuration: frameDuration, totalDuration: totalDuration)

        if startSeconds != nil, endSeconds == nil {
            start = min(start, max(0, end - minimum))
        } else if endSeconds != nil, startSeconds == nil {
            end = max(end, min(totalDuration, start + minimum))
        } else if end - start < minimum {
            end = min(totalDuration, start + minimum)
            if end - start < minimum {
                start = max(0, end - minimum)
            }
        }

        guard end - start >= 0.05 else { return range }
        return ClipRange(startSeconds: start, endSeconds: end)
    }

    static func movedRanges(_ ranges: [ClipRange], from index: Int, direction: Int) -> [ClipRange] {
        guard ranges.indices.contains(index), direction != 0 else { return ranges }
        let destination = index + direction
        guard ranges.indices.contains(destination) else { return ranges }

        var edited = ranges
        edited.swapAt(index, destination)
        return edited
    }

    /// Split a duration into equal-length `ClipRange`s. The final range is
    /// dropped if it's shorter than `minimumFinalSegmentLength` (so a 10.3s
    /// source with 5s segments becomes two clips, not a 0.3s stub).
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
            if let lastIndex = ranges.indices.last {
                let mergedEnd = totalDuration
                ranges[lastIndex] = ClipRange(
                    startSeconds: ranges[lastIndex].startSeconds,
                    endSeconds: mergedEnd
                )
            }
        }

        return ranges
    }
}
