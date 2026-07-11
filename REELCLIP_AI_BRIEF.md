# ReelClip — Product Brief for AI

> Everything an image generator, copywriter, or strategist needs to produce accurate ReelClip material. Source of truth: `~/Documents/GitHub/reelclip/` (iOS), `~/Documents/GitHub/reelclip-web/` (marketing site), TestFlight group "Jude" (internal beta). Last updated: 2026-07-11.

---

## What ReelClip is

A **native iOS video clipping app** that turns long videos into short, share-ready clips. ReelClip is the **upstream prep tool** in a creator's pipeline: you use ReelClip to **cut / extract** clips from a long source (podcast, livestream, vlog), then take those clips into **CapCut, Instagram Edits, or TikTok** for the final assembly, effects, and publishing. ReelClip does not own the final published video.

**One-line description:** *Cut any video into share-ready clips, on-device by default.*

**Slogan:** *Reelclip — make good clips, Really.* (exact casing: lowercase "Reelclip" and "make", capital "Really" as the punchline.)

**Verb for the watermark / brand line:** *Cut with ReelClip.* This is the action verb, not "Made with" — "Made with" is reserved for the final downstream app (CapCut, Edits, TikTok).

---

## Target user

Content creators who publish to Reels, TikTok, and Shorts but don't have time to scrub through hour-long sources. Primary personas:

- **Podcasters** — long-form talking-head video, need to extract the 30-second moments that hook on social.
- **Coaches / educators / solopreneurs** — recorded Zoom or Loom sessions, need highlight clips for marketing.
- **Livestreamers / event hosts** — 60–180 min streams, need 5–10 shareable moments.

Common trait: they have the *source footage* but the *discovery* (which moments to clip) is the bottleneck. ReelClip's on-device AI handles discovery; the user reviews and refines.

---

## The four cut modes

ReelClip has four mutually exclusive cut modes. The user picks one before analysis:

| Mode | What it does | When to use |
|---|---|---|
| **Cut** (Fixed) | Splits the video at regular intervals (e.g. every 30s). | You want N equal-length clips from a long source. |
| **Silence** (Smart Pause) | Detects silent regions in the audio and cuts around them, producing a tighter version of the original. | The original has long pauses you want to skip. |
| **Splice** (Highlight) | Identifies non-overlapping highlight windows using audio energy + visual cues. | You want the "best" N moments from a long source. |
| **AI** (Apple Intelligence) | Uses on-device Foundation Models to plan clips based on the user's natural-language prompt. | The user describes what they want ("the funniest moments", "the product demo segments") and AI picks. |

All four modes run **on-device**. There is no cloud AI. There is no API key. The Apple Intelligence mode requires an iPhone that supports Apple Intelligence (iPhone 15 Pro and later, or iPhone 16+).

---

## Technical architecture

- **Platform:** iOS 17+. Native Swift / SwiftUI app. Not a React Native or Flutter wrapper.
- **AI:** Foundation Models framework (Apple Intelligence) for the AI cut mode. No third-party AI SDK.
- **Video processing:** AVFoundation (AVAsset, AVAssetExportSession) for slicing, transcoding, and proxy generation.
- **Audio analysis:** Custom audio-energy windowing for Silence mode. No third-party audio SDK.
- **Transcription:** Local Whisper (whisper.spm via `LocalPackages/whisper/`) for the transcript panel. No cloud transcription.
- **Storage:** All source media is copied to the app's private `Library/Application Support/VideoSlicer/` workspace on import. Originals are not modified. Exports go to a custom Photos album called "ReelClip".
- **Persistence:** `MediaProjectStore` + `ReelClipProjectFile` JSON-based project files. Projects can be opened, edited, and re-exported.
- **Build / distribution:** TestFlight beta. Local `xcodebuild` + `xcrun altool` upload pipeline, ASC team `7JSY6J5R99`, internal beta group "Jude".

### Codebase shape

