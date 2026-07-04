#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install_launch_agent.sh — install/uninstall the FLOWS test-runner LaunchAgent
#
# Makes the continuous local worker survive sleep, shutdown, reboot, and crash
# by handing lifecycle management to macOS launchd. See the plist template for
# the KeepAlive / RunAtLoad semantics.
#
# Usage:
#   bash scripts/install_launch_agent.sh install     # install + load + start
#   bash scripts/install_launch_agent.sh uninstall   # stop + unload + remove
#   bash scripts/install_launch_agent.sh status      # show launchd state
# -----------------------------------------------------------------------------

set -uo pipefail

LABEL="com.flows.testrunner"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
TEMPLATE="$PROJECT_DIR/scripts/$LABEL.plist.template"
DOMAIN="gui/$(id -u)"

cmd="${1:-status}"

case "$cmd" in
  install)
    # DEPRECATED + DISABLED (security): this installs com.flows.testrunner,
    # whose plist runs /Applications/FLOW.app's Mach-O — an ad-hoc-signed app
    # that was granted Full Disk Access and executes a user-writable script,
    # i.e. a TCC-bypass bridge (any code that can write the runner script
    # inherits FDA). FLOW.app and its FDA grant have been removed. The active,
    # grant-free worker is com.flows.worker -> /Users/Shared/flows/worker.sh
    # (the FANS pattern), which needs no TCC/Gatekeeper permissions. Do NOT
    # resurrect the FDA path. 'uninstall'/'status' remain available for cleanup.
    echo "REFUSED: 'install' is disabled — it recreates the FLOW.app Full-Disk-Access" >&2
    echo "bridge (a TCC bypass). Use the grant-free com.flows.worker LaunchAgent instead." >&2
    echo "Run 'uninstall' to remove any stale com.flows.testrunner agent." >&2
    exit 2
    ;;
  install_UNSAFE_disabled_do_not_use)
    mkdir -p "$AGENTS_DIR" "$PROJECT_DIR/data/results"
    # Stop any manually-launched runner so launchd is the single owner.
    pkill -f autonomous_test_runner.sh 2>/dev/null || true
    sleep 1
    # Materialise the plist from the template with the real project path.
    sed "s#__PROJECT_DIR__#$PROJECT_DIR#g" "$TEMPLATE" > "$PLIST"
    # bootout any prior instance (ignore errors), then bootstrap fresh.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
      || launchctl load -w "$PLIST"   # fallback for older launchctl
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
    echo "installed + loaded $LABEL"
    echo "  plist: $PLIST"
    echo "  the runner now auto-starts on boot and auto-restarts on crash."
    ;;

  uninstall)
    # Clean stop first so KeepAlive doesn't relaunch during teardown.
    touch "$PROJECT_DIR/tests/.stop_runner"
    sleep 2
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null \
      || launchctl unload -w "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -f "$PROJECT_DIR/tests/.stop_runner"
    echo "uninstalled $LABEL (plist removed, agent unloaded)"
    ;;

  status)
    echo "=== launchctl print $DOMAIN/$LABEL ==="
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
      | grep -E "state|pid|program|run count|last exit" || echo "not loaded"
    echo ""
    echo "plist present: $([ -f "$PLIST" ] && echo yes || echo no)"
    echo "runner process: $(pgrep -f autonomous_test_runner.sh | tr '\n' ' ' || echo none)"
    ;;

  *)
    echo "usage: $0 {install|uninstall|status}"
    exit 1
    ;;
esac
