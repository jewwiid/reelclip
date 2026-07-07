import AVFoundation
import SwiftUI
import UIKit

/// Controls-free AVPlayer render.
///
/// `AVKit.VideoPlayer` ships with its own native scrubber + play/pause +
/// AirPlay controls. ReelClip drives playback itself (one play button,
/// one waveform scrubber) and reusing `VideoPlayer` produced two scrubbing
/// surfaces that fought each other and a half-second long-press menu the
/// user never wanted.
///
/// This wrapper hosts an `AVPlayerLayer` directly — no controls, no menu,
/// no draggable scrubber. The waveform above the preview owns all
/// scrubbing semantics, and `ClipView.togglePreviewPlayback()` is the
/// only path that starts/stops playback.
struct PreviewVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// UIView backed by an `AVPlayerLayer` so we can host AVFoundation's
    /// rendering pipeline directly without any AVKit chrome.
    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}