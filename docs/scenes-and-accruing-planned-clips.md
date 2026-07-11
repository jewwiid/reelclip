# Scenes + Accruing Planned Clips — Design Doc

**Status:** draft
**Author:** Mavis
**Target release:** post-build 54, 2–3 phases
**File under design:** `VideoSlicer/ReelClipProjectFile.swift`,
`VideoSlicer/MediaProjectStore.swift`, `VideoSlicer/VideoSplitterViewModel.swift`,
`VideoSlicer/Views/ClipView.swift`

## 0. What you asked for, restated

1. **Accruing planned clips across cut modes.** Make 2 clips in Highlight, 4
   in Fixed, all 6 should be in the same `plannedRanges` and export together.
2. **Scenes as save states within one project.** A `.reelclip` project can hold
   multiple named scenes; the user imports a clip, makes Scene 1, imports
   another clip (or continues editing the same one), makes Scene 2, etc. Each
   scene is a snapshot of the cut state — like a game-emulator save state.
3. **`.reelclip` extension stays** — but the file now contains multiple scenes
   for the same project.

## 1. What the code already does

After deep-diving `VideoSplitterViewModel.swift` and `ReelClipProjectFile.swift`:

- **`plannedRanges: [ClipRange]` already accrues across modes.** Mode changes
  (`fixedRanges()` in `cutMode == .fixed`, `smartCutAnalyzer.ranges(...)` for
  `smartPause`, `plannedRanges` pass-through for `highlight` and `aiAssist`)
  REPLACE `plannedRanges` on mode switch — but only the "regenerate from
  scratch" path. The `addHighlightDraftToPlan()` and
  `updatePlannedRange(at:to:)` paths APPEND/MUTATE without clearing. So
  "make 2 in highlight, then 4 in fixed" *does* work, but only if the user
  never taps "Plan" on the fixed-mode button (that overwrites). This is
  fragile, and the "regenerate on mode switch" is the bug.
- **`.reelclip` format already exists.** `ReelClipProjectEnvelope` +
  `ReelClipProjectFile` + `ReelClipProjectCodec` handle encode/decode with
  schema versioning (`currentSchemaVersion = 1`). Adding scenes is a
  v2 schema bump.
- **One project, one cut state.** Today `MediaProject.plannedRanges` is a
  single array. There's no concept of "this is Scene A's plan, that is Scene
  B's plan". The whole project has one set of clips.

## 2. Design

### 2.1 Data model — new `Scene` type

```swift
struct Scene: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Source video reference for THIS scene. Independent from the project's
    /// "primary" source so a scene can be based on a different clip (or a
    /// re-cut of the same clip with a different mode).
    var sourcePhotoLibraryIdentifier: String?
    var sourceOriginalFilename: String?
    /// The cut state. `plannedRanges` here is the accrue list — what the
    /// user added via "Add to plan" across highlight/fixed/ai/etc. in
    /// THIS scene.
    var cutMode: CutMode
    var segmentLengthText: String
    var editPrompt: String
    var plannedRanges: [ClipRange]
    var highlightDraftStart: Double?
    var highlightDraftDuration: Double?
    var scrubPositionSeconds: Double
    /// Per-scene edit timestamps (the save state). Display "last edited 2m ago"
    /// per scene in the picker.
    var createdAt: Date
    var updatedAt: Date
}
```

`Scene` is a self-contained cut snapshot. One project has many scenes. The
project's "currently active" state is a pointer to a scene id.

### 2.2 `MediaProject` refactor — `scenes: [Scene]` replaces flat fields

Current `MediaProject` has flat `cutMode`, `segmentLengthText`, `plannedRanges`, etc. The refactor:

```swift
struct MediaProject: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// Source of the *project as imported*. A scene can override this
    /// per-scene (see `Scene.sourcePhotoLibraryIdentifier`). This is the
    /// "default" source when the user creates a new scene.
    var sourcePath: String
    var sourceFileName: String
    var durationSeconds: Double
    var sourceAspectRatio: Double
    var frameDurationSeconds: Double
    /// All scenes in this project. Order = user-facing display order.
    var scenes: [Scene]
    /// Which scene is currently being edited. nil = no active scene (just
    /// imported, hasn't created one yet).
    var activeSceneId: UUID?
    var exportedClips: [StoredClipOutput]
    var transcript: Transcript?
    var createdAt: Date
    var updatedAt: Date
    var sourcePhotoLibraryIdentifier: String?
}
```

