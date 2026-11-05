#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# Builds rust/flows-bridge as the static libraries the apps link:
#   rust/target/xcode/macosx/libflows_bridge.a           arm64 + x86_64
#   rust/target/xcode/iphonesimulator/libflows_bridge.a  arm64 + x86_64
#   rust/target/xcode/iphoneos/libflows_bridge.a         arm64
# and, through the crate's build.rs, refreshes the generated Swift bindings in
# apple/FLOWS/RustBridge (written only when their bytes change).
#
# Run by the RustBridge aggregate target in apple/project.yml, or by hand.
#
# It builds EVERY platform, EVERY time, and reads nothing from Xcode's
# environment about which one is wanted. Measured: the aggregate target is
# built with the macOS SDK even when an iOS app depends on it
# (PLATFORM_NAME=macosx and SDKROOT=MacOSX during an iOS simulator build), and
# its $ARCHS said arm64 while the app built arm64 + x86_64. Trusting either
# linked nothing into the iOS app. Cargo does no work for an up-to-date target.
#
# Cargo runs in a CLEAN environment: Xcode's SDKROOT and compiler variables
# would otherwise leak into cargo's host-side build scripts. A missing cargo is
# a hard error; silently linking a stale library is how the app would ship
# old Rust.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"

CARGO="$HOME/.cargo/bin/cargo"
[ -x "$CARGO" ] || CARGO="$(command -v cargo 2>/dev/null || true)"
if [ -z "$CARGO" ] || [ ! -x "$CARGO" ]; then
  echo "error: cargo not found. Install Rust (https://rustup.rs); the app links rust/flows-bridge." >&2
  exit 1
fi

# Deployment floors: Xcode exports the project-level values
# (project.yml options.deploymentTarget); the fallbacks match them for a hand run.
MACOS_FLOOR="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
IOS_FLOOR="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

# Which Rust: FLOWS_RUST_TOOLCHAIN names one (as a variable, or as a build
# setting on the xcodebuild line: `xcodebuild ... FLOWS_RUST_TOOLCHAIN=1.93.0`);
# unset, rustup's default builds. Every target below must be installed for
# it (`rustup target add --toolchain <name> <target>`): a default toolchain
# that only has this Mac's own target stops here with "can't find crate for
# `std`".
TOOLCHAIN="${FLOWS_RUST_TOOLCHAIN:-}"

for T in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-ios; do
  env -i HOME="$HOME" PATH="$(dirname "$CARGO"):/usr/bin:/bin:/usr/sbin:/sbin" \
    ${TOOLCHAIN:+RUSTUP_TOOLCHAIN="$TOOLCHAIN"} \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_FLOOR" IPHONEOS_DEPLOYMENT_TARGET="$IOS_FLOOR" \
    "$CARGO" build --release --locked -p flows-bridge --target "$T" \
    --manifest-path "$REPO/rust/Cargo.toml"
done

lib() { echo "$REPO/rust/target/$1/release/libflows_bridge.a"; }

# publish <platform> <library>...: write one library for the platform,
# atomically, so a concurrent link never reads a half-written archive.
publish() {
  dir="$REPO/rust/target/xcode/$1"
  shift
  mkdir -p "$dir"
  if [ "$#" -eq 1 ]; then
    cp -f "$1" "$dir/libflows_bridge.a.tmp"
  else
    lipo -create "$@" -output "$dir/libflows_bridge.a.tmp"
  fi
  mv -f "$dir/libflows_bridge.a.tmp" "$dir/libflows_bridge.a"
}

publish macosx "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)"
publish iphonesimulator "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)"
publish iphoneos "$(lib aarch64-apple-ios)"
