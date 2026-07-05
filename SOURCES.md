# Source-Backed Auto Cut Plan

VideoSlicer is aimed at creators who want quick clips for Reels, TikTok, Shorts, and downstream editing. It now includes three cut modes:

- Fixed: equal-length segment export.
- Smart Pause: on-device audio energy analysis that cuts around quiet pauses, then falls back to fixed intervals.
- Highlight: on-device frame scoring for creator-friendly moments using AVFoundation frame sampling, Vision face detection, frame brightness, sharpness, and rough motion signals.

This is not a full CapCut Auto Cut clone. CapCut-style Auto Cut combines multiple systems: audio analysis, speech analysis, visual ranking, prompt interpretation, sequencing, transitions, captions, and export. The current implementation adds the first source-backed layer.

## Apple APIs Used Now

- AVFoundation: reads media duration, decodes audio samples, and exports clip ranges.
  https://developer.apple.com/av-foundation/
- AVAssetExportSession: exports selected time ranges from the source video.
  https://developer.apple.com/documentation/avfoundation/avassetexportsession
- AVAssetImageGenerator: samples video frames for highlight scoring.
  https://developer.apple.com/documentation/avfoundation/avassetimagegenerator
- Vision: detects faces as one on-device visual highlight signal.
  https://developer.apple.com/documentation/vision
- PhotosPicker: imports video from the user's photo library.
  https://developer.apple.com/documentation/photosui/photospicker
- PhotoKit: saves generated video clips back to Photos.
  https://developer.apple.com/documentation/Photos

## Apple APIs To Use For Deeper Auto Cut

- Core ML: run custom on-device models for highlight scoring, shot classification, or quality scoring.
  https://developer.apple.com/documentation/coreml
- Sound Analysis: classify audio events with built-in or custom classifiers.
  https://developer.apple.com/documentation/soundanalysis/
- Speech / SpeechAnalyzer: transcribe and analyze spoken audio.
  https://developer.apple.com/documentation/speech/
  https://developer.apple.com/documentation/speech/speechanalyzer
- Vision: run frame-level visual analysis, optionally with Core ML models.
  https://developer.apple.com/documentation/vision
- Foundation Models: use on-device Apple Intelligence language models for prompt-to-edit-plan features on supported OS versions.
  https://developer.apple.com/documentation/foundationmodels/

## Current Prompt Handling

The current `EditIntentPlanner` is a deterministic prompt parser, not a Foundation Models integration. It recognizes common creator instructions such as "fast", "reel", "TikTok", "15 seconds", "cinematic", and "face/person" and maps them into local settings for Highlight mode.

Foundation Models should replace or augment that parser behind SDK and OS availability checks once the project is built with an SDK that includes the framework.

## Core ML Model Contract

The app now includes a Core ML runtime bridge in `CoreMLHighlightScorer`. To activate model-backed highlight scoring, add a Core ML model named `HighlightScorer.mlmodel` to the app target. Xcode will compile it into `HighlightScorer.mlmodelc` in the app bundle.

Expected numeric inputs:

- `brightnessScore`
- `sharpnessScore`
- `faceScore`
- `motionScore`
- `handcraftedScore`

Supported numeric output names:

- `highlightScore`
- `score`
- `output`

The output should be a value from `0.0` to `1.0`, where higher means the frame is more likely to be useful in a Reel/TikTok clip. If the model is absent or prediction fails, the app falls back to the handcrafted Vision/AVFoundation score.

Apple source basis:

- Core ML model files use the `.mlmodel` format, and Xcode compiles them into optimized app resources.
  https://developer.apple.com/documentation/coreml/getting-a-core-ml-model
  https://developer.apple.com/documentation/coreml/integrating-a-core-ml-model-into-your-app
- `MLModel.prediction(from:)` runs predictions using an input feature provider.
  https://developer.apple.com/documentation/coreml/mlmodel/prediction%28from%3A%29-9y2aa

## Foundation Models Upgrade Path

This workspace is currently building with Xcode 16.3 and the iOS 18.4 simulator SDK. `FoundationModels` is not available in that SDK, so it cannot be compiled here.

When building with a supported SDK, replace or augment `EditIntentPlanner` with a Foundation Models-backed planner that generates a structured `CreatorEditIntent`. Apple documents `FoundationModels`, `LanguageModelSession`, `SystemLanguageModel`, `Generable`, and guided generation for structured output:

- https://developer.apple.com/documentation/foundationmodels/
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- https://developer.apple.com/documentation/FoundationModels/Generable

The app already has a readiness check in `AIFeatureReadiness.foundationModelsFrameworkAvailable` so future code can avoid showing Foundation Models features when the framework is unavailable.

## Version Note

The app still targets iOS 17 for broad compatibility. Foundation Models and newer Apple Intelligence APIs should be added behind availability checks because Apple's documentation lists newer OS availability for those APIs. The current Smart Pause mode avoids that dependency and runs fully on-device with AVFoundation.

Apple's developer documentation currently lists Xcode 27 beta release notes and iOS/iPadOS 27 beta release notes, including iOS 27 and iPadOS 27 SDK references. This local workspace is still on Xcode 16.3 with the iOS 18.4 SDK, so the app can be written in a forward-compatible way here but cannot be certified as iOS 27-compatible until it is rebuilt and tested with Xcode 27 and iOS/iPadOS 27 simulator or device runtimes.

Relevant Apple documentation:

- Xcode 27 beta release notes:
  https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- iOS & iPadOS 27 beta release notes:
  https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
- Foundation Models updates:
  https://developer.apple.com/documentation/updates/foundationmodels