**Migration:** the `init(from decoder:)` reads `scenes` if present; if absent
(legacy v1 file), synthesises a single `Scene` from the flat fields:

```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // ... existing field decodes ...
    if let scenes = try c.decodeIfPresent([Scene].self, forKey: .scenes) {
        self.scenes = scenes
        self.activeSceneId = try c.decodeIfPresent(UUID.self, forKey: .activeSceneId)
    } else {
        // Legacy v1 file — wrap the flat fields into a single scene.
        let legacyScene = Scene(
            id: UUID(),
            name: "Scene 1",
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: plannedRanges,
            scrubPositionSeconds: scrubPositionSeconds,
            // ... other fields ...
        )
        self.scenes = [legacyScene]
        self.activeSceneId = legacyScene.id
    }
}
```

### 2.3 `ReelClipProjectFile` — schema v2

`currentSchemaVersion` bumps to `2`. The payload gains `scenes` and
`activeSceneId`. Flat fields stay (decode-tolerant) but are ignored on read
of v2 files; written from v1 fields only when no scenes exist.

```swift
struct ReelClipProjectFile: Codable {
    var id: UUID
    var title: String
    var durationSeconds: Double
    var sourceAspectRatio: Double
    var frameDurationSeconds: Double
    // Legacy fields — read-but-ignored on v2 files. Kept on disk so the
    // schema can be re-emitted as v1 if the project is downgraded.
    var cutModeRaw: String?
    var segmentLengthText: String?
    var editPrompt: String?
    var plannedRanges: [ClipRange]?
    var highlightDraftStart: Double?
    var highlightDraftDuration: Double?
    var scrubPositionSeconds: Double?
    // New in v2
    var scenes: [Scene]?
    var activeSceneId: UUID?

    var exportedClips: [ReelClipStoredClip]
    var createdAt: Date
    var updatedAt: Date
    var sourcePhotoLibraryIdentifier: String?
    var sourceOriginalFilename: String?
    var sourceFileSize: Int64?
}
```

### 2.4 Accruing planned clips — the real fix

**The mode-switch "regenerate" path is the bug.** Today, switching from
Highlight → Fixed (or any other mode) calls `cutMode = .fixed; plannedRanges
= try Self.fixedRanges(...)` which wipes the user's accrued highlight clips.

**Fix:** when switching modes, PRESERVE `plannedRanges` (the user's hand-built
clips) and only regenerate the auto-computed defaults on EXPLICIT user
action (tapping "Plan" on a mode button). Mode switch = "I want to add clips
in a different mode" not "I want to throw away my work".

This is a one-line policy change in `VideoSplitterViewModel.setCutMode` (or
the equivalent setter — `cutMode` is `@Published var`, so we add a `didSet`
or a `func setCutMode(_:)` and have all callers use it).

```swift
// In VideoSplitterViewModel:
@Published var cutMode: CutMode = .highlight {
    didSet {
        // No longer wipes plannedRanges. Switching modes is a tool
        // change, not a state reset. To reset, the user explicitly
        // taps "Plan" on a mode chip or "Reset to defaults".
    }
}
```

The "Plan X" mode buttons (Fixed, Smart Pause, AI Assist) become explicit
"regenerate" actions — they call `Self.fixedRanges(...)` or similar and
APPEND if the user has toggle for it, REPLACE otherwise. The toggle goes in
a new sheet or confirmation: "Replace current 6 clips with new plan?" Yes /
Append / Cancel.

### 2.5 Scene picker UI

The "Planned clips" section header becomes a **scene switcher** with a
dropdown (similar to the Xcode scheme picker):

```
┌─ Planned clips ───────────────────────────┐
│  Scene: [Scene 1 ▾]    [+ New scene]      │
│                                          │
│  6 clips · 0:35 total                    │
│  [Planned clip 1]                        │
│  [Planned clip 2]                        │
│  ...                                     │
│  [Add to plan]                           │
└──────────────────────────────────────────┘
```

