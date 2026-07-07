# Timeline handles & playback — bug fixes

## Bugs found

User reported: "clip portion selection in the timeline the start and end
markers to be grabbed are too big."

Measured against the code, six issues:

### 1. Handle geometry — too big
`RangeInteractionView` in `VideoSlicer/Views/WaveformStrip.swift` had:
- Visible pill width: **18 pt**
- Hit-area padding: **9 pt each side** → total hit width **36 pt**
- Visible pill height: **38 pt** in a strip only **52 pt tall**

73% of the strip's vertical real estate went to the handles, and each
handle's 36 pt hit area overlapped the body by **27 pt** on the inside.
Result: any drag near an edge hit the handle, not the body — users
could not slide a range, only resize it.

### 2. Body was tap-only — no slide gesture
The body's only gesture was `.onTapGesture` (select). With hit areas
eating the inner edges, there was no path to grab the middle of a
range and slide it.

### 3. Two competing scrubbers
`ClipView` rendered both `WaveformStrip` AND a system `Slider`. Both
called `seekPreview(to:)`. Each scrub tick raced between the two
surfaces, and `Slider`'s binding wrote both the model state and the
player position — producing visible "skip ahead" jitter.

### 4. `VideoPlayer` brought its own native controls
`AVKit.VideoPlayer` ships a native scrubber + play/pause + AirPlay
overlay. With this on top of the custom waveform + custom play
button, the user had **three** playback controls on one preview, all
claiming to own "is this playing" / "where is the playhead."

### 5. `seekPreview(to:play:)` default was `true`
Every call site that scrubbed the waveform, tapped a thumbnail, or
tapped a transcript word passed through `seekPreview(to:)` with the
default — which started playback. The user could not scrub to a
position while paused; first drag tick would auto-play from that
point.

### 6. Racy `timeControlStatus` check on play
`if play, previewPlayer.timeControlStatus != .playing` raced against
the async `seek()` — the player may not reflect the new state in
`timeControlStatus` yet, so the play flag was toggled optimistically,
producing intermittent skips.

## Fixes shipped

### `WaveformStrip.swift` — smaller, edge-only handles
- Visible pill: **18 → 8 pt wide**, **38 → 24 pt tall**
- Hit padding: split into **12 pt outside the range** (where there
  is nothing else to grab) and **6 pt inside** (small enough that
  finger drags near the middle hit the body's slide gesture)
- `minWidthForHandles`: **36 → 50** (handles don't show on
  sub-second ranges)
- New `bodyDrag(width:)` gesture on the body — `.gesture` with
  `DragGesture(minimumDistance: 0)` that calls `onUpdateRange?` with
  the proposed range, clamped to the source bounds. Slides whole
  range, no resize.

### `ClipView.swift` — single canonical scrub, idempotent playback
- `WaveformStrip` is now the **only** scrubber. The system `Slider`
  was removed. `scrubBinding` became unused and was deleted.
- `seekPreview(to:)` default flipped from `play: true` to
  `play: false`. Waveform scrub, thumbnail tap, transcript word tap
  all reposition the playhead without auto-starting playback. The
  play button is the only path that calls `seekPreview(to:play:true)`.
- `seekPreview` no longer races on `timeControlStatus`: just call
  `play()` (idempotent when already playing) or `pause()` based on
  the requested intent. No `timeControlStatus` check.

### New file: `Views/PreviewVideoView.swift`
- Controls-free `AVPlayerLayer` host (a `UIViewRepresentable` that
  exposes `AVPlayerLayer` instead of `AVKit.VideoPlayer`).
- No native scrubber, no native play/pause, no AirPlay overlay.
- Replaces `VideoPlayer(player:)` in `ClipView.swift:videoPreview`.

### `VideoSlicer.xcodeproj/project.pbxproj`
- Registered `PreviewVideoView.swift` in:
  1. `PBXBuildFile`
  2. `PBXFileReference`
  3. The `VideoSlicer` file group
  4. The Sources build phase

## Verification
- `xcodebuild build` → **BUILD SUCCEEDED**
- `xcodebuild test` → pre-existing test-target compile errors on
  `main` (missing `CoreMLHighlightScorer`, `HighlightAnalyzer`,
  `EditIntentPlanner`, etc.). These are NOT introduced by this
  patch — same failures occur with the changes stashed. Out of
  scope to fix here.

## Behavior after the fix
- Scrubbing the waveform pauses (or stays paused) and moves the
  playhead. Press play to start; press again to pause.
- Tap a thumbnail or transcript word → seek to that point, no
  playback change.
- Drag a range by its body → slide whole range; snap to frame.
- Drag an edge handle → trim that edge; smaller handles mean
  precise control.
- `Slider` is gone — one scrub surface, one source of truth.
- VideoPlayer's native overlay is gone — no double-controls.