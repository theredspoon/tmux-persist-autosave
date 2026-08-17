#!/usr/bin/env bash
# Installs persist-autosave.sh as a macOS LaunchAgent that runs every 10
# minutes, independent of any attached tmux client.
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.user.tmux-persist-autosave.plist"

if [[ "$(uname)" != "Darwin" ]]; then
	echo "This installer is macOS-only (launchd). On Linux, adapt persist-autosave.sh into a systemd --user timer instead." >&2
	exit 1
fi

mkdir -p "$BIN_DIR" "$LAUNCH_AGENT_DIR"
cp "$REPO_DIR/persist-autosave.sh" "$BIN_DIR/persist-autosave.sh"
chmod +x "$BIN_DIR/persist-autosave.sh"

sed \
	-e "s,__BIN__,$BIN_DIR,g" \
	-e "s,__HOME__,$HOME,g" \
	"$REPO_DIR/$PLIST_NAME" > "$LAUNCH_AGENT_DIR/$PLIST_NAME"

launchctl bootout "gui/$(id -u)/com.user.tmux-persist-autosave" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_DIR/$PLIST_NAME"

echo "Installed. Runs every 10 minutes; first run happens immediately."
echo "Script:  $BIN_DIR/persist-autosave.sh"
echo "Plist:   $LAUNCH_AGENT_DIR/$PLIST_NAME"
echo "Logs:    $HOME/Library/Logs/tmux-persist-autosave.log"
echo
echo "Note: macOS will surface this as a new background item (System Settings"
echo "> General > Login Items & Extensions), labeled 'unidentified developer'"
echo "since it's a plain unsigned script, not a code-signed binary. That's"
echo "expected."
