# ReelClip Research Roadmap

Updated 2026-07-10.

This document separates work that is safe to ship in the current local-first
architecture from work that needs a larger product or data-model decision.

## Shipped in the current architecture

- AI planning uses Apple Intelligence only. There is no cloud AI provider,
  BYOK credential flow, or entitlement mirror in the app target.
- Transcription requires on-device speech recognition. The app does not fall
  back to server recognition when on-device recognition is unavailable.
- StoreKit entitlements are read locally from verified transactions. StoreKit
  still communicates with Apple for product and purchase state, but ReelClip
  does not send purchase or editing data to its own service.
- The unused Whisper experiment and local package are not linked into the app
  target. Production transcription remains the Apple on-device path.
- Imported media, project files, derived thumbnails, waveform data, and export
  files remain in the app's local container or the user's Photos library.
- Free AI usage is persisted locally by calendar month, so closing and
  reopening the app does not reset the allowance.
- Multi-scene planning, per-mode planned ranges, project-wide export ordering,
  local export cleanup, and export preview deletion are implemented.

## High-impact work that is safe to do next

These should be implemented incrementally without adding accounts, analytics,
cloud storage, or video uploads:

1. **Template-ready export presets**
   Add explicit vertical 9:16, square 1:1, and landscape 16:9 presets with
   crop/fit behavior, named export metadata, and a preview of effective output
   dimensions. Keep the existing source-quality and frame-rate controls. This
   must be implemented in the exporter rather than as UI-only labels.

2. **Local beat markers**
   Use the existing waveform/audio reader to calculate transient markers on
   device, cache them with the derived media artifacts, and expose them as
   optional snap points for Highlight and Fixed planning. Do not upload audio.
   The first version should be advisory; it should not silently alter ranges.

3. **Export-plan integrity tests**
   Add fixture tests covering per-scene/per-mode ownership, shuffled order,
   deleted preview clips, missing source scenes, and filename uniqueness.
   These are high-value regression tests for the app's most important data
   contract and do not require user data or network access.

## Deferred until the prerequisites exist

### Vision analysis: scene, face, pose, and OCR

Deferred because it needs a clear user-facing action and review UI. The
implementation should be an opt-in local analyzer with bounded frame sampling,
cached results, and explicit deletion of derived results. Do not add a passive
background analyzer or send frames to a server.

### Multi-source clip library

Deferred because the current scene model assumes one source per scene. A safe
version requires stable source identifiers, source replacement rules, project
file migration, and clear behavior when a source is missing. Do not add a
second source picker until those persistence rules are defined.

### CapCut project export

Deferred because `.capcut` is a third-party project format, not a generic video
export. First define a supported interchange contract and verify that the
format can be generated without private APIs or unsupported reverse
engineering. Until then, clean MP4 export plus the `.reelclip` project file is
the supported handoff.

### Resumable/background exports

Deferred because iOS background execution is time-limited. A real resumable
export needs persisted checkpoints, atomic output finalization, stale-job
cleanup, cancellation recovery, and a user-visible resume state. The current
sequential export is intentionally bounded and cleans partial output on
failure.

### Cloud sync, accounts, analytics, and remote entitlement services

Not planned for the current privacy promise. Do not add them unless the product
direction changes and the user explicitly accepts data collection, disclosures,
retention rules, and a new privacy review.

### Whisper model transcription

Deferred as an optional future local runtime. The current target deliberately
does not link the experimental Whisper package or model downloader. Revisit
only if Apple on-device speech recognition coverage is insufficient and the
model size, first-run download UX, storage policy, and licensing are accepted.

## App Store Connect privacy note

The current app target declares no developer-collected data in
`VideoSlicer/PrivacyInfo.xcprivacy`. App Store Connect declarations still need
to be completed manually and must distinguish Apple's StoreKit processing from
data collected by ReelClip. The declarations should match the shipped target,
not the historical cloud-provider proposal in `docs/paywall-design.md`.
