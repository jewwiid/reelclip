#!/bin/zsh
set -euo pipefail

# Creates a sandbox-only Creator build for the sole internal TestFlight group.
# This is deliberately a separate command from normal archive/upload work.

if [[ $# -ne 1 || ! "$1" =~ '^[0-9]+$' ]]; then
  print "Usage: $0 <new-build-number>"
  exit 64
fi

repo_root="${0:A:h:h}"
build_number="$1"
archive_root="$HOME/Library/Developer/Xcode/Archives/$(date +%F)"
archive_path="$archive_root/ReelClip Internal QA $build_number.xcarchive"

mkdir -p "$archive_root"

xcodebuild archive \
  -project "$repo_root/VideoSlicer.xcodeproj" \
  -scheme VideoSlicer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  CURRENT_PROJECT_VERSION="$build_number" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REELCLIP_INTERNAL_QA'

print "\nCreated internal QA archive: $archive_path"
print "Upload this archive from Xcode Organizer to an internal-only TestFlight group."
