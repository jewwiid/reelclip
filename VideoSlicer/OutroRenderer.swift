@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Composes a 3-second animated outro that is appended to the end of every
/// exported clip. The outro renders the transparent ReelClip icon mark,
/// centred on a solid background, with a fade-scale-in entrance and a brief
/// fade-out exit.
///
/// The renderer produces an `AVMutableComposition` (one black-background
/// video track, exactly `OutroRenderer.duration` long) plus the matching
/// `AVMutableVideoComposition` that drives the Core Animation timeline.
/// The segmenter is responsible for inserting the outro composition *after*
/// the user clip's source track so `AVAssetExportSession` writes
/// `[clip][outro]` into the final MP4.
///
/// Render size and frame rate mirror whatever the user picked for the
/// export, so a `source`-resolution clip gets a 4K outro and a `720p` clip
/// gets a 1280x720 outro — the outro never re-encodes to a different size
/// than the clip it sits next to.
enum OutroRenderer {

    /// Total outro length. Three seconds keeps the brand mark readable without
    /// adding a long tail to short-form exports.
    static let duration: CMTime = CMTime(seconds: 3, preferredTimescale: 600)

    /// Async factory. Writes a tiny black-frame MOV to the caches dir, then
    /// returns the outro composition + matching video composition with the
    /// Core Animation overlay tool attached.
    ///
    /// - Parameters:
    ///   - renderSize: Pixel dimensions of the exported clip. The outro will
    ///     render at exactly these dimensions so the visual size matches
    ///     the rest of the clip with no letterboxing.
    ///   - frameDuration: Time per frame for the outro. The segmenter passes
    ///     `ExportSettings.frameRate.frameDuration` here. Falls back to 30
    ///     fps when the caller asked for `source` so the outro has a
    ///     well-defined time-base.
    static func composition(
        renderSize: CGSize,
        frameDuration: CMTime,
        overlayStartTime: CMTime = .zero
    ) async -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition)? {
        guard
            renderSize.width > 0, renderSize.height > 0,
            renderSize.width.isFinite, renderSize.height.isFinite
        else { return nil }

        // 1. Black-background video track. We need a real video track in the
        //    outro composition because AVAssetExportSession will only render
        //    Core Animation overlays on top of frames that the composition
        //    actually produces. A solid-colour video track gives us those
        //    frames for free.
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { return nil }

        let backgroundURL = await Self.writeBlackBackgroundMOV(
            size: renderSize,
            frameDuration: frameDuration
        )
        guard let backgroundURL else { return nil }

        let backgroundAsset = AVURLAsset(url: backgroundURL)
        let backgroundTracks: [AVAssetTrack]
        do {
            backgroundTracks = try await backgroundAsset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard let backgroundTrack = backgroundTracks.first else { return nil }

        do {
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: backgroundTrack,
                at: .zero
            )
        } catch {
            return nil
        }

        // 2. Video composition with the Core Animation tool attached. The
        //    animation tool composites the layer tree on top of the
        //    black-background track's frames for the entire outro window.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        // UIScreen.main is main-actor-only — capture the scale here so the
        // sync overlay builder doesn't need to hop actors.
        let scale = await MainActor.run { UIScreen.main.scale }
        let overlayLayer = makeOverlayLayer(
            for: renderSize,
            contentsScale: scale,
            overlayStartTime: overlayStartTime
        )
        parentLayer.addSublayer(overlayLayer)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: videoTrack
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
    }

    // MARK: - Black background track

    /// Write a real three-second H.264 MOV to the caches dir. The explicit
    /// frame sequence gives the composition a genuine three-second track;
    /// inserting one frame and asking AVFoundation to stretch it is not
    /// reliable across export presets.
    private static func writeBlackBackgroundMOV(
        size: CGSize,
        frameDuration: CMTime
    ) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            return writeBlackBackgroundMOVSync(size: size, frameDuration: frameDuration)
        }.value
    }

    private static func writeBlackBackgroundMOVSync(
        size: CGSize,
        frameDuration: CMTime
    ) -> URL? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = cacheDir.appendingPathComponent("reelclip-outro-bg-\(UUID().uuidString).mov")

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return nil
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width.rounded()),
                AVVideoHeightKey: Int(size.height.rounded())
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width.rounded()),
                kCVPixelBufferHeightKey as String: Int(size.height.rounded())
            ]
        )

        guard writer.startWriting() else {
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        let frameSeconds = CMTimeGetSeconds(frameDuration)
        guard frameSeconds.isFinite, frameSeconds > 0 else {
            writer.cancelWriting()
            return nil
        }
        let frameCount = max(1, Int(ceil(CMTimeGetSeconds(duration) / frameSeconds)))

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || writer.status == .cancelled {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.001)
            }

            guard let pixelBuffer = makeBlackPixelBuffer(adaptor: adaptor),
                  adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTimeMultiply(
                        frameDuration,
                        multiplier: Int32(frameIndex)
                    )
                  ) else {
                writer.cancelWriting()
                return nil
            }
        }
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            return nil
        }
        return url
    }

    private static func makeBlackPixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // 32BGRA = 4 bytes per pixel. Zero-fill = solid black.
        memset(base, 0, bytesPerRow * height)
        return buffer
    }

    // MARK: - Overlay layer

    /// Build the centred icon-mark layer and attach the animation timeline.
    /// The mark fades and scales in over 0.4 seconds, holds, then fades out
    /// over the final 0.3 seconds.
    static func makeOverlayLayer(
        for renderSize: CGSize,
        contentsScale: CGFloat,
        overlayStartTime: CMTime
    ) -> CALayer {
        let group = CALayer()
        group.frame = CGRect(origin: .zero, size: renderSize)
        let overlayOffset = max(0, CMTimeGetSeconds(overlayStartTime))

        let logoImage = loadLogoImage()
        let logoLayer = CALayer()
        logoLayer.frame = markFrame(
            in: renderSize,
            imageSize: logoImage?.size ?? CGSize(width: 834, height: 1024)
        )
        logoLayer.contents = logoImage?.cgImage
        logoLayer.contentsGravity = .resizeAspect
        logoLayer.contentsScale = contentsScale
        logoLayer.opacity = 0
        logoLayer.transform = CATransform3DMakeScale(0.72, 0.72, 1)

        group.addSublayer(logoLayer)

        addOpacityAnimation(
            to: logoLayer,
            from: 0, to: 1,
            startSeconds: overlayOffset, durationSeconds: 0.4
        )
        addScaleAnimation(
            to: logoLayer,
            from: 0.72, to: 1.0,
            startSeconds: overlayOffset, durationSeconds: 0.4
        )
        addOpacityAnimation(
            to: group,
            from: 1, to: 0,
            startSeconds: overlayOffset + 2.7, durationSeconds: 0.3
        )

        return group
    }

    static func markFrame(in renderSize: CGSize, imageSize: CGSize) -> CGRect {
        guard
            renderSize.width > 0,
            renderSize.height > 0,
            imageSize.width > 0,
            imageSize.height > 0
        else { return .zero }

        let maximumDimension = min(renderSize.width, renderSize.height) * 0.34
        let aspectRatio = imageSize.width / imageSize.height
        let markSize: CGSize
        if aspectRatio <= 1 {
            markSize = CGSize(width: maximumDimension * aspectRatio, height: maximumDimension)
        } else {
            markSize = CGSize(width: maximumDimension, height: maximumDimension / aspectRatio)
        }

        return CGRect(
            x: (renderSize.width - markSize.width) / 2,
            y: (renderSize.height - markSize.height) / 2,
            width: markSize.width,
            height: markSize.height
        )
    }

    private static func addOpacityAnimation(
        to layer: CALayer,
        from: Float,
        to: Float,
        startSeconds: CFTimeInterval,
        durationSeconds: CFTimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + startSeconds
        animation.duration = durationSeconds
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "outro-opacity-\(startSeconds)")
    }

    private static func addScaleAnimation(
        to layer: CALayer,
        from: CGFloat,
        to: CGFloat,
        startSeconds: CFTimeInterval,
        durationSeconds: CFTimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + startSeconds
        animation.duration = durationSeconds
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "outro-scale-\(startSeconds)")
    }

    /// Load the transparent icon mark directly from the asset catalog. Do not
    /// fall back to the app icon because that would reintroduce its square
    /// background into exported video.
    private static func loadLogoImage() -> UIImage? {
        UIImage(named: "LogoMark")
    }
}
