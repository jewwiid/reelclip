#!/usr/bin/env bash
#
# install-on-device.sh — bump build number + install the latest ReelClip
# build onto the plugged-in iPhone. Bypasses TestFlight for fast iteration.
#
# What it does, in order:
#   1. Auto-detect an iPhone (or iPad) connected via USB or paired Wi-Fi.
#   2. Bump CURRENT_PROJECT_VERSION in VideoSlicer.xcodeproj by 1.
#   3. xcodebuild Debug for the device (uses the project's dev team).
#   4. xcrun devicectl device install app — direct install, no TestFlight.
#
# Usage:
#   ./scripts/install-on-device.sh           # bump + install
#   ./scripts/install-on-device.sh --no-bump # install without bumping build
#   UDID=<UDID> ./scripts/install-on-device.sh  # target a specific device
#
# Prerequisites:
#   - iPhone plugged in (USB or paired Wi-Fi), unlocked, "Trust"ed
#   - Xcode 15+ for `xcrun devicectl`
#   - Your Apple ID has a Developer profile accepted by the dev team

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/VideoSlicer.xcodeproj"
SCHEME="VideoSlicer"
PBXPROJ="$PROJECT/project.pbxproj"

if [[ ! -f "$PBXPROJ" ]]; then
    echo "error: cannot find $PBXPROJ" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Find a target device
# ---------------------------------------------------------------------------

# Prefer iPhone, fall back to iPad, skip Watch.
find_device_line() {
    xcrun devicectl list devices 2>/dev/null | awk -v IGNORECASE=1 '
        NR <= 2 { next }                    # skip header rows
        /Watch/ { next }                    # skip paired watches
        /iPhone/ { print; exit }
        /iPad/   { print; exit }
    '
}

DEVICE_LINE=""
if [[ -n "${UDID:-}" ]]; then
    # Caller supplied a UDID — look up its name + state for reporting.
    DEVICE_LINE="$(xcrun devicectl list devices 2>/dev/null \
        | awk -v want="$UDID" '
            NR <= 2 { next }
            $0 ~ want { print; exit }
        ')"
fi

if [[ -z "$DEVICE_LINE" ]]; then
    DEVICE_LINE="$(find_device_line)"
fi

if [[ -z "$DEVICE_LINE" ]]; then
    echo "error: no iPhone or iPad found. Plug one in (USB or paired Wi-Fi),"
    echo "       unlock it, tap 'Trust' if prompted, and re-run." >&2
    exit 1
fi

# devicectl output is fixed-width with 2+ space columns.
# Field 1 = Name, 3 = Identifier (UDID), 4 = State.
DEVICE_NAME="$(echo "$DEVICE_LINE" | awk -F'  +' '{print $1}')"
DEVICE_UDID="$(echo "$DEVICE_LINE" | awk -F'  +' '{print $3}')"
DEVICE_STATE="$(echo "$DEVICE_LINE" | awk -F'  +' '{print $4}')"

case "$DEVICE_STATE" in
    available|connected)
        ;;
    *)
        echo "error: '$DEVICE_NAME' is in state '$DEVICE_STATE'." >&2
        echo "       Unlock it, tap 'Trust' if the prompt is up, and re-run." >&2
        exit 1
        ;;
esac

echo "→ target: $DEVICE_NAME ($DEVICE_UDID, $DEVICE_STATE)"

# ---------------------------------------------------------------------------
# 2. Bump CURRENT_PROJECT_VERSION (skippable via --no-bump)
# ---------------------------------------------------------------------------

NEW_BUILD=""
if [[ "${1:-}" != "--no-bump" ]]; then
    # Several targets (app + tests) carry the same build number. Bump the
    # highest existing value across the project so we don't accidentally
    # decrease any section.
    CURRENT_BUILD="$(
        grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$PBXPROJ" \
            | grep -oE '[0-9]+' \
            | sort -n \
            | tail -1
    )"

    if [[ -z "$CURRENT_BUILD" ]]; then
        echo "error: couldn't read CURRENT_PROJECT_VERSION from $PBXPROJ" >&2
        exit 1
    fi

    NEW_BUILD=$((CURRENT_BUILD + 1))

    echo "→ bumping build: $CURRENT_BUILD → $NEW_BUILD"
    # Update every occurrence (app + test targets) in one pass.
    sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBXPROJ"
fi

# ---------------------------------------------------------------------------
# 3. Build Debug for the device
# ---------------------------------------------------------------------------

BUILD_DIR="$PROJECT_DIR/build/device"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ building Debug for $DEVICE_NAME..."
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS,id=$DEVICE_UDID" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build > "$BUILD_DIR/xcodebuild.log" 2>&1
then
    echo "error: xcodebuild failed. Tail of xcodebuild.log:" >&2
    tail -30 "$BUILD_DIR/xcodebuild.log" >&2
    exit 1
fi

APP_PATH="$(
    find "$BUILD_DIR/Build/Products/Debug-iphoneos" -maxdepth 2 -name "*.app" -type d 2>/dev/null \
        | head -1
)"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "error: build succeeded but no .app bundle was produced under" >&2
    echo "       $BUILD_DIR/Build/Products/Debug-iphoneos/" >&2
    exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
echo "→ built $APP_NAME"

# ---------------------------------------------------------------------------
# 4. Install via devicectl
# ---------------------------------------------------------------------------

echo "→ installing on $DEVICE_NAME..."
if ! xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"; then
    echo "error: install failed." >&2
    exit 1
fi

echo ""
if [[ -n "$NEW_BUILD" ]]; then
    echo "✓ ReelClip build $NEW_BUILD installed on $DEVICE_NAME."
else
    echo "✓ $APP_NAME installed on $DEVICE_NAME (build number unchanged)."
fi
echo "  Launch it from the Home screen."