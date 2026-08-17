#!/usr/bin/env bash
# Periodic full-fleet tmux-persist save, run by launchd independently of any
# attached client. Closes the one gap tmux-persist's own hooks don't cover:
# save-on-exit/detach only fires on a *clean* detach or exit, not a hard
# crash while still attached. This tick fires on a fixed OS timer regardless.
#
# tmux-persist: https://github.com/hyoretsu/tmux-persist
#
# Regression guard (idea adapted from omriariav/tmux-resurrect-launchd
# https://github.com/omriariav/tmux-resurrect-launchd, reimplemented here for
# tmux-persist's per-session snapshot model): if a session's tick-triggered
# save suddenly has far fewer panes than its prior "_last" snapshot, revert
# "_last" to the prior snapshot instead of accepting the degenerate one. This
# is exactly the failure mode that motivated moving off tmux-continuum: a
# session reduced to a bare single pane (e.g. after a crash and respawn)
# would otherwise have its rich saved state silently clobbered by the next
# periodic tick.
#
# To deliberately keep a real teardown (you meant to reduce a session to one
# pane and want that saved), touch "<PERSIST_DIR>/<session>_last.allow_regression"
# before the next tick; the bypass is consumed (removed) after one use.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

TMUX_PERSIST_PLUGIN_DIR="${TMUX_PERSIST_PLUGIN_DIR:-$HOME/.tmux/plugins/tmux-persist}"
SAVE_SCRIPT="$TMUX_PERSIST_PLUGIN_DIR/scripts/save.sh"
LOG_TS="$(date '+%FT%T')"

# Log lines below use paths relative to $HOME so a shared log doesn't leak
# the local username in every line.
short_path() { printf '%s' "${1/#$HOME/\~}"; }

if [ ! -d "$TMUX_PERSIST_PLUGIN_DIR" ]; then
	echo "save: $LOG_TS skipped (tmux-persist not found at $(short_path "$TMUX_PERSIST_PLUGIN_DIR"); set TMUX_PERSIST_PLUGIN_DIR if installed elsewhere)"
	exit 0
fi
if [ ! -x "$SAVE_SCRIPT" ]; then
	echo "save: $LOG_TS skipped (save.sh missing at $(short_path "$SAVE_SCRIPT"))"
	exit 0
fi
if ! tmux ls >/dev/null 2>&1; then
	echo "save: $LOG_TS skipped (no tmux server running)"
	exit 0
fi

# Single-flight lock: mkdir is atomic on any POSIX filesystem, so this is
# portable without depending on flock being installed. Guards against two
# ticks overlapping (a slow save still running when the next timer fires) and
# against a manual "prefix + Ctrl-s" racing our own regression-guard revert.
# A lock older than 5 minutes is treated as stale (left behind by a killed
# run) and reclaimed rather than blocking forever.
LOCK_DIR="${TMPDIR:-/tmp}/tmux-persist-autosave.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	lock_age=9999
	if [ -d "$LOCK_DIR" ]; then
		lock_age=$(( $(date +%s) - $(stat -f '%m' "$LOCK_DIR" 2>/dev/null || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || echo 0) ))
	fi
	if [ "$lock_age" -lt 300 ]; then
		echo "save: $LOG_TS skipped (another run in progress, lock is ${lock_age}s old)"
		exit 0
	fi
	echo "save: $LOG_TS WARN stale lock (${lock_age}s old) — proceeding"
	rmdir "$LOCK_DIR" 2>/dev/null
	mkdir "$LOCK_DIR" 2>/dev/null || true
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# Source tmux-persist's own helpers (rather than reimplementing path/encoding
# logic here) so directory resolution and the session-name-to-filename
# encoding can never drift from what tmux-persist itself actually does.
# set -u is already active, so an unbound variable inside these files aborts
# the whole script here with a normal "unbound variable" error rather than
# being silently swallowed.
CURRENT_DIR="$TMUX_PERSIST_PLUGIN_DIR/scripts"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

PERSIST_DIR="$(persist_dir)"
if [ -z "$PERSIST_DIR" ]; then
	echo "save: $LOG_TS aborted (persist_dir resolved empty; refusing to guess a path)"
	exit 1
fi

count_panes_in_snapshot() {
	# $1 = path to a session's "_last" symlink (may be missing/dangling).
	# Echoes a pane count, or "FAILED" if the snapshot couldn't be read at
	# all (as opposed to genuinely containing zero panes) - the caller must
	# treat those differently, since a failed read isn't evidence of an
	# actual regression.
	local link="$1" target
	[ -L "$link" ] || { echo 0; return; }
	target="$(readlink "$link")"
	case "$target" in
		/*) ;;
		*) target="$PERSIST_DIR/$target" ;;
	esac
	[ -f "$target" ] || { echo 0; return; }
	local layout
	if ! layout="$(tar xzOf "$target" ./layout 2>/dev/null)"; then
		echo "FAILED"
		return
	fi
	printf '%s\n' "$layout" | grep -c $'^pane\t'
}

reverted=0
saved=0
skipped_guard=0
while IFS= read -r session; do
	[ -n "$session" ] || continue
	safe="$(_sanitize_session_for_path "$session")"
	last_link="$PERSIST_DIR/${safe}_last"
	hash_file="${last_link}.hash"
	allow_file="${last_link}.allow_regression"

	prior_target=""
	[ -L "$last_link" ] && prior_target="$(readlink "$last_link")"
	prior_panes="$(count_panes_in_snapshot "$last_link")"
	prior_hash=""
	[ -f "$hash_file" ] && prior_hash="$(cat "$hash_file")"

	"$SAVE_SCRIPT" quiet "$session"
	saved=$((saved + 1))

	new_target=""
	[ -L "$last_link" ] && new_target="$(readlink "$last_link")"
	new_panes="$(count_panes_in_snapshot "$last_link")"

	if [ "$prior_panes" = "FAILED" ] || [ "$new_panes" = "FAILED" ]; then
		skipped_guard=$((skipped_guard + 1))
		echo "save: $LOG_TS regression check skipped for '$session' (snapshot unreadable, not a pane-count signal)"
		continue
	fi

	if [ "$prior_target" != "$new_target" ] && [ "$prior_panes" -ge 2 ] && [ "$new_panes" -le 1 ]; then
		if [ -f "$allow_file" ]; then
			rm -f "$allow_file"
			echo "save: $LOG_TS regression bypassed via .allow_regression for '$session' (prior=$prior_panes new=$new_panes panes)"
			continue
		fi
		# Re-check the symlink still points at what we just wrote before
		# reverting: narrows (does not eliminate) the race against a manual
		# save that lands between our read and this write.
		current="$([ -L "$last_link" ] && readlink "$last_link" || echo "")"
		if [ "$current" != "$new_target" ]; then
			echo "save: $LOG_TS regression check aborted for '$session' (_last changed again since our save; leaving it alone)"
			continue
		fi
		ln -sf "$prior_target" "$last_link"
		[ -n "$prior_hash" ] && printf '%s' "$prior_hash" > "$hash_file"
		reverted=$((reverted + 1))
		echo "save: $LOG_TS regression for '$session' (prior=$prior_panes new=$new_panes panes) — reverted _last to $prior_target; degenerate snapshot $new_target kept on disk for forensics. To keep the new state instead: touch $(short_path "$allow_file")"
	fi
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

echo "save: $LOG_TS done ($saved sessions saved, $reverted reverted, $skipped_guard guard-skipped)"