- Tapping the scene name opens a menu: switch, rename, duplicate, delete.
- "+ New scene" creates a new `Scene` based on the current state (deep copy of
  `plannedRanges`, `cutMode`, etc.) — same as "Save state on emulator".
- Export is per-scene by default, with a "Combine all scenes" option in the
  export sheet.

### 2.6 Save / load UX — the "emulator save state" feel

**In-app (no file export):**

- User has N scenes visible as cards or in the picker.
- "Save" is automatic on every edit (we already auto-save to
  `MediaProjectStore`).
- "Snapshot" button creates a new scene with a copy of the current state —
  like pressing F5 in an emulator to save state.
- "Restore" picks a scene and loads it.

**File export:**

- `.reelclip` file holds all scenes for the project. Sharing a project =
  sharing all scenes.
- Recipient opens the project, sees a scene picker, can switch between
  scenes and edit any of them.
- Scenes are exportable individually (one `.reelclip` file per scene) for
  users who want to share just one cut.

## 3. UI changes (rough wireframes)

### 3.1 Cut Recipe section (currently)

```
[Mode toggle row]  ← already moved to top of Source
[Cut recipe ▾]
  [Metric tiles]
  [Mode-specific controls]
  [Reset to defaults]
[Planned clips ▾]
  [Plan 4 clips] [Reset]
  [Clip cards × 6]
[Exported clips]
```

### 3.2 After scene feature

```
[Mode toggle row]  ← same place
[Cut recipe ▾]
  [Active scene: Scene 1 ▾]   [+ Snapshot]   [↻ Reset]
  [Metric tiles]
  [Mode-specific controls]
[Planned clips ▾]
  [Filter by scene: All ▾]  or auto-shown
  [Clip cards × 6]
  (chips on each card showing which scene it belongs to)
[Exported clips]
```

The "Active scene" dropdown at the top of Cut Recipe is the killer feature —
it's where the user knows which save state they're editing.

## 4. Implementation phases

### Phase 1 — Accruing fix (1 build, ~1 hour)
- **File:** `VideoSplitterViewModel.swift`
- Remove the `plannedRanges = []` from mode-switch code paths
- Keep "Plan X clips" buttons as explicit regenerate actions (they
  currently REPLACE — make them confirm before wiping)
- Tests: switch from Highlight → Fixed without losing highlight clips
- **Risk:** low — this is mostly removing destructive code

### Phase 2 — Scene data model (1 build, ~2 hours)
- **Files:** `MediaProjectStore.swift`, `ReelClipProjectFile.swift`,
  `VideoSplitterViewModel.swift`
- Add `Scene` struct
- Refactor `MediaProject` to hold `[Scene]` + `activeSceneId`
- Migration: legacy v1 files decode to a single auto-generated scene
- Bump `currentSchemaVersion` to 2
- Codec: encode/decode scenes array, fall back to legacy on missing
- **Risk:** medium — this is a schema bump. Existing users' projects
  must continue to load.

### Phase 3 — Scene UI (1 build, ~3 hours)
- **Files:** `ClipView.swift` (cutComposer), new `ScenePickerView.swift`
- Scene switcher dropdown in Cut Recipe
- "+ New scene" / "Rename" / "Duplicate" / "Delete" actions
- "Active scene" indicator
- Per-scene metric tiles
- Per-scene planned-clips list (chips)
- **Risk:** medium — UI complexity. Need a clean picker pattern.

### Phase 4 — Save / load polish (1 build, ~1 hour)
- New "Snapshot" button (creates a new scene from current state)
- "Save state on emulator" naming convention
- Auto-save scenes to MediaProjectStore on every edit
- **Risk:** low — most of the infrastructure is in place

### Phase 5 — Export refinement (1 build, ~1 hour)
- Per-scene export (default)
- "Combine all scenes" option
- Per-scene `.reelclip` export for sharing one cut
- **Risk:** low

Total: **5 builds**, ~8 hours of work. Could be condensed to 2–3 builds if
the UI phase is light.

## 5. Risks and open questions

### Open questions for you

1. **What happens to "Planned clips" from the old flat model after the
   migration?** My proposal: all existing plannedRanges become Scene 1 named
   "Scene 1". User can rename. Alternative: name it "Imported" to mark it
   as a pre-scenes edit.

