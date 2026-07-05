# VideoSlicer

VideoSlicer is a SwiftUI iOS app for creators who need quick source clips for Reels, TikTok, Shorts, and later editing workflows. It imports a video from Photos or the Files picker, auto-cuts or splices creator-friendly clips, and saves the generated clips back to the user's photo library.

It includes four cut modes:

- Fixed: deterministic equal-length clip splitting.
- Smart Pause: on-device audio energy analysis that cuts around quiet pauses, then falls back to fixed intervals.
- Highlight: on-device frame scoring using AVFoundation and Vision signals, with a prompt field that maps creator intent into a simple edit plan.
- AI Assist: sends a compact timeline feature pack to MiniMax M3 using the user's API key, then validates the returned clip plan before export.

The user flow is intentionally beta-safe:

1. Choose a source video.
2. Pick a cut mode and settings.
3. Analyze cuts.
4. Review the planned clip ranges with thumbnails, waveform, and frame-snapped trim handles.
5. Export and save the reviewed clips to Photos.

This prevents the app from writing generated clips to Photos before the creator sees the proposed cut plan.

The current safety guard rejects source videos longer than 30 minutes and rejects plans with more than 180 clips. These limits protect the beta build from trying to thumbnail, analyze, or export an unbounded source on-device.

Export notifications are local-only. The app asks for notification permission when export activity makes it useful, then sends a completion notification after clips are saved to Photos or a failure notification if export stops with an error. There is no remote push service.

Export/save also starts a bounded iOS background task. This gives the app extra time if the user switches apps, but it is not an unlimited background renderer; if iOS expires the allowance, VideoSlicer cancels the export instead of continuing in an unsafe state.

## Requirements

- Xcode 16.3 or later
- iOS 17.0 or later
- iPhone and iPad are both targeted by the app target.

This workspace currently has Xcode 16.3 and the iOS 18.4 SDK installed. Apple documents Xcode 27 beta and iOS/iPadOS 27 SDK availability, but iOS 27 compatibility cannot be proven from this machine until the project is built and tested with that SDK/runtime.

## Run

Open `VideoSlicer.xcodeproj` in Xcode, choose an iPhone simulator or device, and run the `VideoSlicer` scheme.

The app can be built from the command line with:

```sh
xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -sdk iphonesimulator -configuration Debug build
```

## Verify

Run the automated splice tests with:

```sh
xcodebuild test -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' -only-testing:VideoSlicerTests/VideoSegmenterTests
```

The tests generate short videos at runtime, pass them through the real `VideoSegmenter` export path, and assert:

- imported source files are copied into the app media workspace
- export folders are unique and workspace-scoped
- stored media size can be measured
- cleanup only removes clip folders inside the app workspace
- thumbnail sample times stay within source duration
- thumbnails can be generated from real test video frames
- planned range boundaries snap to source frame timing
- planned range handles preserve a valid minimum duration
- planned clips can be reordered without changing their timings
- waveform samples are normalized and can be read from real audio
- exact multiples do not create empty trailing clips
- non-exact durations create a final remainder clip
- invalid or out-of-bounds ranges are clamped or removed before export
- Smart Pause uses silence windows as cut points
- Smart Pause enforces maximum clip duration when there are no quiet pauses
- Smart Pause falls back to fixed ranges when the source video has no audio track
- Highlight selects top-scoring non-overlapping clip ranges
- creator prompts such as fast reel requests map into edit intent
- overlong source videos are rejected before analysis/export
- oversized clip plans are rejected before export
- MiniMax clip-plan JSON is parsed from strict and fenced responses
- MiniMax requests include bearer authentication and return validated ranges
- MiniMax API error messages are surfaced to the user
- the optional live MiniMax test can run with `MINIMAX_API_KEY`
- exported clip files exist and have the expected playable duration
- invalid segment lengths are rejected before export starts

Photo library permission prompts and saving into the user's Photos library should still be manually checked on a simulator or physical device, because that flow depends on iOS privacy state.

Additional checks run during this pass:

```sh
xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.4' -configuration Debug build
xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'generic/platform=iOS' -configuration Release build CODE_SIGNING_ALLOWED=NO
xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -configuration Release -destination 'generic/platform=iOS' archive -archivePath /tmp/VideoSlicer.xcarchive CODE_SIGNING_ALLOWED=NO
```

For TestFlight preparation and real-device coverage, use `TESTFLIGHT_CHECKLIST.md`.

## Implementation

- `PhotosPicker` imports videos from the user's library.
- SwiftUI `fileImporter` imports movies from Files, including connected drives exposed through the Files app.
- `MediaWorkspace` manages app-owned media folders under Application Support.
- Imported source videos are copied into `VideoSlicer/Imports` so they do not depend on temporary transfer URLs.
- Exported clips are written to scoped folders under `VideoSlicer/Exports`.
- `MediaPreviewGenerator` creates thumbnail strips with `AVAssetImageGenerator`.
- `WaveformAnalyzer` creates normalized audio waveform samples with `AVAssetReader`.
- The source preview uses a reusable `AVPlayer`; thumbnail taps and the scrub slider seek the preview player.
- Planned clip ranges visually mark matching thumbnail times in the preview strip.
- Planned clips support direct trim-handle dragging, timeline zoom, and reorder buttons. This is intentionally limited to preparation of export ranges, not a multi-track editor.
- `AVURLAsset` reads video duration.
- `AVAssetReader` analyzes audio energy for Smart Pause cuts.
- `AVAssetImageGenerator` samples video frames for Highlight scoring.
- `Vision` detects faces as one highlight signal.
- `CoreMLHighlightScorer` optionally uses a bundled `HighlightScorer.mlmodelc` model for highlight scoring.
- `CredentialStore` saves the MiniMax API key in the iOS Keychain.
- `MiniMaxEditPlanner` calls the OpenAI-compatible MiniMax chat completions endpoint with model `MiniMax-M3`.
- AI Assist sends timeline metadata, waveform-derived energy points, fallback ranges, and the prompt. It does not upload the source video file.
- `MediaProcessingLimits` enforces the current 30 minute source duration cap and 180 planned clip cap before expensive processing.
- `ExportNotificationManager` handles local export completion/failure notifications and foreground notification presentation.
- `ExportBackgroundTaskManager` wraps export/save in a bounded iOS background task so app switching is handled cleanly.
- `AVAssetExportSession` exports each clip using a `CMTimeRange`.
- `PHPhotoLibrary` and `PHAssetCreationRequest` save clips back to Photos.
- Analysis and export tasks can be cancelled from the UI. Long-running analyzers check cancellation between work units.
- Planned ranges are normalized against the source duration before export starts.
- `AVAssetExportSession` is actively cancelled when the export task is cancelled.
- Export files are removed from the app workspace after successful Photos saves.
- A real 1024x1024 app icon is included in the asset catalog.
- The current build declares `ITSAppUsesNonExemptEncryption` as `false` because the app does not implement custom encryption or network crypto.

The app supports fixed-length splitting in seconds. A selected video with a 95 second duration and a 30 second segment length will output four clips: 0-30, 30-60, 60-90, and 90-95 seconds.

Smart Pause and Highlight are not full CapCut Auto Cut clones. See `SOURCES.md` for the source-backed feature map and future Apple API options.

## MiniMax AI Assist

AI Assist requires a MiniMax API key. In the app, choose AI Assist, paste the key into the MiniMax panel, and save it. The key is stored in Keychain and is not written into the project files.

The live API test is intentionally opt-in:

```sh
MINIMAX_API_KEY='your-key' xcodebuild test -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' -only-testing:VideoSlicerTests/VideoSegmenterTests/testMiniMaxPlannerWithRealAPIKeyWhenAvailable
```

## Optional Core ML Model

To enable custom Core ML highlight scoring, add `HighlightScorer.mlmodel` to the app target. The model should accept:

- `brightnessScore`
- `sharpnessScore`
- `faceScore`
- `motionScore`
- `handcraftedScore`

It should output one score named `highlightScore`, `score`, or `output` in the `0.0...1.0` range. If the model is missing, the app automatically uses its built-in Vision/AVFoundation scoring.
