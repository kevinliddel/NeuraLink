#!/bin/bash
#
# Copies dSYMs that Xcode does not pick up automatically into an archive.
#
# Xcode only collects dSYMs for targets it builds. Binary frameworks that are
# embedded from a prebuilt .xcframework keep their dSYMs inside the xcframework
# (if the vendor shipped any at all), so App Store Connect reports
# "Upload Symbols Failed" for them.
#
# Usage:
#   scripts/copy-missing-dsyms.sh /path/to/NeuraLink.xcarchive
#
# Or wire it up as an Archive post-action in the NeuraLink scheme, where Xcode
# provides $ARCHIVE_PATH:
#   Product > Scheme > Edit Scheme > Archive > Post-actions > New Run Script
#   "${PROJECT_DIR}/scripts/copy-missing-dsyms.sh" "${ARCHIVE_PATH}"

set -euo pipefail

ARCHIVE="${1:-${ARCHIVE_PATH:-}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$ARCHIVE" || ! -d "$ARCHIVE" ]]; then
	echo "usage: $(basename "$0") <path to .xcarchive>" >&2
	exit 1
fi

DEST="$ARCHIVE/dSYMs"
mkdir -p "$DEST"

# dSYMs that ship inside a vendored xcframework and can be recovered.
RECOVERABLE=(
	"$REPO_ROOT/NeuraLink/Dependencies/Whisper/whisper.xcframework/ios-arm64/dSYMs/whisper.dSYM"
)

for src in "${RECOVERABLE[@]}"; do
	name="$(basename "$src")"
	if [[ ! -d "$src" ]]; then
		echo "warning: $name not found at $src" >&2
		continue
	fi
	rm -rf "${DEST:?}/$name"
	cp -R "$src" "$DEST/$name"
	echo "copied $name"
done

# Report any embedded framework still without a matching dSYM, so a vendor that
# starts shipping symbols can be added to RECOVERABLE above.
APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -1)"
[[ -d "$APP/Frameworks" ]] || exit 0

for fw in "$APP/Frameworks"/*.framework; do
	name="$(basename "$fw" .framework)"
	bin="$fw/$name"
	[[ -f "$bin" ]] || continue
	uuid="$(dwarfdump --uuid "$bin" 2>/dev/null | awk '{print $2}' | head -1)"
	[[ -n "$uuid" ]] || continue
	if ! grep -qrl "$uuid" --include="*.plist" "$DEST" 2>/dev/null \
		&& ! find "$DEST" -name "*.dSYM" -exec dwarfdump --uuid {} \; 2>/dev/null | grep -q "$uuid"; then
		echo "no dSYM for $name ($uuid) - vendor ships it stripped"
	fi
done