2. **Per-scene source or single project source?** My proposal: per-scene
   source. So Scene 1 can be a cut of clip A, Scene 2 of clip B. This is
   the more powerful model. Alternative: single project source, all scenes
   cut the same clip. Simpler UI but less flexible.

3. **Cross-scene clip references?** If a scene is deleted, what happens to
   exported clips that came from it? My proposal: keep exported clips
   independent of scenes. They're a "library of finished outputs", scenes
   are "save states of work in progress". This decouples them.

4. **Plan-on-mode-switch:** option (a) silently keep accrued, (b) confirm
   before wiping, (c) always show "Replace / Append / Cancel" sheet when
   Plan button is hit. I lean toward (b) — confirm before wipe. (c) is
   too much friction for the common case.

### Risks

- **Schema migration risk:** any user with an existing project on TestFlight
  needs their file to round-trip through the v2 schema. Test thoroughly
  with sample `.reelclip` files.
- **Scene delete cascade:** if a scene has exported clips, deleting the
  scene shouldn't delete the exports. Confirmed in the data model above.
- **Performance:** 10+ scenes × 100 planned ranges = 1000 ClipRange objects.
  Still small (each is ~80 bytes), but rendering 1000 timeline overlays
  could be slow. Use `LazyVStack` and `ForEach` with stable IDs.
- **The current view-model has `@Published var plannedRanges` everywhere.**
  Refactoring to `scenes[activeSceneId].plannedRanges` touches a lot of
  call sites. Plan for a search-and-replace pass over ClipView.swift,
  WaveformStrip.swift, VideoTimelineView.swift, plus the planned-clips
  cards in the list.

## 6. References consulted

- `docs/swift-ios-resources/the-swift-programming-language/TSPL.docc/LanguageGuide/Protocols.md`
  — the `Codable` protocol we lean on for `.reelclip` encode/decode, and
  the additive-field migration pattern (decodeIfPresent for new fields)
- `docs/swift-ios-resources/swift-evolution/proposals/0166-swift-archival-serialization.md`
  — the original Codable proposal (rejected, replaced by 0166 → 0295).
  Worth reading to understand the design rationale for "all the common
  stuff is free, custom stuff is `encode(to:)` + `init(from:)`"
- `docs/swift-ios-resources/swift-evolution/proposals/0306-actors.md`
  — relevant if we want to make `Scene` access thread-safe via an actor
  wrapper (probably overkill, but worth knowing the option exists)
