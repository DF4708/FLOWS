#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# The Swift twin of `cargo fmt --check`: every hand-written Swift file must
# already be in the shape Apple's own swift-format (it ships with Xcode; no
# third-party tool) gives it under the repo's `.swift-format` rules.
#
#   check_swift_format.sh         check; fails and lists what is out of shape
#   check_swift_format.sh fix     rewrite the files in place
#
# The generated Rust bridge and Xcode's generated files are not ours to shape
# and are left out. The formatter's output can change between versions, so
# the version is pinned: another version fails rather than guessing.
set -eu
PINNED="6.4.4"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
HAVE="$(xcrun swift-format --version)"
if [ "$HAVE" != "$PINNED" ]; then
  echo "swift-format is $HAVE; this repo is shaped by $PINNED." >&2
  echo "Check with that version, or re-shape the tree and change PINNED here." >&2
  exit 1
fi
set -- "${1:-check}" apple/FLOWS/Sources apple/FLOWSWatch apple/FLOWSTests apple/tools
MODE="$1"; shift
case "$MODE" in
  fix) xcrun swift-format format -i -r -p --configuration .swift-format "$@" ;;
  check)
    xcrun swift-format lint --strict -r -p --configuration .swift-format "$@"
    echo "swift format CLEAN" ;;
  *) echo "usage: $0 [check|fix]" >&2; exit 2 ;;
esac
