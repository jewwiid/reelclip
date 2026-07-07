@preconcurrency import AVFoundation
import Foundation
import UIKit
import CoreImage

/// Composes a watermark overlay onto a video segment for free-tier exports.
/// The watermark reads "Made with ReelClip" on a translucent pill at the
/// bottom-right corner of the frame. Watermark is only applied when the
/// subscription tier is `.free`; higher tiers render the segment untouched.
enum WatermarkRenderer {

    /// Build the `AVMutableVideoComposition` that overlays the watermark on
    /// the segment's natural frame size. Returns `nil` if the asset has no
    /// video track.
    ///
    /// - Parameters:
    ///   - asset: The source asset to read track geometry from.
    ///   - start: The segment's start time within the asset. The composition
    ///     instruction's `timeRange` is set to `[start, start+duration)` so
    ///     that `AVAssetExportSession` renders only the requested segment
    ///     when `videoComposition` is set. Without this, the composition's
    ///     instruction would span the entire asset and override the session's
    ///     `timeRange`, silently exporting the full video instead of the clip.
    ///   - duration: The segment's duration.
    static func composition(
        for asset: AVAsset,
        start: CMTime = .zero,
        duration: CMTime? = nil
    ) async -> AVMutableVideoComposition? {
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard let videoTrack = videoTracks.first else { return nil }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        do {
            naturalSize = try await videoTrack.load(.naturalSize)
            transform = try await videoTrack.load(.preferredTransform)
        } catch {
            return nil
        }

        // The source may be portrait or landscape depending on the recording
        // orientation. Use the *rendered* frame size (after orientation is
        // applied) so the watermark sits on the visible canvas.
        let orientedFrame = naturalSize.applying(transform)
        let renderSize = CGSize(
            width: abs(orientedFrame.width),
            height: abs(orientedFrame.height)
        )

        guard
            renderSize.width > 0, renderSize.height > 0,
            renderSize.width.isFinite, renderSize.height.isFinite
        else { return nil }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = await Self.makeOverlayLayer(for: renderSize)
        parentLayer.addSublayer(overlayLayer)

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Use the segment's time range — NOT the full asset duration.
        // When `exportSession.videoComposition` is set, `AVAssetExportSession`
        // ignores `exportSession.timeRange` and uses the composition's
        // instruction timeRange instead. Setting this to the segment range
        // ensures only the requested clip is exported with the watermark.
        let resolvedDuration = duration ?? asset.duration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: start, duration: resolvedDuration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: videoTrack
        )
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        return composition
    }

    private static func makeOverlayLayer(for renderSize: CGSize) async -> CALayer {
        // Pill-shaped chip in the bottom-right with the brand text.
        let overlay = CALayer()
        let inset = renderSize.height * 0.03
        let padding = renderSize.width * 0.025
        let chipHeight = renderSize.height * 0.06
        let text = NSAttributedString(
            string: "Made with ReelClip",
            attributes: [
                .font: UIFont.systemFont(ofSize: chipHeight * 0.55, weight: .bold),
                .foregroundColor: UIColor.white
            ]
        )
        let textSize = text.size()
        let chipWidth = textSize.width + padding * 2
        let chipRect = CGRect(
            x: renderSize.width - chipWidth - inset,
            y: renderSize.height - chipHeight - inset,
            width: chipWidth,
            height: chipHeight
        )

        let chipBackground = CAShapeLayer()
        chipBackground.path = UIBezierPath(roundedRect: chipRect, cornerRadius: chipHeight / 2).cgPath
        chipBackground.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor

        let textLayer = CATextLayer()
        textLayer.frame = chipRect
        textLayer.alignmentMode = .center
        textLayer.string = text
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.fontSize = chipHeight * 0.55
        textLayer.font = UIFont.systemFont(ofSize: chipHeight * 0.55, weight: .bold)
        // UIScreen.main must be accessed on the main thread —
        // `composition(for:)` is async and may run off-main.
        let scale = await MainActor.run { UIScreen.main.scale }
        textLayer.contentsScale = scale
        textLayer.isWrapped = true

        overlay.addSublayer(chipBackground)
        overlay.addSublayer(textLayer)
        return overlay
    }
}