- `docs/swift-ios-resources/resources/README.md` — Apple's
  [File-Apple-Data-The-Basics](https://developer.apple.com/documentation/foundation/file_system_about) and
  [ReferenceFileDocument](https://developer.apple.com/documentation/swiftui/referencefiledocument)
  — iOS-native document model. We're not adopting this directly (our
  `.reelclip` is a JSON envelope, not a binary file package), but the
  versioning and migration patterns are relevant

## 7. TL;DR for the next session

When we come back to this, the first thing to do is:
1. Confirm the four open questions above
2. Decide if we want to do Phase 1 alone (low-risk accruing fix) or wait
   and do Phases 1–3 together (full scene model + UI in one push)
3. I can also draft a sample `.reelclip` v2 file with 2 scenes so we can
   validate the migration path before shipping

Phase 1 alone is safe and probably worth shipping now — it's a real UX bug
(making clips in one mode then another wipes your work) and the fix is
small.

---

## 8. Implementation status (as of build 55)

Implemented so far:
- ✅ **Phase 1 deferred** — the "Plan X clips" buttons still wipe plannedRanges
  on mode switch. Filed as known issue; will fix in a follow-up slice.
- ✅ **Phase 2 — Scene data model.** `MediaProjectScene` struct lives in
  `MediaProjectStore.swift:77`. `MediaProject` holds `[MediaProjectScene]` +
  `activeSceneId: UUID?`. Legacy v1 projects auto-migrate to a single
  "Scene 1" on load (`MediaProjectStore.swift:276`). `ReelClipProjectFile`
  schema bumped to v2 with `scenes` and `activeSceneId` keys (decode-tolerant).
- ✅ **Scene actions on the view model** (`VideoSplitterViewModel.swift:438`):
  `createSceneSnapshot`, `switchToScene`, `renameActiveScene`, plus the
  two new ones added in this slice: `deleteScene(id:)` and `duplicateScene(id:)`.
- ✅ **Auto-save writes current editor state to the active scene** before
  persisting/exporting (`VideoSplitterViewModel.swift:1853`).
- ✅ **First Cut Recipe scene UI** in `ClipView.swift:865` — active scene menu
  with rename, duplicate, and (this slice) delete actions.

**Implementation choices made in build 55:**

- **`deleteScene` UX** — destructive role button at the bottom of the scene
  menu (iOS native menu convention), separated by a divider. Confirmation
  via a `.confirmationDialog` that names the scene being deleted. The
  active scene falls back to the first remaining scene after deletion
  (or to "no scene" state if the project now has zero scenes).
- **`deleteScene` safety** — the menu item is hidden when there's only one
  scene left, so the user can't delete their last scene into an empty
  state. The model also handles empty-scenes correctly via
  `resetEditorForEmptyScenes()`.
- **`duplicateScene` UX** — duplicates the ACTIVE scene (rather than
  "the scene the menu is over", which is the same thing in practice since
  the menu is anchored to the active scene). The copy is inserted
  immediately after the source, named "<source> Copy", and made the new
  active scene. Uses `PolishKit.Haptics.success` for positive feedback.
- **Per-scene source video** — **shipped in build 57** (data model +
  UI). Each `MediaProjectScene` now holds its own `sourcePath`,
  `sourceFileName`, `sourcePhotoLibraryIdentifier`, `durationSeconds`,
  `sourceAspectRatio`, `frameDurationSeconds`. Legacy v2 projects
  (no per-scene source) decode as scenes with nil source fields; the
  project-level cache is the fallback so they keep working. The
  scene switch (`applyScene` → `applySourceForScene`) regenerates
  thumbnails + waveform when the new scene's source differs from
  the currently loaded one. The scene menu now has a "Change
  source…" item that opens a sheet with Files / Photos pickers,
  wired to `replaceActiveSceneSource(from:)`. The new source
  attaches to the active scene only — other scenes keep their
  source. See `MediaProjectStore.swift:77` for the data model,
  `VideoSplitterViewModel.swift:2163` for `applySourceForScene`,
  `VideoSplitterViewModel.swift:2260` for `installSourceForActiveScene`,
  `ClipView.swift:1095` for the scene menu item.
- **Scene ordering** — no reordering UI yet. Scenes appear in insertion
  order. The model would need a `moveScene(from:to:)` action.

**Open items from the original design doc, status:**

| open question | answer / status |
|---|---|
| Name for auto-generated scene from legacy v1 | "Scene 1" (default). User can rename. |
| Per-scene source vs single project source | single project source for now; per-scene is a Phase 5 item |
| Cross-scene clip references | confirmed decoupled — exported clips survive scene deletion |
| Plan-on-mode-switch UX | **shipped in build 56** — added a `cutMode: CutMode`
  field to `ClipRange` and filtered the timeline / list / export
  pipeline by it. Ranges planned in one mode are preserved in
  `plannedRanges` but invisible in other modes. SmartPause and AI-Assist
  share the "auto" pool so the user can switch between them without
  losing either side. See `SmartCutAnalyzer.swift:4` for the model,
  `VideoSplitterViewModel.swift:70` for the `visiblePlannedRanges`
  helper, `ClipView.swift:218` for the view filter, and
  `VideoSplitterViewModel.swift:1535` for the export flow. |

- **Per-scene export** — **shipped in build 58**. Pre-export chooser
  appears when the user has more than one scene (`Current scene /
  Pick a scene… / All scenes`). The chooser dispatches to
  `prepareExport(target:)` with a new `ExportTarget` enum
  (`.activeScene / .specificScene(UUID) / .allScenes`). The
  `.allScenes` path iterates every scene and renders each one
  with its own source URL (per Phase 4), skipping scenes whose
  source file is missing or whose plannedRanges are empty. Each
  rendered clip is tagged with its source scene name; the preview
  sheet shows a scene-name chip per clip and a "skipped scenes"
  banner at the top. See `VideoSplitterViewModel.swift:32` for
  `ExportTarget`, `:1673` for `prepareExport(target:)`,
  `:1903` for `clipTitlesForRanges`, and
  `ClipView.swift:2860` for the scene picker sub-sheet.