```
VideoSlicer/
├── VideoSlicerApp.swift          # @main entry, root scene
├── VideoSlicerApp entry point
├── Views/
│   ├── RootView.swift            # 3-tab TabView: Home / Clip / Settings
│   ├── HomeView.swift            # Project list + import entry
│   ├── ClipView.swift            # Active project editor (timeline, mode picker, plan list)
│   ├── SettingsView.swift        # Tier, AI toggle, defaults
│   ├── ExportPreviewSheet.swift
│   ├── ImportTrimSheet.swift
│   └── ...                       # One file per screen, ~50 files total
├── VideoSplitterViewModel.swift  # Single ~5,800-line ObservableObject — main business logic
├── MediaWorkspace.swift          # File IO, imports, exports, proxy cache
├── MediaProxyGenerator.swift     # 720p H.264 proxy for fast scrubbing
├── SmartCutAnalyzer.swift        # Splice / Silence detection
├── AppleIntelligenceEditProvider.swift  # AI cut mode (Foundation Models)
├── WhisperTranscriptionService.swift    # Local Whisper wrapper
├── OutroRenderer.swift           # Post-export outro
├── ReelClipPhotoAlbum.swift      # Custom Photos album
├── AppTheme.swift                # AppBrandLockup / AppBrandIcon + palette
└── Assets.xcassets/              # AppIcon, Wordmark, LogoMark, LaunchBackground
```

### Key files for context

- `AppTheme.swift` — `AppPalette`, `AppBrandLockup`, `AppBrandIcon`. The accent color is `Color(red: 0.77, green: 0.94, blue: 0.20)` (a bright lime green).
- `VideoSplitterViewModel.swift` — `importPreparedVideo`, `loadPreparedVideoFile`, `installSourceForActiveScene`, `MediaProxyGenerator` integration.
- `MediaWorkspace.swift` — `importSourceCopyResult` (the file copy step), `MediaImportPreparation.ensureFileIsLocal` (iCloud download handling, added 2026-07-11).

---

## Privacy model

- **No cloud upload.** Source videos never leave the device.
- **No analytics, no tracking.** No third-party SDKs that phone home.
- **Photos permission:** Requested only when the user actively imports from Photos. Scope is "add only" + "read selected".
- **Files picker:** Used for non-Photos sources (DJI Mimo exports, screen recordings, downloaded videos). The app does NOT enumerate the user's files — it only sees the URLs the user explicitly picks.
- **iCloud:** Source files in iCloud Drive are forced to download locally before import (`FileManager.startDownloadingUbiquitousItem`). The local copy lives in the app's sandbox and is not synced to iCloud.
- **Foundation Models / Apple Intelligence:** Runs entirely on-device. No Apple ID or iCloud sign-in required for AI features. The user must have Apple Intelligence enabled in System Settings.

**Privacy marketing line:** *Your video never leaves your phone.*

---

## Pricing

Freemium. Four IAP SKUs:

| SKU | Price | Notes |
|---|---|---|
| Weekly | $2.99 | Highest per-day cost; exists for App Store flexibility. |
| Monthly | $9.99 | "Creator" tier. Most common. |
| Yearly | $59.99 | Best per-month value. |
| Lifetime | $149.99 | One-time. |

The free tier allows import + the Cut / Silence modes with a 30-minute source cap. The paid Creator tier unlocks Splice + AI modes, removes the cap, and adds the Whisper transcript.

---

## Brand

### Visual language

- **Dark mode primary.** AppPalette.background is `#0E0F11` (near-black, slightly cool).
- **Accent color:** `#C4EF33` (lime green / chartreuse). Used for the brand letterform, the primary CTA buttons, and active states.
- **Typography:** SF Pro Rounded at large sizes (titles, brand lockup), SF Pro at body sizes.
- **Branding:** Lime green letterform (R) on a dark surface, with a small leaf flourish at the bottom right. Reads as both "R" and "e" — this dual reading is intentional and on-brand.
- **No emoji in marketing copy.** No exclamation points in copy. No "AI-powered" buzzword. Plain language, conversational tone.

