#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------

# FLOWS self-contained worker (FANS pattern). Runs the continuous test runner
# entirely within /Users/Shared/flows/repo (a mirror of the project) so it
# NEVER touches ~/Documents — no TCC, no Gatekeeper, no grants. launchd
# com.flows.worker (KeepAlive) respawns it within 30s of any crash/reboot.
#
# This is the CANONICAL copy (version-controlled); it is deployed to
# /Users/Shared/flows/worker.sh, which is what the LaunchAgent executes.
#
# SECURITY (hardened after the codebase audit):
#  1. PATH lists SYSTEM directories FIRST so a malicious binary dropped into a
#     user-writable dir (~/.cargo/bin, ~/.local/bin — where pip/cargo installs
#     land) cannot shadow the date/awk/sed/git/find/grep the runner calls by
#     bare name at every boot/restart. ~/.cargo/bin is LAST and only for `cargo`
#     itself. Previously these user dirs were FIRST — a supply-chain file-drop
#     would have gained persistent, KeepAlive-healing execution.
#  2. Refuse to run unless the executed tree is owned by us and not
#     group/other-writable. /Users/Shared is a world-writable sticky dir; if the
#     owner-only guard on flows/ ever lapses, another local user could plant a
#     worker.sh that launchd runs as us. This self-check hard-exits instead.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin"
REPO="/Users/Shared/flows/repo"
SHARED="/Users/Shared/flows"
me="$(/usr/bin/id -u)"

for d in "$SHARED" "$REPO"; do
  [ -d "$d" ] || { echo "[worker] REFUSING: $d missing"; exit 1; }
  if [ "$(/usr/bin/stat -f '%u' "$d")" != "$me" ]; then
    echo "[worker] REFUSING: $d not owned by uid $me (persistence-hijack guard)"; exit 1
  fi
  if [ -n "$(/usr/bin/find "$d" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    echo "[worker] REFUSING: $d is group/other-writable (persistence-hijack guard)"; exit 1
  fi
done

cd "$REPO" || { echo "[worker] mirror unreachable"; exit 1; }
exec /bin/bash "$REPO/scripts/autonomous_test_runner.sh"
