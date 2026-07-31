#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
# Build FLOWS from source and install it to /Applications (falls back to
# ~/Applications when /Applications isn't writable). Run from anywhere:
#
#   ./scripts/install_macos.sh
#
# Prerequisites: Xcode (with macOS SDK), xcodegen (brew install xcodegen),
# and a Rust toolchain (rustup.rs). Refuses to swap the app while it runs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if pgrep -f "FLOWS.app/Contents/MacOS/FLOWS" >/dev/null 2>&1; then
  echo "FLOWS is running — quit it first (never swap a live binary)." >&2
  exit 1
fi

echo "==> Rust core (release)"
cargo build --release --manifest-path "$REPO/rust/Cargo.toml"

echo "==> Xcode project"
(cd "$REPO/apple" && xcodegen generate)

echo "==> App (Release)"
xcodebuild -project "$REPO/apple/FLOWS.xcodeproj" -scheme FLOWS-macOS \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$REPO/apple/DerivedData" build | tail -1

BUILT="$REPO/apple/DerivedData/Build/Products/Release/FLOWS.app"
DEST="/Applications/FLOWS.app"
[ -w /Applications ] || DEST="$HOME/Applications/FLOWS.app"
mkdir -p "$(dirname "$DEST")"

rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# Register with LaunchServices so Spotlight/Finder see the new copy at once.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

echo "Installed: $DEST"
echo "Launch with: open \"$DEST\""