### Slogan + variants

- **Primary slogan:** *Reelclip — make good clips, Really.* (literal, exact)
- **Watermark on exported clips:** *Cut with ReelClip.*
- **Value prop (hero):** *Cut any video into share-ready clips.*
- **Subhead (hero):** *Built for creators who publish to Reels, TikTok, and Shorts. Four cut modes. On-device analysis. Review before export.*
- **Accent line (under hero subhead, uppercase tracked):** *MAKE GOOD CLIPS, REALLY*

### What ReelClip is NOT

- **Not** a final editor. CapCut, Instagram Edits, and TikTok are the final editors. ReelClip is upstream.
- **Not** a cloud service. Everything runs on-device.
- **Not** a video compressor or transcoder (transcoding is a side effect, not the product).
- **Not** a TikTok / Reels publisher. Exports go to the Photos library; the user posts manually.

---

## Competitive positioning

- **vs CapCut:** CapCut does *everything* (cut + edit + effects + publish). ReelClip does *one thing well*: finding the moments. The handoff is "Cut with ReelClip" → "Made with CapCut". Different stages of the workflow.
- **vs Descript / Opus Clip:** Both are cloud-AI clipping tools. They require uploading the source video. ReelClip runs the same AI locally — privacy is the differentiator for podcasters, coaches, and anyone with sensitive content.
- **vs Final Cut Pro / iMovie:** Pro tools. ReelClip is for creators who don't want to learn a timeline editor — they just want the AI to find the moments.
- **vs TikTok's built-in editor:** TikTok's editor is for assembling inside TikTok. ReelClip is for clipping from a *long source* (podcast, livestream) before posting.

---

## Current state (2026-07-11)

- **iOS version:** 1.0 (build 124 on TestFlight).
- **TestFlight group:** "Jude" (internal). All builds in ASC under app ID `6787742864`, bundle ID `app.reelclip.ios`.
- **Marketing site:** `reelclip-web` (Next.js) at `reelclip.app`. Latest deploy via `vercel deploy --prod` (Git auto-deploy not configured).
- **In-progress features:** Outro renderer, animated launch screen, centered outro mark (commit `5ef6a43`).
- **Known issues (active):**
  - DJI Mimo exports on iOS can fail to import with "file doesn't exist" — fixed in build 124 via iCloud-aware `ensureFileIsLocal` in `MediaWorkspace.swift`, monitoring.
  - Wordmark in headers overlaps the iOS status bar on some devices — pending safe-area fix.
  - `AppIcon.appiconset` had only `ios-marketing` entries (no home screen idiom) — fixed in build 119.

---

## Glossary

- **Cut mode** — the active plan-analysis mode (Fixed / Smart Pause / Highlight / AI Assist).
- **Planned range** — a proposed clip's start/end timestamps.
- **Project** — a saved `.reelclip` JSON file containing the source URL, planned ranges, exported clips, and the project transcript.
- **Proxy** — a 720p H.264 copy of the source used for fast timeline scrubbing. Original is kept for export-quality output.
- **Jude** — the internal TestFlight beta group, ID `674b13f7-ff54-4446-8be9-22d6c89fb7c1`.
- **Workspace** — the app's `Library/Application Support/VideoSlicer/` directory. All imports land here.

---

## Pointers for downstream tasks

- **Generate marketing copy** → use the Slogan + Value prop + Privacy line above. Tone: plain, conversational, no buzzwords.
- **Generate UI mockups** → use the Visual language section. Dark surface + lime accent. No device frames unless the deliverable is a press render.
- **Generate press / blog content** → lead with the on-device privacy angle. The differentiator vs Descript/Opus Clip is the privacy story.
- **Generate App Store screenshots** → see `REELCLIP_APP_STORE_SCREENS_PROMPT.md` (sibling file) for the panorama prompt.
- **Answer product questions** → the "What ReelClip is NOT" section is the fastest way to head off "but does it do X" confusion.
