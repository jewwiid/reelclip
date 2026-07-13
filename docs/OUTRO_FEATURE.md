# Outro Feature

The animated 3-second outro replaces the old corner-pill "Made with ReelClip"
watermark. It is the **only** watermark on Free-tier exports. Creator-tier
exports are completely clean — no outro, no overlay, no branding of any kind.

## What users see

| Tier      | Outro appended | Corner pill | Final clip           |
|-----------|----------------|-------------|----------------------|
| Free      | Yes (3 s)      | No          | `[clip][outro]`      |
| Creator   | No             | No          | `[clip]`             |

## What the outro renders

A 3-second animated bumper composited onto a solid black background. It uses
the transparent ReelClip icon mark with the caption "Cut with ReelClip" below
it. There is no headline, handle, app-icon tile, or other overlay:

| Time          | Element                                            |
|---------------|----------------------------------------------------|
| 0.00 – 0.40 s | Icon mark scales 0.72 → 1.0; mark + caption fade in |
| 0.40 – 2.70 s | Centred icon-mark and caption lockup holds          |
| 2.70 – 3.00 s | Whole group fades out                              |

Logo: `LogoMark` from the asset catalog. It is the transparent icon artwork
used by the launch screen. There is deliberately no app-icon fallback because
the app icon includes a square background.

Render size + frame duration are derived from the source clip's video track so
the outro matches whatever the user picked for export resolution and frame
rate — no letterboxing, no resampling.

## Architecture

### Files

| File                                         | Status   | Purpose                                  |
|----------------------------------------------|----------|------------------------------------------|
| `VideoSlicer/OutroRenderer.swift`            | NEW      | Builds outro composition + animation     |
| `VideoSlicer/VideoSegmenter.swift`           | modified | Integration + tier gating               |
| `VideoSlicer/WatermarkRenderer.swift`        | DELETED  | Old corner-pill renderer                 |
| `VideoSlicerTests/VideoSegmenterTests.swift` | modified | 6 new tests for outro behaviour          |
| `VideoSlicer.xcodeproj/project.pbxproj`      | modified | Adds OutroRenderer.swift, removes WR     |
| `docs/OUTRO_FEATURE.md`                      | NEW      | This doc                                 |

### Render path

`OutroRenderer.composition(renderSize:frameDuration:)` returns a tuple of:

1. An `AVMutableComposition` containing a 3-second H.264 black-background
   video track with a real frame sequence, which avoids unreliable single-frame
   stretching across export presets.
2. A matching `AVMutableVideoComposition` with a `CoreAnimationTool` that
   composites the centred icon-mark and caption layers on top of those frames.

`VideoSegmenter.appendOutro(to:in:index:)` then:

1. Reads the segment's video track geometry (`naturalSize`, `preferredTransform`,
   `nominalFrameRate` — clamped to `[1, 240]` fps, fallback 30 fps).
2. Computes the oriented render size from `naturalSize.applying(transform)`.
3. Calls `OutroRenderer.composition(...)` for the matching render size + fps.
4. Builds a fresh `AVMutableComposition` with:
   - segment video track at `[0, segmentDuration]` (preserves `preferredTransform`)
   - outro video track at `[segmentDuration, segmentDuration + 3s]`
   - segment audio track at `[0, segmentDuration]` (outro is silent)
5. Builds an `AVMutableVideoComposition` with two instructions
   (segment range + outro range) and copies the outro's `animationTool` across.
6. Exports via `AVAssetExportSession(presetName: AVAssetExportPresetHighestQuality)`
   to `<base>-with-outro.mp4` next to the original.
7. Deletes the intermediate segment file (its content is fully contained in the
   outroed file).

`VideoSegmenter.shouldAppendOutro(forTier:)` is the single source of truth for
the tier gate — centralised so flipping the policy later is one place to change.

`segmentVideo(...)` calls `appendOutro(...)` after `exportSegment(...)` when
the gate returns `true`. If `appendOutro` throws or returns `nil`, the original
segment URL is used unchanged — losing the outro is better than failing the
whole export.

## Tests

Added to `VideoSegmenterTests`:

- `testOutroDurationConstantIsThreeSeconds` — sanity check on `OutroRenderer.duration`
- `testOutroBrandLockupIsCenteredForPortraitAndLandscapeExports` — the icon + caption stay centred
- `testOutroOverlayContainsIconAndTaglineLayers` — the icon asset and exact caption both load
- `testOutroCompositionHasThreeSecondDuration` — composition reports 3 s
- `testShouldAppendOutroIsTrueForFreeTier` — gate returns `true` for `.free`
- `testShouldAppendOutroIsFalseForCreatorTier` — gate returns `false` for `.creator`
- `testFreeTierExportAppendsOutroToClip` — 1 s source → ~4 s output
- `testCreatorTierExportHasNoOutro` — 1 s source → ~1 s output

## Tier-mapping rationale

- **Free**: the outro is the entire branding surface. Showing both a corner
 pill and a 3-second outro would be redundant. The centred icon mark and caption keep the
  branding clear without covering the user's footage.
- **Creator**: paid users paid to remove watermarks. Layering *any* branding
  on their clips breaks the contract. Clean export is the deliverable.

## Known issues / future work

- **No opt-in for creator tier.** If a creator wants an outro on their clips,
  there's no project setting to enable it. Easy follow-up: add
  `MediaProject.appendOutro: Bool` defaulting to `false` for creator.
- **No template picker.** The outro is hard-coded to one design. If we want
  multiple styles, `OutroRenderer` needs to take a `template: OutroTemplate`
  parameter and the cache dir key needs to encode the template.
- **Logo asset coupling.** If `LogoMark` is renamed or removed, the outro stays
  black rather than falling back to a square app icon. `loadLogoImage()` is the
  single extension point for swapping the mark.
- **Caches dir growth.** Each outro render writes a ~2 KB black-frame MOV to
  the caches dir. iOS reaps these automatically, but a long export run
  leaves dozens of them. Acceptable; flagged here so it's not a surprise.
