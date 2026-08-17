#!/usr/bin/env bash
set -eu

BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.user.tmux-persist-autosave.plist"

launchctl bootout "gui/$(id -u)/com.user.tmux-persist-autosave" 2>/dev/null || true
rm -f "$LAUNCH_AGENT_DIR/$PLIST_NAME" "$BIN_DIR/persist-autosave.sh"

echo "Uninstalled. Existing snapshots under your tmux-persist directory are untouched."
