# VideoSlicer TestFlight Checklist

Use this checklist before uploading a beta build and again before inviting external testers.

## Local Build Gate

- `xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -sdk iphonesimulator -configuration Debug build`
- `xcodebuild test -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' -only-testing:VideoSlicerTests/VideoSegmenterTests`
- `xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.4' -configuration Debug build`
- `xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -destination 'generic/platform=iOS' -configuration Release build CODE_SIGNING_ALLOWED=NO`
- `xcodebuild -project VideoSlicer.xcodeproj -scheme VideoSlicer -configuration Release -destination 'generic/platform=iOS' archive -archivePath /tmp/VideoSlicer.xcarchive CODE_SIGNING_ALLOWED=NO`

## Required Before Upload

- Set `DEVELOPMENT_TEAM` to the Apple Developer Team ID.
- Confirm `PRODUCT_BUNDLE_IDENTIFIER` matches the App Store Connect app record.
- Increment `CURRENT_PROJECT_VERSION` for every uploaded build.
- Archive with signing enabled in Xcode or with `xcodebuild archive`.
- Upload with Xcode Organizer, Transporter, or App Store Connect API tooling.
- Confirm TestFlight processing finishes in App Store Connect.
- Answer export compliance questions if App Store Connect requests them.

## Real Device Matrix

Run these on at least one iPhone and one iPad before external TestFlight.

- Fresh install, no Photos permission granted yet.
- Upgrade install over the previous build.
- Portrait and landscape on iPhone.
- Portrait, upside-down portrait, and both landscape orientations on iPad.
- Low battery mode enabled.
- Airplane mode enabled.
- Device storage with at least 5 GB free.
- Device storage intentionally low, if a spare test device is available.

## Video Matrix

Test at least 20-50 real camera-roll videos:

- 5-10 second portrait clip.
- 30-90 second portrait clip.
- 3-10 minute portrait clip.
- Landscape clip.
- 4K clip.
- 60 fps clip.
- Cinematic or HDR clip, if available.
- Clip with no speech.
- Clip with speech pauses.
- Clip with music.
- Clip with no audio track.
- Screen recording.
- Downloaded/shared video from another app.
- Video imported from Files.
- Video imported from a USB-C drive or external storage location visible in Files, especially on iPad.

## Functional Pass Criteria

For each tested video:

- PhotosPicker opens and imports the selected video.
- Files import opens and copies selected video into the app workspace.
- Connected-drive import works after the drive remains attached through the import copy.
- Imported source remains available after leaving and reopening the app.
- Duration displays correctly.
- Source video preview is playable.
- Thumbnail strip appears after import.
- Tapping thumbnails seeks the preview.
- Scrub slider seeks the preview across the source duration.
- Waveform appears for clips with audio and the app remains usable when waveform is unavailable.
- Fixed mode creates expected ranges.
- Smart Pause creates reasonable ranges or falls back to fixed ranges.
- Highlight mode produces non-overlapping planned clips.
- Planned clip ranges visually mark matching thumbnail positions.
- Dragging planned clip handles adjusts start/end times and keeps ranges valid.
- Timeline zoom changes thumbnail density without hiding export controls.
- Reordering planned clips changes export order without changing each clip's start/end timing.
- Changing cut mode, seconds, or prompt clears stale plans.
- Analyze can be cancelled.
- Export can be cancelled.
- Exported clips are playable in Photos.
- Notification permission is requested around export activity, not on first launch.
- Export completion notification appears after clips save to Photos when notifications are allowed.
- Export failure notification appears for a real export error when notifications are allowed.
- Denying notification permission does not block export or saving to Photos.
- Saved clips have expected visual content and audio.
- App remains responsive during and after export.
- Repeating the workflow does not reuse stale clip ranges.
- Repeating the workflow does not grow app storage unexpectedly after successful Photos saves.
- Deleting/reinstalling the app removes app-owned media workspace files.

## Media Management Pass Criteria

- App-owned media is stored under the VideoSlicer workspace, not loose temporary paths.
- Imported source files are copied to the workspace before analysis.
- Export clip folders are unique per export run.
- Export clip folders are cleaned after successful Photos save.
- Cleanup never removes files outside the VideoSlicer workspace.
- Large imports and repeated exports should be checked in iPhone Storage during real-device testing.

## TestFlight Notes

Apple App Store Connect documentation says builds can be uploaded with Xcode, Transporter, `altool`, or App Store Connect API tooling. TestFlight builds are processed before appearing in App Store Connect, and external testing can require beta review.

Apple sources:

- Upload builds:
  https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- TestFlight overview:
  https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Invite external testers:
  https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/
- Export compliance for beta builds:
  https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/
