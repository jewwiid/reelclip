@preconcurrency import AVFoundation
import Foundation
import UIKit
import CoreImage

/// Composes a 3-second animated outro that is appended to the end of every
/// exported clip. The outro renders a centred logo + brand line + handle on
/// a solid background, with a fade-scale-in entrance and a brief fade-out
/// exit.
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

    /// Total outro length. 3 seconds is the sweet spot for Reels / TikTok /
    /// Shorts: long enough for the logo + handle to read, short enough that
    /// viewers don't bounce before the clip's CTA beat.
    static let duration: CMTime = CMTime(seconds: 3, preferredTimescale: 600)

    /// Headline text on the outro. Single source of truth so unit tests can
    /// assert against the same string the UI renders.
    static let headlineText = "Made with ReelClip"

    /// Secondary handle line. Sized smaller than the headline.
    static let handleText = "@reelclip"

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

    /// Build the centred logo + headline + handle layer tree and attach the
    /// animation timeline. Animation timing (all relative to t=0):
    ///
    /// - 0.00–0.40 s : logo opacity 0→1 + scale 0.6→1.0 (ease-out)
    /// - 0.40–0.80 s : headline opacity 0→1 (ease-in)
    /// - 0.80–1.10 s : handle opacity 0→1 (ease-in)
    /// - 1.10–2.70 s : static hold (no animations firing)
    /// - 2.70–3.00 s : whole outro group opacity 1→0 (ease-out)
    private static func makeOverlayLayer(
        for renderSize: CGSize,
        contentsScale: CGFloat,
        overlayStartTime: CMTime
    ) -> CALayer {
        let group = CALayer()
        group.frame = CGRect(origin: .zero, size: renderSize)
        let overlayOffset = max(0, CMTimeGetSeconds(overlayStartTime))

        // --- Logo ---------------------------------------------------------
        // The logo is loaded from the bundle. If the asset is missing the
        // logo layer renders empty — the text layers still appear so the
        // outro is never blank. (Tests assert this behaviour explicitly.)
        let logoSide = min(renderSize.width, renderSize.height) * 0.22
        let logoRect = CGRect(
            x: (renderSize.width - logoSide) / 2,
            y: (renderSize.height - logoSide) / 2 - renderSize.height * 0.06,
            width: logoSide,
            height: logoSide
        )
        let logoLayer = CALayer()
        logoLayer.frame = logoRect
        logoLayer.contents = loadLogoImage()?.cgImage
        logoLayer.contentsGravity = .resizeAspect
        logoLayer.contentsScale = contentsScale
        logoLayer.opacity = 0
        logoLayer.transform = CATransform3DMakeScale(0.6, 0.6, 1)

        // --- Headline -----------------------------------------------------
        let headlineHeight = renderSize.height * 0.045
        let headlineRect = CGRect(
            x: 0,
            y: logoRect.maxY + renderSize.height * 0.035,
            width: renderSize.width,
            height: headlineHeight
        )
        let headlineLayer = CATextLayer()
        headlineLayer.frame = headlineRect
        headlineLayer.alignmentMode = .center
        headlineLayer.string = NSAttributedString(
            string: headlineText,
            attributes: [
                .font: UIFont.systemFont(ofSize: headlineHeight * 0.85, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
        )
        headlineLayer.foregroundColor = UIColor.white.cgColor
        headlineLayer.fontSize = headlineHeight * 0.85
        headlineLayer.font = UIFont.systemFont(ofSize: headlineHeight * 0.85, weight: .heavy)
        headlineLayer.contentsScale = contentsScale
        headlineLayer.opacity = 0

        // --- Handle -------------------------------------------------------
        let handleHeight = renderSize.height * 0.028
        let handleRect = CGRect(
            x: 0,
            y: headlineRect.maxY + renderSize.height * 0.012,
            width: renderSize.width,
            height: handleHeight
        )
        let handleLayer = CATextLayer()
        handleLayer.frame = handleRect
        handleLayer.alignmentMode = .center
        let handleFontSize = handleHeight * 0.85
        handleLayer.string = NSAttributedString(
            string: handleText,
            attributes: [
                .font: UIFont.systemFont(ofSize: handleFontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
        )
        handleLayer.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        handleLayer.fontSize = handleFontSize
        handleLayer.font = UIFont.systemFont(ofSize: handleFontSize, weight: .semibold)
        handleLayer.contentsScale = contentsScale
        handleLayer.opacity = 0

        group.addSublayer(logoLayer)
        group.addSublayer(headlineLayer)
        group.addSublayer(handleLayer)

        // --- Animations ---------------------------------------------------
        // Logo fade + scale-in
        addOpacityAnimation(
            to: logoLayer,
            from: 0, to: 1,
            startSeconds: overlayOffset, durationSeconds: 0.4
        )
        addScaleAnimation(
            to: logoLayer,
            from: 0.6, to: 1.0,
            startSeconds: overlayOffset, durationSeconds: 0.4
        )

        // Headline fade-in
        addOpacityAnimation(
            to: headlineLayer,
            from: 0, to: 1,
            startSeconds: overlayOffset + 0.4, durationSeconds: 0.4
        )

        // Handle fade-in
        addOpacityAnimation(
            to: handleLayer,
            from: 0, to: 1,
            startSeconds: overlayOffset + 0.8, durationSeconds: 0.3
        )

        // Group fade-out at the end. Animates from 1 → 0 on the parent so
        // the entire outro dissolves cleanly into the end of the timeline.
        addOpacityAnimation(
            to: group,
            from: 1, to: 0,
            startSeconds: overlayOffset + 2.7, durationSeconds: 0.3
        )

        return group
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

    /// Load the bundled logo and remove the baked square artwork from the
    /// source PNG. The project icon is also used by the app shell, so it is
    /// intentionally kept unchanged on disk; the outro gets a transparent
    /// lime mark at render time instead of a white/dark tile.
    private static func loadLogoImage() -> UIImage? {
        let image: UIImage?
        if let url = Bundle.main.url(
            forResource: "ReelClipProjectIcon-320",
            withExtension: "png"
        ),
            let data = try? Data(contentsOf: url),
            let bundledImage = UIImage(data: data) {
            image = bundledImage
        } else {
            image = UIImage(named: "AppIcon")
        }
        guard let image else { return nil }
        return transparentMark(from: image)
    }

    private static func transparentMark(from image: UIImage) -> UIImage? {
        guard let source = image.cgImage else { return nil }

        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))

            // The source icon has a white outer field and a dark rounded
            // square. Both are background; the lime mark remains opaque.
            if maximum < 115 || minimum > 232 {
                pixels[index + 3] = 0
            }
        }

        guard let output = context.makeImage() else { return nil }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
}
